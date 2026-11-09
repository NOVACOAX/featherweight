import Foundation

public enum ConversionStep: String, Sendable {
    case backingUp, importing, installing, buildCheck, rewritingConfigs, cleaningUp
}

/// One project file the conversion added, modified or deleted, with a unified diff.
public struct FileChange: Sendable, Hashable {
    public enum Kind: Sendable, Hashable { case added, modified, deleted }

    public let relativePath: String
    public let kind: Kind
    public let diff: String
}

public struct ConversionResult: Sendable {
    public let changes: [FileChange]
    public let warnings: [RewriteWarning]
    public let bytesFreed: Int64
    public let backupID: UUID
    public let pnpmVersion: String
}

/// A conversion or revert that did not finish. `reverted` is true when every backed-up file was put
/// back; `output` then also carries the original manager's reinstall output if that reinstall failed.
public struct ConversionFailure: Error {
    public let step: ConversionStep
    /// The command that failed, or empty when something other than a command failed.
    public let command: String
    public let output: String
    public let reverted: Bool
}

/// Converts an npm or yarn project to pnpm, and back. Every package-manager command runs through the
/// injected runner (the login-shell environment in production). Takes no job lock: callers wrap
/// `convert` and `revert` in `JobRunner.withLock`.
public struct PnpmConverter: Sendable {
    private static let workspaceFile = "pnpm-workspace.yaml"
    private static let pnpmLockfile = "pnpm-lock.yaml"

    private let runner: CommandRunner
    private let paths: AppPaths
    private let rewriter: ConfigRewriting
    /// `/usr/bin/diff` needs no login-shell `PATH`, and diffs are not package-manager commands.
    private let diffRunner = ProcessCommandRunner(environment: ["PATH": "/usr/bin:/bin", "LC_ALL": "C"])

    public init(runner: CommandRunner, paths: AppPaths, rewriter: ConfigRewriting) {
        self.runner = runner
        self.paths = paths
        self.rewriter = rewriter
    }

    /// Converts `project` to pnpm. On any failure after the backup, every backed-up file is restored
    /// and, if `node_modules` had been removed, the original manager reinstalls it; then a
    /// `ConversionFailure` is thrown.
    public func convert(
        _ project: Project, runBuildCheck: Bool, progress: @Sendable (ConversionStep) -> Void
    ) throws -> ConversionResult {
        let root = project.root
        let manager = project.packageManager
        let oldLockfiles = Self.lockfiles(of: manager).filter { exists(root, $0) }
        guard !oldLockfiles.isEmpty else {
            throw ConversionFailure(
                step: .backingUp, command: "", output: "No npm or yarn lockfile to import.", reverted: true)
        }
        let toolchain = PnpmToolchain(runner: runner)
        guard let pnpmVersion = toolchain.installedVersion(), toolchain.isSupported(pnpmVersion) else {
            throw ConversionFailure(
                step: .backingUp, command: "pnpm --version",
                output: "pnpm \(PnpmToolchain.minimumMajor) or later is required.", reverted: true)
        }

        progress(.backingUp)
        let backup: ConversionBackup
        do {
            var backedUp = oldLockfiles + ["package.json", Self.pnpmLockfile, Self.workspaceFile]
            for rewrite in try rewriter.rewriteProject(root: root, from: manager, pnpmVersion: pnpmVersion)
            where rewrite.changed && !backedUp.contains(rewrite.relativePath) {
                backedUp.append(rewrite.relativePath)
            }
            backup = try ConversionBackup.create(root: root, relativePaths: backedUp, manager: manager, paths: paths)
        } catch {
            throw ConversionFailure(step: .backingUp, command: "", output: "\(error)", reverted: true)
        }

        var step = ConversionStep.importing
        var removedNodeModules = false
        do {
            let nodeModules = file(root, "node_modules")
            let before = CloneFS.privateBytes(under: nodeModules)

            progress(.importing)
            try run("pnpm", ["import"], in: root)
            let built = BuildScriptDetector().packagesWithInstallScripts(root: root)
            if !built.isEmpty {
                let yaml = "onlyBuiltDependencies:\n" + built.map { "  - \(Self.yamlScalar($0))\n" }.joined()
                try Data(yaml.utf8).write(to: file(root, Self.workspaceFile))
            }

            step = .installing
            progress(.installing)
            removedNodeModules = true
            try removeIfPresent(nodeModules)
            try run("pnpm", ["install", "--frozen-lockfile"], in: root)

            if runBuildCheck && hasBuildScript(root) {
                step = .buildCheck
                progress(.buildCheck)
                try run("pnpm", ["run", "build"], in: root)
            }

            step = .rewritingConfigs
            progress(.rewritingConfigs)
            let rewrites = try rewriter.rewriteProject(root: root, from: manager, pnpmVersion: pnpmVersion)
            for rewrite in rewrites where rewrite.changed {
                guard backup.entries[rewrite.relativePath] == true else {
                    throw ConversionStepError("\(rewrite.relativePath) changed during the conversion and wasn't backed up.")
                }
                try Data(rewrite.rewritten.utf8).write(to: file(root, rewrite.relativePath))
            }

            step = .cleaningUp
            progress(.cleaningUp)
            for lockfile in oldLockfiles { try removeIfPresent(file(root, lockfile)) }
            let after = CloneFS.privateBytes(under: nodeModules)

            return ConversionResult(
                changes: try changes(since: backup),
                warnings: rewrites.flatMap(\.warnings),
                bytesFreed: max(0, before - after),
                backupID: backup.id,
                pnpmVersion: pnpmVersion)
        } catch {
            let failed = error as? CommandFailed
            throw rollback(
                backup, root: root, reinstall: removedNodeModules,
                failure: ConversionFailure(
                    step: step, command: failed?.command ?? "", output: failed?.output ?? "\(error)", reverted: false))
        }
    }

