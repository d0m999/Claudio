import Darwin
import Foundation

/// Hook 播放链允许写入回执的脱敏结果。它刻意没有关联字符串：提示词、响应内容、
/// 项目/会话信息和音频路径在类型层就无处可放。
public enum HostHookPlaybackResult: String, Codable, Sendable, Equatable {
    case played
    case muted
    case debounced
    case notReady = "not_ready"
    case unsupportedEvent = "unsupported_event"
    case playbackFailed = "playback_failed"
}

/// 一次真实宿主 hook 回调留下的最小回执。
public struct HostHookReceipt: Codable, Sendable, Equatable {
    public static let legacySchema = 1
    public static let currentSchema = 2

    public let schema: Int
    public let installationID: UUID
    public let host: HostID
    public let bindingID: HostEventBindingID
    public let nativeEvent: String
    public let semanticEvent: Event
    public let timestamp: Date
    public let playbackResult: HostHookPlaybackResult

    public init(
        schema: Int = HostHookReceipt.currentSchema,
        installationID: UUID,
        host: HostID,
        bindingID: HostEventBindingID? = nil,
        nativeEvent: String,
        semanticEvent: Event,
        timestamp: Date,
        playbackResult: HostHookPlaybackResult
    ) {
        self.schema = schema
        self.installationID = installationID
        self.host = host
        self.bindingID =
            bindingID
            ?? (schema == Self.currentSchema
                ? HostCapabilityCatalog.binding(host: host, nativeEvent: nativeEvent)?.id
                : Self.legacyBindingID(host: host, nativeEvent: nativeEvent))
            ?? Self.legacyBindingID(host: host, nativeEvent: nativeEvent)
        self.nativeEvent = nativeEvent
        self.semanticEvent = semanticEvent
        self.timestamp = timestamp
        self.playbackResult = playbackResult
    }

    private enum CodingKeys: String, CodingKey {
        case schema
        case installationID = "installation_id"
        case host
        case bindingID = "binding_id"
        case nativeEvent = "native_event"
        case semanticEvent = "semantic_event"
        case timestamp
        case playbackResult = "playback_result"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schema = try container.decode(Int.self, forKey: .schema)
        installationID = try container.decode(UUID.self, forKey: .installationID)
        host = try container.decode(HostID.self, forKey: .host)
        nativeEvent = try container.decode(String.self, forKey: .nativeEvent)
        semanticEvent = try container.decode(Event.self, forKey: .semanticEvent)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        playbackResult = try container.decode(HostHookPlaybackResult.self, forKey: .playbackResult)
        bindingID =
            try container.decodeIfPresent(HostEventBindingID.self, forKey: .bindingID)
            ?? Self.legacyBindingID(host: host, nativeEvent: nativeEvent)
    }

    static func legacyBindingID(host: HostID, nativeEvent: String) -> HostEventBindingID {
        HostEventBindingID(rawValue: "legacy:\(host.rawValue):\(nativeEvent)")
    }
}

public enum HostHookReceiptWriteOutcome: Sendable, Equatable {
    case written
}

public enum HostHookReceiptHistoryState: Sendable, Equatable {
    case available
    case missing
    case damaged(skippedItemCount: Int)
    case unreadable
}

public struct HostHookReceiptHistorySnapshot: Sendable, Equatable {
    public let receipts: [HostHookReceipt]
    public let state: HostHookReceiptHistoryState

    public init(receipts: [HostHookReceipt], state: HostHookReceiptHistoryState) {
        self.receipts = receipts
        self.state = state
    }
}

/// 回执失败只影响可观察证据（activation / latest diagnosis）；hook 调用方可以忽略整个
/// `Result` 并立即退出。
public enum HostHookReceiptStoreError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidReceipt
    case invalidScopeFingerprint
    case staleInstallation
    case encodingFailure(reason: String)
    case lockBusy
    case lockFailed(errno: Int32)
    case directoryCreationFailure(reason: String)
    case writeFailure(reason: String)

    public var description: String {
        switch self {
        case .invalidReceipt:
            "回执字段与宿主能力映射不一致"
        case .invalidScopeFingerprint:
            "当前激活缺少有效的版本 scope"
        case .staleInstallation:
            "回执 installation ID 不是当前连接代次"
        case .encodingFailure(let reason):
            "回执编码失败：\(reason)"
        case .lockBusy:
            "回执代次锁正忙，请重试"
        case .lockFailed(let errno):
            "回执代次锁获取失败（errno \(errno)）"
        case .directoryCreationFailure(let reason):
            "回执目录创建失败：\(reason)"
        case .writeFailure(let reason):
            "回执写入失败：\(reason)"
        }
    }
}

/// 真实 hook 回执的注入式存储。生产调用方传
/// `~/.claudio/integrations/receipts` 与独立锁目录；测试只传临时目录。
public struct HostHookReceiptStore: Sendable {
    public static let historyLimitPerSurface = 20
    public static let historyRetention: TimeInterval = 30 * 24 * 60 * 60
    public static let historyDirectoryEntryLimit = 128

    public let receiptsRoot: URL
    public let locksRoot: URL
    public let installationsRoot: URL
    public let installationLocksRoot: URL
    public let historyRoot: URL

    public init(
        receiptsRoot: URL,
        locksRoot: URL,
        installationsRoot: URL? = nil,
        installationLocksRoot: URL? = nil,
        historyRoot: URL? = nil
    ) {
        self.receiptsRoot = receiptsRoot
        self.locksRoot = locksRoot
        let integrationsRoot = receiptsRoot.deletingLastPathComponent()
        self.installationsRoot =
            installationsRoot
            ?? integrationsRoot.appendingPathComponent("installations", isDirectory: true)
        self.installationLocksRoot =
            installationLocksRoot
            ?? integrationsRoot.appendingPathComponent("installation-locks", isDirectory: true)
        self.historyRoot =
            historyRoot
            ?? integrationsRoot.appendingPathComponent("receipt-history", isDirectory: true)
    }

