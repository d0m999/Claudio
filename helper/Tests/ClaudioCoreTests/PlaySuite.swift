import ClaudioCore
import Dispatch
import Foundation

// MARK: - play: debounced background-spawn playback (ENGINEERING.md 决议 1 + 5 +「工程落地细节 ④」, T5)
//
// `playSoundEvent` must never block the hook caller and must never surface a hard error
// for any "not configured yet" state (unknown event, muted event, incomplete pack). These
// tests exercise the whole `ClaudioCore.playSoundEvent` pipeline against injected
// `PlayEnvironment`s (temp dirs, never the real `~/.claudio`/`~/.claude`) and an injected
// `ProcessSpawning` double, so no test ever calls the real system `afplay`.

// MARK: - Test doubles

/// Records every spawn attempt instead of launching a real process — lets tests assert
/// *what* `play` tried to spawn without ever touching the real system `afplay`.
private final class RecordingSpawner: ProcessSpawning, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [(executablePath: String, arguments: [String])] = []

    var calls: [(executablePath: String, arguments: [String])] {
        lock.lock()
        defer { lock.unlock() }
        return _calls
    }

    var callCount: Int { calls.count }

    func spawn(executablePath: String, arguments: [String]) -> Bool {
        lock.lock()
        _calls.append((executablePath, arguments))
        lock.unlock()
        return true
    }
}

/// Simulates a spawn whose launch itself fails (e.g. a missing/broken `afplay` binary) —
/// `spawn` always reports failure without ever touching the real filesystem/process table.
/// Used to prove `playSoundEvent` appends a `claudio.log` diagnostic line on spawn failure
/// (ENGINEERING.md T6) while still returning `.played` (T5's outcome contract is unchanged).
private final class FailingSpawner: ProcessSpawning, @unchecked Sendable {
    private let lock = NSLock()
    private var _callCount = 0

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _callCount
    }

    func spawn(executablePath: String, arguments: [String]) -> Bool {
        lock.lock()
        _callCount += 1
        lock.unlock()
        return false
    }
}

/// A spawner that holds `play.lock`'s critical section open for `holdDuration` before
/// returning, deliberately widening the contention window so a burst of *concurrent*
/// `playSoundEvent` calls reliably race on the same lock instead of the window closing
/// before every caller has even attempted it. Never spawns a real process.
private final class SlowRecordingSpawner: ProcessSpawning, @unchecked Sendable {
    private let lock = NSLock()
    private var _callCount = 0
    let holdDuration: TimeInterval

    init(holdDuration: TimeInterval) {
        self.holdDuration = holdDuration
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _callCount
    }

    func spawn(executablePath: String, arguments: [String]) -> Bool {
        lock.lock()
        _callCount += 1
        lock.unlock()
        Thread.sleep(forTimeInterval: holdDuration)
        return true
    }
}

/// Simulates a multi-second `afplay` playback: `spawn` itself returns immediately, but a
/// `finished` flag only flips `delay` seconds later on a background queue — exactly the
/// shape of the real fire-and-forget launch. Used to prove `playSoundEvent` never
/// synchronously waits for the spawned work to complete (acceptance (3)).
private final class DelayedSignalSpawner: ProcessSpawning, @unchecked Sendable {
    private let lock = NSLock()
    private var _finished = false
    let delay: TimeInterval

    init(delay: TimeInterval) {
        self.delay = delay
    }

    var finished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _finished
    }

    func spawn(executablePath: String, arguments: [String]) -> Bool {
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
            self.lock.lock()
            self._finished = true
            self.lock.unlock()
        }
        // Returns immediately — never waits for the `asyncAfter` block above.
        return true
    }
}

/// An injectable, manually-advanced clock for deterministic debounce tests — avoids real
/// `Thread.sleep`s spanning the full 1.5s debounce window (ENGINEERING.md「并发 / 进程堆积处理」) just to prove
/// "elapsed >= interval" vs "elapsed < interval" behavior.
private final class FixedClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(start: Date) {
        current = start
    }

    func advance(by seconds: TimeInterval) {
        lock.lock()
        current = current.addingTimeInterval(seconds)
        lock.unlock()
    }

    /// Pass directly as `PlayEnvironment.now`.
    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }
}

/// Thread-safe collector for outcomes produced by concurrent `playSoundEvent` calls.
private final class OutcomeCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var _outcomes: [PlayOutcome] = []

    func append(_ outcome: PlayOutcome) {
        lock.lock()
        _outcomes.append(outcome)
        lock.unlock()
    }

    var outcomes: [PlayOutcome] {
        lock.lock()
        defer { lock.unlock() }
        return _outcomes
    }
}

