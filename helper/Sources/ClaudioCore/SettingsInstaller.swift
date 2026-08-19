import Foundation

/// Installs/uninstalls Claudio's `settings.json` hooks (ENGINEERING.md "settings.json 接管：
/// 追加而非覆盖" + 工程落地细节 ①②③⑤). This is the legacy compatibility writer;
/// modern receipt-bearing connections share the same transaction and matching primitives
/// through ``ClaudeCodeIntegrationAdapter``.
///
/// Invariants enforced here (see `SettingsInstallerSuite.swift`):
/// - **Append, never overwrite**: existing hook groups belonging to other tools are left
///   structurally untouched.
/// - **Idempotent install, exact-match**: both `install`'s idempotency check and the
///   read-only ``detectHookInstallStatus(settingsFile:claudioBinaryPath:)`` probe key off
///   ``claudioHookCommand(for:claudioBinaryPath:)`` compared for exact equality, never a
///   substring (ENGINEERING.md 工程落地细节 ③).
/// - **Never mix legacy and modern playback chains**: a complete modern connection is a
///   successful no-op; partial, conflicting, malformed, relocated, or mixed modern state
///   fails closed and directs the caller to `claudio integrations` for an explicit repair.
/// - **Structural-match uninstall (T13)**: `uninstall` does NOT use the exact-match above —
///   it must still find and remove a claudio hook entry after a *future* binary relocation
///   it was never told the exact old path for. See
///   ``matchedClaudioEvent(inHookCommand:claudioRoot:)`` for the argv-shape + namespace predicate this
///   keys off instead, and why it can never misfire on a third-party hook.
/// - **Install never writes what uninstall cannot sweep**: `install` refuses a
///   `claudioBinaryPath` that names a `.claudio` namespace it would not itself match back out
///   of (``binaryPathContradictsItsNamespace(_:)``). The writer (``shellQuotedPath(_:)``) can
///   quote strictly more paths than the matcher accepts, and the gap opens the day the helper
///   binary relocates or is renamed.
/// - **Abort, never clobber**: an unreadable/unparsable/unexpected-shape `settings.json`
///   aborts with an error and never touches the file.
/// - **One-time backup**: the pre-claudio original is copied to `settings.json.claudio.bak`
///   the first time `install` actually writes, and never overwritten afterwards.
/// - **Non-blocking, serialized read-modify-write**: guarded by its own
///   ``ClaudioPaths/settingsLockFile`` — deliberately **separate** from ``ClaudioPaths/playLockFile``
///   (ENGINEERING.md 工程落地细节 ⑤) — never blocks, and never contends with `play`'s debounce lock.

private let hooksKey = "hooks"
private let hookTypeKey = "type"
private let hookCommandKey = "command"
private let commandHookType = "command"

private func claudeNativeEventName(for event: Event) -> String {
    HostCapabilityCatalog.binding(host: .claudeCode, event: event)!.nativeEvent!
}

/// The exact `settings.json` hook `command` string Claudio installs/matches for `event`.
/// Single source of truth for the install idempotency check and the read-only
/// ``detectHookInstallStatus(settingsFile:claudioBinaryPath:)`` probe. **Not** used by
/// `uninstall`'s removal sweep anymore (T13) — see
/// ``matchedClaudioEvent(inHookCommand:claudioRoot:)``.
///
/// The path goes through ``shellQuotedPath(_:)`` because Claude Code executes this string via
/// `/bin/sh -c`: `~/.claudio/` is space-free by design (决议 4), but the `~` it hangs off is
/// the user's home directory, which claudio does not control. For every path that already
/// works unquoted, `shellQuotedPath` is the identity function, so the emitted string — and
/// therefore install's idempotency and `detectHookInstallStatus`'s answer — is unchanged.
public func claudioHookCommand(for event: Event, claudioBinaryPath: String) -> String {
    "\(shellQuotedPath(claudioBinaryPath)) play \(event.cliName)"
}

// MARK: - Public result types

