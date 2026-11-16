import AppKit
import Combine
import MacControlCore
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

struct HistorySample: Identifiable {
    let id = UUID()
    let date: Date
    let cpu: Double?
    let temperature: Double?
    let rpm: Double?
}

struct CoolingProfile: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var symbol: String
    var points: [FanCurvePoint]
    static let builtIns: [CoolingProfile] = [
        .init(name: "均衡", symbol: "scale.3d", points: [.init(temperature: 35, rpm: 1500), .init(temperature: 50, rpm: 2200), .init(temperature: 65, rpm: 3500), .init(temperature: 80, rpm: 5500)]),
        .init(name: "提前散热", symbol: "snowflake", points: [.init(temperature: 35, rpm: 2000), .init(temperature: 45, rpm: 3000), .init(temperature: 60, rpm: 4500), .init(temperature: 78, rpm: 6000)]),
        .init(name: "持续负载", symbol: "bolt.fill", points: [.init(temperature: 35, rpm: 2500), .init(temperature: 45, rpm: 3500), .init(temperature: 60, rpm: 5000), .init(temperature: 75, rpm: 6500)])
    ]
}

struct ProfileArchive: Codable { var schemaVersion: Int = 1; var profiles: [CoolingProfile] }
struct FanPolicy { var rpm: Double?; var points: [FanCurvePoint]?; var sensorID: String? }

@MainActor final class AppModel: ObservableObject {
    @Published var snapshot: SystemSnapshot
    @Published var history: [HistorySample] = []
    @Published var profiles: [CoolingProfile] = []
    @Published var policies: [Int: FanPolicy] = [:]
    @Published var helperAvailable = false
    @Published var helperMessage = ""
    @Published var message: String?
    @Published var paused = false
    @Published var lastExport: URL?
    @Published var demo: Bool
    @Published var language: String { didSet { UserDefaults.standard.set(language, forKey: "language") } }
    @Published var fahrenheit: Bool { didSet { UserDefaults.standard.set(fahrenheit, forKey: "fahrenheit") } }
    @Published var interval: Double { didSet { UserDefaults.standard.set(interval, forKey: "interval"); startTimer() } }
    @Published var autoProfileOnAC: Bool { didSet { UserDefaults.standard.set(autoProfileOnAC, forKey: "autoProfileOnAC") } }
    @Published var loginEnabled: Bool = SMAppService.mainApp.status == .enabled
    private let monitor: HardwareMonitor
    private let queue = DispatchQueue(label: "io.github.hughhhhcoder.monitor", qos: .utility)
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var sampling = false
    private var tickCount = 0
    private var previousAC: Bool?
    private var suspended = false
    private var controlGeneration = 0
    private var fanGenerations: [Int: Int] = [:]
    private var monitoringGeneration = 0
    var english: Bool { language == "en" }
    func text(_ zh: String, _ en: String) -> String { english ? en : zh }
    var peakTemperature: Double? { snapshot.temperatures.map(\.celsius).max() }
    var meanRPM: Double? { snapshot.fans.isEmpty ? nil : snapshot.fans.map(\.currentRPM).reduce(0,+) / Double(snapshot.fans.count) }
    var activeCount: Int { policies.count }
    var hottestSensor: TemperatureReading? { snapshot.temperatures.max(by: { $0.celsius < $1.celsius }) }
    var memoryFraction: Double { snapshot.memoryTotalBytes == 0 ? 0 : Double(snapshot.memoryUsedBytes) / Double(snapshot.memoryTotalBytes) }
    var allProfiles: [CoolingProfile] { CoolingProfile.builtIns + profiles }