@MainActor
func runPlaySuites() {
    suite("PlayEnvironment()'s default lockFile is ClaudioPaths.playLockFile, never config/settingsLockFile") {
        // Lock separation (D9): `play`'s debounce lock must stay its own — never the lock
        // `claudio use` / `claudio event enabled` / `SettingsInstaller` serialize on. A config.json
        // write or a settings.json install/uninstall must never contend with, or be gated by,
        // `play`'s lock. This is the type-level half of that wiring assertion — no injected
        // paths, just the real production default.
        expect(
            PlayEnvironment().lockFile == ClaudioPaths.playLockFile,
            "PlayEnvironment()'s default lockFile must be ClaudioPaths.playLockFile, got "
                + "\(PlayEnvironment().lockFile.path)"
        )
    }

    suite("playSoundEvent: unknown event name -> .unknownEvent, never spawns") {
        withTempDirectory { root in
            let spawner = RecordingSpawner()
            let env = PlayEnvironment(
                lockFile: root.appendingPathComponent("play.lock"),
                configFile: root.appendingPathComponent("config.json"),
                userPacksDirectory: root.appendingPathComponent("packs"),
                bundledPacksDirectory: nil,
                spawner: spawner,
                debounceStateFile: root.appendingPathComponent("play.state"),
                logFile: root.appendingPathComponent("claudio.log"),
                logLockFile: root.appendingPathComponent("claudio.log.lock"))

            let outcome = playSoundEvent("not_a_real_event", environment: env)
            expect(
                outcome == .unknownEvent,
                "unknown event name must report .unknownEvent, got \(outcome)"
            )
            expect(spawner.callCount == 0, "an unknown event must never spawn afplay")
        }
    }

    suite("playSoundEvent: no config.json at all (fresh install) -> .notReady, never spawns") {
        withTempDirectory { root in
            let spawner = RecordingSpawner()
            let env = PlayEnvironment(
                lockFile: root.appendingPathComponent("play.lock"),
                configFile: root.appendingPathComponent("config.json"),
                userPacksDirectory: root.appendingPathComponent("packs"),
                bundledPacksDirectory: nil,
                spawner: spawner,
                debounceStateFile: root.appendingPathComponent("play.state"),
                logFile: root.appendingPathComponent("claudio.log"),
                logLockFile: root.appendingPathComponent("claudio.log.lock"))

            let outcome = playSoundEvent("stop", environment: env)
            expect(
                outcome == .notReady, "missing config.json must report .notReady, got \(outcome)")
            expect(spawner.callCount == 0, "missing config must never spawn afplay")
        }
    }

    suite("playSoundEvent: corrupt config.json -> .notReady, never spawns") {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            writeFixture("{ not valid json", to: configFile)

            let spawner = RecordingSpawner()
            let env = PlayEnvironment(
                lockFile: root.appendingPathComponent("play.lock"),
                configFile: configFile,
                userPacksDirectory: root.appendingPathComponent("packs"),
                bundledPacksDirectory: nil,
                spawner: spawner,
                debounceStateFile: root.appendingPathComponent("play.state"),
                logFile: root.appendingPathComponent("claudio.log"),
                logLockFile: root.appendingPathComponent("claudio.log.lock"))

            let outcome = playSoundEvent("stop", environment: env)
            expect(
                outcome == .notReady, "corrupt config.json must report .notReady, got \(outcome)")
            expect(spawner.callCount == 0, "corrupt config must never spawn afplay")
        }
    }

    suite("playSoundEvent: selected pack doesn't exist anywhere -> .notReady, never spawns") {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            writeFixture(#"{ "selected_pack": "ghost-pack" }"#, to: configFile)

            let spawner = RecordingSpawner()
            let env = PlayEnvironment(
                lockFile: root.appendingPathComponent("play.lock"),
                configFile: configFile,
                userPacksDirectory: root.appendingPathComponent("packs"),
                bundledPacksDirectory: nil,
                spawner: spawner,
                debounceStateFile: root.appendingPathComponent("play.state"),
                logFile: root.appendingPathComponent("claudio.log"),
                logLockFile: root.appendingPathComponent("claudio.log.lock"))

            let outcome = playSoundEvent("stop", environment: env)
            expect(
                outcome == .notReady, "an unresolved pack id must report .notReady, got \(outcome)")
            expect(spawner.callCount == 0, "an unresolved pack must never spawn afplay")
        }
    }

    suite("playSoundEvent: event key absent from the manifest (未配音) -> .notReady, never spawns") {
        withTempDirectory { root in
            let packsDir = root.appendingPathComponent("packs")
            let configFile = root.appendingPathComponent("config.json")
            writeFixture(#"{ "selected_pack": "minimal-chime" }"#, to: configFile)
            // The manifest only declares `stop`, not `notification`.
            writeFixture(
                #"{ "id": "minimal-chime", "events": { "stop": "stop.mp3" } }"#,
                to: packsDir.appendingPathComponent("minimal-chime/manifest.json"))
            writeFixture(
                "fake-audio", to: packsDir.appendingPathComponent("minimal-chime/stop.mp3"))

            let spawner = RecordingSpawner()
            let env = PlayEnvironment(
                lockFile: root.appendingPathComponent("play.lock"),
                configFile: configFile,
                userPacksDirectory: packsDir,
                bundledPacksDirectory: nil,
                spawner: spawner,
                debounceStateFile: root.appendingPathComponent("play.state"),
                logFile: root.appendingPathComponent("claudio.log"),
                logLockFile: root.appendingPathComponent("claudio.log.lock"))

            let outcome = playSoundEvent("notification", environment: env)
            expect(
                outcome == .notReady,
                "an event missing from the manifest must report .notReady, got \(outcome)")
            expect(spawner.callCount == 0, "an unmapped event must never spawn afplay")
        }
    }

    suite(
        "playSoundEvent: stop_failure absent from an old/incomplete manifest -> .notReady,"
            + " never spawns, never writes a claudio.log line (T13 acceptance 3b — regression"
            + " pin: an old Claude Code without StopFailure support, or a pack that simply"
            + " never mapped stop_failure, both fall through this exact existing silent path;"
            + " this test pins that Play.swift already behaves this way, it is not new"
            + " behavior)"
    ) {
        withTempDirectory { root in
            let packsDir = root.appendingPathComponent("packs")
            let configFile = root.appendingPathComponent("config.json")
            let logFile = root.appendingPathComponent("claudio.log")
            writeFixture(#"{ "selected_pack": "minimal-chime" }"#, to: configFile)
            // The manifest only declares `stop` — never `stop_failure` — mirroring a pack
            // (or a moment in time) that predates StopFailure support entirely.
            writeFixture(
                #"{ "id": "minimal-chime", "events": { "stop": "stop.mp3" } }"#,
                to: packsDir.appendingPathComponent("minimal-chime/manifest.json"))
            writeFixture(
                "fake-audio", to: packsDir.appendingPathComponent("minimal-chime/stop.mp3"))

            let spawner = RecordingSpawner()
            let env = PlayEnvironment(
                lockFile: root.appendingPathComponent("play.lock"),
                configFile: configFile,
                userPacksDirectory: packsDir,
                bundledPacksDirectory: nil,
                spawner: spawner,
                debounceStateFile: root.appendingPathComponent("play.state"),
                logFile: logFile,
                logLockFile: root.appendingPathComponent("claudio.log.lock"))

            let outcome = playSoundEvent("stop_failure", environment: env)
            expect(
                outcome == .notReady,
                "stop_failure missing from the manifest must report .notReady, got \(outcome)")
            expect(spawner.callCount == 0, "a manifest without stop_failure must never spawn afplay")
            expect(
                readRecentLogEntries(from: logFile).isEmpty,
                "a missing-from-manifest event is a silent 'not ready yet' state, not a real"
                    + " failure — it must never append a claudio.log line")
        }
    }

    suite("playSoundEvent: declared audio file missing on disk -> .notReady, never spawns") {
        withTempDirectory { root in
            let packsDir = root.appendingPathComponent("packs")
            let configFile = root.appendingPathComponent("config.json")
            writeFixture(#"{ "selected_pack": "minimal-chime" }"#, to: configFile)
            writeFixture(
                #"{ "id": "minimal-chime", "events": { "stop": "stop.mp3" } }"#,
                to: packsDir.appendingPathComponent("minimal-chime/manifest.json"))
            // `stop.mp3` is declared but never actually written to disk.

            let spawner = RecordingSpawner()
            let env = PlayEnvironment(
                lockFile: root.appendingPathComponent("play.lock"),
                configFile: configFile,
                userPacksDirectory: packsDir,
                bundledPacksDirectory: nil,
                spawner: spawner,
                debounceStateFile: root.appendingPathComponent("play.state"),
                logFile: root.appendingPathComponent("claudio.log"),
                logLockFile: root.appendingPathComponent("claudio.log.lock"))

            let outcome = playSoundEvent("stop", environment: env)
            expect(
                outcome == .notReady,
                "a missing declared audio file must report .notReady, got \(outcome)")
            expect(spawner.callCount == 0, "a missing declared audio file must never spawn afplay")
        }
    }

    suite(
        "playSoundEvent: a manifest event value escaping the pack dir (../) never plays, reported as .notReady"
    ) {
        withTempDirectory { root in
            let packsDir = root.appendingPathComponent("packs")
            let configFile = root.appendingPathComponent("config.json")
            writeFixture(#"{ "selected_pack": "minimal-chime" }"#, to: configFile)
            // Manifest points `stop` at a file OUTSIDE the pack directory via `../` — this
            // must go through the same containment guard `doctor` uses
            // (`safePackFileURL`), never a second, unaudited check.
            writeFixture(
                #"{ "id": "minimal-chime", "events": { "stop": "../evil.mp3" } }"#,
                to: packsDir.appendingPathComponent("minimal-chime/manifest.json"))
            // The escaping file really exists — a naive check would find it and falsely
            // play it.
            writeFixture("fake-audio", to: packsDir.appendingPathComponent("evil.mp3"))

            let spawner = RecordingSpawner()
            let env = PlayEnvironment(
                lockFile: root.appendingPathComponent("play.lock"),
                configFile: configFile,
                userPacksDirectory: packsDir,
                bundledPacksDirectory: nil,
                spawner: spawner,
                debounceStateFile: root.appendingPathComponent("play.state"),
                logFile: root.appendingPathComponent("claudio.log"),
                logLockFile: root.appendingPathComponent("claudio.log.lock"))

            let outcome = playSoundEvent("stop", environment: env)
            expect(
                outcome == .notReady,
                "an escaping manifest event path must report .notReady, got \(outcome)")
            expect(
                spawner.callCount == 0, "an escaping manifest event path must never spawn afplay")
        }
    }

    suite("playSoundEvent: an absolute-path manifest event value never plays") {
        withTempDirectory { root in
            let packsDir = root.appendingPathComponent("packs")
            let configFile = root.appendingPathComponent("config.json")
            writeFixture(#"{ "selected_pack": "minimal-chime" }"#, to: configFile)
            writeFixture(
                #"{ "id": "minimal-chime", "events": { "stop": "/etc/hosts" } }"#,
                to: packsDir.appendingPathComponent("minimal-chime/manifest.json"))

            let spawner = RecordingSpawner()
            let env = PlayEnvironment(
                lockFile: root.appendingPathComponent("play.lock"),
                configFile: configFile,
                userPacksDirectory: packsDir,
                bundledPacksDirectory: nil,
                spawner: spawner,
                debounceStateFile: root.appendingPathComponent("play.state"),
                logFile: root.appendingPathComponent("claudio.log"),
                logLockFile: root.appendingPathComponent("claudio.log.lock"))

            let outcome = playSoundEvent("stop", environment: env)
            expect(
                outcome == .notReady,
                "an absolute-path manifest event value must report .notReady, got \(outcome)")
            expect(
                spawner.callCount == 0,
                "an absolute-path manifest event value must never spawn afplay")
        }
    }

    suite(
        "playSoundEvent: config disables the event (静音钮) -> .disabled, never spawns even though the pack is complete"
    ) {
        withTempDirectory { root in
            let packsDir = root.appendingPathComponent("packs")
            let configFile = root.appendingPathComponent("config.json")
            writeFixture(
                #"{ "selected_pack": "minimal-chime", "events": { "stop": false } }"#,
                to: configFile)
            writeFixture(
                #"{ "id": "minimal-chime", "events": { "stop": "stop.mp3" } }"#,
                to: packsDir.appendingPathComponent("minimal-chime/manifest.json"))
            writeFixture(
                "fake-audio", to: packsDir.appendingPathComponent("minimal-chime/stop.mp3"))

            let spawner = RecordingSpawner()
            let env = PlayEnvironment(
                lockFile: root.appendingPathComponent("play.lock"),
                configFile: configFile,
                userPacksDirectory: packsDir,
                bundledPacksDirectory: nil,
                spawner: spawner,
                debounceStateFile: root.appendingPathComponent("play.state"),
                logFile: root.appendingPathComponent("claudio.log"),
                logLockFile: root.appendingPathComponent("claudio.log.lock"))

            let outcome = playSoundEvent("stop", environment: env)
            expect(
                outcome == .disabled(event: .stop),
                "a muted event must report .disabled(event: .stop), got \(outcome)")
            expect(spawner.callCount == 0, "a muted event must never spawn afplay")
        }
    }

    suite(
        "playSoundEvent: happy path plays every one of the four v1 events through their exact manifest keys (never lowercased)"
    ) {
        withTempDirectory { root in
            let packsDir = root.appendingPathComponent("packs")
            let configFile = root.appendingPathComponent("config.json")
            let lockFile = root.appendingPathComponent("play.lock")
            writeFixture(#"{ "selected_pack": "minimal-chime" }"#, to: configFile)
            writeFixture(
                #"""
                { "id": "minimal-chime", "events": {
                    "stop": "stop.mp3",
                    "stop_failure": "stop_failure.mp3",
                    "notification": "notification.mp3",
                    "subagent_stop": "subagent_stop.mp3"
                } }
                """#,
                to: packsDir.appendingPathComponent("minimal-chime/manifest.json"))
            for event in Event.allCases {
                writeFixture(
                    "fake-audio",
                    to: packsDir.appendingPathComponent("minimal-chime/\(event.manifestKey).mp3"))
            }

            for event in Event.allCases {
                let spawner = RecordingSpawner()
                let env = PlayEnvironment(
                    afplayPath: "/usr/bin/afplay",
                    lockFile: lockFile,
                    configFile: configFile,
                    userPacksDirectory: packsDir,
                    bundledPacksDirectory: nil,
                    spawner: spawner,
                    // Each event gets its own debounce state file: this test's purpose is
                    // the event -> manifestKey mapping, not debounce timing, so isolate it
                    // from the (separately tested) shared-timestamp debounce entirely.
                    debounceStateFile: root.appendingPathComponent("play-\(event.cliName).state"),
                    logFile: root.appendingPathComponent("claudio.log"),
                    logLockFile: root.appendingPathComponent("claudio.log.lock"))

                let outcome = playSoundEvent(event.cliName, environment: env)
                let expectedFile =
                    packsDir
                    .appendingPathComponent("minimal-chime/\(event.manifestKey).mp3")
                    .standardizedFileURL.path
                expect(
                    outcome == .played(event: event, filePath: expectedFile),
                    "expected .played for \(event.cliName), got \(outcome)")
                expect(
                    spawner.callCount == 1,
                    "afplay must be spawned exactly once for \(event.cliName)")
                expect(
                    spawner.calls.first?.executablePath == "/usr/bin/afplay",
                    "spawn must use the configured afplay path for \(event.cliName)")
                // No `master_volume` in this fixture's config.json, so `ClaudioConfig`'s own
                // lenient decoder falls back to `ClaudioConfig.defaultMasterVolume` (T9) —
                // the spawn must carry that mapped default as `-v <value>`, not omit it.
                let expectedDefaultVolumeArgument =
                    AfplayVolume.afplayArgument(forMasterVolume: ClaudioConfig.defaultMasterVolume)
                expect(
                    spawner.calls.first?.arguments == [
                        "-v", expectedDefaultVolumeArgument, expectedFile,
                    ],
                    "spawn arguments must be exactly [-v, <default volume>, audio file path]"
                        + " for \(event.cliName), got"
                        + " \(String(describing: spawner.calls.first?.arguments))")
            }
        }
    }

    suite(
        "playSoundEvent: a custom in-range config.json master_volume is threaded through to"
            + " the afplay spawn as -v <mapped value> (T9)"
    ) {
        withTempDirectory { root in
            let packsDir = root.appendingPathComponent("packs")
            let configFile = root.appendingPathComponent("config.json")
            writeFixture(
                #"{ "selected_pack": "minimal-chime", "master_volume": 0.35 }"#, to: configFile)
            writeFixture(
                #"{ "id": "minimal-chime", "events": { "stop": "stop.mp3" } }"#,
                to: packsDir.appendingPathComponent("minimal-chime/manifest.json"))
            writeFixture(
                "fake-audio", to: packsDir.appendingPathComponent("minimal-chime/stop.mp3"))

            let spawner = RecordingSpawner()
            let env = PlayEnvironment(
                afplayPath: "/usr/bin/afplay",
                lockFile: root.appendingPathComponent("play.lock"),
                configFile: configFile,
                userPacksDirectory: packsDir,
                bundledPacksDirectory: nil,
                spawner: spawner,
                debounceStateFile: root.appendingPathComponent("play.state"),
                logFile: root.appendingPathComponent("claudio.log"),
                logLockFile: root.appendingPathComponent("claudio.log.lock"))

            let expectedFile =
                packsDir.appendingPathComponent("minimal-chime/stop.mp3").standardizedFileURL.path
            let outcome = playSoundEvent("stop", environment: env)
            expect(
                outcome == .played(event: .stop, filePath: expectedFile),
                "expected .played, got \(outcome)")
            expect(
                spawner.calls.first?.arguments == ["-v", "0.35", expectedFile],
                "a 0.35 master_volume must spawn afplay with [-v, 0.35, audio file path], got"
                    + " \(String(describing: spawner.calls.first?.arguments))")
        }
    }

    suite(
        "playSoundEvent: an out-of-range config.json master_volume is clamped before reaching"
            + " the afplay -v argument (T9) — never passed through raw"
    ) {
        withTempDirectory { root in
            let packsDir = root.appendingPathComponent("packs")
            writeFixture(
                #"{ "id": "minimal-chime", "events": { "stop": "stop.mp3" } }"#,
                to: packsDir.appendingPathComponent("minimal-chime/manifest.json"))
            writeFixture(
                "fake-audio", to: packsDir.appendingPathComponent("minimal-chime/stop.mp3"))
            let expectedFile =
                packsDir.appendingPathComponent("minimal-chime/stop.mp3").standardizedFileURL.path

            // Above 1.0 -> clamps to 1.0.
            let tooLoudConfig = root.appendingPathComponent("too-loud.json")
            writeFixture(
                #"{ "selected_pack": "minimal-chime", "master_volume": 1.8 }"#, to: tooLoudConfig)
            let tooLoudSpawner = RecordingSpawner()
            let tooLoudEnv = PlayEnvironment(
                lockFile: root.appendingPathComponent("too-loud.lock"),
                configFile: tooLoudConfig,
                userPacksDirectory: packsDir,
                bundledPacksDirectory: nil,
                spawner: tooLoudSpawner,
                debounceStateFile: root.appendingPathComponent("too-loud.state"),
                logFile: root.appendingPathComponent("claudio.log"),
                logLockFile: root.appendingPathComponent("claudio.log.lock"))
            _ = playSoundEvent("stop", environment: tooLoudEnv)
            expect(
                tooLoudSpawner.calls.first?.arguments == ["-v", "1.0", expectedFile],
                "master_volume 1.8 must clamp to -v 1.0, got"
                    + " \(String(describing: tooLoudSpawner.calls.first?.arguments))")

            // Below 0.0 -> clamps to 0.0.
            let negativeConfig = root.appendingPathComponent("negative.json")
            writeFixture(
                #"{ "selected_pack": "minimal-chime", "master_volume": -0.4 }"#, to: negativeConfig)
            let negativeSpawner = RecordingSpawner()
            let negativeEnv = PlayEnvironment(
                lockFile: root.appendingPathComponent("negative.lock"),
                configFile: negativeConfig,
                userPacksDirectory: packsDir,
                bundledPacksDirectory: nil,
                spawner: negativeSpawner,
                debounceStateFile: root.appendingPathComponent("negative.state"),
                logFile: root.appendingPathComponent("claudio.log"),
                logLockFile: root.appendingPathComponent("claudio.log.lock"))
            _ = playSoundEvent("stop", environment: negativeEnv)
            expect(
                negativeSpawner.calls.first?.arguments == ["-v", "0.0", expectedFile],
                "master_volume -0.4 must clamp to -v 0.0, got"
                    + " \(String(describing: negativeSpawner.calls.first?.arguments))")
        }
    }

    suite(
        "playSoundEvent: a corrupt/wrong-type config.json master_volume falls back to"
            + " ClaudioConfig.defaultMasterVolume's mapped -v argument, never spawns with a"
            + " raw/garbage value"
    ) {
        withTempDirectory { root in
            let packsDir = root.appendingPathComponent("packs")
            let configFile = root.appendingPathComponent("config.json")
            // `master_volume` is a string, not a number — ClaudioConfig's lenient decoder
            // (ClaudioConfig.swift) already recovers this to the documented default; this
            // test proves that recovery reaches all the way through to the afplay spawn.
            writeFixture(
                #"{ "selected_pack": "minimal-chime", "master_volume": "loud" }"#, to: configFile)
            writeFixture(
                #"{ "id": "minimal-chime", "events": { "stop": "stop.mp3" } }"#,
                to: packsDir.appendingPathComponent("minimal-chime/manifest.json"))
            writeFixture(
                "fake-audio", to: packsDir.appendingPathComponent("minimal-chime/stop.mp3"))

            let spawner = RecordingSpawner()
            let env = PlayEnvironment(
                lockFile: root.appendingPathComponent("play.lock"),
                configFile: configFile,
                userPacksDirectory: packsDir,
                bundledPacksDirectory: nil,
                spawner: spawner,
                debounceStateFile: root.appendingPathComponent("play.state"),
                logFile: root.appendingPathComponent("claudio.log"),
                logLockFile: root.appendingPathComponent("claudio.log.lock"))

            let expectedFile =
                packsDir.appendingPathComponent("minimal-chime/stop.mp3").standardizedFileURL.path
            let expectedDefaultVolumeArgument =
                AfplayVolume.afplayArgument(forMasterVolume: ClaudioConfig.defaultMasterVolume)
            _ = playSoundEvent("stop", environment: env)
            expect(
                spawner.calls.first?.arguments == ["-v", expectedDefaultVolumeArgument, expectedFile],
                "a corrupt master_volume must spawn with the mapped default volume, got"
                    + " \(String(describing: spawner.calls.first?.arguments))")
        }
    }

    suite("playSoundEvent: a currently-held play.lock produces .skippedDebounce, never spawns") {
        withTempDirectory { root in
            let packsDir = root.appendingPathComponent("packs")
            let configFile = root.appendingPathComponent("config.json")
            let lockFile = root.appendingPathComponent("play.lock")
            writeFixture(#"{ "selected_pack": "minimal-chime" }"#, to: configFile)
            writeFixture(
                #"{ "id": "minimal-chime", "events": { "stop": "stop.mp3" } }"#,
                to: packsDir.appendingPathComponent("minimal-chime/manifest.json"))
            writeFixture(
                "fake-audio", to: packsDir.appendingPathComponent("minimal-chime/stop.mp3"))

            let holder = FileLock(path: lockFile.path)
            expect(holder.tryLock(), "test setup: holder must acquire play.lock first")

            let spawner = RecordingSpawner()
            let env = PlayEnvironment(
                lockFile: lockFile,
                configFile: configFile,
                userPacksDirectory: packsDir,
                bundledPacksDirectory: nil,
                spawner: spawner,
                debounceStateFile: root.appendingPathComponent("play.state"),
                logFile: root.appendingPathComponent("claudio.log"),
                logLockFile: root.appendingPathComponent("claudio.log.lock"))

            let outcome = playSoundEvent("stop", environment: env)
            expect(
                outcome == .skippedDebounce,
                "a contended play.lock must report .skippedDebounce, got \(outcome)")
            expect(spawner.callCount == 0, "a skipped debounce must never spawn afplay")
            holder.unlock()
        }
    }

    suite(
        "playSoundEvent: a second call for the SAME event inside the debounce window is"
            + " skipped as .skippedRecentPlay — even with zero lock contention (sequential,"
            + " non-overlapping calls), proving the debounce is a real time window and not"
            + " merely 'did two calls literally race on the lock' (ENGINEERING.md「并发 / 进程堆积处理」+ 决议 5)"
    ) {
        withTempDirectory { root in
            let packsDir = root.appendingPathComponent("packs")
            let configFile = root.appendingPathComponent("config.json")
            writeFixture(#"{ "selected_pack": "minimal-chime" }"#, to: configFile)
            writeFixture(
                #"{ "id": "minimal-chime", "events": { "stop": "stop.mp3" } }"#,
                to: packsDir.appendingPathComponent("minimal-chime/manifest.json"))
            writeFixture(
                "fake-audio", to: packsDir.appendingPathComponent("minimal-chime/stop.mp3"))

            // An injected clock (rather than a real `Thread.sleep`) makes this test
            // deterministic and fast: "now" advances by an exact, fixed amount between
            // the two calls instead of relying on real wall-clock elapsed time.
            let clock = FixedClock(start: Date(timeIntervalSince1970: 1_000_000))
            let firstSpawner = RecordingSpawner()
            let firstEnv = PlayEnvironment(
                lockFile: root.appendingPathComponent("play.lock"),
                configFile: configFile,
                userPacksDirectory: packsDir,
                bundledPacksDirectory: nil,
                spawner: firstSpawner,
                debounceStateFile: root.appendingPathComponent("play.state"),
                debounceInterval: 1.5,
                now: clock.now,
                logFile: root.appendingPathComponent("claudio.log"),
                logLockFile: root.appendingPathComponent("claudio.log.lock"))

            let firstOutcome = playSoundEvent("stop", environment: firstEnv)
            expect(
                firstOutcome == .played(
                    event: .stop,
                    filePath: packsDir.appendingPathComponent("minimal-chime/stop.mp3")
                        .standardizedFileURL.path),
                "the first call (nothing played yet) must play, got \(firstOutcome)")
            expect(firstSpawner.callCount == 1, "the first call must spawn afplay exactly once")

            // Second call, 0.5s later per the injected clock — well inside the 1.5s window
            // — with a completely FRESH spawner/lock so any spawn would be unambiguously
            // attributable to this second call, not a leftover from the first.
            clock.advance(by: 0.5)
            let secondSpawner = RecordingSpawner()
            let secondEnv = PlayEnvironment(
                lockFile: root.appendingPathComponent("play.lock"),
                configFile: configFile,
                userPacksDirectory: packsDir,
                bundledPacksDirectory: nil,
                spawner: secondSpawner,
                debounceStateFile: root.appendingPathComponent("play.state"),
                debounceInterval: 1.5,
                now: clock.now,
                logFile: root.appendingPathComponent("claudio.log"),
                logLockFile: root.appendingPathComponent("claudio.log.lock"))

            let secondOutcome = playSoundEvent("stop", environment: secondEnv)
            expect(
                secondOutcome == .skippedRecentPlay(event: .stop),
                "a second call 0.5s after the first (< 1.5s debounce interval) must report"
                    + " .skippedRecentPlay, got \(secondOutcome)")
            expect(
                secondSpawner.callCount == 0,
                "a call inside the debounce window must never spawn afplay")

            // Third call, past the debounce window (1.5s + 0.1s after the FIRST call) must
            // play again — proves the skip is a real time window, not a permanent latch.
            clock.advance(by: 1.1)
            let thirdSpawner = RecordingSpawner()
            let thirdEnv = PlayEnvironment(
                lockFile: root.appendingPathComponent("play.lock"),
                configFile: configFile,
                userPacksDirectory: packsDir,
                bundledPacksDirectory: nil,
                spawner: thirdSpawner,
                debounceStateFile: root.appendingPathComponent("play.state"),
                debounceInterval: 1.5,
                now: clock.now,
                logFile: root.appendingPathComponent("claudio.log"),
                logLockFile: root.appendingPathComponent("claudio.log.lock"))

            let thirdOutcome = playSoundEvent("stop", environment: thirdEnv)
            if case .played = thirdOutcome {
                // expected
            } else {
                expect(false, "expected .played once the debounce window has elapsed, got \(thirdOutcome)")
            }
            expect(
                thirdSpawner.callCount == 1,
                "a call after the debounce window has elapsed must spawn afplay again")
        }
    }

    suite(
        "playSoundEvent: the shared debounce timestamp is event-agnostic by design (ENGINEERING.md"
            + " 决议 5: 一个共享时间戳) — a DIFFERENT event inside the same window is also skipped"
    ) {
        withTempDirectory { root in
            let packsDir = root.appendingPathComponent("packs")
            let configFile = root.appendingPathComponent("config.json")
            writeFixture(#"{ "selected_pack": "minimal-chime" }"#, to: configFile)
            writeFixture(
                #"""
                { "id": "minimal-chime", "events": {
                    "stop": "stop.mp3",
                    "notification": "notification.mp3"
                } }
                """#,
                to: packsDir.appendingPathComponent("minimal-chime/manifest.json"))
            writeFixture(
                "fake-audio", to: packsDir.appendingPathComponent("minimal-chime/stop.mp3"))
            writeFixture(
                "fake-audio", to: packsDir.appendingPathComponent("minimal-chime/notification.mp3"))

            let clock = FixedClock(start: Date(timeIntervalSince1970: 2_000_000))
            let sharedStateFile = root.appendingPathComponent("play.state")
            let sharedLockFile = root.appendingPathComponent("play.lock")

            let stopSpawner = RecordingSpawner()
            let stopEnv = PlayEnvironment(
                lockFile: sharedLockFile,
                configFile: configFile,
                userPacksDirectory: packsDir,
                bundledPacksDirectory: nil,
                spawner: stopSpawner,
                debounceStateFile: sharedStateFile,
                debounceInterval: 1.5,
                now: clock.now,
                logFile: root.appendingPathComponent("claudio.log"),
                logLockFile: root.appendingPathComponent("claudio.log.lock"))
            let stopOutcome = playSoundEvent("stop", environment: stopEnv)
            expect(stopOutcome == .played(
                event: .stop,
                filePath: packsDir.appendingPathComponent("minimal-chime/stop.mp3")
                    .standardizedFileURL.path), "stop must play first, got \(stopOutcome)")

            clock.advance(by: 0.2)
            let notificationSpawner = RecordingSpawner()
            let notificationEnv = PlayEnvironment(
                lockFile: sharedLockFile,
                configFile: configFile,
                userPacksDirectory: packsDir,
                bundledPacksDirectory: nil,
                spawner: notificationSpawner,
                debounceStateFile: sharedStateFile,
                debounceInterval: 1.5,
                now: clock.now,
                logFile: root.appendingPathComponent("claudio.log"),
                logLockFile: root.appendingPathComponent("claudio.log.lock"))
            let notificationOutcome = playSoundEvent("notification", environment: notificationEnv)
            expect(
                notificationOutcome == .skippedRecentPlay(event: .notification),
                "a DIFFERENT event 0.2s later, sharing the same single timestamp, must still be"
                    + " skipped — got \(notificationOutcome)")
            expect(
                notificationSpawner.callCount == 0,
                "the event-agnostic shared timestamp must debounce across events too")
        }
    }

    suite(
        "playSoundEvent: a real lock filesystem error is reported as .lockFailed, never conflated with .skippedDebounce"
    ) {
        withTempDirectory { root in
            let packsDir = root.appendingPathComponent("packs")
            let configFile = root.appendingPathComponent("config.json")
            writeFixture(#"{ "selected_pack": "minimal-chime" }"#, to: configFile)
            writeFixture(
                #"{ "id": "minimal-chime", "events": { "stop": "stop.mp3" } }"#,
                to: packsDir.appendingPathComponent("minimal-chime/manifest.json"))
            writeFixture(
                "fake-audio", to: packsDir.appendingPathComponent("minimal-chime/stop.mp3"))

            // A regular *file* occupies the path where play.lock's parent directory needs
            // to be — FileLock's self-heal (`createDirectory`) cannot turn a file into a
            // directory, so `attemptLock` surfaces a real errno via `.failed`, and
            // `playSoundEvent` must forward it as `.lockFailed`, never silently as
            // `.skippedDebounce` (mirrors `FileLockSuite`'s equivalent test).
            let blockingFile = root.appendingPathComponent("blocking-file")
            writeFixture("not a directory", to: blockingFile)
            let unreachableLockFile =
                blockingFile
                .appendingPathComponent("subdir")
                .appendingPathComponent("play.lock")

            let spawner = RecordingSpawner()
            let logFile = root.appendingPathComponent("claudio.log")
            let logLockFile = root.appendingPathComponent("claudio.log.lock")
            let env = PlayEnvironment(
                lockFile: unreachableLockFile,
                configFile: configFile,
                userPacksDirectory: packsDir,
                bundledPacksDirectory: nil,
                spawner: spawner,
                debounceStateFile: root.appendingPathComponent("play.state"),
                logFile: logFile,
                logLockFile: logLockFile)

            let outcome = playSoundEvent("stop", environment: env)
            if case .lockFailed = outcome {
                // expected
            } else {
                expect(false, "expected .lockFailed, got \(outcome)")
            }
            expect(spawner.callCount == 0, "a real lock error must never spawn afplay")

            let entries = readRecentLogEntries(from: logFile)
            expect(
                entries.count == 1 && entries.first?.event == "stop",
                "a real .lockFailed must append exactly one claudio.log line for the event,"
                    + " got \(entries)")
        }
    }

    suite(
        "playSoundEvent: a spawn failure (e.g. missing/broken afplay) still reports .played"
            + " (T5 outcome contract unchanged) but appends a claudio.log diagnostic line (T6)"
    ) {
        withTempDirectory { root in
            let packsDir = root.appendingPathComponent("packs")
            let configFile = root.appendingPathComponent("config.json")
            writeFixture(#"{ "selected_pack": "minimal-chime" }"#, to: configFile)
            writeFixture(
                #"{ "id": "minimal-chime", "events": { "stop": "stop.mp3" } }"#,
                to: packsDir.appendingPathComponent("minimal-chime/manifest.json"))
            writeFixture(
                "fake-audio", to: packsDir.appendingPathComponent("minimal-chime/stop.mp3"))

            let spawner = FailingSpawner()
            let logFile = root.appendingPathComponent("claudio.log")
            let logLockFile = root.appendingPathComponent("claudio.log.lock")
            let env = PlayEnvironment(
                afplayPath: "/usr/bin/afplay",
                lockFile: root.appendingPathComponent("play.lock"),
                configFile: configFile,
                userPacksDirectory: packsDir,
                bundledPacksDirectory: nil,
                spawner: spawner,
                debounceStateFile: root.appendingPathComponent("play.state"),
                logFile: logFile,
                logLockFile: logLockFile)

            let outcome = playSoundEvent("stop", environment: env)
            expect(
                outcome
                    == .played(
                        event: .stop,
                        filePath: packsDir.appendingPathComponent("minimal-chime/stop.mp3")
                            .standardizedFileURL.path),
                "a spawn failure must NOT change the reported outcome — still .played, got"
                    + " \(outcome)")
            expect(spawner.callCount == 1, "the spawn must still have been attempted exactly once")

            let entries = readRecentLogEntries(from: logFile)
            expect(
                entries.count == 1 && entries.first?.event == "stop",
                "a spawn failure must append exactly one claudio.log line naming the event,"
                    + " got \(entries)")
            expect(
                entries.first?.reason.contains("afplay") == true,
                "the logged reason should mention afplay, got"
                    + " \(String(describing: entries.first?.reason))")
        }
    }

    suite(
        "playSoundEvent: a successful spawn never appends a claudio.log line"
    ) {
        withTempDirectory { root in
            let packsDir = root.appendingPathComponent("packs")
            let configFile = root.appendingPathComponent("config.json")
            writeFixture(#"{ "selected_pack": "minimal-chime" }"#, to: configFile)
            writeFixture(
                #"{ "id": "minimal-chime", "events": { "stop": "stop.mp3" } }"#,
                to: packsDir.appendingPathComponent("minimal-chime/manifest.json"))
            writeFixture(
                "fake-audio", to: packsDir.appendingPathComponent("minimal-chime/stop.mp3"))

            let spawner = RecordingSpawner()
            let logFile = root.appendingPathComponent("claudio.log")
            let logLockFile = root.appendingPathComponent("claudio.log.lock")
            let env = PlayEnvironment(
                lockFile: root.appendingPathComponent("play.lock"),
                configFile: configFile,
                userPacksDirectory: packsDir,
                bundledPacksDirectory: nil,
                spawner: spawner,
                debounceStateFile: root.appendingPathComponent("play.state"),
                logFile: logFile,
                logLockFile: logLockFile)

            _ = playSoundEvent("stop", environment: env)
            expect(
                readRecentLogEntries(from: logFile).isEmpty,
                "a healthy, successful play must never write a claudio.log line")
        }
    }

    suite(
        "playSoundEvent: high-frequency concurrent calls (subagent_stop) — exactly one truly enters the critical section, the rest are skipped"
    ) {
        withTempDirectory { root in
            let packsDir = root.appendingPathComponent("packs")
            let configFile = root.appendingPathComponent("config.json")
            writeFixture(#"{ "selected_pack": "minimal-chime" }"#, to: configFile)
            writeFixture(
                #"{ "id": "minimal-chime", "events": { "subagent_stop": "subagent_stop.mp3" } }"#,
                to: packsDir.appendingPathComponent("minimal-chime/manifest.json"))
            writeFixture(
                "fake-audio", to: packsDir.appendingPathComponent("minimal-chime/subagent_stop.mp3")
            )

            // Widen the critical section so a burst of concurrent calls reliably contend
            // on the same play.lock — a real afplay spawn is fast, but a real
            // high-frequency subagent_stop burst across concurrent Claude Code sessions
            // must still debounce safely no matter how long any one holder takes.
            let spawner = SlowRecordingSpawner(holdDuration: 0.3)
            let env = PlayEnvironment(
                lockFile: root.appendingPathComponent("play.lock"),
                configFile: configFile,
                userPacksDirectory: packsDir,
                bundledPacksDirectory: nil,
                spawner: spawner,
                debounceStateFile: root.appendingPathComponent("play.state"),
                logFile: root.appendingPathComponent("claudio.log"),
                logLockFile: root.appendingPathComponent("claudio.log.lock"))

            let iterations = 6
            let collector = OutcomeCollector()
            DispatchQueue.concurrentPerform(iterations: iterations) { _ in
                collector.append(playSoundEvent("subagent_stop", environment: env))
            }

            let outcomes = collector.outcomes
            let playedCount = outcomes.filter {
                if case .played = $0 { return true }
                return false
            }.count
            let skippedCount = outcomes.filter { $0 == .skippedDebounce }.count

            expect(
                outcomes.count == iterations,
                "every concurrent call must produce an outcome, got \(outcomes.count) of \(iterations)"
            )
            expect(
                playedCount == 1,
                "exactly one concurrent call must truly enter the critical section, got \(playedCount)"
            )
            expect(
                skippedCount == iterations - 1,
                "every other concurrent call must be skipped (not blocked, not crashed), got"
                    + " \(skippedCount) of \(iterations - 1)")
            expect(
                spawner.callCount == 1,
                "afplay must be spawned exactly once despite \(iterations) concurrent play calls"
                    + " (skip-style debounce), got \(spawner.callCount)")
        }
    }

    suite("playSoundEvent returns immediately without waiting for the spawned playback to finish") {
        withTempDirectory { root in
            let packsDir = root.appendingPathComponent("packs")
            let configFile = root.appendingPathComponent("config.json")
            writeFixture(#"{ "selected_pack": "minimal-chime" }"#, to: configFile)
            writeFixture(
                #"{ "id": "minimal-chime", "events": { "stop": "stop.mp3" } }"#,
                to: packsDir.appendingPathComponent("minimal-chime/manifest.json"))
            writeFixture(
                "fake-audio", to: packsDir.appendingPathComponent("minimal-chime/stop.mp3"))

            // Simulates a multi-second `afplay` playback: `spawn` returns instantly, but
            // the "playback" only finishes asynchronously, 0.3s later.
            let spawner = DelayedSignalSpawner(delay: 0.3)
            let env = PlayEnvironment(
                lockFile: root.appendingPathComponent("play.lock"),
                configFile: configFile,
                userPacksDirectory: packsDir,
                bundledPacksDirectory: nil,
                spawner: spawner,
                debounceStateFile: root.appendingPathComponent("play.state"),
                logFile: root.appendingPathComponent("claudio.log"),
                logLockFile: root.appendingPathComponent("claudio.log.lock"))

            let outcome = playSoundEvent("stop", environment: env)
            if case .played = outcome {
                // expected
            } else {
                expect(false, "expected .played, got \(outcome)")
            }
            expect(
                !spawner.finished,
                "playSoundEvent must return before the simulated 0.3s playback finishes — proves"
                    + " it never synchronously waits for the spawned process")
        }
    }

    suite(
        "SystemProcessSpawner.spawn launches a real background process without blocking the caller"
    ) {
        let spawner = SystemProcessSpawner()
        let start = Date()
        // A substitute for the real `afplay` — never invoke the actual system afplay in
        // tests. `/bin/sh -c "sleep 0.3"` exercises the real Process-based spawn path
        // end-to-end (no waitUntilExit) without playing any audio.
        spawner.spawn(executablePath: "/bin/sh", arguments: ["-c", "sleep 0.3"])
        let elapsed = Date().timeIntervalSince(start)
        expect(
            elapsed < 0.2,
            "SystemProcessSpawner.spawn must return immediately, not wait for the child process"
                + " to exit (took \(elapsed)s)")
    }

    suite("SystemProcessSpawner.spawn silently no-ops when the executable doesn't exist") {
        withTempDirectory { root in
            let spawner = SystemProcessSpawner()
            let missing = root.appendingPathComponent("no-such-binary").path
            // Must not throw, crash, or hang — `Process.run()`'s error is swallowed by
            // design (a missing afplay/executable is a silent "can't play yet" state, not
            // a hard failure that should ever reach the hook caller).
            spawner.spawn(executablePath: missing, arguments: ["whatever"])
            expect(true, "reaching this line means spawn(missing executable) didn't crash or hang")
        }
    }

    // MARK: - config.json / play.state must go through the bounded, regular-file-gated read
    //
    // `claudio play` runs on Claude Code's synchronous hook path, so a hostile/oversized
    // `~/.claudio/config.json` (or `play.state`) must never hang or crash it — it must fold
    // into the exact same silent `.notReady` every other "not configured yet" state already
    // takes. `loadClaudioConfig`/`readConfigFileBounded` (SafeFileRead.swift) is the single
    // gate `play`, `doctor`, and `probeConfigRewritable` all share (`ConfigMutationSuite.swift`
    // and `DoctorSuite.swift` cover the other two read entry points).

    suite(
        "playSoundEvent: config.json is a DIRECTORY -> .notReady, never spawns, never hangs"
    ) {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            try? FileManager.default.createDirectory(
                at: configFile, withIntermediateDirectories: true)

            let spawner = RecordingSpawner()
            let env = PlayEnvironment(
                lockFile: root.appendingPathComponent("play.lock"),
                configFile: configFile,
                userPacksDirectory: root.appendingPathComponent("packs"),
                bundledPacksDirectory: nil,
                spawner: spawner,
                debounceStateFile: root.appendingPathComponent("play.state"),
                logFile: root.appendingPathComponent("claudio.log"),
                logLockFile: root.appendingPathComponent("claudio.log.lock"))

            let started = Date()
            let outcome = playSoundEvent("stop", environment: env)
            let elapsed = Date().timeIntervalSince(started)
            expect(
                outcome == .notReady,
                "a directory-shaped config.json must report .notReady, got \(outcome)")
            expect(spawner.callCount == 0, "must never spawn afplay off an unreadable config")
            expect(
                elapsed < 5,
                "must never hang reading a directory-shaped config.json, took \(elapsed)s")
        }
    }

    suite("playSoundEvent: config.json is a FIFO -> .notReady, never spawns, never hangs") {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            makeFIFO(at: configFile)

            let spawner = RecordingSpawner()
            let env = PlayEnvironment(
                lockFile: root.appendingPathComponent("play.lock"),
                configFile: configFile,
                userPacksDirectory: root.appendingPathComponent("packs"),
                bundledPacksDirectory: nil,
                spawner: spawner,
                debounceStateFile: root.appendingPathComponent("play.state"),
                logFile: root.appendingPathComponent("claudio.log"),
                logLockFile: root.appendingPathComponent("claudio.log.lock"))

            let started = Date()
            let outcome = playSoundEvent("stop", environment: env)
            let elapsed = Date().timeIntervalSince(started)
            expect(
                outcome == .notReady, "a FIFO-shaped config.json must report .notReady, got \(outcome)"
            )
            expect(spawner.callCount == 0, "must never spawn afplay off an unreadable config")
            expect(elapsed < 5, "must never hang reading a FIFO-shaped config.json, took \(elapsed)s")
        }
    }

    suite(
        "playSoundEvent: a VALID (fully decodable) but oversize (> 64 KiB) config.json is"
            + " rejected by the size gate before ever resolving the pack it names -> .notReady,"
            + " never spawns (the pack it names is otherwise complete and playable — proving"
            + " this is the size bound doing the rejecting, not a coincidental decode failure)"
    ) {
        withTempDirectory { root in
            let packsDir = root.appendingPathComponent("packs")
            let configFile = root.appendingPathComponent("config.json")
            // The named pack is fully real and playable — if the size gate were ever
            // dropped in favor of a raw, unbounded `Data(contentsOf:)`, this exact file
            // reads and decodes just fine (it's valid JSON, merely padded past 64 KiB via
            // an unknown top-level key) and the pipeline would proceed all the way to a
            // real spawn. That is what makes this a genuine regression pin rather than a
            // fixture that would fail to decode either way.
            let padding = String(repeating: "x", count: (1 << 16) + 100)
            writeFixture(
                #"{ "selected_pack": "minimal-chime", "padding": "\#(padding)" }"#, to: configFile)
            writeFixture(
                #"{ "id": "minimal-chime", "events": { "stop": "stop.mp3" } }"#,
                to: packsDir.appendingPathComponent("minimal-chime/manifest.json"))
            writeFixture(
                "fake-audio", to: packsDir.appendingPathComponent("minimal-chime/stop.mp3"))

            let spawner = RecordingSpawner()
            let env = PlayEnvironment(
                lockFile: root.appendingPathComponent("play.lock"),
                configFile: configFile,
                userPacksDirectory: packsDir,
                bundledPacksDirectory: nil,
                spawner: spawner,
                debounceStateFile: root.appendingPathComponent("play.state"),
                logFile: root.appendingPathComponent("claudio.log"),
                logLockFile: root.appendingPathComponent("claudio.log.lock"))

            let outcome = playSoundEvent("stop", environment: env)
            expect(
                outcome == .notReady,
                "an oversize config.json must report .notReady even though the pack it names"
                    + " is otherwise complete and playable, got \(outcome)")
            expect(spawner.callCount == 0, "must never spawn afplay off an oversize config")
        }
    }

    suite(
        "playSoundEvent: play.state is a FIFO -> the debounce read never hangs, and the call"
            + " still plays (an unreadable state file means 'never debounced yet', not an error)"
    ) {
        withTempDirectory { root in
            let packsDir = root.appendingPathComponent("packs")
            let configFile = root.appendingPathComponent("config.json")
            writeFixture(#"{ "selected_pack": "minimal-chime" }"#, to: configFile)
            writeFixture(
                #"{ "id": "minimal-chime", "events": { "stop": "stop.mp3" } }"#,
                to: packsDir.appendingPathComponent("minimal-chime/manifest.json"))
            writeFixture(
                "fake-audio", to: packsDir.appendingPathComponent("minimal-chime/stop.mp3"))

            let debounceStateFile = root.appendingPathComponent("play.state")
            makeFIFO(at: debounceStateFile)

            let spawner = RecordingSpawner()
            let env = PlayEnvironment(
                lockFile: root.appendingPathComponent("play.lock"),
                configFile: configFile,
                userPacksDirectory: packsDir,
                bundledPacksDirectory: nil,
                spawner: spawner,
                debounceStateFile: debounceStateFile,
                logFile: root.appendingPathComponent("claudio.log"),
                logLockFile: root.appendingPathComponent("claudio.log.lock"))

            let started = Date()
            let outcome = playSoundEvent("stop", environment: env)
            let elapsed = Date().timeIntervalSince(started)
            expect(
                elapsed < 5,
                "a FIFO-shaped play.state must never hang the debounce read, took \(elapsed)s")
            let expectedFile =
                packsDir.appendingPathComponent("minimal-chime/stop.mp3").standardizedFileURL.path
            expect(
                outcome == .played(event: .stop, filePath: expectedFile),
                "an unreadable play.state must fold into 'never debounced yet', so this call"
                    + " must still play, got \(outcome)")
            expect(spawner.callCount == 1, "must actually spawn despite a FIFO-shaped play.state")
        }
    }
}
