import ClaudioCore
import ClaudioGUICore
import ClaudioSettingsPresentation
import Combine
import Foundation
import SoundPacksWindow

@MainActor
func runSettingsPresentationLifecycleSuites() {
    suite("Settings session deletion contract：route、phase 与 lifecycle 只有一个 owner") {
        let root = guiTestRepositoryRoot()
        let sessionURL = root.appendingPathComponent(
            "gui/Sources/ClaudioSettingsPresentation/SettingsPresentationSession.swift")
        let stateURL = root.appendingPathComponent(
            "gui/Sources/ClaudioSettingsPresentation/SettingsPresentationState.swift")
        let rootViewURL = root.appendingPathComponent(
            "gui/Sources/ClaudioSettingsPresentation/SettingsRootView.swift")
        let controllerURL = root.appendingPathComponent(
            "gui/Sources/ClaudioGUI/SettingsWindowController.swift")
        let navigationURL = root.appendingPathComponent(
            "gui/Sources/ClaudioGUICore/SettingsNavigation.swift")
        guard
            let session = try? String(contentsOf: sessionURL, encoding: .utf8),
            let state = try? String(contentsOf: stateURL, encoding: .utf8),
            let rootView = try? String(contentsOf: rootViewURL, encoding: .utf8),
            let controller = try? String(contentsOf: controllerURL, encoding: .utf8),
            let navigation = try? String(contentsOf: navigationURL, encoding: .utf8)
        else {
            expect(false, "读不到 Settings session/controller/navigation ownership source")
            return
        }

        expect(
            session.contains("func send(")
                && session.contains("SettingsPresentationCommand")
                && state.contains("SettingsRouteResolution")
                && state.contains("SettingsWindowPhase")
                && state.contains("focusDebt"),
            "session state/command 必须共同拥有 typed route、window phase 与 focus debt")
        expect(
            rootView.contains("settingsPresentationSession.send(.route(")
                && !rootView.contains("SettingsWindowPresentationModel")
                && !rootView.contains("model.request("),
            "production root 必须只通过 session command 路由，不得保留第二 navigation owner")

        let forbiddenControllerOwners = [
            "SettingsWindowPresentationModel",
            "SoundPacksEditorOwner",
            "PanelConfigController",
            "EventSettingsWindowSelection",
            "HostIntegrationPresentationStore",
            "IntegrationDestinationModel",
            "AICueGenerationViewModel",
            "settingsSoundPackShellProjections(",
        ]
        expect(
            forbiddenControllerOwners.allSatisfy { !controller.contains($0) },
            "AppKit controller 不得持有 destination model/publisher 或 raw Sound Pack owner")
        expect(
            !navigation.contains("SettingsWindowPresentationModel<")
                && !navigation.contains("pendingHandback"),
            "ClaudioGUICore 只能保留纯 route/revision reducer，旧泛型 handback wrapper 必须删除")
    }

    #if DEBUG
    suite("Settings session route：generic、explicit 与 repeated 请求保持单事务") {
        let fixture = SettingsPresentationFixtures.generalLogin(
            route: .destination(.usage),
            availability: PreviewFixtures.settingsRouteAvailability)
        let session = fixture.session
        _ = session.send(.windowWillClose)
        let closedRevision = session.state.explicitRouteRequestRevision

        expect(
            session.send(.present(.route(nil))) == .presented(wasAlreadyPresented: false)
                && session.state.routeResolution.route == .destination(.usage)
                && session.state.activeDestination == .usage
                && session.state.explicitRouteRequestRevision == closedRevision + 1,
            "closed generic open 必须恢复最新 top-level destination 并形成新 focus debt")
        let visibleState = session.state
        expect(
            session.send(.present(.route(nil))) == .presented(wasAlreadyPresented: true)
                && session.state == visibleState,
            "visible generic reopen 必须完全幂等，不改 route、revision 或 focus debt")

        let explicit = SettingsRoute.events(
            scope: .surface(.workBuddy), event: .notification)
        expect(
            session.send(.route(explicit)) == .routed
                && session.state.routeResolution.route == explicit
                && session.state.activeDestination == .eventsAndSounds
                && session.state.focusDebt?.destination == .eventsAndSounds,
            "explicit deep link 必须覆盖 generic destination 并发布精确 focus debt")
        let firstExplicitRevision = session.state.explicitRouteRequestRevision
        expect(
            session.send(.route(explicit)) == .routed
                && session.state.explicitRouteRequestRevision == firstExplicitRevision + 1
                && session.state.focusDebt?.revision == firstExplicitRevision + 1,
            "相同 explicit deep link 每次仍必须只推进一个 request/focus revision")
    }

    suite("Settings session rejection：invalid/stale 保留当前 destination 且零 domain mutation") {
        let fixture = SettingsPresentationFixtures.generalLogin(
            route: .integrations(surface: .workBuddy),
            availability: PreviewFixtures.settingsRouteAvailability)
        let session = fixture.session
        let priorState = session.state
        let priorHost = fixture.integrationsModel.selectedHost
        let priorSurface = fixture.eventSettingsModel.selectedSurface
        let priorSoundMode = fixture.soundPacksEditor.presentation.mode

        expect(
            session.send(.route(.integrations(surface: .chatGPTDesktopAX)))
                == .rejected(.invalidSurface(.chatGPTDesktopAX))
                && session.state == priorState
                && fixture.integrationsModel.selectedHost == priorHost
                && fixture.eventSettingsModel.selectedSurface == priorSurface
                && fixture.soundPacksEditor.presentation.mode == priorSoundMode,
            "invalid route 不得替换当前 destination、推进 revision 或触碰任一 domain owner")

        _ = session.send(.acknowledgeFocus(revision: priorState.explicitRouteRequestRevision))
        let explicitRevision = session.state.explicitRouteRequestRevision
        fixture.session.replaceAvailabilityForTesting(
            SettingsRouteAvailability(
                integrationSurfaces: [],
                eventScopes: [.global],
                soundScopes: [.global],
                soundPackIDs: [],
                events: Set(Event.allCases)))
        expect(
            session.state.routeResolution.route == .integrations(surface: .workBuddy)
                && session.state.routeResolution.failure == .staleSurface(.workBuddy)
                && session.state.activeDestination == .integrations
                && session.state.explicitRouteRequestRevision == explicitRevision
                && session.state.focusDebt == nil
                && fixture.integrationsModel.selectedHost == priorHost,
            "availability 只可重解析当前 route；不得抢焦点、改 destination 或重做 domain mutation")

        _ = session.send(.windowWillClose)
        let invalidWhileClosed = SettingsRoute.sounds(
            .editEvent(surface: nil, packID: "   ", event: .stop))
        let closedInvalidResult = session.send(.present(.route(invalidWhileClosed)))
        expect(
            closedInvalidResult == .rejected(.invalidSoundPackID),
            "closed + invalid explicit 必须保留精确 rejection")
        expect(
            session.state.routeResolution.route == .destination(.integrations)
                && session.state.activeDestination == .integrations,
            "closed + invalid explicit 必须恢复当前合法 top-level destination，不能留下 nil active state")
        expect(
            session.state.windowPhase == .hidden,
            "closed + invalid explicit 在 controller 转发真实 phase 前必须保持 hidden")
        expect(
            fixture.soundPacksEditor.presentation.mode == priorSoundMode,
            "closed + invalid explicit 不得激活失败的 Sound Pack 目标"
        )
    }

    suite("Settings session event shortcut：未知 raw scope 可见且不授权 Global fallback") {
        let fixture = SettingsPresentationFixtures.generalLogin(
            route: .events(scope: .surface(.workBuddy), event: .stop),
            availability: PreviewFixtures.settingsRouteAvailability)
        let previousSurface = fixture.eventSettingsModel.selectedSurface
        let unavailable = EventSettingsWindowRoute(
            scope: .global,
            event: .notification,
            unavailableRequestedScopeStoredValue: "future-surface")

        expect(
            fixture.session.send(.present(.eventShortcut(unavailable)))
                == .presented(wasAlreadyPresented: true)
                && fixture.session.state.activeDestination == .eventsAndSounds
                && fixture.session.state.eventPresentation.route == unavailable
                && fixture.session.state.eventPresentation.route
                    .unavailableRequestedScopeStoredValue == "future-surface"
                && fixture.eventSettingsModel.selectedSurface == previousSurface,
            "shortcut 必须原样保留 unavailable raw scope，绝不能把展示用 Global 变成写目标")
        guard case .events(let editor) = fixture.soundPacksEditor.presentation.mode else {
            expect(false, "event shortcut 必须应用到 shared editor owner")
            return
        }
        expect(
            editor.route == unavailable,
            "同 destination 的新 event route 也必须原样更新 editor context")
    }

    suite("Settings session lifecycle：old inactive 先于 new active 且每次 route 只发布一次") {
        let fixture = SettingsPresentationFixtures.generalLogin(
            route: .integrations(surface: .workBuddy),
            availability: PreviewFixtures.settingsRouteAvailability)
        let session = fixture.session
        _ = session.send(.windowPhaseChanged(.key))
        var routePublications = 0
        var eventActivatedAfterIntegrationHidden = false
        let stateCancellable = session.$state.dropFirst().sink { _ in
            routePublications += 1
        }
        let soundCancellable = fixture.soundPacksEditor.$presentation.dropFirst().sink {
            presentation in
            if case .events = presentation.mode {
                eventActivatedAfterIntegrationHidden = !fixture.integrationsModel.isWindowVisible
            }
        }

        _ = session.send(.route(.events(scope: .global, event: .stop)))
        expect(
            eventActivatedAfterIntegrationHidden && routePublications == 1,
            "transaction 必须先结束旧 Integrations lifecycle，再激活 Events，并只发布一个 coherent state")
        routePublications = 0
        _ = session.send(.route(.integrations(surface: .workBuddy)))
        expect(
            session.state.activeDestination == .integrations
                && fixture.integrationsModel.isWindowVisible
                && fixture.integrationsModel.isWindowKey
                && routePublications == 1,
            "Events→Integrations 返回路径也必须只发布一次并恢复真实 key lifecycle")
        let soundsRoute = SoundPacksWindowRoute.overview(surface: .workBuddy)
        _ = session.send(.route(.sounds(soundsRoute)))
        guard case .sounds(let sounds) = fixture.soundPacksEditor.presentation.mode else {
            expect(false, "Sounds route 必须激活 shared editor owner")
            return
        }
        expect(
            sounds.route == soundsRoute,
            "Sounds typed route 必须逐字应用到 owner，而不是只切换 top-level destination")
        withExtendedLifetime((stateCancellable, soundCancellable)) {}
    }

    suite("Settings session close：Events transient cleanup 恰好一次且 close 幂等") {
        let fixture = SettingsPresentationFixtures.generalLogin(
            route: .events(scope: .global, event: .stop),
            availability: PreviewFixtures.settingsRouteAvailability)
        fixture.beginEventTransientActivity()
        let before = fixture.session.state.eventPresentation
        guard case .events(let activeEditor) = fixture.soundPacksEditor.presentation.mode else {
            expect(false, "AI transient state 必须经 session 激活 shared editor")
            return
        }
        expect(
            before.previewState != .idle && before.aiSessionState != .idle
                && fixture.aiCueViewModel.session != nil
                && activeEditor.route == EventSettingsWindowRoute(scope: .global, event: .stop),
            "fixture 必须先建立真实 preview/AI transient state")

        expect(fixture.session.send(.windowWillClose) == .closed, "首次 close 必须消费窗口 lifecycle")
        let after = fixture.session.state.eventPresentation
        expect(
            after.previewState == .idle
                && after.aiSessionState == .idle
                && after.previewStopRequestRevision == before.previewStopRequestRevision + 1
                && after.aiSessionEndRequestRevision == before.aiSessionEndRequestRevision + 1
                && fixture.aiCueViewModel.session == nil
                && fixture.soundPacksEditor.presentation.mode == .inactive
                && fixture.session.state.windowPhase == .hidden
                && fixture.session.state.activeDestination == nil,
            "close 必须恰好一次结束 sequence、AI session 与 active editor")
        expect(
            fixture.session.send(.windowWillClose) == .unchanged
                && fixture.session.state.eventPresentation == after,
            "retained window 的重复 close callback 不得二次 cleanup")
        let closedState = fixture.session.state
        expect(
            fixture.session.send(.windowPhaseChanged(.visibleNonKey)) == .unchanged
                && fixture.session.send(.windowPhaseChanged(.key)) == .unchanged
                && fixture.session.state == closedState,
            "close 后迟到的 native phase callback 不得把 hidden session 重新推进为 visible/key")
    }

    suite("Settings session announcement：key/active gate 与 post→exact ack 顺序") {
        let fixture = SettingsPresentationFixtures.generalLogin(
            route: .sounds(.overview),
            availability: PreviewFixtures.settingsRouteAvailability)
        let ownerHead = fixture.soundPacksEditor.presentation.pendingAnnouncement?.id
        expect(
            ownerHead != nil && fixture.session.state.pendingAnnouncement == nil,
            "hidden Sounds 可以保留 owner semantic debt，但 session 不得提前交付")
        _ = fixture.session.send(.windowPhaseChanged(.visibleNonKey))
        expect(
            fixture.session.state.pendingAnnouncement == nil,
            "visible non-key 仍不得消费或包装 announcement")
        _ = fixture.session.send(.windowPhaseChanged(.key))
        guard let delivery = fixture.session.state.pendingAnnouncement else {
            expect(false, "key + active Sounds 必须生成唯一 native delivery debt")
            return
        }
        _ = fixture.session.send(
            .acknowledgeAnnouncement(id: delivery.id, didPost: false))
        expect(
            fixture.session.state.pendingAnnouncement?.id == delivery.id
                && fixture.soundPacksEditor.presentation.pendingAnnouncement?.id == ownerHead,
            "post false 必须同时保留 session debt 与 owner exact head")
        _ = fixture.session.send(
            .acknowledgeAnnouncement(id: delivery.id, didPost: true))
        expect(
            fixture.session.state.pendingAnnouncement == nil
                && fixture.soundPacksEditor.presentation.pendingAnnouncement == nil,
            "单一 owner debt 的 post true exact ack 必须同时清空 session 与 owner，不得从 willSet 旧值重建 stale debt"
        )
    }

    suite("Settings session effects：event audibility 与 Calendar privacy 各走一次 typed seam") {
        let fixture = SettingsPresentationFixtures.generalLogin(
            platformActionResult: .performed)
        expect(
            fixture.session.send(.eventAudibilityInputsChanged) == .routed
                && fixture.actionRecorder.eventAudibilityChangeCount == 1,
            "一次 event audibility command 必须只触发一次既有 domain refresh effect")
        expect(
            fixture.session.send(
                .performPlatformAction(.openCalendarPrivacySettings))
                == .platformAction(.performed)
                && fixture.actionRecorder.actions == [.openCalendarPrivacySettings],
            "Calendar privacy 必须经 closed typed platform effect 恰好一次")
    }
    #endif
}
