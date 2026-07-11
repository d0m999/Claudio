import Foundation

/// A minimal, read-only view of a pack's `manifest.json`, sufficient for `doctor`'s
/// pack-integrity check: does the selected pack exist, and do its declared event audio
/// files actually exist on disk?
///
/// This intentionally does **not** model `name` / `author` / `license` / `version` /
/// `schema` — those are validated (SPDX enum for `license`, and the integer `schema`
/// field as the format's forward-compat marker) when `install`
/// (T2) and the GUI-shared `PackManifest` (T16, "共享 PackManifest 模块与运行时查找顺序
/// 同源") land. Unknown JSON keys are simply ignored by `Decodable`'s keyed container,
/// so this type stays forward-compatible with the fuller schema.
public struct PackManifest: Decodable, Equatable, Sendable {
    /// Pack id (`manifest.json`'s `id` field).
    public let id: String
    /// Event key (`manifest.json` key, e.g. `"stop"`) → audio filename within the pack
    /// directory (e.g. `"stop.mp3"`). A missing event key means silent fallback for
    /// that event — not a pack error (ENGINEERING.md: "缺失 event → 该事件静默，不报错").
    public let events: [String: String]
}

/// Whether `id` is a safe pack id: a single, non-escaping path component. Rejects the
/// empty string, `.`/`..`, absolute paths, and anything containing a path separator or
/// NUL. This matters because pack ids flow in from `config.json`'s `selected_pack` and
/// from third-party-distributed packs (ENGINEERING.md: 策展声音包), so a malicious or
/// mistyped id like `../../Library` must never let ``resolvePackDirectory(id:userPacksDirectory:bundledPacksDirectory:)``
/// (and thus `doctor`) read a directory outside the pack root.
///
/// The separator/NUL check runs over Unicode **scalars**, not `String`'s grapheme-cluster
/// `contains(_:)`: a `/` (U+002F) followed by a combining mark (e.g. `"..\u{2F}\u{301}x"`)
/// fuses into one `Character`, so a grapheme-level `contains("/")` would miss the
/// separator — while the kernel still honors the raw `0x2F` byte and escapes the root
/// (T1 review P2, adversarial verify).
public func isSafePackID(_ id: String) -> Bool {
    if id.isEmpty || id == "." || id == ".." { return false }
    if id.unicodeScalars.contains("/") { return false }
    if id.unicodeScalars.contains("\0") { return false }
    return true
}

/// Lexical containment: is `url` strictly inside `base` once both paths are standardized
/// (so any `..` in `url` is collapsed first)? The shared guard behind pack-id and
/// manifest-event resolution against `../` escape. The trailing-slash `basePrefix` keeps
/// a sibling like `.../packs/chime-evil` from matching `.../packs/chime`. Symlinks are
/// **not** resolved here (out of scope; an install-time concern). Because this check is
/// purely lexical, a symlink whose *target* lies outside `base` still satisfies it —
/// callers that read file contents (not just compare path strings) should also use
/// ``isReallyContained(_:inside:)`` (T1 review P2, second pass).
func isContained(_ url: URL, inside base: URL) -> Bool {
    let urlPath = url.standardizedFileURL.path
    let basePath = base.standardizedFileURL.path
    let basePrefix = basePath.hasSuffix("/") ? basePath : basePath + "/"
    return urlPath.hasPrefix(basePrefix)
}

/// Symlink-aware containment: is `url` strictly inside `base` once symlinks on **both**
/// sides have been resolved to their real, on-disk targets?
///
/// ``isContained(_:inside:)`` only compares standardized path *strings*. A pack directory
/// (or a file inside an otherwise-legitimate pack directory, e.g. `manifest.json` or a
/// declared event audio file) that is, or sits behind, a symlink pointing outside the
/// pack root still satisfies that lexical check — the unresolved path string reads as
/// "under the root" even though the target does not live there. Meanwhile the OS calls
/// that actually read pack content (`FileManager.fileExists`, `Data(contentsOf:)`)
/// transparently follow symlinks regardless of what the unresolved path string says, so
/// the lexical check alone leaves a real containment bypass. Resolving symlinks on both
/// `url` and `base` before the prefix check closes that gap.
///
/// `URL.resolvingSymlinksInPath()` gracefully degrades to lexical standardization for
/// path components that don't exist on disk yet, so this stays correct (and agrees with
/// ``isContained(_:inside:)``) even when one side hasn't been created yet — e.g. when
/// probing a candidate pack directory before confirming it exists (T1 review P2, second
/// pass).
func isReallyContained(_ url: URL, inside base: URL) -> Bool {
    isContained(url.resolvingSymlinksInPath(), inside: base.resolvingSymlinksInPath())
}

