import AppKit
import ClaudioCore
import ClaudioGUIComponents
import ClaudioGUICore
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
/// real Mac. `ClaudioGUICore`'s pieces this view composes (``packCoverage``, ``availablePacks``,
/// ``loadPanelConfig``, ``panelLayoutAdaptation``, ``panelFocusOrder``) are each independently
/// unit-tested — this file's own job is ONLY correct composition, not re-deciding anything.
public struct PanelView: View {
    /// 「这一句刚说过」的去重器（T17g）—— 让「一趟 update pass ≤ 一条播报」在结构上成立。
    /// 它必须活得比一次 `body` 求值长（跨 handler、跨帧），所以是 `@StateObject` 而不是局部变量。
    @StateObject private var announcer: PanelAnnouncer
    /// 运行态面板的 config 读模型 + 流经它的写操作（`configState` / `config` / `eventRows` /
    /// `packCards` / `packSwitchError`，以及 `toggleMute` / `switchPack` / `reload` /
    /// `reloadEnabledFlags`）—— **全部搬进了 `ClaudioGUICore.PanelConfigController`**（红队 9cccc9c
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

    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(ClaudioInterfaceTextSize.defaultsKey)
    private var interfaceTextSizeRaw = ClaudioInterfaceTextSize.defaultValue.rawValue

    // Reduced transparency is satisfied structurally: `.background(
    // ClaudioColor.panel(colorScheme))` below is a near-solid opaque color, never a
    // `.material`/`.ultraThinMaterial`/vibrancy effect (DESIGN.md「面板材质（关键决策）」:
    // "不用满毛玻璃 vibrancy"). No code path in this tree introduces one.

