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
        var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    OnboardingGalleryView()
                    DropZoneGalleryView()
                    EventRowGalleryView()
                    PackCardGalleryView()
                }
                .padding(20)
            }
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
        @FocusState private var focusedTarget: PanelFocusTarget?

        var body: some View {
            OnboardingView(viewModel: OnboardingViewModel(previewState: state), focusedTarget: $focusedTarget)
                .frame(width: CGFloat(standardPanelWidth))
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

        init(title: String, @ViewBuilder content: () -> Content) {
            self.title = title
            self.content = content()
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                content
            }
        }
    }

    private struct GalleryFrame<Content: View>: View {
        let caption: String
        let content: Content

        init(caption: String, @ViewBuilder content: () -> Content) {
            self.caption = caption
            self.content = content()
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 4) {
                Text(caption)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
                content
            }
            .padding(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.gray.opacity(0.2))
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
