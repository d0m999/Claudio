import Darwin
import Foundation

/// 配置文件末段是符号链接时的明确策略。Claude/Codex 用户配置常由 dotfiles 管理，
/// `.preserveTarget` 会原子改写目标而不替换链接节点；不允许的调用方可选择 `.reject`。
public enum ConfigFileSymlinkPolicy: Sendable, Equatable {
    case preserveTarget
    case reject
}

public enum ConfigFileTransactionOutcome: Sendable, Equatable {
    case unchanged
    case written
}

public enum ConfigFileTransactionError: Error, Sendable, Equatable, CustomStringConvertible {
    case notWritable(reason: String)
    case readFailure(path: String)
    case parseFailure(reason: String)
    case malformedTopLevel(path: String)
    case mutationRejected(reason: String)
    case backupFailure(reason: String)
    case writeFailure(reason: String)
    case concurrentModification(path: String)
    case symlinkRejected(path: String)
    case danglingSymlink(path: String)
    case lockBusy
    case lockFailed(errno: Int32)

    public var description: String {
        switch self {
        case .notWritable(let reason): reason
        case .readFailure(let path): "配置文件无法安全读取：\(path)"
        case .parseFailure(let reason): "配置文件 JSON 解析失败，未修改：\(reason)"
        case .malformedTopLevel(let path): "配置文件顶层必须是 JSON object，未修改：\(path)"
        case .mutationRejected(let reason): reason
        case .backupFailure(let reason): "配置文件备份失败，未修改：\(reason)"
        case .writeFailure(let reason): "配置文件原子写入失败：\(reason)"
        case .concurrentModification(let path):
            "配置文件在读取与写入之间被外部修改，已放弃本次写入：\(path)"
        case .symlinkRejected(let path): "该配置事务不允许符号链接：\(path)"
        case .danglingSymlink(let path):
            "配置文件是目标不存在的符号链接，已停止写入以保留 dotfiles 链接：\(path)"
        case .lockBusy: "配置文件正被另一个 Claudio 操作占用，请重试"
        case .lockFailed(let errno): "配置文件锁获取失败（errno \(errno)）"
        }
    }
}

/// schema 变换对事务层的唯一回答：不写，或用一棵新 JSON object 原子替换。
public enum ConfigFileMutation {
    case unchanged
    case replace([String: Any])
}

/// 两个宿主 adapter 共用的深层配置事务。
///
/// 它只处理锁、一次备份、有界读取、JSON 安全编码、CAS、符号链接与原子替换；
/// `hooks` 的 schema 和“哪些条目属于 Claudio”完全由 adapter 的纯变换负责。
public struct ConfigFileTransaction {
    private enum FileContentsSnapshot: Equatable {
        case missing
        case bytes(Data)
        case unreadable
    }

    /// CAS 不能只看目标字节：`.preserveTarget` 的链接在读写间改指到
    /// 另一份同字节文件，仍是外部修改。同时把读取时解析到的目标钉住，
    /// CAS 通过后也不会再解析一次并误写到新目标。
    private struct FileSnapshot: Equatable {
        let contents: FileContentsSnapshot
        let resolvedDestinationPath: String
        /// `fileExists` follows the final symlink, so a dangling link otherwise looks exactly
        /// like a genuinely missing path. Preserve the leaf node kind in the CAS baseline to
        /// stop a concurrent missing -> dangling-link replacement from being overwritten.
        let leafIsSymbolicLink: Bool
        /// Preserve the leaf link's literal payload as well as its resolved target. On APFS two
        /// NFC/NFD spellings may resolve to the same inode, while on NFS/SMB they can name distinct
        /// files. Either way, retargeting the dotfiles node is an external mutation.
        let leafSymbolicLinkDestination: Data?

        static func == (lhs: FileSnapshot, rhs: FileSnapshot) -> Bool {
            lhs.contents == rhs.contents
                && utf8BytesEqual(
                    lhs.resolvedDestinationPath, rhs.resolvedDestinationPath)
                && lhs.leafIsSymbolicLink == rhs.leafIsSymbolicLink
                && lhs.leafSymbolicLinkDestination == rhs.leafSymbolicLinkDestination
        }
    }

