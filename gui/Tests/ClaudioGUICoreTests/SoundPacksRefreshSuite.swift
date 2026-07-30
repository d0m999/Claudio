import ClaudioCore
import ClaudioGUICore
import Foundation

private func soundPacksRepoRoot(file: StaticString = #filePath) -> URL {
    URL(fileURLWithPath: "\(file)")
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
}

private func soundPacksSource(_ relativePath: String) -> String? {
    let url = soundPacksRepoRoot().appendingPathComponent(relativePath)
    guard let data = try? Data(contentsOf: url) else { return nil }
    return String(data: data, encoding: .utf8)
}

private func soundPacksCode(_ relativePath: String) -> String? {
    soundPacksSource(relativePath).map { strippingComments($0).code }
}

private func soundPacksFunctionBody(after marker: String, in source: String) -> String? {
    guard let markerRange = source.range(of: marker) else { return nil }
    var depth = 0
    var body = ""
    for character in source[markerRange.upperBound...] {
        if character == "{" {
            depth += 1
            if depth == 1 { continue }
        } else if character == "}" {
            depth -= 1
            if depth == 0 { return body }
        }
        if depth >= 1 { body.append(character) }
    }
    return nil
}

@MainActor
private func soundPacksEnvironment(_ packsDirectory: URL) -> AudioImportEnvironment {
    AudioImportEnvironment(
        userPacksDirectory: packsDirectory,
        bundledPacksDirectory: nil,
        durationProbe: StubDurationProbe(fixedDuration: 1),
        packsLockFile: packsDirectory.deletingLastPathComponent()
            .appendingPathComponent("packs.lock"))
}