public enum InstallOutcome: Sendable, Equatable {
    /// At least one event's hook was newly appended.
    case installed(backup: ConfigBackupOutcome)
    /// Every event already had our exact hook command; nothing changed.
    case alreadyInstalled
    /// A complete modern Claude Code connection already exists. The legacy compatibility
    /// command is an idempotent success and must not append a second playback chain.
    case modernConnectionPresent

    public var didInstall: Bool {
        if case .installed = self { return true }
        return false
    }

    public var backupOutcome: ConfigBackupOutcome? {
        guard case .installed(let backup) = self else { return nil }
        return backup
    }
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
    /// The legacy compatibility installer found a modern Claude Code configuration that is not
    /// a complete, healthy connection. Appending `play` hooks would create two independent
    /// playback/debounce chains, so the caller must repair it through the integration adapter.
    case modernConnectionNeedsRepair(reason: String)
    /// `install` was handed a binary path that lives inside a `.claudio` namespace but does not
    /// have a shape that namespace's own `uninstall` sweep recognizes — see
    /// ``binaryPathContradictsItsNamespace(_:)``. Writing the hook would leak an entry no
    /// `uninstall` could ever remove, so nothing is written at all. Unreachable in production
    /// (the path is always `<root>/bin/claudio`); reachable the day a release relocates or
    /// renames the helper binary, which is precisely when it must be loud.
    case unsweepableBinaryPath(path: String)
    /// The on-disk `settings.json` changed between when this operation read it and when it was
    /// about to write, so another writer edited it concurrently — one that does not take
    /// `settings.lock`: Claude Code itself, or the user's editor. (**Not** the GUI: it writes
    /// settings.json only through ``installClaudioHooks(settingsFile:claudioBinaryPath:lockFile:)``
    /// / ``uninstallClaudioHooks(settingsFile:claudioBinaryPath:lockFile:)``, under the same
    /// `settings.lock` this helper takes — so it serializes with us rather than racing us.)
    /// Rather than clobber that edit in a file `uninstall` keeps no backup of, the
    /// write is aborted so the caller can retry against the fresh contents.
    case concurrentModification(path: String)

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
        case .modernConnectionNeedsRepair(let reason):
            "检测到需要修复的现代 Claude Code 连接（\(reason)）；已拒绝追加 legacy hooks，"
                + "请运行 `~/.claudio/bin/claudi0 integrations connect claude-code` 修复，或先用 "
                + "`~/.claudio/bin/claudi0 integrations disconnect claude-code` 断开"
        case .unsweepableBinaryPath(let path):
            "claudio 二进制路径位于自己的 .claudio 命名空间内，却不是 uninstall 能识别并清除的形状"
                + "（根之下只允许不含 shell 元字符的普通路径段，且文件名必须正好是 claudio）："
                + "\(path)——已中止，未修改 settings.json"
        case .concurrentModification(let path):
            "settings.json 在本次读取与写入之间被其他程序修改（Claude Code 自己，或你的编辑器），"
                + "为避免覆盖对方的改动已中止（未修改文件），请重试：\(path)"
        }
    }
}

// MARK: - Public entry points

/// Appends the legacy `claudio play` command to all four lifecycle events (idempotent). Reuses
/// ``probeSettingsWritable(settingsFile:)`` as a pre-write probe and
/// ``withNonBlockingLock(path:_:)`` on `lockFile` (its own ``ClaudioPaths/settingsLockFile``,
/// never `play`'s debounce lock) to serialize the read-modify-write against concurrent
/// `claudio` invocations.
public func installClaudioHooks(
    settingsFile: URL = ClaudioPaths.claudeSettingsFile,
    claudioBinaryPath: String = ClaudioPaths.claudioBinary.path,
    lockFile: URL = ClaudioPaths.settingsLockFile
) -> Result<InstallOutcome, SettingsUpdateError> {
    installClaudioHooksLocked(
        settingsFile: settingsFile, claudioBinaryPath: claudioBinaryPath, lockFile: lockFile,
        betweenReadAndWrite: nil)
}

