import ClaudioCore
import Foundation

/// One pack card's completeness — ENGINEERING.md T15 D3 (仓库内 pack 切换画廊), derived
/// from the SAME shape ``checkPackIntegrity(configFile:userPacksDirectory:bundledPacksDirectory:)``
/// already reports for the *selected* pack (`.complete`/`.incomplete`/`.manifestUnreadable`/
/// `.packNotFound`), just recomputed per-card instead of only for `config.selectedPack` —
/// `checkPackIntegrity` itself can't be called directly for an arbitrary pack id (it always
/// re-reads `config.json` off disk to learn which pack to check), so ``availablePacks(config:environment:)``
/// recomposes the exact same audited primitives (``resolvePackDirectory``, ``loadPackManifest``,
/// ``safePackFileURL``) it's built from, rather than reinventing pack-safety logic a second
/// time.
///
/// ⚠️ DESIGN.md 未定义 pack 卡状态视觉（selected/broken/partial 的呈现方式）——
/// `PackGalleryView`（`ClaudioGUI`）用既有 token 派生，见该文件的行内注释。
public enum PackCardState: Sendable, Equatable {
    /// Every event the manifest declares has its file present on disk (mirrors
    /// ``checkPackIntegrity``'s `.complete` — note this only means "every *declared*
    /// event's file exists", not "all four v1 events are mapped"; a manifest that legally
    /// leaves some events `unmapped` per DESIGN.md's silent-fallback rule still reports
    /// `.complete` here, exactly as `checkPackIntegrity` already does for the selected pack
    /// today — this type does not redefine that meaning).
    case complete
    /// At least one declared event's file is missing. `present`/`total` mirror
    /// ``PackIntegrityStatus/incomplete(packID:missingFiles:)``'s
    /// `4 - missingFiles.count` / `4` derivation exactly (`total` is always
    /// ``Event/allCases``'s count, `4` in v1).
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

    let manifest: PackManifest
    switch loadPackManifest(in: packDirectory) {
    case .failure(let error):
        return PackCard(
            id: id, name: nil, isCC0: false, presentEvents: presentEvents,
            state: .broken(reason: error.reason), isSelected: isSelected)
    case .success(let loaded):
        manifest = loaded
    }

    let (name, isCC0) = packMetadata(packDirectory: packDirectory)
    let state = packCompletionState(packDirectory: packDirectory, manifest: manifest)

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

/// Mirrors ``checkPackIntegrity(configFile:userPacksDirectory:bundledPacksDirectory:)``'s
/// `.complete`/`.incomplete` derivation exactly (same ``safePackFileURL``-gated containment
/// check, same `fileExists` probe), parameterized by an already-resolved `packDirectory` +
/// `manifest` instead of re-reading `config.json` — see this file's header comment for why
/// `checkPackIntegrity` itself can't be called directly here.
private func packCompletionState(packDirectory: URL, manifest: PackManifest) -> PackCardState {
    let missingCount = manifest.events.values.filter { fileName in
        guard let resolved = safePackFileURL(fileName, in: packDirectory) else { return true }
        return !FileManager.default.fileExists(atPath: resolved.path)
    }.count

    guard missingCount > 0 else { return .complete }
    // Matches `checkPackIntegrity`'s own inherited quirk, not a new one introduced here:
    // `missingCount` only counts *declared* events, so a manifest that legally leaves some
    // events unmapped (silent fallback, not a defect) can still report fewer missing files
    // than `4 - presentEvents.count` would suggest. `present` here is `4 - missingCount`,
    // exactly the formula ENGINEERING.md T15 D3 specifies — not a recount of `presentEvents`.
    return .partial(present: Event.allCases.count - missingCount, total: Event.allCases.count)
}
