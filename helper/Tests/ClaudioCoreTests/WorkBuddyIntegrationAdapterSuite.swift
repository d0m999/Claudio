import ClaudioCore
import Foundation

@MainActor
func runWorkBuddyIntegrationAdapterSuites() async {
    await asyncSuite("WorkBuddy adapter：两事件连接、逐 binding 回执与断开边界") {
        await withWorkBuddyAsyncTempDirectory { root in
            let claudioRoot = root.appendingPathComponent(".claudio", isDirectory: true)
            let settings = root.appendingPathComponent(".workbuddy/settings.json")
            let config = claudioRoot.appendingPathComponent("config.json")
            let receiptStore = HostHookReceiptStore(
                receiptsRoot: claudioRoot.appendingPathComponent("integrations/receipts"),
                locksRoot: claudioRoot.appendingPathComponent("integrations/receipt-locks"))
            writeFixture(
                #"{"enabledPlugins":{"keep":true},"hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo third"}]}]}}"#,
                to: settings)
            writeFixture(
                #"{"selected_pack":"global","surface_overrides":{"workbuddy":{"events":{"stop":false}}}}"#,
                to: config)
            let configBefore = try! Data(contentsOf: config)
            let adapter = WorkBuddyIntegrationAdapter(
                environment: WorkBuddyIntegrationEnvironment(
                    settingsFile: settings,
                    lockFile: root.appendingPathComponent("workbuddy.lock"),
                    claudioBinaryPath: claudioRoot.appendingPathComponent("bin/claudio").path,
                    claudioRoot: claudioRoot.path,
                    receiptStore: receiptStore,
                    scopeFingerprint: { "app=5.3.14;runtime=test;bindings=v1" },
                    availability: { .available }))

            guard case .success(let connected) = await adapter.connect(runtime: .ready),
                let installationID = connected.installationID
            else {
                expect(false, "WorkBuddy 合法 fixture 必须连接成功")
                return
            }
            expect(connected.configuration == .configured, "写入后必须完整配置")
            expect(
                connected.activation == .awaitingReceipt(installationID: installationID),
                "没有真实 task_start 前不得点亮宿主")
            expect(try! Data(contentsOf: config) == configBefore, "连接不得创建或修改声音覆盖")
            let object =
                try! JSONSerialization.jsonObject(
                    with: Data(contentsOf: settings)) as! [String: Any]
            let hooks = object["hooks"] as! [String: Any]
            expect(Set(hooks.keys) == ["UserPromptSubmit", "Stop"], "首发只能管理两种原生事件")
            expect(
                (object["enabledPlugins"] as? [String: Any])?["keep"] as? Bool == true, "未知配置必须保留")

            let stopBinding = HostCapabilityCatalog.binding(host: .workBuddy, nativeEvent: "Stop")!
            let stopReceipt = HostHookReceipt(
                installationID: installationID,
                host: .workBuddy,
                nativeEvent: "Stop",
                semanticEvent: .stop,
                timestamp: Date(timeIntervalSince1970: 42),
                playbackResult: .muted)
            expect(receiptStore.store(stopReceipt) == .success(.written), "Stop 真实回执必须可写")
            let stopObserved = await adapter.inspect(runtime: .ready)
            guard case .observed(let evidence) = stopObserved.activation(for: stopBinding) else {
                expect(false, "Stop binding 必须由自己的真实回执点亮")
                return
            }
            expect(evidence.bindingID == stopBinding.id, "回执必须绑定稳定 binding ID")
            expect(
                stopObserved.activation == .awaitingReceipt(installationID: installationID),
                "Stop 回执不能冒充 task_start 宿主激活证据")

            guard case .success(let disconnected) = await adapter.disconnect(runtime: .ready) else {
                expect(false, "WorkBuddy 断开必须成功")
                return
            }
            expect(disconnected.configuration == .notConfigured, "断开后必须未配置")
            expect(receiptStore.currentInstallationID(host: .workBuddy) == nil, "断开必须撤销当前代次")
            expect(try! Data(contentsOf: config) == configBefore, "断开必须保留 surface 声音偏好")
        }
    }

    await asyncSuite("WorkBuddy adapter：版本身份变化让旧回执失败关闭，显式 repair 恢复") {
        await withWorkBuddyAsyncTempDirectory { root in
            let claudioRoot = root.appendingPathComponent(".claudio", isDirectory: true)
            let settings = root.appendingPathComponent(".workbuddy/settings.json")
            writeFixture("{}", to: settings)
            let store = HostHookReceiptStore(
                receiptsRoot: claudioRoot.appendingPathComponent("integrations/receipts"),
                locksRoot: claudioRoot.appendingPathComponent("integrations/receipt-locks"))
            let scope = MutableScopeFingerprint("scope-v1")
            let adapter = WorkBuddyIntegrationAdapter(
                environment: WorkBuddyIntegrationEnvironment(
                    settingsFile: settings,
                    lockFile: root.appendingPathComponent("workbuddy.lock"),
                    claudioBinaryPath: claudioRoot.appendingPathComponent("bin/claudio").path,
                    claudioRoot: claudioRoot.path,
                    receiptStore: store,
                    scopeFingerprint: { scope.value },
                    availability: { .available }))
            guard case .success(let initial) = await adapter.connect(runtime: .ready),
                let initialID = initial.installationID
            else {
                expect(false, "测试前提：v1 scope 必须连接")
                return
            }
            scope.value = "scope-v2"
            let invalidated = await adapter.inspect(runtime: .ready)
            guard case .conflict(let reason) = invalidated.configuration else {
                expect(false, "版本变化必须使旧连接进入 conflict")
                return
            }
            expect(reason.contains("版本已变化") && reason.contains("旧回执已失效"), "必须给出 repair 原因")
            guard case .success(let repaired) = await adapter.connect(runtime: .ready) else {
                expect(false, "显式 connect/repair 必须发布新 scope")
                return
            }
            expect(repaired.configuration == .configured, "repair 后必须恢复 configured")
            expect(repaired.installationID != initialID, "scope 失配 repair 必须轮换 installation ID")
            expect(
                store.currentInstallationScopeFingerprint(host: .workBuddy) == "scope-v2",
                "新版本 scope 必须原子发布")
        }
    }
}

@MainActor
private func withWorkBuddyAsyncTempDirectory(
    _ body: @MainActor (URL) async -> Void
) async {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "claudio-workbuddy-tests-\(UUID().uuidString)",
        isDirectory: true)
    try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    await body(root)
}

private final class MutableScopeFingerprint: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String

    init(_ value: String) { stored = value }

    var value: String {
        get {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
        set {
            lock.lock()
            stored = newValue
            lock.unlock()
        }
    }
}
