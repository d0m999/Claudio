import ClaudioCore
import Foundation

/// One pack card's completeness — ENGINEERING.md T15 D3 (仓库内 pack 切换画廊). Its
/// `broken`/`complete`/`partial` shape parallels ``checkPackIntegrity(configFile:userPacksDirectory:bundledPacksDirectory:)``'s
/// own `.packNotFound`/`.manifestUnreadable`/`.complete`/`.incomplete`, recomputed per-card
/// instead of only for `config.selectedPack` (``checkPackIntegrity`` can't be called directly
/// for an arbitrary pack id — it always re-reads `config.json` to learn which pack to check),
/// reusing the exact same audited primitives (``resolvePackDirectory``, ``loadPackManifest``,
/// ``safePackFileURL``), never reinventing pack-safety logic. The `partial` count itself,
/// though, is derived from the card's present-event set (see ``packCard``'s ``PackCard/presentEvents``)
/// rather than `checkPackIntegrity`'s declared-file-missing list, so the badge count, the 2×2
/// glyph grid, and the accessibility "缺少：…" list are one source of truth (see
/// `packCompletionState`).
///
/// ⚠️ DESIGN.md 未定义 pack 卡状态视觉（selected/broken/partial 的呈现方式）——
/// `PackGalleryView`（`ClaudioGUI`）用既有 token 派生，见该文件的行内注释。
public enum PackCardState: Sendable, Equatable {
    /// All four v1 events resolve to ``CoverageState/present(fileName:)`` for this pack —
    /// i.e. ``PackCard/presentEvents`` == every ``Event/allCases``. A pack that legally leaves
    /// some events `unmapped` (silent-fallback, per DESIGN.md) reads as ``partial(present:total:)``
    /// with a "N/4" badge, matching DESIGN.md line 218 ("包缺某事件音 → 卡 2×2 网格显「2/4」") —
    /// NOT `.complete`. (Note: `doctor`'s own ``PackIntegrityStatus/incomplete(packID:missingFiles:)``
    /// still keys off *declared*-file presence for its diagnostic list; the pack CARD's
    /// completeness deliberately keys off the same present-event set its glyph grid renders, so
    /// the badge, the grid, and the accessibility label never disagree.)
    case complete
    /// Fewer than all four v1 events are ``CoverageState/present(fileName:)``. `present` is
    /// exactly ``PackCard/presentEvents``'s count (the number of lit glyphs in the card's 2×2
    /// grid), `total` is always ``Event/allCases``'s count (`4` in v1) — the two are derived
    /// from ONE source, so `present` can never exceed `total` or go negative, and always agrees
    /// with the grid and the "缺少：…" accessibility list.
    case partial(present: Int, total: Int)
    /// The pack directory doesn't resolve at all, or its `manifest.json` can't be
    /// read/decoded — mirrors ``PackIntegrityStatus/packNotFound(packID:)`` /
    /// ``PackIntegrityStatus/manifestUnreadable(packID:reason:)``.
    case broken(reason: String)
}

/// One pack switching card — the read-only render model
/// ``PackGalleryView`` (``ClaudioGUI``, T15) lays pixels out from, and the write path
/// (pack switching) reuses ``selectPack(_:configFile:userPacksDirectory:bundledPacksDirectory:lockFile:)``
/// verbatim — this type carries no write logic of its own.
public struct PackCard: Sendable, Equatable {
    public let id: String
    /// The manifest's `name` field (raw JSON key — ``PackManifest`` doesn't model it, see
    /// ``loadPackManifestData(in:)``'s doc comment on why the write path reads raw JSON
    /// instead of the narrower typed model). `nil` when the pack is ``PackCardState/broken(reason:)``
    /// or the manifest simply omits `name`.
    public let name: String?
    /// Whether the manifest's `license` field is exactly the SPDX identifier `"CC0-1.0"`
    /// (ENGINEERING.md「声音包格式」: built-in packs must be `CC0-1.0`; user packs aren't
    /// validated). `false` — not "unknown" — when `license` is absent or any other value;
    /// this only ever drives a positive "CC0" badge, never a negative claim about
    /// non-CC0-licensed packs.
    public let isCC0: Bool
    /// Which of ``Event/allCases`` currently resolve to ``CoverageState/present(fileName:)``
    /// for this pack — reused verbatim from ``packCoverage(packID:config:environment:)``
    /// (T16), never recomputed independently.
    public let presentEvents: Set<Event>
    public let state: PackCardState
    /// `true` iff `id == config.selectedPack` — kept as a separate field (not folded into
    /// ``PackCardState``) since selection and completeness are orthogonal axes, exactly
    /// like ``EventRow/enabled`` stays orthogonal to ``CoverageState`` (决议③'s pattern,
    /// reapplied here).
    public let isSelected: Bool

    public init(
        id: String,
        name: String?,
        isCC0: Bool,
        presentEvents: Set<Event>,
        state: PackCardState,
        isSelected: Bool
    ) {
        self.id = id
        self.name = name
        self.isCC0 = isCC0
        self.presentEvents = presentEvents
        self.state = state
        self.isSelected = isSelected
    }
}

