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
/// rather than `checkPackIntegrity`'s declared-file-missing list, so the badge count, the 4-slot
/// coverage track, and the accessibility "缺少：…" list are one source of truth (see
/// `packCompletionState`).
///
/// DESIGN.md「包行四态」(2026-07-17 竖排整宽行 mockup 拍板) now DOES define the
/// selected/broken/partial visual language (this doc comment used to say it didn't — that was
/// true before that section landed). ``PackGalleryView``（`ClaudioGUI`）renders it; where a pixel
/// choice still isn't pinned by DESIGN.md, that file's inline comments call it out same as before.
public enum PackCardState: Sendable, Equatable {
    /// All four v1 events resolve to ``CoverageState/present(fileName:)`` for this pack —
    /// i.e. ``PackCard/presentEvents`` == every ``Event/allCases``. A pack that legally leaves
    /// some events `unmapped` (silent-fallback, per DESIGN.md) reads as ``partial(present:total:)``
    /// with a "缺 N 个" meta badge, matching DESIGN.md「包行四态」— NOT `.complete`. (Note:
    /// `doctor`'s own ``PackIntegrityStatus/incomplete(packID:missingFiles:)`` still keys off
    /// *declared*-file presence for its diagnostic list; the pack CARD's completeness
    /// deliberately keys off the same present-event set its coverage track renders, so the
    /// badge, the track, and the accessibility label never disagree.)
    case complete
    /// Fewer than all four v1 events are ``CoverageState/present(fileName:)``. `present` is
    /// exactly ``PackCard/presentEvents``'s count (the number of lit slots in the row's 4-slot
    /// coverage track), `total` is always ``Event/allCases``'s count (`4` in v1) — the two are
    /// derived from ONE source, so `present` can never exceed `total` or go negative, and always
    /// agrees with the track and the "缺少：…" accessibility list.
    case partial(present: Int, total: Int)
    /// The pack directory doesn't resolve at all, or its `manifest.json` can't be
    /// read/decoded — mirrors ``PackIntegrityStatus/packNotFound(packID:)`` /
    /// ``PackIntegrityStatus/manifestUnreadable(packID:reason:)``.
    case broken(reason: String)
}

/// What a pack row's trailing "coverage track" position renders, derived purely from
/// ``PackCardState`` — PLAN-SOUND-MANAGER.md T4's a11y/layout model, resolving a 2026-07-17
/// Codex catch: DESIGN.md's "覆盖轨恒显（含 complete）" and "`broken` 不渲染轨" read as
/// contradictory taken together, until "恒显" is read precisely as "every MANIFEST-READABLE
/// row" rather than "literally every row with no exception". This type makes that precise
/// reading the one thing both ``PackGalleryView`` and ``PackGallerySuite`` derive from, so
/// neither can independently drift from the other.
public enum PackRowTrailingSlot: Sendable, Equatable {
    /// `complete`/`partial` — the manifest decoded, so ``PackCard/presentEvents`` is real
    /// per-event data the 4-slot track can render for real.
    case track
    /// `broken` — nothing was read (no directory, or an unreadable/undecodable manifest), so
    /// there is no per-event coverage to show; the row renders a status indicator here instead,
    /// reserving the SAME height the track would have used, so a row's height never jumps
    /// depending on whether it lands on `.track` or `.brokenStatus`.
    case brokenStatus
}

/// Resolves ``PackRowTrailingSlot`` for one card's ``PackCardState`` — see that type's doc
/// comment. Exhaustive `switch`, no `default:`, so a future ``PackCardState`` case fails this
/// to compile rather than silently falling into the wrong slot.
public func packRowTrailingSlot(for state: PackCardState) -> PackRowTrailingSlot {
    switch state {
    case .complete, .partial: return .track
    case .broken: return .brokenStatus
    }
}

/// A pack row's meta 槽 · license 子槽 (DESIGN.md「包行四态」) — one of two axes rendered
/// side by side in ``PackRowMetaSlots``, never combined into one string with the completeness
/// axis (see that type's doc comment for why the two must stay orthogonal).
public enum PackRowLicenseBadge: Sendable, Equatable {
    /// The manifest carries no CC0 claim (``PackCard/isCC0`` is `false`) — nothing renders here.
    case none
    /// ``PackCard/isCC0`` is `true` — renders the `"CC0"` badge.
    case cc0
    // T13 (factoryIntegrity, PLAN-SOUND-MANAGER.md §2.4) will add a `.modified` case here for a
    // pack whose bundled bytes were tampered with — driven by a bundle-byte comparison, not
    // `isCC0` — since it's a negation of the license claim, not completeness information, it
    // belongs on THIS axis. This enum is the reserved slot for that case; nothing else about
    // ``packRowMetaSlots(isCC0:state:)``'s shape should need to change when T13 lands.
}

