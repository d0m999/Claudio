import Foundation

// `claudio play <event>` — hook entry (ENGINEERING.md 决议 1 + 5 +「工程落地细节 ④ 播放必须
// 异步，绝不卡住 Claude Code」, T5). 不是「决议 16」—— 权威决议表只到 6，16 出自修订记录
// 第 2 轮，那节明写「历史快照，勿据此实现」。
//
// A hook is a synchronous call in Claude Code's response path, so this whole chain must
// never block and never fail loudly: unknown event, muted event, incomplete/missing pack,
// or a contended debounce lock all resolve silently (no throw, no stderr) — only the
// caller (`claudio play`'s `run()`) decides to ignore the returned ``PlayOutcome``
// entirely and exit 0 regardless (ENGINEERING.md "绝不阻断 Claude Code").
//
// The critical section (resolve → spawn) runs under `play.lock`'s non-blocking
// `flock` (``withNonBlockingLock(path:_:)``, already implemented in `FileLock.swift`) —
// this is the "跳过式去抖" primitive: if another `claudio play` currently holds the lock,
// this call skips instantly rather than queuing or blocking.

// MARK: - Background process spawning (injectable for tests)

/// Starts a process in the background and returns immediately — never waits for it to
/// exit. Injectable so tests can verify `play` *attempted* the right spawn (executable +
/// arguments) without ever launching the real system `afplay` (see `PlaySuite.swift`).
/// Returns `true` iff the launch itself succeeded (`Process.run()` didn't throw) — this is
/// the one bit `playSoundEvent` needs to decide whether to append a `claudio.log` line
/// (T6); it does not, and cannot, reflect whether the spawned process later exits non-zero.
public protocol ProcessSpawning: Sendable {
    @discardableResult
    func spawn(executablePath: String, arguments: [String]) -> Bool
}

/// Production spawner: launches `executablePath` via `Process`, deliberately never
/// calling `waitUntilExit()` — `claudio play` must return to the hook caller immediately
/// while the audio keeps playing (ENGINEERING.md: "绝不阻断"从退出码语义扩展到时延).
public struct SystemProcessSpawner: ProcessSpawning {
    public init() {}

    @discardableResult
    public func spawn(executablePath: String, arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        // Detach stdio: the child must not inherit (and keep alive) claudio's own
        // stdin/stdout/stderr file descriptors after this short-lived process exits.
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        // Installing a termination handler (even a no-op one) makes `Process` reap the
        // child via its internal SIGCHLD-driven waiter once it exits. Without this, a
        // fire-and-forget launch that nobody `waitUntilExit()`s on would leave a zombie
        // once `afplay` finishes.
        process.terminationHandler = { _ in }
        // `afplay`/the executable may not exist, or launching may fail for any other
        // reason — never thrown onward (matching "缺音/缺 afplay → 静默不报错", T5 scope),
        // but the caller still learns whether the launch itself succeeded so it can log a
        // diagnostic line (T6) without ever turning this into a thrown error.
        return (try? process.run()) != nil
    }
}

// MARK: - Environment (injectable, mirrors `DoctorEnvironment`)