#if DEBUG
/// Test-only overload driving the ``SettingsUpdateError/concurrentModification(path:)`` window.
/// `betweenReadAndWrite` runs once after `settings.json` has been read and before the one-shot
/// backup and ``atomicWrite(root:to:expectedCurrentData:)``'s re-read — the only way to hit that
/// path deterministically, since the window a real external writer has to land in is microseconds
/// wide and racing it from the outside would be flaky rather than a regression net. Compiled
/// out of release builds (`#if DEBUG`), so the shipped ``ClaudioCore`` library surface — the
/// one the GUI links — stays exactly the production 3-argument signature. Injected for the same
/// reason ``PlayEnvironment``'s `now` is, rather than read from the world.
public func installClaudioHooks(
    settingsFile: URL = ClaudioPaths.claudeSettingsFile,
    claudioBinaryPath: String = ClaudioPaths.claudioBinary.path,
    lockFile: URL = ClaudioPaths.settingsLockFile,
    betweenReadAndWrite: (() -> Void)?
) -> Result<InstallOutcome, SettingsUpdateError> {
    installClaudioHooksLocked(
        settingsFile: settingsFile, claudioBinaryPath: claudioBinaryPath, lockFile: lockFile,
        betweenReadAndWrite: betweenReadAndWrite)
}
#endif

private func installClaudioHooksLocked(
    settingsFile: URL, claudioBinaryPath: String, lockFile: URL,
    betweenReadAndWrite: (() -> Void)?
) -> Result<InstallOutcome, SettingsUpdateError> {
    // Writer-side half of the matcher's contract, checked before any I/O: never append a hook
    // entry this build's own `uninstall` would refuse to recognize. `shellQuotedPath` is strictly
    // more permissive than `matchedClaudioEvent`, so without this a relocation into a
    // metacharacter-carrying subdirectory would install a permanently unsweepable entry.
    guard !binaryPathContradictsItsNamespace(claudioBinaryPath) else {
        return .failure(.unsweepableBinaryPath(path: claudioBinaryPath))
    }
    let backupFile = settingsFile.deletingLastPathComponent()
        .appendingPathComponent(settingsFile.lastPathComponent + ".claudio.bak")
    let transaction = ConfigFileTransaction(
        file: settingsFile,
        lockFile: lockFile,
        backupFile: backupFile,
        symlinkPolicy: .preserveTarget,
        maximumBytes: 1 << 20)
    return performInstall(
        transaction: transaction,
        claudioBinaryPath: claudioBinaryPath,
        betweenReadAndWrite: betweenReadAndWrite)
}

/// Removes every legacy hook entry claudio itself could plausibly have written, for any of the
/// four lifecycle events managed by this compatibility installer, preserving everything else
/// untouched — see
/// ``matchedClaudioEvent(inHookCommand:claudioRoot:)`` for the exact structural match this
/// keys off (T13: a match on trailing argv + claudio's own root, NOT an exact-string compare
/// against `claudioBinaryPath` — the whole point is still finding a stale entry after a
/// binary relocation this call was never told the old path for).
///
/// `claudioBinaryPath` does not have to equal the stale entry's path, but it *does* pin the
/// namespace: ``claudioNamespaceRoot(forBinaryPath:)`` derives `~/.claudio` from it, and only
/// entries under that exact root are swept. A binary path outside any `.claudio` directory
/// yields no root and therefore removes nothing (fail-closed; unreachable in production).
public func uninstallClaudioHooks(
    settingsFile: URL = ClaudioPaths.claudeSettingsFile,
    claudioBinaryPath: String = ClaudioPaths.claudioBinary.path,
    lockFile: URL = ClaudioPaths.settingsLockFile
) -> Result<UninstallOutcome, SettingsUpdateError> {
    uninstallClaudioHooksLocked(
        settingsFile: settingsFile, claudioBinaryPath: claudioBinaryPath, lockFile: lockFile,
        betweenReadAndWrite: nil)
}

