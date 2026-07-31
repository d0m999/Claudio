import Foundation

/// The hard upper bound for the future panel display set and its management-window writer.
/// It lives in ClaudioCore so read and write behavior cannot drift into independently-maintained
/// copies of the number four.
public let maxStarredPacks = 4

public enum SetStarredPacksOutcome: Sendable, Equatable {
    /// `config.json` now has exactly this explicit, de-duplicated, existing pack-id array.
    case updated(ids: [String])
}

/// Failure vocabulary for the management window's star writer. The common cases and messages
/// deliberately mirror ``SetEventEnabledError``: the same `config.json` and same lock must not
/// grow divergent explanations for identical failures.
public enum SetStarredPacksError: Error, Sendable, Equatable, CustomStringConvertible {
    case configReadFailure(reason: String)
    case configWriteFailure(reason: String)
    case lockBusy
    case lockFailed(errno: Int32)
    case configMissing
    case tooManyStarredPacks(max: Int)
    case userPacksDirectoryUnreadable(reason: String)

    public var description: String {
        switch self {
        case .configReadFailure(let reason):
            "config.json 读取失败，已中止（未修改文件）：\(reason)"
        case .configWriteFailure(let reason):
            "config.json 写入失败：\(reason)"
        case .lockBusy:
            "config.json 当前被占用（另一个 claudio 进程正在读写），请稍后重试"
        case .lockFailed(let errno):
            "无法获取文件锁（errno \(errno)），请稍后重试"
        case .configMissing:
            "还没有选中任何声音包，config.json 不存在——请先在画廊里选一个声音包"
        case .tooManyStarredPacks(let max):
            "最多只能星标 \(max) 个声音包；请先取消一个星标再重试"
        case .userPacksDirectoryUnreadable(let reason):
            "声音包目录读取失败，已中止（未修改文件）：\(reason)"
        }
    }
}

private enum StarredPackDirectoryReadFailure: Error {
    case unreadable(reason: String)
}

/// Replaces the explicit star selection under the same non-blocking `config.lock` every other
/// config writer uses. A missing config file is fail-closed: only `selectPack` can honestly create
/// one because it holds a real selected-pack id.
///
/// Normalization is deliberately in this write path, not the future UI: duplicates collapse,
/// stale ids (not present directly under `userPacksDirectory`) are removed, and a fifth distinct
/// existing id is rejected without silently truncating or touching the file. An unreadable pack
/// directory is never mistaken for an empty one: it fails closed before the config can be changed.
/// If `starred_packs` has never been materialized, `defaultStarredPackIDs` is expanded here before
/// the requested ids are written, so the first non-built-in star cannot silently erase default stars.
/// `materializeDefaultStarredPacks: false` is for the management window only: it already passes
/// its complete visible selection (including defaults when retained), so it must also be able to
/// make an explicit empty selection when the user cancels the last default star.
public func setStarredPacks(
    _ ids: [String],
    configFile: URL = ClaudioPaths.configFile,
    lockFile: URL = ClaudioPaths.configLockFile,
    userPacksDirectory: URL = ClaudioPaths.packsDirectory,
    defaultStarredPackIDs: Set<String>,
    materializeDefaultStarredPacks: Bool = true
) -> Result<SetStarredPacksOutcome, SetStarredPacksError> {
    let outcome = withNonBlockingLock(path: lockFile.path) {
        performSetStarredPacks(
            ids, configFile: configFile, userPacksDirectory: userPacksDirectory,
            defaultStarredPackIDs: defaultStarredPackIDs,
            materializeDefaultStarredPacks: materializeDefaultStarredPacks)
    }

    switch outcome {
    case .ran(let result): return result
    case .skipped: return .failure(.lockBusy)
    case .failed(let errno): return .failure(.lockFailed(errno: errno))
    }
}

private func performSetStarredPacks(
    _ ids: [String],
    configFile: URL,
    userPacksDirectory: URL,
    defaultStarredPackIDs: Set<String>,
    materializeDefaultStarredPacks: Bool
) -> Result<SetStarredPacksOutcome, SetStarredPacksError> {
    var normalizedIDs: [String] = []
    var unreadablePacksDirectoryReason: String?

    let result = updateConfigJSON(at: configFile, onMissing: .failClosed) { json in
        // This question belongs inside updateConfigJSON's one locked parse/mutate/write cycle. A
        // second pre-read would create a divergent config-reading path and an unnecessary race.
        let installedIDs: Set<String>
        switch installedStarredPackIDs(in: userPacksDirectory) {
        case .success(let ids):
            installedIDs = ids
        case .failure(.unreadable(let reason)):
            unreadablePacksDirectoryReason = reason
            return .failure(.mutationRejected)
        }
        let requestedIDs: [String]
        if json["starred_packs"] == nil && materializeDefaultStarredPacks {
            requestedIDs = defaultStarredPackIDs.sorted() + ids
        } else {
            requestedIDs = ids
        }
        normalizedIDs = normalizedExistingStarredPackIDs(requestedIDs, installedIDs: installedIDs)
        guard normalizedIDs.count <= maxStarredPacks else {
            return .failure(.mutationRejected)
        }
        json["starred_packs"] = normalizedIDs
        return .success(())
    }

    switch result {
    case .success:
        return .success(.updated(ids: normalizedIDs))
    case .failure(.unreadable(let reason)):
        return .failure(.configReadFailure(reason: reason))
    case .failure(.missing):
        return .failure(.configMissing)
    case .failure(.writeFailed(let reason)):
        return .failure(.configWriteFailure(reason: reason))
    case .failure(.mutationRejected):
        if let unreadablePacksDirectoryReason {
            return .failure(.userPacksDirectoryUnreadable(reason: unreadablePacksDirectoryReason))
        }
        return .failure(.tooManyStarredPacks(max: maxStarredPacks))
    }
}

/// Enumerates the write surface once while holding `config.lock`. A directory that cannot be read
/// is a failed precondition, not an empty pack list: treating it as empty would silently erase
/// valid stars. This is deliberately not used by
/// ``starredPackDisplayIDs(orderedPackIDs:starredPacks:defaultStarredPackIDs:)``: panel reads are
/// side-effect free and must not quietly prune disk state.
private func installedStarredPackIDs(
    in userPacksDirectory: URL
) -> Result<Set<String>, StarredPackDirectoryReadFailure> {
    let entries: [String]
    do {
        entries = try FileManager.default.contentsOfDirectory(atPath: userPacksDirectory.path)
    } catch {
        return .failure(.unreadable(reason: "无法列出 \(userPacksDirectory.path)：\(error.localizedDescription)"))
    }
    return .success(Set(entries.filter { id in
        guard !id.hasPrefix(".") else { return false }
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(
            atPath: userPacksDirectory.appendingPathComponent(id, isDirectory: true).path,
            isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }))
}

/// Preserves the caller's first-seen order while collapsing duplicates and dropping stale ids.
private func normalizedExistingStarredPackIDs(
    _ requestedIDs: [String], installedIDs: Set<String>
) -> [String] {
    var seen: Set<String> = []
    return requestedIDs.filter { id in
        installedIDs.contains(id) && seen.insert(id).inserted
    }
}