/// Everything `play` needs, injectable for tests so they never touch the real
/// `~/.claudio` config/packs or spawn the real system `afplay` (see `PlaySuite.swift`).
/// Defaults point at the real machine paths via ``ClaudioPaths``.
public struct PlayEnvironment: Sendable {
    public let afplayPath: String
    public let lockFile: URL
    public let configFile: URL
    public let userPacksDirectory: URL
    public let bundledPacksDirectory: URL?
    public let spawner: any ProcessSpawning
    /// Where the single shared "last played" timestamp lives (ENGINEERING.md 决议 5: "一把
    /// 锁 + 一个共享时间戳" — deliberately one event-agnostic timestamp, not a per-event
    /// map). Always read, compared, and overwritten from *inside* `play.lock`'s critical
    /// section in ``playSoundEvent(_:environment:)`` — never on its own, which would
    /// reopen the exact cross-process TOCTOU race decision 5 exists to close
    /// (ENGINEERING.md「工程落地细节 ⑤ 跨进程并发」: "否则多进程同时放行 = 去抖失效").
    public let debounceStateFile: URL
    /// Minimum spacing between two plays (any event — see ``debounceStateFile``) before
    /// the second is skipped as ``PlayOutcome/skippedRecentPlay(event:)``.
    /// ENGINEERING.md「并发 / 进程堆积处理」: 距上次播放（任意事件）< 1.5s 就跳过.
    public let debounceInterval: TimeInterval
    /// Modern `UserPromptSubmit` records its short debounce timestamp even when the first
    /// callback is muted or not ready, so duplicate host callbacks still collapse to one
    /// semantic task start. Legacy/lifecycle playback keeps the historical `false` behavior.
    public let debounceSilentOutcomes: Bool
    /// Injectable clock so tests can simulate elapsed time deterministically instead of
    /// real `Thread.sleep`s spanning the full debounce window.
    public let now: @Sendable () -> Date
    /// Where `playSoundEvent` appends a diagnostic line on a real failure (spawn failure,
    /// a broken `play.lock`) — see ``appendLogLine(event:reason:timestamp:to:lockFile:maxBytes:)``
    /// (ENGINEERING.md 决议 6, T6). Every other outcome (unknown/muted event, incomplete
    /// pack, debounce skip) stays silent by design; only the two "real error" branches log.
    public let logFile: URL
    /// The lock `appendLogLine` takes while rotating/appending to ``logFile``. Kept
    /// injectable here — rather than left to `appendLogLine`'s own default parameter —
    /// so tests that redirect `logFile` to a temp directory can never fall through to the
    /// real `ClaudioPaths.logLockFile` on the host machine.
    public let logLockFile: URL
    /// 新版双宿主 hook 的脱敏回执需要区分「已尝试且成功启动」与「启动失败」。legacy
    /// ``playSoundEvent`` 的公开 outcome 仍保持 `.played` 兼容语义；只有显式注入的观察者收到
    /// 这一位真实结果，且绝不接收音频路径、提示词或会话数据。
    public let spawnResultObserver: (@Sendable (Bool) -> Void)?

    public init(
        afplayPath: String = "/usr/bin/afplay",
        lockFile: URL = ClaudioPaths.playLockFile,
        configFile: URL = ClaudioPaths.configFile,
        userPacksDirectory: URL = ClaudioPaths.packsDirectory,
        bundledPacksDirectory: URL? = nil,
        spawner: any ProcessSpawning = SystemProcessSpawner(),
        debounceStateFile: URL = ClaudioPaths.debounceStateFile,
        debounceInterval: TimeInterval = 1.5,
        debounceSilentOutcomes: Bool = false,
        now: @escaping @Sendable () -> Date = { Date() },
        logFile: URL = ClaudioPaths.logFile,
        logLockFile: URL = ClaudioPaths.logLockFile,
        spawnResultObserver: (@Sendable (Bool) -> Void)? = nil
    ) {
        self.afplayPath = afplayPath
        self.lockFile = lockFile
        self.configFile = configFile
        self.userPacksDirectory = userPacksDirectory
        self.bundledPacksDirectory = bundledPacksDirectory
        self.spawner = spawner
        self.debounceStateFile = debounceStateFile
        self.debounceInterval = debounceInterval
        self.debounceSilentOutcomes = debounceSilentOutcomes
        self.now = now
        self.logFile = logFile
        self.logLockFile = logLockFile
        self.spawnResultObserver = spawnResultObserver
    }
}

// MARK: - Outcome

