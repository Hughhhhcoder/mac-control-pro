import XCTest
@testable import MacControlCore

/// This transport is entirely in memory. These are protocol/state fixtures, never hardware tests.
private final class FanFixture: SMCTransport {
    var values: [String: SMCValue] = [:]
    var writes: [(String, [UInt8])] = []
    var reads: [String] = []
    var clock: TimeInterval = 100
    var keyQueries = 0
    var beforeWrite: ((String, [UInt8]) throws -> Void)?
    var readOverride: ((String) -> SMCValue?)?
    func read(_ key: String) throws -> SMCValue {
        reads.append(key)
        if let value = readOverride?(key) { return value }
        guard let value = values[key] else { throw SMCError.invalidKey(key) }
        return value
    }
    func write(_ key: String, bytes: [UInt8]) throws {
        writes.append((key, bytes))
        try beforeWrite?(key, bytes)
        guard let current = values[key] else { throw SMCError.invalidKey(key) }
        values[key] = SMCValue(type: current.type, bytes: bytes)
    }
    func key(at index: UInt32) throws -> String { keyQueries += 1; throw SMCError.invalidKey("index") }
    func connection(_ platform: SMCPlatform = .appleSilicon) -> SMCConnection {
        SMCConnection(transport: self, platform: platform, hasWritePrivilege: { true }, now: { self.clock }, sleep: { self.clock += $0 })
    }
    func fan(_ id: Int, minimum: Double = 2000, maximum: Double = 8250, actual: Double = 2500, modeSuffix: String = "md", mode: UInt8 = 0) {
        values[SMCConnection.fanKey(id, "Ac")] = Self.float(actual)
        values[SMCConnection.fanKey(id, "Mn")] = Self.float(minimum)
        values[SMCConnection.fanKey(id, "Mx")] = Self.float(maximum)
        values[SMCConnection.fanKey(id, "Tg")] = Self.float(actual)
        values[SMCConnection.fanKey(id, modeSuffix)] = Self.byte(mode)
    }
    static func float(_ value: Double) -> SMCValue {
        let bits = Float(value).bitPattern
        return SMCValue(type: "flt ", bytes: (0..<4).map { UInt8(truncatingIfNeeded: bits >> (8*$0)) })
    }
    static func byte(_ value: UInt8) -> SMCValue { SMCValue(type: "ui8 ", bytes: [value]) }
    static func word(_ value: UInt16) -> SMCValue { SMCValue(type: "ui16", bytes: [UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)]) }
}

