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
