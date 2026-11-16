import Darwin
import Foundation
import MacControlCore

private var caughtSignal: sig_atomic_t = 0
private func signalHandler(_ value: Int32) { caughtSignal = value }

private struct StatusReport: Encodable {
    let date: Date
    let helper: HelperResponse?
    let helperError: String?
    let snapshot: SystemSnapshot
}

/// JSONL records keep the independent readback alongside each helper response.
private struct ControlEvent: Encodable {
    let event: String
    var date = Date()
    var command: String?
    var fanID: Int?
    var sensorID: String?
    var sourceCelsius: Double?
    var requestedRPM: Double?
    var helper: HelperResponse?
    var snapshot: SystemSnapshot?
    var error: String?
}

private func emit<T: Encodable>(_ value: T, pretty: Bool = false) throws {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
    var data = try encoder.encode(value)
    data.append(10)
    try FileHandle.standardOutput.write(contentsOf: data)
}

private func reportError(_ message: String) {
    try? FileHandle.standardError.write(contentsOf: Data((message + "\n").utf8))
}

private func checked(_ response: HelperResponse) throws {
    guard response.ok else { throw CLIError.failed(response.message) }
}

private func waitUntil(_ time: TimeInterval) {
    while caughtSignal == 0, ProcessInfo.processInfo.systemUptime < time {
        // Short waits allow SIGINT/SIGTERM to enter cleanup promptly.
        usleep(100_000)
    }
}

private func runControl(_ arguments: CLIArguments, monitor: HardwareMonitor) throws {
    let client = HelperClient()
    let fanID = arguments.fanID!
    let baseline = monitor.snapshot()
    guard baseline.fans.contains(where: { $0.id == fanID }) else { throw CLIError.failed("Fan \(fanID) is not available.") }
    if let sensor = arguments.sensorID, !baseline.temperatures.contains(where: { $0.id == sensor }) {
        throw CLIError.failed("Temperature sensor \(sensor) is not available.")
    }
    try checked(client.status())
    var primaryError: Error?
    var restoreError: Error?
    do {
        // A rejected or partially failed set must also reach automatic recovery.
        defer {
            do {
                let reply = try client.automatic(fanID: fanID)
                try emit(ControlEvent(event: "restore", command: "auto", fanID: fanID, helper: reply, snapshot: monitor.snapshot()))
                try checked(reply)
            } catch {
                restoreError = error
                reportError("Automatic recovery failed: \(error.localizedDescription). The helper's lease watchdog remains active.")
            }
        }
        do {
            let started = ProcessInfo.processInfo.systemUptime
            let deadline = started + arguments.duration
            var nextSample = started
            var hasSuccessfulSet = false
            while caughtSignal == 0, ProcessInfo.processInfo.systemUptime < deadline {
                let before = monitor.snapshot()
                guard let fan = before.fans.first(where: { $0.id == fanID }) else { throw CLIError.failed("Fan disappeared during control.") }
                let source: Double?
                let requested: Double
                if let curve = arguments.curve, let sensor = arguments.sensorID {
                    guard let reading = before.temperatures.first(where: { $0.id == sensor }) else { throw CLIError.failed("Curve source disappeared during control.") }
                    source = reading.celsius
                    requested = curve.rpm(at: reading.celsius, minRPM: max(1200, fan.minRPM), maxRPM: fan.maxRPM)
                } else {
                    source = nil
                    requested = arguments.rpm!
                }
                if hasSuccessfulSet {
                    // A safety recovery is authoritative. Never silently reacquire an expired
                    // or revoked lease after temperatures drop between two sample ticks.
                    let status = try client.status()
                    try checked(status)
                    guard status.manualFanIDs.contains(fanID) else {
                        throw CLIError.failed("The helper ended this fan's control lease. Refusing to reapply the previous target; start a new command explicitly.")
                    }
                }
                // The helper independently samples temperatures and enforces its policy again.
                let reply = try client.set(fanID: fanID, rpm: requested)
                try emit(ControlEvent(event: "sample", command: arguments.command.rawValue, fanID: fanID,
                                      sensorID: arguments.sensorID, sourceCelsius: source, requestedRPM: requested,
                                      helper: reply, snapshot: monitor.snapshot()))
                try checked(reply)
                hasSuccessfulSet = true
                nextSample += 2
                // Do not send a burst of missed renewals after a slow I/O operation.
                nextSample = max(nextSample, ProcessInfo.processInfo.systemUptime + 0.05)
                waitUntil(min(nextSample, deadline))
            }
        } catch {
            primaryError = error
            try? emit(ControlEvent(event: "error", command: arguments.command.rawValue, fanID: fanID, error: error.localizedDescription))
        }
    }
    if let restoreError { throw restoreError }
    if let primaryError { throw primaryError }
}

