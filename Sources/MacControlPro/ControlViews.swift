import Charts
import MacControlCore
import SwiftUI

struct FansView: View {
    @EnvironmentObject var model: AppModel
    var compact = false
    @State private var selectedFan: FanReading?
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if compact { HStack { Text(model.text("风扇", "Fans")).font(.title3.weight(.semibold)); Spacer(); Text(model.text("\(model.snapshot.fans.count) 个可见设备", "\(model.snapshot.fans.count) detected")).font(.caption).foregroundStyle(.secondary) } }
            if model.snapshot.fans.isEmpty {
                Panel(title: model.text("没有可用的风扇读数", "No fan readings available"), symbol: "fan.slash") { Text(model.text("无风扇机型或未开放 SMC 接口的设备会显示此状态。CPU 和内存监控仍可使用。", "Fanless models and devices that restrict SMC access may show this state. CPU and memory monitoring remain available.")).foregroundStyle(.secondary).font(.callout) }
            } else {
                ForEach(model.snapshot.fans) { fan in
                    Panel(title: "", symbol: "fan") {
                        HStack(spacing: 18) {
                            Image(systemName: "fan.fill").font(.system(size: 32, weight: .light)).foregroundStyle(.teal).frame(width: 58, height: 58).background(.teal.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                            VStack(alignment: .leading, spacing: 7) { Text(fan.name).font(.headline); HStack(spacing: 5) { Circle().fill(model.policies[fan.id] == nil ? .green : .orange).frame(width: 5, height: 5); Text(model.policies[fan.id] != nil ? model.text("自定义控制", "Custom control") : fan.isManual ? model.text("手动 · 其他控制来源", "Manual · other source") : model.text("系统自动", "System automatic")).font(.caption).foregroundStyle(.secondary) } }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 5) { HStack(alignment: .firstTextBaseline, spacing: 5) { Text(String(format: "%.0f", fan.currentRPM)).font(.system(size: 29, weight: .medium, design: .rounded)).monospacedDigit(); Text("RPM").font(.caption).foregroundStyle(.secondary) }; Text(String(format: "%.0f – %.0f RPM", fan.minRPM, fan.maxRPM)).font(.caption).foregroundStyle(.secondary) }
                            Button(model.text("调整…", "Adjust…")) { selectedFan = fan }.buttonStyle(.bordered)
                        }
                        ProgressView(value: fan.maxRPM > 0 ? min(1, max(0, fan.currentRPM / fan.maxRPM)) : 0).tint(.teal)
                    }
                }
            }
            if !compact {
                HStack { Button(model.text("全部恢复系统自动", "Restore All to Automatic"), action: model.restoreAll).buttonStyle(.bordered); Spacer(); Label(model.helperAvailable ? model.text("控制服务在线", "Helper connected") : model.text("监控模式", "Monitoring mode"), systemImage: model.helperAvailable ? "checkmark.shield" : "eye").font(.caption).foregroundStyle(.secondary) }
                if !model.helperAvailable { Banner(symbol: "lock.shield", title: model.text("管理员辅助服务为可选项", "The privileged helper is optional"), detail: model.text("监控无需管理员权限。安装辅助服务后，才能请求固定转速和温度曲线；实际支持取决于机型。", "Monitoring requires no administrator access. Fixed RPM and temperature curves require the optional helper and compatible hardware.")); Button(model.text("查看安装与卸载指南", "Installation & removal guide"), action: model.openGuide).buttonStyle(.link) }
            }
        }.sheet(item: $selectedFan) { fan in FanEditor(fan: fan) }
    }
}

