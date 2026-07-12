#if DEBUG
    import ClaudioCore
    import ClaudioGUICore
    import SwiftUI

    /// The repo-internal SwiftUI state gallery (ENGINEERING.md T14 D2) — the in-repo VISUAL
    /// TRUTH SOURCE. Renders ONE frame per ``PreviewFixtures`` value, across all four
    /// per-feature state families this app has (``OnboardingState``, ``DropZoneState``,
    /// ``EventRow``/``CoverageState``, ``PackCard``/``PackCardState``), EXCLUSIVELY off
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
                    OnboardingGalleryView()
                    OnboardingActionGalleryView()
                    DropZoneGalleryView()
                    EventRowGalleryView()
                    PackCardGalleryView()
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
            GallerySection(title: "OnboardingState (\(PreviewFixtures.onboardingStates.count))") {
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
                title: "OnboardingActionState (\(PreviewFixtures.onboardingActionStates.count))"
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

    // MARK: - DropZoneState (9 fixtures: idle / hover / reject×6 / success)

    struct DropZoneGalleryView: View {
        var body: some View {
            GallerySection(title: "DropZoneState (\(PreviewFixtures.dropZoneStates.count))") {
                ForEach(Array(PreviewFixtures.dropZoneStates.enumerated()), id: \.offset) { _, state in
                    GalleryFrame(caption: dropZoneStateCaption(state)) {
                        DropZoneStateFrame(state: state)
                    }
                }
            }
        }
    }

    private struct DropZoneStateFrame: View {
        let state: DropZoneState
        var body: some View {
            AudioDropZoneView(
                viewModel: AudioImportViewModel(
                    packID: "minimal-chime", environment: previewAudioImportEnvironment,
                    previewState: state)
            )
            .frame(width: CGFloat(standardPanelWidth))
        }
    }

    private func dropZoneStateCaption(_ state: DropZoneState) -> String {
        switch state {
        case .idle: ".idle"
        case .hover: ".hover"
        case .reject(let reason): ".reject(\(dropRejectionReasonCaption(reason)))"
        case .success(let file): ".success(\(file.fileName))"
        }
    }

    /// Exhaustive over every ``DropRejectionReason`` case, no `default:`.
    private func dropRejectionReasonCaption(_ reason: DropRejectionReason) -> String {
        switch reason {
        case .oversize: ".oversize"
        case .nonWhitelistFormat: ".nonWhitelistFormat"
        case .pathTraversal: ".pathTraversal"
        case .overDuration: ".overDuration"
        case .overwritesBuiltin: ".overwritesBuiltin"
        case .copyFailed: ".copyFailed"
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
            // `importViewModel` only backs the row-end drag/pick-to-bind AFFORDANCE — never
            // read by `EventRowView`'s rendering itself (see its own doc comment) — so a
            // throwaway instance, pinned to no particular state, is exactly what its own
            // doc comment anticipates ("construct a throwaway EventRowImportViewModel...
            // for its affordance").
            EventRowView(
                row: row,
                importViewModel: EventRowImportViewModel(
                    event: row.event,
                    importViewModel: AudioImportViewModel(
                        packID: "minimal-chime", environment: previewAudioImportEnvironment)),
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
                // ``AudioDropZoneView``, ``PackGalleryView``, ``OnboardingView`` — paints NO
                // surface of its own; in production ``PanelView`` (the composition root) supplies
                // it. Without this background, the gallery rendered all four event colors, every
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
        durationProbe: PreviewDurationProbe()
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

    struct DropZoneGalleryView_Previews: PreviewProvider {
        static var previews: some View {
            Group {
                DropZoneGalleryView().preferredColorScheme(.light)
                DropZoneGalleryView().preferredColorScheme(.dark)
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

    struct PackCardGalleryView_Previews: PreviewProvider {
        static var previews: some View {
            Group {
                PackCardGalleryView().preferredColorScheme(.light)
                PackCardGalleryView().preferredColorScheme(.dark)
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
