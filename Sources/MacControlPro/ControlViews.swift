import Charts
import MacControlCore
import SwiftUI

struct HelperSetupPanel: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Banner(symbol: model.needsHelperSetup ? "lock.shield" : "info.circle", title: title, detail: model.helperMessage, color: model.helperAvailable ? .teal : .orange)
            HStack {
                if model.needsHelperSetup {
                    Button(model.serviceCondition == .outdated ? model.text("更新控制助手…", "Update Control Helper…") : model.text("安装 / 修复控制助手…", "Install / Repair Control Helper…"), action: model.openHelperInstaller).buttonStyle(.borderedProminent)
                }
                Button(model.text("重新检测", "Check Again"), action: model.checkServiceNow).buttonStyle(.bordered)
                Button(model.text("复制诊断", "Copy Diagnostics"), action: model.copySupportDetails).buttonStyle(.bordered)
                Spacer()
                Button(model.text("安装说明", "Setup Guide"), action: model.openGuide).buttonStyle(.link)
            }
        }
    }
    private var title: String {
        switch model.serviceCondition {
        case .checking: return model.text("正在检查控制服务", "Checking the control service")
        case .missing: return model.text("监控已可用，调速需要安装控制助手", "Monitoring is ready. Fan control needs the helper.")
        case .outdated: return model.text("控制助手需要更新", "The control helper needs updating")
        case .otherUser: return model.text("控制助手绑定了其他登录账号", "The helper belongs to another login account")
        case .unavailable: return model.text("当前控制服务不可用", "The control service is unavailable")
        case .ready: return model.text("控制保护或硬件能力限制", "Control protection or hardware limitation")
        }
    }
}

