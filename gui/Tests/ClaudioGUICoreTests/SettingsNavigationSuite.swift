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

    suite("Settings shell：尺寸、单滚动、焦点序、DEBUG gallery 与生产隔离") {
        expect(
            SettingsWindowGeometry.defaultWidth == 1_240
                && SettingsWindowGeometry.defaultHeight == 820,
            "默认窗口尺寸必须匹配批准原型")
        expect(
            SettingsWindowGeometry.minimumWidth == 960
                && SettingsWindowGeometry.minimumHeight == 640,
            "最小窗口尺寸必须匹配批准原型")
        expect(
            settingsWindowFocusOrder(selectedDestination: .sounds)
                == SettingsDestination.allCases.map(SettingsWindowFocusTarget.sidebar)
                    + [.title(.sounds), .firstAction(.sounds)],
            "焦点序必须稳定为全部 sidebar 项、当前标题、首个动作")

        guard
            let controller = settingsSource(
                "gui/Sources/ClaudioGUI/SettingsWindowController.swift"),
            let view = settingsSource("gui/Sources/ClaudioGUI/SettingsWindowView.swift"),
            let gallery = settingsSource("gui/Sources/ClaudioGUI/StateGalleryView.swift"),
            let menuBar = settingsSource("gui/Sources/ClaudioGUI/MenuBarController.swift")
        else {
            expect(false, "缺少 Settings window/shell/gallery/production wiring 源文件")
            return
        }

        expect(
            controller.hasPrefix("#if DEBUG"),
            "统一设置窗口 owner 当前只能进入 DEBUG build")
        expect(
            controller.contains("window ?? makeWindow()"),
            "AppKit owner 必须复用唯一窗口")
        expect(
            controller.contains("window.isReleasedWhenClosed = false"),
            "关闭后不得释放 retained window")
        expect(
            controller.contains("SettingsWindowGeometry.defaultWidth")
                && controller.contains("SettingsWindowGeometry.minimumWidth"),
            "AppKit owner 必须消费同一个默认/最小尺寸合同")
        expect(
            view.components(separatedBy: "ScrollView(").count - 1 == 1,
            "SwiftUI shell 只能有一层主滚动")
        expect(
            view.contains("ForEach(SettingsDestination.allCases)")
                && view.contains("SettingsWindowFocusTarget.title")
                && view.contains("SettingsWindowFocusTarget.firstAction"),
            "shell 必须接线固定 sidebar → 标题 → 首个动作焦点序")
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
            !menuBar.contains("private let settingsWindowController: SettingsWindowController")
                && menuBar.contains("SoundPacksWindowController")
                && menuBar.contains("EventSettingsWindowController")
                && menuBar.contains("IntegrationsWindowController"),
            "production composition 必须保留现有三个窗口入口且不接入半成品设置窗")
    }
}

private func settingsSource(_ relativePath: String) -> String? {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    return try? String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
}
