import AppKit
import ClaudioCore
import ClaudioGUIComponents
import ClaudioGUICore
import ClaudioLocalization
import SwiftUI

/// The menu-bar panel's always-operational dual-host surface. Host rows and event coverage are
/// projected from the shared adapter manager; this view never probes Claude Code or Codex files.
/// Pack completeness, focus order, contrast and Dynamic Type decisions are likewise made in
/// `ClaudioGUICore`/`ClaudioCore` before this view renders. This file lays out those facts, wires
/// the tested sound-pack controls, and resolves preview playback via
/// ``NSSoundAudioPreviewPlayer``.
///
/// COMPILE-ONLY here (CommandLineTools, no Xcode/simulator/`#Preview`): rendering, the
/// operational-panel wiring end-to-end, and Dynamic Type behavior are manual-verify on a
/// real Mac. `ClaudioGUICore`'s pieces this view composes (``SoundPackLibrarySnapshot``,
/// ``loadPanelConfig``, ``panelLayoutAdaptation``, ``panelFocusOrder``) are each independently
/// tested — this file's own job is ONLY correct composition, not re-deciding anything.
public struct PanelView: View {
    /// 「这一句刚说过」的去重器（T17g）—— 让「一趟 update pass ≤ 一条播报」在结构上成立。
    /// 它必须活得比一次 `body` 求值长（跨 handler、跨帧），所以是 `@StateObject` 而不是局部变量。
    @StateObject private var announcer: PanelAnnouncer
    /// 运行态面板的 config 读模型 + 流经它的写操作（`configState` / `config` / `eventRows` /
    /// `packCards` / `packSwitchError`，以及 `toggleMute` / `switchPack` / `reload` /
    /// `reloadConfigOnly`）—— **全部搬进了 `ClaudioGUICore.PanelConfigController`**（红队 9cccc9c
    /// 兑现台账那条 P2）。理由见那个类的文档：这几段逻辑曾是本视图的 `@State` + 私有方法，而本视图住在
    /// `@main` executableTarget、测试 import 不进来，于是红队实测三条「改坏行为、两套测试全绿」的变异
    /// （refresh 不重载 configState / 某条路由 case 成死代码 / 静音去掉取反）。搬进可实例化的类之后，
    /// `PanelConfigControllerSuite` 用真磁盘把这三条各钉一条行为断言。
    ///
    /// 本视图这一侧只剩两件文本绊线**够得着**的事：① `operationalPanel` 从 `panelModel` 读状态渲染；
    /// ② 按钮把 action 接到 `panelModel` 的方法（`ViewWiringSuite` 的存在性检查）。
    @StateObject private var panelModel: PanelConfigController

    /// The REAL `@FocusState` `panelFocusOrder(_:)`'s pure model drives (a11y-architect FIX
    /// 4, CRITICAL/HIGH — `panelFocusOrder` was computed but never consumed anywhere in
    /// production before this fix). Every focusable control (`EventRowView`'s action/mute
    /// buttons, `PackGalleryView`'s cards, `OnboardingView`'s CTAs) reports into THIS one
    /// binding, keyed by the SAME ``PanelFocusTarget`` identities the pure model returns —
    /// see ``applyFirstFocus()``.
    @FocusState private var focusedTarget: PanelFocusTarget?

    /// Signals "the popover just showed" from `MenuBarController` (a11y-architect FIX 4) —
    /// see ``PanelFocusCoordinator``'s doc comment for why `.onAppear` alone isn't reliable
    /// enough as that signal. `@ObservedObject`, not `@StateObject`: this instance is OWNED
    /// and shared by `MenuBarController` (constructed once for the app's lifetime, passed in
    /// here), never created fresh per `PanelView` value.
    @ObservedObject private var focusCoordinator: PanelFocusCoordinator
    /// Shared with the retained integrations window. Both surfaces render the same immutable
    /// adapter-derived presentation instead of probing host files independently.
    @ObservedObject private var hostIntegrations: HostIntegrationPresentationStore
    @ObservedObject private var bootstrapReports: BootstrapReportPresentationStore
    /// App-lifetime explicit language state shared with both retained management windows.
    @ObservedObject private var languageStore: ClaudioLanguageStore

    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(ClaudioInterfaceTextSize.defaultsKey)
    private var interfaceTextSizeRaw = ClaudioInterfaceTextSize.defaultValue.rawValue
    @AppStorage("claudio.panel.selected-surface")
    private var selectedSurfaceRaw = "global"
    /// The two host cards share the tallest measured natural card height. The measurement is
    /// kept at the panel level so a width, text-size, or host-state change re-runs the same
    /// equalization for both buttons.
    @State private var hostSourceCardHeight: CGFloat?

    // Reduced transparency is satisfied structurally: `.background(
    // ClaudioColor.panel(colorScheme))` below is a near-solid opaque color, never a
    // `.material`/`.ultraThinMaterial`/vibrancy effect (DESIGN.md「面板材质（关键决策）」:
    // "不用满毛玻璃 vibrancy"). No code path in this tree introduces one.

    private let audioEnvironment: AudioImportEnvironment
    private let configFile: URL
    private let lockFile: URL
    private let previewPlayer: AudioPreviewPlaying
    private let soundPackLibrary: SoundPackLibrary
    private let soundPacksRefreshCoordinator: SoundPacksRefreshCoordinator
    private let onManageSounds: @MainActor (SoundPacksWindowRoute, PanelFocusTarget) -> Void
    private let onManageIntegrations: @MainActor (PanelFocusTarget) -> Void
    private let onRetryBootstrap: @MainActor () -> Void
    private let onAudibilityInputsChanged: @MainActor () -> Void
    private let onQuit: @MainActor () -> Void

    /// Reports this panel's CURRENT ``PanelLayoutAdaptation/panelWidth`` to whoever owns the
    /// AppKit container around it — in production, ``MenuBarController``, which resizes its
    /// `NSPopover.contentSize` to match (T15 D5's 「极大 → 加宽 popover」 degradation rule).
    ///
    /// This callback is the whole reason that rule actually WORKS: the SwiftUI side already sized
    /// itself via `.frame(width: layoutAdaptation.panelWidth)`, but `NSPopover` had a HARDCODED
    /// 312pt `contentSize`, so at the `.maximum` Dynamic Type tier the panel widened to 360pt
    /// INSIDE a popover that stayed 312pt wide (TODOS.md:257). Defaulted to a no-op so previews /
    /// the state gallery — which have no popover to resize — need not care.
    private let onPanelWidthChange: (Double) -> Void

