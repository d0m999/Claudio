import ClaudioCore
import Foundation

/// Why ``bindEventToManifest(event:fileName:packID:environment:)`` refused to bind.
public enum ManifestBindError: Error, Sendable, Equatable {
    /// `packID` doesn't currently resolve to a real, on-disk **user** pack directory.
    /// Binding never creates a pack — it only ever edits a `manifest.json` that already
    /// exists (in practice, always right after
    /// ``importAudioFile(sourceURL:suggestedFileName:packID:environment:)`` created the
    /// user pack directory for the very first time).
    case packNotFound(packID: String)
    /// `fileName` failed ``safePackFileURL(_:in:)``'s containment check (empty / absolute /
    /// `..`-escaping / NUL-bearing / a symlink resolving outside the pack directory).
    case unsafeFileName
    /// `fileName` passed the containment check but doesn't actually exist inside the pack
    /// directory — binding an event to a file that isn't really there would make the row
    /// recompute to ``CoverageState/broken(fileName:)`` immediately after a "successful"
    /// bind, which must never happen.
    case fileNotFound(fileName: String)
    /// `manifest.json` couldn't be read at all (see ``PackManifestLoadError``), its
    /// content isn't a top-level JSON *object*, its `events` field is present but isn't
    /// itself a JSON object (e.g. an array or string), its `events` object holds a
    /// non-string value (e.g. `{"stop": 1}`), or it has no valid top-level `id` (missing /
    /// not a string / empty) — every shape this read-modify-write requires to safely operate
    /// without silently coercing a malformed manifest into a fabricated one, PLUS every shape
    /// ``PackManifest`` itself must be able to decode afterwards (T16 review 修复④: a bind
    /// that "succeeds" into a manifest nothing can decode would leave the row rendering
    /// 「未配置」 with no error shown anywhere).
    case manifestUnreadable(reason: String)
    /// The updated JSON couldn't be serialized or written back to disk.
    case writeFailed(reason: String)
}

