import Foundation

// `claudio doctor`'s "版本兼容" check (ENGINEERING.md「其它折进计划」: "记录最低 macOS/Claude
// Code 版本 + 检测", T13). Two independent halves, both informational/warning-only:
//
//   (macOS)        Purely informational — see `VersionCompatibility.minimumMacOSVersion`'s
//                  doc comment for why the "below floor" branch is provably unreachable
//                  under this build's deployment target, and therefore never anything but
//                  `.ok`.
//   (Claude Code)  A REAL, actionable check: `claude --version` compared against
//                  `VersionCompatibility.minimumVerifiedClaudeCodeVersion`. Below it is a
//                  warning with a human explanation (StopFailure may not fire; the other
//                  three events are unaffected) — never a hard failure. Undetectable (not on
//                  PATH, non-zero exit, unparsable output, timeout) is *also* just a
//                  warning — `doctor` must never hang or hard-fail just because it couldn't
//                  ask `claude` about itself.

// MARK: - SemanticVersion

/// A minimal, dependency-free `major.minor.patch` value — built specifically to compare
/// `claude --version` output against
/// ``VersionCompatibility/minimumVerifiedClaudeCodeVersion``. This is NOT a full SemVer
/// implementation (no prerelease/build-metadata suffixes) — Claude Code's `--version`
/// output has never been observed to carry either (see ``parseClaudeCodeVersionOutput(_:)``
/// for the exact shape this parses).
public struct SemanticVersion: Sendable, Equatable, Comparable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// Parses a dot-separated numeric version string (`"2"`, `"2.1"`, `"2.1.201"`) into
    /// major/minor/patch, defaulting any component missing from the input to `0` — a
    /// deliberate, documented answer to "unequal component counts" (the task's own example):
    /// `"2.1"` and `"2.1.0"` parse to the exact same value and therefore compare EQUAL,
    /// never "incomparable" and never silently treated as older. Rejects anything that isn't
    /// 1–3 non-negative integer components — empty string, non-numeric text, a negative
    /// number, a trailing/doubled dot (which produces an empty component), or more than 3
    /// components all produce `nil`, never a partial/best-effort guess.
    public init?(parsing text: String) {
        let components = text.split(separator: ".", omittingEmptySubsequences: false)
            .map(String.init)
        guard !components.isEmpty, components.count <= 3 else { return nil }
        var parts: [Int] = []
        for component in components {
            guard let value = Int(component), value >= 0 else { return nil }
            parts.append(value)
        }
        while parts.count < 3 { parts.append(0) }
        major = parts[0]
        minor = parts[1]
        patch = parts[2]
    }

    public var description: String { "\(major).\(minor).\(patch)" }

    /// Numeric, component-wise comparison — NEVER string comparison. `"201" > "99"` is
    /// false lexically but `2.1.201 > 2.1.99` must be true numerically; Swift's tuple
    /// comparison already does exactly this, component-by-component, left to right.
    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

extension SemanticVersion {
    /// The macOS version this process is actually running on, via the real (non-injectable)
    /// `ProcessInfo.processInfo.operatingSystemVersion`. ``DoctorEnvironment/currentMacOSVersion``
    /// wraps this behind an injectable closure so tests can simulate any version without
    /// needing to actually run on that OS.
    public static func currentMacOS() -> SemanticVersion {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return SemanticVersion(
            major: version.majorVersion, minor: version.minorVersion,
            patch: version.patchVersion)
    }
}

// MARK: - Documented version floors (single source of truth)

/// Documented single source of truth for claudio's version-compatibility floors — every
/// place that needs "what's the minimum we support/verified" (doctor's checks below, and
/// their tests) reads these two constants rather than hardcoding a second copy of either
/// number.
public enum VersionCompatibility {
    /// Mirrors `helper/Package.swift`'s `platforms: [.macOS(.v12)]` — if that deployment
    /// target ever changes, this constant (and this comment) must change with it, and vice
    /// versa.
    ///
    /// **This floor is provably unreachable at runtime under the current deployment
    /// target**: dyld refuses to even load a binary built with `.macOS(.v12)` on an OS
    /// older than 12, so "current macOS < this constant" can never actually happen on a real
    /// machine running this binary. `macOSVersionDoctorResult(current:)` therefore reports
    /// this check as purely informational (always `.ok`) — never dressed up as a real gate.
    public static let minimumMacOSVersion = SemanticVersion(major: 12, minor: 0, patch: 0)

