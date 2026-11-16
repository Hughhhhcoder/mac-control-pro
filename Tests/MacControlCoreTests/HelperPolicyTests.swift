import XCTest
import Darwin
@testable import MacControlCore

final class HelperPolicyTests: XCTestCase {
    func testRefusesMissingOrDangerousTemperatureFeedback() {
        for temperatures in [[], [Double.nan], [85], [42, 93], [-3], [Double.infinity]] as [[Double]] {
            XCTAssertThrowsError(try FanControlPolicy.validateSet(requestedRPM: 2000, minimumRPM: 1000, maximumRPM: 6000, temperatures: temperatures))
        }
        XCTAssertNoThrow(try FanControlPolicy.validateSet(requestedRPM: 2000, minimumRPM: 1000, maximumRPM: 6000, temperatures: [40, 70]))
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
}
