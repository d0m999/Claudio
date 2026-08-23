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
            ?? (
                schema == Self.currentSchema
                    ? HostCapabilityCatalog.binding(host: host, nativeEvent: nativeEvent)?.id
                    : Self.legacyBindingID(host: host, nativeEvent: nativeEvent)
            )
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

    /// 返回与当前 activation 解耦的脱敏历史。断开或版本失效不会删除它；只保留最近 30 天、
    /// 每个 surface 最多 20 条。损坏或非 regular file 会被忽略，绝不提升为当前连接证据。
    public func receiptHistory(host: HostID, now: Date = Date()) -> [HostHookReceipt] {
        let directory = historyDirectory(host: host)
        guard
            let files = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [
                    .contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey,
                ],
                options: [.skipsHiddenFiles])
        else { return [] }
        let cutoff = now.addingTimeInterval(-Self.historyRetention)
        return files.compactMap { file -> HostHookReceipt? in
            guard
                let values = try? file.resourceValues(forKeys: [
                    .contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey,
                ]),
                values.isRegularFile == true,
                values.isSymbolicLink != true,
                (values.contentModificationDate ?? .distantPast) >= cutoff,
                case .success(let data) = readRegularFileBounded(
                    at: file, maxBytes: 1 << 16, followSymlink: false),
                let receipt = try? Self.decode(data),
                receipt.host == host,
                let binding = HostCapabilityCatalog.binding(
                    host: host, nativeEvent: receipt.nativeEvent),
                binding.event == receipt.semanticEvent,
                Self.isValidHistoricalReceipt(receipt, binding: binding)
            else { return nil }
            return receipt
        }
        .sorted { $0.timestamp > $1.timestamp }
        .prefix(Self.historyLimitPerSurface)
        .map { $0 }
    }

    /// 用户显式清除某个 surface 的历史；当前稳定回执与 activation marker 不受影响。
    public func clearReceiptHistory(
        host: HostID
    ) -> Result<Void, HostHookReceiptStoreError> {
        let locked = withNonBlockingLock(path: installationLockFile(host: host).path) {
            let directory = historyDirectory(host: host)
            guard FileManager.default.fileExists(atPath: directory.path) else {
                return Result<Void, HostHookReceiptStoreError>.success(())
            }
            do {
                try FileManager.default.removeItem(at: directory)
                return .success(())
            } catch {
                return .failure(.writeFailure(reason: error.localizedDescription))
            }
        }
        return flattenInstallationLock(locked)
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
