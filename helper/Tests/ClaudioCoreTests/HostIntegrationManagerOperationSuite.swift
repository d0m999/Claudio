import ClaudioCore
import Foundation

@MainActor
func runHostIntegrationManagerOperationSuites() async {
    await asyncSuite("HostIntegrationManager：registry 只发布正常产品表面，AX 仅保留直接诊断目录") {
        let manager = HostIntegrationManager(
            adapters: [], bootstrapper: OperationReadyRuntimeBootstrapper())
        let capabilities = await manager.capabilities()
        let descriptors = await manager.descriptors()
        expect(
            Set(capabilities.keys) == Set(HostID.productVisibleCases)
                && capabilities[.chatGPTDesktopAX] == nil
                && capabilities[.claudeDesktopAX] == nil,
            "manager 能力 registry 不得发布 AX Beta identity")
        expect(
            descriptors.map(\.host) == HostID.productVisibleCases,
            "descriptor registry 必须只覆盖正常产品表面")
    }

    await asyncSuite("HostIntegrationManager：连接进行中可观察，失败保持到显式刷新") {
        let adapter = ControlledHostIntegrationAdapter(
            host: .claudeCode,
            initiallyConnected: false,
            connectFailure: .configuration(reason: "fixture connect failure"))
        let manager = HostIntegrationManager(
            adapters: [adapter], bootstrapper: OperationReadyRuntimeBootstrapper())
        _ = await manager.refresh()

        let connectTask = Task { await manager.connect(.claudeCode) }
        await adapter.waitUntilConnectStarted()

        let whileConnecting = await manager.snapshots()
        expect(
            operation(for: .claudeCode, in: whileConnecting) == .connecting,
            "adapter 尚未返回时 manager 快照必须暴露 connecting")
        expect(
            operation(for: .codex, in: whileConnecting) == .idle,
            "Claude 连接中不得改变 Codex 的 operation")

        let refreshedWhileConnecting = await manager.refresh()
        expect(
            operation(for: .claudeCode, in: refreshedWhileConnecting) == .connecting,
            "并发 refresh 不得用旧 inspect 结果覆盖 connecting")

        await adapter.releaseConnect()
        guard case .failure(.configuration(let reason)) = await connectTask.value else {
            expect(false, "受控 adapter 的连接必须按 fixture 失败")
            return
        }
        expect(reason == "fixture connect failure", "manager 必须原样返回 adapter 错误")

        let afterFailure = await manager.snapshots()
        expect(
            operation(for: .claudeCode, in: afterFailure)
                == .failed(reason: "fixture connect failure"),
            "失败完成后 cached snapshot 必须保留 failed 及原因")

        let afterExplicitRefresh = await manager.refresh()
        expect(
            operation(for: .claudeCode, in: afterExplicitRefresh) == .idle,
            "后续显式 refresh 应以新的 inspect 事实清除 failed")
    }

    await asyncSuite("HostIntegrationManager：断开进行中可观察，成功后恢复 idle") {
        let adapter = ControlledHostIntegrationAdapter(
            host: .codex,
            initiallyConnected: true)
        let manager = HostIntegrationManager(
            adapters: [adapter], bootstrapper: OperationReadyRuntimeBootstrapper())
        _ = await manager.refresh()

        let disconnectTask = Task { await manager.disconnect(.codex) }
        await adapter.waitUntilDisconnectStarted()

        let whileDisconnecting = await manager.snapshots()
        expect(
            operation(for: .codex, in: whileDisconnecting) == .disconnecting,
            "adapter 尚未返回时 manager 快照必须暴露 disconnecting")
        expect(
            operation(for: .claudeCode, in: whileDisconnecting) == .idle,
            "Codex 断开中不得改变 Claude 的 operation")
        expect(
            whileDisconnecting.first(where: { $0.host == .codex })?.latestReceipt?.event == .stop,
            "切换为 disconnecting 的快照复制不得丢掉 adapter 已提供的最新回执")

        let refreshedWhileDisconnecting = await manager.refresh()
        expect(
            operation(for: .codex, in: refreshedWhileDisconnecting) == .disconnecting,
            "并发 refresh 不得用旧 inspect 结果覆盖 disconnecting")

        await adapter.releaseDisconnect()
        guard case .success(let disconnected) = await disconnectTask.value else {
            expect(false, "受控 adapter 的断开必须成功")
            return
        }
        expect(disconnected.operation == .idle, "成功结果必须恢复 idle")
        expect(disconnected.configuration == .notConfigured, "成功结果必须反映已断开")

        let afterSuccess = await manager.snapshots()
        expect(
            operation(for: .codex, in: afterSuccess) == .idle,
            "断开成功后 cached snapshot 必须恢复 idle")
        expect(
            afterSuccess.first(where: { $0.host == .codex })?.configuration == .notConfigured,
            "断开成功后 cached snapshot 必须保留 adapter 的最新配置事实")
    }

    await asyncSuite("HostIntegrationManager：refresh 与 connect 的 operation 投影保留 latestReceipt") {
        let adapter = ControlledHostIntegrationAdapter(
            host: .claudeCode,
            initiallyConnected: false)
        let manager = HostIntegrationManager(
            adapters: [adapter], bootstrapper: OperationReadyRuntimeBootstrapper())

        let initial = await manager.refresh()
        expect(
            initial.first(where: { $0.host == .claudeCode })?.latestReceipt == nil,
            "未连接 fixture 不应伪造回执")

        let connectTask = Task { await manager.connect(.claudeCode) }
        await adapter.waitUntilConnectStarted()
        await adapter.releaseConnect()
        guard case .success(let connected) = await connectTask.value else {
            expect(false, "受控 adapter 的连接必须成功")
            return
        }
        expect(
            connected.latestReceipt?.event == .stop,
            "connect 成功返回的 idle 投影必须保留 adapter 回执")

        let cached = await manager.snapshots()
        expect(
            cached.first(where: { $0.host == .claudeCode })?.latestReceipt
                == connected.latestReceipt,
            "connect 后 manager cache 必须保留同一条回执")
        let refreshed = await manager.refresh()
        expect(
            refreshed.first(where: { $0.host == .claudeCode })?.latestReceipt
                == connected.latestReceipt,
            "显式 refresh 的 idle 投影不得清空回执")
    }
}

