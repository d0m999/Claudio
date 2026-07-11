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
    // No `@Environment(\.accessibilityReduceMotion)` read here: this view tree (PanelView /
    // EventRowView / PackGalleryView / OnboardingView) applies NO `.animation()`/
    // `withAnimation` anywhere — DESIGN.md's "招牌动效" (pitch-follow motion, EQ-bar bounce,
    // visual waveform replay) isn't implemented by any T-numbered task yet, so there is
    // nothing implicit to suppress today. This is a real compliance state, not an oversight:
    // if a future task adds any animation to this tree, it MUST gate it behind
    // `accessibilityReduceMotion` at that point — this comment is the tripwire.
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

        _onboardingViewModel = StateObject(
            wrappedValue: OnboardingViewModel(environment: onboardingEnvironment))
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
            onPanelWidthChange(layoutAdaptation.panelWidth)
        }
        // a11y-architect FIX 4: `MenuBarController.popoverDidShow` bumps
        // `focusCoordinator.showCount` every time the popover becomes visible — the ONE place
        // "the popover just (re)opened, re-read the disk" is handled.
        .onChange(of: focusCoordinator.showCount) { _ in
            refresh()
            applyFirstFocus()
        }
        // T15 D5 「极大 → 加宽 popover」: SwiftUI already widened ITSELF (`.frame(width:)` above);
        // this tells the AppKit popover around it to follow (see ``onPanelWidthChange``).
        .onChange(of: layoutAdaptation.panelWidth) { newWidth in
            onPanelWidthChange(newWidth)
        }
        // ENGINEERING.md「无障碍规格」: "VoiceOver 进入先播报面板标题 + 当前包" — a single
        // combined announcement for the header, mirroring `EventRowView`'s own row-level
        // combine pattern.
        .accessibilityElement(children: .contain)
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
        guard onboardingViewModel.state == .installed else {
            let copy = onboardingViewModel.copy
            focusedTarget = panelFirstFocusTarget(
                .onboarding(
                    hasPrimaryAction: copy.primaryActionTitle != nil,
                    hasSecondaryAction: copy.secondaryActionTitle != nil))
            return
        }
        focusedTarget = panelOpeningFocus(rows: eventRows, packCardIDs: packCards.map(\.id))
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
