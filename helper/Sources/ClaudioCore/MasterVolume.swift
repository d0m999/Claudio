import Foundation

/// Master-volume write-back (ENGINEERING.md「面板 UI 线框」`🔊 主音量 ●———————` +「交互状态覆盖表 ·
/// 主音量」): flips `config.json`'s `master_volume` — the panel's volume slider is its (future)
/// real caller, mirroring ``setEventEnabled(_:enabled:configFile:lockFile:)``'s relationship to
/// the mute button.
///
/// The third writer of `config.json`, alongside
/// ``selectPack(_:configFile:userPacksDirectory:bundledPacksDirectory:lockFile:)`` and
/// ``setEventEnabled(_:enabled:configFile:lockFile:)``. All three go through the same surgical
/// read-modify-write (``updateConfigJSON(at:onMissing:mutate:)``) and take the same
/// ``ClaudioPaths/configLockFile`` — not a fourth, independently-reasoned lock/write story for the
/// identical file.
///
/// **No `freshSelectedPack` parameter — this signature never had one (D13 判死).** An earlier WIP
/// (branch `feat/master-volume-slider`, predating `updateConfigJSON`'s `MissingConfigPolicy`
/// refactor) required the caller to hand in a pack id so a missing `config.json` could be seeded
/// with it — the same shape `setEventEnabled` briefly had, killed there for the same reason
/// (D23 定稿①): a caller with no real pack context can only fabricate one, and a fabricated
/// `selected_pack` is worse than refusing outright. A volume value carries no pack identity, so
/// this call is built directly on the post-D23 shape — see ``SetMasterVolumeError/configMissing``.
/// This does **not** touch ``updateConfigJSON(at:onMissing:mutate:)``'s own `freshSelectedPack`
/// parameter on ``MissingConfigPolicy/createFresh(selectedPack:)``: `selectPack` still uses it
/// (`Use.swift`), and that is the only path that still creates `config.json` from nothing — this
/// call passes ``MissingConfigPolicy/failClosed`` instead.
///
/// **Clamped before it is written, never after.** ENGINEERING.md's interaction table says 「越界值
/// → 钳制到 0.0–1.0」, and this is the only place that can honor it for the *stored* value:
/// ``AfplayVolume/clamped(_:)`` already guards the *playback* path (`afplay -v`), but a raw
/// out-of-range or non-finite number sitting in `config.json` would still be a number the user's
/// own file shows. Reuses ``AfplayVolume/clamped(_:)`` — the one clamp this repo has, not a second
/// one rederived here — so a non-finite input (`NaN`, `±infinity`) is already
/// ``ClaudioConfig/defaultMasterVolume`` by the time it reaches
/// ``updateConfigJSON(at:onMissing:mutate:)`` / `JSONSafeWrite`'s encoder; those still fail-closed
/// on a non-finite number as a second, independent gate (belt and braces — see
/// ``firstUnwritableJSONValue(in:keyPath:depth:path:)``), but this call never exercises that gate.
/// ``SetMasterVolumeOutcome/updated(volume:)`` carries the **landed** (clamped) value, not the one
/// the caller asked for, so a UI can snap its slider to the truth without re-reading the file.
public enum SetMasterVolumeOutcome: Sendable, Equatable {
    /// `config.json` now has `master_volume == volume`, where `volume` is the value that actually
    /// landed on disk (already run through ``AfplayVolume/clamped(_:)``) — not necessarily the one
    /// the caller passed in.
    case updated(volume: Double)
}

/// Mirrors ``SetEventEnabledError`` case-for-case (same file, same lock, same missing-config
/// policy) — the two writers must not grow two different vocabularies for the same failures.
public enum SetMasterVolumeError: Error, Sendable, Equatable, CustomStringConvertible {
    case configReadFailure(reason: String)
    case configWriteFailure(reason: String)
    case lockBusy
    case lockFailed(errno: Int32)
    /// `config.json` doesn't exist yet — fail closed rather than fabricate one, exactly like
    /// ``SetEventEnabledError/configMissing`` (D23 定稿①): a volume value carries no pack
    /// identity, so there is nothing real to seed `selected_pack` with. Same self-heal path: pick
    /// a pack in the gallery (``selectPack``), which creates `config.json` with a real selection.
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

/// Sets `master_volume`, clamped into `[0.0, 1.0]` via ``AfplayVolume/clamped(_:)`` before it is
/// written. Only that one key is touched — `selected_pack`, every event's mute flag, and every
/// top-level key this v1 model doesn't even know about are read back and written out untouched
/// (``updateConfigJSON(at:onMissing:mutate:)``'s contract).
///
/// If `configFile` does **not** exist yet, this call is **fail-closed**: it returns
/// ``SetMasterVolumeError/configMissing`` and creates nothing — see the type-level doc above.
///
/// Takes the exact same non-blocking ``ClaudioPaths/configLockFile`` `selectPack` and
/// `setEventEnabled` do (not a fourth, independent lock) — all three edit the same file, and must
/// serialize against each other, not just against themselves. Deliberately **not** `play`'s
/// ``ClaudioPaths/playLockFile`` — dragging a slider must never gate on, or be gated by, `play`'s
/// debounce.
public func setMasterVolume(
    _ volume: Double,
    configFile: URL = ClaudioPaths.configFile,
    lockFile: URL = ClaudioPaths.configLockFile
) -> Result<SetMasterVolumeOutcome, SetMasterVolumeError> {
    let landed = AfplayVolume.clamped(volume)

    let outcome = withNonBlockingLock(path: lockFile.path) {
        performSetMasterVolume(landed, configFile: configFile)
    }

    switch outcome {
    case .ran(let result): return result
    case .skipped: return .failure(.lockBusy)
    case .failed(let errno): return .failure(.lockFailed(errno: errno))
    }
}

/// 走 ``updateConfigJSON(at:onMissing:mutate:)`` 这条共用的外科式读-改-写：只 set `master_volume`，
/// 其余顶层键（`selected_pack` / 每个事件的开关 / 我们根本不认识的键）逐字保留。
///
/// `landed` 在进来之前已经被 ``AfplayVolume/clamped(_:)`` 钳过
/// （``setMasterVolume(_:configFile:lockFile:)`` 里做的），所以这里**不**重新钳一次——钳制只有一份
/// 实现，不在两个地方各判一遍。
///
/// 文件不存在时 **fail closed**（同 `setEventEnabled`，D23 定稿①同一个理由）：
/// ``MissingConfigPolicy/failClosed``，不新建——这个调用手上没有任何 pack id，凭空新建等于伪造一次
/// 谁也没做过的选择。
private func performSetMasterVolume(
    _ landed: Double, configFile: URL
) -> Result<SetMasterVolumeOutcome, SetMasterVolumeError> {
    let result = updateConfigJSON(at: configFile, onMissing: .failClosed) { json in
        json["master_volume"] = landed
    }

    switch result {
    case .success:
        return .success(.updated(volume: landed))
    case .failure(.unreadable(let reason)):
        return .failure(.configReadFailure(reason: reason))
    case .failure(.missing):
        return .failure(.configMissing)
    case .failure(.writeFailed(let reason)):
        return .failure(.configWriteFailure(reason: reason))
    }
}