    public func installationFile(host: HostID) -> URL {
        installationsRoot.appendingPathComponent("\(host.rawValue).json")
    }

    public func installationLockFile(host: HostID) -> URL {
        installationLocksRoot.appendingPathComponent("\(host.rawValue).lock")
    }

    /// Adapter 在配置成功后发布当前代次。hook 必须在这份 Claudio 自有、0600 的原子标记
    /// 仍匹配时才可替换稳定事件回执，从源头拒绝断开/重连后的迟到旧进程。
    public func activate(
        host: HostID,
        installationID: UUID,
        scopeFingerprint: String
    ) -> Result<Void, HostHookReceiptStoreError> {
        guard !scopeFingerprint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure(.invalidScopeFingerprint)
        }
        let marker = ActiveHostInstallation(
            schema: ActiveHostInstallation.currentSchema,
            host: host,
            installationID: installationID,
            scopeFingerprint: scopeFingerprint)
        let data: Data
        do {
            data = try Self.markerEncoder.encode(marker)
        } catch {
            return .failure(.encodingFailure(reason: error.localizedDescription))
        }
        let locked = withNonBlockingLock(path: installationLockFile(host: host).path) {
            publish(data, to: installationFile(host: host)).map { _ in () }
        }
        return flattenInstallationLock(locked)
    }

    /// 只删除调用方刚刚从宿主配置中摘除的那个代次。若另一进程已经连接了新代次，旧的
    /// disconnect 不得把新标记一起删掉。
    public func deactivate(
        host: HostID,
        installationID: UUID
    ) -> Result<Void, HostHookReceiptStoreError> {
        let locked = withNonBlockingLock(path: installationLockFile(host: host).path) {
            guard currentInstallationIDUnlocked(host: host) == installationID else {
                return Result<Void, HostHookReceiptStoreError>.success(())
            }
            let file = installationFile(host: host)
            guard Darwin.unlink(file.path) == 0 || errno == ENOENT else {
                return .failure(
                    .writeFailure(reason: String(cString: strerror(errno))))
            }
            return .success(())
        }
        return flattenInstallationLock(locked)
    }

    public func currentInstallationID(host: HostID) -> UUID? {
        currentInstallationUnlocked(host: host)?.installationID
    }

    public func currentInstallationScopeFingerprint(host: HostID) -> String? {
        currentInstallationUnlocked(host: host)?.scopeFingerprint
    }

    /// 每个宿主原生事件拥有独立 JSON。未知/unsupported 事件没有路径，避免把外部输入当文件名。
    public func receiptFile(host: HostID, nativeEvent: String) -> URL? {
        guard HostCapabilityCatalog.semanticEvent(host: host, nativeEvent: nativeEvent) != nil
        else {
            return nil
        }
        return
            receiptsRoot
            .appendingPathComponent(host.rawValue, isDirectory: true)
            .appendingPathComponent("\(nativeEvent).json")
    }

    /// 与 JSON 一一对应的非阻塞独立锁；一个事件的争用不会吞掉同宿主或另一宿主的事件。
    public func lockFile(host: HostID, nativeEvent: String) -> URL? {
        guard HostCapabilityCatalog.semanticEvent(host: host, nativeEvent: nativeEvent) != nil
        else {
            return nil
        }
        return
            locksRoot
            .appendingPathComponent(host.rawValue, isDirectory: true)
            .appendingPathComponent("\(nativeEvent).lock")
    }

    public func store(
        _ receipt: HostHookReceipt
    ) -> Result<HostHookReceiptWriteOutcome, HostHookReceiptStoreError> {
        guard receipt.schema == HostHookReceipt.currentSchema,
            let binding = HostCapabilityCatalog.binding(
                host: receipt.host, nativeEvent: receipt.nativeEvent),
            binding.event == receipt.semanticEvent,
            binding.id == receipt.bindingID,
            let destination = receiptFile(
                host: receipt.host, nativeEvent: receipt.nativeEvent),
            let lock = lockFile(host: receipt.host, nativeEvent: receipt.nativeEvent)
        else {
            return .failure(.invalidReceipt)
        }

        let data: Data
        do {
            data = try Self.encode(receipt)
        } catch {
            return .failure(.encodingFailure(reason: error.localizedDescription))
        }

        let generationLocked = withNonBlockingLock(
            path: installationLockFile(host: receipt.host).path
        ) {
            guard currentInstallationIDUnlocked(host: receipt.host) == receipt.installationID else {
                return Result<HostHookReceiptWriteOutcome, HostHookReceiptStoreError>.failure(
                    .staleInstallation)
            }
            let eventLocked = withNonBlockingLock(path: lock.path) {
                switch publish(data, to: destination) {
                case .failure(let error):
                    return Result<HostHookReceiptWriteOutcome, HostHookReceiptStoreError>.failure(
                        error)
                case .success:
                    return archive(receipt, data: data)
                }
            }
            switch eventLocked {
            case .ran(let result): return result
            case .skipped: return .failure(.lockBusy)
            case .failed(let code): return .failure(.lockFailed(errno: code))
            }
        }
        switch generationLocked {
        case .ran(let result): return result
        case .skipped: return .failure(.lockBusy)
        case .failed(let code): return .failure(.lockFailed(errno: code))
        }
    }

    /// 返回与当前 activation 解耦的单次、有界、no-follow 历史快照。目录与每个文件都绑定到
    /// 已打开的 descriptor；损坏项计数和可用 receipt 来自同一次最多 128 项的 readdir。
    public func receiptHistorySnapshot(
        host: HostID,
        now: Date = Date()
    ) -> HostHookReceiptHistorySnapshot {
        let rootDescriptor = historyRoot.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return open(path, O_RDONLY | O_NONBLOCK | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard rootDescriptor >= 0 else {
            let code = errno
            if code == ENOENT {
                return HostHookReceiptHistorySnapshot(receipts: [], state: .missing)
            }
            if code == ELOOP || code == ENOTDIR {
                return HostHookReceiptHistorySnapshot(
                    receipts: [], state: .damaged(skippedItemCount: 1))
            }
            return HostHookReceiptHistorySnapshot(receipts: [], state: .unreadable)
        }
        defer { close(rootDescriptor) }

        var rootStatus = stat()
        guard fstat(rootDescriptor, &rootStatus) == 0,
            rootStatus.st_mode & S_IFMT == S_IFDIR,
            rootStatus.st_uid == geteuid()
        else {
            return HostHookReceiptHistorySnapshot(receipts: [], state: .unreadable)
        }

        let surfaceName = host.surfaceID.rawValue
        let surfaceDescriptor = surfaceName.withCString {
            openat(
                rootDescriptor,
                $0,
                O_RDONLY | O_NONBLOCK | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard surfaceDescriptor >= 0 else {
            let code = errno
            if code == ENOENT {
                return HostHookReceiptHistorySnapshot(receipts: [], state: .missing)
            }
            if code == ELOOP || code == ENOTDIR {
                return HostHookReceiptHistorySnapshot(
                    receipts: [], state: .damaged(skippedItemCount: 1))
            }
            return HostHookReceiptHistorySnapshot(receipts: [], state: .unreadable)
        }
        guard let stream = fdopendir(surfaceDescriptor) else {
            close(surfaceDescriptor)
            return HostHookReceiptHistorySnapshot(receipts: [], state: .unreadable)
        }
        defer { closedir(stream) }

        let cutoff = now.addingTimeInterval(-Self.historyRetention)
        var receipts: [HostHookReceipt] = []
        var inspectedItemCount = 0
        var rejectedItemCount = 0
        var directoryReadFailed = false
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                directoryReadFailed = errno != 0
                break
            }
            let name = Self.historyEntryName(entry)
            guard name != ".", name != ".." else { continue }
            guard inspectedItemCount < Self.historyDirectoryEntryLimit else {
                rejectedItemCount += 1
                break
            }
            inspectedItemCount += 1
            guard !name.hasPrefix(".") else {
                rejectedItemCount += 1
                continue
            }

            let fileDescriptor = name.withCString {
                openat(dirfd(stream), $0, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
            }
            guard fileDescriptor >= 0 else {
                rejectedItemCount += 1
                continue
            }
            defer { close(fileDescriptor) }

            var status = stat()
            guard fstat(fileDescriptor, &status) == 0,
                status.st_mode & S_IFMT == S_IFREG
            else {
                rejectedItemCount += 1
                continue
            }
            let modified = Date(
                timeIntervalSince1970: TimeInterval(status.st_mtimespec.tv_sec)
                    + TimeInterval(status.st_mtimespec.tv_nsec) / 1_000_000_000)
            guard modified >= cutoff else { continue }
            guard let data = Self.readHistoryData(from: fileDescriptor, maximumBytes: 1 << 16),
                let receipt = try? Self.decode(data),
                receipt.host == host,
                let binding = HostCapabilityCatalog.binding(
                    host: host, nativeEvent: receipt.nativeEvent),
                binding.event == receipt.semanticEvent,
                Self.isValidHistoricalReceipt(receipt, binding: binding)
            else {
                rejectedItemCount += 1
                continue
            }
            receipts.append(receipt)
        }
        guard !directoryReadFailed else {
            return HostHookReceiptHistorySnapshot(receipts: [], state: .unreadable)
        }
        let retained = receipts.sorted { $0.timestamp > $1.timestamp }
            .prefix(Self.historyLimitPerSurface)
        let state: HostHookReceiptHistoryState =
            rejectedItemCount == 0
            ? .available : .damaged(skippedItemCount: rejectedItemCount)
        return HostHookReceiptHistorySnapshot(receipts: Array(retained), state: state)
    }

    public func receiptHistory(host: HostID, now: Date = Date()) -> [HostHookReceipt] {
        receiptHistorySnapshot(host: host, now: now).receipts
    }

    /// 用户显式清除某个 surface 的历史；当前稳定回执与 activation marker 不受影响。
    public func clearReceiptHistory(
        host: HostID
    ) -> Result<Void, HostHookReceiptStoreError> {
        clearReceiptHistory(hosts: [host])
    }

    /// 多 surface 清理先持有所有 installation locks，再把每个目录原子移入同一 tombstone。
    /// 全部 rename 完成前的失败会反序恢复；全部 rename 完成就是不可逆 commit boundary，之后
    /// 的 descriptor-relative 清理可重试，不能把已经提交的清除伪报为可回滚 failure。
    public func clearReceiptHistory(
        hosts: [HostID],
        beforeStaging: (HostID) throws -> Void = { _ in },
        beforeCommittedCleanup: (Int) throws -> Void = { _ in }
    ) -> Result<Void, HostHookReceiptStoreError> {
        var seen = Set<HostID>()
        let orderedHosts = hosts.filter { seen.insert($0).inserted }
        var lockHostSet = Set<HostID>()
        let lockHosts = (HostID.productVisibleCases + orderedHosts).filter {
            lockHostSet.insert($0).inserted
        }
        var locks: [FileLock] = []
        for host in lockHosts {
            let lock = FileLock(path: installationLockFile(host: host).path)
            switch lock.attemptLock() {
            case .acquired:
                locks.append(lock)
            case .busy:
                locks.forEach { $0.unlock() }
                return .failure(.lockBusy)
            case .failed(let code):
                locks.forEach { $0.unlock() }
                return .failure(.lockFailed(errno: code))
            }
        }
        defer { locks.forEach { $0.unlock() } }
        return clearReceiptHistoryWhileLocked(
            hosts: orderedHosts,
            recoveryHosts: lockHosts,
            beforeStaging: beforeStaging,
            beforeCommittedCleanup: beforeCommittedCleanup)
    }

    /// 只有当前 installation、请求的宿主/原生事件、catalog 语义和 schema 全部匹配时，
    /// 才把磁盘回执提升为结构化 evidence。是否可用作 activation 由 adapter 另行限制为
    /// `UserPromptSubmit`；其它受支持事件只进入 latest diagnosis。损坏、旧代次或错位文件全部
    /// 返回 `nil`。
    public func receiptEvidence(
        host: HostID,
        nativeEvent: String,
        installationID: UUID,
        scopeFingerprint: String
    ) -> HostReceiptEvidence? {
        guard
            currentInstallationID(host: host) == installationID,
            currentInstallationScopeFingerprint(host: host) == scopeFingerprint,
            let expectedBinding = HostCapabilityCatalog.binding(
                host: host, nativeEvent: nativeEvent),
            let file = receiptFile(host: host, nativeEvent: nativeEvent),
            case .success(let data) = readRegularFileBounded(
                at: file, maxBytes: 1 << 16, followSymlink: false),
            let receipt = try? Self.decode(data),
            receipt.schema == HostHookReceipt.currentSchema,
            receipt.installationID == installationID,
            receipt.host == host,
            receipt.bindingID == expectedBinding.id,
            receipt.nativeEvent == nativeEvent,
            receipt.semanticEvent == expectedBinding.event
        else {
            return nil
        }
        return HostReceiptEvidence(
            bindingID: receipt.bindingID,
            installationID: receipt.installationID,
            nativeEvent: receipt.nativeEvent,
            event: receipt.semanticEvent,
            timestamp: receipt.timestamp,
            playbackResult: receipt.playbackResult)
    }

    private func publish(
        _ data: Data,
        to destination: URL
    ) -> Result<HostHookReceiptWriteOutcome, HostHookReceiptStoreError> {
        let directory = destination.deletingLastPathComponent()
        do {
            try ensurePrivateDirectoryTree(at: directory)
        } catch {
            return .failure(.directoryCreationFailure(reason: error.localizedDescription))
        }

        // mkstemp(3) 让 staging 从创建瞬间就是 0600；不会先按常见 umask 暴露成 0644，
        // 再依赖一个存在隐私窗口的事后 chmod。与目标同目录确保 rename(2) 不跨卷。
        let templateURL = directory.appendingPathComponent(
            ".\(destination.lastPathComponent).tmp-XXXXXX")
        var template = templateURL.path.utf8CString
        let descriptor = template.withUnsafeMutableBufferPointer { buffer in
            mkstemp(buffer.baseAddress!)
        }
        guard descriptor >= 0 else {
            return .failure(
                .writeFailure(reason: String(cString: strerror(errno))))
        }
        let stagingPath = template.withUnsafeBufferPointer { buffer in
            String(cString: buffer.baseAddress!)
        }
        var needsClose = true
        defer {
            if needsClose { _ = Darwin.close(descriptor) }
            _ = Darwin.unlink(stagingPath)
        }

        do {
            guard fchmod(descriptor, 0o600) == 0 else {
                throw hostHookReceiptPOSIXError(errno)
            }
            try writeHostHookReceiptData(data, to: descriptor)
            guard fsync(descriptor) == 0 else { throw hostHookReceiptPOSIXError(errno) }
            guard Darwin.close(descriptor) == 0 else {
                needsClose = false
                throw hostHookReceiptPOSIXError(errno)
            }
            needsClose = false
        } catch {
            return .failure(.writeFailure(reason: error.localizedDescription))
        }

        let renamed = destination.withUnsafeFileSystemRepresentation { target in
            guard let target else { return Int32(-1) }
            return Darwin.rename(stagingPath, target)
        }
        guard renamed == 0 else {
            let code = errno
            return .failure(
                .writeFailure(reason: String(cString: strerror(code))))
        }
        // rename 保留 staging inode 的 0600；最终路径从未出现过更宽权限。
        return .success(.written)
    }

    private func historyDirectory(host: HostID) -> URL {
        historyRoot.appendingPathComponent(host.surfaceID.rawValue, isDirectory: true)
    }

    private static func historyEntryName(_ entry: UnsafeMutablePointer<dirent>) -> String {
        var name = entry.pointee.d_name
        let capacity = MemoryLayout.size(ofValue: name)
        return withUnsafePointer(to: &name) { pointer in
            pointer.withMemoryRebound(
                to: CChar.self,
                capacity: capacity
            ) {
                String(cString: $0)
            }
        }
    }

    private static func readHistoryData(
        from descriptor: Int32,
        maximumBytes: Int
    ) -> Data? {
        let readCap = maximumBytes + 1
        var data = Data()
        data.reserveCapacity(readCap)
        var buffer = [UInt8](repeating: 0, count: min(1 << 14, readCap))
        while data.count < readCap {
            let requested = min(buffer.count, readCap - data.count)
            let bytesRead = buffer.withUnsafeMutableBytes { raw -> Int in
                var result = Darwin.read(descriptor, raw.baseAddress, requested)
                while result < 0 && errno == EINTR {
                    result = Darwin.read(descriptor, raw.baseAddress, requested)
                }
                return result
            }
            guard bytesRead >= 0 else { return nil }
            if bytesRead == 0 { break }
            data.append(contentsOf: buffer[0..<bytesRead])
        }
        return data.count <= maximumBytes ? data : nil
    }

    private func clearReceiptHistoryWhileLocked(
        hosts: [HostID],
        recoveryHosts: [HostID],
        beforeStaging: (HostID) throws -> Void,
        beforeCommittedCleanup: (Int) throws -> Void
    ) -> Result<Void, HostHookReceiptStoreError> {
        guard !hosts.isEmpty else { return .success(()) }

        let rootDescriptor = historyRoot.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard rootDescriptor >= 0 else {
            if errno == ENOENT { return .success(()) }
            return .failure(.writeFailure(reason: String(cString: strerror(errno))))
        }
        defer { close(rootDescriptor) }

        var rootStatus = stat()
        guard fstat(rootDescriptor, &rootStatus) == 0,
            rootStatus.st_mode & S_IFMT == S_IFDIR,
            rootStatus.st_uid == geteuid(),
            rootStatus.st_mode & mode_t(S_IRWXG | S_IRWXO) == 0,
            Self.pathMatchesDescriptor(historyRoot, expected: rootStatus)
        else {
            return .failure(.writeFailure(reason: "回执历史根目录身份不安全"))
        }

        // `.staging-*` is explicitly pre-commit. A process exit may leave some surfaces there;
        // recover them before any new clear. All product installation locks are held, so another
        // clear cannot mistake or mutate this recovery state concurrently.
        guard
            Self.recoverInterruptedHistoryStaging(
                rootDescriptor: rootDescriptor,
                hosts: recoveryHosts)
        else {
            return .failure(.writeFailure(reason: "未提交的历史 staging 无法安全恢复"))
        }

        // A previous committed clear may have been interrupted while reclaiming its private
        // tombstone. Reclaiming it is best-effort: its product-visible surface names are already
        // gone, so cleanup failure must never be reported as a rollback-capable clear failure.
        Self.cleanupCommittedHistoryTombstones(rootDescriptor: rootDescriptor)

        var sourceStatusByHost: [HostID: stat] = [:]
        for host in hosts {
            var status = stat()
            let result = host.surfaceID.rawValue.withCString {
                fstatat(rootDescriptor, $0, &status, AT_SYMLINK_NOFOLLOW)
            }
            if result != 0 {
                if errno == ENOENT { continue }
                return .failure(.writeFailure(reason: String(cString: strerror(errno))))
            }
            guard status.st_mode & S_IFMT == S_IFDIR else {
                return .failure(.writeFailure(reason: "回执历史 surface 不是安全目录"))
            }
            sourceStatusByHost[host] = status
        }
        let presentHosts = hosts.filter { sourceStatusByHost[$0] != nil }
        guard !presentHosts.isEmpty else { return .success(()) }

        let transactionID = UUID().uuidString.lowercased()
        let stagingName = ".staging-\(transactionID)"
        let committedName = ".clear-\(transactionID)"
        let created = stagingName.withCString {
            mkdirat(rootDescriptor, $0, mode_t(S_IRWXU))
        }
        guard created == 0 else {
            return .failure(.writeFailure(reason: String(cString: strerror(errno))))
        }
        defer {
            _ = stagingName.withCString {
                unlinkat(rootDescriptor, $0, AT_REMOVEDIR)
            }
        }

        let stagingDescriptor = stagingName.withCString {
            openat(rootDescriptor, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard stagingDescriptor >= 0 else {
            return .failure(.writeFailure(reason: String(cString: strerror(errno))))
        }
        defer { close(stagingDescriptor) }

        var stagingStatus = stat()
        var stagingPathStatus = stat()
        let stagingPathResult = stagingName.withCString {
            fstatat(rootDescriptor, $0, &stagingPathStatus, AT_SYMLINK_NOFOLLOW)
        }
        guard fstat(stagingDescriptor, &stagingStatus) == 0,
            stagingPathResult == 0,
            Self.sameEntry(stagingStatus, stagingPathStatus),
            stagingStatus.st_mode & S_IFMT == S_IFDIR,
            stagingStatus.st_uid == geteuid(),
            stagingStatus.st_mode & mode_t(S_IRWXG | S_IRWXO) == 0
        else {
            return .failure(.writeFailure(reason: "回执历史 tombstone 身份不安全"))
        }

        var movedHosts: [HostID] = []
        func rollback() -> Bool {
            var restored = true
            for host in movedHosts.reversed() {
                let name = host.surfaceID.rawValue
                let result = name.withCString { pointer in
                    renameatx_np(
                        stagingDescriptor,
                        pointer,
                        rootDescriptor,
                        pointer,
                        UInt32(RENAME_EXCL))
                }
                restored = restored && result == 0
            }
            return restored
        }

        for host in presentHosts {
            do {
                try beforeStaging(host)
            } catch {
                let restored = rollback()
                let suffix = restored ? "" : "；回滚失败"
                return .failure(
                    .writeFailure(reason: "历史清理被拒绝：\(error.localizedDescription)\(suffix)"))
            }
            let name = host.surfaceID.rawValue
            guard Self.pathMatchesDescriptor(historyRoot, expected: rootStatus),
                let expectedStatus = sourceStatusByHost[host]
            else {
                let restored = rollback()
                let suffix = restored ? "" : "；回滚失败"
                return .failure(.writeFailure(reason: "历史根目录身份已改变\(suffix)"))
            }
            var currentStatus = stat()
            let currentResult = name.withCString {
                fstatat(rootDescriptor, $0, &currentStatus, AT_SYMLINK_NOFOLLOW)
            }
            guard currentResult == 0, Self.sameEntry(expectedStatus, currentStatus) else {
                let restored = rollback()
                let suffix = restored ? "" : "；回滚失败"
                return .failure(.writeFailure(reason: "历史 surface 身份已改变\(suffix)"))
            }
            let moved = name.withCString { pointer in
                renameatx_np(
                    rootDescriptor,
                    pointer,
                    stagingDescriptor,
                    pointer,
                    UInt32(RENAME_EXCL))
            }
            guard moved == 0 else {
                let code = errno
                let restored = rollback()
                let suffix = restored ? "" : "；回滚失败"
                return .failure(
                    .writeFailure(
                        reason: "历史 staging 失败：\(String(cString: strerror(code)))\(suffix)"))
            }
            movedHosts.append(host)
            var isolatedStatus = stat()
            let isolatedResult = name.withCString {
                fstatat(stagingDescriptor, $0, &isolatedStatus, AT_SYMLINK_NOFOLLOW)
            }
            guard isolatedResult == 0, Self.sameEntry(expectedStatus, isolatedStatus) else {
                let restored = rollback()
                let suffix = restored ? "" : "；回滚失败"
                return .failure(.writeFailure(reason: "历史 staging 身份校验失败\(suffix)"))
            }
        }

        guard Self.pathMatchesDescriptor(historyRoot, expected: rootStatus) else {
            let restored = rollback()
            let suffix = restored ? "" : "；回滚失败"
            return .failure(.writeFailure(reason: "历史根目录在提交前已改变\(suffix)"))
        }

        // One same-directory rename publishes the durable commit marker. Before it, a crash leaves
        // `.staging-*`, which the next lock owner rolls back. After it, `.clear-*` is committed and
        // must only move toward descriptor-relative reclamation, never rollback.
        let committed = stagingName.withCString { stagingPointer in
            committedName.withCString { committedPointer in
                renameatx_np(
                    rootDescriptor,
                    stagingPointer,
                    rootDescriptor,
                    committedPointer,
                    UInt32(RENAME_EXCL))
            }
        }
        guard committed == 0 else {
            let code = errno
            let restored = rollback()
            let suffix = restored ? "" : "；回滚失败"
            return .failure(
                .writeFailure(
                    reason: "历史 commit marker 发布失败：\(String(cString: strerror(code)))\(suffix)"))
        }
        var committedStatus = stat()
        let committedStatusResult = committedName.withCString {
            fstatat(rootDescriptor, $0, &committedStatus, AT_SYMLINK_NOFOLLOW)
        }
        guard committedStatusResult == 0, Self.sameEntry(stagingStatus, committedStatus) else {
            // The atomic rename already crossed the commit boundary. Do not claim rollback.
            return .success(())
        }

        // Recursive reclamation is descriptor-relative and resumable; even a partial cleanup
        // failure leaves only a private hidden committed tombstone and therefore returns success.
        _ = Self.removeCommittedHistoryTombstone(
            named: committedName,
            rootDescriptor: rootDescriptor,
            beforeRemoval: beforeCommittedCleanup)
        return .success(())
    }

    private static func pathMatchesDescriptor(_ url: URL, expected: stat) -> Bool {
        var current = stat()
        let result = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return lstat(path, &current)
        }
        return result == 0
            && current.st_mode & S_IFMT == S_IFDIR
            && sameEntry(expected, current)
    }

    private static func sameEntry(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino
    }

    private static func isCommittedHistoryTombstoneName(_ name: String) -> Bool {
        let prefix = ".clear-"
        guard name.hasPrefix(prefix) else { return false }
        return UUID(uuidString: String(name.dropFirst(prefix.count))) != nil
    }

    private static func isInterruptedHistoryStagingName(_ name: String) -> Bool {
        let prefix = ".staging-"
        guard name.hasPrefix(prefix) else { return false }
        return UUID(uuidString: String(name.dropFirst(prefix.count))) != nil
    }

    private static func recoverInterruptedHistoryStaging(
        rootDescriptor: Int32,
        hosts: [HostID]
    ) -> Bool {
        scanHistoryRootEntries(rootDescriptor: rootDescriptor) { name in
            guard isInterruptedHistoryStagingName(name) else { return true }
            return recoverInterruptedHistoryStaging(
                named: name,
                rootDescriptor: rootDescriptor,
                hosts: hosts)
        }
    }

    /// Opens one descriptor-relative root snapshot and visits at most the audited directory limit.
    /// Callers keep their own recovery/cleanup policy while sharing the no-follow traversal.
    private static func scanHistoryRootEntries(
        rootDescriptor: Int32,
        visit: (String) -> Bool
    ) -> Bool {
        let scanDescriptor = openat(
            rootDescriptor,
            ".",
            O_RDONLY | O_NONBLOCK | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard scanDescriptor >= 0, let stream = fdopendir(scanDescriptor) else {
            if scanDescriptor >= 0 { close(scanDescriptor) }
            return false
        }
        defer { closedir(stream) }

        var inspectedItemCount = 0
        while true {
            errno = 0
            guard let entry = readdir(stream) else { return errno == 0 }
            let name = historyEntryName(entry)
            guard name != ".", name != ".." else { continue }
            guard inspectedItemCount < historyDirectoryEntryLimit else { return false }
            inspectedItemCount += 1
            guard visit(name) else { return false }
        }
    }

    private static func recoverInterruptedHistoryStaging(
        named stagingName: String,
        rootDescriptor: Int32,
        hosts: [HostID]
    ) -> Bool {
        guard isInterruptedHistoryStagingName(stagingName) else { return false }
        var pathStatus = stat()
        let pathStatusResult = stagingName.withCString {
            fstatat(rootDescriptor, $0, &pathStatus, AT_SYMLINK_NOFOLLOW)
        }
        guard pathStatusResult == 0,
            pathStatus.st_mode & S_IFMT == S_IFDIR,
            pathStatus.st_uid == geteuid(),
            pathStatus.st_mode & mode_t(S_IRWXG | S_IRWXO) == 0
        else { return false }

        let stagingDescriptor = stagingName.withCString {
            openat(
                rootDescriptor,
                $0,
                O_RDONLY | O_NONBLOCK | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard stagingDescriptor >= 0 else { return false }
        defer { close(stagingDescriptor) }
        var openedStatus = stat()
        guard fstat(stagingDescriptor, &openedStatus) == 0,
            sameEntry(pathStatus, openedStatus)
        else { return false }

        var restoredHosts: [HostID] = []
        func rollbackRecovery() -> Bool {
            var rolledBack = true
            for host in restoredHosts.reversed() {
                let name = host.surfaceID.rawValue
                let result = name.withCString { pointer in
                    renameatx_np(
                        rootDescriptor,
                        pointer,
                        stagingDescriptor,
                        pointer,
                        UInt32(RENAME_EXCL))
                }
                rolledBack = rolledBack && result == 0
            }
            return rolledBack
        }

        for host in hosts {
            let surfaceName = host.surfaceID.rawValue
            var isolatedStatus = stat()
            let isolatedResult = surfaceName.withCString {
                fstatat(stagingDescriptor, $0, &isolatedStatus, AT_SYMLINK_NOFOLLOW)
            }
            if isolatedResult != 0 {
                if errno == ENOENT { continue }
                _ = rollbackRecovery()
                return false
            }
            guard isolatedStatus.st_mode & S_IFMT == S_IFDIR else {
                _ = rollbackRecovery()
                return false
            }

            var liveStatus = stat()
            let liveResult = surfaceName.withCString {
                fstatat(rootDescriptor, $0, &liveStatus, AT_SYMLINK_NOFOLLOW)
            }
            guard liveResult != 0, errno == ENOENT else {
                _ = rollbackRecovery()
                return false
            }
            let restored = surfaceName.withCString { pointer in
                renameatx_np(
                    stagingDescriptor,
                    pointer,
                    rootDescriptor,
                    pointer,
                    UInt32(RENAME_EXCL))
            }
            guard restored == 0 else {
                _ = rollbackRecovery()
                return false
            }
            restoredHosts.append(host)

            var restoredStatus = stat()
            let restoredStatusResult = surfaceName.withCString {
                fstatat(rootDescriptor, $0, &restoredStatus, AT_SYMLINK_NOFOLLOW)
            }
            guard restoredStatusResult == 0, sameEntry(isolatedStatus, restoredStatus) else {
                _ = rollbackRecovery()
                return false
            }
        }

        let removedStaging = stagingName.withCString {
            unlinkat(rootDescriptor, $0, AT_REMOVEDIR)
        }
        guard removedStaging == 0 else {
            _ = rollbackRecovery()
            return false
        }
        return true
    }

    private static func cleanupCommittedHistoryTombstones(rootDescriptor: Int32) {
        _ = scanHistoryRootEntries(rootDescriptor: rootDescriptor) { name in
            guard isCommittedHistoryTombstoneName(name) else { return true }
            _ = removeCommittedHistoryTombstone(
                named: name,
                rootDescriptor: rootDescriptor,
                beforeRemoval: { _ in })
            return true
        }
    }

    private static func removeCommittedHistoryTombstone(
        named name: String,
        rootDescriptor: Int32,
        beforeRemoval: (Int) throws -> Void
    ) -> Bool {
        guard isCommittedHistoryTombstoneName(name) else { return false }
        var tombstoneStatus = stat()
        let statusResult = name.withCString {
            fstatat(rootDescriptor, $0, &tombstoneStatus, AT_SYMLINK_NOFOLLOW)
        }
        guard statusResult == 0,
            tombstoneStatus.st_mode & S_IFMT == S_IFDIR,
            tombstoneStatus.st_uid == geteuid(),
            tombstoneStatus.st_mode & mode_t(S_IRWXG | S_IRWXO) == 0
        else { return false }
        var entryBudget = 4_096
        var removalIndex = 0
        return removeCommittedHistoryEntry(
            named: name,
            parentDescriptor: rootDescriptor,
            depthRemaining: 4,
            requirePrivateDirectory: true,
            entryBudget: &entryBudget,
            removalIndex: &removalIndex,
            beforeRemoval: beforeRemoval)
    }

    private static func removeCommittedHistoryEntry(
        named name: String,
        parentDescriptor: Int32,
        depthRemaining: Int,
        requirePrivateDirectory: Bool,
        entryBudget: inout Int,
        removalIndex: inout Int,
        beforeRemoval: (Int) throws -> Void
    ) -> Bool {
        guard entryBudget > 0 else { return false }
        entryBudget -= 1

        var entryStatus = stat()
        let statusResult = name.withCString {
            fstatat(parentDescriptor, $0, &entryStatus, AT_SYMLINK_NOFOLLOW)
        }
        if statusResult != 0 { return errno == ENOENT }

        if entryStatus.st_mode & S_IFMT == S_IFDIR {
            guard depthRemaining > 0,
                entryStatus.st_uid == geteuid(),
                !requirePrivateDirectory
                    || entryStatus.st_mode & mode_t(S_IRWXG | S_IRWXO) == 0
            else { return false }

            let childDescriptor = name.withCString {
                openat(
                    parentDescriptor,
                    $0,
                    O_RDONLY | O_NONBLOCK | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard childDescriptor >= 0 else { return false }
            var openedStatus = stat()
            guard fstat(childDescriptor, &openedStatus) == 0,
                sameEntry(entryStatus, openedStatus),
                let stream = fdopendir(childDescriptor)
            else {
                close(childDescriptor)
                return false
            }

            var childrenRemoved = true
            while let entry = readdir(stream) {
                let childName = historyEntryName(entry)
                guard childName != ".", childName != ".." else { continue }
                guard
                    removeCommittedHistoryEntry(
                        named: childName,
                        parentDescriptor: dirfd(stream),
                        depthRemaining: depthRemaining - 1,
                        requirePrivateDirectory: false,
                        entryBudget: &entryBudget,
                        removalIndex: &removalIndex,
                        beforeRemoval: beforeRemoval)
                else {
                    childrenRemoved = false
                    break
                }
            }
            closedir(stream)
            guard childrenRemoved else { return false }

            var finalStatus = stat()
            let finalStatusResult = name.withCString {
                fstatat(parentDescriptor, $0, &finalStatus, AT_SYMLINK_NOFOLLOW)
            }
            guard finalStatusResult == 0, sameEntry(entryStatus, finalStatus) else {
                return false
            }

            do {
                try beforeRemoval(removalIndex)
            } catch {
                return false
            }
            removalIndex += 1
            return name.withCString {
                unlinkat(parentDescriptor, $0, AT_REMOVEDIR)
            } == 0
        }

        do {
            try beforeRemoval(removalIndex)
        } catch {
            return false
        }
        removalIndex += 1
        return name.withCString { unlinkat(parentDescriptor, $0, 0) } == 0
    }

    private func archive(
        _ receipt: HostHookReceipt,
        data: Data
    ) -> Result<HostHookReceiptWriteOutcome, HostHookReceiptStoreError> {
        let directory = historyDirectory(host: receipt.host)
        let timestamp = UInt64(max(0, receipt.timestamp.timeIntervalSince1970) * 1_000_000)
        let destination = directory.appendingPathComponent(
            "\(timestamp)-\(UUID().uuidString.lowercased()).json")
        switch publish(data, to: destination) {
        case .failure(let error):
            return .failure(error)
        case .success:
            return pruneHistory(host: receipt.host, now: Date())
        }
    }

    private func pruneHistory(
        host: HostID,
        now: Date
    ) -> Result<HostHookReceiptWriteOutcome, HostHookReceiptStoreError> {
        let directory = historyDirectory(host: host)
        let keys: Set<URLResourceKey> = [
            .contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey,
        ]
        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]
            )
        } catch {
            return .failure(.writeFailure(reason: error.localizedDescription))
        }
        let cutoff = now.addingTimeInterval(-Self.historyRetention)
        let regular = files.compactMap { file -> (url: URL, modified: Date, event: Date)? in
            guard let values = try? file.resourceValues(forKeys: keys),
                values.isRegularFile == true,
                values.isSymbolicLink != true
            else { return nil }
            let eventDate: Date
            if case .success(let data) = readRegularFileBounded(
                at: file, maxBytes: 1 << 16, followSymlink: false),
                let receipt = try? Self.decode(data)
            {
                eventDate = receipt.timestamp
            } else {
                eventDate = .distantPast
            }
            return (file, values.contentModificationDate ?? .distantPast, eventDate)
        }.sorted {
            $0.event == $1.event ? $0.modified > $1.modified : $0.event > $1.event
        }
        for (index, entry) in regular.enumerated()
        where entry.modified < cutoff || index >= Self.historyLimitPerSurface {
            do {
                try FileManager.default.removeItem(at: entry.url)
            } catch {
                return .failure(.writeFailure(reason: error.localizedDescription))
            }
        }
        return .success(.written)
    }

    private static func encode(_ receipt: HostHookReceipt) throws -> Data {
        let encoder = JSONEncoder()
        // `.iso8601` drops all fractional seconds, while `ISO8601DateFormatter` with
        // `.withFractionalSeconds` still emits only milliseconds. Different native events can
        // legitimately land inside the same millisecond, so persist the Date's IEEE-754 epoch
        // value directly; JSON's round-trip representation preserves every bit Date exposes.
        encoder.dateEncodingStrategy = .custom { date, valueEncoder in
            var container = valueEncoder.singleValueContainer()
            try container.encode(date.timeIntervalSince1970)
        }
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(receipt)
    }

    private static func decode(_ data: Data) throws -> HostHookReceipt {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { valueDecoder in
            let container = try valueDecoder.singleValueContainer()
            if let seconds = try? container.decode(Double.self), seconds.isFinite {
                return Date(timeIntervalSince1970: seconds)
            }
            if let value = try? container.decode(String.self),
                let timestamp = hostHookReceiptTimestamp(from: value)
            {
                return timestamp
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "回执 timestamp 不是有限 epoch seconds 或受支持的 ISO-8601 时间")
        }
        return try decoder.decode(HostHookReceipt.self, from: data)
    }

    private func currentInstallationIDUnlocked(host: HostID) -> UUID? {
        currentInstallationUnlocked(host: host)?.installationID
    }

    private func currentInstallationUnlocked(host: HostID) -> ActiveHostInstallation? {
        guard
            case .success(let data) = readRegularFileBounded(
                at: installationFile(host: host), maxBytes: 1 << 12, followSymlink: false),
            let marker = try? Self.markerDecoder.decode(ActiveHostInstallation.self, from: data),
            marker.schema == ActiveHostInstallation.currentSchema,
            marker.host == host
        else { return nil }
        return marker
    }

    private func flattenInstallationLock(
        _ locked: LockedRun<Result<Void, HostHookReceiptStoreError>>
    ) -> Result<Void, HostHookReceiptStoreError> {
        switch locked {
        case .ran(let result): result
        case .skipped: .failure(.lockBusy)
        case .failed(let code): .failure(.lockFailed(errno: code))
        }
    }

    private static var markerEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private static var markerDecoder: JSONDecoder { JSONDecoder() }
}

private struct ActiveHostInstallation: Codable {
    static let currentSchema = 2
    let schema: Int
    let host: HostID
    let installationID: UUID
    let scopeFingerprint: String

    private enum CodingKeys: String, CodingKey {
        case schema
        case host
        case installationID = "installation_id"
        case scopeFingerprint = "scope_fingerprint"
    }
}

extension HostHookReceiptStore {
    private static func isValidHistoricalReceipt(
        _ receipt: HostHookReceipt,
        binding: HostCapabilityBinding
    ) -> Bool {
        switch receipt.schema {
        case HostHookReceipt.currentSchema:
            return receipt.bindingID == binding.id
        case HostHookReceipt.legacySchema:
            return receipt.bindingID == binding.id
                || receipt.bindingID
                    == HostHookReceipt.legacyBindingID(
                        host: receipt.host, nativeEvent: receipt.nativeEvent)
        default:
            return false
        }
    }
}

private func writeHostHookReceiptData(_ data: Data, to descriptor: Int32) throws {
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
                throw hostHookReceiptPOSIXError(errno)
            }
            guard count > 0 else { throw hostHookReceiptPOSIXError(EIO) }
            written += count
        }
    }
}

private func hostHookReceiptPOSIXError(_ code: Int32) -> NSError {
    NSError(domain: NSPOSIXErrorDomain, code: Int(code))
}

/// Numeric epoch timestamps are the new lossless encoding. String decoding remains compatible
/// with both whole-second schema-1 receipts and any fractional ISO-8601 producer.
private func hostHookReceiptTimestamp(from value: String) -> Date? {
    let fractionalFormatter = ISO8601DateFormatter()
    fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let timestamp = fractionalFormatter.date(from: value) {
        return timestamp
    }

    let legacyFormatter = ISO8601DateFormatter()
    legacyFormatter.formatOptions = [.withInternetDateTime]
    return legacyFormatter.date(from: value)
}
