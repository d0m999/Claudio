import Darwin
import Foundation

public enum HostIntegrationActionError: Error, Sendable, Equatable, CustomStringConvertible {
    case runtimeUnavailable(reason: String)
    case hostUnavailable(reason: String)
    case configuration(reason: String)
    case transaction(ConfigFileTransactionError)
    case migrationConflict(reason: String)

    public var description: String {
        switch self {
        case .runtimeUnavailable(let reason): "claudi0 共享 runtime 不可用：\(reason)"
        case .hostUnavailable(let reason): reason
        case .configuration(let reason): reason
        case .transaction(let error): error.description
        case .migrationConflict(let reason): reason
        }
    }
}

/// UI、CLI、doctor 面向宿主配置的唯一 seam。adapter 自己拥有原生事件与 schema；调用方只看快照。
public protocol HostIntegrationAdapter: Sendable {
    var host: HostID { get }
    var capabilities: [HostCapabilityBinding] { get }

    func inspect(runtime: SharedRuntimeHealth) async -> HostIntegrationSnapshot
    func connect(
        runtime: SharedRuntimeHealth
    ) async -> Result<HostIntegrationSnapshot, HostIntegrationActionError>
    func disconnect(
        runtime: SharedRuntimeHealth
    ) async -> Result<HostIntegrationSnapshot, HostIntegrationActionError>
}

public protocol SharedRuntimeBootstrapping: Sendable {
    func inspect() -> SharedRuntimeHealth
    func bootstrap() -> Result<SharedRuntimeBootstrapOutcome, SetupError>
}

/// 固定 helper 的共享事实：manager 与 doctor 都必须拒绝 symlink、目录、空存根、
/// 丢失执行位和 quarantine，避免同一路径在两个入口得到相反结论。
func inspectSharedRuntimeHelper(at helper: URL) -> SharedRuntimeHealth {
    var helperStatus = stat()
    var inspectionErrno: Int32 = 0
    let inspected = helper.withUnsafeFileSystemRepresentation { path -> Bool in
        guard let path else {
            inspectionErrno = EINVAL
            return false
        }
        guard Darwin.lstat(path, &helperStatus) == 0 else {
            inspectionErrno = errno
            return false
        }
        return true
    }
    guard inspected else {
        if inspectionErrno == ENOENT || inspectionErrno == ENOTDIR {
            return .unavailable(reason: "helper 尚未发布")
        }
        return .damaged(
            reason: "无法检查 helper：\(String(cString: strerror(inspectionErrno)))")
    }
    guard (helperStatus.st_mode & S_IFMT) == S_IFREG else {
        return .damaged(reason: "helper 不是普通文件：\(helper.path)")
    }
    guard helperStatus.st_size > 0 else {
        return .damaged(reason: "helper 是空文件：\(helper.path)")
    }
    guard FileManager.default.isExecutableFile(atPath: helper.path) else {
        return .damaged(reason: "helper 不可执行：\(helper.path)")
    }
    guard !hasQuarantineAttribute(at: helper) else {
        return .damaged(reason: "helper 被 macOS 隔离：\(helper.path)")
    }
    return .ready
}

public struct SystemSharedRuntimeBootstrapper: SharedRuntimeBootstrapping {
    public let environment: SetupEnvironment

    public init(environment: SetupEnvironment) {
        self.environment = environment
    }

    public func inspect() -> SharedRuntimeHealth {
        let helper = environment.claudioBinaryDestination
        let helperHealth = inspectSharedRuntimeHelper(at: helper)
        guard helperHealth == .ready else { return helperHealth }
        switch checkPackIntegrity(
            configFile: environment.configFile,
            userPacksDirectory: environment.userPacksDirectory,
            bundledPacksDirectory: nil)
        {
        case .complete:
            return .ready
        case .noConfig:
            return .unavailable(reason: "尚未选择声音包")
        case .configUnreadable(let reason):
            return .damaged(reason: reason)
        case .packNotFound(let packID):
            return .damaged(reason: "当前声音包不存在：\(packID)")
        case .manifestUnreadable(let packID, let reason):
            return .damaged(reason: "声音包 \(packID) 的 manifest 无法读取：\(reason)")
        case .incomplete:
            // partial 声音包不是整个共享 runtime 损坏：其他事件仍可播放。
            // HostIntegrationManagerBridge 会把同一份 manifest 的逐事件 coverage
            // 交给 AudibilityMatrix，只让真正缺音的格子显示 missingSound。
            return .ready
        }
    }

    public func bootstrap() -> Result<SharedRuntimeBootstrapOutcome, SetupError> {
        performSharedRuntimeBootstrap(environment: environment)
    }
}

