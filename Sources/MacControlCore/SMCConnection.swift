import Foundation
import Darwin
import CSMC

public enum SMCError: LocalizedError {
    case driver(Int32), invalidKey(String), unsupportedType(String), unavailableFan(Int), unsafeSpeed, requiresRoot, verificationFailed(String)
    case writeNotConfirmed(key: String, requested: Double, observed: Double?)
    public var errorDescription: String? {
        switch self {
        case .driver(let code): return String(format: "AppleSMC returned 0x%08x. This hardware or macOS may not expose the requested operation.", UInt32(bitPattern: code))
        case .invalidKey(let key): return "SMC key unavailable: \(key)"
        case .unsupportedType(let type): return "Unsupported SMC value type: \(type)"
        case .unavailableFan(let id): return "Fan \(id) has no valid hardware speed bounds."
        case .unsafeSpeed: return "Fan speed must be finite, at least 1200 RPM, and within the reported hardware bounds."
        case .requiresRoot: return "Fan control requires the administrator helper."
        case .writeNotConfirmed(let key, let requested, let observed): return "Firmware did not confirm \(key) within the bounded wait (requested \(requested), observed \(observed.map(String.init(describing:)) ?? "unavailable")). Automatic control was requested."
        case .verificationFailed(let key): return "Firmware did not confirm the write to \(key). Automatic control was requested."
        }
    }
}

struct SMCValue {
    let type: String
    let bytes: [UInt8]
    var number: Double? {
        switch type {
        case "ui8 " where bytes.count == 1: return Double(bytes[0])
        case "ui16" where bytes.count == 2: return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
        case "ui32" where bytes.count == 4: return Double(bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
        case "fpe2" where bytes.count == 2: return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) / 4
        case "sp78" where bytes.count == 2: return Double(Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))) / 256
        case "flt " where bytes.count == 4:
            let bits = bytes.enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8*$1.offset) }
            let value = Double(Float(bitPattern: bits))
            return value.isFinite ? value : nil
        default: return nil
        }
    }
}

/// Access to a private, model-dependent hardware interface. A connection serializes all I/O.
/// Monitoring never writes hardware state; only the root helper calls the write methods.
public final class SMCConnection {
    private var connection: UInt32 = 0
    private let lock = NSLock()
    private var temperatureKeys: [String]?

    public init() throws {
        let result = mcp_smc_open(&connection)
        guard result == 0 else { throw SMCError.driver(result) }
    }
    deinit { mcp_smc_close(connection) }

