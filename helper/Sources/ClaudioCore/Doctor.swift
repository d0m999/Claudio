import Foundation

// `claudio doctor` — three real self-checks (ENGINEERING.md v1 helper-CLI 契约):
//   (a) settings.json 可写   — read-only probe, NEVER writes.
//   (b) 包完整               — parse selected pack's manifest + verify declared audio
//                              files exist; missing config/pack/manifest are WARNINGS,
//                              not crashes (a fresh install has no pack yet).
//   (c) afplay 在位.
//   (d) claudio.log 尾部汇总 — read the last few `claudio.log` lines `play` appended on a
//                              real failure (spawn failure, broken `play.lock`); always a
//                              WARNING at worst (a missing/corrupt log is itself not a
//                              reason to hard-fail doctor), see T6.
//
// Hard failures (→ non-zero exit) are ONLY (a) and (c). Everything pack- and log-related is
// a warning in v1 doctor, per the orchestrator's scope note for T1/T6.

// MARK: - (a) settings.json writability probe

/// Result of probing whether `claudio install` would be able to write `settings.json`.
/// This is a **read-only** probe (`access(2)`/`isWritableFile`) — it never creates or
/// modifies any file.
public enum SettingsWritability: Sendable, Equatable {
    case writable
    case notWritable(reason: String)
}

/// Probes `settingsFile` for writability without touching disk:
/// - If the file exists, checks it directly.
/// - If it doesn't exist yet (common before the first `claudio install`), checks
///   whether its parent directory is writable (since `install` would need to create
///   it there).
public func probeSettingsWritable(settingsFile: URL) -> SettingsWritability {
    let fileManager = FileManager.default

    if fileManager.fileExists(atPath: settingsFile.path) {
        return fileManager.isWritableFile(atPath: settingsFile.path)
            ? .writable
            : .notWritable(reason: "settings.json 存在但不可写：\(settingsFile.path)")
    }

    let parentDirectory = settingsFile.deletingLastPathComponent()
    var parentIsDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: parentDirectory.path, isDirectory: &parentIsDirectory)
    else {
        return .notWritable(reason: "settings.json 所在目录不存在：\(parentDirectory.path)")
    }
    // A writable *file* where the parent directory should be still can't hold a new
    // `settings.json`, so `install` would fail — require an actual directory.
    guard parentIsDirectory.boolValue else {
        return .notWritable(reason: "settings.json 所在父路径不是目录：\(parentDirectory.path)")
    }
    return fileManager.isWritableFile(atPath: parentDirectory.path)
        ? .writable
        : .notWritable(reason: "settings.json 尚未创建，且所在目录不可写：\(parentDirectory.path)")
}

// MARK: - (b) pack integrity check

/// Outcome of checking whether the currently-selected sound pack is fully present.
/// Every case except ``complete`` maps to a **warning** in `doctor` (never a hard
/// failure) — see the module-level note above.
public enum PackIntegrityStatus: Sendable, Equatable {
    /// No `config.json` at all — a fresh install that hasn't run `claudio use` yet.
    case noConfig
    /// `config.json` exists but couldn't be read/parsed.
    case configUnreadable(reason: String)
    /// `config.json` parsed, but the selected pack doesn't exist in the user pack root
    /// or the bundled pack root.
    case packNotFound(packID: String)
    /// The pack directory exists, but its `manifest.json` couldn't be read/parsed.
    case manifestUnreadable(packID: String, reason: String)
    /// The manifest parsed, but one or more declared event audio files are missing.
    case incomplete(packID: String, missingFiles: [String])
    /// The manifest parsed and every declared event audio file exists.
    case complete(packID: String, events: [String])
}