@MainActor
private func operation(
    for host: HostID,
    in snapshots: [HostIntegrationSnapshot]
) -> HostOperationState? {
    snapshots.first(where: { $0.host == host })?.operation
}

private actor ControlledHostIntegrationAdapter: HostIntegrationAdapter {
    nonisolated let host: HostID
    nonisolated let capabilities: [HostCapabilityBinding]

    private let installationID = UUID(uuidString: "10000000-0000-4000-8000-000000000001")!
    private let connectFailure: HostIntegrationActionError?
    private var connected: Bool

    private var connectStarted = false
    private var connectStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var connectRelease: CheckedContinuation<Void, Never>?

    private var disconnectStarted = false
    private var disconnectStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var disconnectRelease: CheckedContinuation<Void, Never>?

    init(
        host: HostID,
        initiallyConnected: Bool,
        connectFailure: HostIntegrationActionError? = nil
    ) {
        self.host = host
        self.capabilities = HostCapabilityCatalog.bindings(for: host)
        self.connected = initiallyConnected
        self.connectFailure = connectFailure
    }

    func inspect(runtime: SharedRuntimeHealth) -> HostIntegrationSnapshot {
        snapshot(runtime: runtime)
    }

    func connect(
        runtime: SharedRuntimeHealth
    ) async -> Result<HostIntegrationSnapshot, HostIntegrationActionError> {
        connectStarted = true
        connectStartWaiters.forEach { $0.resume() }
        connectStartWaiters.removeAll()
        await withCheckedContinuation { continuation in
            connectRelease = continuation
        }
        if let connectFailure {
            return .failure(connectFailure)
        }
        connected = true
        return .success(snapshot(runtime: runtime))
    }

    func disconnect(
        runtime: SharedRuntimeHealth
    ) async -> Result<HostIntegrationSnapshot, HostIntegrationActionError> {
        disconnectStarted = true
        disconnectStartWaiters.forEach { $0.resume() }
        disconnectStartWaiters.removeAll()
        await withCheckedContinuation { continuation in
            disconnectRelease = continuation
        }
        connected = false
        return .success(snapshot(runtime: runtime))
    }

    func waitUntilConnectStarted() async {
        if connectStarted { return }
        await withCheckedContinuation { continuation in
            connectStartWaiters.append(continuation)
        }
    }

    func releaseConnect() {
        connectRelease?.resume()
        connectRelease = nil
    }

    func waitUntilDisconnectStarted() async {
        if disconnectStarted { return }
        await withCheckedContinuation { continuation in
            disconnectStartWaiters.append(continuation)
        }
    }

    func releaseDisconnect() {
        disconnectRelease?.resume()
        disconnectRelease = nil
    }

    private func snapshot(runtime: SharedRuntimeHealth) -> HostIntegrationSnapshot {
        let latestReceipt = connected
            ? HostReceiptEvidence(
                installationID: installationID,
                nativeEvent: "Stop",
                event: .stop,
                timestamp: Date(timeIntervalSince1970: 42),
                playbackResult: .played)
            : nil
        return HostIntegrationSnapshot(
            host: host,
            runtime: runtime,
            availability: .available,
            configuration: connected ? .configured : .notConfigured,
            writability: .writable,
            activation: connected
                ? .awaitingReceipt(installationID: installationID)
                : .none,
            latestReceipt: latestReceipt,
            installationID: connected ? installationID : nil)
    }
}

private struct OperationReadyRuntimeBootstrapper: SharedRuntimeBootstrapping {
    func inspect() -> SharedRuntimeHealth { .ready }

    func bootstrap() -> Result<SharedRuntimeBootstrapOutcome, SetupError> {
        .success(
            SharedRuntimeBootstrapOutcome(
                copiedBinary: false,
                copiedPacks: [],
                salvaged: [],
                packSelection: .untouched))
    }
}
