import Darwin
import Foundation

/// GUI 与短生命周期 helper 之间唯一允许交换的动态静默事实。
///
/// 字段刻意固定为 schema、revision、expiry 与布尔原因；Focus 名称、宿主内容、路径和任何
/// 日历字段都没有进入这个类型的表达能力。第一阶段只交付 Focus 原因，未来原因必须由自己的
/// ticket 扩展 schema，而不能把私人字段塞进一个自由字典。
public struct DynamicQuietSnapshot: Codable, Sendable, Equatable {
    public static let currentSchema = 1
    public static let maximumLifetime: TimeInterval = 30

    public let schema: Int
    public let revision: UInt64
    public let expiresAtEpochSeconds: TimeInterval
    public let focusActive: Bool

    public init(
        revision: UInt64,
        expiresAtEpochSeconds: TimeInterval,
        focusActive: Bool
    ) {
        schema = Self.currentSchema
        self.revision = revision
        self.expiresAtEpochSeconds = expiresAtEpochSeconds
        self.focusActive = focusActive
    }

    private enum CodingKeys: String, CodingKey {
        case schema
        case revision
        case expiresAtEpochSeconds = "expires_at"
        case focusActive = "focus_active"
    }
}

public let maximumDynamicQuietSnapshotBytes = 1 << 12

/// Dynamic Quiet 跨进程存储布局的单一来源。生产使用 Claudio root，测试可注入临时 root；
/// publisher 与 reader 不得各自重复文件名，否则一次改名会让两端静默分叉。
public struct DynamicQuietPaths: Sendable, Equatable {
    public let directory: URL
    public let snapshotFile: URL
    public let revisionStateFile: URL
    public let lockFile: URL

    public init(rootDirectory: URL) {
        directory = rootDirectory.appendingPathComponent("dynamic-quiet", isDirectory: true)
        snapshotFile = directory.appendingPathComponent("snapshot.json")
        revisionStateFile = directory.appendingPathComponent("accepted-revision.state")
        lockFile = directory.appendingPathComponent("reader.lock")
    }
}

/// Helper 对快照的最终、脱敏判定。拒绝原因只是一枚固定枚举，调用方可写入诊断日志，绝不
/// 拼接文件内容、Focus 名称或本机路径。
public enum DynamicQuietDiagnostic: String, Sendable, Equatable {
    case unsafeDirectory = "unsafe_directory"
    case notRegularFile = "not_regular_file"
    case oversize
    case unreadable
    case malformed
    case wrongSchema = "wrong_schema"
    case expired
    case expiryTooDistant = "expiry_too_distant"
    case revisionStateInvalid = "revision_state_invalid"
    case revisionRollback = "revision_rollback"
    case revisionStateWriteFailed = "revision_state_write_failed"
    case lockBusy = "lock_busy"
    case lockFailed = "lock_failed"
}

public enum DynamicQuietDecision: Sendable, Equatable {
    case inactive
    case quiet
    case rejected(DynamicQuietDiagnostic)
}

public struct DynamicQuietReadEnvironment: Sendable {
    public let snapshotFile: URL
    public let revisionStateFile: URL
    public let lockFile: URL
    public let now: @Sendable () -> Date
    public let maximumSnapshotBytes: Int
    let publishRevisionState: @Sendable (Data, URL) -> Bool

    public init(
        snapshotFile: URL,
        revisionStateFile: URL,
        lockFile: URL,
        now: @escaping @Sendable () -> Date = { Date() },
        maximumSnapshotBytes: Int = maximumDynamicQuietSnapshotBytes,
        publishRevisionState: (@Sendable (Data, URL) -> Bool)? = nil
    ) {
        self.snapshotFile = snapshotFile
        self.revisionStateFile = revisionStateFile
        self.lockFile = lockFile
        self.now = now
        self.maximumSnapshotBytes = maximumSnapshotBytes
        self.publishRevisionState =
            publishRevisionState ?? { data, destination in
                publishPrivateAtomicData(data, to: destination)
            }
    }
}

