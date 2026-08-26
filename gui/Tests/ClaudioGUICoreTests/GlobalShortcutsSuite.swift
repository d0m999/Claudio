import ClaudioCore
import ClaudioGUICore
import Foundation

@MainActor
func runGlobalShortcutsSuites() {
    suite("Global shortcuts：modifier normalization 与输入约束") {
        let normalized = GlobalShortcut(
            shortcutID: .togglePanel,
            keyCode: 0,
            modifiers: GlobalShortcutModifiers(rawValue: 0xffff))
        expect(
            normalized.modifiers == [.command, .control, .option, .shift],
            "未知 modifier 位必须在写入 adapter 前移除")

        let bare = GlobalShortcut(
            shortcutID: .togglePanel,
            keyCode: 0,
            modifiers: [])
        let shiftOnly = GlobalShortcut(
            shortcutID: .togglePanel,
            keyCode: 0,
            modifiers: .shift)
        let optionOnly = GlobalShortcut(
            shortcutID: .togglePanel,
            keyCode: 0,
            modifiers: .option)
        expect(
            validateGlobalShortcut(bare, existing: []) == .primaryModifierRequired
                && validateGlobalShortcut(shiftOnly, existing: [])
                    == .primaryModifierRequired
                && validateGlobalShortcut(optionOnly, existing: [])
                    == .primaryModifierRequired,
            "裸键与仅 Shift/Option 必须拒绝")

        let commandSpace = GlobalShortcut(
            shortcutID: .togglePanel,
            keyCode: 49,
            modifiers: .command)
        expect(
            validateGlobalShortcut(commandSpace, existing: []) == .systemReserved,
            "系统保留组合必须在 Carbon 注册前拒绝")

        let unsupportedKey = GlobalShortcut(
            shortcutID: .togglePanel,
            keyCode: 65535,
            modifiers: .command)
        expect(
            validateGlobalShortcut(unsupportedKey, existing: []) == .unsupportedKeyCode,
            "未知硬件 key code 必须在 Carbon 注册前失败关闭")

        let duplicate = GlobalShortcut(
            shortcutID: .openSettings,
            keyCode: 0,
            modifiers: [.command, .control])
        expect(
            validateGlobalShortcut(
                duplicate,
                existing: [
                    GlobalShortcut(
                        shortcutID: .togglePanel,
                        keyCode: 0,
                        modifiers: [.control, .command])
                ]) == .duplicate(.togglePanel),
            "同一 app 内规范化后重复组合必须指出已占用 action")
    }

    suite("Global shortcuts：替换严格执行 unregister → register → persist") {
        let fake = FakeGlobalShortcutEnvironment()
        let model = fake.makeModel()
        model.replace(.togglePanel, keyCode: 0, modifiers: .command)
        fake.operations.removeAll()

        model.replace(.togglePanel, keyCode: 1, modifiers: [.command, .shift])

        expect(
            fake.operations == [
                "unregister:toggle-panel",
                "register:toggle-panel:1:9",
                "persist:toggle-panel",
            ],
            "成功替换的系统与持久化顺序不得漂移")
        expect(
            model.state(for: .togglePanel).shortcut?.keyCode == 1
                && model.state(for: .togglePanel).isRegistered,
            "persist 成功后才能发布新注册")
    }

    suite("Global shortcuts：新注册冲突恢复旧值且不覆盖持久化") {
        let fake = FakeGlobalShortcutEnvironment()
        let model = fake.makeModel()
        model.replace(.togglePanel, keyCode: 0, modifiers: .command)
        let oldData = fake.persisted[.togglePanel]
        fake.operations.removeAll()
        fake.failNextRegistration = true

        model.replace(.togglePanel, keyCode: 1, modifiers: [.command, .shift])

        expect(
            fake.operations == [
                "unregister:toggle-panel",
                "register:toggle-panel:1:9",
                "register:toggle-panel:0:1",
            ],
            "冲突必须重新注册旧值，且不得提前 persist 新值")
        expect(
            fake.persisted[.togglePanel] == oldData
                && model.state(for: .togglePanel).shortcut?.keyCode == 0
                && model.state(for: .togglePanel).isRegistered
                && model.state(for: .togglePanel).failure == .conflict,
            "冲突后旧值必须同时保持在系统、状态与持久化中")
    }

    suite("Global shortcuts：系统注册失败不误报为组合冲突") {
        let fake = FakeGlobalShortcutEnvironment()
        let model = fake.makeModel()
        model.replace(.togglePanel, keyCode: 0, modifiers: .command)
        let oldData = fake.persisted[.togglePanel]
        fake.nextRegistrationFailure = .systemFailure(-50)

        model.replace(.togglePanel, keyCode: 1, modifiers: .command)

        expect(
            fake.persisted[.togglePanel] == oldData
                && fake.registrations[.togglePanel]?.keyCode == 0
                && model.state(for: .togglePanel).shortcut?.keyCode == 0
                && model.state(for: .togglePanel).isRegistered
                && model.state(for: .togglePanel).failure == .registrationFailed,
            "adapter systemFailure 必须恢复旧值并保留与 conflict 不同的用户可见语义")
    }

    suite("Global shortcuts：rollback 自身失败时诚实禁用运行态") {
        let fake = FakeGlobalShortcutEnvironment()
        let model = fake.makeModel()
        model.replace(.togglePanel, keyCode: 0, modifiers: .command)
        fake.operations.removeAll()
        fake.registrationFailuresRemaining = 2

        model.replace(.togglePanel, keyCode: 1, modifiers: .command)

        expect(
            model.state(for: .togglePanel).shortcut?.keyCode == 0
                && !model.state(for: .togglePanel).isRegistered
                && model.state(for: .togglePanel).failure == .rollbackFailed,
            "旧值无法重新注册时不得伪装仍有效")
    }

    suite("Global shortcuts：persist 失败清理新值并恢复旧值") {
        let fake = FakeGlobalShortcutEnvironment()
        let model = fake.makeModel()
        model.replace(.togglePanel, keyCode: 0, modifiers: .command)
        let oldData = fake.persisted[.togglePanel]
        fake.operations.removeAll()
        fake.failPersistence = true

        model.replace(.togglePanel, keyCode: 1, modifiers: .command)

        expect(
            fake.operations == [
                "unregister:toggle-panel",
                "register:toggle-panel:1:1",
                "persist:toggle-panel",
                "unregister:toggle-panel",
                "register:toggle-panel:0:1",
            ],
            "persist 失败必须先清理新注册，再 rollback 旧值")
        expect(
            fake.persisted[.togglePanel] == oldData
                && fake.registrations[.togglePanel]?.keyCode == 0
                && model.state(for: .togglePanel).shortcut?.keyCode == 0
                && model.state(for: .togglePanel).isRegistered
                && model.state(for: .togglePanel).failure == .persistenceFailed,
            "persist 失败后 adapter、model 与持久化必须一致保留旧值")
    }

    suite("Global shortcuts：persist 失败且新注册清理失败时保留诚实运行态") {
        let fake = FakeGlobalShortcutEnvironment()
        let model = fake.makeModel()
        model.replace(.togglePanel, keyCode: 0, modifiers: .command)
        let oldData = fake.persisted[.togglePanel]
        fake.operations.removeAll()
        fake.failPersistence = true
        fake.successfulUnregistrationsBeforeFailure = 1

        model.replace(.togglePanel, keyCode: 1, modifiers: .command)

        expect(
            fake.persisted[.togglePanel] == oldData
                && fake.registrations[.togglePanel]?.keyCode == 1
                && model.state(for: .togglePanel).shortcut?.keyCode == 1
                && model.state(for: .togglePanel).isRegistered
                && model.state(for: .togglePanel).failure == .persistenceCleanupFailed,
            "新值无法撤销时不得谎报旧值或未注册")

        model.replace(.openSettings, keyCode: 0, modifiers: .command)
        expect(
            model.state(for: .openSettings).failure == .validation(.duplicate(.togglePanel))
                && fake.registrations[.openSettings] == nil
                && fake.persisted[.openSettings] == nil,
            "deferred persisted 旧组合仍被本 app 保留，其他 action 不得重复使用")

        model.suspend()
        expect(
            fake.registrations.isEmpty
                && model.state(for: .togglePanel).shortcut?.keyCode == 0
                && !model.state(for: .togglePanel).isRegistered,
            "临时新值一旦成功撤销，运行态必须回到 persisted 旧值")
        model.resume()
        expect(
            fake.registrations[.togglePanel]?.keyCode == 0
                && model.state(for: .togglePanel).shortcut?.keyCode == 0
                && model.state(for: .togglePanel).isRegistered,
            "wake replay 必须恢复 persisted 旧值，不得重放未保存的临时新值")
    }

    suite("Global shortcuts：未注册的 deferred 临时值也在 sleep 时回到 persisted 值") {
        let fake = FakeGlobalShortcutEnvironment()
        let model = fake.makeModel()
        model.replace(.togglePanel, keyCode: 0, modifiers: .command)
        fake.failPersistence = true
        fake.successfulUnregistrationsBeforeFailure = 1
        model.replace(.togglePanel, keyCode: 1, modifiers: .command)
        fake.registrationFailuresRemaining = 2

        model.replace(.togglePanel, keyCode: 2, modifiers: .command)
        expect(
            fake.registrations.isEmpty
                && model.state(for: .togglePanel).shortcut?.keyCode == 1
                && !model.state(for: .togglePanel).isRegistered
                && model.state(for: .togglePanel).failure == .rollbackFailed,
            "复合失败必须真实表示临时值已未注册")

        model.suspend()
        expect(
            model.state(for: .togglePanel).shortcut?.keyCode == 0
                && !model.state(for: .togglePanel).isRegistered,
            "suspend 不得因 isRegistered=false 跳过 deferred persisted 回归")
        model.resume()
        expect(
            fake.registrations[.togglePanel]?.keyCode == 0
                && model.state(for: .togglePanel).shortcut?.keyCode == 0
                && model.state(for: .togglePanel).isRegistered,
            "wake 必须重放 persisted 旧值，不得重放已未注册的临时值")
    }

    suite("Global shortcuts：重复、清除与损坏记录按 item 隔离") {
        let fake = FakeGlobalShortcutEnvironment()
        let model = fake.makeModel()
        model.replace(.togglePanel, keyCode: 0, modifiers: .command)
        model.replace(.openSettings, keyCode: 0, modifiers: .command)
        expect(
            model.state(for: .openSettings).failure == .validation(.duplicate(.togglePanel))
                && fake.registrations[.openSettings] == nil,
            "app 内重复不得触碰 Carbon adapter")

        model.clear(.togglePanel)
        expect(
            model.state(for: .togglePanel) == GlobalShortcutItemState()
                && fake.registrations[.togglePanel] == nil
                && fake.persisted[.togglePanel] == nil,
            "清除必须同时撤销系统注册与单项持久化")

        let encoder = JSONEncoder()
        fake.persisted[.togglePanel] = Data("damaged".utf8)
        fake.persisted[.openSettings] = try? encoder.encode(
            GlobalShortcut(
                shortcutID: .openSettings,
                keyCode: 1,
                modifiers: .control))
        let restored = fake.makeModel()
        expect(
            restored.state(for: .togglePanel).failure == .invalidStoredValue
                && restored.state(for: .togglePanel).shortcut == nil,
            "损坏记录必须只禁用对应 item")
        expect(
            restored.state(for: .openSettings).isRegistered
                && restored.state(for: .openSettings).shortcut?.schema
                    == GlobalShortcut.schemaVersion,
            "另一个合法 schema 记录必须独立恢复")

        restored.clear(.togglePanel)
        expect(
            restored.state(for: .togglePanel) == GlobalShortcutItemState()
                && fake.persisted[.togglePanel] == nil,
            "用户必须能清除损坏记录后重新录制")
    }

    suite("Global shortcuts：未知 schema 与 mismatched shortcut ID 均失败关闭") {
        let fake = FakeGlobalShortcutEnvironment()
        let encoder = JSONEncoder()
        fake.persisted[.togglePanel] = try? encoder.encode(
            GlobalShortcut(
                shortcutID: .togglePanel,
                keyCode: 0,
                modifiers: .command,
                schema: GlobalShortcut.schemaVersion + 1))
        fake.persisted[.openSettings] = try? encoder.encode(
            GlobalShortcut(
                shortcutID: .openCurrentScopeEvents,
                keyCode: 1,
                modifiers: .control))
        fake.persisted[.openCurrentScopeEvents] = try? encoder.encode(
            GlobalShortcut(
                shortcutID: .openCurrentScopeEvents,
                keyCode: 65535,
                modifiers: .command))

        let model = fake.makeModel()
        expect(
            model.state(for: .togglePanel).failure == .invalidStoredValue
                && model.state(for: .openSettings).failure == .invalidStoredValue
                && model.state(for: .openCurrentScopeEvents).failure == .invalidStoredValue
                && fake.registrations.isEmpty,
            "未知 schema、action 身份或 key code 不得猜测注册")
    }

    suite("Global shortcuts：睡眠撤销、唤醒恢复与 action routing") {
        let fake = FakeGlobalShortcutEnvironment()
        var actions: [GlobalShortcutAction] = []
        let model = fake.makeModel { actions.append($0) }
        model.replace(.togglePanel, keyCode: 0, modifiers: .command)
        model.replace(.openSettings, keyCode: 1, modifiers: .control)
        model.replace(.openCurrentScopeEvents, keyCode: 2, modifiers: [.command, .control])
        fake.trigger(.togglePanel)
        fake.trigger(.openSettings)
        fake.trigger(.openCurrentScopeEvents)
        expect(
            actions == [.togglePanel, .openSettings, .openCurrentScopeEvents],
            "fake Carbon callback 必须路由到对应 app-lifetime action")

        fake.operations.removeAll()
        model.suspend()
        expect(
            fake.registrations.isEmpty
                && !model.state(for: .togglePanel).isRegistered
                && !model.state(for: .openSettings).isRegistered
                && !model.state(for: .openCurrentScopeEvents).isRegistered,
            "睡眠必须撤销进程注册但保留 shortcut 值")
        fake.trigger(.togglePanel)
        expect(
            actions == [.togglePanel, .openSettings, .openCurrentScopeEvents],
            "挂起期间 action 必须失败关闭")

        model.resume()
        fake.trigger(.togglePanel)
        expect(
            fake.registrations.count == 3
                && model.state(for: .togglePanel).isRegistered
                && actions
                    == [.togglePanel, .openSettings, .openCurrentScopeEvents, .togglePanel],
            "唤醒必须恢复全部合法注册与 action routing")
    }

    suite("Global shortcuts：本地录制暂停 Carbon 并在结束后保留验证失败") {
        let fake = FakeGlobalShortcutEnvironment()
        let model = fake.makeModel()
        model.replace(.togglePanel, keyCode: 0, modifiers: .command)
        model.replace(.openSettings, keyCode: 1, modifiers: .control)
        model.replace(.openCurrentScopeEvents, keyCode: 2, modifiers: [.command, .control])

        expect(model.suspendForRecording(), "录制前必须能完整撤销三项 Carbon 注册")
        expect(fake.registrations.isEmpty, "本地 recorder 武装期间不得留下会吞掉按键的全局注册")

        model.replace(.openSettings, keyCode: 0, modifiers: .command)
        expect(
            model.state(for: .openSettings).failure == .validation(.duplicate(.togglePanel)),
            "暂停系统注册不得绕过 app 内持久化快捷键的重复验证")

        model.resumeAfterRecording(preservingFailureFor: .openSettings)
        expect(
            fake.registrations.count == 3
                && model.state(for: .openSettings).isRegistered
                && model.state(for: .openSettings).failure
                    == .validation(.duplicate(.togglePanel)),
            "录制结束必须恢复原注册并保留用户可见的新组合验证失败")
    }

    suite("Global shortcuts：录制暂停失败不静默降级且可恢复已撤销项") {
        let fake = FakeGlobalShortcutEnvironment()
        let model = fake.makeModel()
        model.replace(.togglePanel, keyCode: 0, modifiers: .command)
        model.replace(.openSettings, keyCode: 1, modifiers: .control)
        model.replace(.openCurrentScopeEvents, keyCode: 2, modifiers: [.command, .control])
        fake.successfulUnregistrationsBeforeFailure = 1

        expect(!model.suspendForRecording(), "任一 Carbon unregister 失败时 recorder 不得报告已安全武装")
        expect(
            model.state(for: .openSettings).isRegistered
                && model.state(for: .openSettings).failure == .unregisterFailed,
            "暂停失败必须投影为对应 item 的可见 unregister 错误")

        model.resumeAfterRecording()
        expect(
            fake.registrations.count == 3
                && model.state(for: .openSettings).failure == .unregisterFailed,
            "recorder 放弃武装后必须恢复其余注册且不清除失败证据")
    }

    suite("Global shortcuts：录制与系统睡眠交错时只在全部解除后恢复") {
        let wakeDuringRecording = FakeGlobalShortcutEnvironment()
        let recordingModel = wakeDuringRecording.makeModel()
        recordingModel.replace(.togglePanel, keyCode: 0, modifiers: .command)
        recordingModel.replace(.openSettings, keyCode: 1, modifiers: .control)
        recordingModel.replace(
            .openCurrentScopeEvents,
            keyCode: 2,
            modifiers: [.command, .control])

        expect(recordingModel.suspendForRecording(), "录制暂停前置条件必须成立")
        recordingModel.suspend()
        recordingModel.resume()
        expect(
            wakeDuringRecording.registrations.isEmpty,
            "录制仍武装时 didWake 不得提前重注册 Carbon 而吞掉本地 keyDown")

        recordingModel.replace(.openSettings, keyCode: 3, modifiers: .control)
        recordingModel.resumeAfterRecording()
        expect(
            wakeDuringRecording.registrations.count == 3
                && recordingModel.state(for: .openSettings).shortcut?.keyCode == 3,
            "唤醒后完成一次本地 capture 才能恢复全部注册")

        let cancelDuringSleep = FakeGlobalShortcutEnvironment()
        let sleepingModel = cancelDuringSleep.makeModel()
        sleepingModel.replace(.togglePanel, keyCode: 0, modifiers: .command)
        sleepingModel.replace(.openSettings, keyCode: 1, modifiers: .control)
        expect(sleepingModel.suspendForRecording(), "取消交错的录制暂停前置条件必须成立")
        sleepingModel.suspend()
        sleepingModel.resumeAfterRecording()
        expect(
            cancelDuringSleep.registrations.isEmpty,
            "系统仍在睡眠时取消录制不得恢复 Carbon")
        sleepingModel.resume()
        expect(
            cancelDuringSleep.registrations.count == 2,
            "取消录制且系统唤醒后才能恢复原注册")
    }

    suite("Global shortcuts：显示基于硬件 key code 且不依赖输入源") {
        let shortcut = GlobalShortcut(
            shortcutID: .openCurrentScopeEvents,
            keyCode: 0,
            modifiers: [.control, .option, .command])
        expect(
            shortcut.displayName == "⌃⌥⌘A"
                && globalShortcutKeyName(keyCode: shortcut.keyCode) == "A"
                && globalShortcutKeyName(keyCode: 36) == "↩"
                && globalShortcutKeyName(keyCode: 65) == "⌨."
                && globalShortcutKeyName(keyCode: 93) == "¥"
                && globalShortcutKeyName(keyCode: 65_535) == "#65535",
            "布局变化后显示必须由稳定的语言中性 key-cap 投影，不得猜字符")
    }

    suite("Global shortcuts：当前、失效与非法 scope route") {
        let scopes = panelSoundScopePresentations(
            sourceRows: [],
            config: ClaudioConfig(selectedPack: "pack"),
            language: .english)
        let route = globalShortcutEventSettingsRoute(
            storedValue: "future-surface",
            scopes: scopes)
        expect(
            route.scope == .global
                && route.unavailableRequestedScopeStoredValue == "future-surface",
            "未知 scope 必须路由到合法页面并保留可见失败原因")
        let staleKnown = globalShortcutEventSettingsRoute(
            storedValue: PanelSoundScopeID.surface(.codex).storedValue,
            scopes: scopes)
        expect(
            staleKnown.scope == .global
                && staleKnown.unavailableRequestedScopeStoredValue
                    == PanelSoundScopeID.surface(.codex).storedValue,
            "已知但当前不存在的 Surface 必须在 Events controller 调用前安全回退并带原因")
        let pending = globalShortcutEventSettingsRoute(
            storedValue: "unselected",
            scopes: scopes)
        expect(
            pending.scope == .global && pending.unavailableRequestedScopeStoredValue == nil,
            "从未选择应使用安全当前投影，不伪造损坏原因")
    }

    suite("Global shortcuts production wiring：Carbon、本地录制、owner 与非法 scope 原因") {
        let root = guiTestRepositoryRoot()
        let carbonURL = root.appendingPathComponent(
            "gui/Sources/ClaudioGUI/CarbonGlobalShortcutAdapter.swift")
        let recorderURL = root.appendingPathComponent(
            "gui/Sources/ClaudioGUI/ShortcutSettingsView.swift")
        let menuURL = root.appendingPathComponent(
            "gui/Sources/ClaudioGUI/MenuBarController.swift")
        let settingsControllerURL = root.appendingPathComponent(
            "gui/Sources/ClaudioGUI/SettingsWindowController.swift")
        let eventsURL = root.appendingPathComponent(
            "gui/Sources/ClaudioGUI/EventSettingsWindowView.swift")
        let coreURL = root.appendingPathComponent(
            "gui/Sources/ClaudioGUICore/GlobalShortcuts.swift")
        guard let carbon = try? String(contentsOf: carbonURL, encoding: .utf8),
            let recorder = try? String(contentsOf: recorderURL, encoding: .utf8),
            let menu = try? String(contentsOf: menuURL, encoding: .utf8),
            let settingsController = try? String(
                contentsOf: settingsControllerURL,
                encoding: .utf8),
            let events = try? String(contentsOf: eventsURL, encoding: .utf8),
            let core = try? String(contentsOf: coreURL, encoding: .utf8)
        else {
            expect(false, "读不到 global shortcut production wiring")
            return
        }

        expect(
            carbon.contains("RegisterEventHotKey(")
                && carbon.contains("UnregisterEventHotKey(")
                && carbon.contains("installEventHandlerIfNeeded() throws")
                && carbon.contains("throw GlobalShortcutAdapterError.systemFailure(status)")
                && !carbon.contains("precondition(status == noErr")
                && !carbon.contains("addGlobalMonitorForEvents")
                && !carbon.contains("addLocalMonitorForEvents"),
            "production 必须只用可投影初始化错误的 Carbon API，不得 crash 或安装 NSEvent monitor")
        expect(
            recorder.contains("override func keyDown(with event: NSEvent)")
                && recorder.contains("guard isRecording, !event.isARepeat")
                && recorder.contains("onCapture?(UInt32(event.keyCode)")
                && recorder.contains("event.keyCode == 53")
                && recorder.contains("else if model.suspendForRecording()")
                && recorder.contains("model.resumeAfterRecording(preservingFailureFor: action)")
                && recorder.contains(".onDisappear { stopRecording(restoringFocus: false) }")
                && recorder.contains("focusedTarget.wrappedValue = target")
                && recorder.contains(": .shortcutAction(action)")
                && recorder.contains("ClaudioTheme.font(.sectionTitle)")
                && recorder.contains("ClaudioTheme.font(.body)")
                && recorder.contains("ClaudioTheme.clay(colorScheme)")
                && recorder.contains("ClaudioTheme.error(colorScheme)")
                && !recorder.contains("design: .monospaced")
                && !recorder.contains(".foregroundColor(.accentColor)")
                && !recorder.contains(".foregroundColor(.red)")
                && !recorder.contains("event.characters")
                && !recorder.contains("charactersIgnoringModifiers"),
            "录制必须暂停 Carbon，使用字体/颜色 token，并在结束后恢复发起按钮焦点")
        expect(
            menu.contains("private let globalShortcutSettings: GlobalShortcutSettingsModel")
                && menu.contains("fileprivate func performGlobalShortcut(")
                && menu.contains("NSWorkspace.willSleepNotification")
                && menu.contains("NSWorkspace.didWakeNotification")
                && menu.contains("requestCurrentScopeEventsFromShortcut()")
                && menu.contains("settingsWindowController.showEventSettingsFromGlobalShortcut("),
            "注册与三项 action 必须由 MenuBarController 生命周期持有")
        expect(
            settingsController.contains("func showEventSettingsFromGlobalShortcut(")
                && settingsController.contains(".destination(.eventsAndSounds)"),
            "快捷键必须进入唯一 retained Settings owner，非法 scope 仍落在 Events destination")
        expect(
            events.contains("selection.unavailableRequestedScopeStoredValue")
                && events.contains("ClaudioTheme.error(colorScheme)")
                && events.contains("event-settings.shortcut-scope-failure"),
            "非法或失效 scope 必须仍打开 production Events，并用错误 token 显示原因")
        expect(
            core.contains("public let persist:")
                && core.contains("private var systemSuspensionActive = false")
                && core.contains("private var recordingSuspensionActive = false")
                && core.contains("guard !systemSuspensionActive, !recordingSuspensionActive")
                && !core.contains("persistence.write("),
            "持久化边界与录制/睡眠两种暂停原因必须由领域 model 统一持有")
    }
}

