import Foundation

/// Rewrites npm, npx and yarn commands in one shell command line to pnpm, using a fixed table.
/// Anything outside the table is left exactly as it was and reported as uncertain.
public enum CommandRewriter {
    /// Splits `command` on `&&`, `||`, `;` and `|` (outside quotes) and rewrites each segment whose
    /// first word (after any `NAME=value` assignments) is `npm`, `npx` or `yarn`. `uncertain` holds,
    /// trimmed, every segment that mentions one of them but was left alone. `from` is accepted for
    /// symmetry with the config rewriters: npm, npx and yarn commands are rewritten whichever manager
    /// the project used.
    public static func rewrite(
        _ command: String, from: PackageManager, scripts: Set<String>, dependencyBins: Set<String>
    ) -> (String, uncertain: [String]) {
        var state = State()
        let line = rewriteLine(command, scripts: scripts, dependencyBins: dependencyBins, state: &state)
        return (line.text, line.uncertain)
    }

    // MARK: - Internal API for the config rewriters

    /// Carries what earlier commands did into later ones, across the lines of one script.
    struct State {
        /// A `cd` to somewhere other than `.` ran earlier, so later commands may target another project.
        var changedDirectory = false
    }

    struct Line {
        var text: String
        var uncertain: [String]
        /// A segment was an install (`npm ci`, `yarn install`, …) and was rewritten.
        var rewroteInstall = false
        /// A non-install segment was rewritten to pnpm.
        var rewroteOther = false
    }

    /// Rewrites one command line. `installReplacement`, when set, replaces every install form (the
    /// Dockerfile's `corepack enable && pnpm install --frozen-lockfile`). When `certain` is false,
    /// nothing is rewritten and every npm, npx or yarn segment is uncertain.
    static func rewriteLine(
        _ command: String, scripts: Set<String>, dependencyBins: Set<String>, state: inout State,
        installReplacement: String? = nil, certain: Bool = true
    ) -> Line {
        var line = Line(text: "", uncertain: [])
        for piece in split(command) {
            guard case .segment(let segment) = piece else {
                if case .separator(let separator) = piece { line.text += separator }
                continue
            }
            let leading = String(segment.prefix { $0.isWhitespace })
            let trailing = String(segment.reversed().prefix { $0.isWhitespace }.reversed())
            let body = segment.trimmingCharacters(in: .whitespaces)
            let words = words(body)
            var assignments = 0
            while assignments < words.count && isAssignment(words[assignments]) { assignments += 1 }
            let commandWords = Array(words[assignments...])

            if commandWords.first == "cd" {
                let target = commandWords.dropFirst().first
                if target != "." && target != "./" { state.changedDirectory = true }
            }
            guard let first = commandWords.first, Self.managers.contains(first) else {
                if words.contains(where: Self.managers.contains) { line.uncertain.append(body) }
                line.text += segment
                continue
            }
            let mapped = certain && !state.changedDirectory
                ? map(commandWords, scripts: scripts, dependencyBins: dependencyBins)
                : nil
            guard let mapped else {
                line.uncertain.append(body)
                line.text += segment
                continue
            }
            let replacement = mapped.isInstall ? (installReplacement ?? mapped.words.joined(separator: " "))
                : mapped.words.joined(separator: " ")
            if mapped.isInstall { line.rewroteInstall = true } else { line.rewroteOther = true }
            line.text += leading + (Array(words[..<assignments]) + [replacement]).joined(separator: " ") + trailing
        }
        return line
    }

    /// True when any word of `text` is `npm`, `npx` or `yarn`.
    static func mentionsManager(_ text: String) -> Bool {
        split(text).contains { piece in
            guard case .segment(let segment) = piece else { return false }
            return words(segment).contains(where: managers.contains)
        }
    }

    // MARK: - The command table

    private static let managers: Set<String> = ["npm", "npx", "yarn"]

    private struct Mapped {
        let words: [String]
        let isInstall: Bool
    }

    private static func map(_ words: [String], scripts: Set<String>, dependencyBins: Set<String>) -> Mapped? {
        let args = Array(words.dropFirst())
        switch words[0] {
        case "npm": return mapNpm(args)
        case "npx": return mapNpx(args, dependencyBins: dependencyBins)
        default: return mapYarn(args, scripts: scripts)
        }
    }