/// 只接受一个正规、有界、字段集合精确、未过期且 revision 不倒退的快照。
///
/// revision 水位持久化在 Claudio 私有目录里，因此连续的 helper 进程仍共享同一防回滚事实。
/// 水位只有在原子写成功后才允许静默；任何锁、读取或写入故障都 fail safe 为正常播放。
public func dynamicQuietDecision(
    environment: DynamicQuietReadEnvironment
) -> DynamicQuietDecision {
    switch leafPresence(at: environment.snapshotFile) {
    case .missing:
        return .inactive
    case .failed:
        return .rejected(.unreadable)
    case .present:
        break
    }

    let directory = environment.snapshotFile.deletingLastPathComponent()
    do {
        try ensurePrivateDirectoryExists(at: directory)
    } catch {
        return .rejected(.unsafeDirectory)
    }

    return withDynamicQuietLock(at: environment.lockFile) {
        switch readStrictDynamicQuietSnapshot(
            from: environment.snapshotFile,
            maximumBytes: environment.maximumSnapshotBytes)
        {
        case .failure(let diagnostic):
            return .rejected(diagnostic)
        case .success(let snapshot):
            let now = environment.now().timeIntervalSince1970
            guard snapshot.expiresAtEpochSeconds > now else {
                return .rejected(.expired)
            }
            guard snapshot.expiresAtEpochSeconds <= now + DynamicQuietSnapshot.maximumLifetime
            else {
                return .rejected(.expiryTooDistant)
            }

            let lastRevision: UInt64
            switch readRevisionState(from: environment.revisionStateFile) {
            case .missing:
                lastRevision = 0
            case .valid(let revision):
                lastRevision = revision
            case .invalid:
                return .rejected(.revisionStateInvalid)
            }
            guard snapshot.revision >= lastRevision else {
                return .rejected(.revisionRollback)
            }
            if snapshot.revision > lastRevision,
                !environment.publishRevisionState(
                    Data(String(snapshot.revision).utf8),
                    environment.revisionStateFile)
            {
                return .rejected(.revisionStateWriteFailed)
            }
            return snapshot.focusActive ? .quiet : .inactive
        }
    }
}

public enum DynamicQuietPublicationError: String, Error, Sendable, Equatable {
    case invalidLifetime = "invalid_lifetime"
    case revisionExhausted = "revision_exhausted"
    case writeFailed = "write_failed"
}

/// GUI 侧的单写者。每次 publication 都生成严格递增 revision、短 TTL、精确四字段 JSON，
/// 再经 0600 staging + fsync + rename 原子发布。失败不推进内存 revision，也不会报告假成功。
public final class DynamicQuietSnapshotPublisher {
    public let snapshotFile: URL
    public let revisionStateFile: URL
    private var lastPublishedRevision: UInt64 = 0

    public init(snapshotFile: URL, revisionStateFile: URL) {
        self.snapshotFile = snapshotFile
        self.revisionStateFile = revisionStateFile
    }

    public func publish(
        focusActive: Bool,
        now: Date = Date(),
        lifetime: TimeInterval = 12
    ) -> Result<DynamicQuietSnapshot, DynamicQuietPublicationError> {
        guard lifetime > 0, lifetime <= DynamicQuietSnapshot.maximumLifetime else {
            return .failure(.invalidLifetime)
        }

        let diskSnapshotRevision: UInt64
        switch readStrictDynamicQuietSnapshot(
            from: snapshotFile,
            maximumBytes: maximumDynamicQuietSnapshotBytes)
        {
        case .success(let snapshot): diskSnapshotRevision = snapshot.revision
        case .failure: diskSnapshotRevision = 0
        }
        let acceptedRevision: UInt64
        switch readRevisionState(from: revisionStateFile) {
        case .valid(let revision): acceptedRevision = revision
        case .missing, .invalid: acceptedRevision = 0
        }
        let epochMicroseconds = UInt64(
            max(0, min(Double(UInt64.max - 1), now.timeIntervalSince1970 * 1_000_000)))
        let floor = max(
            lastPublishedRevision,
            max(diskSnapshotRevision, max(acceptedRevision, epochMicroseconds)))
        guard floor < UInt64.max else { return .failure(.revisionExhausted) }

        let snapshot = DynamicQuietSnapshot(
            revision: floor + 1,
            expiresAtEpochSeconds: now.addingTimeInterval(lifetime).timeIntervalSince1970,
            focusActive: focusActive)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(snapshot),
            data.count <= maximumDynamicQuietSnapshotBytes,
            publishPrivateAtomicData(data, to: snapshotFile)
        else {
            return .failure(.writeFailed)
        }
        lastPublishedRevision = snapshot.revision
        return .success(snapshot)
    }
}