private func selfTest() throws {
    let fixed = try CLIArguments.parse(["set", "--fan", "0", "--rpm", "3000"])
    guard fixed.fanID == 0, fixed.rpm == 3000, fixed.duration == 20 else { throw CLIError.failed("Fixed parsing self-test failed.") }
    let curve = try CLIArguments.parse(["curve", "--fan0", "--sensor=TCMb", "--points", "45:3000,65:4000,80:6000", "--duration60"])
    guard curve.duration == 60, curve.curve?.rpm(at: 55, minRPM: 2000, maxRPM: 8250) == 3500 else { throw CLIError.failed("Curve parsing/interpolation self-test failed.") }
    for invalid in [
        ["set"], ["set", "--fan", "-1", "--rpm", "3000"],
        ["set", "--fan", "0", "--rpm", "nan"], ["set", "--fan", "0", "--rpm", "3000", "--duration", "61"],
        ["set", "--fan", "0", "--rpm", "3000", "--duration", "0"],
        ["curve", "--fan", "0", "--sensor", "TCMb", "--points", "65:3000,45:4000"],
        ["read", "--rpm", "3000"], ["auto", "--fan", "0", "--fan", "1"], ["status", "--unknown", "1"]
    ] {
        do { _ = try CLIArguments.parse(invalid) } catch { continue }
        throw CLIError.failed("Self-test accepted an invalid command: \(invalid)")
    }
    print("CLI parser, duration bounds and curve self-test passed. No hardware was accessed or changed.")
}

private let usage = """
MacControlCLI — Mac Control Pro local hardware diagnostics and bounded fan tests

Usage:
  MacControlCLI read
  MacControlCLI status
  MacControlCLI auto [--fan 0]
  MacControlCLI set --fan 0 --rpm 3000 [--duration 20]
  MacControlCLI curve --fan 0 --sensor TCMb --points '45:3000,65:4000,80:6000' [--duration 20]
  MacControlCLI --self-test
  MacControlCLI --help

read: actual snapshot JSON, without the helper. status: helper status + snapshot JSON.
set/curve: JSONL every 2s, default 20s, duration must be >0 and <=60s.
Curve points are Celsius:RPM, 2–12 ascending temperature points, nondecreasing RPM.
Each sample includes the requested RPM, helper response and independent hardware snapshot.
Normal completion, errors, SIGINT and SIGTERM all attempt per-fan automatic recovery.
No command disables temperature guards. set/curve require the installed helper; run this
CLI as your normal user. Omitted command only prints help and never writes hardware.
Exit codes: 0 success, 1 operational/recovery error, 2 helper unavailable (status),
64 invalid usage, 130 SIGINT or 143 SIGTERM after recovery. SIGKILL cannot run cleanup;
the helper's lease watchdog is the fallback.
"""

@main
private enum MacControlCLI {
    static func main() {
        signal(SIGPIPE, SIG_IGN)
        signal(SIGINT, signalHandler)
        signal(SIGTERM, signalHandler)
        do {
            let arguments = try CLIArguments.parse(Array(CommandLine.arguments.dropFirst()))
            switch arguments.command {
            case .help: print(usage)
            case .selfTest: try selfTest()
            case .read: try emit(HardwareMonitor().snapshot(), pretty: true)
            case .status:
                var helper: HelperResponse?
                var helperError: String?
                do { helper = try HelperClient().status() } catch { helperError = error.localizedDescription }
                try emit(StatusReport(date: Date(), helper: helper, helperError: helperError, snapshot: HardwareMonitor().snapshot()), pretty: true)
                if helper?.ok != true { exit(2) }
            case .auto:
                let reply = try HelperClient().automatic(fanID: arguments.fanID)
                try emit(ControlEvent(event: "restore", command: "auto", fanID: arguments.fanID, helper: reply, snapshot: HardwareMonitor().snapshot()))
                try checked(reply)
            case .set, .curve: try runControl(arguments, monitor: HardwareMonitor())
            }
            if caughtSignal != 0 { exit(128 + caughtSignal) }
        } catch CLIError.usage(let message) {
            reportError(message + "\nRun MacControlCLI --help for usage.")
            exit(64)
        } catch {
            reportError(error.localizedDescription)
            exit(1)
        }
    }
}
