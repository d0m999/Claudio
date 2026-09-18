import ClaudioCore
import ClaudioGUICore
import Foundation

@MainActor
private func focusEventPresentations(
    scope: PanelSoundScopeID = .global,
    coverage: CoverageState = .present(fileName: "tone.aiff"),
    masterVolume: Double = 0.8
) -> [PanelEventPresentation] {
    panelEventPresentations(
        rows: Event.allCases.map { EventRow(event: $0, coverage: coverage, enabled: true) },
        scope: scope,
        masterVolume: masterVolume,
        language: .zhHans)
}

@MainActor
func runPanelFocusOrderSuites() {
    suite("声音作用域浮层焦点：只列出当前可见的作用域") {
        let scopes: [PanelSoundScopeID] = [
            .global, .surface(.codex), .surface(.claudeCode), .surface(.workBuddy),
        ]
        expect(
            panelSoundScopePickerFocusOrder(scopes: scopes)
                == scopes.map(PanelSoundScopePickerFocusTarget.scope),
            "浮层焦点顺序必须由当前可见作用域生成，不得注入旧的连接入口")
        expect(
            !panelSoundScopePickerFocusOrder(scopes: scopes)
                .contains(PanelSoundScopePickerFocusTarget.integrationAction(.surface(.codex))),
            "行内状态动作只进入 Tab 焦点序，不得占用方向键顺序")
    }

    suite("panelFocusOrder：onboarding 兼容顺序保持失败详情 → 主动作 → 次动作") {
        expect(
            panelFocusOrder(
                .onboarding(
                    hasPrimaryAction: true,
                    hasSecondaryAction: true,
                    hasDetailToggle: true))
                == [.revealDetail, .onboardingPrimaryAction, .onboardingSecondaryAction],
            "onboarding 兼容焦点顺序漂移")
    }

    suite("panelFocusOrder：Global 正常顺序为作用域 → 近期提示 → 五行试听/静音 → 音量 → 设置 → 退出") {
        let events = focusEventPresentations()
        let order = panelFocusOrder(
            .operational(
                events: events,
                hasMasterVolume: true,
                hasOpenSoundSettings: true,
                hasResetSurface: false))
        let eventTargets = Event.allCases.flatMap {
            [PanelFocusTarget.eventPreview($0), .eventMute($0)]
        }
        expect(
            order == [.recentNotices, .soundScope] + eventTargets
                + [.masterVolume, .openSoundSettings, .quitApplication],
            "Global 正常焦点顺序错误：\(order)")
        expect(
            panelFirstFocusTarget(
                .operational(
                    events: events,
                    hasMasterVolume: true,
                    hasOpenSoundSettings: true,
                    hasResetSurface: false)) == .soundScope, "打开必须落声音作用域")
    }

    suite("panelFocusOrder：WorkBuddy 未实现事件不产生试听或静音焦点") {
        let events = focusEventPresentations(scope: .surface(.workBuddy))
        let order = panelFocusOrder(
            .operational(
                events: events,
                hasMasterVolume: true,
                hasOpenSoundSettings: true,
                hasResetSurface: true))
        for event in [Event.stopFailure, .notification] {
            expect(!order.contains(.eventPreview(event)), "\(event) 不得有试听焦点")
            expect(!order.contains(.eventMute(event)), "\(event) 不得有静音焦点")
        }
        for event in [Event.taskStart, .stop, .subagentStop] {
            expect(order.contains(.eventPreview(event)), "\(event) 必须有试听焦点")
            expect(order.contains(.eventMute(event)), "\(event) 必须有静音焦点")
        }
        expect(
            order.suffix(4).elementsEqual([
                .masterVolume, .openSoundSettings, .resetSurface, .quitApplication,
            ]),
            "Surface 播放设置与 reset/退出顺序错误：\(order)")
    }

    suite("panelFocusOrder：缺失声音只移除试听，保留已实现事件静音") {
        let events = focusEventPresentations(coverage: .broken(fileName: "missing.aiff"))
        let order = panelFocusOrder(
            .operational(
                events: events,
                hasMasterVolume: true,
                hasOpenSoundSettings: true,
                hasResetSurface: false))
        for event in Event.allCases {
            expect(!order.contains(.eventPreview(event)), "缺失声音不得有试听焦点")
            expect(order.contains(.eventMute(event)), "缺失声音仍须保留静音焦点")
        }
    }

    suite("panelFocusOrder：主音量为零移除试听，不影响静音") {
        let events = focusEventPresentations(masterVolume: 0)
        let order = panelFocusOrder(
            .operational(
                events: events,
                hasMasterVolume: true,
                hasOpenSoundSettings: true,
                hasResetSurface: false))
        expect(
            !order.contains(where: {
                if case .eventPreview = $0 { return true }; return false
            }),
            "音量为零不得保留试听焦点")
        expect(
            Event.allCases.allSatisfy { order.contains(.eventMute($0)) },
            "音量为零不等于逐事件静音")
    }

    suite("panelFocusOrder：bootstrap/config recovery 位于事件之前") {
        let actions: [PanelFocusTarget] = [
            .bootstrapReportRetry(id: "a"),
            .bootstrapReportDiagnostics(id: "a"),
        ]
        let order = panelFocusOrder(
            .operational(
                events: [],
                hasMasterVolume: false,
                hasOpenSoundSettings: false,
                hasResetSurface: false,
                hasConfigFailureNotice: true,
                bootstrapReportActions: actions))
        expect(
            order == [.recentNotices, .soundScope] + actions + [.configReveal, .quitApplication],
            "恢复动作视觉/焦点顺序错误：\(order)")
    }

    suite("panelFocusOrder：needsPack 保留声音作用域、近期提示、打开设置与退出，禁用主音量") {
        let order = panelFocusOrder(
            .operational(
                events: [],
                hasMasterVolume: false,
                hasOpenSoundSettings: true,
                hasResetSurface: false))
        expect(
            order == [.recentNotices, .soundScope, .openSoundSettings, .quitApplication],
            "needsPack 焦点顺序错误：\(order)")
    }

    suite("刷新失败重试：焦点位于活动概览之后、事件之前；消失时回到作用域") {
        let events = focusEventPresentations()
        let failedOrder = panelFocusOrder(
            .activityOperational(
                events: events,
                hasActivityOverview: true,
                hasMasterVolume: true,
                hasRefreshFailedNotice: true))
        let readyOrder = panelFocusOrder(
            .activityOperational(
                events: events,
                hasActivityOverview: true,
                hasMasterVolume: true))
        let lastActivityEvent = ActivityOverviewBarLayout.events.last!
        let activityEnd = failedOrder.lastIndex(of: .activityMetric(lastActivityEvent))!
        let retryIndex = failedOrder.firstIndex(of: .libraryRefreshRetry)!
        let firstEventIndex = failedOrder.firstIndex(of: .eventPreview(Event.allCases[0]))!
        expect(
            activityEnd < retryIndex && retryIndex < firstEventIndex,
            "重试按钮必须按视觉顺序插在活动控件与事件控件之间")
        expect(!readyOrder.contains(.libraryRefreshRetry), "提示消失后不得保留幽灵焦点")
        expect(
            panelFocusAfterTopContentChange(
                previous: .events,
                current: .events,
                focusedTarget: .libraryRefreshRetry,
                nextOrder: readyOrder) == .soundScope,
            "重试按钮消失后，焦点必须回到声音作用域")
        let configFailureOrder: [PanelFocusTarget] = [
            .headerSettings, .recentNotices, .soundScope, .configReveal, .quitApplication,
        ]
        expect(
            panelFocusAfterTopContentChange(
                previous: .events,
                current: .configFailure(reason: "配置损坏"),
                focusedTarget: .libraryRefreshRetry,
                nextOrder: configFailureOrder) == .soundScope,
            "内容种类切换时，消失的刷新重试按钮也必须回到声音作用域")
        expect(
            panelFocusAfterTopContentChange(
                previous: .events,
                current: .events,
                focusedTarget: .eventMute(.stop),
                nextOrder: failedOrder) == .eventMute(.stop),
            "新增提示时仍存在的事件焦点必须保持")
        expect(
            panelFocusAfterTopContentChange(
                previous: .events,
                current: .events,
                focusedTarget: .eventMute(.stop),
                nextOrder: readyOrder) == .eventMute(.stop),
            "移除提示时仍存在的事件焦点必须保持")
    }

    suite("panelFocusAfterTopContentChange：错误原因文字变化不重置仍存在的控件焦点") {
        let nextOrder: [PanelFocusTarget] = [
            .headerSettings, .recentNotices, .soundScope, .configReveal, .quitApplication,
        ]
        let target = panelFocusAfterTopContentChange(
            previous: .configFailure(reason: "旧原因"),
            current: .configFailure(reason: "新原因"),
            focusedTarget: .configReveal,
            nextOrder: nextOrder)
        expect(
            target == .configReveal,
            "同一失败卡只改变 reason 时，仍存在的 Reveal 控件必须保留焦点，得到 \(String(describing: target))")
    }

    suite("panelFocusAfterTopContentChange：原本无焦点时内容发布不主动聚焦") {
        let nextOrder: [PanelFocusTarget] = [
            .headerSettings, .recentNotices, .soundScope, .configReveal, .quitApplication,
        ]
        expect(
            panelFocusAfterTopContentChange(
                previous: .configFailure(reason: "旧原因"),
                current: .configFailure(reason: "新原因"),
                focusedTarget: nil,
                nextOrder: nextOrder) == nil,
            "失败原因文字变化时，原本无焦点的面板必须继续无焦点")
        expect(
            panelFocusAfterTopContentChange(
                previous: .events,
                current: .configFailure(reason: "坏配置"),
                focusedTarget: nil,
                nextOrder: nextOrder) == nil,
            "切换内容种类也不能在没有消失控件时凭空创建焦点")
    }

    suite("panelFocusAfterTopContentChange：事件控件消失时优先恢复按钮，否则回到声音作用域") {
        let recoveryOrder: [PanelFocusTarget] = [
            .headerSettings, .recentNotices, .soundScope, .configReveal, .quitApplication,
        ]
        expect(
            panelFocusAfterTopContentChange(
                previous: .events,
                current: .configFailure(reason: "坏配置"),
                focusedTarget: .eventMute(.stop),
                nextOrder: recoveryOrder) == .configReveal,
            "事件行消失并进入配置失败态时，焦点必须落在有效恢复按钮")

        let needsPackOrder: [PanelFocusTarget] = [
            .headerSettings, .recentNotices, .soundScope, .quitApplication,
        ]
        expect(
            panelFocusAfterTopContentChange(
                previous: .events,
                current: .needsPack,
                focusedTarget: .eventMute(.stop),
                nextOrder: needsPackOrder) == .soundScope,
            "事件行消失且没有恢复按钮时，焦点必须回到声音作用域")
    }
}

@MainActor
func runPanelFocusInFlightSuites() {
    suite("panelFirstFocusTarget：onboarding in-flight 不落禁用 CTA") {
        expect(
            panelFirstFocusTarget(
                .onboarding(hasPrimaryAction: true, hasSecondaryAction: true),
                ctaOperable: false) == nil,
            "禁用 CTA 不得接收焦点")
    }
}
