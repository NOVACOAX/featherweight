import Foundation

/// What the config rewriters need to know about the project being converted.
public struct RewriteContext: Sendable {
    /// Names of the scripts in `package.json`.
    public let scripts: Set<String>
    /// Executables that the project's direct dependencies install into `node_modules/.bin`.
    public let dependencyBins: Set<String>
    /// The lockfile pnpm replaces: `package-lock.json`, `npm-shrinkwrap.json` or `yarn.lock`.
    public let oldLockfile: String
    public let pnpmVersion: String
    /// `package.json` has a `packageManager` field, which `pnpm/action-setup` reads for the version.
    public let packageManagerField: Bool

    public init(
        scripts: Set<String>, dependencyBins: Set<String>, oldLockfile: String, pnpmVersion: String,
        packageManagerField: Bool
    ) {
        self.scripts = scripts
        self.dependencyBins = dependencyBins
        self.oldLockfile = oldLockfile
        self.pnpmVersion = pnpmVersion
        self.packageManagerField = packageManagerField
    }

    var pnpmMajor: String { String(pnpmVersion.prefix { $0 != "." }) }
}

/// Rewrites npm and yarn references in a project's CI, deploy and script configs to pnpm, only where
/// the pattern is certain. Everything else is left as it was and reported as a warning. Text is
/// edited in place so formatting, comments and key order are kept. Nothing is written to disk.
public struct ConfigRewriter: ConfigRewriting {
    public init() {}

    // MARK: - Whole project

    public func rewriteProject(root: URL, from: PackageManager, pnpmVersion: String) throws -> [FileRewrite] {
        let context = Self.context(root: root, from: from, pnpmVersion: pnpmVersion)
        let fileManager = FileManager.default
        var targets: [(String, (String, String, PackageManager, RewriteContext) -> FileRewrite)] = []

        let workflows = ".github/workflows"
        for name in (try? fileManager.contentsOfDirectory(atPath: root.path + "/" + workflows)) ?? []
        where name.hasSuffix(".yml") || name.hasSuffix(".yaml") {
            targets.append((workflows + "/" + name, rewriteWorkflow))
        }
        for name in (try? fileManager.contentsOfDirectory(atPath: root.path)) ?? [] where name.hasPrefix("Dockerfile") {
            targets.append((name, rewriteDockerfile))
        }
        targets += [
            ("firebase.json", rewriteFirebase), ("netlify.toml", rewriteNetlify), ("vercel.json", rewriteVercel),
            ("package.json", rewritePackageJSON),
        ]

        var rewrites: [FileRewrite] = []
        for (relativePath, rewrite) in targets {
            let path = root.path + "/" + relativePath
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue,
                  let data = fileManager.contents(atPath: path),
                  let text = String(data: data, encoding: .utf8) else { continue }
            let result = rewrite(text, relativePath, from, context)
            if result.changed || !result.warnings.isEmpty { rewrites.append(result) }
        }
        return rewrites.sorted { $0.relativePath < $1.relativePath }
    }

    static func context(root: URL, from: PackageManager, pnpmVersion: String) -> RewriteContext {
        let package = readJSONObject(root.path + "/package.json") ?? [:]
        let scripts = Set((package["scripts"] as? [String: Any])?.keys.map { $0 } ?? [])
        var bins: Set<String> = []
        for key in ["dependencies", "devDependencies", "optionalDependencies"] {
            for name in ((package[key] as? [String: Any]) ?? [:]).keys {
                guard let manifest = readJSONObject(root.path + "/node_modules/" + name + "/package.json") else { continue }
                if let bin = manifest["bin"] as? [String: Any] {
                    bins.formUnion(bin.keys)
                } else if manifest["bin"] is String {
                    bins.insert(String(name.split(separator: "/").last ?? Substring(name)))
                }
            }
        }
        let oldLockfile: String
        switch from {
        case .yarn: oldLockfile = "yarn.lock"
        default:
            oldLockfile = FileManager.default.fileExists(atPath: root.path + "/npm-shrinkwrap.json")
                ? "npm-shrinkwrap.json" : "package-lock.json"
        }
        return RewriteContext(
            scripts: scripts, dependencyBins: bins, oldLockfile: oldLockfile, pnpmVersion: pnpmVersion,
            packageManagerField: package["packageManager"] is String)
    }

