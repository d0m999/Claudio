import ClaudioCore
import ClaudioGUICore
import Foundation

private enum SoundPacksInjectedRestoreFailure: Error, Sendable {
    case beforeSalvage
    case beforePublish
}

private final class SoundPacksFailFirstPublish: @unchecked Sendable {
    private let lock = NSLock()
    private var hasFailed = false

    func run() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !hasFailed else { return }
        hasFailed = true
        throw SoundPacksInjectedRestoreFailure.beforePublish
    }
}

private final class SoundPacksFailSelectedPublishCalls: @unchecked Sendable {
    private let lock = NSLock()
    private let failingCalls: Set<Int>
    private var callCount = 0

    init(_ failingCalls: Set<Int>) {
        self.failingCalls = failingCalls
    }

    func run() throws {
        lock.lock()
        defer { lock.unlock() }
        callCount += 1
        if failingCalls.contains(callCount) {
            throw SoundPacksInjectedRestoreFailure.beforePublish
        }
    }
}

private final class SoundPacksForkCollisionInjector: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: Int

    init(count: Int) { remaining = count }

    func occupy(_ destination: URL) {
        lock.lock()
        defer { lock.unlock() }
        guard remaining > 0 else { return }
        remaining -= 1
        try? Data("external-occupier".utf8).write(to: destination)
    }
}

private final class SoundPacksBlockingDurationProbe: AudioDurationProbing, @unchecked Sendable {
    private let entered = DispatchSemaphore(value: 0)
    private let resume = DispatchSemaphore(value: 0)

    func probeDuration(of fileURL: URL) -> TimeInterval? {
        entered.signal()
        resume.wait()
        return 1
    }

    func waitUntilEntered() -> DispatchTimeoutResult {
        entered.wait(timeout: .now() + 5)
    }

    func allowCompletion() { resume.signal() }
}

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
private func soundPacksEnvironment(
    _ packsDirectory: URL,
    factoryPacksDirectory: URL? = nil
) -> AudioImportEnvironment {
    AudioImportEnvironment(
        userPacksDirectory: packsDirectory,
        bundledPacksDirectory: nil,
        factoryPacksDirectory: factoryPacksDirectory,
        durationProbe: StubDurationProbe(fixedDuration: 1),
        packsLockFile: packsDirectory.deletingLastPathComponent()
            .appendingPathComponent("packs.lock"))
}

