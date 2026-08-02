#if DEBUG
import ClaudioCore
import ClaudioGUIComponents
    import ClaudioGUICore
    import SoundPacksWindow
    import SwiftUI

    /// The repo-internal SwiftUI state gallery (ENGINEERING.md T14 D2) — the in-repo VISUAL
    /// TRUTH SOURCE. Renders ONE frame per ``PreviewFixtures`` value across the app's
    /// current per-feature state families and dual-host scenarios, plus an explicitly labelled
    /// archive for the still-supported Claude-only legacy onboarding components (``OnboardingState``, ``OnboardingActionState``,
    /// ``DropZoneState``, ``EventRow``/``CoverageState``, ``PackCard``/``PackCardState``,
    /// ``MasterVolumeState`` — PLAN-MASTER-VOLUME.md D33/D38), EXCLUSIVELY off
    /// `PreviewFixtures` — no ad-hoc values are constructed anywhere in this file. See
    /// `PreviewFixtures`'s own doc comment for why it — and therefore this gallery — is the
    /// single source both the gallery and the state tests draw sample values from.
    ///
    /// `#if DEBUG`-gated end to end: every frame here pins a view-model's state via a
    /// `#if DEBUG`-only `previewState:` initializer (``OnboardingViewModel``,
    /// ``AudioImportViewModel``, both in `ClaudioGUICore`), so this whole file can never
    /// compile into a release build — matching those initializers' own scoping exactly.
    ///
    /// COMPILE-ONLY here (CommandLineTools, no Xcode/simulator): `swift build --package-path
    /// gui` proves every frame + every `PreviewProvider` below actually compiles; the
    /// gallery's real VISUAL truth — what each frame actually *looks* like — is Xcode
    /// Canvas, on a real Mac, per this repo's harness notes (`#Preview` does not compile
    /// under CommandLineTools; only the classic `PreviewProvider` protocol form is used
    /// below).
    struct StateGalleryView: View {
        @Environment(\.colorScheme) private var colorScheme

        var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    GallerySection(title: "Legacy Claude-only onboarding archive（非生产 Panel）") {
                        OnboardingGalleryView()
                        OnboardingActionGalleryView()
                    }
                    EventRowGalleryView()
                    PanelPackSectionGalleryView()
                    InterfaceTextSizeGalleryView()
                    MasterVolumeGalleryView()
                    PackCardGalleryView()
                    GallerySection(title: "Sound Packs Window (3 production states)") {
                        SoundPacksWindowStateGalleryView()
                    }
                    HostIntegrationGalleryView()
                }
                .padding(20)
            }
            // The gallery's own chrome sits on a TOKENIZED surface too, never SwiftUI's
            // untokenized default window background — see ``GalleryFrame``'s note for why that
            // background was a correctness bug in a file DESIGN.md calls the 视觉真相源.
            .background(ClaudioColor.panel(colorScheme))
        }
    }

    // MARK: - OnboardingState (6 fixtures)

    struct OnboardingGalleryView: View {
        var body: some View {
            GallerySection(title: "Legacy OnboardingState (\(PreviewFixtures.onboardingStates.count))") {
                ForEach(Array(PreviewFixtures.onboardingStates.enumerated()), id: \.offset) { _, state in
                    GalleryFrame(caption: onboardingStateCaption(state)) {
                        OnboardingStateFrame(state: state)
                    }
                }
            }
        }
    }

    /// One onboarding frame — owns its own `@FocusState` (SwiftUI requires the property
    /// wrapper to be declared on a concrete `View`, not conjured ad hoc per loop iteration),
    /// mirroring `PanelView`'s real `focusedTarget` ownership at a per-frame scale.
    private struct OnboardingStateFrame: View {
        let state: OnboardingState
        /// T17: the CTA's own state, pinned alongside `state` (both are `#if DEBUG` preview-init
        /// parameters). `.idle` for the six plain ``OnboardingState`` frames.
        var actionState: OnboardingActionState = .idle
        @FocusState private var focusedTarget: PanelFocusTarget?

        var body: some View {
            OnboardingView(
                viewModel: OnboardingViewModel(previewState: state, actionState: actionState),
                focusedTarget: $focusedTarget
            )
            .frame(width: CGFloat(standardPanelWidth))
        }
    }

    // MARK: - OnboardingActionState (T17: the CTA's own state — in-flight / failed)

    /// The two visual states T17 introduces — a CTA that is RUNNING (disabled + spinner + a
    /// changed label) and a CTA that FAILED (a rejection row, optionally with a 「查看原因」
    /// disclosure). Without this section they would be the first states in the repo that no frame
    /// of the 视觉真相源 has ever rendered — in either theme — while `assertExhaustive()` stayed
    /// green, because `onboardingStates` still covers its own six cases perfectly.
    ///
    /// Rendered against `.notInstalled` (the state a first-run user actually presses 接管 from),
    /// except `.running(.disconnect)` which only exists in `.installed`.
    struct OnboardingActionGalleryView: View {
        var body: some View {
            GallerySection(
                title: "Legacy OnboardingActionState (\(PreviewFixtures.onboardingActionStates.count))"
            ) {
                ForEach(
                    Array(PreviewFixtures.onboardingActionStates.enumerated()), id: \.offset
                ) { _, actionState in
                    GalleryFrame(caption: onboardingActionStateCaption(actionState)) {
                        OnboardingStateFrame(
                            state: hostState(for: actionState), actionState: actionState)
                    }
                }
            }
        }

        /// 哪个 ``OnboardingState`` 承载这一帧。`.running(.disconnect)` 只可能发生在 `.installed`
        /// （断开是它的次 CTA）；`.reported` 同理 —— 告知只从一次**成功的接管**而来，而成功必然让
        /// `refresh()` 把 state 推成 `.installed`（T17f）。其余都用 `.notInstalled` —— 新用户真正
        /// 按下「接管」的那个状态。
        ///
        /// ⚠️ **诚实标注**：这一帧渲染的是 `OnboardingStateFrame` → `OnboardingView`，而真机上
        /// `.installed` 渲染的是 `PanelView` 的运行态面板 —— 也就是说画廊在这里展示的是告知行的
        /// **长相**（字形 / 颜色 / 断行 / Dynamic Type），不是它**真实的落位**。`.running(.disconnect)`
        /// 早就有同一条错位，本次没有引入新的债。真实落位由 `ViewWiringSuite` 的两条文本绊线守着
        /// （两个渲染点都必须调 `onboardingVisibleNotices`）。
        private func hostState(for actionState: OnboardingActionState) -> OnboardingState {
            if case .running(.disconnect) = actionState { return .installed }
            if case .reported = actionState { return .installed }
            return .notInstalled
        }
    }

    private func onboardingActionStateCaption(_ state: OnboardingActionState) -> String {
        switch state {
        case .idle: ".idle"
        case .running(.takeOver): ".running(.takeOver) × .notInstalled"
        case .running(.disconnect): ".running(.disconnect) × .installed"
        case .failed(let action, _, let detail):
            detail == nil
                ? ".failed(\(action), detail: nil) × .notInstalled"
                : ".failed(\(action), detail: …) × .notInstalled（可展开）"
        case .reported(let notices):
            ".reported(\(notices.count) 条) × .installed —— 我替你做了主"
        }
    }

    /// A developer-facing (not user-facing) label for the gallery caption — exhaustive over
    /// every ``OnboardingState`` case, no `default:`, so a 7th case fails this file to
    /// compile until it's captioned too (on top of ``PreviewFixtures``'s own guard).
    private func onboardingStateCaption(_ state: OnboardingState) -> String {
        switch state {
        case .claudeCodeNotInstalled: ".claudeCodeNotInstalled"
        case .helperMissing: ".helperMissing"
        case .settingsNotWritable(let reason): ".settingsNotWritable(reason: \"\(reason)\")"
        case .settingsParseFailure(let reason): ".settingsParseFailure(reason: \"\(reason)\")"
        case .notInstalled: ".notInstalled"
        case .installed: ".installed"
        }
    }

    // MARK: - EventRow / CoverageState (6 fixtures)

    struct EventRowGalleryView: View {
        var body: some View {
            GallerySection(title: "EventRow / CoverageState (\(PreviewFixtures.eventRows.count))") {
                ForEach(Array(PreviewFixtures.eventRows.enumerated()), id: \.offset) { _, row in
                    GalleryFrame(caption: eventRowCaption(row)) {
                        EventRowStateFrame(row: row)
                    }
                }
            }
        }
    }

    private struct EventRowStateFrame: View {
        let row: EventRow
        @FocusState private var focusedTarget: PanelFocusTarget?

        var body: some View {
            // 生产事件行只负责扫读、显式编辑路由、手工试听与自动事件静音；画廊不写磁盘。
            EventRowView(
                row: row,
                previewAvailability: eventPreviewAvailability(
                    coverage: row.coverage,
                    masterVolume: 1),
                focusedTarget: $focusedTarget,
                onPreview: {}
            )
            .frame(width: CGFloat(standardPanelWidth))
        }
    }

    private func eventRowCaption(_ row: EventRow) -> String {
        "\(row.event.cliName) · \(coverageStateCaption(row.coverage)) · enabled=\(row.enabled)"
    }

    /// Exhaustive over every ``CoverageState`` case, no `default:`.
    private func coverageStateCaption(_ state: CoverageState) -> String {
        switch state {
        case .present: ".present"
        case .unmapped: ".unmapped"
        case .broken: ".broken"
        }
    }

    // MARK: - Product UI refactor states

    struct PanelPackSectionGalleryView: View {
        var body: some View {
            GallerySection(
                title: "PanelPackSectionState (\(PreviewFixtures.panelPackSectionStates.count))"
            ) {
                ForEach(
                    Array(PreviewFixtures.panelPackSectionStates.enumerated()),
                    id: \.offset
                ) { _, state in
                    GalleryFrame(caption: panelPackSectionCaption(state)) {
                        PanelPackSectionStateFrame(state: state)
                    }
                }
            }
        }
    }

    private struct PanelPackSectionStateFrame: View {
        let state: PanelPackSectionState
        @FocusState private var focusedTarget: PanelFocusTarget?

        var body: some View {
            PanelPackSectionView(
                state: state,
                typeScale: 1,
                focusedTarget: $focusedTarget,
                adaptation: panelLayoutAdaptation(for: .standard),
                onSelect: { _ in })
                .frame(width: CGFloat(standardPanelWidth))
        }
    }

    private func panelPackSectionCaption(_ state: PanelPackSectionState) -> String {
        switch state {
        case .pinned(let cards): ".pinned(\(cards.count))"
        case .noPinnedPacks(let count): ".noPinnedPacks(available: \(count))"
        case .noPacks: ".noPacks"
        case .readFailed: ".readFailed"
        }
    }

    struct InterfaceTextSizeGalleryView: View {
        var body: some View {
            GallerySection(title: "ClaudioInterfaceTextSize (4)") {
                ForEach(PreviewFixtures.interfaceTextSizes) { size in
                    GalleryFrame(caption: ".\(size.rawValue) · \(size.displayName)") {
                        InterfaceTextSizeFrame(size: size)
                    }
                }
            }
        }
    }

    private struct InterfaceTextSizeFrame: View {
        let size: ClaudioInterfaceTextSize
        @FocusState private var focusedTarget: PanelFocusTarget?

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                Text("claudi0 · 当前声音包 极简铃 · 4 个可听事件")
                    .font(ClaudioTheme.font(.productTitle))
                EventRowView(
                    row: PreviewFixtures.eventRows[0],
                    previewAvailability: .available(fileName: "stop.mp3"),
                    focusedTarget: $focusedTarget,
                    adaptation: panelLayoutAdaptation(for: panelTier))
            }
            .frame(width: size == .maximum ? CGFloat(widenedPanelWidth) : CGFloat(standardPanelWidth))
            .environment(\.dynamicTypeSize, size.dynamicTypeSize)
        }

        private var panelTier: PanelTypeSizeTier {
            switch size {
            case .compact, .standard: .standard
            case .large: .larger
            case .maximum: .maximum
            }
        }
    }

    // MARK: - MasterVolumeState (6 fixtures, PLAN-MASTER-VOLUME.md D33/D38)

    struct MasterVolumeGalleryView: View {
        var body: some View {
            GallerySection(
                title: "MasterVolumeState (\(PreviewFixtures.masterVolumeStates.count))"
            ) {
                ForEach(Array(PreviewFixtures.masterVolumeStates.enumerated()), id: \.offset) { _, state in
                    GalleryFrame(caption: masterVolumeStateCaption(state)) {
                        MasterVolumeStateFrame(state: state)
                    }
                }
            }
        }
    }

    /// One master-volume frame. The gallery never actually writes anything — every frame's state
    /// is fully determined by ``PreviewFixtures/MasterVolumeState``, so ``onCommit`` is a no-op
    /// that always reports failure (never invoked in practice, since nothing here drags the
    /// slider) and ``focusCoordinator`` is a fresh, never-observed instance (mirrors this file's
    /// other frames constructing throwaway view-models pinned to no particular state).
    ///
    /// D39: `.writeFailed` is rendered by `PanelView`, not `MasterVolumeRow` itself — this frame
    /// reproduces that exact split (row, then a SEPARATE error row) for the `.failed` case, rather
    /// than inventing a shape `MasterVolumeRow` alone could never produce on its own.
    private struct MasterVolumeStateFrame: View {
        let state: PreviewFixtures.MasterVolumeState
        @FocusState private var focusedTarget: PanelFocusTarget?
        @Environment(\.colorScheme) private var colorScheme

        var body: some View {
            VStack(alignment: .leading, spacing: 4) {
                MasterVolumeRow(
                    diskVolume: volume,
                    onCommit: { _ in nil },
                    focusCoordinator: PanelFocusCoordinator(),
                    focusedTarget: $focusedTarget,
                    adaptation: panelLayoutAdaptation(for: .standard))
                if case .failed(_, let message) = state {
                    FailureRow(message: message)
                }
            }
            .frame(width: CGFloat(standardPanelWidth))
        }

        private var volume: Double {
            switch state {
            case .value(let volume): volume
            case .failed(let volume, _): volume
            }
        }

        /// 直接渲染产品用的那一个 ``FailureRow``（`PanelRows.swift`）—— 展柜画的就是真身，不是它的仿品。
        ///
        /// 【这里原本是第七份手抄副本，而它的注释把整个病灶说穿了】原文：
        ///
        /// > Mirrors `PanelView.errorNotice`'s shape **verbatim** … this repo's established
        /// > 「拒绝行」 pattern is **duplicated per-view rather than shared** …, since each already
        /// > lives as a `private` method on a `View` with **no public surface for another file to call**.
        ///
        /// 那句话是**对当时事实的准确描述**，也正是复制粘贴自我繁殖的机制：前五份全是 `private`，于是
        /// 第六个想用它的人**只能再抄一份** —— 而每一份新副本，都被前面那些副本正当化了。抄到第七份时，
        /// 「大家都是抄的」本身成了继续抄下去的理由。
        ///
        /// 它还有一个副本独有的 bug：字号是裸 `size: 11`，**没有乘 `typeScale`** —— 展柜里这一行字
        /// 从来不跟随 Dynamic Type。换成 `FailureRow` 之后它**免费**获得了跟随（组件自带
        /// `@ScaledMetric`），这一条谁都没去修过，它是被这次合并顺手带走的。
        ///
        /// 现在那个「no public surface」不成立了：``FailureRow`` 就是那个 surface。
    }

    /// Exhaustive over every ``MasterVolumeState`` case, no `default:`.
    private func masterVolumeStateCaption(_ state: PreviewFixtures.MasterVolumeState) -> String {
        switch state {
        case .value(let volume): ".value(\(volume))"
        case .failed(let volume, let message):
            ".failed(volume: \(volume), message: \"\(message.prefix(24))…\")"
        }
    }

    // MARK: - PackCard / PackCardState (6 fixtures)

    struct PackCardGalleryView: View {
        var body: some View {
            GallerySection(title: "PackCard / PackCardState (\(PreviewFixtures.packCards.count))") {
                ForEach(Array(PreviewFixtures.packCards.enumerated()), id: \.offset) { _, card in
                    GalleryFrame(caption: packCardCaption(card)) {
                        PackCardStateFrame(card: card)
                    }
                }
            }
        }
    }

    private struct PackCardStateFrame: View {
        let card: PackCard
        @FocusState private var focusedTarget: PanelFocusTarget?

        var body: some View {
            // `PackCardView` itself is `private` to `PackGalleryView.swift` — a single-card
            // array is the only way to render exactly one card via the public
            // `PackGalleryView` API, never a second, parallel card-rendering path.
            PackGalleryView(cards: [card], focusedTarget: $focusedTarget)
        }
    }

    private func packCardCaption(_ card: PackCard) -> String {
        "\(card.id) · \(packCardStateCaption(card.state)) · isSelected=\(card.isSelected)"
    }

    /// Exhaustive over every ``PackCardState`` case, no `default:`.
    private func packCardStateCaption(_ state: PackCardState) -> String {
        switch state {
        case .complete: ".complete"
        case .partial(let present, let total): ".partial(\(present)/\(total))"
        case .broken: ".broken"
        }
    }

    // MARK: - Host integrations (10 dual-host scenarios)

    /// 双宿主展柜直接渲染生产 ``IntegrationsWindowView``：宿主卡、可听矩阵、检查器和
    /// Dynamic Type 重排全都走同一份视图，不在 gallery 复制第二套展示组件。
    struct HostIntegrationGalleryView: View {
        var body: some View {
            GallerySection(
                title: "Host integrations (\(PreviewFixtures.hostIntegrationScenarios.count))"
            ) {
                ForEach(PreviewFixtures.hostIntegrationScenarios) { scenario in
                    GalleryFrame(caption: "\(scenario.id) · \(scenario.title)") {
                        HostIntegrationStateFrame(scenario: scenario)
                    }
                }
            }
        }
    }

    private struct HostIntegrationStateFrame: View {
        @StateObject private var model: IntegrationsWindowModel
        @StateObject private var focusCoordinator = IntegrationsWindowFocusCoordinator()

        init(scenario: PreviewFixtures.HostIntegrationScenario) {
            let store = HostIntegrationPresentationStore(
                state: scenario.state,
                configurationSources: [
                    .claudeCode: "~/.claude/settings.json",
                    .codex: "~/.codex/hooks.json",
                ])
            let content = store.content
            let unchanged = IntegrationsWindowActionOutcome(
                content: content,
                feedbackKind: .information,
                feedbackMessage: "预览不会修改配置")
            _model = StateObject(
                wrappedValue: IntegrationsWindowModel(
                    content: content,
                    refreshHandler: IntegrationsWindowRefreshHandler { unchanged },
                    actionHandler: IntegrationsWindowActionHandler { _ in unchanged },
                    clipboardWriter: IntegrationsWindowClipboardWriter { _ in true }))
        }

        var body: some View {
            IntegrationsWindowView(
                model: model,
                focusCoordinator: focusCoordinator)
                .frame(width: 680, height: 640)
        }
    }

    // MARK: - Shared gallery chrome

    private struct GallerySection<Content: View>: View {
        let title: String
        let content: Content
        @Environment(\.colorScheme) private var colorScheme

        init(title: String, @ViewBuilder content: () -> Content) {
            self.title = title
            self.content = content()
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    // 既有 token，不是 SwiftUI 默认 `.primary`。
                    .foregroundColor(ClaudioColor.text(colorScheme))
                content
            }
        }
    }

    private struct GalleryFrame<Content: View>: View {
        let caption: String
        let content: Content
        @Environment(\.colorScheme) private var colorScheme

        init(caption: String, @ViewBuilder content: () -> Content) {
            self.caption = caption
            self.content = content()
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 4) {
                Text(caption)
                    .font(.system(size: 10, design: .monospaced))
                    .monospacedDigit()
                    // 既有 token（`text-2`），不是非 token 的 `.secondary`。
                    .foregroundColor(ClaudioColor.textSecondary(colorScheme))
                // LOAD-BEARING (`/ship` 评审): every framed view here — ``EventRowView``,
                // ``PackGalleryView``, ``OnboardingView`` — paints NO surface of its own; in
                // production ``PanelView`` (the composition root) supplies it. Without this
                // background, the gallery rendered all four event colors, every
                // glyph tile and every reject row on SwiftUI's **untokenized default window
                // background** — and that surface is precisely what every contrast assertion in
                // `ContrastSuite` is talking about. A 视觉真相源 (DESIGN.md line 134) that shows
                // the colors on the wrong surface is worse than no gallery: it makes a
                // contrast failure look fine (which is exactly how the glyph-tile ≥3:1 failure
                // this pass fixes survived review). `panel` in both schemes — the same token
                // `PanelView` uses.
                content
                    .background(ClaudioColor.panel(colorScheme))
            }
            .padding(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    // 既有 token，不是非 token 的 `Color.gray.opacity(0.2)`。
                    .strokeBorder(ClaudioColor.hairlineStrong(colorScheme))
            )
        }
    }

    // MARK: - Preview-only support environment (never touches disk)

    /// A fixed-duration stub — the gallery never actually imports a file (every drop-zone
    /// frame's state is pinned via `previewState:`, not produced by running the pipeline),
    /// so this is only ever present to satisfy ``AudioImportEnvironment``'s required
    /// `durationProbe` parameter.
    private struct PreviewDurationProbe: AudioDurationProbing {
        func probeDuration(of fileURL: URL) -> TimeInterval? { 1.0 }
    }

    /// `userPacksDirectory` is a placeholder, never-resolved path — mirrors
    /// `OnboardingViewModel(previewState:)`'s own placeholder `environment`; nothing in this
    /// gallery ever performs a real import, so nothing ever reads it.
    private let previewAudioImportEnvironment = AudioImportEnvironment(
        userPacksDirectory: URL(fileURLWithPath: "/dev/null/claudio-preview-packs"),
        durationProbe: PreviewDurationProbe(),
        // 与 `userPacksDirectory` 同一个理由：一条**永不解析**的占位路径。gallery 从不写 manifest，
        // 所以这把锁从不会被打开 —— 但它必须显式写出来（形参没有默认值），而写出来的绝不能是
        // 真实路径：一个 preview 不该有能力去碰用户 home 上的锁。
        packsLockFile: URL(fileURLWithPath: "/dev/null/claudio-preview-packs.lock")
    )

    // MARK: - Preview providers (classic `PreviewProvider` ONLY — `#Preview` does not
    // compile under CommandLineTools, see this file's header doc comment)

    struct OnboardingGalleryView_Previews: PreviewProvider {
        static var previews: some View {
            Group {
                OnboardingGalleryView().preferredColorScheme(.light)
                OnboardingGalleryView().preferredColorScheme(.dark)
            }
        }
    }

    struct EventRowGalleryView_Previews: PreviewProvider {
        static var previews: some View {
            Group {
                EventRowGalleryView().preferredColorScheme(.light)
                EventRowGalleryView().preferredColorScheme(.dark)
            }
        }
    }

    struct MasterVolumeGalleryView_Previews: PreviewProvider {
        static var previews: some View {
            Group {
                MasterVolumeGalleryView().preferredColorScheme(.light)
                MasterVolumeGalleryView().preferredColorScheme(.dark)
            }
        }
    }

    struct PackCardGalleryView_Previews: PreviewProvider {
        static var previews: some View {
            Group {
                PackCardGalleryView().preferredColorScheme(.light)
                PackCardGalleryView().preferredColorScheme(.dark)
            }
        }
    }

    struct HostIntegrationGalleryView_Previews: PreviewProvider {
        static var previews: some View {
            Group {
                HostIntegrationGalleryView().preferredColorScheme(.light)
                HostIntegrationGalleryView().preferredColorScheme(.dark)
            }
        }
    }

    /// The combined, one-screen gallery (T14 acceptance criterion 2: "browsable in one
    /// Xcode Canvas screen").
    struct StateGalleryView_Previews: PreviewProvider {
        static var previews: some View {
            Group {
                StateGalleryView().preferredColorScheme(.light)
                StateGalleryView().preferredColorScheme(.dark)
            }
        }
    }
#endif