/// Binds `fileName` (already copied into the user pack, e.g. by
/// ``importAudioFile(sourceURL:suggestedFileName:packID:environment:)``) to `event` inside
/// `packID`'s `manifest.json` (ENGINEERING.md T16 D3: "逐事件导入绑定").
///
/// This is a **surgical read-modify-write of the raw JSON object** — read the file's bytes
/// → `JSONSerialization` to `[String: Any]` → set `json["events"][event.manifestKey] =
/// fileName` (creating the `events` object first if it's absent) → write the whole object
/// back atomically. Deliberately **never** round-trips through ``PackManifest``'s
/// `Decodable`/`Encodable`: `PackManifest` only models `id`+`events` (its own doc comment
/// says so), so decoding into it and re-encoding would silently DROP every other top-level
/// key a real manifest carries — `name`/`author`/`license`/`version`/`schema` — a real data
/// loss bug, not a hypothetical one, since those fields already exist in shipped manifests
/// (`packs/minimal-chime/manifest.json`).
///
/// Reuses the exact same audited primitives everything else in this codebase uses for pack
/// safety, never a second, unaudited path check:
/// - ``resolvePackDirectory(id:userPacksDirectory:bundledPacksDirectory:)`` to resolve
///   `packID`, then an explicit equality check against the **user** pack root — binding
///   must never write into the read-only bundled pack root, even if `resolvePackDirectory`
///   fell through to it (mirrors ``importAudioFile``'s own confinement to
///   `environment.userPacksDirectory`, never `environment.bundledPacksDirectory`).
/// - ``safePackFileURL(_:in:)`` to validate `fileName` before it's ever written into the
///   manifest, plus a `fileExists` check so a bind can never point an event at a file that
///   isn't really on disk.
/// - ``loadPackManifestData(in:)`` (T16's shared loader) to read `manifest.json`'s raw
///   bytes, gated by the same `isReallyContained` symlink-escape guard `checkPackIntegrity`/
///   `loadPackManifest` use — never a second, unaudited manifest read.
///
/// The final write is `Data.write(to:options:.atomic)`, exactly like
/// ``importAudioFile(sourceURL:suggestedFileName:packID:environment:)``'s own persist step
/// (`AudioImport.swift`'s step 6). **This guarantee is scoped to the write's LEAF path
/// component only** (`manifest.json` itself): the atomic rename replaces whatever directory
/// entry currently sits at that exact leaf (a prior regular file, or even a symlink) by
/// repointing the directory entry itself, rather than opening/truncating/writing through an
/// existing symlink's target — so a same-user race that swaps `manifest.json` itself for a
/// symlink between the read above and this write can't turn this into a write-through-
/// symlink escape.
///
/// It does **not** protect an INTERMEDIATE path component: if `userPackDirectory` (the
/// packID directory itself) were swapped for a symlink after `resolvePackDirectory`'s check
/// above but before this write, the kernel would follow that symlink and the write would
/// land outside the pack. This is the same same-user-local-attacker TOCTOU class already
/// explicitly out of v1's scope per ENGINEERING.md's threat model (a same-user racer already
/// has write access to everything the user owns — no privilege escalation is possible from
/// this), and identical in shape to `importAudioFile`'s own final write
/// (`AudioImport.swift:229-234`), which carries the same limitation today. A full fix
/// (fd-relative `openat`/`renameat` operations that never re-resolve any path component by
/// name after the initial check) is a shared v2 item for both call sites — not implemented
/// here.
public func bindEventToManifest(
    event: Event,
    fileName: String,
    packID: String,
    environment: AudioImportEnvironment
) -> Result<Void, ManifestBindError> {
    guard
        let packDirectory = resolvePackDirectory(
            id: packID, userPacksDirectory: environment.userPacksDirectory,
            bundledPacksDirectory: environment.bundledPacksDirectory)
    else {
        return .failure(.packNotFound(packID: packID))
    }

    let userPackDirectory = environment.userPacksDirectory.appendingPathComponent(
        packID, isDirectory: true)
    guard
        packDirectory.standardizedFileURL.path == userPackDirectory.standardizedFileURL.path
    else {
        // `resolvePackDirectory` found `packID` only via the read-only bundled root — never
        // a legal bind target.
        return .failure(.packNotFound(packID: packID))
    }

    guard let resolvedFile = safePackFileURL(fileName, in: userPackDirectory) else {
        return .failure(.unsafeFileName)
    }
    guard FileManager.default.fileExists(atPath: resolvedFile.path) else {
        return .failure(.fileNotFound(fileName: fileName))
    }

    let manifestData: Data
    switch loadPackManifestData(in: userPackDirectory) {
    case .success(let data):
        manifestData = data
    case .failure(let error):
        return .failure(.manifestUnreadable(reason: error.reason))
    }

    guard
        let parsed = try? JSONSerialization.jsonObject(with: manifestData),
        var json = parsed as? [String: Any]
    else {
        return .failure(.manifestUnreadable(reason: "manifest.json 顶层不是 JSON 对象"))
    }

    // Fail CLOSED on a malformed `events` field, mirroring the top-level-not-object guard
    // just above: `events` present but not itself a JSON object (e.g. an array or string)
    // must never be silently coerced into a fresh, fabricated `{}` — that would quietly
    // discard whatever was really there instead of surfacing the manifest as broken.
    // `events` genuinely ABSENT is the only case that legitimately starts from `[:]`.
    var events: [String: Any]
    if let rawEvents = json["events"] {
        guard let eventsDict = rawEvents as? [String: Any] else {
            return .failure(
                .manifestUnreadable(reason: "manifest.json 的 events 字段不是 JSON 对象"))
        }
        events = eventsDict
    } else {
        events = [:]
    }

    // Fail CLOSED on any shape ``PackManifest`` itself could not decode (T16 review 修复④).
    // Without these two guards, a manifest whose `events` is an object of NON-string values
    // (`{"stop": 1}`), or whose top-level `id` is missing / not a string / empty, would be
    // written back and reported as a SUCCESSFUL bind — yet the very next
    // ``loadPackManifest(in:)`` / ``packCoverage(packID:config:environment:)`` would fail to
    // decode it into ``PackManifest`` and the just-bound row would still render 「未配置」
    // (`CoverageState.unmapped`). A "success" the UI immediately contradicts is worse than an
    // honest refusal — and refusing is what this whole path's fail-closed design already
    // intends (see the non-object `events` guard directly above). Both checks run BEFORE the
    // write, so a malformed manifest is left byte-for-byte untouched.
    //
    // Only the EXISTING sibling values need checking: the value about to be inserted is
    // `fileName`, already a `String`.
    guard events.values.allSatisfy({ $0 is String }) else {
        return .failure(
            .manifestUnreadable(reason: "manifest.json 的 events 存在非字符串取值，无法安全改写"))
    }
    guard let id = json["id"] as? String, !id.isEmpty else {
        return .failure(
            .manifestUnreadable(reason: "manifest.json 缺少有效的顶层 id 字段（必须是非空字符串）"))
    }

    events[event.manifestKey] = fileName
    json["events"] = events

    do {
        let updatedData = try JSONSerialization.data(
            withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        let manifestFile = userPackDirectory.appendingPathComponent("manifest.json")
        try updatedData.write(to: manifestFile, options: .atomic)
    } catch {
        return .failure(.writeFailed(reason: error.localizedDescription))
    }

    return .success(())
}