@MainActor
func runSoundPacksRefreshSuites() async {
    suite("SoundPacksWindow show policy：首开不 reload、隐藏重开 reload、已可见只前置") {
        expect(
            !shouldReloadSoundPacksWindowOnShow(
                wasAlreadyCreated: false, isVisible: false),
            "首次创建的 model init 已完成 hydration，不得立即再 reload")
        expect(
            shouldReloadSoundPacksWindowOnShow(
                wasAlreadyCreated: true, isVisible: false),
            "retained window 隐藏后重开必须重读外部磁盘变化")
        expect(
            !shouldReloadSoundPacksWindowOnShow(
                wasAlreadyCreated: true, isVisible: true),
            "已可见窗口再次 show 不得打断当前详情")

        expect(
            shouldPrepareSoundPacksWindowForPresentation(isVisible: false),
            "隐藏→显示才应设置首焦点并播报 opened")
        expect(
            !shouldPrepareSoundPacksWindowForPresentation(isVisible: true),
            "已可见窗口不得重置焦点或重播 opened")
    }

    suite("SoundPacksRefreshCoordinator：窗口成功写只发 panel full reload") {
        let coordinator = SoundPacksRefreshCoordinator()

        expect(coordinator.panelReloadRevision == 0, "初始不应欠面板刷新")
        expect(coordinator.windowReloadRevision == 0, "初始不应欠窗口刷新")
        expect(coordinator.windowContentReloadRevision == 0, "初始不应欠窗口内容刷新")

        let effect = coordinator.completeWindowWrite(.succeeded)

        expect(effect == .panelFullReload, "窗口成功写必须选择 panel full reload，得到 \(effect)")
        expect(coordinator.panelReloadRevision == 1, "窗口成功写必须发布一次面板刷新")
        expect(
            !coordinator.panelReloadRequiresLibraryRefresh,
            "窗口写入方已负责共享库刷新，面板只能重投影，不能发第二次扫描")
        expect(coordinator.windowReloadRevision == 0, "窗口自己的写不得伪装成 panel 切包")
        expect(coordinator.windowContentReloadRevision == 0, "窗口自己的写不得反向再刷自己")
    }

    suite("SoundPacksRefreshCoordinator：config-only 窗口写只重投影，不要求扫描包库") {
        let coordinator = SoundPacksRefreshCoordinator()

        let effect = coordinator.completeWindowWrite(.succeeded)

        expect(effect == .panelFullReload, "config-only 写仍须让面板重读 config 与投影")
        expect(coordinator.panelReloadRevision == 1, "config-only 写必须发布一次面板刷新")
        expect(
            !coordinator.panelReloadRequiresLibraryRefresh,
            "config-only 写不得附带声音包扫描请求")
    }

    suite("SoundPacksRefreshCoordinator：面板到窗口的 config 与磁盘变化保留扫描语义") {
        let coordinator = SoundPacksRefreshCoordinator()

        coordinator.completePanelPackSwitch(.succeeded)
        expect(
            !coordinator.windowReloadRequiresLibraryRefresh,
            "切包只改 selected_pack，窗口跟随时不得扫描")

        coordinator.completePanelConfigChange(.changed)
        expect(
            !coordinator.windowContentReloadRequiresLibraryRefresh,
            "静音或主音量只改 config，窗口内容刷新不得扫描")

        coordinator.completePanelPackAudioChange(.changed)
        expect(
            coordinator.windowContentReloadRequiresLibraryRefresh,
            "manifest 或音频变化必须要求窗口刷新共享库")
    }

    suite("SoundPacksRefreshCoordinator：窗口失败写不发布任何刷新") {
        let coordinator = SoundPacksRefreshCoordinator()

        let effect = coordinator.completeWindowWrite(.failed)

        expect(effect == .none, "失败写没有落盘事实，不得发布刷新，得到 \(effect)")
        expect(coordinator.panelReloadRevision == 0, "失败写不得让面板假装落盘成功")
        expect(coordinator.windowReloadRevision == 0, "失败写不得让窗口假装落盘成功")
        expect(coordinator.windowContentReloadRevision == 0, "失败写不得发布窗口内容刷新")
    }

    suite("SoundPacksRefreshCoordinator：失败前已改变磁盘仍发布真实 full reload") {
        let coordinator = SoundPacksRefreshCoordinator()

        let effect = coordinator.completeWindowWrite(.changedDespiteFailure)

        expect(effect == .panelFullReload, "部分失败必须让面板重读磁盘真实状态，得到 \(effect)")
        expect(coordinator.panelReloadRevision == 1, "部分失败必须发布一次面板刷新")
        expect(coordinator.windowReloadRevision == 0, "窗口自己的部分失败不得伪装成 panel 切包")
        expect(coordinator.windowContentReloadRevision == 0, "窗口自己的部分失败不得反向再刷自己")
    }

    suite("shared bootstrap 完成：启动前已 hydration 的 PanelConfigController 必须 full reload 新磁盘真相") {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let packsDirectory = root.appendingPathComponent("packs", isDirectory: true)
            let coordinator = SoundPacksRefreshCoordinator()
            let panel = PanelConfigController(
                configFile: configFile,
                lockFile: root.appendingPathComponent("config.lock"),
                environment: soundPacksEnvironment(packsDirectory),
                soundPacksRefreshCoordinator: coordinator)

            expect(panel.configState == .needsPack, "前提：bootstrap 前面板已读到 needsPack")

            writeFixture(
                #"{"selected_pack":"bootstrapped","events":{},"starred_packs":["bootstrapped"]}"#,
                to: configFile)
            writeFixture(
                #"{"id":"bootstrapped","name":"Bootstrap 包","events":{"stop":"stop.mp3"}}"#,
                to: packsDirectory.appendingPathComponent("bootstrapped/manifest.json"))
            writeFixture(
                "audio", to: packsDirectory.appendingPathComponent("bootstrapped/stop.mp3"))

            let effect = coordinator.completeSharedRuntimeBootstrap()

            expect(effect == .panelFullReload, "bootstrap 完成必须选择 panel full reload")
            expect(coordinator.panelReloadRevision == 1, "bootstrap 完成必须发布一次面板刷新")
            expect(
                coordinator.panelReloadRequiresLibraryRefresh,
                "bootstrap 可能创建或修复包，必须刷新共享库")
            expect(panel.config.selectedPack == "bootstrapped", "面板必须重读 bootstrap 创建的默认选择")
            expect(panel.configState.topContent == .events, "面板必须从 needsPack 切到 operational 事件态")
            expect(
                panel.packCards.first?.id == "bootstrapped"
                    && panel.packCards.first?.presentEvents == [.stop],
                "full reload 必须重扫 bootstrap 新增的 pack manifest，而非只重读 config")
            expect(coordinator.windowReloadRevision == 0, "bootstrap 面板刷新不得伪装成 panel 切包")
            expect(
                coordinator.windowContentReloadRevision == 1
                    && !coordinator.windowContentReloadRequiresLibraryRefresh,
                "bootstrap 必须让可能已创建的保留窗口重投影 config，但不重复请求包扫描")
        }
    }

    suite("app activation：保留窗口重投影外部 config，且包扫描由生命周期入口单独负责") {
        let coordinator = SoundPacksRefreshCoordinator()
        let effect = coordinator.refreshWindowConfigProjection()
        expect(effect == .windowReload, "激活必须发布窗口 config projection")
        expect(coordinator.windowContentReloadRevision == 1, "激活必须推进一次内容 revision")
        expect(
            !coordinator.windowContentReloadRequiresLibraryRefresh,
            "config 投影本身不得再附带第二次库扫描")
        expect(coordinator.panelReloadRevision == 0, "激活不应伪造一次窗口写入面板")
    }

    suite("SoundPacksRefreshCoordinator：面板切包仅成功时通知窗口") {
        let coordinator = SoundPacksRefreshCoordinator()

        let failedEffect = coordinator.completePanelPackSwitch(.failed(.lockBusy))
        expect(failedEffect == .none, "失败切包不得刷新窗口，得到 \(failedEffect)")
        expect(coordinator.windowReloadRevision == 0, "失败切包不得推进窗口 revision")

        let succeededEffect = coordinator.completePanelPackSwitch(.succeeded)
        expect(succeededEffect == .windowReload, "成功切包必须通知窗口 reload，得到 \(succeededEffect)")
        expect(coordinator.windowReloadRevision == 1, "成功切包必须推进窗口 revision")
        expect(coordinator.windowContentReloadRevision == 0, "切包不得伪装成普通内容变化")
        expect(coordinator.panelReloadRevision == 0, "panel 自己已完成 reload，不得反向再刷一次")
    }

    suite("SoundPacksRefreshCoordinator：面板包音频真实变化只刷新窗口内容，不强迫侧栏跟随 active pack") {
        let coordinator = SoundPacksRefreshCoordinator()

        expect(
            coordinator.completePanelPackAudioChange(.unchanged) == .none,
            "没有磁盘变化不得发布假刷新")
        expect(coordinator.windowContentReloadRevision == 0, "unchanged 不得推进内容 revision")

        expect(
            coordinator.completePanelPackAudioChange(.changed) == .windowReload,
            "包音频或 manifest 真变化必须通知管理窗口重读")
        expect(coordinator.windowContentReloadRevision == 1, "changed 必须推进内容 revision")
        expect(coordinator.windowReloadRevision == 0, "内容变化不得复用切包 revision")
    }

    suite("SoundPacksRefreshCoordinator：面板 config 真实变化只刷新窗口读模型") {
        let coordinator = SoundPacksRefreshCoordinator()

        expect(
            coordinator.completePanelConfigChange(.unchanged) == .none,
            "没有 config 落盘变化不得发布假刷新")
        expect(coordinator.windowContentReloadRevision == 0, "unchanged 不得推进窗口 revision")

        expect(
            coordinator.completePanelConfigChange(.changed) == .windowReload,
            "master_volume 等非切包 config 变化必须通知管理窗口重读")
        expect(coordinator.windowContentReloadRevision == 1, "config changed 必须推进内容 revision")
        expect(coordinator.windowReloadRevision == 0, "非切包 config 变化不得伪装成 active pack 切换")
        expect(coordinator.panelReloadRevision == 0, "panel 自己已重读，不得反向再刷一次")
    }

    suite("集成取消静音：config-only revision 让保留的声音包窗口重读 enabled") {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let configLock = root.appendingPathComponent("config.lock")
            let packs = root.appendingPathComponent("packs")
            writeFixture(
                #"{ "selected_pack": "pack-a", "events": { "notification": false } }"#,
                to: configFile)
            writeFixture(
                #"{ "id": "pack-a", "events": { "notification": "notification.mp3" } }"#,
                to: packs.appendingPathComponent("pack-a/manifest.json"))
            writeFixture(
                "audio",
                to: packs.appendingPathComponent("pack-a/notification.mp3"))
            let coordinator = SoundPacksRefreshCoordinator()
            let window = SoundPacksWindowModel(
                configFile: configFile,
                lockFile: configLock,
                environment: soundPacksEnvironment(packs),
                refreshCoordinator: coordinator)
            let muteController = EventMuteController(
                configFile: configFile,
                lockFile: configLock)
            expect(
                window.selectedEventRows.first(where: { $0.event == .notification })?.enabled
                    == false,
                "前提：窗口初始必须读到 notification 已静音")

            expect(
                muteController.setEnabled(.notification, enabled: true),
                "集成恢复 seam 必须成功写入逐事件 enabled")
            coordinator.completePanelConfigChange(.changed)

            expect(coordinator.windowContentReloadRevision == 1, "成功写必须发布一次窗口内容刷新")
            expect(
                window.selectedEventRows.first(where: { $0.event == .notification })?.enabled
                    == true,
                "保留窗口必须立即重读 config，VoiceOver 不得继续播报已静音")
            expect(window.selectedPackID == "pack-a", "config-only 刷新不得改变检查中的包")
        }
    }

    suite("窗口写后：configOnly 负控保持 stale，full effect 重算真实 PanelConfigController.packCards") {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let packsDirectory = root.appendingPathComponent("packs")
            let manifest = packsDirectory.appendingPathComponent("pack-a/manifest.json")
            writeFixture(
                #"{ "selected_pack": "pack-a", "master_volume": 0.42, "events": {}, "starred_packs": ["pack-a"] }"#,
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

            let packAError = window.deleteSelectedOrphanAudioFileAfterConfirmation(
                "stop.mp3", expectedPackID: "pack-a")
            guard case .failure(.delete(.stillReferenced)) = packAError else {
                expect(false, "前提：必须先在 pack-a 留下一条音频操作错误，实得 \(packAError)")
                return
            }
            expect(window.audioActionError != nil, "前提：pack-a 音频错误必须留在窗口状态中")

            coordinator.completePanelPackSwitch(panel.switchPack(to: "missing-pack"))
            expect(window.selectedPackID == "pack-a", "失败切包不得让窗口选择漂移")
            expect(window.config.selectedPack == "pack-a", "失败切包不得让窗口假装 config 已变化")
            expect(window.audioActionError != nil, "选择未变化的失败切包不得误清当前包错误")

            coordinator.completePanelPackSwitch(panel.switchPack(to: "pack-b"))
            expect(window.selectedPackID == "pack-b", "成功切包后窗口侧栏选择必须跟随 pack-b")
            expect(window.config.selectedPack == "pack-b", "窗口 config 必须重读为 pack-b")
            expect(window.audioActionError == nil, "跟随到 pack-b 时必须清掉只属于 pack-a 的音频错误")
            expect(
                window.selectedEventRows.first(where: { $0.event == .notification })?.coverage
                    == .present(fileName: "notification.mp3"),
                "窗口主区必须跟着侧栏切到 pack-b 的真实事件映射")
        }
    }

    suite("SoundPacksWindowModel：安全拒删会重读确认期间漂移的音频清单，不发布假写刷新") {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let packsDirectory = root.appendingPathComponent("packs")
            let pack = packsDirectory.appendingPathComponent("pack-a")
            let manifest = pack.appendingPathComponent("manifest.json")
            writeFixture(
                #"{ "selected_pack": "pack-a", "events": {} }"#,
                to: configFile)
            writeFixture(
                #"{ "id": "pack-a", "events": {} }"#,
                to: manifest)
            writeFixture("orphan", to: pack.appendingPathComponent("orphan.mp3"))
            let coordinator = SoundPacksRefreshCoordinator()
            let window = SoundPacksWindowModel(
                configFile: configFile,
                environment: soundPacksEnvironment(packsDirectory),
                refreshCoordinator: coordinator)
            expect(
                window.selectedAudioFiles
                    == [PackAudioFile(fileName: "orphan.mp3", isOrphan: true)],
                "前提：确认前窗口把 orphan.mp3 显示成可删孤儿")

            writeFixture(
                #"{ "id": "pack-a", "events": { "stop": "orphan.mp3" } }"#,
                to: manifest)
            let becameReferenced = window.deleteSelectedOrphanAudioFileAfterConfirmation(
                "orphan.mp3", expectedPackID: "pack-a")

            guard case .failure(.delete(.stillReferenced)) = becameReferenced else {
                expect(false, "确认期间新增引用必须安全拒删，实得 \(becameReferenced)")
                return
            }
            expect(
                window.selectedAudioFiles
                    == [PackAudioFile(fileName: "orphan.mp3", isOrphan: false)],
                "stillReferenced 必须立即重读清单，不能继续把该项显示为可删孤儿")
            expect(
                window.selectedEventRows.first(where: { $0.event == .stop })?.coverage
                    == .present(fileName: "orphan.mp3"),
                "同一次漂移重读必须让窗口事件映射也反映锁内发现的新引用")
            expect(coordinator.panelReloadRevision == 0, "外部漂移后的安全拒删不是本窗口写成功，不得发布刷新")
        }

        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let packsDirectory = root.appendingPathComponent("packs")
            let pack = packsDirectory.appendingPathComponent("pack-a")
            let orphan = pack.appendingPathComponent("orphan.mp3")
            writeFixture(
                #"{ "selected_pack": "pack-a", "events": {} }"#,
                to: configFile)
            writeFixture(
                #"{ "id": "pack-a", "events": {} }"#,
                to: pack.appendingPathComponent("manifest.json"))
            writeFixture("orphan", to: orphan)
            let coordinator = SoundPacksRefreshCoordinator()
            let window = SoundPacksWindowModel(
                configFile: configFile,
                environment: soundPacksEnvironment(packsDirectory),
                refreshCoordinator: coordinator)
            expect(window.selectedAudioFiles.count == 1, "前提：确认前音频清单含 orphan.mp3")

            try? FileManager.default.removeItem(at: orphan)
            let disappeared = window.deleteSelectedOrphanAudioFileAfterConfirmation(
                "orphan.mp3", expectedPackID: "pack-a")

            guard case .failure(.delete(.fileNotFound)) = disappeared else {
                expect(false, "确认期间文件被外部移走必须安全拒删，实得 \(disappeared)")
                return
            }
            expect(
                window.selectedAudioFiles.isEmpty,
                "fileNotFound 必须立即重读清单，让已经消失的孤儿行退出窗口")
            expect(coordinator.panelReloadRevision == 0, "外部移走后的安全拒删不得发布窗口写刷新")
        }

        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let packsDirectory = root.appendingPathComponent("packs")
            let pack = packsDirectory.appendingPathComponent("only-pack")
            writeFixture(
                #"{ "selected_pack": "only-pack", "events": {} }"#,
                to: configFile)
            writeFixture(
                #"{ "id": "only-pack", "events": {} }"#,
                to: pack.appendingPathComponent("manifest.json"))
            writeFixture("orphan", to: pack.appendingPathComponent("orphan.mp3"))
            let coordinator = SoundPacksRefreshCoordinator()
            let window = SoundPacksWindowModel(
                configFile: configFile,
                environment: soundPacksEnvironment(packsDirectory),
                refreshCoordinator: coordinator)

            try? FileManager.default.removeItem(at: pack)
            let disappearedPack = window.deleteSelectedOrphanAudioFileAfterConfirmation(
                "orphan.mp3", expectedPackID: "only-pack")

            guard case .failure(.delete(.packNotFound(packID: "only-pack"))) = disappearedPack
            else {
                expect(false, "确认期间唯一包被外部移走必须以 packNotFound 安全拒删，实得 \(disappearedPack)")
                return
            }
            expect(
                window.packCards.count == 1
                    && window.packCards.first?.availability == .missingSelectedPlaceholder
                    && window.selectedPackID == "only-pack",
                "packNotFound 后必须保留选中且 broken 的缺失包 placeholder")
            expect(
                window.audioActionError?.message.contains("声音包「only-pack」已找不到") == true,
                "即使重读后进入空态，真实拒删原因仍必须留在窗口级错误状态")
            expect(coordinator.panelReloadRevision == 0, "外部移走唯一包后的安全拒删不得发布窗口写刷新")
        }
    }

    suite("SoundPacksWindowModel：分配孤儿复用 T3 bind，刷新事件行/孤儿状态并通知面板") {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let packsDirectory = root.appendingPathComponent("packs")
            let pack = packsDirectory.appendingPathComponent("pack-a")
            writeFixture(
                #"{ "selected_pack": "pack-a", "master_volume": 0.42, "events": {} }"#,
                to: configFile)
            writeFixture(
                #"{ "id": "pack-a", "events": {} }"#,
                to: pack.appendingPathComponent("manifest.json"))
            writeFixture("audio", to: pack.appendingPathComponent("spare.mp3"))

            let coordinator = SoundPacksRefreshCoordinator()
            let environment = soundPacksEnvironment(packsDirectory)
            let panel = PanelConfigController(
                configFile: configFile,
                lockFile: root.appendingPathComponent("config.lock"),
                environment: environment,
                soundPacksRefreshCoordinator: coordinator)
            let window = SoundPacksWindowModel(
                configFile: configFile,
                environment: environment,
                refreshCoordinator: coordinator)
            expect(
                window.selectedAudioFiles
                    == [PackAudioFile(fileName: "spare.mp3", isOrphan: true)],
                "前提：窗口初始应把 spare.mp3 列为孤儿")

            let result = window.assignSelectedAudioFile("spare.mp3", to: .notification)

            if case .failure(let error) = result {
                expect(false, "分配孤儿应成功，实得 \(error)")
            } else {
                expect(true, "分配孤儿成功")
            }
            expect(
                window.selectedEventRows.first(where: { $0.event == .notification })?.coverage
                    == .present(fileName: "spare.mp3"),
                "窗口成功写后 notification 行必须立即转 present")
            expect(
                window.selectedAudioFiles
                    == [PackAudioFile(fileName: "spare.mp3", isOrphan: false)],
                "同一次 reload 必须让 spare.mp3 从孤儿转为已引用")
            expect(
                panel.eventRows.first(where: { $0.event == .notification })?.coverage
                    == .present(fileName: "spare.mp3"),
                "窗口写发布的 panel full reload 必须同步刷新面板事件投影")
            expect(coordinator.panelReloadRevision == 1, "成功分配必须发布一次面板 full reload")
            expect(window.audioActionError == nil, "成功分配必须清掉旧错误")
        }
    }

    suite("T11 双向刷新：面板复用包内音频后，已打开窗口不再保留陈旧孤儿；普通内容刷新不改侧栏选择") {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let packsDirectory = root.appendingPathComponent("packs")
            let packA = packsDirectory.appendingPathComponent("pack-a")
            writeFixture(
                #"{ "selected_pack": "pack-a", "master_volume": 0.42, "events": {} }"#,
                to: configFile)
            writeFixture(
                #"{ "id": "pack-a", "events": {} }"#,
                to: packA.appendingPathComponent("manifest.json"))
            writeFixture("audio", to: packA.appendingPathComponent("spare.mp3"))
            writeFixture(
                #"{ "id": "pack-b", "events": {} }"#,
                to: packsDirectory.appendingPathComponent("pack-b/manifest.json"))

            let coordinator = SoundPacksRefreshCoordinator()
            let environment = soundPacksEnvironment(packsDirectory)
            let window = SoundPacksWindowModel(
                configFile: configFile,
                environment: environment,
                refreshCoordinator: coordinator)
            let row = EventRowImportViewModel(
                event: .notification,
                importViewModel: AudioImportViewModel(packID: "pack-a", environment: environment))
            expect(
                window.selectedAudioFiles
                    == [PackAudioFile(fileName: "spare.mp3", isOrphan: true)],
                "前提：窗口已经打开且仍把 spare.mp3 显示为孤儿")

            row.bindExistingFile("spare.mp3")
            expect(
                window.selectedAudioFiles
                    == [PackAudioFile(fileName: "spare.mp3", isOrphan: true)],
                "负控：只改磁盘、不发协调事件时，保留窗口确实会 stale")

            coordinator.completePanelPackAudioChange(.changed)
            expect(
                window.selectedAudioFiles
                    == [PackAudioFile(fileName: "spare.mp3", isOrphan: false)],
                "面板成功 bind 后的内容 revision 必须让窗口立即重算引用状态")

            window.selectPackForInspection("pack-b")
            coordinator.completePanelPackAudioChange(.changed)
            expect(
                window.selectedPackID == "pack-b",
                "普通音频内容变化只重读当前侧栏项，不得把用户拉回 active pack-a")
        }
    }

    suite("SoundPacksWindowModel：显式确认后的删除刷新孤儿列表；失败删除不假刷新") {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let packsDirectory = root.appendingPathComponent("packs")
            let pack = packsDirectory.appendingPathComponent("pack-a")
            writeFixture(
                #"{ "selected_pack": "pack-a", "master_volume": 0.42, "events": {} }"#,
                to: configFile)
            writeFixture(
                #"{ "id": "pack-a", "events": { "stop": "used.mp3" } }"#,
                to: pack.appendingPathComponent("manifest.json"))
            writeFixture("used", to: pack.appendingPathComponent("used.mp3"))
            writeFixture("orphan", to: pack.appendingPathComponent("orphan.mp3"))

            let coordinator = SoundPacksRefreshCoordinator()
            let window = SoundPacksWindowModel(
                configFile: configFile,
                environment: soundPacksEnvironment(packsDirectory),
                refreshCoordinator: coordinator)

            let staleConfirmation = window.deleteSelectedOrphanAudioFileAfterConfirmation(
                "orphan.mp3", expectedPackID: "previous-pack")
            if case .failure(.selectionChanged) = staleConfirmation {
                expect(true, "陈旧确认被拒绝")
            } else {
                expect(false, "确认后若选择已换包必须拒删，实得 \(staleConfirmation)")
            }
            expect(
                regularFileExists(at: pack.appendingPathComponent("orphan.mp3")),
                "陈旧确认不得删除当前包里的同名文件")
            expect(coordinator.panelReloadRevision == 0, "陈旧确认失败不得发布假刷新")

            let refused = window.deleteSelectedOrphanAudioFileAfterConfirmation(
                "used.mp3", expectedPackID: "pack-a")
            if case .failure(.delete(.stillReferenced(fileName: "used.mp3"))) = refused {
                expect(true, "引用文件拒删原因正确")
            } else {
                expect(false, "引用文件必须以 stillReferenced 拒删，实得 \(refused)")
            }
            expect(coordinator.panelReloadRevision == 0, "失败删除不得发布假刷新")
            expect(window.audioActionError != nil, "失败删除必须留在窗口可见错误表面")

            let deleted = window.deleteSelectedOrphanAudioFileAfterConfirmation(
                "orphan.mp3", expectedPackID: "pack-a")
            if case .failure(let error) = deleted {
                expect(false, "显式确认后的孤儿删除应成功，实得 \(error)")
            } else {
                expect(true, "确认后的孤儿删除成功")
            }
            expect(
                window.selectedAudioFiles
                    == [PackAudioFile(fileName: "used.mp3", isOrphan: false)],
                "成功删除后孤儿行必须从窗口读模型消失")
            expect(coordinator.panelReloadRevision == 1, "成功删除必须发布一次面板 full reload")
            expect(window.audioActionError == nil, "后一次成功必须清掉前一次失败")
        }
    }

    suite("SoundPacksWindowModel：显式确认后的恢复会告知 salvage 路径、重回 CC0，并全量刷新面板") {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let packsDirectory = root.appendingPathComponent("packs")
            let factory = root.appendingPathComponent("factory")
            let installed = packsDirectory.appendingPathComponent("minimal-chime")
            let factoryPack = factory.appendingPathComponent("minimal-chime")
            writeFixture(
                #"{ "selected_pack": "minimal-chime", "master_volume": 0.42, "events": {} }"#,
                to: configFile)
            writeFixture(
                #"{ "id": "minimal-chime", "name": "极简铃音", "license": "CC0-1.0", "events": { "stop": "stop.mp3" } }"#,
                to: factoryPack.appendingPathComponent("manifest.json"))
            writeFixture("factory", to: factoryPack.appendingPathComponent("stop.mp3"))
            writeFixture(
                #"{ "id": "minimal-chime", "name": "已修改", "license": "CC0-1.0", "events": { "stop": "stop.mp3" } }"#,
                to: installed.appendingPathComponent("manifest.json"))
            writeFixture("modified", to: installed.appendingPathComponent("stop.mp3"))
            writeFixture("mine", to: installed.appendingPathComponent("my-extra.wav"))

            let coordinator = SoundPacksRefreshCoordinator()
            let environment = soundPacksEnvironment(
                packsDirectory,
                factoryPacksDirectory: factory)
            let panel = PanelConfigController(
                configFile: configFile,
                lockFile: root.appendingPathComponent("config.lock"),
                environment: environment,
                soundPacksRefreshCoordinator: coordinator)
            let window = SoundPacksWindowModel(
                configFile: configFile,
                environment: environment,
                refreshCoordinator: coordinator)
            expect(
                window.packCards.first?.factoryIntegrity == false
                    && panel.packCards.first?.factoryIntegrity == false,
                "前提：窗口与面板都必须先如实显示内置包已修改")

            let result = window.restoreSelectedFactoryPackAfterConfirmation(
                expectedPackID: "minimal-chime")

            guard case .success(let outcome) = result, let salvaged = outcome.salvaged else {
                expect(false, "确认后的内置包恢复应成功并产生 salvage 告知，实得 \(result)")
                return
            }
            expect(
                window.factoryRestoreNotice == outcome,
                "成功结果必须留在窗口可见告知模型里，不能在 reload 时掉地上")
            let notice = factoryPackRestoreNoticeMessage(outcome)
            expect(
                notice.contains(salvaged.movedTo)
                    && notice.contains("一个文件都没删")
                    && notice.contains("已恢复为出厂版本"),
                "成功告知必须说清替换结果、绝对 salvage 路径与零删除，实得 \(notice)")
            expect(window.factoryRestoreActionError == nil, "成功恢复必须清掉旧恢复错误")
            expect(
                window.packCards.first?.factoryIntegrity == true,
                "窗口必须在写完成后立刻重算 factoryIntegrity")
            expect(
                panel.packCards.first?.factoryIntegrity == true,
                "窗口成功写发布的 full reload 必须让面板也回到 CC0")
            expect(coordinator.panelReloadRevision == 1, "成功恢复必须只发布一次面板 full reload")
            expect(
                (try? String(
                    contentsOf: URL(fileURLWithPath: salvaged.movedTo)
                        .appendingPathComponent("my-extra.wav"),
                    encoding: .utf8)) == "mine",
                "model 告知指向的路径必须真的保存用户自加文件")
        }
    }

    suite("SoundPacksWindowModel：salvage 失败保持原包、显示原包身份且不发布假刷新") {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let packsDirectory = root.appendingPathComponent("packs")
            let factory = root.appendingPathComponent("factory")
            let installed = packsDirectory.appendingPathComponent("minimal-chime")
            writeFixture(
                #"{ "selected_pack": "minimal-chime", "events": {} }"#,
                to: configFile)
            writeFixture(
                #"{ "id": "minimal-chime", "events": {} }"#,
                to: factory.appendingPathComponent("minimal-chime/manifest.json"))
            writeFixture(
                #"{ "id": "minimal-chime", "events": {} }"#,
                to: installed.appendingPathComponent("manifest.json"))
            writeFixture("mine", to: installed.appendingPathComponent("only-user.wav"))
            let coordinator = SoundPacksRefreshCoordinator()
            let environment = AudioImportEnvironment(
                userPacksDirectory: packsDirectory,
                factoryPacksDirectory: factory,
                durationProbe: StubDurationProbe(fixedDuration: 1),
                packsLockFile: injectedPacksLock(besideUserPacks: packsDirectory),
                beforeFactoryPackRestoreSalvage: {
                    throw SoundPacksInjectedRestoreFailure.beforeSalvage
                })
            let window = SoundPacksWindowModel(
                configFile: configFile,
                environment: environment,
                refreshCoordinator: coordinator)

            let failed = window.restoreSelectedFactoryPackAfterConfirmation(
                expectedPackID: "minimal-chime")

            guard
                case .failure(
                    .restore(
                        packID: "minimal-chime",
                        error: .salvageFailed,
                        retainedSalvages: [])) = failed
            else {
                expect(false, "注入的 salvage 失败必须保持结构化错误，实得 \(failed)")
                return
            }
            expect(
                window.factoryRestoreActionError?.message.contains(
                    "声音包「minimal-chime」") == true
                    && window.factoryRestoreActionError?.message.contains(
                        "没有替换任何东西") == true,
                "salvage 失败必须明确归属原包，并说明没有替换")
            expect(
                window.packCards.contains(where: { $0.id == "minimal-chime" })
                    && regularFileExists(
                        at: installed.appendingPathComponent("only-user.wav")),
                "salvage 失败时窗口和磁盘都必须继续保留原包")
            expect(
                window.factoryRestoreNotice == nil
                    && coordinator.panelReloadRevision == 0,
                "salvage 前失败不能伪造成功告知或发布磁盘已变化的假刷新")
        }
    }

    suite("SoundPacksWindowModel：陈旧确认拒绝恢复；publish 失败显示 salvage 路径并刷新磁盘真相") {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let packsDirectory = root.appendingPathComponent("packs")
            let factory = root.appendingPathComponent("factory")
            let installed = packsDirectory.appendingPathComponent("minimal-chime")
            let factoryPack = factory.appendingPathComponent("minimal-chime")
            let fallbackPack = packsDirectory.appendingPathComponent("other-pack")
            let thirdPack = packsDirectory.appendingPathComponent("third-pack")
            writeFixture(
                #"{ "selected_pack": "minimal-chime", "events": {} }"#,
                to: configFile)
            writeFixture(
                #"{ "id": "minimal-chime", "events": {} }"#,
                to: factoryPack.appendingPathComponent("manifest.json"))
            writeFixture(
                #"{ "id": "minimal-chime", "name": "changed", "events": {} }"#,
                to: installed.appendingPathComponent("manifest.json"))
            writeFixture("mine", to: installed.appendingPathComponent("my-extra.wav"))
            writeFixture(
                #"{ "id": "other-pack", "name": "另一个包", "events": {} }"#,
                to: fallbackPack.appendingPathComponent("manifest.json"))
            writeFixture(
                #"{ "id": "third-pack", "name": "第三个包", "events": {} }"#,
                to: thirdPack.appendingPathComponent("manifest.json"))

            let coordinator = SoundPacksRefreshCoordinator()
            let failFirstPublish = SoundPacksFailFirstPublish()
            let environment = AudioImportEnvironment(
                userPacksDirectory: packsDirectory,
                factoryPacksDirectory: factory,
                durationProbe: StubDurationProbe(fixedDuration: 1),
                packsLockFile: injectedPacksLock(besideUserPacks: packsDirectory),
                beforeFactoryPackRestorePublish: {
                    try failFirstPublish.run()
                })
            let window = SoundPacksWindowModel(
                configFile: configFile,
                environment: environment,
                refreshCoordinator: coordinator)

            let stale = window.restoreSelectedFactoryPackAfterConfirmation(
                expectedPackID: "previous-pack")
            if case .failure(.selectionChanged) = stale {
                expect(true, "陈旧恢复确认被拒绝")
            } else {
                expect(false, "确认期间选择变化必须拒绝恢复，实得 \(stale)")
            }
            expect(
                regularFileExists(at: installed.appendingPathComponent("my-extra.wav")),
                "陈旧确认不得搬走当前包")
            expect(coordinator.panelReloadRevision == 0, "陈旧确认失败不得发布刷新")

            let failed = window.restoreSelectedFactoryPackAfterConfirmation(
                expectedPackID: "minimal-chime")
            guard
                case .failure(
                    .restore(
                        packID: "minimal-chime",
                        error: .publishFailed(_, let salvaged?),
                        retainedSalvages: let retainedSalvages)) = failed
            else {
                expect(false, "注入的发布失败必须保持结构化 salvage 结果，实得 \(failed)")
                return
            }
            expect(retainedSalvages == [salvaged], "首次部分失败必须把同一条 salvage 路径带入重试生命周期")
            let message = window.factoryRestoreActionError?.message ?? ""
            expect(
                message.contains(salvaged.movedTo)
                    && message.contains("一个文件都没删")
                    && message.contains("出厂副本未能发布")
                    && message.contains("声音包「minimal-chime」"),
                "失败行必须说清原恢复包、失败、salvage 绝对路径与零删除，不能把提示归到 fallback 包，"
                    + "实得 \(message)")
            expect(window.factoryRestoreNotice == nil, "失败不能同时伪装成成功告知")
            expect(
                window.packCards.first(where: { $0.id == "minimal-chime" })?.availability
                    == .missingSelectedPlaceholder,
                "旧树搬走后必须把 active 路径降级为缺失 placeholder")
            expect(
                window.selectedPackID == "minimal-chime",
                "窗口必须保留 config 的缺失选择，让用户明确恢复或另选")
            expect(
                coordinator.panelReloadRevision == 1,
                "旧树已经搬到 salvage 后，面板必须收到一次 full reload 以显示磁盘真相")
            expect(
                window.factoryRestoreRetryPackID == "minimal-chime",
                "原包已从 availablePacks 消失时，窗口级失败状态必须仍保留可重试的内置包 id")

            // 用户或另一个进程可能在重试前重新创建同名目录。第二次 restore 必须再次
            // salvage 这个新目录，并把两条真实路径一起交给最终的成功告知。
            writeFixture(
                #"{ "id": "minimal-chime", "events": {} }"#,
                to: installed.appendingPathComponent("manifest.json"))
            writeFixture("mine-again", to: installed.appendingPathComponent("second-user.wav"))
            let retried = window.retryFailedFactoryPackRestoreAfterConfirmation(
                expectedPackID: "minimal-chime")
            guard case .success(let retryOutcome) = retried else {
                expect(false, "发布失败后的窗口级重试必须能在没有所选目标卡片时恢复，实得 \(retried)")
                return
            }
            expect(
                retryOutcome.restoredPackID == "minimal-chime"
                    && retryOutcome.salvaged == salvaged
                    && retryOutcome.retainedSalvages.count == 2
                    && retryOutcome.retainedSalvages.first == salvaged
                    && retryOutcome.retainedSalvages[1] != salvaged,
                "重试再次 salvage 时，最终结果必须按顺序保留首次和本次实际搬走的两条路径")
            let secondSalvage = retryOutcome.retainedSalvages[1]
            expect(
                regularFileExists(
                    at: URL(fileURLWithPath: secondSalvage.movedTo)
                        .appendingPathComponent("second-user.wav")),
                "最终告知中的第二条路径必须真的保存重试前重新出现的用户文件")
            expect(
                window.packCards.contains(where: { $0.id == "minimal-chime" }),
                "重试成功后原内置包必须重新进入窗口读模型")
            expect(
                window.factoryRestoreActionError == nil
                    && window.factoryRestoreRetryPackID == nil
                    && window.factoryRestoreNotice == retryOutcome
                    && factoryPackRestoreNoticeMessage(retryOutcome).contains(salvaged.movedTo)
                    && factoryPackRestoreNoticeMessage(retryOutcome).contains(secondSalvage.movedTo),
                "重试成功必须清掉失败/重试入口，并在最终成功告知中显示每次 salvage 路径")
            expect(
                coordinator.panelReloadRevision == 2,
                "首次部分失败与后续重试成功各发布一次真实 full reload")

            window.selectPackForInspection("third-pack")
            expect(
                window.selectedPackID == "third-pack"
                    && window.factoryRestoreActionError == nil,
                "自动 fallback 必须保留并归属原包的失败；用户随后主动切到另一个包时才清掉旧恢复提示")
        }
    }

    suite("SoundPacksWindowModel：恢复重试再次 salvage 后失败仍保留全部路径") {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let packsDirectory = root.appendingPathComponent("packs")
            let factory = root.appendingPathComponent("factory")
            let installed = packsDirectory.appendingPathComponent("minimal-chime")
            writeFixture(
                #"{ "selected_pack": "minimal-chime", "events": {} }"#,
                to: configFile)
            writeFixture(
                #"{ "id": "minimal-chime", "events": {} }"#,
                to: factory.appendingPathComponent("minimal-chime/manifest.json"))
            writeFixture(
                #"{ "id": "minimal-chime", "events": {} }"#,
                to: installed.appendingPathComponent("manifest.json"))
            writeFixture("mine", to: installed.appendingPathComponent("only-user.wav"))
            let coordinator = SoundPacksRefreshCoordinator()
            let environment = AudioImportEnvironment(
                userPacksDirectory: packsDirectory,
                factoryPacksDirectory: factory,
                durationProbe: StubDurationProbe(fixedDuration: 1),
                packsLockFile: injectedPacksLock(besideUserPacks: packsDirectory),
                beforeFactoryPackRestorePublish: {
                    throw SoundPacksInjectedRestoreFailure.beforePublish
                })
            let window = SoundPacksWindowModel(
                configFile: configFile,
                environment: environment,
                refreshCoordinator: coordinator)

            let first = window.restoreSelectedFactoryPackAfterConfirmation(
                expectedPackID: "minimal-chime")
            guard
                case .failure(
                    .restore(
                        packID: "minimal-chime",
                        error: .publishFailed(_, let firstSalvage?),
                        retainedSalvages: let firstRetainedSalvages)) = first
            else {
                expect(false, "首次发布失败必须搬走旧树并返回 salvage，实得 \(first)")
                return
            }
            expect(firstRetainedSalvages == [firstSalvage], "首次失败必须记住实际搬走的目录")
            expect(coordinator.panelReloadRevision == 1, "首次部分失败确实改变活动路径，必须发布一次 full reload")

            writeFixture(
                #"{ "id": "minimal-chime", "events": {} }"#,
                to: installed.appendingPathComponent("manifest.json"))
            writeFixture("mine-again", to: installed.appendingPathComponent("second-user.wav"))
            let retried = window.retryFailedFactoryPackRestoreAfterConfirmation(
                expectedPackID: "minimal-chime")
            guard
                case .failure(
                    .restore(
                        packID: "minimal-chime",
                        error: .publishFailed(_, let secondSalvage?),
                        retainedSalvages: let retainedSalvages)) = retried
            else {
                expect(false, "重试再次 salvage 后发布失败必须保留全部路径，实得 \(retried)")
                return
            }
            expect(
                retainedSalvages == [firstSalvage, secondSalvage]
                    && window.factoryRestoreActionError?.message.contains(firstSalvage.movedTo)
                        == true
                    && window.factoryRestoreActionError?.message.contains(secondSalvage.movedTo)
                        == true,
                "后续失败必须在结构化状态和错误文案中显示每一条 salvage 的绝对路径")
            expect(
                regularFileExists(
                    at: URL(fileURLWithPath: firstSalvage.movedTo)
                        .appendingPathComponent("only-user.wav")),
                "保留的路径必须仍指向含用户文件的首次 salvage 目录")
            expect(
                regularFileExists(
                    at: URL(fileURLWithPath: secondSalvage.movedTo)
                        .appendingPathComponent("second-user.wav")),
                "第二条保留路径必须仍指向重试前重新出现的用户文件")
            expect(
                window.factoryRestoreRetryPackID == "minimal-chime"
                    && window.factoryRestoreNotice == nil,
                "再次失败后必须保留原包重试入口，且不能伪装成成功")
            expect(
                coordinator.panelReloadRevision == 2,
                "重试再次搬走目录后必须发布第二次真实的磁盘变化刷新")
        }
    }

    suite("SoundPacksWindowModel fork：factory bytes、顺序、config/star 零副作用与单次公告 token") {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let packs = root.appendingPathComponent("packs")
            let factory = root.appendingPathComponent("factory")
            let manifest =
                #"{ "id": "builtin", "name": "内置原版", "license": "CC0-1.0", "events": { "stop": "stop.mp3" } }"#
            writeFixture(
                #"{ "selected_pack": "builtin", "events": {}, "starred_packs": ["builtin"] }"#,
                to: configFile)
            writeFixture(manifest, to: factory.appendingPathComponent("builtin/manifest.json"))
            writeFixture("factory-bytes", to: factory.appendingPathComponent("builtin/stop.mp3"))
            writeFixture(
                #"{ "id": "builtin", "name": "用户改过", "license": "CC0-1.0", "events": { "stop": "stop.mp3" } }"#,
                to: packs.appendingPathComponent("builtin/manifest.json"))
            writeFixture("modified-bytes", to: packs.appendingPathComponent("builtin/stop.mp3"))
            let configBytesBefore = try? Data(contentsOf: configFile)
            let coordinator = SoundPacksRefreshCoordinator()
            let model = SoundPacksWindowModel(
                configFile: configFile,
                lockFile: root.appendingPathComponent("config.lock"),
                environment: soundPacksEnvironment(
                    packs, factoryPacksDirectory: factory),
                refreshCoordinator: coordinator)

            let result = model.forkSelectedFactoryPack()
            guard case .success(let outcome) = result else {
                expect(false, "built-in fork should succeed, got \(result)")
                return
            }
            expect(outcome.newPackID == "builtin-copy", "first finite candidate must be -copy")
            expect(model.selectedPackID == "builtin-copy", "reload must precede selecting the new id")
            expect(
                model.consumeSelectionAnnouncementSuppression(for: "builtin-copy"),
                "programmatic fork selection must carry exactly one suppression token")
            expect(
                !model.consumeSelectionAnnouncementSuppression(for: "builtin-copy"),
                "suppression token must be one-shot")
            expect(
                (try? Data(contentsOf: packs.appendingPathComponent("builtin-copy/stop.mp3")))
                    == Data("factory-bytes".utf8),
                "modified installed bytes must never become the fork source")
            expect(
                (try? Data(contentsOf: configFile)) == configBytesBefore,
                "fork must leave config.json byte-for-byte unchanged")
            expect(model.config.selectedPack == "builtin", "fork must not activate the copy")
            expect(model.starredPackIDs == ["builtin"], "fork must not add a star")
            expect(coordinator.panelReloadRevision == 1, "successful fork must publish one panel full reload")
            expect(
                model.windowStatuses.first?.kind == .packFork
                    && model.windowStatuses.first?.message.contains("已创建并选中") == true,
                "compound success must be the visible/VoiceOver status truth")
        }
    }

    suite("SoundPacksWindowModel fork：publish EEXIST 只重试有限次数且不做下一次") {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let packs = root.appendingPathComponent("packs")
            let factory = root.appendingPathComponent("factory")
            writeFixture(#"{ "selected_pack": "builtin", "events": {} }"#, to: configFile)
            writeFixture(
                #"{ "id": "builtin", "events": {} }"#,
                to: packs.appendingPathComponent("builtin/manifest.json"))
            writeFixture(
                #"{ "id": "builtin", "events": {} }"#,
                to: factory.appendingPathComponent("builtin/manifest.json"))
            let injector = SoundPacksForkCollisionInjector(count: 3)
            var environment = soundPacksEnvironment(packs, factoryPacksDirectory: factory)
            environment.beforeForkPackPublish = { injector.occupy($0) }
            let coordinator = SoundPacksRefreshCoordinator()
            let model = SoundPacksWindowModel(
                configFile: configFile,
                lockFile: root.appendingPathComponent("config.lock"),
                environment: environment,
                refreshCoordinator: coordinator)

            let result = model.forkSelectedFactoryPack(maximumPublishCollisions: 3)
            guard case .failure(.destinationAllocationExhausted(let attempts)) = result else {
                expect(false, "three collisions must exhaust exactly, got \(result)")
                return
            }
            expect(attempts == 3, "error must report the actual finite attempt cap")
            let entries = Set((try? FileManager.default.contentsOfDirectory(atPath: packs.path)) ?? [])
            expect(
                entries == ["builtin", "builtin-copy", "builtin-copy-2", "builtin-copy-3"],
                "must preserve exactly three occupiers and create no fourth candidate/staging, got \(entries)")
            expect(coordinator.panelReloadRevision == 0, "collision-only failure changed no Claudio bytes")
        }
    }

    suite("SoundPacksWindowModel route：缺失包明确拒绝且不污染当前检查上下文") {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let packs = root.appendingPathComponent("packs")
            writeFixture(
                #"{ "selected_pack": "pack-a", "events": {} }"#,
                to: configFile)
            writeFixture(
                #"{ "id": "pack-a", "events": { "stop": "stop.mp3" } }"#,
                to: packs.appendingPathComponent("pack-a/manifest.json"))
            writeFixture("audio", to: packs.appendingPathComponent("pack-a/stop.mp3"))
            let model = SoundPacksWindowModel(
                configFile: configFile,
                lockFile: root.appendingPathComponent("config.lock"),
                environment: soundPacksEnvironment(packs),
                refreshCoordinator: SoundPacksRefreshCoordinator())
            let originalRows = model.selectedEventRows

            expect(
                !model.selectPackForInspection("deleted-pack"),
                "路由目标未进入 retained model 时必须明确返回失败")
            expect(model.selectedPackID == "pack-a", "失败选择不得改到其他包")
            expect(model.selectedEventRows == originalRows, "失败选择不得重算成其他包的同名事件")
        }
    }

    suite("SoundPacksWindowModel use：only explicit action changes selected_pack and preserves stars") {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let packs = root.appendingPathComponent("packs")
            writeFixture(
                #"{ "selected_pack": "pack-a", "events": {}, "starred_packs": ["pack-a"] }"#,
                to: configFile)
            for id in ["pack-a", "pack-b"] {
                writeFixture(
                    "{ \"id\": \"\(id)\", \"name\": \"\(id)\", \"events\": {} }",
                    to: packs.appendingPathComponent("\(id)/manifest.json"))
            }
            let coordinator = SoundPacksRefreshCoordinator()
            let model = SoundPacksWindowModel(
                configFile: configFile,
                lockFile: root.appendingPathComponent("config.lock"),
                environment: soundPacksEnvironment(packs),
                refreshCoordinator: coordinator)
            model.selectPackForInspection("pack-b")
            expect(model.config.selectedPack == "pack-a", "inspection alone must not activate pack-b")

            let result = model.useSelectedPack()
            guard case .success(.selected(let packID)) = result else {
                expect(false, "explicit use should succeed, got \(result)")
                return
            }
            expect(packID == "pack-b" && model.config.selectedPack == "pack-b", "use must activate pack-b")
            expect(model.starredPackIDs == ["pack-a"], "use must not mutate starred_packs")
            expect(coordinator.panelReloadRevision == 1, "use must publish one full panel reload")
            expect(
                model.windowStatuses.first?.kind == .packUse
                    && model.windowStatuses.first?.severity == .notice,
                "use success must enter unified status")
        }
    }

    await suite("SoundPacksWindowModel add audio：改选期间按原包落盘但禁止串包反馈与试听") {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "claudio-window-import-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let configFile = root.appendingPathComponent("config.json")
        let packs = root.appendingPathComponent("packs")
        writeFixture(#"{ "selected_pack": "pack-a", "events": {} }"#, to: configFile)
        for id in ["pack-a", "pack-b"] {
            writeFixture(
                "{ \"id\": \"\(id)\", \"name\": \"\(id)\", \"events\": {} }",
                to: packs.appendingPathComponent("\(id)/manifest.json"))
        }
        let source = root.appendingPathComponent("picked.wav")
        try? validWAVData().write(to: source)
        let probe = SoundPacksBlockingDurationProbe()
        let environment = AudioImportEnvironment(
            userPacksDirectory: packs,
            durationProbe: probe,
            packsLockFile: injectedPacksLock(under: root))
        let model = SoundPacksWindowModel(
            configFile: configFile,
            lockFile: root.appendingPathComponent("config.lock"),
            environment: environment,
            refreshCoordinator: SoundPacksRefreshCoordinator())

        let operation = Task {
            await model.importSelectedAudioFiles(
                [AudioImportRequest(sourceURL: source, suggestedFileName: "picked.wav")],
                expectedPackID: "pack-a")
        }
        await Task.yield()
        expect(probe.waitUntilEntered() == .success, "detached import must reach duration probe")
        model.selectPackForInspection("pack-b")
        probe.allowCompletion()
        let result = await operation.value
        guard case .success(let completion) = result else {
            expect(false, "import should complete for original pack, got \(result)")
            return
        }
        expect(completion.completedInBackground, "selection change must mark background completion")
        expect(completion.previewFile == nil, "later-selected pack must never preview pack-a audio")
        expect(model.selectedPackID == "pack-b", "completion must not pull inspection back to pack-a")
        expect(
            FileManager.default.fileExists(
                atPath: packs.appendingPathComponent("pack-a/picked.wav").path),
            "bytes must still land in the pack that started the action")
        expect(
            model.windowStatuses.first?.message.contains("后台操作") == true
                && model.windowStatuses.first?.message.contains("pack-a") == true,
            "global result must explicitly name the real background target")
    }

    await suite("SoundPacksWindowModel add audio：A→B→A 不得重新继承旧操作的前台身份") {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "claudio-window-import-aba-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let configFile = root.appendingPathComponent("config.json")
        let packs = root.appendingPathComponent("packs")
        writeFixture(#"{ "selected_pack": "pack-a", "events": {} }"#, to: configFile)
        for id in ["pack-a", "pack-b"] {
            writeFixture(
                "{ \"id\": \"\(id)\", \"name\": \"\(id)\", \"events\": {} }",
                to: packs.appendingPathComponent("\(id)/manifest.json"))
        }
        let source = root.appendingPathComponent("picked.wav")
        try? validWAVData().write(to: source)
        let probe = SoundPacksBlockingDurationProbe()
        let model = SoundPacksWindowModel(
            configFile: configFile,
            lockFile: root.appendingPathComponent("config.lock"),
            environment: AudioImportEnvironment(
                userPacksDirectory: packs,
                durationProbe: probe,
                packsLockFile: injectedPacksLock(under: root)),
            refreshCoordinator: SoundPacksRefreshCoordinator())

        let operation = Task {
            await model.importSelectedAudioFiles(
                [AudioImportRequest(sourceURL: source, suggestedFileName: "picked.wav")],
                expectedPackID: "pack-a")
        }
        await Task.yield()
        expect(probe.waitUntilEntered() == .success, "detached import 必须进入 duration probe")
        model.selectPackForInspection("pack-b")
        model.selectPackForInspection("pack-a")
        probe.allowCompletion()

        guard case .success(let completion) = await operation.value else {
            expect(false, "导入应继续完成并落到原目标包")
            return
        }
        expect(completion.completedInBackground, "选择身份一旦改变，返回原包也必须是后台结果")
        expect(completion.previewFile == nil, "A→B→A 不得自动播放旧操作的音频")
        expect(
            model.windowStatuses.first?.message.contains("后台操作") == true,
            "A→B→A 完成状态必须明确标成后台结果")
    }

    await suite("SoundPacksWindowModel add audio：隐藏期间完成的结果必须跨 follow-active 重开存活") {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "claudio-window-hidden-import-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let configFile = root.appendingPathComponent("config.json")
        let packs = root.appendingPathComponent("packs")
        writeFixture(#"{ "selected_pack": "pack-b", "events": {} }"#, to: configFile)
        for id in ["pack-a", "pack-b"] {
            writeFixture(
                "{ \"id\": \"\(id)\", \"name\": \"\(id)\", \"events\": {} }",
                to: packs.appendingPathComponent("\(id)/manifest.json"))
        }
        let source = root.appendingPathComponent("picked.wav")
        try? validWAVData().write(to: source)
        let probe = SoundPacksBlockingDurationProbe()
        let model = SoundPacksWindowModel(
            configFile: configFile,
            lockFile: root.appendingPathComponent("config.lock"),
            environment: AudioImportEnvironment(
                userPacksDirectory: packs,
                durationProbe: probe,
                packsLockFile: injectedPacksLock(under: root)),
            refreshCoordinator: SoundPacksRefreshCoordinator())
        model.selectPackForInspection("pack-a")

        let operation = Task {
            await model.importSelectedAudioFiles(
                [AudioImportRequest(sourceURL: source, suggestedFileName: "picked.wav")],
                expectedPackID: "pack-a")
        }
        await Task.yield()
        expect(probe.waitUntilEntered() == .success, "hidden import 必须进入 duration probe")
        probe.allowCompletion()
        _ = await operation.value
        let completedRevision = model.windowStatuses.first?.revision
        expect(model.windowStatuses.first?.kind == .audio, "隐藏期间完成必须先产生音频结果")

        model.reload(followActivePack: true)

        let retained = model.windowStatuses.first(where: { $0.kind == .audio })
        expect(model.selectedPackID == "pack-b", "重开仍必须跟随真实 active pack")
        expect(retained?.revision == completedRevision, "提升为后台状态不得伪造一次新操作 revision")
        expect(retained?.packID == nil, "重开后的异步结果必须是窗口级，不得错挂到 active pack")
        expect(
            retained?.message.contains("后台操作") == true
                && retained?.message.contains("pack-a") == true,
            "重开后仍必须公告真实原目标，不得在播报前清除")
    }

    suite("Panel master volume：成功落盘后及时刷新保留窗口的 preview config") {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let configLock = root.appendingPathComponent("config.lock")
            let packs = root.appendingPathComponent("packs")
            writeFixture(
                #"{ "selected_pack": "pack-a", "master_volume": 0.2, "events": {} }"#,
                to: configFile)
            writeFixture(
                #"{ "id": "pack-a", "events": {} }"#,
                to: packs.appendingPathComponent("pack-a/manifest.json"))
            let coordinator = SoundPacksRefreshCoordinator()
            let environment = soundPacksEnvironment(packs)
            let window = SoundPacksWindowModel(
                configFile: configFile,
                lockFile: configLock,
                environment: environment,
                refreshCoordinator: coordinator)
            let panel = PanelConfigController(
                configFile: configFile,
                lockFile: configLock,
                environment: environment,
                soundPacksRefreshCoordinator: coordinator)
            expect(previewVolume(for: window.config) == 0.2, "前提：窗口初始音量是 0.2")

            expect(panel.setMasterVolume(1.0) == 1.0, "面板主音量应成功落盘")

            expect(coordinator.windowContentReloadRevision == 1, "主音量成功必须发布一次定向窗口刷新")
            expect(previewVolume(for: window.config) == 1.0, "窗口下一次试听必须使用最新落盘音量")
            expect(coordinator.panelReloadRevision == 0, "面板自己的写不得形成反向刷新环")
        }
    }

    suite("SoundPacksWindowModel preview：只返回当前映射的包内正规文件，陈旧时刷成 broken") {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let packs = root.appendingPathComponent("packs")
            let sound = packs.appendingPathComponent("pack-a/stop.wav")
            writeFixture(
                #"{ "selected_pack": "pack-a", "events": {} }"#,
                to: configFile)
            writeFixture(
                #"{ "id": "pack-a", "events": { "stop": "stop.wav" } }"#,
                to: packs.appendingPathComponent("pack-a/manifest.json"))
            writeFixture("audio", to: sound)
            let model = SoundPacksWindowModel(
                configFile: configFile,
                environment: soundPacksEnvironment(packs),
                refreshCoordinator: SoundPacksRefreshCoordinator())

            expect(
                model.previewFileForSelectedEvent(.stop) == sound,
                "present 事件必须解析到当前包内的真文件")
            try? FileManager.default.removeItem(at: sound)
            expect(
                model.previewFileForSelectedEvent(.stop) == nil,
                "外部删除后试听必须 fail closed，不得播放陈旧路径")
            expect(
                model.selectedEventRows.first(where: { $0.event == .stop })?.coverage
                    == .broken(fileName: "stop.wav"),
                "解析失败必须立即刷新为 broken，不得静默无反馈")
        }
    }

    suite("SoundPacksWindowModel status：失败优先，同级按最新 revision 排序") {
        withTempDirectory { root in
            let model = SoundPacksWindowModel(
                configFile: root.appendingPathComponent("missing-config.json"),
                environment: soundPacksEnvironment(root.appendingPathComponent("packs")),
                refreshCoordinator: SoundPacksRefreshCoordinator())
            _ = model.forkSelectedFactoryPack()
            _ = model.useSelectedPack()
            _ = model.restoreAllFactoryPacksAfterConfirmation()

            expect(model.windowStatuses.count == 3, "three independent kinds must remain visible")
            expect(
                model.windowStatuses.map(\.severity) == [.failure, .failure, .notice],
                "all failures must sort ahead of a newer notice")
            expect(
                model.windowStatuses[0].kind == .packUse
                    && model.windowStatuses[1].kind == .packFork,
                "same-severity failures must sort by descending monotonic revision")
        }
    }

    suite("SoundPacksWindowModel empty restore：all factory IDs attempted，partial failure aggregated，one refresh") {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let packs = root.appendingPathComponent("packs")
            let factory = root.appendingPathComponent("factory")
            writeFixture(#"{ "selected_pack": "missing", "events": {} }"#, to: configFile)
            writeFixture(
                #"{ "id": "good", "events": {} }"#,
                to: factory.appendingPathComponent("good/manifest.json"))
            writeFixture(
                "not-json",
                to: factory.appendingPathComponent("broken/manifest.json"))
            writeFixture("user-only", to: packs.appendingPathComponent("good"))
            let coordinator = SoundPacksRefreshCoordinator()
            let model = SoundPacksWindowModel(
                configFile: configFile,
                lockFile: root.appendingPathComponent("config.lock"),
                environment: soundPacksEnvironment(packs, factoryPacksDirectory: factory),
                refreshCoordinator: coordinator)
            expect(
                model.packCards.map(\.id) == ["missing"],
                "precondition: missing config selection is represented by a placeholder")

            let outcome = model.restoreAllFactoryPacksAfterConfirmation()
            expect(outcome.restoredPackIDs == ["good"], "good factory ID must restore")
            expect(outcome.failures.map(\.packID) == ["broken"], "broken factory ID must be named")
            expect(
                outcome.retainedSalvages.count == 1,
                "successful batch restore must retain and report the plain-file occupant")
            if let salvage = outcome.retainedSalvages.first {
                expect(
                    (try? String(contentsOfFile: salvage.movedTo, encoding: .utf8)) == "user-only",
                    "successful salvage bytes must remain intact at the reported path")
                expect(
                    model.windowStatuses.first?.message.contains(salvage.movedTo) == true
                        && model.windowStatuses.first?.message.contains("一个文件都没删") == true,
                    "partial status must expose successful salvage path and no-delete truth")
            }
            expect(coordinator.panelReloadRevision == 1, "batch must publish exactly one final refresh")
            expect(model.packCards.map(\.id) == ["good", "missing"], "successful partial result and placeholder must be visible")
            expect(
                model.windowStatuses.first?.severity == .failure
                    && model.windowStatuses.first?.message.contains("broken") == true,
                "partial failure status must aggregate and name the failed pack")
            expect(
                model.factoryRestoreRetryPackIDs == ["broken"]
                    && model.windowStatuses.first?.recovery
                        == .retryFactoryRestores(packIDs: ["broken"]),
                "批量部分失败刷新出非空列表后，失败项仍必须保留可执行的窗口级重试入口")
        }
    }

    suite("SoundPacksWindowModel batch restore：success sibling cannot hide salvaged publish failure retry") {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let packs = root.appendingPathComponent("packs")
            let factory = root.appendingPathComponent("factory")
            writeFixture(#"{ "selected_pack": "missing", "events": {} }"#, to: configFile)
            writeFixture(
                #"{ "id": "a-failed", "events": {} }"#,
                to: factory.appendingPathComponent("a-failed/manifest.json"))
            writeFixture(
                #"{ "id": "b-good", "events": {} }"#,
                to: factory.appendingPathComponent("b-good/manifest.json"))
            writeFixture("user-only", to: packs.appendingPathComponent("a-failed"))
            let failFirstPublish = SoundPacksFailFirstPublish()
            let coordinator = SoundPacksRefreshCoordinator()
            let environment = AudioImportEnvironment(
                userPacksDirectory: packs,
                factoryPacksDirectory: factory,
                durationProbe: StubDurationProbe(fixedDuration: 1),
                packsLockFile: injectedPacksLock(besideUserPacks: packs),
                beforeFactoryPackRestorePublish: {
                    try failFirstPublish.run()
                })
            let model = SoundPacksWindowModel(
                configFile: configFile,
                lockFile: root.appendingPathComponent("config.lock"),
                environment: environment,
                refreshCoordinator: coordinator)
            expect(model.packCards.map(\.id) == ["missing"], "precondition: batch restore starts with the selected placeholder")

            let outcome = model.restoreAllFactoryPacksAfterConfirmation()
            guard
                outcome.restoredPackIDs == ["b-good"],
                outcome.failures.count == 1,
                let failure = outcome.failures.first,
                failure.packID == "a-failed",
                case .publishFailed(_, let salvage?) = failure.error
            else {
                expect(false, "first sorted pack must fail after salvage while its sibling succeeds: \(outcome)")
                return
            }
            expect(
                failure.retainedSalvages == [salvage]
                    && (try? String(contentsOfFile: salvage.movedTo, encoding: .utf8))
                        == "user-only",
                "batch failure state must retain the exact salvage that contains the displaced bytes")
            expect(
                model.packCards.map(\.id) == ["b-good", "missing"]
                    && model.factoryRestoreRetryPackIDs == ["a-failed"],
                "successful sibling makes the library nonempty, but must not hide the failed pack retry")
            let failureStatus = model.windowStatuses.first(where: {
                $0.kind == .factoryBatchRestore
            })
            expect(
                failureStatus?.severity == .failure
                    && failureStatus?.message.contains(salvage.movedTo) == true
                    && failureStatus?.recovery
                        == .retryFactoryRestores(packIDs: ["a-failed"]),
                "visible batch failure must expose salvage truth and an executable recovery payload")
            expect(
                model.factoryRestoreActionError == nil,
                "batch retry state must not masquerade as the selected-pack restore error")

            let retry = model.retryFailedFactoryPackRestoreAfterConfirmation(
                expectedPackID: "a-failed")
            guard case .success(let retryOutcome) = retry else {
                expect(false, "batch publish failure must be retryable after its card disappeared: \(retry)")
                return
            }
            expect(
                retryOutcome.restoredPackID == "a-failed"
                    && retryOutcome.retainedSalvages == [salvage],
                "successful batch retry must carry the original salvage into its final outcome")
            expect(
                model.packCards.map(\.id) == ["a-failed", "b-good", "missing"]
                    && model.factoryRestoreRetryPackIDs.isEmpty,
                "successful retry must restore the missing card and clear only the completed recovery")
            let successStatus = model.windowStatuses.first(where: {
                $0.kind == .factoryBatchRestore
            })
            expect(
                successStatus?.severity == .notice
                    && successStatus?.recovery == nil
                    && successStatus?.message.contains(salvage.movedTo) == true,
                "final batch notice must remove the retry and continue exposing the retained path")
            expect(
                coordinator.panelReloadRevision == 2,
                "partial batch and successful retry must each publish one truthful full reload")
        }
    }

    suite("SoundPacksWindowModel restore：单包失败后重选再成功仍吸收同 ID 全部 batch salvage") {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let packs = root.appendingPathComponent("packs")
            let factory = root.appendingPathComponent("factory")
            writeFixture(#"{ "selected_pack": "missing", "events": {} }"#, to: configFile)
            writeFixture(
                #"{ "id": "recover-me", "events": {} }"#,
                to: factory.appendingPathComponent("recover-me/manifest.json"))
            writeFixture("original-user-bytes", to: packs.appendingPathComponent("recover-me"))
            let failPublish = SoundPacksFailSelectedPublishCalls([1, 2])
            let coordinator = SoundPacksRefreshCoordinator()
            let environment = AudioImportEnvironment(
                userPacksDirectory: packs,
                factoryPacksDirectory: factory,
                durationProbe: StubDurationProbe(fixedDuration: 1),
                packsLockFile: injectedPacksLock(besideUserPacks: packs),
                beforeFactoryPackRestorePublish: {
                    try failPublish.run()
                })
            let model = SoundPacksWindowModel(
                configFile: configFile,
                lockFile: root.appendingPathComponent("config.lock"),
                environment: environment,
                refreshCoordinator: coordinator)

            let batch = model.restoreAllFactoryPacksAfterConfirmation()
            guard
                batch.failures.count == 1,
                let batchFailure = batch.failures.first,
                let firstSalvage = batchFailure.retainedSalvages.first
            else {
                expect(
                    false,
                    "precondition: batch publish must fail after retaining the old occupant")
                return
            }
            expect(
                model.packCards.count == 1
                    && model.packCards.first?.availability == .missingSelectedPlaceholder
                    && model.factoryRestoreRetryPackIDs == ["recover-me"],
                "批量 publish 失败必须留下缺失包的窗口级恢复状态")

            writeFixture(
                #"{ "id": "recover-me", "events": {} }"#,
                to: packs.appendingPathComponent("recover-me/manifest.json"))
            writeFixture(
                "first-external-rebuild-bytes",
                to: packs.appendingPathComponent("recover-me/first-external.wav"))
            model.reload(followActivePack: false)
            expect(
                model.packCards.contains(where: { $0.id == "recover-me" })
                    && model.selectPackForInspection("recover-me"),
                "外部重建后 reload 必须提供可显式选择的同 ID 单包详情入口")

            let failedOnce = model.restoreSelectedFactoryPackAfterConfirmation(
                expectedPackID: "recover-me")
            guard
                case .failure(
                    .restore(
                        packID: "recover-me",
                        error: .publishFailed(_, let secondSalvage?),
                        retainedSalvages: let retainedAfterFailure)) = failedOnce
            else {
                expect(false, "单包再次 publish 失败必须返回第二条 salvage，实得 \(failedOnce)")
                return
            }
            expect(
                retainedAfterFailure == [firstSalvage, secondSalvage]
                    && model.factoryRestoreActionError?.message.contains(firstSalvage.movedTo)
                        == true
                    && model.factoryRestoreActionError?.message.contains(secondSalvage.movedTo)
                        == true,
                "同 ID 单包失败必须立即吸收 batch salvage，并按发生顺序保留本次 salvage")
            let failedBatchStatus = model.windowStatuses.first(where: {
                $0.kind == .factoryBatchRestore
            })
            expect(
                failedBatchStatus?.severity == .failure
                    && failedBatchStatus?.recovery
                        == .retryFactoryRestores(packIDs: ["recover-me"])
                    && failedBatchStatus?.message.contains(firstSalvage.movedTo) == true
                    && failedBatchStatus?.message.contains(secondSalvage.movedTo) == true,
                "单包失败时批量状态也必须累计第二条 salvage，但不得清失败或增加完成数")

            writeFixture(
                #"{ "id": "recover-me", "events": {} }"#,
                to: packs.appendingPathComponent("recover-me/manifest.json"))
            writeFixture(
                "second-external-rebuild-bytes",
                to: packs.appendingPathComponent("recover-me/second-external.wav"))
            model.reload(followActivePack: false)
            expect(
                model.selectPackForInspection("recover-me")
                    && model.selectedPackID == "recover-me"
                    && model.factoryRestoreActionError == nil
                    && model.factoryRestoreRetryPackIDs == ["recover-me"]
                    && model.windowStatuses.first(where: {
                        $0.kind == .factoryBatchRestore
                    })?.message.contains(secondSalvage.movedTo) == true,
                "重选会清单包错误，但批量失败必须继续持有第二条 salvage 与同一重试入口")

            let restored = model.restoreSelectedFactoryPackAfterConfirmation(
                expectedPackID: "recover-me")
            guard case .success(let outcome) = restored else {
                expect(false, "再次外部重建后的单包恢复应成功，实得 \(restored)")
                return
            }
            expect(
                outcome.retainedSalvages.count == 3
                    && outcome.retainedSalvages.first == firstSalvage
                    && outcome.retainedSalvages[1] == secondSalvage
                    && outcome.salvaged == firstSalvage
                    && outcome.retainedSalvages.filter { $0 == firstSalvage }.count == 1,
                "最终成功必须保留 batch、单包失败和本次成功三次 salvage，且稳定去重")
            if outcome.retainedSalvages.count == 3 {
                let thirdSalvage = outcome.retainedSalvages[2]
                expect(
                    (try? String(contentsOfFile: firstSalvage.movedTo, encoding: .utf8))
                        == "original-user-bytes",
                    "批量失败保留的原始用户字节不得丢失")
                expect(
                    (try? String(
                        contentsOf: URL(fileURLWithPath: secondSalvage.movedTo)
                            .appendingPathComponent("first-external.wav"),
                        encoding: .utf8)) == "first-external-rebuild-bytes",
                    "单包失败搬走的外部重建字节必须跨重选保持原样")
                expect(
                    (try? String(
                        contentsOf: URL(fileURLWithPath: thirdSalvage.movedTo)
                            .appendingPathComponent("second-external.wav"),
                        encoding: .utf8)) == "second-external-rebuild-bytes",
                    "最终成功搬走的外部重建字节也必须保持原样")
            }
            expect(
                model.factoryRestoreNotice == outcome
                    && model.factoryRestoreRetryPackIDs.isEmpty,
                "单包成功必须发布合并后的结果并清除同 ID 批量重试")
            let batchStatus = model.windowStatuses.first(where: {
                $0.kind == .factoryBatchRestore
            })
            let singleStatus = model.windowStatuses.first(where: {
                $0.kind == .factoryRestore
            })
            let retainedPaths = outcome.retainedSalvages.map(\.movedTo)
            expect(
                batchStatus?.severity == .notice
                    && batchStatus?.recovery == nil
                    && batchStatus?.message.contains("已恢复 1 个") == true
                    && retainedPaths.allSatisfy {
                        batchStatus?.message.contains($0) == true
                    },
                "单包成功必须把旧批量失败计入完成数、移除 recovery，并告知新旧全部 salvage")
            expect(
                singleStatus?.severity == .notice
                    && retainedPaths.allSatisfy {
                        singleStatus?.message.contains($0) == true
                    },
                "单包成功状态也必须使用合并后的 outcome，逐条告知新旧 salvage")
            expect(
                model.windowStatuses.allSatisfy { $0.severity != .failure },
                "成功后不得同时显示成功与已解决的旧批量失败")
            expect(
                coordinator.panelReloadRevision == 3,
                "批量失败、单包部分失败与最终成功应各发布一次真实 full reload")
        }
    }

    suite("SoundPacksWindowModel restore：重试焦点严格投影最新 windowStatuses 视觉顺序") {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let packs = root.appendingPathComponent("packs")
            let factory = root.appendingPathComponent("factory")
            writeFixture(#"{ "selected_pack": "missing", "events": {} }"#, to: configFile)
            for packID in ["a-batch", "b-single"] {
                writeFixture(
                    #"{ "id": "\#(packID)", "events": {} }"#,
                    to: factory.appendingPathComponent("\(packID)/manifest.json"))
                writeFixture("user-\(packID)", to: packs.appendingPathComponent(packID))
            }
            let failPublish = SoundPacksFailSelectedPublishCalls([1, 3, 4])
            let environment = AudioImportEnvironment(
                userPacksDirectory: packs,
                factoryPacksDirectory: factory,
                durationProbe: StubDurationProbe(fixedDuration: 1),
                packsLockFile: injectedPacksLock(besideUserPacks: packs),
                beforeFactoryPackRestorePublish: {
                    try failPublish.run()
                })
            let model = SoundPacksWindowModel(
                configFile: configFile,
                lockFile: root.appendingPathComponent("config.lock"),
                environment: environment,
                refreshCoordinator: SoundPacksRefreshCoordinator())

            let batch = model.restoreAllFactoryPacksAfterConfirmation()
            expect(
                batch.restoredPackIDs == ["b-single"]
                    && batch.failures.map(\.packID) == ["a-batch"],
                "precondition: first publish fails for A while sorted sibling B succeeds")
            expect(
                model.selectPackForInspection("b-single"),
                "缺失选择 placeholder 不得隐式跳到 sibling；测试显式选择 B 后再恢复")
            let singleFailure = model.restoreSelectedFactoryPackAfterConfirmation(
                expectedPackID: "b-single")
            guard case .failure = singleFailure else {
                expect(false, "third publish call must create the newer single-pack B failure")
                return
            }
            expect(
                model.windowStatuses.compactMap { status -> [String]? in
                    guard case .retryFactoryRestores(let ids)? = status.recovery else { return nil }
                    return ids
                }.flatMap { $0 } == ["b-single", "a-batch"]
                    && model.factoryRestoreRetryPackIDs == ["b-single", "a-batch"],
                "B 的单包失败较新，视觉状态与重试焦点都必须先 B 后 A，实得 \(model.factoryRestoreRetryPackIDs)")

            let batchRetry = model.retryFailedFactoryPackRestoreAfterConfirmation(
                expectedPackID: "a-batch")
            guard case .failure = batchRetry else {
                expect(
                    false,
                    "fourth publish call must keep batch A failed and make its status newest")
                return
            }
            let visibleRecoveryIDs = model.windowStatuses.compactMap {
                status -> [String]? in
                guard case .retryFactoryRestores(let ids)? = status.recovery else { return nil }
                return ids
            }.flatMap { $0 }
            let recoveryStatusKinds = model.windowStatuses.compactMap { status in
                status.recovery == nil ? nil : status.kind
            }
            let recoveryStatuses = model.windowStatuses.filter { $0.recovery != nil }
            let focusOrder = soundPacksWindowFocusOrder(
                SoundPacksWindowFocusScope(
                    packIDs: model.packCards.map(\.id),
                    selectedPackID: model.selectedPackID,
                    retryFactoryRestorePackIDs: model.factoryRestoreRetryPackIDs))
            expect(
                visibleRecoveryIDs == ["a-batch", "b-single"]
                    && model.factoryRestoreRetryPackIDs == visibleRecoveryIDs
                    && model.packCards.count == 1
                    && model.packCards.first?.availability == .missingSelectedPlaceholder
                    && recoveryStatusKinds == [.factoryBatchRestore, .factoryRestore]
                    && recoveryStatuses[0].revision > recoveryStatuses[1].revision
                    && Array(focusOrder.prefix(3))
                        == [
                            .packList,
                            .retryFactoryRestore(packID: "a-batch"),
                            .retryFactoryRestore(packID: "b-single"),
                        ],
                "A 重试后成为第一条视觉状态，焦点投影必须同步变为 A→B，不能固定单包优先；visible=\(visibleRecoveryIDs) retry=\(model.factoryRestoreRetryPackIDs) cards=\(model.packCards.map(\.id))")
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
            let view = soundPacksCode("gui/Sources/SoundPacksWindow/SoundPacksWindowView.swift"),
            let model = soundPacksCode(
                "gui/Sources/ClaudioGUICore/SoundPacksWindowModel.swift")
        else {
            expect(
                false,
                "读不到 SoundPacksWindowController.swift、SoundPacksWindowView.swift 或 SoundPacksWindowModel.swift")
            return
        }

        expect(controller.contains("@MainActor"), "NSWindow owner 必须显式 @MainActor")
        expect(model.contains("@MainActor"), "窗口 model 必须显式 @MainActor")
        expect(
            controller.contains("private var window: NSWindow?"),
            "owner 必须持有一个 optional NSWindow，按需创建")
        expect(
            controller.contains("private lazy var model: SoundPacksWindowModel"),
            "管理窗口 model 必须延迟到首次展示时创建，启动时不得扫描声音包")
        expect(
            view.contains("packRowMetaSlots(") && view.contains("case .modified:"),
            "管理窗口 license 必须复用 factoryIntegrity 的 modified 优先规则")
        expect(
            controller.contains("window ?? makeWindow()"),
            "showWindow 必须复用已有窗口，不能每点一次管理就 new 一扇")
        let reloadPolicyCalls = callArguments(
            of: "shouldReloadSoundPacksWindowOnShow", in: controller)
        expect(
            reloadPolicyCalls.count == 1,
            "controller 必须恰好调用一次 show-time reload policy，实得 \(reloadPolicyCalls.count) 次")
        if let arguments = reloadPolicyCalls.first {
            expect(
                argumentValue("wasAlreadyCreated", in: arguments) == "wasAlreadyCreated"
                    && argumentValue("isVisible", in: arguments) == "wasVisible",
                "show-time reload 的两个实参必须锚在同一处调用上并逐字转发 "
                    + "`wasAlreadyCreated` / `wasVisible`，实得：\(arguments) —— 全文件 contains 会被"
                    + "下面 focus policy 的 `isVisible: wasVisible` 诱饵喂饱")
        }
        expect(
            controller.contains("shouldPrepareSoundPacksWindowForPresentation(isVisible: wasVisible)"),
            "首焦点与 windowOpened 必须共用真实 hidden→visible 判定")
        expect(
            controller.contains(
                "effectiveRoute = model.selectPackForInspection(packID) ? resolvedRoute : .overview")
                && controller.contains("pendingRoute = route")
                && controller.contains("resolvePendingRouteIfPossible")
                && controller.contains("requestInitialFocus(route: effectiveRoute)")
                && controller.contains("focusCoordinator.requestRoute(effectiveRoute)"),
            "editEvent 必须等待 library 证明目标存在后再选包；ready 缺失只能降级 overview")
        expect(
            controller.contains("ClaudioL10n(language: languageStore.language).text(.soundPacksWindowTitle)"),
            "后台标准窗口标题必须保留 claudi0 品牌锚点")
        expect(
            controller.contains("isReleasedWhenClosed = false"),
            "关闭后 owner 仍保留窗口，下一次复用同一实例")
        expect(
            controller.contains("private var handbackApplication: NSRunningApplication?"),
            "window owner 必须接住 popover 的 previous-app handback 债务")
        expect(
            controller.contains("public func showWindow(")
                && controller.contains("returnFocusTo application: NSRunningApplication?"),
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
            controller.contains(
                "private var focusRestoration: (@MainActor (NSRunningApplication?) -> Bool)?")
                && closeBody.contains("guard !restoration(previous) else { return }")
                && closeBody.contains("self.completeCloseHandoff(to: previous)")
                && controller.contains("private func completeCloseHandoff("),
            "恢复闭包必须报告真实成功；目标窗口消失时仍要继续普通 handback/deactivate")
        expect(
            controller.contains("private func completeCloseHandoff(")
                && controller.contains("guard NSApp.isActive else { return }"),
            "用户已切到别处时，窗口关闭不得把旧 app 抢回前台")
        expect(
            controller.contains("NSApp.yieldActivation(to: previous)")
                && controller.contains("NSApp.deactivate()"),
            "windowWillClose 必须覆盖 macOS 14+ cooperative handback 与旧系统 deactivate")
        expect(
            controller.contains("NSWorkspace.didActivateApplicationNotification")
                && controller.contains("[weak self]"),
            "窗口后台停留期间必须弱订阅外部 app 激活，把 handback 更新为最近来源且不成环")
        expect(
            controller.contains("isClosingWindow"),
            "窗口关闭时必须阻止 activation notification 把刚清掉的 handback 债务重新写回")
        expect(
            !controller.contains("Task.detached")
                && !controller.contains("mutateManifestJSON")
                && !controller.contains("setEventEnabled("),
            "窗口 owner 可延后焦点恢复，但不得自行启动后台 manifest/config 写路径")
    }

    suite(".manageSounds：保留按钮位置/焦点，只把 Finder 动作改为 pending-close 窗口 presentation") {
        guard
            let panel = soundPacksCode("gui/Sources/ClaudioGUI/PanelView.swift"),
            let menu = soundPacksCode("gui/Sources/ClaudioGUI/MenuBarController.swift"),
            let requestBody = soundPacksFunctionBody(
                after: "fileprivate func requestSoundPacksWindowPresentation(", in: menu),
            let closeBody = soundPacksFunctionBody(
                after: "func popoverDidClose(_ notification: Notification)", in: menu)
        else {
            expect(false, "读不到 PanelView/MenuBarController 或切不出窗口 presentation 函数体")
            return
        }

        expect(
            panel.contains("onManageSounds(.overview, .manageSounds)"),
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
            requestBody.contains("pendingSoundPacksWindowPresentation = (route, target)")
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
            of: "pendingSoundPacksWindowPresentation = (route, target)"
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
            closeBody.contains("if let soundPacksPresentation")
                && closeBody.contains("route: soundPacksPresentation.route")
                && closeBody.contains("returnFocusTo: previous"),
            "popover 关闭完成后必须把 previous-app handback 债务转交给单窗口 owner")
        if let showAt = closeBody.range(
            of: "soundPacksWindowController.showWindow("
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
