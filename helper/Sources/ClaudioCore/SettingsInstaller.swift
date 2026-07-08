import Foundation

/// Installs/uninstalls Claudio's `settings.json` hooks (ENGINEERING.md "settings.json 接管：
/// 追加而非覆盖" + 工程落地细节 ①②③⑤). This is the only code path allowed to write
/// `~/.claude/settings.json` — every other Claudio subsystem lives under `~/.claudio/`.
///
/// Invariants enforced here (see `SettingsInstallerSuite.swift`):
/// - **Append, never overwrite**: existing hook groups belonging to other tools are left
///   structurally untouched.
/// - **Idempotent install / exact-match uninstall**: both key off
///   ``claudioHookCommand(for:claudioBinaryPath:)`` compared for exact equality, never a
///   substring (ENGINEERING.md 工程落地细节 ③).
/// - **Abort, never clobber**: an unreadable/unparsable/unexpected-shape `settings.json`
///   aborts with an error and never touches the file.
/// - **One-time backup**: the pre-claudio original is copied to `settings.json.claudio.bak`
///   the first time `install` actually writes, and never overwritten afterwards.
/// - **Non-blocking, serialized read-modify-write**: reuses the same ``ClaudioPaths/lockFile``
///   `play` debounces on (ENGINEERING.md 工程落地细节 ⑤) — never blocks.

private let hooksKey = "hooks"
private let hookTypeKey = "type"
private let hookCommandKey = "command"
private let commandHookType = "command"

/// The exact `settings.json` hook `command` string Claudio installs/matches for `event`.
/// Single source of truth for both the install idempotency check and the uninstall
/// exact-match removal.
public func claudioHookCommand(for event: Event, claudioBinaryPath: String) -> String {
    "\(claudioBinaryPath) play \(event.cliName)"
}

// MARK: - Public result types

public enum InstallOutcome: Sendable, Equatable {
    /// At least one event's hook was newly appended.
    case installed
    /// Every event already had our exact hook command; nothing changed.
    case alreadyInstalled
}

public enum UninstallOutcome: Sendable, Equatable {
    /// `count` claudio hook entries were removed.
    case uninstalled(count: Int)
    /// No claudio hook entries were present (or no settings.json at all); nothing changed.
    case notInstalled
}

public enum SettingsUpdateError: Error, Sendable, Equatable, CustomStringConvertible {
    case notWritable(reason: String)
    case readFailure(reason: String)
    case parseFailure(reason: String)
    case malformedHooksSection(reason: String)
    case backupFailure(reason: String)
    case writeFailure(reason: String)
    case lockBusy
    case lockFailed(errno: Int32)

    public var description: String {
        switch self {
        case .notWritable(let reason): reason
        case .readFailure(let reason): "settings.json 读取失败，已中止（未修改文件）：\(reason)"
        case .parseFailure(let reason): "settings.json 解析失败，已中止（未修改文件）：\(reason)"
        case .malformedHooksSection(let reason): reason
        case .backupFailure(let reason): "备份 settings.json 失败，已中止（未修改文件）：\(reason)"
        case .writeFailure(let reason): "settings.json 写入失败：\(reason)"
        case .lockBusy: "settings.json 当前被占用（另一个 claudio 进程正在读写），请稍后重试"
        case .lockFailed(let errno): "无法获取文件锁（errno \(errno)），请稍后重试"
        }
    }
}

// MARK: - Public entry points

/// Appends claudio's hook command to all four core events (idempotent). Reuses
/// ``probeSettingsWritable(settingsFile:)`` as a pre-write probe and
/// ``withNonBlockingLock(path:_:)`` on `lockFile` (the same lock `play` debounces on) to
/// serialize the read-modify-write against concurrent `claudio` invocations.
public func installClaudioHooks(
    settingsFile: URL = ClaudioPaths.claudeSettingsFile,
    claudioBinaryPath: String = ClaudioPaths.claudioBinary.path,
    lockFile: URL = ClaudioPaths.lockFile
) -> Result<InstallOutcome, SettingsUpdateError> {
    if case .notWritable(let reason) = probeSettingsWritable(settingsFile: settingsFile) {
        return .failure(.notWritable(reason: reason))
    }

    let outcome = withNonBlockingLock(path: lockFile.path) {
        performInstall(settingsFile: settingsFile, claudioBinaryPath: claudioBinaryPath)
    }

    switch outcome {
    case .ran(let result): return result
    case .skipped: return .failure(.lockBusy)
    case .failed(let errno): return .failure(.lockFailed(errno: errno))
    }
}

