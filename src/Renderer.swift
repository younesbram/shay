import Foundation

public struct StatusSnapshot {
    public let desiredOn: Bool
    public let actual: Int?
    public let power: PowerSnapshot
    public let thermal: ThermalLevel?
    public let reason: String
    public let guardLoaded: Bool
    public let heartbeat: Int64?
    public let expiresAt: Int64?
    public let expiryConfigured: Bool
    public let now: Int64

    public init(desiredOn: Bool, actual: Int?, power: PowerSnapshot, thermal: ThermalLevel?, reason: String, guardLoaded: Bool, heartbeat: Int64?, expiresAt: Int64? = nil, expiryConfigured: Bool = false, now: Int64) {
        self.desiredOn = desiredOn
        self.actual = actual
        self.power = power
        self.thermal = thermal
        self.reason = reason
        self.guardLoaded = guardLoaded
        self.heartbeat = heartbeat
        self.expiresAt = expiresAt
        self.expiryConfigured = expiryConfigured
        self.now = now
    }
}

public struct StatusRenderer {
    private struct Palette {
        let reset: String
        let bold: String
        let dim: String
        let cyan: String
        let green: String
        let yellow: String
        let red: String

        static let plain = Palette(reset: "", bold: "", dim: "", cyan: "", green: "", yellow: "", red: "")
        static let color = Palette(reset: "\u{001B}[0m", bold: "\u{001B}[1m", dim: "\u{001B}[2m", cyan: "\u{001B}[38;5;81m", green: "\u{001B}[38;5;84m", yellow: "\u{001B}[38;5;220m", red: "\u{001B}[38;5;203m")
    }

    public init() {}