#if DEBUG
/// Test-only overload — the uninstall counterpart of
/// ``installClaudioHooks(settingsFile:claudioBinaryPath:lockFile:betweenReadAndWrite:)``'s seam,
/// compiled out of release builds.
public func uninstallClaudioHooks(
    settingsFile: URL = ClaudioPaths.claudeSettingsFile,
    claudioBinaryPath: String = ClaudioPaths.claudioBinary.path,
    lockFile: URL = ClaudioPaths.settingsLockFile,
    betweenReadAndWrite: (() -> Void)?
) -> Result<UninstallOutcome, SettingsUpdateError> {
    uninstallClaudioHooksLocked(
        settingsFile: settingsFile, claudioBinaryPath: claudioBinaryPath, lockFile: lockFile,
        betweenReadAndWrite: betweenReadAndWrite)
}
#endif

private func uninstallClaudioHooksLocked(
    settingsFile: URL, claudioBinaryPath: String, lockFile: URL,
    betweenReadAndWrite: (() -> Void)?
) -> Result<UninstallOutcome, SettingsUpdateError> {
    guard FileManager.default.fileExists(atPath: settingsFile.path) else {
        return .success(.notInstalled)
    }
    let transaction = ConfigFileTransaction(
        file: settingsFile,
        lockFile: lockFile,
        symlinkPolicy: .preserveTarget,
        maximumBytes: 1 << 20)
    return performUninstall(
        transaction: transaction,
        claudioBinaryPath: claudioBinaryPath,
        betweenReadAndWrite: betweenReadAndWrite)
}

// MARK: - Read-only hook-install detection (GUI onboarding, T7)

/// Whether Claudio's legacy hook command is present, for every one of the four lifecycle events, in
/// `settings.json` — a **read-only** query, never a write. GUI onboarding (T7) needs to
/// tell "已接管" (already taken over) from "未接管" without ever calling
/// ``installClaudioHooks(settingsFile:claudioBinaryPath:lockFile:)`` — which has the real
/// side effect of writing the file — just to answer that question (ENGINEERING.md T7
/// note: "判定'是否已接管'要用只读方式").
public enum HookInstallStatus: Sendable, Equatable {
    /// Every legacy lifecycle event already carries claudio's exact-match hook command.
    case installed
    /// `settings.json` is absent, or at least one legacy lifecycle event is missing claudio's hook
    /// command — this covers both "never installed" and "partially installed" (e.g. a
    /// user manually removed one event's entry): onboarding treats anything short of
    /// full coverage as "not yet taken over", since a fresh ``installClaudioHooks`` call
    /// would still have real, visible work to do.
    case notInstalled
    /// `settings.json` exists but couldn't be read or parsed, or its `hooks` section has
    /// an unexpected shape — the exact same classification `install`/`uninstall` would
    /// abort on. Carries the same ``SettingsUpdateError`` so callers can reuse its
    /// `description` verbatim instead of re-deriving their own copy.
    case settingsUnreadable(SettingsUpdateError)
}

/// Read-only counterpart to ``installClaudioHooks(settingsFile:claudioBinaryPath:lockFile:)``.
/// Parses `settingsFile` exactly the same way — reusing ``loadRoot(from:)``,
/// ``validateHooksShape(_:)``, and ``groupContainsCommand(_:command:)``, the very same
/// private helpers `install`/`uninstall` use — so "is it installed?" can never silently
/// drift out of sync with what a real `install`/`uninstall` call would actually see.
/// Never takes ``ClaudioPaths/settingsLockFile``: there is nothing to serialize against
/// concurrent writers for a pure read that never writes anything back.
public func detectHookInstallStatus(
    settingsFile: URL = ClaudioPaths.claudeSettingsFile,
    claudioBinaryPath: String = ClaudioPaths.claudioBinary.path
) -> HookInstallStatus {
    switch loadRoot(from: settingsFile) {
    case .failure(let error):
        return .settingsUnreadable(error)
    case .success(let loaded):
        if let shapeError = validateHooksShape(loaded.root) {
            return .settingsUnreadable(shapeError)
        }
        let hooksSection = (loaded.root[hooksKey] as? [String: Any]) ?? [:]
        let allEventsInstalled = Event.legacyLifecycleCases.allSatisfy { event in
            let command = claudioHookCommand(for: event, claudioBinaryPath: claudioBinaryPath)
            let eventArray = (hooksSection[claudeNativeEventName(for: event)] as? [Any]) ?? []
            return eventArray.contains { groupContainsCommand($0, command: command) }
        }
        return allEventsInstalled ? .installed : .notInstalled
    }
}

