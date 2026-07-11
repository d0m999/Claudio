import ClaudioCore
import Foundation

// This entire catalog is DEBUG-only: its only consumers are the DEBUG-gated state gallery
// (`ClaudioGUI/StateGalleryView.swift`) and the (always-debug) test harness, so it never
// belongs in a Release build — matching the `#if DEBUG` gating on the `previewState`
// view-model inits it renders through. Keeps this preview/test-only sample data off the
// shipped `ClaudioGUICore` public surface entirely rather than relying on the linker to
// dead-strip it (T14 swift-review nit).
#if DEBUG

/// The **single canonical catalog** of concrete sample values for every case of all four
/// per-feature state families (ENGINEERING.md T14 D1): ``OnboardingState``,
/// ``DropZoneState``, ``EventRow``/``CoverageState``, ``PackCard``/``PackCardState``.
///
/// This is the ONE place in the repo that constructs sample state VALUES — both the state
/// gallery (`ClaudioGUI`'s `StateGalleryView`, T14 D2) and, where a test already hard-coded
/// its own sample values, the dependency-free test harness now point HERE instead (T14
/// acceptance criterion 3: "changing an enum reflects in BOTH tests and gallery"). It must
/// live in `ClaudioGUICore` (not a separate module, and not `ClaudioGUI`) for one structural
/// reason: ``ImportedAudioFile``'s memberwise initializer is synthesized `internal` (Swift
/// never synthesizes a `public` memberwise init for a `public` struct, even when every
/// stored property is itself `public` — a well-known gotcha, not an oversight) — only code
/// inside THIS module can construct ``DropZoneState/success(_:)`` at all.
///
/// Pure value construction only — **no disk I/O, no environment/view-model wiring**. Every
/// fixture below is a plain, deterministic literal; nothing here reads `~/.claude` or
/// `~/.claudio`, mirroring every other fixture helper in this codebase
/// (`OnboardingEnvironment`'s own warning about `$HOME` not working on Darwin — this type
/// sidesteps that class of bug entirely by never touching a real path).
///
/// ## Exhaustiveness (T14 acceptance criterion 3, the load-bearing part)
/// None of the four state enums below are `CaseIterable` (each has at least one
/// associated-value case), so there is no compiler-checked "did I fixture every case?" for
/// free. The four `_coverage(_:)` functions at the bottom of this file are hand-written
/// exhaustive `switch`es over EVERY case of ``OnboardingState``, ``DropRejectionReason``
/// (nested one level inside ``DropZoneState``), ``CoverageState``, and ``PackCardState`` —
/// with no `default:` branch anywhere. The instant a new case is added to any of those four
/// enums, EVERY `switch` in THIS repo that already omits `default:` (which includes these
/// four, plus each type's own `OnboardingState.swift`/`DropZoneState.swift`/
/// `CoverageState.swift`/`PackGallery.swift` internals) stops compiling until a matching
/// branch — and, by the convention this file establishes, a fixture — is added. `Package
/// GallerySuite.swift` (T14 D3) additionally pins the RUNTIME shape (how many fixtures,
/// which combinations) so a compiling-but-incomplete fixture array still fails a test.
public enum PreviewFixtures {

    // MARK: - OnboardingState (6 cases, ENGINEERING.md T7)

    /// All six ``OnboardingState`` cases, in the same declaration order as the enum itself.
    /// The two associated-value cases carry representative reason strings shaped like the
    /// real ones ``detectOnboardingState(environment:)`` produces (see
    /// `OnboardingDetectorSuite.swift`), not placeholder text.
    public static let onboardingStates: [OnboardingState] = [
        .claudeCodeNotInstalled,
        .helperMissing,
        .settingsNotWritable(reason: "settings.json 存在但不可写：/Users/demo/.claude/settings.json"),
        .settingsParseFailure(reason: "settings.json 解析失败，已中止（未修改文件）：期望对象，得到数组"),
        .notInstalled,
        .installed,
    ]

    // MARK: - DropZoneState (ENGINEERING.md T8): idle / hover / reject×6 / success

    /// A representative ``ImportedAudioFile`` — the payload ``DropZoneState/success(_:)``
    /// carries. `destinationURL` is a plausible (never-touched) path shape; nothing reads
    /// it.
    public static let sampleImportedAudioFile = ImportedAudioFile(
        packID: "minimal-chime",
        destinationURL: URL(fileURLWithPath: "/Users/demo/.claudio/packs/minimal-chime/stop.mp3"),
        fileName: "stop.mp3",
        format: .mp3,
        fileSizeBytes: 214_016,
        duration: 1.2
    )

    /// `.idle`, `.hover`, `.success`, and one `.reject` for EACH of ``DropRejectionReason``'s
    /// six cases (nine fixtures total) — every ``DropZoneState`` case, and every reason a
    /// `.reject` can carry, appears at least once.
    public static let dropZoneStates: [DropZoneState] = [
        .idle,
        .hover,
        .reject(.oversize(actualBytes: 8_400_000, maxBytes: 5 * 1024 * 1024)),
        .reject(.nonWhitelistFormat),
        .reject(.pathTraversal),
        .reject(.overDuration(actualSeconds: 6.4, maxSeconds: 3.0)),
        .reject(.overwritesBuiltin(packID: "minimal-chime")),
        .reject(.copyFailed(reason: "磁盘已满")),
        .success(sampleImportedAudioFile),
    ]