/// Removes every hook entry whose command exactly matches
/// ``claudioHookCommand(for:claudioBinaryPath:)``, preserving everything else untouched.
public func uninstallClaudioHooks(
    settingsFile: URL = ClaudioPaths.claudeSettingsFile,
    claudioBinaryPath: String = ClaudioPaths.claudioBinary.path,
    lockFile: URL = ClaudioPaths.lockFile
) -> Result<UninstallOutcome, SettingsUpdateError> {
    let outcome = withNonBlockingLock(path: lockFile.path) {
        performUninstall(settingsFile: settingsFile, claudioBinaryPath: claudioBinaryPath)
    }

    switch outcome {
    case .ran(let result): return result
    case .skipped: return .failure(.lockBusy)
    case .failed(let errno): return .failure(.lockFailed(errno: errno))
    }
}

// MARK: - Locked critical sections

private func performInstall(
    settingsFile: URL, claudioBinaryPath: String
) -> Result<InstallOutcome, SettingsUpdateError> {
    switch loadRoot(from: settingsFile) {
    case .failure(let error):
        return .failure(error)
    case .success(let originalRoot):
        if let shapeError = validateHooksShape(originalRoot) {
            return .failure(shapeError)
        }

        var root = originalRoot
        var anyChanged = false
        for event in Event.allCases {
            let command = claudioHookCommand(for: event, claudioBinaryPath: claudioBinaryPath)
            let (nextRoot, changed) = appendHookEntry(root: root, event: event, command: command)
            root = nextRoot
            anyChanged = anyChanged || changed
        }

        guard anyChanged else { return .success(.alreadyInstalled) }

        if case .failure(let error) = backupOriginalIfNeeded(settingsFile: settingsFile) {
            return .failure(error)
        }
        if case .failure(let error) = atomicWrite(root: root, to: settingsFile) {
            return .failure(error)
        }
        return .success(.installed)
    }
}

private func performUninstall(
    settingsFile: URL, claudioBinaryPath: String
) -> Result<UninstallOutcome, SettingsUpdateError> {
    guard FileManager.default.fileExists(atPath: settingsFile.path) else {
        return .success(.notInstalled)
    }

    switch loadRoot(from: settingsFile) {
    case .failure(let error):
        return .failure(error)
    case .success(let originalRoot):
        if let shapeError = validateHooksShape(originalRoot) {
            return .failure(shapeError)
        }

        var root = originalRoot
        var totalRemoved = 0
        for event in Event.allCases {
            let command = claudioHookCommand(for: event, claudioBinaryPath: claudioBinaryPath)
            let (nextRoot, removed) = removeHookEntries(root: root, event: event, command: command)
            root = nextRoot
            totalRemoved += removed
        }

        guard totalRemoved > 0 else { return .success(.notInstalled) }

        if case .failure(let error) = atomicWrite(root: root, to: settingsFile) {
            return .failure(error)
        }
        return .success(.uninstalled(count: totalRemoved))
    }
}

// MARK: - Read / validate

private func loadRoot(from settingsFile: URL) -> Result<[String: Any], SettingsUpdateError> {
    guard FileManager.default.fileExists(atPath: settingsFile.path) else {
        return .success([:])
    }
    let data: Data
    do {
        data = try Data(contentsOf: settingsFile)
    } catch {
        return .failure(.readFailure(reason: "\(settingsFile.path)：\(error.localizedDescription)"))
    }
    do {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure(.parseFailure(reason: "顶层必须是 JSON object：\(settingsFile.path)"))
        }
        return .success(root)
    } catch {
        return .failure(.parseFailure(reason: error.localizedDescription))
    }
}

/// Refuses to proceed if `hooks` (or one of our four target event arrays) exists but is
/// not the shape we expect — silently coercing it to `[:]`/`[]` before writing would
/// **destroy** whatever the user/another tool actually had there.
private func validateHooksShape(_ root: [String: Any]) -> SettingsUpdateError? {
    guard let hooksValue = root[hooksKey] else { return nil }
    guard let hooksSection = hooksValue as? [String: Any] else {
        return .malformedHooksSection(
            reason: "settings.json 的 \"hooks\" 字段不是 object，已中止（未修改文件）")
    }
    for event in Event.allCases {
        guard let eventValue = hooksSection[event.settingsName] else { continue }
        guard eventValue is [Any] else {
            return .malformedHooksSection(
                reason:
                    "settings.json 的 \"hooks.\(event.settingsName)\" 字段不是 array，已中止（未修改文件）"
            )
        }
    }
    return nil
}

