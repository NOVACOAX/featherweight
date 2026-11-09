import Foundation

/// Helpers for a git remote's URL, which may carry credentials (`https://user:token@host/...`).
public enum RemoteURL {
    /// The remote without its user info: everything up to the last `@` that occurs before the path
    /// begins is dropped, whether or not there is a scheme.
    ///
    /// - `https://user:token@github.com/org/repo.git` -> `https://github.com/org/repo.git`
    /// - `git@github.com:org/repo.git` -> `github.com:org/repo.git`
    /// - `user:token@github.com/org/repo` -> `github.com/org/repo`
    /// - local paths and `file://` URLs are returned as they are.
    public static func withoutCredentials(_ remote: String) -> String {
        let text = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        if let scheme = text.range(of: "://") {
            let rest = text[scheme.upperBound...]
            let authorityEnd = rest.firstIndex(of: "/") ?? rest.endIndex
            return String(text[..<scheme.upperBound]) + droppingUserInfo(rest[..<authorityEnd]) + rest[authorityEnd...]
        }
        // A local path has no user info.
        if text.hasPrefix("/") || text.hasPrefix(".") || text.hasPrefix("~") { return text }
        // `[user[:password]@]host[:path]` or `host/path`: the path starts at the first "/".
        let pathStart = text.firstIndex(of: "/") ?? text.endIndex
        return droppingUserInfo(text[..<pathStart]) + text[pathStart...]
    }

    /// What people recognise, without credentials: `https://user:token@github.com/org/repo.git`
    /// and `git@github.com:org/repo.git` both become `github.com/org/repo`. A local path stays a
    /// path. Nil when there is nothing to show.
    public static func hostAndPath(_ remote: String) -> String? {
        var text = withoutCredentials(remote)
        if let scheme = text.range(of: "://") {
            text = String(text[scheme.upperBound...])
        } else if !text.hasPrefix("/"), let colon = text.firstIndex(of: ":"), !text[..<colon].contains("/") {
            // scp-style `host:path`
            let path = text[text.index(after: colon)...].drop { $0 == "/" }
            text = text[..<colon] + "/" + path
        }
        while text.hasSuffix("/") { text.removeLast() }
        if text.hasSuffix(".git") { text.removeLast(4) }
        return text.isEmpty ? nil : text
    }

    private static func droppingUserInfo(_ authority: Substring) -> String {
        guard let at = authority.lastIndex(of: "@") else { return String(authority) }
        return String(authority[authority.index(after: at)...])
    }
}
