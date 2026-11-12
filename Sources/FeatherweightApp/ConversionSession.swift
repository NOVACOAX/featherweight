import FeatherweightCore
import Foundation
import Observation

/// One pass through the "Convert to pnpm…" sheets for one project: finding pnpm, confirming,
/// converting, then committing or reverting.
@MainActor @Observable
final class ConversionSession: Identifiable {
    enum Phase {
        case checkingPnpm
        /// pnpm is missing (`found` is nil) or older than `PnpmToolchain.minimumMajor`.
        case needsPnpm(found: String?)
        case installingPnpm
        case confirm
        case running(ConversionStep)
        case failed(ConversionFailure)
        case done(ConversionResult)
        case reverting
        case revertFailed(ConversionFailure)
    }

    /// Where a commit would go. `upstream` (e.g. `origin/main`) is nil when the branch has none.
    struct GitTarget: Sendable {
        let repoRoot: URL
        let upstream: String?
        /// The upstream remote as host and path, e.g. `github.com/NOVACOAX/linkbreeze`.
        let remote: String?
    }

    enum CommitState: Equatable {
        case idle
        case working(pushing: Bool)
        /// `pushedTo` is the upstream when the commit was pushed too.
        case committed(pushedTo: String?)
        /// The commit was made but the push failed; the text is git's output.
        case pushFailed(String)
        case failed(String)
    }

    let id = UUID()
    let summary: ProjectSummary
    let project: Project
    var phase = Phase.checkingPnpm
    /// The output of a failed pnpm install, shown on the install sheet.
    var installError: String?
    let hasBuildScript: Bool
    var runBuildCheck = true
    var waitingForLock = false
    /// Each command as `$ command`, followed by its output.
    var log: [String] = []
    var commitMessage: String
    var git: GitTarget?
    var commit = CommitState.idle

    init(summary: ProjectSummary) {
        self.summary = summary
        let root = URL(fileURLWithPath: summary.id, isDirectory: true)
        project = Project(
            root: root, parentRoot: summary.parentRoot.map { URL(fileURLWithPath: $0, isDirectory: true) },
            packageManager: summary.packageManager,
            nodeModules: URL(fileURLWithPath: summary.id + "/node_modules", isDirectory: true))
        hasBuildScript = Self.hasBuildScript(root: summary.id)
        commitMessage = ConversionCommit.defaultMessage(from: summary.packageManager)
    }

    var name: String { summary.name }

    /// The lockfile `pnpm import` reads: `yarn.lock`, `npm-shrinkwrap.json` or `package-lock.json`.
    var oldLockfile: String {
        if summary.packageManager == .yarn { return "yarn.lock" }
        return FileManager.default.fileExists(atPath: summary.id + "/npm-shrinkwrap.json")
            ? "npm-shrinkwrap.json" : "package-lock.json"
    }

    /// The steps this conversion goes through, in order.
    var steps: [ConversionStep] {
        ConversionStep.allCases.filter { $0 != .buildCheck || (runBuildCheck && hasBuildScript) }
    }

    /// Applies a progress report, unless the conversion has already finished (reports arrive
    /// asynchronously and may land after the result).
    func report(_ step: ConversionStep) {
        guard case .running = phase else { return }
        waitingForLock = false
        phase = .running(step)
    }

    private static func hasBuildScript(root: String) -> Bool {
        guard let data = FileManager.default.contents(atPath: root + "/package.json"),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let scripts = json["scripts"] as? [String: Any] else { return false }
        return (scripts["build"] as? String)?.isEmpty == false
    }
}

/// Passes every command to `base`, reporting `$ command` before it runs and its output after.
struct LoggingCommandRunner: CommandRunner {
    let base: CommandRunner
    let log: @Sendable (String) -> Void

    func run(_ command: String, _ args: [String], in directory: URL?) throws -> CommandResult {
        log("$ " + ([command] + args).joined(separator: " "))
        do {
            let result = try base.run(command, args, in: directory)
            let output = (result.stdout + result.stderr).trimmingCharacters(in: .newlines)
            if !output.isEmpty { log(output) }
            if !result.succeeded { log("(exit code \(result.exitCode))") }
            return result
        } catch {
            log("\(error)")
            throw error
        }
    }
}
