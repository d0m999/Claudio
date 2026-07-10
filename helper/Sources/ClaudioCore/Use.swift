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
/// The read-modify-write runs under ``ClaudioPaths/lockFile``'s non-blocking `flock` —
/// the same lock `install`/`play` already serialize on — so two concurrent `claudio use`
/// (or `use` racing `setup`) invocations can't silently lose one write (Codex review of
/// 3d09bf5, confirmed again by `/ship`'s pre-landing review red team pass: unlike
/// `settings.json`'s write path, this one had never been brought under the lock). Because
/// the lock is non-blocking, contention surfaces as ``UseError/lockBusy`` — a real,
/// distinct error the caller sees and can retry — never a silent no-op reported as
/// success (project rule: never silently swallow an error).
public func selectPack(
    _ packID: String,
    configFile: URL = ClaudioPaths.configFile,
    userPacksDirectory: URL = ClaudioPaths.packsDirectory,
    bundledPacksDirectory: URL? = nil,
    lockFile: URL = ClaudioPaths.lockFile
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

private func performSelectPack(
    _ packID: String, configFile: URL
) -> Result<UseOutcome, UseError> {
    var config: ClaudioConfig
    if FileManager.default.fileExists(atPath: configFile.path) {
        guard let data = try? Data(contentsOf: configFile) else {
            return .failure(.configReadFailure(reason: "无法读取 \(configFile.path)"))
        }
        guard var existing = try? JSONDecoder().decode(ClaudioConfig.self, from: data) else {
            return .failure(.configReadFailure(reason: "\(configFile.path) 解析失败"))
        }
        existing.selectedPack = packID
        config = existing
    } else {
        config = ClaudioConfig(selectedPack: packID)
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

    return .success(.selected(packID: packID))
}
