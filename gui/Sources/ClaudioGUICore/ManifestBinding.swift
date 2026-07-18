import ClaudioCore
import Foundation

/// Why ``bindEventToManifest(event:fileName:packID:environment:)`` or
/// ``clearEventBinding(event:packID:environment:)`` refused to write `manifest.json`.
public enum ManifestBindError: Error, Sendable, Equatable {
    /// `packID` doesn't currently resolve to a real, on-disk **user** pack directory.
    /// Binding never creates a pack — it only ever edits a `manifest.json` that already
    /// exists (in practice, always right after
    /// ``importAudioFile(sourceURL:suggestedFileName:packID:environment:)`` created the
    /// user pack directory for the very first time).
    case packNotFound(packID: String)
    /// `fileName` failed ``safePackFileURL(_:in:)``'s containment check (empty / absolute /
    /// `..`-escaping / NUL-bearing / a symlink resolving outside the pack directory).
    ///
    /// ⚠️ **只由 `bindEventToManifest` 自己的文件预检产生**（PLAN-SOUND-MANAGER.md §2.1 T3）：
    /// ``mutateManifestJSON(at:_:)``——bind/clear/未来 fork 共用的读-改-写原语——结构上不做任何
    /// 文件名校验，不可能产生这个 case；``clearEventBinding(event:packID:environment:)`` 从不
    /// 触碰文件，同样永远不会走到这里。
    case unsafeFileName
    /// `fileName` passed the containment check but doesn't exist inside the pack directory as
    /// a **regular file** — binding an event to a file that isn't really there would make the
    /// row recompute to ``CoverageState/broken(fileName:)`` immediately after a "successful"
    /// bind, which must never happen.
    ///
    /// 「正规文件」是负重的，判定是 ``regularFileExists(at:)``（`stat(2)` + `S_IFREG`），与
    /// `coverageState`（`CoverageState.swift`）、`doctor`、`play` **逐字同一个谓词**。曾经这里用的是
    /// `FileManager.fileExists(atPath:)`，它对**目录**、FIFO、socket、设备一律回答 `true`：于是把一个
    /// 名叫 `stop.mp3` 的目录绑上去会**返回成功并写进 manifest**，而面板下一次刷新立刻把同一条路径判成
    /// `.broken`、`doctor` 报缺失、`play` 拒播——「导入成功了却是坏的」，正是这一族谓词要消灭的矛盾
    /// （`/codex review` [P2]）。绑定是**写**路径，必须在写进 manifest 之前就挡住，而不是写完再由读路径
    /// 去发现。
    ///
    /// ⚠️ **同 `.unsafeFileName`，只由 `bindEventToManifest` 自己的文件预检产生** —— 原语本身结构上
    /// 不产生它，`clearEventBinding` 也永远不会走到这里。
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
    ///
    /// Produced by ``mutateManifestJSON(at:_:)`` — the shared primitive — so both
    /// ``bindEventToManifest`` and ``clearEventBinding`` can fail this way identically.
    case manifestUnreadable(reason: String)
    /// The updated JSON couldn't be serialized or written back to disk. Also produced by
    /// ``mutateManifestJSON(at:_:)``.
    case writeFailed(reason: String)
}

// MARK: - The shared read-modify-write primitive (PLAN-SOUND-MANAGER.md §2.1, T3)
//
// `bindEventToManifest`'s 99–207 lines (before this refactor) only ever had ONE line that was
// the actual mutation; everything else — resolve directory → confirm it's the user root → read
// manifest → parse → three fail-closed checks → (mutate) → `encodeJSONObjectForWriting` → atomic
// write — is exactly what `clearEventBinding` (this file) and a future `forkPack` (T6) need to
// reuse VERBATIM. Splitting the file-level checks (`safePackFileURL`/`regularFileExists`, which
// only `bind` needs — `clear` never touches a file, `fork` copies files that already exist) from
// the manifest-level read-modify-write (which every writer needs) is what makes that reuse
// possible without a second, independently-maintained JSON-surgery path.