/// Runs the full (b) pack-integrity check described above.
public func checkPackIntegrity(
    configFile: URL,
    userPacksDirectory: URL,
    bundledPacksDirectory: URL?
) -> PackIntegrityStatus {
    let fileManager = FileManager.default

    guard fileManager.fileExists(atPath: configFile.path) else { return .noConfig }
    guard let configData = try? Data(contentsOf: configFile) else {
        return .configUnreadable(reason: "config.json 无法读取：\(configFile.path)")
    }

    let config: ClaudioConfig
    do {
        config = try JSONDecoder().decode(ClaudioConfig.self, from: configData)
    } catch {
        return .configUnreadable(reason: "config.json 解析失败：\(error.localizedDescription)")
    }

    guard
        let packDirectory = resolvePackDirectory(
            id: config.selectedPack,
            userPacksDirectory: userPacksDirectory,
            bundledPacksDirectory: bundledPacksDirectory
        )
    else {
        return .packNotFound(packID: config.selectedPack)
    }

    let manifestFile = packDirectory.appendingPathComponent("manifest.json")
    // `packDirectory` itself is already symlink-safe (`resolvePackDirectory` runs
    // `isReallyContained`), but `manifest.json` is a leaf entry inside it and could
    // independently be a symlink escaping the pack directory — require real containment
    // here too, not just a successful read.
    guard isReallyContained(manifestFile, inside: packDirectory),
        let manifestData = try? Data(contentsOf: manifestFile)
    else {
        return .manifestUnreadable(
            packID: config.selectedPack, reason: "manifest.json 不存在或不可读：\(manifestFile.path)")
    }

    let manifest: PackManifest
    do {
        manifest = try JSONDecoder().decode(PackManifest.self, from: manifestData)
    } catch {
        return .manifestUnreadable(
            packID: config.selectedPack, reason: error.localizedDescription)
    }

    let missingFiles =
        manifest.events.values
        .filter { eventFile in
            // An event value must resolve to a file *inside* the pack directory. A
            // manifest that points at `../shared/stop.mp3` (a third-party pack escaping
            // its own directory) must be treated as missing, never as a satisfied file —
            // otherwise `doctor` would falsely report the pack `.complete` off an
            // out-of-pack file (T1 review P2).
            guard let resolved = safePackFileURL(eventFile, in: packDirectory) else { return true }
            return !fileManager.fileExists(atPath: resolved.path)
        }
        .sorted()

    if missingFiles.isEmpty {
        return .complete(packID: config.selectedPack, events: manifest.events.keys.sorted())
    }
    return .incomplete(packID: config.selectedPack, missingFiles: missingFiles)
}

/// Resolves `relativeFile` (a manifest event's audio filename) against `packDirectory`,
/// returning the URL only if it stays strictly inside `packDirectory`. Rejects empty,
/// absolute, NUL-bearing, and `../`-escaping paths by lexically standardizing the joined
/// URL and requiring the result to be contained by the pack root. Symlink escape is now
/// also rejected the same way as a `../` escape — treated as "missing", never satisfied
/// (T1 review P2, second pass).
///
/// `public` (promoted from module-internal by T8) so both in-module callers (`play`, T5,
/// `Play.swift`) and cross-module callers (`gui`'s `ClaudioGUICore`, T8's drag-in import
/// pipeline, which resolves a dropped file's destination filename against the target
/// user-pack directory) reuse this exact, adversarially-tested containment check —
/// rather than each reinventing its own, unaudited path-containment implementation
/// (ENGINEERING.md NOT-in-scope note on `safePackFileURL` visibility, and T8's explicit
/// "REUSE, do not reinvent" instruction). `gui` depends on `ClaudioCore` as a package
/// product (see `helper/Package.swift`), so only `public` symbols are visible to it —
/// module-internal was no longer sufficient once a second module needed this.
public func safePackFileURL(_ relativeFile: String, in packDirectory: URL) -> URL? {
    // Scalar-level checks (mirroring `isSafePackID`): a leading `/` fused with a combining
    // mark would slip a grapheme-level `hasPrefix("/")`. `isContained` already backstops
    // this, but keep the fast-path reject symmetric so a future refactor can't reopen it.
    if relativeFile.isEmpty || relativeFile.unicodeScalars.first == "/"
        || relativeFile.unicodeScalars.contains("\0")
    {
        return nil
    }
    let candidate = packDirectory.appendingPathComponent(relativeFile)
    guard isContained(candidate, inside: packDirectory),
        isReallyContained(candidate, inside: packDirectory)
    else {
        return nil
    }
    return candidate.standardizedFileURL
}

// MARK: - Combined report

public enum DoctorSeverity: String, Sendable, Equatable {
    case ok
    case warning
    case failure
}

public struct DoctorCheckResult: Sendable, Equatable {
    public let name: String
    public let severity: DoctorSeverity
    public let message: String
}

public struct DoctorReport: Sendable, Equatable {
    public let results: [DoctorCheckResult]

    /// `true` iff a **hard** problem was found (afplay missing / settings.json not
    /// writable) — the only cases where `claudio doctor` should exit non-zero.
    public var hasFailure: Bool {
        results.contains { $0.severity == .failure }
    }
}

/// Everything `doctor` needs, injectable for tests so they never touch the real
/// `~/.claudio` / `~/.claude` (see `DoctorSuite.swift`). Defaults point at the real
/// machine paths via ``ClaudioPaths``.
public struct DoctorEnvironment: Sendable {
    public let afplayPath: String
    public let settingsFile: URL
    public let configFile: URL
    public let userPacksDirectory: URL
    public let bundledPacksDirectory: URL?
    /// Where check (d) reads its tail from — see ``summarizeRecentLogFailures(logFile:maxEntries:)``.
    public let logFile: URL

