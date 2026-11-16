import XCTest
@testable import MacControlCore

final class FanCurveTests: XCTestCase {
    let curve = FanCurve(points: [.init(temperature: 40, rpm: 1200), .init(temperature: 60, rpm: 3000), .init(temperature: 80, rpm: 6000)])
    func testInterpolatesAndClampsToHardwareBounds() throws {
        try curve.validate()
        XCTAssertEqual(curve.rpm(at: 50, minRPM: 1800, maxRPM: 5000), 2100)
        XCTAssertEqual(curve.rpm(at: 20, minRPM: 1800, maxRPM: 5000), 1800)
        XCTAssertEqual(curve.rpm(at: 90, minRPM: 1800, maxRPM: 5000), 5000)
        XCTAssertEqual(curve.rpm(at: 60, minRPM: 1800, maxRPM: 5000), 3000)
    }
    func testDuplicateOrUnorderedTemperatureIsRejected() {
        XCTAssertThrowsError(try FanCurve(points: [.init(temperature: 50, rpm: 2000), .init(temperature: 50, rpm: 3000)]).validate())
        XCTAssertThrowsError(try FanCurve(points: [.init(temperature: 60, rpm: 2000), .init(temperature: 50, rpm: 3000)]).validate())
    }
    func testNonMonotonicSpeedAndNonFiniteAreRejected() {
        XCTAssertThrowsError(try FanCurve(points: [.init(temperature: 40, rpm: 3000), .init(temperature: 60, rpm: 2000)]).validate())
        XCTAssertThrowsError(try FanCurve(points: [.init(temperature: 40, rpm: 1000), .init(temperature: .nan, rpm: 3000)]).validate())
        XCTAssertThrowsError(try FanCurve(points: [.init(temperature: 40, rpm: .infinity), .init(temperature: 60, rpm: 3000)]).validate())
    }
    func testInvalidCurveOrSensorFailsToMaximum() {
        let invalid = FanCurve(points: [])
        XCTAssertEqual(invalid.rpm(at: 40, minRPM: 1200, maxRPM: 6000), 6000)
        XCTAssertEqual(curve.rpm(at: .nan, minRPM: 1200, maxRPM: 6000), 6000)
        XCTAssertEqual(curve.rpm(at: 50, minRPM: 6000, maxRPM: 1200), 1200)
    }
    func testOutOfRangePointsRejected() {
        XCTAssertThrowsError(try FanCurve(points: [.init(temperature: -1, rpm: 1200), .init(temperature: 80, rpm: 6000)]).validate())
        XCTAssertThrowsError(try FanCurve(points: [.init(temperature: 40, rpm: 1200), .init(temperature: 80, rpm: 20001)]).validate())
    }
    func testCodablePreservesCurve() throws {
        XCTAssertEqual(try JSONDecoder().decode(FanCurve.self, from: JSONEncoder().encode(curve)), curve)
    }
}

final class SMCValueTests: XCTestCase {
    func testIntegerDecodingIncludesLegitimateZeroModes() {
        XCTAssertEqual(SMCValue(type: "ui8 ", bytes: [0]).number, 0)
        XCTAssertEqual(SMCValue(type: "ui16", bytes: [0x12, 0x34]).number, 4660)
        XCTAssertEqual(SMCValue(type: "ui32", bytes: [0, 1, 0, 0]).number, 65536)
    }
    func testSignedTemperatureAndFanFixedPoint() {
        XCTAssertEqual(SMCValue(type: "sp78", bytes: [0x32, 0x80]).number, 50.5)
        XCTAssertEqual(SMCValue(type: "sp78", bytes: [0xff, 0x80]).number, -0.5)
        XCTAssertEqual(SMCValue(type: "fpe2", bytes: [0x25, 0x80]).number, 2400)
    }
    func testLittleEndianFloatAndMalformedValues() {
        let bits = Float(46.5).bitPattern
        let bytes = (0..<4).map { UInt8(truncatingIfNeeded: bits >> (8*$0)) }
        XCTAssertEqual(SMCValue(type: "flt ", bytes: bytes).number, 46.5)
        XCTAssertNil(SMCValue(type: "flt ", bytes: [0,0,0xc0,0x7f]).number)
        XCTAssertNil(SMCValue(type: "sp78", bytes: [1]).number)
        XCTAssertNil(SMCValue(type: "????", bytes: [1,2]).number)
    }
    func testDemoIsExplicitAndSnapshotRoundTrips() throws {
        let demo = HardwareMonitor.demoSnapshot()
        XCTAssertTrue(demo.smcStatus.contains("DEMO"))
        XCTAssertTrue(demo.temperatures.allSatisfy { $0.id.hasPrefix("DEMO-") })
        let decoded = try JSONDecoder().decode(SystemSnapshot.self, from: JSONEncoder().encode(demo))
        XCTAssertEqual(decoded.fans.count, demo.fans.count)
        XCTAssertEqual(decoded.memoryUsedBytes, demo.memoryUsedBytes)
    }
}