@MainActor
func runSoundPacksRefreshSuites() {
    suite("SoundPacksRefreshCoordinator：窗口成功写只发 panel full reload") {
        let coordinator = SoundPacksRefreshCoordinator()

        expect(coordinator.panelReloadRevision == 0, "初始不应欠面板刷新")
        expect(coordinator.windowReloadRevision == 0, "初始不应欠窗口刷新")

        let effect = coordinator.completeWindowWrite(.succeeded)

        expect(effect == .panelFullReload, "窗口成功写必须选择 panel full reload，得到 \(effect)")
        expect(coordinator.panelReloadRevision == 1, "窗口成功写必须发布一次面板刷新")
        expect(coordinator.windowReloadRevision == 0, "窗口自己的写不得伪装成 panel 切包")
    }

    suite("SoundPacksRefreshCoordinator：窗口失败写不发布任何刷新") {
        let coordinator = SoundPacksRefreshCoordinator()

        let effect = coordinator.completeWindowWrite(.failed)

        expect(effect == .none, "失败写没有落盘事实，不得发布刷新，得到 \(effect)")
        expect(coordinator.panelReloadRevision == 0, "失败写不得让面板假装落盘成功")
        expect(coordinator.windowReloadRevision == 0, "失败写不得让窗口假装落盘成功")
    }

    suite("SoundPacksRefreshCoordinator：面板切包仅成功时通知窗口") {
        let coordinator = SoundPacksRefreshCoordinator()

        let failedEffect = coordinator.completePanelPackSwitch(.failed(.lockBusy))
        expect(failedEffect == .none, "失败切包不得刷新窗口，得到 \(failedEffect)")
        expect(coordinator.windowReloadRevision == 0, "失败切包不得推进窗口 revision")

        let succeededEffect = coordinator.completePanelPackSwitch(.succeeded)
        expect(succeededEffect == .windowReload, "成功切包必须通知窗口 reload，得到 \(succeededEffect)")
        expect(coordinator.windowReloadRevision == 1, "成功切包必须推进窗口 revision")
        expect(coordinator.panelReloadRevision == 0, "panel 自己已完成 reload，不得反向再刷一次")
    }

    suite("窗口写后：configOnly 负控保持 stale，full effect 重算真实 PanelConfigController.packCards") {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let packsDirectory = root.appendingPathComponent("packs")
            let manifest = packsDirectory.appendingPathComponent("pack-a/manifest.json")
            writeFixture(
                #"{ "selected_pack": "pack-a", "master_volume": 0.42, "events": {} }"#,
                to: configFile)
            writeFixture(
                #"{ "id": "pack-a", "events": { "stop": "stop.mp3" } }"#,
                to: manifest)
            writeFixture("audio", to: packsDirectory.appendingPathComponent("pack-a/stop.mp3"))

            let coordinator = SoundPacksRefreshCoordinator()
            let panel = PanelConfigController(
                configFile: configFile, lockFile: root.appendingPathComponent("config.lock"),
                environment: soundPacksEnvironment(packsDirectory),
                soundPacksRefreshCoordinator: coordinator)
            let window = SoundPacksWindowModel(
                configFile: configFile,
                environment: soundPacksEnvironment(packsDirectory),
                refreshCoordinator: coordinator)
            expect(
                panel.packCards.first?.presentEvents == [.stop],
                "前提：面板初始卡片只能看见 stop")
            expect(
                window.selectedEventRows.first(where: { $0.event == .stop })?.coverage
                    == .present(fileName: "stop.mp3"),
                "前提：窗口初始也必须从同一份 pack-a manifest 读到 stop")

            // 模拟窗口里的同步 manifest 写已经成功落盘。
            writeFixture(
                #"{ "id": "pack-a", "events": { "stop": "stop.mp3", "notification": "notification.mp3" } }"#,
                to: manifest)
            writeFixture(
                "audio",
                to: packsDirectory.appendingPathComponent("pack-a/notification.mp3"))

            panel.reloadConfigOnly()
            expect(
                panel.packCards.first?.presentEvents == [.stop],
                "负控：selected_pack 未变时 reloadConfigOnly 不重算 packCards，必须保持 stale，"
                    + "否则这条测试没有证明 full 路由的必要性")

            window.completeSynchronousWrite(.succeeded)

            expect(
                panel.packCards.first?.presentEvents == [.stop, .notification],
                "窗口成功写发布的 revision 必须直接触发 PanelConfigController.reload()，让 packCards "
                    + "重读 manifest；得到 \(String(describing: panel.packCards.first?.presentEvents))")
            expect(
                window.selectedEventRows.first(where: { $0.event == .notification })?.coverage
                    == .present(fileName: "notification.mp3"),
                "窗口成功写也必须重读自己的事件映射，不能只刷 popover")
        }
    }

    suite("PanelConfigController.switchPack 返回真实 outcome：成功刷窗口，失败不假刷") {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let packsDirectory = root.appendingPathComponent("packs")
            writeFixture(
                #"{ "selected_pack": "pack-a", "master_volume": 0.42, "events": {} }"#,
                to: configFile)
            writeFixture(
                #"{ "id": "pack-a", "events": {} }"#,
                to: packsDirectory.appendingPathComponent("pack-a/manifest.json"))
            writeFixture(
                #"{ "id": "pack-b", "events": {} }"#,
                to: packsDirectory.appendingPathComponent("pack-b/manifest.json"))

            let panel = PanelConfigController(
                configFile: configFile, lockFile: root.appendingPathComponent("config.lock"),
                environment: soundPacksEnvironment(packsDirectory))
            let coordinator = SoundPacksRefreshCoordinator()

            let failed = panel.switchPack(to: "missing-pack")
            expect(
                coordinator.completePanelPackSwitch(failed) == .none,
                "失败切包的 outcome 不得推进窗口刷新")
            expect(coordinator.windowReloadRevision == 0, "失败切包不得让窗口假装跟随")

            let succeeded = panel.switchPack(to: "pack-b")
            expect(
                coordinator.completePanelPackSwitch(succeeded) == .windowReload,
                "成功切包的 outcome 必须发布窗口刷新")
            expect(coordinator.windowReloadRevision == 1, "成功切包必须恰好推进一次窗口 revision")
            expect(panel.config.selectedPack == "pack-b", "前提：成功 outcome 必须对应真实落盘的 pack-b")
        }
    }

    suite("共享 coordinator：popover 成功切包后窗口模型自动跟随；失败保持原状态") {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let packsDirectory = root.appendingPathComponent("packs")
            writeFixture(
                #"{ "selected_pack": "pack-a", "master_volume": 0.42, "events": {} }"#,
                to: configFile)
            writeFixture(
                #"{ "id": "pack-a", "name": "包 A", "events": { "stop": "stop.mp3" } }"#,
                to: packsDirectory.appendingPathComponent("pack-a/manifest.json"))
            writeFixture("audio", to: packsDirectory.appendingPathComponent("pack-a/stop.mp3"))
            writeFixture(
                #"{ "id": "pack-b", "name": "包 B", "events": { "notification": "notification.mp3" } }"#,
                to: packsDirectory.appendingPathComponent("pack-b/manifest.json"))
            writeFixture(
                "audio",
                to: packsDirectory.appendingPathComponent("pack-b/notification.mp3"))

            let coordinator = SoundPacksRefreshCoordinator()
            let panel = PanelConfigController(
                configFile: configFile, lockFile: root.appendingPathComponent("config.lock"),
                environment: soundPacksEnvironment(packsDirectory))
            let window = SoundPacksWindowModel(
                configFile: configFile,
                environment: soundPacksEnvironment(packsDirectory),
                refreshCoordinator: coordinator)
            expect(window.selectedPackID == "pack-a", "前提：窗口初始跟随 active pack-a")

            coordinator.completePanelPackSwitch(panel.switchPack(to: "missing-pack"))
            expect(window.selectedPackID == "pack-a", "失败切包不得让窗口选择漂移")
            expect(window.config.selectedPack == "pack-a", "失败切包不得让窗口假装 config 已变化")

            coordinator.completePanelPackSwitch(panel.switchPack(to: "pack-b"))
            expect(window.selectedPackID == "pack-b", "成功切包后窗口侧栏选择必须跟随 pack-b")
            expect(window.config.selectedPack == "pack-b", "窗口 config 必须重读为 pack-b")
            expect(
                window.selectedEventRows.first(where: { $0.event == .notification })?.coverage
                    == .present(fileName: "notification.mp3"),
                "窗口主区必须跟着侧栏切到 pack-b 的真实事件映射")
        }
    }

    suite("SoundPacksWindow 是普通 library target，仓库仍只有一个 @main") {
        guard let package = soundPacksCode("gui/Package.swift") else {
            expect(false, "读不到 gui/Package.swift")
            return
        }
        let normalized = package.split(whereSeparator: { $0.isWhitespace }).joined()
        expect(
            normalized.contains(#".target(name:"SoundPacksWindow""#),
            "Package.swift 必须声明普通 .target(name: \"SoundPacksWindow\")")
        expect(
            !normalized.contains(#".executableTarget(name:"SoundPacksWindow""#),
            "SoundPacksWindow 不得是 executableTarget")
        if let appTargetStart = normalized.range(
            of: #".executableTarget(name:"ClaudioGUI""#
        )?.lowerBound,
            let testsTargetStart = normalized.range(
                of: #".executableTarget(name:"claudio-gui-tests""#
            )?.lowerBound
        {
            expect(
                normalized[appTargetStart..<testsTargetStart].contains(#""SoundPacksWindow""#),
                "ClaudioGUI executable target 必须显式依赖 SoundPacksWindow")
        } else {
            expect(false, "Package.swift 必须同时有 ClaudioGUI 与 claudio-gui-tests target")
        }

        let sourcesRoot = soundPacksRepoRoot().appendingPathComponent("gui/Sources")
        let enumerator = FileManager.default.enumerator(atPath: sourcesRoot.path)
        var mainSites: [String] = []
        while let name = enumerator?.nextObject() as? String {
            guard name.hasSuffix(".swift"),
                let code = soundPacksCode("gui/Sources/\(name)")
            else { continue }
            if code.contains("@main") { mainSites.append(name) }
        }
        expect(
            mainSites == ["ClaudioGUI/ClaudioGUIApp.swift"],
            "gui/Sources 下只许 shipping app 有一个 @main，实得 \(mainSites)")
    }

    suite("SoundPacksWindow owner：lazy 单窗口、关闭后复用、全体 MainActor") {
        guard
            let controller = soundPacksCode(
                "gui/Sources/SoundPacksWindow/SoundPacksWindowController.swift"),
            let model = soundPacksCode(
                "gui/Sources/ClaudioGUICore/SoundPacksWindowModel.swift")
        else {
            expect(false, "读不到 SoundPacksWindowController.swift 或 SoundPacksWindowModel.swift")
            return
        }

        expect(controller.contains("@MainActor"), "NSWindow owner 必须显式 @MainActor")
        expect(model.contains("@MainActor"), "窗口 model 必须显式 @MainActor")
        expect(
            controller.contains("private var window: NSWindow?"),
            "owner 必须持有一个 optional NSWindow，按需创建")
        expect(
            controller.contains("window ?? makeWindow()"),
            "showWindow 必须复用已有窗口，不能每点一次管理就 new 一扇")
        expect(
            controller.contains("isReleasedWhenClosed = false"),
            "关闭后 owner 仍保留窗口，下一次复用同一实例")
        expect(
            controller.contains("private var handbackApplication: NSRunningApplication?"),
            "window owner 必须接住 popover 的 previous-app handback 债务")
        expect(
            controller.contains("showWindow(returnFocusTo application: NSRunningApplication?)"),
            "窗口展示入口必须显式接收 handback app，不能在 popover 关闭时把它丢掉")
        guard
            let closeBody = soundPacksFunctionBody(
                after: "public func windowWillClose(_ notification: Notification)", in: controller)
        else {
            expect(false, "SoundPacksWindowController 必须在标准窗口关闭时偿还或清理 handback 债务")
            return
        }
        expect(
            closeBody.contains("handbackApplication = nil"),
            "windowWillClose 必须先清 handback 债务，关闭/重开不得复用陈旧 app")
        expect(
            closeBody.contains("NSApp.isActive"),
            "用户已切到别处时，窗口关闭不得把旧 app 抢回前台")
        expect(
            closeBody.contains("NSApp.yieldActivation(to: previous)")
                && closeBody.contains("NSApp.deactivate()"),
            "windowWillClose 必须覆盖 macOS 14+ cooperative handback 与旧系统 deactivate")
        expect(
            controller.contains("NSWorkspace.didActivateApplicationNotification")
                && controller.contains("[weak self]"),
            "窗口后台停留期间必须弱订阅外部 app 激活，把 handback 更新为最近来源且不成环")
        expect(
            controller.contains("isClosingWindow"),
            "窗口关闭时必须阻止 activation notification 把刚清掉的 handback 债务重新写回")
        expect(
            !controller.contains("Task") && !controller.contains("DispatchQueue")
                && !controller.contains(" async "),
            "窗口 target 不得把 config/manifest 写或刷新丢进 Task/DispatchQueue/async")
    }

    suite(".manageSounds：保留按钮位置/焦点，只把 Finder 动作改为 pending-close 窗口 presentation") {
        guard
            let panel = soundPacksCode("gui/Sources/ClaudioGUI/PanelView.swift"),
            let menu = soundPacksCode("gui/Sources/ClaudioGUI/MenuBarController.swift"),
            let requestBody = soundPacksFunctionBody(
                after: "fileprivate func requestSoundPacksWindowPresentation()", in: menu),
            let closeBody = soundPacksFunctionBody(
                after: "func popoverDidClose(_ notification: Notification)", in: menu)
        else {
            expect(false, "读不到 PanelView/MenuBarController 或切不出窗口 presentation 函数体")
            return
        }

        expect(
            panel.contains("onManageSounds()"),
            "manageSoundsRow 必须调用注入的真窗口入口")
        expect(
            !panel.contains(
                "NSWorkspace.shared.activateFileViewerSelecting([audioEnvironment.userPacksDirectory])"
            ),
            "T7 的 Finder 中间态必须被真窗口替换")
        expect(
            panel.contains(".focused($focusedTarget, equals: .manageSounds)"),
            "T7 的 .manageSounds 焦点契约不得因换动作而丢失")
        expect(
            requestBody.contains("pendingSoundPacksWindowPresentation = true")
                && requestBody.contains("popover.close()"),
            "管理入口必须先记 pending，再强制关闭 transient popover；performClose 可能因 nested "
                + "popover/child window 失败并留下幽灵 pending")
        expect(
            !requestBody.contains("popover.performClose"),
            "自家窗口导航不得用可拒绝的 performClose；失败后没有 didClose 可消费 pending")
        expect(
            closeBody.contains("let previous = previousApp")
                && closeBody.contains("previousApp = nil"),
            "popoverDidClose 必须取出并清掉 previous app，普通关闭偿还、窗口导航则转交")
        if let pendingAt = requestBody.range(
            of: "pendingSoundPacksWindowPresentation = true"
        )?.lowerBound,
            let closeAt = requestBody.range(of: "popover.close()")?.lowerBound
        {
            expect(
                pendingAt < closeAt,
                "管理入口顺序必须是 pending → 强制 close")
        } else {
            expect(false, "管理入口必须同时包含 pending 与强制 close")
        }
        expect(
            closeBody.contains("if shouldPresentSoundPacksWindow")
                && closeBody.contains(
                    "soundPacksWindowController.showWindow(returnFocusTo: previous)"),
            "popover 关闭完成后必须把 previous-app handback 债务转交给单窗口 owner")
        if let showAt = closeBody.range(
            of: "soundPacksWindowController.showWindow(returnFocusTo: previous)"
        )?.lowerBound,
            let returnAt = closeBody[showAt...].range(of: "return")?.lowerBound,
            let handbackGuardAt = closeBody.range(of: "guard NSApp.isActive")?.lowerBound
        {
            expect(
                showAt < returnAt && returnAt < handbackGuardAt,
                "自家窗口 presentation 必须先于 previous-app handback guard 并直接 return")
        } else {
            expect(
                false,
                "didClose 必须同时包含窗口 presentation、直接 return 与 previous-app handback guard")
        }
    }
}