@MainActor
private final class FakeGlobalShortcutEnvironment {
    var registrations: [GlobalShortcutAction: GlobalShortcut] = [:]
    var persisted: [GlobalShortcutAction: Data] = [:]
    var operations: [String] = []
    var failNextRegistration = false
    var registrationFailuresRemaining = 0
    var nextRegistrationFailure: GlobalShortcutAdapterError?
    var failUnregister = false
    var failPersistence = false
    var successfulUnregistrationsBeforeFailure: Int?
    private var handler: (@MainActor (GlobalShortcutAction) -> Void)?

    func makeModel(
        actionHandler: @escaping @MainActor (GlobalShortcutAction) -> Void = { _ in }
    ) -> GlobalShortcutSettingsModel {
        GlobalShortcutSettingsModel(
            adapter: GlobalHotKeyAdapter(
                register: { [weak self] shortcut in
                    guard let self else { throw GlobalShortcutAdapterError.systemFailure(-1) }
                    self.operations.append(
                        "register:\(shortcut.shortcutID.rawValue):\(shortcut.keyCode):"
                            + "\(shortcut.modifiers.rawValue)")
                    if let failure = self.nextRegistrationFailure {
                        self.nextRegistrationFailure = nil
                        throw failure
                    }
                    if self.failNextRegistration {
                        self.failNextRegistration = false
                        throw GlobalShortcutAdapterError.conflict
                    }
                    if self.registrationFailuresRemaining > 0 {
                        self.registrationFailuresRemaining -= 1
                        throw GlobalShortcutAdapterError.conflict
                    }
                    guard self.registrations[shortcut.shortcutID] == nil else {
                        throw GlobalShortcutAdapterError.conflict
                    }
                    self.registrations[shortcut.shortcutID] = shortcut
                },
                unregister: { [weak self] action in
                    guard let self else { throw GlobalShortcutAdapterError.systemFailure(-1) }
                    self.operations.append("unregister:\(action.rawValue)")
                    if let remaining = self.successfulUnregistrationsBeforeFailure {
                        if remaining == 0 {
                            self.successfulUnregistrationsBeforeFailure = nil
                            throw GlobalShortcutAdapterError.systemFailure(-1)
                        }
                        self.successfulUnregistrationsBeforeFailure = remaining - 1
                    }
                    if self.failUnregister {
                        throw GlobalShortcutAdapterError.systemFailure(-1)
                    }
                    self.registrations[action] = nil
                },
                setActionHandler: { [weak self] handler in self?.handler = handler }),
            persistence: GlobalShortcutPersistenceAdapter(
                read: { [weak self] action in self?.persisted[action] },
                persist: { [weak self] action, data in
                    guard let self else { return }
                    self.operations.append("persist:\(action.rawValue)")
                    if self.failPersistence { throw FakePersistenceError.rejected }
                    self.persisted[action] = data
                }),
            actionHandler: actionHandler)
    }

    func trigger(_ action: GlobalShortcutAction) {
        handler?(action)
    }
}

private enum FakePersistenceError: Error {
    case rejected
}
