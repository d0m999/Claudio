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
        expect(scopes[0].compactStatusText == "5/5 全局默认", "Global 必须显示五事件全局默认")
        expect(scopes[1].compactStatusText == "4/5 已就绪", "Codex 必须显示 4/5 能力事实")
        expect(scopes[2].compactStatusText == "2/5 已配置", "WorkBuddy 待确认仍显示 2/5")
        expect(
            !scopes.contains(where: { $0.scope == .surface(.claudeCode) }),
            "即使磁盘残留 Surface 覆盖，notConnected 也不得进入 popup")
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