    /// The lowest Claude Code version claudio has actually been run against and confirmed to
    /// have a working `StopFailure` hook — a **verified lower bound**, not a claimed hard
    /// requirement. Evidence: spike 2026-07-06 (binary + official docs cross-checked on
    /// 2.1.201 — see `docs/spike-hooks.md` and ENGINEERING.md 决议 2) and reconfirmed
    /// 2026-07-10 on 2.1.206. Versions older than this are simply **unverified**, not
    /// confirmed broken — below it, `doctor` reports a warning, never a failure: StopFailure
    /// silently not firing is the documented graceful-degradation path (ENGINEERING.md 决议
    /// 2's "manifest 缺失事件→静默" fallback), and the other three events are unaffected
    /// either way.
    public static let minimumVerifiedClaudeCodeVersion = SemanticVersion(
        major: 2, minor: 1, patch: 201)
}

// MARK: - Injectable subprocess runner (mirrors `ProcessSpawning` in `Play.swift`)

/// Outcome of a single ``CommandRunning/run(executablePath:arguments:timeout:)`` call.
public enum CommandRunResult: Sendable, Equatable {
    /// The process ran to completion within the timeout.
    case completed(exitCode: Int32, stdout: String)
    /// The process did not exit within the given timeout — it was actively terminated
    /// (never left to run forever just because the caller gave up waiting).
    case timedOut
    /// `Process.run()` itself threw (executable missing/not executable/etc).
    case launchFailed
}

/// Runs a subprocess and captures its stdout + exit code, with a REAL enforced timeout —
/// injectable so tests never spawn a real `claude` process (see
/// `VersionCompatibilitySuite.swift`'s fakes) while ``SystemCommandRunner`` (the production
/// implementation) is itself tested against a real `sleep`-based subprocess to prove the
/// timeout actually terminates a hung child rather than merely hoping the command is fast.
public protocol CommandRunning: Sendable {
    func run(executablePath: String, arguments: [String], timeout: TimeInterval) -> CommandRunResult
}

/// Production ``CommandRunning``: launches via `Process`, reads stdout on a background queue
/// concurrently with waiting for exit (reading and waiting on the same thread would risk a
/// classic deadlock if a child ever wrote enough output to fill the pipe buffer before
/// exiting — irrelevant for `claude --version`'s tiny output today, but this must be correct
/// regardless), and actively terminates the child if `timeout` elapses first.
public struct SystemCommandRunner: CommandRunning {
    public init() {}

    public func run(
        executablePath: String, arguments: [String], timeout: TimeInterval
    ) -> CommandRunResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let outputPipe = Pipe()
        process.standardOutput = outputPipe

        let output = CommandOutputBox()
        let readQueue = DispatchQueue(label: "claudio.command-runner.stdout-read")
        readQueue.async {
            // Blocks until the child's end of the pipe closes (it exits, or is terminated
            // below) — never until `timeout`, since this runs on its own queue, not the one
            // `semaphore.wait(timeout:)` below blocks.
            let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
            output.set(data)
        }

