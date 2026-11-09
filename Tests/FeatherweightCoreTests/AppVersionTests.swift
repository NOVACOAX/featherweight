import Foundation
import Testing

@testable import FeatherweightCore

struct AppVersionTests {
    private static let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict>
        <key>CFBundleShortVersionString</key><string>1.2.3</string>
        </dict></plist>
        """

    @Test func readsVersionFromEnclosingApp() throws {
        let tree = try TempTree([
            "Featherweight.app/Contents/Info.plist": Self.plist,
            "Featherweight.app/Contents/Resources/featherweight": "",
        ])
        let executable = tree.url("Featherweight.app/Contents/Resources/featherweight")
        #expect(AppVersion.version(ofAppEnclosing: executable) == "1.2.3")
    }

    @Test func followsSymlinkIntoApp() throws {
        let tree = try TempTree([
            "Featherweight.app/Contents/Info.plist": Self.plist,
            "Featherweight.app/Contents/Resources/featherweight": "",
            "bin/": "",
        ])
        let link = tree.url("bin/featherweight")
        try FileManager.default.createSymbolicLink(
            at: link, withDestinationURL: tree.url("Featherweight.app/Contents/Resources/featherweight"))
        #expect(AppVersion.version(ofAppEnclosing: link) == "1.2.3")
    }

    @Test func nilOutsideAnApp() throws {
        let tree = try TempTree(["bin/featherweight": ""])
        #expect(AppVersion.version(ofAppEnclosing: tree.url("bin/featherweight")) == nil)
    }
}
