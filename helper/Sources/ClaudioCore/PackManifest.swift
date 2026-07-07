import Foundation

/// A minimal, read-only view of a pack's `manifest.json`, sufficient for `doctor`'s
/// pack-integrity check: does the selected pack exist, and do its declared event audio
/// files actually exist on disk?
///
/// This intentionally does **not** model `name` / `author` / `license` / `version` /
/// `schema` — those are validated (SPDX enum, `schema_version` compat) when `install`
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
/// **not** resolved here (out of scope; an install-time concern).
func isContained(_ url: URL, inside base: URL) -> Bool {
    let urlPath = url.standardizedFileURL.path
    let basePath = base.standardizedFileURL.path
    let basePrefix = basePath.hasSuffix("/") ? basePath : basePath + "/"
    return urlPath.hasPrefix(basePrefix)
}

/// Resolves a pack id to its on-disk directory, checking the **user pack root first**
/// (so a user pack can override a same-id bundled pack), then the bundled pack root.
/// Returns `nil` if `id` is unsafe (see ``isSafePackID(_:)``) or the pack exists in
/// neither location. Each candidate is additionally required to stay inside its pack
/// root (``isContained(_:inside:)``) as defense in depth behind ``isSafePackID(_:)``.
public func resolvePackDirectory(
    id: String,
    userPacksDirectory: URL,
    bundledPacksDirectory: URL?
) -> URL? {
    guard isSafePackID(id) else { return nil }

    let fileManager = FileManager.default

    let userDirectory = userPacksDirectory.appendingPathComponent(id, isDirectory: true)
    if isContained(userDirectory, inside: userPacksDirectory),
        fileManager.fileExists(atPath: userDirectory.path)
    {
        return userDirectory
    }

    if let bundledPacksDirectory {
        let bundledDirectory = bundledPacksDirectory.appendingPathComponent(id, isDirectory: true)
        if isContained(bundledDirectory, inside: bundledPacksDirectory),
            fileManager.fileExists(atPath: bundledDirectory.path)
        {
            return bundledDirectory
        }
    }

    return nil
}