    /// Restores `backup`, removes `node_modules` and reinstalls with the original manager.
    /// Throws a `ConversionFailure` (step `.installing`) if the files can't be restored or the
    /// reinstall fails.
    public func revert(_ project: Project, backup: ConversionBackup) throws {
        guard (PhysicalPath.resolve(project.root.path) ?? project.root.path) == backup.projectRoot else {
            throw ConversionFailure(
                step: .backingUp, command: "", output: "This backup belongs to \(backup.projectRoot).", reverted: false)
        }
        let root = URL(fileURLWithPath: backup.projectRoot, isDirectory: true)
        let failure = rollback(
            backup, root: root, reinstall: true,
            failure: ConversionFailure(step: .installing, command: "", output: "", reverted: false))
        if failure.reverted && failure.output.isEmpty { return }
        throw failure
    }

    // MARK: - Rollback

    /// Restores the backup and, when asked (and the files came back), removes `node_modules` and
    /// reinstalls with the original manager. Returns `failure` with `reverted` set and any restore or
    /// reinstall output appended.
    private func rollback(
        _ backup: ConversionBackup, root: URL, reinstall: Bool, failure: ConversionFailure
    ) -> ConversionFailure {
        var command = failure.command
        var output = [failure.output].filter { !$0.isEmpty }
        do {
            try backup.restore(paths: paths)
        } catch {
            output.append("Restoring the backup failed: \(error)")
            return ConversionFailure(
                step: failure.step, command: command, output: output.joined(separator: "\n\n"), reverted: false)
        }
        if reinstall {
            let (tool, args) = Self.reinstallCommand(for: backup.originalManager)
            do {
                try removeIfPresent(file(root, "node_modules"))
                try run(tool, args, in: root)
            } catch {
                let failed = error as? CommandFailed
                if command.isEmpty { command = failed?.command ?? "" }
                output.append(
                    "Reinstalling with \(backup.originalManager.rawValue) failed"
                        + " (\(([tool] + args).joined(separator: " "))):\n\(failed?.output ?? "\(error)")")
            }
        }
        return ConversionFailure(
            step: failure.step, command: command, output: output.joined(separator: "\n\n"), reverted: true)
    }

