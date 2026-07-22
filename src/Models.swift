import Foundation

public let shayProtocolVersion = 5
public let shayVersion = "0.2.0-alpha.3"
public let shayBatteryCutoff = 25
public let shayGuardStaleSeconds: Int64 = 45
public let shayMaximumExpirySeconds: Int64 = 365 * 24 * 60 * 60

public enum ThermalLevel: Int, Equatable, Sendable {
    case nominal = 0
    case fair = 1
    case serious = 2
    case critical = 3

    public var label: String {
        switch self {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        }
    }
}

public struct PowerSnapshot: Equatable, Sendable {
    public let source: String?
    public let batteryPercent: Int?

    public init(source: String?, batteryPercent: Int?) {
        self.source = source
        self.batteryPercent = batteryPercent
    }
}

public enum SafetyResult: Equatable, Sendable {
    case safe
    case unsafe(String)

    public static func evaluate(battery: Int?, thermal: ThermalLevel?) -> SafetyResult {
        guard let battery, (0...100).contains(battery) else {
            return .unsafe("battery_reading_unavailable")
        }
        guard battery > shayBatteryCutoff else {
            return .unsafe("battery_\(battery)_percent")
        }
        guard let thermal else {
            return .unsafe("thermal_reading_unavailable")
        }
        guard thermal.rawValue < ThermalLevel.serious.rawValue else {
            return .unsafe("thermal_\(thermal.label)")
        }
        return .safe
    }
}

public enum ExpiryParser {
    public static func duration(_ input: String, now: Int64) -> Int64? {
        guard input.count >= 2, let unit = input.last else { return nil }
        let number = input.dropLast()
        guard number.allSatisfy(\.isNumber), let amount = Int64(number), amount > 0 else { return nil }

        let multiplier: Int64
        switch unit {
        case "m": multiplier = 60
        case "h": multiplier = 60 * 60
        case "d": multiplier = 24 * 60 * 60
        default: return nil
        }

        let (seconds, multiplyOverflow) = amount.multipliedReportingOverflow(by: multiplier)
        guard !multiplyOverflow, seconds <= shayMaximumExpirySeconds else { return nil }
        let (deadline, addOverflow) = now.addingReportingOverflow(seconds)
        return addOverflow ? nil : deadline
    }

    public static func wallClock(_ input: String, now: Date, calendar: Calendar = .current) -> Int64? {
        let fields = input.split(separator: ":", omittingEmptySubsequences: false)
        guard fields.count == 2,
              fields[0].count == 2,
              fields[1].count == 2,
              fields[0].allSatisfy(\.isNumber),
              fields[1].allSatisfy(\.isNumber),
              let hour = Int(fields[0]), (0...23).contains(hour),
              let minute = Int(fields[1]), (0...59).contains(minute) else { return nil }

        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.hour = hour
        components.minute = minute
        components.second = 0
        guard var candidate = calendar.date(from: components) else { return nil }
        if candidate <= now {
            guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: candidate) else { return nil }
            candidate = tomorrow
        }

        let deadline = Int64(candidate.timeIntervalSince1970)
        let current = Int64(now.timeIntervalSince1970)
        guard deadline > current, deadline - current <= shayMaximumExpirySeconds else { return nil }
        return deadline
    }
}

public enum ShayParser {
    public static func power(_ output: String) -> PowerSnapshot {
        let source: String?
        if let range = output.range(of: #"Now drawing from '([^']+)'"#, options: .regularExpression) {
            let match = String(output[range])
            source = match.dropFirst("Now drawing from '".count).dropLast().description
        } else {
            source = nil
        }

        var percent: Int?
        if let range = output.range(of: #"(?:^|\s)([0-9]{1,3})%;"#, options: .regularExpression) {
            let token = output[range].split(whereSeparator: { !$0.isNumber }).first
            if let token, let value = Int(token), (0...100).contains(value) {
                percent = value
            }
        }
        return PowerSnapshot(source: source, batteryPercent: percent)
    }

    public static func sleepDisabled(_ output: String) -> Int? {
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace)
            if fields.count == 2, fields[0] == "SleepDisabled", let value = Int(fields[1]), value == 0 || value == 1 {
                return value
            }
        }
        return nil
    }

    public static func thermal(_ output: String) -> ThermalLevel? {
        let fields = output.split(whereSeparator: \.isWhitespace)
        guard fields.count == 2, let raw = Int(fields[0]), let level = ThermalLevel(rawValue: raw), fields[1] == Substring(level.label) else {
            return nil
        }
        return level
    }
}
