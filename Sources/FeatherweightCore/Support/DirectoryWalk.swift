import Foundation

extension FileManager.DirectoryEnumerator {
    /// Calls `body` with each URL until it returns false. Each entry gets its own autorelease pool
    /// that also covers `nextObject()`: in an app process every entry the enumerator fetches goes
    /// through FileProvider, which leaves autoreleased objects behind. Without a pool around the
    /// fetch they pile up for the whole walk, which over a few hundred thousand entries is gigabytes
    /// on a background thread whose pool drains only when it exits.
    func forEachURL(_ body: (URL) -> Bool) {
        while true {
            let keepGoing = autoreleasepool { () -> Bool in
                guard let next = nextObject() else { return false }
                guard let url = next as? URL else { return true }
                return body(url)
            }
            if !keepGoing { return }
        }
    }
}