    init() {
        let useDemo = ProcessInfo.processInfo.arguments.contains("--demo")
        demo = useDemo
        let hardware = HardwareMonitor()
        monitor = hardware
        snapshot = useDemo ? HardwareMonitor.demoSnapshot() : hardware.snapshot()
        language = UserDefaults.standard.string(forKey: "language") ?? "zh"
        fahrenheit = UserDefaults.standard.bool(forKey: "fahrenheit")
        let savedInterval = UserDefaults.standard.double(forKey: "interval")
        interval = (1...5).contains(savedInterval) ? savedInterval : 2
        autoProfileOnAC = UserDefaults.standard.bool(forKey: "autoProfileOnAC")
        if let data = UserDefaults.standard.data(forKey: "profiles"), let archive = try? JSONDecoder().decode(ProfileArchive.self, from: data) { profiles = archive.profiles }
        record(snapshot)
        startTimer()
        refresh()
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.monitoringGeneration += 1; self?.suspended = true; self?.restoreAll() } })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.suspended = false; self?.refresh() } })
    }

    func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in Task { @MainActor in self?.refresh() } }
    }
    func refresh() {
        guard !sampling, !suspended else { return }
        // Pausing monitoring always relinquishes manual control so no heartbeat can be stale.
        guard !paused else { return }
        sampling = true
        let isDemo = demo
        let generation = monitoringGeneration
        let monitor = monitor
        queue.async { [weak self] in
            let current = isDemo ? HardwareMonitor.demoSnapshot() : monitor.snapshot()
            let helper = isDemo ? nil : try? HelperClient().status()
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.sampling = false
                guard self.monitoringGeneration == generation, self.demo == isDemo, !self.paused, !self.suspended else { return }
                self.snapshot = current
                self.helperAvailable = helper?.ok == true
                self.helperMessage = helper?.message ?? self.text("辅助服务未安装，监控可正常使用", "Helper is not installed. Monitoring is available.")
                self.record(current)
                if !self.policies.isEmpty, self.helperAvailable {
                    let owned = Set(helper?.manualFanIDs ?? [])
                    // Helper is authoritative: after a safety recovery do not silently take control again.
                    self.policies = self.policies.filter { owned.contains($0.key) }
                }
                self.renewPolicies()
                if self.autoProfileOnAC, let old = self.previousAC, let ac = current.isOnACPower, old != ac, self.helperAvailable, !self.demo {
                    if ac { self.applyProfile(CoolingProfile.builtIns[0]) } else { self.restoreAll() }
                }
                self.previousAC = current.isOnACPower
            }
        }
    }
    private func record(_ current: SystemSnapshot) {
        history.append(.init(date: current.date, cpu: current.cpuUsage, temperature: current.temperatures.map(\.celsius).max(), rpm: current.fans.isEmpty ? nil : current.fans.map(\.currentRPM).reduce(0,+) / Double(current.fans.count)))
        if history.count > 1800 { history.removeFirst(history.count - 1800) }
    }
    func temperature(_ celsius: Double?) -> String {
        guard let celsius else { return "—" }
        return String(format: "%.0f°%@", fahrenheit ? celsius * 1.8 + 32 : celsius, fahrenheit ? "F" : "C")
    }
    func temperatureValue(_ celsius: Double) -> Double { fahrenheit ? celsius * 1.8 + 32 : celsius }
    func profileName(_ profile: CoolingProfile) -> String {
        guard english else { return profile.name }
        return ["均衡":"Balanced", "提前散热":"Proactive cooling", "持续负载":"Sustained load"][profile.name] ?? profile.name
    }
    func setPaused(_ value: Bool) { monitoringGeneration += 1; if value { restoreAll() }; paused = value; if !value { refresh() } }
    func setDemo(_ value: Bool) {
        monitoringGeneration += 1
        let generation = monitoringGeneration
        restoreAll()
        let hardware = monitor
        queue.async { [weak self] in
            let replacement = value ? HardwareMonitor.demoSnapshot() : hardware.snapshot()
            Task { @MainActor [weak self] in
                guard let self, self.monitoringGeneration == generation else { return }
                self.demo = value
                self.snapshot = replacement
                self.history.removeAll()
                self.record(replacement)
                self.paused = false
                self.previousAC = replacement.isOnACPower
                self.helperAvailable = false
                self.refresh()
            }
        }
    }
    func setFixed(_ fan: FanReading, rpm: Double) {
        guard canControl else { return }
        fanGenerations[fan.id, default: 0] += 1
        policies.removeValue(forKey: fan.id)
        send(fanID: fan.id, policy: .init(rpm: rpm, points: nil, sensorID: nil))
    }
    var canControl: Bool {
        if paused || suspended { message = text("请先恢复实时采样。", "Resume live sampling before applying control."); return false }
        if demo { message = text("演示模式不控制硬件。", "Demo mode never controls hardware."); return false }
        if !helperAvailable { message = text("请先在设置中查看辅助服务安装说明。", "Install the optional helper from the Settings guide first."); return false }
        return true
    }
    func setCurve(_ fan: FanReading, points: [FanCurvePoint], sensorID: String?) {
        guard canControl else { return }
        do { try FanCurve(points: points).validate() } catch { message = error.localizedDescription; return }
        guard sensorID != nil, snapshot.temperatures.contains(where: { $0.id == sensorID }) else { message = text("请选择有效温度传感器。", "Choose an available temperature sensor."); return }
        fanGenerations[fan.id, default: 0] += 1
        policies.removeValue(forKey: fan.id)
        send(fanID: fan.id, policy: .init(rpm: nil, points: points, sensorID: sensorID))
    }
    func applyProfile(_ profile: CoolingProfile) {
        guard canControl else { return }
        guard let sensor = hottestSensor else { message = text("没有可用温度传感器，无法启用曲线。", "No temperature sensor is available for a curve."); return }
        for fan in snapshot.fans { setCurve(fan, points: profile.points, sensorID: sensor.id) }
    }
    private func desiredRPM(fanID: Int, policy: FanPolicy) -> Double? {
        guard let fan = snapshot.fans.first(where: { $0.id == fanID }) else { return nil }
        if let rpm = policy.rpm { return rpm }
        if let points = policy.points, let sensor = snapshot.temperatures.first(where: { $0.id == policy.sensorID }) {
            return FanCurve(points: points).rpm(at: sensor.celsius, minRPM: max(1200, fan.minRPM), maxRPM: fan.maxRPM)
        }
        return nil
    }
    private func send(fanID: Int, policy: FanPolicy) {
        guard let rpm = desiredRPM(fanID: fanID, policy: policy) else { return }
        let generation = controlGeneration
        let fanGeneration = fanGenerations[fanID, default: 0]
        queue.async { [weak self] in
            let result: Result<HelperResponse, Error> = Result { try HelperClient().set(fanID: fanID, rpm: rpm) }
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.controlGeneration == generation, self.fanGenerations[fanID, default: 0] == fanGeneration, !self.demo, !self.paused, !self.suspended else { return }
                switch result {
                case .success(let response):
                    if response.ok { self.policies[fanID] = policy } else { self.policies.removeValue(forKey: fanID); self.message = response.message }
                case .failure(let error): self.policies.removeValue(forKey: fanID); self.message = error.localizedDescription
                }
            }
        }
    }
    private func renewPolicies() {
        guard !demo, helperAvailable else { return }
        for (fanID, policy) in policies {
            if desiredRPM(fanID: fanID, policy: policy) == nil { restore(fanID) } else { send(fanID: fanID, policy: policy) }
        }
    }
    func restore(_ id: Int) {
        fanGenerations[id, default: 0] += 1
        policies.removeValue(forKey: id)
        guard !demo else { return }
        queue.async { [weak self] in
            do { let response = try HelperClient().automatic(fanID: id); if !response.ok { Task { @MainActor [weak self] in self?.message = response.message } } }
            catch { Task { @MainActor [weak self] in self?.message = error.localizedDescription } }
        }
    }
    func restoreAll() {
        controlGeneration += 1
        policies.removeAll()
        guard !demo, helperAvailable else { return }
        queue.async { [weak self] in
            do { let response = try HelperClient().automatic(); if !response.ok { Task { @MainActor [weak self] in self?.message = response.message } } }
            catch { Task { @MainActor [weak self] in self?.message = error.localizedDescription } }
        }
    }
    func shutdown() { restoreAll() }
    func saveProfile(name: String, points: [FanCurvePoint]) {
        do {
            try FanCurve(points: points).validate()
            guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            profiles.append(.init(name: String(name.prefix(80)), symbol: "slider.horizontal.3", points: points))
            persistProfiles()
        } catch { message = error.localizedDescription }
    }
    func deleteProfile(_ profile: CoolingProfile) { profiles.removeAll { $0.id == profile.id }; persistProfiles() }
    private func persistProfiles() { UserDefaults.standard.set(try? JSONEncoder().encode(ProfileArchive(profiles: profiles)), forKey: "profiles") }
    func importProfiles() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            guard data.count < 1_000_000 else { throw CocoaError(.fileReadTooLarge) }
            let archive = try JSONDecoder().decode(ProfileArchive.self, from: data)
            guard archive.schemaVersion == 1, archive.profiles.count <= 100 else { throw CocoaError(.fileReadCorruptFile) }
            for profile in archive.profiles { try FanCurve(points: profile.points).validate(); guard !profile.name.isEmpty, profile.name.count <= 80 else { throw CocoaError(.fileReadCorruptFile) } }
            profiles.append(contentsOf: archive.profiles.map { .init(name: $0.name, symbol: "slider.horizontal.3", points: $0.points) }); persistProfiles()
            message = text("配置已导入，尚未应用到硬件。", "Profiles imported. Hardware settings have not changed.")
        } catch { message = error.localizedDescription }
    }
    func exportProfiles() { do { try save(data: JSONEncoder().encode(ProfileArchive(profiles: allProfiles)), name: "MacControlPro-profiles.json", type: .json) } catch { message = error.localizedDescription } }
    func exportCSV() {
        let formatter = ISO8601DateFormatter()
        let lines = history.map { "\(formatter.string(from: $0.date)),\($0.cpu.map { String(format: "%.2f", $0) } ?? ""),\($0.temperature.map { String(format: "%.2f", $0) } ?? ""),\($0.rpm.map { String(format: "%.0f", $0) } ?? "")" }
        do { try save(data: Data((["timestamp,cpu_percent,max_temperature_celsius,mean_fan_rpm"] + lines).joined(separator: "\n").utf8), name: "MacControlPro-history.csv", type: .commaSeparatedText) } catch { message = error.localizedDescription }
    }
    func exportDiagnostics() {
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
            try save(data: encoder.encode(snapshot), name: "MacControlPro-diagnostics.json", type: .json)
        } catch { message = error.localizedDescription }
    }
    private func save(data: Data, name: String, type: UTType) throws {
        let panel = NSSavePanel(); panel.nameFieldStringValue = name; panel.allowedContentTypes = [type]
        guard panel.runModal() == .OK, let url = panel.url else { return }; try data.write(to: url, options: .atomic); lastExport = url
    }
    func setLogin(_ enabled: Bool) {
        do { if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }; loginEnabled = SMAppService.mainApp.status == .enabled }
        catch { message = error.localizedDescription; loginEnabled = SMAppService.mainApp.status == .enabled }
    }
    func openGuide() { NSWorkspace.shared.open(URL(string: "https://github.com/Hughhhhcoder/mac-control-pro/blob/main/docs/HELPER.md")!) }
}
