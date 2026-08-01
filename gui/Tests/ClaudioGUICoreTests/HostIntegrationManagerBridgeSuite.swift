import ClaudioCore
import ClaudioGUICore
import Foundation

private final class BridgeBootstrapper: SharedRuntimeBootstrapping, @unchecked Sendable {
    private let lock = NSLock()
    private var bootstrapCalls = 0
    private var inspectCalls = 0

    func inspect() -> SharedRuntimeHealth {
        lock.lock()
        inspectCalls += 1
        lock.unlock()
        return .ready
    }

    func bootstrap() -> Result<SharedRuntimeBootstrapOutcome, SetupError> {
        lock.lock()
        bootstrapCalls += 1
        lock.unlock()
        return .success(
            SharedRuntimeBootstrapOutcome(
                copiedBinary: false,
                copiedPacks: [],
                salvaged: [],
                packSelection: .untouched))
    }

    func counts() -> (bootstrap: Int, inspect: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (bootstrapCalls, inspectCalls)
    }
}

private actor BridgeAdapter: HostIntegrationAdapter {
    nonisolated let host: HostID
    nonisolated let capabilities: [HostCapabilityBinding]
    private var connected: Bool
    private var inspectCalls = 0
    private var connectCalls = 0
    private var disconnectCalls = 0
    private let failsConnect: Bool
    private let observesReceipt: Bool

    init(
        host: HostID,
        connected: Bool = false,
        failsConnect: Bool = false,
        observesReceipt: Bool = true
    ) {
        self.host = host
        self.capabilities = HostCapabilityCatalog.bindings(for: host)
        self.connected = connected
        self.failsConnect = failsConnect
        self.observesReceipt = observesReceipt
    }

    func inspect(runtime: SharedRuntimeHealth) async -> HostIntegrationSnapshot {
        inspectCalls += 1
        return snapshot(runtime: runtime)
    }

    func connect(
        runtime: SharedRuntimeHealth
    ) async -> Result<HostIntegrationSnapshot, HostIntegrationActionError> {
        connectCalls += 1
        if failsConnect {
            return .failure(.configuration(reason: "fixture 拒绝连接"))
        }
        connected = true
        return .success(snapshot(runtime: runtime))
    }

    func disconnect(
        runtime: SharedRuntimeHealth
    ) async -> Result<HostIntegrationSnapshot, HostIntegrationActionError> {
        disconnectCalls += 1
        connected = false
        return .success(snapshot(runtime: runtime))
    }

    func counts() -> (inspect: Int, connect: Int, disconnect: Int) {
        (inspectCalls, connectCalls, disconnectCalls)
    }

    private func snapshot(runtime: SharedRuntimeHealth) -> HostIntegrationSnapshot {
        guard connected else {
            return HostIntegrationSnapshot(
                host: host,
                runtime: runtime,
                availability: .available,
                configuration: .notConfigured,
                writability: .writable,
                activation: .none)
        }
        let installationID = UUID(uuidString: "00000000-0000-4000-8000-0000000000B1")!
        let binding = capabilities.first(where: { $0.isAudibleCapability })!
        let activation: HostActivationEvidence = observesReceipt
            ? .observed(
                HostReceiptEvidence(
                    installationID: installationID,
                    nativeEvent: binding.nativeEvent!,
                    event: binding.event,
                    timestamp: Date(timeIntervalSince1970: 123),
                    playbackResult: .played))
            : .awaitingReceipt(installationID: installationID)
        return HostIntegrationSnapshot(
            host: host,
            runtime: runtime,
            availability: .available,
            configuration: .configured,
            writability: .writable,
            activation: activation,
            installationID: installationID)
    }
}

