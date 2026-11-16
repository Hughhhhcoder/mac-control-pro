import Foundation
import XCTest
import MacControlCore
@testable import MacControlPro

private final class FakeHardware: HardwareSource, @unchecked Sendable {
    private let lock = NSLock()
    private var value: SystemSnapshot
    private var reconnectCount = 0
    init(_ snapshot: SystemSnapshot) { value = snapshot }
    func snapshot() -> SystemSnapshot { lock.lock(); defer { lock.unlock() }; return value }
    func replace(_ snapshot: SystemSnapshot) { lock.lock(); value = snapshot; lock.unlock() }
    func reconnect() -> Bool { lock.lock(); reconnectCount += 1; lock.unlock(); return true }
}

private final class FakeService: FanService, @unchecked Sendable {
    enum Operation: Equatable { case status, set, renew, automatic, release }
    struct Call: Equatable { let operation: Operation; let fanID: Int?; let rpm: Double? }
    private let lock = NSLock()
    private var recorded: [Call] = []
    private var owned: Set<Int> = []
    private var statusFailure: Error?
    private var statusOverride: HelperResponse?
    private var setReplies: [HelperResponse] = []
    private var renewReplies: [HelperResponse] = []
    private var automaticReply: HelperResponse?
    private var setGate: DispatchSemaphore?
    private var releaseGate: DispatchSemaphore?

    func configureStatus(_ response: HelperResponse) { locked { statusOverride = response } }
    func configureStatus(error: Error) { locked { statusFailure = error } }
    func configureSet(_ replies: [HelperResponse]) { locked { setReplies = replies } }
    func configureRenew(_ replies: [HelperResponse]) { locked { renewReplies = replies } }
    func configureAutomatic(_ reply: HelperResponse) { locked { automaticReply = reply } }
    func holdSet(with semaphore: DispatchSemaphore) { locked { setGate = semaphore } }
    func holdRelease(with semaphore: DispatchSemaphore) { locked { releaseGate = semaphore } }
    func stopHoldingSets() { locked { setGate = nil } }
    var calls: [Call] { locked { recorded } }
    private func locked<T>(_ action: () throws -> T) rethrows -> T { lock.lock(); defer { lock.unlock() }; return try action() }

    static func ready(owned: [Int] = []) -> HelperResponse {
        HelperResponse(ok: true, message: "Ready", manualFanIDs: owned,
                       protocolVersion: FanControlProtocol.currentVersion, smcAvailable: true, canControl: true)
    }
    static func applied(_ fan: Int, rpm: Double) -> HelperResponse {
        HelperResponse(ok: true, message: "Applied", manualFanIDs: [fan],
                       protocolVersion: FanControlProtocol.currentVersion, smcAvailable: true, canControl: true,
                       requestedRPM: rpm, confirmedTargetRPM: rpm, applicationState: .applied)
    }
    func status() throws -> HelperResponse {
        try locked {
            recorded.append(.init(operation: .status, fanID: nil, rpm: nil))
            if let statusFailure { throw statusFailure }
            return statusOverride ?? Self.ready(owned: owned.sorted())
        }
    }
    func set(fanID: Int, rpm: Double) throws -> HelperResponse {
        let gate = locked { () -> DispatchSemaphore? in
            recorded.append(.init(operation: .set, fanID: fanID, rpm: rpm))
            return setGate
        }
        if let gate, gate.wait(timeout: .now() + 5) != .success { throw FanControlError.connectionTimeout("Test gate timed out") }
        return locked {
            let reply = setReplies.isEmpty ? Self.applied(fanID, rpm: rpm) : setReplies.removeFirst()
            if reply.ok { owned.insert(fanID) }
            return reply
        }
    }
    func renew(fanID: Int, rpm: Double) throws -> HelperResponse {
        locked {
            recorded.append(.init(operation: .renew, fanID: fanID, rpm: rpm))
            if !renewReplies.isEmpty {
                let reply = renewReplies.removeFirst()
                if !reply.ok { owned.remove(fanID) }
                return reply
            }
            guard owned.contains(fanID) else {
                return HelperResponse(ok: false, message: "Lease ended", protocolVersion: FanControlProtocol.currentVersion, errorCode: .leaseExpired, applicationState: .blocked)
            }
            return Self.applied(fanID, rpm: rpm)
        }
    }
    func automatic(fanID: Int?) throws -> HelperResponse {
        locked {
            recorded.append(.init(operation: .automatic, fanID: fanID, rpm: nil))
            if let automaticReply { return automaticReply }
            if let fanID { owned.remove(fanID) } else { owned.removeAll() }
            return HelperResponse(ok: true, message: "Automatic", manualFanIDs: owned.sorted(), protocolVersion: FanControlProtocol.currentVersion, applicationState: .automatic)
        }
    }
    func release(fanID: Int?) throws -> HelperResponse {
        let gate = locked { () -> DispatchSemaphore? in
            recorded.append(.init(operation: .release, fanID: fanID, rpm: nil))
            return releaseGate
        }
        if let gate, gate.wait(timeout: .now() + 5) != .success { throw FanControlError.connectionTimeout("Test release gate timed out") }
        return locked {
            if let fanID { owned.remove(fanID) } else { owned.removeAll() }
            return HelperResponse(ok: true, message: "Released", manualFanIDs: owned.sorted(), protocolVersion: FanControlProtocol.currentVersion, applicationState: .released)
        }
    }
}