    // MARK: - EventRow / CoverageState (ENGINEERING.md T16 D2, DESIGN.md "事件行三态")

    /// Every ``CoverageState`` case × `enabled` (true/false) — six rows, one representative
    /// ``Event`` per coverage case (kept distinct across the pair so a reader can tell them
    /// apart in the gallery at a glance; the ×enabled combination is what's under test, not
    /// event identity).
    public static let eventRows: [EventRow] = [
        EventRow(event: .stop, coverage: .present(fileName: "stop.mp3"), enabled: true),
        EventRow(event: .stop, coverage: .present(fileName: "stop.mp3"), enabled: false),
        EventRow(event: .stopFailure, coverage: .unmapped, enabled: true),
        EventRow(event: .stopFailure, coverage: .unmapped, enabled: false),
        EventRow(event: .notification, coverage: .broken(fileName: "ping.mp3"), enabled: true),
        EventRow(event: .notification, coverage: .broken(fileName: "ping.mp3"), enabled: false),
    ]

    // MARK: - PackCard / PackCardState (ENGINEERING.md T15 D3)

    /// Every ``PackCardState`` case × `isSelected` (true/false) — six cards.
    public static let packCards: [PackCard] = [
        PackCard(
            id: "minimal-chime", name: "极简铃", isCC0: true, presentEvents: Set(Event.allCases),
            state: .complete, isSelected: true),
        PackCard(
            id: "sunny-chime", name: "晴朗铃", isCC0: true, presentEvents: Set(Event.allCases),
            state: .complete, isSelected: false),
        PackCard(
            id: "half-pack", name: "半成品", isCC0: false, presentEvents: [.stop, .notification],
            state: .partial(present: 2, total: 4), isSelected: true),
        PackCard(
            id: "quarter-pack", name: "缺三个", isCC0: false, presentEvents: [.stop],
            state: .partial(present: 1, total: 4), isSelected: false),
        PackCard(
            id: "ghost-pack", name: nil, isCC0: false, presentEvents: [],
            state: .broken(reason: "声音包目录未找到"), isSelected: true),
        PackCard(
            id: "corrupt-pack", name: nil, isCC0: false, presentEvents: [],
            state: .broken(reason: "manifest.json 解析失败"), isSelected: false),
    ]

    // MARK: - Compile-time exhaustiveness guards

    /// Calls every `_coverage(_:)` guard below against its matching fixture array — exists
    /// so the guards are demonstrably live code (not an unreferenced private function a
    /// future cleanup could silently delete, which would quietly remove the whole
    /// enforcement mechanism), and so ``PreviewFixturesSuite`` (T14 D3) has one call site to
    /// exercise for its own "this compiles" sanity check.
    public static func assertExhaustive() {
        for state in onboardingStates { _ = onboardingStateCoverage(state) }
        for state in dropZoneStates { _ = dropZoneStateCoverage(state) }
        for row in eventRows { _ = coverageStateCoverage(row.coverage) }
        for card in packCards { _ = packCardStateCoverage(card.state) }
    }

    /// Exhaustive over every ``OnboardingState`` case — no `default:`. Adding a 7th case
    /// breaks this `switch` (and, independently, every other non-`default` `switch` over
    /// `OnboardingState` in `OnboardingState.swift`/`OnboardingCopy.swift`) until it's
    /// handled here too.
    static func onboardingStateCoverage(_ state: OnboardingState) -> String {
        switch state {
        case .claudeCodeNotInstalled: "claudeCodeNotInstalled"
        case .helperMissing: "helperMissing"
        case .settingsNotWritable: "settingsNotWritable"
        case .settingsParseFailure: "settingsParseFailure"
        case .notInstalled: "notInstalled"
        case .installed: "installed"
        }
    }

    /// Exhaustive over every ``DropZoneState`` case, recursing into ``DropRejectionReason``
    /// for `.reject` so both the outer 4-case enum and the inner 6-case one are guarded by
    /// one function.
    static func dropZoneStateCoverage(_ state: DropZoneState) -> String {
        switch state {
        case .idle: "idle"
        case .hover: "hover"
        case .reject(let reason): "reject.\(dropRejectionReasonCoverage(reason))"
        case .success: "success"
        }
    }

    /// Exhaustive over every ``DropRejectionReason`` case — no `default:`.
    static func dropRejectionReasonCoverage(_ reason: DropRejectionReason) -> String {
        switch reason {
        case .oversize: "oversize"
        case .nonWhitelistFormat: "nonWhitelistFormat"
        case .pathTraversal: "pathTraversal"
        case .overDuration: "overDuration"
        case .overwritesBuiltin: "overwritesBuiltin"
        case .copyFailed: "copyFailed"
        }
    }

    /// Exhaustive over every ``CoverageState`` case — no `default:`.
    static func coverageStateCoverage(_ state: CoverageState) -> String {
        switch state {
        case .present: "present"
        case .unmapped: "unmapped"
        case .broken: "broken"
        }
    }

    /// Exhaustive over every ``PackCardState`` case — no `default:`.
    static func packCardStateCoverage(_ state: PackCardState) -> String {
        switch state {
        case .complete: "complete"
        case .partial: "partial"
        case .broken: "broken"
        }
    }
}

#endif
