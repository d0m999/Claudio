import Foundation

/// Per-event mute write-back (ENGINEERING.md 决议③, T15 D4): flips one event's
/// `config.json`「静音钮」bit — `T16` left `EventRowView`'s mute button presentation-only
/// ("writing the actual per-event `enabled` bit back to `config.json` is a future task's
/// write path"); this is that write path, and the GUI's mute button (`EventRowView`, T15)
/// is its only real caller.
///
/// Mirrors ``selectPack(_:configFile:userPacksDirectory:bundledPacksDirectory:lockFile:)``'s
/// locking and atomic-write shape — same ``ClaudioPaths/configLockFile`` non-blocking `flock`,
/// same atomic write — so two concurrent config.json writers (a pack switch racing a mute
/// toggle, or two mute toggles racing each other) serialize on the identical lock `selectPack`
/// already uses, rather than opening a second, independently-reasoned concurrency story for
/// the exact same file. `installClaudioHooks` writes a *different* file (`settings.json`) and
/// deliberately takes a *different* lock (``ClaudioPaths/settingsLockFile``) — a settings
/// install must never gate a mute toggle.
///
/// **Diverges from `selectPack` on one thing on purpose (D23 定稿①):** `selectPack` creates a
/// fresh `config.json` when none exists (it always has a real pack id to seed it with);
/// `setEventEnabled` does **not** — see ``SetEventEnabledError/configMissing`` below.

public enum SetEventEnabledOutcome: Sendable, Equatable {
    /// `config.json` now has `events.<event.cliName> == enabled`.
    case updated(event: Event, enabled: Bool)
}

public enum SetEventEnabledError: Error, Sendable, Equatable, CustomStringConvertible {
    case configReadFailure(reason: String)
    case configWriteFailure(reason: String)
    case lockBusy
    case lockFailed(errno: Int32)
    /// `config.json` doesn't exist yet — fail closed rather than fabricate one (D23 定稿①,
    /// see ``setEventEnabled(_:enabled:configFile:lockFile:)``'s doc comment). The panel's
    /// fix is the same self-heal path a missing/empty selection already has: pick a pack in
    /// the gallery (``selectPack``), which creates `config.json` with a real selection.
    case configMissing

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
        }
    }
}

/// Sets `event`'s mute flag. If `configFile` already exists, only `events.<event.cliName>`
/// is updated — `selected_pack` / `master_volume` / every *other* event's flag are read
/// back and preserved untouched (mirrors ``selectPack``'s "update only the one field this
/// call owns" contract).
///
/// If it does **not** exist yet, this call is **fail-closed** (D23 定稿①): it returns
/// ``SetEventEnabledError/configMissing`` and creates nothing. It used to create a fresh
/// ``ClaudioConfig`` instead — deliberately with an **empty** `selectedPack`, reasoning that
/// this call has no pack context at all (unlike ``selectPack``, which is always handed the
/// exact pack id it's about to select), so inventing a default here would silently fabricate
/// a selection nothing actually chose. That reasoning about *what* to write was right, but
/// the conclusion it led to — write an empty-selection config anyway — was the actual bug:
/// it planted `selected_pack: ""` on disk, which every downstream reader (`packSelectionPlan`,
/// the panel) then had to special-case as "this means nobody has chosen a pack yet, not that
/// someone chose an empty one." This branch is **not** theoretical: nothing in the real panel
/// gates the mute toggle on a pack already being selected, so a fresh install with hooks
/// installed but no pack chosen yet reaches this exact call. Refusing outright — rather than
/// fabricating — is the fix; the user's self-heal path is the same one an empty/missing
/// selection already has elsewhere: pick a pack in the gallery (``selectPack``), which is the
/// only call that still creates `config.json` from nothing, and only ever with a real pack id.
///
/// Takes the exact same non-blocking ``ClaudioPaths/configLockFile`` `selectPack` does (not a
/// second, independent lock) — the two calls edit the same file, and must serialize against
/// each other, not just against themselves.
public func setEventEnabled(
    _ event: Event,
    enabled: Bool,
    configFile: URL = ClaudioPaths.configFile,
    lockFile: URL = ClaudioPaths.configLockFile
) -> Result<SetEventEnabledOutcome, SetEventEnabledError> {
    let outcome = withNonBlockingLock(path: lockFile.path) {
        performSetEventEnabled(event, enabled: enabled, configFile: configFile)
    }

    switch outcome {
    case .ran(let result): return result
    case .skipped: return .failure(.lockBusy)
    case .failed(let errno): return .failure(.lockFailed(errno: errno))
    }
}

/// 走 ``updateConfigJSON(at:onMissing:mutate:)`` 这条共用的外科式读-改-写：只 set
/// `events.<event.cliName>`，其余顶层键（`selected_pack` / `master_volume` / `starred_packs` / 兄弟事件的开关 /
/// 我们根本不认识的键）逐字保留。
///
/// 这里**曾经**是 round-trip `ClaudioConfig`（Codable）：解码 → 改一个字段 → 重新编码。而
/// `ClaudioConfig` 的合成 `Encodable` 只写已建模键，它的解码器又是宽松的——于是点一次静音就会
/// 悄悄抹掉未知键、把一个坏掉的 `master_volume` 换成默认值 0.8 再写回去，还报 SUCCESS
/// （`/ship` pre-landing 评审实证复现）。见 `ConfigMutation.swift` 的类型注释。
///
/// 文件不存在时 **fail closed**（D23 定稿①）：``MissingConfigPolicy/failClosed``，不新建。旧行为会在
/// 磁盘上种下一份 `selected_pack: ""` 的 config，把「还没有人选过包」伪装成「选过，选的是空」，
/// 而这条路是真实生产路径，不是理论加固。
///
/// 这里**没有**一道自己的 `fileExists` guard：存在性由 ``updateConfigJSON(at:onMissing:mutate:)``
/// 在它真正要新建的那一刻**当场**判——多探一次就多一个窗口（探到文件在、外部把它删了、写路径照常
/// 新建并报成功）。拒写的资格写在类型里（这条调用递不出一个 pack id），不是写在一次抢跑的检查里。
private func performSetEventEnabled(
    _ event: Event, enabled: Bool, configFile: URL
) -> Result<SetEventEnabledOutcome, SetEventEnabledError> {
    let result = updateConfigJSON(at: configFile, onMissing: .failClosed) { json in
        // `updateConfigJSON` 的校验已经保证：`events` 要么不存在，要么就是一张**每个值都是布尔**
        // 的 JSON 对象（否则整份文件早已按损坏中止，一个字节都不会写）。所以这里的 `as?` 落空
        // 只可能是「`events` 键根本不存在」这一种合法情况。
        var events = json["events"] as? [String: Any] ?? [:]
        events[event.cliName] = enabled
        json["events"] = events
        return .success(())
    }

    switch result {
    case .success:
        return .success(.updated(event: event, enabled: enabled))
    case .failure(.unreadable(let reason)):
        return .failure(.configReadFailure(reason: reason))
    case .failure(.missing):
        return .failure(.configMissing)
    case .failure(.writeFailed(let reason)):
        return .failure(.configWriteFailure(reason: reason))
    case .failure(.mutationRejected):
        return .failure(.configWriteFailure(reason: "配置变更被调用方拒绝"))
    }
}
