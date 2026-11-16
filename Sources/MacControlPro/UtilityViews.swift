import AppKit
import Charts
import MacControlCore
import SwiftUI

struct ProfilesView: View {
    @EnvironmentObject var model: AppModel
    @State private var creating = false
    @State private var applying: UUID?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text(model.text("预设与自定义", "Presets & custom curves")).font(.title3.weight(.semibold)); Spacer(); Button(model.text("导入…", "Import…"), action: model.importProfiles); Button(model.text("导出…", "Export…"), action: model.exportProfiles); Button { creating = true } label: { Label(model.text("新建配置", "New Profile"), systemImage: "plus") }.buttonStyle(.borderedProminent) }
            if model.globalControlNotice != nil || !model.helperAvailable { HelperSetupPanel() }
            ForEach(model.allProfiles) { profile in
                Panel(title: model.profileName(profile), symbol: profile.symbol) {
                    HStack { Label(profile.usesPercent == true ? model.text("按每只风扇的硬件范围适配", "Adapts to each fan's hardware range") : model.text("绝对转速曲线", "Absolute RPM curve"), systemImage: profile.usesPercent == true ? "arrow.left.and.right" : "speedometer").font(.caption).foregroundStyle(.secondary); Spacer() }
                    Chart(Array(profile.points.enumerated()), id: \.offset) { _, point in LineMark(x: .value("°C", point.temperature), y: .value("Speed", point.rpm)).foregroundStyle(.teal); PointMark(x: .value("°C", point.temperature), y: .value("Speed", point.rpm)).foregroundStyle(.teal) }.chartXAxisLabel("°C").chartYAxisLabel(profile.usesPercent == true ? "%" : "RPM").frame(height: 100)
                    HStack {
                        Text(model.text("\(profile.points.count) 个节点", "\(profile.points.count) points")).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if model.profiles.contains(where: { $0.id == profile.id }) { Button(role: .destructive) { model.deleteProfile(profile) } label: { Image(systemName: "trash") }.buttonStyle(.borderless) }
                        if applying == profile.id { ProgressView().controlSize(.small) }
                        Button(applying == profile.id ? model.text("正在应用…", "Applying…") : model.text("应用至可控风扇", "Apply to Controllable Fans")) { applying = profile.id; Task { await model.applyProfile(profile); applying = nil } }.buttonStyle(.bordered).disabled(applying != nil || model.snapshot.fans.isEmpty || model.globalControlNotice != nil)
                    }
                }
            }
            Banner(symbol: "info.circle", title: model.text("适合不同 Mac 的配置", "Profiles for different Macs"), detail: model.text("内置预设使用转速范围百分比，不把笔记本的固定 RPM 直接套给 Mac mini 或 Mac Studio。自定义配置支持百分比或 RPM；温度节点始终使用 °C。", "Built-in presets use percentages of each fan's range. Custom profiles can use percent or RPM. Temperature points always use °C."))
        }.sheet(isPresented: $creating) { NewProfileView() }
    }
}
struct NewProfileView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var points = CoolingProfile.builtIns[0].points
    @State private var percent = true
    private var valid: Bool { !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (try? CoolingProfile(name: name, symbol: "slider.horizontal.3", points: points, usesPercent: percent).validate()) != nil }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(model.text("创建散热配置", "Create a Cooling Profile")).font(.title2.bold())
            TextField(model.text("配置名称", "Profile name"), text: $name)
            Picker(model.text("转速单位", "Speed unit"), selection: $percent) { Text(model.text("硬件范围百分比", "Percent of hardware range")).tag(true); Text("RPM").tag(false) }.pickerStyle(.segmented)
            CurveEditor(points: $points, usesPercent: percent)
            HStack { Spacer(); Button(model.text("取消", "Cancel")) { dismiss() }.keyboardShortcut(.cancelAction); Button(model.text("保存", "Save")) { model.saveProfile(name: name, points: points, usesPercent: percent); dismiss() }.buttonStyle(.borderedProminent).disabled(!valid) }
        }.padding(24).frame(width: 580)
        .onChange(of: percent) { _, value in
            if value { points = CoolingProfile.builtIns[0].points }
            else if let fan = model.snapshot.fans.first, let adapted = CoolingProfile.builtIns[0].resolvedPoints(for: fan) { points = adapted }
            else { points = [.init(temperature: 35, rpm: 2000), .init(temperature: 80, rpm: 5000)] }
        }
    }
}

