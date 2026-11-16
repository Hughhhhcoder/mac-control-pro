import AppKit
import Charts
import MacControlCore
import SwiftUI

struct ProfilesView: View {
    @EnvironmentObject var model: AppModel
    @State private var creating = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text(model.text("预设与自定义", "Presets & custom curves")).font(.title3.weight(.semibold)); Spacer(); Button(model.text("导入…", "Import…"), action: model.importProfiles); Button(model.text("导出…", "Export…"), action: model.exportProfiles); Button { creating = true } label: { Label(model.text("新建配置", "New Profile"), systemImage: "plus") }.buttonStyle(.borderedProminent) }
            ForEach(model.allProfiles) { profile in
                Panel(title: model.profileName(profile), symbol: profile.symbol) {
                    Chart(Array(profile.points.enumerated()), id: \.offset) { _, point in LineMark(x: .value("°C", point.temperature), y: .value("RPM", point.rpm)).foregroundStyle(.teal); PointMark(x: .value("°C", point.temperature), y: .value("RPM", point.rpm)).foregroundStyle(.teal) }.chartXAxisLabel("°C").chartYAxisLabel("RPM").frame(height: 100)
                    HStack { Text(model.text("\(profile.points.count) 个节点 · 按每个风扇硬件范围限幅", "\(profile.points.count) points · clamped to each fan’s limits")).font(.caption).foregroundStyle(.secondary); Spacer(); if model.profiles.contains(where: { $0.id == profile.id }) { Button(role: .destructive) { model.deleteProfile(profile) } label: { Image(systemName: "trash") }.buttonStyle(.borderless) }; Button(model.text("应用至全部风扇", "Apply to All Fans")) { model.applyProfile(profile) }.buttonStyle(.bordered).disabled(model.snapshot.fans.isEmpty) }
                }
            }
            Banner(symbol: "info.circle", title: model.text("配置由你掌控", "Profiles are yours"), detail: model.text("曲线支持多节点线性插值；应用预设时以当前最热的传感器作为温度来源。温度使用 °C。导入配置不会自动控制硬件。", "Curves use multi-point linear interpolation. Applying a preset uses the currently hottest sensor as its source. Curve temperatures use °C. Importing never applies hardware control."))
        }.sheet(isPresented: $creating) { NewProfileView() }
    }
}
struct NewProfileView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var points = CoolingProfile.builtIns[0].points
    var body: some View { VStack(alignment: .leading, spacing: 20) { Text(model.text("创建散热配置", "Create a Cooling Profile")).font(.title2.bold()); TextField(model.text("配置名称", "Profile name"), text: $name); CurveEditor(points: $points); HStack { Spacer(); Button(model.text("取消", "Cancel")) { dismiss() }.keyboardShortcut(.cancelAction); Button(model.text("保存", "Save")) { model.saveProfile(name: name, points: points); dismiss() }.buttonStyle(.borderedProminent).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (try? FanCurve(points: points).validate()) == nil) } }.padding(24).frame(width: 580) }
}

