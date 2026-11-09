import Foundation

public enum AppVersion {
    /// `CFBundleShortVersionString` of the `.app` enclosing this executable (found by resolving
    /// symlinks on `CommandLine.arguments[0]`), or "dev" when not running from inside an app.
    public static var current: String {
        guard let executable = CommandLine.arguments.first else { return "dev" }
        return version(ofAppEnclosing: URL(fileURLWithPath: executable)) ?? "dev"
    }

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