// MARK: - Pure JSON tree edits

private func appendHookEntry(
    root: [String: Any], event: Event, command: String
) -> (root: [String: Any], changed: Bool) {
    var root = root
    var hooksSection = (root[hooksKey] as? [String: Any]) ?? [:]
    var eventArray = (hooksSection[event.settingsName] as? [Any]) ?? []

    if eventArray.contains(where: { groupContainsCommand($0, command: command) }) {
        return (root, false)
    }

    let newGroup: [String: Any] = [
        hooksKey: [[hookTypeKey: commandHookType, hookCommandKey: command]]
    ]
    eventArray.append(newGroup)
    hooksSection[event.settingsName] = eventArray
    root[hooksKey] = hooksSection
    return (root, true)
}

private func groupContainsCommand(_ group: Any, command: String) -> Bool {
    guard let groupDict = group as? [String: Any],
        let innerHooks = groupDict[hooksKey] as? [Any]
    else { return false }
    return innerHooks.contains { entry in
        guard let entryDict = entry as? [String: Any] else { return false }
        return (entryDict[hookCommandKey] as? String) == command
    }
}

private func removeHookEntries(
    root: [String: Any], event: Event, command: String
) -> (root: [String: Any], removed: Int) {
    var root = root
    guard var hooksSection = root[hooksKey] as? [String: Any],
        let eventArray = hooksSection[event.settingsName] as? [Any]
    else {
        return (root, 0)
    }

    var removed = 0
    var newEventArray: [Any] = []
    for group in eventArray {
        guard var groupDict = group as? [String: Any],
            let innerHooks = groupDict[hooksKey] as? [Any]
        else {
            // Unknown/malformed shape: preserve it untouched rather than risk dropping
            // something we don't understand.
            newEventArray.append(group)
            continue
        }

        let filteredInner = innerHooks.filter { entry in
            guard let entryDict = entry as? [String: Any],
                (entryDict[hookCommandKey] as? String) == command
            else { return true }
            removed += 1
            return false
        }

        guard !filteredInner.isEmpty else { continue }
        if filteredInner.count != innerHooks.count {
            groupDict[hooksKey] = filteredInner
        }
        newEventArray.append(groupDict)
    }

    if newEventArray.isEmpty {
        hooksSection.removeValue(forKey: event.settingsName)
    } else {
        hooksSection[event.settingsName] = newEventArray
    }
    root[hooksKey] = hooksSection
    return (root, removed)
}

// MARK: - Backup + atomic write

/// Copies the pre-claudio original to `settings.json.claudio.bak`, but only the first
/// time (an existing backup is left alone — "一次性备份"). A failed copy (e.g. the
/// directory isn't writable even though the file itself is — creating a new sibling
/// entry needs directory write permission, not just file write permission) must abort
/// the whole install rather than being silently swallowed: proceeding to overwrite
/// `settings.json` without a successful backup defeats the entire safety net.
private func backupOriginalIfNeeded(settingsFile: URL) -> Result<Void, SettingsUpdateError> {
    let fileManager = FileManager.default
    guard fileManager.fileExists(atPath: settingsFile.path) else { return .success(()) }
    let backupFile = settingsFile.deletingLastPathComponent()
        .appendingPathComponent(settingsFile.lastPathComponent + ".claudio.bak")
    guard !fileManager.fileExists(atPath: backupFile.path) else { return .success(()) }
    do {
        try fileManager.copyItem(at: settingsFile, to: backupFile)
        return .success(())
    } catch {
        return .failure(.backupFailure(reason: error.localizedDescription))
    }
}

/// Writes `root` to `settingsFile` atomically. `Data.write(options:.atomic)` writes a
/// temp file **in the same directory** and `rename(2)`s it into place, which is exactly
/// the "临时文件同目录 + rename" contract (ENGINEERING.md 工程落地细节 ⑤).
private func atomicWrite(
    root: [String: Any], to settingsFile: URL
) -> Result<Void, SettingsUpdateError> {
    do {
        let data = try JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: settingsFile, options: .atomic)
        return .success(())
    } catch {
        return .failure(.writeFailure(reason: error.localizedDescription))
    }
}