// MARK: - Locked critical sections

private enum InstallMutationResult: Sendable {
    case installed
    case alreadyInstalled
    case modernConnectionPresent
}

private func performInstall(
    transaction: ConfigFileTransaction,
    claudioBinaryPath: String,
    betweenReadAndWrite: (() -> Void)? = nil
) -> Result<InstallOutcome, SettingsUpdateError> {
    var semanticError: SettingsUpdateError?
    let mutate: ([String: Any]) -> ConfigFileTypedMutation<InstallMutationResult> = {
        originalRoot in
        if let shapeError = validateHooksShape(originalRoot) {
            semanticError = shapeError
            return .unchanged(.alreadyInstalled)
        }
        if let claudioRoot = claudioNamespaceRoot(forBinaryPath: claudioBinaryPath) {
            if containsRelocatedClaudeCodeHooks(
                root: originalRoot,
                claudioRoot: claudioRoot,
                claudioBinaryPath: claudioBinaryPath)
            {
                semanticError = .modernConnectionNeedsRepair(
                        reason:
                            "同一 claudi0 root 下仍有旧 helper 路径的 modern callback，"
                            + "可能与新连接同时执行")
                return .unchanged(.alreadyInstalled)
            }
            switch inspectClaudeCodeHooks(
                root: originalRoot,
                claudioRoot: claudioRoot,
                claudioBinaryPath: claudioBinaryPath)
            {
            case .success(.configured):
                return .unchanged(.modernConnectionPresent)
            case .success(.partial(_, let missing, let hasLegacyEntries))
                where missing.count < HostCapabilityCatalog.bindings(for: .claudeCode).count:
                let detail = hasLegacyEntries
                    ? "现代与 legacy hook 同时存在，可能重复播放"
                    : "现代 hook 不完整，缺少 \(missing.joined(separator: ", "))"
                semanticError = .modernConnectionNeedsRepair(reason: detail)
                return .unchanged(.alreadyInstalled)
            case .success(.conflict(let reason)):
                semanticError = .modernConnectionNeedsRepair(reason: reason)
                return .unchanged(.alreadyInstalled)
            case .failure(let error):
                semanticError = .modernConnectionNeedsRepair(
                    reason: "现代/legacy hooks 无法安全检查：\(error.description)")
                return .unchanged(.alreadyInstalled)
            case .success(.notConfigured), .success(.legacyConnected), .success(.partial):
                break
            }
        }

        var root = originalRoot
        var anyChanged = false
        for event in Event.legacyLifecycleCases {
            let command = claudioHookCommand(for: event, claudioBinaryPath: claudioBinaryPath)
            let (nextRoot, changed) = appendHookEntry(root: root, event: event, command: command)
            root = nextRoot
            anyChanged = anyChanged || changed
        }

        guard anyChanged else { return .unchanged(.alreadyInstalled) }
        return .replace(root, .installed)
    }

    let updated: Result<ConfigFileTransactionReport<InstallMutationResult>, ConfigFileTransactionError>
    #if DEBUG
    updated = transaction.update(mutate, betweenReadAndWrite: betweenReadAndWrite)
    #else
    updated = transaction.update(mutate)
    #endif
    if let semanticError { return .failure(semanticError) }
    switch updated {
    case .failure(let error):
        return .failure(mapTransactionError(error))
    case .success(let report):
        switch report.value {
        case .installed: return .success(.installed(backup: report.backup))
        case .alreadyInstalled: return .success(.alreadyInstalled)
        case .modernConnectionPresent: return .success(.modernConnectionPresent)
        }
    }
}

