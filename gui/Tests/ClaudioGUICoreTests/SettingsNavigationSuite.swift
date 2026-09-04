import ClaudioCore
import ClaudioGUICore
import ClaudioLocalization
import Combine
import Foundation

@MainActor
func runSettingsNavigationSuites() {
    suite("Settings destinations：固定身份、顺序与双语名称") {
        let expected: [SettingsDestination] = [
            .general, .integrations, .eventsAndSounds, .notifications, .display, .sounds,
            .usage, .shortcuts, .about,
        ]
        expect(
            SettingsDestination.allCases == expected,
            "设置侧栏必须固定为批准的九项目顺序")
        expect(
            Set(expected.map(\.rawValue)).count == 9,
            "九个设置目的页必须有唯一稳定身份")

        let expectedNames: [(SettingsDestination, String, String)] = [
            (.general, "通用", "General"),
            (.integrations, "集成", "Integrations"),
            (.eventsAndSounds, "事件与提示音", "Events & Sounds"),
            (.notifications, "通知", "Notifications"),
            (.display, "显示", "Display"),
            (.sounds, "声音", "Sounds"),
            (.usage, "用量", "Usage"),
            (.shortcuts, "快捷键", "Shortcuts"),
            (.about, "关于", "About"),
        ]
        for (destination, chinese, english) in expectedNames {
            expect(
                destination.localizedName(language: .zhHans) == chinese,
                "\(destination.rawValue) 必须有稳定简体中文可访问名称")
            expect(
                destination.localizedName(language: .english) == english,
                "\(destination.rawValue) 必须有稳定英文可访问名称")
            expect(
                ClaudioL10nKey.allKnown.contains(destination.localizationKey),
                "\(destination.rawValue) 的名称必须注册进 localization catalog")
        }
    }

    suite("Settings routes：只携带稳定 ID，非法或陈旧目标不回退") {
        let availability = SettingsRouteAvailability(
            integrationSurfaces: [.workBuddy],
            eventScopes: [.global, .surface(.workBuddy)],
            soundScopes: [.global, .surface(.workBuddy)],
            soundPackIDs: ["orbit-pack"],
            events: Set(Event.allCases))

        let generic = SettingsRoute.destination(.display)
        expect(
            resolveSettingsRoute(generic, availability: availability).failure == nil,
            "generic destination 必须直接解析")
        expect(
            generic.stableIdentityComponents == ["display"],
            "generic route 只能携带稳定 ID")

        let integration = SettingsRoute.integrations(surface: .workBuddy)
        expect(
            integration.stableIdentityComponents == ["integrations", "workbuddy"],
            "Integrations 深链接必须携带 HostSurfaceID 而非展示名")
        expect(
            resolveSettingsRoute(integration, availability: availability).failure == nil,
            "已存在 Surface 必须保留 Integrations 深链接")

        let events = SettingsRoute.events(scope: .surface(.workBuddy), event: .notification)
        expect(
            events.stableIdentityComponents
                == ["events-and-sounds", "workbuddy", "notification"],
            "Events 深链接必须携带 Sound Scope 与 Event 稳定 ID")
        expect(
            resolveSettingsRoute(events, availability: availability).failure == nil,
            "已存在 Sound Scope/Event 必须解析")

        let sounds = SettingsRoute.sounds(
            .editEvent(surface: .workBuddy, packID: "orbit-pack", event: .stop))
        expect(
            sounds.stableIdentityComponents
                == ["sounds", "workbuddy", "orbit-pack", "stop"],
            "Sounds 深链接必须携带 scope、pack 与 event 稳定 ID")
        expect(
            resolveSettingsRoute(sounds, availability: availability).failure == nil,
            "已存在声音包深链接必须解析")

        let invalidSurface = resolveSettingsRoute(
            .integrations(surface: .chatGPTDesktopAX),
            availability: availability)
        expect(
            invalidSurface.destination == .integrations,
            "非法 Surface 必须留在集成目的页")
        expect(
            invalidSurface.failure == .invalidSurface(.chatGPTDesktopAX),
            "诊断专用 Surface 不得被当成产品 Surface 或回退")

        let staleSurface = resolveSettingsRoute(
            .events(scope: .surface(.codex), event: .stopFailure),
            availability: availability)
        expect(
            staleSurface.destination == .eventsAndSounds,
            "陈旧 scope 必须留在事件目的页")
        expect(
            staleSurface.failure == .staleSurface(.codex),
            "陈旧事件 scope 不得静默选择 Global 或其他 Surface")

        let stalePack = resolveSettingsRoute(
            .sounds(.editEvent(surface: .workBuddy, packID: "removed-pack", event: .stop)),
            availability: availability)
        expect(stalePack.destination == .sounds, "陈旧 pack 必须留在声音目的页")
        expect(
            stalePack.failure == .staleSoundPack("removed-pack"),
            "陈旧声音包不得静默选择 overview 或其他 pack")

        let staleEventAvailability = SettingsRouteAvailability(
            integrationSurfaces: availability.integrationSurfaces,
            eventScopes: availability.eventScopes,
            soundScopes: availability.soundScopes,
            soundPackIDs: availability.soundPackIDs,
            events: Set(Event.allCases.filter { $0 != .stopFailure }))
        let staleEvent = resolveSettingsRoute(
            .events(scope: .surface(.workBuddy), event: .stopFailure),
            availability: staleEventAvailability)
        expect(
            staleEvent.destination == .eventsAndSounds,
            "陈旧 Event 必须留在事件目的页")
        expect(
            staleEvent.failure == .staleEvent(.stopFailure),
            "陈旧 Event 不得静默选择其他事件")

        let staleSoundEvent = resolveSettingsRoute(
            .sounds(
                .editEvent(
                    surface: .workBuddy,
                    packID: "orbit-pack",
                    event: .stopFailure)),
            availability: staleEventAvailability)
        expect(
            staleSoundEvent.destination == .sounds,
            "声音编辑的陈旧 Event 必须留在声音目的页")
        expect(
            staleSoundEvent.failure == .staleEvent(.stopFailure),
            "声音编辑的陈旧 Event 不得静默选择其他事件")
    }

    suite("Settings Sounds route：只在共享库 fresh ready 后判定陈旧 pack") {
        let route = SettingsRoute.sounds(
            .editEvent(surface: .workBuddy, packID: "delayed-pack", event: .stop))
        let loading = SettingsRouteAvailability(
            integrationSurfaces: [],
            eventScopes: [.global],
            soundScopes: [.global, .surface(.workBuddy)],
            soundPackIDs: [],
            soundPackSnapshotIsFresh: false,
            events: Set(Event.allCases))
        expect(
            resolveSettingsRoute(route, availability: loading).failure == nil,
            "首次 hydration 的空投影不得把仍可能出现的 pack 判成陈旧")

        let readyMissing = SettingsRouteAvailability(
            integrationSurfaces: [],
            eventScopes: [.global],
            soundScopes: [.global, .surface(.workBuddy)],
            soundPackIDs: [],
            soundPackSnapshotIsFresh: true,
            events: Set(Event.allCases))
        expect(
            resolveSettingsRoute(route, availability: readyMissing).failure
                == .staleSoundPack("delayed-pack"),
            "fresh ready 快照确认缺失后必须显示 stale pack 失败")

    }

    suite("Settings sound shell：inactive editor 通过一个 coherent projection 提供 route 事实") {
        withTempDirectory { root in
            let packID = "pack-a"
            let environment = makeAudioImportEnvironment(
                userPacksDirectory: root.appendingPathComponent("packs", isDirectory: true))
            let editor = SoundPacksEditorOwner.stateGalleryFixture(
                previewConfig: ClaudioConfig(selectedPack: packID),
                packCards: [
                    PackCard(
                        id: packID,
                        name: "Pack A",
                        isCC0: true,
                        presentEvents: Set(Event.allCases),
                        state: .complete,
                        isSelected: true)
                ],
                selectedPackID: packID,
                selectedEventRows: [],
                libraryPresentationState: .ready,
                environment: environment,
                activation: nil)
            let hostIntegrations = HostIntegrationPresentationStore(
                state: integrationDestinationTestState(
                    statuses: [.workBuddy: .notConnected]))
            var emissions: [SettingsSoundPackShellProjection] = []
            let cancellable = settingsSoundPackShellProjections(
                editor: editor,
                hostIntegrations: hostIntegrations
            ).sink { emissions.append($0) }

            guard emissions.count == 1, let projection = emissions.first else {
                expect(false, "订阅必须同步交付且只交付一个初始 Settings shell projection")
                return
            }
            let allSurfaceScopes = Set(
                [PanelSoundScopeID.global]
                    + HostID.productVisibleCases.map {
                        PanelSoundScopeID.surface($0.surfaceID)
                    })
            expect(editor.presentation.mode == .inactive, "fixture 必须证明未挂载 Sounds view")
            expect(
                projection.availability.soundPackIDs == [packID]
                    && projection.availability.soundPackSnapshotIsFresh,
                "inactive editor 必须从同一 root 交付 installed identity 与 fresh 事实")
            expect(
                projection.availability.integrationSurfaces
                    == Set(HostID.productVisibleCases.map(\.surfaceID))
                    && projection.availability.eventScopes
                        == [.global, .surface(.claudeCode), .surface(.codex)]
                    && projection.availability.soundScopes == allSurfaceScopes,
                "host rows 必须保留全部 Integrations Surface，只过滤 Events scope")
            expect(
                projection.availability.events == Set(Event.allCases)
                    && projection.pendingAnnouncement == nil,
                "projection 必须提供完整 Event identity，且不得制造 announcement debt")
            expect(
                resolveSettingsRoute(
                    .sounds(.editEvent(surface: nil, packID: packID, event: .stop)),
                    availability: projection.availability
                ).failure == nil,
                "inactive owner 的已安装 pack deep link 必须立即解析")
            expect(
                resolveSettingsRoute(
                    .sounds(.editEvent(surface: nil, packID: "missing", event: .stop)),
                    availability: projection.availability
                ).failure == .staleSoundPack("missing"),
                "只有同一 projection 的 fresh root 才能确认 missing pack 已陈旧")
            withExtendedLifetime(cancellable) {}

            let staleEditor = SoundPacksEditorOwner.stateGalleryFixture(
                previewConfig: ClaudioConfig(selectedPack: packID),
                packCards: [
                    PackCard(
                        id: packID,
                        name: "Previous Pack A",
                        isCC0: true,
                        presentEvents: [.stop],
                        state: .complete,
                        isSelected: true)
                ],
                selectedPackID: packID,
                selectedEventRows: [],
                libraryPresentationState: .refreshFailed(reason: "fixture failure"),
                environment: environment,
                activation: nil)
            var staleProjection: SettingsSoundPackShellProjection?
            let staleCancellable = settingsSoundPackShellProjections(
                editor: staleEditor,
                hostIntegrations: hostIntegrations
            ).sink { staleProjection = $0 }
            expect(
                staleProjection?.availability.soundPackIDs == [packID]
                    && staleProjection?.availability.soundPackSnapshotIsFresh == false,
                "refresh failure 必须保留 previous installed identity，但不能冒充 fresh")
            expect(
                resolveSettingsRoute(
                    .sounds(
                        .editEvent(
                            surface: nil,
                            packID: "still-unknown",
                            event: .stop)),
                    availability: staleProjection?.availability ?? .empty
                ).failure == nil,
                "non-fresh previous 不得永久否定尚未出现的 pack deep link")
            withExtendedLifetime(staleCancellable) {}
        }
    }

    suite("Settings sound shell：无关 editor publication 不重复唤醒订阅") {
        withTempDirectory { root in
            let environment = makeAudioImportEnvironment(
                userPacksDirectory: root.appendingPathComponent("packs", isDirectory: true))
            let editor = SoundPacksEditorOwner.stateGalleryFixture(
                previewConfig: ClaudioConfig(selectedPack: "pack-a"),
                packCards: [
                    PackCard(
                        id: "pack-a",
                        name: "Pack A",
                        isCC0: true,
                        presentEvents: [.stop],
                        state: .complete,
                        isSelected: true)
                ],
                selectedPackID: "pack-a",
                selectedEventRows: [],
                libraryPresentationState: .ready,
                environment: environment,
                activation: nil)
            let hostIntegrations = HostIntegrationPresentationStore(
                state: integrationDestinationTestState())
            var emissions: [SettingsSoundPackShellProjection] = []
            let cancellable = settingsSoundPackShellProjections(
                editor: editor,
                hostIntegrations: hostIntegrations
            ).sink { emissions.append($0) }

            expect(emissions.count == 1, "订阅必须先同步交付初始 projection")
            expect(
                editor.send(.activate(.inactive)) == .applied,
                "fixture 必须触发 revision 改变但不改变 Settings shell 事实")
            expect(
                emissions.count == 1,
                "activity/mode/revision 等无关 editor publication 不得重复唤醒 Settings shell，实得 "
                    + "\(emissions.count) 次")
            withExtendedLifetime(cancellable) {}
        }
    }

    suite("Settings sound shell：host/editor transaction 与 announcement queue 保持同一投影") {
        withTempDirectory { root in
            let packID = "pack-a"
            let environment = makeAudioImportEnvironment(
                userPacksDirectory: root.appendingPathComponent("packs", isDirectory: true))
            let editor = SoundPacksEditorOwner.stateGalleryFixture(
                previewConfig: ClaudioConfig(selectedPack: packID),
                packCards: [
                    PackCard(
                        id: packID,
                        name: "Pack A",
                        isCC0: true,
                        presentEvents: [.stop],
                        state: .complete,
                        isSelected: true)
                ],
                selectedPackID: packID,
                selectedEventRows: [],
                libraryPresentationState: .ready,
                environment: environment,
                activation: nil)
            let hostIntegrations = HostIntegrationPresentationStore(
                state: integrationDestinationTestState())
            var emissions: [SettingsSoundPackShellProjection] = []
            let projectionCancellable = settingsSoundPackShellProjections(
                editor: editor,
                hostIntegrations: hostIntegrations
            ).sink { projection in
                emissions.append(projection)
            }

            expect(
                emissions.count == 1
                    && emissions[0].availability.soundPackIDs == [packID],
                "初始 coherent availability 必须同步投影 editor route facts")

            hostIntegrations.replace(
                state: integrationDestinationTestState(
                    statuses: [.workBuddy: .notConnected]))
            guard emissions.count == 2 else {
                expect(false, "host-only route 事实变化必须只交付一个新 projection")
                return
            }
            let hostOnly = emissions[1]
            expect(
                hostOnly.availability.eventScopes
                    == [.global, .surface(.claudeCode), .surface(.codex)]
                    && hostOnly.availability.soundPackIDs == [packID]
                    && hostOnly.availability.soundPackSnapshotIsFresh
                    && hostOnly.pendingAnnouncement == nil,
                "host-only publication 不得重建或损坏 editor identity/freshness/debt")

            expect(
                editor.send(
                    .activate(
                        .sounds(
                            route: .overview(surface: nil),
                            requestRevision: 132))) == .applied,
                "fixture 必须产生一个 owner semantic announcement head")
            guard let pending = emissions.last?.pendingAnnouncement else {
                expect(false, "editor-only debt 变化必须穿过同一个 shell projection")
                return
            }
            expect(
                emissions.last?.availability == hostOnly.availability,
                "editor-only debt 变化必须保留最新 host-derived availability")
            let countBeforeFailedPost = emissions.count
            expect(
                editor.send(.acknowledgeAnnouncement(id: pending.id, didPost: false)) == .unchanged
                    && editor.presentation.pendingAnnouncement?.id == pending.id
                    && emissions.count == countBeforeFailedPost,
                "native post 失败不得消费 queue head 或制造同义 shell publication")
            expect(
                editor.send(.acknowledgeAnnouncement(id: pending.id, didPost: true)) == .applied
                    && editor.presentation.pendingAnnouncement == nil
                    && emissions.last?.pendingAnnouncement == nil,
                "成功 ack 必须且只能消费 exact queue head，并通过同一 projection 交付")

            editor.publishLibraryStateForTesting(
                .failed(previous: nil, error: .scanFailed(reason: "fixture failure")))
            expect(
                emissions.last?.availability.soundPackIDs.isEmpty == true
                    && emissions.last?.availability.soundPackSnapshotIsFresh == false,
                "一次 owner publication 必须同时交付匹配的新 installed IDs 与 freshness")
            expect(
                !emissions.contains {
                    $0.availability.soundPackIDs.isEmpty
                        && $0.availability.soundPackSnapshotIsFresh
                },
                "订阅不得观察到 old/new 两组 raw publisher 撕裂出的不可能组合")
            withExtendedLifetime(projectionCancellable) {}
        }
    }

    suite("Settings shell：尺寸、单滚动、焦点序、DEBUG gallery 与生产通用页") {
        expect(
            SettingsWindowGeometry.defaultWidth == 1_240
                && SettingsWindowGeometry.defaultHeight == 820,
            "默认窗口尺寸必须匹配批准原型")
        expect(
            SettingsWindowGeometry.minimumWidth == 960
                && SettingsWindowGeometry.minimumHeight == 640,
            "最小窗口尺寸必须匹配批准原型")
        expect(
            settingsSidebarWidth(windowWidth: 960, interfaceTextSize: .standard) == 220
                && settingsSidebarWidth(windowWidth: 1_240, interfaceTextSize: .standard) == 252
                && settingsSidebarWidth(windowWidth: 1_240, interfaceTextSize: .maximum) == 276
                && settingsSidebarWidth(windowWidth: 960, interfaceTextSize: .maximum) == 252,
            "侧栏必须在最小窗口收紧，并为最大文字档保留额外阅读宽度")
        let sidebarSections = settingsSidebarSections(
            availableDestinations: SettingsDestination.allCases)
        expect(
            sidebarSections.map(\.id) == [.primary, .advanced, .product]
                && sidebarSections.flatMap(\.destinations) == SettingsDestination.allCases,
            "侧栏必须按主区、高级、claudi0 分组且保持固定目的页顺序")
        expect(
            settingsSidebarDestination(
                moving: .next,
                from: .usage,
                availableDestinations: SettingsDestination.allCases) == .shortcuts
                && settingsSidebarDestination(
                    moving: .previous,
                    from: .general,
                    availableDestinations: SettingsDestination.allCases) == .general,
            "方向键导航必须跨分组连续，并在首尾停住")
        expect(
            settingsWindowFocusOrder(selectedDestination: .sounds)
                == SettingsDestination.allCases.map(SettingsWindowFocusTarget.sidebar)
                + [.title(.sounds)],
            "Sounds 先走 sidebar 与标题，再把编辑器内焦点交给其独立 route coordinator")
        expect(
            settingsWindowFocusOrder(selectedDestination: .eventsAndSounds)
                == SettingsDestination.allCases.map(SettingsWindowFocusTarget.sidebar)
                + [.title(.eventsAndSounds)],
            "Events 先走 sidebar 与标题，再把精确 scope/Event 焦点交给嵌入页")
        expect(
            settingsWindowFocusOrder(selectedDestination: .general)
                == SettingsDestination.allCases.map(SettingsWindowFocusTarget.sidebar)
                + [.title(.general), .firstAction(.general)],
            "非嵌入目的页必须保留 sidebar、标题、首个动作焦点序")
        expect(
            settingsWindowFocusOrder(selectedDestination: .integrations)
                == SettingsDestination.allCases.map(SettingsWindowFocusTarget.sidebar)
                + [.title(.integrations)],
            "Integrations 的 destination focus coordinator 必须接管标题之后的焦点序")

    }
}