    public init(
        audioEnvironment: AudioImportEnvironment,
        configFile: URL = ClaudioPaths.configFile,
        lockFile: URL = ClaudioPaths.configLockFile,
        focusCoordinator: PanelFocusCoordinator = PanelFocusCoordinator(),
        hostIntegrations: HostIntegrationPresentationStore,
        bootstrapReports: BootstrapReportPresentationStore,
        languageStore: ClaudioLanguageStore,
        soundPackLibrary: SoundPackLibrary,
        soundPacksRefreshCoordinator: SoundPacksRefreshCoordinator,
        onManageSounds: @escaping @MainActor (SoundPacksWindowRoute, PanelFocusTarget) -> Void,
        onManageIntegrations: @escaping @MainActor (PanelFocusTarget) -> Void,
        onRetryBootstrap: @escaping @MainActor () -> Void,
        onAudibilityInputsChanged: @escaping @MainActor () -> Void,
        onQuit: @escaping @MainActor () -> Void,
        onPanelWidthChange: @escaping (Double) -> Void = { _ in }
    ) {
        self.audioEnvironment = audioEnvironment
        self.configFile = configFile
        self.lockFile = lockFile
        self.focusCoordinator = focusCoordinator
        self.hostIntegrations = hostIntegrations
        self.bootstrapReports = bootstrapReports
        self.languageStore = languageStore
        self.soundPackLibrary = soundPackLibrary
        self.soundPacksRefreshCoordinator = soundPacksRefreshCoordinator
        self.onManageSounds = onManageSounds
        self.onManageIntegrations = onManageIntegrations
        self.onRetryBootstrap = onRetryBootstrap
        self.onAudibilityInputsChanged = onAudibilityInputsChanged
        self.onQuit = onQuit
        self.onPanelWidthChange = onPanelWidthChange
        // Construct the shared `ClaudioGUIComponents` player here. Both GUI surfaces reuse the
        // same retention/volume implementation while owning independent playback lifetimes.
        self.previewPlayer = NSSoundAudioPreviewPlayer()

        let onAudibilityInputsChanged = self.onAudibilityInputsChanged
        let panelModel = PanelConfigController(
            configFile: configFile,
            lockFile: lockFile,
            environment: audioEnvironment,
            soundPackLibrary: soundPackLibrary,
            afterFullReload: { _ in
                onAudibilityInputsChanged()
            },
            soundPacksRefreshCoordinator: soundPacksRefreshCoordinator)

        _announcer = StateObject(wrappedValue: PanelAnnouncer())
        _panelModel = StateObject(wrappedValue: panelModel)
    }