/// manifest.json 的**唯一**读-改-写原语。``bindEventToManifest`` / ``clearEventBinding`` 全部
/// 经它——未来的 `forkPack`（T6）同理。
///
/// **同步（不许 `async`）**：`SourceScannerSuite` 有一条源码绊线钉着这一点。manifest.json 今天
/// **零锁**——`grep -iE 'lock' ManifestBinding.swift` 找不到一把锁——它唯一的并发安全保证是
/// 「全同步 + 全在 `@MainActor`」：每个调用方都从 GUI 的 `@MainActor` 触发，所以同一时刻只可能有
/// 一次读-改-写在跑。这条原语一旦被改成 `async`，这条不变式会在**没有任何运行时报错**的情况下
/// 悄悄失效——manifest 的并发安全从此只是一句会被忘记的注释（PLAN-SOUND-MANAGER.md §2.1 / 4c
/// 「并发不变式」：唯一的 critical gap，唯一的守卫就是那条源码绊线）。
///
/// **只做目录级的读-改-写**：调用方必须先把 `packID` 解析成一个已经确认过是**用户**包根的
/// `packDirectory`（见本文件 `resolveUserPackDirectory(packID:environment:)`），本函数不重新
/// 解析 `packID`，本身也不做任何 `.unsafeFileName`/`.fileNotFound` 那一类文件级校验——那是
/// `bindEventToManifest` 自己文件预检的职责（见 ``ManifestBindError`` 两个 case 的 doc）。
///
/// 保留 `bindEventToManifest` 原有的**全部三道** fail-closed 校验，顺序不变，且都在 `transform`
/// 运行**之前**跑完（一份不合规的 manifest 被拒时，磁盘上的字节一个都不会变）：
///   1. `events` 若存在但不是 JSON 对象 → 拒绝，绝不静默塞进一个新 `{}`；
///   2. `events` 对象里出现非字符串取值 → 拒绝，绝不写进一份 ``PackManifest`` 解不动的 manifest；
///   3. 顶层 `id` 缺失 / 非字符串 / 空 → 拒绝。
///
/// `transform` 拿到的是**完整的顶层 JSON 字典**（`inout`），不仅仅是 `events`——`forkPack` 要改的
/// 是顶层 `id` / `name` / `license` / `author`，一个只开放 `events` 的原语会逼出第二条顶层 JSON
/// 手术路径，正是这个原语要消灭的重复。`transform` 跑完之后，走
/// ``encodeJSONObjectForWriting(_:path:)``（数字规范化 + 防 `-inf` 硬崩，与 `config.json` 的读-改-写
/// 同一份实现）编码，再 `Data.write(to:options:.atomic)` 写回——与原来 `bindEventToManifest` 的最后
/// 一步完全同构。未知顶层键（`schema` / `version` / 任何未来键）全程只被读进 `[String: Any]`、原样
/// 透传给编码器，这个原语自己从不检查或丢弃它们。
public func mutateManifestJSON(
    at packDirectory: URL,
    _ transform: (inout [String: Any]) -> Void
) -> Result<Void, ManifestBindError> {
    let manifestData: Data
    switch loadPackManifestData(in: packDirectory) {
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

    // Fail CLOSED 校验 1/3 与 2/3：`events` 若存在但不是对象，或对象里出现非字符串取值，一律拒绝
    // ——绝不静默 coerce 成一个新 `{}`，也绝不写进一份 ``PackManifest`` 之后解不动的 manifest。
    // `events` 整个缺失是合法起点：这里不提前造一个 `[:]` 塞回 `json`，创不创建 `events` 是
    // 各自 `transform` 自己的决定（bind 会新建，clear 在 events 整个缺席时无事可做）。
    if let rawEvents = json["events"] {
        guard let eventsDict = rawEvents as? [String: Any] else {
            return .failure(
                .manifestUnreadable(reason: "manifest.json 的 events 字段不是 JSON 对象"))
        }
        guard eventsDict.values.allSatisfy({ $0 is String }) else {
            return .failure(
                .manifestUnreadable(reason: "manifest.json 的 events 存在非字符串取值，无法安全改写"))
        }
    }

    // Fail CLOSED 校验 3/3：顶层 `id` 缺失 / 非字符串 / 空。
    guard let id = json["id"] as? String, !id.isEmpty else {
        return .failure(
            .manifestUnreadable(reason: "manifest.json 缺少有效的顶层 id 字段（必须是非空字符串）"))
    }

    transform(&json)

    let manifestFile = packDirectory.appendingPathComponent("manifest.json")

    // 规范化 + 校验 + 序列化走 ClaudioCore 的 ``encodeJSONObjectForWriting(_:path:)``——与
    // `config.json` 的读-改-写**同一份实现**，两个洞（数字规范化、绝不 abort）一次性同时补给每一个
    // 未来的写者，不必在每个新写者里再抄一遍补丁。
    let updatedData: Data
    switch encodeJSONObjectForWriting(json, path: manifestFile.path) {
    case .success(let encoded): updatedData = encoded
    case .failure(let rejection): return .failure(.writeFailed(reason: rejection.reason))
    }

    do {
        try updatedData.write(to: manifestFile, options: .atomic)
    } catch {
        return .failure(.writeFailed(reason: error.localizedDescription))
    }

    return .success(())
}

/// Resolves `packID` to its **user** pack directory, refusing anything that only exists via the
/// read-only bundled pack root — the ownership check both ``bindEventToManifest`` and
/// ``clearEventBinding`` need before they're allowed to call ``mutateManifestJSON(at:_:)``.
///
/// Factored out because both writers need EXACTLY the same refusal (never write into
/// `environment.bundledPacksDirectory`, even if ``resolvePackDirectory`` fell through to it —
/// mirrors ``importAudioFile``'s own confinement to `environment.userPacksDirectory`), not
/// because it's part of the primitive's own contract: ``mutateManifestJSON(at:_:)`` takes an
/// already-resolved directory and never re-resolves a `packID` itself (§2.1 — deliberately a
/// directory-level primitive, not a packID-level one).
private func resolveUserPackDirectory(
    packID: String,
    environment: AudioImportEnvironment
) -> Result<URL, ManifestBindError> {
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
        // a legal write target for bind OR clear.
        return .failure(.packNotFound(packID: packID))
    }
    return .success(userPackDirectory)
}

