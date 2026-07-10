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
            // `Int("+2")` succeeds (== 2), so a bare `Int(_:)` would accept a leading `+` — a
            // "non-numeric" shape the doc above promises to reject. Require ASCII digits only
            // (also rejects a `-`, Unicode digits, and the empty component a doubled/trailing
            // dot produces) BEFORE parsing, so the contract and the code agree.
            guard component.unicodeScalars.allSatisfy({ ("0"..."9").contains($0) }),
                let value = Int(component)
            else { return nil }
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

/// Production ``CommandRunning``: launches via `Process`, drains stdout with a **deadline-
/// bounded `poll(2)` loop on the calling thread**, and actively terminates the child if
/// `timeout` elapses first.
///
/// **Why not a background `readDataToEndOfFile()` reader.** The obvious shape — spawn a queue
/// to read stdout, wait on the process's `terminationHandler` semaphore with the timeout, then
/// `readQueue.sync {}` to collect — is wrong in a way that only shows up off the happy path.
/// `readDataToEndOfFile()` returns at EOF, and EOF arrives only when **every** copy of the
/// pipe's write end is closed. A child that exits while leaving a grandchild holding its
/// stdout (`sh -c 'sleep 4 & echo hi'`, and any real command that daemonizes) satisfies the
/// termination semaphore immediately but never EOFs the pipe: the `readQueue.sync {}` after it
/// then waits **unbounded**, with the whole timeout budget already spent. Measured: 4.02s for
/// a 0.5s timeout. That silently breaks this type's one documented promise — and doctor's
/// anchor, "绝不能挂住" — for exactly the callers (`claude --version`, later the menu-bar
/// app's in-process reuse) it exists to protect. Draining with `poll(2)` against an absolute
/// deadline makes the timeout cover the read, not just the wait, and needs no second thread,
/// so it also retires the `.launchFailed` reader-leak this replaces rather than patching it.
public struct SystemCommandRunner: CommandRunning {
    /// Ceiling on retained stdout. `claude --version` emits ~22 bytes; a runaway child cannot
    /// grow this process's memory while we drain it to EOF. Bytes past the cap are read (so
    /// the child never blocks on a full pipe, and EOF still arrives) and dropped.
    private static let maximumOutputBytes = 1 << 20

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
        // The parent's read end is ours to close, on every exit path — `.completed`, `.timedOut`,
        // and the `catch` below alike. A `Pipe`'s `FileHandle`s do NOT close their descriptor when
        // the `Pipe` goes out of scope here (measured: one fd leaked per call, two per failed
        // launch), so without this each `run()` permanently costs a descriptor. `claudio doctor` is
        // one-shot and the OS reclaims them at exit, but this type is slated for in-process reuse
        // by the menu-bar app, where an unbounded leak would eventually exhaust the process's
        // descriptor table and fail every subsequent open — not just the next spawn.
        defer { try? outputPipe.fileHandleForReading.close() }

        // Installed before `run()` so no exit can be missed. Kept installed (never nil-ed) on
        // every path: `Process` reaps the child through its SIGCHLD-driven waiter only while a
        // handler is present, and dropping it would leave a zombie behind once a terminated
        // child actually exits (mirrors `SystemProcessSpawner`'s reaping rationale in
        // `Play.swift`).
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        do {
            try process.run()
        } catch {
            // No child was ever created, so BOTH ends are still ours. There is no reader thread to
            // unwind anymore (the drain below runs on this thread), but the descriptors do not free
            // themselves: the `defer` above closes the read end, and the write end — which a
            // successful `run()` would have closed on our behalf when it handed the child its copy
            // — has to be closed here, or a failed launch costs two descriptors instead of zero.
            try? outputPipe.fileHandleForWriting.close()
            return .launchFailed
        }

        // `Process.run()` has already closed the parent's copy of the write end, so the only
        // remaining holders are the child and anything it hands the descriptor to. EOF here
        // therefore means "nobody can write to us again" — the precondition for the exit wait
        // below to be short rather than open-ended.
        let deadline = Date().addingTimeInterval(timeout)
        let (stdout, sawEOF) = drainToEOF(outputPipe.fileHandleForReading, deadline: deadline)

        if !sawEOF {
            return terminate(process, returning: .timedOut)
        }
        let remaining = max(deadline.timeIntervalSinceNow, 0)
        guard exited.wait(timeout: .now() + remaining) == .success else {
            // stdout closed but the child is still running past the deadline.
            return terminate(process, returning: .timedOut)
        }
        return .completed(exitCode: process.terminationStatus, stdout: stdout)
    }

    /// Reads `handle` until EOF or `deadline`, whichever comes first. Returns what was read
    /// (capped at ``maximumOutputBytes``) and whether EOF was actually reached — a `false`
    /// there means some descriptor still holds the write end, and the caller must not wait on
    /// it any further.
    private func drainToEOF(_ handle: FileHandle, deadline: Date) -> (String, Bool) {
        let descriptor = handle.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL, 0)
        guard flags != -1, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) != -1 else {
            // Without O_NONBLOCK a `read` could block past the deadline; refuse to read at all
            // rather than risk the hang this whole design exists to prevent.
            return ("", false)
        }

        var collected = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)

        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return (decode(collected), false) }

            var descriptors = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            // `remaining > 0` guarantees this rounds up to at least 1ms, so `poll` always
            // sleeps rather than spinning; the 1s ceiling just bounds each slice so the
            // deadline is re-checked regularly.
            let milliseconds = Int32(min(remaining * 1000, 1000).rounded(.up))
            let ready = withUnsafeMutablePointer(to: &descriptors) { poll($0, 1, milliseconds) }
            let pollFailure = errno
            if ready < 0 {
                if pollFailure == EINTR { continue }
                return (decode(collected), false)
            }
            if ready == 0 { continue }  // slice expired; re-check the deadline

            // POLLHUP/POLLERR/POLLNVAL need no special case: each makes the `read` below
            // return 0 (EOF) or -1 with a terminal errno, both of which exit the loop.
            // `errno` is captured immediately, before `decode`/`append` can clobber it.
            let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
            let readFailure = errno
            if count > 0 {
                let headroom = Self.maximumOutputBytes - collected.count
                if headroom > 0 { collected.append(contentsOf: buffer[0..<min(count, headroom)]) }
                continue  // keep draining past the cap so the child never blocks and EOF arrives
            }
            if count == 0 { return (decode(collected), true) }  // EOF: no writer remains
            if readFailure == EINTR || readFailure == EAGAIN || readFailure == EWOULDBLOCK {
                continue
            }
            return (decode(collected), false)
        }
    }

    private func decode(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }

    /// Real enforcement, not "assume it's fast": actively stop a child we have stopped waiting
    /// on, rather than leaving it running in the background because we gave up.
    private func terminate(_ process: Process, returning result: CommandRunResult)
        -> CommandRunResult
    {
        if process.isRunning { process.terminate() }
        return result
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