/// One pack row's meta 槽, split into its two orthogonal sub-slots per DESIGN.md「包行四态」:
/// "`CC0` 与「缺 N 个」必须分居两个槽位（license 与完整度是两根**正交**的轴，一个格子塞不下两根
/// 轴）". Before this type existed, ``PackGalleryView``'s `metaSlot` switched on `card.state`
/// alone, so a CC0 pack that was also ``PackCardState/partial(present:total:)`` silently lost
/// its CC0 badge the moment it fell into that branch (T5, fixing a T4-inherited gap — see
/// ``PackRowTrailingSlot``'s own doc comment for the analogous T4 precedent this type mirrors).
/// `license` and `missingCount` are computed independently below, so a CC0 partial pack now
/// reports BOTH at once.
public struct PackRowMetaSlots: Sendable, Equatable {
    public let license: PackRowLicenseBadge
    /// `nil` when there's nothing to report — ``PackCardState/complete`` (zero missing) or
    /// ``PackCardState/broken`` (no coverage data was ever read). Never `0`: a `.complete` row
    /// has no "缺 0 个" badge, it has no completeness badge at all.
    public let missingCount: Int?

    public init(license: PackRowLicenseBadge, missingCount: Int?) {
        self.license = license
        self.missingCount = missingCount
    }
}

