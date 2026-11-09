import Darwin
import Foundation

public enum LaunchAgentError: Error, Equatable, LocalizedError {
    case bootstrapFailed(String)

    public var errorDescription: String? {
        switch self {
        case .bootstrapFailed(let message): "launchctl bootstrap failed: \(message)"
        }
    }
}

/// The per-user LaunchAgent that keeps the background helper running.
public struct LaunchAgent: Sendable {
    public static let label = "com.novacoax.featherweight.helper"
    private static let launchctl = "/bin/launchctl"

    private let paths: AppPaths
    private let runner: CommandRunner

    public init(paths: AppPaths, runner: CommandRunner) {
        self.paths = paths
        self.runner = runner
    }

    /// `<launchAgentsDir>/com.novacoax.featherweight.helper.plist`
    public var plistURL: URL {
        paths.launchAgentsDir.appendingPathComponent("\(Self.label).plist")
    }

    private var domain: String { "gui/\(getuid())" }

    public func plist(helperExecutable: URL) -> [String: Any] {
        [
            "Label": Self.label,
            "ProgramArguments": [helperExecutable.path],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],
            "ProcessType": "Background",
            "LowPriorityIO": true,
            "LowPriorityBackgroundIO": true,
            "Nice": 10,
        ]
    }

    /// Writes the plist, unloads any running copy (ignoring failure) and loads the new one.
    public func install(helperExecutable: URL) throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist(helperExecutable: helperExecutable), format: .xml, options: 0)
        try FileManager.default.createDirectory(at: paths.launchAgentsDir, withIntermediateDirectories: true)
        try data.write(to: plistURL, options: .atomic)
        bootout()
        let result = try runner.run(Self.launchctl, ["bootstrap", domain, plistURL.path], in: nil)
        guard result.succeeded else {
            let message = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw LaunchAgentError.bootstrapFailed(message.isEmpty ? "exit code \(result.exitCode)" : message)
        }
    }

    /// Unloads the helper (ignoring failure, for example when it is not loaded), then removes the
    /// plist and the helper's pid file.
    public func uninstall() throws {
        bootout()
        for url in [plistURL, paths.helperPID] where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    public func isInstalled() -> Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    private func bootout() {
        _ = try? runner.run(Self.launchctl, ["bootout", "\(domain)/\(Self.label)"], in: nil)
    }
}
