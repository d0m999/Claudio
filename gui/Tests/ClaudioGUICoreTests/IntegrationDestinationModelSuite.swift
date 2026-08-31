import ClaudioCore
import ClaudioGUICore
import ClaudioLocalization
import Foundation

@MainActor
func runIntegrationDestinationModelSuites() async {
    suite("集成 destination 偏好：missing、valid、unknown、AX 与 generic 恢复") {
        let suiteName = "IntegrationDestinationModelSuite.preferences.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let missing = ClaudioPreferences(
            defaults: defaults,
            notificationCenter: NotificationCenter(),
            preferredLanguageIdentifiers: { ["zh-Hans"] })
        expect(
            missing.lastIntegrationSurface == .claudeCode
                && !missing.recoveryIssues.contains(.invalidIntegrationSurface),
            "缺失集成 Surface 偏好必须默认 Claude Code 且不产生恢复错误")

        defaults.set(HostSurfaceID.codex.rawValue, forKey: ClaudioPreferences.integrationSurfaceDefaultsKey)
        let valid = ClaudioPreferences(
            defaults: defaults,
            notificationCenter: NotificationCenter(),
            preferredLanguageIdentifiers: { ["zh-Hans"] })
        expect(valid.lastIntegrationSurface == .codex, "合法 Surface 必须恢复 Codex")
        let validModel = IntegrationDestinationModel(
            content: integrationDestinationTestContent(),
            refreshHandler: IntegrationDestinationRefreshHandler {
                integrationDestinationTestOutcome(content: integrationDestinationTestContent())
            },
            actionHandler: IntegrationDestinationActionHandler { _ in
                integrationDestinationTestOutcome(content: integrationDestinationTestContent())
            },
            preferences: valid)
        expect(validModel.selectedHost == .codex, "generic destination 必须恢复最后选择的 Codex")
        expect(validModel.selectHost(.workBuddy), "产品 Surface deep link 选择必须成功")
        expect(valid.lastIntegrationSurface == .workBuddy, "选择 Agent 必须持久化对应 Surface")
        expect(!validModel.selectHost(.chatGPTDesktopAX), "AX-only Surface deep link 必须拒绝")
        expect(valid.lastIntegrationSurface == .workBuddy, "拒绝 AX deep link 不得改写偏好")

        defaults.set("unknown-surface", forKey: ClaudioPreferences.integrationSurfaceDefaultsKey)
        let unknown = ClaudioPreferences(
            defaults: defaults,
            notificationCenter: NotificationCenter(),
            preferredLanguageIdentifiers: { ["zh-Hans"] })
        expect(
            unknown.lastIntegrationSurface == .claudeCode
                && unknown.recoveryIssues.contains(.invalidIntegrationSurface)
                && defaults.string(forKey: ClaudioPreferences.integrationSurfaceDefaultsKey)
                    == "unknown-surface",
            "未知 Surface 必须 fail closed、记录 recovery issue 且不静默重写 defaults")

        defaults.set(HostSurfaceID.chatGPTDesktopAX.rawValue, forKey: ClaudioPreferences.integrationSurfaceDefaultsKey)
        let axOnly = ClaudioPreferences(
            defaults: defaults,
            notificationCenter: NotificationCenter(),
            preferredLanguageIdentifiers: { ["zh-Hans"] })
        expect(
            axOnly.lastIntegrationSurface == .claudeCode
                && axOnly.recoveryIssues.contains(.invalidIntegrationSurface),
            "AX-only Surface 偏好必须回退 Claude Code 并记录恢复错误")
    }

    suite("集成 destination reconcile：当前 Agent 被刷新移除时按产品顺序选择并持久化") {
        let suiteName = "IntegrationDestinationModelSuite.reconcile.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(HostSurfaceID.codex.rawValue, forKey: ClaudioPreferences.integrationSurfaceDefaultsKey)
        let preferences = ClaudioPreferences(
            defaults: defaults,
            notificationCenter: NotificationCenter(),
            preferredLanguageIdentifiers: { ["zh-Hans"] })
        let full = integrationDestinationTestContent()
        let model = IntegrationDestinationModel(
            content: full,
            refreshHandler: IntegrationDestinationRefreshHandler {
                integrationDestinationTestOutcome(content: full)
            },
            actionHandler: IntegrationDestinationActionHandler { _ in
                integrationDestinationTestOutcome(content: full)
            },
            preferences: preferences)
        expect(model.selectedHost == .codex, "reconcile 前必须选中偏好 Codex")

        let replacement = IntegrationDestinationContent(
            sourceRows: full.sourceRows.filter { $0.host != .codex },
            matrix: full.matrix,
            hostFacts: full.hostFacts.filter { $0.host != .codex })
        model.replaceExternalContent(replacement)
        expect(
            model.selectedHost == .claudeCode
                && preferences.lastIntegrationSurface == .claudeCode,
            "移除当前 Agent 后必须按 productVisibleCases 选择并持久化 Claude Code")

        let unavailable = IntegrationDestinationContent(
            sourceRows: [],
            matrix: full.matrix,
            hostFacts: [],
            unavailableReason: "manager unavailable")
        model.replaceExternalContent(unavailable)
        expect(
            model.selectedHost == nil && model.content.isUnavailable
                && model.content.unavailableReason == "manager unavailable",
            "空内容必须渲染 unavailable 状态，不得进入 onboarding/debug route")
    }

    suite("集成 destination route：有效 deep link 精确选中 Surface，stale/invalid 不持久化") {
        let allSurfaces = Set(HostID.productVisibleCases.map(\.surfaceID))
        let availability = SettingsRouteAvailability(
            integrationSurfaces: allSurfaces,
            eventScopes: [.global],
            soundScopes: [.global],
            soundPackIDs: [],
            events: Set(Event.allCases))
        let validRoute = SettingsRoute.integrations(surface: .workBuddy)
        let validResolution = resolveSettingsRoute(validRoute, availability: availability)
        expect(validResolution.failure == nil, "产品 Surface deep link 必须解析成功")

        let suiteName = "IntegrationDestinationModelSuite.route.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = ClaudioPreferences(
            defaults: defaults,
            notificationCenter: NotificationCenter(),
            preferredLanguageIdentifiers: { ["zh-Hans"] })
        let content = integrationDestinationTestContent()
        let model = IntegrationDestinationModel(
            content: content,
            refreshHandler: IntegrationDestinationRefreshHandler {
                integrationDestinationTestOutcome(content: content)
            },
            actionHandler: IntegrationDestinationActionHandler { _ in
                integrationDestinationTestOutcome(content: content)
            },
            preferences: preferences)
        if validResolution.failure == nil {
            _ = model.selectHost(.workBuddy)
        }
        expect(
            model.selectedHost == .workBuddy
                && preferences.lastIntegrationSurface == .workBuddy,
            "有效 deep link 必须经过 selectHost 单入口并持久化")

        let staleAvailability = SettingsRouteAvailability(
            integrationSurfaces: [.claudeCode],
            eventScopes: [.global],
            soundScopes: [.global],
            soundPackIDs: [],
            events: Set(Event.allCases))
        let stale = resolveSettingsRoute(
            .integrations(surface: .codex),
            availability: staleAvailability)
        expect(stale.failure == .staleSurface(.codex), "缺失产品 Surface 必须保持 stale-route failure")
        expect(
            preferences.lastIntegrationSurface == .workBuddy,
            "stale deep link 不得静默回退或改写最后选择")
        let invalid = resolveSettingsRoute(
            .integrations(surface: .chatGPTDesktopAX),
            availability: availability)
        expect(invalid.failure == .invalidSurface(.chatGPTDesktopAX), "AX deep link 必须保持 invalid-route failure")
    }

    await suite("集成 destination Toggle/action lifecycle：确认取消、host 归属、in-flight 与无乐观翻转") {
        let initial = integrationDestinationTestContent()
        let updated = integrationDestinationTestContent(statuses: [.claudeCode: .notConnected])
        let gate = IntegrationDestinationTestGate()
        let calls = IntegrationDestinationTestRecorder<HostIntegrationUserAction>()
        let model = IntegrationDestinationModel(
            content: initial,
            refreshHandler: IntegrationDestinationRefreshHandler {
                await gate.wait()
                return integrationDestinationTestOutcome(content: initial, message: "refresh complete")
            },
            actionHandler: IntegrationDestinationActionHandler { action in
                await calls.append(action)
                await gate.wait()
                return integrationDestinationTestOutcome(
                    content: action == .disconnect(.claudeCode) ? updated : initial,
                    kind: .information,
                    message: "action complete")
            })
        _ = model.selectHost(.claudeCode)

        model.requestToggle(for: .claudeCode)
        let callsBeforeConfirmation = await calls.all()
        expect(
            model.pendingConfirmation == .disconnect(.claudeCode)
                && callsBeforeConfirmation.isEmpty,
            "关闭 Toggle 必须先进入 disconnect confirmation，不能直接调用 manager")
        model.cancelPendingAction()
        expect(model.pendingConfirmation == nil, "取消 disconnect 必须零副作用")
        model.requestClearReceiptHistory(for: .claudeCode)
        expect(model.pendingConfirmation == .clearReceiptHistory(.claudeCode), "第四行清除必须先确认")
        model.cancelPendingAction()

        model.requestToggle(for: .claudeCode)
        let disconnectTask = Task { @MainActor in
            await model.confirmPendingAction()
        }
        for _ in 0..<20 where model.inFlightOperation == nil {
            await Task.yield()
        }
        expect(
            model.inFlightOperation?.host == .claudeCode
                && model.inFlightOperation?.action == .disconnect(.claudeCode),
            "断开 in-flight 必须归属原 action.host")
        expect(
            model.content.agent(for: .claudeCode)?.isOn == true,
            "断开进行中不得乐观翻转 Toggle")
        expect(
            model.agentControls.allSatisfy { !$0.isToggleEnabled },
            "in-flight 期间所有冲突 Toggle 必须禁用")
        _ = model.selectHost(.workBuddy)
        expect(model.selectedHost == .workBuddy, "in-flight 期间仍允许切换 Agent 查看")
        model.requestToggle(for: .workBuddy)
        expect(model.pendingConfirmation == nil, "in-flight 期间不得提交新的冲突动作")
        let callsWhileInFlight = await calls.all()
        expect(callsWhileInFlight == [.disconnect(.claudeCode)], "重复提交不得重复调用 manager")
        await gate.open()
        await disconnectTask.value
        expect(
            model.inFlightOperation == nil
                && model.content.agent(for: .claudeCode)?.isOn == false
                && model.feedback?.host == .claudeCode,
            "断开完成后必须发布刷新快照、关闭 in-flight 并反馈原宿主")
    }

    await suite("集成 destination connect/clear：未连接 Toggle 执行 connect，清除确认归属第四行") {
        let initial = integrationDestinationTestContent(statuses: [.workBuddy: .notConnected])
        let gate = IntegrationDestinationTestGate()
        let calls = IntegrationDestinationTestRecorder<HostIntegrationUserAction>()
        let connected = integrationDestinationTestContent()
        let model = IntegrationDestinationModel(
            content: initial,
            refreshHandler: IntegrationDestinationRefreshHandler {
                integrationDestinationTestOutcome(content: connected)
            },
            actionHandler: IntegrationDestinationActionHandler { action in
                await calls.append(action)
                await gate.wait()
                return integrationDestinationTestOutcome(content: connected, message: "connected")
            })
        _ = model.selectHost(.workBuddy)
        let connectTask = Task { @MainActor in await model.toggleHost(.workBuddy) }
        for _ in 0..<20 where model.inFlightOperation == nil { await Task.yield() }
        expect(
            model.inFlightOperation?.action == .connect(.workBuddy)
                && model.content.agent(for: .workBuddy)?.isOn == false,
            "未连接 Toggle 必须执行 connect，期间保持关闭状态")
        await gate.open()
        await connectTask.value
        let connectCalls = await calls.all()
        expect(
            connectCalls == [.connect(.workBuddy)]
                && model.content.agent(for: .workBuddy)?.isOn == true,
            "connect 完成后必须消费新快照")

        model.requestClearReceiptHistory(for: .workBuddy)
        expect(model.pendingConfirmation == .clearReceiptHistory(.workBuddy), "清除历史必须归属 WorkBuddy")
        model.cancelPendingAction()
        expect(model.pendingConfirmation == nil, "取消清除历史不得调用 action handler")
    }

    await suite("集成 destination outcome/error：manager failure、throw、store unavailable 都保留可见失败事实") {
        let initial = integrationDestinationTestContent()
        let degraded = integrationDestinationTestContent(statuses: [.codex: .needsAttention])
        let failureModel = IntegrationDestinationModel(
            content: initial,
            refreshHandler: IntegrationDestinationRefreshHandler {
                integrationDestinationTestOutcome(content: initial)
            },
            actionHandler: IntegrationDestinationActionHandler { _ in
                integrationDestinationTestOutcome(
                    content: degraded,
                    kind: .failure,
                    message: "manager rejected")
            })
        await failureModel.perform(.repair(.codex))
        expect(
            failureModel.content.agent(for: .codex)?.status == .needsAttention
                && failureModel.feedback?.kind == .failure
                && failureModel.feedback?.message == "manager rejected",
            "manager failure outcome 仍必须刷新并显示完整 failure 反馈")

        let throwingModel = IntegrationDestinationModel(
            content: initial,
            refreshHandler: IntegrationDestinationRefreshHandler {
                throw HostIntegrationPresentationError.storeUnavailable
            },
            actionHandler: IntegrationDestinationActionHandler { _ in
                throw HostIntegrationPresentationError.storeUnavailable
            })
        await throwingModel.perform(.redetect)
        expect(
            throwingModel.content == initial
                && throwingModel.feedback?.kind == .failure
                && throwingModel.feedback?.message
                    == ClaudioL10n(language: .zhHans).text(.integrationsStoreUnavailable),
            "store unavailable throw 必须保留旧快照并显示可见失败")

        let copylessModel = IntegrationDestinationModel(
            content: integrationDestinationTestContent(configurationSources: [:]),
            refreshHandler: IntegrationDestinationRefreshHandler {
                integrationDestinationTestOutcome(content: initial)
            },
            actionHandler: IntegrationDestinationActionHandler { _ in
                integrationDestinationTestOutcome(content: initial)
            },
            clipboardWriter: IntegrationDestinationClipboardWriter { _ in true })
        expect(!copylessModel.copyConfigurationSource(for: .workBuddy), "无来源时复制必须 fail closed")
        let copyModel = IntegrationDestinationModel(
            content: initial,
            refreshHandler: IntegrationDestinationRefreshHandler {
                integrationDestinationTestOutcome(content: initial)
            },
            actionHandler: IntegrationDestinationActionHandler { _ in
                integrationDestinationTestOutcome(content: initial)
            },
            clipboardWriter: IntegrationDestinationClipboardWriter { _ in true })
        expect(copyModel.copyConfigurationSource(for: .workBuddy), "manager 提供来源时复制必须走注入 adapter")
    }

    await suite("集成 destination receipt/feedback：回执变化逐条反馈，窗口生命周期限制主动播报") {
        let awaiting = integrationDestinationTestContent(
            statuses: [.workBuddy: .awaitingActivation])
        let ready = integrationDestinationTestContent(statuses: [.workBuddy: .ready])
        let model = IntegrationDestinationModel(
            content: awaiting,
            refreshHandler: IntegrationDestinationRefreshHandler {
                integrationDestinationTestOutcome(content: ready)
            },
            actionHandler: IntegrationDestinationActionHandler { _ in
                integrationDestinationTestOutcome(content: ready)
            })
        model.noteWindowVisibility(false)
        model.noteWindowKeyState(true)
        expect(!model.isWindowVisible && !model.isWindowKey, "隐藏窗口不得被标记为 key")
        model.replaceExternalContent(ready)
        expect(model.feedback == nil, "隐藏 destination 收到外部回执时不得播报 toast")

        model.noteWindowVisibility(true)
        model.noteWindowKeyState(false)
        model.replaceExternalContent(awaiting)
        model.replaceExternalContent(ready)
        expect(
            model.feedback?.host == .workBuddy
                && model.feedback?.message.contains("回执") == true,
            "可见 destination 的新真实回执必须产生逐条脱敏反馈")
        model.noteWindowVisibility(false)
        expect(!model.isWindowKey, "窗口隐藏必须清除 key 状态，防止越界播报")
    }
}
