import Darwin
import Foundation

/// The helper's process ID in `helper.pid`, so the app and CLI can tell whether it is running.
public struct HelperHeartbeat: Sendable {
    private let paths: AppPaths

    public init(paths: AppPaths) {
        self.paths = paths
    }

    public func write(pid: Int32) throws {
        try paths.ensureExists()
        try Data("\(pid)\n".utf8).write(to: paths.helperPID, options: .atomic)
    }

    /// True when `helper.pid` names a process that exists.
    public func isAlive() -> Bool {
        guard let data = try? Data(contentsOf: paths.helperPID),
              let pid = Int32(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)),
              pid > 0
        else { return false }
        return kill(pid, 0) == 0
    }
}
