import XCTest
@testable import MacControlCLI

/// These tests exercise the public command surface without creating a monitor or helper client.
final class ArgumentsTests: XCTestCase {
    func testOmittedCommandOnlyShowsHelp() throws {
        let arguments = try CLIArguments.parse([])
        XCTAssertEqual(arguments.command, .help)
        XCTAssertNil(arguments.fanID)
        XCTAssertNil(arguments.rpm)
        XCTAssertNil(arguments.curve)
        for command in ["read", "status", "--help", "-h", "help", "--self-test"] {
            let parsed = try CLIArguments.parse([command])
            XCTAssertFalse([.set, .curve, .auto].contains(parsed.command))
        }
    }

    func testCanonicalFixedCommandAndDefaults() throws {
        let arguments = try CLIArguments.parse(["set", "--fan", "0", "--rpm", "3000"])
        XCTAssertEqual(arguments.command, .set)
        XCTAssertEqual(arguments.fanID, 0)
        XCTAssertEqual(arguments.rpm, 3000)
        XCTAssertEqual(arguments.duration, 20)
        XCTAssertNil(arguments.sensorID)
        XCTAssertNil(arguments.curve)
    }

    func testCanonicalCurveKeepsSourceAndInterpolates() throws {
        let arguments = try CLIArguments.parse(["curve", "--fan", "0", "--sensor", "TCMb", "--points", "45:3000,65:4000,80:6000", "--duration", "60"])
        XCTAssertEqual(arguments.command, .curve)
        XCTAssertEqual(arguments.sensorID, "TCMb")
        XCTAssertEqual(arguments.duration, 60)
        let curve = try XCTUnwrap(arguments.curve)
        XCTAssertEqual(curve.points.count, 3)
        XCTAssertEqual(curve.rpm(at: 55, minRPM: 2000, maxRPM: 8250), 3500)
        XCTAssertEqual(curve.rpm(at: 100, minRPM: 2000, maxRPM: 5500), 5500)
    }

    func testSupportedOptionSpellingsAgree() throws {
        let canonical = try CLIArguments.parse(["set", "--fan", "2", "--rpm", "4000", "--duration", "10"])
        for tokens in [
            ["set", "--fan=2", "--rpm=4000", "--duration=10"],
            ["set", "--fan2", "--rpm4000", "--duration10"]
        ] {
            let arguments = try CLIArguments.parse(tokens)
            XCTAssertEqual(arguments.fanID, canonical.fanID)
            XCTAssertEqual(arguments.rpm, canonical.rpm)
            XCTAssertEqual(arguments.duration, canonical.duration)
        }
    }

    func testDurationRejectsNonfiniteAndOutOfRangeValues() {
        for duration in ["nan", "NaN", "inf", "-inf", "infinity", "1e309", "0", "-1", "60.00001", "61"] {
            XCTAssertThrowsError(try CLIArguments.parse(["set", "--fan", "0", "--rpm", "3000", "--duration", duration]), "Accepted duration \(duration)")
        }
    }

    func testDurationAllowsPositiveBoundaryValues() throws {
        for duration in ["0.1", "20", "60"] {
            let arguments = try CLIArguments.parse(["set", "--fan", "0", "--rpm", "3000", "--duration", duration])
            XCTAssertEqual(arguments.duration, Double(duration))
        }
    }

    func testMalformedAndUnsafeCurvesAreRejectedBeforeHardware() {
        let malformed = [
            "", "45:3000", "45:3000,", ",45:3000", "45:3000,,65:4000",
            "45,65:4000", "45:3000:1,65:4000", "forty:3000,65:4000",
            "45:3000;touch /tmp/cli-should-never-execute,65:4000",
            "45:$(id),65:4000", "nan:3000,65:4000", "45:inf,65:4000",
            "65:3000,45:4000", "45:3000,45:4000", "45:4000,65:3000",
            "-1:3000,65:4000", "45:3000,121:4000", "45:-1,65:4000", "45:3000,65:20001"
        ]
        for points in malformed {
            XCTAssertThrowsError(try CLIArguments.parse(["curve", "--fan", "0", "--sensor", "TCMb", "--points", points]), "Accepted curve \(points)")
        }
    }

    func testCurvePointCountIsBounded() throws {
        let twelve = (0..<12).map { "\($0 * 5):\(2000 + $0 * 100)" }.joined(separator: ",")
        let arguments = try CLIArguments.parse(["curve", "--fan", "0", "--sensor", "TCMb", "--points", twelve])
        XCTAssertEqual(arguments.curve?.points.count, 12)
        let thirteen = twelve + ",60:3200"
        XCTAssertThrowsError(try CLIArguments.parse(["curve", "--fan", "0", "--sensor", "TCMb", "--points", thirteen]))
    }

    func testFanRPMAndRequiredSourceValidation() {
        let invalid = [
            ["set"], ["set", "--fan", "0"], ["set", "--rpm", "3000"],
            ["set", "--fan", "-1", "--rpm", "3000"], ["set", "--fan", "16", "--rpm", "3000"],
            ["set", "--fan", "0", "--rpm", "nan"], ["set", "--fan", "0", "--rpm", "0"],
            ["set", "--fan", "0", "--rpm", "30001"],
            ["curve", "--fan", "0", "--points", "45:3000,65:4000"],
            ["curve", "--fan", "0", "--sensor", "TCM", "--points", "45:3000,65:4000"],
            ["curve", "--fan", "0", "--sensor", "TCMbb", "--points", "45:3000,65:4000"],
            ["curve", "--fan", "0", "--sensor", "温度", "--points", "45:3000,65:4000"]
        ]
        for tokens in invalid { XCTAssertThrowsError(try CLIArguments.parse(tokens), "Accepted \(tokens)") }
    }

    func testUnknownRepeatedAndCommandSpecificFlagsFailClosed() {
        let invalid = [
            ["launch"], ["read", "--rpm", "3000"], ["status", "--fan", "0"],
            ["auto", "--rpm", "3000"], ["auto", "--fan", "0", "--fan", "1"],
            ["set", "--fan", "0", "--rpm", "3000", "--force", "true"],
            ["set", "--fan", "0", "--rpm"], ["set", "--fan=", "--rpm=3000"],
            ["--help", "set"], ["--self-test", "--fan", "0"], ["read", "anything"]
        ]
        for tokens in invalid { XCTAssertThrowsError(try CLIArguments.parse(tokens), "Accepted \(tokens)") }
    }

    func testAutomaticCanSelectOneFanOrAllFans() throws {
        XCTAssertNil(try CLIArguments.parse(["auto"]).fanID)
        XCTAssertEqual(try CLIArguments.parse(["auto", "--fan", "0"]).fanID, 0)
    }
}
