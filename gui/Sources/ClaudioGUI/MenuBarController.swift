import AppKit
import ClaudioCore
import ClaudioGUICore
import ClaudioLocalization
import ClaudioSettingsPresentation
import Combine
import SoundPacksWindow
import SwiftUI

/// Breaks the pre-`super.init()` construction cycle: `PanelView` needs an action closure before
/// `MenuBarController` can become that closure's weak owner.
@MainActor
private final class MenuBarActionRouter {
    weak var owner: MenuBarController?

    func requestSoundsSettings(
        route: SoundPacksWindowRoute,
        returnFocusTo target: PanelFocusTarget
    ) {
        owner?.requestSoundsSettingsPresentation(route: route, returnFocusTo: target)
    }

    func requestIntegrationsSettings(
        preselect host: HostID?,
        returnFocusTo target: PanelFocusTarget
    ) {
        owner?.requestIntegrationsSettingsPresentation(preselect: host, returnFocusTo: target)
    }

    func requestEventsSettings(
        route: EventSettingsWindowRoute,
        returnFocusTo target: PanelFocusTarget
    ) {
        owner?.requestEventsSettingsPresentation(route: route, returnFocusTo: target)
    }

    func audibilityInputsChanged() {
        owner?.requestHostIntegrationRefresh()
    }

    func publishHostIntegrationState(
        _ state: HostIntegrationPresentationState
    ) -> IntegrationDestinationContent? {
        owner?.publishHostIntegrationState(state)
    }

    func performGlobalShortcut(_ action: GlobalShortcutAction) {
        owner?.performGlobalShortcut(action)
    }
}

private struct PendingSettingsPresentation {
    let request: SettingsPresentationRequest
    let panelFocusTarget: PanelFocusTarget?
    let handbackApplication: NSRunningApplication?
}

/// The real menu-bar shell (ENGINEERING.md T15 D2): an `NSStatusItem` + `NSPopover` hosting
/// ``PanelView`` via `NSHostingController` — replaces T7's temporary `WindowGroup`
/// scaffolding (its own doc comment already said so: "expected to be replaced wholesale
/// once the menu bar skeleton lands").
///
/// ⚠️ **COMPILE-ONLY here** (CommandLineTools, no Xcode/simulator): this file compiles
/// cleanly, but its actual interactive behavior — click-to-toggle, popover open/close
/// animation, `.transient` dismiss-on-click-outside/Esc, first-responder/focus handoff —
/// is entirely `NSResponder`/AppKit runtime behavior that cannot be exercised by this
/// repo's headless dependency-free test harness. Every piece below is structured to be
/// CORRECT BY INSPECTION against ENGINEERING.md「无障碍规格」's focus-owner rule; a real Mac
/// manual walkthrough is required to confirm it actually behaves that way (see this task's
/// handoff `manual-verify-needed` list).
@MainActor
final class MenuBarController: NSObject, NSPopoverDelegate {
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private let hostingController: NSHostingController<PanelView>
    private let soundPacksRefreshCoordinator: SoundPacksRefreshCoordinator
    private let soundPackLibrary: SoundPackLibrary
    private let settingsWindowController: SettingsWindowController
    private let eventSettingsModel: PanelConfigController
    private let globalShortcutRegistrar: CarbonGlobalShortcutRegistrar
    private let globalShortcutSettings: GlobalShortcutSettingsModel
    private let languageStore: ClaudioPreferences
    private let integrationsModel: IntegrationDestinationModel
    private let actionRouter: MenuBarActionRouter
    private let hostIntegrations: HostIntegrationPresentationStore
    private let hostIntegrationMatrixProvider: HostIntegrationMatrixProvider
    private let bootstrapReports: BootstrapReportPresentationStore
    private let dynamicQuietObserver: DynamicQuietSystemObserver
    private var hostIntegrationRefreshTask: Task<Void, Never>?
    private var appActivationCancellable: AnyCancellable?
    private var menuBarIconCancellable: AnyCancellable?
    private var systemPowerCancellables: Set<AnyCancellable> = []
    private var hostIntegrationRefreshRevision: UInt64 = 0