    private static func readJSONObject(_ path: String) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    // MARK: - GitHub Actions workflows

    public func rewriteWorkflow(text: String, file: String, from: PackageManager, context: RewriteContext) -> FileRewrite {
        var lines = text.components(separatedBy: "\n")
        var warnings: [RewriteWarning] = []

        // 1. pnpm/action-setup before each actions/setup-node step, and its cache settings.
        let hasActionSetup = text.contains("pnpm/action-setup")
        var setupNodeSteps = 0
        var index = 0
        while index < lines.count {
            guard Self.matches(lines[index], #"^\s*(-\s+)?uses:\s*['"]?actions/setup-node@"#),
                  let step = Self.step(containing: index, in: lines) else {
                index += 1
                continue
            }
            setupNodeSteps += 1
            for i in step.range {
                lines[i] = Self.rewriteCacheLine(lines[i], context: context)
            }
            if !hasActionSetup {
                let dash = String(repeating: " ", count: step.dashColumn)
                var inserted = [dash + "- uses: pnpm/action-setup@v4"]
                if !context.packageManagerField {
                    inserted += [dash + "  with:", dash + "    version: " + context.pnpmMajor]
                }
                lines.insert(contentsOf: inserted, at: step.range.lowerBound)
                index = step.range.upperBound + inserted.count
            } else {
                index = step.range.upperBound
            }
        }

        // 2. `run:` commands.
        var firstCommandLine: Int?
        index = 0
        while index < lines.count {
            guard let run = Self.firstMatch(lines[index], #"^(\s*)(-\s+)?run:(\s*)(.*)$"#) else {
                index += 1
                continue
            }
            let keyColumn = run[1].count + run[2].count
            let certain = !Self.stepChangesDirectory(lineIndex: index, keyColumn: keyColumn, lines: lines)
            var state = CommandRewriter.State()
            let value = run[4]
            if value.hasPrefix("|") || value.hasPrefix(">") {
                var i = index + 1
                while i < lines.count, Self.isBlank(lines[i]) || Self.indent(lines[i]) > keyColumn {
                    if !Self.isBlank(lines[i]) && !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("#") {
                        let indent = String(lines[i].prefix(Self.indent(lines[i])))
                        let body = String(lines[i].dropFirst(indent.count))
                        if let result = Self.rewriteShell(
                            body, line: i, file: file, context: context, state: &state, certain: certain,
                            warnings: &warnings) {
                            if result.mentioned && firstCommandLine == nil { firstCommandLine = i }
                            lines[i] = indent + result.text
                        }
                    }
                    i += 1
                }
                index = i
                continue
            }
            let (open, inner, close) = Self.unquote(value)
            if let result = Self.rewriteShell(
                inner, line: index, file: file, context: context, state: &state, certain: certain,
                warnings: &warnings) {
                if result.mentioned && firstCommandLine == nil { firstCommandLine = index }
                lines[index] = run[1] + run[2] + "run:" + run[3] + open + result.text + close
            }
            index += 1
        }

        if setupNodeSteps == 0, let line = firstCommandLine {
            warnings.append(RewriteWarning(
                file: file, line: line + 1,
                text: "No actions/setup-node step: add pnpm/action-setup@v4 before pnpm runs"))
        }
        warnings.sort { $0.line < $1.line }
        return FileRewrite(relativePath: file, original: text, rewritten: lines.joined(separator: "\n"), warnings: warnings)
    }

    private struct Step {
        /// Lines of the step, from its `- ` line up to (not including) the next line at or left of the dash.
        let range: Range<Int>
        let dashColumn: Int
    }

    /// The step (`- key: …` list item) that line `index` belongs to.
    private static func step(containing index: Int, in lines: [String]) -> Step? {
        var start = index
        if firstMatch(lines[index], #"^(\s*)(-\s+)"#) == nil {
            let keyColumn = indent(lines[index])
            while start > 0 {
                start -= 1
                if let match = firstMatch(lines[start], #"^(\s*)(-\s+)"#),
                   match[1].count + match[2].count == keyColumn { break }
                if !isBlank(lines[start]) && indent(lines[start]) < keyColumn { return nil }
            }
            guard firstMatch(lines[start], #"^(\s*)(-\s+)"#) != nil else { return nil }
        }
        let dashColumn = indent(lines[start])
        var end = start + 1
        while end < lines.count, isBlank(lines[end]) || indent(lines[end]) > dashColumn { end += 1 }
        // Trailing blank lines belong to whatever follows.
        while end > start + 1, isBlank(lines[end - 1]) { end -= 1 }
        return Step(range: start..<end, dashColumn: dashColumn)
    }

    /// True when the `run:` at `lineIndex` belongs to a step, or a workflow, whose `working-directory`
    /// is not the project root, so its commands may target a different project.
    private static func stepChangesDirectory(lineIndex: Int, keyColumn: Int, lines: [String]) -> Bool {
        if let step = step(containing: lineIndex, in: lines) {
            for i in step.range where i != lineIndex {
                if let match = firstMatch(lines[i], #"^(\s*)(-\s+)?working-directory:\s*(.*)$"#),
                   match[1].count + match[2].count == keyColumn, !isRootDirectory(match[3]) { return true }
            }
        }
        // `defaults: run: working-directory:` at job or workflow level.
        return lines.indices.contains { i in
            guard let match = firstMatch(lines[i], #"^\s+working-directory:\s*(.*)$"#),
                  !isRootDirectory(match[1]) else { return false }
            return isUnderDefaults(lineIndex: i, lines: lines)
        }
    }

    /// True when an ancestor key of line `lineIndex` is `defaults:`.
    private static func isUnderDefaults(lineIndex: Int, lines: [String]) -> Bool {
        var column = indent(lines[lineIndex])
        var i = lineIndex
        while i > 0, column > 0 {
            i -= 1
            guard !isBlank(lines[i]), indent(lines[i]) < column else { continue }
            if matches(lines[i], #"^\s*defaults:\s*$"#) { return true }
            column = indent(lines[i])
        }
        return false
    }

    private static func isRootDirectory(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: CharacterSet(charactersIn: " '\""))
        return trimmed == "." || trimmed == "./"
    }

    private static func rewriteCacheLine(_ line: String, context: RewriteContext) -> String {
        if let match = firstMatch(line, #"^(\s*cache:\s*)(['"]?)(npm|yarn)\2(\s*(#.*)?)$"#) {
            return match[1] + "pnpm" + match[4]
        }
        if let match = firstMatch(line, #"^(\s*cache-dependency-path:\s*)(.*)$"#) {
            return match[1] + replacingWord(context.oldLockfile, with: "pnpm-lock.yaml", in: match[2])
        }
        return line
    }

    // MARK: - Dockerfile

    public func rewriteDockerfile(text: String, file: String, from: PackageManager, context: RewriteContext) -> FileRewrite {
        var lines = text.components(separatedBy: "\n")
        var warnings: [RewriteWarning] = []
        var pnpmEnabled = false
        var continuesRun = false
        var state = CommandRewriter.State()
        for (index, original) in lines.enumerated() {
            let trimmed = original.trimmingCharacters(in: .whitespaces)
            let inRun = continuesRun
            continuesRun = trimmed.hasSuffix("\\") && (inRun || Self.instruction(trimmed) == "RUN")
            if inRun {
                if trimmed.hasPrefix("#") { continuesRun = true; continue }
                lines[index] = rewriteRunText(
                    original, line: index, file: file, context: context, state: &state,
                    pnpmEnabled: &pnpmEnabled, warnings: &warnings)
                continue
            }
            switch Self.instruction(trimmed) {
            case "COPY", "ADD":
                lines[index] = Self.rewriteCopy(original, context: context)
            case "RUN":
                state = CommandRewriter.State()
                let keyword = original.prefix { $0.isWhitespace }.count + 3
                let head = String(original.prefix(keyword))
                let body = String(original.dropFirst(keyword))
                if body.trimmingCharacters(in: .whitespaces).hasPrefix("[") {
                    if CommandRewriter.mentionsManager(body) {
                        warnings.append(RewriteWarning(file: file, line: index + 1, text: trimmed))
                    }
                } else {
                    lines[index] = head + rewriteRunText(
                        body, line: index, file: file, context: context, state: &state,
                        pnpmEnabled: &pnpmEnabled, warnings: &warnings)
                }
            default:
                break
            }
        }
        return FileRewrite(relativePath: file, original: text, rewritten: lines.joined(separator: "\n"), warnings: warnings)
    }

    private static let corepackInstall = "corepack enable && pnpm install --frozen-lockfile"

    private func rewriteRunText(
        _ text: String, line: Int, file: String, context: RewriteContext, state: inout CommandRewriter.State,
        pnpmEnabled: inout Bool, warnings: inout [RewriteWarning]
    ) -> String {
        let (body, continuation) = Self.splitContinuation(text)
        let result = CommandRewriter.rewriteLine(
            body, scripts: context.scripts, dependencyBins: context.dependencyBins, state: &state,
            installReplacement: Self.corepackInstall)
        for segment in result.uncertain {
            warnings.append(RewriteWarning(file: file, line: line + 1, text: segment))
        }
        if result.rewroteOther && !pnpmEnabled && !result.rewroteInstall {
            warnings.append(RewriteWarning(
                file: file, line: line + 1,
                text: body.trimmingCharacters(in: .whitespaces) + " — pnpm isn't enabled earlier in this Dockerfile"))
        }
        if result.rewroteInstall { pnpmEnabled = true }
        return result.text + continuation
    }

    /// The Dockerfile instruction keyword of a line, uppercased, or nil for blank and comment lines.
    private static func instruction(_ trimmed: String) -> String? {
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
        return String(trimmed.prefix { !$0.isWhitespace }).uppercased()
    }

    /// Points `COPY` and `ADD` sources at `pnpm-lock.yaml` instead of the old lockfile. A glob that
    /// matched the old lockfile (e.g. `package*.json`) gets `pnpm-lock.yaml` added beside it.
    private static func rewriteCopy(_ line: String, context: RewriteContext) -> String {
        let (body, continuation) = splitContinuation(line)
        let leading = String(body.prefix { $0.isWhitespace })
        var words = body.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard words.count >= 3, !words[1...].contains(where: { $0.hasPrefix("[") }) else { return line }
        let sources = (1..<(words.count - 1)).filter { !words[$0].hasPrefix("--") }
        if words.contains(where: { ($0 as NSString).lastPathComponent == "pnpm-lock.yaml" }) { return line }
        var changed = false
        for i in sources where (words[i] as NSString).lastPathComponent == context.oldLockfile {
            words[i] = String(words[i].dropLast(context.oldLockfile.count)) + "pnpm-lock.yaml"
            changed = true
        }
        if !changed, let glob = sources.first(where: { isGlob(words[$0], matching: context.oldLockfile) }) {
            let directory = (words[glob] as NSString).deletingLastPathComponent
            words.insert(directory.isEmpty ? "pnpm-lock.yaml" : directory + "/pnpm-lock.yaml", at: words.count - 1)
            changed = true
        }
        return changed ? leading + words.joined(separator: " ") + continuation : line
    }

    private static func isGlob(_ word: String, matching name: String) -> Bool {
        let last = (word as NSString).lastPathComponent
        guard last.contains(where: { "*?[".contains($0) }) else { return false }
        return fnmatch(last, name, 0) == 0
    }

    /// Splits a trailing ` \` line continuation (with the whitespace before it) off `text`.
    private static func splitContinuation(_ text: String) -> (String, String) {
        guard let match = firstMatch(text, #"^(.*?)(\s*\\\s*)$"#) else { return (text, "") }
        return (match[1], match[2])
    }

    // MARK: - JSON configs

    public func rewriteFirebase(text: String, file: String, from: PackageManager, context: RewriteContext) -> FileRewrite {
        rewriteJSON(text: text, file: file, context: context) { path in
            path.contains { $0 == .key("predeploy") || $0 == .key("postdeploy") } ? .command : nil
        }
    }

    public func rewriteVercel(text: String, file: String, from: PackageManager, context: RewriteContext) -> FileRewrite {
        rewriteJSON(text: text, file: file, context: context) { path in
            path == [.key("installCommand")] || path == [.key("buildCommand")] ? .command : nil
        }
    }

    public func rewritePackageJSON(text: String, file: String, from: PackageManager, context: RewriteContext) -> FileRewrite {
        rewriteJSON(text: text, file: file, context: context) { path in
            if path.count == 2 && path[0] == .key("scripts") { return .command }
            if path == [.key("packageManager")] { return .packageManager }
            return nil
        }
    }

    private enum JSONTarget {
        case command, packageManager
    }

    /// Rewrites the string values whose paths `target` selects, replacing only those literals in the text.
    private func rewriteJSON(
        text: String, file: String, context: RewriteContext, target: ([JSONPathComponent]) -> JSONTarget?
    ) -> FileRewrite {
        var bytes = Array(text.utf8)
        guard let tokens = try? JSONStringScanner.scan(bytes) else {
            return FileRewrite(relativePath: file, original: text, rewritten: text, warnings: [])
        }
        var warnings: [RewriteWarning] = []
        var replacements: [(Range<Int>, String)] = []
        for token in tokens {
            guard let kind = target(token.path) else { continue }
            let newValue: String
            switch kind {
            case .packageManager:
                guard token.value.hasPrefix("npm@") || token.value.hasPrefix("yarn@") else { continue }
                newValue = "pnpm@" + context.pnpmVersion
            case .command:
                var state = CommandRewriter.State()
                let result = CommandRewriter.rewriteLine(
                    token.value, scripts: context.scripts, dependencyBins: context.dependencyBins, state: &state)
                let line = bytes[..<token.range.lowerBound].filter { $0 == UInt8(ascii: "\n") }.count + 1
                warnings += result.uncertain.map { RewriteWarning(file: file, line: line, text: $0) }
                newValue = result.text
            }
            guard newValue != token.value,
                  let encoded = try? JSONSerialization.data(
                      withJSONObject: newValue, options: [.fragmentsAllowed, .withoutEscapingSlashes]),
                  let literal = String(data: encoded, encoding: .utf8) else { continue }
            replacements.append((token.range, literal))
        }
        for (range, literal) in replacements.reversed() {
            bytes.replaceSubrange(range, with: Array(literal.utf8))
        }
        return FileRewrite(
            relativePath: file, original: text, rewritten: String(decoding: bytes, as: UTF8.self), warnings: warnings)
    }

    // MARK: - netlify.toml

    public func rewriteNetlify(text: String, file: String, from: PackageManager, context: RewriteContext) -> FileRewrite {
        var lines = text.components(separatedBy: "\n")
        var warnings: [RewriteWarning] = []
        for (index, line) in lines.enumerated() {
            guard let match = Self.firstMatch(line, #"^(\s*command\s*=\s*)(["'])(.*)\2(\s*(#.*)?)$"#) else { continue }
            let (head, quote, value, tail) = (match[1], match[2], match[3], match[4])
            var state = CommandRewriter.State()
            // A basic string with escapes can't be edited safely as raw text.
            let certain = !(quote == "\"" && value.contains("\\"))
            if let result = Self.rewriteShell(
                value, line: index, file: file, context: context, state: &state, certain: certain, warnings: &warnings) {
                lines[index] = head + quote + result.text + quote + tail
            }
        }
        return FileRewrite(relativePath: file, original: text, rewritten: lines.joined(separator: "\n"), warnings: warnings)
    }

    // MARK: - Shared helpers

    /// Rewrites one shell line, appending a warning for each uncertain segment. Nil when the line
    /// mentions no package manager; `mentioned` is true when it does.
    private static func rewriteShell(
        _ text: String, line: Int, file: String, context: RewriteContext, state: inout CommandRewriter.State,
        certain: Bool, warnings: inout [RewriteWarning]
    ) -> (text: String, mentioned: Bool)? {
        guard CommandRewriter.mentionsManager(text) else {
            // Still track `cd` so later lines of the same script are judged correctly.
            _ = CommandRewriter.rewriteLine(text, scripts: [], dependencyBins: [], state: &state)
            return nil
        }
        let (body, continuation) = splitContinuation(text)
        let result = CommandRewriter.rewriteLine(
            body, scripts: context.scripts, dependencyBins: context.dependencyBins, state: &state, certain: certain)
        warnings += result.uncertain.map { RewriteWarning(file: file, line: line + 1, text: $0) }
        return (result.text + continuation, true)
    }

    /// Splits a YAML scalar's surrounding quotes off, when it is a single quoted string.
    private static func unquote(_ value: String) -> (String, String, String) {
        for quote in ["'", "\""] where value.count >= 2 && value.hasPrefix(quote) && value.hasSuffix(quote) {
            return (quote, String(value.dropFirst().dropLast()), quote)
        }
        return ("", value, "")
    }

    private static func replacingWord(_ word: String, with replacement: String, in text: String) -> String {
        let pattern = #"(?<![A-Za-z0-9._-])"# + NSRegularExpression.escapedPattern(for: word) + #"(?![A-Za-z0-9._-])"#
        return text.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
    }

    private static func indent(_ line: String) -> Int {
        line.prefix { $0 == " " }.count
    }

    private static func isBlank(_ line: String) -> Bool {
        line.allSatisfy(\.isWhitespace)
    }

    private static func matches(_ line: String, _ pattern: String) -> Bool {
        line.range(of: pattern, options: .regularExpression) != nil
    }

    /// Capture groups of the first match (index 0 is the whole match; unmatched groups are "").
    private static func firstMatch(_ line: String, _ pattern: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else { return nil }
        return (0..<match.numberOfRanges).map { group in
            Range(match.range(at: group), in: line).map { String(line[$0]) } ?? ""
        }
    }
}

// MARK: - JSON string scanner

enum JSONPathComponent: Hashable {
    case key(String)
    case index(Int)
}

/// Finds every string value in JSON text with its path and byte range, so single values can be
/// replaced without re-serialising (and reformatting) the whole document.
enum JSONStringScanner {
    struct Token {
        let path: [JSONPathComponent]
        /// Byte range of the literal, quotes included.
        let range: Range<Int>
        let value: String
    }

    struct Malformed: Error {}

    static func scan(_ bytes: [UInt8]) throws -> [Token] {
        var scanner = Scanner(bytes: bytes)
        try scanner.value(path: [])
        scanner.skipWhitespace()
        guard scanner.index == bytes.count else { throw Malformed() }
        return scanner.tokens
    }

    private struct Scanner {
        let bytes: [UInt8]
        var index = 0
        var tokens: [Token] = []

        init(bytes: [UInt8]) {
            self.bytes = bytes
        }

        mutating func skipWhitespace() {
            while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
        }

        mutating func value(path: [JSONPathComponent]) throws {
            skipWhitespace()
            guard index < bytes.count else { throw Malformed() }
            switch bytes[index] {
            case UInt8(ascii: "{"):
                index += 1
                skipWhitespace()
                if index < bytes.count, bytes[index] == UInt8(ascii: "}") {
                    index += 1
                    return
                }
                while true {
                    skipWhitespace()
                    let key = try string().value
                    skipWhitespace()
                    guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { throw Malformed() }
                    index += 1
                    try value(path: path + [.key(key)])
                    skipWhitespace()
                    guard index < bytes.count else { throw Malformed() }
                    if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                    if bytes[index] == UInt8(ascii: "}") { index += 1; return }
                    throw Malformed()
                }
            case UInt8(ascii: "["):
                index += 1
                skipWhitespace()
                if index < bytes.count, bytes[index] == UInt8(ascii: "]") {
                    index += 1
                    return
                }
                var position = 0
                while true {
                    try value(path: path + [.index(position)])
                    position += 1
                    skipWhitespace()
                    guard index < bytes.count else { throw Malformed() }
                    if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                    if bytes[index] == UInt8(ascii: "]") { index += 1; return }
                    throw Malformed()
                }
            case UInt8(ascii: "\""):
                let (range, decoded) = try string()
                tokens.append(Token(path: path, range: range, value: decoded))
            default:
                let start = index
                while index < bytes.count, !Array(",]} \t\r\n".utf8).contains(bytes[index]) { index += 1 }
                guard index > start else { throw Malformed() }
            }
        }

        mutating func string() throws -> (range: Range<Int>, value: String) {
            guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { throw Malformed() }
            let start = index
            index += 1
            while index < bytes.count, bytes[index] != UInt8(ascii: "\"") {
                index += bytes[index] == UInt8(ascii: "\\") ? 2 : 1
            }
            guard index < bytes.count else { throw Malformed() }
            index += 1
            let literal = Data(bytes[start..<index])
            guard let decoded = try? JSONSerialization.jsonObject(with: literal, options: .fragmentsAllowed) as? String
            else { throw Malformed() }
            return (start..<index, decoded)
        }
    }
}
