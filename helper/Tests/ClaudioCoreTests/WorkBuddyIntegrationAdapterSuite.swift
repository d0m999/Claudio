import ClaudioCore
import Foundation

@MainActor
func runWorkBuddyIntegrationAdapterSuites() async {
    await asyncSuite("WorkBuddy adapter：四事件连接、逐 binding 回执与断开边界") {
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
            expect(
                Set(hooks.keys) == ["UserPromptSubmit", "Stop", "SubagentStop", "Notification"],
                "只能管理四种已验证的原生事件")
            expect(
                (object["enabledPlugins"] as? [String: Any])?["keep"] as? Bool == true, "未知配置必须保留")
            let connectedBytes = try! Data(contentsOf: settings)
            _ = await adapter.connect(runtime: .ready)
            expect(
                try! Data(contentsOf: settings) == connectedBytes,
                "完整四绑定重连必须逐字节幂等")
            let notification = HostCapabilityCatalog.binding(
                host: .workBuddy, nativeEvent: "Notification")!
            expect(
                connected.activation(for: notification)
                    == .awaitingReceipt(installationID: installationID),
                "两条 matcher 只形成一个待回执 Notification binding")

            let stopBinding = HostCapabilityCatalog.binding(host: .workBuddy, nativeEvent: "Stop")!
            let stopReceipt = HostHookReceipt(
                installationID: installationID,
                host: .workBuddy,
                nativeEvent: "Stop",
                semanticEvent: .stop,
                timestamp: Date(timeIntervalSince1970: 42),
                playbackResult: .muted)
            expect(
                receiptStore.store(
                    stopReceipt, scopeFingerprint: adapter.environment.scopeFingerprint)
                    == .success(.written), "Stop 真实回执必须可写")
            let stopObserved = await adapter.inspect(runtime: .ready)
            guard case .observed(let evidence) = stopObserved.activation(for: stopBinding) else {
                expect(false, "Stop binding 必须由自己的真实回执点亮")
                return
            }
            expect(evidence.bindingID == stopBinding.id, "回执必须绑定稳定 binding ID")
            expect(
                stopObserved.activation == .awaitingReceipt(installationID: installationID),
                "Stop 回执不能冒充 task_start 宿主激活证据")
            let notificationReceipt = HostHookReceipt(
                installationID: installationID,
                host: .workBuddy, nativeEvent: "Notification", semanticEvent: .notification,
                timestamp: Date(timeIntervalSince1970: 43), playbackResult: .played)
            expect(
                receiptStore.store(
                    notificationReceipt, scopeFingerprint: adapter.environment.scopeFingerprint)
                    == .success(.written), "Notification 当前回执应可写")
            let notificationObserved = await adapter.inspect(runtime: .ready)
            if case .observed(let evidence) = notificationObserved.activation(for: notification) {
                expect(evidence.bindingID == notification.id, "Notification 回执只激活自己")
            } else {
                expect(false, "Notification 回执必须出现在 adapter snapshot")
            }
            expect(
                notificationObserved.activation == .awaitingReceipt(installationID: installationID),
                "Notification 回执不冒充宿主 task_start ready")

            guard case .success(let disconnected) = await adapter.disconnect(runtime: .ready) else {
                expect(false, "WorkBuddy 断开必须成功")
                return
            }
            expect(disconnected.configuration == .notConfigured, "断开后必须未配置")
            expect(receiptStore.currentInstallationID(host: .workBuddy) == nil, "断开必须撤销当前代次")
            expect(try! Data(contentsOf: config) == configBefore, "断开必须保留 surface 声音偏好")
        }
    }

    await asyncSuite("WorkBuddy adapter：三绑定旧 scope 升级为四绑定时必须轮换代次") {
        await withWorkBuddyAsyncTempDirectory { root in
            let claudio = root.appendingPathComponent("claudio")
            let settings = root.appendingPathComponent("settings.json")
            let store = HostHookReceiptStore(
                receiptsRoot: root.appendingPathComponent("receipts"),
                locksRoot: root.appendingPathComponent("locks"))
            let scope = HostActivationScope.fingerprint(host: .workBuddy, hostVersion: "app=5.6.2")!
            let notificationID = HostCapabilityCatalog.binding(
                host: .workBuddy, nativeEvent: "Notification")!.id.rawValue
            let oldScope = scope.replacingOccurrences(of: notificationID + ",", with: "")
            expect(oldScope != scope, "四绑定 scope 必须包含 Notification binding 身份")
            let oldID = UUID()
            var oldRoot = try! connectWorkBuddyHooks(
                root: [:], claudioRoot: claudio.path,
                claudioBinaryPath: claudio.appendingPathComponent("bin/claudio").path,
                installationID: oldID
            ).get().root
            var oldHooks = oldRoot["hooks"] as! [String: Any]
            oldHooks.removeValue(forKey: "Notification")
            oldRoot["hooks"] = oldHooks
            try! JSONSerialization.data(withJSONObject: oldRoot).write(to: settings)
            _ = store.activate(host: .workBuddy, installationID: oldID, scopeFingerprint: oldScope)
            let adapter = WorkBuddyIntegrationAdapter(
                environment: WorkBuddyIntegrationEnvironment(
                    settingsFile: settings, lockFile: root.appendingPathComponent("config.lock"),
                    claudioBinaryPath: claudio.appendingPathComponent("bin/claudio").path,
                    claudioRoot: claudio.path, receiptStore: store,
                    scopeFingerprint: { scope }, availability: { .available }))
            let before = await adapter.inspect(runtime: .ready)
            expect(
                before.configuration == .incomplete(missingNativeEvents: ["Notification"]),
                "旧三绑定配置应显示 Notification 缺失")
            let upgraded = try! await adapter.connect(runtime: .ready).get()
            expect(
                upgraded.configuration == .configured && upgraded.installationID != oldID,
                "升级通过现有 Repair 路径发布完整四绑定与新代次")
            expect(
                store.currentInstallationScopeFingerprint(host: .workBuddy) == scope,
                "激活 marker 必须绑定四绑定完整 scope")
            let stale = HostHookReceipt(
                installationID: oldID, host: .workBuddy,
                nativeEvent: "Stop", semanticEvent: .stop, timestamp: Date(),
                playbackResult: .played)
            expect(
                store.store(stale, scopeFingerprint: { scope }) == .failure(.staleInstallation),
                "升级后旧代次回执必须被拒绝")
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