        let semaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in semaphore.signal() }

        do {
            try process.run()
        } catch {
            // A successful `run()` hands the pipe's write end to the child and closes the
            // parent's own copy — that close is what later delivers EOF to the background
            // `readDataToEndOfFile()` above. When `run()` *throws* (the executable doesn't
            // exist — i.e. `claude` isn't on PATH, the single most likely real-world branch
            // here) no child ever existed, nothing closed the write end, and that reader
            // would block on it forever: one wedged thread plus both pipe fds, retained for
            // the calling process's whole lifetime. Harmless for a one-shot `claudio doctor`,
            // unbounded the moment a long-lived caller (the menu-bar app) reuses this.
            // Closing the write end here hands the reader its EOF so the thread unwinds.
            try? outputPipe.fileHandleForWriting.close()
            return .launchFailed
        }

        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            // Real enforcement, not "assume it's fast": actively stop the still-running
            // child rather than leaving it to run indefinitely in the background just
            // because we gave up waiting on it. Keep a (now no-op) terminationHandler
            // installed rather than `nil` — `Process` reaps the child via its
            // SIGCHLD-driven waiter only while a handler is installed (mirrors
            // `SystemProcessSpawner`'s identical reaping rationale in `Play.swift`); nil-ing
            // it out here would leak a zombie once the terminated child actually exits.
            process.terminationHandler = { _ in }
            if process.isRunning {
                process.terminate()
            }
            return .timedOut
        }

        // The process has exited, which closes its end of the pipe and unblocks the
        // background `readDataToEndOfFile()` above. `readQueue` is serial, so `sync {}`
        // submitted after that `.async` block only runs once it has finished — this is what
        // guarantees `output` is fully populated before it's read back below.
        readQueue.sync {}
        let stdout = String(data: output.data, encoding: .utf8) ?? ""
        return .completed(exitCode: process.terminationStatus, stdout: stdout)
    }
}

/// Thread-safe holder for `SystemCommandRunner`'s asynchronously-read stdout — written from
/// the background read queue, read back on the calling thread after `readQueue.sync {}`
/// establishes the happens-before ordering between them.
private final class CommandOutputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _data = Data()

    func set(_ newData: Data) {
        lock.lock()
        _data = newData
        lock.unlock()
    }

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return _data
    }
}

// MARK: - Claude Code version probe

/// Outcome of probing the installed Claude Code CLI's version against
/// ``VersionCompatibility/minimumVerifiedClaudeCodeVersion``. Every case maps to a
/// **warning at worst** in `doctor` — never a failure (see ``claudeCodeVersionDoctorResult``)
/// — the task's own anchor: "claude 命令不存在 / 输出无法解析 / 子进程超时 → 都是 warning, 且
/// 绝不能挂住 doctor".
public enum ClaudeCodeVersionStatus: Sendable, Equatable {
    /// Parsed successfully and meets or exceeds the verified floor.
    case verified(current: SemanticVersion)
    /// Parsed successfully but is below the verified floor.
    case belowVerifiedMinimum(current: SemanticVersion)
    /// `claude` isn't on PATH, exited non-zero, its stdout didn't parse as a version, or the
    /// probe timed out — every one of these collapses into the same "couldn't verify" case,
    /// since `doctor` reacts identically to all of them: one warning, carrying a
    /// human-readable reason, never blocking.
    case undetectable(reason: String)
}

/// Extracts the semantic version from a real `claude --version` invocation's stdout, whose
/// observed shape (verified on the real binary, 2026-07-06 + 2026-07-10) is
/// `"<semver> (Claude Code)"` — e.g. `"2.1.206 (Claude Code)"`. Takes the first
/// whitespace-delimited token and parses it as a ``SemanticVersion``; `nil` for anything
/// that doesn't fit (empty output, garbage, a version string outside the 1–3-component
/// numeric shape ``SemanticVersion/init(parsing:)`` accepts).
public func parseClaudeCodeVersionOutput(_ output: String) -> SemanticVersion? {
    let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let firstToken = trimmed.split(separator: " ", omittingEmptySubsequences: true).first
    else { return nil }
    return SemanticVersion(parsing: String(firstToken))
}