private func bridgeFixture(
    root: URL,
    initiallyConnected: Bool = false,
    claudeFailsConnect: Bool = false,
    codexObservesReceipt: Bool = true
) -> (
    bridge: HostIntegrationManagerBridge,
    bootstrapper: BridgeBootstrapper,
    claude: BridgeAdapter,
    codex: BridgeAdapter,
    configFile: URL,
    packDirectory: URL
) {
    let packs = root.appendingPathComponent("packs", isDirectory: true)
    let pack = packs.appendingPathComponent("dual", isDirectory: true)
    let config = root.appendingPathComponent("config.json")
    let bootstrapper = BridgeBootstrapper()
    let claude = BridgeAdapter(
        host: .claudeCode,
        connected: initiallyConnected,
        failsConnect: claudeFailsConnect)
    let codex = BridgeAdapter(
        host: .codex,
        connected: initiallyConnected,
        observesReceipt: codexObservesReceipt)
    let manager = HostIntegrationManager(
        adapters: [claude, codex],
        bootstrapper: bootstrapper)
    let audioEnvironment = AudioImportEnvironment(
        userPacksDirectory: packs,
        durationProbe: StubDurationProbe(fixedDuration: 0.1),
        packsLockFile: root.appendingPathComponent("packs.lock"))
    let bridge = HostIntegrationManagerBridge(
        manager: manager,
        configFile: config,
        audioEnvironment: audioEnvironment)
    return (bridge, bootstrapper, claude, codex, config, pack)
}

