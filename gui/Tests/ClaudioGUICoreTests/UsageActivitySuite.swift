import ClaudioCore
import ClaudioGUICore
import Foundation

@MainActor
func runUsageActivitySuites() async {
    suite("Usage projector：每个 Surface 只投影 20 条 / 30 天并按公共 Event 与结果分组") {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let installationID = UUID(uuidString: "10101010-1010-4010-8010-101010101010")!
        var receipts: [HostHookReceipt] = []
        for index in 0..<25 {
            let result: HostHookPlaybackResult =
                switch index {
                case 1: .notReady
                case 2: .unsupportedEvent
                case 3: .playbackFailed
                default: index.isMultiple(of: 3) ? .muted : .played
                }
            receipts.append(
                HostHookReceipt(
                    installationID: installationID,
                    host: .workBuddy,
                    nativeEvent: index.isMultiple(of: 2) ? "UserPromptSubmit" : "Stop",
                    semanticEvent: index.isMultiple(of: 2) ? .taskStart : .stop,
                    timestamp: now.addingTimeInterval(-Double(index)),
                    playbackResult: result))
        }
        receipts.append(
            HostHookReceipt(
                installationID: installationID,
                host: .workBuddy,
                nativeEvent: "Stop",
                semanticEvent: .stop,
                timestamp: now.addingTimeInterval(-31 * 24 * 60 * 60),
                playbackResult: .playbackFailed))
        receipts.append(
            HostHookReceipt(
                installationID: installationID,
                host: .workBuddy,
                nativeEvent: "Stop",
                semanticEvent: .stop,
                timestamp: now.addingTimeInterval(1),
                playbackResult: .debounced))

        let presentation = UsageActivityProjector.project(
            historySources: [
                UsageHistorySourceSnapshot(
                    host: .workBuddy,
                    receipts: receipts,
                    state: .available)
            ],
            log: UsageDiagnosticLogSnapshot(
                path: "/tmp/claudio.log",
                state: .missing,
                failures: []),
            now: now)
        let workBuddy = presentation.surfaces.first { $0.host == .workBuddy }
        expect(
            presentation.surfaces.map(\.host) == HostID.productVisibleCases,
            "projector 必须只按产品可见 Host Surface 的稳定顺序输出")
        expect(
            workBuddy?.retainedCount == HostHookReceiptStore.historyLimitPerSurface,
            "单 Surface 最多只能投影 20 条，不得把过期/未来回执算入")
        expect(
            workBuddy?.events.map(\.event) == [.taskStart, .stop],
            "回执必须按公共 Event 分组并保持公共事件顺序")
        let projectedCount = workBuddy?.events.flatMap(\.resultCounts).map(\.count).reduce(0, +)
        expect(projectedCount == 20, "每种结果计数之和必须等于实际保留回执数")
        let failedCount = workBuddy?.events
            .flatMap(\.resultCounts)
            .filter { $0.result == .failed }
            .reduce(0) { $0 + $1.count }
        expect(
            failedCount == 3,
            "not ready / unsupported / playback failed 必须收敛为唯一 fail 计数，30 天外失败不得混入")
    }

    suite("Usage store：损坏历史与日志只留下可见状态，原始敏感 reason 不进入投影") {
        withTempDirectory { root in
            let now = Date()
            let receiptStore = makeUsageReceiptStore(root: root)
            let history = receiptStore.historyRoot.appendingPathComponent(
                HostSurfaceID.workBuddy.rawValue,
                isDirectory: true)
            writeFixture("{broken receipt", to: history.appendingPathComponent("broken.json"))
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: receiptStore.historyRoot.path)
            let log = root.appendingPathComponent("claudio.log")
            let lock = root.appendingPathComponent("claudio.log.lock")
            writeFixture("not a valid line\n", to: log)
            expect(
                appendLogLine(
                    event: "stop",
                    reason:
                        "Authorization Bearer top-secret /Users/private/audio.wav prompt response",
                    timestamp: now,
                    to: log,
                    lockFile: lock),
                "测试前提：含敏感原始 reason 的日志行必须先成功写入")
            let store = UsageActivityStore(
                receiptStore: receiptStore,
                logFile: log,
                logLockFile: lock,
                historyManagementLockFile: root.appendingPathComponent("history.lock"))
            let presentation = store.load(now: now)
            let reflected = String(reflecting: presentation)

            expect(
                presentation.surfaces.first { $0.host == .workBuddy }?.sourceState
                    == .damaged(skippedItemCount: 1),
                "损坏 receipt 必须可见但不得被提升成活动")
            expect(
                presentation.log.state
                    == .damaged(
                        sizeBytes: (try? Data(contentsOf: log).count) ?? 0, skippedLineCount: 1)
                    && presentation.log.failures.map(\.category) == [.other],
                "日志只可显示存在/大小、损坏行数与有限脱敏分类")
            for forbidden in [
                "top-secret", "Authorization", "/Users/private/audio.wav", "prompt", "response",
            ] {
                expect(
                    !reflected.contains(forbidden),
                    "Usage presentation 不得携带敏感原始字段：\(forbidden)")
            }
        }
    }

    suite("Usage provider disclosure：四个 allowlisted profile 分别归属 Provider 与 region") {
        let profiles = AICueProviderRegistry().profiles()
        let disclosures = UsageProviderDisclosure.allowlisted
        expect(
            disclosures.map(\.profileID) == profiles.map(\.id)
                && disclosures.map(\.displayNameKey) == profiles.map(\.displayNameKey)
                && disclosures.map(\.regionID) == profiles.map(\.regionID),
            "逐 Provider 披露必须直接投影 registry 的 typed profile、名称与 region")
        expect(
            disclosures.count == 4
                && disclosures.compactMap(\.regionID) == ["singapore", "beijing"],
            "accepted registry 必须分别保留四个 profile，Singapore/Beijing 不得互相归因")
        expect(
            Set(disclosures.map(\.profileID)).count == disclosures.count,
            "每个披露 profile 必须拥有独立稳定身份")
    }

    suite("Usage 清理：历史与日志副作用隔离，连接/稳定回执/配置/Provider/credential 不变") {
        withTempDirectory { root in
            let receiptStore = makeUsageReceiptStore(root: root)
            let installationID = UUID(uuidString: "20202020-2020-4020-8020-202020202020")!
            let scope = "usage-fixture-scope"
            let receipt = HostHookReceipt(
                installationID: installationID,
                host: .workBuddy,
                nativeEvent: "UserPromptSubmit",
                semanticEvent: .taskStart,
                timestamp: Date(),
                playbackResult: .played)
            expect(
                resultSucceeded(
                    receiptStore.activate(
                        host: .workBuddy,
                        installationID: installationID,
                        scopeFingerprint: scope)),
                "测试前提：当前连接 marker 必须写入")
            expect(receiptStore.store(receipt) == .success(.written), "测试前提：稳定回执与历史必须写入")

            let log = root.appendingPathComponent("claudio.log")
            let logLock = root.appendingPathComponent("claudio.log.lock")
            expect(
                appendLogLine(
                    event: "task_start", reason: "afplay 启动失败：fixed", to: log, lockFile: logLock),
                "测试前提：日志必须写入")
            let config = root.appendingPathComponent("config.json")
            let providerPreference = root.appendingPathComponent("provider-profile.preference")
            let keychainSentinel = root.appendingPathComponent("keychain-credential.sentinel")
            writeFixture("config-stable", to: config)
            writeFixture("qwen-singapore", to: providerPreference)
            writeFixture("credential-stable", to: keychainSentinel)
            let store = UsageActivityStore(
                receiptStore: receiptStore,
                logFile: log,
                logLockFile: logLock,
                historyManagementLockFile: root.appendingPathComponent("history.lock"))

            expect(resultSucceeded(store.clearHistory()), "历史清理必须成功")
            expect(receiptStore.receiptHistory(host: .workBuddy).isEmpty, "历史清理只删除保留历史")
            expect(
                receiptStore.currentInstallationID(host: .workBuddy) == installationID
                    && receiptStore.receiptEvidence(
                        host: .workBuddy,
                        nativeEvent: "UserPromptSubmit",
                        installationID: installationID,
                        scopeFingerprint: scope) != nil,
                "历史清理不得修改连接 marker、Current Activation 或当前稳定回执")
            expect(FileManager.default.fileExists(atPath: log.path), "历史清理不得删除诊断日志")
            expect(
                fixtureText(config) == "config-stable"
                    && fixtureText(providerPreference) == "qwen-singapore"
                    && fixtureText(keychainSentinel) == "credential-stable",
                "历史清理不得触碰声音配置、Provider profile 偏好或 credential")

            expect(receiptStore.store(receipt) == .success(.written), "日志清理前必须重建一条历史")
            expect(resultSucceeded(store.clearLog()), "日志清理必须成功")
            expect(!FileManager.default.fileExists(atPath: log.path), "日志清理只删除日志路径")
            expect(
                receiptStore.receiptHistory(host: .workBuddy).count == 1
                    && receiptStore.currentInstallationID(host: .workBuddy) == installationID,
                "日志清理不得删除历史或连接事实")
            expect(
                fixtureText(config) == "config-stable"
                    && fixtureText(providerPreference) == "qwen-singapore"
                    && fixtureText(keychainSentinel) == "credential-stable",
                "日志清理不得触碰配置、Provider profile 偏好或 credential")
        }
    }

    suite("Usage 清理：历史/日志锁彼此独立且 busy 时不运行对应删除") {
        withTempDirectory { root in
            let receiptStore = makeUsageReceiptStore(root: root)
            let historyLockURL = root.appendingPathComponent("history.lock")
            let log = root.appendingPathComponent("claudio.log")
            let logLockURL = root.appendingPathComponent("claudio.log.lock")
            let store = UsageActivityStore(
                receiptStore: receiptStore,
                logFile: log,
                logLockFile: logLockURL,
                historyManagementLockFile: historyLockURL)

            writeFixture("log-one", to: log)
            let historyLock = FileLock(path: historyLockURL.path)
            expect(historyLock.attemptLock() == .acquired, "测试前提：历史管理锁必须被占用")
            expect(
                resultFailure(store.clearHistory()) == .historyLockBusy,
                "历史锁忙必须可见且不阻塞")
            expect(resultSucceeded(store.clearLog()), "历史锁忙不得阻塞独立日志清理")
            historyLock.unlock()

            let installationLock = FileLock(
                path: receiptStore.installationLockFile(host: .claudeCode).path)
            expect(
                installationLock.attemptLock() == .acquired,
                "测试前提：真实 receipt installation lock 必须被占用")
            expect(
                resultFailure(store.clearHistory()) == .historyLockBusy,
                "内层 receipt installation lock 争用也必须投影为可见的历史锁忙")
            installationLock.unlock()

            writeFixture("log-two", to: log)
            let logLock = FileLock(path: logLockURL.path)
            expect(logLock.attemptLock() == .acquired, "测试前提：日志锁必须被占用")
            expect(
                resultFailure(store.clearLog()) == .logLockBusy,
                "日志锁忙必须可见且不删除日志")
            expect(resultSucceeded(store.clearHistory()), "日志锁忙不得阻塞独立历史清理")
            expect(fixtureText(log) == "log-two", "日志 busy 失败必须保留原文件事实")
            logLock.unlock()
        }
    }

    await suite("Usage model：清理失败保留旧可见事实，Finder/clipboard 失败分别呈现") {
        let original = UsageActivityPresentation(
            surfaces: [
                UsageSurfaceActivity(
                    host: .workBuddy,
                    retainedCount: 7,
                    events: [],
                    sourceState: .available)
            ],
            log: UsageDiagnosticLogSnapshot(
                path: "/tmp/missing.log",
                state: .missing,
                failures: []))
        let model = UsageSettingsModel(
            initialPresentation: original,
            operations: UsageSettingsOperations(
                load: { original },
                clearHistory: { .failure(.historyLockBusy) },
                clearLog: { .failure(.logClearFailed) },
                revealLog: { false },
                copyLogPath: { false }))

        model.clearHistory()
        for _ in 0..<4 { await Task.yield() }
        expect(
            model.presentation == original
                && model.feedback
                    == UsageSettingsFeedback(
                        action: .clearHistory,
                        failure: .historyLockBusy),
            "历史清理失败不得清空或刷新旧可见事实")
        model.clearLog()
        for _ in 0..<4 { await Task.yield() }
        expect(
            model.presentation == original
                && model.feedback
                    == UsageSettingsFeedback(action: .clearLog, failure: .logClearFailed),
            "日志清理失败不得清空或刷新旧可见事实")
        model.revealLog()
        expect(
            model.feedback
                == UsageSettingsFeedback(action: .revealLog, failure: .finderFailed),
            "Finder reveal 失败必须独立可见")
        model.copyLogPath()
        expect(
            model.feedback
                == UsageSettingsFeedback(action: .copyLogPath, failure: .clipboardFailed),
            "clipboard 失败必须独立可见")
    }

    await suite("Usage model：可控延迟下 refresh 与两个清理由单一 owner 串行发布") {
        let original = UsageActivityPresentation.empty
        let refreshed = UsageActivityPresentation(
            surfaces: [
                UsageSurfaceActivity(
                    host: .workBuddy,
                    retainedCount: 3,
                    events: [],
                    sourceState: .available)
            ],
            log: UsageDiagnosticLogSnapshot(
                path: "/tmp/refreshed.log", state: .missing, failures: []))
        let refreshGate = UsageAsyncGate()
        var historyClearCalls = 0
        let refreshModel = UsageSettingsModel(
            initialPresentation: original,
            operations: UsageSettingsOperations(
                load: {
                    await refreshGate.wait()
                    return refreshed
                },
                clearHistory: {
                    historyClearCalls += 1
                    return .success(refreshed)
                },
                clearLog: { .success(refreshed) },
                revealLog: { true },
                copyLogPath: { true }))

        refreshModel.refresh()
        refreshModel.clearHistory()
        expect(
            refreshModel.isRefreshing
                && refreshModel.activeActions.isEmpty
                && historyClearCalls == 0
                && refreshModel.presentation == original,
            "延迟 refresh 在途时清理必须留在串行 owner 外，不能并发发布旧/新组合")
        await refreshGate.open()
        for _ in 0..<6 { await Task.yield() }
        expect(
            refreshModel.presentation == refreshed && !refreshModel.isOperationActive,
            "延迟 refresh 完成后只能发布自己的最新 revision")

        let clearGate = UsageAsyncGate()
        var refreshCalls = 0
        var logClearCalls = 0
        let cleared = UsageActivityPresentation(
            surfaces: [],
            log: UsageDiagnosticLogSnapshot(path: "/tmp/cleared.log", state: .missing, failures: [])
        )
        let clearModel = UsageSettingsModel(
            initialPresentation: original,
            operations: UsageSettingsOperations(
                load: {
                    refreshCalls += 1
                    return original
                },
                clearHistory: {
                    await clearGate.wait()
                    return .success(cleared)
                },
                clearLog: {
                    logClearCalls += 1
                    return .success(original)
                },
                revealLog: { true },
                copyLogPath: { true }))

        clearModel.clearHistory()
        clearModel.refresh()
        clearModel.clearLog()
        expect(
            clearModel.activeActions == [.clearHistory]
                && refreshCalls == 0
                && logClearCalls == 0
                && clearModel.presentation == original,
            "延迟清理在途时 refresh/另一清理必须被串行 owner 拒绝，不得回写旧快照")
        await clearGate.open()
        for _ in 0..<6 { await Task.yield() }
        expect(
            clearModel.presentation == cleared
                && clearModel.feedback
                    == UsageSettingsFeedback(action: .clearHistory, failure: nil)
                && !clearModel.isOperationActive,
            "清理完成后只能发布该 revision 的最终快照和反馈")
    }

    suite("Usage production wiring：真实目的页、双确认和安全 composition 已进入生产") {
        let root = guiTestRepositoryRoot()
        let view = try? String(
            contentsOf: root.appendingPathComponent(
                "gui/Sources/ClaudioGUI/UsageSettingsView.swift"),
            encoding: .utf8)
        let settings = try? String(
            contentsOf: root.appendingPathComponent(
                "gui/Sources/ClaudioGUI/SettingsWindowView.swift"),
            encoding: .utf8)
        let adapter = try? String(
            contentsOf: root.appendingPathComponent(
                "gui/Sources/ClaudioGUI/UsageActivityAdapter.swift"),
            encoding: .utf8)
        expect(
            view?.contains("confirmation = .history") == true
                && view?.contains("confirmation = .log") == true
                && view?.contains("settings.usage.clear-history") == true
                && view?.contains("settings.usage.clear-log") == true,
            "历史与日志必须有两个独立确认入口和稳定 AX 标识")
        expect(
            settings?.contains("else if destination == .usage") == true
                && settings?.contains("UsageSettingsView(") == true,
            "Usage destination 必须渲染 production 内容而非 debug route")
        expect(
            adapter?.contains("UsageActivityStore.production()") == true
                && adapter?.contains("AICueKeychainCredentialVault") == false,
            "production composition 只能注入 receipt/log owner，不得读取 Keychain")
    }
}

private func makeUsageReceiptStore(root: URL) -> HostHookReceiptStore {
    HostHookReceiptStore(
        receiptsRoot: root.appendingPathComponent("integrations/receipts", isDirectory: true),
        locksRoot: root.appendingPathComponent("integrations/receipt-locks", isDirectory: true),
        installationsRoot: root.appendingPathComponent(
            "integrations/installations", isDirectory: true),
        installationLocksRoot: root.appendingPathComponent(
            "integrations/installation-locks", isDirectory: true),
        historyRoot: root.appendingPathComponent(
            "integrations/receipt-history", isDirectory: true))
}

private func fixtureText(_ url: URL) -> String? {
    try? String(contentsOf: url, encoding: .utf8)
}

private func resultSucceeded<Failure>(_ result: Result<Void, Failure>) -> Bool {
    if case .success = result { return true }
    return false
}

private func resultFailure<Failure>(_ result: Result<Void, Failure>) -> Failure? {
    if case .failure(let failure) = result { return failure }
    return nil
}

private actor UsageAsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}