    public let file: URL
    public let lockFile: URL
    public let backupFile: URL?
    public let symlinkPolicy: ConfigFileSymlinkPolicy
    public let maximumBytes: Int
    private let exclusiveRename: (String, String) -> Int32

    public init(
        file: URL,
        lockFile: URL,
        backupFile: URL? = nil,
        symlinkPolicy: ConfigFileSymlinkPolicy = .preserveTarget,
        maximumBytes: Int = 1 << 20
    ) {
        self.init(
            file: file,
            lockFile: lockFile,
            backupFile: backupFile,
            symlinkPolicy: symlinkPolicy,
            maximumBytes: maximumBytes,
            exclusiveRename: configFileExclusiveRename)
    }

    #if DEBUG
    /// Filesystem capability seam: tests force `ENOTSUP` while still observing the complete
    /// public transaction. Production always uses `renameatx_np(RENAME_EXCL)` first.
    public init(
        file: URL,
        lockFile: URL,
        backupFile: URL? = nil,
        symlinkPolicy: ConfigFileSymlinkPolicy = .preserveTarget,
        maximumBytes: Int = 1 << 20,
        testingExclusiveRename: @escaping (String, String) -> Int32
    ) {
        self.init(
            file: file,
            lockFile: lockFile,
            backupFile: backupFile,
            symlinkPolicy: symlinkPolicy,
            maximumBytes: maximumBytes,
            exclusiveRename: testingExclusiveRename)
    }
    #endif

    private init(
        file: URL,
        lockFile: URL,
        backupFile: URL?,
        symlinkPolicy: ConfigFileSymlinkPolicy,
        maximumBytes: Int,
        exclusiveRename: @escaping (String, String) -> Int32
    ) {
        self.file = file
        self.lockFile = lockFile
        self.backupFile = backupFile
        self.symlinkPolicy = symlinkPolicy
        self.maximumBytes = maximumBytes
        self.exclusiveRename = exclusiveRename
    }

    public func update(
        _ mutate: ([String: Any]) -> ConfigFileMutation
    ) -> Result<ConfigFileTransactionOutcome, ConfigFileTransactionError> {
        updateLocked(mutate, betweenReadAndWrite: nil)
    }

    #if DEBUG
    public func update(
        _ mutate: ([String: Any]) -> ConfigFileMutation,
        betweenReadAndWrite: (() -> Void)?,
        beforeFinalPublish: (() -> Void)? = nil
    ) -> Result<ConfigFileTransactionOutcome, ConfigFileTransactionError> {
        updateLocked(
            mutate,
            betweenReadAndWrite: betweenReadAndWrite,
            beforeFinalPublish: beforeFinalPublish)
    }
    #endif

    private func updateLocked(
        _ mutate: ([String: Any]) -> ConfigFileMutation,
        betweenReadAndWrite: (() -> Void)?,
        beforeFinalPublish: (() -> Void)? = nil
    ) -> Result<ConfigFileTransactionOutcome, ConfigFileTransactionError> {
        let locked = withNonBlockingLock(path: lockFile.path) {
            // Keep the policy gate under the same lock as the snapshot. Checking only before
            // `flock` leaves a TOCTOU window where the leaf can become a symlink before read.
            if symlinkPolicy == .reject, isSymbolicLink(at: file) {
                return Result<ConfigFileTransactionOutcome, ConfigFileTransactionError>.failure(
                    .symlinkRejected(path: file.path))
            }
            if symlinkPolicy == .preserveTarget,
                leafNodeIsSymbolicLink(at: file),
                !FileManager.default.fileExists(atPath: file.path)
            {
                return .failure(.danglingSymlink(path: file.path))
            }
            if case .notWritable(let reason) = probeSettingsWritable(settingsFile: file) {
                return .failure(.notWritable(reason: reason))
            }
            return performUpdate(
                mutate,
                betweenReadAndWrite: betweenReadAndWrite,
                beforeFinalPublish: beforeFinalPublish)
        }
        switch locked {
        case .ran(let result): return result
        case .skipped: return .failure(.lockBusy)
        case .failed(let errno): return .failure(.lockFailed(errno: errno))
        }
    }