final class AppModelTests: XCTestCase {
    private func fan(_ id: Int = 0, minimum: Double? = 2000, maximum: Double? = 8250) -> FanReading {
        FanReading(id: id, name: "Test fan \(id)", currentRPM: 2500, minRPM: minimum, maxRPM: maximum,
                   targetRPM: 2500, modeRawValue: 0, modeKey: "F\(id)md", targetKey: "F\(id)Tg")
    }
    private func snapshot(fans: [FanReading]) -> SystemSnapshot {
        SystemSnapshot(date: Date(), cpuUsage: 10, memoryUsedBytes: 1_000_000, memoryTotalBytes: 2_000_000,
                       batteryPercent: nil, isOnACPower: true, thermalState: "Nominal", uptime: 100,
                       fans: fans, temperatures: [.init(id: "TCMb", name: "CPU", celsius: 65, category: "CPU")],
                       hardwareModel: "Test Mac", chipName: "Fixture", smcStatus: "In-memory fixture",
                       reportedFanCount: fans.count, smcAvailable: true)
    }
    @MainActor private func model(service: FakeService, fans: [FanReading]? = nil, preferences: UserDefaults? = nil) -> AppModel {
        AppModel(monitor: FakeHardware(snapshot(fans: fans ?? [fan()])), helperClient: service,
                 preferences: preferences ?? UserDefaults(suiteName: "MacControlProTests.\(UUID().uuidString)")!,
                 startsAutomatically: false, persistsPreferences: false, demoMode: false)
    }
    @MainActor private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while ProcessInfo.processInfo.systemUptime < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Asynchronous condition did not complete", file: file, line: line)
    }
    @MainActor private func connect(_ model: AppModel) async {
        model.refresh()
        await waitUntil { model.serviceCondition != .checking }
    }

    @MainActor func testDisabledStartupDoesNotConnectOrPersistPreferences() async throws {
        let service = FakeService()
        let preferences = try XCTUnwrap(UserDefaults(suiteName: "MacControlProTests.\(UUID().uuidString)"))
        let before = preferences.string(forKey: "language")
        let app = model(service: service, preferences: preferences)
        app.language = "en"
        XCTAssertTrue(service.calls.isEmpty)
        XCTAssertEqual(preferences.string(forKey: "language"), before)
        XCTAssertFalse(app.demo)
    }

    @MainActor func testLegacyHelperIsOutdatedAndCannotWrite() async {
        let service = FakeService(); service.configureStatus(.init(ok: true, message: "Legacy"))
        let app = model(service: service); await connect(app)
        XCTAssertEqual(app.serviceCondition, .outdated)
        let applied = await app.setFixed(fan(), rpm: 3000)
        XCTAssertFalse(applied)
        XCTAssertTrue(service.calls.filter { $0.operation == .set }.isEmpty)
        XCTAssertTrue(app.policies.isEmpty)
    }

    @MainActor func testTypedMissingAndWrongUserErrorsHaveStableConditions() async {
        for (error, expected) in [(FanControlError.helperNotInstalled("Missing fixture"), ServiceCondition.missing), (.wrongUser("Wrong fixture user"), .otherUser)] {
            let service = FakeService(); service.configureStatus(error: error)
            let app = model(service: service); await connect(app)
            XCTAssertEqual(app.serviceCondition, expected)
            XCTAssertFalse(app.helperAvailable)
            let applied = await app.setFixed(fan(), rpm: 3000)
            XCTAssertFalse(applied)
            XCTAssertFalse(service.calls.contains { $0.operation == .set })
        }
    }

    @MainActor func testRejectedSetNeverBecomesActiveAndReleasesSession() async {
        let service = FakeService()
        service.configureSet([.init(ok: false, message: "Firmware refused", protocolVersion: FanControlProtocol.currentVersion, errorCode: .writeFailed, applicationState: .blocked)])
        let app = model(service: service); await connect(app)
        let applied = await app.setFixed(fan(), rpm: 3000)
        XCTAssertFalse(applied); XCTAssertTrue(app.policies.isEmpty)
        XCTAssertEqual(app.fanActions[0]?.phase, .failed)
        XCTAssertTrue(service.calls.contains { $0.operation == .release && $0.fanID == 0 })
    }

    @MainActor func testPendingApplicationWaitsThenUsesRenewalForConfirmation() async {
        let service = FakeService()
        service.configureSet([.init(ok: true, message: "Waiting", manualFanIDs: [0], protocolVersion: FanControlProtocol.currentVersion, applicationState: .pending, retryAfterSeconds: 0.1, pendingFanIDs: [0])])
        service.configureRenew([FakeService.applied(0, rpm: 3000)])
        let app = model(service: service); await connect(app)
        let task = Task { await app.setFixed(fan(), rpm: 3000) }
        await waitUntil { app.fanActions[0]?.phase == .waiting }
        XCTAssertTrue(app.policies.isEmpty)
        let applied = await task.value
        XCTAssertTrue(applied); XCTAssertEqual(app.fanActions[0]?.phase, .active)
        XCTAssertNotNil(app.policies[0])
        XCTAssertEqual(service.calls.filter { $0.operation == .set }.count, 1)
        XCTAssertEqual(service.calls.filter { $0.operation == .renew }.count, 1)
    }

    @MainActor func testRenewalPendingIsVisibleAndUnconfirmedRenewalReleasesControl() async {
        let service = FakeService(); let app = model(service: service); await connect(app)
        let applied = await app.setFixed(fan(), rpm: 3000); XCTAssertTrue(applied)
        service.configureRenew([.init(ok: true, message: "Firmware reclaimed control", manualFanIDs: [0], protocolVersion: FanControlProtocol.currentVersion, applicationState: .pending)])
        app.refresh()
        await waitUntil { app.fanActions[0]?.phase == .waiting }
        XCTAssertNotNil(app.policies[0])
        service.configureRenew([.init(ok: true, message: "Missing confirmation", manualFanIDs: [0], protocolVersion: FanControlProtocol.currentVersion)])
        app.refresh()
        await waitUntil { app.fanActions[0]?.phase == .failed }
        XCTAssertTrue(app.policies.isEmpty)
        await waitUntil { service.calls.contains { $0.operation == .release && $0.fanID == 0 } }
    }

    @MainActor func testCancellationCannotBeRearmedByDelayedSetCompletion() async {
        let service = FakeService(); let gate = DispatchSemaphore(value: 0); service.holdSet(with: gate)
        let app = model(service: service); await connect(app)
        let task = Task { await app.setFixed(fan(), rpm: 3000) }
        await waitUntil { service.calls.contains { $0.operation == .set } }
        app.cancelControl(0)
        XCTAssertTrue(app.policies.isEmpty)
        gate.signal()
        let applied = await task.value
        XCTAssertFalse(applied)
        await waitUntil { service.calls.contains { $0.operation == .release } }
        XCTAssertTrue(app.policies.isEmpty)
        XCTAssertNotEqual(app.fanActions[0]?.phase, .active)
    }

    @MainActor func testActivePolicyUsesAtomicRenewAndDoesNotReacquireAfterFailure() async {
        let service = FakeService(); let app = model(service: service); await connect(app)
        let applied = await app.setFixed(fan(), rpm: 3000); XCTAssertTrue(applied)
        service.configureRenew([.init(ok: false, message: "Lease expired", protocolVersion: FanControlProtocol.currentVersion, errorCode: .leaseExpired, applicationState: .blocked)])
        app.refresh()
        await waitUntil { app.fanActions[0]?.phase == .failed && service.calls.contains(where: { $0.operation == .release }) }
        XCTAssertTrue(app.policies.isEmpty)
        XCTAssertEqual(service.calls.filter { $0.operation == .set }.count, 1)
        XCTAssertEqual(service.calls.filter { $0.operation == .renew }.count, 1)
        XCTAssertTrue(service.calls.contains { $0.operation == .release })
    }

    @MainActor func testRestoreAllStopsAnAwaitingTwoFanProfileBeforeTheNextFan() async {
        let first = fan(0), second = fan(1)
        let service = FakeService(), gate = DispatchSemaphore(value: 0)
        service.holdSet(with: gate)
        let app = model(service: service, fans: [first, second]); await connect(app)
        let task = Task { await app.applyProfile(CoolingProfile.builtIns[0]) }
        await waitUntil { service.calls.contains { $0.operation == .set && $0.fanID == 0 } }
        app.restoreAll()
        gate.signal()
        let applied = await task.value
        XCTAssertFalse(applied)
        await waitUntil { service.calls.contains { $0.operation == .automatic && $0.fanID == nil } }
        XCTAssertEqual(service.calls.filter { $0.operation == .set }.map(\.fanID), [0])
        XCTAssertTrue(app.policies.isEmpty)
        XCTAssertNil(app.fanActions[1])
        XCTAssertNil(app.message, "A stale profile must not replace restoration with a partial-apply warning")
    }

    @MainActor func testNewerTwoFanProfileSupersedesAnAwaitingOlderProfile() async {
        let service = FakeService(), gate = DispatchSemaphore(value: 0)
        service.holdSet(with: gate)
        let app = model(service: service, fans: [fan(0), fan(1)]); await connect(app)
        let old = CoolingProfile(name: "Old", symbol: "fan", points: [.init(temperature: 40, rpm: 3000), .init(temperature: 80, rpm: 3000)])
        let newer = CoolingProfile(name: "New", symbol: "fan", points: [.init(temperature: 40, rpm: 4500), .init(temperature: 80, rpm: 4500)])
        let oldTask = Task { await app.applyProfile(old) }
        await waitUntil { service.calls.contains { $0.operation == .set && $0.fanID == 0 } }
        service.stopHoldingSets()
        let newTask = Task { await app.applyProfile(newer) }
        // Wait until the second profile has replaced fan zero's local intent, before
        // allowing the older hardware completion to return from the serial queue.
        await waitUntil { app.fanActions[0]?.requestedRPM == 4500 }
        gate.signal()
        let oldApplied = await oldTask.value, newApplied = await newTask.value
        XCTAssertFalse(oldApplied); XCTAssertTrue(newApplied)
        let secondFanWrites = service.calls.filter { $0.operation == .set && $0.fanID == 1 }
        XCTAssertEqual(secondFanWrites.count, 1)
        XCTAssertEqual(secondFanWrites.first?.rpm, 4500)
        XCTAssertEqual(app.activeCount, 2)
        XCTAssertNil(app.message, "An obsolete profile must not publish a partial-apply warning")
    }

    @MainActor func testQuitBlocksNewSamplingAndPowerAutomationWhileReleaseIsPending() async {
        var onBattery = snapshot(fans: [fan()]); onBattery.isOnACPower = false
        let hardware = FakeHardware(onBattery), service = FakeService(), gate = DispatchSemaphore(value: 0)
        let app = AppModel(monitor: hardware, helperClient: service,
                           preferences: UserDefaults(suiteName: "MacControlProQuitTests.\(UUID().uuidString)")!,
                           startsAutomatically: false, persistsPreferences: false, demoMode: false)
        app.autoProfileOnAC = true
        await connect(app)
        let applied = await app.setFixed(fan(), rpm: 3000); XCTAssertTrue(applied)
        let statusesBeforeQuit = service.calls.filter { $0.operation == .status }.count
        service.holdRelease(with: gate)
        let quitting = Task { await app.finishControlSession() }
        await waitUntil { service.calls.contains { $0.operation == .release } }
        XCTAssertTrue(app.paused)
        XCTAssertTrue(app.policies.isEmpty)
        var connectedPower = onBattery; connectedPower.isOnACPower = true
        hardware.replace(connectedPower)
        app.refresh()
        let acceptedDuringQuit = await app.setFixed(fan(), rpm: 4000)
        XCTAssertFalse(acceptedDuringQuit)
        gate.signal()
        await quitting.value
        await Task.yield()
        XCTAssertEqual(service.calls.filter { $0.operation == .status }.count, statusesBeforeQuit)
        XCTAssertEqual(service.calls.filter { $0.operation == .set }.count, 1)
        XCTAssertTrue(app.policies.isEmpty)
    }

    @MainActor func testPercentageProfileResolvesIndependentlyForDifferentFans() async {
        let desktop = fan(0, minimum: 700, maximum: 3000)
        let notebook = fan(1, minimum: 2000, maximum: 8250)
        let service = FakeService(); let app = model(service: service, fans: [desktop, notebook]); await connect(app)
        let applied = await app.applyProfile(CoolingProfile.builtIns[0])
        XCTAssertTrue(applied)
        let writes = service.calls.filter { $0.operation == .set }
        XCTAssertEqual(writes.count, 2)
        XCTAssertEqual(writes.first { $0.fanID == 0 }?.rpm, 1965)
        XCTAssertEqual(writes.first { $0.fanID == 1 }?.rpm, 5437.5)
        XCTAssertEqual(app.activeCount, 2)
    }

    @MainActor func testSchemaOneAbsoluteProfileKeepsItsMeaning() async throws {
        let json = Data(#"{"schemaVersion":1,"profiles":[{"id":"D19C9C92-AB86-4DBB-B8D7-D962DD818AB2","name":"Legacy","symbol":"fan","points":[{"temperature":45,"rpm":2500},{"temperature":65,"rpm":4000}]}]}"#.utf8)
        let archive = try JSONDecoder().decode(ProfileArchive.self, from: json)
        let profile = try XCTUnwrap(archive.profiles.first)
        XCTAssertNil(profile.usesPercent)
        XCTAssertEqual(profile.resolvedPoints(for: fan())?.last?.rpm, 4000)
        let service = FakeService(); let app = model(service: service); await connect(app)
        let applied = await app.applyProfile(profile)
        XCTAssertTrue(applied)
        XCTAssertEqual(service.calls.first { $0.operation == .set }?.rpm, 4000)
    }

    @MainActor func testIncompleteBoundsAndInvalidRPMCauseNoWrite() async {
        let incomplete = fan(0, minimum: nil, maximum: 8250)
        let service = FakeService(); let app = model(service: service, fans: [incomplete]); await connect(app)
        let incompleteResult = await app.setFixed(incomplete, rpm: 3000)
        XCTAssertFalse(incompleteResult)
        for rpm in [Double.nan, -1, 0, 9000] {
            let rejected = await app.setFixed(fan(), rpm: rpm)
            XCTAssertFalse(rejected)
        }
        XCTAssertFalse(service.calls.contains { $0.operation == .set || $0.operation == .renew })
        XCTAssertTrue(app.policies.isEmpty)
    }

    @MainActor func testMissingCurveSourceAndInvalidCurveCauseNoWrite() async {
        let service = FakeService(); let app = model(service: service); await connect(app)
        let missing = await app.setCurve(fan(), points: [.init(temperature: 45, rpm: 3000), .init(temperature: 65, rpm: 4000)], sensorID: "NONE")
        let invalid = await app.setCurve(fan(), points: [.init(temperature: 65, rpm: 3000), .init(temperature: 45, rpm: 4000)], sensorID: "TCMb")
        XCTAssertFalse(missing); XCTAssertFalse(invalid)
        XCTAssertFalse(service.calls.contains { $0.operation == .set })
    }

    @MainActor func testUnconfirmedOKResponseIsRejectedAndReleased() async {
        let service = FakeService()
        service.configureSet([.init(ok: true, message: "No application state", manualFanIDs: [0], protocolVersion: FanControlProtocol.currentVersion)])
        let app = model(service: service); await connect(app)
        let applied = await app.setFixed(fan(), rpm: 3000)
        XCTAssertFalse(applied); XCTAssertTrue(app.policies.isEmpty)
        XCTAssertEqual(app.fanActions[0]?.phase, .failed)
        XCTAssertTrue(service.calls.contains { $0.operation == .release })
    }

    @MainActor func testThermalProtectionPreservesMonitoringAndBlocksWrites() async {
        let service = FakeService()
        service.configureStatus(.init(ok: true, message: "Thermal protection", protocolVersion: FanControlProtocol.currentVersion,
                                      smcAvailable: true, canControl: false, controlBlockReason: "Too hot", controlBlockCode: .temperatureLimit,
                                      temperatureLimitCelsius: 85, hottestTemperatureCelsius: 90))
        let app = model(service: service); await connect(app)
        XCTAssertTrue(app.helperAvailable)
        XCTAssertEqual(app.snapshot.fans.count, 1)
        XCTAssertNotNil(app.globalControlNotice)
        let applied = await app.setFixed(fan(), rpm: 3000)
        XCTAssertFalse(applied); XCTAssertFalse(service.calls.contains { $0.operation == .set })
    }

    @MainActor func testAutomaticRecoveryFailureIsVisibleAndNeverClaimsSuccess() async {
        let service = FakeService(); let app = model(service: service); await connect(app)
        let applied = await app.setFixed(fan(), rpm: 3000); XCTAssertTrue(applied)
        service.configureAutomatic(.init(ok: false, message: "Recovery failed", protocolVersion: FanControlProtocol.currentVersion, errorCode: .recoveryFailed))
        let restored = await app.restoreConfirmed(0)
        XCTAssertFalse(restored); XCTAssertTrue(app.policies.isEmpty)
        XCTAssertEqual(app.fanActions[0]?.phase, .failed)
        XCTAssertNotNil(app.message)
        XCTAssertTrue(service.calls.contains { $0.operation == .automatic && $0.fanID == 0 })
    }
}
