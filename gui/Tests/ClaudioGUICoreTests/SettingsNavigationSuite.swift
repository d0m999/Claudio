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

        let model = SettingsWindowPresentationModel<String>(
            initialRoute: route,
            availability: loading)
        var focusRevisions: [UInt64] = []
        let cancellable = model.$routeRequestRevision.dropFirst().sink {
            focusRevisions.append($0)
        }
        model.updateAvailability(readyMissing)
        expect(
            model.resolution.failure == .staleSoundPack("delayed-pack"),
            "共享库发布 fresh ready 后 retained route 必须原位重解析")
        expect(
            focusRevisions.isEmpty,
            "后台 availability 更新不得伪造显式路由请求或抢走键盘焦点")
        withExtendedLifetime(cancellable) {}
    }

    suite("Settings lifecycle：显示、覆盖、重复深链接、关闭与一次性 handback") {
        let availability = SettingsRouteAvailability(
            integrationSurfaces: [.workBuddy],
            eventScopes: [.global, .surface(.workBuddy)],
            soundScopes: [.global, .surface(.workBuddy)],
            soundPackIDs: ["orbit-pack"],
            events: Set(Event.allCases))
        var lifecycle = SettingsWindowLifecycle<String>()

        let first = lifecycle.present(availability: availability, handback: "panel.general")
        expect(!first.wasAlreadyPresented, "首次展示必须开启 retained window presentation")
        expect(
            first.resolution.route == .destination(.general),
            "首次无路由展示必须落到通用")
        expect(first.routeRequestRevision == 1, "首次展示必须请求一次标题焦点")

        let repeated = lifecycle.present(availability: availability, handback: "panel.general")
        expect(repeated.wasAlreadyPresented, "重复展示必须识别同一个可见窗口")
        expect(
            repeated.routeRequestRevision == first.routeRequestRevision,
            "无显式路由的重复展示不得制造粘滞焦点请求")

        let route = SettingsRoute.integrations(surface: .workBuddy)
        let override = lifecycle.present(
            route: route,
            availability: availability,
            handback: "panel.integrations")
        expect(override.resolution.route == route, "显式路由必须覆盖当前目的页")
        expect(
            override.routeRequestRevision == first.routeRequestRevision + 1,
            "显式路由必须发出新的焦点请求")

        let sameRoute = lifecycle.present(
            route: route,
            availability: availability,
            handback: "panel.integrations.latest")
        expect(sameRoute.resolution.route == route, "相同深链接必须保持目标")
        expect(
            sameRoute.routeRequestRevision == override.routeRequestRevision + 1,
            "相同深链接重复请求仍必须可被观察")

        expect(
            lifecycle.close() == "panel.integrations.latest",
            "关闭必须归还最近一次明确的焦点债务")
        expect(lifecycle.close() == nil, "同一次关闭不得重复 handback")
        expect(!lifecycle.isPresented, "关闭后 retained owner 必须记录为隐藏")

        let reopened = lifecycle.present(availability: availability, handback: "panel.reopen")
        expect(reopened.resolution.route == route, "关闭后重开必须保留上次目的页")
        expect(
            reopened.routeRequestRevision == sameRoute.routeRequestRevision + 1,
            "隐藏到可见的重开必须重新请求当前标题焦点")
    }

    suite("Settings presentation model：幂等重复展示不发布粘滞焦点") {
        let availability = SettingsRouteAvailability(
            integrationSurfaces: [.workBuddy],
            eventScopes: [.global, .surface(.workBuddy)],
            soundScopes: [.global, .surface(.workBuddy)],
            soundPackIDs: ["orbit-pack"],
            events: Set(Event.allCases))
        let model = SettingsWindowPresentationModel<String>(availability: availability)
        var publishedRevisions: [UInt64] = []
        let cancellable = model.$routeRequestRevision
            .dropFirst()
            .sink { publishedRevisions.append($0) }

        model.present(handback: "panel.general")
        model.present(handback: "panel.general.latest")
        expect(
            publishedRevisions == [1],
            "可见窗口的无路由重复展示不得发布相同 revision 并抢回内容焦点")

        let route = SettingsRoute.integrations(surface: .workBuddy)
        model.present(route: route, handback: "panel.integrations")
        model.present(route: route, handback: "panel.integrations.latest")
        expect(
            publishedRevisions == [1, 2, 3],
            "相同显式深链接每次都必须发布一个新的可观察 revision")
        withExtendedLifetime(cancellable) {}
    }

    suite("Settings presentation model：generic 入口只恢复持久化顶层 destination") {
        let suiteName = "SettingsNavigationSuite.preferences.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = ClaudioPreferences(
            defaults: defaults,
            notificationCenter: NotificationCenter(),
            availableSettingsDestinations: SettingsDestination.allCases,
            preferredLanguageIdentifiers: { ["en-US"] })
        preferences.setLastSettingsDestination(.sounds)

        let availability = SettingsRouteAvailability(
            integrationSurfaces: [.workBuddy],
            eventScopes: [.global, .surface(.workBuddy)],
            soundScopes: [.global, .surface(.workBuddy)],
            soundPackIDs: ["orbit-pack"],
            events: Set(Event.allCases))
        let model = SettingsWindowPresentationModel<String>(
            preferences: preferences,
            availability: availability)
        let generic = model.present(handback: "panel.settings")
        expect(
            generic.resolution.route == .destination(.sounds),
            "generic 设置入口必须恢复上次合法顶层 destination")

        let deepLink = SettingsRoute.integrations(surface: .workBuddy)
        model.request(deepLink)
        expect(model.resolution.route == deepLink, "显式深链接必须在当前展示中保留")
        expect(
            preferences.lastSettingsDestination == .integrations
                && defaults.string(forKey: SettingsDestination.defaultsKey) == "integrations",
            "深链接只能持久化顶层 destination，不得持久化 Surface")
        expect(
            defaults.string(forKey: SettingsDestination.defaultsKey)?.contains("workbuddy")
                == false,
            "持久化 destination 不得包含可能陈旧的 Surface ID")

        _ = model.close()
        let reopened = model.present(handback: "panel.settings.reopen")
        expect(
            reopened.resolution.route == .destination(.integrations),
            "generic 重开必须恢复顶层页，而不是陈旧深链接")
    }

    suite("Settings embedded lifecycle：使用 publisher 新目的页进入/离开 Integrations") {
        let availability = SettingsRouteAvailability(
            integrationSurfaces: [.workBuddy],
            eventScopes: [.global, .surface(.workBuddy)],
            soundScopes: [.global, .surface(.workBuddy)],
            soundPackIDs: [],
            events: Set(Event.allCases))
        let model = SettingsWindowPresentationModel<String>(availability: availability)
        var states: [SettingsEmbeddedDestinationState] = []
        let cancellable = model.$resolution
            .map(\.destination)
            .dropFirst()
            .sink { emittedDestination in
                states.append(
                    settingsEmbeddedDestinationState(
                        selectedDestination: emittedDestination,
                        embeddedDestination: .integrations,
                        windowIsVisible: true,
                        windowIsKey: true))
            }

        model.request(.integrations(surface: .workBuddy))
        model.request(.destination(.general))
        expect(
            states
                == [
                    SettingsEmbeddedDestinationState(isVisible: true, isKey: true),
                    SettingsEmbeddedDestinationState(isVisible: false, isKey: false),
                ],
            "publisher 的新 destination 必须让同一 retained 窗口进入时可见、离开时立即隐藏")
        expect(
            settingsEmbeddedDestinationState(
                selectedDestination: .integrations,
                embeddedDestination: .integrations,
                windowIsVisible: true,
                windowIsKey: false)
                == SettingsEmbeddedDestinationState(isVisible: true, isKey: false),
            "可见但非 key 的 Integrations 必须保留可见事实且关闭公告闸门")
        withExtendedLifetime(cancellable) {}
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
                + [.title(.integrations), .firstAction(.integrations)],
            "Integrations 必须在嵌入 model 前保留 Settings 内部的管理事件动作")

        guard
            let controller = settingsSource(
                "gui/Sources/ClaudioGUI/SettingsWindowController.swift"),
            let soundPacksOwner = settingsSource(
                "gui/Sources/ClaudioGUICore/SoundPacksEditorOwner.swift"),
            let view = settingsSource("gui/Sources/ClaudioGUI/SettingsWindowView.swift"),
            let gallery = settingsSource("gui/Sources/ClaudioGUI/StateGalleryView.swift"),
            let menuBar = settingsSource("gui/Sources/ClaudioGUI/MenuBarController.swift"),
            let app = settingsSource("gui/Sources/ClaudioGUI/ClaudioGUIApp.swift")
        else {
            expect(false, "缺少 Settings window/shell/gallery/production wiring 源文件")
            return
        }

        expect(
            !controller.hasPrefix("#if DEBUG") && !view.hasPrefix("#if DEBUG"),
            "通用设置窗口与真实通用页必须进入 production build")
        expect(
            controller.contains("window ?? makeWindow()"),
            "AppKit owner 必须复用唯一窗口")
        expect(
            controller.contains("window.isReleasedWhenClosed = false"),
            "关闭后不得释放 retained window")
        expect(
            controller.contains("private var isPresentingWindow = false")
                && controller.contains("!isPresentingWindow"),
            "Settings presentation 必须抑制 didBecomeKey 抢在窗口上下文前补播陈旧声音结果")
        if let presenting = controller.range(of: "isPresentingWindow = true")?.lowerBound,
            let modelPresent = controller.range(of: "let presentation = model.present")?.lowerBound,
            let makeKey = controller.range(of: "presentedWindow.makeKeyAndOrderFront")?.lowerBound,
            let announce = controller.range(of: "announceSoundsPresentationIfNeeded")?.lowerBound,
            let presented = controller.range(
                of: "isPresentingWindow = false",
                range: makeKey..<controller.endIndex)?.lowerBound
        {
            expect(
                presenting < modelPresent && modelPresent < makeKey && makeKey < announce
                    && announce < presented,
                "Settings 必须先门闩 didBecomeKey，再按窗口上下文→latest status 排队，最后解除门闩")
        } else {
            expect(false, "Settings showWindow 缺少声音公告 presentation 顺序锚点")
        }
        if let firstPresentationOnly = controller.range(
            of: "if !presentation.wasAlreadyPresented"),
            let announcementDebt = controller.range(of: "// The presentation latch"),
            let announcement = controller.range(of: "announceSoundsPresentationIfNeeded"),
            let presentationEnds = controller.range(
                of: "isPresentingWindow = false",
                range: announcement.lowerBound..<controller.endIndex)
        {
            let firstPresentationBody =
                controller[firstPresentationOnly.lowerBound..<announcementDebt.lowerBound]
            expect(
                firstPresentationBody.contains("makeFirstResponder")
                    && firstPresentationBody.hasSuffix("        }\n        "),
                "首次展示只独占焦点设置；公告必须在条件外覆盖 retained deep link 与重新置前")
            expect(
                announcementDebt.lowerBound < announcement.lowerBound
                    && announcement.lowerBound < presentationEnds.lowerBound,
                "Settings 重新置前必须在解除门闩前补齐 Sounds 上下文与 latest status")
        } else {
            expect(false, "Settings retained presentation 缺少无条件声音公告顺序锚点")
        }
        expect(
            controller.contains("SettingsWindowGeometry.defaultWidth")
                && controller.contains("SettingsWindowGeometry.minimumWidth"),
            "AppKit owner 必须消费同一个默认/最小尺寸合同")
        expect(
            view.components(separatedBy: "ScrollView(").count - 1 == 1,
            "SwiftUI shell 只能保留一层通用主滚动；嵌入编辑器不得再被外层滚动包裹")
        expect(
            view.contains("EmbeddedSoundPacksEditorView(")
                && view.contains("soundPacksEditorOwner")
                && controller.contains("soundPacksEditorOwner.model.$packCards")
                && controller.contains(".combineLatest(")
                && controller.contains("soundPackSnapshotIsFresh: libraryState == .ready"),
            "Sounds destination 必须嵌入完整共享编辑器，并以 shared fresh-ready 快照重解析 route")
        expect(
            view.contains("IntegrationsWindowView(")
                && view.contains("integrationsFocusCoordinator")
                && view.contains("integrationsFocusCoordinator.cancelPendingRequest()")
                && view.contains("settings.integrations.manage-events")
                && view.contains("model.request(.events(scope: .surface(host.surfaceID)")
                && controller.contains("integrationSurfaces: publishedSurfaces")
                && controller.contains("selectedDestination: destination")
                && controller.contains("integrationsModel.noteWindowVisibility(state.isVisible)"),
            "Integrations destination 必须复用完整 model/view、解析 Surface 深链并在窗口内路由 Events")
        expect(
            controller.contains("soundPackSelectionAnnouncementCancellable")
                && controller.contains("soundPackLibraryAnnouncementCancellable")
                && controller.contains("soundPackStatusAnnouncementCancellable")
                && controller.contains("DispatchQueue.main.async { [weak self] in")
                && controller.contains(
                    "destination == .sounds,\n                        !self.isPresentingWindow")
                && controller.contains("model.resolution.destination == .sounds")
                && controller.contains("window.isKeyWindow")
                && controller.contains("SoundPacksWindowAccessibilityBridge.post(")
                && controller.contains(".selectionChanged")
                && controller.contains(".libraryStateChanged")
                && controller.contains("status.severity == .failure")
                && controller.contains("func windowDidBecomeKey")
                && controller.contains("announceLatestSoundPackStatusIfNeeded(in: keyWindow)")
                && controller.contains("soundPacksEditorOwner.beginStatusAnnouncementAttempt(")
                && controller.contains("soundPacksEditorOwner.finishStatusAnnouncementAttempt(")
                && soundPacksOwner.contains("private var statusAnnouncementTracker")
                && soundPacksOwner.contains("shouldAnnounceSelectionChange(to packID:"),
            "唯一 Settings 必须只由实际 key Sounds presentation 播报，并共享 status/suppression 消费")
        expect(
            view.contains("settingsSidebarSections(")
                && view.contains("moveSidebarSelection(")
                && view.contains("SettingsWindowFocusTarget.title")
                && view.contains("SettingsWindowFocusTarget.firstAction"),
            "shell 必须接线分组 sidebar、方向键移动、标题与首个动作焦点序")
        expect(
            view.contains("ForEach(ClaudioLanguageMode.allCases)")
                && view.contains("preferences.setLanguageMode($0)")
                && view.contains("SettingsWindowFocusTarget.firstAction(.general)"),
            "通用页必须呈现三种语言模式并把 Picker 接入首个键盘焦点")
        expect(
            view.contains("settings.general.language")
                && view.contains("settings.general.preference-recovery")
                && view.contains(".accessibilityLabel")
                && view.contains(".accessibilityHint"),
            "通用页的选择器与恢复失败态必须有稳定 AX 接线")
        for forbiddenPreference in ["fullScreenHide", "idleHide", "hiddenStatus"] {
            expect(
                !view.contains(forbiddenPreference),
                "#87 通用页不得提前加入 \(forbiddenPreference)")
        }
        expect(view.contains("Text(\"claudi0\")"), "设置侧栏必须使用产品品牌 claudi0")
        expect(
            view.contains("resolution.failure") && view.contains("SettingsRouteFailure"),
            "非法或陈旧路由必须在对应 route slot 渲染可见失败")
        expect(
            !view.contains("EmptyView") && !view.localizedCaseInsensitiveContains("coming soon"),
            "统一设置骨架不得植入 placeholder destination")
        expect(
            gallery.contains("SettingsWindowRouteGalleryView()")
                && gallery.contains("ForEach(PreviewFixtures.settingsRouteScenarios)")
                && gallery.contains("ForEach(PreviewFixtures.settingsRouteFailureScenarios)"),
            "DEBUG state gallery 必须遍历九个 route slot 与全部可见失败态")
        expect(
            gallery.contains("SettingsExperienceGalleryView()")
                && gallery.contains("ForEach(ClaudioInterfaceTextSize.allCases)")
                && gallery.contains("ForEach(PreviewFixtures.settingsExperienceScenarios)")
                && gallery.contains("experienceScenario: scenario"),
            "基础六页 gallery 必须用 production Settings view 覆盖双语与四档文字")
        expect(
            view.contains("SettingsSectionCard")
                && view.contains("settingsSidebarWidth(")
                && view.contains(".onMoveCommand")
                && view.contains(".onExitCommand")
                && view.contains("onAnnouncement")
                && view.contains("onAnnouncement?(settingsFailureMessage(failure))")
                && view.contains("model.retryFailedOperation()")
                && view.contains("announceFailureIfPresent()"),
            "#100 必须接线共享分组表面、自适应侧栏、键盘 Escape 与可见结果公告")
        expect(
            menuBar.contains("private let settingsWindowController: SettingsWindowController")
                && menuBar.contains("let settingsWindowController = SettingsWindowController(")
                && menuBar.contains("requestSettingsWindowPresentation()")
                && menuBar.contains("let soundPacksEditorOwner = SoundPacksEditorOwner(")
                && menuBar.contains("soundPacksEditorOwner: soundPacksEditorOwner")
                && !menuBar.contains("SoundPacksWindowController")
                && !menuBar.contains("EventSettingsWindowController")
                && menuBar.contains("integrationsModel: integrationsModel")
                && !menuBar.contains(
                    "let integrationsWindowController = IntegrationsWindowController(")
                && menuBar.contains("private var pendingSettingsPresentation:")
                && !menuBar.contains("pendingSoundPacksWindowPresentation")
                && !menuBar.contains("pendingEventSettingsWindowPresentation"),
            "production composition 必须只保留一个 Settings window、一个声音写入 owner 与单一 typed pending")
        expect(
            app.contains("CommandGroup(replacing: .appSettings) {}")
                && !app.contains("keyboardShortcut(\",\", modifiers: .command)"),
            "合成 appSettings 必须移除，popover 激活时不得抢占前台宿主的 Command-comma")
        expect(
            menuBar.contains("func requestSettingsWindowPresentation()")
                && menuBar.contains("case .openSettings:")
                && menuBar.contains("requestSettingsWindowPresentation()"),
            "显式面板入口和用户配置的 Carbon openSettings 仍必须进入 retained Settings")
        expect(
            controller.contains("preferences: preferences")
                && controller.contains("preferences.$snapshot")
                && controller.contains(".map(\\.language)")
                && controller.contains("self?.updateWindowTitle()"),
            "Settings owner 必须共享 typed preferences，并在语言投影变化时只更新窗口标题")
    }
}

private func settingsSource(_ relativePath: String) -> String? {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    return try? String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
}
