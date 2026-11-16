import Foundation
import Darwin
import CSMC

public enum SMCError: LocalizedError {
    case driver(Int32), invalidKey(String), unsupportedType(String), unavailableFan(Int), unsafeSpeed, requiresRoot, verificationFailed(String)
    case writeNotConfirmed(key: String, requested: Double, observed: Double?)
    case unlockTimedOut(Int)
    public var errorDescription: String? {
        switch self {
        case .driver(let code): return String(format: "AppleSMC returned 0x%08x. This hardware or macOS may not expose the requested operation.", UInt32(bitPattern: code))
        case .invalidKey(let key): return "SMC key unavailable: \(key)"
        case .unsupportedType(let type): return "Unsupported SMC value type: \(type)"
        case .unavailableFan(let id): return "Fan \(id) does not expose the readings and keys needed for manual control."
        case .unsafeSpeed: return "Fan speed must be positive, finite, and within this fan's reported manual range."
        case .requiresRoot: return "Fan control requires the administrator helper."
        case .writeNotConfirmed(let key, let requested, let observed): return "Firmware did not confirm \(key) within the bounded wait (requested \(requested), observed \(observed.map(String.init(describing:)) ?? "unavailable")). Automatic control was requested."
        case .verificationFailed(let key): return "Firmware did not confirm the write to \(key). Automatic control was requested."
        case .unlockTimedOut(let id): return "Fan \(id) remained under system thermal control after the bounded unlock period. Automatic control was requested."
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
    var supportsNumericWrite: Bool {
        switch type {
        case "flt ": return bytes.count == 4
        case "fpe2", "ui16": return bytes.count == 2
        case "ui8 ": return bytes.count == 1
        default: return false
        }
    }
}

enum SMCPlatform {
    case appleSilicon, intel
    static var current: SMCPlatform {
        #if arch(arm64)
        return .appleSilicon
        #else
        return .intel
        #endif
    }
}

/// The injectable boundary permits multi-fan and protected-mode tests without touching hardware.
protocol SMCTransport: AnyObject {
    func read(_ key: String) throws -> SMCValue
    func write(_ key: String, bytes: [UInt8]) throws
    func key(at index: UInt32) throws -> String
}

private final class LiveSMCTransport: SMCTransport {
    private var connection: UInt32 = 0
    init() throws {
        let result = mcp_smc_open(&connection)
        guard result == 0 else { throw SMCError.driver(result) }
    }
    deinit { mcp_smc_close(connection) }
    func read(_ key: String) throws -> SMCValue {
        guard key.utf8.count == 4 else { throw SMCError.invalidKey(key) }
        var value = MCPValue()
        let result = key.withCString { mcp_smc_read(connection, $0, &value) }
        guard result == 0 else { throw SMCError.driver(result) }
        let chars = (0..<4).map { UInt8(truncatingIfNeeded: value.type >> (24-8*$0)) }
        let type = String(bytes: chars, encoding: .ascii) ?? "????"
        let bytes = withUnsafeBytes(of: value.bytes) { Array($0.prefix(Int(value.size))) }
        return SMCValue(type: type, bytes: bytes)
    }
    func write(_ key: String, bytes: [UInt8]) throws {
        guard key.utf8.count == 4 else { throw SMCError.invalidKey(key) }
        let result = key.withCString { pointer in
            bytes.withUnsafeBufferPointer { mcp_smc_write(connection, pointer, $0.baseAddress, UInt32($0.count)) }
        }
        guard result == 0 else { throw SMCError.driver(result) }
    }
    func key(at index: UInt32) throws -> String {
        var bytes = [CChar](repeating: 0, count: 5)
        let result = bytes.withUnsafeMutableBufferPointer { mcp_smc_key_at(connection, index, $0.baseAddress) }
        guard result == 0 else { throw SMCError.driver(result) }
        return String(cString: bytes)
    }
}

/// Private, model-dependent hardware interface. All connection state and I/O is serialized.
public final class SMCConnection {
    private let transport: SMCTransport
    private let platform: SMCPlatform
    private let hasWritePrivilege: () -> Bool
    private let now: () -> TimeInterval
    private let sleep: (TimeInterval) -> Void
    private let lock = NSLock()
    private var temperatureKeys: [String]?
    private var pendingUnlocks: [Int: TimeInterval] = [:]
    private static let unlockLifetime: TimeInterval = 8

    public convenience init() throws {
        self.init(transport: try LiveSMCTransport(), platform: .current)
    }
    init(transport: SMCTransport, platform: SMCPlatform, hasWritePrivilege: @escaping () -> Bool = { geteuid() == 0 },
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         sleep: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }) {
        self.transport = transport; self.platform = platform; self.hasWritePrivilege = hasWritePrivilege
        self.now = now; self.sleep = sleep
    }
    private func synchronized<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body()
    }
    /// A single hexadecimal index preserves the four-byte SMC key size for IDs 0...15.
    static func fanKey(_ id: Int, _ suffix: String) -> String {
        "F\(String(id, radix: 16, uppercase: true))\(suffix)"
    }
    private func read(_ key: String) throws -> SMCValue { try transport.read(key) }
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
        try transport.write(key, bytes: bytes)
        let deadline = now() + confirmationTimeout
        var observed: Double?
        repeat {
            observed = self.number(key)
            if let observed, abs(observed-number) < 1 { return }
            let remaining = deadline - now()
            guard remaining > 0 else { break }
            sleep(min(0.025, remaining))
        } while true
        throw SMCError.writeNotConfirmed(key: key, requested: number, observed: observed)
    }
    private func modeKey(_ id: Int) -> String? {
        for suffix in ["md", "Md"] {
            let key = Self.fanKey(id, suffix)
            if let value = try? read(key), value.supportsNumericWrite, Self.modeNumber(value) != nil { return key }
        }
        return nil
    }
    private static func modeNumber(_ value: SMCValue?) -> Int? {
        guard let number = value?.number, number.isFinite, number >= 0, number <= 255, number.rounded(.towardZero) == number else { return nil }
        return Int(number)
    }
    private func fanInventoryUnlocked() -> FanInventory {
        let rawCount = number("FNum")
        let count = rawCount.flatMap { value -> Int? in
            guard value.isFinite, (0...16).contains(value), value.rounded(.towardZero) == value else { return nil }
            return Int(value)
        }
        let maskValue = try? read("FS! ")
        let mask = maskValue?.number.flatMap { value -> Int? in
            guard value.isFinite, (0...65535).contains(value), value.rounded(.towardZero) == value else { return nil }
            return Int(value)
        }
        var fans: [FanReading] = []
        for id in 0..<16 {
            let actualValue = try? read(Self.fanKey(id, "Ac"))
            let minimumValue = try? read(Self.fanKey(id, "Mn"))
            let maximumValue = try? read(Self.fanKey(id, "Mx"))
            let targetValue = try? read(Self.fanKey(id, "Tg"))
            let lowerMode = try? read(Self.fanKey(id, "md"))
            let upperMode = try? read(Self.fanKey(id, "Md"))
            let nameValue = try? read(Self.fanKey(id, "ID"))
            let declared = count.map { id < $0 } ?? false
            let evidence = actualValue != nil || minimumValue != nil || maximumValue != nil || targetValue != nil || lowerMode != nil || upperMode != nil || nameValue != nil
            guard declared || evidence else { continue }
            // Hex-only slots are augmented only when an actual-speed value provides evidence.
            if id >= 10, !declared {
                guard let actual = actualValue?.number, actual.isFinite, actual >= 0, actual <= 30_000 else { continue }
            }
            func rpm(_ value: SMCValue?, zeroAllowed: Bool = true) -> Double? {
                guard let number = value?.number, number.isFinite, number >= (zeroAllowed ? 0 : Double.leastNonzeroMagnitude), number <= 30_000 else { return nil }
                return number
            }
            let perFan = [(Self.fanKey(id, "md"), lowerMode), (Self.fanKey(id, "Md"), upperMode)].first {
                $0.1?.supportsNumericWrite == true && Self.modeNumber($0.1) != nil
            }
            let perFanMode = perFan?.1
            let perFanKey = perFan?.0
            let resolvedMode: Int?
            let resolvedModeKey: String?
            if platform == .intel, let mask, maskValue?.supportsNumericWrite == true {
                resolvedMode = (mask & (1 << id)) == 0 ? 0 : 1
                resolvedModeKey = "FS! "
            } else if let value = perFanMode, value.supportsNumericWrite, let mode = Self.modeNumber(value) {
                resolvedMode = mode; resolvedModeKey = perFanKey
            } else if let mask, maskValue?.supportsNumericWrite == true {
                resolvedMode = (mask & (1 << id)) == 0 ? 0 : 1; resolvedModeKey = "FS! "
            } else { resolvedMode = nil; resolvedModeKey = nil }
            var name = "Fan \(id + 1)"
            if let value = nameValue {
                let nameBytes = value.type == "ch8*" ? value.bytes : Array(value.bytes.dropFirst(4))
                if let decoded = String(bytes: nameBytes.prefix { $0 != 0 }, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !decoded.isEmpty { name = decoded }
            }
            let target = rpm(targetValue)
            fans.append(FanReading(id: id, name: name, currentRPM: rpm(actualValue), minRPM: rpm(minimumValue), maxRPM: rpm(maximumValue, zeroAllowed: false),
                                   targetRPM: target, isManual: resolvedMode == 1, modeRawValue: resolvedMode, modeKey: resolvedModeKey,
                                   targetKey: target != nil && targetValue?.supportsNumericWrite == true ? Self.fanKey(id, "Tg") : nil))
        }
        let message: String
        if let count, count != fans.count {
            message = "SMC FNum reports \(count) fans; indexed keys expose \(fans.count) fan records. All detected records are retained."
        } else if let count, count == 0 {
            message = "SMC reports zero fans and no indexed fan keys are readable."
        } else if let count {
            message = "SMC reports \(count) fans. Missing readings are preserved as unavailable."
        } else if fans.isEmpty {
            message = "SMC fan count is unavailable and no indexed fan keys are readable; this does not establish that the Mac is fanless."
        } else {
            message = "SMC fan count is unavailable or invalid; discovered \(fans.count) fans from indexed keys."
        }
        return FanInventory(fans: fans, reportedFanCount: count, message: message)
    }
    public func fanInventory() -> FanInventory { synchronized { fanInventoryUnlocked() } }
    public func fans() -> [FanReading] { fanInventory().fans }

    private func discoverTemperatureKeys() -> [String] {
        var keys = Set<String>()
        if let count = number("#KEY"), count.isFinite, count > 0 {
            for index in 0..<UInt32(min(count.rounded(.down), 8192)) {
                if let key = try? transport.key(at: index), key.utf8.count == 4, key.hasPrefix("T") { keys.insert(key) }
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
                if platform == .appleSilicon, key.hasPrefix("Ta") || key == "TVMD" { return nil }
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
    private func releaseGlobalUnlockIfUnused() throws {
        guard platform == .appleSilicon, pendingUnlocks.isEmpty, let unlock = number("Ftst"), unlock != 0 else { return }
        let fans = fanInventoryUnlocked().fans
        guard !fans.contains(where: \.isManual) else { return }
        guard fans.allSatisfy({ $0.modeRawValue != nil }) else { throw SMCError.verificationFailed("fan mode before Ftst release") }
        try write("Ftst", number: 0)
    }
    private func setManual(_ id: Int, _ manual: Bool) throws -> FanSetResult {
        guard (0..<16).contains(id) else { throw SMCError.unavailableFan(id) }
        if !manual { pendingUnlocks.removeValue(forKey: id) }
        if manual, let started = pendingUnlocks[id], now() - started >= Self.unlockLifetime { throw SMCError.unlockTimedOut(id) }
        if platform == .intel, let value = try? read("FS! "), value.supportsNumericWrite,
           let current = value.number, current >= 0, current <= 65535, current.rounded(.towardZero) == current {
            let mask = Int(current)
            try write("FS! ", number: Double(manual ? mask | (1 << id) : mask & ~(1 << id)))
            return .applied
        }
        guard let key = modeKey(id) else {
            if let value = try? read("FS! "), value.supportsNumericWrite,
               let current = value.number, current >= 0, current <= 65535, current.rounded(.towardZero) == current {
                let mask = Int(current)
                try write("FS! ", number: Double(manual ? mask | (1 << id) : mask & ~(1 << id)))
                return .applied
            }
            throw SMCError.invalidKey(Self.fanKey(id, "md/Md"))
        }
        if !manual {
            try write(key, number: 0)
            return .applied
        }
        do {
            // Direct mode changes work on unprotected firmware and avoid unnecessary Ftst writes.
            try write(key, number: 1)
            pendingUnlocks.removeValue(forKey: id)
            return .applied
        } catch {
            // Some protected firmware still reports automatic mode (0), while other models
            // report system mode (3). Both may need Ftst after a direct mode write fails.
            // Unknown mode values never enter diagnostic unlock. Retry on later renewals
            // so the helper's temperature and lease watchdogs remain responsive.
            guard platform == .appleSilicon, let observedMode = number(key), [0.0, 3.0].contains(observedMode),
                  let unlock = try? read("Ftst"), unlock.supportsNumericWrite, unlock.number != nil else { throw error }
            if let started = pendingUnlocks[id] {
                guard now() - started < Self.unlockLifetime else { throw SMCError.unlockTimedOut(id) }
            } else {
                if unlock.number != 1 { try write("Ftst", number: 1) }
                pendingUnlocks[id] = now()
            }
            return .pending(retryAfter: 0.5, message: "Waiting for the system thermal manager to release fan \(id + 1).")
        }
    }
    @discardableResult public func setFan(id: Int, rpm: Double) throws -> FanSetResult {
        try synchronized {
            guard hasWritePrivilege() else { throw SMCError.requiresRoot }
            guard let fan = fanInventoryUnlocked().fans.first(where: { $0.id == id }), fan.canRequestControl,
                  let minimum = fan.manualMinimumRPM, let maximum = fan.maxRPM else { throw SMCError.unavailableFan(id) }
            guard rpm.isFinite, rpm > 0, rpm >= minimum, rpm <= maximum else { throw SMCError.unsafeSpeed }
            do {
                let result = try setManual(id, true)
                if case .pending = result { return result }
                try write(Self.fanKey(id, "Tg"), number: rpm, confirmationTimeout: 0.8)
                let confirmed = fanInventoryUnlocked().fans.first(where: { $0.id == id })
                guard confirmed?.isManual == true else {
                    throw SMCError.verificationFailed(confirmed?.modeKey ?? fan.modeKey ?? "fan \(id + 1) manual mode")
                }
                guard let target = confirmed?.targetRPM, abs(target - rpm) < 1 else {
                    throw SMCError.writeNotConfirmed(key: Self.fanKey(id, "Tg"), requested: rpm, observed: confirmed?.targetRPM)
                }
                return .applied
            } catch {
                _ = try? setManual(id, false)
                try? releaseGlobalUnlockIfUnused()
                throw error
            }
        }
    }
    public func restoreAutomatic(fanID: Int) throws {
        try synchronized {
            guard hasWritePrivilege() else { throw SMCError.requiresRoot }
            _ = try setManual(fanID, false)
            try releaseGlobalUnlockIfUnused()
        }
    }
    public func restoreAllAutomatic() throws {
        try synchronized {
            guard hasWritePrivilege() else { throw SMCError.requiresRoot }
            let ids = Set(fanInventoryUnlocked().fans.map(\.id)).union(pendingUnlocks.keys).sorted()
            var firstError: Error?
            for id in ids {
                do { _ = try setManual(id, false) } catch { if firstError == nil { firstError = error } }
            }
            do { try releaseGlobalUnlockIfUnused() } catch { if firstError == nil { firstError = error } }
            if let error = firstError { throw error }
        }
    }
}
