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
    /// non-string value (e.g. `{"stop": 1}`), it has no valid top-level `id` (missing /
    /// not a string / empty), or a scoped writer required that id to match its captured pack
    /// identity and it did not — every shape this read-modify-write requires to safely operate
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
    /// 另一个写者此刻正持有 `~/.claudio/packs.lock` —— 这次读-改-写**一个字节都没跑**。
    ///
    /// `manifest.json` 有两个写者：这里（bind/clear，字节级）与 `performFirstRunSetup` 的包发布
    /// 循环（目录级，会把整个包目录 `moveItem` 挪走）。`withNonBlockingLock` 是**非阻塞**的，
    /// 争用即返回、body 根本不跑 —— 所以这个 case 的语义是「什么都没发生，重试即可」，
    /// 与 ``SetEventEnabledError/lockBusy`` 逐字同构。
    ///
    /// ⚠️ **绝不能把它折叠成 `.success`**：面板只在 `.failure` 上出文案，报成功会让用户点完
    /// 「设置声音」之后什么都没发生、而且没有任何提示。
    case lockBusy
    /// 取包锁时撞上一个**真的**系统错误（不是争用）—— 坏掉的文件系统、权限、路径被占。
    /// 与 ``lockBusy`` 分开，理由同 ``FileLock``：把真错误当成「忙，重试」会让用户永远重试下去。
    case lockFailed(errno: Int32)
    /// The Event mapping no longer matches the value captured before an asynchronous import.
    /// The comparison runs under `packs.lock`, before the transform, so no external manifest
    /// update or unknown sibling is overwritten.
    case targetChanged
}

public enum ManifestEventBindingExpectation: Sendable, Equatable {
    case unmapped
    case mapped(fileName: String)
}

/// Carries the optional Event compare-and-set condition through the existing single locked
/// read-modify-write body. Keeping this policy beside the transform preserves one manifest read
/// path and lets the body abort before encoding when an async target has drifted.
@MainActor
private final class LockedManifestTransform {
    private let expectedEventBinding: (event: Event, binding: ManifestEventBindingExpectation)?
    private let body: (inout [String: Any]) -> Void
    private(set) var failure: ManifestBindError?

    init(
        expectedEventBinding: (event: Event, binding: ManifestEventBindingExpectation)?,
        body: @escaping (inout [String: Any]) -> Void
    ) {
        self.expectedEventBinding = expectedEventBinding
        self.body = body
    }

