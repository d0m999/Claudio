import Darwin
import Foundation

public enum AnchoredFileError: Error, CustomStringConvertible {
    case unsafePath(String)
    case readFailed(String)
    case changed(String)
    case destinationExists(String)
    case publishFailed(String)
    /// Publication already occurred. The displaced external file remains at this path.
    case publishedWithConflict(recoveryPath: String)
    /// Publication occurred in the pinned directory, but its original path moved.
    case publishedButPathChanged(location: String)

    public var description: String {
        switch self {
        case .unsafePath(let detail): "文件路径不安全：\(detail)"
        case .readFailed(let detail): "文件无法安全读取：\(detail)"
        case .changed(let detail): "文件在读写期间变化，已放弃发布：\(detail)"
        case .destinationExists(let detail): "目标文件已经存在：\(detail)"
        case .publishFailed(let detail): "文件发布失败：\(detail)"
        case .publishedWithConflict(let recoveryPath):
            "发布后发现外部替换；原外部文件已保留在 \(recoveryPath)，请检查当前文件后手工恢复"
        case .publishedButPathChanged(let location):
            "文件已发布到固定目录，但原路径随后变化；请检查被移动的目录（原路径及条目：\(location)）"
        }
    }
}

private struct AnchoredIdentity: Equatable {
    let device: dev_t
    let inode: ino_t
    let size: off_t
    let mode: mode_t
    let modifiedSeconds: Int
    let modifiedNanoseconds: Int
    let changedSeconds: Int
    let changedNanoseconds: Int

    init(_ info: stat) {
        device = info.st_dev
        inode = info.st_ino
        size = info.st_size
        mode = info.st_mode
        modifiedSeconds = info.st_mtimespec.tv_sec
        modifiedNanoseconds = info.st_mtimespec.tv_nsec
        changedSeconds = info.st_ctimespec.tv_sec
        changedNanoseconds = info.st_ctimespec.tv_nsec
    }
}

public struct AnchoredFileSnapshot: Equatable {
    public let data: Data?
    fileprivate let identity: AnchoredIdentity?
    fileprivate let permissions: mode_t
}

/// Pins the entry and resolved target directories to open descriptors. All file operations use
/// names relative to those descriptors; moving a parent cannot redirect an in-flight write.
/// A final config symlink is preserved, with its literal payload and inode checked again at
/// publication. Pack callers pass `preserveFinalSymlink: false` and reject links.
public final class AnchoredFileIO {
    private final class Directory {
        let url: URL
        let fd: Int32
        let identity: AnchoredIdentity