struct DiagnosticsView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        Panel(title: model.text("这台 Mac", "This Mac"), symbol: "desktopcomputer") {
            HStack(spacing: 24) { Image(systemName: "laptopcomputer").font(.system(size: 65, weight: .ultraLight)).foregroundStyle(.teal); VStack(alignment: .leading, spacing: 7) { Text(model.snapshot.chipName).font(.title2.weight(.semibold)); Text(model.snapshot.hardwareModel).foregroundStyle(.secondary); Text(ProcessInfo.processInfo.operatingSystemVersionString).font(.caption).foregroundStyle(.secondary) }; Spacer() }
            Divider()
            LabeledContent(model.text("运行时间", "Uptime"), value: Duration.seconds(model.snapshot.uptime).formatted(.units(allowed: [.days, .hours, .minutes], width: .abbreviated)))
            LabeledContent(model.text("系统温控状态", "System thermal state"), value: model.snapshot.thermalState)
            LabeledContent(model.text("SMC 接口", "SMC interface"), value: model.snapshot.smcStatus)
            LabeledContent(model.text("温度 / 风扇", "Sensors / fans"), value: "\(model.snapshot.temperatures.count) / \(model.snapshot.fans.count)")
            LabeledContent(model.text("辅助服务", "Control helper"), value: model.helperMessage)
        }
        Banner(symbol: "lock.shield", title: model.text("可审查的权限边界", "An auditable permission boundary"), detail: model.text("主应用以普通用户运行。可选辅助服务仅接受状态查询、指定风扇转速和恢复自动三类指令，不执行任意命令。未安装时仍可完整使用监控功能。", "The app runs as your user. The optional helper accepts only status, fan RPM and restore-automatic commands. Monitoring works without it."))
        Panel(title: model.text("支持与开源", "Support & open source"), symbol: "curlybraces") {
            Text(model.text("v0.1.0 · MIT License · 完全开源", "v0.1.0 · MIT License · Fully open source")).font(.headline)
            Text(model.text("这是独立实现的首个预览版本。SMC 接口未公开，不同机型可读和可控的范围会变化。通用温度标识保留原始 SMC 名称；尚未验证的型号不会被宣称完整支持。", "This is an independent first preview. SMC is undocumented and hardware support varies. Generic sensors retain their raw SMC key; untested models are not claimed as fully supported.")).font(.callout).foregroundStyle(.secondary)
            HStack { Link(model.text("查看源码", "Source Code"), destination: URL(string: "https://github.com/Hughhhhcoder/mac-control-pro")!); Link(model.text("报告问题", "Report an Issue"), destination: URL(string: "https://github.com/Hughhhhcoder/mac-control-pro/issues/new/choose")!); Spacer(); Button(model.text("导出诊断…", "Export Diagnostics…"), action: model.exportDiagnostics).buttonStyle(.borderedProminent) }
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        Form {
            Section(model.text("通用", "General")) {
                Picker(model.text("界面语言", "Language"), selection: $model.language) { Text("简体中文").tag("zh"); Text("English").tag("en") }
                Toggle(model.text("登录时启动", "Launch at login"), isOn: Binding(get: { model.loginEnabled }, set: model.setLogin))
                Picker(model.text("温度单位", "Temperature unit"), selection: $model.fahrenheit) { Text("Celsius · °C").tag(false); Text("Fahrenheit · °F").tag(true) }
                Picker(model.text("采样间隔", "Sampling interval"), selection: $model.interval) { Text("1 s").tag(1.0); Text("2 s").tag(2.0); Text("5 s").tag(5.0) }
            }
            Section(model.text("散热与自动化", "Cooling & automation")) {
                Toggle(model.text("电源接入时启用均衡曲线，断开时恢复自动", "Apply Balanced on AC connection; restore on battery"), isOn: $model.autoProfileOnAC)
                Text(model.text("此规则默认关闭，需要安装辅助服务；仅在电源状态发生变化时触发。", "Off by default. Requires the optional helper and triggers only when the power source changes.")).font(.caption).foregroundStyle(.secondary)
                LabeledContent(model.text("辅助服务状态", "Helper status"), value: model.helperAvailable ? model.text("在线", "Connected") : model.text("未连接", "Disconnected"))
                Button(model.text("查看安装与卸载指南…", "Installation & Removal Guide…"), action: model.openGuide)
            }
            Section(model.text("预览与数据", "Preview & data")) {
                Toggle(model.text("演示模式（示例数据）", "Demo mode (sample data)"), isOn: Binding(get: { model.demo }, set: model.setDemo))
                Text(model.text("演示模式不会向硬件发送控制指令。切换模式会清空会话历史，并释放现有控制。", "Demo mode sends no hardware control commands. Switching clears session history and releases existing control.")).font(.caption).foregroundStyle(.secondary)
                Button(model.text("导出当前诊断…", "Export Current Diagnostics…"), action: model.exportDiagnostics)
            }
        }.formStyle(.grouped).padding().frame(width: 600, height: 520).tint(.teal)
    }
}

struct CurveEditor: View {
    @EnvironmentObject var model: AppModel
    @Binding var points: [FanCurvePoint]
    var body: some View {
        VStack(spacing: 12) {
            Chart(Array(points.enumerated()), id: \.offset) { _, point in LineMark(x: .value("°C", point.temperature), y: .value("RPM", point.rpm)).foregroundStyle(.teal); PointMark(x: .value("°C", point.temperature), y: .value("RPM", point.rpm)).foregroundStyle(.teal) }.chartXAxisLabel("°C").chartYAxisLabel("RPM").frame(height: 130)
            HStack { Text(model.text("温度 (°C)", "Temperature (°C)")); Spacer(); Text(model.text("目标转速 (RPM)", "Target speed (RPM)")) }.font(.caption).foregroundStyle(.secondary)
            ForEach(points.indices, id: \.self) { index in
                HStack {
                    TextField("°C", value: $points[index].temperature, format: .number.precision(.fractionLength(0))).frame(width: 110)
                    Spacer(); Image(systemName: "arrow.right").foregroundStyle(.tertiary); Spacer()
                    TextField("RPM", value: $points[index].rpm, format: .number.precision(.fractionLength(0))).frame(width: 130)
                    Button { points.remove(at: index) } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless).disabled(points.count <= 2)
                }
            }
            HStack { Button { if let last = points.last { points.append(.init(temperature: min(120, last.temperature + 5), rpm: min(20000, last.rpm + 500))) } } label: { Label(model.text("添加节点", "Add Point"), systemImage: "plus.circle") }.disabled(points.count >= 12); Spacer(); if (try? FanCurve(points: points).validate()) == nil { Text(model.text("温度须严格递增，转速不得下降", "Temperature must rise; RPM cannot decrease")).foregroundStyle(.orange).font(.caption) } }
        }
    }
}