struct FansView: View {
    @EnvironmentObject var model: AppModel
    var compact = false
    @State private var selectedFan: FanReading?
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { if compact { Text(model.text("风扇", "Fans")).font(.title3.weight(.semibold)) }; Spacer(); Text(model.reportedFanSummary).font(.caption).foregroundStyle(.secondary) }
            if model.snapshot.fans.isEmpty {
                Panel(title: model.snapshot.reportedFanCount == 0 ? model.text("这台 Mac 报告为无风扇设备", "This Mac reports no fans") : model.text("风扇信息暂不可用", "Fan information is unavailable"), symbol: "fan.slash") {
                    Text(model.snapshot.fanDiscoveryMessage ?? model.snapshot.smcStatus).foregroundStyle(.secondary).font(.callout)
                    Text(model.text("风扇数量由硬件读取；不同 MacBook、Mac mini、Mac Studio 的数量可以不同。", "Fan count comes from the hardware and can differ across MacBook, Mac mini and Mac Studio models.")).foregroundStyle(.secondary).font(.caption)
                }
            } else {
                ForEach(model.snapshot.fans) { fan in
                    Panel(title: "", symbol: "fan") {
                        HStack(spacing: 18) {
                            Image(systemName: "fan.fill").font(.system(size: 32, weight: .light)).foregroundStyle(.teal).frame(width: 58, height: 58).background(.teal.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                            VStack(alignment: .leading, spacing: 7) {
                                Text(fan.name).font(.headline)
                                Text(stateLabel(fan)).font(.caption).foregroundStyle(model.fanActions[fan.id]?.phase == .failed ? .orange : .secondary)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 5) {
                                HStack(alignment: .firstTextBaseline, spacing: 5) { Text(fan.currentRPM.map { String(format: "%.0f", $0) } ?? "—").font(.system(size: 29, weight: .medium, design: .rounded)).monospacedDigit(); Text("RPM").font(.caption).foregroundStyle(.secondary) }
                                Text(bounds(fan)).font(.caption).foregroundStyle(.secondary)
                            }
                            if let action = model.fanActions[fan.id], [.applying,.waiting,.restoring].contains(action.phase) { ProgressView().controlSize(.small) }
                            Button(model.text("调整…", "Adjust…")) { selectedFan = fan }.buttonStyle(.bordered)
                        }
                        if let actual = fan.currentRPM, let maximum = fan.maxRPM, maximum > 0 { ProgressView(value: min(1, max(0, actual/maximum))).tint(.teal) }
                        if let action = model.fanActions[fan.id], action.phase == .active, let rpm = action.requestedRPM { Text(model.text("当前请求 ", "Requested ") + String(format: "%.0f RPM", rpm)).font(.caption).foregroundStyle(.secondary) }
                        if !fan.canRequestControl { Label(model.text("部分硬件信息不可读，已保留此风扇的可用读数。", "Some hardware details are unavailable. Available fan readings are preserved."), systemImage: "info.circle").font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
            if !compact {
                HStack { Button(model.text("全部恢复系统自动", "Restore All to Automatic"), action: model.restoreAll).buttonStyle(.bordered); Spacer(); Label(model.helperAvailable ? model.text("控制服务在线", "Helper connected") : model.text("监控模式", "Monitoring mode"), systemImage: model.helperAvailable ? "checkmark.shield" : "eye").font(.caption).foregroundStyle(.secondary) }
                if model.globalControlNotice != nil || !model.helperAvailable { HelperSetupPanel() }
                if let detail = model.snapshot.fanDiscoveryMessage { Text(detail).font(.caption).foregroundStyle(.secondary) }
            }
        }.sheet(item: $selectedFan) { fan in FanEditor(fan: fan) }
    }
    private func stateLabel(_ fan: FanReading) -> String {
        if let action = model.fanActions[fan.id] { return action.message }
        if fan.modeRawValue == nil { return model.text("控制模式不可读", "Control mode unavailable") }
        if let raw = fan.modeRawValue, ![0,1,3].contains(raw) { return model.text("硬件模式 \(raw)", "Hardware mode \(raw)") }
        return fan.isManual ? model.text("手动 · 其他控制来源", "Manual · another controller") : model.text("系统自动", "System automatic")
    }
    private func bounds(_ fan: FanReading) -> String {
        guard let lower = fan.minRPM, let upper = fan.maxRPM, fan.hasValidBounds else { return model.text("硬件转速范围不可用", "Hardware speed bounds unavailable") }
        return String(format: "%.0f – %.0f RPM", lower, upper)
    }
}

struct FanEditor: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let fan: FanReading
    @State private var mode = 0
    @State private var rpm = 0.0
    @State private var sensor = ""
    @State private var points: [FanCurvePoint] = []
    @State private var profileName = ""
    @State private var applying = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Image(systemName: "fan.fill").foregroundStyle(.teal).font(.largeTitle); VStack(alignment: .leading, spacing: 4) { Text(fan.name).font(.title2.bold()); Text(model.text("选择此风扇的控制方式", "Choose how this fan is managed")).foregroundStyle(.secondary) }; Spacer() }
            Picker(model.text("模式", "Mode"), selection: $mode) { Text(model.text("系统自动", "Automatic")).tag(0); Text(model.text("固定转速", "Fixed RPM")).tag(1); Text(model.text("温度曲线", "Temperature Curve")).tag(2) }.pickerStyle(.segmented).disabled(applying)
            if mode == 0 { Banner(symbol: "checkmark.shield", title: model.text("交还给 macOS", "Let macOS manage cooling"), detail: model.text("结束当前风扇的自定义控制。", "End custom control for this fan.")) }
            if mode == 1, let lower = fan.manualMinimumRPM, let upper = fan.maxRPM {
                HStack { TextField("RPM", value: $rpm, format: .number.precision(.fractionLength(0))).font(.title2.monospacedDigit()).textFieldStyle(.roundedBorder).frame(width: 160); Text("RPM").foregroundStyle(.secondary); Spacer() }
                if upper > lower { Slider(value: $rpm, in: lower...upper, step: 1).disabled(applying) }
                HStack { Text(String(format: "%.0f RPM", lower)); Spacer(); Text(String(format: "%.0f RPM", upper)) }.font(.caption).foregroundStyle(.secondary)
            }
            if mode == 2 {
                Picker(model.text("温度来源", "Temperature source"), selection: $sensor) { Text(model.text("选择传感器", "Choose a sensor")).tag(""); ForEach(model.snapshot.temperatures) { Text("\($0.name) · \(model.temperature($0.celsius))").tag($0.id) } }.disabled(applying)
                CurveEditor(points: $points).disabled(applying)
                HStack { TextField(model.text("保存为新配置的名称", "Name for a new profile"), text: $profileName); Button(model.text("保存配置", "Save Profile")) { model.saveProfile(name: profileName, points: points); profileName = "" }.disabled(profileName.trimmingCharacters(in: .whitespaces).isEmpty || applying) }
            }
            if mode != 0, let reason = model.controlBlockReason(for: fan) { Banner(symbol: "exclamationmark.circle", title: model.text("当前无法应用", "Cannot apply right now"), detail: reason, color: .orange) }
            if model.needsHelperSetup { Button(model.text("安装 / 更新控制助手…", "Install / Update Control Helper…"), action: model.openHelperInstaller).buttonStyle(.borderedProminent) }
            if let action = model.fanActions[fan.id], [.waiting,.applying,.failed].contains(action.phase) { HStack { if applying { ProgressView().controlSize(.small) }; Text(action.message).font(.caption).foregroundStyle(action.phase == .failed ? .orange : .secondary) } }
            HStack {
                Button(model.text("复制诊断", "Copy Diagnostics"), action: model.copySupportDetails).buttonStyle(.link)
                Spacer()
                Button(model.text("取消", "Cancel")) { if applying { model.cancelControl(fan.id) }; dismiss() }.keyboardShortcut(.cancelAction)
                Button(applying ? model.text("正在应用…", "Applying…") : model.text("应用", "Apply")) {
                    applying = true
                    Task {
                        let applied: Bool
                        if mode == 0 { applied = await model.restoreConfirmed(fan.id) }
                        else if mode == 1 { applied = await model.setFixed(fan, rpm: rpm) }
                        else { applied = await model.setCurve(fan, points: points, sensorID: sensor.isEmpty ? nil : sensor) }
                        applying = false
                        if applied { dismiss() }
                    }
                }.buttonStyle(.borderedProminent).tint(.teal).disabled(applying || (mode != 0 && (model.controlBlockReason(for: fan) != nil || (mode == 2 && (sensor.isEmpty || (try? FanCurve(points: points).validate()) == nil)))))
            }
        }.padding(26).frame(width: 590)
        .onAppear {
            let lower = fan.manualMinimumRPM ?? 0, upper = fan.maxRPM ?? lower
            rpm = min(upper, max(lower, model.policies[fan.id]?.rpm ?? fan.currentRPM ?? lower))
            points = model.policies[fan.id]?.points ?? CoolingProfile.builtIns[0].resolvedPoints(for: fan) ?? [.init(temperature: 35, rpm: lower), .init(temperature: 80, rpm: upper)]
            sensor = model.policies[fan.id]?.sensorID ?? model.hottestSensor?.id ?? ""
            if let policy = model.policies[fan.id] { mode = policy.points == nil ? 1 : 2 }
        }
    }
}
struct SensorsView: View {
    @EnvironmentObject var model: AppModel
    @State private var search = ""
    @State private var sort = "hot"
    private var filtered: [TemperatureReading] { model.snapshot.temperatures.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.id.localizedCaseInsensitiveContains(search) || $0.category.localizedCaseInsensitiveContains(search) }.sorted { sort == "hot" ? $0.celsius > $1.celsius : $0.name < $1.name } }
    var body: some View {
        let rows = filtered
        return VStack(spacing: 16) {
            HStack { Image(systemName: "magnifyingglass").foregroundStyle(.secondary); TextField(model.text("搜索名称、类别或 SMC 标识", "Search name, category or SMC key"), text: $search).textFieldStyle(.plain); Picker("", selection: $sort) { Text(model.text("温度优先", "Hottest first")).tag("hot"); Text(model.text("名称排序", "Name")).tag("name") }.frame(width: 140) }.padding(12).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            if rows.isEmpty { ContentUnavailableView(model.text("没有传感器读数", "No sensor readings"), systemImage: "thermometer.medium", description: Text(search.isEmpty ? model.snapshot.smcStatus : model.text("试试其他搜索词。", "Try a different search."))) }
            else {
                Panel(title: model.text("\(rows.count) 个温度传感器", "\(rows.count) temperature sensors"), symbol: "sensor") {
                    ForEach(rows) { sensor in HStack { Image(systemName: "thermometer.medium").foregroundStyle(sensor.celsius >= 80 ? .orange : .teal).frame(width: 25); VStack(alignment: .leading, spacing: 4) { Text(sensor.name).font(.callout.weight(.medium)); Text("\(sensor.category) · \(sensor.id)").font(.caption).foregroundStyle(.secondary) }; Spacer(); Text(model.temperature(sensor.celsius)).font(.system(.title3, design: .rounded).weight(.medium)).monospacedDigit() }.padding(.vertical, 6); if sensor.id != rows.last?.id { Divider() } }
                }
            }
        }
    }
}