/// Resolves a pack id to its on-disk directory, checking the **user pack root first**
/// (so a user pack can override a same-id bundled pack), then the bundled pack root.
/// Returns `nil` if `id` is unsafe (see ``isSafePackID(_:)``) or the pack exists in
/// neither location. Each candidate is additionally required to stay inside its pack
/// root both lexically (``isContained(_:inside:)``) as defense in depth behind
/// ``isSafePackID(_:)``, and by real path (``isReallyContained(_:inside:)``) so a pack
/// directory that is, or sits behind, a symlink escaping the root is rejected too (T1
/// review P2, second pass).
/// Whether `directory` exists on disk **as a directory** — `FileManager.fileExists(atPath:)`
/// alone returns `true` for a plain file too, which would let a stray regular file sitting
/// at a pack-id's expected path be mistaken for that pack's directory (`/codex review`
/// 2026-07-08). Module-visible (not `private`) so `Setup.swift`'s bundle-adjacent-packs
/// discovery (T17) reuses this exact check instead of a second, unaudited copy.
func directoryExists(at directory: URL) -> Bool {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory)
    else { return false }
    return isDirectory.boolValue
}

// MARK: - Shared manifest loading (T16: single source of truth for `helper` and `gui`)

/// Why ``loadPackManifestData(in:)``/``loadPackManifest(in:)`` couldn't read/decode
/// `manifest.json`. Carries the exact reason strings `checkPackIntegrity` has always
/// surfaced (T1), now shared by every caller instead of re-derived per call site.
public enum PackManifestLoadError: Error, Sendable, Equatable {
    /// `manifest.json` doesn't exist at `packDirectory`, isn't readable, or is/sits behind
    /// a symlink resolving outside `packDirectory` (``isReallyContained(_:inside:)``).
    case unreadable(reason: String)
    /// `manifest.json`'s bytes were read successfully, but don't decode as ``PackManifest``.
    case decodeFailed(reason: String)

    /// The human-readable reason, regardless of which case — the exact string
    /// `checkPackIntegrity` has always attached to its own `.manifestUnreadable` result.
    public var reason: String {
        switch self {
        case .unreadable(let reason): reason
        case .decodeFailed(let reason): reason
        }
    }
}

