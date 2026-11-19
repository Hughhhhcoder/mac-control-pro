import XCTest
import Darwin
@testable import MacControlCore

final class HelperPolicyTests: XCTestCase {
    func testRefusesMissingOrInvalidTemperatureFeedback() {
        for temperatures in [[], [Double.nan], [-3], [Double.infinity]] as [[Double]] {
            XCTAssertThrowsError(try FanControlPolicy.validateSet(requestedRPM: 2000, minimumRPM: 1000, maximumRPM: 6000, temperatures: temperatures))
        }
        XCTAssertNoThrow(try FanControlPolicy.validateSet(requestedRPM: 2000, minimumRPM: 1000, maximumRPM: 6000, temperatures: [40, 70]))
        XCTAssertNoThrow(try FanControlPolicy.validateSet(requestedRPM: 2000, minimumRPM: 1000, maximumRPM: 6000, temperatures: [42, 93]))
    }

    func testRefusesOutOfRangeAndInvalidRPMBounds() {
        for rpm in [0, 999, 6001, Double.nan, Double.infinity] {
            XCTAssertThrowsError(try FanControlPolicy.validateSet(requestedRPM: rpm, minimumRPM: 1000, maximumRPM: 6000, temperatures: [50]))
        }
        XCTAssertThrowsError(try FanControlPolicy.validateSet(requestedRPM: 2000, minimumRPM: 6000, maximumRPM: 1000, temperatures: [50]))
        XCTAssertThrowsError(try FanControlPolicy.validateSet(requestedRPM: 2000, minimumRPM: 0, maximumRPM: 0, temperatures: [50]))
    }

    func testEachFanHasIndependentLeaseAndRenewal() {
        let start = Date(timeIntervalSince1970: 100)
        var leases = FanLeaseBook()
        leases.renew(fanID: 0, now: start)
        leases.renew(fanID: 1, now: start.addingTimeInterval(4))
        XCTAssertEqual(leases.expired(at: start.addingTimeInterval(11.9)), [])
        XCTAssertEqual(leases.expired(at: start.addingTimeInterval(12)), [0])
        leases.renew(fanID: 0, now: start.addingTimeInterval(12))
        XCTAssertEqual(leases.expired(at: start.addingTimeInterval(16)), [1])
        leases.remove(fanID: 1)
        XCTAssertEqual(leases.fanIDs, [0])
    }

    func testRejectsAmbiguousOrUnsupportedRequests() {
        XCTAssertThrowsError(try FanRequest(command: .status, fanID: 0).validate())
        XCTAssertThrowsError(try FanRequest(command: .automatic, rpm: 1000).validate())
        XCTAssertThrowsError(try FanRequest(command: .set, rpm: 2000).validate())
        XCTAssertThrowsError(try FanRequest(command: .set, fanID: -1, rpm: 2000).validate())
        XCTAssertThrowsError(try FanRequest(command: .set, fanID: 16, rpm: 2000).validate())
        XCTAssertThrowsError(try JSONDecoder().decode(FanRequest.self, from: Data("{\"command\":\"write-key\"}".utf8)))
        XCTAssertNoThrow(try FanRequest(command: .automatic).validate())
    }

    func testProtocolRoundTripRetainsCommandAndBounds() throws {
        let request = FanRequest(command: .set, fanID: 1, rpm: 3250)
        let decoded = try JSONDecoder().decode(FanRequest.self, from: JSONEncoder().encode(request))
        XCTAssertEqual(decoded.command, .set)
        XCTAssertEqual(decoded.fanID, 1)
        XCTAssertEqual(decoded.rpm, 3250)
        try decoded.validate()
    }