    private func synchronized<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body()
    }
    private func read(_ key: String) throws -> SMCValue {
        guard key.utf8.count == 4 else { throw SMCError.invalidKey(key) }
        var value = MCPValue()
        let result = key.withCString { mcp_smc_read(connection, $0, &value) }
        guard result == 0 else { throw SMCError.driver(result) }
        let chars = (0..<4).map { UInt8(truncatingIfNeeded: value.type >> (24-8*$0)) }
        let type = String(bytes: chars, encoding: .ascii) ?? "????"
        let bytes = withUnsafeBytes(of: value.bytes) { Array($0.prefix(Int(value.size))) }
        return SMCValue(type: type, bytes: bytes)
    }
    private func number(_ key: String) -> Double? { (try? read(key))?.number }
    private func write(_ key: String, number: Double, confirmationTimeout: TimeInterval = 0) throws {
        guard number.isFinite else { throw SMCError.unsafeSpeed }
        let current = try read(key)
        let bytes: [UInt8]
        switch current.type {
        case "flt " where current.bytes.count == 4:
            let bits = Float(number).bitPattern
            bytes = (0..<4).map { UInt8(truncatingIfNeeded: bits >> (8*$0)) }
        case "fpe2" where current.bytes.count == 2:
            guard number >= 0, number <= 16383.75 else { throw SMCError.unsafeSpeed }
            let value = UInt16((number*4).rounded())
            bytes = [UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)]
        case "ui8 " where current.bytes.count == 1:
            guard number >= 0, number <= 255 else { throw SMCError.unsafeSpeed }
            bytes = [UInt8(number)]
        case "ui16" where current.bytes.count == 2:
            guard number >= 0, number <= 65535 else { throw SMCError.unsafeSpeed }
            let value = UInt16(number)
            bytes = [UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)]
        default: throw SMCError.unsupportedType(current.type)
        }
        let result = key.withCString { keyPointer in
            bytes.withUnsafeBufferPointer { mcp_smc_write(connection, keyPointer, $0.baseAddress, UInt32($0.count)) }
        }
        guard result == 0 else { throw SMCError.driver(result) }
        // Some fan target registers acknowledge the write before publishing the new value.
        // Bound this wait below the helper's 2-second IPC deadline; mode writes stay immediate.
        let deadline = ProcessInfo.processInfo.systemUptime + confirmationTimeout
        var observed: Double?
        repeat {
            observed = self.number(key)
            if let observed, abs(observed-number) < 1 { return }
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { break }
            Thread.sleep(forTimeInterval: min(0.025, remaining))
        } while true
        throw SMCError.writeNotConfirmed(key: key, requested: number, observed: observed)
    }
    private func modeKey(_ id: Int) -> String? {
        for key in ["F\(id)md", "F\(id)Md"] where number(key) != nil { return key }
        return nil
    }
    private func fanReadings() -> [FanReading] {
        guard let rawCount = number("FNum"), rawCount.isFinite, rawCount >= 0, rawCount <= 10 else { return [] }
        let forced = Int(number("FS! ") ?? 0)
        return (0..<Int(rawCount)).compactMap { id in
            guard let actual = number("F\(id)Ac"), actual.isFinite, actual >= 0,
                  let lower = number("F\(id)Mn"), lower.isFinite, lower >= 0,
                  let upper = number("F\(id)Mx"), upper.isFinite, upper > 0, upper <= 20_000, upper >= lower else { return nil }
            var name = "Fan \(id+1)"
            if let value = try? read("F\(id)ID"), value.bytes.count > 4 {
                let text = String(bytes: value.bytes.dropFirst(4).prefix { $0 != 0 }, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !text.isEmpty { name = text }
            }
            #if arch(arm64)
            let manual = modeKey(id).flatMap { number($0) }.map { $0 == 1 } ?? ((forced & (1 << id)) != 0)
            #else
            let manual = number("FS! ").map { (Int($0) & (1 << id)) != 0 } ?? (modeKey(id).flatMap { number($0) } == 1)
            #endif
            return FanReading(id: id, name: name, currentRPM: actual, minRPM: lower, maxRPM: upper,
                              targetRPM: number("F\(id)Tg"), isManual: manual)
        }
    }
    public func fans() -> [FanReading] { synchronized { fanReadings() } }
    private func discoverTemperatureKeys() -> [String] {
        var keys = Set<String>()
        if let count = number("#KEY"), count.isFinite, count > 0 {
            for index in 0..<min(UInt32(count), 8192) {
                var bytes = [CChar](repeating: 0, count: 5)
                let result = bytes.withUnsafeMutableBufferPointer { mcp_smc_key_at(connection, index, $0.baseAddress) }
                if result == 0 {
                    let key = String(cString: bytes)
                    if key.utf8.count == 4, key.hasPrefix("T") { keys.insert(key) }
                }
            }
        }
        if keys.isEmpty {
            keys.formUnion(["TC0P", "TC0D", "TC0E", "TC0F", "TG0P", "TG0D", "TB0T", "TB1T", "TA0P", "Tm0P", "Tp0P", "Tp0H", "Te05", "Tp01", "Tg05", "Ts0P"])
        }
        return keys.sorted()
    }
    public func temperatures() -> [TemperatureReading] {
        synchronized {
            if temperatureKeys == nil { temperatureKeys = discoverTemperatureKeys() }
            return (temperatureKeys ?? []).compactMap { key in
                #if arch(arm64)
                // Ta* is thermal headroom on Apple Silicon, not a temperature.
                guard !key.hasPrefix("Ta"), key != "TVMD" else { return nil }
                #endif
                guard let value = try? read(key), ["flt ", "sp78"].contains(value.type),
                      let degrees = value.number, degrees > 0, degrees < 125 else { return nil }
                let label = Self.sensorLabel(key)
                return TemperatureReading(id: key, name: label.name, celsius: degrees, category: label.category)
            }.sorted { $0.category == $1.category ? $0.id < $1.id : $0.category < $1.category }
        }
    }
    private static func sensorLabel(_ key: String) -> (name: String, category: String) {
        let exact: [String: String] = ["TCMb":"CPU die average", "TCMz":"CPU die maximum", "TC0P":"CPU proximity", "TC0D":"CPU diode", "TC0E":"CPU die", "TC0F":"CPU filtered", "TG0P":"GPU proximity", "TG0D":"GPU diode", "TA0P":"Ambient", "TB0T":"Battery", "TB1T":"Battery sensor 1", "Tm0P":"Memory proximity", "Ts0P":"Palm rest"]
        let prefix = String(key.prefix(2))
        let category: String
        switch prefix { case "TC", "Tp", "Te": category = "CPU"; case "TG", "Tg": category = "GPU"; case "TB", "Tb": category = "Battery"; case "Tm", "TM": category = "Memory"; default: category = "System" }
        return (exact[key] ?? "\(category) · \(key)", category)
    }
    private func setManual(_ id: Int, _ manual: Bool) throws {
        #if arch(x86_64)
        if let current = number("FS! ") {
            let mask = Int(current)
            try write("FS! ", number: Double(manual ? mask | (1 << id) : mask & ~(1 << id)))
            return
        }
        #endif
        #if arch(arm64)
        if manual, number("Ftst") != nil { try write("Ftst", number: 1) }
        #endif
        if let key = modeKey(id) {
            try write(key, number: manual ? 1 : 0)
        } else if let current = number("FS! ") {
            let mask = Int(current)
            try write("FS! ", number: Double(manual ? mask | (1 << id) : mask & ~(1 << id)))
        } else { throw SMCError.invalidKey("F\(id)Md") }
    }
    public func setFan(id: Int, rpm: Double) throws {
        try synchronized {
            guard geteuid() == 0 else { throw SMCError.requiresRoot }
            guard let fan = fanReadings().first(where: { $0.id == id }) else { throw SMCError.unavailableFan(id) }
            guard rpm.isFinite, rpm >= max(fan.minRPM, 1200), rpm <= fan.maxRPM else { throw SMCError.unsafeSpeed }
            do {
                try setManual(id, true)
                try write("F\(id)Tg", number: rpm, confirmationTimeout: 0.8)
            } catch {
                try? setManual(id, false)
                #if arch(arm64)
                if number("Ftst") != nil, !fanReadings().contains(where: \.isManual) { try? write("Ftst", number: 0) }
                #endif
                throw error
            }
        }
    }
    public func restoreAutomatic(fanID: Int) throws {
        try synchronized {
            guard geteuid() == 0 else { throw SMCError.requiresRoot }
            guard fanReadings().contains(where: { $0.id == fanID }) else { throw SMCError.unavailableFan(fanID) }
            try setManual(fanID, false)
            #if arch(arm64)
            if number("Ftst") != nil, !fanReadings().contains(where: \.isManual) {
                try write("Ftst", number: 0)
            }
            #endif
        }
    }
    public func restoreAllAutomatic() throws {
        try synchronized {
            guard geteuid() == 0 else { throw SMCError.requiresRoot }
            var firstError: Error?
            for fan in fanReadings() {
                do { try setManual(fan.id, false) } catch { if firstError == nil { firstError = error } }
            }
            #if arch(arm64)
            if number("Ftst") != nil {
                do { try write("Ftst", number: 0) } catch { if firstError == nil { firstError = error } }
            }
            #endif
            if let error = firstError { throw error }
        }
    }
}
