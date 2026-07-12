import AppKit
import ClaudioCore
import ClaudioGUICore
import SwiftUI

/// The real menu-bar panel content (ENGINEERING.md T15 D1) — the composition root that
/// replaces the temporary `WindowGroup { OnboardingView(...) }` scaffolding T7 shipped.
/// Every state DECISION (onboarding vs operational, per-row coverage, pack completeness,
/// focus order, contrast, Dynamic Type tier) already happened in `ClaudioGUICore`/`ClaudioCore`
/// before this view renders — this file only lays pixels out, wires actions to the already-
/// tested write paths (``selectPack``, ``EventMuteController/setEnabled(_:enabled:)``), and
/// resolves real playback via ``NSSoundAudioPreviewPlayer``.
///
/// COMPILE-ONLY here (CommandLineTools, no Xcode/simulator/`#Preview`): rendering, the
/// operational-panel wiring end-to-end, and Dynamic Type behavior are manual-verify on a
/// real Mac. `ClaudioGUICore`'s pieces this view composes (``packCoverage``, ``availablePacks``,
/// ``loadPanelConfig``, ``panelLayoutAdaptation``, ``panelFocusOrder``) are each independently
/// unit-tested — this file's own job is ONLY correct composition, not re-deciding anything.
public struct PanelView: View {
    @StateObject private var onboardingViewModel: OnboardingViewModel
    @StateObject private var muteController: EventMuteController
    @StateObject private var dropZoneViewModel: AudioImportViewModel
    @State private var rowImportViewModels: [Event: EventRowImportViewModel]
    @State private var config: ClaudioConfig
    @State private var eventRows: [EventRow]
    @State private var packCards: [PackCard]

    /// The last pack switch that FAILED, if any — `nil` before any switch and cleared on the next
    /// successful one (mirrors ``EventMuteController/lastError``'s own shape, which is where the
    /// mute half of this same reporting lives).
    ///
    /// 绝不静默吞错（项目规则）: ``switchPack(to:)`` used to be
    /// `if case .success = result { refresh() }` — the failure was **discarded entirely, not even
    /// recorded**, so a switch that hit `.lockBusy`/`.packNotFound` left the gallery visibly
    /// unchanged with zero explanation. `UseError` is `CustomStringConvertible` with a ready
    /// Chinese sentence for every case (including 「请稍后重试」 for `.lockBusy`); nothing was
    /// showing it.
    @State private var packSwitchError: UseError?

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

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// Dynamic-Type scale factor for the header's fixed `.system(size:)` text (a11y fix) — see
    /// ``EventRowView``'s `typeScale`. `dynamicTypeSize` above still drives the LAYOUT tier
    /// (``typeSizeTier``); this makes the header TEXT actually scale alongside it.
    @ScaledMetric(relativeTo: .body) private var typeScale: CGFloat = 1

    // MARK: - Reduced motion / reduced transparency (ENGINEERING.md T15 D5)
    //
    // 这条绊线响了，而且是被 T17 自己踩响的（T17c 修复）。
    //
    // 它此前写的是：「this view tree applies NO `.animation()`/`withAnimation` anywhere … if a
    // future task adds any animation to this tree, it MUST gate it behind
    // `accessibilityReduceMotion` at that point — this comment is the tripwire.」而 T17 往这棵树里
    // 加了**两个** `ProgressView()`（`OnboardingView.ctaButton` 与本文件的 `disconnectRow`）——
    // 一个无限旋转动画 —— 既没有 gate，也没有回来改这段话。一条自己被跨过去还留在原地的绊线，
    // 比没有绊线更坏：它是一句已经不成立的断言，而下一个人会信它。
    //
    // 现在的状态：这棵树里**唯一**的动画是那两颗 in-flight spinner，两者都 gate 在下面这个
    // `reduceMotion` 后面。降级路径是 DESIGN.md 写的「静态字形与瞬时状态切换」—— 进行态本来就已经
    // 由文案（「正在接管…」/「正在断开…」）与禁用态承担了，那圈转动只是锦上添花。
    // **规矩不变**：再往这棵树里加任何动画，必须在那一点 gate 住 `reduceMotion`。
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    //
    // Reduced transparency: already satisfied structurally, not just here — `.background(
    // ClaudioColor.panel(colorScheme))` below is a near-solid opaque color, never a
    // `.material`/`.ultraThinMaterial`/vibrancy effect (DESIGN.md「面板材质（关键决策）」:
    // "不用满毛玻璃 vibrancy"). No code path in this tree introduces one.

