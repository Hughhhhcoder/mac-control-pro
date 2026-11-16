import Foundation

public enum FanControlProtocol {
    public static let currentVersion = 2
    public static let helperVersion = "0.2.0"
}

public enum FanCommand: String, Codable, Sendable {
    case status, set, renew, release, automatic
}

/// Numeric/shape validation is usable without hardware. The helper separately enforces
/// the version and session contract before it grants or renews a control lease.
public struct FanRequest: Codable, Sendable {
    public var command: FanCommand
    public var fanID: Int?
    public var rpm: Double?
    public var protocolVersion: Int?
    public var leaseID: String?

    public init(command: FanCommand, fanID: Int? = nil, rpm: Double? = nil,
                protocolVersion: Int? = FanControlProtocol.currentVersion, leaseID: String? = nil) {
        self.command = command; self.fanID = fanID; self.rpm = rpm
        self.protocolVersion = protocolVersion; self.leaseID = leaseID
    }

    public func validate() throws {
        if let fanID, !(0..<16).contains(fanID) { throw FanControlError.invalidRequest("Fan ID must be between 0 and 15.") }
        if let leaseID, UUID(uuidString: leaseID) == nil { throw FanControlError.invalidRequest("The control session identifier must be a UUID.") }
        switch command {
        case .status:
            guard fanID == nil, rpm == nil, leaseID == nil else { throw FanControlError.invalidRequest("Status accepts no fan, RPM or control session.") }
        case .automatic:
            guard rpm == nil, leaseID == nil else { throw FanControlError.invalidRequest("Automatic mode accepts no RPM or control session.") }
        case .release:
            guard rpm == nil else { throw FanControlError.invalidRequest("Releasing a control session accepts no RPM.") }
        case .set, .renew:
            guard fanID != nil, let rpm, rpm.isFinite, rpm > 0, rpm <= 30_000 else {
                throw FanControlError.invalidRequest("A valid fan ID and finite positive RPM are required.")
            }
        }
    }

    public func validateForControl() throws {
        try validate()
        guard command == .set || command == .renew || command == .release else { throw FanControlError.invalidRequest("This is not a control request.") }
        guard protocolVersion == FanControlProtocol.currentVersion else {
            throw FanControlError.upgradeRequired("The app and fan helper must both use control protocol \(FanControlProtocol.currentVersion). Install the current app and its helper together.")
        }
        guard leaseID != nil else { throw FanControlError.invalidRequest("Control requires an app session identifier.") }
    }
}

public enum HelperErrorCode: String, Codable, Sendable {
    case invalidRequest = "invalid_request"
    case upgradeRequired = "upgrade_required"
    case helperNotInstalled = "helper_not_installed"
    case helperUnavailable = "helper_unavailable"
    case wrongUser = "wrong_user"
    case untrustedHelper = "untrusted_helper"
    case transportFailure = "transport_failure"
    case connectionTimeout = "connection_timeout"
    case smcUnavailable = "smc_unavailable"
    case fanUnavailable = "fan_unavailable"
    case fanReadOnly = "fan_read_only"
    case temperatureUnavailable = "temperature_unavailable"
    case temperatureLimit = "temperature_limit"
    case thermalPressure = "thermal_pressure"
    case leaseExpired = "lease_expired"
    case leaseOwnedByAnotherClient = "lease_owned_by_another_client"
    case writeFailed = "write_failed"
    case recoveryFailed = "recovery_failed"
}

public enum HelperApplicationState: String, Codable, Sendable {
    case pending, applied, released, automatic, blocked
}

public struct HelperFanCapability: Codable, Sendable {
    public var id: Int
    public var canControl: Bool
    public var issue: String?
    public var minRPM: Double?
    public var maxRPM: Double?
    public var modeKey: String?
    public var targetKey: String?

    public init(id: Int, canControl: Bool, issue: String? = nil, minRPM: Double? = nil,
                maxRPM: Double? = nil, modeKey: String? = nil, targetKey: String? = nil) {
        self.id = id; self.canControl = canControl; self.issue = issue; self.minRPM = minRPM
        self.maxRPM = maxRPM; self.modeKey = modeKey; self.targetKey = targetKey
    }
}

