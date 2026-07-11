import Foundation

/// Per-event mute write-back (ENGINEERING.md 决议③, T15 D4): flips one event's
/// `config.json`「静音钮」bit — `T16` left `EventRowView`'s mute button presentation-only
/// ("writing the actual per-event `enabled` bit back to `config.json` is a future task's
/// write path"); this is that write path, and the GUI's mute button (`EventRowView`, T15)
/// is its only real caller.
///
/// Mirrors ``selectPack(_:configFile:userPacksDirectory:bundledPacksDirectory:lockFile:)``
/// **exactly** — same ``ClaudioPaths/lockFile`` non-blocking `flock`, same
/// read-existing-or-create-fresh shape, same atomic write — so two concurrent config.json
/// writers (a pack switch racing a mute toggle, or two mute toggles racing each other)
/// serialize on the identical lock `selectPack`/`installClaudioHooks` already use, rather
/// than opening a second, independently-reasoned concurrency story for the exact same file.

public enum SetEventEnabledOutcome: Sendable, Equatable {
    /// `config.json` now has `events.<event.cliName> == enabled`.
    case updated(event: Event, enabled: Bool)
}

public enum SetEventEnabledError: Error, Sendable, Equatable, CustomStringConvertible {
    case configReadFailure(reason: String)
    case configWriteFailure(reason: String)
    case lockBusy
    case lockFailed(errno: Int32)

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
        }
    }
}

/// Sets `event`'s mute flag. If `configFile` already exists, only `events.<event.cliName>`
/// is updated — `selected_pack` / `master_volume` / every *other* event's flag are read
/// back and preserved untouched (mirrors ``selectPack``'s "update only the one field this
/// call owns" contract). If it doesn't exist yet, a fresh ``ClaudioConfig`` is created —
/// deliberately with an **empty** `selectedPack`, not a guessed default: unlike
/// ``selectPack``, which is always handed the exact pack id it's about to select, this call
/// has no pack context at all, so inventing one here would silently fabricate a selection
/// nothing actually chose. In practice this branch is unreachable from the real panel (the
/// mute button only renders once a pack is already selected, which only ever happens after
/// `config.json` already exists via `selectPack`/`performFirstRunSetup`) — it exists so
/// this function is still total and testable on its own, not gated on that invariant
/// holding elsewhere.
///
/// Takes the exact same non-blocking ``ClaudioPaths/lockFile`` `selectPack` does (not a
/// second, independent lock) — the two calls edit the same file, and must serialize against
/// each other, not just against themselves.
public func setEventEnabled(
    _ event: Event,
    enabled: Bool,
    configFile: URL = ClaudioPaths.configFile,
    lockFile: URL = ClaudioPaths.lockFile
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

/// 走 ``updateConfigJSON(at:freshSelectedPack:mutate:)`` 这条共用的外科式读-改-写：只 set
/// `events.<event.cliName>`，其余顶层键（`selected_pack` / `master_volume` / 兄弟事件的开关 /
/// 我们根本不认识的键）逐字保留。
///
/// 这里**曾经**是 round-trip `ClaudioConfig`（Codable）：解码 → 改一个字段 → 重新编码。而
/// `ClaudioConfig` 的合成 `Encodable` 只写三个键，它的解码器又是宽松的——于是点一次静音就会
/// 悄悄抹掉未知键、把一个坏掉的 `master_volume` 换成默认值 0.8 再写回去，还报 SUCCESS
/// （`/ship` pre-landing 评审实证复现）。见 `ConfigMutation.swift` 的类型注释。
///
/// 文件不存在时仍然新建一份最小 config，且**刻意**用空的 `selected_pack`——见上面
/// ``setEventEnabled(_:enabled:configFile:lockFile:)`` 的注释。
private func performSetEventEnabled(
    _ event: Event, enabled: Bool, configFile: URL
) -> Result<SetEventEnabledOutcome, SetEventEnabledError> {
    let result = updateConfigJSON(at: configFile, freshSelectedPack: "") { json in
        // `updateConfigJSON` 的校验已经保证：`events` 要么不存在，要么就是一张**每个值都是布尔**
        // 的 JSON 对象（否则整份文件早已按损坏中止，一个字节都不会写）。所以这里的 `as?` 落空
        // 只可能是「`events` 键根本不存在」这一种合法情况。
        var events = json["events"] as? [String: Any] ?? [:]
        events[event.cliName] = enabled
        json["events"] = events
    }

    switch result {
    case .success:
        return .success(.updated(event: event, enabled: enabled))
    case .failure(.unreadable(let reason)):
        return .failure(.configReadFailure(reason: reason))
    case .failure(.writeFailed(let reason)):
        return .failure(.configWriteFailure(reason: reason))
    }
}
