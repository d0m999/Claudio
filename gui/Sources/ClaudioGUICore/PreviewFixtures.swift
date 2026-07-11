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

    /// Every ``CoverageState`` case × `enabled` (true/false) — six rows — AND every ``Event``,
    /// on both axes at once: the four events are ROTATED across the six coverage×enabled
    /// combinations (in ``Event/allCases`` declaration order), so the combination grid stays
    /// exhaustive while no event is left un-rendered.
    ///
    /// The event axis is load-bearing, not decoration (T14 review 修复①): this catalog is the
    /// repo's ONLY exhaustive visual truth source, and an event that never appears in it has
    /// its display name, its glyph, and its ``ClaudioColor/event(_:_:)`` tile color rendered
    /// exactly zero times — nobody has ever LOOKED at it. That is precisely how `night_dim`
    /// drifted before. `SubagentStop`'s indigo was missing here until this fix.
    ///
    /// Each row's event is visible in FULL color regardless of `enabled`/coverage
    /// (`EventRowView`'s `glyphTile` never dims — DESIGN.md 硬约束 "不整行降 opacity"), so one
    /// appearance per event is genuinely enough to see its true color; the rotation doesn't
    /// need to also pair every event with every coverage state.
    ///
    /// ``PreviewFixturesSuite`` pins BOTH axes at runtime: the six coverage×enabled
    /// combinations, and `Set(eventRows.map(\.event)) == Set(Event.allCases)` — the latter
    /// driven straight off ``Event``'s compiler-synthesized `allCases`, so adding a fifth
    /// event turns that check red without anyone having to remember to update a hand-written
    /// list.
    public static let eventRows: [EventRow] = [
        EventRow(event: .stop, coverage: .present(fileName: "stop.mp3"), enabled: true),
        EventRow(
            event: .stopFailure, coverage: .present(fileName: "stop-failure.mp3"), enabled: false),
        EventRow(event: .notification, coverage: .unmapped, enabled: true),
        EventRow(event: .subagentStop, coverage: .unmapped, enabled: false),
        EventRow(
            event: .subagentStop, coverage: .broken(fileName: "subagent-stop.mp3"), enabled: true),
        EventRow(event: .notification, coverage: .broken(fileName: "ping.mp3"), enabled: false),
    ]

    // MARK: - PackCard / PackCardState (ENGINEERING.md T15 D3)

    /// Every ``PackCardState`` case × `isSelected` (true/false) — six cards.
    ///
    /// The `presentEvents` sets carry a SECOND exhaustiveness obligation, for the same reason
    /// ``eventRows`` does (T14 review 修复①): `PackGalleryView`'s 2×2 glyph grid renders
    /// ``Event/allCases`` on EVERY card, styling each glyph present-or-absent. So a card fixture
    /// set must show each of the four events in BOTH styles somewhere, or one of the eight
    /// (event × present/absent) glyph renderings never gets looked at. The `.complete` cards
    /// (`presentEvents == Set(Event.allCases)`) supply all four PRESENT glyphs; the two
    /// `.broken` cards (`presentEvents == []`) supply all four ABSENT ones. ``PreviewFixturesSuite``
    /// pins both halves off ``Event/allCases`` directly.
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

    /// Runs every `_coverage(_:)` guard below against its matching fixture array and RETURNS
    /// the set of `family.case` labels those guards actually visited — e.g.
    /// `"onboarding.installed"`, `"dropZone.reject.oversize"`, `"coverage.broken"`,
    /// `"packCard.partial"`. Labels are family-qualified because the bare ones collide
    /// (`broken` belongs to both ``CoverageState`` and ``PackCardState``).
    ///
    /// It RETURNS a value rather than merely running (T14 review 修复②): the previous
    /// `-> Void` version could only ever be "tested" by calling it and asserting `true`, a
    /// tautology that could never fail while still occupying a line in the check count. The
    /// returned set is a real, falsifiable observation of WHICH cases the shipped fixtures
    /// exercise, so ``PreviewFixturesSuite`` can compare it against the full expected roster and
    /// go RED the moment a fixture array stops covering one of its enum's cases — the compiler's
    /// own exhaustive-`switch` guarantee (a branch EXISTS for every case) never covered that: a
    /// branch nothing ever reaches compiles perfectly.
    ///
    /// Still also serves its original purpose: it keeps the four `switch`es below demonstrably
    /// live code, so a future cleanup can't delete the enforcement mechanism as unreferenced.
    public static func assertExhaustive() -> Set<String> {
        var visited: Set<String> = []
        for state in onboardingStates { visited.insert("onboarding.\(onboardingStateCoverage(state))") }
        for state in dropZoneStates { visited.insert("dropZone.\(dropZoneStateCoverage(state))") }
        for row in eventRows { visited.insert("coverage.\(coverageStateCoverage(row.coverage))") }
        for card in packCards { visited.insert("packCard.\(packCardStateCoverage(card.state))") }
        return visited
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