    public func render(_ snapshot: StatusSnapshot, color: Bool) -> String {
        let p = color ? Palette.color : Palette.plain
        let state: String
        let stateColor: String
        if snapshot.desiredOn && snapshot.actual == 1 {
            state = "ONLINE"; stateColor = p.green
        } else if !snapshot.desiredOn && snapshot.actual == 0 {
            state = "OFFLINE"; stateColor = p.dim
        } else {
            state = "DEGRADED"; stateColor = p.red
        }

        let sleepText: String
        let sleepColor: String
        switch snapshot.actual {
        case 1: sleepText = "disabled · awake"; sleepColor = p.green
        case 0: sleepText = "enabled · normal"; sleepColor = p.cyan
        default: sleepText = "unknown"; sleepColor = p.red
        }

        let battery = snapshot.power.batteryPercent
        let batteryColor: String
        if let battery, battery > 40 { batteryColor = p.green }
        else if let battery, battery > shayBatteryCutoff { batteryColor = p.yellow }
        else { batteryColor = p.red }

        let thermalColor: String
        switch snapshot.thermal {
        case .nominal: thermalColor = p.green
        case .fair: thermalColor = p.yellow
        default: thermalColor = p.red
        }

        let watchdog: String
        let watchdogColor: String
        if !snapshot.guardLoaded {
            watchdog = "unavailable"; watchdogColor = p.red
        } else if !snapshot.desiredOn {
            watchdog = "armed · checks every 15s"; watchdogColor = p.cyan
        } else if let heartbeat = snapshot.heartbeat, snapshot.now >= heartbeat {
            let age = snapshot.now - heartbeat
            if age <= shayGuardStaleSeconds {
                watchdog = "healthy · \(age)s ago"; watchdogColor = p.green
            } else {
                watchdog = "stale · \(age)s ago"; watchdogColor = p.red
            }
        } else if snapshot.heartbeat == nil {
            watchdog = "starting"; watchdogColor = p.yellow
        } else {
            watchdog = "invalid heartbeat"; watchdogColor = p.red
        }

        let face: String
        let artColor: String
        switch state {
        case "ONLINE": face = "O.O"; artColor = p.green
        case "OFFLINE": face = "-_-"; artColor = p.dim
        default: face = "!.!"; artColor = p.red
        }

        let art = [
            "╔════════════╗",
            "║ ┌────────┐ ║",
            "║ │  \(face)   │ ║",
            "║ └────────┘ ║",
            "╚════════════╝",
            "",
            "",
            "",
            "",
        ]

        let source = snapshot.power.source ?? "unknown"
        let percent = battery.map { "\($0)%" } ?? "unknown"
        let thermal = snapshot.thermal?.label ?? "unknown"
        let reason = snapshot.reason.replacingOccurrences(of: "_", with: " ")
        let expiry: String
        let expiryColor: String
        if snapshot.expiryConfigured, let expiresAt = snapshot.expiresAt {
            let remaining = expiresAt - snapshot.now
            expiry = remaining > 0 ? Self.remainingTime(remaining) : "due"
            expiryColor = remaining <= 0 ? p.red : (remaining <= 3600 ? p.yellow : p.cyan)
        } else if snapshot.expiryConfigured {
            expiry = "invalid"
            expiryColor = p.red
        } else {
            expiry = "never"
            expiryColor = p.dim
        }

        var lines: [String] = []
        append(&lines, visible: "  ◆ shay      ● \(state)", rendered: "  \(p.cyan)◆\(p.reset) \(p.bold)shay\(p.reset)      \(stateColor)● \(state)\(p.reset)", art: art[0], artColor: artColor, reset: p.reset)
        append(&lines, visible: "  ────────────────────────────────────────", rendered: "  \(p.dim)────────────────────────────────────────\(p.reset)", art: art[1], artColor: artColor, reset: p.reset)
        append(&lines, visible: "  Sleep       \(sleepText)", rendered: "  \(p.bold)Sleep\(p.reset)       \(sleepColor)\(sleepText)\(p.reset)", art: art[2], artColor: artColor, reset: p.reset)
        append(&lines, visible: "  Power       \(source) · \(percent)", rendered: "  \(p.bold)Power\(p.reset)       \(batteryColor)\(source) · \(percent)\(p.reset)", art: art[3], artColor: artColor, reset: p.reset)
        append(&lines, visible: "  Thermal     \(thermal)", rendered: "  \(p.bold)Thermal\(p.reset)     \(thermalColor)\(thermal)\(p.reset)", art: art[4], artColor: artColor, reset: p.reset)
        append(&lines, visible: "  Guard       ≤\(shayBatteryCutoff)% battery · serious+ thermal", rendered: "  \(p.bold)Guard\(p.reset)       ≤\(shayBatteryCutoff)% battery · serious+ thermal", art: art[5], artColor: artColor, reset: p.reset)
        append(&lines, visible: "  Expiry      \(expiry)", rendered: "  \(p.bold)Expiry\(p.reset)      \(expiryColor)\(expiry)\(p.reset)", art: art[6], artColor: artColor, reset: p.reset)
        append(&lines, visible: "  Watchdog    \(watchdog)", rendered: "  \(p.bold)Watchdog\(p.reset)    \(watchdogColor)\(watchdog)\(p.reset)", art: art[7], artColor: artColor, reset: p.reset)
        append(&lines, visible: "  Last event  \(reason)", rendered: "  \(p.bold)Last event\(p.reset)  \(p.dim)\(reason)\(p.reset)", art: art[8], artColor: artColor, reset: p.reset)
        return lines.joined(separator: "\n")
    }

    private static func remainingTime(_ seconds: Int64) -> String {
        let minutes = max(1, (seconds + 59) / 60)
        let days = minutes / (24 * 60)
        let hours = (minutes % (24 * 60)) / 60
        let mins = minutes % 60
        if days > 0 { return hours > 0 ? "\(days)d \(hours)h" : "\(days)d" }
        if hours > 0 { return mins > 0 ? "\(hours)h \(mins)m" : "\(hours)h" }
        return "\(mins)m"
    }

    private func append(_ lines: inout [String], visible: String, rendered: String, art: String, artColor: String, reset: String) {
        guard !art.isEmpty else {
            lines.append(rendered)
            return
        }
        let padding = max(2, 56 - visible.count)
        lines.append(rendered + String(repeating: " ", count: padding) + artColor + art + reset)
    }
}