struct DiagnosticsView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        Panel(title: model.text("这台 Mac", "This Mac"), symbol: "desktopcomputer") {
            HStack(spacing: 24) { Image(systemName: "desktopcomputer").font(.system(size: 60, weight: .ultraLight)).foregroundStyle(.teal); VStack(alignment: .leading, spacing: 7) { Text(model.snapshot.chipName).font(.title2.weight(.semibold)); Text(model.snapshot.hardwareModel).foregroundStyle(.secondary); Text(ProcessInfo.processInfo.operatingSystemVersionString).font(.caption).foregroundStyle(.secondary) }; Spacer() }
            Divider()
            LabeledContent(model.text("运行时间", "Uptime"), value: Duration.seconds(model.snapshot.uptime).formatted(.units(allowed: [.days,.hours,.minutes], width: .abbreviated)))
            LabeledContent(model.text("系统温控状态", "System thermal state"), value: model.snapshot.thermalState)
            LabeledContent(model.text("SMC 接口", "SMC interface"), value: model.snapshot.smcStatus)
            LabeledContent(model.text("风扇数量", "Fan count"), value: model.reportedFanSummary)
            LabeledContent(model.text("当前温度传感器", "Temperature sensors"), value: "\(model.snapshot.temperatures.count)")
            if let detail = model.snapshot.fanDiscoveryMessage { Text(detail).font(.caption).foregroundStyle(.secondary) }
        }
        Panel(title: model.text("控制助手与兼容性", "Control Helper & Compatibility"), symbol: "checkmark.shield") {
            LabeledContent(model.text("状态", "Status"), value: model.helperMessage)
            LabeledContent(model.text("应用 / 助手版本", "App / helper version"), value: "\(model.version) / \(model.helperResponse?.helperVersion ?? "—")")
            LabeledContent(model.text("控制协议", "Control protocol"), value: "\(model.helperResponse?.protocolVersion.map(String.init) ?? "—") / \(AppModel.requiredProtocolVersion)")
            if let limit = model.helperResponse?.temperatureLimitCelsius { LabeledContent(model.text("控制保护阈值", "Control protection limit"), value: model.temperature(limit)) }
            if let reason = model.helperResponse?.lastRecoveryReason { LabeledContent(model.text("最近恢复自动原因", "Last automatic recovery"), value: model.localizedReason(code: model.helperResponse?.lastRecoveryCode?.rawValue, fallback: reason)) }
            ForEach(model.snapshot.fans) { fan in
                Divider()
                HStack { Text(fan.name).font(.subheadline.weight(.semibold)); Spacer(); Text(fan.canRequestControl ? model.text("已识别控制键", "Control keys detected") : model.text("当前仅监控", "Monitoring only")).font(.caption).foregroundStyle(fan.canRequestControl ? .teal : .orange) }
                Text(fan.controlIssue ?? [fan.modeKey,fan.targetKey].compactMap { $0 }.joined(separator: " · ")).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            HStack { if model.needsHelperSetup { Button(model.text("安装 / 更新控制助手…", "Install / Update Helper…"), action: model.openHelperInstaller).buttonStyle(.borderedProminent) }; Button(model.text("复制排障信息", "Copy Support Details"), action: model.copySupportDetails); Button(model.text("重新检测", "Check Again"), action: model.checkServiceNow) }
        }
        Panel(title: model.text("支持与开源", "Support & Open Source"), symbol: "curlybraces") {
            Text(model.text("v\(model.version) · MIT License · 完全开源", "v\(model.version) · MIT License · Fully open source")).font(.headline)
            Text(model.text("按硬件实际能力识别风扇数量、范围和控制键。不同型号的风扇可以不同；无风扇设备不显示虚构风扇。已支持的接口路径与实机验证范围分别记录。", "Fan count, bounds and control keys are discovered from hardware. Fanless devices are not given synthetic fans. Implemented interface paths and physical validation are documented separately.")).foregroundStyle(.secondary).font(.callout)
            HStack { Link(model.text("查看源码", "Source Code"), destination: URL(string: "https://github.com/Hughhhhcoder/mac-control-pro")!); Link(model.text("兼容性记录", "Compatibility"), destination: URL(string: "https://github.com/Hughhhhcoder/mac-control-pro/blob/main/docs/COMPATIBILITY.md")!); Spacer(); Button(model.text("导出诊断…", "Export Diagnostics…"), action: model.exportDiagnostics).buttonStyle(.bordered) }
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        Form {
            Section(model.text("通用", "General")) {
                Picker(model.text("界面语言", "Language"), selection: $model.language) { Text("简体中文").tag("zh"); Text("English").tag("en") }
                Toggle(model.text("登录时启动", "Launch at Login"), isOn: Binding(get: { model.loginEnabled }, set: model.setLogin))
                Picker(model.text("温度单位", "Temperature Unit"), selection: $model.fahrenheit) { Text("Celsius · °C").tag(false); Text("Fahrenheit · °F").tag(true) }
                Picker(model.text("采样间隔", "Sampling Interval"), selection: $model.interval) { Text("1 s").tag(1.0); Text("2 s").tag(2.0); Text("5 s").tag(5.0) }
            }
            Section(model.text("风扇控制助手", "Fan Control Helper")) {
                LabeledContent(model.text("状态", "Status"), value: model.helperMessage)
                Button(model.serviceCondition == .outdated ? model.text("更新控制助手…", "Update Control Helper…") : model.text("安装 / 修复控制助手…", "Install / Repair Control Helper…"), action: model.openHelperInstaller)
                Button(model.text("卸载控制助手…", "Remove Control Helper…"), action: model.openHelperUninstaller)
                Button(model.text("复制排障信息", "Copy Support Details"), action: model.copySupportDetails)
                Button(model.text("安装与卸载指南…", "Installation & Removal Guide…"), action: model.openGuide)
            }
            Section(model.text("散热与自动化", "Cooling & Automation")) {
                Toggle(model.text("接入电源时启用均衡曲线，断开时恢复自动", "Apply Balanced on AC Connection; Restore on Battery"), isOn: $model.autoProfileOnAC)
                Text(model.text("默认关闭；仅在电源来源改变时触发，不会在启动时自动接管风扇。", "Off by default. Triggers on power-source changes and never takes control at startup.")).font(.caption).foregroundStyle(.secondary)
            }
            Section(model.text("预览与数据", "Preview & Data")) {
                Toggle(model.text("演示模式（示例数据）", "Demo Mode (Sample Data)"), isOn: Binding(get: { model.demo }, set: model.setDemo))
                Text(model.text("演示模式不会控制硬件。切换模式会清空会话历史并释放现有控制。", "Demo mode never controls hardware. Switching clears history and releases control.")).font(.caption).foregroundStyle(.secondary)
                Button(model.text("导出诊断…", "Export Diagnostics…"), action: model.exportDiagnostics)
            }
        }.formStyle(.grouped).padding().frame(width: 620, height: 620).tint(.teal)
    }
}

