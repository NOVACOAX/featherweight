import Darwin
import Foundation

/// The helper's process ID in `helper.pid`, so the app and CLI can tell whether it is running.
public struct HelperHeartbeat: Sendable {
    private let paths: AppPaths
    private let processName: String

    /// `processName` is the helper's executable name (injectable for tests).
    public init(paths: AppPaths, processName: String = "FeatherweightHelper") {
        self.paths = paths
        self.processName = processName
    }

    public func write(pid: Int32) throws {
        try paths.ensureExists()
        try Data("\(pid)\n".utf8).write(to: paths.helperPID, options: .atomic)
    }

    /// True when `helper.pid` names a running process whose executable is the helper (a stale pid
    /// may since have been reused by another program).
    public func isAlive() -> Bool {
        guard let data = try? Data(contentsOf: paths.helperPID),
              let pid = Int32(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)),
              pid > 0, kill(pid, 0) == 0
        else { return false }
        return Self.executablePath(of: pid).map { URL(fileURLWithPath: $0).lastPathComponent == processName } ?? false
    }

    private static func executablePath(of pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