        init(_ url: URL) throws {
            self.url = url.standardizedFileURL
            let opened = Darwin.open(self.url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard opened >= 0 else { throw AnchoredFileError.unsafePath(self.url.path) }
            var info = stat()
            guard fstat(opened, &info) == 0 else {
                let code = errno
                Darwin.close(opened)
                throw AnchoredFileError.readFailed("\(self.url.path) errno \(code)")
            }
            fd = opened
            identity = AnchoredIdentity(info)
        }

        init(child name: String, of parent: Directory) throws {
            guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else {
                throw AnchoredFileError.unsafePath(name)
            }
            url = parent.url.appendingPathComponent(name, isDirectory: true)
            let opened = openat(
                parent.fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard opened >= 0 else { throw AnchoredFileError.unsafePath(url.path) }
            var info = stat()
            guard fstat(opened, &info) == 0 else {
                let code = errno
                Darwin.close(opened)
                throw AnchoredFileError.readFailed("\(url.path) errno \(code)")
            }
            fd = opened
            identity = AnchoredIdentity(info)
        }

        func isStillAtPath() -> Bool {
            var info = stat()
            guard stat(url.path, &info) == 0 else { return false }
            let current = AnchoredIdentity(info)
            return current.device == identity.device && current.inode == identity.inode
        }

        deinit { _ = Darwin.close(fd) }
    }

    public let file: URL
    public let resolvedFile: URL
    private let entryDirectory: Directory
    private let targetDirectory: Directory
    private let entryName: String
    private let targetName: String
    private let linkIdentity: AnchoredIdentity?
    private let linkPayload: Data?

    public init(
        file: URL, preserveFinalSymlink: Bool, rootDirectory: URL? = nil
    ) throws {
        self.file = file.standardizedFileURL
        entryName = self.file.lastPathComponent
        guard entryName != ".", entryName != "..", !entryName.isEmpty else {
            throw AnchoredFileError.unsafePath(self.file.path)
        }
        entryDirectory = try Self.openParent(
            of: self.file, relativeTo: rootDirectory)
        var linkInfo = stat()
        let inspection = fstatat(entryDirectory.fd, entryName, &linkInfo, AT_SYMLINK_NOFOLLOW)
        let inspectionErrno = errno
        if inspection == 0,
            (linkInfo.st_mode & S_IFMT) == S_IFLNK
        {
            guard preserveFinalSymlink else { throw AnchoredFileError.unsafePath(self.file.path) }
            let payload = try Self.readLink(in: entryDirectory.fd, name: entryName)
            let target = self.file.resolvingSymlinksInPath().standardizedFileURL
            resolvedFile = target
            targetDirectory = try Self.openParent(of: target, relativeTo: rootDirectory)
            targetName = target.lastPathComponent
            linkIdentity = AnchoredIdentity(linkInfo)
            linkPayload = payload
        } else {
            if inspection < 0 && inspectionErrno != ENOENT {
                throw AnchoredFileError.readFailed(self.file.path)
            }
            targetDirectory = entryDirectory
            resolvedFile = self.file
            targetName = entryName
            linkIdentity = nil
            linkPayload = nil
        }
    }

    private static func openParent(of file: URL, relativeTo root: URL?) throws -> Directory {
        guard let root else { return try Directory(file.deletingLastPathComponent()) }
        let rootURL = root.standardizedFileURL
        let parentURL = file.deletingLastPathComponent().standardizedFileURL
        let prefix = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
        guard parentURL.path == rootURL.path || parentURL.path.hasPrefix(prefix) else {
            throw AnchoredFileError.unsafePath(file.path)
        }
        var current = try Directory(rootURL)
        if parentURL.path == rootURL.path { return current }
        let remainder = String(parentURL.path.dropFirst(prefix.count))
        for component in remainder.split(separator: "/") {
            current = try Directory(child: String(component), of: current)
        }
        return current
    }

    public func read(maxBytes: Int) throws -> AnchoredFileSnapshot {
        guard directoriesAreCurrent(), linkIsCurrent() else {
            throw AnchoredFileError.changed(file.path)
        }
        let descriptor = openat(
            targetDirectory.fd, targetName, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        if descriptor < 0 {
            if errno == ENOENT && linkIdentity == nil {
                return AnchoredFileSnapshot(data: nil, identity: nil, permissions: 0o600)
            }
            throw AnchoredFileError.readFailed(file.path)
        }
        defer { _ = Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
            info.st_size >= 0, info.st_size <= maxBytes
        else { throw AnchoredFileError.readFailed(file.path) }
        let openedIdentity = AnchoredIdentity(info)
        var bytes = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, $0.count)
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw AnchoredFileError.readFailed(file.path)
            }
            if count == 0 { break }
            guard bytes.count + count <= maxBytes else {
                throw AnchoredFileError.readFailed(file.path)
            }
            bytes.append(contentsOf: buffer.prefix(count))
        }
        var afterRead = stat()
        guard fstat(descriptor, &afterRead) == 0,
            AnchoredIdentity(afterRead) == openedIdentity,
            directoriesAreCurrent(), linkIsCurrent()
        else {
            throw AnchoredFileError.changed(file.path)
        }
        return AnchoredFileSnapshot(
            data: bytes, identity: openedIdentity, permissions: info.st_mode & 0o777)
    }

