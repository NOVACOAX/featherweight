import Foundation

public enum CustomCacheFolderError: Error, Equatable, LocalizedError {
    /// Not a folder name that is safe to clear inside a project.
    case invalid
    /// Already in the list (compared ignoring case).
    case duplicate(String)

    public var errorDescription: String? {
        switch self {
        case .invalid:
            "That isn't a usable folder name. Use a folder inside the project, like .astro or node_modules/.parcel-cache. "
                + "It can't start with a slash, contain .. or .git, or be node_modules itself."
        case .duplicate(let name):
            "\(name) is already in the list."
        }
    }
}

extension CacheFolderSetting {
    /// A new, enabled cache folder for the name the user typed. Surrounding spaces and trailing
    /// slashes are dropped; the result must pass `isSafeRelativePath`.
    public static func custom(named input: String, existing: [CacheFolderSetting]) throws -> CacheFolderSetting {
        var name = input.trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasSuffix("/") { name.removeLast() }
        guard isSafeRelativePath(name) else { throw CustomCacheFolderError.invalid }
        func folded(_ text: String) -> String {
            text.precomposedStringWithCanonicalMapping.folding(options: .caseInsensitive, locale: nil)
        }
        if existing.contains(where: { folded($0.relativePath) == folded(name) }) {
            throw CustomCacheFolderError.duplicate(name)
        }
        return CacheFolderSetting(relativePath: name, enabled: true, isBuiltIn: false)
    }
}