struct FanEditor: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let fan: FanReading
    @State private var mode = 0
    @State private var rpm = 2500.0
    @State private var sensor = ""
    @State private var points = CoolingProfile.builtIns[0].points
    @State private var profileName = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack { Image(systemName: "fan.fill").foregroundStyle(.teal).font(.largeTitle); VStack(alignment: .leading, spacing: 4) { Text(fan.name).font(.title2.bold()); Text(model.text("选择此风扇的控制方式", "Choose how this fan is managed")).foregroundStyle(.secondary) }; Spacer() }
            Picker(model.text("模式", "Mode"), selection: $mode) { Text(model.text("系统自动", "Automatic")).tag(0); Text(model.text("固定转速", "Fixed RPM")).tag(1); Text(model.text("温度曲线", "Temperature Curve")).tag(2) }.pickerStyle(.segmented)
            if mode == 0 { Banner(symbol: "checkmark.shield", title: model.text("交还给 macOS", "Let macOS manage cooling"), detail: model.text("清除本应用对此风扇的自定义控制。", "Release this app's custom control for this fan.")) }
            if mode == 1 {
                Text(String(format: "%.0f RPM", rpm)).font(.largeTitle.monospacedDigit())
                Slider(value: $rpm, in: safeMinimum...safeMaximum, step: 50)
                HStack { Text(String(format: "%.0f RPM", safeMinimum)); Spacer(); Text(String(format: "%.0f RPM", safeMaximum)) }.font(.caption).foregroundStyle(.secondary)
            }
            if mode == 2 {
                Picker(model.text("温度来源", "Temperature source"), selection: $sensor) { Text(model.text("选择传感器", "Choose a sensor")).tag(""); ForEach(model.snapshot.temperatures) { Text("\($0.name) · \(model.temperature($0.celsius))").tag($0.id) } }
                CurveEditor(points: $points)
                HStack { TextField(model.text("保存为新配置的名称", "Name for a new profile"), text: $profileName); Button(model.text("保存配置", "Save Profile")) { model.saveProfile(name: profileName, points: points); profileName = "" }.disabled(profileName.trimmingCharacters(in: .whitespaces).isEmpty) }
            }
            if mode != 0 { Text(model.text("控制服务将拒绝超出硬件范围的转速；温度达到 85°C、读数丢失或心跳超时后，会尝试恢复系统自动。", "The helper rejects RPM outside hardware limits. At 85°C, on missing feedback or heartbeat timeout, it attempts to restore automatic mode.")).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            HStack { if !model.helperAvailable { Button(model.text("辅助服务说明", "Helper Guide"), action: model.openGuide).buttonStyle(.link) }; Spacer(); Button(model.text("取消", "Cancel")) { dismiss() }.keyboardShortcut(.cancelAction); Button(model.text("应用", "Apply")) { if mode == 0 { model.restore(fan.id) } else if mode == 1 { model.setFixed(fan, rpm: rpm) } else { model.setCurve(fan, points: points, sensorID: sensor.isEmpty ? nil : sensor) }; dismiss() }.buttonStyle(.borderedProminent).tint(.teal).disabled(mode != 0 && (model.demo || !model.helperAvailable || (mode == 2 && sensor.isEmpty))) }
        }.padding(26).frame(width: 570)
        .onAppear { rpm = min(safeMaximum, max(safeMinimum, fan.currentRPM)); sensor = model.hottestSensor?.id ?? "" }
    }
    private var safeMinimum: Double { max(1200, fan.minRPM) }
    private var safeMaximum: Double { max(safeMinimum, fan.maxRPM) }
}

struct SensorsView: View {
    @EnvironmentObject var model: AppModel
    @State private var search = ""
    @State private var sort = "hot"
    private var filtered: [TemperatureReading] { model.snapshot.temperatures.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.id.localizedCaseInsensitiveContains(search) || $0.category.localizedCaseInsensitiveContains(search) }.sorted { sort == "hot" ? $0.celsius > $1.celsius : $0.name < $1.name } }
    var body: some View {
        VStack(spacing: 16) {
            HStack { Image(systemName: "magnifyingglass").foregroundStyle(.secondary); TextField(model.text("搜索名称、类别或 SMC 标识", "Search name, category or SMC key"), text: $search).textFieldStyle(.plain); Picker("", selection: $sort) { Text(model.text("温度优先", "Hottest first")).tag("hot"); Text(model.text("名称排序", "Name")).tag("name") }.frame(width: 140) }.padding(12).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            if filtered.isEmpty { ContentUnavailableView(model.text("没有传感器读数", "No sensor readings"), systemImage: "thermometer.medium", description: Text(search.isEmpty ? model.snapshot.smcStatus : model.text("试试其他搜索词。", "Try a different search."))) }
            else {
                Panel(title: model.text("\(filtered.count) 个温度传感器", "\(filtered.count) temperature sensors"), symbol: "sensor") {
                    ForEach(filtered) { sensor in HStack { Image(systemName: "thermometer.medium").foregroundStyle(sensor.celsius >= 80 ? .orange : .teal).frame(width: 25); VStack(alignment: .leading, spacing: 4) { Text(sensor.name).font(.callout.weight(.medium)); Text("\(sensor.category) · \(sensor.id)").font(.caption).foregroundStyle(.secondary) }; Spacer(); Text(model.temperature(sensor.celsius)).font(.system(.title3, design: .rounded).weight(.medium)).monospacedDigit() }.padding(.vertical, 6); if sensor.id != filtered.last?.id { Divider() } }
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
