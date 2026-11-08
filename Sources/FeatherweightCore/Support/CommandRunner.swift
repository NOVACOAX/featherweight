import Foundation

public struct CommandResult: Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String

    public var succeeded: Bool { exitCode == 0 }

    public init(exitCode: Int32, stdout: String, stderr: String) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

public enum CommandRunnerError: Error, Equatable {
    case commandNotFound(String)
}

public protocol CommandRunner: Sendable {
    /// `command` is a bare name resolved on the runner's `PATH`, or an absolute path.
    func run(_ command: String, _ args: [String], in directory: URL?) throws -> CommandResult
}

public struct ProcessCommandRunner: CommandRunner {
    private let environment: [String: String]

    public init(environment: [String: String] = LoginShellEnvironment.shared) {
        self.environment = environment
    }

    public func run(_ command: String, _ args: [String], in directory: URL?) throws -> CommandResult {
        guard let executable = resolve(command) else {
            throw CommandRunnerError.commandNotFound(command)
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = args
        process.environment = environment
        process.currentDirectoryURL = directory
        process.standardInput = FileHandle.nullDevice
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        try process.run()
        let out = PipeReader(outPipe.fileHandleForReading)
        let err = PipeReader(errPipe.fileHandleForReading)
        process.waitUntilExit()

        return CommandResult(
            exitCode: process.terminationStatus,
            stdout: String(decoding: out.data() ?? Data(), as: UTF8.self),
            stderr: String(decoding: err.data() ?? Data(), as: UTF8.self)
        )
    }

    private func resolve(_ command: String) -> URL? {
        let fileManager = FileManager.default
        if command.contains("/") {
            return fileManager.isExecutableFile(atPath: command) ? URL(fileURLWithPath: command) : nil
        }
        for directory in (environment["PATH"] ?? "").split(separator: ":", omittingEmptySubsequences: true) {
            let candidate = URL(fileURLWithPath: String(directory), isDirectory: true)
                .appendingPathComponent(command)
            if fileManager.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }
}
