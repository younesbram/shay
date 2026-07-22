import Darwin
import Foundation

private final class FakeSystem: SystemProviding {
    var power = PowerSnapshot(source: "Battery Power", batteryPercent: 80)
    var thermal: ThermalLevel? = .nominal
    var sleep: Int? = 0
    var loaded = true
    var timestamp: Int64 = 1_000
    var setOutcomes: [(reported: Bool, resultingState: Int?)] = []
    var logs: [String] = []

    func powerSnapshot() -> PowerSnapshot { power }
    func thermalLevel() -> ThermalLevel? { thermal }
    func sleepDisabled() -> Int? { sleep }
    func setSleepDisabled(_ value: Int) -> Bool {
        if !setOutcomes.isEmpty {
            let outcome = setOutcomes.removeFirst()
            sleep = outcome.resultingState
            return outcome.reported
        }
        sleep = value
        return true
    }
    func guardLoaded() -> Bool { loaded }
    func now() -> Int64 { timestamp }
    func log(_ message: String) { logs.append(message) }
}

@main
private struct NativeTests {
    static func main() throws {
        try parserTests()
        safetyTests()
        rendererTests()
        try controllerTests()
        print("native safety tests passed")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("native test failed: \(message)\n", stderr)
            exit(1)
        }
    }

    private static func parserTests() throws {
        let power = ShayParser.power("Now drawing from 'Battery Power'\n -InternalBattery-0 (id=1)\t41%; discharging")
        expect(power == PowerSnapshot(source: "Battery Power", batteryPercent: 41), "power parser")
        expect(ShayParser.power("Now drawing from 'AC Power'\nBattery 101%;").batteryPercent == nil, "reject impossible battery")
        expect(ShayParser.sleepDisabled(" System-wide power settings:\n SleepDisabled 1\n") == 1, "sleep parser")
        expect(ShayParser.sleepDisabled("SleepDisabled 2") == nil, "reject invalid sleep policy")
        expect(ShayParser.thermal("2 serious\n") == .serious, "thermal parser")
        expect(ShayParser.thermal("2 nominal") == nil, "thermal label consistency")

        expect(ExpiryParser.duration("30m", now: 1_000) == 2_800, "minute duration")
        expect(ExpiryParser.duration("4h", now: 1_000) == 15_400, "hour duration")
        expect(ExpiryParser.duration("2d", now: 1_000) == 173_800, "day duration")
        expect(ExpiryParser.duration("0m", now: 1_000) == nil, "reject zero duration")
        expect(ExpiryParser.duration("4hours", now: 1_000) == nil, "reject loose duration")
        expect(ExpiryParser.duration("366d", now: 1_000) == nil, "reject excessive duration")

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = calendar.date(from: DateComponents(year: 2026, month: 7, day: 22, hour: 22, minute: 30))!
        let sameDay = calendar.date(from: DateComponents(year: 2026, month: 7, day: 22, hour: 23, minute: 0))!
        let nextDay = calendar.date(from: DateComponents(year: 2026, month: 7, day: 23, hour: 21, minute: 0))!
        expect(ExpiryParser.wallClock("23:00", now: now, calendar: calendar) == Int64(sameDay.timeIntervalSince1970), "same-day wall clock")
        expect(ExpiryParser.wallClock("21:00", now: now, calendar: calendar) == Int64(nextDay.timeIntervalSince1970), "next-day wall clock")
        expect(ExpiryParser.wallClock("7:00", now: now, calendar: calendar) == nil, "require padded wall clock")
        expect(ExpiryParser.wallClock("24:00", now: now, calendar: calendar) == nil, "reject invalid wall clock")
    }

    private static func safetyTests() {
        expect(SafetyResult.evaluate(battery: 26, thermal: .fair) == .safe, "safe boundary")
        expect(SafetyResult.evaluate(battery: 25, thermal: .nominal) == .unsafe("battery_25_percent"), "battery cutoff")
        expect(SafetyResult.evaluate(battery: 80, thermal: .serious) == .unsafe("thermal_serious"), "thermal cutoff")
        expect(SafetyResult.evaluate(battery: nil, thermal: .nominal) == .unsafe("battery_reading_unavailable"), "battery fail closed")
        expect(SafetyResult.evaluate(battery: 80, thermal: nil) == .unsafe("thermal_reading_unavailable"), "thermal fail closed")
    }

    private static func rendererTests() {
        let base = StatusSnapshot(desiredOn: true, actual: 1, power: PowerSnapshot(source: "AC Power", batteryPercent: 90), thermal: .nominal, reason: "active", guardLoaded: true, heartbeat: 998, now: 1_000)
        let online = StatusRenderer().render(base, color: false)
        expect(online.contains("O.O") && online.contains("╔════════════╗") && online.contains("┌────────┐") && online.contains("healthy · 2s ago"), "online double-rectangle rendering")
        expect(!online.contains("\u{001B}["), "plain rendering")
        let artColumns = online.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            String(line.dropFirst(56).prefix(1))
        }
        expect(artColumns == ["╔", "║", "║", "║", "╚", "", "", "", ""], "fixed art column")
        expect(online.split(separator: "\n", omittingEmptySubsequences: false).allSatisfy { !$0.hasSuffix(" ") }, "no trailing status whitespace")
        let expiring = StatusSnapshot(desiredOn: true, actual: 1, power: base.power, thermal: .nominal, reason: "active", guardLoaded: true, heartbeat: 998, expiresAt: 1_600, expiryConfigured: true, now: 1_000)
        expect(StatusRenderer().render(expiring, color: false).contains("Expiry      10m"), "expiry rendering")
        expect(StatusRenderer().render(base, color: true).contains("\u{001B}["), "color rendering")
        let degraded = StatusSnapshot(desiredOn: true, actual: 0, power: base.power, thermal: .nominal, reason: "drift", guardLoaded: true, heartbeat: nil, now: 1_000)
        expect(StatusRenderer().render(degraded, color: false).contains("!.!"), "degraded face")
    }

    private static func controllerTests() throws {
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("shay-native-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: fixture) }

        let state = StateStore(directory: fixture.appendingPathComponent("state").path, lockPath: fixture.appendingPathComponent("lock").path, production: false)
        let system = FakeSystem()
        let controller = ShayController(system: system, state: state, privileged: true)
        _ = try controller.enable()
        expect(state.enabled && system.sleep == 1, "verified enable")
        expect(controller.promptStatus() == "shay ∞", "indefinite prompt status")
        system.power = PowerSnapshot(source: "Battery Power", batteryPercent: 25)
        try controller.guardOnce()
        expect(!state.enabled && system.sleep == 0 && state.read("last_reason") == "battery_25_percent", "guard trip")
        expect(controller.promptStatus().isEmpty, "offline prompt status")

        system.power = PowerSnapshot(source: "AC Power", batteryPercent: 80)
        system.timestamp = 1_000
        _ = try controller.enable(expiresAt: 1_060)
        expect(state.enabled && state.read("expires_at") == "1060", "expiry persisted")
        expect(controller.promptStatus() == "shay 1m", "expiring prompt status")
        system.timestamp = 1_060
        try controller.guardOnce()
        expect(!state.enabled && system.sleep == 0 && state.read("last_reason") == "expired", "expiry restored sleep")

        do {
            _ = try controller.enable(expiresAt: 1_060)
            expect(false, "past expiry should fail")
        } catch {
            expect(!state.enabled, "invalid expiry changed state")
        }

        system.setOutcomes = [(false, 1), (false, 1)]
        do {
            _ = try controller.enable()
            expect(false, "ambiguous enable should fail")
        } catch {
            expect(state.enabled && state.read("last_reason") == "enable_failed_restore_pending", "ambiguous enable remains guarded")
        }
    }
}
