import Foundation

/// GUI apps launched from Finder do not inherit the user's shell `PATH`, so tools installed through
/// nvm, Homebrew or Volta would be invisible. This captures the environment a login shell sets up.
public enum LoginShellEnvironment {
    public static let shared: [String: String] = resolve(
        shell: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh",
        timeout: 5
    )

    private static let marker = "__FW__"

    /// Runs `shell -ilc 'printf __FW__; env -0'` and parses everything after the marker.
    /// Falls back to the current process environment on timeout or failure.
    public static func resolve(shell: String, timeout: TimeInterval) -> [String: String] {
        let fallback = ProcessInfo.processInfo.environment
        guard FileManager.default.isExecutableFile(atPath: shell) else { return fallback }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-ilc", "printf \(marker); env -0"]
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let outPipe = Pipe()
        process.standardOutput = outPipe

        do { try process.run() } catch { return fallback }
        let reader = PipeReader(outPipe.fileHandleForReading)

        guard let data = reader.data(timeout: timeout) else {
            process.terminate()
            return fallback
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0, let parsed = parse(data), parsed["PATH"] != nil else {
            return fallback
        }
        return parsed
    }

    private static func parse(_ data: Data) -> [String: String]? {
        let output = String(decoding: data, as: UTF8.self)
        // Interactive startup files may print before the marker; ignore all of it.
        guard let range = output.range(of: marker, options: .backwards) else { return nil }
        var environment: [String: String] = [:]
        for entry in output[range.upperBound...].split(separator: "\0", omittingEmptySubsequences: true) {
            guard let equals = entry.firstIndex(of: "=") else { continue }
            environment[String(entry[..<equals])] = String(entry[entry.index(after: equals)...])
        }
        return environment
    }
}
