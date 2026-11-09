import Foundation

/// Every pnpm install command failed; `output` holds each command and what it printed.
public struct PnpmInstallError: Error, Sendable {
    public let output: String
}

/// Finds and installs pnpm. Every command runs through the injected runner, which in production
/// uses the login-shell environment so nvm, Homebrew and Volta installs are found.
public struct PnpmToolchain: Sendable {
    public static let minimumMajor = 10
    /// Tried in order: Corepack first, then npm.
    public static let installCommands: [[String]] = [["corepack", "enable", "pnpm"], ["npm", "install", "-g", "pnpm@latest"]]

    private let runner: CommandRunner

    public init(runner: CommandRunner) {
        self.runner = runner
    }

    /// The output of `pnpm --version`, or nil when pnpm is missing or fails.
    public func installedVersion() -> String? {
        guard let result = try? runner.run("pnpm", ["--version"], in: nil), result.succeeded else { return nil }
        let version = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return version.isEmpty ? nil : version
    }

    /// True when the version's major number is at least `minimumMajor`.
    public func isSupported(_ version: String) -> Bool {
        guard let major = Int(version.prefix { $0.isASCII && $0.isNumber }) else { return false }
        return major >= Self.minimumMajor
    }

    /// Runs each install command in turn and returns the first one that succeeded, joined with spaces.
    public func install() throws -> String {
        var log: [String] = []
        for command in Self.installCommands {
            let display = command.joined(separator: " ")
            do {
                let result = try runner.run(command[0], Array(command.dropFirst()), in: nil)
                if result.succeeded { return display }
                log.append("$ \(display)\n\(result.stdout)\(result.stderr)")
            } catch {
                log.append("$ \(display)\n\(error)")
            }
        }
        throw PnpmInstallError(output: log.joined(separator: "\n"))
    }
}