/// Resolves ``PackRowMetaSlots`` for one card's `isCC0` + ``PackCardState`` — see that type's
/// doc comment. Exhaustive `switch` on `state`, no `default:`, mirroring
/// ``packRowTrailingSlot(for:)`` exactly. `.broken` reports `(.none, nil)` regardless of
/// `isCC0`: DESIGN.md is explicit that a `.broken` row's ENTIRE meta slot renders nothing (its
/// one visible indicator lives in the trailing slot instead, see ``PackRowTrailingSlot``) — a
/// broken pack's manifest may never even have been read far enough to know its license.
public func packRowMetaSlots(isCC0: Bool, state: PackCardState) -> PackRowMetaSlots {
    let license: PackRowLicenseBadge = isCC0 ? .cc0 : .none
    switch state {
    case .complete:
        return PackRowMetaSlots(license: license, missingCount: nil)
    case .partial(let present, let total):
        return PackRowMetaSlots(license: license, missingCount: total - present)
    case .broken:
        return PackRowMetaSlots(license: .none, missingCount: nil)
    }
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
///
/// ⚠️ **`environment.factoryPacksDirectory` is deliberately NOT a third root here, and never
/// should be** (PLAN-SOUND-MANAGER.md §2.3, T6). It answers a different question ("where do
/// built-in packs get COPIED from") than this function does ("what's switchable right now") —
/// see that field's own doc comment for the full reasoning (mixing the two would make a pack
/// that only exists in the app bundle, not yet copied into the user root, appear switchable
/// here while `play` still can't see it — the exact false-negative `Setup.swift:503-505`
/// warns about). This function enumerates exactly two roots today, unchanged by T6:
/// `environment.userPacksDirectory` ∪ `environment.bundledPacksDirectory`.
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
///
/// Module-visible (not `private`) as of T6: ``AudioImportEnvironment/builtinPackIDs`` reuses
/// this exact function against `factoryPacksDirectory` — same "list dirs, drop dot-prefixed,
/// drop non-directories" logic, not a second, independently-maintained copy.
func packDirectoryIDs(in root: URL) -> [String] {
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

/// 每张卡片：**解析一次目录、读一次 manifest bytes、解码一次**，把这同一份 `packDirectory` /
/// `Data` / ``PackManifest`` 喂给三个消费者（每事件覆盖状态 / broken 判定 / `name`+`license`）。
///
/// 之前不是这样（/ship 评审修复④，性能）：`presentEventSet` → `packCoverage(packID:)` 读一遍
/// manifest、这里的 `loadPackManifest` 再读第二遍（注释自己承认解码值「不再需要」）、
/// `packMetadata` → `loadPackManifestData` 读第三遍，外加**两次** `resolvePackDirectory`——每次都
/// 跑 `resolvingSymlinksInPath()`（realpath 系统调用）。而 `PanelView.refresh()` 在**主线程**、
/// 每次开面板和每次静音点击时都会把整个画廊重建一遍，包数越多越贵。
///
/// 三条不变量没有被这次优化动过：
///   · coverage 逻辑仍是单一真相源——覆盖状态走 ``packCoverage(manifest:packDirectory:config:)``
///     （`packCoverage(packID:config:environment:)` 现在是它的薄包装），这里**没有**任何一行
///     自己的「文件在不在」判断；
///   · 读 manifest 仍然只走 ``loadPackManifestData(in:)``（`ClaudioCore` 那份 `O_NOFOLLOW` +
///     正规文件闸门 + 1 MiB 上限、被对抗测试过的读），不是裸 `Data(contentsOf:)`；
///   · `.broken` 的 reason 字符串仍与 ``loadPackManifest(in:)`` 逐字一致——不可读走
///     ``PackManifestLoadError/unreadable(reason:)``，解不开走
///     ``PackManifestLoadError/decodeFailed(reason:)``，两者的 `reason` 与原来完全相同
///     （`PackGallerySuite` 里对 reason 的断言原样保留）。
private func buildPackCard(
    id: String, config: ClaudioConfig, environment: AudioImportEnvironment
) -> PackCard {
    let isSelected = id == config.selectedPack

    // ① 目录只解析一次（原来两次，每次一轮 realpath）。
    guard
        let packDirectory = resolvePackDirectory(
            id: id, userPacksDirectory: environment.userPacksDirectory,
            bundledPacksDirectory: environment.bundledPacksDirectory)
    else {
        // 目录都没有 → 四个事件全 `.unmapped`，present 集合必为空（这正是原来
        // `packCoverage(packID:)` 在同一情形下返回的东西，只是不必再为此白跑一趟 IO）。
        return PackCard(
            id: id, name: nil, isCC0: false, presentEvents: [],
            state: .broken(reason: "声音包目录未找到"), isSelected: isSelected)
    }

    // ② manifest bytes 只读一次（原来三次）。
    let manifestData: Data
    switch loadPackManifestData(in: packDirectory) {
    case .failure(let error):
        return PackCard(
            id: id, name: nil, isCC0: false, presentEvents: [],
            state: .broken(reason: error.reason), isSelected: isSelected)
    case .success(let data):
        manifestData = data
    }

    // ③ 解码也只做一次。错误串刻意经 ``PackManifestLoadError/decodeFailed(reason:)`` 构造，
    //    与 ``loadPackManifest(in:)``（同样是 `JSONDecoder().decode` + `localizedDescription`）
    //    产出的 reason 完全一致——这里没有发明第二种报错话术。
    let manifest: PackManifest
    do {
        manifest = try JSONDecoder().decode(PackManifest.self, from: manifestData)
    } catch {
        return PackCard(
            id: id, name: nil, isCC0: false, presentEvents: [],
            state: .broken(
                reason: PackManifestLoadError.decodeFailed(reason: error.localizedDescription)
                    .reason),
            isSelected: isSelected)
    }

    let presentEvents = presentEventSet(
        manifest: manifest, packDirectory: packDirectory, config: config)
    let (name, isCC0) = packMetadata(manifestData: manifestData)
    let state = packCompletionState(presentEventCount: presentEvents.count)

    return PackCard(
        id: id, name: name, isCC0: isCC0, presentEvents: presentEvents, state: state,
        isSelected: isSelected)
}

/// Reuses ``packCoverage(manifest:packDirectory:config:)`` (T16 的 coverage 单一真相源) verbatim,
/// filtering to the events that resolved ``CoverageState/present(fileName:)`` — never a second,
/// independent per-event presence check. （只是换成了不再自己重读一遍 manifest 的那个下层入口；
/// 逐事件的判定逻辑一个字都没改。）
private func presentEventSet(
    manifest: PackManifest, packDirectory: URL, config: ClaudioConfig
) -> Set<Event> {
    Set(
        packCoverage(manifest: manifest, packDirectory: packDirectory, config: config)
            .compactMap { row -> Event? in
                if case .present = row.coverage { return row.event }
                return nil
            })
}

/// `name`/`license` aren't modeled by ``PackManifest`` (it only carries `id`/`events` — see
/// its doc comment), so this reads them off the raw JSON object rather than extending
/// ``PackManifest`` (which `checkPackIntegrity`/`bindEventToManifest` also decode, and which
/// must keep ignoring unknown keys for forward-compat, per `PackManifest`'s own doc comment).
/// This function only ever READS these fields; it never writes manifest.json, so there's no
/// unknown-key preservation concern here the way there is in `bindEventToManifest`'s
/// read-modify-write.
///
/// 入参是**已经读好的** bytes（``buildPackCard`` 唯一那次 ``loadPackManifestData(in:)`` 的产物），
/// 而不是再自己去读一遍第三次——那份读仍然是 `ClaudioCore` 那个 `isReallyContained` 闸门 +
/// 有界读，只是不再对同一个文件重复触发（/ship 评审修复④）。
private func packMetadata(manifestData: Data) -> (name: String?, isCC0: Bool) {
    guard let raw = try? JSONSerialization.jsonObject(with: manifestData) as? [String: Any] else {
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
