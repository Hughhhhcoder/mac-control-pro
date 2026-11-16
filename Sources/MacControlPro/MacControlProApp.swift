import AppKit
import MacControlCore
import SwiftUI

@main
struct MacControlProApp: App {
    @StateObject private var model: AppModel
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    init() {
        if ProcessInfo.processInfo.arguments.contains("--diagnose") {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
            if let data = try? encoder.encode(HardwareMonitor().snapshot()) { FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data("\n".utf8)) }
            exit(0)
        }
        _model = StateObject(wrappedValue: AppModel())
    }
    var body: some Scene {
        WindowGroup("Mac Control Pro", id: "main") {
            ContentView().environmentObject(model)
                .onAppear { delegate.model = model; NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true) }
        }
        .defaultSize(width: 1140, height: 790)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .newItem) { Button(model.text("导出历史记录…", "Export History…"), action: model.exportCSV).keyboardShortcut("e", modifiers: [.command, .shift]) }
            CommandMenu(model.text("风扇", "Fans")) { Button(model.text("全部恢复自动", "Restore All to Automatic"), action: model.restoreAll).keyboardShortcut("0", modifiers: [.command, .shift]) }
        }
        MenuBarExtra {
            MenuPanel().environmentObject(model)
        } label: {
            Label(model.peakTemperature.map { model.temperature($0) } ?? "Mac", systemImage: "fan")
        }.menuBarExtraStyle(.window)
        Settings { SettingsView().environmentObject(model) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        Task { @MainActor in await model.finishControlSession(); sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

struct MenuPanel: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Label("Mac Control Pro", systemImage: "fan.fill").font(.headline); Spacer(); if model.demo { Text("DEMO").font(.caption).foregroundStyle(.orange) } }
            HStack(spacing: 24) {
                VStack(alignment: .leading) { Text(model.temperature(model.peakTemperature)).font(.title2.monospacedDigit()); Text(model.text("最高温度", "Peak temperature")).font(.caption).foregroundStyle(.secondary) }
                VStack(alignment: .leading) { Text(model.meanRPM.map { String(format: "%.0f RPM", $0) } ?? "—").font(.title2.monospacedDigit()); Text(model.text("平均转速", "Mean fan speed")).font(.caption).foregroundStyle(.secondary) }
            }
            Text(model.coolingSummary).font(.caption).foregroundStyle(.secondary)
            Divider()
            Button(model.text("打开控制中心", "Open Control Center")) { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }.buttonStyle(.borderedProminent).frame(maxWidth: .infinity)
            HStack { Button(model.text("恢复自动", "Restore Automatic"), action: model.restoreAll); Spacer(); SettingsLink { Image(systemName: "gearshape") }; Button(model.text("退出", "Quit")) { NSApp.terminate(nil) } }
        }.padding(20).frame(width: 320)
    }
}