final class FanDiscoveryTests: XCTestCase {
    func testTwoFansRemainIndependentAndKeepTheirNames() throws {
        let fixture = FanFixture(); fixture.values["FNum"] = FanFixture.byte(2)
        fixture.fan(0); fixture.fan(1, actual: 2700)
        fixture.values["F0ID"] = SMCValue(type: "{fds", bytes: [0,0,0,0] + Array("Left fan\0".utf8))
        fixture.values["F1ID"] = SMCValue(type: "ch8*", bytes: Array("Right fan\0".utf8))
        let inventory = fixture.connection().fanInventory()
        XCTAssertEqual(inventory.reportedFanCount, 2)
        XCTAssertEqual(inventory.fans.map(\.name), ["Left fan", "Right fan"])
        XCTAssertEqual(inventory.fans.map(\.currentRPM), [2500, 2700])
        XCTAssertTrue(inventory.fans.allSatisfy(\.canRequestControl))
    }
    func testMissingBoundsAndEntirelyUnreadableDeclaredFanAreNotDropped() {
        let fixture = FanFixture(); fixture.values["FNum"] = FanFixture.byte(2); fixture.fan(0)
        fixture.values.removeValue(forKey: "F0Mn")
        let fans = fixture.connection().fans()
        XCTAssertEqual(fans.map(\.id), [0, 1])
        XCTAssertNil(fans[0].minRPM)
        XCTAssertEqual(fans[0].currentRPM, 2500)
        XCTAssertFalse(fans[0].canRequestControl)
        XCTAssertNil(fans[1].currentRPM)
        XCTAssertNil(fans[1].maxRPM)
        XCTAssertFalse(fans[1].canRequestControl)
        XCTAssertNotNil(fans[1].controlIssue)
    }
    func testValidFanlessAndUnavailableCountRemainDifferent() {
        let fixture = FanFixture(); fixture.values["FNum"] = FanFixture.byte(0)
        let fanless = fixture.connection().fanInventory()
        XCTAssertEqual(fanless.reportedFanCount, 0); XCTAssertTrue(fanless.fans.isEmpty)
        fixture.values.removeValue(forKey: "FNum")
        let unavailable = fixture.connection().fanInventory()
        XCTAssertNil(unavailable.reportedFanCount); XCTAssertTrue(unavailable.fans.isEmpty)
        XCTAssertTrue(unavailable.message.contains("does not establish"))
    }
    func testCountAbsentInvalidOrUndercountedStillDiscoversReadableFanKeys() {
        for count in [nil, FanFixture.float(-1), FanFixture.float(.infinity), FanFixture.byte(1), FanFixture.byte(0)] as [SMCValue?] {
            let fixture = FanFixture(); fixture.values["FNum"] = count
            fixture.fan(0); fixture.fan(1)
            let inventory = fixture.connection().fanInventory()
            XCTAssertEqual(inventory.fans.map(\.id), [0, 1])
            if count?.number == 1 || count?.number == 0 { XCTAssertTrue(inventory.message.contains("indexed keys")) }
        }
    }
    func testProbeDoesNotStopAtGapAndKeepsFourByteKeys() {
        let fixture = FanFixture(); fixture.fan(3); fixture.fan(10)
        let fans = fixture.connection().fans()
        XCTAssertEqual(fans.map(\.id), [3, 10])
        XCTAssertEqual(fans[1].targetKey, "FATg")
        XCTAssertTrue(fixture.reads.allSatisfy { $0.utf8.count == 4 })
    }
    func testUnsupportedLowercaseModeFallsBackToUppercase() {
        let fixture = FanFixture(); fixture.fan(0, modeSuffix: "Md", mode: 3)
        fixture.values["F0md"] = SMCValue(type: "ui32", bytes: [0,0,0,0])
        let fan = fixture.connection().fans()[0]
        XCTAssertEqual(fan.modeKey, "F0Md"); XCTAssertEqual(fan.modeRawValue, 3)
        XCTAssertFalse(fan.isManual); XCTAssertTrue(fan.canRequestControl)
    }
    func testDesktopPositiveMinimumAndSmallMaximumAreUsable() throws {
        let fixture = FanFixture(); fixture.fan(0, minimum: 700, maximum: 1100, actual: 800)
        let connection = fixture.connection(); let fan = connection.fans()[0]
        XCTAssertEqual(fan.manualMinimumRPM, 700); XCTAssertTrue(fan.canRequestControl)
        try connection.setFan(id: 0, rpm: 900)
        XCTAssertEqual(fixture.values["F0Tg"]?.number, 900)
        let stopped = FanReading(id: 1, name: "Small fan", currentRPM: 0, minRPM: 0, maxRPM: 900, modeRawValue: 0, modeKey: "F1md", targetKey: "F1Tg")
        XCTAssertEqual(stopped.manualMinimumRPM, 900); XCTAssertTrue(stopped.canRequestControl)
    }
    func testImpossibleBoundsDoNotEraseFanOrPermitControl() {
        let fixture = FanFixture(); fixture.fan(0, minimum: 5000, maximum: 2000)
        let fan = fixture.connection().fans()[0]
        XCTAssertEqual(fan.minRPM, 5000); XCTAssertEqual(fan.maxRPM, 2000)
        XCTAssertFalse(fan.hasValidBounds); XCTAssertFalse(fan.canRequestControl)
    }
    func testLegacyFanJSONDecodesWithoutNewMetadata() throws {
        let json = Data(#"{"id":0,"name":"Fan 1","currentRPM":2500,"minRPM":2000,"maxRPM":8250,"targetRPM":2500,"isManual":false}"#.utf8)
        let fan = try JSONDecoder().decode(FanReading.self, from: json)
        XCTAssertEqual(fan.currentRPM, 2500); XCTAssertNil(fan.modeKey)
        XCTAssertFalse(fan.canRequestControl)
    }
    func testLargeSensorCountIsClampedBeforeIntegerConversion() {
        let fixture = FanFixture(); fixture.values["#KEY"] = FanFixture.float(1e30)
        XCTAssertTrue(fixture.connection().temperatures().isEmpty)
        XCTAssertEqual(fixture.keyQueries, 8192)
    }
}

final class FanModeTransitionTests: XCTestCase {
    func testUnsupportedIntelMaskFallsBackToReadablePerFanMode() throws {
        let fixture = FanFixture(); fixture.fan(0, modeSuffix: "Md")
        fixture.values["FS! "] = SMCValue(type: "ui32", bytes: [0,0,0,0])
        let connection = fixture.connection(.intel)
        XCTAssertEqual(connection.fans()[0].modeKey, "F0Md")
        try connection.setFan(id: 0, rpm: 3000)
        XCTAssertEqual(fixture.values["F0Md"]?.number, 1)
        try connection.restoreAutomatic(fanID: 0)
        XCTAssertEqual(fixture.values["F0Md"]?.number, 0)
    }
    func testIntelFourFanBitmaskPreservesOtherManualFans() throws {
        let fixture = FanFixture(); fixture.values["FNum"] = FanFixture.byte(4); fixture.values["FS! "] = FanFixture.word(0b1010)
        for id in 0..<4 { fixture.fan(id, minimum: 1000, maximum: 6000) }
        let connection = fixture.connection(.intel)
        XCTAssertEqual(connection.fans().map(\.isManual), [false, true, false, true])
        try connection.setFan(id: 2, rpm: 1800)
        XCTAssertEqual(fixture.values["FS! "]?.number, 0b1110)
        try connection.restoreAutomatic(fanID: 2)
        XCTAssertEqual(fixture.values["FS! "]?.number, 0b1010)
    }
    func testM4ProtectedModeUnlockDoesNotBlockRPCAndResumesAfterYield() throws {
        let fixture = FanFixture(); fixture.fan(0, modeSuffix: "Md", mode: 3); fixture.values["Ftst"] = FanFixture.byte(0)
        var unlockedAt: TimeInterval?
        fixture.beforeWrite = { key, bytes in
            if key == "Ftst", bytes == [1] { unlockedAt = fixture.clock }
            if key == "F0Md", bytes == [1], unlockedAt == nil || fixture.clock - unlockedAt! < 3 { throw SMCError.driver(Int32(bitPattern: 0xe0000082)) }
        }
        let connection = fixture.connection()
        if case .pending = try connection.setFan(id: 0, rpm: 3000) {} else { XCTFail("Expected pending unlock") }
        XCTAssertEqual(fixture.clock, 100)
        XCTAssertEqual(fixture.writes.first?.0, "F0Md")
        XCTAssertEqual(fixture.values["Ftst"]?.number, 1)
        XCTAssertEqual(fixture.values["F0Tg"]?.number, 2500)
        fixture.clock += 3.5
        if case .applied = try connection.setFan(id: 0, rpm: 3000) {} else { XCTFail("Expected confirmed manual target") }
        XCTAssertEqual(fixture.values["F0Tg"]?.number, 3000)
        try connection.restoreAutomatic(fanID: 0)
        XCTAssertEqual(fixture.values["F0Md"]?.number, 0); XCTAssertEqual(fixture.values["Ftst"]?.number, 0)
    }
    func testProtectedAutomaticModeZeroUsesBoundedUnlockAfterDirectFailure() throws {
        let fixture = FanFixture(); fixture.fan(0, modeSuffix: "Md", mode: 0); fixture.values["Ftst"] = FanFixture.byte(0)
        var unlockedAt: TimeInterval?
        fixture.beforeWrite = { key, bytes in
            if key == "Ftst", bytes == [1] { unlockedAt = fixture.clock }
            if key == "F0Md", bytes == [1], unlockedAt == nil || fixture.clock - unlockedAt! < 3 {
                throw SMCError.driver(Int32(bitPattern: 0xe0000082))
            }
        }
        let connection = fixture.connection()
        if case .pending = try connection.setFan(id: 0, rpm: 3000) {} else { XCTFail("Expected protected mode 0 to wait for unlock") }
        XCTAssertEqual(fixture.clock, 100)
        XCTAssertEqual(fixture.writes.first?.0, "F0Md")
        XCTAssertFalse(fixture.writes.contains { $0.0 == "F0Tg" })
        fixture.clock += 1
        if case .pending = try connection.setFan(id: 0, rpm: 3000) {} else { XCTFail("Expected the same pending unlock") }
        XCTAssertEqual(fixture.writes.filter { $0.0 == "Ftst" && $0.1 == [1] }.count, 1)
        fixture.clock += 2.5
        if case .applied = try connection.setFan(id: 0, rpm: 3000) {} else { XCTFail("Expected control after the thermal manager yields") }
        try connection.restoreAutomatic(fanID: 0)
        XCTAssertEqual(fixture.values["F0Md"]?.number, 0)
        XCTAssertEqual(fixture.values["Ftst"]?.number, 0)
    }
    func testUnknownModesNeverWriteOrEnterDiagnosticUnlock() throws {
        for unknown in [UInt8(2), UInt8(255)] {
            let fixture = FanFixture(); fixture.fan(0, modeSuffix: "Md", mode: unknown); fixture.values["Ftst"] = FanFixture.byte(0)
            let connection = fixture.connection()
            let fan = try XCTUnwrap(connection.fans().first)
            XCTAssertEqual(fan.modeRawValue, Int(unknown))
            XCTAssertFalse(fan.canRequestControl)
            XCTAssertNotNil(fan.controlIssue)
            XCTAssertThrowsError(try connection.setFan(id: 0, rpm: 3000))
            XCTAssertTrue(fixture.writes.isEmpty)
            XCTAssertEqual(fixture.values["Ftst"]?.number, 0)
        }
    }
    func testFPE2QuarterRPMEncodingAndOverflowRecovery() throws {
        let fixture = FanFixture(); fixture.fan(0, minimum: 700, maximum: 6000)
        fixture.values["F0Tg"] = SMCValue(type: "fpe2", bytes: [0x27, 0x10])
        let connection = fixture.connection(.intel)
        try connection.setFan(id: 0, rpm: 725.25)
        XCTAssertEqual(fixture.values["F0Tg"]?.bytes, [0x0b, 0x55])
        XCTAssertEqual(fixture.values["F0Tg"]?.number, 725.25)
        try connection.restoreAutomatic(fanID: 0)
        let overflow = FanFixture(); overflow.fan(0, minimum: 700, maximum: 20_000)
        overflow.values["F0Tg"] = SMCValue(type: "fpe2", bytes: [0x27, 0x10])
        XCTAssertThrowsError(try overflow.connection(.intel).setFan(id: 0, rpm: 18_000))
        XCTAssertFalse(overflow.writes.contains { $0.0 == "F0Tg" })
        XCTAssertEqual(overflow.values["F0md"]?.number, 0)
    }
    func testStoppedSmallFanUsesPositiveHardwareBoundWithoutImpossibleFloor() throws {
        let fixture = FanFixture(); fixture.fan(0, minimum: 0, maximum: 900, actual: 0)
        let connection = fixture.connection()
        XCTAssertEqual(connection.fans()[0].manualMinimumRPM, 900)
        XCTAssertThrowsError(try connection.setFan(id: 0, rpm: 500))
        XCTAssertTrue(fixture.writes.isEmpty)
        try connection.setFan(id: 0, rpm: 900)
        XCTAssertEqual(fixture.values["F0Tg"]?.number, 900)
        try connection.restoreAutomatic(fanID: 0)
        XCTAssertEqual(fixture.values["F0md"]?.number, 0)
    }
    func testProtectedModeTimeoutRestoresWithoutWritingTarget() throws {
        let fixture = FanFixture(); fixture.fan(0, modeSuffix: "Md", mode: 3); fixture.values["Ftst"] = FanFixture.byte(0)
        fixture.beforeWrite = { key, bytes in if key == "F0Md", bytes == [1] { throw SMCError.driver(-1) } }
        let connection = fixture.connection()
        _ = try connection.setFan(id: 0, rpm: 3000)
        fixture.clock += 8
        XCTAssertThrowsError(try connection.setFan(id: 0, rpm: 3000))
        XCTAssertEqual(fixture.values["F0Md"]?.number, 0); XCTAssertEqual(fixture.values["Ftst"]?.number, 0)
        XCTAssertFalse(fixture.writes.contains { $0.0 == "F0Tg" })
    }
    func testRestoringOnePendingFanKeepsOtherFanGlobalUnlock() throws {
        let fixture = FanFixture(); fixture.fan(0, modeSuffix: "Md", mode: 0); fixture.fan(1, modeSuffix: "Md", mode: 3)
        fixture.values["Ftst"] = FanFixture.byte(0)
        fixture.beforeWrite = { key, bytes in if ["F0Md", "F1Md"].contains(key), bytes == [1] { throw SMCError.driver(-1) } }
        let connection = fixture.connection()
        _ = try connection.setFan(id: 0, rpm: 3000); _ = try connection.setFan(id: 1, rpm: 3000)
        try connection.restoreAutomatic(fanID: 0)
        XCTAssertEqual(fixture.values["Ftst"]?.number, 1)
        try connection.restoreAutomatic(fanID: 1)
        XCTAssertEqual(fixture.values["Ftst"]?.number, 0)
    }
    func testDelayedTargetAcknowledgementAndPermanentRejection() throws {
        let fixture = FanFixture(); fixture.fan(0)
        var targetVisibleAt: TimeInterval = .infinity
        fixture.beforeWrite = { key, _ in if key == "F0Tg" { targetVisibleAt = fixture.clock + 0.2 } }
        fixture.readOverride = { key in key == "F0Tg" && fixture.clock < targetVisibleAt ? FanFixture.float(2500) : nil }
        try fixture.connection().setFan(id: 0, rpm: 3000)
        XCTAssertGreaterThanOrEqual(fixture.clock, 100.2)
        XCTAssertLessThan(fixture.clock, 100.8)
        let rejected = FanFixture(); rejected.fan(0)
        rejected.readOverride = { key in key == "F0Tg" ? FanFixture.float(2500) : nil }
        XCTAssertThrowsError(try rejected.connection().setFan(id: 0, rpm: 3000))
        XCTAssertLessThanOrEqual(rejected.clock, 100.800001)
        XCTAssertEqual(rejected.values["F0md"]?.number, 0)
    }
    func testConfirmedTargetDoesNotHideFirmwareReclaimingPerFanMode() throws {
        for reclaimedMode in [UInt8(0), UInt8(3)] {
            let fixture = FanFixture(); fixture.fan(0, modeSuffix: "Md")
            fixture.beforeWrite = { key, _ in
                if key == "F0Tg" { fixture.values["F0Md"] = FanFixture.byte(reclaimedMode) }
            }
            XCTAssertThrowsError(try fixture.connection().setFan(id: 0, rpm: 3000)) { error in
                guard case SMCError.verificationFailed("F0Md") = error else { return XCTFail("Expected a failed manual-mode confirmation, got \(error)") }
            }
            XCTAssertEqual(fixture.values["F0Tg"]?.number, 3000)
            XCTAssertEqual(fixture.values["F0Md"]?.number, 0)
            XCTAssertEqual(fixture.writes.filter { $0.0 == "F0Md" }.map(\.1), [[1], [0]])
        }
    }
    func testConfirmedTargetDoesNotHideFirmwareReclaimingIntelMask() throws {
        let fixture = FanFixture(); fixture.fan(0); fixture.fan(1)
        fixture.values["FNum"] = FanFixture.byte(2); fixture.values["FS! "] = FanFixture.word(0b10)
        fixture.beforeWrite = { key, _ in
            if key == "F0Tg" { fixture.values["FS! "] = FanFixture.word(0b10) }
        }
        XCTAssertThrowsError(try fixture.connection(.intel).setFan(id: 0, rpm: 3000)) { error in
            guard case SMCError.verificationFailed("FS! ") = error else { return XCTFail("Expected a failed bitmask confirmation, got \(error)") }
        }
        XCTAssertEqual(fixture.values["F0Tg"]?.number, 3000)
        XCTAssertEqual(fixture.values["FS! "]?.number, 0b10)
    }
    func testTargetMustRemainConfirmedInFinalFanSnapshot() throws {
        let fixture = FanFixture(); fixture.fan(0)
        var wroteTarget = false, targetReadCount = 0
        fixture.beforeWrite = { key, _ in if key == "F0Tg" { wroteTarget = true } }
        fixture.readOverride = { key in
            guard key == "F0Tg", wroteTarget else { return nil }
            targetReadCount += 1
            return FanFixture.float(targetReadCount == 1 ? 3000 : 2500)
        }
        XCTAssertThrowsError(try fixture.connection().setFan(id: 0, rpm: 3000)) { error in
            guard case SMCError.writeNotConfirmed(key: "F0Tg", requested: 3000, observed: 2500) = error else { return XCTFail("Expected the changed target to fail confirmation, got \(error)") }
        }
        XCTAssertEqual(fixture.values["F0md"]?.number, 0)
    }
    func testMissingBoundsStillAllowExplicitAutomaticRecovery() throws {
        let fixture = FanFixture(); fixture.values["F0md"] = FanFixture.byte(1)
        try fixture.connection().restoreAutomatic(fanID: 0)
        XCTAssertEqual(fixture.values["F0md"]?.number, 0)
    }
}
