import Darwin
import Foundation

// `claudio doctor` — self-checks (ENGINEERING.md v1 helper-CLI 契约):
//   (a) settings.json 可写   — read-only probe, NEVER writes.
//   (b) 包完整               — parse selected pack's manifest + verify declared audio
//                              files exist; missing config/pack/manifest are WARNINGS,
//                              not crashes (a fresh install has no pack yet).
//   (c) afplay 在位.
//   (d) claudio.log 尾部汇总 — read the last few `claudio.log` lines `play` appended on a
//                              real失败 (spawn failure, broken `play.lock`); always a
//                              WARNING at worst (a missing/corrupt log is itself not a
//                              reason to hard-fail doctor), see T6.
//   (e) claudio 固定路径二进制在位 — settings.json 的 hooks 命令始终指向
//                              `ClaudioPaths.claudioBinary`（T17）；如果这条路径上什么都
//                              没有，每一次 Claude Code 事件都会静默失败，跟 (c) afplay
//                              缺失是同一严重程度，所以同样是硬失败（/ship pre-landing
//                              review 的对抗审查发现：`claudio setup` 有可能在这个路径还
//                              没真正落地二进制的情况下就把 hooks 装好——这个检查是那个
//                              bug 修好之后的第二道防线，用来在 bug 复发或用户手动删了
//                              二进制时也能被 `doctor` 抓到，而不是只能靠事件静默无声去猜）。
//   (f) 版本兼容（T13）       — macOS 版本对照部署下限，纯信息性上报（真实机器上不可达的
//                              分支，见 `VersionCompatibility.swift`）；Claude Code 版本
//                              对照「已验证下限」2.1.201，低于/无法探测都只是 warning，
//                              绝不硬失败、绝不挂住（子进程带真实超时）。
//   (g) config.json 可重写    — 只读探针（``probeConfigRewritable(configFile:)``），本轮评审新增。
//                              写路径（静音钮 / 切包）对畸形 config **fail closed**，而宽松读路径
//                              照常工作——于是一份 `{"events":{"stop":1}}` 的 config 会让 App 里
//                              所有写操作永久失败，声音却一切正常，用户完全看不出发生了什么，且
//                              `setup` 因为 config 已存在也不会重建它。doctor 的职责就是诊断：这条
//                              检查把那个隐形状态摆到台面上，并直接给出可执行的修复指令。
//
// Legacy（未注入 integrations）hard failures 仍是 (a)、(c)、(e)。双宿主 doctor 另外把
// ``SystemSharedRuntimeBootstrapper.inspect`` 的 unavailable/damaged 判成 hard failure；原始 pack 行仍
// 保留细节 warning，但不能再让一个不可播放的共享 runtime 以退出码 0 假绿。log、版本兼容与
// config-rewritability 仍只是 warning。(g) 刻意也是 warning 而不是
// failure：一份畸形 config **不影响播放**（读路径宽松，hook 照响），坏的只是 App 内的写操作——把它
// 报成 failure 会让「声音一切正常」的机器 doctor 非零退出，与 (a)/(c)/(e)「claudio 根本工作不了」
// 不是同一量级。

// MARK: - (a) settings.json writability probe

/// Result of probing whether `claudio install` would be able to write `settings.json`.
/// This is a **read-only** probe (`access(2)`/`isWritableFile`) — it never creates or
/// modifies any file.
public enum SettingsWritability: Sendable, Equatable {
    case writable
    case notWritable(reason: String)
}