/// Binds `fileName` (already copied into the user pack, e.g. by
/// ``importAudioFile(sourceURL:suggestedFileName:packID:environment:)``) to `event` inside
/// `packID`'s `manifest.json` (ENGINEERING.md T16 D3: "逐事件导入绑定").
///
/// This is a **surgical read-modify-write of the raw JSON object**, delegated to
/// ``mutateManifestJSON(at:_:)`` (PLAN-SOUND-MANAGER.md §2.1, T3) after this function's own two
/// file-level checks. Deliberately **never** round-trips through ``PackManifest``'s
/// `Decodable`/`Encodable`: `PackManifest` only models `id`+`events` (its own doc comment says
/// so), so decoding into it and re-encoding would silently DROP every other top-level key a real
/// manifest carries — `name`/`author`/`license`/`version`/`schema` — a real data loss bug, not a
/// hypothetical one, since those fields already exist in shipped manifests
/// (`packs/minimal-chime/manifest.json`).
///
/// Reuses the exact same audited primitives everything else in this codebase uses for pack
/// safety, never a second, unaudited path check:
/// - ``resolvePackDirectory(id:userPacksDirectory:bundledPacksDirectory:)`` (via
///   `resolveUserPackDirectory` above) to resolve `packID`, then an explicit equality check
///   against the **user** pack root — binding must never write into the read-only bundled pack
///   root, even if `resolvePackDirectory` fell through to it.
/// - ``safePackFileURL(_:in:)`` to validate `fileName` before it's ever written into the
///   manifest, plus a ``regularFileExists(at:)`` check — the same `stat(2)`+`S_IFREG` gate
///   `coverageState`/`doctor`/`play` use, never a bare `FileManager.fileExists` — so a bind
///   can never point an event at something that isn't a real, playable file (see
///   ``ManifestBindError/fileNotFound(fileName:)``).
/// - ``mutateManifestJSON(at:_:)`` for everything else: reading `manifest.json`'s raw bytes
///   (via ``loadPackManifestData(in:)``), the three fail-closed manifest guards, and the final
///   atomic write through ``encodeJSONObjectForWriting(_:path:)`` — never a second, unaudited
///   manifest read/write path.
///
/// The final write's atomicity/TOCTOU scope is documented on ``mutateManifestJSON(at:_:)`` and
/// identical to what this function always did — see that function's doc comment (and
/// `importAudioFile`'s own final write, `AudioImport.swift`'s step 6, which carries the same
/// intermediate-path-component limitation, a shared v2 item for both call sites).
public func bindEventToManifest(
    event: Event,
    fileName: String,
    packID: String,
    environment: AudioImportEnvironment
) -> Result<Void, ManifestBindError> {
    let userPackDirectory: URL
    switch resolveUserPackDirectory(packID: packID, environment: environment) {
    case .success(let directory):
        userPackDirectory = directory
    case .failure(let error):
        return .failure(error)
    }

    guard let resolvedFile = safePackFileURL(fileName, in: userPackDirectory) else {
        return .failure(.unsafeFileName)
    }
    guard regularFileExists(at: resolvedFile) else {
        return .failure(.fileNotFound(fileName: fileName))
    }

    return mutateManifestJSON(at: userPackDirectory) { json in
        var events = (json["events"] as? [String: Any]) ?? [:]
        events[event.manifestKey] = fileName
        json["events"] = events
    }
}

