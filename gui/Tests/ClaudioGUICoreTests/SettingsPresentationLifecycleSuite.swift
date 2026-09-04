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
    suite("Settings executable deletion contract：controller 与 menu 不恢复第二 owner") {
        let root = guiTestRepositoryRoot()
        let controllerURL = root.appendingPathComponent(
            "gui/Sources/ClaudioGUI/SettingsWindowController.swift")
        let navigationURL = root.appendingPathComponent(
            "gui/Sources/ClaudioGUICore/SettingsNavigation.swift")
        let menuBarURL = root.appendingPathComponent(
            "gui/Sources/ClaudioGUI/MenuBarController.swift")
        guard
            let controller = try? String(contentsOf: controllerURL, encoding: .utf8),
            let navigation = try? String(contentsOf: navigationURL, encoding: .utf8),
            let menuBar = try? String(contentsOf: menuBarURL, encoding: .utf8)
        else {
            expect(false, "读不到 Settings controller/navigation/menu composition source")
            return
        }
        let scans = [controller, navigation, menuBar].map(strippingComments)
        guard scans.allSatisfy({ $0.unmodeledConstructs.isEmpty }) else {
            expect(false, "Settings executable source audit 遇到无法建模的构造")
            return
        }
        let controllerCode = scans[0].codeWithoutStringLiterals
        let navigationCode = scans[1].codeWithoutStringLiterals

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
            forbiddenControllerOwners.allSatisfy { !controllerCode.contains($0) },
            "AppKit controller 不得持有 destination model/publisher 或 raw Sound Pack owner")
        expect(
            controllerCode.contains(
                "let content = SettingsRootView(session: settingsPresentationSession)")
                && controllerCode.contains("NSHostingController(rootView: content)")
                && !controllerCode.contains("SettingsWindowView"),
            "唯一 native Settings controller 必须挂 production SettingsRootView(session:)，不得回退旧树")
        expect(
            !navigationCode.contains("SettingsWindowPresentationModel<")
                && !navigationCode.contains("pendingHandback")
                && !navigationCode.contains("SettingsWindowLifecycle")
                && !navigationCode.contains("SettingsWindowPresentation"),
            "ClaudioGUICore 不得恢复旧泛型 handback 或 lifecycle facade")
        let mutation = menuBar.replacingOccurrences(
            of: "let selectedHost = host ?? integrationsModel.selectedHost ?? .claudeCode",
            with:
                "_ = integrationsModel.selectHost(.claudeCode)\n"
                + "        let selectedHost = host ?? integrationsModel.selectedHost ?? .claudeCode"
        )
        expect(
            settingsMenuRequestOwnsOnlyTypedRoute(menuBar)
                && !settingsMenuRequestOwnsOnlyTypedRoute(mutation),
            "MenuBar 只能构造 typed route；Host 选择 mutation 必须由 session 单事务拥有")
    }

    suite("Settings executable gallery：所有场景只经 target-owned production root mount") {
        let galleryURL = guiTestRepositoryRoot().appendingPathComponent(
            "gui/Sources/ClaudioGUI/StateGalleryView.swift")
        guard let gallery = try? String(contentsOf: galleryURL, encoding: .utf8) else {
            expect(false, "读不到 executable StateGalleryView.swift")
            return
        }
        let scanned = strippingComments(gallery)
        guard scanned.unmodeledConstructs.isEmpty else {
            expect(false, "State gallery source audit 遇到无法建模的构造")
            return
        }
        let code = scanned.codeWithoutStringLiterals
        let forbiddenDirectMounts = [
            "EventSettingsWindowView(",
            "EventSettingsAICueServiceCard(",
            "EventSettingsAICueCredentialSheet(",
            "EventSettingsAICueComposerView(",
            "IntegrationsSettingsDestinationView(",
            "EventSettingsWindowSelection(",
            "SoundPacksWindowModel(",
        ]
        expect(
            code.components(separatedBy: "SettingsStateGalleryView(").count - 1 == 1
                && forbiddenDirectMounts.allSatisfy { !code.contains($0) },
            "gallery 必须只组合 target-owned SettingsStateGalleryView，不得直接重建 destination/model")
    }

    suite("Settings native announcement adapter：deferred exact-head post/ack 与 key retry") {
        let controllerURL = guiTestRepositoryRoot().appendingPathComponent(
            "gui/Sources/ClaudioGUI/SettingsWindowController.swift")
        guard let controller = try? String(contentsOf: controllerURL, encoding: .utf8) else {
            expect(false, "读不到唯一 Settings native announcement adapter")
            return
        }
        let missingLatchGuard = controller.replacingOccurrences(
            of: "guard !settingsPresentationAnnouncementDeliveryScheduled else { return }",
            with: "")
        let eagerHeadRead = controller.replacingOccurrences(
            of:
                "settingsPresentationAnnouncementDeliveryScheduled = true\n"
                + "        DispatchQueue.main.async",
            with:
                "settingsPresentationAnnouncementDeliveryScheduled = true\n"
                + "        _ = settingsPresentationSession.state.pendingAnnouncement\n"
                + "        DispatchQueue.main.async")
        let missingKeyGate = controller.replacingOccurrences(
            of: "window.isKeyWindow\n        else { return }",
            with: "true\n        else { return }")
        let missingNativePost = controller.replacingOccurrences(
            of: "NSAccessibility.post(",
            with: "settingsNativePostWasDeleted(")
        let missingKeyRetry = settingsReplacingFirstOccurrence(
            in: controller,
            of:
                "_ = settingsPresentationSession.send(.windowPhaseChanged(.key))\n"
                + "        scheduleSettingsPresentationAnnouncementDelivery()",
            with: "_ = settingsPresentationSession.send(.windowPhaseChanged(.key))")

        expect(
            settingsNativeAnnouncementAdapterIsSound(controller)
                && !settingsNativeAnnouncementAdapterIsSound(missingLatchGuard)
                && !settingsNativeAnnouncementAdapterIsSound(eagerHeadRead)
                && !settingsNativeAnnouncementAdapterIsSound(missingKeyGate)
                && !settingsNativeAnnouncementAdapterIsSound(missingNativePost)
                && !settingsNativeAnnouncementAdapterIsSound(missingKeyRetry),
            "窄 adapter contract 必须 fail closed，并杀死 latch/head/gate/post/key-retry mutations")
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
        let cases:
            [(
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
            let initialHostVisibility = fixture.integrationsModel.isWindowVisible
            let initialHostKeyState = fixture.integrationsModel.isWindowKey
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
                    && fixture.integrationsModel.isWindowVisible == initialHostVisibility
                    && fixture.integrationsModel.isWindowKey == initialHostKeyState
                    && fixture.eventSettingsModel.selectedSurface == initialEventSurface
                    && session.state.eventPresentation == initialEventPresentation
                    && fixture.soundPacksEditor.presentation == initialSoundPresentation
                    && fixture.lastSettingsDestination == initialPreference,
                "\(testCase.failure) 必须保留 requested destination/failure，同时保持 Host/Event/Sound/preference 零 mutation"
            )
        }
    }

    suite("Settings failed route：保留真实 lifecycle owner，后续 success/close 各 cleanup 一次") {
        let availability = SettingsRouteAvailability(
            integrationSurfaces: Set(HostID.productVisibleCases.map(\.surfaceID)),
            eventScopes: [.global],
            soundScopes: [.global],
            soundPackIDs: ["settings-fixture-pack"],
            events: Set(Event.allCases))
        let failedRoute = SettingsRoute.sounds(
            .editEvent(surface: nil, packID: "missing-pack", event: .stop))

        for exitsThroughClose in [false, true] {
            let fixture = SettingsPresentationFixtures.generalLogin(
                route: .events(scope: .global, event: .stop),
                availability: availability)
            fixture.beginEventTransientActivity()
            let beforeFailure = fixture.session.state.eventPresentation
            let soundBeforeFailure = fixture.soundPacksEditor.presentation

            expect(
                fixture.session.send(.route(failedRoute))
                    == .rejected(.staleSoundPack("missing-pack"))
                    && fixture.session.state.activeDestination == .sounds
                    && fixture.session.state.eventPresentation == beforeFailure
                    && fixture.soundPacksEditor.presentation == soundBeforeFailure
                    && fixture.aiCueViewModel.session != nil,
                "failed Sounds request 只能换 presentation failure；不得提前结束真实 Events lifecycle"
            )

            if exitsThroughClose {
                _ = fixture.session.send(.windowWillClose)
            } else {
                _ = fixture.session.send(.route(.destination(.general)))
            }
            let afterExit = fixture.session.state.eventPresentation
            expect(
                afterExit.previewStopRequestRevision
                    == beforeFailure.previewStopRequestRevision + 1
                    && afterExit.aiSessionEndRequestRevision
                        == beforeFailure.aiSessionEndRequestRevision + 1
                    && afterExit.previewState == .idle
                    && afterExit.aiSessionState == .idle
                    && fixture.aiCueViewModel.session == nil
                    && fixture.soundPacksEditor.presentation.mode == .inactive,
                "failed route 后的 \(exitsThroughClose ? "close" : "successful route") 必须恰好一次 cleanup retained Events lifecycle"
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
        let hostingView = NSHostingView(rootView: SettingsRootView(session: fixture.session))
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
        let hostingView = NSHostingView(rootView: SettingsRootView(session: fixture.session))
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
            aiCueViewModel.generation?.id == generation.id,
            "deterministic AI generator 必须先发布当前 generation")
        expect(
            presentation.route
                == EventSettingsWindowRoute(
                    scope: .surface(.workBuddy),
                    event: .stop),
            "AI session emitted route 必须保持当前 Surface/Event")
        expect(
            presentation.eventAccess.first(where: { $0.event == .stop })?.adoptionAvailability
                == .eligible,
            "fixture 的当前 Surface pack/Event 必须先具备 adoption eligibility")
        guard let permit = presentation.adoptionPermit,
            let candidateID = generation.candidates.first?.id
        else {
            expect(
                false,
                "$session/$generation 的 emitted coherent tuple 必须把当前 generation 交给 owner 签 adoption permit"
            )
            return
        }
        let ownerRevision = fixture.soundPacksEditor.presentation.revision
        let eligibility =
            presentation.eventAccess.first(where: { $0.event == .stop })?.adoptionAvailability

        fixture.presentCredentialSheet()

        guard case .events(let credential) = fixture.soundPacksEditor.presentation.mode else {
            expect(false, "credential-only projection 后 shared owner 必须保持 Events presentation")
            return
        }
        expect(
            fixture.session.state.eventPresentation.credentialSheetIsPresented
                && fixture.session.state.eventPresentation.playingCandidateID == nil
                && fixture.soundPacksEditor.presentation.revision == ownerRevision
                && credential.adoptionPermit == permit
                && credential.eventAccess.first(where: { $0.event == .stop })?
                    .adoptionAvailability == eligibility,
            "credential-sheet visibility publication 不得重激活 editor generation context")

        fixture.beginCandidatePreview(id: candidateID)

        guard case .events(let playing) = fixture.soundPacksEditor.presentation.mode else {
            expect(false, "playing-only projection 后 shared owner 必须保持 Events presentation")
            return
        }
        expect(
            fixture.session.state.eventPresentation.credentialSheetIsPresented
                && fixture.session.state.eventPresentation.playingCandidateID == candidateID,
            "credential/playing transient 必须继续发布到 session projection")
        expect(
            fixture.soundPacksEditor.presentation.revision == ownerRevision
                && playing.adoptionPermit == permit
                && playing.eventAccess.first(where: { $0.event == .stop })?.adoptionAvailability
                    == eligibility,
            "credential/playing-only publication 不得重激活 editor 或替换 generation permit")

        fixture.stopCandidatePreview()

        guard case .events(let stopped) = fixture.soundPacksEditor.presentation.mode else {
            expect(false, "停止候选试听后 shared owner 必须保持 Events presentation")
            return
        }
        expect(
            fixture.session.state.eventPresentation.credentialSheetIsPresented
                && fixture.session.state.eventPresentation.playingCandidateID == nil
                && fixture.soundPacksEditor.presentation.revision == ownerRevision
                && stopped.adoptionPermit == permit
                && stopped.eventAccess.first(where: { $0.event == .stop })?.adoptionAvailability
                    == eligibility,
            "preview stop 必须只清 playing transient，并保留原 generation permit identity/eligibility")

        fixture.dismissCredentialSheet()

        guard case .events(let dismissed) = fixture.soundPacksEditor.presentation.mode else {
            expect(false, "关闭 credential sheet 后 shared owner 必须保持 Events presentation")
            return
        }
        expect(
            !fixture.session.state.eventPresentation.credentialSheetIsPresented
                && fixture.session.state.eventPresentation.playingCandidateID == nil
                && fixture.soundPacksEditor.presentation.revision == ownerRevision
                && dismissed.adoptionPermit == permit
                && dismissed.eventAccess.first(where: { $0.event == .stop })?.adoptionAvailability
                    == eligibility,
            "credential dismiss 必须只清 UI transient，并保留原 generation permit identity/eligibility")
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

private func settingsMenuRequestOwnsOnlyTypedRoute(_ source: String) -> Bool {
    let scanned = strippingComments(source)
    guard scanned.unmodeledConstructs.isEmpty,
        let request = settingsLifecycleBracedBlock(
            after: "fileprivate func requestIntegrationsSettingsPresentation(",
            in: scanned.code)
    else { return false }
    return request.contains("host ?? integrationsModel.selectedHost ?? .claudeCode")
        && request.contains(".route(.integrations(surface: selectedHost.surfaceID))")
        && !request.contains("integrationsModel.selectHost")
}

private func settingsNativeAnnouncementAdapterIsSound(_ source: String) -> Bool {
    let scanned = strippingComments(source)
    guard scanned.unmodeledConstructs.isEmpty,
        let scheduler = settingsLifecycleBracedBlock(
            after: "private func scheduleSettingsPresentationAnnouncementDelivery()",
            in: scanned.code),
        let delivery = settingsLifecycleBracedBlock(
            after: "private func deliverPendingSettingsPresentationAnnouncement()",
            in: scanned.code),
        let didBecomeKey = settingsLifecycleBracedBlock(
            after: "func windowDidBecomeKey(",
            in: scanned.code),
        let showWindow = settingsLifecycleBracedBlock(
            after: "func showWindow(",
            in: scanned.code),
        let dispatch = scheduler.range(of: "DispatchQueue.main.async"),
        let latchGuard = scheduler.range(
            of: "guard !settingsPresentationAnnouncementDeliveryScheduled"),
        let latchSet = scheduler.range(
            of: "settingsPresentationAnnouncementDeliveryScheduled = true"),
        let latchClear = scheduler.range(
            of: "settingsPresentationAnnouncementDeliveryScheduled = false"),
        let deliver = scheduler.range(of: "deliverPendingSettingsPresentationAnnouncement()"),
        latchGuard.lowerBound < latchSet.lowerBound,
        latchSet.lowerBound < dispatch.lowerBound,
        dispatch.lowerBound < latchClear.lowerBound,
        latchClear.lowerBound < deliver.lowerBound,
        !scheduler[..<dispatch.lowerBound].contains(
            "settingsPresentationSession.state.pendingAnnouncement"),
        let phaseGate = delivery.range(
            of: "settingsPresentationSession.state.windowPhase == .key"),
        let currentHead = delivery.range(
            of: "settingsPresentationSession.state.pendingAnnouncement"),
        let visibleGate = delivery.range(of: "window.isVisible"),
        let keyGate = delivery.range(of: "window.isKeyWindow"),
        let post = delivery.range(of: "NSAccessibility.post("),
        let exactAck = delivery.range(
            of: ".acknowledgeAnnouncement(id: announcement.id, didPost: true)"),
        phaseGate.lowerBound < currentHead.lowerBound,
        currentHead.lowerBound < visibleGate.lowerBound,
        visibleGate.lowerBound < keyGate.lowerBound,
        keyGate.lowerBound < post.lowerBound,
        post.lowerBound < exactAck.lowerBound
    else { return false }

    return didBecomeKey.contains(".windowPhaseChanged(.key)")
        && didBecomeKey.contains("scheduleSettingsPresentationAnnouncementDelivery()")
        && showWindow.contains("makeKeyAndOrderFront")
        && showWindow.contains("scheduleSettingsPresentationAnnouncementDelivery()")
}

private func settingsReplacingFirstOccurrence(
    in source: String,
    of target: String,
    with replacement: String
) -> String {
    guard let range = source.range(of: target) else { return source }
    var result = source
    result.replaceSubrange(range, with: replacement)
    return result
}
