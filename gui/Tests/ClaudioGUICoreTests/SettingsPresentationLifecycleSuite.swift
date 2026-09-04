import AppKit
import ClaudioCore
import ClaudioGUICore
import ClaudioSettingsPresentation
import Combine
import Foundation
import SoundPacksWindow
import SwiftUI

@MainActor
func runSettingsPresentationLifecycleSuites() async {
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
        let menuBarURL = root.appendingPathComponent(
            "gui/Sources/ClaudioGUI/MenuBarController.swift")
        guard
            let session = try? String(contentsOf: sessionURL, encoding: .utf8),
            let state = try? String(contentsOf: stateURL, encoding: .utf8),
            let rootView = try? String(contentsOf: rootViewURL, encoding: .utf8),
            let controller = try? String(contentsOf: controllerURL, encoding: .utf8),
            let navigation = try? String(contentsOf: navigationURL, encoding: .utf8),
            let menuBar = try? String(contentsOf: menuBarURL, encoding: .utf8)
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
        guard
            let integrationsRequest = settingsLifecycleBracedBlock(
                after: "fileprivate func requestIntegrationsSettingsPresentation(",
                in: menuBar)
        else {
            expect(false, "无法解析 MenuBar Integrations Settings request owner")
            return
        }
        expect(
            integrationsRequest.contains(
                "host ?? integrationsModel.selectedHost ?? .claudeCode")
                && integrationsRequest.contains(
                    ".route(.integrations(surface: selectedHost.surfaceID))")
                && !integrationsRequest.contains("integrationsModel.selectHost"),
            "MenuBar 只能构造 typed route；Host 选择 mutation 必须由 session 单事务拥有")
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

    suite("Settings session rejection：invalid/stale 保留 requested destination 且零 target mutation") {
        let fixture = SettingsPresentationFixtures.generalLogin(
            route: .integrations(surface: .workBuddy),
            availability: PreviewFixtures.settingsRouteAvailability)
        let session = fixture.session
        _ = session.send(.windowPhaseChanged(.key))
        let priorHost = fixture.integrationsModel.selectedHost
        let priorSurface = fixture.eventSettingsModel.selectedSurface
        let priorSoundMode = fixture.soundPacksEditor.presentation.mode
        let firstFailedRoute = SettingsRoute.integrations(surface: .chatGPTDesktopAX)
        let firstFailedRevision = session.state.explicitRouteRequestRevision

        expect(
            session.send(.route(firstFailedRoute))
                == .rejected(.invalidSurface(.chatGPTDesktopAX))
                && session.state.routeResolution
                    == SettingsRouteResolution(
                        route: firstFailedRoute,
                        failure: .invalidSurface(.chatGPTDesktopAX))
                && session.state.activeDestination == .integrations
                && session.state.explicitRouteRequestRevision == firstFailedRevision + 1
                && session.state.focusDebt?.revision == firstFailedRevision + 1
                && session.state.focusDebt?.destination == .integrations
                && fixture.integrationsModel.selectedHost == priorHost
                && fixture.eventSettingsModel.selectedSurface == priorSurface
                && fixture.soundPacksEditor.presentation.mode == priorSoundMode,
            "visible invalid route 必须发布 requested destination/failure/focus，且不得选择失败 Host 或触碰其他 owner"
        )
        let repeatedFailureRevision = session.state.explicitRouteRequestRevision
        expect(
            session.send(.route(firstFailedRoute))
                == .rejected(.invalidSurface(.chatGPTDesktopAX))
                && session.state.routeResolution.route == firstFailedRoute
                && session.state.explicitRouteRequestRevision == repeatedFailureRevision + 1
                && session.state.focusDebt?.revision == repeatedFailureRevision + 1,
            "同一 failed explicit route 每次仍必须形成一个新的可观察 revision/focus debt")

        _ = session.send(.route(.integrations(surface: .workBuddy)))
        _ = session.send(
            .acknowledgeFocus(revision: session.state.explicitRouteRequestRevision))
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

        let staleSoundRoute = SettingsRoute.sounds(
            .editEvent(surface: nil, packID: "missing-pack", event: .stop))
        let staleRevision = session.state.explicitRouteRequestRevision
        expect(
            session.send(.route(staleSoundRoute))
                == .rejected(.staleSoundPack("missing-pack"))
                && session.state.routeResolution
                    == SettingsRouteResolution(
                        route: staleSoundRoute,
                        failure: .staleSoundPack("missing-pack"))
                && session.state.activeDestination == .sounds
                && session.state.explicitRouteRequestRevision == staleRevision + 1
                && session.state.focusDebt?.destination == .sounds
                && fixture.integrationsModel.selectedHost == priorHost
                && fixture.eventSettingsModel.selectedSurface == priorSurface
                && fixture.soundPacksEditor.presentation.mode == priorSoundMode,
            "visible stale deep link 必须挂载 requested Sounds failure，且不得激活 Sound owner")

        _ = session.send(.windowWillClose)
        let invalidWhileClosed = SettingsRoute.sounds(
            .editEvent(surface: nil, packID: "   ", event: .stop))
        let closedRevision = session.state.explicitRouteRequestRevision
        let closedInvalidResult = session.send(.present(.route(invalidWhileClosed)))
        expect(
            closedInvalidResult == .rejected(.invalidSoundPackID)
                && session.state.routeResolution
                    == SettingsRouteResolution(
                        route: invalidWhileClosed,
                        failure: .invalidSoundPackID)
                && session.state.activeDestination == .sounds
                && session.state.windowPhase == .hidden
                && session.state.explicitRouteRequestRevision == closedRevision + 1
                && session.state.focusDebt?.revision == closedRevision + 1
                && session.state.focusDebt?.destination == .sounds
                && fixture.integrationsModel.selectedHost == priorHost
                && fixture.eventSettingsModel.selectedSurface == priorSurface
                && fixture.soundPacksEditor.presentation.mode == priorSoundMode,
            "closed invalid explicit 必须发布 requested Sounds failure/focus，但在 native phase 前保持 hidden 且零 target mutation"
        )
        let repeatedClosedFailureRevision = session.state.explicitRouteRequestRevision
        expect(
            session.send(.present(.route(invalidWhileClosed)))
                == .rejected(.invalidSoundPackID)
                && session.state.explicitRouteRequestRevision
                    == repeatedClosedFailureRevision + 1
                && session.state.focusDebt?.revision == repeatedClosedFailureRevision + 1
                && fixture.integrationsModel.selectedHost == priorHost
                && fixture.eventSettingsModel.selectedSurface == priorSurface
                && fixture.soundPacksEditor.presentation.mode == priorSoundMode,
            "closed phase 的同一 failed explicit route 也必须可重复观察且不触碰 domain owner")

        _ = session.send(.windowWillClose)
        expect(
            session.send(.present(.route(nil))) == .presented(wasAlreadyPresented: false)
                && session.state.routeResolution.route == .destination(.integrations)
                && session.state.activeDestination == .integrations
                && session.state.routeResolution.failure == nil
                && fixture.integrationsModel.selectedHost == priorHost
                && fixture.eventSettingsModel.selectedSurface == priorSurface
                && fixture.soundPacksEditor.presentation.mode == priorSoundMode,
            "failed explicit route 不得写入偏好；下次 generic open 必须恢复最近合法 top-level destination"
        )
    }

    suite("Settings session failure matrix：Surface、scope、pack、Event 均只发布 typed failure") {
        let allSurfaces = Set(HostID.productVisibleCases.map(\.surfaceID))
        let allScopes = Set(
            [PanelSoundScopeID.global]
                + HostID.productVisibleCases.map { .surface($0.surfaceID) })
        let cases: [(
            route: SettingsRoute,
            availability: SettingsRouteAvailability,
            failure: SettingsRouteFailure,
            destination: SettingsDestination
        )] = [
            (
                .integrations(surface: .chatGPTDesktopAX),
                SettingsRouteAvailability(
                    integrationSurfaces: allSurfaces,
                    eventScopes: allScopes,
                    soundScopes: allScopes,
                    soundPackIDs: ["settings-fixture-pack"],
                    events: Set(Event.allCases)),
                .invalidSurface(.chatGPTDesktopAX),
                .integrations
            ),
            (
                .integrations(surface: .workBuddy),
                SettingsRouteAvailability(
                    integrationSurfaces: [],
                    eventScopes: allScopes,
                    soundScopes: allScopes,
                    soundPackIDs: ["settings-fixture-pack"],
                    events: Set(Event.allCases)),
                .staleSurface(.workBuddy),
                .integrations
            ),
            (
                .events(scope: .global, event: .stop),
                SettingsRouteAvailability(
                    integrationSurfaces: allSurfaces,
                    eventScopes: [],
                    soundScopes: allScopes,
                    soundPackIDs: ["settings-fixture-pack"],
                    events: Set(Event.allCases)),
                .staleSoundScope(.global),
                .eventsAndSounds
            ),
            (
                .sounds(
                    .editEvent(
                        surface: nil,
                        packID: "missing-pack",
                        event: .stop)),
                SettingsRouteAvailability(
                    integrationSurfaces: allSurfaces,
                    eventScopes: allScopes,
                    soundScopes: allScopes,
                    soundPackIDs: [],
                    events: Set(Event.allCases)),
                .staleSoundPack("missing-pack"),
                .sounds
            ),
            (
                .sounds(
                    .editEvent(
                        surface: nil,
                        packID: "   ",
                        event: .stop)),
                SettingsRouteAvailability(
                    integrationSurfaces: allSurfaces,
                    eventScopes: allScopes,
                    soundScopes: allScopes,
                    soundPackIDs: ["settings-fixture-pack"],
                    events: Set(Event.allCases)),
                .invalidSoundPackID,
                .sounds
            ),
            (
                .events(scope: .global, event: .stopFailure),
                SettingsRouteAvailability(
                    integrationSurfaces: allSurfaces,
                    eventScopes: allScopes,
                    soundScopes: allScopes,
                    soundPackIDs: ["settings-fixture-pack"],
                    events: Set(Event.allCases).subtracting([.stopFailure])),
                .staleEvent(.stopFailure),
                .eventsAndSounds
            ),
        ]

        for testCase in cases {
            let fixture = SettingsPresentationFixtures.generalLogin(
                route: .destination(.general),
                availability: testCase.availability)
            let session = fixture.session
            let initialHost = fixture.integrationsModel.selectedHost
            let initialEventSurface = fixture.eventSettingsModel.selectedSurface
            let initialEventPresentation = session.state.eventPresentation
            let initialSoundPresentation = fixture.soundPacksEditor.presentation
            let initialPreference = fixture.lastSettingsDestination
            let initialRevision = session.state.explicitRouteRequestRevision

            let result = session.send(.route(testCase.route))
            expect(
                result == .rejected(testCase.failure)
                    && session.state.routeResolution
                        == SettingsRouteResolution(
                            route: testCase.route,
                            failure: testCase.failure)
                    && session.state.activeDestination == testCase.destination
                    && session.state.explicitRouteRequestRevision == initialRevision + 1
                    && session.state.focusDebt?.destination == testCase.destination
                    && fixture.integrationsModel.selectedHost == initialHost
                    && fixture.eventSettingsModel.selectedSurface == initialEventSurface
                    && session.state.eventPresentation == initialEventPresentation
                    && fixture.soundPacksEditor.presentation == initialSoundPresentation
                    && fixture.lastSettingsDestination == initialPreference,
                "\(testCase.failure) 必须保留 requested destination/failure，同时保持 Host/Event/Sound/preference 零 mutation"
            )
        }
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

    suite("Settings mounted root：visible explicit route 必须消费 emitted focus debt") {
        let fixture = SettingsPresentationFixtures.generalLogin(
            route: .destination(.general),
            availability: PreviewFixtures.settingsRouteAvailability)
        let hostingView = NSHostingView(rootView: fixture.rootView)
        hostingView.frame = NSRect(x: 0, y: 0, width: 1_240, height: 820)
        hostingView.layoutSubtreeIfNeeded()
        _ = fixture.session.send(.windowPhaseChanged(.key))
        if let initialDebt = fixture.session.state.focusDebt {
            _ = fixture.session.send(.acknowledgeFocus(revision: initialDebt.revision))
        }

        let priorRevision = fixture.session.state.explicitRouteRequestRevision
        _ = fixture.session.send(.route(.destination(.notifications)))
        hostingView.layoutSubtreeIfNeeded()
        expect(
            fixture.session.state.activeDestination == .notifications
                && fixture.session.state.explicitRouteRequestRevision == priorRevision + 1
                && fixture.session.state.focusDebt == nil,
            "mounted root 必须用 $state emitted value 移交目标焦点并 exact-ack visible route debt")
        withExtendedLifetime(hostingView) {}
    }

    suite("Settings mounted Events：离开 destination 的 preview/AI cleanup 必须恰好一次") {
        let fixture = SettingsPresentationFixtures.generalLogin(
            route: .events(scope: .global, event: .stop),
            availability: PreviewFixtures.settingsRouteAvailability)
        let hostingView = NSHostingView(rootView: fixture.rootView)
        hostingView.frame = NSRect(x: 0, y: 0, width: 1_240, height: 820)
        hostingView.layoutSubtreeIfNeeded()
        fixture.beginEventTransientActivity()
        let before = fixture.session.state.eventPresentation
        var previewStopPublications = 0
        let cancellable = fixture.previewStopRequestRevisions.dropFirst().sink { _ in
            previewStopPublications += 1
        }
        _ = fixture.session.send(.route(.destination(.general)))
        hostingView.layoutSubtreeIfNeeded()
        let after = fixture.session.state.eventPresentation
        expect(
            previewStopPublications == 1
                && after.previewStopRequestRevision == before.previewStopRequestRevision + 1
                && after.aiSessionEndRequestRevision == before.aiSessionEndRequestRevision + 1
                && after.previewState == .idle
                && after.aiSessionState == .idle
                && fixture.aiCueViewModel.session == nil
                && fixture.soundPacksEditor.presentation.mode == .inactive,
            "真实 mounted Events view 必须无递归地恰好一次消费 leave cleanup debt")
        withExtendedLifetime((hostingView, cancellable)) {}
    }

    await suite("Settings Events AI generation：emitted tuple 必须签发当前 candidate adoption permit") {
        let generation = PreviewFixtures.AICueGalleryScenario.candidates.previewState.generation!
        let aiCueViewModel = AICueGenerationViewModel(
            credentialManager: SettingsLifecycleCredentialManager(),
            generator: SettingsLifecycleGenerator(generation: generation),
            providerProfileID: generation.profileID,
            providerPreferences: AICueProviderPreferences(defaults: UserDefaults()))
        let fixture = SettingsPresentationFixtures.generalLogin(
            route: .events(scope: .surface(.workBuddy), event: .stop),
            availability: PreviewFixtures.settingsRouteAvailability,
            aiCueViewModel: aiCueViewModel)
        aiCueViewModel.begin(scope: .surface(.workBuddy), event: .stop)
        aiCueViewModel.updateDescription("short completion cue")
        aiCueViewModel.startGeneration(locale: "en")
        for _ in 0..<200 where aiCueViewModel.generation?.id != generation.id {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }

        guard case .events(let presentation) = fixture.soundPacksEditor.presentation.mode else {
            expect(false, "AI generation 后 shared owner 必须保持 Events presentation")
            return
        }
        expect(
            aiCueViewModel.generation?.id == generation.id
                && presentation.route
                    == EventSettingsWindowRoute(
                        scope: .surface(.workBuddy),
                        event: .stop)
                && presentation.adoptionPermit != nil,
            "$session/$generation 的 emitted coherent tuple 必须把当前 generation 交给 owner 签 adoption permit"
        )
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

private actor SettingsLifecycleCredentialManager: AICueCredentialManaging {
    func status(for _: AICueProviderProfileID) async -> AICueCredentialStatus {
        .stored(verification: .verified, hasPendingReplacement: false)
    }

    func save(
        _: SensitiveCredentialInput,
        for _: AICueProviderProfileID
    ) async throws -> AICueCredentialStatus {
        .stored(verification: .verified, hasPendingReplacement: false)
    }

    func delete(for _: AICueProviderProfileID) async throws {}
    func cancelPendingReplacement(for _: AICueProviderProfileID) async throws {}
}

private actor SettingsLifecycleGenerator: AICueGenerating {
    let generation: AICueGeneration

    init(generation: AICueGeneration) {
        self.generation = generation
    }

    func generate(
        description _: String,
        locale _: String,
        providerProfileID _: AICueProviderProfileID,
        deadline _: AICueGenerationDeadline
    ) async throws -> AICueGeneration {
        generation
    }

    func discard(generationID _: UUID) async {}
    func discardAll() async {}
}

private func settingsLifecycleBracedBlock(after marker: String, in source: String) -> String? {
    guard let markerRange = source.range(of: marker),
        let openingBrace = source[markerRange.upperBound...].firstIndex(of: "{")
    else { return nil }
    var depth = 0
    var index = openingBrace
    while index < source.endIndex {
        switch source[index] {
        case "{":
            depth += 1
        case "}":
            depth -= 1
            if depth == 0 {
                return String(source[openingBrace...index])
            }
        default:
            break
        }
        index = source.index(after: index)
    }
    return nil
}
