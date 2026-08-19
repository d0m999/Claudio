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
    public static let currentSchema = 1

    public let schema: Int
    public let installationID: UUID
    public let host: HostID
    public let nativeEvent: String
    public let semanticEvent: Event
    public let timestamp: Date
    public let playbackResult: HostHookPlaybackResult

    public init(
        schema: Int = HostHookReceipt.currentSchema,
        installationID: UUID,
        host: HostID,
        nativeEvent: String,
        semanticEvent: Event,
        timestamp: Date,
        playbackResult: HostHookPlaybackResult
    ) {
        self.schema = schema
        self.installationID = installationID
        self.host = host
        self.nativeEvent = nativeEvent
        self.semanticEvent = semanticEvent
        self.timestamp = timestamp
        self.playbackResult = playbackResult
    }

    private enum CodingKeys: String, CodingKey {
        case schema
        case installationID = "installation_id"
        case host
        case nativeEvent = "native_event"
        case semanticEvent = "semantic_event"
        case timestamp
        case playbackResult = "playback_result"
    }
}

public enum HostHookReceiptWriteOutcome: Sendable, Equatable {
    case written
}

/// 回执失败只影响可观察证据（activation / latest diagnosis）；hook 调用方可以忽略整个
/// `Result` 并立即退出。
public enum HostHookReceiptStoreError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidReceipt
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
    public let receiptsRoot: URL
    public let locksRoot: URL
    public let installationsRoot: URL
    public let installationLocksRoot: URL

    public init(
        receiptsRoot: URL,
        locksRoot: URL,
        installationsRoot: URL? = nil,
        installationLocksRoot: URL? = nil
    ) {
        self.receiptsRoot = receiptsRoot
        self.locksRoot = locksRoot
        let integrationsRoot = receiptsRoot.deletingLastPathComponent()
        self.installationsRoot = installationsRoot
            ?? integrationsRoot.appendingPathComponent("installations", isDirectory: true)
        self.installationLocksRoot = installationLocksRoot
            ?? integrationsRoot.appendingPathComponent("installation-locks", isDirectory: true)
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
        installationID: UUID
    ) -> Result<Void, HostHookReceiptStoreError> {
        let marker = ActiveHostInstallation(
            schema: ActiveHostInstallation.currentSchema,
            host: host,
            installationID: installationID)
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
        currentInstallationIDUnlocked(host: host)
    }

    /// 每个宿主原生事件拥有独立 JSON。未知/unsupported 事件没有路径，避免把外部输入当文件名。
    public func receiptFile(host: HostID, nativeEvent: String) -> URL? {
        guard HostCapabilityCatalog.semanticEvent(host: host, nativeEvent: nativeEvent) != nil else {
            return nil
        }
        return receiptsRoot
            .appendingPathComponent(host.rawValue, isDirectory: true)
            .appendingPathComponent("\(nativeEvent).json")
    }

    /// 与 JSON 一一对应的非阻塞独立锁；一个事件的争用不会吞掉同宿主或另一宿主的事件。
    public func lockFile(host: HostID, nativeEvent: String) -> URL? {
        guard HostCapabilityCatalog.semanticEvent(host: host, nativeEvent: nativeEvent) != nil else {
            return nil
        }
        return locksRoot
            .appendingPathComponent(host.rawValue, isDirectory: true)
            .appendingPathComponent("\(nativeEvent).lock")
    }

    public func store(
        _ receipt: HostHookReceipt
    ) -> Result<HostHookReceiptWriteOutcome, HostHookReceiptStoreError> {
        guard receipt.schema == HostHookReceipt.currentSchema,
            HostCapabilityCatalog.semanticEvent(
                host: receipt.host, nativeEvent: receipt.nativeEvent) == receipt.semanticEvent,
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
                publish(data, to: destination)
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

    /// 只有当前 installation、请求的宿主/原生事件、catalog 语义和 schema 全部匹配时，
    /// 才把磁盘回执提升为结构化 evidence。是否可用作 activation 由 adapter 另行限制为
    /// `UserPromptSubmit`；其它受支持事件只进入 latest diagnosis。损坏、旧代次或错位文件全部
    /// 返回 `nil`。
    public func receiptEvidence(
        host: HostID,
        nativeEvent: String,
        installationID: UUID
    ) -> HostReceiptEvidence? {
        guard
            currentInstallationID(host: host) == installationID,
            let expectedEvent = HostCapabilityCatalog.semanticEvent(
                host: host, nativeEvent: nativeEvent),
            let file = receiptFile(host: host, nativeEvent: nativeEvent),
            case .success(let data) = readRegularFileBounded(
                at: file, maxBytes: 1 << 16, followSymlink: false),
            let receipt = try? Self.decode(data),
            receipt.schema == HostHookReceipt.currentSchema,
            receipt.installationID == installationID,
            receipt.host == host,
            receipt.nativeEvent == nativeEvent,
            receipt.semanticEvent == expectedEvent
        else {
            return nil
        }
        return HostReceiptEvidence(
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
        guard
            case .success(let data) = readRegularFileBounded(
                at: installationFile(host: host), maxBytes: 1 << 12, followSymlink: false),
            let marker = try? Self.markerDecoder.decode(ActiveHostInstallation.self, from: data),
            marker.schema == ActiveHostInstallation.currentSchema,
            marker.host == host
        else { return nil }
        return marker.installationID
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
    static let currentSchema = 1
    let schema: Int
    let host: HostID
    let installationID: UUID

    private enum CodingKeys: String, CodingKey {
        case schema
        case host
        case installationID = "installation_id"
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
