import ClaudioCore
import ClaudioGUICore
import ClaudioLocalization
import Combine
import Foundation

private let settingsCharacterizationAvailability = SettingsRouteAvailability(
    integrationSurfaces: [.workBuddy],
    eventScopes: [.global, .surface(.workBuddy)],
    soundScopes: [.global, .surface(.workBuddy)],
    soundPackIDs: ["orbit-pack"],
    events: Set(Event.allCases))

@MainActor
func runSettingsPresentationCharacterizationSuites() {
    suite("Settings characterization：generic 与 explicit 请求形成可重复 route transaction") {
        withSettingsCharacterizationPreferences { preferences, _ in
            preferences.setLastSettingsDestination(.usage)
            let model = SettingsWindowPresentationModel<String>(
                preferences: preferences,
                availability: settingsCharacterizationAvailability)

            let closedGeneric = model.present(handback: "generic.closed")
            expect(
                closedGeneric.resolution.route == .destination(.usage)
                    && closedGeneric.routeRequestRevision == 1,
                "closed generic open 必须恢复最近合法顶层 destination，并产生一次首焦点请求")

            let explicit = SettingsRoute.events(
                scope: .surface(.workBuddy), event: .notification)
            model.request(explicit)
            expect(
                model.resolution.route == explicit
                    && model.routeRequestRevision == 2
                    && preferences.lastSettingsDestination == .eventsAndSounds,
                "explicit route 必须覆盖恢复值，但只持久化它的顶层 destination")

            let revisionBeforeVisibleGeneric = model.routeRequestRevision
            let visibleGeneric = model.present(handback: "generic.visible")
            expect(
                visibleGeneric.resolution.route == explicit
                    && visibleGeneric.routeRequestRevision == revisionBeforeVisibleGeneric,
                "visible generic reopen 必须保留当前 deep link，且不得制造粘滞焦点请求")

            let identical = model.present(
                route: explicit, handback: "explicit.identical")
            expect(
                identical.resolution.route == explicit
                    && identical.routeRequestRevision == revisionBeforeVisibleGeneric + 1,
                "相同 explicit deep link 必须恰好推进一个 focus revision")
            expect(
                model.close() == "explicit.identical" && model.close() == nil,
                "close 必须只消费最近 handback 一次")

            preferences.setLastSettingsDestination(.sounds)
            let reopened = model.present(handback: "generic.reopened")
            expect(
                reopened.resolution.route == .destination(.sounds)
                    && reopened.routeRequestRevision == identical.routeRequestRevision + 1,
                "关闭后的 generic reopen 必须重新读取最近合法顶层 destination")
        }
    }

    suite("Settings characterization：失败 deep link 原位可见且零 preference mutation") {
        withSettingsCharacterizationPreferences { preferences, defaults in
            preferences.setLastSettingsDestination(.display)
            let model = SettingsWindowPresentationModel<String>(
                preferences: preferences,
                availability: settingsCharacterizationAvailability)
            _ = model.present(handback: "failure.matrix")

            let failures: [(SettingsRoute, SettingsRouteFailure, SettingsDestination)] = [
                (
                    .integrations(surface: .chatGPTDesktopAX),
                    .invalidSurface(.chatGPTDesktopAX),
                    .integrations
                ),
                (
                    .events(scope: .surface(.codex), event: .stop),
                    .staleSurface(.codex),
                    .eventsAndSounds
                ),
                (
                    .sounds(
                        .editEvent(
                            surface: .workBuddy,
                            packID: "removed-pack",
                            event: .stop)),
                    .staleSoundPack("removed-pack"),
                    .sounds
                ),
            ]

            for (route, failure, destination) in failures {
                model.request(route)
                expect(
                    model.resolution.route == route
                        && model.resolution.destination == destination
                        && model.resolution.failure == failure,
                    "失败 route 必须保留 exact identity 与对应 destination：\(route)")
                expect(
                    preferences.lastSettingsDestination == .display
                        && defaults.string(forKey: SettingsDestination.defaultsKey) == "display",
                    "失败 route 不得改写 last destination：\(route)")
            }

            model.updateAvailability(
                SettingsRouteAvailability(
                    integrationSurfaces: [.workBuddy],
                    eventScopes: [.global, .surface(.workBuddy)],
                    soundScopes: [.global, .surface(.workBuddy)],
                    soundPackIDs: ["orbit-pack"],
                    events: [.stop]))
            let staleEvent = SettingsRoute.events(scope: .global, event: .notification)
            model.request(staleEvent)
            expect(
                model.resolution.route == staleEvent
                    && model.resolution.failure == .staleEvent(.notification)
                    && preferences.lastSettingsDestination == .display,
                "stale Event 必须留在 Events destination，且不得改写 preference")

            let valid = SettingsRoute.integrations(surface: .workBuddy)
            model.request(valid)
            expect(
                preferences.lastSettingsDestination == .integrations,
                "合法 explicit route 应继续持久化其顶层 destination")

            var focusRevisions: [UInt64] = []
            let cancellable = model.$routeRequestRevision.dropFirst().sink {
                focusRevisions.append($0)
            }
            let revisionBeforeAvailabilityChange = model.routeRequestRevision
            model.updateAvailability(
                SettingsRouteAvailability(
                    integrationSurfaces: [],
                    eventScopes: [.global],
                    soundScopes: [.global],
                    soundPackIDs: [],
                    events: Set(Event.allCases)))
            expect(
                model.resolution.route == valid
                    && model.resolution.failure == .staleSurface(.workBuddy)
                    && preferences.lastSettingsDestination == .integrations,
                "availability 变化只能把当前 route 原位标为 stale，不得改写路由或偏好")
            expect(
                model.routeRequestRevision == revisionBeforeAvailabilityChange
                    && focusRevisions.isEmpty,
                "availability 更新不得冒充 explicit request 或抢焦点")
            withExtendedLifetime(cancellable) {}
        }
    }

    suite("Settings characterization：publisher 暴露 old→new destination transaction") {
        let initial = SettingsRoute.events(scope: .global, event: .stop)
        let model = SettingsWindowPresentationModel<String>(
            initialRoute: initial,
            availability: settingsCharacterizationAvailability)
        var transitions: [String] = []
        let cancellable = model.$resolution.dropFirst().sink { emittedResolution in
            transitions.append(
                "\(model.resolution.destination.rawValue)->"
                    + emittedResolution.destination.rawValue)
        }

        model.request(.integrations(surface: .workBuddy))
        model.request(.destination(.about))
        expect(
            transitions
                == [
                    "events-and-sounds->integrations",
                    "integrations->about",
                ],
            "每次 route transaction 必须只发一次，并让 adapter 先看到旧页、再激活新页")
        withExtendedLifetime(cancellable) {}
    }

    suite("Settings characterization：event shortcut 的未知 raw scope 不获得 Global 写目标") {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let initial = #"{"selected_pack":"orbit-pack","events":{}}"#
            writeFixture(initial, to: configFile)
            let controller = PanelConfigController(
                configFile: configFile,
                lockFile: root.appendingPathComponent("config.lock"),
                environment: makeAudioImportEnvironment(
                    userPacksDirectory: root.appendingPathComponent("packs")))
            let scopes = panelSoundScopePresentations(
                sourceRows: [],
                config: controller.config,
                language: .english)
            let route = globalShortcutEventSettingsRoute(
                storedValue: "future-surface",
                scopes: scopes)
            let writeScope = resolvedEventSettingsScope(route: route, scopes: scopes)
            let bytesBefore = try! Data(contentsOf: configFile)

            if let writeScope {
                controller.selectSoundSurface(writeScope.surface)
                controller.toggleMute(.stop)
            }

            expect(
                route.scope == .global
                    && route.unavailableRequestedScopeStoredValue == "future-surface"
                    && writeScope == nil,
                "未知 raw scope 必须可见失败，但不得把展示用 Global 变成 writable fallback")
            expect(
                try! Data(contentsOf: configFile) == bytesBefore
                    && controller.config.isEnabled(.stop),
                "unavailable event shortcut 必须产生零 Global 配置写入")
        }
    }

    suite("Settings characterization：embedded phase 与 Sounds 公告消费使用同一 active gate") {
        let inactive = settingsEmbeddedDestinationState(
            selectedDestination: .eventsAndSounds,
            embeddedDestination: .sounds,
            windowIsVisible: true,
            windowIsKey: true)
        let hidden = settingsEmbeddedDestinationState(
            selectedDestination: .sounds,
            embeddedDestination: .sounds,
            windowIsVisible: false,
            windowIsKey: true)
        let visibleNonKey = settingsEmbeddedDestinationState(
            selectedDestination: .sounds,
            embeddedDestination: .sounds,
            windowIsVisible: true,
            windowIsKey: false)
        let active = settingsEmbeddedDestinationState(
            selectedDestination: .sounds,
            embeddedDestination: .sounds,
            windowIsVisible: true,
            windowIsKey: true)
        expect(
            inactive == SettingsEmbeddedDestinationState(isVisible: false, isKey: false)
                && hidden == SettingsEmbeddedDestinationState(isVisible: false, isKey: false)
                && visibleNonKey
                    == SettingsEmbeddedDestinationState(isVisible: true, isKey: false)
                && active == SettingsEmbeddedDestinationState(isVisible: true, isKey: true),
            "destination、window visibility 与 key phase 必须共同决定 active presentation")

        var tracker = SoundPacksWindowStatusAnnouncementTracker()
        expect(
            !tracker.beginAttempt(revision: 7, isWindowKey: inactive.isKey)
                && !tracker.beginAttempt(revision: 7, isWindowKey: hidden.isKey)
                && !tracker.beginAttempt(revision: 7, isWindowKey: visibleNonKey.isKey),
            "非 active+visible+key 的 Sounds presentation 不得取得公告代次")
        expect(
            tracker.beginAttempt(revision: 7, isWindowKey: active.isKey),
            "active+visible+key 的 Sounds presentation 必须能取得公告代次")
        tracker.finishAttempt(revision: 7, didPost: false)
        expect(
            tracker.beginAttempt(revision: 7, isWindowKey: active.isKey),
            "bridge 未成功 post 时不得消费公告代次")
        tracker.finishAttempt(revision: 7, didPost: true)
        expect(
            !tracker.beginAttempt(revision: 7, isWindowKey: active.isKey),
            "只有成功 post 才能消费公告代次并阻止重播")
    }
}

@MainActor
private func withSettingsCharacterizationPreferences(
    _ body: (ClaudioPreferences, UserDefaults) -> Void
) {
    let suiteName = "SettingsPresentationCharacterizationSuite.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let preferences = ClaudioPreferences(
        defaults: defaults,
        notificationCenter: NotificationCenter(),
        availableSettingsDestinations: SettingsDestination.allCases,
        preferredLanguageIdentifiers: { ["en-US"] })
    body(preferences, defaults)
}
