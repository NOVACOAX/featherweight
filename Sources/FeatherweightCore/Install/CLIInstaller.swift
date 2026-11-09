import Foundation

public enum CLIInstallError: Error, Equatable, LocalizedError {
    /// No folder that is on `PATH` can be written to. `suggestedLine` is a line for the shell's startup file.
    case noWritableDirectoryOnPath(suggestedLine: String)
    /// The command-line tool to link to is missing.
    case executableNotFound(URL)
    /// Something that is not a link to `featherweight` already has the name.
    case fileInTheWay(URL)

    public var errorDescription: String? {
        switch self {
        case .noWritableDirectoryOnPath:
            "None of ~/.local/bin, /opt/homebrew/bin or /usr/local/bin is both on your PATH and writable."
        case .executableNotFound(let url):
            "The featherweight command was not found at \(url.path)."
        case .fileInTheWay(let url):
            "\(url.path) already exists and is not a link to featherweight."
        }
    }
}

/// Installs the `featherweight` terminal command as a symlink to the tool inside the app.
///
/// A link is only ever treated as ours if it resolves to a `featherweight` inside an app bundle
/// (`…app/Contents/Helpers/featherweight`) or to the exact executable the caller says is the
/// command line tool. A Homebrew link such as `…/Cellar/featherweight/1.0/bin/featherweight`, or
/// any regular file with that name, is never replaced or removed.
public struct CLIInstaller: @unchecked Sendable {
    public static let commandName = "featherweight"
    public static let suggestedPathLine = "export PATH=\"$HOME/.local/bin:$PATH\""

    private let pathEntries: [String]
    private let candidates: [URL]
    private let fileManager: FileManager

    /// `candidates` are the folders to try, in order; the default is `~/.local/bin`,
    /// `/opt/homebrew/bin` and `/usr/local/bin`.
    public init(home: URL, pathEnv: String, fileManager: FileManager = .default, candidates: [URL]? = nil) {
        pathEntries = pathEnv.split(separator: ":", omittingEmptySubsequences: true).map(String.init)
        self.candidates = candidates ?? [
            home.appendingPathComponent(".local/bin", isDirectory: true),
            URL(fileURLWithPath: "/opt/homebrew/bin", isDirectory: true),
            URL(fileURLWithPath: "/usr/local/bin", isDirectory: true),
        ]
        self.fileManager = fileManager
    }

    /// The first candidate folder that is on `PATH`, exists and can be written to.
    public func targetDirectory() -> URL? {
        let onPath = Set(pathEntries.map(Self.normalized))
        return candidates.first { candidate in
            var isDirectory: ObjCBool = false
            return onPath.contains(Self.normalized(candidate.path))
                && fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory)
                && isDirectory.boolValue
                && fileManager.isWritableFile(atPath: candidate.path)
        }
    }

    /// Links `featherweight` in `targetDirectory()` to `cli` (replacing an older link of ours) and
    /// returns the link.
    public func install(cli: URL) throws -> URL {
        guard fileManager.isExecutableFile(atPath: cli.path) else { throw CLIInstallError.executableNotFound(cli) }
        guard let directory = targetDirectory() else {
            throw CLIInstallError.noWritableDirectoryOnPath(suggestedLine: Self.suggestedPathLine)
        }
        let link = directory.appendingPathComponent(Self.commandName)
        if exists(link) {
            guard isOurs(link, cli: cli) else { throw CLIInstallError.fileInTheWay(link) }
            try fileManager.removeItem(at: link)
        }
        try fileManager.createSymbolicLink(at: link, withDestinationURL: cli)
        return link
    }

    /// Our links in any candidate folder, whether or not it is on `PATH`. `cli` is the command
    /// line tool this process knows about; a link to it counts even outside an app bundle (a
    /// development build).
    public func installedLinks(cli: URL? = nil) -> [URL] {
        candidates.map { $0.appendingPathComponent(Self.commandName) }.filter { isOurs($0, cli: cli) }
    }

    /// Removes the links `install` made. Anything else named `featherweight` is left alone.
    public func uninstall(cli: URL? = nil) throws {
        for link in installedLinks(cli: cli) {
            try fileManager.removeItem(at: link)
        }
    }

    /// Whether anything, including a dangling link, is at `url`.
    private func exists(_ url: URL) -> Bool {
        (try? fileManager.attributesOfItem(atPath: url.path)) != nil
    }

    /// A symlink that points into an app bundle's `Contents/Helpers/featherweight`, or at `cli`
    /// (the target may be gone). Anything else, including regular files, is not ours.
    private func isOurs(_ url: URL, cli: URL?) -> Bool {
        guard let destination = try? fileManager.destinationOfSymbolicLink(atPath: url.path) else { return false }
        let target = destination.hasPrefix("/")
            ? URL(fileURLWithPath: destination)
            : url.deletingLastPathComponent().appendingPathComponent(destination)
        let path = target.standardizedFileURL.path
        if path.hasSuffix(".app/Contents/Helpers/\(Self.commandName)") { return true }
        guard let cli else { return false }
        return path == cli.standardizedFileURL.path || Self.normalized(path) == Self.normalized(cli.path)
    }

    private static func normalized(_ path: String) -> String {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        return PhysicalPath.resolve(standardized) ?? standardized
    }
}