    public var body: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 12) {
                    header
                    hostSourcesSection
                    operationalPanel
                }
                .padding(13)
            }
            PanelQuitFooter(
                language: languageStore.language,
                typeScale: typeScale,
                focusedTarget: $focusedTarget,
                onQuit: onQuit)
        }
        .frame(width: layoutAdaptation.panelWidth)
        .background(ClaudioTheme.panelGradient(colorScheme))
        .overlay(
            RoundedRectangle(cornerRadius: ClaudioTheme.Radius.panel)
                .strokeBorder(ClaudioTheme.hairline(colorScheme), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: ClaudioTheme.Radius.panel))
        .environment(\.dynamicTypeSize, interfaceTextSize.dynamicTypeSize)
        // `.onAppear` deliberately does not request another library refresh. The app-lifetime
        // `SoundPackLibrary` performs its scan off the main actor and replays the latest state;
        // `showCount` below is the single presentation signal that asks it to revalidate.
        //
        // T17g：它也**不播报**，一字不差的同一条推理 —— `.onAppear` 与 `.onChange(showCount)` 在同一次
        // 打开里**都会**跑，两条 post 会抢同一条「一次一句」的通道，而谁先谁后取决于 `onAppear` 与
        // `popoverDidShow` 的 AppKit 时序：一个没实测过的语义。`showCount` 是这两个信号里可靠的那个
        // （见 ``PanelFocusCoordinator`` 的文档），所以播报只挂它。
        .onAppear {
            synchronizeSelectedSoundSurface()
            applyFirstFocus()
            onPanelWidthChange(layoutAdaptation.panelWidth)
        }
        // a11y-architect FIX 4: `MenuBarController.popoverDidShow` bumps
        // `focusCoordinator.showCount` every time the popover becomes visible — the ONE place
        // "the popover just (re)opened, re-read current panel state" is handled. Host config and
        // receipts refresh independently through MenuBarController's manager-backed provider.
        .onChange(of: focusCoordinator.showCount) { _ in
            panelModel.reload()
            applyFirstFocus()
            announcePanelSummary()
        }
        .onChange(of: bootstrapReports.records) { _ in
            guard focusCoordinator.showCount > focusCoordinator.hideCount else { return }
            applyFirstFocus()
            announcePanelSummary()
        }
        // T15 D5 「极大 → 加宽 popover」: SwiftUI already widened ITSELF (`.frame(width:)` above);
        // this tells the AppKit popover around it to follow (see ``onPanelWidthChange``).
        .onChange(of: layoutAdaptation.panelWidth) { newWidth in
            onPanelWidthChange(newWidth)
        }
        .onChange(of: panelModel.libraryPresentationState) { state in
            guard !state.hasUsableSnapshot, isEventFocusTarget(focusedTarget) else { return }
            applyFirstFocus()
        }
        // `.contain` keeps every control individually reachable by the VoiceOver cursor; the
        // label names the container itself, which otherwise reads as an anonymous group. It is
        // NOT what delivers 「VoiceOver 进入先播报面板标题 + 当前包」 — a label is read when the
        // cursor lands on the element, and the cursor lands on a control, not on the group.
        // ``announcePanelSummary()`` is what actually says the sentence on open.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(headerAccessibilityLabel)
    }

    /// 每次 popover 真实打开后的唯一面板播报出口。它从共享呈现取两条声音
    /// 来源数，再带上刚重读的当前声音包；去重仍由 ``PanelAnnouncer`` 负责。
    ///
    /// post 推迟到下一趟 main queue，让 AppKit 先把 popover 变成 key window 并放入
    /// AX 树。排队前捕获 `hideCount`，排队后先复核；如果可见代次已变，说明用户
    /// 已离开面板，这一句既不 post，也不消费去重器。
    private func announcePanelSummary() {
        let announcer = self.announcer
        let coordinator = focusCoordinator
        let panelModel = self.panelModel
        let sourceCount = hostIntegrations.content.sourceRows.count
        let hideCount = coordinator.hideCount
        DispatchQueue.main.async {
            // `DispatchQueue.main.async` 让 AppKit 先完成 key-window/AX 交接。该闭包
            // 运行在主线程，但类型系统不把它视为 `@MainActor`；
            // `assumeIsolated` 只把这个运行期事实交给编译器。
            MainActor.assumeIsolated {
                // 先复核可见代次，再消费去重器或 post。
                guard coordinator.hideCount == hideCount else { return }
                let packName = panelModel.selectedPackMetadata.displayName
                let l10n = ClaudioL10n(language: languageStore.language)
                let base = l10n.format(.panelHeader, Int64(sourceCount))
                let header =
                    packName.isEmpty
                    ? base
                    : l10n.format(.panelHeaderWithPack, Int64(sourceCount), packName as NSString)
                let pendingReports = bootstrapReports.pendingAnnouncementRecords()
                let reports = pendingReports.map(bootstrapReportAnnouncement).joined(separator: " ")
                let candidate = [dualHostPanelAnnouncement(header: header), reports]
                    .compactMap { $0 }
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
                guard
                    let sentence = announcer.consume(
                        candidate,
                        openCount: coordinator.showCount)
                else { return }
                NSAccessibility.post(
                    element: NSApp as Any,
                    notification: .announcementRequested,
                    userInfo: [
                        .announcement: sentence,
                        .priority: NSAccessibilityPriorityLevel.high.rawValue,
                    ])
                bootstrapReports.markAnnounced(pendingReports)
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center) {
                ClaudioOrbitWordmark(height: 22 * typeScale)
                Spacer(minLength: 8)
                interfaceOptionsMenu
            }
            Text(
                selectedPackDisplayName.isEmpty
                    ? l10n.text(.panelSelectedPackNone)
                    : selectedPackDisplayName
            )
            .font(.system(size: 14 * typeScale, weight: .semibold, design: .rounded))
            .foregroundColor(ClaudioTheme.text(colorScheme))
            .lineLimit(2)
            Text(audibleEventSummary)
                .font(.system(size: 11 * typeScale, design: .rounded))
                .foregroundColor(ClaudioTheme.secondaryText(colorScheme))
        }
        .accessibilityLabel(headerAccessibilityLabel)
    }

    private var interfaceOptionsMenu: some View {
        InterfaceTextSizeControl(
            selection: interfaceTextSizeBinding,
            languageStore: languageStore)
    }

    private var l10n: ClaudioL10n { ClaudioL10n(language: languageStore.language) }

    private var interfaceTextSizeBinding: Binding<ClaudioInterfaceTextSize> {
        Binding(
            get: { ClaudioInterfaceTextSize(storedValue: interfaceTextSizeRaw) },
            set: { interfaceTextSizeRaw = $0.rawValue })
    }

    private var headerAccessibilityLabel: String {
        let packName = selectedPackDisplayName
        let base = l10n.format(.panelHeader, Int64(hostIntegrations.content.sourceRows.count))
        let withPack =
            packName.isEmpty
            ? base
            : l10n.format(
                .panelHeaderWithPack, Int64(hostIntegrations.content.sourceRows.count),
                packName as NSString)
        let separator = languageStore.language == .english ? ", " : "，"
        return "\(withPack)\(separator)\(audibleEventSummary)"
    }

    private var hostSourcesSection: some View {
        HStack(alignment: .top, spacing: 8) {
            ForEach(localizedHostRows) { row in
                HostSourceRowView(
                    row: row,
                    typeScale: typeScale,
                    language: languageStore.language,
                    focusedTarget: $focusedTarget,
                    equalizedHeight: hostSourceCardHeight,
                    onSelect: { onManageIntegrations(.hostSource(row.host)) }
                )
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .onPreferenceChange(HostSourceCardHeightPreferenceKey.self) { heights in
            guard let maximum = heights.values.max(), maximum > 0 else { return }
            guard hostSourceCardHeight.map({ abs($0 - maximum) > 0.5 }) ?? true else { return }
            hostSourceCardHeight = maximum
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(l10n.text(.panelSources))
    }

    private var localizedHostRows: [HostSourceRowPresentation] {
        localizedHostSourceRows(
            hostIntegrations.content.sourceRows,
            language: languageStore.language)
    }

    private var audibleEventCount: Int {
        panelModel.eventRows.filter {
            eventPreviewAvailability(
                coverage: $0.coverage,
                masterVolume: panelModel.config.masterVolume
            ).isAvailable
        }.count
    }

    private var audibleEventSummary: String {
        localizedPanelAudibleEventSummary(
            audibleEventCount: audibleEventCount,
            libraryState: panelModel.libraryPresentationState,
            language: languageStore.language)
    }

    /// Header 与事件区标题共用这一份 current-pack 读数。它不看 `packCards`：星标显示集可合法地
    /// 隐去当前包，而这两处仍必须播/显示 manifest 里的真名。
    private var selectedPackDisplayName: String {
        panelModel.selectedPackMetadata.displayName
    }

    // MARK: - Operational panel (installed state)

    @ViewBuilder
    private var operationalPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            soundSurfaceSelector
            // D23 定稿④：路由到已经存在的自救路径，零新机制。`configState.topContent` 决定这一块顶部
            // 内容显示什么——`.events`（= `.operational`）是今天这五行事件覆盖度 + 主音量滑块；`.needsPack`
            //（还没有人选过包）换成画廊空态「先选包」，`PackGalleryView` 本身仍然照常渲染在下面（自救路径
            // 本来就通：点一个声音包就是 ``selectPack``，会建出一份正确的 config）；`.configFailure`（=
            // `.malformed`/`.unwritable`）换成诚实失败态 + 可执行的修复指令——不禁用任何控件（写者本来就
            // 全部 fail closed），只是不再假装一切正常（D19 已作废：不是禁用一个滑块，是整个面板换一个诚实的态）。
            //
            // 这里 switch 的是 `.topContent`（`PanelConfigState.topContent`，映射由 `PanelConfigSuite` 真行为
            // 单测钉死），不是裸 `configState`——`applyFirstFocus` 的 `hasMasterVolume`/`hasConfigFailureNotice`
            // 读**同一个**分类，渲染判据与焦点判据从此在**决策级**一致（不再各写一份 `switch configState`），
            // 决策级漂移由类型堵死。但**呈现级**的 render 映射仍是手写：这个 switch 里 case→哪个子视图 没有
            // import 单测钉（塞错子视图、两颗投影仍全绿），要 ViewInspector/XCTest 才挡得住、本机没有——ViewWiringSuite
            // 只文本探针它「还在」（残余呈现级洞见 TODOS.md「render 映射仍是手写 switch」）
            //（/codex review f54d335 P1#1，取代 26bba37 那轮「两段 switch + 文本绊线防漂移」的设计）。
            switch panelModel.configState.topContent {
            case .events:
                if panelModel.libraryPresentationState.hasUsableSnapshot {
                    Text("\(selectedPackDisplayName) · \(l10n.text(.panelEvents))")
                        .font(.system(size: 11 * typeScale, weight: .semibold))
                        .foregroundColor(ClaudioColor.textSecondary(colorScheme))
                    ForEach(panelModel.eventRows, id: \.event) { row in
                        EventRowView(
                            row: row,
                            hostIndicators: localizedEventHostIndicators(
                                eventHostIndicatorPresentations(
                                    event: row.event,
                                    matrix: hostIntegrations.content.matrix),
                                language: languageStore.language),
                            previewAvailability: eventPreviewAvailability(
                                coverage: row.coverage,
                                masterVolume: panelModel.config.masterVolume),
                            language: languageStore.language,
                            focusedTarget: $focusedTarget,
                            adaptation: layoutAdaptation,
                            onOpenEditor: {
                                onManageSounds(
                                    .editEvent(
                                        packID: panelModel.config.selectedPack,
                                        event: row.event),
                                    .eventSound(row.event))
                            },
                            onPreview: { playPreview(for: row) },
                            onToggleMute: {
                                panelModel.toggleMute(row.event)
                                onAudibilityInputsChanged()
                            })
                    }
                } else {
                    libraryEventFactsPlaceholder
                }
                // PLAN-MASTER-VOLUME.md 阶段 D：位置对齐线框——五行事件之后、拖入区之前。只在
                // `.events`（= `.operational`）渲染（D23 定稿 + D41：这是滑块唯一真的出现在屏幕上的态）。
                // `applyFirstFocus()` 的 `hasMasterVolume: isOperational` 从**同一个** `.topContent` 分类派生
                //（`isOperational = (content == .events)`），所以渲染判据与焦点判据自动一致——「不在屏幕上的
                // 控件不得占用焦点位」这条铁律由类型担保，不再靠两处手动同步。
                //
                // `setMasterVolume` 的完整行为（写、republish 错误、按结果路由刷新）整段住在
                // `panelModel` 里（`PanelConfigControllerSuite` 用真磁盘钉死）——这里只转发。
                MasterVolumeRow(
                    diskVolume: panelModel.config.masterVolume,
                    onCommit: { volume in
                        let landed = panelModel.setMasterVolume(volume)
                        // Like the config-only mute path above, every real commit attempt must
                        // republish the matrix from disk. A success can cross the global 0/non-zero
                        // audibility boundary; a failure may still reveal an external config change
                        // through PanelConfigController's post-attempt reload.
                        onAudibilityInputsChanged()
                        return landed
                    },
                    focusCoordinator: focusCoordinator,
                    focusedTarget: $focusedTarget,
                    adaptation: layoutAdaptation,
                    language: languageStore.language)
            case .needsPack:
                needsPackNotice
            case .configFailure(let reason):
                configFailureNotice(reason: reason)
            }
            // 绝不静默吞错（项目规则）—— 静音写回失败、切包失败、主音量写回失败**都**在这里如实
            // 上报，合并成一个有序去重列表（PLAN-MASTER-VOLUME.md Step 5 · D3，`PanelWriteFailures.swift`）：
            // 多条可以同时存在（互不顶替），顺序稳定（静音 → 切包 → 主音量），三个写者撞上同一份
            // `.lockBusy`/`.lockFailed` 文案时只保留一条。`.configMissing` 已经在纯函数内部被滤掉
            // （D43）：那个失败不面向用户——写者据此把 `configState` 重路由到 `.needsPack`，「先选包」
            // 空态卡本身就是解释，再印一遍 description 是重复且从未 QA 过的字符串。
            //
            // `.lockBusy` 仍然要渲染，但**它的成因已经变了**（锁分离，D9）：`setEventEnabled` /
            // `selectPack` / `setMasterVolume` 现在拿 `config.lock`，`claudio play` 拿 `play.lock` ——
            // 两者不再相撞，「每个 Claude Code 事件 spawn 一次 play 就可能吞掉一次点击」那条高频路径
            // **已经没了**。今天 `.lockBusy` 只剩两个真实来源：另一个 config.json 写者（第二个 GUI
            // 实例，或用户手动跑 `claudio use`）—— 低频，但绝不是零。渲染保留（项目铁律：绝不静默
            // 吞错），文案本来就写好在各自的错误枚举里。
            ForEach(
                Array(
                    panelWriteFailures(
                        muteError: panelModel.muteError,
                        packSwitchError: panelModel.packSwitchError,
                        masterVolumeError: panelModel.masterVolumeError
                    ).enumerated()), id: \.offset
            ) { _, message in
                FailureRow(message: message)
            }
            if let issue = panelModel.surfaceSoundIssue {
                FailureRow(message: issue)
            }
            // T17f：**这里是告知真正的家 —— 而且位置本身是它文案的一部分。**
            //
            // 一次成功的「接管」必然把 state 推成 `.installed`（`runDiskAction` 无条件 `refresh()`），
            // 而 `.installed` 渲染的正是这个运行态面板 —— onboarding 卡此刻根本不在屏幕上。所以
            // 「你选的包没了、已替你换成 X」「你那个读不出的包被搬到了 Y」这两句话，**每一次都诞生
            // 在这一侧**。上一版这里一行都没有，于是它们每一次都无声。
            //
            // **紧挨在 `PackGalleryView` 之前**，这一条是硬约束，不是排版口味：那句文案白纸黑字写着
            // 「你随时可以在**下面的**声音包里换成别的」。因此告知必须留在画廊之前。
            //
            // 换句话说：**移动这个 `ForEach` 到画廊下方，就等于把那句文案变成谎话。** 要改位置，
            // 先改文案。（`runSetupNoticeSuites` 钉住了「文案里有『下面的声音包』」这一半；另一半
            // ——「它真的在下面」—— 只有这条注释和你的眼睛守着。）
            bootstrapReportSection
            Text(l10n.text(.panelSoundPacks))
                .font(.system(size: 11 * typeScale, weight: .semibold))
                .foregroundColor(ClaudioColor.textSecondary(colorScheme))
            if let reason = soundPackLibraryRefreshFailureReason {
                VStack(alignment: .leading, spacing: 6) {
                    FailureRow(message: reason)
                    soundPackLibraryRetryButton
                }
            }
            panelPackSection
            if case .loadFailed = panelModel.libraryPresentationState {
                soundPackLibraryRetryButton
            }
            manageSoundsRow
        }
    }

    private var selectableSoundSourceRows: [HostSourceRowPresentation] {
        hostIntegrations.content.sourceRows.filter { $0.status != .notConnected }
    }

    private var soundSurfaceSelector: some View {
        HStack(spacing: 8) {
            Picker(l10n.text(.panelSoundScope), selection: $selectedSurfaceRaw) {
                Text(l10n.text(.panelGlobalDefaults)).tag("global")
                ForEach(selectableSoundSourceRows) { row in
                    Text(localizedHostName(row.host, language: languageStore.language))
                        .tag(row.host.surfaceID.rawValue)
                }
            }
            .labelsHidden()
            .accessibilityLabel(l10n.text(.panelSoundScope))
            .accessibilityIdentifier("panel.sound-scope")
            .onChange(of: selectedSurfaceRaw) { rawValue in
                panelModel.selectSoundSurface(
                    rawValue == "global" ? nil : HostSurfaceID(rawValue: rawValue))
            }

            if panelModel.selectedSurface != nil {
                Button(l10n.text(.panelResetSurface)) {
                    panelModel.resetSelectedSurfaceOverrides()
                    onAudibilityInputsChanged()
                }
                .buttonStyle(.borderless)
                .help(l10n.text(.panelResetSurfaceHint))
                .accessibilityLabel(l10n.text(.panelResetSurface))
                .accessibilityIdentifier("panel.sound-scope.reset")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(l10n.text(.panelSoundScope))
    }

    private func synchronizeSelectedSoundSurface() {
        let available = selectableSoundSourceRows.map { $0.host.surfaceID.rawValue }
        if selectedSurfaceRaw != "global", !available.contains(selectedSurfaceRaw) {
            selectedSurfaceRaw = available.first ?? "global"
        }
        panelModel.selectSoundSurface(
            selectedSurfaceRaw == "global" ? nil : HostSurfaceID(rawValue: selectedSurfaceRaw))
    }

    @ViewBuilder
    private var bootstrapReportSection: some View {
        if let error = bootstrapReports.acknowledgementError {
            FailureRow(message: error)
        }
        ForEach(bootstrapReports.records) { record in
            let reportID = record.id.uuidString
            let failure = record.events.contains { event in
                if case .failure = event { return true }
                return false
            }
            VStack(alignment: .leading, spacing: 7) {
                Text(bootstrapReportMessage(record))
                    .font(.system(size: 11 * typeScale, weight: .medium))
                    .foregroundStyle(failure ? Color.red : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    if failure {
                        Button(languageStore.language == .english ? "Retry" : "重试") {
                            onRetryBootstrap()
                        }
                        .accessibilityIdentifier("bootstrap-report.retry")
                        .focused($focusedTarget, equals: .bootstrapReportRetry(id: reportID))
                        Button(
                            languageStore.language == .english
                                ? "Connections & diagnostics" : "打开连接与诊断"
                        ) {
                            onManageIntegrations(.hostSource(.claudeCode))
                        }
                        .accessibilityIdentifier("bootstrap-report.diagnostics")
                        .focused(
                            $focusedTarget,
                            equals: .bootstrapReportDiagnostics(id: reportID))
                    }
                    if let path = bootstrapReportRevealPath(record) {
                        Button(
                            languageStore.language == .english ? "Show in Finder" : "在 Finder 中显示"
                        ) {
                            NSWorkspace.shared.activateFileViewerSelecting([
                                URL(fileURLWithPath: path)
                            ])
                        }
                        .accessibilityIdentifier("bootstrap-report.reveal")
                        .focused($focusedTarget, equals: .bootstrapReportReveal(id: reportID))
                    }
                    if record.events.contains(where: { event in
                        if case .selectionChanged = event { return true }
                        return false
                    }) {
                        Button(languageStore.language == .english ? "Manage sounds" : "管理声音包") {
                            onManageSounds(.overview, .manageSounds)
                        }
                        .accessibilityIdentifier("bootstrap-report.manage-sounds")
                        .focused(
                            $focusedTarget,
                            equals: .bootstrapReportManageSounds(id: reportID))
                    }
                    Spacer(minLength: 0)
                    Button(languageStore.language == .english ? "Got it" : "知道了") {
                        bootstrapReports.acknowledge(record.id)
                    }
                    .accessibilityIdentifier("bootstrap-report.acknowledge")
                    .focused(
                        $focusedTarget,
                        equals: .bootstrapReportAcknowledge(id: reportID))
                }
                .buttonStyle(.bordered)
            }
            .padding(9)
            .background((failure ? Color.red : Color.orange).opacity(0.09))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .accessibilityElement(children: .contain)
            .accessibilityLabel(bootstrapReportMessage(record))
        }
    }

    private func bootstrapReportMessage(_ record: BootstrapReportRecord) -> String {
        let english = languageStore.language == .english
        let parts = record.events.map { event -> String in
            switch event {
            case .failure(let code):
                return english ? "Startup repair failed (\(code))." : "启动修复失败（\(code)）。"
            case .helperCopied:
                return english ? "The helper was installed." : "helper 已完成安装。"
            case .packPublished(let packID):
                return english ? "Installed sound pack \(packID)." : "已发布声音包 \(packID)。"
            case .packSalvaged(let packID, let movedTo):
                return english
                    ? "Moved unreadable pack \(packID) to \(movedTo); no files were deleted."
                    : "无法读取的声音包 \(packID) 已搬到 \(movedTo)，没有删除任何文件。"
            case .selectionChanged(let removed, let selected):
                if let removed {
                    return english
                        ? "The missing selection \(removed) was replaced with \(selected)."
                        : "缺失的选中包 \(removed) 已自动改为 \(selected)。"
                }
                return english ? "Selected \(selected)." : "已自动选择 \(selected)。"
            }
        }
        let count =
            record.occurrenceCount > 1
            ? (english
                ? " Repeated \(record.occurrenceCount) times."
                : " 已重复 \(record.occurrenceCount) 次。")
            : ""
        return parts.joined(separator: " ") + count
    }

    private func bootstrapReportRevealPath(_ record: BootstrapReportRecord) -> String? {
        record.events.compactMap { event in
            if case .packSalvaged(_, let movedTo) = event { return movedTo }
            return nil
        }.first
    }

    private func bootstrapReportAnnouncement(_ record: BootstrapReportRecord) -> String {
        let english = languageStore.language == .english
        var actions: [String] = []
        if record.events.contains(where: {
            if case .failure = $0 { return true }; return false
        }) {
            actions.append(english ? "Retry" : "重试")
            actions.append(english ? "Connections and diagnostics" : "打开连接与诊断")
        }
        if bootstrapReportRevealPath(record) != nil {
            actions.append(english ? "Show in Finder" : "在 Finder 中显示")
        }
        if record.events.contains(where: {
            if case .selectionChanged = $0 { return true }
            return false
        }) {
            actions.append(english ? "Manage sounds" : "管理声音包")
        }
        actions.append(english ? "Got it" : "知道了")
        let actionSummary =
            english
            ? "Available actions: \(actions.joined(separator: ", "))."
            : "可用操作：\(actions.joined(separator: "、"))。"
        return bootstrapReportMessage(record) + " " + actionSummary
    }

    private var bootstrapReportFocusActions: [PanelFocusTarget] {
        bootstrapReports.records.flatMap { record in
            let id = record.id.uuidString
            var actions: [PanelFocusTarget] = []
            if record.events.contains(where: {
                if case .failure = $0 { return true }; return false
            }) {
                actions.append(.bootstrapReportRetry(id: id))
                actions.append(.bootstrapReportDiagnostics(id: id))
            }
            if bootstrapReportRevealPath(record) != nil {
                actions.append(.bootstrapReportReveal(id: id))
            }
            if record.events.contains(where: {
                if case .selectionChanged = $0 { return true }
                return false
            }) {
                actions.append(.bootstrapReportManageSounds(id: id))
            }
            actions.append(.bootstrapReportAcknowledge(id: id))
            return actions
        }
    }

    @ViewBuilder
    private var panelPackSection: some View {
        PanelPackSectionView(
            state: panelModel.packSectionState,
            typeScale: typeScale,
            focusedTarget: $focusedTarget,
            adaptation: layoutAdaptation,
            language: languageStore.language,
            onSelect: {
                let outcome = panelModel.switchPack(to: $0.id)
                soundPacksRefreshCoordinator.completePanelPackSwitch(outcome)
            })
    }

    private var soundPackLibraryRefreshFailureReason: String? {
        switch panelModel.libraryPresentationState {
        case .refreshFailed(let reason):
            return
                "\(l10n.text(.panelRetry))\(languageStore.language == .english ? ": " : "：")\(reason)"
        case .loading, .ready, .refreshing, .loadFailed:
            return nil
        }
    }

    private var soundPackLibraryRetryButton: some View {
        Button(l10n.text(.panelRetry)) {
            panelModel.retrySoundPackLibraryRefresh()
        }
        .buttonStyle(.bordered)
        .accessibilityLabel(l10n.text(.panelRetry))
        .accessibilityHint(l10n.text(.panelRetryHint))
        .accessibilityIdentifier("panel.packs.retry")
    }

    @ViewBuilder
    private var libraryEventFactsPlaceholder: some View {
        switch panelModel.libraryPresentationState {
        case .loading:
            Text(l10n.text(.panelLoadingEvents))
                .foregroundColor(ClaudioColor.textSecondary(colorScheme))
                .accessibilityLabel(l10n.text(.panelLoadingEvents))
        case .loadFailed:
            Text(l10n.text(.panelUnavailableEvents))
                .foregroundColor(ClaudioColor.textSecondary(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
        case .ready, .refreshing, .refreshFailed:
            EmptyView()
        }
    }

    /// D23 定稿④「先选包」空态卡——`configState == .needsPack` 时替换掉本该渲染的五行事件覆盖度。
    /// `PackGalleryView` 仍然照常渲染在下面；有包行时主行动是「点一个声音包」，零行时则指向仍在
    /// 屏幕上的「管理声音包…」。这里只负责说清楚温度 + 主行动 + 上下文（DESIGN.md 空态三要素）。
    private var needsPackNotice: some View {
        let copy = needsPackNoticeCopy(
            hasVisiblePackChoices: !panelModel.packCards.isEmpty,
            language: languageStore.language)
        return VStack(alignment: .leading, spacing: 4) {
            Text(l10n.text(.panelSelectPack))
                .font(.system(size: 13 * typeScale, weight: .semibold))
                .foregroundColor(ClaudioColor.text(colorScheme))
            Text(copy.message)
                .font(.system(size: 11 * typeScale))
                .foregroundColor(ClaudioColor.textSecondary(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(copy.accessibilityLabel)
    }

    /// T8 的「管理声音包…」真窗口入口。它位于包列表之后、断开连接之前，并在四种 configState 下无条件渲染；
    /// 这与 `panelFocusOrder` 无条件 append `.manageSounds` 是一对不可拆的诚实性契约。
    private var manageSoundsRow: some View {
        Button {
            onManageSounds(.overview, .manageSounds)
        } label: {
            Text(l10n.text(.panelManageSoundPacks))
                .font(.system(size: 11 * typeScale))
                .frame(maxWidth: .infinity)
                .frame(minHeight: 24)
                .padding(.vertical, 4)
                .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .foregroundColor(ClaudioColor.textSecondary(colorScheme))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(
                    ClaudioColor.hairlineStrong(colorScheme),
                    style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
        )
        .accessibilityLabel(l10n.text(.panelManageSoundPacks))
        .accessibilityHint(l10n.text(.panelManageSoundPacksHint))
        .accessibilityIdentifier("panel.manage-sound-packs")
        .focused($focusedTarget, equals: .manageSounds)
    }

    /// D23 定稿④诚实失败态——`configState`是 `.malformed`/`.unwritable` 时替换掉本该渲染的五行事件
    /// 覆盖度。**不禁用任何控件**（写者本来就全部 fail closed，见 `ConfigMutation.swift`）：这里只
    /// 负责把已经存在的、可执行的修复原因说出来，并给一个「在访达中显示」的快捷方式——doctor 的
    /// 诊断今天就带着这句一模一样的话（``configRewritabilityResult(configFile:)``），这里不重新
    /// 发明一套说法。
    ///
    /// 那颗「在访达中显示 config.json」是一颗**真控件**（焦点目标 ``PanelFocusTarget/configReveal``），
    /// 不是装饰：它渲染在面板顶端，是这两态开局键盘/VoiceOver 焦点的落点（/codex review P1，26bba37
    /// follow-up）。渲染它的判据与 `applyFirstFocus` 派生 `hasConfigFailureNotice` 的判据现在是**同一个**
    /// `panelModel.configState.topContent` 分类的 `.configFailure` 分支（单源化 f54d335 P1#1）——渲染 / 焦点
    /// 漂移在类型层就不可能；`ViewWiringSuite` 只需钉「两边都读了这个单源」+ 接线还在。
    private func configFailureNotice(reason: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // 2026-07-15 冗余审计的**第六份**手抄拒绝行 —— 审计当时只数到五份，漏了这一处（它藏在
            // `configFailureNotice` 里面，不是一个独立命名的 `xxxRow` 函数，grep 拒绝行的时候没捞到它）。
            // 如实记在这里：一次「我数清了所有副本」的断言，自己也漏了一个。
            FailureRow(message: reason)

            Button {
                NSWorkspace.shared.activateFileViewerSelecting([configFile])
            } label: {
                Text(l10n.text(.panelRevealConfig))
                    .font(.system(size: 11 * typeScale))
            }
            .buttonStyle(.plain)
            .foregroundColor(ClaudioColor.textSecondary(colorScheme))
            .accessibilityLabel(l10n.text(.panelRevealConfig))
            .accessibilityValue(configFile.path)
            .accessibilityHint(l10n.text(.panelRevealConfigHint))
            .accessibilityIdentifier("panel.reveal-config")
            // 它是这张卡上唯一的 bespoke 修复动作，渲染在面板最顶端 —— 所以它必须在焦点序里，且开局
            // 焦点就落在它上面（`.malformed`/`.unwritable` 时 `applyFirstFocus` 走 `.configReveal`）。
            // /codex review P1（26bba37 follow-up）。
            .focused($focusedTarget, equals: .configReveal)
        }
    }

    // `errorNotice(_:)` 已删（2026-07-15 冗余审计 · A 类修复）—— 它是 DESIGN.md「拒绝行」的六份手抄
    // 副本之一，而它自己的 doc comment 当时写着「**identical to** `AudioDropZoneView` 的 `rejectRow`
    // 与 `EventRowView` 的 `importErrorRow`」，那句话在写下的时候就已经不是真的了（`rejectRow` 的图标
    // 根本没设字号，文字是 11.5 不是 11）。现在这个面板里的每一条失败行都渲染同一个 ``FailureRow``
    // （`PanelRows.swift`）—— 「它们长得一样」从一句需要被守的注释，变成了一个编译期事实。

    // MARK: - Dynamic Type (ENGINEERING.md T15 D5「Dynamic Type + 降级规则」)

    private var interfaceTextSize: ClaudioInterfaceTextSize {
        ClaudioInterfaceTextSize(storedValue: interfaceTextSizeRaw)
    }

    private var typeScale: CGFloat { CGFloat(interfaceTextSize.scale) }

    private var typeSizeTier: PanelTypeSizeTier {
        panelTypeSizeTier(for: interfaceTextSize)
    }

    private var layoutAdaptation: PanelLayoutAdaptation { panelLayoutAdaptation(for: typeSizeTier) }

    // MARK: - Focus owner (a11y-architect FIX 4; ENGINEERING.md「无障碍规格」"打开焦点落首个
    // 可操作项")

    /// Sets ``focusedTarget`` to the panel's first OPERABLE control for whichever state it is
    /// currently rendering — called on appear and every time ``focusCoordinator`` signals the
    /// popover just (re)showed.
    ///
    /// The OPERATIONAL half delegates wholesale to ``panelOpeningFocus(rows:packCardIDs:)``
    /// (`ClaudioGUICore`, unit-tested): building the scope, deriving which rows' `.eventAction`
    /// slots are non-operable (``EventRow/eventActionOperable``), and resolving through
    /// ``panelFirstFocusTarget(_:nonOperableActionEvents:)`` — never plain
    /// `panelFocusOrder(_:).first`, which would park the opening caret on a muted first row's
    /// disabled 试听 ▶ (ENGINEERING.md「无障碍规格」"打开焦点落首个可操作项" — 可操作 is
    /// load-bearing). That three-step composition used to be hand-inlined HERE, as two private
    /// members inside SwiftUI, i.e. unreachable from this machine's dependency-free harness (T16
    /// review 修复⑥ sank it into the pure function precisely so it is TESTABLE — this view must
    /// not keep a second, untested copy of the same derivation).
    ///
    /// Onboarding has no rows, hence no `.eventAction` targets to filter, so it resolves through
    /// ``panelFirstFocusTarget(_:nonOperableActionEvents:)`` directly, off the same
    /// ``OnboardingCopy`` the branch actually renders — the consumed ORDER and the rendered
    /// CONTROLS can never disagree about which state the panel is in.
    ///
    /// Note: setting a SwiftUI `@FocusState` value only actually MOVES real AppKit keyboard focus
    /// once the hosting view is already part of the window's responder chain — that half is
    /// `MenuBarController.popoverDidShow`'s `makeFirstResponder` call, which always runs BEFORE
    /// this (via `focusCoordinator.requestFocus()`), never after.
    private func applyFirstFocus() {
        // Claude Code / Codex 连接与失败动作全部位于 IntegrationsWindow。
        // 因此面板永远没有旧 onboarding CTA 或其「查看原因」焦点槽。
        let ctaOperable = true
        let hasDetailToggle = false

        // D23 定稿④「路由态只做减法」：`operationalPanel` only renders `eventRows` for `.events`
        // (= `.operational`) — `.needsPack`/`.configFailure` show the empty-state/failure card
        // instead (see `operationalPanel`'s `switch panelModel.configState.topContent`). A control
        // that isn't on screen must never claim a slot in the opening-focus order, so this passes
        // an EMPTY row list for every non-`.events` state rather than `eventRows` (which, off
        // `resolvedConfig`'s empty-pack default, would otherwise resolve to four `.unmapped` rows
        // that are never actually rendered).
        //
        // 渲染与焦点读**同一个**分类 `panelModel.configState.topContent`（`PanelConfigState.topContent`，
        // 映射由 `PanelConfigSuite` 真行为单测钉死）：`operationalPanel` 顶部 switch 在它上面，这里也从它派生
        // 两颗 flag。此前这两颗 flag 各自 `switch panelModel.configState` 一遍、与渲染判据靠 ViewWiringSuite
        // 文本绊线防漂移；改读单源后，渲染判据与焦点判据在**决策级**一致，决策级漂移不再可能（呈现级 render 映射
        // 仍是手写 switch、只文本探针封——见 operationalPanel 顶部注释与 TODOS.md）（/codex review f54d335 P1#1）。
        let content = panelModel.configState.topContent
        // 两颗焦点 flag 现在是 `content` 上**单测钉过**的纯投影，applyFirstFocus 只**原样转发**、不在视图里
        // 重新解释——这是把「单源」从**值级**提到**决策级**的关键（/codex review f54d335 P1#1 follow-up：对抗
        // 复核实测，只让 render/focus 读同一个 `content` **值**还不够——视图里 `if case … = content { return
        // true }` 这两颗闭包的**返回值**没有任何测试钉，把 true 翻成 false 就能让失败卡照画、而焦点跳过 Reveal
        // 钮，全绿。把投影上提到 `PanelTopContent.showsEventContent` / `.hasConfigFailureNotice`、由 `PanelConfigSuite`
        // 单测其返回值后，视图这侧再没有可翻转的布尔，只剩一句转发；ViewWiringSuite 钉住这句转发原样还在）。
        // - showsEventContent：滑块 + 五行事件只在 `.events`（= `.operational`）真的在屏幕上，所以它同时决定
        //   `visibleRows`（哪些行真被渲染进焦点序）与 `hasMasterVolume`（滑块此刻在不在屏幕上）。
        // - hasConfigFailureNotice：诚实失败卡（`.configFailure` = `.malformed`/`.unwritable`）带着「在访达中
        //   显示 config.json」这颗真控件，渲染在面板顶端，所以 `.configReveal` 领序、开局焦点落在它上面。
        let visibleRows: [EventRow] =
            content.showsEventContent && panelModel.libraryPresentationState.hasUsableSnapshot
            ? panelModel.eventRows : []
        let hostSources = hostIntegrations.content.sourceRows.map(\.host)
        let openingTarget = panelOpeningFocus(
            rows: visibleRows, packCardIDs: panelModel.packCards.map(\.id),
            ctaOperable: ctaOperable,
            hasDetailToggle: hasDetailToggle, hasMasterVolume: content.showsEventContent,
            hasConfigFailureNotice: content.hasConfigFailureNotice,
            hostSources: hostSources,
            bootstrapReportActions: bootstrapReportFocusActions)
        let visibleOrder = panelFocusOrder(
            .operational(
                events: visibleRows.map(\.event),
                packCardIDs: panelModel.packCards.map(\.id),
                hasDetailToggle: hasDetailToggle,
                hasMasterVolume: content.showsEventContent,
                hasConfigFailureNotice: content.hasConfigFailureNotice,
                hostSources: hostSources,
                bootstrapReportActions: bootstrapReportFocusActions))
        if let requestedTarget = focusCoordinator.requestedTarget,
            visibleOrder.contains(requestedTarget)
        {
            focusedTarget = requestedTarget
        } else {
            focusedTarget = openingTarget
        }
    }

    private func isEventFocusTarget(_ target: PanelFocusTarget?) -> Bool {
        switch target {
        case .eventSound, .eventMute, .eventAction:
            return true
        case .none, .onboardingPrimaryAction, .onboardingSecondaryAction, .hostSource,
            .masterVolume, .bootstrapReportRetry, .bootstrapReportDiagnostics,
            .bootstrapReportReveal, .bootstrapReportManageSounds, .bootstrapReportAcknowledge,
            .packCard, .manageSounds, .revealDetail, .disconnect, .configReveal, .quitApplication:
            return false
        }
    }

    // MARK: - Actions

    /// Resolves the row's present file against the SELECTED pack directory (never trusting
    /// a stale path) and plays it — the real playback wiring `EventRowView`'s `onPreview`
    /// seam has always awaited (its own doc comment: "the caller...owns turning this into
    /// an actual playback call").
    /// 试听这一行的声音。
    ///
    /// `else` 分支**不是**空的（本轮 /ship 评审：Claude 对抗子代理）。走到这里说明 `row.coverage` 还是
    /// `.present`——那是上一次 ``panelModel.reload()`` 时算出来的——但文件此刻已经解析不出来了：用户在
    /// 这中间把它删了 / 改名了 / 换成了一个目录。原来的 `else { return }` 让「点了试听、什么都没发生、
    /// 也没有任何解释」成为可能，而这正是这一轮刚在 `switchPack` / 静音 / 绑定三处修掉的那种静默吞错。
    ///
    /// 修法不是弹一个错误框，而是**让面板说实话**：重跑 ``panelModel.reload()``，这一行会自己从
    /// `.present` 变成 `.broken`（「文件丢失」+ 进 doctor）。用户点下去看到的是行的状态当场改变——那比
    /// 任何一句提示都更接近「不回头也知道状态」。
    private func playPreview(for row: EventRow) {
        guard case .present(let fileName) = row.coverage,
            let packDirectory = resolvePackDirectory(
                id: panelModel.config.selectedPack,
                userPacksDirectory: audioEnvironment.userPacksDirectory,
                bundledPacksDirectory: audioEnvironment.bundledPacksDirectory),
            let resolvedFile = safePackFileURL(fileName, in: packDirectory),
            nonEmptyRegularFileExists(at: resolvedFile)
        else {
            panelModel.reload()
            return
        }
        // D2: 试听 must play at the panel's current master volume, not NSSound's own default
        // of 1.0 — read at the moment of the click (`panelModel.config` is always the
        // just-reloaded truth), not cached anywhere.
        previewPlayer.play(
            fileAt: resolvedFile, volume: Float(previewVolume(for: panelModel.config)))
    }

    // toggleMute / switchPack / reload / reloadConfigOnly 已搬进 `ClaudioGUICore.PanelConfigController`
    // （红队 9cccc9c 兑现台账那条 P2）。理由见那个类的文档：这几段逻辑住在测不到的 View 里时，
    // 红队实测三条「改坏行为、两套测试全绿」的变异（refresh 不重载 configState / 某条路由 case 成
    // 死代码 / 静音去掉取反）；搬进可实例化的类后由 `PanelConfigControllerSuite` 用真磁盘各钉一条
    // 行为断言。本视图只经 `panelModel.toggleMute(_:)` / `.switchPack(to:)` / `.reload()` 调它们。
}

/// The panel-only trigger for the shared interface-text preference. Its trigger is intentionally
/// outside ``PanelFocusTarget``: the panel still opens on its first sound-source control, while
/// closing this child popover can return focus to this local trigger.
@MainActor
struct InterfaceTextSizeControl: View {
    @Binding var selection: ClaudioInterfaceTextSize
    @ObservedObject var languageStore: ClaudioLanguageStore

    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var isTriggerFocused: Bool
    @State private var isPopoverPresented = false

    var body: some View {
        ZStack {
            triggerButton
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("panel.options")
    }

    private var triggerButton: some View {
        Button {
            isPopoverPresented.toggle()
        } label: {
            Text("Aa⌄")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
        }
        .buttonStyle(.bordered)
        .tint(ClaudioTheme.clay(colorScheme))
        .frame(width: 54, height: 32)
        .contentShape(Rectangle())
        .focused($isTriggerFocused)
        .accessibilityLabel(ClaudioL10n(language: languageStore.language).text(.interfaceTitle))
        .accessibilityValue(
            "\(languageStore.language.selfName)\(languageStore.language == .english ? ", " : "，")"
                + selection.localizedDisplayName(languageStore.language)
        )
        .accessibilityHint(ClaudioL10n(language: languageStore.language).text(.panelOptionsHint))
        .accessibilityIdentifier("panel.options.text-size")
        .popover(isPresented: $isPopoverPresented, arrowEdge: .bottom) {
            InterfaceSettingsPopoverContent(
                selection: $selection,
                languageStore: languageStore)
        }
        .onChange(of: isPopoverPresented) { presented in
            if !presented {
                isTriggerFocused = true
            }
        }
        .onDisappear {
            // Parent NSPopover.close() can dismiss this nested child without emitting a useful
            // SwiftUI focus transition. Clear the local state so reopening always starts from
            // the current language segment and never targets a vanished child control.
            isPopoverPresented = false
            isTriggerFocused = false
        }
    }
}

/// One geometry and one accessibility contract for both host rows in the panel. The status is
/// already classified by `ClaudioGUICore`; notably Codex's normal 4/5 uses `.ready`, not warning.
private struct HostSourceCardHeightPreferenceKey: PreferenceKey {
    static let defaultValue: [HostID: CGFloat] = [:]

    static func reduce(
        value: inout [HostID: CGFloat],
        nextValue: () -> [HostID: CGFloat]
    ) {
        value.merge(nextValue(), uniquingKeysWith: { _, newValue in newValue })
    }
}

@MainActor
private struct HostSourceRowView: View {
    let row: HostSourceRowPresentation
    let typeScale: CGFloat
    let language: ClaudioAppLanguage
    var focusedTarget: FocusState<PanelFocusTarget?>.Binding
    let equalizedHeight: CGFloat?
    let onSelect: @MainActor () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: onSelect) {
            ZStack(alignment: .topLeading) {
                // Keep the natural layout as a sibling of the visible card. A fixed shared
                // height must never become the proposal that measures this view, otherwise a
                // later host-state or text-size change can remain stuck at the previous height.
                naturalCardLayout
                    .hidden()
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                cardSurface
            }
        }
        .buttonStyle(.plain)
        // Keep the hit target equal to the visible card, including its blank lower area.
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .contentShape(RoundedRectangle(cornerRadius: ClaudioTheme.Radius.control))
        .focused(focusedTarget, equals: .hostSource(row.host))
        .accessibilityLabel(row.accessibilityLabel)
        .accessibilityValue(row.readinessText)
        .accessibilityHint(ClaudioL10n(language: language).text(.hostDetailsHint))
        .accessibilityIdentifier("panel.host.\(row.host.rawValue)")
    }

    private var cardSurface: some View {
        cardContentLayout
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .frame(height: equalizedHeight, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: ClaudioTheme.Radius.control)
                    .fill(ClaudioTheme.elevated(colorScheme).opacity(0.88))
            )
            .overlay(
                RoundedRectangle(cornerRadius: ClaudioTheme.Radius.control)
                    .stroke(ClaudioTheme.hairline(colorScheme), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: ClaudioTheme.Radius.control))
    }

    private var cardContentLayout: some View {
        cardContent
            .foregroundColor(ClaudioTheme.text(colorScheme))
            .frame(maxWidth: .infinity, minHeight: 48 * typeScale, alignment: .topLeading)
            .padding(8)
    }

    private var naturalCardLayout: some View {
        cardContentLayout
            // Preserve the proposed card width while asking the vertical axis for its ideal
            // height. This is intentionally outside `cardSurface`'s equalized frame.
            .fixedSize(horizontal: false, vertical: true)
            .background(naturalHeightMeasurement)
            .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: statusSymbol)
                    .font(.system(size: 11 * typeScale, weight: .semibold))
                    .foregroundColor(statusColor)
                    .accessibilityHidden(true)
                Text(row.title)
                    .font(.system(size: 11.5 * typeScale, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                Spacer(minLength: 2)
            }
            Text(row.readinessText)
                .font(.system(size: 9.5 * typeScale, weight: .medium, design: .rounded))
                .foregroundColor(ClaudioTheme.secondaryText(colorScheme))
                .lineLimit(2)
            optionalDetailText
        }
    }

    private var statusSymbol: String {
        switch row.status {
        case .ready: "checkmark.circle.fill"
        case .awaitingActivation: "clock.fill"
        case .legacy: "clock.arrow.circlepath"
        case .notConnected: "circle"
        case .needsAttention: "exclamationmark.circle.fill"
        }
    }

    @ViewBuilder
    private var optionalDetailText: some View {
        if row.status != .ready, let detailText = row.detailText {
            Text(detailText)
                .font(.system(size: 9 * typeScale, design: .rounded))
                .foregroundColor(ClaudioTheme.secondaryText(colorScheme))
                .lineLimit(2)
        }
    }

    private var naturalHeightMeasurement: some View {
        GeometryReader { proxy in
            let height = proxy.size.height
            Color.clear.preference(
                key: HostSourceCardHeightPreferenceKey.self,
                value: [row.host: height])
        }
    }

    private var statusColor: Color {
        switch row.status {
        case .ready: ClaudioColor.success(colorScheme)
        case .awaitingActivation, .legacy, .notConnected:
            ClaudioColor.textSecondary(colorScheme)
        case .needsAttention: ClaudioColor.error(colorScheme)
        }
    }
}
