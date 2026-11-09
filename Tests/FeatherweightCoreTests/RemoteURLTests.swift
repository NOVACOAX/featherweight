import Testing

@testable import FeatherweightCore

@Suite struct RemoteURLTests {
    @Test func hostAndPathDropsCredentialsInEveryForm() {
        let cases: [(String, String)] = [
            ("https://user:token@github.com/org/repo.git", "github.com/org/repo"),
            ("https://ghp_secret@github.com/org/repo", "github.com/org/repo"),
            ("https://github.com/org/repo", "github.com/org/repo"),
            ("ssh://git@github.com:2222/org/repo.git", "github.com:2222/org/repo"),
            ("git@github.com:org/repo.git", "github.com/org/repo"),
            ("git@host:/abs/path.git", "host/abs/path"),
            ("user:token@github.com/org/repo", "github.com/org/repo"),
            ("user:token@github.com/org/repo.git", "github.com/org/repo"),
            ("https://user:p@ss@github.com/org/repo.git", "github.com/org/repo"),
            ("user:p@ss@github.com/org/repo", "github.com/org/repo"),
            ("file:///Users/h/Remotes/lamp.git", "/Users/h/Remotes/lamp"),
            ("/Users/h/Remotes/lamp.git", "/Users/h/Remotes/lamp"),
            ("  https://tok@host.com/  ", "host.com"),
        ]
        for (remote, expected) in cases {
            #expect(RemoteURL.hostAndPath(remote) == expected, "\(remote)")
        }
    }

    @Test func hostAndPathIsNilWhenThereIsNothingToShow() {
        #expect(RemoteURL.hostAndPath("") == nil)
        #expect(RemoteURL.hostAndPath("   ") == nil)
    }

    @Test func withoutCredentialsKeepsTheRestOfTheURL() {
        #expect(RemoteURL.withoutCredentials("https://user:token@github.com/org/repo.git") == "https://github.com/org/repo.git")
        #expect(RemoteURL.withoutCredentials("ssh://git@host:2222/org/repo.git") == "ssh://host:2222/org/repo.git")
        #expect(RemoteURL.withoutCredentials("git@github.com:org/repo.git") == "github.com:org/repo.git")
        #expect(RemoteURL.withoutCredentials("user:token@github.com/org/repo") == "github.com/org/repo")
        #expect(RemoteURL.withoutCredentials("https://user:p@ss@github.com/org/repo") == "https://github.com/org/repo")
        #expect(RemoteURL.withoutCredentials("file:///Users/h/lamp.git") == "file:///Users/h/lamp.git")
        #expect(RemoteURL.withoutCredentials("/Users/h/lamp.git") == "/Users/h/lamp.git")
        #expect(RemoteURL.withoutCredentials("https://github.com/org/repo") == "https://github.com/org/repo")
    }

    @Test func anAtSignInThePathIsNotUserInfo() {
        #expect(RemoteURL.withoutCredentials("https://github.com/org/re@po.git") == "https://github.com/org/re@po.git")
        #expect(RemoteURL.hostAndPath("https://tok@github.com/@scope/pkg.git") == "github.com/@scope/pkg")
    }
}
