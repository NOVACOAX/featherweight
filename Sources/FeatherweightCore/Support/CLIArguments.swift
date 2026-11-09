import Foundation

public enum CLICommand: Equatable, Sendable {
    case status
    case dedupe(dryRun: Bool)
    case clean(dryRun: Bool)
    case projects
    case pause
    case resume
    case log(limit: Int)
    case uninstall
    case version
    case help
}

/// A command-line usage problem; `message` is shown to the user.
public struct CLIError: Error, Equatable, Sendable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }
}

public enum CLIArguments {
    public static let defaultLogLimit = 20

    /// Parses the arguments after the program name.
    public static func parse(_ args: [String]) -> Result<CLICommand, CLIError> {
        guard let name = args.first else { return .success(.help) }
        let rest = Array(args.dropFirst())
        switch name {
        case "status": return expectNone(rest, for: name, .status)
        case "projects": return expectNone(rest, for: name, .projects)
        case "pause": return expectNone(rest, for: name, .pause)
        case "resume": return expectNone(rest, for: name, .resume)
        case "uninstall": return expectNone(rest, for: name, .uninstall)
        case "version", "--version": return expectNone(rest, for: name, .version)
        case "help", "--help", "-h": return expectNone(rest, for: name, .help)
        case "dedupe": return parseDryRun(rest, for: name) { .dedupe(dryRun: $0) }
        case "clean": return parseDryRun(rest, for: name) { .clean(dryRun: $0) }
        case "log": return parseLog(rest)
        default: return .failure(CLIError("Unknown command '\(name)'."))
        }
    }

    private static func expectNone(
        _ rest: [String], for name: String, _ command: CLICommand
    ) -> Result<CLICommand, CLIError> {
        if let extra = rest.first { return .failure(unexpected(extra, for: name)) }
        return .success(command)
    }

    private static func parseDryRun(
        _ rest: [String], for name: String, _ make: (Bool) -> CLICommand
    ) -> Result<CLICommand, CLIError> {
        var dryRun = false
        for argument in rest {
            guard argument == "--dry-run" else { return .failure(unexpected(argument, for: name)) }
            dryRun = true
        }
        return .success(make(dryRun))
    }

    private static func parseLog(_ rest: [String]) -> Result<CLICommand, CLIError> {
        var limit = defaultLogLimit
        var index = rest.startIndex
        while index < rest.endIndex {
            guard rest[index] == "--limit" else { return .failure(unexpected(rest[index], for: "log")) }
            index += 1
            guard index < rest.endIndex else { return .failure(CLIError("'--limit' needs a number.")) }
            guard let value = Int(rest[index]), value > 0 else {
                return .failure(CLIError("'--limit' needs a positive number, not '\(rest[index])'."))
            }
            limit = value
            index += 1
        }
        return .success(.log(limit: limit))
    }

    private static func unexpected(_ argument: String, for name: String) -> CLIError {
        CLIError("Unexpected argument '\(argument)' for '\(name)'.")
    }
}
