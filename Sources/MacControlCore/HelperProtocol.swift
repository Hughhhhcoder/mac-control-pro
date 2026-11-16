import Foundation

public enum FanCommand: String, Codable, Sendable {
    case status, set, automatic
}

/// The helper accepts only these operations; it never executes commands or writes arbitrary SMC keys.
public struct FanRequest: Codable, Sendable {
    public var command: FanCommand
    public var fanID: Int?
    public var rpm: Double?

    public init(command: FanCommand, fanID: Int? = nil, rpm: Double? = nil) {
        self.command = command
        self.fanID = fanID
        self.rpm = rpm
    }

    public func validate() throws {
        if let fanID, !(0..<16).contains(fanID) { throw FanControlError.invalidRequest("Fan ID must be between 0 and 15.") }
        switch command {
        case .status:
            guard fanID == nil, rpm == nil else { throw FanControlError.invalidRequest("Status accepts no parameters.") }
        case .automatic:
            guard rpm == nil else { throw FanControlError.invalidRequest("Automatic mode accepts no RPM.") }
        case .set:
            guard fanID != nil, let rpm, rpm.isFinite, rpm > 0, rpm <= 30_000 else {
                throw FanControlError.invalidRequest("A valid fan ID and finite positive RPM are required.")
            }
        }
    }
}

public struct HelperResponse: Codable, Sendable {
    public var ok: Bool
    public var message: String
    public var manualFanIDs: [Int]

    public init(ok: Bool, message: String, manualFanIDs: [Int] = []) {
        self.ok = ok
        self.message = message
        self.manualFanIDs = manualFanIDs.sorted()
    }
}

public enum FanControlError: LocalizedError {
    case invalidRequest(String)
    case unavailable(String)
    case transport(String)

    public var errorDescription: String? {
        switch self {
        case .invalidRequest(let message), .unavailable(let message), .transport(let message): return message
        }
    }
}

/// Each successful set renews the lease. A stopped or crashed client automatically loses control.
public struct FanLeaseBook: Sendable {
    public static let lifetime: TimeInterval = 12
    private var deadlines: [Int: Date] = [:]
    public init() {}
    public var fanIDs: [Int] { deadlines.keys.sorted() }
    public mutating func renew(fanID: Int, now: Date = Date()) {
        deadlines[fanID] = now.addingTimeInterval(Self.lifetime)
    }
    public func expired(at now: Date = Date()) -> [Int] {
        deadlines.filter { $0.value <= now }.keys.sorted()
    }
    public mutating func remove(fanID: Int) { deadlines.removeValue(forKey: fanID) }
    public mutating func removeAll() { deadlines.removeAll() }
}

public enum FanControlPolicy {
    public static let maximumTemperature = 85.0

    /// Refuse manual overrides when temperature feedback or fan bounds are unavailable.
    public static func validateSet(requestedRPM: Double, minimumRPM: Double, maximumRPM: Double, temperatures: [Double]) throws {
        guard requestedRPM.isFinite, minimumRPM.isFinite, maximumRPM.isFinite,
              minimumRPM >= 0, maximumRPM > minimumRPM, maximumRPM <= 30_000,
              (minimumRPM...maximumRPM).contains(requestedRPM) else {
            throw FanControlError.invalidRequest("RPM is outside this fan's reported hardware limits.")
        }
        guard !temperatures.isEmpty, temperatures.allSatisfy({ $0.isFinite && $0 > 0 && $0 < maximumTemperature }) else {
            throw FanControlError.unavailable("Manual control requires valid temperature readings below 85°C. Use system automatic mode.")
        }
    }
}