@MainActor
func runHostIntegrationManagerBridgeSuites() async {
    await suite("HostIntegrationManagerBridge 首启：只 bootstrap 共享 runtime + inspect，绝不自动连接宿主") {
        await withTempDirectory { root in
            let fixture = bridgeFixture(root: root)
            let state = await fixture.bridge.bootstrapSharedRuntime()
            let bootstrapCounts = fixture.bootstrapper.counts()
            let claudeCounts = await fixture.claude.counts()
            let codexCounts = await fixture.codex.counts()

            expect(bootstrapCounts.bootstrap == 1, "首启必须恰好调用一次共享 bootstrap")
            expect(bootstrapCounts.inspect >= 2, "manager 初始化与 bootstrap 后必须探测 runtime")
            expect(claudeCounts.connect == 0, "首启不得自动 connect Claude Code")
            expect(codexCounts.connect == 0, "首启不得自动 connect Codex")
            expect(claudeCounts.inspect == 1, "首启必须 inspect Claude Code")
            expect(codexCounts.inspect == 1, "首启必须 inspect Codex")
            expect(
                state.snapshots.map(\.host) == HostID.allCases,
                "首启状态必须同代返回两条宿主快照")
            expect(
                hostSourceRowPresentations(from: state.matrix).map(\.host) == HostID.allCases,
                "首启矩阵不得隐藏任一宿主")
        }
    }

    await suite("HostIntegrationManagerBridge 动作：connect/repair/disconnect 只写目标 adapter，repair 复用 connect") {
        await withTempDirectory { root in
            let fixture = bridgeFixture(root: root)
            _ = await fixture.bridge.refresh()

            _ = try? await fixture.bridge.perform(.connect(.claudeCode))
            var claudeCounts = await fixture.claude.counts()
            var codexCounts = await fixture.codex.counts()
            expect(claudeCounts.connect == 1, "connect Claude Code 必须只调用 Claude adapter")
            expect(codexCounts.connect == 0, "connect Claude Code 不得写 Codex")

            let repair = try? await fixture.bridge.perform(.repair(.codex))
            claudeCounts = await fixture.claude.counts()
            codexCounts = await fixture.codex.counts()
            expect(claudeCounts.connect == 1, "repair Codex 不得再次 connect Claude Code")
            expect(codexCounts.connect == 1, "repair 必须复用目标 adapter 的 connect")
            expect(
                repair?.feedbackMessage == "Codex 已连接，当前代次已收到真实回执",
                "刷新后已有当前代次回执时，反馈不得还说等待确认")

            let disconnected = try? await fixture.bridge.perform(.disconnect(.claudeCode))
            claudeCounts = await fixture.claude.counts()
            codexCounts = await fixture.codex.counts()
            expect(claudeCounts.disconnect == 1, "disconnect 必须调用目标 Claude adapter")
            expect(codexCounts.disconnect == 0, "disconnect Claude Code 不得写 Codex")
            expect(
                disconnected?.state.snapshots.first(where: { $0.host == .codex })?
                    .configuration == .configured,
                "断开一侧后刷新不得清空另一侧状态")
        }
    }

    await suite("HostIntegrationManagerBridge Codex 待确认：只在无当前代次回执时显示固定文案") {
        await withTempDirectory { root in
            let fixture = bridgeFixture(root: root, codexObservesReceipt: false)
            let outcome = try? await fixture.bridge.perform(.connect(.codex))
            expect(
                outcome?.feedbackMessage == "Claudio 已写好，等待 Codex 确认",
                "Codex 配置完成但没有真实回执时，必须保留固定待确认文案")
            expect(
                outcome?.state.snapshots.first(where: { $0.host == .codex })?.activation
                    == .awaitingReceipt(
                        installationID: UUID(
                            uuidString: "00000000-0000-4000-8000-0000000000B1")!),
                "反馈必须与同一份 awaiting snapshot 一致")
        }
    }

    await suite("HostIntegrationManagerBridge 动作失败：仍返回双宿主新状态与 failure 反馈，不冻结另一侧") {
        await withTempDirectory { root in
            let fixture = bridgeFixture(root: root, claudeFailsConnect: true)
            _ = await fixture.bridge.refresh()
            let codexBefore = await fixture.codex.counts().inspect

            let outcome = try? await fixture.bridge.perform(.connect(.claudeCode))
            let codexAfter = await fixture.codex.counts().inspect

            expect(outcome?.feedbackKind == .failure, "adapter 失败必须成为可见 failure outcome")
            expect(
                outcome?.feedbackMessage.contains("fixture 拒绝连接") == true,
                "失败反馈必须保留 manager 的具体原因")
            expect(
                outcome?.state.snapshots.map(\.host) == HostID.allCases,
                "单侧失败仍必须同代返回两条宿主快照")
            expect(
                codexAfter > codexBefore,
                "Claude 连接失败后仍必须刷新 Codex，不能把另一侧冻结在旧状态")
        }
    }

    await suite("HostIntegrationManagerBridge 矩阵：真实 config + manifest 依次投影 audible、muted、missingSound") {
        await withTempDirectory { root in
            let fixture = bridgeFixture(root: root, initiallyConnected: true)
            writeFixture(
                #"{"selected_pack":"dual","events":{"notification":true}}"#,
                to: fixture.configFile)
            writeFixture(
                #"{"id":"dual","events":{"stop":"stop.mp3","stop_failure":"failure.mp3","notification":"notification.mp3","subagent_stop":"subagent.mp3"}}"#,
                to: fixture.packDirectory.appendingPathComponent("manifest.json"))
            for file in ["stop.mp3", "failure.mp3", "notification.mp3", "subagent.mp3"] {
                writeFixture(Data([0x01]), to: fixture.packDirectory.appendingPathComponent(file))
            }

            var state = await fixture.bridge.refresh()
            expect(
                state.matrix.cell(host: .codex, event: .notification)?.state == .audible,
                "当前包真实存在且事件启用时，Codex PermissionRequest 必须是 audible")

            writeFixture(
                #"{"selected_pack":"dual","events":{"notification":false}}"#,
                to: fixture.configFile)
            state = await fixture.bridge.refresh()
            expect(
                state.matrix.cell(host: .claudeCode, event: .notification)?.state == .muted
                    && state.matrix.cell(host: .codex, event: .notification)?.state == .muted,
                "静音配置变化必须同时进入两个宿主的同一语义格")

            writeFixture(
                #"{"selected_pack":"dual","events":{"notification":true}}"#,
                to: fixture.configFile)
            try? FileManager.default.removeItem(
                at: fixture.packDirectory.appendingPathComponent("notification.mp3"))
            state = await fixture.bridge.refresh()
            expect(
                state.matrix.cell(host: .claudeCode, event: .notification)?.state
                    == .missingSound
                    && state.matrix.cell(host: .codex, event: .notification)?.state
                        == .missingSound,
                "manifest 声明文件消失后必须投影 missingSound，不得沿用 all-false 占位矩阵")

            writeFixture(
                #"{"selected_pack":"dual","master_volume":0,"events":{"notification":true}}"#,
                to: fixture.configFile)
            state = await fixture.bridge.refresh()
            expect(
                state.matrix.cell(host: .claudeCode, event: .stop)?.state == .muted
                    && state.matrix.cell(host: .codex, event: .stop)?.state == .muted,
                "master_volume == 0 必须把所有 supported 格投影为 muted")
            expect(
                state.matrix.cell(host: .codex, event: .stopFailure)?.state == .unsupported,
                "全局静音不得把 Codex 不支持的 StopFailure 误画成 muted")
        }
    }
}
