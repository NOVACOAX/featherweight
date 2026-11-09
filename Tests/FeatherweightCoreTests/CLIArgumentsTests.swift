import Testing

@testable import FeatherweightCore

struct CLIArgumentsTests {
    private func parse(_ args: String...) -> Result<CLICommand, CLIError> {
        CLIArguments.parse(args)
    }

    @Test func parsesEachSubcommand() {
        #expect(parse("status") == .success(.status))
        #expect(parse("dedupe") == .success(.dedupe(dryRun: false)))
        #expect(parse("clean") == .success(.clean(dryRun: false)))
        #expect(parse("projects") == .success(.projects))
        #expect(parse("pause") == .success(.pause))
        #expect(parse("resume") == .success(.resume))
        #expect(parse("log") == .success(.log(limit: 20)))
        #expect(parse("uninstall") == .success(.uninstall))
        #expect(parse("version") == .success(.version))
        #expect(parse("help") == .success(.help))
    }

    @Test func versionAndHelpFlags() {
        #expect(parse("--version") == .success(.version))
        #expect(parse("--help") == .success(.help))
        #expect(parse("-h") == .success(.help))
    }

    @Test func noArgumentsShowsHelp() {
        #expect(CLIArguments.parse([]) == .success(.help))
    }

    @Test func dryRunFlag() {
        #expect(parse("dedupe", "--dry-run") == .success(.dedupe(dryRun: true)))
        #expect(parse("clean", "--dry-run") == .success(.clean(dryRun: true)))
        #expect(parse("projects", "--dry-run") == .failure(CLIError("Unexpected argument '--dry-run' for 'projects'.")))
    }

    @Test func logLimit() {
        #expect(parse("log", "--limit", "5") == .success(.log(limit: 5)))
        #expect(parse("log", "--limit") == .failure(CLIError("'--limit' needs a number.")))
        #expect(parse("log", "--limit", "x") == .failure(CLIError("'--limit' needs a positive number, not 'x'.")))
        #expect(parse("log", "--limit", "0") == .failure(CLIError("'--limit' needs a positive number, not '0'.")))
    }

    @Test func unknownCommandIsUsageError() {
        #expect(parse("frobnicate") == .failure(CLIError("Unknown command 'frobnicate'.")))
        #expect(parse("status", "extra") == .failure(CLIError("Unexpected argument 'extra' for 'status'.")))
    }
}
