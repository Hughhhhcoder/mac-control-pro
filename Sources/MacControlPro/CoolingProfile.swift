import Foundation
import MacControlCore

/// Existing absolute-RPM profiles remain readable; portable presets use each fan's own range.
struct CoolingProfile: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var symbol: String
    var points: [FanCurvePoint]
    var usesPercent: Bool? = nil
    var isPercentage: Bool { usesPercent == true }

    static let builtIns: [CoolingProfile] = [
        .init(name: "均衡", symbol: "scale.3d", points: [.init(temperature: 35, rpm: 0), .init(temperature: 50, rpm: 20), .init(temperature: 65, rpm: 55), .init(temperature: 80, rpm: 100)], usesPercent: true),
        .init(name: "提前散热", symbol: "snowflake", points: [.init(temperature: 35, rpm: 15), .init(temperature: 45, rpm: 35), .init(temperature: 60, rpm: 70), .init(temperature: 78, rpm: 100)], usesPercent: true),
        .init(name: "持续负载", symbol: "bolt.fill", points: [.init(temperature: 35, rpm: 25), .init(temperature: 45, rpm: 45), .init(temperature: 60, rpm: 75), .init(temperature: 75, rpm: 100)], usesPercent: true)
    ]
    func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 80, (2...12).contains(points.count) else { throw CocoaError(.fileReadCorruptFile) }
        try FanCurve(points: points).validate()
        if isPercentage, !points.allSatisfy({ (0...100).contains($0.rpm) }) { throw CocoaError(.fileReadCorruptFile) }
    }
    func resolvedPoints(for fan: FanReading) -> [FanCurvePoint]? {
        guard let lower = fan.manualMinimumRPM, let upper = fan.maxRPM, upper >= lower, (try? validate()) != nil else { return nil }
        return points.map { point in
            let target = isPercentage ? lower + (upper-lower) * point.rpm/100 : point.rpm
            return .init(temperature: point.temperature, rpm: min(upper, max(lower, target)))
        }
    }
}
struct ProfileArchive: Codable {
    var schemaVersion: Int = 2
    var profiles: [CoolingProfile]
}
