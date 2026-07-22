import Darwin
import Foundation

private let corePath = "/usr/local/libexec/shay-core"

private struct Runtime {
    let controller: ShayController
    let testMode: Bool

    init(environment: [String: String]) {
        testMode = geteuid() != 0 && environment["SHAY_TEST_MODE"] == "1"
        if testMode {
            let required = ["SHAY_PMSET", "SHAY_THERMAL", "SHAY_LAUNCHCTL", "SHAY_STATE_DIR", "SHAY_LOCK_PATH"]
            for name in required where environment[name]?.isEmpty != false {
                fputs("shay: \(name) is required in test mode\n", stderr)
                exit(2)
            }
            let system = MacSystemClient(
                pmset: environment["SHAY_PMSET"]!,
                launchctl: environment["SHAY_LAUNCHCTL"]!,
                thermalProbe: environment["SHAY_THERMAL"]!,
                environment: environment,
                logger: "/usr/bin/true"
            )
            let state = StateStore(directory: environment["SHAY_STATE_DIR"]!, lockPath: environment["SHAY_LOCK_PATH"]!, production: false)
            controller = ShayController(system: system, state: state, privileged: true)
        } else {
            let system = MacSystemClient()
            let state = StateStore(directory: "/var/db/shay", lockPath: "/var/run/shay.lock", production: true)
            controller = ShayController(system: system, state: state, privileged: geteuid() == 0)
        }
    }
}

private func fail(_ message: String, code: Int32 = 1) -> Never {
    fputs("shay: \(message)\n", stderr)
    exit(code)
}

private let usage = "usage: shay -on [--for 30m|4h|2d | --until HH:MM] | -off | -status"

private func runViaSudo(_ command: String, input: String? = nil) -> Never {
    guard FileManager.default.isExecutableFile(atPath: corePath) else {
        fail("privileged helper is not installed; run sudo ./install.sh")
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
    process.arguments = ["-n", corePath, command]
    var inputPipe: Pipe?
    if let input {
        let pipe = Pipe()
        inputPipe = pipe
        process.standardInput = pipe
        try? pipe.fileHandleForWriting.write(contentsOf: Data(input.utf8))
        try? pipe.fileHandleForWriting.close()
    } else {
        process.standardInput = FileHandle.standardInput
    }
    process.standardOutput = FileHandle.standardOutput
    process.standardError = FileHandle.standardError
    do { try process.run() } catch { fail("could not start sudo: \(error.localizedDescription)") }
    process.waitUntilExit()
    _ = inputPipe
    exit(process.terminationStatus)
}

private func readExpiryDeadline() -> Int64 {
    let data = FileHandle.standardInput.readData(ofLength: 64)
    guard data.count <= 32,
          let raw = String(data: data, encoding: .utf8),
          raw == raw.trimmingCharacters(in: .whitespacesAndNewlines) + "\n",
          let deadline = Int64(raw.trimmingCharacters(in: .whitespacesAndNewlines)) else {
        fail("invalid expiry protocol")
    }
    return deadline
}

private func useColor(_ environment: [String: String]) -> Bool {
    if environment["SHAY_FORCE_COLOR"] == "1" { return true }
    return isatty(STDOUT_FILENO) == 1 && environment["NO_COLOR"] == nil && environment["TERM"] != "dumb"
}

private let environment = ProcessInfo.processInfo.environment
private let suppliedArguments = Array(CommandLine.arguments.dropFirst())

if suppliedArguments == ["-on"] { runViaSudo("on") }
if suppliedArguments.count == 3, suppliedArguments[0] == "-on" {
    let deadline: Int64?
    switch suppliedArguments[1] {
    case "--for":
        deadline = ExpiryParser.duration(suppliedArguments[2], now: Int64(Date().timeIntervalSince1970))
    case "--until":
        deadline = ExpiryParser.wallClock(suppliedArguments[2], now: Date())
    default:
        deadline = nil
    }
    guard let deadline else { fail(usage, code: 2) }
    runViaSudo("on-expiring", input: "\(deadline)\n")
}
if suppliedArguments == ["-off"] { runViaSudo("off") }

guard suppliedArguments.count == 1 else { fail(usage, code: 2) }
private let argument = suppliedArguments[0]

private let runtime = Runtime(environment: environment)
do {
    switch argument {
    case "on":
        try runtime.controller.enable().forEach { print($0) }
    case "on-expiring":
        try runtime.controller.enable(expiresAt: readExpiryDeadline()).forEach { print($0) }
    case "off":
        try runtime.controller.disable().forEach { print($0) }
    case "guard":
        try runtime.controller.guardOnce()
    case "-status", "status":
        print(runtime.controller.status(color: useColor(environment)))
    case "prompt":
        let output = runtime.controller.promptStatus()
        if !output.isEmpty { print(output) }
    case "selftest":
        guard SafetyResult.evaluate(battery: 26, thermal: .nominal) == .safe,
              SafetyResult.evaluate(battery: 25, thermal: .nominal) == .unsafe("battery_25_percent"),
              SafetyResult.evaluate(battery: 80, thermal: .serious) == .unsafe("thermal_serious"),
              SafetyResult.evaluate(battery: nil, thermal: .nominal) == .unsafe("battery_reading_unavailable"),
              SafetyResult.evaluate(battery: 80, thermal: nil) == .unsafe("thermal_reading_unavailable") else {
            fail("self-test failed")
        }
        print("shay-core self-test passed")
    case "protocol-version":
        print(shayProtocolVersion)
    case "--version", "version":
        print("shay \(shayVersion)")
    default:
        fail(usage, code: 2)
    }
} catch {
    fail(String(describing: error))
}
