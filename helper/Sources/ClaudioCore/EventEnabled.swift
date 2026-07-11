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

private func performSetEventEnabled(
    _ event: Event, enabled: Bool, configFile: URL
) -> Result<SetEventEnabledOutcome, SetEventEnabledError> {
    var config: ClaudioConfig
    if FileManager.default.fileExists(atPath: configFile.path) {
        guard let data = try? Data(contentsOf: configFile) else {
            return .failure(.configReadFailure(reason: "无法读取 \(configFile.path)"))
        }
        guard var existing = try? JSONDecoder().decode(ClaudioConfig.self, from: data) else {
            return .failure(.configReadFailure(reason: "\(configFile.path) 解析失败"))
        }
        existing.eventsEnabled[event.cliName] = enabled
        config = existing
    } else {
        config = ClaudioConfig(selectedPack: "", eventsEnabled: [event.cliName: enabled])
    }

    do {
        try FileManager.default.createDirectory(
            at: configFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)
        try data.write(to: configFile, options: .atomic)
    } catch {
        return .failure(.configWriteFailure(reason: error.localizedDescription))
    }

    return .success(.updated(event: event, enabled: enabled))
}