    public func publish(_ bytes: Data, expected: AnchoredFileSnapshot) throws {
        try publish(bytes, expected: expected, beforeRename: {})
    }

    /// Audio imports use this entry point: the final name must remain absent from the
    /// initial check through the kernel's exclusive publication.
    public func publishNew(_ bytes: Data) throws {
        var info = stat()
        guard directoriesAreCurrent() else { throw AnchoredFileError.changed(file.path) }
        if !linkIsCurrent() {
            if fstatat(targetDirectory.fd, targetName, &info, AT_SYMLINK_NOFOLLOW) == 0 {
                throw AnchoredFileError.destinationExists(file.path)
            }
            throw AnchoredFileError.changed(file.path)
        }
        if fstatat(targetDirectory.fd, targetName, &info, AT_SYMLINK_NOFOLLOW) == 0 {
            throw AnchoredFileError.destinationExists(file.path)
        }
        guard errno == ENOENT else { throw AnchoredFileError.readFailed(file.path) }
        let absent = AnchoredFileSnapshot(data: nil, identity: nil, permissions: 0o600)
        do {
            try publish(bytes, expected: absent, beforeRename: {})
        } catch AnchoredFileError.readFailed {
            if fstatat(targetDirectory.fd, targetName, &info, AT_SYMLINK_NOFOLLOW) == 0 {
                throw AnchoredFileError.destinationExists(file.path)
            }
            throw AnchoredFileError.readFailed(file.path)
        } catch AnchoredFileError.changed {
            if fstatat(targetDirectory.fd, targetName, &info, AT_SYMLINK_NOFOLLOW) == 0 {
                throw AnchoredFileError.destinationExists(file.path)
            }
            throw AnchoredFileError.changed(file.path)
        }
    }

    #if DEBUG
    public func publish(
        _ bytes: Data, expected: AnchoredFileSnapshot,
        testingBeforeRename: () -> Void
    ) throws {
        try publish(bytes, expected: expected, beforeRename: testingBeforeRename)
    }
    #endif