/// Enumerates every pack available for switching to — the user pack root **∪** the bundled
/// pack root, deduplicated by id. A pack id present in both roots is backed by the user
/// copy's data (``resolvePackDirectory`` itself already checks the user root first, "so a
/// user pack can override a same-id bundled pack" — this function never second-guesses
/// that ordering, it just calls the same resolver every other pack lookup in this codebase
/// does).
///
/// Cards are returned sorted by `id` — a stable, deterministic order a gallery view (and a
/// test asserting its shape) can rely on; DESIGN.md doesn't specify a gallery ordering rule,
/// and alphabetical-by-id is the least surprising default that doesn't require reading
/// every manifest first just to decide a display order.
public func availablePacks(
    config: ClaudioConfig,
    environment: AudioImportEnvironment
) -> [PackCard] {
    var seenIDs: Set<String> = []
    var orderedIDs: [String] = []
    for id in packDirectoryIDs(in: environment.userPacksDirectory) where seenIDs.insert(id).inserted {
        orderedIDs.append(id)
    }
    if let bundledPacksDirectory = environment.bundledPacksDirectory {
        for id in packDirectoryIDs(in: bundledPacksDirectory) where seenIDs.insert(id).inserted {
            orderedIDs.append(id)
        }
    }
    return orderedIDs.sorted().map { buildPackCard(id: $0, config: config, environment: environment) }
}

/// Lists candidate pack ids directly under `root`: real subdirectories only (a stray
/// regular file at a pack-id-shaped path is never a pack — mirrors `ClaudioCore`'s own
/// `directoryExists` check, module-internal there so re-implemented here against the same
/// public `FileManager` API, not against a private symbol this module can't see), excluding
/// dot-prefixed entries (mirrors `Setup.swift`'s own filter: a killed import/setup can leave
/// a `.<id>.tmp-<pid>` scratch directory behind, which must never appear as a switchable
/// pack).
private func packDirectoryIDs(in root: URL) -> [String] {
    let entries = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
    return entries.filter { id in
        guard !id.hasPrefix(".") else { return false }
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(
            atPath: root.appendingPathComponent(id, isDirectory: true).path,
            isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }
}

private func buildPackCard(
    id: String, config: ClaudioConfig, environment: AudioImportEnvironment
) -> PackCard {
    let isSelected = id == config.selectedPack
    let presentEvents = presentEventSet(packID: id, config: config, environment: environment)

    guard
        let packDirectory = resolvePackDirectory(
            id: id, userPacksDirectory: environment.userPacksDirectory,
            bundledPacksDirectory: environment.bundledPacksDirectory)
    else {
        return PackCard(
            id: id, name: nil, isCC0: false, presentEvents: presentEvents,
            state: .broken(reason: "声音包目录未找到"), isSelected: isSelected)
    }

    // Still load the manifest here purely to distinguish `.broken` (undecodable manifest)
    // from a readable one — the decoded value itself is no longer needed for completeness,
    // which now derives from `presentEvents` (below), the SAME set the card's glyph grid and
    // accessibility label read from.
    switch loadPackManifest(in: packDirectory) {
    case .failure(let error):
        return PackCard(
            id: id, name: nil, isCC0: false, presentEvents: presentEvents,
            state: .broken(reason: error.reason), isSelected: isSelected)
    case .success:
        break
    }

    let (name, isCC0) = packMetadata(packDirectory: packDirectory)
    let state = packCompletionState(presentEventCount: presentEvents.count)

    return PackCard(
        id: id, name: name, isCC0: isCC0, presentEvents: presentEvents, state: state,
        isSelected: isSelected)
}

/// Reuses ``packCoverage(packID:config:environment:)`` (T16) verbatim, filtering to the
/// events that resolved ``CoverageState/present(fileName:)`` — never a second, independent
/// per-event presence check.
private func presentEventSet(
    packID: String, config: ClaudioConfig, environment: AudioImportEnvironment
) -> Set<Event> {
    Set(
        packCoverage(packID: packID, config: config, environment: environment)
            .compactMap { row -> Event? in
                if case .present = row.coverage { return row.event }
                return nil
            })
}

/// `name`/`license` aren't modeled by ``PackManifest`` (it only carries `id`/`events` — see
/// its doc comment), so this reads the raw JSON object directly via
/// ``loadPackManifestData(in:)`` — the same `isReallyContained`-gated read every other
/// manifest reader in this module uses — rather than extending ``PackManifest`` (which
/// `checkPackIntegrity`/`bindEventToManifest` also decode, and which must keep ignoring
/// unknown keys for forward-compat, per `PackManifest`'s own doc comment). This function
/// only ever READS these fields; it never writes manifest.json, so there's no unknown-key
/// preservation concern here the way there is in `bindEventToManifest`'s read-modify-write.
private func packMetadata(packDirectory: URL) -> (name: String?, isCC0: Bool) {
    guard case .success(let data) = loadPackManifestData(in: packDirectory),
        let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
        return (nil, false)
    }
    let name = raw["name"] as? String
    let license = raw["license"] as? String
    return (name, license == "CC0-1.0")
}

/// Derives the card's completeness from `presentEventCount` — the number of ``Event/allCases``
/// that resolve to ``CoverageState/present(fileName:)`` for this pack (``presentEventSet``, the
/// SAME set the card's 2×2 glyph grid and its "缺少：…" VoiceOver list read from).
///
/// This deliberately counts over **all four v1 events**, NOT over `manifest.events.values`
/// (the declared keys). An earlier version used `4 - (declared files missing)`, which made
/// `present` disagree with `presentEvents` whenever a pack mixed an unmapped event with a
/// declared-but-missing file (grid lit 1, badge said "3/4", VoiceOver listed 3 missing) — and,
/// because `manifest.events` is an unconstrained `[String: String]`, a forward-compat manifest
/// with several extra event keys pointing at missing files could even drive it negative
/// ("-1/4"). Counting present events instead keeps the badge, the grid, and the label a single
/// source of truth, always in `0...Event.allCases.count`, and matches DESIGN.md line 218
/// ("包缺某事件音 → 卡 2×2 网格显「2/4」"): a pack that only maps some events reads as partial,
/// with the badge count equal to the number of lit glyphs.
private func packCompletionState(presentEventCount: Int) -> PackCardState {
    let total = Event.allCases.count
    guard presentEventCount < total else { return .complete }
    return .partial(present: presentEventCount, total: total)
}