    private func performUpdate(
        _ mutate: ([String: Any]) -> ConfigFileMutation,
        betweenReadAndWrite: (() -> Void)?,
        beforeFinalPublish: (() -> Void)?
    ) -> Result<ConfigFileTransactionOutcome, ConfigFileTransactionError> {
        let loaded: (root: [String: Any], snapshot: FileSnapshot)
        switch loadJSONObject() {
        case .success(let value): loaded = value
        case .failure(let error): return .failure(error)
        }

        let nextRoot: [String: Any]
        switch mutate(loaded.root) {
        case .unchanged:
            return .success(.unchanged)
        case .replace(let replacement):
            nextRoot = replacement
        }

        let encoded: Data
        switch encodeJSONObjectForWriting(nextRoot, path: file.path) {
        case .success(let data): encoded = data
        case .failure(let rejection):
            return .failure(.mutationRejected(reason: rejection.reason))
        }
        guard encoded.count <= maximumBytes else {
            return .failure(
                .mutationRejected(
                    reason:
                        "配置编码后为 \(encoded.count) 字节，超过 maximumBytes "
                        + "上限 \(maximumBytes) 字节，未修改文件"))
        }

        betweenReadAndWrite?()
        // The policy check must live inside the transaction lock and be repeated at the
        // publication boundary. A regular file can be replaced by an identical-byte symlink
        // after the initial read; byte-only CAS would otherwise accept it and rename over the
        // newly-created link node.
        if symlinkPolicy == .reject, isSymbolicLink(at: file) {
            return .failure(.symlinkRejected(path: file.path))
        }
        guard currentSnapshot() == loaded.snapshot else {
            return .failure(.concurrentModification(path: file.path))
        }

        let loadedDestination = URL(fileURLWithPath: loaded.snapshot.resolvedDestinationPath)
        if let backupFile, case .bytes(let original) = loaded.snapshot.contents,
            !FileManager.default.fileExists(atPath: backupFile.path)
        {
            do {
                try secureAtomicPublish(
                    original,
                    to: backupFile,
                    permissions: filePermissions(at: loadedDestination),
                    replaceExisting: false,
                    exclusiveRename: exclusiveRename)
            } catch {
                return .failure(.backupFailure(reason: error.localizedDescription))
            }
        }

        do {
            try secureAtomicPublish(
                encoded,
                to: loadedDestination,
                permissions: filePermissions(at: loadedDestination),
                replaceExisting: true,
                exclusiveRename: exclusiveRename,
                beforeRename: {
                    // Staging and the one-time backup can take arbitrarily long. External editors
                    // do not share Claudio's lock, so the CAS that authorizes replacement must run
                    // after all of that work, immediately beside the final rename boundary.
                    beforeFinalPublish?()
                    if symlinkPolicy == .reject, isSymbolicLink(at: file) {
                        throw ConfigFileTransactionError.symlinkRejected(path: file.path)
                    }
                    guard currentSnapshot() == loaded.snapshot else {
                        throw ConfigFileTransactionError.concurrentModification(path: file.path)
                    }
                })
            return .success(.written)
        } catch let error as ConfigFileTransactionError {
            return .failure(error)
        } catch {
            return .failure(.writeFailure(reason: error.localizedDescription))
        }
    }

