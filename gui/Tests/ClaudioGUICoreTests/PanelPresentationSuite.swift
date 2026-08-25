import ClaudioCore
import ClaudioGUICore
import Foundation

private func panelPresentationRow(
    _ host: HostID,
    status: HostSourceRowStatus,
    supported: Int
) -> HostSourceRowPresentation {
    HostSourceRowPresentation(
        host: host,
        title: host.displayName,
        readinessText: "fixture",
        detailText: nil,
        status: status,
        supportedCount: supported,
        totalCount: Event.allCases.count)
}

private func panelPresentationEventRows(
    coverage: CoverageState = .present(fileName: "tone.aiff")
) -> [EventRow] {
    Event.allCases.map { EventRow(event: $0, coverage: coverage, enabled: true) }
}

@MainActor
func runPanelPresentationSuites() {
    suite("面板作用域：Global 恒在、Surface 按 registry 排序，notConnected 一律过滤") {
        let config = ClaudioConfig(
            selectedPack: "pack",
            surfaceOverrides: [
                HostSurfaceID.claudeCode.rawValue: SurfaceSoundOverride(selectedPack: "other")
            ])
        let scopes = panelSoundScopePresentations(
            sourceRows: [
                panelPresentationRow(.workBuddy, status: .awaitingActivation, supported: 2),
                panelPresentationRow(.claudeCode, status: .notConnected, supported: 5),
                panelPresentationRow(.codex, status: .ready, supported: 4),
            ],
            config: config,
            language: .zhHans)

        expect(
            scopes.map(\.scope) == [.global, .surface(.codex), .surface(.workBuddy)],
            "作用域菜单必须遵守 Global → Codex → Claude Code → WorkBuddy，并过滤未连接项：\(scopes.map(\.scope))")
        expect(scopes[0].name == "全局默认", "Global 作用域必须使用完整名称")
        expect(
            scopes[0].coverageText == "5 个事件" && scopes[0].stateText == "默认"
                && scopes[0].summaryText == "5 个事件 · 默认",
            "Global 必须把事件数与默认状态分开投影")
        expect(
            scopes[1].coverageText == "4/5" && scopes[1].stateText == "已激活"
                && scopes[1].summaryText == "4/5 · 已激活",
            "Codex 必须显示 4/5 与当前激活事实")
        expect(
            scopes[2].status == .awaitingActivation && scopes[2].stateText == "待回执"
                && scopes[2].summaryText == "2/5 · 待回执",
            "WorkBuddy 必须保留 awaitingActivation 语义并使用面板专属待回执文案")
        expect(
            !scopes.contains(where: { $0.scope == .surface(.claudeCode) }),
            "即使磁盘残留 Surface 覆盖，notConnected 也不得进入 popup")
    }

    suite("面板作用域文案：英文同样分离覆盖数与状态，不回退共享 readiness 文案") {
        let scopes = panelSoundScopePresentations(
            sourceRows: [
                panelPresentationRow(.workBuddy, status: .awaitingActivation, supported: 2)
            ],
            config: ClaudioConfig(selectedPack: "pack"),
            language: .english)

        expect(scopes[0].name == "Global defaults", "英文 Global 必须使用完整名称")
        expect(scopes[0].summaryText == "5 events · Default", "英文 Global 摘要错误")
        expect(
            scopes[1].summaryText == "2/5 · Awaiting receipt",
            "英文等待态不得继续显示 configured")
        expect(
            scopes[1].accessibilityLabel.contains("Awaiting receipt"),
            "AX 文案必须消费与屏幕相同的面板状态投影")
    }

    suite("面板作用域恢复：显式 Global/合法历史值保留，首次与失效值选首个可用来源") {
        let scopes = panelSoundScopePresentations(
            sourceRows: [
                panelPresentationRow(.claudeCode, status: .ready, supported: 5),
                panelPresentationRow(.codex, status: .ready, supported: 4),
                panelPresentationRow(.workBuddy, status: .ready, supported: 2),
            ],
            config: ClaudioConfig(selectedPack: "pack"),
            language: .english)

        expect(
            resolvedPanelSoundScopeSelection(storedValue: "global", scopes: scopes) == .global,
            "显式 Global 不得被自动选择覆盖")
        expect(
            resolvedPanelSoundScopeSelection(
                storedValue: HostSurfaceID.workBuddy.rawValue,
                scopes: scopes) == .surface(.workBuddy),
            "合法历史 WorkBuddy 选择必须恢复")
        expect(
            resolvedPanelSoundScopeSelection(storedValue: nil, scopes: scopes) == .surface(.codex),
            "首次打开应选 registry 中首个可用来源")
        expect(
            resolvedPanelSoundScopeSelection(storedValue: "stale", scopes: scopes)
                == .surface(.codex),
            "失效值应选首个可用来源")
        expect(
            resolvedPanelSoundScopeSelection(storedValue: nil, scopes: [scopes[0]]) == .global,
            "没有可用来源时必须回退 Global")

        let pendingFallback = resolvedPanelSoundScopeSelection(
            storedValue: "unselected",
            scopes: [scopes[0]])
        expect(
            panelSoundScopeStoredValueToPersist(
                storedValue: "unselected",
                resolvedSelection: pendingFallback) == nil,
            "首次宿主刷新尚未完成时只能临时显示 Global，必须保留 unselected 未决状态")

        let firstAvailable = resolvedPanelSoundScopeSelection(
            storedValue: "unselected",
            scopes: scopes)
        expect(
            panelSoundScopeStoredValueToPersist(
                storedValue: "unselected",
                resolvedSelection: firstAvailable) == HostSurfaceID.codex.rawValue,
            "首个可用来源到达后才应把首次自动选择持久化")
    }

    suite("WorkBuddy 五行：仅 UserPromptSubmit/Stop 可操作，其余显式未实现") {
        let events = panelEventPresentations(
            rows: panelPresentationEventRows(),
            scope: .surface(.workBuddy),
            masterVolume: 0.8,
            language: .english)

        expect(events.count == 5, "WorkBuddy 必须稳定显示五行")
        expect(
            events.map(\.nativeEventText)
                == ["UserPromptSubmit", "Stop", "StopFailure", "Notification", "SubagentStop"],
            "WorkBuddy 原生事件名必须来自 catalog")
        for event in events.prefix(2) {
            expect(event.implementation == .implemented, "\(event.event) 必须已实现")
            expect(
                event.controls.previewEnabled && event.controls.muteEnabled,
                "\(event.event) 必须同时允许试听与静音")
        }
        for event in events.suffix(3) {
            expect(event.implementation == .notImplemented, "\(event.event) 必须显式未实现")
            expect(event.capabilityText.contains("Not implemented"), "能力标签必须说出未实现")
            expect(
                !event.controls.previewEnabled && !event.controls.muteEnabled,
                "未实现事件不得提供试听或静音假动作")
        }
    }

    suite("Codex 4/5：无原生事件的 StopFailure 不得伪装成 claudi0 事件 ID") {
        let events = panelEventPresentations(
            rows: panelPresentationEventRows(),
            scope: .surface(.codex),
            masterVolume: 0.8,
            language: .zhHans)
        let unsupported = events.first(where: { $0.event == .stopFailure })!

        expect(unsupported.support == .unsupported, "Codex StopFailure 必须携带 unsupported 枚举")
        expect(unsupported.nativeEventText == "无原生事件", "不得用 stop_failure 伪造宿主原生事件")
        expect(
            !unsupported.controls.previewEnabled && !unsupported.controls.muteEnabled,
            "Codex 不支持事件的两个动作必须禁用")
        expect(
            events.filter { $0.controls.muteEnabled }.count == 4,
            "Codex 必须只有 4/5 个可配置事件")
    }

    suite("Global 行使用 claudi0 事件 ID 与全局默认，不伪造宿主事实") {
        let events = panelEventPresentations(
            rows: panelPresentationEventRows(),
            scope: .global,
            masterVolume: 0.8,
            language: .zhHans)
        expect(
            events.map(\.nativeEventText) == Event.allCases.map(\.cliName),
            "Global 原生事件列必须显示稳定 claudi0 ID")
        expect(events.allSatisfy { $0.capabilityText == "全局默认" }, "Global 能力标签必须是全局默认")
        expect(
            events.allSatisfy { $0.support == nil && $0.implementation == nil },
            "Global 不得伪造 Host capability")
    }

    suite("事件可用性：缺失声音只禁试听；主音量为零不禁静音；禁止写入时静音 fail closed") {
        let broken = panelEventPresentations(
            rows: panelPresentationEventRows(coverage: .broken(fileName: "missing.aiff")),
            scope: .global,
            masterVolume: 0.8,
            language: .zhHans)
        expect(
            broken.allSatisfy { !$0.controls.previewEnabled && $0.controls.muteEnabled },
            "文件缺失只应禁用试听")
        expect(broken[0].soundFileText == "文件缺失：missing.aiff", "缺失文件必须明确标注")

        let silent = panelEventPresentations(
            rows: panelPresentationEventRows(),
            scope: .global,
            masterVolume: 0,
            language: .zhHans)
        expect(
            silent.allSatisfy { !$0.controls.previewEnabled && $0.controls.muteEnabled },
            "主音量零只影响试听可达性")

        let readOnly = panelEventPresentations(
            rows: panelPresentationEventRows(),
            scope: .global,
            masterVolume: 0.8,
            language: .zhHans,
            configWritesAllowed: false)
        expect(readOnly.allSatisfy { !$0.controls.muteEnabled }, "配置不可写时不得展示可操作静音")
    }

    suite("能力格显式保留 support/implementation，视图无需从文案反推") {
        let binding = HostCapabilityCatalog.binding(host: .workBuddy, event: .notification)!
        let cell = HostCapabilityCellPresentation(
            host: .workBuddy,
            event: .notification,
            state: .unsupported,
            support: binding.support,
            implementation: binding.implementation,
            qualificationText: "fixture")
        let localized = localizedCapabilityCell(cell, language: .english)
        expect(localized.support == .partial, "能力格必须保留 partial support")
        expect(localized.implementation == .notImplemented, "能力格必须保留 notImplemented")
    }
}
