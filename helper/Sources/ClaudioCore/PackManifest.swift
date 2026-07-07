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

/// Resolves a pack id to its on-disk directory, checking the **user pack root first**
/// (so a user pack can override a same-id bundled pack), then the bundled pack root.
/// Returns `nil` if the pack exists in neither location.
public func resolvePackDirectory(
    id: String,
    userPacksDirectory: URL,
    bundledPacksDirectory: URL?
) -> URL? {
    let fileManager = FileManager.default

    let userDirectory = userPacksDirectory.appendingPathComponent(id, isDirectory: true)
    if fileManager.fileExists(atPath: userDirectory.path) {
        return userDirectory
    }

    if let bundledPacksDirectory {
        let bundledDirectory = bundledPacksDirectory.appendingPathComponent(id, isDirectory: true)
        if fileManager.fileExists(atPath: bundledDirectory.path) {
            return bundledDirectory
        }
    }

    return nil
}