    private func loadJSONObject()
        -> Result<(root: [String: Any], snapshot: FileSnapshot), ConfigFileTransactionError>
    {
        let leafWasSymbolicLink = isSymbolicLink(at: file)
        if symlinkPolicy == .reject, leafWasSymbolicLink {
            return .failure(.symlinkRejected(path: file.path))
        }
        if symlinkPolicy == .preserveTarget,
            leafWasSymbolicLink,
            !FileManager.default.fileExists(atPath: file.path)
        {
            // `URL.resolvingSymlinksInPath()` 不会解析 dangling 的最后一段。若继续把它
            // 当作普通 missing 文件，最终 rename 会替换 symlink 节点，令 dotfiles 管理
            // 静默失效。目标不存在时没有可安全保留的写入目的地，明确 fail closed。
            return .failure(.danglingSymlink(path: file.path))
        }
        let destinationBeforeRead = resolvedDestinationPath()
        let linkDestinationBeforeRead = symbolicLinkDestinationBytes()
        guard FileManager.default.fileExists(atPath: file.path) else {
            return .success(
                (root: [:],
                 snapshot: FileSnapshot(
                    contents: .missing,
                    resolvedDestinationPath: destinationBeforeRead,
                    leafIsSymbolicLink: leafWasSymbolicLink,
                    leafSymbolicLinkDestination: linkDestinationBeforeRead)))
        }
        let data: Data
        switch readRegularFileBounded(at: file, maxBytes: maximumBytes, followSymlink: true) {
        case .success(let bytes): data = bytes
        case .notRegularFile, .oversize, .unreadable:
            return .failure(.readFailure(path: file.path))
        }
        let value: Any
        do {
            value = try JSONSerialization.jsonObject(with: data)
        } catch {
            return .failure(.parseFailure(reason: error.localizedDescription))
        }
        guard let root = value as? [String: Any] else {
            return .failure(.malformedTopLevel(path: file.path))
        }
        let destinationAfterRead = resolvedDestinationPath()
        let leafIsSymbolicLinkAfterRead = isSymbolicLink(at: file)
        let linkDestinationAfterRead = symbolicLinkDestinationBytes()
        guard utf8BytesEqual(destinationBeforeRead, destinationAfterRead),
            leafWasSymbolicLink == leafIsSymbolicLinkAfterRead,
            linkDestinationBeforeRead == linkDestinationAfterRead
        else {
            return .failure(.concurrentModification(path: file.path))
        }
        return .success(
            (root: root,
             snapshot: FileSnapshot(
                contents: .bytes(data),
                resolvedDestinationPath: destinationAfterRead,
                leafIsSymbolicLink: leafIsSymbolicLinkAfterRead,
                leafSymbolicLinkDestination: linkDestinationAfterRead)))
    }

    private func currentSnapshot() -> FileSnapshot {
        let leafWasSymbolicLink = isSymbolicLink(at: file)
        let destinationBeforeRead = resolvedDestinationPath()
        let linkDestinationBeforeRead = symbolicLinkDestinationBytes()
        guard FileManager.default.fileExists(atPath: file.path) else {
            return FileSnapshot(
                contents: .missing,
                resolvedDestinationPath: destinationBeforeRead,
                leafIsSymbolicLink: leafWasSymbolicLink,
                leafSymbolicLinkDestination: linkDestinationBeforeRead)
        }
        guard case .success(let data) = readRegularFileBounded(
            at: file, maxBytes: maximumBytes, followSymlink: true)
        else {
            return FileSnapshot(
                contents: .unreadable,
                resolvedDestinationPath: destinationBeforeRead,
                leafIsSymbolicLink: leafWasSymbolicLink,
                leafSymbolicLinkDestination: linkDestinationBeforeRead)
        }
        let destinationAfterRead = resolvedDestinationPath()
        let leafIsSymbolicLinkAfterRead = isSymbolicLink(at: file)
        let linkDestinationAfterRead = symbolicLinkDestinationBytes()
        guard utf8BytesEqual(destinationBeforeRead, destinationAfterRead),
            leafWasSymbolicLink == leafIsSymbolicLinkAfterRead,
            linkDestinationBeforeRead == linkDestinationAfterRead
        else {
            return FileSnapshot(
                contents: .unreadable,
                resolvedDestinationPath: destinationAfterRead,
                leafIsSymbolicLink: leafIsSymbolicLinkAfterRead,
                leafSymbolicLinkDestination: linkDestinationAfterRead)
        }
        return FileSnapshot(
            contents: .bytes(data),
            resolvedDestinationPath: destinationAfterRead,
            leafIsSymbolicLink: leafIsSymbolicLinkAfterRead,
            leafSymbolicLinkDestination: linkDestinationAfterRead)
    }

    private func resolvedDestination() -> URL {
        symlinkPolicy == .preserveTarget ? file.resolvingSymlinksInPath() : file
    }

    private func resolvedDestinationPath() -> String {
        resolvedDestination().standardizedFileURL.path
    }

    private func symbolicLinkDestinationBytes() -> Data? {
        guard leafNodeIsSymbolicLink(at: file) else { return nil }
        // Foundation may bridge filesystem strings through NSString and normalize canonically
        // equivalent Unicode. CAS needs the literal link payload because NFC/NFD can name
        // different files on normalization-sensitive NFS/SMB volumes.
        var buffer = [UInt8](repeating: 0, count: Int(PATH_MAX) + 1)
        let count = file.withUnsafeFileSystemRepresentation { path -> Int in
            guard let path else { return -1 }
            return buffer.withUnsafeMutableBytes { bytes in
                guard let baseAddress = bytes.baseAddress else { return -1 }
                return Darwin.readlink(path, baseAddress.assumingMemoryBound(to: CChar.self), bytes.count)
            }
        }
        guard count >= 0, count < buffer.count else { return nil }
        return Data(buffer.prefix(count))
    }
}

