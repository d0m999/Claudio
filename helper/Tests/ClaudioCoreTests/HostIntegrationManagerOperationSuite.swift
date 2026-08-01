import ClaudioCore
import Foundation

@MainActor
func runHostIntegrationManagerOperationSuites() async {
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
        HostIntegrationSnapshot(
            host: host,
            runtime: runtime,
            availability: .available,
            configuration: connected ? .configured : .notConfigured,
            writability: .writable,
            activation: connected
                ? .awaitingReceipt(installationID: installationID)
                : .none,
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