    func publish(
        _ bytes: Data, expected: AnchoredFileSnapshot, beforeRename: () throws -> Void
    ) throws {
        guard try read(maxBytes: max(bytes.count, expected.data?.count ?? 0, 1 << 20)) == expected
        else { throw AnchoredFileError.changed(file.path) }
        // A validated import name may already occupy NAME_MAX bytes. Keep staging names
        // independent of the destination basename so those names remain importable.
        let stageName = ".claudio-stage-\(UUID().uuidString)"
        let descriptor = openat(
            targetDirectory.fd, stageName,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw AnchoredFileError.publishFailed(file.path) }
        var removeStage = true
        defer {
            _ = Darwin.close(descriptor)
            if removeStage { _ = unlinkat(targetDirectory.fd, stageName, 0) }
        }
        guard fchmod(descriptor, expected.permissions) == 0 else {
            throw AnchoredFileError.publishFailed(file.path)
        }
        try bytes.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let count = Darwin.write(descriptor, base.advanced(by: offset), raw.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw AnchoredFileError.publishFailed(file.path) }
                offset += count
            }
        }
        guard fsync(descriptor) == 0 else { throw AnchoredFileError.publishFailed(file.path) }
        guard try read(maxBytes: max(expected.data?.count ?? 0, 1 << 20)) == expected else {
            throw AnchoredFileError.changed(file.path)
        }
        try beforeRename()
        var result: Int32
        if expected.data == nil {
            result = renameatx_np(
                targetDirectory.fd, stageName, targetDirectory.fd, targetName, UInt32(RENAME_EXCL))
        } else {
            result = renameatx_np(
                targetDirectory.fd, stageName, targetDirectory.fd, targetName, UInt32(RENAME_SWAP))
        }
        if result != 0 && expected.data == nil && (errno == ENOTSUP || errno == ENOSYS) {
            // linkat has the same no-replacement contract for files staged in this directory.
            result = linkat(targetDirectory.fd, stageName, targetDirectory.fd, targetName, 0)
        }
        guard result == 0 else {
            if expected.data == nil && errno == EEXIST {
                throw AnchoredFileError.destinationExists(file.path)
            }
            if expected.data != nil && errno == ENOENT {
                throw AnchoredFileError.changed(file.path)
            }
            throw AnchoredFileError.publishFailed("\(file.path) errno \(errno)")
        }
        if expected.data != nil {
            let displaced = try? readNamedFile(
                in: targetDirectory.fd, name: stageName,
                maxBytes: max(expected.data?.count ?? 0, 1 << 20))
            if displaced?.data != expected.data
                || displaced?.identity?.device != expected.identity?.device
                || displaced?.identity?.inode != expected.identity?.inode
            {
                removeStage = false
                if !directoriesAreCurrent() {
                    throw AnchoredFileError.publishedButPathChanged(
                        location: targetDirectory.url.appendingPathComponent(stageName).path)
                }
                throw AnchoredFileError.publishedWithConflict(
                    recoveryPath: targetDirectory.url.appendingPathComponent(stageName).path)
            }
        }
        _ = fsync(targetDirectory.fd)
        guard directoriesAreCurrent(), linkIsCurrent() else {
            // The publication may already have occurred in the pinned directory.
            if expected.data == nil {
                throw AnchoredFileError.publishedButPathChanged(
                    location: targetDirectory.url.appendingPathComponent(targetName).path)
            }
            removeStage = false
            if !directoriesAreCurrent() {
                throw AnchoredFileError.publishedButPathChanged(
                    location: targetDirectory.url.appendingPathComponent(stageName).path)
            }
            throw AnchoredFileError.publishedWithConflict(
                recoveryPath: targetDirectory.url.appendingPathComponent(stageName).path)
        }
    }

    private func directoriesAreCurrent() -> Bool {
        entryDirectory.isStillAtPath() && targetDirectory.isStillAtPath()
    }

    private func linkIsCurrent() -> Bool {
        var info = stat()
        let result = fstatat(entryDirectory.fd, entryName, &info, AT_SYMLINK_NOFOLLOW)
        if let linkIdentity, let linkPayload {
            guard result == 0, AnchoredIdentity(info) == linkIdentity,
                let current = try? Self.readLink(in: entryDirectory.fd, name: entryName)
            else { return false }
            return current == linkPayload
        }
        return result < 0 && errno == ENOENT || result == 0 && (info.st_mode & S_IFMT) != S_IFLNK
    }

    private func readNamedFile(in directory: Int32, name: String, maxBytes: Int) throws
        -> AnchoredFileSnapshot
    {
        let descriptor = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw AnchoredFileError.readFailed(name) }
        defer { _ = Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
            info.st_size >= 0, info.st_size <= maxBytes
        else { throw AnchoredFileError.readFailed(name) }
        var bytes = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, $0.count)
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw AnchoredFileError.readFailed(name)
            }
            if count == 0 { break }
            guard bytes.count + count <= maxBytes else {
                throw AnchoredFileError.readFailed(name)
            }
            bytes.append(contentsOf: buffer.prefix(count))
        }
        return AnchoredFileSnapshot(
            data: bytes, identity: AnchoredIdentity(info), permissions: info.st_mode & 0o777)
    }

    private static func readLink(in directory: Int32, name: String) throws -> Data {
        var buffer = [UInt8](repeating: 0, count: Int(PATH_MAX) + 1)
        let count = buffer.withUnsafeMutableBytes {
            readlinkat(
                directory, name, $0.baseAddress?.assumingMemoryBound(to: CChar.self), $0.count)
        }
        guard count >= 0, count < buffer.count else { throw AnchoredFileError.readFailed(name) }
        return Data(buffer.prefix(count))
    }
}