struct HistoryView: View {
    @EnvironmentObject var model: AppModel
    @State private var metric = "temperature"
    var body: some View {
        Panel(title: model.text("会话历史", "Session History"), symbol: "chart.xyaxis.line") {
            HStack { Picker("", selection: $metric) { Text(model.text("温度", "Temperature")).tag("temperature"); Text("CPU").tag("cpu"); Text(model.text("风扇转速", "Fan RPM")).tag("rpm") }.pickerStyle(.segmented).frame(width: 350); Spacer(); Text(unit).font(.caption).foregroundStyle(.secondary) }
            TrendChart(samples: model.history, metric: metric).frame(height: 300)
            Divider()
            HStack { Label(model.text("\(model.history.count) 个采样点", "\(model.history.count) samples"), systemImage: "clock"); Spacer(); Text(model.text("每 \(Int(model.interval)) 秒采样 · 最多 1800 点", "Every \(Int(model.interval))s · up to 1800 points")) }.font(.caption).foregroundStyle(.secondary)
            Button(model.text("导出为 CSV…", "Export CSV…"), action: model.exportCSV).buttonStyle(.bordered)
        }
        Banner(symbol: "externaldrive", title: model.text("数据留在你的 Mac", "Your data stays on your Mac"), detail: model.text("历史仅保存在本次会话内存中，退出后清除。CSV 使用摄氏度和 ISO 8601 时间，便于复核和分析。", "History is held in session memory and cleared on exit. CSV uses Celsius and ISO 8601 timestamps for reproducible analysis."))
    }
    var unit: String { metric == "temperature" ? (model.fahrenheit ? "°F" : "°C") : metric == "rpm" ? "RPM" : "%" }
}