    private let audioEnvironment: AudioImportEnvironment
    private let configFile: URL
    private let lockFile: URL
    private let previewPlayer: AudioPreviewPlaying
    private let soundPacksRefreshCoordinator: SoundPacksRefreshCoordinator
    private let onManageSounds: @MainActor (SoundPacksWindowRoute, PanelFocusTarget) -> Void
    private let onManageIntegrations: @MainActor (PanelFocusTarget) -> Void
    private let onAudibilityInputsChanged: @MainActor () -> Void

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
        soundPacksRefreshCoordinator: SoundPacksRefreshCoordinator,
        onManageSounds: @escaping @MainActor (SoundPacksWindowRoute, PanelFocusTarget) -> Void,
        onManageIntegrations: @escaping @MainActor (PanelFocusTarget) -> Void,
        onAudibilityInputsChanged: @escaping @MainActor () -> Void,
        onPanelWidthChange: @escaping (Double) -> Void = { _ in }
    ) {
        self.audioEnvironment = audioEnvironment
        self.configFile = configFile
        self.lockFile = lockFile
        self.focusCoordinator = focusCoordinator
        self.hostIntegrations = hostIntegrations
        self.soundPacksRefreshCoordinator = soundPacksRefreshCoordinator
        self.onManageSounds = onManageSounds
        self.onManageIntegrations = onManageIntegrations
        self.onAudibilityInputsChanged = onAudibilityInputsChanged
        self.onPanelWidthChange = onPanelWidthChange
        // Construct the shared `ClaudioGUIComponents` player here. Both GUI surfaces reuse the
        // same retention/volume implementation while owning independent playback lifetimes.
        self.previewPlayer = NSSoundAudioPreviewPlayer()

        let onAudibilityInputsChanged = self.onAudibilityInputsChanged
        let panelModel = PanelConfigController(
            configFile: configFile,
            lockFile: lockFile,
            environment: audioEnvironment,
            afterFullReload: { _ in
                onAudibilityInputsChanged()
            },
            soundPacksRefreshCoordinator: soundPacksRefreshCoordinator)

        _announcer = StateObject(wrappedValue: PanelAnnouncer())
        _panelModel = StateObject(wrappedValue: panelModel)
    }

    public var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 12) {
                header
                hostSourcesSection
                operationalPanel
            }
            .padding(13)
        }
        .frame(width: layoutAdaptation.panelWidth)
        .background(ClaudioTheme.panelGradient(colorScheme))
        .overlay(
            RoundedRectangle(cornerRadius: ClaudioTheme.Radius.panel)
                .strokeBorder(ClaudioTheme.hairline(colorScheme), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: ClaudioTheme.Radius.panel))
        .environment(\.dynamicTypeSize, interfaceTextSize.dynamicTypeSize)
        // `.onAppear` deliberately does NOT call `refresh()` (`/ship` 评审 · 性能): `refresh()`
        // is a synchronous, main-thread DISK SCAN (re-reads config.json, the selected pack's
        // manifest + a `stat` per event, then enumerates BOTH pack roots and reads EVERY pack's
        // manifest). It used to run from `.onAppear` **and** from `.onChange(showCount)` below —
        // both of which fire when the popover opens, so the very first open scanned everything
        // TWICE. `.onChange(showCount)` is the reliable signal of the two (see
        // ``PanelFocusCoordinator``'s own doc comment on why `.onAppear` is not), and `init(...)`
        // has already loaded the initial rows/cards from disk, so this hook only needs to place
        // focus and report the panel's width.
        //
        // T17g：它也**不播报**，一字不差的同一条推理 —— `.onAppear` 与 `.onChange(showCount)` 在同一次
        // 打开里**都会**跑，两条 post 会抢同一条「一次一句」的通道，而谁先谁后取决于 `onAppear` 与
        // `popoverDidShow` 的 AppKit 时序：一个没实测过的语义。`showCount` 是这两个信号里可靠的那个
        // （见 ``PanelFocusCoordinator`` 的文档），所以播报只挂它。
        .onAppear {
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
        // T15 D5 「极大 → 加宽 popover」: SwiftUI already widened ITSELF (`.frame(width:)` above);
        // this tells the AppKit popover around it to follow (see ``onPanelWidthChange``).
        .onChange(of: layoutAdaptation.panelWidth) { newWidth in
            onPanelWidthChange(newWidth)
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
                let base = "claudi0 面板，\(sourceCount) 个声音来源"
                let header = packName.isEmpty ? base : "\(base)，当前声音包 \(packName)"
                guard
                    let sentence = announcer.consume(
                        dualHostPanelAnnouncement(header: header),
                        openCount: coordinator.showCount)
                else { return }
                NSAccessibility.post(
                    element: NSApp as Any,
                    notification: .announcementRequested,
                    userInfo: [
                        .announcement: sentence,
                        .priority: NSAccessibilityPriorityLevel.high.rawValue,
                    ])
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
            Text(selectedPackDisplayName.isEmpty ? "尚未选择声音包" : selectedPackDisplayName)
                .font(.system(size: 14 * typeScale, weight: .semibold, design: .rounded))
                .foregroundColor(ClaudioTheme.text(colorScheme))
                .lineLimit(2)
            Text("\(audibleEventCount) 个可听事件")
                .font(.system(size: 11 * typeScale, design: .rounded))
                .foregroundColor(ClaudioTheme.secondaryText(colorScheme))
        }
        .accessibilityLabel(headerAccessibilityLabel)
    }

    private var interfaceOptionsMenu: some View {
        Menu {
            Picker("界面文字", selection: $interfaceTextSizeRaw) {
                ForEach(ClaudioInterfaceTextSize.allCases) { size in
                    Text(size.displayName).tag(size.rawValue)
                }
            }
            .accessibilityLabel("界面文字大小")
            .accessibilityValue(interfaceTextSize.displayName)
            .accessibilityHint("应用到主面板、声音包窗口和集成窗口")
            .accessibilityIdentifier("panel.options.text-size")
        } label: {
            Image(systemName: "ellipsis.circle")
                .frame(
                    minWidth: ClaudioTheme.Metrics.iconTarget,
                    minHeight: ClaudioTheme.Metrics.iconTarget)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel("claudi0 选项")
        .accessibilityValue("界面文字，\(interfaceTextSize.displayName)")
        .accessibilityHint("选择 claudi0 三个界面的文字大小")
        .accessibilityIdentifier("panel.options")
    }

    private var headerAccessibilityLabel: String {
        let packName = selectedPackDisplayName
        let base = "claudi0 面板，2 个声音来源，\(audibleEventCount) 个可听事件"
        guard !packName.isEmpty else { return base }
        return "\(base)，当前声音包 \(packName)"
    }

    private var hostSourcesSection: some View {
        HStack(alignment: .top, spacing: 8) {
            ForEach(hostIntegrations.content.sourceRows) { row in
                HostSourceRowView(
                    row: row,
                    typeScale: typeScale,
                    focusedTarget: $focusedTarget,
                    onSelect: { onManageIntegrations(.hostSource(row.host)) })
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("声音来源")
    }

    private var audibleEventCount: Int {
        panelModel.eventRows.filter {
            eventPreviewAvailability(
                coverage: $0.coverage,
                masterVolume: panelModel.config.masterVolume).isAvailable
        }.count
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
            // D23 定稿④：路由到已经存在的自救路径，零新机制。`configState.topContent` 决定这一块顶部
            // 内容显示什么——`.events`（= `.operational`）是今天这四行事件覆盖度 + 主音量滑块；`.needsPack`
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
                Text("\(selectedPackDisplayName) · 事件")
                    .font(.system(size: 11 * typeScale, weight: .semibold))
                    .foregroundColor(ClaudioColor.textSecondary(colorScheme))
                ForEach(panelModel.eventRows, id: \.event) { row in
                    EventRowView(
                        row: row,
                        hostCoverage: eventHostCoveragePresentation(
                            event: row.event,
                            matrix: hostIntegrations.content.matrix),
                        previewAvailability: eventPreviewAvailability(
                            coverage: row.coverage,
                            masterVolume: panelModel.config.masterVolume),
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
                // PLAN-MASTER-VOLUME.md 阶段 D：位置对齐线框——四行事件之后、拖入区之前。只在
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
                    adaptation: layoutAdaptation)
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
                        muteError: panelModel.muteError, packSwitchError: panelModel.packSwitchError,
                        masterVolumeError: panelModel.masterVolumeError
                    ).enumerated()), id: \.offset
            ) { _, message in
                FailureRow(message: message)
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
            Text("声音包")
                .font(.system(size: 11 * typeScale, weight: .semibold))
                .foregroundColor(ClaudioColor.textSecondary(colorScheme))
            panelPackSection
            manageSoundsRow
        }
    }

    @ViewBuilder
    private var panelPackSection: some View {
        PanelPackSectionView(
            state: panelModel.packSectionState,
            typeScale: typeScale,
            focusedTarget: $focusedTarget,
            adaptation: layoutAdaptation,
            onSelect: {
                let outcome = panelModel.switchPack(to: $0.id)
                soundPacksRefreshCoordinator.completePanelPackSwitch(outcome)
            })
    }

    /// D23 定稿④「先选包」空态卡——`configState == .needsPack` 时替换掉本该渲染的四行事件覆盖度。
    /// `PackGalleryView` 仍然照常渲染在下面；有包行时主行动是「点一个声音包」，零行时则指向仍在
    /// 屏幕上的「管理声音包…」。这里只负责说清楚温度 + 主行动 + 上下文（DESIGN.md 空态三要素）。
    private var needsPackNotice: some View {
        let copy = needsPackNoticeCopy(hasVisiblePackChoices: !panelModel.packCards.isEmpty)
        return VStack(alignment: .leading, spacing: 4) {
            Text("先选包")
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
            Text("管理声音包…")
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
        .accessibilityLabel("管理声音包")
        .accessibilityHint("打开声音包管理窗口")
        .accessibilityIdentifier("panel.manage-sound-packs")
        .focused($focusedTarget, equals: .manageSounds)
    }

    /// D23 定稿④诚实失败态——`configState`是 `.malformed`/`.unwritable` 时替换掉本该渲染的四行事件
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
                Text("在访达中显示 config.json")
                    .font(.system(size: 11 * typeScale))
            }
            .buttonStyle(.plain)
            .foregroundColor(ClaudioColor.textSecondary(colorScheme))
            .accessibilityLabel("在访达中显示 claudi0 配置")
            .accessibilityValue(configFile.path)
            .accessibilityHint("在访达中定位 config.json，方便手工修正")
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
        switch interfaceTextSize {
        case .compact, .standard: .standard
        case .large: .larger
        case .maximum: .maximum
        }
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
        // - showsEventContent：滑块 + 四行事件只在 `.events`（= `.operational`）真的在屏幕上，所以它同时决定
        //   `visibleRows`（哪些行真被渲染进焦点序）与 `hasMasterVolume`（滑块此刻在不在屏幕上）。
        // - hasConfigFailureNotice：诚实失败卡（`.configFailure` = `.malformed`/`.unwritable`）带着「在访达中
        //   显示 config.json」这颗真控件，渲染在面板顶端，所以 `.configReveal` 领序、开局焦点落在它上面。
        let visibleRows: [EventRow] = content.showsEventContent ? panelModel.eventRows : []
        let hostSources = hostIntegrations.content.sourceRows.map(\.host)
        let openingTarget = panelOpeningFocus(
            rows: visibleRows, packCardIDs: panelModel.packCards.map(\.id), ctaOperable: ctaOperable,
            hasDetailToggle: hasDetailToggle, hasMasterVolume: content.showsEventContent,
            hasConfigFailureNotice: content.hasConfigFailureNotice,
            hostSources: hostSources)
        let visibleOrder = panelFocusOrder(
            .operational(
                events: visibleRows.map(\.event),
                packCardIDs: panelModel.packCards.map(\.id),
                hasDetailToggle: hasDetailToggle,
                hasMasterVolume: content.showsEventContent,
                hasConfigFailureNotice: content.hasConfigFailureNotice,
                hostSources: hostSources))
        if let requestedTarget = focusCoordinator.requestedTarget,
            visibleOrder.contains(requestedTarget)
        {
            focusedTarget = requestedTarget
        } else {
            focusedTarget = openingTarget
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
                id: panelModel.config.selectedPack, userPacksDirectory: audioEnvironment.userPacksDirectory,
                bundledPacksDirectory: audioEnvironment.bundledPacksDirectory),
            let resolvedFile = safePackFileURL(fileName, in: packDirectory),
            regularFileExists(at: resolvedFile)
        else {
            panelModel.reload()
            return
        }
        // D2: 试听 must play at the panel's current master volume, not NSSound's own default
        // of 1.0 — read at the moment of the click (`panelModel.config` is always the
        // just-reloaded truth), not cached anywhere.
        previewPlayer.play(fileAt: resolvedFile, volume: Float(previewVolume(for: panelModel.config)))
    }

    // toggleMute / switchPack / reload / reloadEnabledFlags 已搬进 `ClaudioGUICore.PanelConfigController`
    // （红队 9cccc9c 兑现台账那条 P2）。理由见那个类的文档：这几段逻辑住在测不到的 View 里时，
    // 红队实测三条「改坏行为、两套测试全绿」的变异（refresh 不重载 configState / 某条路由 case 成
    // 死代码 / 静音去掉取反）；搬进可实例化的类后由 `PanelConfigControllerSuite` 用真磁盘各钉一条
    // 行为断言。本视图只经 `panelModel.toggleMute(_:)` / `.switchPack(to:)` / `.reload()` 调它们。
}

