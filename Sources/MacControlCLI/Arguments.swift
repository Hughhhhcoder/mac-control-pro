import Foundation
import MacControlCore

/// Parsing is separate from execution: neither help nor validation can modify hardware.
struct CLIArguments {
    enum Command: String { case read, status, set, auto, curve, help, selfTest }
    var command: Command
    var fanID: Int?
    var rpm: Double?
    var duration: Double = 20
    var sensorID: String?
    var curve: FanCurve?

    static func parse(_ arguments: [String]) throws -> CLIArguments {
        guard let first = arguments.first else { return .init(command: .help) }
        if first == "--help" || first == "-h" || first == "help" {
            guard arguments.count == 1 else { throw CLIError.usage("Help accepts no options.") }
            return .init(command: .help)
        }
        if first == "--self-test" {
            guard arguments.count == 1 else { throw CLIError.usage("Self-test accepts no options.") }
            return .init(command: .selfTest)
        }
        guard let command = Command(rawValue: first), ![.help, .selfTest].contains(command) else {
            throw CLIError.usage("Unknown command: \(first)")
        }
        var options: [String: String] = [:]
        var index = 1
        let names = ["fan", "rpm", "duration", "sensor", "points"]
        while index < arguments.count {
            let token = arguments[index]
            guard token.hasPrefix("--") else { throw CLIError.usage("Unexpected argument: \(token)") }
            let raw = String(token.dropFirst(2))
            let key: String
            let value: String
            if let equals = raw.firstIndex(of: "=") {
                key = String(raw[..<equals]); value = String(raw[raw.index(after: equals)...])
            } else if names.contains(raw) {
                key = raw
                index += 1
                guard index < arguments.count else { throw CLIError.usage("Missing value for --\(key).") }
                value = arguments[index]
            } else if let prefix = ["duration", "fan", "rpm"].first(where: { raw.hasPrefix($0) && raw.count > $0.count }) {
                // Also accepts --fan0, --rpm3000 and --duration20 for script compatibility.
                key = prefix; value = String(raw.dropFirst(prefix.count))
            } else { throw CLIError.usage("Unknown option: \(token)") }
            guard names.contains(key), !value.isEmpty, options[key] == nil else {
                throw CLIError.usage("Unknown, empty or repeated option: --\(key)")
            }
            options[key] = value
            index += 1
        }
        let allowed: Set<String>
        switch command {
        case .set: allowed = ["fan", "rpm", "duration"]
        case .curve: allowed = ["fan", "sensor", "points", "duration"]
        case .auto: allowed = ["fan"]
        default: allowed = []
        }
        guard Set(options.keys).isSubset(of: allowed) else { throw CLIError.usage("This command does not accept those options.") }
        var result = CLIArguments(command: command)
        if let raw = options["fan"] {
            guard let fanID = Int(raw), (0..<16).contains(fanID) else { throw CLIError.usage("Fan ID must be between 0 and 15.") }
            result.fanID = fanID
        }
        if let raw = options["duration"] {
            guard let duration = Double(raw), duration.isFinite, duration > 0, duration <= 60 else {
                throw CLIError.usage("Duration must be greater than 0 and at most 60 seconds.")
            }
            result.duration = duration
        }
        if command == .set {
            guard let fanID = result.fanID, let raw = options["rpm"], let rpm = Double(raw) else {
                throw CLIError.usage("Set requires --fan and --rpm.")
            }
            do { try FanRequest(command: .set, fanID: fanID, rpm: rpm).validate() }
            catch { throw CLIError.usage(error.localizedDescription) }
            result.rpm = rpm
        }
        if command == .curve {
            guard result.fanID != nil, let sensor = options["sensor"], sensor.utf8.count == 4,
                  sensor.unicodeScalars.allSatisfy({ $0.isASCII }), let raw = options["points"] else {
                throw CLIError.usage("Curve requires --fan, a four-character --sensor SMC key and --points.")
            }
            let pairs = raw.split(separator: ",", omittingEmptySubsequences: false)
            guard (2...12).contains(pairs.count) else { throw CLIError.usage("A curve requires 2 to 12 points.") }
            let points: [FanCurvePoint] = try pairs.map { pair in
                let values = pair.split(separator: ":", omittingEmptySubsequences: false)
                guard values.count == 2, let temperature = Double(values[0]), let rpm = Double(values[1]) else {
                    throw CLIError.usage("Use --points '45:3000,65:4000,80:6000' (Celsius:RPM).")
                }
                return FanCurvePoint(temperature: temperature, rpm: rpm)
            }
            let curve = FanCurve(points: points)
            do { try curve.validate() } catch { throw CLIError.usage(error.localizedDescription) }
            result.sensorID = sensor; result.curve = curve
        }
        return result
    }
}


enum CLIError: LocalizedError {
    case usage(String)
    case failed(String)
    var errorDescription: String? {
        switch self { case .usage(let value), .failed(let value): return value }
    }
}