/// Optional metadata deliberately decodes responses from the 0.1.x helper, allowing
/// monitoring and emergency automatic recovery while presenting a clear upgrade action.
public struct HelperResponse: Codable, Sendable {
    public var ok: Bool
    public var message: String
    public var manualFanIDs: [Int]
    public var protocolVersion: Int?
    public var helperVersion: String?
    public var authorizedUID: UInt32?
    public var smcAvailable: Bool?
    public var hardwareModel: String?
    public var fanCapabilities: [HelperFanCapability]?
    public var canControl: Bool?
    public var controlBlockReason: String?
    public var controlBlockCode: HelperErrorCode?
    public var temperatureLimitCelsius: Double?
    public var hottestTemperatureCelsius: Double?
    public var requestedRPM: Double?
    public var confirmedTargetRPM: Double?
    public var errorCode: HelperErrorCode?
    public var applicationState: HelperApplicationState?
    public var retryAfterSeconds: Double?
    public var pendingFanIDs: [Int]?
    public var lastRecoveryReason: String?
    public var lastRecoveryCode: HelperErrorCode?

    public var supportsSafeControl: Bool { protocolVersion == FanControlProtocol.currentVersion }

    public init(ok: Bool, message: String, manualFanIDs: [Int] = [],
                protocolVersion: Int? = nil, helperVersion: String? = nil, authorizedUID: UInt32? = nil,
                smcAvailable: Bool? = nil, hardwareModel: String? = nil,
                fanCapabilities: [HelperFanCapability]? = nil, canControl: Bool? = nil,
                controlBlockReason: String? = nil, controlBlockCode: HelperErrorCode? = nil,
                temperatureLimitCelsius: Double? = nil, hottestTemperatureCelsius: Double? = nil,
                requestedRPM: Double? = nil, confirmedTargetRPM: Double? = nil,
                errorCode: HelperErrorCode? = nil, applicationState: HelperApplicationState? = nil,
                retryAfterSeconds: Double? = nil, pendingFanIDs: [Int]? = nil,
                lastRecoveryReason: String? = nil, lastRecoveryCode: HelperErrorCode? = nil) {
        self.ok = ok; self.message = message; self.manualFanIDs = manualFanIDs.sorted()
        self.protocolVersion = protocolVersion; self.helperVersion = helperVersion; self.authorizedUID = authorizedUID
        self.smcAvailable = smcAvailable; self.hardwareModel = hardwareModel; self.fanCapabilities = fanCapabilities
        self.canControl = canControl; self.controlBlockReason = controlBlockReason; self.controlBlockCode = controlBlockCode
        self.temperatureLimitCelsius = temperatureLimitCelsius; self.hottestTemperatureCelsius = hottestTemperatureCelsius
        self.requestedRPM = requestedRPM; self.confirmedTargetRPM = confirmedTargetRPM
        self.errorCode = errorCode; self.applicationState = applicationState; self.retryAfterSeconds = retryAfterSeconds
        self.pendingFanIDs = pendingFanIDs?.sorted()
        self.lastRecoveryReason = lastRecoveryReason; self.lastRecoveryCode = lastRecoveryCode
    }
}

public enum FanControlError: LocalizedError {
    case invalidRequest(String), unavailable(String), transport(String), upgradeRequired(String)
    case leaseExpired(String), leaseOwnedByAnotherClient(String), helperNotInstalled(String)
    case wrongUser(String), untrustedHelper(String), connectionTimeout(String)

    public var code: HelperErrorCode {
        switch self {
        case .invalidRequest: return .invalidRequest
        case .unavailable: return .helperUnavailable
        case .transport: return .transportFailure
        case .upgradeRequired: return .upgradeRequired
        case .leaseExpired: return .leaseExpired
        case .leaseOwnedByAnotherClient: return .leaseOwnedByAnotherClient
        case .helperNotInstalled: return .helperNotInstalled
        case .wrongUser: return .wrongUser
        case .untrustedHelper: return .untrustedHelper
        case .connectionTimeout: return .connectionTimeout
        }
    }
    public var errorDescription: String? {
        switch self {
        case .invalidRequest(let value), .unavailable(let value), .transport(let value), .upgradeRequired(let value),
             .leaseExpired(let value), .leaseOwnedByAnotherClient(let value), .helperNotInstalled(let value),
             .wrongUser(let value), .untrustedHelper(let value), .connectionTimeout(let value): return value
        }
    }
}

