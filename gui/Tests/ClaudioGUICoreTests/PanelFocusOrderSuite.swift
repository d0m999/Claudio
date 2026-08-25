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

    suite("panelFocusOrder：Global 正常顺序为作用域 → 五行试听/静音 → 音量 → 设置 → 退出") {
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
            order == [.soundScope] + eventTargets
                + [.masterVolume, .openSoundSettings, .quitApplication],
            "Global 正常焦点顺序错误：\(order)")
        expect(panelFirstFocusTarget(.operational(
            events: events,
            hasMasterVolume: true,
            hasOpenSoundSettings: true,
            hasResetSurface: false)) == .soundScope, "打开必须落声音作用域")
    }

    suite("panelFocusOrder：WorkBuddy 三条未实现事件不产生试听或静音焦点") {
        let events = focusEventPresentations(scope: .surface(.workBuddy))
        let order = panelFocusOrder(
            .operational(
                events: events,
                hasMasterVolume: true,
                hasOpenSoundSettings: true,
                hasResetSurface: true))
        for event in [Event.stopFailure, .notification, .subagentStop] {
            expect(!order.contains(.eventPreview(event)), "\(event) 不得有试听焦点")
            expect(!order.contains(.eventMute(event)), "\(event) 不得有静音焦点")
        }
        for event in [Event.taskStart, .stop] {
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
            !order.contains(where: { if case .eventPreview = $0 { return true }; return false }),
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
            order == [.soundScope] + actions + [.configReveal, .quitApplication],
            "恢复动作视觉/焦点顺序错误：\(order)")
    }

    suite("panelFocusOrder：needsPack 保留声音作用域、打开设置与退出，禁用主音量") {
        let order = panelFocusOrder(
            .operational(
                events: [],
                hasMasterVolume: false,
                hasOpenSoundSettings: true,
                hasResetSurface: false))
        expect(
            order == [.soundScope, .openSoundSettings, .quitApplication],
            "needsPack 焦点顺序错误：\(order)")
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
