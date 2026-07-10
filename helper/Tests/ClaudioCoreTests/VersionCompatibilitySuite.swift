import ClaudioCore
import Foundation

// MARK: - 版本兼容 (T13): SemanticVersion parsing/comparison + checkClaudeCodeVersion +
// SystemCommandRunner's REAL enforced timeout. Doctor-level integration tests (the two
// checks folded into `runDoctorChecks`) live in `DoctorSuite.swift`, right next to the rest
// of the doctor report tests they extend.

/// A canned ``CommandRunning`` double — every `checkClaudeCodeVersion` test below injects
/// one of these so NO test in this file ever spawns a real subprocess or depends on
/// whether/which `claude` happens to be installed on the machine running the tests. The
/// only tests that spawn anything real are ``SystemCommandRunner``'s own (at the bottom),
/// which deliberately exercise the production implementation end-to-end.
private struct FakeCommandRunner: CommandRunning {
    let result: CommandRunResult
    func run(executablePath: String, arguments: [String], timeout: TimeInterval) -> CommandRunResult
    {
        result
    }
}

@MainActor
func runVersionCompatibilitySuites() {
    // MARK: SemanticVersion parsing

    suite("SemanticVersion.init(parsing:) parses full major.minor.patch") {
        expect(
            SemanticVersion(parsing: "2.1.201") == SemanticVersion(major: 2, minor: 1, patch: 201),
            "\"2.1.201\" should parse to (2, 1, 201)")
    }

    suite(
        "SemanticVersion.init(parsing:) zero-pads missing components — \"2.1\" == \"2.1.0\","
            + " a defined, non-ambiguous behavior for unequal component counts"
    ) {
        expect(
            SemanticVersion(parsing: "2.1") == SemanticVersion(major: 2, minor: 1, patch: 0),
            "\"2.1\" should parse as (2, 1, 0)")
        expect(
            SemanticVersion(parsing: "2") == SemanticVersion(major: 2, minor: 0, patch: 0),
            "\"2\" should parse as (2, 0, 0)")
        expect(
            SemanticVersion(parsing: "2.1") == SemanticVersion(parsing: "2.1.0"),
            "\"2.1\" and \"2.1.0\" must parse to the exact same, EQUAL value")
    }

    suite("SemanticVersion.init(parsing:) rejects malformed input, never a partial guess") {
        expect(SemanticVersion(parsing: "") == nil, "empty string must fail to parse")
        expect(SemanticVersion(parsing: "abc") == nil, "non-numeric text must fail to parse")
        expect(SemanticVersion(parsing: "2.-1.0") == nil, "a negative component must fail to parse")
        expect(SemanticVersion(parsing: "2..1") == nil, "a doubled dot (empty component) must fail")
        expect(SemanticVersion(parsing: "2.1.") == nil, "a trailing dot (empty component) must fail")
        expect(
            SemanticVersion(parsing: "2.1.201.5") == nil,
            "more than 3 components must fail rather than silently truncating")
    }

    suite(
        "SemanticVersion comparison is NUMERIC, never string/lexical — 2.1.201 > 2.1.99 even"
            + " though \"99\" > \"201\" as strings"
    ) {
        let v201 = SemanticVersion(parsing: "2.1.201")!
        let v99 = SemanticVersion(parsing: "2.1.99")!
        expect(v201 > v99, "2.1.201 must compare GREATER than 2.1.99 (numeric: 201 > 99)")
        expect(v99 < v201, "2.1.99 must compare LESS than 2.1.201")
        expect(
            "99" > "201",
            "sanity: lexical string comparison would (wrongly) say \"99\" > \"201\" — proves"
                + " the numeric comparison above isn't accidentally passing")
    }

    suite("SemanticVersion comparison handles multi-digit minor version components correctly") {
        expect(
            SemanticVersion(parsing: "2.10.0")! > SemanticVersion(parsing: "2.9.0")!,
            "2.10.0 must compare GREATER than 2.9.0 (numeric: 10 > 9, not lexical \"10\" < \"9\")"
        )
    }

    suite("SemanticVersion.description round-trips to \"major.minor.patch\"") {
        expect(
            SemanticVersion(major: 2, minor: 1, patch: 201).description == "2.1.201",
            "description should render as major.minor.patch")
    }

    // MARK: parseClaudeCodeVersionOutput

    suite(
        "parseClaudeCodeVersionOutput extracts the version from the real"
            + " \"<semver> (Claude Code)\" shape"
    ) {
        expect(
            parseClaudeCodeVersionOutput("2.1.206 (Claude Code)")
                == SemanticVersion(major: 2, minor: 1, patch: 206),
            "should parse \"2.1.206 (Claude Code)\" to 2.1.206")
        expect(
            parseClaudeCodeVersionOutput("2.1.206 (Claude Code)\n")
                == SemanticVersion(major: 2, minor: 1, patch: 206),
            "a trailing newline must not break parsing")
        expect(
            parseClaudeCodeVersionOutput("  2.1.201 (Claude Code)  ")
                == SemanticVersion(major: 2, minor: 1, patch: 201),
            "leading/trailing whitespace around the whole output must not break parsing")
    }

    suite("parseClaudeCodeVersionOutput returns nil for garbage/empty output") {
        expect(
            parseClaudeCodeVersionOutput("command not found") == nil,
            "non-version garbage output must fail to parse, not crash or guess")
        expect(parseClaudeCodeVersionOutput("") == nil, "empty output must fail to parse")
        expect(
            parseClaudeCodeVersionOutput("   \n  ") == nil,
            "whitespace-only output must fail to parse")
    }

    // MARK: checkClaudeCodeVersion (fake CommandRunning — no real subprocess)

    suite("checkClaudeCodeVersion: a version at/above the verified minimum reports .verified") {
        let runner = FakeCommandRunner(result: .completed(exitCode: 0, stdout: "2.1.206 (Claude Code)"))
        let status = checkClaudeCodeVersion(commandRunner: runner)
        expect(
            status == .verified(current: SemanticVersion(major: 2, minor: 1, patch: 206)),
            "expected .verified(2.1.206), got \(status)")
    }

    suite(
        "checkClaudeCodeVersion: exactly the verified minimum itself reports .verified (boundary,"
            + " not .belowVerifiedMinimum)"
    ) {
        let runner = FakeCommandRunner(result: .completed(exitCode: 0, stdout: "2.1.201 (Claude Code)"))
        let status = checkClaudeCodeVersion(commandRunner: runner)
        expect(
            status == .verified(current: VersionCompatibility.minimumVerifiedClaudeCodeVersion),
            "the exact floor version must be .verified, not .belowVerifiedMinimum, got \(status)")
    }

    suite(
        "checkClaudeCodeVersion: a version below the verified minimum reports"
            + " .belowVerifiedMinimum — proves the numeric (not lexical) comparison reaches all"
            + " the way through this function, using the task's own 2.1.201 vs 2.1.99 example"
    ) {
        let runner = FakeCommandRunner(result: .completed(exitCode: 0, stdout: "2.1.99 (Claude Code)"))
        let status = checkClaudeCodeVersion(commandRunner: runner)
        expect(
            status == .belowVerifiedMinimum(current: SemanticVersion(major: 2, minor: 1, patch: 99)),
            "expected .belowVerifiedMinimum(2.1.99), got \(status)")
    }

    suite("checkClaudeCodeVersion: a non-zero exit code (claude not on PATH via env) is .undetectable")
    {
        let runner = FakeCommandRunner(result: .completed(exitCode: 127, stdout: ""))
        let status = checkClaudeCodeVersion(commandRunner: runner)
        if case .undetectable = status {
            // expected
        } else {
            expect(false, "expected .undetectable for a non-zero exit code, got \(status)")
        }
    }

    suite("checkClaudeCodeVersion: unparsable stdout is .undetectable, never a crash") {
        let runner = FakeCommandRunner(result: .completed(exitCode: 0, stdout: "garbage output\n"))
        let status = checkClaudeCodeVersion(commandRunner: runner)
        if case .undetectable = status {
            // expected
        } else {
            expect(false, "expected .undetectable for unparsable stdout, got \(status)")
        }
    }

    suite("checkClaudeCodeVersion: a runner-reported timeout is .undetectable, never hangs") {
        let runner = FakeCommandRunner(result: .timedOut)
        let status = checkClaudeCodeVersion(commandRunner: runner)
        if case .undetectable = status {
            // expected
        } else {
            expect(false, "expected .undetectable for a timeout, got \(status)")
        }
    }

    suite("checkClaudeCodeVersion: a launch failure (env itself missing) is .undetectable") {
        let runner = FakeCommandRunner(result: .launchFailed)
        let status = checkClaudeCodeVersion(commandRunner: runner)
        if case .undetectable = status {
            // expected
        } else {
            expect(false, "expected .undetectable for a launch failure, got \(status)")
        }
    }

    // MARK: claudeCodeVersionDoctorResult — never .failure, for any outcome

    suite(
        "claudeCodeVersionDoctorResult: every ClaudeCodeVersionStatus outcome maps to .ok or"
            + " .warning, NEVER .failure (anchor 2: doctor's hard-failure set must never widen)"
    ) {
        let scenarios: [(String, CommandRunResult)] = [
            ("verified", .completed(exitCode: 0, stdout: "2.1.206 (Claude Code)")),
            ("below minimum", .completed(exitCode: 0, stdout: "2.1.99 (Claude Code)")),
            ("not on PATH", .completed(exitCode: 127, stdout: "")),
            ("unparsable", .completed(exitCode: 0, stdout: "garbage\n")),
            ("timed out", .timedOut),
            ("launch failed", .launchFailed),
        ]
        for (label, result) in scenarios {
            let doctorResult = claudeCodeVersionDoctorResult(commandRunner: FakeCommandRunner(result: result))
            expect(
                doctorResult.severity != .failure,
                "\(label) must never produce .failure, got \(doctorResult.severity)")
        }
    }

    suite(
        "claudeCodeVersionDoctorResult: the below-minimum warning explains StopFailure in"
            + " plain language, and does not blame the other three events"
    ) {
        let runner = FakeCommandRunner(result: .completed(exitCode: 0, stdout: "2.1.99 (Claude Code)"))
        let result = claudeCodeVersionDoctorResult(commandRunner: runner)
        expect(result.severity == .warning, "expected .warning, got \(result.severity)")
        expect(
            result.message.contains("StopFailure"),
            "message should name StopFailure specifically, got \(result.message)")
    }

    // MARK: macOSVersionDoctorResult — always .ok (anchor 3: informational, never a real gate)

    suite("macOSVersionDoctorResult: at/above the documented floor reports .ok") {
        let result = macOSVersionDoctorResult(current: SemanticVersion(major: 15, minor: 0, patch: 0))
        expect(result.severity == .ok, "expected .ok, got \(result.severity)")
    }

    suite(
        "macOSVersionDoctorResult: even an (impossible on a real machine) below-floor injected"
            + " version still reports .ok — never .warning, never .failure — because this branch"
            + " is provably unreachable in production and must not masquerade as a live signal"
    ) {
        let result = macOSVersionDoctorResult(current: SemanticVersion(major: 10, minor: 15, patch: 0))
        expect(
            result.severity == .ok,
            "a below-floor macOS version must still report .ok (purely informational), got"
                + " \(result.severity)")
        expect(
            result.message.contains("12.0.0") || result.message.contains("10.15.0"),
            "the message should still mention both the current and floor versions for"
                + " visibility, got \(result.message)")
    }

    // MARK: VersionCompatibility constants are the single source of truth

    suite(
        "VersionCompatibility constants match the documented values (single source of truth —"
            + " no test hardcodes a second copy of either number)"
    ) {
        expect(
            VersionCompatibility.minimumMacOSVersion == SemanticVersion(major: 12, minor: 0, patch: 0),
            "minimumMacOSVersion must mirror Package.swift's platforms: [.macOS(.v12)]")
        expect(
            VersionCompatibility.minimumVerifiedClaudeCodeVersion
                == SemanticVersion(major: 2, minor: 1, patch: 201),
            "minimumVerifiedClaudeCodeVersion must be the spike-verified 2.1.201 floor")
    }

    // MARK: SystemCommandRunner — the ONLY tests in this file that spawn a real subprocess,
    // proving the production implementation's timeout is REAL enforcement, not "assume it's
    // fast" (mirrors the existing `SystemProcessSpawner` tests in `PlaySuite.swift`).

    suite(
        "SystemCommandRunner.run: a real subprocess that finishes within the timeout reports"
            + " .completed with its actual stdout and exit code"
    ) {
        let runner = SystemCommandRunner()
        let result = runner.run(executablePath: "/bin/echo", arguments: ["hello"], timeout: 2.0)
        expect(
            result == .completed(exitCode: 0, stdout: "hello\n"),
            "expected .completed(0, \"hello\\n\"), got \(result)")
    }

    suite(
        "SystemCommandRunner.run: a REAL enforced timeout — a subprocess that sleeps far longer"
            + " than the given timeout is actively terminated and reported as .timedOut quickly,"
            + " never waited out to completion (task requirement: 超时必须真的实现)"
    ) {
        let runner = SystemCommandRunner()
        let start = Date()
        let result = runner.run(
            executablePath: "/bin/sh", arguments: ["-c", "sleep 5"], timeout: 0.2)
        let elapsed = Date().timeIntervalSince(start)
        expect(result == .timedOut, "expected .timedOut, got \(result)")
        expect(
            elapsed < 2.0,
            "run() must return promptly after actively terminating the child, not after the"
                + " full 5s sleep completes (took \(elapsed)s)")
    }

    suite("SystemCommandRunner.run: a non-existent executable reports .launchFailed, never crashes")
    {
        let runner = SystemCommandRunner()
        let result = runner.run(
            executablePath: "/no/such/executable-claudio-test", arguments: [], timeout: 2.0)
        expect(result == .launchFailed, "expected .launchFailed, got \(result)")
    }

    suite("SystemCommandRunner.run: a non-zero exit code is reported faithfully, not swallowed") {
        let runner = SystemCommandRunner()
        let result = runner.run(
            executablePath: "/bin/sh", arguments: ["-c", "exit 3"], timeout: 2.0)
        expect(
            result == .completed(exitCode: 3, stdout: ""),
            "expected .completed(exitCode: 3, stdout: \"\"), got \(result)")
    }

    suite(
        "SystemCommandRunner.run: stdout larger than the ~64KB pipe buffer is drained without"
            + " deadlocking the child — the property the original background reader existed to"
            + " provide, which the single-threaded poll(2) drain must not give up"
    ) {
        let runner = SystemCommandRunner()
        let result = runner.run(
            executablePath: "/bin/sh",
            arguments: ["-c", "head -c 200000 /dev/zero | tr '\\0' 'a'"], timeout: 10.0)
        guard case .completed(let exitCode, let stdout) = result else {
            expect(false, "expected .completed, got \(result)")
            return
        }
        expect(exitCode == 0, "expected exit 0, got \(exitCode)")
        expect(
            stdout.count == 200_000,
            "all 200000 bytes must be read; a reader that stopped early would let the child"
                + " block on a full pipe forever, got \(stdout.count)")
    }

    suite(
        "SystemCommandRunner.run: retained stdout is capped at 1 MiB, and the child is still"
            + " drained to EOF past the cap so it never blocks and never becomes a timeout"
    ) {
        // Without the cap this returns ~4 MiB and a runaway child grows the menu-bar app's
        // memory without bound; with a cap that STOPS reading instead of dropping, the child
        // would wedge on a full pipe and this would report .timedOut.
        let runner = SystemCommandRunner()
        let result = runner.run(
            executablePath: "/bin/sh",
            arguments: ["-c", "head -c 4194304 /dev/zero | tr '\\0' 'a'"], timeout: 20.0)
        guard case .completed(let exitCode, let stdout) = result else {
            expect(false, "the cap must not turn a well-behaved child into a timeout, got \(result)")
            return
        }
        expect(exitCode == 0, "the child must still exit cleanly, got \(exitCode)")
        expect(
            stdout.count == 1 << 20,
            "retained output must be capped at exactly 1 MiB, got \(stdout.count)")
    }

    suite(
        "SystemCommandRunner.run: the timeout covers READING stdout, not just waiting for exit"
            + " — a child that exits while a grandchild still holds its stdout never EOFs the"
            + " pipe, and must not be able to block run() past the deadline"
    ) {
        // The regression this pins: the original implementation waited for the process's
        // termination semaphore with the timeout, then did an UNBOUNDED `readQueue.sync {}` to
        // collect a background `readDataToEndOfFile()`. EOF arrives only when *every* copy of
        // the write end closes, so `sh` exiting while its backgrounded `sleep` keeps stdout
        // open satisfied the semaphore instantly and then hung on the collect — measured 4.02s
        // against a 0.5s timeout, with the whole budget already spent. `claude --version`
        // happens not to daemonize today, but this type is slated for in-process reuse by the
        // menu-bar app, and "绝不能挂住" is the contract regardless of the callee.
        let runner = SystemCommandRunner()
        let start = Date()
        let result = runner.run(
            executablePath: "/bin/sh", arguments: ["-c", "sleep 3 & echo hi"], timeout: 0.3)
        let elapsed = Date().timeIntervalSince(start)

        expect(
            result == .timedOut,
            "stdout never reached EOF within the deadline, so the honest answer is .timedOut,"
                + " not a .completed carrying output we could not finish reading; got \(result)")
        expect(
            elapsed < 1.5,
            "run() must honor its deadline even though the child exited immediately and only a"
                + " grandchild holds the pipe open (took \(elapsed)s, timeout was 0.3s)")
    }

    suite(
        "SystemCommandRunner.run: repeated grandchild-holds-stdout timeouts strand no threads"
            + " — the deadline-bounded drain runs on the caller's thread, so there is no reader"
            + " to leak in the first place"
    ) {
        let iterations = 20
        let runner = SystemCommandRunner()
        let before = liveThreadCount()
        for _ in 0..<iterations {
            _ = runner.run(
                executablePath: "/bin/sh", arguments: ["-c", "sleep 2 & echo hi"], timeout: 0.05)
        }
        Thread.sleep(forTimeInterval: 0.3)
        let after = liveThreadCount()

        expect(
            before > 0 && after > 0,
            "premise: liveThreadCount() must actually work, got before=\(before) after=\(after)")
        expect(
            after - before < 5,
            "\(iterations) unreadable-stdout timeouts must not each strand a reader thread:"
                + " thread count went \(before) → \(after) (delta \(after - before))")
    }

    suite("SystemCommandRunner.run: a failed launch leaks neither the stdout reader nor its pipe")
    {
        // `.launchFailed` is the branch that fires whenever `claude` isn't on PATH — the most
        // likely real-world one. A successful `run()` closes the parent's copy of the pipe's
        // write end, which is what EOFs the background reader; a throwing `run()` never does,
        // so before this was fixed each failed launch wedged one reader thread on
        // `readDataToEndOfFile()` forever and pinned both pipe fds with it. `claudio doctor`
        // is one-shot so the OS reclaimed it at exit, but the menu-bar app is slated to reuse
        // this API in-process, where it would grow without bound.
        //
        // Measured via the process's own mach thread count. GCD may legitimately keep a few
        // worker threads warm, so this asserts "no growth proportional to the call count"
        // (slack of 5 against 40 calls), not an exact figure — before the fix the delta was
        // exactly `iterations`.
        let iterations = 40
        let runner = SystemCommandRunner()
        let before = liveThreadCount()
        for _ in 0..<iterations {
            _ = runner.run(
                executablePath: "/no/such/executable-claudio-test", arguments: [], timeout: 2.0)
        }
        // The reader unwinds asynchronously once it sees EOF; give it a moment to be reaped
        // rather than racing the measurement.
        Thread.sleep(forTimeInterval: 0.3)
        let after = liveThreadCount()

        expect(
            before > 0 && after > 0,
            "premise: liveThreadCount() must actually work on this platform,"
                + " got before=\(before) after=\(after)")
        expect(
            after - before < 5,
            "\(iterations) failed launches must not each strand a reader thread:"
                + " thread count went \(before) → \(after) (delta \(after - before))")
    }
}

/// Number of threads currently live in this process, via the mach task API. Used only by the
/// `.launchFailed` leak regression above — a leaked `readDataToEndOfFile()` reader is
/// invisible to any assertion on `run`'s return value, so the leak has to be observed
/// directly. Returns 0 if the kernel call fails, which the caller asserts against rather
/// than silently treating as "no threads".
@MainActor
private func liveThreadCount() -> Int {
    var threads: thread_act_array_t?
    var count = mach_msg_type_number_t(0)
    guard task_threads(mach_task_self_, &threads, &count) == KERN_SUCCESS, let threads else {
        return 0
    }
    for index in 0..<Int(count) {
        mach_port_deallocate(mach_task_self_, threads[index])
    }
    vm_deallocate(
        mach_task_self_,
        vm_address_t(UInt(bitPattern: threads)),
        vm_size_t(Int(count) * MemoryLayout<thread_t>.stride))
    return Int(count)
}