private enum StrictSnapshotRead {
    case success(DynamicQuietSnapshot)
    case failure(DynamicQuietDiagnostic)
}

private func readStrictDynamicQuietSnapshot(
    from file: URL,
    maximumBytes: Int
) -> StrictSnapshotRead {
    let data: Data
    switch readRegularFileBounded(at: file, maxBytes: maximumBytes, followSymlink: false) {
    case .success(let bytes): data = bytes
    case .notRegularFile: return .failure(.notRegularFile)
    case .oversize: return .failure(.oversize)
    case .unreadable: return .failure(.unreadable)
    }

    guard
        let object = try? JSONSerialization.jsonObject(with: data),
        let dictionary = object as? [String: Any],
        Set(dictionary.keys) == ["schema", "revision", "expires_at", "focus_active"]
    else {
        return .failure(.malformed)
    }
    guard let schema = exactUnsignedInteger(dictionary["schema"]),
        schema == DynamicQuietSnapshot.currentSchema
    else {
        return .failure(.wrongSchema)
    }
    guard let revision = exactUnsignedInteger(dictionary["revision"]), revision > 0,
        let expiry = (dictionary["expires_at"] as? NSNumber)?.doubleValue,
        expiry.isFinite,
        let focusValue = dictionary["focus_active"],
        isJSONBoolean(focusValue),
        let snapshot = try? JSONDecoder().decode(DynamicQuietSnapshot.self, from: data),
        snapshot.revision == revision,
        snapshot.expiresAtEpochSeconds == expiry
    else {
        return .failure(.malformed)
    }
    return .success(snapshot)
}

private func exactUnsignedInteger(_ value: Any?) -> UInt64? {
    guard let number = value as? NSNumber, !isJSONBoolean(number) else { return nil }
    let double = number.doubleValue
    guard double.isFinite, double >= 0, double.rounded(.towardZero) == double,
        double <= Double(UInt64.max)
    else { return nil }
    let integer = number.uint64Value
    return Double(integer) == double ? integer : nil
}

private enum RevisionStateRead {
    case missing
    case valid(UInt64)
    case invalid
}

private func readRevisionState(from file: URL) -> RevisionStateRead {
    switch leafPresence(at: file) {
    case .missing: return .missing
    case .failed: return .invalid
    case .present: break
    }
    guard
        case .success(let data) = readRegularFileBounded(
            at: file, maxBytes: 64, followSymlink: false),
        let text = String(data: data, encoding: .utf8),
        let revision = UInt64(text.trimmingCharacters(in: .whitespacesAndNewlines)),
        revision > 0
    else {
        return .invalid
    }
    return .valid(revision)
}

private enum LeafPresence {
    case missing
    case present
    case failed
}

private func leafPresence(at file: URL) -> LeafPresence {
    var status = stat()
    let result = file.withUnsafeFileSystemRepresentation { path -> Int32 in
        guard let path else {
            errno = EINVAL
            return -1
        }
        return Darwin.lstat(path, &status)
    }
    if result == 0 { return .present }
    return errno == ENOENT ? .missing : .failed
}

private func withDynamicQuietLock(
    at file: URL,
    body: () -> DynamicQuietDecision
) -> DynamicQuietDecision {
    switch withNonBlockingLock(path: file.path, body) {
    case .ran(let decision):
        return decision
    case .skipped:
        return .rejected(.lockBusy)
    case .failed:
        return .rejected(.lockFailed)
    }
}

/// 复用 Claudio 已审计的 0600 同目录 staging + fsync + rename 发布原语。
private func publishPrivateAtomicData(_ data: Data, to destination: URL) -> Bool {
    do {
        try writePrivateAtomic(data, to: destination)
        return true
    } catch {
        return false
    }
}
