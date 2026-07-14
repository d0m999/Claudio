import Foundation

/// `claudio use <pack-id>` — switches the active sound pack by writing `config.json`
/// (ENGINEERING.md「工程落地细节 ⑥ config.json 归属」: the GUI writes it, `claudio play` only
/// ever reads it; `use` is the documented CLI-convenience equivalent writer, T17).
///
/// Validates `packID` the exact same way `play` resolves the pack it's about to read from
/// (``resolvePackDirectory(id:userPacksDirectory:bundledPacksDirectory:)``), so `use` can
/// never select a pack id that `play` would then silently fail to find.

public enum UseOutcome: Sendable, Equatable {
    /// `config.json` now has `selected_pack == packID`.
    case selected(packID: String)
}

/// `configReadFailure`/`configWriteFailure`/`lockBusy`/`lockFailed` mirror
/// ``SetEventEnabledError``/``SetMasterVolumeError``'s cases of the same name — same file,
/// same lock, same failure vocabulary. Their `description` strings must stay byte-for-byte
/// identical across all three types: ``panelWriteFailures(muteError:packSwitchError:masterVolumeError:)``
/// dedupes cross-writer failures (e.g. two writers hitting the same `.lockBusy`) by comparing
/// `description` text, not case identity — a wording change here that drifts from the other two
/// types silently stops that dedup from firing for this case (`PanelWriteFailuresSuite`'s
/// cross-type `.lockBusy` suites catch the drift, but nothing here warns a future editor before
/// they make it).
public enum UseError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidPackID(String)
    case packNotFound(String)
    case configReadFailure(reason: String)
    case configWriteFailure(reason: String)
    case lockBusy
    case lockFailed(errno: Int32)

    public var description: String {
        switch self {
        case .invalidPackID(let id):
            "\"\(id)\" 不是合法的声音包 id（不能为空、不能是 . / ..、不能含路径分隔符）"
        case .packNotFound(let id):
            "找不到声音包 \"\(id)\"（~/.claudio/packs/\(id)/ 不存在）"
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

/// Switches the active pack. If `configFile` already exists, only `selected_pack` is
/// updated — `master_volume` / `events` are read back and preserved untouched. If it
/// doesn't exist yet, a fresh ``ClaudioConfig`` is created with defaults for everything
/// else (T17: this is also the path ``performFirstRunSetup(environment:)`` uses to
/// establish a first-run default pack selection).
///
/// The read-modify-write runs under ``ClaudioPaths/configLockFile``'s non-blocking `flock` —
/// the same lock `setEventEnabled` serializes on, and deliberately **not** the one `install`
/// (``ClaudioPaths/settingsLockFile``) or `play` (``ClaudioPaths/playLockFile``) takes — so
/// two concurrent `claudio use` (or `use` racing `setup`) invocations can't silently lose
/// one write (Codex review of 3d09bf5, confirmed again by `/ship`'s pre-landing review red
/// team pass: unlike `settings.json`'s write path, this one had never been brought under
/// the lock). Because the lock is non-blocking, contention surfaces as ``UseError/lockBusy``
/// — a real, distinct error the caller sees and can retry — never a silent no-op reported
/// as success (project rule: never silently swallow an error).
public func selectPack(
    _ packID: String,
    configFile: URL = ClaudioPaths.configFile,
    userPacksDirectory: URL = ClaudioPaths.packsDirectory,
    bundledPacksDirectory: URL? = nil,
    lockFile: URL = ClaudioPaths.configLockFile
) -> Result<UseOutcome, UseError> {
    guard isSafePackID(packID) else { return .failure(.invalidPackID(packID)) }
    guard
        resolvePackDirectory(
            id: packID, userPacksDirectory: userPacksDirectory,
            bundledPacksDirectory: bundledPacksDirectory) != nil
    else {
        return .failure(.packNotFound(packID))
    }

    let outcome = withNonBlockingLock(path: lockFile.path) {
        performSelectPack(packID, configFile: configFile)
    }

    switch outcome {
    case .ran(let result): return result
    case .skipped: return .failure(.lockBusy)
    case .failed(let errno): return .failure(.lockFailed(errno: errno))
    }
}

/// 走 ``updateConfigJSON(at:onMissing:mutate:)`` 这条共用的外科式读-改-写——与
/// `setEventEnabled` 的写路径**同一份实现**，不是两份各自推理出来的：两者编辑的是同一个文件，
/// 「保真」的定义必须只有一个。只 set `selected_pack`，`master_volume` / `events` / 未知顶层键
/// 逐字保留。
///
/// 这里同样**曾经**是 round-trip `ClaudioConfig`（Codable），带着和 `setEventEnabled` 一模一样
/// 的数据丢失 bug（只写三个键 + 宽松解码把坏值静默换成默认值），只是触发频率低——切包比点静音少。
/// 见 `ConfigMutation.swift` 的类型注释。
private func performSelectPack(
    _ packID: String, configFile: URL
) -> Result<UseOutcome, UseError> {
    // 全仓**唯一**有资格从无到有建出一份 config 的写者——因为它是唯一手上握着真实 pack id 的那个
    // （而且这个 id 上面刚刚校验过）。没有 pack 上下文的写者（静音钮、主音量）一律 `.failClosed`：
    // 凭空新建等于伪造一次谁也没做过的选择（D23 定稿①）。
    let result = updateConfigJSON(at: configFile, onMissing: .createFresh(selectedPack: packID)) {
        json in
        json["selected_pack"] = packID
    }

    switch result {
    case .success:
        return .success(.selected(packID: packID))
    case .failure(.unreadable(let reason)):
        return .failure(.configReadFailure(reason: reason))
    case .failure(.missing(let reason)):
        // 上面传的是 `.createFresh`，拒写只归 `.failClosed`，所以这一支不该出现。它存在是为了穷尽，
        // 不是为了给一句「不可能」背书：真出现了，如实报一句「config 读不到」也不会伪造任何东西。
        return .failure(.configReadFailure(reason: reason))
    case .failure(.writeFailed(let reason)):
        return .failure(.configWriteFailure(reason: reason))
    }
}
