import ClaudioCore
import Foundation

/// The management window's star state is intentionally a different projection from the panel's
/// ``starredPackDisplayIDs(orderedPackIDs:starredPacks:defaultStarredPackIDs:)``. It preserves
/// every existing explicit star so a hand-edited fifth entry remains visible and removable; only
/// the panel's id-level read model applies the defensive four-item cap.
public func soundPacksWindowStarredPackIDs(
    installedPackIDs: [String],
    starredPacks: [String]?,
    defaultStarredPackIDs: Set<String>
) -> [String] {
    let installed = Set(installedPackIDs)
    let requested = starredPacks ?? defaultStarredPackIDs.sorted()
    var emitted: Set<String> = []
    return requested.filter { id in
        installed.contains(id) && emitted.insert(id).inserted
    }
}

/// Render-ready state for exactly one management-window `★` / `☆` control.
///
/// Existing stars always remain enabled, including a fifth manually written star and a star whose
/// pack has subsequently become unreadable: hiding its removal path would turn defensive reading
/// into silent data loss. Only a *new* star is blocked by the cap or an unusable pack.
public struct SoundPacksWindowStarControl: Sendable, Equatable {
    public let isStarred: Bool
    public let isEnabled: Bool
    public let disabledReason: String?

    public init(isStarred: Bool, isEnabled: Bool, disabledReason: String?) {
        self.isStarred = isStarred
        self.isEnabled = isEnabled
        self.disabledReason = disabledReason
    }
}

public func soundPacksWindowStarControl(
    packID: String,
    rawStarredPackIDs: [String],
    isPackBroken: Bool
) -> SoundPacksWindowStarControl {
    let starredIDs = Set(rawStarredPackIDs)
    if starredIDs.contains(packID) {
        return SoundPacksWindowStarControl(isStarred: true, isEnabled: true, disabledReason: nil)
    }
    if isPackBroken {
        return SoundPacksWindowStarControl(
            isStarred: false,
            isEnabled: false,
            disabledReason: "声音包不可用，无法显示在面板")
    }
    if starredIDs.count >= maxStarredPacks {
        return SoundPacksWindowStarControl(
            isStarred: false,
            isEnabled: false,
            disabledReason: "面板最多显示 4 个，先取消一颗")
    }
    return SoundPacksWindowStarControl(isStarred: false, isEnabled: true, disabledReason: nil)
}

/// The exact sentence rendered by the window when T16's writer rejects a star mutation.
/// A malformed config is special: `probeConfigRewritable` owns the actionable parse sentence, so
/// the window must surface that sentence itself rather than wrapping it in another writer-specific
/// prefix that would drift from the probe.
public func soundPacksWindowStarredPacksFailureReason(_ error: SetStarredPacksError) -> String {
    switch error {
    case .configReadFailure(let reason):
        return reason
    default:
        return error.description
    }
}
