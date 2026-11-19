import AppKit
import Combine
import MacControlCore
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

@MainActor final class AppModel: ObservableObject {
    @Published var snapshot: SystemSnapshot
    @Published var history: [HistorySample] = []
    @Published var profiles: [CoolingProfile] = []
    @Published var policies: [Int: FanPolicy] = [:]
    @Published var fanActions: [Int: FanAction] = [:]
    @Published var helperAvailable = false
    @Published var helperMessage = ""
    @Published var helperResponse: HelperResponse?
    @Published var serviceCondition: ServiceCondition = .checking
    @Published var message: String?
    @Published var paused = false
    @Published var lastExport: URL?
    @Published var demo: Bool
    @Published var language: String { didSet { persist(language, for: "language") } }
    @Published var fahrenheit: Bool { didSet { persist(fahrenheit, for: "fahrenheit") } }
    @Published var interval: Double { didSet { persist(interval, for: "interval"); if automaticallySamples { startTimer() } } }
    @Published var autoProfileOnAC: Bool { didSet { persist(autoProfileOnAC, for: "autoProfileOnAC") } }
    @Published var loginEnabled = false

    private let monitor: any HardwareSource
    private let helperClient: any FanService
    private let preferences: UserDefaults
    private let persistsPreferences: Bool
    private let automaticallySamples: Bool
    private let refreshDeliveryGate: (@MainActor @Sendable () async -> Void)?
    private let queue = DispatchQueue(label: "io.github.hughhhhcoder.monitor", qos: .utility)
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var sampling = false
    private var previousAC: Bool?
    private var suspended = false
    private var controlGeneration = 0
    private var profileGeneration = 0
    private var fanGenerations: [Int: Int] = [:]
    private var monitoringGeneration = 0
    private var inFlight = Set<Int>()
    private var lastTransportError: String?

    static let requiredProtocolVersion = FanControlProtocol.currentVersion
    var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development" }
    var english: Bool { language == "en" }
    func text(_ zh: String, _ en: String) -> String { english ? en : zh }
    var peakTemperature: Double? { snapshot.temperatures.map(\.celsius).max() }
    var meanRPM: Double? { let values = snapshot.fans.compactMap(\.currentRPM); return values.isEmpty ? nil : values.reduce(0,+) / Double(values.count) }
    var activeCount: Int { policies.count }
    var hottestSensor: TemperatureReading? { snapshot.temperatures.max(by: { $0.celsius < $1.celsius }) }
    var memoryFraction: Double { snapshot.memoryTotalBytes == 0 ? 0 : Double(snapshot.memoryUsedBytes) / Double(snapshot.memoryTotalBytes) }
    var allProfiles: [CoolingProfile] { CoolingProfile.builtIns + profiles }
    var needsHelperSetup: Bool { !demo && [.missing, .otherUser, .outdated].contains(serviceCondition) }
    var reportedFanSummary: String {
        if let count = snapshot.reportedFanCount { return text("硬件报告 \(count) 个风扇 · 当前列出 \(snapshot.fans.count) 个", "Hardware reports \(count) fans · \(snapshot.fans.count) listed") }
        return text("当前识别 \(snapshot.fans.count) 个风扇，硬件总数不可用", "\(snapshot.fans.count) detected; reported count unavailable")
    }
    var globalControlNotice: String? { globalControlBlockReason }
    var helperSetupTitle: String {
        switch serviceCondition {
        case .outdated: return text("需要更新控制助手", "Update the control helper")
        case .otherUser: return text("助手属于另一个登录账号", "Helper belongs to another account")
        case .missing: return text("安装风扇控制助手", "Install the fan control helper")
        case .checking: return text("正在检查控制助手", "Checking the control helper")
        default: return text("控制能力与状态", "Control capabilities & status")
        }
    }
    var globalControlBlockReason: String? {
        if demo { return text("演示模式使用样例数据，不控制硬件。", "Demo mode uses sample data and never controls hardware.") }
        if paused || suspended { return text("请先恢复实时监控。", "Resume live monitoring first.") }
        switch serviceCondition {
        case .checking: return text("正在检查控制助手，请稍候。", "Checking the helper. Please wait.")
        case .missing: return text("下载应用只提供监控；手动调速需要安装匹配的管理员助手。点击下方安装按钮即可打开系统安装器。", "Monitoring works without installation. Fan control needs the matching administrator helper; use Install Helper to open the system installer.")
        case .otherUser: return text("现有助手授权给了另一个账号。请用本账号重新安装助手。", "The existing helper authorizes another user. Reinstall it from this account.")
        case .outdated: return text("主应用与已安装助手的协议不匹配，更新助手后才能应用设置。", "The installed helper uses an incompatible protocol. Update the helper before applying settings.")
        case .unavailable: return helperMessage.isEmpty ? text("控制服务暂时不可用。", "The control service is unavailable.") : helperMessage
        case .ready: break
        }
        if snapshot.reportedFanCount == 0, snapshot.fans.isEmpty { return text("这台 Mac 报告为无风扇设备，无需安装或调速。", "This Mac reports no fans. Fan control is not required.") }
        if helperResponse?.canControl == false { return localizedReason(code: helperResponse?.controlBlockCode?.rawValue, fallback: helperResponse?.controlBlockReason ?? helperMessage) }
        return nil
    }
    func controlBlockReason(for fan: FanReading) -> String? {
        if let reason = globalControlBlockReason { return reason }
        guard fan.canRequestControl else { return text("这只风扇的转速、范围或控制键不完整，当前可监控，不能安全写入。", "This fan has incomplete speed, range or control-key readings. Monitoring is available; safe writing is unavailable.") }
        if let capability = helperResponse?.fanCapabilities?.first(where: { $0.id == fan.id }), !capability.canControl {
            return capability.issue ?? text("助手无法控制这只风扇。", "The helper cannot control this fan.")
        }
        return nil
    }