/// Reads `manifest.json`'s raw bytes from `packDirectory`, gated by the same
/// ``isReallyContained(_:inside:)`` symlink-escape guard every other manifest reader in
/// this module uses. `isReallyContained` itself stays module-internal to `ClaudioCore`
/// (a lexical/realpath primitive, not a public API surface on its own) — this narrower,
/// `public` read primitive is what callers outside this module (`gui`'s `ClaudioGUICore`,
/// T16's manifest-binding write path, which needs the *raw* JSON — not the narrower
/// ``PackManifest`` model — to do a read-modify-write that preserves unknown top-level
/// keys) actually get to reuse, rather than reinventing the containment check a second
/// time (ENGINEERING.md T16: "REUSE, do not reinvent").
public func loadPackManifestData(in packDirectory: URL) -> Result<Data, PackManifestLoadError> {
    let manifestFile = packDirectory.appendingPathComponent("manifest.json")
    // `packDirectory` itself is already symlink-safe by the time a caller has one in hand
    // (e.g. via `resolvePackDirectory`, which runs `isReallyContained`), but `manifest.json`
    // is a leaf entry inside it and could independently be a symlink escaping the pack
    // directory — require real containment here too, not just a successful read.
    guard isReallyContained(manifestFile, inside: packDirectory) else {
        return .failure(
            .unreadable(reason: "manifest.json 不存在或不可读：\(manifestFile.path)"))
    }

    // 声音包是第三方分发内容，`manifest.json` 是不可信输入：读它必须走
    // ``readRegularFileBounded(at:maxBytes:followSymlink:)``（`fstat` 正规文件闸门 + 1 MiB 上限），
    // 不能是裸的 `Data(contentsOf:)`——后者**没有任何大小上限**，一个 500MB 形状的 manifest 会被整份
    // 读进来再原样喂给解码器（Codex [P1] + 对抗审查 F2）。非正规文件（目录 / FIFO / socket）今天恰好
    // 也被 Foundation 顺手挡了下来，但那是它的实现细节、不是它的契约——见 `SafeFileRead.swift` 顶部
    // 的实测结论：这里把「绝不阻塞、绝不读非正规文件」变成我们自己的、被测试钉死的契约，而不是一个
    // 借来的巧合。
    //
    // `followSymlink: true`——**与音频文件（``regularFileExists(at:)``，刻意 `stat` 而非 `lstat`）
    // 逐字同一句话**。这一条是本轮评审的修正：manifest 那条路曾用 `O_NOFOLLOW` 拒绝一切符号链接，而
    // 音频那条路跟随它们，于是同一个「包内指向同包内真实文件的符号链接」被两条路给出**相反**的合法性
    // 判断（包作者手工把 manifest 链到 repo 里的包，会莫名其妙变 broken，而它的音频文件却好好的）。
    // 放开跟随在安全性上等价：逃逸早已被上面那道 `isReallyContained`（**解析符号链接后**再判包含）
    // 挡死——`O_NOFOLLOW` 从来不是拦逃逸的那道门；而「链接目标可以任意大 / 可以是 FIFO」这两条，分别
    // 由绑定在同一个 fd 上的大小上限与 `fstat` 正规文件闸门继续挡住。因此：**manifest.json 允许是包内
    // 符号链接，只要它解析后仍在包内、目标是正规文件、且不超上限**——这是给包作者的契约，被
    // `PackContentSafetySuite` 钉死。
    switch readRegularFileBounded(
        at: manifestFile, maxBytes: maxPackManifestBytes, followSymlink: true)
    {
    case .success(let manifestData):
        return .success(manifestData)
    case .notRegularFile:
        return .failure(
            .unreadable(
                reason: "manifest.json 不是正规文件（目录 / FIFO / socket / 设备），"
                    + "拒绝读取：\(manifestFile.path)"))
    case .oversize:
        return .failure(
            .unreadable(
                reason: "manifest.json 超过大小上限（\(maxPackManifestBytes) 字节），"
                    + "拒绝读取：\(manifestFile.path)"))
    case .unreadable:
        return .failure(
            .unreadable(reason: "manifest.json 不存在或不可读：\(manifestFile.path)"))
    }
}

/// Loads and decodes `packDirectory`'s `manifest.json` into a ``PackManifest`` — the single
/// shared loader behind both `helper`'s ``checkPackIntegrity(configFile:userPacksDirectory:bundledPacksDirectory:)``
/// and `gui`'s `ClaudioGUICore` per-event coverage computation (T16: "共享 PackManifest
/// 模块与运行时查找顺序同源"), so both sides parse exactly one, adversarially-tested
/// manifest-reading code path rather than each growing its own.
public func loadPackManifest(in packDirectory: URL) -> Result<PackManifest, PackManifestLoadError>
{
    switch loadPackManifestData(in: packDirectory) {
    case .failure(let error):
        return .failure(error)
    case .success(let manifestData):
        do {
            return .success(try JSONDecoder().decode(PackManifest.self, from: manifestData))
        } catch {
            return .failure(.decodeFailed(reason: error.localizedDescription))
        }
    }
}

public func resolvePackDirectory(
    id: String,
    userPacksDirectory: URL,
    bundledPacksDirectory: URL?
) -> URL? {
    guard isSafePackID(id) else { return nil }

    let userDirectory = userPacksDirectory.appendingPathComponent(id, isDirectory: true)
    if isContained(userDirectory, inside: userPacksDirectory),
        isReallyContained(userDirectory, inside: userPacksDirectory),
        directoryExists(at: userDirectory)
    {
        return userDirectory
    }

    if let bundledPacksDirectory {
        let bundledDirectory = bundledPacksDirectory.appendingPathComponent(id, isDirectory: true)
        if isContained(bundledDirectory, inside: bundledPacksDirectory),
            isReallyContained(bundledDirectory, inside: bundledPacksDirectory),
            directoryExists(at: bundledDirectory)
        {
            return bundledDirectory
        }
    }

    return nil
}
