import Charts
import MacControlCore
import SwiftUI

enum Destination: String, CaseIterable, Identifiable {
    case overview, fans, sensors, history, profiles, diagnostics
    var id: String { rawValue }
    var chinese: String { ["overview":"总览", "fans":"风扇控制", "sensors":"温度传感器", "history":"历史趋势", "profiles":"散热配置", "diagnostics":"设备与诊断"][rawValue]! }
    var english: String { ["overview":"Overview", "fans":"Fan Control", "sensors":"Temperature Sensors", "history":"History", "profiles":"Cooling Profiles", "diagnostics":"Device & Diagnostics"][rawValue]! }
    var symbol: String { ["overview":"square.grid.2x2", "fans":"fan", "sensors":"thermometer.medium", "history":"chart.xyaxis.line", "profiles":"slider.horizontal.3", "diagnostics":"desktopcomputer"][rawValue]! }
    var subtitle: String { ["overview":"实时掌握 Mac 的运行状态", "fans":"让散热与你的工作节奏同步", "sensors":"查看硬件报告的温度读数", "history":"观察负载、温度与散热的变化", "profiles":"为不同工作场景保存散热曲线", "diagnostics":"了解硬件能力，导出可复现的诊断"][rawValue]! }
    var englishSubtitle: String { ["overview":"Your Mac, at a glance.", "fans":"Cooling that follows your workflow.", "sensors":"Temperature readings reported by your hardware.", "history":"Follow load, temperature and cooling over time.", "profiles":"Keep cooling curves for every workflow.", "diagnostics":"Understand hardware support and export diagnostics."][rawValue]! }
}

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var destination: Destination? = .overview
    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "fan.fill").font(.title2).foregroundStyle(.tint).frame(width: 40, height: 40).background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                    VStack(alignment: .leading, spacing: 3) { Text("Mac Control").font(.headline); Text("PRO · OPEN SOURCE").font(.system(size: 9, weight: .semibold, design: .rounded)).tracking(1.2).foregroundStyle(.secondary) }
                    Spacer(minLength: 0)
                }.padding(.horizontal, 20).padding(.vertical, 22)
                List(selection: $destination) {
                    Section(model.text("控制中心", "CONTROL CENTER")) {
                        ForEach(Destination.allCases) { item in Label(model.text(item.chinese, item.english), systemImage: item.symbol).tag(item).padding(.vertical, 5) }
                    }
                }.listStyle(.sidebar)
                VStack(alignment: .leading, spacing: 10) {
                    Divider()
                    Label(model.snapshot.chipName, systemImage: "cpu").font(.caption.weight(.medium)).lineLimit(1)
                    HStack { Circle().fill(model.demo ? .orange : .green).frame(width: 6, height: 6); Text(model.demo ? model.text("演示数据", "Demo data") : model.text("本机实时监控", "Live · on this Mac")).font(.caption).foregroundStyle(.secondary); Spacer() }
                    SettingsLink { Label(model.text("设置", "Settings"), systemImage: "gearshape").font(.caption) }.buttonStyle(.plain)
                }.padding(20)
            }.navigationSplitViewColumnWidth(min: 205, ideal: 225, max: 260)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 7) { Text(model.text(current.chinese, current.english)).font(.system(size: 29, weight: .bold)); Text(model.text(current.subtitle, current.englishSubtitle)).foregroundStyle(.secondary) }
                        Spacer()
                        Label(model.paused ? model.text("已暂停", "Paused") : model.text("实时", "Live"), systemImage: model.paused ? "pause.circle.fill" : "dot.radiowaves.left.and.right").font(.caption.weight(.medium)).foregroundStyle(model.paused ? .orange : .green).padding(.horizontal, 12).padding(.vertical, 8).background(.quaternary, in: Capsule())
                    }
                    if model.demo { Banner(symbol: "sparkles", title: model.text("当前为演示模式", "Demo mode is active"), detail: model.text("示例读数用于预览界面，所有硬件控制均已停用。", "Sample readings preview the interface. Hardware controls are disabled."), color: .orange) }
                    switch current {
                    case .overview: OverviewView()
                    case .fans: FansView()
                    case .sensors: SensorsView()
                    case .history: HistoryView()
                    case .profiles: ProfilesView()
                    case .diagnostics: DiagnosticsView()
                    }
                }.padding(30).frame(maxWidth: 1200, alignment: .leading).frame(maxWidth: .infinity)
            }.background(Color(nsColor: .windowBackgroundColor))
            .toolbar {
                ToolbarItemGroup { Button { model.setPaused(!model.paused) } label: { Image(systemName: model.paused ? "play" : "pause") }.help(model.text("暂停或继续采样", "Pause or resume sampling")); Button(action: model.exportCSV) { Label(model.text("导出", "Export"), systemImage: "square.and.arrow.up") } }
            }
        }.tint(.teal).frame(minWidth: 940, minHeight: 650)
        .alert(model.text("Mac Control Pro 提示", "Mac Control Pro"), isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) { Button(model.text("好", "OK")) { model.message = nil } } message: { Text(model.message ?? "") }
    }
    private var current: Destination { destination ?? .overview }
}