struct CurveEditor: View {
    @EnvironmentObject var model: AppModel
    @Binding var points: [FanCurvePoint]
    var usesPercent = false
    private var valid: Bool { (try? FanCurve(points: points).validate()) != nil && (!usesPercent || points.allSatisfy { (0...100).contains($0.rpm) }) }
    var body: some View {
        VStack(spacing: 12) {
            Chart(Array(points.enumerated()), id: \.offset) { _, point in LineMark(x: .value("°C", point.temperature), y: .value("Speed", point.rpm)).foregroundStyle(.teal); PointMark(x: .value("°C", point.temperature), y: .value("Speed", point.rpm)).foregroundStyle(.teal) }.chartXAxisLabel("°C").chartYAxisLabel(usesPercent ? "%" : "RPM").frame(height: 130)
            HStack { Text(model.text("温度 (°C)", "Temperature (°C)")); Spacer(); Text(usesPercent ? model.text("转速范围 (%)", "Speed Range (%)") : model.text("目标转速 (RPM)", "Target Speed (RPM)")) }.font(.caption).foregroundStyle(.secondary)
            ForEach(points.indices, id: \.self) { index in
                HStack { TextField("°C", value: $points[index].temperature, format: .number.precision(.fractionLength(0))).frame(width: 110); Spacer(); Image(systemName: "arrow.right").foregroundStyle(.tertiary); Spacer(); TextField(usesPercent ? "%" : "RPM", value: $points[index].rpm, format: .number.precision(.fractionLength(0))).frame(width: 130); Button { points.remove(at: index) } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless).disabled(points.count <= 2) }
            }
            HStack { Button { if let last = points.last { points.append(.init(temperature: min(120, last.temperature+5), rpm: min(usesPercent ? 100 : 20000, last.rpm+(usesPercent ? 10 : 500)))) } } label: { Label(model.text("添加节点", "Add Point"), systemImage: "plus.circle") }.disabled(points.count >= 12); Spacer(); if !valid { Text(model.text("请检查递增节点和转速范围", "Check increasing points and speed bounds")).foregroundStyle(.orange).font(.caption) } }
        }
    }
}