    public init(
        afplayPath: String = "/usr/bin/afplay",
        settingsFile: URL = ClaudioPaths.claudeSettingsFile,
        configFile: URL = ClaudioPaths.configFile,
        userPacksDirectory: URL = ClaudioPaths.packsDirectory,
        bundledPacksDirectory: URL? = nil,
        logFile: URL = ClaudioPaths.logFile
    ) {
        self.afplayPath = afplayPath
        self.settingsFile = settingsFile
        self.configFile = configFile
        self.userPacksDirectory = userPacksDirectory
        self.bundledPacksDirectory = bundledPacksDirectory
        self.logFile = logFile
    }
}

/// Runs all three `doctor` self-checks and returns a combined, human-readable report.
public func runDoctorChecks(environment: DoctorEnvironment = DoctorEnvironment()) -> DoctorReport {
    var results: [DoctorCheckResult] = []

    // (c) afplay 在位 — hard failure if missing.
    if FileManager.default.isExecutableFile(atPath: environment.afplayPath) {
        results.append(
            DoctorCheckResult(
                name: "afplay", severity: .ok, message: "✓ afplay 在位：\(environment.afplayPath)")
        )
    } else {
        results.append(
            DoctorCheckResult(
                name: "afplay", severity: .failure,
                message: "✗ 未找到 afplay（\(environment.afplayPath)），无法播放")
        )
    }

    // (a) settings.json 可写 — hard failure if not (read-only probe, never writes).
    switch probeSettingsWritable(settingsFile: environment.settingsFile) {
    case .writable:
        results.append(
            DoctorCheckResult(
                name: "settings.json", severity: .ok,
                message: "✓ settings.json 可写：\(environment.settingsFile.path)")
        )
    case .notWritable(let reason):
        results.append(
            DoctorCheckResult(name: "settings.json", severity: .failure, message: "✗ \(reason)"))
    }

    // (b) 包完整 — always a warning at worst, never a hard failure in v1 doctor.
    let packStatus = checkPackIntegrity(
        configFile: environment.configFile,
        userPacksDirectory: environment.userPacksDirectory,
        bundledPacksDirectory: environment.bundledPacksDirectory
    )
    results.append(packStatus.doctorCheckResult)

    // (d) claudio.log 尾部汇总 — always a warning at worst, never a hard failure (T6).
    results.append(summarizeRecentLogFailures(logFile: environment.logFile))

    return DoctorReport(results: results)
}

/// Reads the last `maxEntries` `claudio.log` lines and summarizes them for `doctor`.
/// `.ok` when nothing has ever failed (the common case); `.warning` — never `.failure` — when
/// recent failures exist, since the log itself is diagnostic, not authoritative (ENGINEERING.md
/// 决议 6, T6).
public func summarizeRecentLogFailures(logFile: URL, maxEntries: Int = 5) -> DoctorCheckResult {
    let entries = readRecentLogEntries(from: logFile, maxLines: maxEntries)
    guard !entries.isEmpty else {
        return DoctorCheckResult(
            name: "log", severity: .ok, message: "✓ 最近无失败记录：\(logFile.path)")
    }

    let formatter = ISO8601DateFormatter()
    let summary = entries.map { entry in
        "\(formatter.string(from: entry.timestamp)) [\(entry.event)] \(entry.reason)"
    }.joined(separator: "; ")
    return DoctorCheckResult(
        name: "log", severity: .warning,
        message: "⚠ 最近 \(entries.count) 条失败记录：\(summary)")
}

extension PackIntegrityStatus {
    fileprivate var doctorCheckResult: DoctorCheckResult {
        switch self {
        case .noConfig:
            return DoctorCheckResult(
                name: "pack", severity: .warning,
                message: "⚠ 尚未选择声音包（全新安装，运行 `claudio use <pack-id>` 后可解决）")
        case .configUnreadable(let reason):
            return DoctorCheckResult(name: "pack", severity: .warning, message: "⚠ \(reason)")
        case .packNotFound(let packID):
            return DoctorCheckResult(
                name: "pack", severity: .warning,
                message: "⚠ 声音包 `\(packID)` 未找到（用户包与内置包均无）")
        case .manifestUnreadable(let packID, let reason):
            return DoctorCheckResult(
                name: "pack", severity: .warning,
                message: "⚠ 声音包 `\(packID)` 的 manifest.json 解析失败：\(reason)")
        case .incomplete(let packID, let missingFiles):
            return DoctorCheckResult(
                name: "pack", severity: .warning,
                message: "⚠ 声音包 `\(packID)` 缺少音频文件：\(missingFiles.joined(separator: ", "))")
        case .complete(let packID, let events):
            return DoctorCheckResult(
                name: "pack", severity: .ok,
                message: "✓ 声音包 `\(packID)` 完整（\(events.joined(separator: ", "))）")
        }
    }
}