/// Ownership and expiry are checked atomically on the helper's serial request loop.
/// A renewal can never create a new lease after a safety recovery or expiry.
public struct FanLeaseBook: Sendable {
    public static let lifetime: TimeInterval = 12
    private struct Lease: Sendable { var deadline: Date; var ownerID: String? }
    private var leases: [Int: Lease] = [:]
    public init() {}
    public var fanIDs: [Int] { leases.keys.sorted() }
    public func ownerID(fanID: Int) -> String? { leases[fanID]?.ownerID }
    public func ownedFanIDs(ownerID: String, fanID: Int? = nil) -> [Int] {
        leases.filter { $0.value.ownerID == ownerID && (fanID == nil || $0.key == fanID) }.keys.sorted()
    }
    public func isActive(fanID: Int, now: Date = Date()) -> Bool { leases[fanID].map { $0.deadline > now } ?? false }
    // Used for importing an already-expired recovery journal and legacy pure-data tests.
    public mutating func renew(fanID: Int, now: Date = Date()) { leases[fanID] = Lease(deadline: now.addingTimeInterval(Self.lifetime), ownerID: leases[fanID]?.ownerID) }
    public mutating func acquire(fanID: Int, ownerID: String, now: Date = Date()) throws {
        if let existing = leases[fanID] {
            guard existing.deadline > now else { throw FanControlError.leaseExpired("This fan's previous control lease expired. Restore automatic mode before starting a new session.") }
            guard existing.ownerID == ownerID else { throw FanControlError.leaseOwnedByAnotherClient("Another app or CLI session owns this fan. Restore automatic mode before taking control.") }
        }
        leases[fanID] = Lease(deadline: now.addingTimeInterval(Self.lifetime), ownerID: ownerID)
    }
    public mutating func renewExisting(fanID: Int, ownerID: String, now: Date = Date()) throws {
        guard let existing = leases[fanID], existing.deadline > now else { throw FanControlError.leaseExpired("The helper ended this control lease. Start a new control session explicitly.") }
        guard existing.ownerID == ownerID else { throw FanControlError.leaseOwnedByAnotherClient("This fan belongs to another control session.") }
        leases[fanID] = Lease(deadline: now.addingTimeInterval(Self.lifetime), ownerID: ownerID)
    }
    public func expired(at now: Date = Date()) -> [Int] { leases.filter { $0.value.deadline <= now }.keys.sorted() }
    public mutating func remove(fanID: Int) { leases.removeValue(forKey: fanID) }
    public mutating func removeAll() { leases.removeAll() }
}

public struct HelperControlBlock: Sendable {
    public var code: HelperErrorCode
    public var message: String
    public init(code: HelperErrorCode, message: String) { self.code = code; self.message = message }
}

public enum FanControlPolicy {
    public static let maximumTemperature = 85.0
    public static let minimumManualRPM = 1200.0

    public static func manualMinimumRPM(minimumRPM: Double, maximumRPM: Double) -> Double? {
        guard minimumRPM.isFinite, maximumRPM.isFinite, minimumRPM >= 0,
              maximumRPM > minimumRPM, maximumRPM <= 30_000 else { return nil }
        return minimumRPM > 0 ? minimumRPM : min(minimumManualRPM, maximumRPM)
    }

    public static func guardFailure(temperatures: [Double], thermalPressure: Bool = false) -> HelperControlBlock? {
        if thermalPressure { return .init(code: .thermalPressure, message: "macOS reports serious or critical thermal pressure. Use system automatic mode.") }
        guard !temperatures.isEmpty, temperatures.allSatisfy({ $0.isFinite && $0 > 0 }) else {
            return .init(code: .temperatureUnavailable, message: "Manual control needs valid temperature feedback. Use system automatic mode.")
        }
        if let hottest = temperatures.max(), hottest >= maximumTemperature {
            return .init(code: .temperatureLimit, message: String(format: "The highest temperature is %.1f°C; manual control is blocked at %.0f°C. Use system automatic mode.", hottest, maximumTemperature))
        }
        return nil
    }

    public static func validateSet(requestedRPM: Double, minimumRPM: Double, maximumRPM: Double, temperatures: [Double]) throws {
        guard requestedRPM.isFinite, let lower = manualMinimumRPM(minimumRPM: minimumRPM, maximumRPM: maximumRPM),
              requestedRPM >= lower, requestedRPM <= maximumRPM else {
            throw FanControlError.invalidRequest("RPM is outside this fan's valid manual control range.")
        }
        if let block = guardFailure(temperatures: temperatures) { throw FanControlError.unavailable(block.message) }
    }
}
