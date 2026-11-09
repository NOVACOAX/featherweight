import Foundation
@testable import FeatherweightCore

/// Records every call and returns scripted results keyed by `"command args…"` (joined with single
/// spaces). A scripted action runs first, with the call's working directory, so a test can mutate the
/// temp project the way the real tool would (for example by writing `pnpm-lock.yaml`).
/// Unscripted calls succeed with empty output; commands in `missing` throw `commandNotFound`.
final class FakeCommandRunner: CommandRunner, @unchecked Sendable {
    typealias Action = @Sendable (URL?) throws -> Void

    private struct Script {
        let result: CommandResult
        let action: Action?
    }

    private let lock = NSLock()
    private var scripts: [String: Script] = [:]
    private var recorded: [String] = []
    private var missing: Set<String> = []

    /// Every call so far, as `"command args…"`.
    var calls: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func script(
        _ key: String, exitCode: Int32 = 0, stdout: String = "", stderr: String = "", action: Action? = nil
    ) {
        lock.lock()
        defer { lock.unlock() }
        scripts[key] = Script(result: CommandResult(exitCode: exitCode, stdout: stdout, stderr: stderr), action: action)
    }

    /// Makes `command` (the bare command name) throw `CommandRunnerError.commandNotFound`.
    func makeMissing(_ command: String) {
        lock.lock()
        defer { lock.unlock() }
        missing.insert(command)
    }

    func run(_ command: String, _ args: [String], in directory: URL?) throws -> CommandResult {
        let key = ([command] + args).joined(separator: " ")
        lock.lock()
        recorded.append(key)
        let isMissing = missing.contains(command)
        let script = scripts[key]
        lock.unlock()
        if isMissing { throw CommandRunnerError.commandNotFound(command) }
        try script?.action?(directory)
        return script?.result ?? CommandResult(exitCode: 0, stdout: "", stderr: "")
    }
}