    init(monitor: any HardwareSource = HardwareMonitor(), helperClient: any FanService = HelperClient(), preferences: UserDefaults = .standard, startsAutomatically: Bool = true, persistsPreferences: Bool = true, demoMode: Bool? = nil, refreshDeliveryGate: (@MainActor @Sendable () async -> Void)? = nil) {
        self.monitor = monitor
        self.helperClient = helperClient
        self.preferences = preferences
        self.persistsPreferences = persistsPreferences
        self.automaticallySamples = startsAutomatically
        self.refreshDeliveryGate = refreshDeliveryGate
        let useDemo = demoMode ?? ProcessInfo.processInfo.arguments.contains("--demo")
        demo = useDemo
        snapshot = useDemo ? HardwareMonitor.demoSnapshot() : monitor.snapshot()
        language = preferences.string(forKey: "language") ?? "zh"
        fahrenheit = preferences.bool(forKey: "fahrenheit")
        let saved = preferences.double(forKey: "interval")
        interval = [1.0, 2.0, 5.0].contains(saved) ? saved : 2
        autoProfileOnAC = preferences.bool(forKey: "autoProfileOnAC")
        if let data = preferences.data(forKey: "profiles"), let archive = try? JSONDecoder().decode(ProfileArchive.self, from: data), [1,2].contains(archive.schemaVersion) {
            profiles = archive.profiles.filter { (try? $0.validate()) != nil }
        }
        record(snapshot)
        guard startsAutomatically else { return }
        loginEnabled = SMAppService.mainApp.status == .enabled
        startTimer()
        refresh()
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.monitoringGeneration += 1; self?.suspended = true; self?.releaseOwnedControl() }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.suspended = false
                self.reconnectHardware()
            }
        })
    }
    private func persist(_ value: Any, for key: String) { if persistsPreferences { preferences.set(value, forKey: key) } }
    func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in Task { @MainActor in self?.refresh() } }
    }
    func refresh() {
        guard !sampling, !suspended, !paused else { return }
        sampling = true
        let isDemo = demo, generation = monitoringGeneration, monitor = monitor, client = helperClient
        let controlRevision = controlGeneration, fanRevisions = fanGenerations
        queue.async { [weak self] in
            let current = isDemo ? HardwareMonitor.demoSnapshot() : monitor.snapshot()
            let result: Result<HelperResponse, Error>? = isDemo ? nil : Result { try client.status() }
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.refreshDeliveryGate?()
                self.sampling = false
                guard self.monitoringGeneration == generation, self.demo == isDemo, !self.paused, !self.suspended else { return }
                self.snapshot = current
                self.updateService(result)
                self.record(current)
                if self.helperAvailable, let response = self.helperResponse {
                    let owned = Set(response.manualFanIDs)
                    for id in Array(self.policies.keys) where !owned.contains(id)
                        && self.controlGeneration == controlRevision
                        && self.fanGenerations[id, default: 0] == fanRevisions[id, default: 0]
                        && !self.inFlight.contains(id) {
                        self.fanGenerations[id, default: 0] += 1
                        self.policies.removeValue(forKey: id)
                        self.fanActions[id] = .init(phase: .failed, message: self.recoveryReason(from: response, fallback: self.text("助手已交还控制，原策略已停止。", "The helper released control. The old policy has stopped.")))
                    }
                }
                self.renewPolicies()
                if self.autoProfileOnAC, let old = self.previousAC, let ac = current.isOnACPower, old != ac, self.helperAvailable, !self.demo {
                    if ac { Task { await self.applyProfile(CoolingProfile.builtIns[0]) } } else { self.releaseOwnedControl() }
                }
                self.previousAC = current.isOnACPower
            }
        }
    }
    private func updateService(_ result: Result<HelperResponse, Error>?) {
        helperResponse = nil; helperAvailable = false
        guard let result else { serviceCondition = .checking; helperMessage = text("演示模式不连接控制助手", "Demo mode does not connect to the helper"); return }
        switch result {
        case .success(let response):
            helperResponse = response; lastTransportError = nil
            if response.protocolVersion != Self.requiredProtocolVersion {
                serviceCondition = .outdated; helperMessage = text("已安装旧版助手，需要更新。", "An older helper is installed and needs updating.")
            } else if !response.ok || response.smcAvailable == false {
                serviceCondition = .unavailable; helperMessage = localizedReason(code: response.errorCode?.rawValue, fallback: response.message)
            } else {
                serviceCondition = .ready; helperAvailable = true
                helperMessage = response.canControl == false ? localizedReason(code: response.controlBlockCode?.rawValue, fallback: response.controlBlockReason ?? response.message) : text("匹配的控制助手在线", "Matching control helper connected")
            }
        case .failure(let error):
            lastTransportError = error.localizedDescription
            if let typed = error as? FanControlError {
                switch typed.code {
                case .helperNotInstalled: serviceCondition = .missing
                case .wrongUser: serviceCondition = .otherUser
                case .upgradeRequired: serviceCondition = .outdated
                default: serviceCondition = .unavailable
                }
                helperMessage = localizedReason(code: typed.code.rawValue, fallback: typed.localizedDescription)
                return
            }
            let path = "/var/run/mac-control-pro/control.sock"
            if let attributes = try? FileManager.default.attributesOfItem(atPath: path), let owner = attributes[.ownerAccountID] as? NSNumber, owner.uint32Value != getuid() { serviceCondition = .otherUser }
            else if FileManager.default.fileExists(atPath: "/Library/PrivilegedHelperTools/io.github.hughhhhcoder.MacControlPro.helper") { serviceCondition = .unavailable }
            else { serviceCondition = .missing }
            helperMessage = serviceCondition == .unavailable ? text("助手已安装但未能连接。可尝试重新安装，并复制诊断查看原因。", "The helper is installed but unreachable. Reinstall it or copy diagnostics for the exact error.") : helperSetupTitle
        }
    }
    private func record(_ current: SystemSnapshot) {
        let speeds = current.fans.compactMap(\.currentRPM)
        history.append(.init(date: current.date, cpu: current.cpuUsage, temperature: current.temperatures.map(\.celsius).max(), rpm: speeds.isEmpty ? nil : speeds.reduce(0,+)/Double(speeds.count)))
        if history.count > 1800 { history.removeFirst(history.count-1800) }
    }
    func temperature(_ celsius: Double?) -> String { guard let celsius else { return "—" }; return String(format: "%.0f°%@", fahrenheit ? celsius*1.8+32 : celsius, fahrenheit ? "F" : "C") }
    func temperatureValue(_ celsius: Double) -> Double { fahrenheit ? celsius*1.8+32 : celsius }
    func profileName(_ profile: CoolingProfile) -> String { english ? (["均衡":"Balanced", "提前散热":"Proactive cooling", "持续负载":"Sustained load"][profile.name] ?? profile.name) : profile.name }
    func setPaused(_ value: Bool) { monitoringGeneration += 1; if value { releaseOwnedControl() }; paused = value; if !value { refresh() } }
    func setDemo(_ value: Bool) {
        monitoringGeneration += 1; let generation = monitoringGeneration
        releaseOwnedControl(); let hardware = monitor
        queue.async { [weak self] in
            let replacement = value ? HardwareMonitor.demoSnapshot() : hardware.snapshot()
            Task { @MainActor [weak self] in
                guard let self, self.monitoringGeneration == generation else { return }
                self.demo = value; self.snapshot = replacement; self.history.removeAll(); self.record(replacement)
                self.paused = false; self.previousAC = replacement.isOnACPower; self.helperAvailable = false; self.serviceCondition = .checking; self.refresh()
            }
        }
    }
    @discardableResult func setFixed(_ fan: FanReading, rpm: Double) async -> Bool {
        guard rpm.isFinite, let lower = fan.manualMinimumRPM, let upper = fan.maxRPM, (lower...upper).contains(rpm) else { message = text("目标转速不在这只风扇的可用范围内。", "Target RPM is outside this fan's available range."); return false }
        return await applyPolicy(fan: fan, policy: .init(rpm: rpm, points: nil, sensorID: nil))
    }
    @discardableResult func setCurve(_ fan: FanReading, points: [FanCurvePoint], sensorID: String?) async -> Bool {
        do { try FanCurve(points: points).validate() } catch { message = error.localizedDescription; return false }
        guard sensorID != nil, snapshot.temperatures.contains(where: { $0.id == sensorID }) else { message = text("请选择有效温度传感器。", "Choose an available temperature sensor."); return false }
        return await applyPolicy(fan: fan, policy: .init(rpm: nil, points: points, sensorID: sensorID))
    }
    @discardableResult func applyProfile(_ profile: CoolingProfile) async -> Bool {
        profileGeneration += 1
        let bulkGeneration = profileGeneration, control = controlGeneration
        func isCurrentProfile() -> Bool {
            controlGeneration == control && profileGeneration == bulkGeneration && !demo && !paused && !suspended
        }
        if let reason = globalControlBlockReason { message = reason; return false }
        guard isCurrentProfile() else { return false }
        guard let sensor = hottestSensor else { message = text("没有可用温度传感器，无法应用曲线。", "No temperature sensor is available for a curve."); return false }
        let eligible = snapshot.fans.filter { $0.canRequestControl }
        guard !eligible.isEmpty else { message = globalControlBlockReason ?? text("未发现可安全控制的风扇。", "No safely controllable fan was detected."); return false }
        var succeeded = 0
        for fan in eligible {
            guard isCurrentProfile() else { return false }
            if let points = profile.resolvedPoints(for: fan) {
                let applied = await setCurve(fan, points: points, sensorID: sensor.id)
                // Restore All, pause/sleep/quit, or a newer profile invalidates this whole
                // bulk operation. It must not start a fresh per-fan request afterward.
                guard isCurrentProfile() else { return false }
                if applied { succeeded += 1 }
            }
        }
        guard isCurrentProfile() else { return false }
        if succeeded != snapshot.fans.count { message = text("已应用 \(succeeded)/\(snapshot.fans.count) 个风扇；未成功的风扇已显示原因。", "Applied to \(succeeded)/\(snapshot.fans.count) fans. Unsuccessful fans show their reason.") }
        return succeeded == snapshot.fans.count
    }
    private func desiredRPM(fanID: Int, policy: FanPolicy) -> Double? {
        guard let fan = snapshot.fans.first(where: { $0.id == fanID }), fan.canRequestControl, let lower = fan.manualMinimumRPM, let upper = fan.maxRPM else { return nil }
        if let rpm = policy.rpm { return (lower...upper).contains(rpm) ? rpm : nil }
        if let points = policy.points, let sensor = snapshot.temperatures.first(where: { $0.id == policy.sensorID }) { return FanCurve(points: points).rpm(at: sensor.celsius, minRPM: lower, maxRPM: upper) }
        return nil
    }
    private func transport(_ operation: @escaping @Sendable () throws -> HelperResponse) async -> Result<HelperResponse, Error> {
        await withCheckedContinuation { continuation in queue.async { continuation.resume(returning: Result { try operation() }) } }
    }
    private func isCurrent(_ id: Int, global: Int, fan: Int) -> Bool { controlGeneration == global && fanGenerations[id, default: 0] == fan && !demo && !paused && !suspended }
    private func applyPolicy(fan: FanReading, policy: FanPolicy) async -> Bool {
        if let reason = controlBlockReason(for: fan) { message = reason; return false }
        let id = fan.id
        fanGenerations[id, default: 0] += 1; let fanGeneration = fanGenerations[id, default: 0], global = controlGeneration
        policies.removeValue(forKey: id); inFlight.insert(id)
        defer { if fanGenerations[id, default: 0] == fanGeneration { inFlight.remove(id) } }
        guard let rpm = desiredRPM(fanID: id, policy: policy) else { return false }
        fanActions[id] = .init(phase: .applying, message: text("正在应用…", "Applying…"), requestedRPM: rpm)
        let client = helperClient
        var result = await transport { try client.set(fanID: id, rpm: rpm) }
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        while true {
            guard isCurrent(id, global: global, fan: fanGeneration) else { return false }
            switch result {
            case .failure(let error): await failControl(id, reason: error.localizedDescription); return false
            case .success(let response):
                guard response.ok else { await failControl(id, reason: controlFailureReason(from: response)); return false }
                if response.applicationState?.rawValue == "pending" {
                    fanActions[id] = .init(phase: .waiting, message: text("等待固件释放控制…", "Waiting for firmware control…"), requestedRPM: rpm)
                    guard ProcessInfo.processInfo.systemUptime < deadline else { await failControl(id, reason: text("固件未在等待期限内释放控制，已请求恢复自动。", "Firmware did not yield before the deadline. Automatic recovery was requested.")); return false }
                    do { try await Task.sleep(nanoseconds: 750_000_000) } catch { await failControl(id, reason: text("应用已取消。", "Apply was cancelled.")); return false }
                    guard isCurrent(id, global: global, fan: fanGeneration) else { return false }
                    result = await transport { try client.renew(fanID: id, rpm: rpm) }
                } else {
                    guard response.applicationState == .applied else { await failControl(id, reason: text("助手未确认设置已应用，已释放本会话的控制。", "The helper did not confirm application. This session released control.")); return false }
                    policies[id] = policy
                    fanActions[id] = .init(phase: .active, message: text("设置已应用", "Settings applied"), requestedRPM: response.confirmedTargetRPM ?? rpm)
                    return true
                }
            }
        }
    }
    private func failControl(_ id: Int, reason: String) async {
        policies.removeValue(forKey: id)
        fanActions[id] = .init(phase: .failed, message: reason)
        let client = helperClient
        let revision = fanGenerations[id, default: 0], global = controlGeneration
        let recovery = await transport { try client.release(fanID: id) }
        guard fanGenerations[id, default: 0] == revision, controlGeneration == global else { return }
        var detail = reason
        if case .failure = recovery { detail += text(" 自动恢复未确认，请检查风扇模式。", " Automatic recovery was not confirmed. Check the fan mode.") }
        else if case .success(let reply) = recovery, !reply.ok { detail += " " + reply.message }
        message = detail
    }
    private func renewPolicies() {
        guard !demo, helperAvailable else { return }
        for (id, policy) in policies where !inFlight.contains(id) {
            guard let rpm = desiredRPM(fanID: id, policy: policy) else { restore(id); continue }
            inFlight.insert(id); let global = controlGeneration, fan = fanGenerations[id, default: 0], client = helperClient
            Task {
                let result = await transport { try client.renew(fanID: id, rpm: rpm) }
                guard isCurrent(id, global: global, fan: fan) else { return }
                inFlight.remove(id)
                switch result {
                case .success(let reply) where reply.ok && reply.applicationState == .applied:
                    fanActions[id] = .init(phase: .active, message: text("曲线 / 转速控制中", "Controlling fan speed"), requestedRPM: reply.confirmedTargetRPM ?? rpm)
                case .success(let reply) where reply.ok && reply.applicationState == .pending:
                    fanActions[id] = .init(phase: .waiting, message: text("等待固件释放控制…", "Waiting for firmware control…"), requestedRPM: rpm)
                case .success(let reply) where reply.ok:
                    await failControl(id, reason: text("助手未确认续约设置，已释放本会话的控制。", "The helper did not confirm the renewed setting. This session released control."))
                case .success(let reply): await failControl(id, reason: controlFailureReason(from: reply))
                case .failure(let error): await failControl(id, reason: error.localizedDescription)
                }
            }
        }
    }
    func restore(_ id: Int) { Task { _ = await restoreConfirmed(id) } }
    @discardableResult func restoreConfirmed(_ id: Int) async -> Bool {
        fanGenerations[id, default: 0] += 1
        policies.removeValue(forKey: id); inFlight.remove(id)
        if demo { fanActions.removeValue(forKey: id); return true }
        let generation = fanGenerations[id, default: 0]
        fanActions[id] = .init(phase: .restoring, message: text("正在恢复系统自动…", "Restoring automatic control…"))
        let client = helperClient
        let result = await transport { try client.automatic(fanID: id) }
        guard fanGenerations[id, default: 0] == generation else { return false }
        switch result {
        case .success(let reply) where reply.ok:
            fanActions.removeValue(forKey: id); refresh(); return true
        case .success(let reply):
            let detail = localizedReason(code: reply.errorCode?.rawValue, fallback: reply.message)
            fanActions[id] = .init(phase: .failed, message: detail); message = detail; return false
        case .failure(let error):
            fanActions[id] = .init(phase: .failed, message: error.localizedDescription); message = error.localizedDescription; return false
        }
    }
    func restoreAll() {
        controlGeneration += 1; policies.removeAll(); inFlight.removeAll(); fanActions.removeAll()
        guard !demo else { return }
        let client = helperClient
        Task {
            let result = await transport { try client.automatic(fanID: nil) }
            if case .success(let reply) = result, !reply.ok { message = reply.message }
            if case .failure(let error) = result { message = error.localizedDescription }
            refresh()
        }
    }
    func cancelControl(_ id: Int) {
        fanGenerations[id, default: 0] += 1
        policies.removeValue(forKey: id); inFlight.remove(id); fanActions.removeValue(forKey: id)
        let client = helperClient
        Task { _ = await transport { try client.release(fanID: id) }; refresh() }
    }
    private func releaseOwnedControl() {
        let shouldSend = helperAvailable || !policies.isEmpty || !inFlight.isEmpty
        controlGeneration += 1; policies.removeAll(); inFlight.removeAll(); fanActions.removeAll()
        guard !demo, shouldSend else { return }
        let client = helperClient
        Task { _ = await transport { try client.release(fanID: nil) }; refresh() }
    }
    func shutdown() { releaseOwnedControl() }
    func finishControlSession() async {
        // Quitting must also stop new automation while the final IPC release is pending.
        monitoringGeneration += 1
        timer?.invalidate(); timer = nil
        paused = true
        controlGeneration += 1; policies.removeAll(); inFlight.removeAll(); fanActions.removeAll()
        guard !demo else { return }
        let client = helperClient
        _ = await transport { try client.release(fanID: nil) }
    }
    private func reconnectHardware() {
        let hardware = monitor
        queue.async { [weak self] in _ = hardware.reconnect(); Task { @MainActor [weak self] in self?.refresh() } }
    }
    func checkServiceNow() {
        let client = helperClient
        Task { let response = await transport { try client.status() }; updateService(response); if !paused { refresh() } }
    }
    func openHelperUninstaller() {
        releaseOwnedControl()
        guard let url = Bundle.main.url(forResource: "Uninstall Fan Helper", withExtension: "pkg"), NSWorkspace.shared.open(url) else { message = text("当前构建未包含卸载包，请使用发行版。", "This build has no removal package. Use the packaged release."); return }
    }

    private func controlFailureReason(from response: HelperResponse) -> String {
        // A lease can disappear because the helper already performed a safety recovery.
        // Recovery metadata must never replace an unrelated new request error.
        if response.errorCode == .leaseExpired,
           response.lastRecoveryCode != nil || response.lastRecoveryReason != nil {
            return recoveryReason(from: response, fallback: response.message)
        }
        return localizedReason(code: response.errorCode?.rawValue, fallback: response.message, context: response)
    }
    private func recoveryReason(from response: HelperResponse, fallback: String) -> String {
        let recorded = response.lastRecoveryReason ?? fallback
        let localized = localizedReason(code: response.lastRecoveryCode?.rawValue, fallback: recorded, context: response)
        if !english, response.lastRecoveryReason != nil, localized != recorded {
            // Preserve the event's exact reason, including its measured temperature;
            // the latest status temperature may already have fallen since recovery.
            return localized + "\n助手记录的恢复原因：" + recorded
        }
        return localized
    }
    func localizedReason(code: String?, fallback: String, context: HelperResponse? = nil) -> String {
        guard !english else { return fallback }
        switch code {
        case "helper_not_installed": return "尚未安装控制助手。点击“安装控制助手”并完成系统管理员验证后即可重新检测。"
        case "helper_unavailable", "transport_failure", "connection_timeout": return "控制助手已断开或没有及时响应。可重新检测、重新安装助手，或复制诊断查看原因。"
        case "wrong_user": return "控制助手当前绑定了另一个账号。为当前登录账号重新安装助手即可修复。"
        case "upgrade_required", "protocol_mismatch": return "主应用和控制助手版本不匹配，请更新助手。"
        case "temperature_unavailable": return "无法获取有效的温度读数，请使用系统自动模式。"
        case "thermal_pressure": return "macOS 报告严重或危急的热压力，请使用系统自动模式。"
        case "temperature_guard", "thermal_guard", "temperature_limit":
            let report = context ?? helperResponse
            guard let limit = report?.temperatureLimitCelsius else {
                return "温度达到旧版助手的控制阈值，请使用系统自动模式。"
            }
            let current = temperature(report?.hottestTemperatureCelsius ?? peakTemperature)
            return "温度达到旧版助手的控制阈值（当前最高 \(current)，阈值 \(temperature(limit))）。请使用系统自动模式。"
        case "lease_lost", "lease_expired": return "助手已结束控制租约，原策略已停止。请确认原因后重新应用。"
        case "fan_busy", "session_mismatch", "lease_owned_by_another_client": return "这只风扇正由另一个控制会话管理。请先恢复自动，避免多个控制器互相覆盖。"
        case "smc_unavailable", "unsupported_hardware": return "系统暂未开放可用的 SMC 控制接口。监控仍可使用；可复制诊断排查。"
        case "invalid_rpm", "invalid_request", "fan_unavailable", "fan_read_only": return "风扇参数或硬件范围不可用，请查看这只风扇的诊断信息。"
        default: return fallback
        }
    }
    func openHelperInstaller() {
        guard let url = Bundle.main.url(forResource: "Install Fan Helper", withExtension: "pkg") else { message = text("当前运行的是源码构建，未包含安装包。请下载完整发行版或运行构建脚本生成安装包。", "This source build has no embedded installer. Download the packaged release or run the release build script."); return }
        if !NSWorkspace.shared.open(url) { message = text("未能打开系统安装器。", "Could not open the system installer.") }
    }
    func openGuide() { NSWorkspace.shared.open(URL(string: "https://github.com/Hughhhhcoder/mac-control-pro/blob/main/docs/HELPER.md")!) }
    func copySupportDetails() {
        let report = SupportReport(appVersion: version, requiredProtocolVersion: Self.requiredProtocolVersion, hardwareModel: snapshot.hardwareModel, chip: snapshot.chipName, os: ProcessInfo.processInfo.operatingSystemVersionString, reportedFanCount: snapshot.reportedFanCount, fans: snapshot.fans, smcStatus: snapshot.smcStatus, sensorCount: snapshot.temperatures.count, hottestCelsius: peakTemperature, helper: helperResponse, transportError: lastTransportError)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(report), let string = String(data: data, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(string, forType: .string)
    }
    private struct SupportReport: Encodable {
        let appVersion: String; let requiredProtocolVersion: Int; let hardwareModel: String; let chip: String; let os: String
        let reportedFanCount: Int?; let fans: [FanReading]; let smcStatus: String; let sensorCount: Int; let hottestCelsius: Double?
        let helper: HelperResponse?; let transportError: String?
    }
    func saveProfile(name: String, points: [FanCurvePoint], usesPercent: Bool = false) {
        guard profiles.count < 100 else { message = text("最多保存 100 个配置。", "Up to 100 profiles can be saved."); return }
        let profile = CoolingProfile(name: String(name.prefix(80)), symbol: "slider.horizontal.3", points: points, usesPercent: usesPercent)
        do { try profile.validate(); profiles.append(profile); persistProfiles() } catch { message = error.localizedDescription }
    }
    func deleteProfile(_ profile: CoolingProfile) { profiles.removeAll { $0.id == profile.id }; persistProfiles() }
    private func persistProfiles() { if persistsPreferences { preferences.set(try? JSONEncoder().encode(ProfileArchive(profiles: profiles)), forKey: "profiles") } }
    func importProfiles() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let attributes = try url.resourceValues(forKeys: [.fileSizeKey]); guard (attributes.fileSize ?? Int.max) < 1_000_000 else { throw CocoaError(.fileReadTooLarge) }
            let archive = try JSONDecoder().decode(ProfileArchive.self, from: Data(contentsOf: url))
            guard [1,2].contains(archive.schemaVersion), archive.profiles.count <= 100, profiles.count + archive.profiles.count <= 100 else { throw CocoaError(.fileReadCorruptFile) }
            for profile in archive.profiles { try profile.validate() }
            profiles.append(contentsOf: archive.profiles.map { .init(name: $0.name, symbol: "slider.horizontal.3", points: $0.points, usesPercent: $0.usesPercent) }); persistProfiles()
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
        do { let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601; try save(data: encoder.encode(snapshot), name: "MacControlPro-diagnostics.json", type: .json) } catch { message = error.localizedDescription }
    }
    private func save(data: Data, name: String, type: UTType) throws {
        let panel = NSSavePanel(); panel.nameFieldStringValue = name; panel.allowedContentTypes = [type]
        guard panel.runModal() == .OK, let url = panel.url else { return }; try data.write(to: url, options: .atomic); lastExport = url
    }
    func setLogin(_ enabled: Bool) {
        do { if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }; loginEnabled = SMAppService.mainApp.status == .enabled }
        catch { message = error.localizedDescription; loginEnabled = SMAppService.mainApp.status == .enabled }
    }
}