    private let audioEnvironment: AudioImportEnvironment
    private let configFile: URL
    private let lockFile: URL
    private let previewPlayer: AudioPreviewPlaying

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
        /// `Claudio.app/Contents/Resources/bin/claudio` — the helper the 接管 CTA copies into
        /// `~/.claudio/bin/claudio`. **No default on purpose**: a default would let a future call
        /// site silently ship a panel whose CTA can never install anything, which is precisely the
        /// bug T17 exists to close. `nil` is a legal, explicit answer ("this build has no bundle"),
        /// and it surfaces as a real error in the panel — never as a dead button.
        bundledHelperBinary: URL?,
        configFile: URL = ClaudioPaths.configFile,
        lockFile: URL = ClaudioPaths.lockFile,
        onboardingEnvironment: OnboardingEnvironment = OnboardingEnvironment(),
        focusCoordinator: PanelFocusCoordinator = PanelFocusCoordinator(),
        onPanelWidthChange: @escaping (Double) -> Void = { _ in }
    ) {
        self.audioEnvironment = audioEnvironment
        self.configFile = configFile
        self.lockFile = lockFile
        self.focusCoordinator = focusCoordinator
        self.onPanelWidthChange = onPanelWidthChange
        // `NSSoundAudioPreviewPlayer` is internal (module-private, not exposed as a public
        // API surface) — mirrors `AudioDropZoneView`'s own init, which constructs it the
        // same way rather than taking it as a public, overridable parameter.
        self.previewPlayer = NSSoundAudioPreviewPlayer()

        // The runner is built INSIDE the `StateObject(wrappedValue:)` autoclosure, together with
        // the view-model it belongs to — never assigned afterwards.
        //
        // Assigning it in this init's BODY (`onboardingViewModel.actionRunner = …`) would be the
        // tempting answer and a silent disaster: reading a `@StateObject`'s `wrappedValue` before
        // SwiftUI has installed the state re-evaluates this autoclosure and hands back a BRAND NEW
        // instance every time ("Accessing StateObject's object without being installed on a View.
        // This will create a new instance each time."). The runner would land on a phantom
        // view-model that `body` never renders, the real one would keep a nil runner, and the CTA
        // would be a no-op again — T17's own bug, reproduced by the fix for T17.
        //
        // Constructor injection removes the question entirely: there is no "when do we wire it",
        // and deleting the wiring is a COMPILE ERROR rather than a green test suite.
        let actionEnvironment = OnboardingActionEnvironment(
            onboarding: onboardingEnvironment,
            bundledHelperBinary: bundledHelperBinary,
            userPacksDirectory: audioEnvironment.userPacksDirectory,
            configFile: configFile,
            lockFile: lockFile)
        _onboardingViewModel = StateObject(
            wrappedValue: OnboardingViewModel(
                environment: onboardingEnvironment,
                actionRunner: DiskOnboardingActionRunner(environment: actionEnvironment)))
        _muteController = StateObject(
            wrappedValue: EventMuteController(configFile: configFile, lockFile: lockFile))

        let loadedConfig = loadPanelConfig(from: configFile)
        _config = State(initialValue: loadedConfig)
        _eventRows = State(
            initialValue: packCoverage(
                packID: loadedConfig.selectedPack, config: loadedConfig, environment: audioEnvironment))
        _packCards = State(
            initialValue: availablePacks(config: loadedConfig, environment: audioEnvironment))
        _dropZoneViewModel = StateObject(
            wrappedValue: AudioImportViewModel(
                packID: loadedConfig.selectedPack, environment: audioEnvironment))

        var perRow: [Event: EventRowImportViewModel] = [:]
        for event in Event.allCases {
            let importViewModel = AudioImportViewModel(
                packID: loadedConfig.selectedPack, environment: audioEnvironment)
            perRow[event] = EventRowImportViewModel(event: event, importViewModel: importViewModel)
        }
        _rowImportViewModels = State(initialValue: perRow)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // `header` is rendered ONLY in the operational (`.installed`) branch — NOT
            // unconditionally above the `if` — because `OnboardingView` renders its OWN
            // "Claudio" header (`OnboardingView.header`). Rendering both would stack two
            // identical titles (and double the VoiceOver announcement) on every onboarding
            // screen — the first thing a new user sees. Installed → PanelView owns the header
            // (with the "当前声音包 …" a11y label); onboarding → OnboardingView owns it.
            if onboardingViewModel.state == .installed {
                header
                operationalPanel
            } else {
                OnboardingView(viewModel: onboardingViewModel, focusedTarget: $focusedTarget)
            }
        }
        .padding(13)
        .frame(width: layoutAdaptation.panelWidth)
        .background(ClaudioColor.panel(colorScheme))
        .overlay(
            RoundedRectangle(cornerRadius: 15)
                .strokeBorder(ClaudioColor.hairlineStrong(colorScheme), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 15))
        // `.onAppear` deliberately does NOT call `refresh()` (`/ship` 评审 · 性能): `refresh()`
        // is a synchronous, main-thread DISK SCAN (re-reads config.json, the selected pack's
        // manifest + a `stat` per event, then enumerates BOTH pack roots and reads EVERY pack's
        // manifest). It used to run from `.onAppear` **and** from `.onChange(showCount)` below —
        // both of which fire when the popover opens, so the very first open scanned everything
        // TWICE. `.onChange(showCount)` is the reliable signal of the two (see
        // ``PanelFocusCoordinator``'s own doc comment on why `.onAppear` is not), and `init(...)`
        // has already loaded the initial rows/cards from disk, so this hook only needs to place
        // focus and report the panel's width.
        .onAppear {
            applyFirstFocus()
            announcePanel()
            onPanelWidthChange(layoutAdaptation.panelWidth)
        }
        // a11y-architect FIX 4: `MenuBarController.popoverDidShow` bumps
        // `focusCoordinator.showCount` every time the popover becomes visible — the ONE place
        // "the popover just (re)opened, re-read the disk" is handled.
        .onChange(of: focusCoordinator.showCount) { _ in
            // 面板真的出现在屏幕上了。**一条已经被看过的失败**在这里被忘掉；一条在面板关着时诞生的
            // 失败**不会** —— 这一次打开才是它的第一次露面（T17d，见
            // ``OnboardingViewModel/panelDidBecomeVisible()``）。上一版在这里无条件清，于是「用户
            // 点完接管就切走、安装在后台失败」这条路径上的失败，从头到尾一个像素都没有过。
            //
            // 必须在 `refresh()` **之前**：清掉 `.failed` 会改变 `hasDetailToggle`，而
            // `applyFirstFocus()` 要按清理**之后**的焦点序落焦，否则光标会落在一颗刚被清掉的
            // 「查看原因」上。
            onboardingViewModel.panelDidBecomeVisible()
            refresh()
            applyFirstFocus()
            announcePanel()
        }
        // 另一半（T17d）：`MenuBarController.popoverDidClose` bumps `focusCoordinator.hideCount`。
        // 没有它，view-model 就只能去**假定**「下一次打开 = 上一条失败已经被看过」—— 而在
        // `.transient` popover 被一次 app 切换关掉、写盘 Task 却还在跑的那条路径上，那个假定是假的。
        .onChange(of: focusCoordinator.hideCount) { _ in
            onboardingViewModel.panelDidHide()
        }
        // T17 —— **这一行是「接管成功」这件事真正被兑现的地方**，不是锦上添花。
        //
        // CTA 落地后 `onboardingViewModel.refresh()` 把 state 翻到 `.installed`，`body` 于是从
        // onboarding 卡切到 `operationalPanel`。但 `config` / `eventRows` / `packCards` 是三个
        // 独立的 `@State`，只在 `init` 里读过一次盘 —— 而 `init` 跑在 app 启动的那一刻，也就是
        // setup **之前**：那时 `config.json` 还不存在（`loadPanelConfig` 回落到 `selectedPack: ""`）、
        // 包一个都还没复制。于是用户在**接管成功的那一秒**看到的会是：四行「未配置 / 文件丢失」、
        // 试听全禁用、一个空的切包画廊 —— 而真实的包和 config 明明已经躺在磁盘上了。他必须关掉
        // 面板再打开一次才看得到真相。这个产品在它唯一一次庆祝时刻上撒谎。
        //
        // 不会递归：`refresh()` 内部第一行就是 `onboardingViewModel.refresh()`，而探测是磁盘的
        // 纯函数 —— 第二遍得到同一个 state，`onChange` 不再触发。
        .onChange(of: onboardingViewModel.state) { _ in
            refresh()
            applyFirstFocus()
            announcePanel()
        }
        // 动作态变化（开始跑 / 失败）：① 播报——一颗变灰的按钮 + 一个 spinner 对 VoiceOver 是完全
        // 无声的，而这个仓库自己已经论证过「光有 label 不会被播报，VO 只读它光标落上的元素」；
        // ② 重新落焦——in-flight 期间 CTA 被禁用，持有焦点的那颗按钮当场作废，没人把焦点接走的话
        // 键盘用户按完空格就无处可去了。
        .onChange(of: onboardingViewModel.actionState) { newValue in
            announceActionState(newValue)
            applyFirstFocus()
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
        // ``announcePanel()`` is what actually says the sentence on open.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(headerAccessibilityLabel)
    }

    /// 「VoiceOver 进入先播报面板标题 + 当前包」 (ENGINEERING.md「无障碍规格」), which nothing in this
    /// view used to implement: the sentence lives in ``headerAccessibilityLabel``, hung on a
    /// static `Text` header that the VoiceOver cursor never lands on by itself. `@FocusState`
    /// doesn't help — that is the KEYBOARD focus, not the VoiceOver cursor. The only way to
    /// make VoiceOver *say* something on open is to ask it to.
    ///
    /// AppKit's `.announcementRequested` rather than SwiftUI's `AccessibilityNotification`
    /// (macOS 14+, above this package's macOS 12 floor). Async so it lands after the popover's
    /// window is key and in the AX tree — VoiceOver drops announcements aimed at an app that
    /// isn't there yet. A no-op when VoiceOver is off.
    private func announcePanel() {
        announce(headerAccessibilityLabel)
    }

    /// 一次 CTA 动作的开始 / 失败，也必须说出口（T17）。
    ///
    /// 与 ``announcePanel()`` 同一条推理，只是换了时刻：一个禁用的按钮 + 一个 spinner 对 VoiceOver
    /// 完全无声；一条静态 `Text` 写的失败原因，VO 光标不会自己跑过去。而用户此刻正在等一次可能长达
    /// 数百毫秒的磁盘复制，或者刚刚经历一次失败。
    ///
    /// 成功不在这里播报：成功会让 `state` 变成 `.installed`，由上面 `.onChange(of: state)` 里的
    /// ``announcePanel()`` 说出「Claudio 面板，当前声音包 X」—— 那句话比「成功了」信息量大得多。
    private func announceActionState(_ actionState: OnboardingActionState) {
        switch actionState {
        case .idle:
            break
        case .running(let action):
            announce(onboardingActionRunningTitle(action))
        case .failed(_, let message, _):
            announce(message)
        }
    }

    private func announce(_ message: String) {
        DispatchQueue.main.async {
            NSAccessibility.post(
                element: NSApp as Any,
                notification: .announcementRequested,
                userInfo: [
                    .announcement: message,
                    .priority: NSAccessibilityPriorityLevel.high.rawValue,
                ])
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            Text("Claudio")
                .font(.system(size: 15 * typeScale, weight: .semibold))
                .foregroundColor(ClaudioColor.text(colorScheme))
            if onboardingViewModel.state.showsHeaderTakenOverDot {
                Circle()
                    .fill(ClaudioColor.success(colorScheme))
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
            }
            Spacer()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(headerAccessibilityLabel)
    }

    private var headerAccessibilityLabel: String {
        guard onboardingViewModel.state == .installed else { return "Claudio 面板" }
        let packName = packCards.first(where: \.isSelected)?.name ?? config.selectedPack
        return "Claudio 面板，当前声音包 \(packName)"
    }

    // MARK: - Operational panel (installed state)

    @ViewBuilder
    private var operationalPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(eventRows, id: \.event) { row in
                if let importViewModel = rowImportViewModels[row.event] {
                    EventRowView(
                        row: row,
                        importViewModel: importViewModel,
                        focusedTarget: $focusedTarget,
                        adaptation: layoutAdaptation,
                        onPreview: { playPreview(for: row) },
                        onToggleMute: { toggleMute(row.event) },
                        // T16 fix: a successful row-end bind writes `manifest.json` but the
                        // row renders off `eventRows`, which only `refresh()` recomputes —
                        // without this the just-bound row keeps showing "未配置/文件丢失" and a
                        // disabled 试听 until an unrelated mute/switch/reopen. Recompute now.
                        onImportCompleted: { refresh() }
                    )
                }
            }
            // 绝不静默吞错（项目规则）—— 静音写回失败与切包失败**都**在这里如实上报。两条都
            // 可能同时非 nil（一次失败的静音 + 一次失败的切包），所以两条都渲染，不互相顶替。
            //
            // `.lockBusy` 尤其是**真会发生**的，不是理论值：`setEventEnabled`/`selectPack` 与
            // `claudio play` 抢同一把 `play.lock`，而每个 Claude Code 事件都会 spawn 一次
            // `claudio play`。点静音正好撞上 → 此前按钮纹丝不动、零反馈；现在它会说
            // 「…请稍后重试」（文案本来就写好在 `SetEventEnabledError`/`UseError` 里，只是没人显示）。
            if let error = muteController.lastError {
                errorNotice(error.description)
            }
            if let error = packSwitchError {
                errorNotice(error.description)
            }
            AudioDropZoneView(viewModel: dropZoneViewModel)
            PackGalleryView(
                cards: packCards, focusedTarget: $focusedTarget, onSelect: { switchPack(to: $0.id) })
            disconnectRow
        }
    }

    /// 「断开连接」——`.installed` 态的次 CTA（T17，**授权的设计变更**）。
    ///
    /// 它此前**在整个 shipping app 里没有一个像素**：`OnboardingCopy(.installed).secondaryActionTitle`
    /// 确实写着「断开连接」，但 `.installed` 时 `body` 渲染的是这个 `operationalPanel`，
    /// `OnboardingView` 压根不出现 —— 那颗按钮只活在 state gallery 里。而 `.notInstalled` 的正文
    /// 白纸黑字向用户承诺「还会自动留一份备份，**随时可以一键撤销**」。那个「一键」到今天为止
    /// 不存在。
    ///
    /// 失败也在这里渲染：断开失败的那一刻，onboarding 卡不在屏幕上（state 还是 `.installed`），
    /// 所以 `OnboardingView` 里那条 `ActionFailureRow` 够不着它。
    @ViewBuilder
    private var disconnectRow: some View {
        // 渲染**任何**失败，不只是断开的（T17c）。上一版这里只认 `branch: .disconnect`，理由是
        // 「一条陈旧的接管失败不该永久挂在一张已经装好的面板底部」—— 顾虑是真的，答案是错的：它让
        // 一次**真的**接管失败（失败后 state 恰好落在 `.installed`）变得**一个像素都没有**。
        // 陈旧问题现在由时效性回答（``OnboardingViewModel/clearConsumedFailure()``，面板重开即清），
        // 而不是靠在这里把它丢掉。
        if let failure = onboardingVisibleFailure(actionState: onboardingViewModel.actionState) {
            ActionFailureRow(
                message: failure.message, detail: failure.detail,
                isShowingDetail: onboardingViewModel.isShowingDetail,
                showsDetailToggle: onboardingShowsFailureDetailToggle(
                    state: onboardingViewModel.state, actionState: onboardingViewModel.actionState),
                onToggleDetail: { onboardingViewModel.toggleDetail() },
                focusedTarget: $focusedTarget, typeScale: typeScale)
        }

        let intent = onboardingSecondaryIntent(for: onboardingViewModel.state)
        let isRunning = onboardingViewModel.isRunning(intent)
        // copy 是按钮文案的**单一真相源**，没有兜底字面量（T17c）。上一版写的是
        // `?? "断开连接"` —— 一条死分支（`.installed` 的 `secondaryActionTitle` 恒非 nil），
        // 它唯一的效果是：哪天有人把那条 copy 改成 `nil`（= 「这个态没有这颗按钮」），面板照样会
        // 用硬编码字面量把按钮画出来，copy 与视图当场分叉且零信号。copy 说没有，就真的不画。
        if let baseTitle = onboardingViewModel.copy.secondaryActionTitle {
            let title = isRunning ? onboardingActionRunningTitle(.disconnect) : baseTitle

            Button {
                Task { await onboardingViewModel.performSecondaryAction() }
            } label: {
                HStack(spacing: 6) {
                    // `reduceMotion` 时不画 spinner（T17c）：这棵视图树的「无动画」绊线注释（见 body
                    // 上方）立下的规矩是「若将来往这棵树里加动画，**必须**在那一点 gate 住
                    // `accessibilityReduceMotion`」。`ProgressView` 是一个无限旋转动画，它是这棵树里
                    // 的第一个。降级路径正是 DESIGN.md 写的「静态字形与瞬时状态切换」—— 而进行态本来
                    // 就已经由文案（「正在断开…」）承担了，不靠那圈转动。
                    if isRunning, !reduceMotion {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityHidden(true)
                    }
                    Text(title)
                        .font(.system(size: 11 * typeScale))
                }
                .frame(maxWidth: .infinity)
                // ≥24×24 命中区（a11y-architect FIX 6）。
                .frame(minHeight: 24)
                .padding(.vertical, 4)
                .contentShape(RoundedRectangle(cornerRadius: 8))
            }
            // DESIGN.md「次 CTA = ghost」：**必须有 1px 描边**。裸 `.plain` 会让这条全宽的、破坏性的
            // 点击区在视觉上彻底消失 —— 用户看到的只是一行灰字，既不知道它是个按钮，也不知道它有多大。
            // 只用既有 token（`hairline-strong` 描边 + `text-2` 文字），不新造颜色。
            .buttonStyle(.plain)
            .foregroundColor(ClaudioColor.textSecondary(colorScheme))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(ClaudioColor.hairlineStrong(colorScheme), lineWidth: 1)
            )
            .disabled(onboardingViewModel.isPerformingAction)
            .accessibilityLabel(title)
            .accessibilityHint("摘掉 Claudio 的声音，Claude Code 的其它设置都保留")
            .focused($focusedTarget, equals: .disconnect)
        }
    }

    /// One panel-level failure line — the 「拒绝行」 shape DESIGN.md already defines ("真红
    /// `circle-x` 字形 + `text-2` 说明"), identical to ``AudioDropZoneView``'s `rejectRow(_:)` and
    /// ``EventRowView``'s `importErrorRow(_:)` so every failure in this panel looks like the same
    /// kind of thing.
    ///
    /// 真红只上**图标**（非文本，≥3:1），文案走 `text-2`（≥4.5:1）—— 真红当正文亮色下只有
    /// 4.07:1，不达文本门槛（`/ship` 评审实证）。
    private func errorNotice(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 11 * typeScale))
                .foregroundColor(ClaudioColor.error(colorScheme))
            Text(message)
                .font(.system(size: 11 * typeScale))
                .foregroundColor(ClaudioColor.textSecondary(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Dynamic Type (ENGINEERING.md T15 D5「Dynamic Type + 降级规则」)

    /// Real `DynamicTypeSize` (11 cases) → this panel's own 4-tier
    /// ``PanelTypeSizeTier`` — the only place this mapping happens; the actual DEGRADATION
    /// TABLE for each tier (``panelLayoutAdaptation(for:)``) lives in `ClaudioGUICore` and
    /// is unit-tested there. This mapping itself is a one-line SwiftUI-only lookup, not a
    /// "decision" worth its own test (the environment type isn't available outside SwiftUI).
    private var typeSizeTier: PanelTypeSizeTier {
        switch dynamicTypeSize {
        case .xSmall, .small, .medium, .large: .standard
        case .xLarge, .xxLarge: .larger
        case .xxxLarge, .accessibility1: .largest
        default: .maximum  // .accessibility2...5
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
        // `ctaOperable` (T17): while a `.takeOver`/`.disconnect` is in flight, both CTAs are
        // `.disabled(...)`, so the pure model must not hand focus to one — otherwise the caret
        // sits on a dead control and the keyboard user who just pressed 空格 on 「接管」 has
        // nowhere to go. Same 可操作 rule the muted-row's disabled 试听 ▶ already obeys, applied
        // to a transition that happens INSIDE the panel rather than at open.
        let ctaOperable = !onboardingViewModel.isPerformingAction
        // 失败行上那颗「查看原因」是一个真控件，所以它必须在焦点序里 —— 而渲染它的判据与算焦点序的
        // 判据是**同一个纯函数**，两者不可能各自漂移。
        let hasDetailToggle = onboardingShowsFailureDetailToggle(
            state: onboardingViewModel.state, actionState: onboardingViewModel.actionState)

        guard onboardingViewModel.state == .installed else {
            let copy = onboardingViewModel.copy
            focusedTarget = panelFirstFocusTarget(
                .onboarding(
                    hasPrimaryAction: copy.primaryActionTitle != nil,
                    hasSecondaryAction: copy.secondaryActionTitle != nil,
                    hasDetailToggle: hasDetailToggle),
                ctaOperable: ctaOperable)
            return
        }
        focusedTarget = panelOpeningFocus(
            rows: eventRows, packCardIDs: packCards.map(\.id), ctaOperable: ctaOperable,
            hasDetailToggle: hasDetailToggle)
    }

    // MARK: - Actions

    /// Resolves the row's present file against the SELECTED pack directory (never trusting
    /// a stale path) and plays it — the real playback wiring `EventRowView`'s `onPreview`
    /// seam has always awaited (its own doc comment: "the caller...owns turning this into
    /// an actual playback call").
    /// 试听这一行的声音。
    ///
    /// `else` 分支**不是**空的（本轮 /ship 评审：Claude 对抗子代理）。走到这里说明 `row.coverage` 还是
    /// `.present`——那是上一次 ``refresh()`` 时算出来的——但文件此刻已经解析不出来了：用户在这中间把它
    /// 删了 / 改名了 / 换成了一个目录。原来的 `else { return }` 让「点了试听、什么都没发生、也没有任何
    /// 解释」成为可能，而这正是这一轮刚在 `switchPack` / 静音 / 绑定三处修掉的那种静默吞错。
    ///
    /// 修法不是弹一个错误框，而是**让面板说实话**：重跑 `refresh()`，这一行会自己从 `.present` 变成
    /// `.broken`（「文件丢失」+ 进 doctor）。用户点下去看到的是行的状态当场改变——那比任何一句提示都更
    /// 接近「不回头也知道状态」。
    private func playPreview(for row: EventRow) {
        guard case .present(let fileName) = row.coverage,
            let packDirectory = resolvePackDirectory(
                id: config.selectedPack, userPacksDirectory: audioEnvironment.userPacksDirectory,
                bundledPacksDirectory: audioEnvironment.bundledPacksDirectory),
            let resolvedFile = safePackFileURL(fileName, in: packDirectory),
            regularFileExists(at: resolvedFile)
        else {
            refresh()
            return
        }
        previewPlayer.play(fileAt: resolvedFile)
    }

    /// Flips `event`'s mute flag to the opposite of its CURRENT ``EventRow/enabled`` value,
    /// via ``EventMuteController`` — never re-derives the write itself.
    ///
    /// On FAILURE this does not silently do nothing (it used to): ``EventMuteController/setEnabled(_:enabled:)``
    /// records the reason in its own `@Published` ``EventMuteController/lastError``, which
    /// ``operationalPanel`` now renders — so a `.lockBusy` (a real, reachable race with the
    /// `claudio play` every Claude Code event spawns, both taking `play.lock`) shows 「…请稍后
    /// 重试」 instead of a button that just doesn't move.
    private func toggleMute(_ event: Event) {
        let currentlyEnabled = eventRows.first(where: { $0.event == event })?.enabled ?? true
        if muteController.setEnabled(event, enabled: !currentlyEnabled) {
            refreshEnabledFlags()
        }
    }

    /// Switches the selected pack via ``selectPack(_:configFile:userPacksDirectory:bundledPacksDirectory:lockFile:)``
    /// — the exact same write path `claudio use`/`performFirstRunSetup` already use, never a
    /// second one. A FAILURE is recorded in ``packSwitchError`` (and rendered by
    /// ``operationalPanel``), never discarded: this was `if case .success = result { refresh() }`,
    /// which threw the error away entirely — a dead card click with no explanation.
    private func switchPack(to packID: String) {
        switch selectPack(
            packID, configFile: configFile, userPacksDirectory: audioEnvironment.userPacksDirectory,
            bundledPacksDirectory: audioEnvironment.bundledPacksDirectory, lockFile: lockFile)
        {
        case .success:
            packSwitchError = nil
            refresh()
        case .failure(let error):
            packSwitchError = error
        }
    }

    /// The panel's LIGHTWEIGHT post-mute refresh (`/ship` 评审 · 性能): re-reads `config.json` and
    /// recomputes ONLY the `enabled` bit of each row.
    ///
    /// A mute toggle flips exactly one boolean in `config.json`. It **cannot** change any pack's
    /// `manifest.json`, any sound file's existence, or which packs are on disk — so the full
    /// ``refresh()``, which re-reads the selected pack's manifest + `stat`s each event's file +
    /// enumerates BOTH pack roots and reads EVERY pack's manifest, is pure waste on this path:
    /// a main-thread disk scan of the entire pack library on every click of a mute button.
    /// ``CoverageState`` is carried over UNCHANGED from the rows we already have — not because
    /// it's cheap to recompute, but because it is unchanged *by definition* of what was written.
    ///
    /// (`config` itself is re-read rather than patched in memory, so the panel still reflects the
    /// bytes that actually landed on disk — the same re-detect-don't-patch discipline ``refresh()``
    /// follows.)
    private func refreshEnabledFlags() {
        let reloaded = loadPanelConfig(from: configFile)
        config = reloaded
        eventRows = eventRows.map { row in
            EventRow(event: row.event, coverage: row.coverage, enabled: reloaded.isEnabled(row.event))
        }
    }

    /// Re-reads `config.json` + recomputes every derived read model — the panel's "something on
    /// disk might have changed" rule (mirrors `OnboardingViewModel/refresh()`'s exact same
    /// re-detect-don't-patch shape). Called when the popover (re)opens, after a pack switch, and
    /// after a row-end import/bind — i.e. only on paths that really can have changed a pack's
    /// manifest or files. A mute toggle goes through ``refreshEnabledFlags()`` instead (see there).
    ///
    /// Does NOT re-run onboarding detection's *own* underlying facts (helper binary /
    /// settings.json) beyond what `onboardingViewModel.refresh()` already does — this view
    /// never duplicates that detection.
    private func refresh() {
        onboardingViewModel.refresh()
        config = loadPanelConfig(from: configFile)
        eventRows = packCoverage(packID: config.selectedPack, config: config, environment: audioEnvironment)
        packCards = availablePacks(config: config, environment: audioEnvironment)
        // `retarget(to:)`，不是裸赋 `packID`：包换了，属于上一个包的导入 / 绑定结果就失去了主语，必须
        // 一起丢掉，否则包 A 的「已加入 stop.mp3」/「manifest 读不动」会原样留在包 B 的面板上
        // （本轮 /ship 评审：`/codex review` [P2]）。两个 view-model 都只在包**真的换了**时才清——
        // `refresh()` 在一次导入 / 绑定结束后也会被调用，无条件清空会把用户刚触发的那条结果（尤其是
        // 失败原因）在他看见之前抹掉。判断条件在 view-model 里，这里不重复一遍。
        dropZoneViewModel.retarget(to: config.selectedPack)
        for rowViewModel in rowImportViewModels.values {
            rowViewModel.retarget(to: config.selectedPack)
        }
    }
}