    fileprivate func callAsFunction(_ json: inout [String: Any]) {
        if let expectedEventBinding {
            let events = (json["events"] as? [String: Any]) ?? [:]
            let current = events[expectedEventBinding.event.manifestKey] as? String
            let matches: Bool
            switch expectedEventBinding.binding {
            case .unmapped:
                matches = current == nil
            case .mapped(let fileName):
                matches = current == fileName
            }
            guard matches else {
                failure = .targetChanged
                return
            }
        }
        body(&json)
    }
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
/// **三条腿：`packs.lock`（跨进程）+ @MainActor 隔离（进程内）+ 同步（无挂起点）。**
///
/// ⚠️ **上一版这段写的是「零锁」，那是假的，而且假了很久。** 原文逐字声称「`@MainActor` + 同步
/// 这两条腿合起来，才是 manifest.json 今天**零锁**却仍并发安全的全部理由」，并让读者自己去
/// `grep -iE 'lock' ManifestBinding.swift` 验证那份空结果。它漏掉的是：`manifest.json` 从来就有
/// **第二个写者** —— helper 的 `performFirstRunSetup` 以目录粒度发布整棵包目录
/// （`Setup.swift` 的 `copyItem`→`moveItem`），还会在 manifest 解不开时把用户整个包目录挪走，
/// 当时零锁（本轮已一并上锁，与这里共用同一把）；而 `restoreBundledPacksHint` 与
/// `docs/distribution.md` 都在**主动教用户**去 Terminal
/// 跑它。`@MainActor` 是**进程内**的东西，对第二个进程一个字都管不住；`.atomic` 写只挡撕裂，
/// **挡不住丢更新**，更挡不住 `moveItem` 在别人读到一半时把整个包目录换掉。
///
/// 现在这段读-改-写**整段**跑在 `~/.claudio/packs.lock` 里（见 ``ClaudioPaths/packsLockFile``），
/// 与 `performFirstRunSetup` 的包发布循环共用同一把 —— 跨进程互斥由锁给。
/// 锁盖住的是「读到写」这个**区间**，不是「写」这个瞬间：只包最后那次 write，两个写者仍然可以
/// 各自读到同一份旧 JSON、各改各的、再依次写回，后写的整份覆盖先写的。
///
/// 另外两条腿**没有被锁取代**，各自还在守自己的东西：
///  · `@MainActor`（进程内）—— 本函数标了它，编译器逼着任何调用方都在主 actor 上调它，不再是
///    「每个调用方碰巧都从 GUI 触发」这句会被下一个后台调用方悄悄推翻的约定
///    （`/codex review dcab3de,7e97bc4` 的 P1）。**但编译器强制的是注解的*后果*，不是注解的*存在***：
///    删掉 `@MainActor` 是一次放宽，现存调用方本身都在主 actor 上，放宽后依然合法 —— 实测
///    `swift build` **零诊断**。守住它的只有 `SourceScannerSuite` 那条源码绊线。
///  · 同步 / 无挂起点 —— 它现在守的是**锁的作用域**：`Task.detached { … write … }` 或在读与写
///    之间插一个 `await`，都会把真正的写挪到锁释放之后，锁当场形同虚设。实测：注入
///    `Task.detached` 包住那次 write，**Build complete、零警告**（`Data`/`URL` 都是 Sendable、
///    `Data.write` 是 nonisolated，strict concurrency 无从报警）。这也只有那条源码绊线看得见。
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
@MainActor
public func mutateManifestJSON(
    at packDirectory: URL,
    lockFile: URL,
    expectedManifestID: String? = nil,
    expectedEventBinding: (event: Event, binding: ManifestEventBindingExpectation)? = nil,
    _ transform: (inout [String: Any]) -> Void
) -> Result<Void, ManifestBindError> {
    // 整段读-改-写都在锁里。**别把锁收窄到只包最后那次 `write`** —— 那样两个写者仍然可以各自
    // 读到同一份旧 JSON、各改各的、再依次写回，后写的把先写的整份覆盖掉（丢更新）。锁要盖住的
    // 是「读到写」这个区间，不是「写」这个瞬间。
    //
    // ⚠️ **上面这句话今天没有可执行的守卫，别把它读成已经钉住了。** 本轮台账（8 条全中）打的
    // 靶子是「锁在不在」「忙时映射对不对」「是不是同一把锁」，**没有一条能分辨「读在锁里」与
    // 「读在锁外」**：把读挪到锁外、只留写在锁里，忙的时候依然返回 `.lockBusy`、磁盘依然一个
    // 字节没动 —— 四条新断言全绿，而丢更新的窗口原地打开。今天挡着它的只有「临界区是一个
    // 函数体」这个形状（`performManifestMutation` 是 `private`、只有这一个调用点），那是可读性
    // 保护，不是断言。见 TODOS。
    return withoutActuallyEscaping(transform) { body in
        let transform = LockedManifestTransform(
            expectedEventBinding: expectedEventBinding,
            body: body)
        let outcome = withNonBlockingLock(path: lockFile.path) {
            performManifestMutation(
                at: packDirectory, expectedManifestID: expectedManifestID, transform)
        }
        switch outcome {
        case .ran(let result): return result
        case .skipped: return .failure(.lockBusy)
        case .failed(let errno): return .failure(.lockFailed(errno: errno))
        }
    }
}

/// ``mutateManifestJSON(at:lockFile:_:)`` 的临界区本体 —— **只**在持有 `packs.lock` 时被调用。
///
/// 单独抽出来是为了让「锁的作用域 == 读-改-写的全长」在源码上一眼可判：临界区是一个函数体，
/// 而不是一段可以被后来者不小心挪出去半截的内联代码。
@MainActor
private func performManifestMutation(
    at packDirectory: URL,
    expectedManifestID: String?,
    _ transform: LockedManifestTransform
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

    // Optional AI cue display metadata is just as untrusted as `events`. Existing malformed
    // content must stop every manifest writer; silently replacing it with `{}` would erase user
    // metadata while reporting a successful bind.
    if let rawAudioNames = json["audio_names"] {
        guard let names = rawAudioNames as? [String: Any] else {
            return .failure(
                .manifestUnreadable(reason: "manifest.json 的 audio_names 字段不是 JSON 对象"))
        }
        guard names.values.allSatisfy({ $0 is String }) else {
            return .failure(
                .manifestUnreadable(reason: "manifest.json 的 audio_names 存在非字符串取值，无法安全改写"))
        }
    }

    // Fail CLOSED 校验 3/3：顶层 `id` 缺失 / 非字符串 / 空。
    guard let id = json["id"] as? String, !id.isEmpty else {
        return .failure(
            .manifestUnreadable(reason: "manifest.json 缺少有效的顶层 id 字段（必须是非空字符串）"))
    }
    if let expectedManifestID, id != expectedManifestID {
        return .failure(
            .manifestUnreadable(
                reason:
                    "manifest.json 的 id「\(id)」与目标声音包「\(expectedManifestID)」不一致"))
    }
    transform(&json)
    if let failure = transform.failure { return .failure(failure) }

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
@MainActor
public func bindEventToManifest(
    event: Event,
    fileName: String,
    packID: String,
    environment: AudioImportEnvironment,
    expectedEventBinding: ManifestEventBindingExpectation? = nil
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
    guard nonEmptyRegularFileExists(at: resolvedFile) else {
        return .failure(.fileNotFound(fileName: fileName))
    }

    return mutateManifestJSON(
        at: userPackDirectory,
        lockFile: environment.packsLockFile,
        expectedManifestID: packID,
        expectedEventBinding: expectedEventBinding.map { (event, $0) }
    ) { json in
        var events = (json["events"] as? [String: Any]) ?? [:]
        events[event.manifestKey] = fileName
        json["events"] = events
    }
}

public struct AICueManifestBindingOutcome: Sendable, Equatable {
    public let event: Event
    public let fileName: String
    public let finalDisplayName: String

    public init(event: Event, fileName: String, finalDisplayName: String) {
        self.event = event
        self.fileName = fileName
        self.finalDisplayName = finalDisplayName
    }
}

/// Publishes the event mapping and its user-facing AI cue name in one manifest transaction. The
/// name is metadata only; file resolution continues to consume `events[event]` exclusively.
@MainActor
public func bindAICueToManifest(
    event: Event,
    fileName: String,
    displayName: AICueDisplayName,
    packID: String,
    environment: AudioImportEnvironment,
    expectedEventBinding: ManifestEventBindingExpectation? = nil
) -> Result<AICueManifestBindingOutcome, ManifestBindError> {
    let userPackDirectory: URL
    switch resolveUserPackDirectory(packID: packID, environment: environment) {
    case .success(let directory): userPackDirectory = directory
    case .failure(let error): return .failure(error)
    }
    guard let resolvedFile = safePackFileURL(fileName, in: userPackDirectory) else {
        return .failure(.unsafeFileName)
    }
    guard nonEmptyRegularFileExists(at: resolvedFile) else {
        return .failure(.fileNotFound(fileName: fileName))
    }

    var finalDisplayName = displayName.value
    let result = mutateManifestJSON(
        at: userPackDirectory,
        lockFile: environment.packsLockFile,
        expectedManifestID: packID,
        expectedEventBinding: expectedEventBinding.map { (event, $0) }
    ) { json in
        var events = (json["events"] as? [String: Any]) ?? [:]
        var audioNames = (json["audio_names"] as? [String: Any]) ?? [:]
        let occupiedNames = audioNames.compactMap { key, value -> String? in
            guard key != fileName else { return nil }
            return value as? String
        }
        finalDisplayName = uniqueAICueDisplayName(
            requested: displayName.value,
            occupiedNames: occupiedNames)
        events[event.manifestKey] = fileName
        audioNames[fileName] = finalDisplayName
        json["events"] = events
        json["audio_names"] = audioNames
    }
    switch result {
    case .success:
        return .success(
            AICueManifestBindingOutcome(
                event: event,
                fileName: fileName,
                finalDisplayName: finalDisplayName))
    case .failure(let error):
        return .failure(error)
    }
}

private func uniqueAICueDisplayName(
    requested: String,
    occupiedNames: [String]
) -> String {
    let locale = Locale(identifier: "en_US_POSIX")
    let comparisonKey: (String) -> String = { value in
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: locale)
    }
    let occupied = Set(occupiedNames.map(comparisonKey))
    guard occupied.contains(comparisonKey(requested)) else { return requested }
    // Every ordinal produces a distinct folded suffix. With N occupied names, one of the first
    // N + 1 suffix candidates must therefore be free; the manifest's 1 MiB read ceiling also
    // keeps this loop tightly bounded for untrusted input without an arbitrary saturation point.
    var ordinal = 2
    while true {
        let suffix = " \(ordinal)"
        let prefixLimit = max(1, AICueDisplayName.maximumCharacters - suffix.count)
        let candidate = String(requested.prefix(prefixLimit)) + suffix
        if !occupied.contains(comparisonKey(candidate)) { return candidate }
        ordinal += 1
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
@MainActor
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

    return mutateManifestJSON(at: userPackDirectory, lockFile: environment.packsLockFile) {
        json in
        guard var events = json["events"] as? [String: Any] else { return }
        events.removeValue(forKey: event.manifestKey)
        json["events"] = events
    }
}