/// What happened for one `playSoundEvent` call. Every case except ``played`` and
/// ``lockFailed`` is an expected, silent "don't play" path — never a hard error
/// (ENGINEERING.md T5 scope: hook 调用绝不能因为用户未配置声音包而失败).
public enum PlayOutcome: Sendable, Equatable {
    /// The full chain resolved; a background spawn of `afplay filePath` was attempted.
    /// (The spawn itself may still silently fail inside `ProcessSpawning` — e.g. a
    /// missing `afplay` binary — but that failure is not observable here by design: T5
    /// scope stops at "attempted the spawn", real spawn-failure logging is T6.)
    case played(event: Event, filePath: String)
    /// `eventName` didn't match any of the five current events (`Event(cliName:)` → `nil`).
    case unknownEvent
    /// `ClaudioConfig.isEnabled(event) == false` — the user muted this event.
    case disabled(event: Event)
    /// Config missing/unreadable, pack unresolved, manifest unreadable/unmapped, or the
    /// declared audio file missing on disk — all silent "nothing to play yet" states
    /// (fresh install / incomplete pack), collapsed into one case because `play` reacts
    /// to every one of them identically: don't play, don't error.
    case notReady
    /// Another `claudio play` currently holds `play.lock` — the *lock-contention* skip
    /// path: two calls truly overlapped in time. This is a safety net for the rare
    /// literal race, not the debounce ENGINEERING.md「并发 / 进程堆积处理」asks for — see
    /// ``skippedRecentPlay(event:)`` for the actual "距上次播放 < N ms 就跳过" time window.
    case skippedDebounce
    /// The shared timestamp (``PlayEnvironment/debounceStateFile``) shows *some* event
    /// (any event — decision 5's timestamp is deliberately event-agnostic) played more
    /// recently than ``PlayEnvironment/debounceInterval`` ago. This is the actual
    /// time-based "跳过式去抖" ENGINEERING.md「并发 / 进程堆积处理」+ 决议 5 specify, distinct from the mere
    /// lock-contention race covered by ``skippedDebounce``.
    case skippedRecentPlay(event: Event)
    /// A real filesystem error (not lock contention) prevented acquiring `play.lock`.
    /// Deliberately a distinct case from ``skippedDebounce`` — collapsing the two would
    /// silently mask a broken filesystem as an ordinary debounce skip (mirrors
    /// `LockedRun`'s `.failed` vs `.skipped` distinction in `FileLock.swift`).
    case lockFailed(errno: Int32)
}

// MARK: - Entry point

/// `claudio play <event>`'s entire pipeline: parse the event → load config → check
/// per-event `enabled` → resolve the selected pack's manifest → resolve+validate the
/// declared audio file (via ``safePackFileURL(_:in:)``, the same adversarially-tested
/// containment check `doctor` uses — never a second, unaudited implementation) → run the
/// spawn under `play.lock`'s non-blocking debounce.
///
/// Never throws. Callers (the `claudio play` CLI subcommand) are expected to ignore the
/// returned outcome and exit 0 unconditionally — this return value exists for tests, not
/// for the hook caller to branch on. A real failure (spawn failure, a broken `play.lock`)
/// additionally appends one `claudio.log` line as a side effect before returning (T6); every
/// other outcome stays silent by design.
public func playSoundEvent(
    _ eventName: String,
    environment: PlayEnvironment = PlayEnvironment()
) -> PlayOutcome {
    guard let event = Event(cliName: eventName) else { return .unknownEvent }
    let preparation: PreparedPlay
    if let config = loadPlayConfig(from: environment.configFile) {
        if !config.isEnabled(event) {
            preparation = .silent(.disabled(event: event))
        } else if let audioFile = resolveAudioFile(
            for: event, config: config, environment: environment)
        {
            preparation = .ready(config: config, audioFile: audioFile)
        } else {
            preparation = .silent(.notReady)
        }
    } else {
        preparation = .silent(.notReady)
    }

    if case .silent(let outcome) = preparation,
        !environment.debounceSilentOutcomes
    {
        return outcome
    }

    return performDebouncedPlay(event: event, preparation: preparation, environment: environment)
}

private enum PreparedPlay {
    case ready(config: ClaudioConfig, audioFile: URL)
    case silent(PlayOutcome)
}