/// Probes the installed `claude` CLI's version via `/usr/bin/env claude --version` — routed
/// through `env` rather than a hardcoded absolute path so a normal `$PATH` lookup finds
/// whatever `claude` install the user actually has (`Process.executableURL` does NOT search
/// `$PATH` itself; `env`'s entire job is doing that lookup for us). If `claude` isn't on
/// PATH, `env` itself exits non-zero with nothing useful on stdout — already handled by the
/// `exitCode != 0` branch below, so a missing Claude Code install degrades exactly the same
/// way as every other "couldn't tell" case.
///
/// Never blocks longer than `timeout` — see ``CommandRunning`` and ``SystemCommandRunner``.
public func checkClaudeCodeVersion(
    commandRunner: any CommandRunning = SystemCommandRunner(),
    envPath: String = "/usr/bin/env",
    timeout: TimeInterval = 2.0
) -> ClaudeCodeVersionStatus {
    switch commandRunner.run(
        executablePath: envPath, arguments: ["claude", "--version"], timeout: timeout)
    {
    case .launchFailed:
        return .undetectable(reason: "无法启动版本探测进程（\(envPath) 不存在或不可执行）")
    case .timedOut:
        return .undetectable(
            reason: "claude --version 在 \(timeout)s 内未返回，可能是子进程挂起，已放弃等待")
    case .completed(let exitCode, let stdout):
        guard exitCode == 0 else {
            return .undetectable(
                reason: "claude 命令不存在或执行失败（退出码 \(exitCode)），可能尚未安装 Claude Code 或不在 PATH 中"
            )
        }
        guard let version = parseClaudeCodeVersionOutput(stdout) else {
            let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            return .undetectable(reason: "无法解析 claude --version 的输出：\"\(trimmed)\"")
        }
        if version < VersionCompatibility.minimumVerifiedClaudeCodeVersion {
            return .belowVerifiedMinimum(current: version)
        }
        return .verified(current: version)
    }
}

// MARK: - doctor-facing formatting

/// `doctor`'s macOS-version check result — ALWAYS `.ok`, unconditionally, regardless of how
/// `current` compares to the floor. See ``VersionCompatibility/minimumMacOSVersion``'s doc
/// comment for why "current < floor" is provably unreachable under this build's deployment
/// target (dyld itself refuses to load this binary below that floor) — per the task's own
/// anchor ("别假装它是一道真实防线"), a branch that can only be reached by artificially
/// injecting an impossible value (as a test double does) must not masquerade as a live
/// `.warning`; there is no real degraded state to report here, only current-version +
/// documented-floor information.
public func macOSVersionDoctorResult(
    current: SemanticVersion = .currentMacOS()
) -> DoctorCheckResult {
    let minimum = VersionCompatibility.minimumMacOSVersion
    guard current < minimum else {
        return DoctorCheckResult(
            name: "macos-version", severity: .ok,
            message: "✓ macOS \(current)（部署下限 \(minimum)，信息性上报——dyld 已保证此项恒成立，非真实防线）"
        )
    }
    return DoctorCheckResult(
        name: "macos-version", severity: .ok,
        message:
            "✓ macOS \(current)（低于部署下限 \(minimum)——真实机器上不可能发生，dyld 会拒绝加载此二进制；信息性上报，非真实防线）"
    )
}

/// `doctor`'s Claude Code version check result — never `.failure`; every branch of
/// ``ClaudeCodeVersionStatus`` maps to `.ok` or `.warning`.
public func claudeCodeVersionDoctorResult(
    commandRunner: any CommandRunning = SystemCommandRunner(),
    envPath: String = "/usr/bin/env",
    timeout: TimeInterval = 2.0
) -> DoctorCheckResult {
    let minimum = VersionCompatibility.minimumVerifiedClaudeCodeVersion
    switch checkClaudeCodeVersion(commandRunner: commandRunner, envPath: envPath, timeout: timeout)
    {
    case .verified(let current):
        return DoctorCheckResult(
            name: "claude-code-version", severity: .ok,
            message: "✓ Claude Code \(current)（已验证下限 \(minimum)）")
    case .belowVerifiedMinimum(let current):
        return DoctorCheckResult(
            name: "claude-code-version", severity: .warning,
            message:
                "⚠ Claude Code \(current) 低于已验证的最低版本 \(minimum)：StopFailure（中断了）音效可能不会触发；"
                + "Stop / Notification / SubagentStop 三个事件不受影响，仍会正常播放")
    case .undetectable(let reason):
        return DoctorCheckResult(
            name: "claude-code-version", severity: .warning,
            message: "⚠ 无法核实 Claude Code 版本：\(reason)")
    }
}