/// `claudioBinaryPath` drives the removal match only through the `.claudio` root it names —
/// see ``uninstallClaudioHooks(settingsFile:claudioBinaryPath:lockFile:)``. A path naming no
/// root is fail-closed: nothing matches, nothing is written, `.notInstalled`.
private func performUninstall(
    transaction: ConfigFileTransaction,
    claudioBinaryPath: String,
    betweenReadAndWrite: (() -> Void)? = nil
) -> Result<UninstallOutcome, SettingsUpdateError> {
    var semanticError: SettingsUpdateError?
    let mutate: ([String: Any]) -> ConfigFileTypedMutation<UninstallOutcome> = {
        originalRoot in
        if let shapeError = validateHooksShape(originalRoot) {
            semanticError = shapeError
            return .unchanged(.notInstalled)
        }
        // Deliberately AFTER load+validate: a corrupt `settings.json` must still surface its
        // error rather than be masked as "nothing installed" just because the caller handed us
        // a binary path that names no root.
        guard let claudioRoot = claudioNamespaceRoot(forBinaryPath: claudioBinaryPath) else {
            return .unchanged(.notInstalled)
        }

        var root = originalRoot
        var totalRemoved = 0
        for event in Event.legacyLifecycleCases {
            let (nextRoot, removed) = removeHookEntries(
                root: root, event: event, claudioRoot: claudioRoot)
            root = nextRoot
            totalRemoved += removed
        }

        guard totalRemoved > 0 else { return .unchanged(.notInstalled) }
        return .replace(root, .uninstalled(count: totalRemoved))
    }

    let updated: Result<ConfigFileTransactionReport<UninstallOutcome>, ConfigFileTransactionError>
    #if DEBUG
    updated = transaction.update(mutate, betweenReadAndWrite: betweenReadAndWrite)
    #else
    updated = transaction.update(mutate)
    #endif
    if let semanticError { return .failure(semanticError) }
    return updated
        .map(\.value)
        .mapError(mapTransactionError)
}

private func mapTransactionError(_ error: ConfigFileTransactionError) -> SettingsUpdateError {
    switch error {
    case .notWritable(let reason): return .notWritable(reason: reason)
    case .readFailure(let path): return .readFailure(reason: path)
    case .parseFailure(let reason): return .parseFailure(reason: reason)
    case .malformedTopLevel(let path):
        return .parseFailure(reason: "顶层必须是 JSON object：\(path)")
    case .mutationRejected(let reason): return .writeFailure(reason: reason)
    case .backupFailure(let reason): return .backupFailure(reason: reason)
    case .writeFailure(let reason): return .writeFailure(reason: reason)
    case .concurrentModification(let path): return .concurrentModification(path: path)
    case .symlinkRejected(let path): return .readFailure(reason: "拒绝符号链接：\(path)")
    case .danglingSymlink(let path): return .readFailure(reason: "悬空符号链接：\(path)")
    case .lockBusy: return .lockBusy
    case .lockFailed(let code): return .lockFailed(errno: code)
    }
}

// MARK: - Read / validate

