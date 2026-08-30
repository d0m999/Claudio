import Foundation

/// 新版 `claudio hook` 一次调用的注入式环境。`playEnvironment` 必须使用该宿主自己的
/// lock/state；构造器显式携带 host，以免测试或未来调用方误把两宿主又接回 legacy 全局去抖。
public struct HostHookEnvironment: Sendable {
    public let host: HostID
    public let playEnvironment: PlayEnvironment
    public let taskStartDebounceStateFile: URL
    public let taskStartDebounceInterval: TimeInterval
    public let receiptStore: HostHookReceiptStore
    public let now: @Sendable () -> Date

    public init(
        host: HostID,
        playEnvironment: PlayEnvironment,
        taskStartDebounceStateFile: URL? = nil,
        taskStartDebounceInterval: TimeInterval = 0.25,
        receiptStore: HostHookReceiptStore,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.host = host
        self.playEnvironment = playEnvironment
        self.taskStartDebounceStateFile =
            taskStartDebounceStateFile
            ?? playEnvironment.debounceStateFile.deletingLastPathComponent()
            .appendingPathComponent("task-start.state")
        self.taskStartDebounceInterval = taskStartDebounceInterval
        self.receiptStore = receiptStore
        self.now = now
    }
}

/// 生产 CLI 的单一环境工厂。宿主级锁/状态路径留在 Core 的路径事实源内，CLI 不自行拼装。
public func systemHostHookEnvironment(for host: HostID) -> HostHookEnvironment {
    HostHookEnvironment(
        host: host,
        playEnvironment: PlayEnvironment(
            surfaceID: host.surfaceID,
            lockFile: ClaudioPaths.hostPlayLockFile(host),
            debounceStateFile: ClaudioPaths.hostDebounceStateFile(host)),
        taskStartDebounceStateFile: ClaudioPaths.hostTaskStartDebounceStateFile(host),
        receiptStore: HostHookReceiptStore(
            receiptsRoot: ClaudioPaths.receiptsDirectory,
            locksRoot: ClaudioPaths.receiptLocksDirectory,
            installationsRoot: ClaudioPaths.activeInstallationsDirectory,
            installationLocksRoot: ClaudioPaths.activeInstallationLocksDirectory))
}

public struct HostHookHandlingOutcome: Sendable, Equatable {
    public let host: HostID
    public let nativeEvent: String
    public let event: Event
    public let playbackResult: HostHookPlaybackResult
    public let receiptWritten: Bool

    public init(
        host: HostID,
        nativeEvent: String,
        event: Event,
        playbackResult: HostHookPlaybackResult,
        receiptWritten: Bool
    ) {
        self.host = host
        self.nativeEvent = nativeEvent
        self.event = event
        self.playbackResult = playbackResult
        self.receiptWritten = receiptWritten
    }
}

/// 严格归一化、播放并写最小回执。任何失败都折叠进返回值，不 throw、不打印；CLI 无条件退出 0。
/// 未知事件与 Codex `StopFailure` 完全不进入播放链，也不会制造伪回执。
public func handleHostHook(
    host: HostID,
    nativeEvent: String,
    installationID: UUID,
    environment: HostHookEnvironment
) -> HostHookHandlingOutcome? {
    guard environment.host == host,
        let event = HostCapabilityCatalog.semanticEvent(host: host, nativeEvent: nativeEvent)
    else { return nil }

    let capture = SpawnResultCapture()
    let base = environment.playEnvironment
    let isTaskStart = event == .taskStart
    let observedPlayEnvironment = PlayEnvironment(
        surfaceID: base.surfaceID,
        afplayPath: base.afplayPath,
        lockFile: base.lockFile,
        configFile: base.configFile,
        userPacksDirectory: base.userPacksDirectory,
        bundledPacksDirectory: base.bundledPacksDirectory,
        spawner: base.spawner,
        debounceStateFile: isTaskStart
            ? environment.taskStartDebounceStateFile
            : base.debounceStateFile,
        debounceInterval: isTaskStart
            ? environment.taskStartDebounceInterval
            : base.debounceInterval,
        debounceSilentOutcomes: isTaskStart || base.debounceSilentOutcomes,
        now: base.now,
        logFile: base.logFile,
        logLockFile: base.logLockFile,
        dynamicQuietEnvironment: base.dynamicQuietEnvironment,
        spawnResultObserver: { succeeded in capture.record(succeeded) })
    let outcome = playSoundEvent(event.cliName, environment: observedPlayEnvironment)
    let playbackResult = redactedPlaybackResult(
        outcome: outcome, spawnSucceeded: capture.value)
    let receipt = HostHookReceipt(
        installationID: installationID,
        host: host,
        nativeEvent: nativeEvent,
        semanticEvent: event,
        timestamp: environment.now(),
        playbackResult: playbackResult)
    let written: Bool
    switch environment.receiptStore.store(receipt) {
    case .success:
        written = true
    case .failure(.staleInstallation):
        // Disconnect/reconnect 后迟到的旧 callback 是预期竞争，安全丢弃且不制造噪声。
        written = false
    case .failure(let error):
        written = false
        appendLogLine(
            event: event.cliName,
            reason: "回执写入失败（\(redactedReceiptStoreError(error))）",
            timestamp: environment.now(),
            to: base.logFile,
            lockFile: base.logLockFile)
    }
    return HostHookHandlingOutcome(
        host: host,
        nativeEvent: nativeEvent,
        event: event,
        playbackResult: playbackResult,
        receiptWritten: written)
}

private func redactedReceiptStoreError(_ error: HostHookReceiptStoreError) -> String {
    switch error {
    case .invalidReceipt: "invalid_receipt"
    case .invalidScopeFingerprint: "invalid_scope_fingerprint"
    case .staleInstallation: "stale_installation"
    case .encodingFailure: "encoding_failure"
    case .lockBusy: "lock_busy"
    case .lockFailed: "lock_failed"
    case .directoryCreationFailure: "directory_creation_failure"
    case .writeFailure: "write_failure"
    }
}

private final class SpawnResultCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Bool?

    var value: Bool? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func record(_ value: Bool) {
        lock.lock()
        stored = value
        lock.unlock()
    }
}

private func redactedPlaybackResult(
    outcome: PlayOutcome,
    spawnSucceeded: Bool?
) -> HostHookPlaybackResult {
    switch outcome {
    case .played:
        return spawnSucceeded == false ? .playbackFailed : .played
    case .disabled, .dynamicQuiet:
        return .muted
    case .skippedDebounce, .skippedRecentPlay:
        return .debounced
    case .notReady:
        return .notReady
    case .unknownEvent:
        return .unsupportedEvent
    case .lockFailed:
        return .playbackFailed
    }
}