struct Panel<Content: View>: View {
    let title: String
    var symbol: String = ""
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if !title.isEmpty { HStack { if !symbol.isEmpty { Image(systemName: symbol).foregroundStyle(.teal) }; Text(title).font(.headline); Spacer() } }
            content
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16)).overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.primary.opacity(0.055)))
    }
}
struct Banner: View {
    let symbol: String; let title: String; let detail: String; var color: Color = .teal
    var body: some View { HStack(alignment: .top, spacing: 12) { Image(systemName: symbol).font(.title3).foregroundStyle(color); VStack(alignment: .leading, spacing: 5) { Text(title).font(.subheadline.weight(.semibold)); Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }; Spacer() }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(color.opacity(0.07), in: RoundedRectangle(cornerRadius: 12)) }
}
struct MetricCard: View {
    let title: String; let value: String; let detail: String; let symbol: String; let color: Color; var fraction: Double? = nil
    var body: some View { VStack(alignment: .leading, spacing: 15) { HStack { Image(systemName: symbol).foregroundStyle(color).font(.title3); Spacer(); Text(title).font(.caption).foregroundStyle(.secondary) }; Text(value).font(.system(size: 28, weight: .semibold, design: .rounded)).monospacedDigit().minimumScaleFactor(0.7).lineLimit(1); if let fraction { ProgressView(value: min(max(fraction, 0), 1)).tint(color) }; Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1) }.padding(18).frame(maxWidth: .infinity, minHeight: 145, alignment: .leading).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16)).overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.primary.opacity(0.055))) }
}

struct OverviewView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        LazyVGrid(columns: [.init(.flexible()), .init(.flexible()), .init(.flexible()), .init(.flexible())], spacing: 14) {
            MetricCard(title: model.text("最高温度", "Peak temperature"), value: model.temperature(model.peakTemperature), detail: model.hottestSensor?.name ?? model.text("传感器不可用", "Sensor unavailable"), symbol: "thermometer.medium", color: .orange)
            MetricCard(title: model.text("CPU 负载", "CPU load"), value: model.snapshot.cpuUsage.map { String(format: "%.0f%%", $0) } ?? "—", detail: model.text("所有核心合计", "Across all cores"), symbol: "cpu", color: .teal, fraction: model.snapshot.cpuUsage.map { $0/100 })
            MetricCard(title: model.text("内存占用", "Memory in use"), value: String(format: "%.1f GB", Double(model.snapshot.memoryUsedBytes)/1_073_741_824), detail: model.text("总计 ", "Total ") + String(format: "%.0f GB", Double(model.snapshot.memoryTotalBytes)/1_073_741_824), symbol: "memorychip", color: .purple, fraction: model.memoryFraction)
            MetricCard(title: model.text("平均转速", "Mean fan speed"), value: model.meanRPM.map { String(format: "%.0f", $0) } ?? "—", detail: model.text("RPM · \(model.snapshot.fans.count) 个风扇", "RPM · \(model.snapshot.fans.count) fans"), symbol: "fan", color: .blue)
        }
        Panel(title: model.text("温度趋势", "Temperature trend"), symbol: "waveform.path") {
            HStack(alignment: .firstTextBaseline, spacing: 8) { Text(model.temperature(model.peakTemperature)).font(.system(size: 32, weight: .medium, design: .rounded)).monospacedDigit(); Text(model.text("本次会话 · 最近 5 分钟", "This session · last 5 minutes")).font(.caption).foregroundStyle(.secondary); Spacer() }
            TrendChart(samples: model.history.filter { $0.date >= Date().addingTimeInterval(-300) }).frame(height: 165)
        }
        FansView(compact: true)
        HStack(spacing: 14) {
            Banner(symbol: "checkmark.shield", title: model.coolingSummary, detail: model.text("控制服务在通信超时、温度过高或传感器丢失时尝试恢复自动。", "The helper attempts to restore automatic mode on timeout, high temperature or sensor loss."))
            Banner(symbol: model.snapshot.isOnACPower == true ? "powerplug" : "battery.75percent", title: model.snapshot.isOnACPower == true ? model.text("已连接电源", "Power adapter") : model.text("电池供电 / 未知", "Battery / unavailable"), detail: model.snapshot.batteryPercent.map { model.text("电量 ", "Charge ") + String(format: "%.0f%%", $0) } ?? model.text("设备未报告电池状态", "Battery status is not reported"), color: .blue)
        }
    }
}

struct TrendChart: View {
    @EnvironmentObject var model: AppModel
    let samples: [HistorySample]
    var metric = "temperature"
    private func value(_ sample: HistorySample) -> Double? { metric == "cpu" ? sample.cpu : metric == "rpm" ? sample.rpm : sample.temperature.map(model.temperatureValue) }
    var body: some View {
        if samples.compactMap(value).isEmpty {
            ContentUnavailableView(model.text("暂无读数", "No readings yet"), systemImage: "chart.xyaxis.line", description: Text(model.text("设备未提供此项数据，或采样尚未完成。", "The device has not reported this metric yet.")))
        } else {
            Chart(samples) { sample in
                if let value = value(sample) {
                    AreaMark(x: .value("Time", sample.date), yStart: .value("Baseline", 0), yEnd: .value("Value", value)).foregroundStyle(LinearGradient(colors: [.teal.opacity(0.22), .teal.opacity(0.015)], startPoint: .top, endPoint: .bottom)).interpolationMethod(.linear)
                    LineMark(x: .value("Time", sample.date), y: .value("Value", value)).foregroundStyle(.teal).lineStyle(StrokeStyle(lineWidth: 2)).interpolationMethod(.linear)
                }
            }.chartXAxis { AxisMarks(values: .automatic(desiredCount: 5)) { _ in AxisGridLine().foregroundStyle(.primary.opacity(0.04)); AxisValueLabel(format: .dateTime.hour().minute().second()) } }.chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { _ in AxisGridLine().foregroundStyle(.primary.opacity(0.06)); AxisValueLabel() } }.chartYScale(domain: .automatic(includesZero: true))
        }
    }
}