private func performDebouncedPlay(
    event: Event,
    preparation: PreparedPlay,
    environment: PlayEnvironment
) -> PlayOutcome {

    // The read-compare-write of the shared timestamp happens entirely inside
    // `play.lock`'s non-blocking critical section: `withNonBlockingLock` guarantees at
    // most one process's `body` is ever running at a time, so there is no TOCTOU window
    // between "read last-played" and "write now" across concurrent `claudio play`
    // processes (ENGINEERING.md「工程落地细节 ⑤ 跨进程并发」's exact race decision 5 calls out).
    let lockResult = withNonBlockingLock(path: environment.lockFile.path) { () -> PlayOutcome in
        let now = environment.now()
        if let lastPlayed = readLastPlayedTimestamp(from: environment.debounceStateFile),
            now.timeIntervalSince(lastPlayed) < environment.debounceInterval
        {
            return .skippedRecentPlay(event: event)
        }
        writeLastPlayedTimestamp(now, to: environment.debounceStateFile)
        if case .silent(let outcome) = preparation {
            return outcome
        }
        guard case .ready(let config, let audioFile) = preparation else {
            return .notReady
        }
        // `-v` and its value are two separate argv elements (never one concatenated
        // string) — `Process.arguments` passes each array element through as its own argv
        // entry, so `["-v value", path]` would make afplay see `-v value` as a single
        // malformed argument instead of a flag + its value (T9).
        let volumeArgument = AfplayVolume.afplayArgument(forMasterVolume: config.masterVolume)
        let spawned = environment.spawner.spawn(
            executablePath: environment.afplayPath,
            arguments: ["-v", volumeArgument, audioFile.path])
        environment.spawnResultObserver?(spawned)
        if !spawned {
            appendLogLine(
                event: event.cliName,
                reason: "afplay 启动失败：\(environment.afplayPath)",
                timestamp: now, to: environment.logFile, lockFile: environment.logLockFile)
        }
        return .played(event: event, filePath: audioFile.path)
    }

    switch lockResult {
    case .ran(let outcome):
        return outcome
    case .skipped:
        return .skippedDebounce
    case .failed(let code):
        appendLogLine(
            event: event.cliName,
            reason: "play.lock 获取失败（errno \(code)）",
            timestamp: environment.now(), to: environment.logFile, lockFile: environment.logLockFile)
        return .lockFailed(errno: code)
    }
}

/// Resolves `event`'s audio file inside the currently-selected pack, or `nil` if any step
/// of the chain (pack resolution → manifest → event mapping → containment → on-disk
/// existence) fails — every failure here is one more "not ready to play yet" case that
/// `playSoundEvent` reports as ``PlayOutcome/notReady``.
private func resolveAudioFile(
    for event: Event,
    config: ClaudioConfig,
    environment: PlayEnvironment
) -> URL? {
    guard
        let packDirectory = resolvePackDirectory(
            id: config.selectedPack,
            userPacksDirectory: environment.userPacksDirectory,
            bundledPacksDirectory: environment.bundledPacksDirectory),
        let manifest = loadPlayManifest(from: packDirectory),
        let relativeFile = manifest.events[event.manifestKey],
        let audioFile = safePackFileURL(relativeFile, in: packDirectory),
        // 必须是**正规文件**：一个名叫 `stop.mp3` 的目录 / FIFO 会让 `fileExists` 回答 `true`，
        // 于是 `play` 兴高采烈地去 spawn afplay，而事件触发时根本没有声音（`/codex review` [P2]）。
        // 见 ``regularFileExists(at:)``。
        regularFileExists(at: audioFile)
    else { return nil }
    return audioFile
}

/// Reads and decodes `configFile` via the shared ``loadClaudioConfig(from:)`` — 同一道
/// `O_NONBLOCK` + `fstat` 正规文件闸门、同一个 64 KiB 上限，与 `doctor` 和 `gui` 面板完全同源。
/// `nil` on any read/parse failure — `ClaudioConfig`'s own lenient decoder (see `ClaudioConfig.swift`)
/// already recovers from a malformed `master_volume`/`events`; only a missing `selected_pack` or
/// unreadable file lands here.
///
/// 这里原本是裸的 `Data(contentsOf:)`——和 ``loadPlayManifest(from:)`` 修掉的那份复制品一模一样的洞，
/// 只是漏在了 config 上（本轮 /ship 评审：Codex 对抗 + 红队 + Claude 对抗**三路独立命中**）。真实的
/// 危害是**读取无大小上限**：一个 500MB 形状的 `~/.claudio/config.json` 会在这条**同步 hook 路径**上被
/// 整份读进内存，而这条路径每一次 Claude Code 事件都要跑一遍。
///
/// （评审同时断言「FIFO 会让 `Data(contentsOf:)` 永久阻塞、挂死 hook」——**实测不成立**，Darwin 上它
/// 立刻抛 `EACCES`。同一个伪命题上一轮已经在 `manifest.json` 上被证伪过一次。正规文件闸门保留的理由
/// 是契约，不是「堵住今天的挂死」——详见 `SafeFileRead.swift` 的 ``readConfigFileBounded(at:)``。）
private func loadPlayConfig(from configFile: URL) -> ClaudioConfig? {
    loadClaudioConfig(from: configFile)
}