/// Clears `event`'s binding from `packID`'s `manifest.json` — ``bindEventToManifest``'s dual
/// (PLAN-SOUND-MANAGER.md §2.1). Removes the `events[event.manifestKey]` entry if present;
/// **never touches the audio file on disk** — the file becomes "unused", surfaced later by the
/// orphan view (T11); deleting it here would be an irreversible action hiding inside a
/// reversible one.
///
/// Recomputes to ``CoverageState/unmapped`` — deliberately **never** ``CoverageState/broken``:
/// decision ①'s "a real packaging defect must never be disguised as intentional silence" also
/// runs in reverse here — a user's deliberate clear must never be disguised as a packaging
/// defect. `doctor`'s missing-files check (`checkPackIntegrity`) only ever looks at
/// manifest-DECLARED files (`manifest.events.values`); a cleared key is no longer declared, so
/// it can never appear on that list — `doctor` simply has nothing to say about it.
///
/// **Idempotent**: clearing an event that's already unmapped (key absent, or `events` itself
/// absent from the manifest) is a no-op `transform` — `.success(())`, never an error.
///
/// Shares ``bindEventToManifest``'s pack-resolution refusal (never writes through the read-only
/// bundled pack root, via `resolveUserPackDirectory`) and the three fail-closed manifest guards
/// via ``mutateManifestJSON(at:_:)`` — but never calls ``safePackFileURL(_:in:)`` /
/// ``regularFileExists(at:)`` at all, which is exactly why clearing a binding whose file was
/// already deleted out from under it (a `.broken` row) still succeeds: clearing doesn't care
/// whether the file is there.
public func clearEventBinding(
    event: Event,
    packID: String,
    environment: AudioImportEnvironment
) -> Result<Void, ManifestBindError> {
    let userPackDirectory: URL
    switch resolveUserPackDirectory(packID: packID, environment: environment) {
    case .success(let directory):
        userPackDirectory = directory
    case .failure(let error):
        return .failure(error)
    }

    return mutateManifestJSON(at: userPackDirectory) { json in
        guard var events = json["events"] as? [String: Any] else { return }
        events.removeValue(forKey: event.manifestKey)
        json["events"] = events
    }
}
