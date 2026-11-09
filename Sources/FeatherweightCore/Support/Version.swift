import Foundation

public enum AppVersion {
    /// `CFBundleShortVersionString` of the `.app` enclosing this executable, or "dev" when not
    /// running from inside an app. The real executable path is tried first (so a bare
    /// `featherweight` found through PATH still works); `CommandLine.arguments[0]` is only a fallback.
    public static var current: String {
        let candidates = [Bundle.main.executablePath, CommandLine.arguments.first].compactMap { $0 }
        for path in candidates {
            if let version = version(ofAppEnclosing: URL(fileURLWithPath: path)) { return version }
        }
        return "dev"
    }

    /// Resolves symlinks on `executable`, then walks up to the enclosing `.app`.
    static func version(ofAppEnclosing executable: URL) -> String? {
        var directory = executable.resolvingSymlinksInPath().deletingLastPathComponent()
        while directory.path != "/" {
            if directory.pathExtension == "app" {
                let plist = directory.appendingPathComponent("Contents/Info.plist")
                guard let data = try? Data(contentsOf: plist),
                      let info = try? PropertyListSerialization.propertyList(from: data, format: nil)
                          as? [String: Any]
                else { return nil }
                return info["CFBundleShortVersionString"] as? String
            }
            directory = directory.deletingLastPathComponent()
        }
        return nil
    }
}
