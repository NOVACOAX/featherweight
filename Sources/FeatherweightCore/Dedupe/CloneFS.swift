import Darwin
import Foundation

/// File identity and APFS block-sharing facts for one path (never follows symlinks).
public struct CloneInfo: Equatable, Sendable {
    public let device: UInt64
    public let inode: UInt64
    public let linkCount: UInt32
    public let size: Int64
    /// Bytes allocated to the file, shared or not.
    public let allocatedSize: Int64
    /// Bytes freed if this file were deleted (blocks not shared with any clone).
    public let privateSize: Int64
    public let mtimeNanos: Int64
    public let cloneID: UInt64
    public let sharesAllBlocks: Bool
    public let isRegularFile: Bool
}

public enum CloneError: Error {
    case notRegularFile
    case differentVolume
    case changedDuringReplace
    /// A failed system call: its name and `errno`.
    case system(String, Int32)
}

public enum CloneFS {
    /// Reads identity and clone facts with `lstat` plus `getattrlist` (common extended attributes).
    /// Clone attributes the volume does not return are reported as 0 / false.
    public static func info(at url: URL) throws -> CloneInfo {
        let path = url.path
        let st = try lstatOrThrow(path)

        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS)
        // With FSOPT_ATTR_CMN_EXTENDED, `forkattr` carries the ATTR_CMNEXT_* bits.
        request.forkattr = attrgroup_t(attrPrivateSize | attrCloneID | attrExtFlags)
        let options = UInt32(FSOPT_NOFOLLOW) | UInt32(FSOPT_ATTR_CMN_EXTENDED)

        // u_int32_t length, attribute_set_t returned, then the requested attributes.
        var buffer = [UInt8](repeating: 0, count: 128)
        let rc = buffer.withUnsafeMutableBytes { raw in
            getattrlist(path, &request, raw.baseAddress, raw.count, options)
        }
        if rc != 0 { throw CloneError.system("getattrlist", errno) }

        var privateSize: Int64 = 0
        var cloneID: UInt64 = 0
        var extFlags: UInt64 = 0
        buffer.withUnsafeBytes { raw in
            let length = Int(raw.loadUnaligned(fromByteOffset: 0, as: UInt32.self))
            let returned = raw.loadUnaligned(fromByteOffset: 4, as: attribute_set_t.self)
            var offset = 4 + MemoryLayout<attribute_set_t>.size
            // Common extended attributes are packed in ascending bit order.
            func next<T>(_ bit: UInt32, _: T.Type) -> T? {
                guard returned.forkattr & bit != 0,
                      offset + MemoryLayout<T>.size <= min(length, raw.count) else { return nil }
                defer { offset += MemoryLayout<T>.size }
                return raw.loadUnaligned(fromByteOffset: offset, as: T.self)
            }
            if let v = next(attrPrivateSize, Int64.self) { privateSize = v }
            if let v = next(attrCloneID, UInt64.self) { cloneID = v }
            if let v = next(attrExtFlags, UInt64.self) { extFlags = v }
        }

