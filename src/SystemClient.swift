import Darwin
import Foundation

public struct CommandResult: Sendable {
    public let status: Int32
    public let stdout: String
    public let stderr: String

    public var succeeded: Bool { status == 0 }
}

public final class CommandRunner {
    private let environment: [String: String]
    private let timeout: TimeInterval

    public init(environment: [String: String], timeout: TimeInterval = 5) {
        self.environment = environment
        self.timeout = timeout
    }

    public func run(_ executable: String, _ arguments: [String]) -> CommandResult {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            return CommandResult(status: 127, stdout: "", stderr: error.localizedDescription)
        }

        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            process.waitUntilExit()
            finished.signal()
        }
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if finished.wait(timeout: .now() + 1) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + 1)
            }
            return CommandResult(status: 124, stdout: "", stderr: "command timed out")
        }

        let stdout = String(decoding: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let stderr = String(decoding: stderrPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return CommandResult(status: process.terminationStatus, stdout: stdout, stderr: stderr)
    }
}

public protocol SystemProviding {
    func powerSnapshot() -> PowerSnapshot
    func thermalLevel() -> ThermalLevel?
    func sleepDisabled() -> Int?
    func setSleepDisabled(_ value: Int) -> Bool
    func guardLoaded() -> Bool
    func now() -> Int64
    func log(_ message: String)
}

public final class MacSystemClient: SystemProviding {
    private let runner: CommandRunner
    private let pmset: String
    private let launchctl: String
    private let thermalProbe: String?
    private let label: String
    private let logger: String

    public init(pmset: String = "/usr/bin/pmset",
                launchctl: String = "/bin/launchctl",
                thermalProbe: String? = nil,
                label: String = "org.shaycli.guard",
                environment: [String: String] = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C", "LC_ALL": "C"],
                logger: String = "/usr/bin/logger") {
        self.runner = CommandRunner(environment: environment)
        self.pmset = pmset
        self.launchctl = launchctl
        self.thermalProbe = thermalProbe
        self.label = label
        self.logger = logger
    }

    public func powerSnapshot() -> PowerSnapshot {
        let result = runner.run(pmset, ["-g", "batt"])
        guard result.succeeded else { return PowerSnapshot(source: nil, batteryPercent: nil) }
        return ShayParser.power(result.stdout)
    }

    public func thermalLevel() -> ThermalLevel? {
        if let thermalProbe {
            let result = runner.run(thermalProbe, [])
            return result.succeeded ? ShayParser.thermal(result.stdout) : nil
        }
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return .nominal
        case .fair: return .fair
        case .serious: return .serious
        case .critical: return .critical
        @unknown default: return nil
        }
    }

    public func sleepDisabled() -> Int? {
        let result = runner.run(pmset, ["-g"])
        return result.succeeded ? ShayParser.sleepDisabled(result.stdout) : nil
    }

    public func setSleepDisabled(_ value: Int) -> Bool {
        guard value == 0 || value == 1 else { return false }
        _ = runner.run(pmset, ["-a", "disablesleep", String(value)])
        // The observed postcondition is authoritative. A nonzero pmset exit can
        // still leave the requested policy applied, and the inverse is also
        // possible; only the read-back decides whether the transition finished.
        return sleepDisabled() == value
    }

    public func guardLoaded() -> Bool {
        runner.run(launchctl, ["print", "system/\(label)"]).succeeded
    }

    public func now() -> Int64 {
        Int64(Date().timeIntervalSince1970)
    }

    public func log(_ message: String) {
        _ = runner.run(logger, ["-t", "shay", message])
    }
}
