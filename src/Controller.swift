import Darwin
import Foundation

public enum ShayError: Error, CustomStringConvertible {
    case rootRequired
    case guardUnavailable
    case invalidExpiry
    case unsafe(String)
    case operation(String)

    public var description: String {
        switch self {
        case .rootRequired: return "this action requires root"
        case .guardUnavailable: return "safety daemon unavailable; refusing to enable"
        case .invalidExpiry: return "expiry must be in the future and no more than 365 days away"
        case .unsafe(let reason): return "refusing to enable: \(reason.replacingOccurrences(of: "_", with: " "))"
        case .operation(let message): return message
        }
    }
}

public final class ShayController {
    private let system: SystemProviding
    private let state: StateStore
    private let privileged: Bool

    public init(system: SystemProviding, state: StateStore, privileged: Bool) {
        self.system = system
        self.state = state
        self.privileged = privileged
    }

    public func enable(expiresAt: Int64? = nil) throws -> [String] {
        try requireRoot()
        guard system.guardLoaded() else { throw ShayError.guardUnavailable }
        return try state.withLock {
            try state.ensureDirectory()
            guard system.guardLoaded() else { throw ShayError.guardUnavailable }
            let now = system.now()
            if let expiresAt {
                guard expiresAt > now, expiresAt - now <= shayMaximumExpirySeconds else { throw ShayError.invalidExpiry }
            }
            switch safetyCheck() {
            case .safe: break
            case .unsafe(let reason): throw ShayError.unsafe(reason)
            }

            if let expiresAt {
                try state.write("expires_at", value: String(expiresAt))
            } else {
                try state.remove("expires_at")
            }
            try state.write("enabled", value: "enabled")
            guard system.setSleepDisabled(1) else {
                if system.setSleepDisabled(0) {
                    try state.remove("enabled")
                    try? state.remove("expires_at")
                    try? state.remove("last_check_epoch")
                    try state.write("last_reason", value: "enable_failed_safe")
                    throw ShayError.operation("enable failed; normal sleep was verified")
                }
                try state.write("last_reason", value: "enable_failed_restore_pending")
                system.log("ERROR: enable failed and normal sleep could not be verified; guard remains armed")
                throw ShayError.operation("enable failed and rollback is unverified; guard remains armed")
            }

            try state.write("last_check_epoch", value: String(now))
            try state.write("last_reason", value: "active")
            return ["◆ shay online", "  guarded above \(shayBatteryCutoff)% battery · thermal below serious"]
        }
    }

    public func disable() throws -> [String] {
        try requireRoot()
        return try state.withLock {
            try state.ensureDirectory()
            guard system.setSleepDisabled(0) else {
                try state.write("last_reason", value: "manual_restore_failed")
                throw ShayError.operation("failed to restore normal sleep; guard remains armed")
            }
            try state.remove("enabled")
            try? state.remove("expires_at")
            try? state.remove("last_check_epoch")
            try state.write("last_reason", value: "manual_off")
            return ["◇ shay offline", "  normal macOS sleep restored"]
        }
    }

    public func guardOnce() throws {
        try requireRoot()
        guard state.enabled else { return }
        try state.withLock {
            guard state.enabled else { return }
            if let expiryReason = expiryReason() {
                try restoreFromGuard(reason: expiryReason)
                return
            }
            switch safetyCheck() {
            case .unsafe(let reason):
                try restoreFromGuard(reason: reason)
            case .safe:
                if system.sleepDisabled() != 1 {
                    guard system.setSleepDisabled(1) else {
                        try state.write("last_reason", value: "reassert_failed")
                        system.log("ERROR: failed to reassert SleepDisabled")
                        throw ShayError.operation("failed to reassert SleepDisabled")
                    }
                    try state.write("last_reason", value: "active_reasserted")
                }
                try state.write("last_check_epoch", value: String(system.now()))
            }
        }
    }

    public func status(color: Bool) -> String {
        let heartbeat = state.read("last_check_epoch").flatMap(Int64.init)
        let expiryConfigured = state.contains("expires_at")
        let expiresAt = state.read("expires_at").flatMap(Int64.init)
        let snapshot = StatusSnapshot(
            desiredOn: state.enabled,
            actual: system.sleepDisabled(),
            power: system.powerSnapshot(),
            thermal: system.thermalLevel(),
            reason: state.read("last_reason") ?? "never",
            guardLoaded: system.guardLoaded(),
            heartbeat: heartbeat,
            expiresAt: expiresAt,
            expiryConfigured: expiryConfigured,
            now: system.now()
        )
        return StatusRenderer().render(snapshot, color: color)
    }

    private func requireRoot() throws {
        guard privileged else { throw ShayError.rootRequired }
    }

    private func safetyCheck() -> SafetyResult {
        let power = system.powerSnapshot()
        return SafetyResult.evaluate(battery: power.batteryPercent, thermal: system.thermalLevel())
    }

    private func expiryReason() -> String? {
        guard state.contains("expires_at") else { return nil }
        guard let raw = state.read("expires_at"), let deadline = Int64(raw), deadline > 0 else {
            return "expiry_reading_unavailable"
        }
        return system.now() >= deadline ? "expired" : nil
    }

    private func restoreFromGuard(reason: String) throws {
        guard system.setSleepDisabled(0) else {
            try state.write("last_reason", value: "restore_failed_\(reason)")
            system.log("ERROR: failed to restore sleep after: \(reason)")
            throw ShayError.operation("failed to restore normal sleep")
        }
        try state.remove("enabled")
        try? state.remove("expires_at")
        try? state.remove("last_check_epoch")
        try state.write("last_reason", value: reason)
        system.log("safety guard restored sleep: \(reason)")
    }
}
