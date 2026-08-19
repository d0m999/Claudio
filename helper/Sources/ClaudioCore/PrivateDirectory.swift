import Darwin
import Foundation

/// Claudio 自有目录的安全创建错误。调用方保留 typed 错误或映射到自己的磁盘错误；绝不把
/// symlink / 非目录节点当作“已经存在”。
public enum PrivateDirectoryError: Error, Sendable, Equatable, CustomStringConvertible {
    case unsafeNode(path: String)
    case operationFailed(path: String, errno: Int32)

    public var description: String {
        switch self {
        case .unsafeNode(let path):
            "私有目录路径包含符号链接或非目录节点：\(path)"
        case .operationFailed(let path, let code):
            "无法安全创建或收紧私有目录：\(path)（errno \(code)）"
        }
    }
}

/// 创建 Claudio 自有目录并把最终目录节点固定为 `0700`。
///
/// 缺失的中间层逐层用 `mkdir(2)` 创建并逐层校验；已存在的祖先不会被 chmod（因此不会碰
/// `$HOME`、`/tmp` 等用户/系统目录）。最终节点无论新旧都通过
/// `O_NOFOLLOW | O_DIRECTORY` 打开后 `fchmod(0700)`，把宽松 `umask` 和创建竞态都关在 fd
/// 身份之内。任一层是 symlink、普通文件或其它节点时失败关闭。
public func ensurePrivateDirectoryTree(at directory: URL) throws {
    try ensurePrivateDirectory(directory.standardizedFileURL, tightenExistingLeaf: true)
}

/// 与 ``ensurePrivateDirectoryTree(at:)`` 使用同一套 no-follow 创建/校验，但不改动一个已经存在的
/// 最终目录权限。用于注入式低层写路径：新建 Claudio 目录仍从一开始就是 0700；已有只读目录则
/// 保持只读并让后续写入如实失败，不偷偷把用户的故障注入/显式权限改回去。
public func ensurePrivateDirectoryExists(at directory: URL) throws {
    try ensurePrivateDirectory(directory.standardizedFileURL, tightenExistingLeaf: false)
}

private func ensurePrivateDirectory(
    _ directory: URL,
    tightenExistingLeaf: Bool
) throws {
    var status = stat()
    let inspection = directory.withUnsafeFileSystemRepresentation { path -> Int32 in
        guard let path else {
            errno = EINVAL
            return -1
        }
        return Darwin.lstat(path, &status)
    }

    if inspection == 0 {
        guard status.st_mode & S_IFMT == S_IFDIR else {
            throw PrivateDirectoryError.unsafeNode(path: directory.path)
        }
        if tightenExistingLeaf {
            try tightenPrivateDirectory(directory)
        }
        return
    }

    let inspectionErrno = errno
    guard inspectionErrno == ENOENT else {
        throw PrivateDirectoryError.operationFailed(path: directory.path, errno: inspectionErrno)
    }

    let parent = directory.deletingLastPathComponent()
    guard parent.path != directory.path else {
        throw PrivateDirectoryError.unsafeNode(path: directory.path)
    }
    // 已存在祖先只验证类型，不改变权限；若祖先也是本次递归创建的，它会在自己的 mkdir 后收紧。
    try ensurePrivateDirectory(parent, tightenExistingLeaf: false)

    let created = directory.withUnsafeFileSystemRepresentation { path -> Int32 in
        guard let path else {
            errno = EINVAL
            return -1
        }
        return Darwin.mkdir(path, 0o700)
    }
    if created != 0 && errno != EEXIST {
        throw PrivateDirectoryError.operationFailed(path: directory.path, errno: errno)
    }
    // EEXIST 可能来自同用户竞态。重新以 no-follow fd 校验真实终态，而非相信先前 lstat。
    try tightenPrivateDirectory(directory)
}

private func tightenPrivateDirectory(_ directory: URL) throws {
    let descriptor = directory.withUnsafeFileSystemRepresentation { path -> Int32 in
        guard let path else {
            errno = EINVAL
            return -1
        }
        return Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_DIRECTORY)
    }
    guard descriptor >= 0 else {
        let code = errno
        if code == ELOOP || code == ENOTDIR {
            throw PrivateDirectoryError.unsafeNode(path: directory.path)
        }
        throw PrivateDirectoryError.operationFailed(path: directory.path, errno: code)
    }
    defer { _ = Darwin.close(descriptor) }
    guard Darwin.fchmod(descriptor, 0o700) == 0 else {
        throw PrivateDirectoryError.operationFailed(path: directory.path, errno: errno)
    }
}