    private static func mapNpm(_ arguments: [String]) -> Mapped? {
        // Pull out `--prefix D` / `--prefix=D` that come before any `--`.
        var args: [String] = []
        var prefix: String?
        var index = 0
        while index < arguments.count {
            let word = arguments[index]
            if word == "--" {
                args += arguments[index...]
                break
            }
            if word == "--prefix", index + 1 < arguments.count, prefix == nil {
                prefix = arguments[index + 1]
                index += 2
                continue
            }
            if word.hasPrefix("--prefix="), prefix == nil {
                prefix = String(word.dropFirst("--prefix=".count))
                index += 1
                continue
            }
            args.append(word)
            index += 1
        }
        guard let subcommand = args.first else { return nil }
        let rest = Array(args.dropFirst())
        if prefix == nil {
            if subcommand == "ci" && rest.isEmpty { return Mapped(words: ["pnpm", "install", "--frozen-lockfile"], isInstall: true) }
            if (subcommand == "install" || subcommand == "i") && rest.isEmpty {
                return Mapped(words: ["pnpm", "install"], isInstall: true)
            }
            if (subcommand == "test" || subcommand == "start") && passesThrough(rest) {
                return Mapped(words: ["pnpm", subcommand] + rest, isInstall: false)
            }
        }
        if (subcommand == "run" || subcommand == "run-script"), let script = rest.first, passesThrough(Array(rest.dropFirst())) {
            let dir = prefix.map { ["--dir", $0] } ?? []
            return Mapped(words: ["pnpm"] + dir + ["run", script] + rest.dropFirst(), isInstall: false)
        }
        return nil
    }

    private static func mapNpx(_ arguments: [String], dependencyBins: Set<String>) -> Mapped? {
        var args = arguments[...]
        // `pnpm dlx` never prompts, so npx's "yes, install it" flag can go.
        while let first = args.first, first == "-y" || first == "--yes" { args = args.dropFirst() }
        guard let tool = args.first, !tool.hasPrefix("-") else { return nil }
        let runner = dependencyBins.contains(tool) ? "exec" : "dlx"
        return Mapped(words: ["pnpm", runner] + args, isInstall: false)
    }

    private static func mapYarn(_ args: [String], scripts: Set<String>) -> Mapped? {
        switch args {
        case [], ["install"]:
            return Mapped(words: ["pnpm", "install"], isInstall: true)
        case ["install", "--frozen-lockfile"], ["install", "--immutable"], ["--frozen-lockfile"], ["--immutable"]:
            return Mapped(words: ["pnpm", "install", "--frozen-lockfile"], isInstall: true)
        default:
            break
        }
        if args[0] == "run", args.count >= 2 {
            return Mapped(words: ["pnpm"] + args, isInstall: false)
        }
        if args[0] == "dlx", args.count >= 2 {
            return Mapped(words: ["pnpm"] + args, isInstall: false)
        }
        if scripts.contains(args[0]) {
            return Mapped(words: ["pnpm", "run"] + args, isInstall: false)
        }
        return nil
    }

    /// Arguments after a script name that pnpm passes on the same way npm does: none, or `-- …`.
    private static func passesThrough(_ rest: [String]) -> Bool {
        rest.isEmpty || rest[0] == "--"
    }

    private static func isAssignment(_ word: String) -> Bool {
        guard let equals = word.firstIndex(of: "="), equals != word.startIndex else { return false }
        let name = word[..<equals]
        return name.first.map { $0 == "_" || ($0.isASCII && $0.isLetter) } == true
            && name.allSatisfy { $0 == "_" || ($0.isASCII && ($0.isLetter || $0.isNumber)) }
    }

    // MARK: - Shell lexing

    private enum Piece {
        case segment(String)
        case separator(String)
    }

    /// Splits on `&&`, `||`, `;` and `|` outside single quotes, double quotes and backslash escapes.
    private static func split(_ command: String) -> [Piece] {
        var pieces: [Piece] = []
        var current = ""
        var quote: Character?
        var escaped = false
        let characters = Array(command)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if escaped {
                current.append(character)
                escaped = false
            } else if character == "\\" && quote != "'" {
                current.append(character)
                escaped = true
            } else if let open = quote {
                current.append(character)
                if character == open { quote = nil }
            } else if character == "'" || character == "\"" {
                current.append(character)
                quote = character
            } else if character == ";" {
                pieces += [.segment(current), .separator(";")]
                current = ""
            } else if (character == "&" || character == "|"), index + 1 < characters.count,
                      characters[index + 1] == character {
                pieces += [.segment(current), .separator(String([character, character]))]
                current = ""
                index += 1
            } else if character == "|" {
                pieces += [.segment(current), .separator("|")]
                current = ""
            } else {
                current.append(character)
            }
            index += 1
        }
        pieces.append(.segment(current))
        return pieces
    }

    /// Splits a segment into words on whitespace outside quotes, keeping each word's quotes.
    private static func words(_ segment: String) -> [String] {
        var words: [String] = []
        var current = ""
        var quote: Character?
        var escaped = false
        for character in segment {
            if escaped {
                current.append(character)
                escaped = false
            } else if character == "\\" && quote != "'" {
                current.append(character)
                escaped = true
            } else if let open = quote {
                current.append(character)
                if character == open { quote = nil }
            } else if character == "'" || character == "\"" {
                current.append(character)
                quote = character
            } else if character.isWhitespace {
                if !current.isEmpty { words.append(current) }
                current = ""
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { words.append(current) }
        return words
    }
}