        return CloneInfo(
            device: UInt64(UInt32(bitPattern: st.st_dev)),
            inode: st.st_ino,
            linkCount: UInt32(st.st_nlink),
            size: Int64(st.st_size),
            allocatedSize: Int64(st.st_blocks) * 512,
            privateSize: privateSize,
            mtimeNanos: mtimeNanos(st),
            cloneID: cloneID,
            sharesAllBlocks: extFlags & UInt64(EF_SHARES_ALL_BLOCKS) != 0,
            isRegularFile: st.st_mode & S_IFMT == S_IFREG
        )
    }

    /// Atomically replaces `duplicate` with an APFS clone of `keeper`, keeping the duplicate's
    /// mode, owner, times, xattrs and ACL. On any failure the duplicate is left untouched and
    /// the temporary clone is removed. `beforeRename` runs last, just before the duplicate is
    /// re-checked and replaced; a throw from it aborts the replace.
    public static func replaceWithClone(
        of keeper: URL, replacing duplicate: URL, beforeRename: (() throws -> Void)? = nil
    ) throws {
        let keeperPath = keeper.path
        let dupPath = duplicate.path
        let keeperStat = try lstatOrThrow(keeperPath)
        let dupStat = try lstatOrThrow(dupPath)
        guard keeperStat.st_mode & S_IFMT == S_IFREG, dupStat.st_mode & S_IFMT == S_IFREG else {
            throw CloneError.notRegularFile
        }
        guard keeperStat.st_dev == dupStat.st_dev else { throw CloneError.differentVolume }

        let dir = (dupPath as NSString).deletingLastPathComponent
        let name = (dupPath as NSString).lastPathComponent
        let tmp = dir + "/." + name + ".fw-" + UUID().uuidString

        if clonefile(keeperPath, tmp, UInt32(CLONE_NOFOLLOW)) != 0 {
            let err = errno
            throw err == EXDEV ? CloneError.differentVolume : CloneError.system("clonefile", err)
        }
        do {
            // Replaces the clone's xattrs (inherited from the keeper) and ACL with the duplicate's.
            if copyfile(dupPath, tmp, nil, copyfile_flags_t(COPYFILE_XATTR | COPYFILE_ACL)) != 0 {
                throw CloneError.system("copyfile", errno)
            }
            // Owner before mode: chown can clear setuid/setgid bits.
            if lchown(tmp, dupStat.st_uid, dupStat.st_gid) != 0 {
                let err = errno
                let current = try lstatOrThrow(tmp)
                let alreadyMatches = current.st_uid == dupStat.st_uid && current.st_gid == dupStat.st_gid
                if !(err == EPERM && alreadyMatches) { throw CloneError.system("lchown", err) }
            }
            if chmod(tmp, dupStat.st_mode & 0o7777) != 0 { throw CloneError.system("chmod", errno) }
            let times = [dupStat.st_atimespec, dupStat.st_mtimespec]
            if utimensat(AT_FDCWD, tmp, times, AT_SYMLINK_NOFOLLOW) != 0 {
                throw CloneError.system("utimensat", errno)
            }

            try beforeRename?()

            let now = try lstatOrThrow(dupPath)
            guard now.st_ino == dupStat.st_ino, now.st_size == dupStat.st_size,
                  mtimeNanos(now) == mtimeNanos(dupStat) else {
                throw CloneError.changedDuringReplace
            }
            if rename(tmp, dupPath) != 0 { throw CloneError.system("rename", errno) }
        } catch {
            unlink(tmp)
            throw error
        }
    }

    /// Sum of `privateSize` over the regular files under `directory`, without following symlinks.
    public static func privateBytes(under directory: URL) -> Int64 {
        guard let walker = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: nil, options: [], errorHandler: { _, _ in true })
        else { return 0 }
        var total: Int64 = 0
        for case let url as URL in walker {
            if let info = try? info(at: url), info.isRegularFile { total += info.privateSize }
        }
        return total
    }

    // <sys/attr.h> common extended attributes (requested via `forkattr`).
    private static let attrPrivateSize = UInt32(ATTR_CMNEXT_PRIVATESIZE)  // 0x8, off_t
    private static let attrCloneID = UInt32(ATTR_CMNEXT_CLONEID)  // 0x100, u_int64_t
    private static let attrExtFlags = UInt32(ATTR_CMNEXT_EXT_FLAGS)  // 0x200, u_int64_t

    private static func lstatOrThrow(_ path: String) throws -> stat {
        var st = stat()
        if lstat(path, &st) != 0 { throw CloneError.system("lstat", errno) }
        return st
    }

    private static func mtimeNanos(_ st: stat) -> Int64 {
        Int64(st.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(st.st_mtimespec.tv_nsec)
    }
}