    private static func reinstallCommand(for manager: PackageManager) -> (String, [String]) {
        manager == .yarn ? ("yarn", ["install", "--frozen-lockfile"]) : ("npm", ["ci"])
    }

    private static func lockfiles(of manager: PackageManager) -> [String] {
        switch manager {
        case .npm: ["package-lock.json", "npm-shrinkwrap.json"]
        case .yarn: ["yarn.lock"]
        case .pnpm, .bun, .none: []
        }
    }

    // MARK: - Commands

    private struct CommandFailed: Error {
        let command: String
        let output: String
    }

    private struct ConversionStepError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    /// Runs a command in `directory`, throwing `CommandFailed` if it can't start or exits non-zero.
    private func run(_ command: String, _ args: [String], in directory: URL) throws {
        let display = ([command] + args).joined(separator: " ")
        let result: CommandResult
        do {
            result = try runner.run(command, args, in: directory)
        } catch {
            throw CommandFailed(command: display, output: "\(error)")
        }
        guard result.succeeded else {
            throw CommandFailed(command: display, output: result.stdout + result.stderr)
        }
    }

    // MARK: - Diffs

    /// Every backed-up file that now differs from its backup, with a `diff -u` against the backup or
    /// `/dev/null`.
    private func changes(since backup: ConversionBackup) throws -> [FileChange] {
        let root = URL(fileURLWithPath: backup.projectRoot, isDirectory: true)
        var changes: [FileChange] = []
        for (relativePath, existed) in backup.entries.sorted(by: { $0.key < $1.key }) {
            let current = file(root, relativePath).path
            let saved = backup.storedFile(relativePath, paths: paths)
            let kind: FileChange.Kind
            let old: (path: String, label: String)
            let new: (path: String, label: String)
            switch (existed, FileManager.default.fileExists(atPath: current)) {
            case (true, true):
                guard FileManager.default.contentsEqual(atPath: saved, andPath: current) == false else { continue }
                kind = .modified
                old = (saved, "a/" + relativePath)
                new = (current, "b/" + relativePath)
            case (true, false):
                kind = .deleted
                old = (saved, "a/" + relativePath)
                new = ("/dev/null", "/dev/null")
            case (false, true):
                kind = .added
                old = ("/dev/null", "/dev/null")
                new = (current, "b/" + relativePath)
            case (false, false):
                continue
            }
            let result = try diffRunner.run(
                "/usr/bin/diff", ["-u", "--label", old.label, "--label", new.label, old.path, new.path], in: nil)
            guard result.exitCode == 0 || result.exitCode == 1 else {
                throw CommandFailed(command: "diff -u \(relativePath)", output: result.stderr)
            }
            changes.append(FileChange(relativePath: relativePath, kind: kind, diff: result.stdout))
        }
        return changes
    }

    // MARK: - Files

    /// `root/relativePath`, built from strings so trailing spaces in names survive.
    private func file(_ root: URL, _ relativePath: String) -> URL {
        URL(fileURLWithPath: root.path + "/" + relativePath)
    }

    private func exists(_ root: URL, _ relativePath: String) -> Bool {
        FileManager.default.fileExists(atPath: file(root, relativePath).path)
    }

    private func removeIfPresent(_ url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return }
        try FileManager.default.removeItem(at: url)
    }

    private func hasBuildScript(_ root: URL) -> Bool {
        guard let data = try? Data(contentsOf: file(root, "package.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let scripts = json["scripts"] as? [String: Any] else { return false }
        return (scripts["build"] as? String)?.isEmpty == false
    }

    /// A package name as a YAML scalar: plain when it is a simple name, single-quoted otherwise
    /// (YAML can't start a plain scalar with `@`, so scoped names must be quoted).
    private static func yamlScalar(_ name: String) -> String {
        let plain = name.first.map { $0.isASCII && ($0.isLowercase || $0.isNumber) } == true
            && name.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber || "-._".contains($0)) }
        return plain ? name : "'" + name.replacingOccurrences(of: "'", with: "''") + "'"
    }
}