    func testSocketFramingAndOversizeDefense() throws {
        var descriptors: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors), 0)
        defer { close(descriptors[0]); close(descriptors[1]) }
        FanControlSocket.configureTimeout(descriptors[0])
        FanControlSocket.configureTimeout(descriptors[1])
        let expected = Data("{\"command\":\"status\"}".utf8)
        try FanControlSocket.send(expected, to: descriptors[0])
        XCTAssertEqual(try FanControlSocket.receive(from: descriptors[1]), expected)
        XCTAssertThrowsError(try FanControlSocket.send(Data(repeating: 1, count: 4097), to: descriptors[0]))
        var oversized = Data(repeating: 65, count: 4097)
        oversized.append(10)
        _ = oversized.withUnsafeBytes { Darwin.write(descriptors[0], $0.baseAddress, $0.count) }
        XCTAssertThrowsError(try FanControlSocket.receive(from: descriptors[1]))
        XCTAssertThrowsError(try FanControlSocket.address(path: String(repeating: "a", count: 150)))
    }

    func testSlowClientCannotExtendAbsoluteMessageDeadline() throws {
        var descriptors: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors), 0)
        defer { close(descriptors[0]); close(descriptors[1]) }
        FanControlSocket.configureTimeout(descriptors[0])
        FanControlSocket.configureTimeout(descriptors[1])
        let writer = descriptors[0]
        let finished = expectation(description: "Slow writer finished")
        DispatchQueue.global().async {
            for _ in 0..<7 {
                var byte: UInt8 = 65
                _ = Darwin.write(writer, &byte, 1)
                Thread.sleep(forTimeInterval: 0.35)
            }
            finished.fulfill()
        }
        let start = ProcessInfo.processInfo.systemUptime
        XCTAssertThrowsError(try FanControlSocket.receive(from: descriptors[1]))
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 2.6)
        wait(for: [finished], timeout: 3)
    }
    func testProtocolTwoRequiresVersionAndSessionOnlyForControl() throws {
        let owner = UUID().uuidString
        let legacy = try JSONDecoder().decode(FanRequest.self, from: Data("{\"command\":\"set\",\"fanID\":0,\"rpm\":2000}".utf8))
        try legacy.validate()
        XCTAssertThrowsError(try legacy.validateForControl()) { XCTAssertEqual(($0 as? FanControlError)?.code, .upgradeRequired) }
        XCTAssertThrowsError(try FanRequest(command: .set, fanID: 0, rpm: 2000).validateForControl())
        XCTAssertThrowsError(try FanRequest(command: .set, fanID: 0, rpm: 2000, protocolVersion: 1, leaseID: owner).validateForControl())
        XCTAssertThrowsError(try FanRequest(command: .renew, fanID: 0, rpm: 2000, leaseID: "not-a-session").validateForControl())
        XCTAssertNoThrow(try FanRequest(command: .set, fanID: 0, rpm: 2000, leaseID: owner).validateForControl())
        XCTAssertNoThrow(try FanRequest(command: .renew, fanID: 0, rpm: 2200, leaseID: owner).validateForControl())
        XCTAssertNoThrow(try FanRequest(command: .automatic, protocolVersion: nil).validate())
    }

    func testRenewalCannotReacquireAfterRecoveryOrExpiry() throws {
        let start = Date(timeIntervalSince1970: 100)
        let owner = UUID().uuidString
        var leases = FanLeaseBook()
        try leases.acquire(fanID: 0, ownerID: owner, now: start)
        try leases.renewExisting(fanID: 0, ownerID: owner, now: start.addingTimeInterval(10))
        XCTAssertThrowsError(try leases.renewExisting(fanID: 0, ownerID: owner, now: start.addingTimeInterval(22))) {
            XCTAssertEqual(($0 as? FanControlError)?.code, .leaseExpired)
        }
        leases.remove(fanID: 0)
        XCTAssertThrowsError(try leases.renewExisting(fanID: 0, ownerID: owner, now: start.addingTimeInterval(23)))
        XCTAssertEqual(leases.fanIDs, [])
        try leases.acquire(fanID: 0, ownerID: owner, now: start.addingTimeInterval(23))
        XCTAssertTrue(leases.isActive(fanID: 0, now: start.addingTimeInterval(24)))
    }

    func testClientsCannotRenewOrReplaceEachOthersActiveFan() throws {
        let now = Date(timeIntervalSince1970: 100)
        let app = UUID().uuidString, cli = UUID().uuidString
        var leases = FanLeaseBook()
        try leases.acquire(fanID: 0, ownerID: app, now: now)
        try leases.acquire(fanID: 1, ownerID: cli, now: now)
        XCTAssertThrowsError(try leases.renewExisting(fanID: 0, ownerID: cli, now: now.addingTimeInterval(1))) {
            XCTAssertEqual(($0 as? FanControlError)?.code, .leaseOwnedByAnotherClient)
        }
        XCTAssertThrowsError(try leases.acquire(fanID: 0, ownerID: cli, now: now.addingTimeInterval(1)))
        XCTAssertEqual(leases.ownerID(fanID: 0), app)
        XCTAssertEqual(leases.ownerID(fanID: 1), cli)
        leases.remove(fanID: 0)
        try leases.acquire(fanID: 0, ownerID: cli, now: now.addingTimeInterval(2))
        XCTAssertEqual(leases.ownerID(fanID: 0), cli)
    }

    func testLegacyResponseDecodesButDoesNotAdvertiseSafeControl() throws {
        let legacy = Data("{\"ok\":true,\"message\":\"Helper ready\",\"manualFanIDs\":[0]}".utf8)
        let reply = try JSONDecoder().decode(HelperResponse.self, from: legacy)
        XCTAssertTrue(reply.ok)
        XCTAssertFalse(reply.supportsSafeControl)
        XCTAssertNil(reply.protocolVersion)
        XCTAssertNil(reply.fanCapabilities)
        XCTAssertEqual(reply.manualFanIDs, [0])
    }

    func testNewStatusAndPendingResponsesRoundTripWithinFrameLimit() throws {
        let capabilities = (0..<16).map { HelperFanCapability(id: $0, canControl: false,
            issue: "Valid minimum and maximum fan speeds are unavailable.", minRPM: 0, maxRPM: 30_000, modeKey: "F0md", targetKey: "F0Tg") }
        let reply = HelperResponse(ok: true, message: "Helper ready; fan control capabilities are reported per fan.", manualFanIDs: [0, 1],
            protocolVersion: 2, helperVersion: "0.2.0", authorizedUID: 502, smcAvailable: true, hardwareModel: "Mac16,7",
            fanCapabilities: capabilities, canControl: false, controlBlockReason: "Read-only fan records.", controlBlockCode: .fanReadOnly,
            temperatureLimitCelsius: 85, hottestTemperatureCelsius: 42, applicationState: .pending,
            retryAfterSeconds: 0.5, pendingFanIDs: [1], lastRecoveryReason: "The client stopped renewing fan 1.", lastRecoveryCode: .leaseExpired)
        let data = try JSONEncoder().encode(reply)
        XCTAssertLessThanOrEqual(data.count, FanControlSocket.maximumMessageBytes)
        let decoded = try JSONDecoder().decode(HelperResponse.self, from: data)
        XCTAssertTrue(decoded.supportsSafeControl)
        XCTAssertEqual(decoded.authorizedUID, 502)
        XCTAssertEqual(decoded.applicationState, .pending)
        XCTAssertEqual(decoded.pendingFanIDs, [1])
        XCTAssertEqual(decoded.fanCapabilities?.count, 16)
        XCTAssertEqual(decoded.controlBlockCode, .fanReadOnly)
        XCTAssertEqual(decoded.lastRecoveryCode, .leaseExpired)
    }

    func testDesktopFanMinimumUsesReportedHardwareRange() {
        XCTAssertEqual(FanControlPolicy.manualMinimumRPM(minimumRPM: 700, maximumRPM: 2000), 700)
        XCTAssertEqual(FanControlPolicy.manualMinimumRPM(minimumRPM: 1000, maximumRPM: 5000), 1000)
        XCTAssertEqual(FanControlPolicy.manualMinimumRPM(minimumRPM: 0, maximumRPM: 800), 800)
        XCTAssertEqual(FanControlPolicy.manualMinimumRPM(minimumRPM: 0, maximumRPM: 8000), 1200)
        XCTAssertNil(FanControlPolicy.manualMinimumRPM(minimumRPM: -1, maximumRPM: 8000))
        XCTAssertNoThrow(try FanControlPolicy.validateSet(requestedRPM: 700, minimumRPM: 700, maximumRPM: 2000, temperatures: [45]))
        XCTAssertNoThrow(try FanControlPolicy.validateSet(requestedRPM: 800, minimumRPM: 0, maximumRPM: 800, temperatures: [45]))
        XCTAssertThrowsError(try FanControlPolicy.validateSet(requestedRPM: 799, minimumRPM: 0, maximumRPM: 800, temperatures: [45]))
    }

    func testGuardStatusAllowsHighReadingsAndStillChecksFeedbackAndSystemPressure() {
        XCTAssertNil(FanControlPolicy.guardFailure(temperatures: [45, 70]))
        XCTAssertNil(FanControlPolicy.guardFailure(temperatures: [45, 85]))
        XCTAssertNil(FanControlPolicy.guardFailure(temperatures: [45, 93]))
        XCTAssertEqual(FanControlPolicy.guardFailure(temperatures: [])?.code, .temperatureUnavailable)
        XCTAssertEqual(FanControlPolicy.guardFailure(temperatures: [.nan])?.code, .temperatureUnavailable)
        XCTAssertEqual(FanControlPolicy.guardFailure(temperatures: [93], thermalPressure: true)?.code, .thermalPressure)
    }

    func testNonReadingPeerCannotBlockSendBeyondAbsoluteDeadline() throws {
        var descriptors: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors), 0)
        defer { close(descriptors[0]); close(descriptors[1]) }
        FanControlSocket.configureTimeout(descriptors[0])
        var smallBuffer: Int32 = 1024
        _ = setsockopt(descriptors[0], SOL_SOCKET, SO_SNDBUF, &smallBuffer, socklen_t(MemoryLayout<Int32>.size))
        let fill = [UInt8](repeating: 65, count: 4096)
        while true {
            let result = fill.withUnsafeBytes { Darwin.send(descriptors[0], $0.baseAddress, $0.count, MSG_DONTWAIT) }
            if result < 0 { break }
        }
        let start = ProcessInfo.processInfo.systemUptime
        XCTAssertThrowsError(try FanControlSocket.send(Data("status".utf8), to: descriptors[0]))
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 2.6)
    }

    func testReleaseOnlySelectsTheRequestingSessionsFans() throws {
        let now = Date(timeIntervalSince1970: 100)
        let app = UUID().uuidString, cli = UUID().uuidString
        var leases = FanLeaseBook()
        try leases.acquire(fanID: 0, ownerID: app, now: now)
        try leases.acquire(fanID: 1, ownerID: cli, now: now)
        try leases.acquire(fanID: 2, ownerID: app, now: now)
        XCTAssertEqual(leases.ownedFanIDs(ownerID: app), [0, 2])
        XCTAssertEqual(leases.ownedFanIDs(ownerID: app, fanID: 1), [])
        XCTAssertEqual(leases.ownedFanIDs(ownerID: UUID().uuidString), [])
        for fanID in leases.ownedFanIDs(ownerID: app) { leases.remove(fanID: fanID) }
        XCTAssertEqual(leases.fanIDs, [1])
        XCTAssertEqual(leases.ownerID(fanID: 1), cli)
    }

    func testReleaseRequiresCurrentProtocolAndValidSessionWithoutRPM() {
        let owner = UUID().uuidString
        XCTAssertNoThrow(try FanRequest(command: .release, leaseID: owner).validateForControl())
        XCTAssertNoThrow(try FanRequest(command: .release, fanID: 1, leaseID: owner).validateForControl())
        XCTAssertThrowsError(try FanRequest(command: .release, leaseID: nil).validateForControl())
        XCTAssertThrowsError(try FanRequest(command: .release, protocolVersion: 1, leaseID: owner).validateForControl())
        XCTAssertThrowsError(try FanRequest(command: .release, fanID: 1, rpm: 2000, leaseID: owner).validateForControl())
        XCTAssertThrowsError(try FanRequest(command: .release, fanID: 16, leaseID: owner).validateForControl())
        XCTAssertThrowsError(try FanRequest(command: .release, leaseID: "other").validateForControl())
    }

}
