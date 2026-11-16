import Foundation
import MacControlCore

protocol HardwareSource: Sendable {
    func snapshot() -> SystemSnapshot
    @discardableResult func reconnect() -> Bool
}
extension HardwareMonitor: HardwareSource {}

protocol FanService: Sendable {
    func status() throws -> HelperResponse
    func set(fanID: Int, rpm: Double) throws -> HelperResponse
    func renew(fanID: Int, rpm: Double) throws -> HelperResponse
    func automatic(fanID: Int?) throws -> HelperResponse
    func release(fanID: Int?) throws -> HelperResponse
}
extension HelperClient: FanService {}

struct HistorySample: Identifiable {
    let id = UUID()
    let date: Date
    let cpu: Double?
    let temperature: Double?
    let rpm: Double?
}

struct FanPolicy {
    var rpm: Double?
    var points: [FanCurvePoint]?
    var sensorID: String?
}

enum FanActionPhase: String { case applying, waiting, active, restoring, failed }
struct FanAction {
    var phase: FanActionPhase
    var message: String
    var requestedRPM: Double?
}

enum ServiceCondition: Equatable {
    case checking, missing, otherUser, outdated, unavailable, ready
}

@MainActor extension AppModel {
    var coolingSummary: String {
        guard !snapshot.fans.isEmpty else { return snapshot.reportedFanCount == 0 ? text("无风扇设备", "Fanless device") : text("风扇状态不可用", "Fan state unavailable") }
        if fanActions.values.contains(where: { [.applying, .waiting, .restoring].contains($0.phase) }) { return text("正在确认风扇控制…", "Confirming fan control…") }
        if activeCount > 0 { return text("本应用正在控制 \(activeCount) 个风扇", "This app controls \(activeCount) fans") }
        if snapshot.fans.contains(where: \.isManual) { return text("检测到其他手动控制", "Other manual control detected") }
        if snapshot.fans.allSatisfy({ [0, 3].contains($0.modeRawValue ?? -1) }) { return text("系统自动散热", "Automatic cooling") }
        return text("风扇控制状态待确认", "Fan control state unconfirmed")
    }
}