    /// Owned here (not by `PanelView`) so it survives across every popover show/close cycle
    /// for the app's whole lifetime, and so `popoverDidShow` has something concrete to
    /// signal (a11y-architect FIX 4) — see ``PanelFocusCoordinator``'s doc comment.
    private let focusCoordinator = PanelFocusCoordinator()

    /// Whoever was frontmost when the popover opened. `showPopover()` takes the foreground
    /// away from them (it has to — see there); an ordinary `popoverDidClose` gives it back,
    /// while a transition to retained Settings transfers the debt to that window's owner.
    /// Nil whenever no handback is owed.
    private var previousApp: NSRunningApplication?
    /// Every production settings entry shares one close-before-show handoff. The typed route and
    /// exact panel focus target travel together, so no legacy window can race with this retained
    /// owner or leave a later popover close carrying a stale presentation.
    private var pendingSettingsPresentation: PendingSettingsPresentation?
    /// Set by the retained settings window's close callback and consumed by the next
    /// `popoverDidShow`, so focus restoration is one-shot rather than sticky across later opens.
    private var pendingRestoredPanelFocusTarget: PanelFocusTarget?

    /// 面板 shell 只接收 manager 已组合的宿主事实。内置 helper 的定位与
    /// shared bootstrap 已上移到 AppDelegate 的 composition root，不再经过面板。
    init(
        preferences: ClaudioPreferences,
        loginItemSettings: LoginItemSettingsModel,
        audioEnvironment: AudioImportEnvironment,
        hostIntegrationState: HostIntegrationPresentationState,
        integrationMatrixProvider: HostIntegrationMatrixProvider,
        integrationActionProvider: HostIntegrationActionProvider
    ) {
        let languageStore = preferences
        let soundPacksRefreshCoordinator = SoundPacksRefreshCoordinator()
        let soundPackLibrary = SoundPackLibrary(environment: audioEnvironment)
        let soundPacksEditorOwner = SoundPacksEditorOwner(
            configFile: ClaudioPaths.configFile,
            environment: audioEnvironment,
            soundPackLibrary: soundPackLibrary,
            refreshCoordinator: soundPacksRefreshCoordinator)
        let actionRouter = MenuBarActionRouter()
        let hostIntegrations = HostIntegrationPresentationStore(
            state: hostIntegrationState,
            configurationSources: [
                .claudeCode: ClaudioPaths.claudeSettingsFile.path,
                .codex: ClaudioPaths.codexHooksFile.path,
                .workBuddy: ClaudioPaths.workBuddySettingsFile.path,
            ])
        let bootstrapReports = BootstrapReportPresentationStore()
        let integrationsModel = IntegrationDestinationModel(
            content: hostIntegrations.content,
            refreshHandler: IntegrationDestinationRefreshHandler {
                [weak actionRouter, weak hostIntegrations] in
                let state = try await integrationMatrixProvider()
                guard let hostIntegrations else {
                    throw HostIntegrationPresentationError.storeUnavailable
                }
                let content =
                    actionRouter?.publishHostIntegrationState(state)
                    ?? hostIntegrations.replace(state: state)
                return IntegrationDestinationActionOutcome(
                    content: content,
                    feedbackKind: .information,
                    feedbackText: .localized(key: .feedbackRedetectedSources, arguments: []))
            },
            actionHandler: IntegrationDestinationActionHandler {
                [weak actionRouter, weak hostIntegrations] action in
                let managerOutcome = try await integrationActionProvider(action)
                guard let hostIntegrations else {
                    throw HostIntegrationPresentationError.storeUnavailable
                }
                let content =
                    actionRouter?.publishHostIntegrationState(managerOutcome.state)
                    ?? hostIntegrations.replace(state: managerOutcome.state)
                return IntegrationDestinationActionOutcome(
                    content: content,
                    feedbackKind: managerOutcome.feedbackKind,
                    feedbackText: managerOutcome.feedbackText)
            },
            preferences: languageStore,
            clipboardWriter: IntegrationDestinationClipboardAdapter.system,
            onContentChanged: { [weak hostIntegrations] content in
                hostIntegrations?.replace(content: content)
            })
        let eventSettingsModel = makeEventSettingsConfigController(
            configFile: ClaudioPaths.configFile,
            environment: audioEnvironment,
            soundPackLibrary: soundPackLibrary,
            soundPacksRefreshCoordinator: soundPacksRefreshCoordinator,
            afterFullReload: { [weak actionRouter] _ in
                actionRouter?.audibilityInputsChanged()
            })
        let globalShortcutRegistrar = CarbonGlobalShortcutRegistrar()
        let globalShortcutSettings = GlobalShortcutSettingsModel(
            adapter: globalShortcutRegistrar.makeAdapter(),
            persistence: .userDefaults(),
            actionHandler: { [weak actionRouter] action in
                actionRouter?.performGlobalShortcut(action)
            })
        let aiCueVault = AICueKeychainCredentialVault()
        let aiCueElevenLabsProvider = ElevenLabsAICueProvider()
        let aiCueMiniMaxProvider = MiniMaxAICueProvider()
        let aiCueQwenSingaporeProvider = try! QwenAICueProvider(
            profileID: .qwenSingapore)
        let aiCueQwenBeijingProvider = try! QwenAICueProvider(
            profileID: .qwenBeijing)
        let aiCueCredentialManager = AICueCredentialManager(
            vault: aiCueVault,
            validators: [
                .elevenLabsGlobal: aiCueElevenLabsProvider,
                .miniMaxGlobal: aiCueMiniMaxProvider,
            ])
        let aiCueTemporaryRoot = ClaudioPaths.root.appendingPathComponent(
            "ai-cue-temporary",
            isDirectory: true)
        let aiCueGenerator = try! AICueGenerationDispatcher(generators: [
            .elevenLabsGlobal: AICueGenerationEngine(
                credentialManager: aiCueCredentialManager,
                provider: aiCueElevenLabsProvider,
                temporaryRoot: aiCueTemporaryRoot,
                durationProbe: audioEnvironment.durationProbe),
            .miniMaxGlobal: AICueGenerationEngine(
                credentialManager: aiCueCredentialManager,
                provider: aiCueMiniMaxProvider,
                temporaryRoot: aiCueTemporaryRoot,
                durationProbe: audioEnvironment.durationProbe),
            .qwenSingapore: AICueGenerationEngine(
                credentialManager: aiCueCredentialManager,
                provider: aiCueQwenSingaporeProvider,
                temporaryRoot: aiCueTemporaryRoot,
                durationProbe: audioEnvironment.durationProbe),
            .qwenBeijing: AICueGenerationEngine(
                credentialManager: aiCueCredentialManager,
                provider: aiCueQwenBeijingProvider,
                temporaryRoot: aiCueTemporaryRoot,
                durationProbe: audioEnvironment.durationProbe),
        ])
        let aiCueViewModel = AICueGenerationViewModel(
            credentialManager: aiCueCredentialManager,
            generator: aiCueGenerator)
        let dynamicQuietObserver = DynamicQuietSystemObserver()
        let settingsPresentationSession = SettingsPresentationSession(
            dependencies: SettingsPresentationDependencies(
                preferences: languageStore,
                loginItemSettings: loginItemSettings,
                dynamicQuietPolicy: dynamicQuietObserver.policy,
                usageSettings: makeUsageSettingsModel(),
                globalShortcutSettings: globalShortcutSettings,
                aboutSettings: makeSystemAboutSettingsModel(
                    surfaceFacts: hostIntegrations.safeSurfaceFacts),
                soundPacksEditorOwner: soundPacksEditorOwner,
                soundPacksEditorNativeEffects: SoundPacksEditorNativeEffectsDispatcher(
                    adapter: SystemSoundPacksEditorNativeEffectsAdapter()),
                eventSettingsModel: eventSettingsModel,
                hostIntegrations: hostIntegrations,
                integrationsModel: integrationsModel,
                aiCueViewModel: aiCueViewModel),
            actions: makeSystemSettingsPresentationActions(
                onEventAudibilityInputsChanged: { [weak actionRouter] in
                    actionRouter?.audibilityInputsChanged()
                }))
        let settingsWindowController = SettingsWindowController(
            session: settingsPresentationSession)

        // Built BEFORE the panel so the panel's width callback can capture it (the callback can't
        // capture `self` — we're still pre-`super.init()` here).
        let popover = NSPopover()
        // `standardPanelWidth` (`ClaudioGUICore`), never a second hardcoded `312`: DESIGN.md's
        // 312pt panel width already exists as a constant, and `PanelLayoutAdaptation/panelWidth`
        // — the value the SwiftUI side actually sizes itself to — is derived from it.
        // Height is intrinsic-content-driven at runtime.
        popover.contentSize = NSSize(width: standardPanelWidth, height: 520)

        let panel = PanelView(
            audioEnvironment: audioEnvironment,
            focusCoordinator: focusCoordinator,
            hostIntegrations: hostIntegrations,
            bootstrapReports: bootstrapReports,
            languageStore: languageStore,
            soundPackLibrary: soundPackLibrary,
            soundPacksRefreshCoordinator: soundPacksRefreshCoordinator,
            onManageSounds: { [weak actionRouter] route, focusTarget in
                actionRouter?.requestSoundsSettings(
                    route: route,
                    returnFocusTo: focusTarget)
            },
            onOpenEventSettings: { [weak actionRouter] route, focusTarget in
                actionRouter?.requestEventsSettings(
                    route: route,
                    returnFocusTo: focusTarget)
            },
            onManageIntegrations: { [weak actionRouter] host, target in
                actionRouter?.requestIntegrationsSettings(preselect: host, returnFocusTo: target)
            },
            onRetryBootstrap: { [weak actionRouter] in
                actionRouter?.owner?.requestHostIntegrationRefresh(bootstrapSharedRuntime: true)
            },
            onAudibilityInputsChanged: { [weak actionRouter] in
                actionRouter?.audibilityInputsChanged()
            },
            onQuit: {
                NSApp.terminate(nil)
            },
            // T15 D5「极大 → 加宽 popover」, now actually in effect (TODOS.md:257): `PanelView`
            // widens ITSELF to `widenedPanelWidth` (360pt) at the `.maximum` Dynamic Type tier,
            // but this AppKit popover around it kept its hardcoded 312pt `contentSize` — so the
            // widened panel was being rendered inside a container that never grew, which is
            // exactly the 「不裁切、不溢出」 the degradation rule exists to prevent. `PanelView`
            // reports its real width here (on appear and on every tier change) and the popover
            // follows. Captures `popover` (a class), never `self`.
            // `[weak popover]`：强捕获会成环——`popover → contentViewController → rootView(PanelView)
            // → 这个闭包 → popover`，于是 popover 与它整棵 SwiftUI 视图树永不释放（本轮 /ship 评审：
            // Claude 对抗子代理）。今天菜单栏 app 的 popover 与进程同生共死，所以泄漏不可见；一旦将来
            // 有人重建 popover（换皮肤、换尺寸策略、多状态栏图标），它就会变成一个真实的、每次重建都
            // 涨一份的泄漏。捕获 popover 而不是 self 本来就是对的，只是漏了 weak。
            onPanelWidthChange: { [weak popover] width in
                popover?.contentSize.width = CGFloat(width)
            }
        )
        hostingController = NSHostingController(rootView: panel)

        popover.contentViewController = hostingController
        self.popover = popover
        self.soundPacksRefreshCoordinator = soundPacksRefreshCoordinator
        self.soundPackLibrary = soundPackLibrary
        self.settingsWindowController = settingsWindowController
        self.eventSettingsModel = eventSettingsModel
        self.globalShortcutRegistrar = globalShortcutRegistrar
        self.globalShortcutSettings = globalShortcutSettings
        self.languageStore = languageStore
        self.integrationsModel = integrationsModel
        self.actionRouter = actionRouter
        self.hostIntegrations = hostIntegrations
        self.hostIntegrationMatrixProvider = integrationMatrixProvider
        self.bootstrapReports = bootstrapReports
        self.dynamicQuietObserver = dynamicQuietObserver
        // `.transient`: AppKit closes the popover on a click outside it, on an app switch,
        // and — ONLY once the popover's window is key — on Esc. That last clause is the whole
        // catch: `.transient` alone does NOT buy "Esc 关闭", because a status-item popover in
        // an `.accessory` app is never key until someone activates the app. See `showPopover()`
        // for the measurement and the fix; this line used to claim Esc came for free here.
        popover.behavior = .transient

        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.statusItem = statusItem
        // Template image, auto light/dark. The 16pt Orbit Zero reduction lives in
        // `MenuBarIcon`; panel/onboarding headers use the matching full wordmark.
        Self.applyMenuBarIcon(
            showsStatusDot: languageStore.showsMenuBarStatusDot,
            language: languageStore.language,
            to: statusItem)

        super.init()

        actionRouter.owner = self
        popover.delegate = self
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)