/// 双 adapter 的唯一协调者。刷新始终返回两个宿主，单侧失败不会短路另一侧；bootstrap 只运行共享层。
public actor HostIntegrationManager {
    private struct InFlightOperation {
        let revision: UInt64
        let state: HostOperationState
    }

    private let adapters: [HostID: any HostIntegrationAdapter]
    private let bootstrapper: any SharedRuntimeBootstrapping
    private var runtime: SharedRuntimeHealth
    private var cachedSnapshots: [HostID: HostIntegrationSnapshot]
    private var nextOperationRevision: UInt64
    private var latestOperationRevisions: [HostID: UInt64]
    private var inFlightOperations: [HostID: InFlightOperation]

    public init(
        adapters: [any HostIntegrationAdapter],
        bootstrapper: any SharedRuntimeBootstrapping
    ) {
        self.adapters = Dictionary(uniqueKeysWithValues: adapters.map { ($0.host, $0) })
        self.bootstrapper = bootstrapper
        self.runtime = bootstrapper.inspect()
        self.cachedSnapshots = [:]
        self.nextOperationRevision = 0
        self.latestOperationRevisions = [:]
        self.inFlightOperations = [:]
    }

    public func capabilities() -> [HostID: [HostCapabilityBinding]] {
        Dictionary(uniqueKeysWithValues: HostID.allCases.map { host in
            (host, adapters[host]?.capabilities ?? [])
        })
    }

    /// GUI 首启入口：只自举共享 runtime，不连接或改写任何宿主配置，然后刷新两侧事实。
    @discardableResult
    public func bootstrapSharedRuntime() async -> [HostIntegrationSnapshot] {
        switch bootstrapper.bootstrap() {
        case .success:
            runtime = bootstrapper.inspect()
        case .failure(let error):
            runtime = .damaged(reason: error.description)
        }
        return await refresh(usingCurrentRuntime: true)
    }

    public func refresh() async -> [HostIntegrationSnapshot] {
        runtime = bootstrapper.inspect()
        return await refresh(usingCurrentRuntime: true)
    }

    public func snapshots() -> [HostIntegrationSnapshot] {
        HostID.allCases.map { host in
            cachedSnapshots[host]
                ?? HostIntegrationSnapshot(
                    host: host,
                    runtime: runtime,
                    availability: .unavailable(reason: "尚未检测"),
                    configuration: .notConfigured,
                    writability: .unknown,
                    activation: .none,
                    operation: inFlightOperations[host]?.state ?? .idle)
        }
    }

    public func connect(
        _ host: HostID
    ) async -> Result<HostIntegrationSnapshot, HostIntegrationActionError> {
        let operationRevision = beginOperation(.connecting, host: host)
        if runtime != .ready {
            switch bootstrapper.bootstrap() {
            case .success:
                runtime = bootstrapper.inspect()
            case .failure(let error):
                runtime = .damaged(reason: error.description)
            }
            if runtime != .ready {
                _ = await refresh(usingCurrentRuntime: true)
                let error = HostIntegrationActionError.runtimeUnavailable(
                    reason: runtimeReason(runtime))
                recordFailure(error, host: host, revision: operationRevision)
                return .failure(error)
            }
        }
        guard let adapter = adapters[host] else {
            let error = HostIntegrationActionError.hostUnavailable(
                reason: "没有 \(host.displayName) adapter")
            recordFailure(error, host: host, revision: operationRevision)
            return .failure(error)
        }
        let operationRuntime = runtime
        let result = await adapter.connect(runtime: operationRuntime)
        switch result {
        case .success(let snapshot):
            let completed = snapshotWithOperation(snapshot, operation: .idle)
            if latestOperationRevisions[host] == operationRevision {
                inFlightOperations.removeValue(forKey: host)
                cachedSnapshots[host] = completed
            }
            return .success(completed)
        case .failure(let error):
            recordFailure(error, host: host, revision: operationRevision)
            let inspected = await adapter.inspect(runtime: runtime)
            if latestOperationRevisions[host] == operationRevision {
                cachedSnapshots[host] = snapshotWithOperation(
                    inspected, operation: .failed(reason: error.description))
            }
            return .failure(error)
        }
    }

    public func disconnect(
        _ host: HostID
    ) async -> Result<HostIntegrationSnapshot, HostIntegrationActionError> {
        let operationRevision = beginOperation(.disconnecting, host: host)
        guard let adapter = adapters[host] else {
            let error = HostIntegrationActionError.hostUnavailable(
                reason: "没有 \(host.displayName) adapter")
            recordFailure(error, host: host, revision: operationRevision)
            return .failure(error)
        }
        let operationRuntime = runtime
        let result = await adapter.disconnect(runtime: operationRuntime)
        switch result {
        case .success(let snapshot):
            let completed = snapshotWithOperation(snapshot, operation: .idle)
            if latestOperationRevisions[host] == operationRevision {
                inFlightOperations.removeValue(forKey: host)
                cachedSnapshots[host] = completed
            }
            return .success(completed)
        case .failure(let error):
            recordFailure(error, host: host, revision: operationRevision)
            let inspected = await adapter.inspect(runtime: runtime)
            if latestOperationRevisions[host] == operationRevision {
                cachedSnapshots[host] = snapshotWithOperation(
                    inspected, operation: .failed(reason: error.description))
            }
            return .failure(error)
        }
    }

    private func refresh(usingCurrentRuntime: Bool) async -> [HostIntegrationSnapshot] {
        _ = usingCurrentRuntime  // 明确：调用方已经决定是否重探 runtime。
        let currentRuntime = runtime
        // Actor 在 adapter await 期间可重入。刷新若跨过一次 connect/disconnect 的开始或完成，
        // 它手里的 inspect 结果就可能比 operation cache 更旧；逐宿主 revision 防止旧刷新把
        // connecting/disconnecting/failed 或刚完成的新事实覆盖回 idle。
        let operationRevisionsAtStart = latestOperationRevisions
        let activeHostsAtStart = Set(inFlightOperations.keys)
        let availableAdapters = HostID.allCases.compactMap { adapters[$0] }
        var inspected: [HostID: HostIntegrationSnapshot] = [:]
        await withTaskGroup(of: HostIntegrationSnapshot.self) { group in
            for adapter in availableAdapters {
                group.addTask { await adapter.inspect(runtime: currentRuntime) }
            }
            for await snapshot in group { inspected[snapshot.host] = snapshot }
        }
        var refreshed: [HostID: HostIntegrationSnapshot] = [:]
        for host in HostID.allCases {
            let operationChangedWhileRefreshing =
                latestOperationRevisions[host] != operationRevisionsAtStart[host]
            if activeHostsAtStart.contains(host) || operationChangedWhileRefreshing,
                let cached = cachedSnapshots[host]
            {
                refreshed[host] = cached
                continue
            }
            let snapshot = inspected[host]
                ?? HostIntegrationSnapshot(
                    host: host,
                    runtime: currentRuntime,
                    availability: .unavailable(reason: "adapter 不可用"),
                    configuration: .notConfigured,
                    writability: .unknown,
                    activation: .none)
            refreshed[host] = snapshotWithOperation(snapshot, operation: .idle)
        }
        cachedSnapshots = refreshed
        return HostID.allCases.compactMap { refreshed[$0] }
    }

    private func beginOperation(
        _ operation: HostOperationState,
        host: HostID
    ) -> UInt64 {
        nextOperationRevision &+= 1
        let revision = nextOperationRevision
        latestOperationRevisions[host] = revision
        inFlightOperations[host] = InFlightOperation(revision: revision, state: operation)
        let base = cachedSnapshots[host]
            ?? HostIntegrationSnapshot(
                host: host,
                runtime: runtime,
                availability: .unavailable(reason: "尚未检测"),
                configuration: .notConfigured,
                writability: .unknown,
                activation: .none)
        cachedSnapshots[host] = snapshotWithOperation(base, operation: operation)
        return revision
    }

    private func recordFailure(
        _ error: HostIntegrationActionError,
        host: HostID,
        revision: UInt64
    ) {
        guard latestOperationRevisions[host] == revision else { return }
        inFlightOperations.removeValue(forKey: host)
        let base = cachedSnapshots[host]
            ?? HostIntegrationSnapshot(
                host: host,
                runtime: runtime,
                availability: .unavailable(reason: "尚未检测"),
                configuration: .notConfigured,
                writability: .unknown,
                activation: .none)
        cachedSnapshots[host] = snapshotWithOperation(
            base, operation: .failed(reason: error.description))
    }
}

private func snapshotWithOperation(
    _ snapshot: HostIntegrationSnapshot,
    operation: HostOperationState
) -> HostIntegrationSnapshot {
    HostIntegrationSnapshot(
        host: snapshot.host,
        runtime: snapshot.runtime,
        availability: snapshot.availability,
        configuration: snapshot.configuration,
        writability: snapshot.writability,
        activation: snapshot.activation,
        operation: operation,
        installationID: snapshot.installationID)
}

private func runtimeReason(_ health: SharedRuntimeHealth) -> String {
    switch health {
    case .ready: "已就绪"
    case .unavailable(let reason), .damaged(let reason): reason
    }
}
