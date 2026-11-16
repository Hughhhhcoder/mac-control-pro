import Foundation
import Darwin
import IOKit.ps

/// Real readings only. AppleSMC access can be unavailable; consumers must display that state.
// Snapshot access is serialized by the internal lock.
public final class HardwareMonitor: @unchecked Sendable {
    private let smc: SMCConnection?
    private let smcError: String?
    private var previousTicks: [UInt64]?
    private let lock = NSLock()
    private let hostPort = mach_host_self()
    private let model = HardwareMonitor.sysctlString("hw.model")
    private let chip = HardwareMonitor.sysctlString("machdep.cpu.brand_string")

    public init() {
        do { smc = try SMCConnection(); smcError = nil }
        catch { smc = nil; smcError = error.localizedDescription }
    }
    deinit { mach_port_deallocate(mach_task_self_, hostPort) }
    public func snapshot() -> SystemSnapshot {
        lock.lock(); defer { lock.unlock() }
        let fans = smc?.fans() ?? []
        let temperatures = smc?.temperatures() ?? []
        let power = battery()
        let status: String
        if let error = smcError { status = error }
        else if fans.isEmpty && temperatures.isEmpty { status = "AppleSMC connected; no supported temperature or fan readings exposed by this model." }
        else { status = "AppleSMC connected · \(temperatures.count) temperature sensors · \(fans.count) fans" }
        return SystemSnapshot(date: Date(), cpuUsage: cpu(), memoryUsedBytes: usedMemory(), memoryTotalBytes: ProcessInfo.processInfo.physicalMemory,
                              batteryPercent: power.percent, isOnACPower: power.ac, thermalState: thermal(), uptime: ProcessInfo.processInfo.systemUptime,
                              fans: fans, temperatures: temperatures, hardwareModel: model, chipName: chip.isEmpty ? "Unknown processor" : chip, smcStatus: status)
    }
    private func cpu() -> Double? {
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        var info = host_cpu_load_info_data_t()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(hostPort, HOST_CPU_LOAD_INFO, $0, &count) }
        }
        guard result == KERN_SUCCESS else { return nil }
        let ticks = [UInt64(info.cpu_ticks.0), UInt64(info.cpu_ticks.1), UInt64(info.cpu_ticks.2), UInt64(info.cpu_ticks.3)]
        defer { previousTicks = ticks }
        guard let before = previousTicks else { return nil }
        // The kernel's 32-bit counters wrap naturally; calculate the modular delta.
        let delta = zip(ticks, before).map { UInt64(UInt32(truncatingIfNeeded: $0) &- UInt32(truncatingIfNeeded: $1)) }
        let total = delta.reduce(0, +)
        guard total > 0 else { return nil }
        return min(100, max(0, 100 * Double(total-delta[2])/Double(total)))
    }
    private func usedMemory() -> UInt64 {
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        var stats = vm_statistics64_data_t()
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(hostPort, HOST_VM_INFO64, $0, &count) }
        }
        guard result == KERN_SUCCESS else { return 0 }
        // Active + wired + compressed is an explicit estimate, not Activity Monitor's pressure metric.
        let pages = UInt64(stats.active_count) + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)
        return min(ProcessInfo.processInfo.physicalMemory, pages * UInt64(vm_kernel_page_size))
    }
    private func battery() -> (percent: Double?, ac: Bool?) {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return (nil, nil) }
        var ac: Bool?
        if let source = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String? { ac = source == kIOPSACPowerValue }
        for source in list {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  let current = description[kIOPSCurrentCapacityKey] as? NSNumber,
                  let capacity = description[kIOPSMaxCapacityKey] as? NSNumber, capacity.doubleValue > 0 else { continue }
            let percent = min(100, max(0, current.doubleValue/capacity.doubleValue*100))
            return (percent, ac)
        }
        return (nil, ac)
    }
    private func thermal() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "Nominal"
        case .fair: return "Fair"
        case .serious: return "Serious"
        case .critical: return "Critical"
        @unknown default: return "Unknown"
        }
    }
    private static func sysctlString(_ name: String) -> String {
        var length = 0
        guard sysctlbyname(name, nil, &length, nil, 0) == 0, length > 0 else { return "" }
        var bytes = [CChar](repeating: 0, count: length)
        guard sysctlbyname(name, &bytes, &length, nil, 0) == 0 else { return "" }
        return String(cString: bytes)
    }
    public static func demoSnapshot() -> SystemSnapshot {
        let time = Date().timeIntervalSince1970
        let variation = sin(time/10)
        return SystemSnapshot(date: Date(), cpuUsage: 28+8*variation, memoryUsedBytes: 11_800_000_000, memoryTotalBytes: 32_000_000_000,
            batteryPercent: 86, isOnACPower: true, thermalState: "Nominal", uptime: 24_300,
            fans: [FanReading(id: 0, name: "Left fan", currentRPM: 2300+150*variation, minRPM: 1200, maxRPM: 6000), FanReading(id: 1, name: "Right fan", currentRPM: 2200+120*variation, minRPM: 1200, maxRPM: 6000)],
            temperatures: [TemperatureReading(id: "DEMO-CPU", name: "CPU die", celsius: 49+3*variation, category: "CPU"), TemperatureReading(id: "DEMO-GPU", name: "GPU die", celsius: 43+2*variation, category: "GPU"), TemperatureReading(id: "DEMO-BAT", name: "Battery", celsius: 31+variation, category: "Battery"), TemperatureReading(id: "DEMO-SSD", name: "SSD", celsius: 36+variation, category: "System")],
            hardwareModel: "Demo Mac", chipName: "Demo · Apple Silicon", smcStatus: "DEMO DATA · no hardware writes")
    }
}