        menuBarIconCancellable = languageStore.$snapshot
            .sink { [weak statusItem] snapshot in
                MainActor.assumeIsolated {
                    guard let statusItem else { return }
                    Self.applyMenuBarIcon(
                        showsStatusDot: snapshot.showsMenuBarStatusDot,
                        language: snapshot.language,
                        to: statusItem)
                }
            }

        let workspaceNotifications = NSWorkspace.shared.notificationCenter
        workspaceNotifications.publisher(for: NSWorkspace.willSleepNotification)
            .sink { [weak globalShortcutSettings] _ in
                MainActor.assumeIsolated {
                    globalShortcutSettings?.suspend()
                }
            }
            .store(in: &systemPowerCancellables)
        workspaceNotifications.publisher(for: NSWorkspace.didWakeNotification)
            .sink { [weak globalShortcutSettings] _ in
                MainActor.assumeIsolated {
                    globalShortcutSettings?.resume()
                }
            }
            .store(in: &systemPowerCancellables)

        appActivationCancellable = NotificationCenter.default
            .publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.soundPacksRefreshCoordinator.refreshWindowConfigProjection()
                    Task {
                        await self.soundPackLibrary.requestRefresh(
                            trigger: .applicationActivation)
                    }
                }
            }

        // GUI 首启只运行共享 bootstrap + 双侧 inspect。宿主连接必须始终来自详情窗里的显式动作。
        requestHostIntegrationRefresh(bootstrapSharedRuntime: true)
    }

    private static func applyMenuBarIcon(
        showsStatusDot: Bool,
        language: ClaudioAppLanguage,
        to statusItem: NSStatusItem
    ) {
        let accessibilityLabel = ClaudioL10n(language: language).text(
            .settingsDisplay.statusRunning)
        let icon = MenuBarIcon.make(showsStatusDot: showsStatusDot)
        icon.accessibilityDescription = accessibilityLabel
        statusItem.button?.image = icon
        statusItem.button?.setAccessibilityLabel(accessibilityLabel)
    }

    deinit {
        hostIntegrationRefreshTask?.cancel()
    }

    func applicationWillTerminate() {
        globalShortcutSettings.suspend()
        globalShortcutRegistrar.invalidate()
    }

    /// 声音包、manifest 或静音配置变化后重算同一份可听矩阵。代次保护避免较慢的旧 refresh
    /// 覆盖集成目的页动作刚发布的新状态；失败时保留最后一份诚实状态，不伪造 ready。
    fileprivate func requestHostIntegrationRefresh(
        bootstrapSharedRuntime: Bool = false
    ) {
        hostIntegrationRefreshRevision &+= 1
        let revision = hostIntegrationRefreshRevision
        hostIntegrationRefreshTask?.cancel()
        let provider = hostIntegrationMatrixProvider
        hostIntegrationRefreshTask = Task { @MainActor [weak self] in
            do {
                let state =
                    try await
                    (bootstrapSharedRuntime
                    ? provider.bootstrapSharedRuntime()
                    : provider())
                // Bootstrap can create config/packs after PanelConfigController has already read
                // its initial state. Notify that read model before the presentation revision guard:
                // opening the popover while bootstrap is in flight cancels this task and starts a
                // newer refresh, but cancellation must not discard the completed disk mutation.
                if bootstrapSharedRuntime {
                    self?.bootstrapReports.reload()
                    self?.soundPackLibrary.invalidate(packIDs: [])
                    self?.soundPacksRefreshCoordinator.completeSharedRuntimeBootstrap()
                }
                guard
                    !Task.isCancelled,
                    let self,
                    self.hostIntegrationRefreshRevision == revision
                else { return }
                let content = self.hostIntegrations.replace(state: state)
                self.integrationsModel.replaceExternalContent(content)
            } catch {
                // 集成目的页的显式“重新检测”会显示错误反馈；后台/打开面板刷新只保留
                // 上一份事实，避免一次瞬时 I/O 失败把两条宿主行抹成伪造状态。
            }
        }
    }

    /// 集成目的页的显式 refresh/action 赢过任何较早的后台刷新。发布与失效都在
    /// MainActor 上完成，因此 popover 与 retained window 永远同时切到同一份 content。
    fileprivate func publishHostIntegrationState(
        _ state: HostIntegrationPresentationState
    ) -> IntegrationDestinationContent {
        hostIntegrationRefreshRevision &+= 1
        hostIntegrationRefreshTask?.cancel()
        return hostIntegrations.replace(state: state)
    }

    @objc private func togglePopover() {
        if popover.isShown {
            // `performClose` can leave a nested SwiftUI child popover alive. `close()` cascades
            // through the child first and guarantees `popoverDidClose` clears pending window
            // transitions and local child focus state.
            popover.close()
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        let visibleHeight =
            button.window?.screen?.visibleFrame.height
            ?? NSScreen.main?.visibleFrame.height
            ?? 560
        popover.contentSize.height = min(560, max(400, visibleHeight - 32))

        // Remember who we're about to take the foreground from, so `popoverDidClose` can give
        // it back (AppKit will not: see there). Guarded on a real closed→open transition —
        // a redundant `show` while already shown would otherwise overwrite this with Claudio.
        if !popover.isShown {
            let front = NSWorkspace.shared.frontmostApplication
            if front?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                previousApp = front
            }
        }

        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)

        // Everything T15 promises — first focus lands on the first operable control, Tab /
        // Shift+Tab traversal, Space/Enter activation, Esc closes, VoiceOver announces the
        // panel — rides on the popover's window being KEY. It never is, on its own: the app
        // is `.accessory` (no Dock icon) and clicking a status item does NOT activate it, so
        // `NSApp` stays inactive and the popover's window never becomes key.
        //
        // Measured on a real Mac (2026-07-11), popover visibly open on screen:
        //     windows=0   frontmost=false   topLevelUIElements=2   (just the two menu bars)
        // Zero AX windows means VoiceOver cannot reach a single control in the panel, and an
        // inactive app means Esc/Tab/Space/Enter are delivered to whatever app IS frontmost.
        // `popoverDidShow`'s `makeFirstResponder` is a no-op against a non-key window, and
        // `.transient` only ever gave us click-outside dismissal — never Esc.
        //
        // Activating is what makes the window key, which puts it in the AX tree and in the
        // key-event path. `.transient` still closes the popover when the user clicks away or
        // switches apps (an app that deactivates dismisses its transient popover), so this
        // does not trade Esc for a popover that will not go away.
        //
        // There is no way to have the key window without the activation, and it was checked
        // one API at a time against the AppKit headers (ENGINEERING.md T15 决议): `NSPopover`
        // exposes no non-activating switch; `.nonactivatingPanel` is documented as "only
        // applicable for NSPanel"; `becomesKeyOnlyIfNeeded` points the other way; and a
        // `makeKey()` without activation is the no-op that produced the windows=0 above (an
        // inactive app has no key window at all). Escaping it means dropping NSPopover for a
        // hand-built `NSPanel` — see TODOS.md, and don't start down that road casually.
        //
        // So opening the panel costs one app switch, every time, and one part of that bill
        // cannot be refunded by `popoverDidClose`'s handback: if the user is mid-composition
        // in an IME (Chinese/Japanese/Korean, characters not yet committed), deactivating
        // their app forces the marked text to commit or drops it. That is the price of a
        // keyboard/VoiceOver-operable panel on this architecture.
        NSApp.activate(ignoringOtherApps: true)
        popover.contentViewController?.view.window?.makeKey()
    }

    /// Every panel destination closes the transient popover first, then presents the same retained
    /// Settings window from ``popoverDidClose(_:)``. The typed route replaces the former parallel
    /// window ownership while preserving the exact panel focus target for the final handback.
    fileprivate func requestSoundsSettingsPresentation(
        route: SoundPacksWindowRoute,
        returnFocusTo target: PanelFocusTarget
    ) {
        requestSettingsPresentation(
            request: .route(.sounds(route)),
            returnFocusTo: target)
    }

    /// Carries the panel's exact Sound Scope into the unified Events & Sounds destination.
    fileprivate func requestEventsSettingsPresentation(
        route: EventSettingsWindowRoute,
        returnFocusTo target: PanelFocusTarget
    ) {
        requestSettingsPresentation(
            request: .route(.events(scope: route.scope, event: route.event)),
            returnFocusTo: target)
    }

    /// Global-shortcut actions are owned by MenuBarController, not the Settings view that edits
    /// them. The route reads the panel's stable persisted scope, validates it against the current
    /// production projection, and deliberately preserves a stale known scope so Events can show
    /// the visible recovery reason instead of silently guessing another target.
    fileprivate func performGlobalShortcut(_ action: GlobalShortcutAction) {
        switch action {
        case .togglePanel:
            togglePopover()
        case .openSettings:
            requestSettingsWindowPresentation()
        case .openCurrentScopeEvents:
            requestCurrentScopeEventsFromShortcut()
        }
    }

    private func globalShortcutHandbackApplication() -> NSRunningApplication? {
        let frontmost = NSWorkspace.shared.frontmostApplication
        return resolveGlobalShortcutHandbackApplication(
            frontmostApplication: frontmost,
            previousApplication: previousApp,
            isCurrentApplication: {
                $0.processIdentifier == ProcessInfo.processInfo.processIdentifier
            })
    }

    private func requestCurrentScopeEventsFromShortcut() {
        let scopes = panelSoundScopePresentations(
            sourceRows: hostIntegrations.content.sourceRows,
            config: eventSettingsModel.config,
            language: languageStore.language)
        let storedValue = UserDefaults.standard.string(forKey: panelSoundScopeDefaultsKey)
        let route = globalShortcutEventSettingsRoute(
            storedValue: storedValue,
            scopes: scopes)

        requestSettingsPresentation(
            request: .eventShortcut(route),
            returnFocusTo: nil,
            handbackApplication: globalShortcutHandbackApplication())
    }

    /// The Integrations destination follows the same close-before-show rule as other management
    /// routes, but the unified Settings close callback first reopens the panel at the exact trigger;
    /// the later ordinary popover close finally returns activation to the original app.
    fileprivate func requestIntegrationsSettingsPresentation(
        preselect host: HostID?,
        returnFocusTo target: PanelFocusTarget
    ) {
        let selectedHost = host ?? integrationsModel.selectedHost ?? .claudeCode
        requestSettingsPresentation(
            request: .route(.integrations(surface: selectedHost.surfaceID)),
            returnFocusTo: target)
    }

    /// Production generic Settings entry. No explicit route is supplied, so the retained owner
    /// restores the last legal top-level destination from the shared typed preferences.
    func requestSettingsWindowPresentation() {
        requestSettingsPresentation(
            request: .route(nil),
            returnFocusTo: nil,
            handbackApplication: globalShortcutHandbackApplication())
    }

    private func requestSettingsPresentation(
        request: SettingsPresentationRequest,
        returnFocusTo target: PanelFocusTarget?,
        handbackApplication explicitHandback: NSRunningApplication? = nil
    ) {
        let presentation = PendingSettingsPresentation(
            request: request,
            panelFocusTarget: target,
            handbackApplication: explicitHandback ?? previousApp)
        previousApp = nil

        guard popover.isShown else {
            presentSettings(presentation)
            return
        }
        pendingSettingsPresentation = presentation
        // `close()` also closes nested popovers and guarantees the pending transition reaches the
        // delegate callback; `performClose` may be vetoed by a child window and leave stale state.
        popover.close()
    }

    private func presentSettings(_ presentation: PendingSettingsPresentation) {
        settingsWindowController.showWindow(
            request: presentation.request,
            returnFocusTo: presentation.handbackApplication
        ) { [weak self] latestHandbackApplication in
            guard let self else { return }
            let handback = latestHandbackApplication ?? presentation.handbackApplication
            if let target = presentation.panelFocusTarget {
                _ = self.restorePanelFocus(
                    to: target,
                    latestHandbackApplication: handback)
            } else {
                self.activateHandbackApplication(handback)
            }
        }
    }

    private func restorePanelFocus(
        to target: PanelFocusTarget,
        latestHandbackApplication: NSRunningApplication?
    ) -> Bool {
        // Unified Settings may have remained visible while the user visited another app. Preserve
        // the original debt when no such activation occurred; otherwise the latest app becomes the
        // recipient after the restored popover eventually closes.
        if let latestHandbackApplication {
            previousApp = latestHandbackApplication
        }
        pendingRestoredPanelFocusTarget = target
        showPopover()
        return popover.isShown
    }

    private func activateHandbackApplication(_ application: NSRunningApplication?) {
        guard
            let application,
            !application.isTerminated,
            application.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else { return }

        if #available(macOS 14.0, *) {
            NSApp.yieldActivation(to: application)
            application.activate()
        } else {
            application.activate(options: [])
            NSApp.deactivate()
        }
    }

    // MARK: - NSPopoverDelegate — focus owner (ENGINEERING.md「无障碍规格」, a11y-architect
    // FIX 4)
    //
    // "打开焦点落首个可操作项...VoiceOver 进入先播报面板标题 + 当前包" — a TWO-step handoff:
    // (1) make the hosting view itself first responder — puts keyboard focus inside the
    // popover's view hierarchy at all, the prerequisite for Tab/SwiftUI focus to do
    // anything; (2) THEN tell `focusCoordinator` the popover just showed, which `PanelView`
    // observes to set its real `@FocusState` to `panelFocusOrder(_:)`'s current first item
    // (``PanelView/applyFirstFocus()``) — routing focus to the SPECIFIC first control, not
    // just the container. Order matters: step 2 only has an observable effect once step 1
    // has already put the hosting view into the responder chain.
    func popoverDidShow(_ notification: Notification) {
        // 真实 hook 回执与宿主外部配置可在 app 后台期间变化。每次打开
        // 都经 manager 重探两侧，面板不直接读 settings.json/hooks.json。
        requestHostIntegrationRefresh()
        popover.contentViewController?.view.window?.makeFirstResponder(
            popover.contentViewController?.view)
        let restoredTarget = pendingRestoredPanelFocusTarget
        pendingRestoredPanelFocusTarget = nil
        focusCoordinator.requestFocus(target: restoredTarget)
    }

    // The other half of `showPopover()`'s `NSApp.activate` — the two are a pair, and shipping
    // the activate without this is a regression, not a partial fix.
    //
    // AppKit does not deactivate an app just because its last window went away. So without a
    // handback: Esc closes the panel and leaves an `.accessory` app frontmost with ZERO
    // windows. The menu bar on screen still belongs to the app the user is looking at, so
    // nothing tells them the foreground moved — they keep typing and every keystroke is
    // swallowed, and ⌘Q quits Claudio instead of their editor. That failure lands squarely on
    // the keyboard/VoiceOver users the Esc path exists for.
    //
    // This replaces `makeFirstResponder(statusItem.button)`, which had been standing in for
    // 「关闭后焦点回菜单栏 status item」 while doing nothing at all: `statusItem.button` lives in
    // the system-owned `NSStatusBarWindow`, whose `canBecomeKeyWindow` is false, and AppKit
    // delivers key events only to the KEY window's first responder — setting one on a window
    // that can never be key changes nothing. (It isn't in the app's AX window tree either; it
    // hangs off `AXExtrasMenuBar`, so the VoiceOver cursor doesn't follow a first responder
    // there.) The contract cannot be met literally, and what it is actually for — "the panel
    // closed, someone give the keyboard back" — is met by returning it to the only party that
    // can hold it: the app the user came from. ENGINEERING.md's wording was corrected to say so.
    func popoverDidClose(_ notification: Notification) {
        // 必须在任何早返回之前通知 MasterVolumeRow 冲刷拖动会话。
        focusCoordinator.notePanelHidden()

        let settingsPresentation = pendingSettingsPresentation
        pendingSettingsPresentation = nil
        if let settingsPresentation {
            presentSettings(settingsPresentation)
            return
        }

        let previous = previousApp
        previousApp = nil

        // Not active ⇒ the popover closed BECAUSE the user went elsewhere (clicked another
        // app, ⌘-Tabbed away). That app owns the foreground now, and it is not necessarily
        // `previous` — pulling it back would be us overriding the user's own choice.
        guard NSApp.isActive,
            let previous,
            !previous.isTerminated,
            previous.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else { return }

        activateHandbackApplication(previous)
    }
}
