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

    public init(
        audioEnvironment: AudioImportEnvironment,
        configFile: URL = ClaudioPaths.configFile,
        lockFile: URL = ClaudioPaths.lockFile,
        onboardingEnvironment: OnboardingEnvironment = OnboardingEnvironment(),
        focusCoordinator: PanelFocusCoordinator = PanelFocusCoordinator()
    ) {
        self.audioEnvironment = audioEnvironment
        self.configFile = configFile
        self.lockFile = lockFile
        self.focusCoordinator = focusCoordinator
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
        .onAppear {
            refresh()
            applyFirstFocus()
        }
        // a11y-architect FIX 4: `MenuBarController.popoverDidShow` bumps
        // `focusCoordinator.showCount` every time the popover becomes visible — `.onAppear`
        // alone is not reliable enough across repeated show/close cycles (see
        // `PanelFocusCoordinator`'s doc comment), so this is the SECOND, EXPLICIT trigger for
        // the same "apply first focus" step, not a duplicate/competing one.
        .onChange(of: focusCoordinator.showCount) { _ in
            refresh()
            applyFirstFocus()
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
            AudioDropZoneView(viewModel: dropZoneViewModel)
            PackGalleryView(
                cards: packCards, focusedTarget: $focusedTarget, onSelect: { switchPack(to: $0.id) })
        }
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

    /// This panel's CURRENT ``PanelFocusScope`` — the same shape `operationalPanel`/
    /// `OnboardingView` branch renders off (`onboardingViewModel.state == .installed` for
    /// operational, else onboarding), fed straight into ``panelFocusOrder(_:)`` so the
    /// consumed ORDER and the actually-rendered CONTROLS can never silently disagree about
    /// which state the panel is in.
    private var currentFocusScope: PanelFocusScope {
        guard onboardingViewModel.state == .installed else {
            let copy = onboardingViewModel.copy
            return .onboarding(
                hasPrimaryAction: copy.primaryActionTitle != nil,
                hasSecondaryAction: copy.secondaryActionTitle != nil)
        }
        return .operational(events: eventRows.map(\.event), packCardIDs: packCards.map(\.id))
    }

    /// Sets ``focusedTarget`` to ``panelFocusOrder(_:)``'s current first item — called on
    /// appear and every time ``focusCoordinator`` signals the popover just (re)showed. Note:
    /// setting a SwiftUI `@FocusState` value only actually MOVES real AppKit keyboard focus
    /// once the hosting view is already part of the window's responder chain — that half is
    /// `MenuBarController.popoverDidShow`'s `makeFirstResponder` call, which always runs
    /// BEFORE this (via `focusCoordinator.requestFocus()`), never after.
    private func applyFirstFocus() {
        focusedTarget = panelFocusOrder(currentFocusScope).first
    }

    // MARK: - Actions

    /// Resolves the row's present file against the SELECTED pack directory (never trusting
    /// a stale path) and plays it — the real playback wiring `EventRowView`'s `onPreview`
    /// seam has always awaited (its own doc comment: "the caller...owns turning this into
    /// an actual playback call").
    private func playPreview(for row: EventRow) {
        guard case .present(let fileName) = row.coverage,
            let packDirectory = resolvePackDirectory(
                id: config.selectedPack, userPacksDirectory: audioEnvironment.userPacksDirectory,
                bundledPacksDirectory: audioEnvironment.bundledPacksDirectory),
            let resolvedFile = safePackFileURL(fileName, in: packDirectory)
        else { return }
        previewPlayer.play(fileAt: resolvedFile)
    }

    /// Flips `event`'s mute flag to the opposite of its CURRENT ``EventRow/enabled`` value,
    /// via ``EventMuteController`` — never re-derives the write itself.
    private func toggleMute(_ event: Event) {
        let currentlyEnabled = eventRows.first(where: { $0.event == event })?.enabled ?? true
        if muteController.setEnabled(event, enabled: !currentlyEnabled) {
            refresh()
        }
    }

    /// Switches the selected pack via ``selectPack(_:configFile:userPacksDirectory:bundledPacksDirectory:lockFile:)``
    /// — the exact same write path `claudio use`/`performFirstRunSetup` already use, never a
    /// second one.
    private func switchPack(to packID: String) {
        let result = selectPack(
            packID, configFile: configFile, userPacksDirectory: audioEnvironment.userPacksDirectory,
            bundledPacksDirectory: audioEnvironment.bundledPacksDirectory, lockFile: lockFile)
        if case .success = result {
            refresh()
        }
    }

    /// Re-reads `config.json` + recomputes every derived read model — the panel's one and
    /// only "something on disk might have changed" rule (mirrors
    /// `OnboardingViewModel/refresh()`'s exact same re-detect-don't-patch shape). Called on
    /// appear and after every local write this view performs (mute toggle, pack switch).
    /// Does NOT re-run onboarding detection's *own* underlying facts (helper binary /
    /// settings.json) beyond what `onboardingViewModel.refresh()` already does — this view
    /// never duplicates that detection.
    private func refresh() {
        onboardingViewModel.refresh()
        config = loadPanelConfig(from: configFile)
        eventRows = packCoverage(packID: config.selectedPack, config: config, environment: audioEnvironment)
        packCards = availablePacks(config: config, environment: audioEnvironment)
        dropZoneViewModel.packID = config.selectedPack
        for importViewModel in rowImportViewModels.values {
            importViewModel.importViewModel.packID = config.selectedPack
        }
    }
}