/// Reads and decodes `packDirectory`'s `manifest.json` via the shared ``loadPackManifest(in:)``
/// (T16 的单一 manifest 加载源) — 同一个 `isReallyContained` 符号链接逃逸闸门、同一个
/// `O_NOFOLLOW` + `fstat` 正规文件闸门、同一个 1 MiB 上限、同一次解码，与 `doctor` 完全同源。
///
/// 这里原本是第二份手写的 `Data(contentsOf:)` 读取——而 `play` 恰恰是最不能有第二份的地方：它跑在
/// Claude Code 的**同步 hook 路径**上（ENGINEERING.md「绝不阻断 Claude Code」），一个 500MB 形状的
/// `manifest.json` 会被它整份读进内存。删掉这份复制品之后，`play` 与 `doctor` 共享同一道闸门，且
/// 未来任何一次加固都自动同时覆盖两边。任何失败一律折叠成 `nil`，也就是 `playSoundEvent` 的
/// ``PlayOutcome/notReady``——静默不播，绝不报错（T5 契约不变）。
private func loadPlayManifest(from packDirectory: URL) -> PackManifest? {
    guard case .success(let manifest) = loadPackManifest(in: packDirectory) else { return nil }
    return manifest
}

// MARK: - Shared debounce timestamp (ENGINEERING.md「并发 / 进程堆积处理」+ 决议 5)

/// Reads the "last played" timestamp another (or this) `claudio play` process previously
/// wrote, or `nil` if the state file is missing/corrupt (fresh install, or the very first
/// play ever) — either way, `nil` means "never debounced yet", not an error.
///
/// Must only ever be called from inside `play.lock`'s critical section (see
/// ``playSoundEvent(_:environment:)``): the mutual exclusion `withNonBlockingLock`
/// guarantees is what makes this read-then-``writeLastPlayedTimestamp(_:to:)`` pair
/// TOCTOU-safe across processes, not anything about this function itself.
///
/// 有界读（同 ``loadPlayConfig(from:)``）：`play.state` 也躺在 `~/.claudio` 里，也在同步 hook 路径上，
/// 也一样不该被无上限地读。它装的是一个 epoch 秒数，几十个字节；`maxConfigFileBytes` 这道 64 KiB 上限
/// 对它宽得离谱，正好。任何拒读一律折成 `nil` = 「还没去抖过」，与原来的语义逐字相同。
private func readLastPlayedTimestamp(from stateFile: URL) -> Date? {
    guard case .success(let data) = readConfigFileBounded(at: stateFile),
        let text = String(data: data, encoding: .utf8),
        let epochSeconds = TimeInterval(text.trimmingCharacters(in: .whitespacesAndNewlines))
    else { return nil }
    return Date(timeIntervalSince1970: epochSeconds)
}

/// Persists `date` as the shared "last played" timestamp the next `claudio play`
/// invocation (this process or another) will compare itself against. Best-effort: a
/// write failure (e.g. `~/.claudio` deleted mid-run) is silently swallowed — the worst
/// consequence is the next call isn't debounced, which is strictly safer for a
/// synchronous hook than throwing or blocking (ENGINEERING.md "绝不阻断 Claude Code").
///
/// Must only ever be called from inside `play.lock`'s critical section — see
/// ``readLastPlayedTimestamp(from:)``.
private func writeLastPlayedTimestamp(_ date: Date, to stateFile: URL) {
    try? FileManager.default.createDirectory(
        at: stateFile.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? String(date.timeIntervalSince1970).write(to: stateFile, atomically: true, encoding: .utf8)
}