/// One geometry and one accessibility contract for both host rows in the panel. The status is
/// already classified by `ClaudioGUICore`; notably Codex's normal 3/4 uses `.ready`, not warning.
@MainActor
private struct HostSourceRowView: View {
    let row: HostSourceRowPresentation
    let typeScale: CGFloat
    var focusedTarget: FocusState<PanelFocusTarget?>.Binding
    let onSelect: @MainActor () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: onSelect) {
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
                if row.status != .ready, let detailText = row.detailText {
                    Text(detailText)
                        .font(.system(size: 9 * typeScale, design: .rounded))
                        .foregroundColor(ClaudioTheme.secondaryText(colorScheme))
                        .lineLimit(2)
                        }
            }
            .foregroundColor(ClaudioTheme.text(colorScheme))
            .frame(maxWidth: .infinity, minHeight: 48 * typeScale, alignment: .topLeading)
            .padding(8)
            .contentShape(RoundedRectangle(cornerRadius: ClaudioTheme.Radius.control))
            .background(
                RoundedRectangle(cornerRadius: ClaudioTheme.Radius.control)
                    .fill(ClaudioTheme.elevated(colorScheme).opacity(0.88)))
            .overlay(
                RoundedRectangle(cornerRadius: ClaudioTheme.Radius.control)
                    .stroke(ClaudioTheme.hairline(colorScheme), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .focused(focusedTarget, equals: .hostSource(row.host))
        .accessibilityLabel(row.accessibilityLabel)
        .accessibilityValue(row.readinessText)
        .accessibilityHint("打开该声音来源的连接与诊断详情")
        .accessibilityIdentifier("panel.host.\(row.host.rawValue)")
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

    private var statusColor: Color {
        switch row.status {
        case .ready: ClaudioColor.success(colorScheme)
        case .awaitingActivation, .legacy, .notConnected:
            ClaudioColor.textSecondary(colorScheme)
        case .needsAttention: ClaudioColor.error(colorScheme)
        }
    }
}