private func isSymbolicLink(at url: URL) -> Bool {
    leafNodeIsSymbolicLink(at: url)
}

/// 原配置和一次性备份都可能包含第三方命令及用户私有设置。staging 在创建瞬间就是 0600，
/// 再按原文件权限收窄/恢复；不会先以 umask 常见的 0644 暴露一扇 chmod 窗口。
private func secureAtomicPublish(
    _ data: Data,
    to destination: URL,
    permissions: mode_t,
    replaceExisting: Bool,
    exclusiveRename: (String, String) -> Int32,
    beforeRename: () throws -> Void = {}
) throws {
    let directory = destination.deletingLastPathComponent()
    let templateURL = directory.appendingPathComponent(
        ".\(destination.lastPathComponent).claudio-XXXXXX")
    var template = templateURL.path.utf8CString
    let descriptor = template.withUnsafeMutableBufferPointer { buffer in
        mkstemp(buffer.baseAddress!)
    }
    guard descriptor >= 0 else { throw posixWriteError(errno) }

    let stagingPath = template.withUnsafeBufferPointer { buffer in
        String(cString: buffer.baseAddress!)
    }
    var needsClose = true
    defer {
        if needsClose { _ = Darwin.close(descriptor) }
        _ = Darwin.unlink(stagingPath)
    }

    guard fchmod(descriptor, permissions) == 0 else { throw posixWriteError(errno) }
    try writeAll(data, to: descriptor)
    guard fsync(descriptor) == 0 else { throw posixWriteError(errno) }
    guard Darwin.close(descriptor) == 0 else {
        needsClose = false
        throw posixWriteError(errno)
    }
    needsClose = false

    try beforeRename()

    let result: Int32
    if replaceExisting {
        result = Darwin.rename(stagingPath, destination.path)
    } else {
        let exclusiveResult = exclusiveRename(stagingPath, destination.path)
        if exclusiveResult == 0 {
            result = 0
        } else {
            let exclusiveErrno = errno
            if exclusiveErrno == ENOTSUP || exclusiveErrno == ENOSYS {
                // 一些网络/FUSE 挂载卷不实现 RENAME_EXCL。staging 与 backup 同目录，
                // hard link 不跨卷，且目标已存在时以 EEXIST 失败，不会覆盖一次性备份。
                result = stagingPath.withCString { sourcePath in
                    destination.withUnsafeFileSystemRepresentation { destinationPath in
                        guard let destinationPath else {
                            errno = EINVAL
                            return Int32(-1)
                        }
                        return Darwin.link(sourcePath, destinationPath)
                    }
                }
            } else {
                errno = exclusiveErrno
                result = -1
            }
        }
    }
    guard result == 0 else { throw posixWriteError(errno) }
}

private func configFileExclusiveRename(
    _ source: String,
    _ destination: String
) -> Int32 {
    renameatx_np(
        AT_FDCWD,
        source,
        AT_FDCWD,
        destination,
        UInt32(RENAME_EXCL))
}

private func writeAll(_ data: Data, to descriptor: Int32) throws {
    try data.withUnsafeBytes { rawBuffer in
        guard let baseAddress = rawBuffer.baseAddress else { return }
        var written = 0
        while written < rawBuffer.count {
            let count = write(
                descriptor,
                baseAddress.advanced(by: written),
                rawBuffer.count - written)
            if count < 0 {
                if errno == EINTR { continue }
                throw posixWriteError(errno)
            }
            guard count > 0 else { throw posixWriteError(EIO) }
            written += count
        }
    }
}

private func filePermissions(at file: URL) -> mode_t {
    guard
        let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
        let value = attributes[.posixPermissions] as? NSNumber
    else { return 0o600 }
    return mode_t(value.uint16Value) & 0o777
}

private func posixWriteError(_ code: Int32) -> NSError {
    NSError(domain: NSPOSIXErrorDomain, code: Int(code))
}