/// Probes `settingsFile` for writability without touching disk:
/// Atomic publication always creates a sibling staging file and renames it over the destination.
/// Therefore both an existing file and a first write require a writable/searchable destination
/// directory; checking only the existing inode produces a false-green state that cannot be repaired.
public func probeSettingsWritable(settingsFile: URL) -> SettingsWritability {
    let fileManager = FileManager.default
    let fileExists = fileManager.fileExists(atPath: settingsFile.path)

    if fileExists, !fileManager.isWritableFile(atPath: settingsFile.path) {
        return .notWritable(reason: "settings.json 存在但不可写：\(settingsFile.path)")
    }

    // A valid final symlink is published through its resolved target directory. For a missing
    // path (including legacy callers' dangling-link behavior), resolving still canonicalizes any
    // parent symlinks without inventing a target.
    let publicationFile = settingsFile.resolvingSymlinksInPath().standardizedFileURL
    let parentDirectory = publicationFile.deletingLastPathComponent()
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
    let canPublish = parentDirectory.withUnsafeFileSystemRepresentation { path -> Bool in
        guard let path else { return false }
        return Darwin.access(path, W_OK | X_OK) == 0
    }
    guard canPublish else {
        let operation = fileExists ? "无法在所在目录原子替换" : "尚未创建，且所在目录不可写"
        return .notWritable(reason: "settings.json \(operation)：\(parentDirectory.path)")
    }
    return .writable
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
    // 有界 + 正规文件闸门（``readConfigFileBounded(at:)``），不是裸的 `Data(contentsOf:)`：一个目录 /
    // FIFO 形状的 config.json 会让后者挂住或读出垃圾，而 `doctor` 恰恰是用户拿来诊断这种局面的工具，
    // 它自己绝不能先挂在上面。与 `play` / `gui` 面板同一道门（本轮 /ship 评审）。
    guard case .success(let configData) = readConfigFileBounded(at: configFile) else {
        return .configUnreadable(
            reason: "config.json 无法读取：\(configFile.path)"
                + "（须是不大于 \(maxConfigFileBytes) 字节的普通文件）")
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

    // Delegates to the shared ``loadPackManifest(in:)`` (T16: single manifest-loading
    // source of truth for `helper` and `gui`) — same `isReallyContained` symlink-escape
    // guard, same read, same decode, same error messages as before this was extracted.
    let manifest: PackManifest
    switch loadPackManifest(in: packDirectory) {
    case .success(let loaded):
        manifest = loaded
    case .failure(let error):
        return .manifestUnreadable(packID: config.selectedPack, reason: error.reason)
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
            // 必须是**正规文件**，不能只是「路径上有东西」：`fileExists(atPath:)` 对一个名叫
            // `stop.mp3` 的**目录**（以及 FIFO / socket / 设备）一律回答 `true`，于是 doctor 会把
            // 一个根本发不出声的包报成 complete（`/codex review` [P2]）。见 ``regularFileExists(at:)``。
            return !regularFileExists(at: resolved)
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

    /// `true` iff a **hard** problem was found；双宿主模式还包括共享 runtime 不可用与
    /// 已连接宿主的配置/可写性损坏。
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
    /// Check (e)'s target — the fixed-path helper binary settings.json's hooks actually
    /// invoke. Defaults to ``ClaudioPaths/claudioBinary``, injectable so tests never touch
    /// the real path.
    public let claudioBinaryPath: String
    /// Check (f)'s Claude Code half — injectable subprocess runner, defaulting to the real,
    /// subprocess-spawning ``SystemCommandRunner``. Tests inject a fake ``CommandRunning``
    /// double (see `VersionCompatibilitySuite.swift`) so no test ever spawns a real `claude`
    /// process or depends on whether/which version is installed on the machine running the
    /// tests.
    public let commandRunner: any CommandRunning
    /// How long check (f) waits for `claude --version` before giving up — never blocks
    /// longer (see ``checkClaudeCodeVersion(commandRunner:envPath:timeout:)``).
    public let claudeVersionTimeout: TimeInterval
    /// Injectable "what macOS version are we on" for check (f)'s macOS half — tests
    /// simulate both above- and below-floor versions without needing to run on that actual
    /// OS. Defaults to the real ``SemanticVersion/currentMacOS()``.
    public let currentMacOSVersion: @Sendable () -> SemanticVersion
    /// 双宿主检查为显式注入，保证旧测试与嵌入方不会意外读取真实 HOME。CLI 的 production
    /// 入口传 ``DoctorIntegrationsEnvironment`` 默认值，自动覆盖 Claude Code 与 Codex。
    public let integrations: DoctorIntegrationsEnvironment?

    public init(
        afplayPath: String = "/usr/bin/afplay",
        settingsFile: URL = ClaudioPaths.claudeSettingsFile,
        configFile: URL = ClaudioPaths.configFile,
        userPacksDirectory: URL = ClaudioPaths.packsDirectory,
        bundledPacksDirectory: URL? = nil,
        logFile: URL = ClaudioPaths.logFile,
        claudioBinaryPath: String = ClaudioPaths.claudioBinary.path,
        commandRunner: any CommandRunning = SystemCommandRunner(),
        claudeVersionTimeout: TimeInterval = 2.0,
        currentMacOSVersion: @escaping @Sendable () -> SemanticVersion = { .currentMacOS() },
        integrations: DoctorIntegrationsEnvironment? = nil
    ) {
        self.afplayPath = afplayPath
        self.settingsFile = settingsFile
        self.configFile = configFile
        self.userPacksDirectory = userPacksDirectory
        self.bundledPacksDirectory = bundledPacksDirectory
        self.logFile = logFile
        self.claudioBinaryPath = claudioBinaryPath
        self.commandRunner = commandRunner
        self.claudeVersionTimeout = claudeVersionTimeout
        self.currentMacOSVersion = currentMacOSVersion
        self.integrations = integrations
    }
}

public struct DoctorIntegrationsEnvironment: Sendable {
    public let claudeSettingsFile: URL
    public let codexHooksFile: URL
    public let codexConfigFile: URL
    public let legacyCodexNotifyWrapper: URL
    public let claudioRoot: String
    public let claudioBinaryPath: String
    public let receiptStore: HostHookReceiptStore
    public let claudeAvailability: @Sendable () -> HostAvailability
    public let codexAvailability: @Sendable () -> HostAvailability

    public init(
        claudeSettingsFile: URL = ClaudioPaths.claudeSettingsFile,
        codexHooksFile: URL = ClaudioPaths.codexHooksFile,
        codexConfigFile: URL? = nil,
        legacyCodexNotifyWrapper: URL? = nil,
        claudioRoot: String = ClaudioPaths.root.path,
        claudioBinaryPath: String? = nil,
        receiptStore: HostHookReceiptStore = HostHookReceiptStore(
            receiptsRoot: ClaudioPaths.receiptsDirectory,
            locksRoot: ClaudioPaths.receiptLocksDirectory,
            installationsRoot: ClaudioPaths.activeInstallationsDirectory,
            installationLocksRoot: ClaudioPaths.activeInstallationLocksDirectory),
        claudeAvailability: @escaping @Sendable () -> HostAvailability = {
            let directory = ClaudioPaths.claudeSettingsFile.deletingLastPathComponent()
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(
                atPath: directory.path, isDirectory: &isDirectory) && isDirectory.boolValue
                ? .available : .unavailable(reason: "未检测到 Claude Code 配置目录")
        },
        codexAvailability: @escaping @Sendable () -> HostAvailability = {
            let directory = ClaudioPaths.codexHooksFile.deletingLastPathComponent()
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(
                atPath: directory.path, isDirectory: &isDirectory) && isDirectory.boolValue
                ? .available : .unavailable(reason: "未检测到 Codex 配置目录")
        }
    ) {
        self.claudeSettingsFile = claudeSettingsFile
        self.codexHooksFile = codexHooksFile
        self.codexConfigFile = codexConfigFile
            ?? codexHooksFile.deletingLastPathComponent().appendingPathComponent("config.toml")
        self.legacyCodexNotifyWrapper = legacyCodexNotifyWrapper
            ?? URL(fileURLWithPath: claudioRoot, isDirectory: true)
                .appendingPathComponent("bin/codex-notify")
        self.claudioRoot = claudioRoot
        self.claudioBinaryPath = claudioBinaryPath
            ?? URL(fileURLWithPath: claudioRoot, isDirectory: true)
                .appendingPathComponent("bin/claudio").path
        self.receiptStore = receiptStore
        self.claudeAvailability = claudeAvailability
        self.codexAvailability = codexAvailability
    }
}

/// Runs the complete `doctor` self-check set and returns a combined, human-readable report.
public func runDoctorChecks(environment: DoctorEnvironment = DoctorEnvironment()) -> DoctorReport {
    var results: [DoctorCheckResult] = []
    let sharedRuntime: SharedRuntimeHealth? = environment.integrations.map { _ in
        SystemSharedRuntimeBootstrapper(
            environment: SetupEnvironment(
                executablePath: URL(fileURLWithPath: environment.claudioBinaryPath),
                claudioBinaryDestination: URL(
                    fileURLWithPath: environment.claudioBinaryPath),
                userPacksDirectory: environment.userPacksDirectory,
                configFile: environment.configFile,
                settingsFile: environment.settingsFile))
            .inspect()
    }

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

    // (e) 固定 helper 必须是非空、可执行、无 quarantine 的普通文件；与 manager 复用同一判据。
    switch inspectSharedRuntimeHelper(
        at: URL(fileURLWithPath: environment.claudioBinaryPath))
    {
    case .unavailable(let reason), .damaged(let reason):
        results.append(
            DoctorCheckResult(
                name: "claudio-binary", severity: .failure,
                message: "✗ \(reason)，hooks 会静默失效——从 claudi0.app 重跑一次 claudi0 setup"
            )
        )
    case .ready:
        results.append(
            DoctorCheckResult(
                name: "claudio-binary", severity: .ok,
                message: "✓ claudio 二进制在位：\(environment.claudioBinaryPath)")
        )
    }

    // 兼容嵌入方未启用双宿主报告时的 v1 检查。新版 CLI 已注入 integrations，写入能力
    // 必须按宿主分别判定：未安装/未连接的一侧只是 warning，不能再被旧 Claude-only
    // settings.json 检查提升成整个 doctor 的 hard failure。
    if environment.integrations == nil {
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
    }

    // (b) 包完整 — always a warning at worst, never a hard failure in v1 doctor.
    let packStatus = checkPackIntegrity(
        configFile: environment.configFile,
        userPacksDirectory: environment.userPacksDirectory,
        bundledPacksDirectory: environment.bundledPacksDirectory
    )
    results.append(packStatus.doctorCheckResult)

    if let sharedRuntime {
        results.append(sharedRuntimeDoctorResult(sharedRuntime))
    }

    // (g) config.json 可重写 — always a warning at worst (see the module note above).
    results.append(configRewritabilityResult(configFile: environment.configFile))

    // (d) claudio.log 尾部汇总 — always a warning at worst, never a hard failure (T6).
    results.append(summarizeRecentLogFailures(logFile: environment.logFile))

    // (f) 版本兼容（T13）— macOS 半信息性上报（永远 .ok），Claude Code 半对照已验证下限，
    // 低于/无法探测都只是 warning，从不 failure。见 `VersionCompatibility.swift`。
    results.append(macOSVersionDoctorResult(current: environment.currentMacOSVersion()))
    results.append(
        claudeCodeVersionDoctorResult(
            commandRunner: environment.commandRunner, timeout: environment.claudeVersionTimeout))

    if let integrations = environment.integrations {
        results.append(
            contentsOf: hostIntegrationDoctorResults(
                environment: integrations,
                runtime: sharedRuntime ?? .unavailable(reason: "共享 runtime 未检测")))
    }

    return DoctorReport(results: results)
}

/// 双宿主 doctor 事实层。未安装/未连接、健康 runtime 上的 legacy/待确认是 warning；完整连接是 ok；
/// 已连接侧的配置损坏、缺 hook、不可写或共享 runtime 不可用是 failure。始终返回两条宿主行。
public func hostIntegrationDoctorResults(
    environment: DoctorIntegrationsEnvironment,
    runtime: SharedRuntimeHealth = .ready
) -> [DoctorCheckResult] {
    // doctor 只负责把 adapter 快照翻译成人类可读的严重度；配置、legacy wrapper 与
    // 当前 installation 回执的判定全部复用 adapter 的同一事实入口。
    let claude = inspectClaudeSnapshot(
        environment: ClaudeCodeIntegrationEnvironment(
            settingsFile: environment.claudeSettingsFile,
            claudioBinaryPath: environment.claudioBinaryPath,
            claudioRoot: environment.claudioRoot,
            receiptStore: environment.receiptStore,
            availability: environment.claudeAvailability),
        runtime: runtime)
    let codex = inspectCodexSnapshot(
        environment: CodexIntegrationEnvironment(
            hooksFile: environment.codexHooksFile,
            configFile: environment.codexConfigFile,
            legacyNotifyWrapper: environment.legacyCodexNotifyWrapper,
            claudioBinaryPath: environment.claudioBinaryPath,
            claudioRoot: environment.claudioRoot,
            receiptStore: environment.receiptStore,
            availability: environment.codexAvailability),
        runtime: runtime)
    return [
        doctorHostResult(snapshot: claude),
        doctorHostResult(snapshot: codex),
    ]
}

private func sharedRuntimeDoctorResult(
    _ runtime: SharedRuntimeHealth
) -> DoctorCheckResult {
    switch runtime {
    case .ready:
        return DoctorCheckResult(
            name: "shared-runtime",
            severity: .ok,
            message: "✓ 共享 runtime 已就绪")
    case .unavailable(let reason), .damaged(let reason):
        return DoctorCheckResult(
            name: "shared-runtime",
            severity: .failure,
            message: "✗ 共享 runtime 不可用：\(reason)")
    }
}

private func sharedRuntimeFailureReason(
    _ runtime: SharedRuntimeHealth
) -> String? {
    switch runtime {
    case .ready: nil
    case .unavailable(let reason), .damaged(let reason): reason
    }
}

private func doctorHostResult(
    snapshot: HostIntegrationSnapshot
) -> DoctorCheckResult {
    let host = snapshot.host
    let configuration = snapshot.configuration
    let name = "host-\(host.rawValue)"
    if case .unavailable(let reason) = snapshot.availability, configuration == .notConfigured {
        return DoctorCheckResult(
            name: name, severity: .warning,
            message: "⚠ \(host.displayName) 未安装或不可用：\(reason)")
    }
    if case .unavailable(let reason) = snapshot.availability {
        return DoctorCheckResult(
            name: name, severity: .failure,
            message: "✗ \(host.displayName) 已有 claudi0 连接但宿主不可用：\(reason)")
    }
    let writable: Bool
    let writableReason: String?
    switch snapshot.writability {
    case .writable:
        writable = true
        writableReason = nil
    case .notWritable(let reason):
        writable = false
        writableReason = reason
    case .unknown:
        writable = false
        writableReason = "宿主配置路径尚不可用"
    }

    switch configuration {
    case .notConfigured:
        return DoctorCheckResult(
            name: name, severity: .warning,
            message: writable
                ? "⚠ \(host.displayName) 未连接"
                : "⚠ \(host.displayName) 未连接；当前也无法写入配置：\(writableReason ?? "未知原因")")
    case .legacyConnected:
        guard writable else {
            return DoctorCheckResult(
                name: name, severity: .failure,
                message: "✗ \(host.displayName) 旧版连接仍在但配置不可写：\(writableReason ?? "未知原因")")
        }
        if let reason = sharedRuntimeFailureReason(snapshot.runtime) {
            return DoctorCheckResult(
                name: name, severity: .failure,
                message: "✗ \(host.displayName) 已连接但共享 runtime 不可用：\(reason)")
        }
        return DoctorCheckResult(
            name: name, severity: .warning,
            message: "⚠ \(host.displayName) 是旧版连接：可听，但暂无真实回执；可显式升级连接")
    case .incomplete(let missing):
        return DoctorCheckResult(
            name: name, severity: .failure,
            message: "✗ \(host.displayName) 已有 claudi0 配置但缺少 hook：\(missing.joined(separator: ", "))")
    case .unreadable(let reason), .conflict(let reason):
        return DoctorCheckResult(
            name: name, severity: .failure,
            message: "✗ \(host.displayName) 配置损坏或冲突：\(reason)")
    case .configured:
        if let reason = sharedRuntimeFailureReason(snapshot.runtime) {
            return DoctorCheckResult(
                name: name, severity: .failure,
                message: "✗ \(host.displayName) 已连接但共享 runtime 不可用：\(reason)")
        }
        guard writable else {
            return DoctorCheckResult(
                name: name, severity: .failure,
                message: "✗ \(host.displayName) 已连接但配置不可写：\(writableReason ?? "未知原因")")
        }
        guard snapshot.installationID != nil else {
            return DoctorCheckResult(
                name: name, severity: .failure,
                message: "✗ \(host.displayName) 已配置但缺少 installation ID")
        }
        guard case .observed = snapshot.activation else {
            return DoctorCheckResult(
                name: name, severity: .warning,
                message: host == .codex
                    ? "⚠ Codex：在 Codex 输入 /hooks，确认后再提交一次提示词"
                    : "⚠ Claude Code 已配置，请提交一次提示词以确认连接")
        }
        let supported = HostCapabilityCatalog.bindings(for: host).filter(\.isAudibleCapability).count
        let qualifier = host == .codex ? "；执行中断暂无事件，待响应仅授权请求" : ""
        return DoctorCheckResult(
            name: name, severity: .ok,
            message: "✓ \(host.displayName) \(supported)/\(Event.allCases.count) 已就绪\(qualifier)")
    }
}


/// (g) 把 ``probeConfigRewritable(configFile:)`` 的判定讲成 `doctor` 的一行话。
///
/// 这是 fail-closed 写路径唯一的**可见性**出口：畸形 config 不影响播放（读路径宽松），所以用户唯一
/// 的信号就是「点静音没反应」——除非 doctor 主动把它说出来，并把 `probeConfigRewritable` 已经带上的
/// **可执行修复指令**（哪个键、必须是什么、当前是什么、怎么修）原样透出来。刻意 `.warning` 而非
/// `.failure`：见文件头 (g) 的严重级说明。
public func configRewritabilityResult(configFile: URL) -> DoctorCheckResult {
    switch probeConfigRewritable(configFile: configFile) {
    case .absent:
        // ⚠️ 这句话曾经写的是「首次选包 / **静音**时会自动创建」，而它在 D23 定稿①（`573336d`）那一刻
        // 就地变成了假的：`setEventEnabled` 从那一刻起对缺失的 config **fail closed**（`.configMissing`），
        // 静音再也不会创建它了。改了行为、没改文案 —— 而 doctor 是「静默失败必须有诊断轨迹」（决议 6）的
        // 唯一出口，一个说假话的 doctor 诊断的就不是这台机器。（`/codex review 573336d` [P2]。）
        //
        // 现在**唯一**能从无到有建出 config.json 的写者是 `selectPack`（`claudio use` / 面板选包 /
        // 首次自举），这一点由 `ConfigMutation.MissingConfigPolicy` 在**类型层面**保证。这句文案由
        // `DoctorSuite` 钉着：它不许再宣称静音能创建 config。
        return DoctorCheckResult(
            name: "config", severity: .ok,
            message: "✓ 尚无 config.json（全新安装，首次选包时创建）")
    case .rewritable:
        return DoctorCheckResult(
            name: "config", severity: .ok, message: "✓ config.json 可安全重写：\(configFile.path)")
    case .malformed(let reason):
        return DoctorCheckResult(
            name: "config", severity: .warning,
            message: "⚠ config.json 畸形：App 内的静音 / 切包会一直失败（播放不受影响）。\(reason)")
    case .unwritable(let reason):
        // 与 .malformed 同为 .warning、同样不影响播放，但讲的是另一件事：文件没错，是目录不让写。
        return DoctorCheckResult(
            name: "config", severity: .warning,
            message: "⚠ config.json 写不进去：App 内的静音 / 切包会一直失败（播放不受影响）。\(reason)")
    }
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
                message: "⚠ 尚未选择声音包（全新安装，运行 `~/.claudio/bin/claudi0 use <pack-id>` 后可解决）")
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
            let message: String
            if events.isEmpty {
                message = "✓ 声音包 `\(packID)` 未声明事件；无需检查音频文件"
            } else {
                message = "✓ 声音包 `\(packID)` 完整（\(events.joined(separator: ", "))）"
            }
            return DoctorCheckResult(
                name: "pack", severity: .ok,
                message: message)
        }
    }
}
