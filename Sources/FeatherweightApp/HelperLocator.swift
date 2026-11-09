import Foundation

/// Where the background helper and the command-line tool live.
///
/// Inside a `.app` bundle they are in the bundle; when running from the build folder
/// (`swift run`) they sit next to the app's own executable.
enum HelperLocator {
    static func helperExecutable(bundle: Bundle = .main, executable: URL? = Bundle.main.executableURL) -> URL {
        locate(
            bundled: "Contents/Library/LoginItems/Featherweight Helper.app/Contents/MacOS/FeatherweightHelper",
            sibling: "FeatherweightHelper", bundle: bundle, executable: executable)
    }

    static func cliExecutable(bundle: Bundle = .main, executable: URL? = Bundle.main.executableURL) -> URL {
        locate(bundled: "Contents/Helpers/featherweight", sibling: "featherweight", bundle: bundle, executable: executable)
    }

    private static func locate(bundled: String, sibling: String, bundle: Bundle, executable: URL?) -> URL {
        if bundle.bundleURL.pathExtension == "app" {
            return bundle.bundleURL.appendingPathComponent(bundled)
        }
        let directory = (executable ?? URL(fileURLWithPath: CommandLine.arguments[0]))
            .resolvingSymlinksInPath().deletingLastPathComponent()
        return directory.appendingPathComponent(sibling)
    }
}