/// Also returns the exact bytes it read (`rawData`, `nil` when the file doesn't exist yet), so
/// the caller can hand them to ``atomicWrite(root:to:expectedCurrentData:)`` as an
/// optimistic-concurrency baseline: the write aborts if the on-disk bytes changed underneath a
/// read-modify-write that no cross-process lock protects (see that function).
private func loadRoot(
    from settingsFile: URL
) -> Result<(root: [String: Any], rawData: Data?), SettingsUpdateError> {
    guard FileManager.default.fileExists(atPath: settingsFile.path) else {
        return .success((root: [:], rawData: nil))
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
        return .success((root: root, rawData: data))
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
    for event in Event.legacyLifecycleCases {
        let nativeEvent = claudeNativeEventName(for: event)
        guard let eventValue = hooksSection[nativeEvent] else { continue }
        guard eventValue is [Any] else {
            return .malformedHooksSection(
                reason:
                    "settings.json 的 \"hooks.\(nativeEvent)\" 字段不是 array，已中止（未修改文件）"
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
    let nativeEvent = claudeNativeEventName(for: event)
    var eventArray = (hooksSection[nativeEvent] as? [Any]) ?? []

    if eventArray.contains(where: { groupContainsCommand($0, command: command) }) {
        return (root, false)
    }

    let newGroup: [String: Any] = [
        hooksKey: [[hookTypeKey: commandHookType, hookCommandKey: command]]
    ]
    eventArray.append(newGroup)
    hooksSection[nativeEvent] = eventArray
    root[hooksKey] = hooksSection
    return (root, true)
}

/// Whether `group` contains a **real command hook** — an entry whose `"type"` is
/// `"command"` *and* whose `"command"` exactly matches. The `type == "command"`
/// requirement is deliberate and load-bearing for the two callers that use this:
/// `appendHookEntry` (install idempotency) and `detectHookInstallStatus` (the read-only
/// "已接管?" probe). An entry that carries our command string but a missing or different
/// `type` is one Claude Code will NOT execute as a command hook, so treating it as "ours,
/// already installed" would (a) make onboarding claim `.installed` for a config that never
/// actually fires, and (b) make `install` skip appending the real, runnable entry that
/// would fix it. Requiring the type instead lets `install` self-heal past such a leftover.
///
/// `uninstall` intentionally does NOT go through here — `removeHookEntries` matches
/// structurally via ``matchedClaudioEvent(inHookCommand:claudioRoot:)`` (ignoring `"type"` entirely, and
/// not comparing against any single expected path), so a malformed or relocated-binary
/// leftover carrying a claudio-shaped command still gets cleaned up.
private func groupContainsCommand(_ group: Any, command: String) -> Bool {
    guard let groupDict = group as? [String: Any],
        let innerHooks = groupDict[hooksKey] as? [Any]
    else { return false }
    return innerHooks.contains { entry in
        guard let entryDict = entry as? [String: Any] else { return false }
        return (entryDict[hookTypeKey] as? String) == commandHookType
            && (entryDict[hookCommandKey] as? String) == command
    }
}

/// Removes every hook entry under `event`'s array whose `"command"` is structurally
/// claudio's own, inside `claudioRoot` — see
/// ``matchedClaudioEvent(inHookCommand:claudioRoot:)``. Matches on `command` alone (ignoring
/// `"type"`, mirroring the pre-T13 exact-match behavior this replaces), so a malformed
/// leftover missing `"type": "command"` still gets swept.
private func removeHookEntries(
    root: [String: Any], event: Event, claudioRoot: String
) -> (root: [String: Any], removed: Int) {
    var root = root
    let nativeEvent = claudeNativeEventName(for: event)
    guard var hooksSection = root[hooksKey] as? [String: Any],
        let eventArray = hooksSection[nativeEvent] as? [Any]
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
                let command = entryDict[hookCommandKey] as? String,
                matchedClaudioEvent(inHookCommand: command, claudioRoot: claudioRoot) == event
            else { return true }
            removed += 1
            return false
        }

        if filteredInner.isEmpty {
            // Filtered down to empty. Only DROP the group if WE emptied it (it held entries
            // before, all of which were ours). A group that was ALREADY empty before this sweep
            // is a third-party artifact — preserve it byte-for-byte rather than collaterally
            // deleting someone else's (empty) group in this no-backup path.
            if innerHooks.isEmpty {
                newEventArray.append(group)
            }
            continue
        }
        if filteredInner.count != innerHooks.count {
            groupDict[hooksKey] = filteredInner
        }
        newEventArray.append(groupDict)
    }

    if newEventArray.isEmpty {
        hooksSection.removeValue(forKey: nativeEvent)
    } else {
        hooksSection[nativeEvent] = newEventArray
    }
    root[hooksKey] = hooksSection
    return (root, removed)
}
