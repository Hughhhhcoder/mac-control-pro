import Foundation

public struct FanReading: Identifiable, Codable, Sendable {
    public var id: Int
    public var name: String
    public var currentRPM: Double
    public var minRPM: Double
    public var maxRPM: Double
    public var targetRPM: Double?
    public var isManual: Bool
    public init(id: Int, name: String, currentRPM: Double, minRPM: Double, maxRPM: Double, targetRPM: Double? = nil, isManual: Bool = false) {
        self.id = id; self.name = name; self.currentRPM = currentRPM; self.minRPM = minRPM; self.maxRPM = maxRPM; self.targetRPM = targetRPM; self.isManual = isManual
    }
}
public struct TemperatureReading: Identifiable, Codable, Sendable {
    public var id: String
    public var name: String
    public var celsius: Double
    public var category: String
    public init(id: String, name: String, celsius: Double, category: String) {
        self.id = id; self.name = name; self.celsius = celsius; self.category = category
    }
}
public struct SystemSnapshot: Codable, Sendable {
    public var date: Date
    public var cpuUsage: Double?
    public var memoryUsedBytes: UInt64
    public var memoryTotalBytes: UInt64
    public var batteryPercent: Double?
    public var isOnACPower: Bool?
    public var thermalState: String
    public var uptime: Double
    public var fans: [FanReading]
    public var temperatures: [TemperatureReading]
    public var hardwareModel: String
    public var chipName: String
    public var smcStatus: String
    public init(date: Date, cpuUsage: Double?, memoryUsedBytes: UInt64, memoryTotalBytes: UInt64, batteryPercent: Double?, isOnACPower: Bool?, thermalState: String, uptime: Double, fans: [FanReading], temperatures: [TemperatureReading], hardwareModel: String, chipName: String, smcStatus: String) {
        self.date = date; self.cpuUsage = cpuUsage; self.memoryUsedBytes = memoryUsedBytes; self.memoryTotalBytes = memoryTotalBytes; self.batteryPercent = batteryPercent; self.isOnACPower = isOnACPower; self.thermalState = thermalState; self.uptime = uptime; self.fans = fans; self.temperatures = temperatures; self.hardwareModel = hardwareModel; self.chipName = chipName; self.smcStatus = smcStatus
    }
}

public struct FanCurvePoint: Codable, Equatable, Sendable {
    public var temperature: Double
    public var rpm: Double
    public init(temperature: Double, rpm: Double) { self.temperature = temperature; self.rpm = rpm }
}
public enum FanCurveError: LocalizedError {
    case tooFewPoints, nonFinite, outOfRange, unsorted, decreasingSpeed
    public var errorDescription: String? {
        switch self {
        case .tooFewPoints: return "A curve needs at least two points."
        case .nonFinite: return "Curve values must be finite numbers."
        case .outOfRange: return "Temperature must be 0–120 °C and speed 0–20,000 RPM."
        case .unsorted: return "Temperatures must increase without duplicates."
        case .decreasingSpeed: return "Fan speed must not decrease as temperature rises."
        }
    }
}
public struct FanCurve: Codable, Equatable, Sendable {
    public var points: [FanCurvePoint]
    public init(points: [FanCurvePoint]) { self.points = points }
    public func validate() throws {
        guard points.count >= 2 else { throw FanCurveError.tooFewPoints }
        for (index, point) in points.enumerated() {
            guard point.temperature.isFinite, point.rpm.isFinite else { throw FanCurveError.nonFinite }
            guard (0...120).contains(point.temperature), (0...20_000).contains(point.rpm) else { throw FanCurveError.outOfRange }
            if index > 0 {
                guard point.temperature > points[index-1].temperature else { throw FanCurveError.unsorted }
                guard point.rpm >= points[index-1].rpm else { throw FanCurveError.decreasingSpeed }
            }
        }
    }
    public func rpm(at temperature: Double, minRPM: Double, maxRPM: Double) -> Double {
        // Invalid input cannot produce an arbitrary low speed: fail to the hardware maximum.
        guard maxRPM.isFinite, maxRPM > 0 else { return 0 }
        guard temperature.isFinite, minRPM.isFinite, minRPM >= 0, minRPM <= maxRPM,
              (try? validate()) != nil else { return maxRPM }
        let clamp: (Double) -> Double = { min(maxRPM, max(minRPM, $0)) }
        guard let first = points.first, let last = points.last else { return maxRPM }
        if temperature <= first.temperature { return clamp(first.rpm) }
        if temperature >= last.temperature { return clamp(last.rpm) }
        for index in 1..<points.count where temperature <= points[index].temperature {
            let left = points[index-1], right = points[index]
            let fraction = (temperature-left.temperature)/(right.temperature-left.temperature)
            return clamp(left.rpm + fraction*(right.rpm-left.rpm))
        }
        return maxRPM
    }
}
