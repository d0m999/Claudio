import ClaudioCore
import Dispatch
import Foundation

// MARK: - setEventEnabled: per-event mute write-back (ENGINEERING.md 决议③, T15 D4)
//
// Mirrors `UseSuite.swift`'s structure exactly — `setEventEnabled` mirrors `selectPack`'s
// shape (flock + read-or-create + atomic write), so its test coverage mirrors `selectPack`'s
// too: flip, field preservation, fresh-create, corrupt-abort, lock contention.

/// Thread-safe collector for outcomes produced by concurrent `setEventEnabled` calls.
/// Mirrors `PlaySuite.swift`'s `OutcomeCollector` — that one is file-scope `private` there,
/// so this file needs its own copy over `Result<SetEventEnabledOutcome, SetEventEnabledError>`.
private final class SetEventEnabledOutcomeCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var _outcomes: [Result<SetEventEnabledOutcome, SetEventEnabledError>] = []

    func append(_ outcome: Result<SetEventEnabledOutcome, SetEventEnabledError>) {
        lock.lock()
        _outcomes.append(outcome)
        lock.unlock()
    }

    var outcomes: [Result<SetEventEnabledOutcome, SetEventEnabledError>] {
        lock.lock()
        defer { lock.unlock() }
        return _outcomes
    }
}

@MainActor
func runEventEnabledSuites() {
    suite("setEventEnabled: fresh install creates config.json with just that one flag set") {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let lockFile = root.appendingPathComponent("config.lock")

            let result = setEventEnabled(.stop, enabled: false, configFile: configFile, lockFile: lockFile)
            expect(
                result == .success(.updated(event: .stop, enabled: false)),
                "flipping on a fresh install should succeed, got \(result)")

            let data = try? Data(contentsOf: configFile)
            let config = data.flatMap { try? JSONDecoder().decode(ClaudioConfig.self, from: $0) }
            expect(config?.isEnabled(.stop) == false, "the written config.json must reflect the flip")
            expect(
                config?.selectedPack == "",
                "a fresh config.json created with no pack context has an empty selected_pack"
                    + " (never a guessed default), got \(String(describing: config?.selectedPack))")
        }
    }

    suite("setEventEnabled: an existing config.json only changes the one event, everything else survives") {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let lockFile = root.appendingPathComponent("config.lock")
            writeFixture(
                #"""
                { "selected_pack": "minimal-chime", "master_volume": 0.42, "events": { "notification": false } }
                """#, to: configFile)

            let result = setEventEnabled(
                .stopFailure, enabled: false, configFile: configFile, lockFile: lockFile)
            expect(
                result == .success(.updated(event: .stopFailure, enabled: false)),
                "flipping an existing config should succeed, got \(result)")

            let data = try? Data(contentsOf: configFile)
            let config = data.flatMap { try? JSONDecoder().decode(ClaudioConfig.self, from: $0) }
            expect(
                config?.selectedPack == "minimal-chime",
                "selected_pack must survive a mute toggle untouched")
            expect(
                config?.masterVolume == 0.42, "master_volume must survive a mute toggle untouched")
            expect(
                config?.isEnabled(.notification) == false,
                "a sibling event's pre-existing override must survive untouched")
            expect(
                config?.isEnabled(.stopFailure) == false, "the target event must reflect the new value")
            expect(
                config?.isEnabled(.stop) == true,
                "an event never mentioned in config.json still defaults to enabled")
        }
    }

    suite("setEventEnabled: toggling back to true clears the muted state") {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let lockFile = root.appendingPathComponent("config.lock")
            writeFixture(
                #"{ "selected_pack": "minimal-chime", "events": { "stop": false } }"#, to: configFile)

            let result = setEventEnabled(.stop, enabled: true, configFile: configFile, lockFile: lockFile)
            expect(
                result == .success(.updated(event: .stop, enabled: true)),
                "toggling back on should succeed, got \(result)")

            let data = try? Data(contentsOf: configFile)
            let config = data.flatMap { try? JSONDecoder().decode(ClaudioConfig.self, from: $0) }
            expect(config?.isEnabled(.stop) == true, "the event must now read back as enabled")
        }
    }

    suite("setEventEnabled: a corrupt existing config.json aborts without overwriting it") {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let lockFile = root.appendingPathComponent("config.lock")
            writeFixture("{ not valid json", to: configFile)

            let result = setEventEnabled(.stop, enabled: false, configFile: configFile, lockFile: lockFile)
            guard case .failure(.configReadFailure) = result else {
                expect(false, "corrupt config.json must fail with .configReadFailure, got \(result)")
                return
            }
            let rawContents = try? String(contentsOf: configFile, encoding: .utf8)
            expect(
                rawContents == "{ not valid json",
                "a read failure must leave the corrupt file byte-for-byte untouched")
        }
    }

    suite(
        "setEventEnabled: a contended lock fails with .lockBusy instead of silently losing the write"
    ) {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let lockFile = root.appendingPathComponent("config.lock")
            let original = #"{ "selected_pack": "minimal-chime", "events": { "stop": true } }"#
            writeFixture(original, to: configFile)

            let holder = FileLock(path: lockFile.path)
            expect(holder.tryLock(), "test setup: holder must acquire config.lock first")

            let result = setEventEnabled(.stop, enabled: false, configFile: configFile, lockFile: lockFile)
            expect(
                result == .failure(.lockBusy),
                "a contended lock must report .lockBusy, not silently succeed, got \(result)")

            holder.unlock()

            let rawContents = try? String(contentsOf: configFile, encoding: .utf8)
            expect(
                rawContents == original,
                "a lock-contended call must never touch config.json — the prior contents must"
                    + " survive byte-for-byte, got \(String(describing: rawContents))")
        }
    }

    suite(
        "setEventEnabled: a real lock filesystem error is reported as .lockFailed, never conflated with .lockBusy"
    ) {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let original = #"{ "selected_pack": "minimal-chime" }"#
            writeFixture(original, to: configFile)

            // A regular *file* occupies the path where config.lock's parent directory needs to
            // be — `FileLock`'s ENOENT self-heal (`createDirectory`) cannot turn a file into a
            // directory, so `attemptLock` surfaces a real errno via `.failed` (mirrors
            // `PlaySuite`/`FileLockSuite`'s equivalent fixtures). `.lockFailed` and `.lockBusy`
            // must stay distinct: a broken filesystem is not a "someone else is writing, retry"
            // debounce skip.
            let blockingFile = root.appendingPathComponent("blocking-file")
            writeFixture("not a directory", to: blockingFile)
            let unreachableLockFile =
                blockingFile.appendingPathComponent("subdir").appendingPathComponent("config.lock")

            let result = setEventEnabled(
                .stop, enabled: false, configFile: configFile, lockFile: unreachableLockFile)
            guard case .failure(.lockFailed) = result else {
                expect(false, "a real lock system error must report .lockFailed, got \(result)")
                return
            }
            expect(
                result != .failure(.lockBusy),
                "a filesystem failure must never be reported as mere contention")
            expect(
                (try? String(contentsOf: configFile, encoding: .utf8)) == original,
                "a lock-failed call must never touch config.json")
        }
    }

    suite(
        "setEventEnabled: an existing-but-unreadable config.json (a directory at its path) fails with .configReadFailure"
    ) {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let lockFile = root.appendingPathComponent("config.lock")
            // `FileManager.fileExists(atPath:)` answers `true` for a DIRECTORY too, so this
            // takes the "file exists" branch and then fails the `Data(contentsOf:)` read —
            // the read-failure path distinct from the decode-failure one above (they carry
            // different reasons: "无法读取" vs "解析失败").
            try? FileManager.default.createDirectory(at: configFile, withIntermediateDirectories: true)

            let result = setEventEnabled(.stop, enabled: false, configFile: configFile, lockFile: lockFile)
            guard case .failure(.configReadFailure(let reason)) = result else {
                expect(false, "an unreadable config.json must fail with .configReadFailure, got \(result)")
                return
            }
            expect(
                reason.contains("无法读取"),
                "an unreadable (not merely corrupt) config.json must carry the read-failure reason,"
                    + " not the parse-failure one, got \(reason)")
        }
    }

    suite("setEventEnabled: a write failure is reported as .configWriteFailure, never a silent success") {
        withTempDirectory { root in
            let lockFile = root.appendingPathComponent("config.lock")
            // A regular file occupies the path where config.json's PARENT directory would have
            // to be, so `createDirectory(withIntermediateDirectories:)` in the persist step
            // throws — the `.configWriteFailure` branch (previously the only `setEventEnabled`
            // outcome with no test at all).
            let blockingFile = root.appendingPathComponent("blocking-file")
            writeFixture("not a directory", to: blockingFile)
            let unwritableConfigFile = blockingFile.appendingPathComponent("config.json")

            let result = setEventEnabled(
                .stop, enabled: false, configFile: unwritableConfigFile, lockFile: lockFile)
            guard case .failure(.configWriteFailure) = result else {
                expect(false, "an unwritable config.json must fail with .configWriteFailure, got \(result)")
                return
            }
            expect(
                !FileManager.default.fileExists(atPath: unwritableConfigFile.path),
                "a failed write must not leave a config.json behind")
        }
    }

    suite("SetEventEnabledError: every case carries a distinct, human-readable description") {
        // `CustomStringConvertible` here is a user-facing surface (the same shape `selectPack`'s
        // own errors take), so its four messages are behavior, not decoration.
        let messages = [
            SetEventEnabledError.configReadFailure(reason: "boom").description,
            SetEventEnabledError.configWriteFailure(reason: "boom").description,
            SetEventEnabledError.lockBusy.description,
            SetEventEnabledError.lockFailed(errno: 13).description,
        ]
        expect(
            Set(messages).count == 4, "each error case must render a distinct message, got \(messages)")
        expect(
            messages[0].contains("未修改文件"),
            "a read failure must promise the file was left untouched, got \(messages[0])")
        expect(messages[1].contains("写入失败"), "got \(messages[1])")
        expect(messages[2].contains("请稍后重试"), "a busy lock must tell the user to retry, got \(messages[2])")
        expect(messages[3].contains("13"), "a lock failure must surface the real errno, got \(messages[3])")
    }

    suite("setEventEnabled: shares config.lock with selectPack — the two calls serialize on the same lock") {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let userPacks = root.appendingPathComponent("packs", isDirectory: true)
            let lockFile = root.appendingPathComponent("config.lock")
            try? FileManager.default.createDirectory(
                at: userPacks.appendingPathComponent("minimal-chime", isDirectory: true),
                withIntermediateDirectories: true)

            let selectResult = selectPack(
                "minimal-chime", configFile: configFile, userPacksDirectory: userPacks,
                lockFile: lockFile)
            expect(selectResult == .success(.selected(packID: "minimal-chime")), "setup: selectPack succeeds")

            let muteResult = setEventEnabled(
                .subagentStop, enabled: false, configFile: configFile, lockFile: lockFile)
            expect(
                muteResult == .success(.updated(event: .subagentStop, enabled: false)),
                "setEventEnabled after selectPack (same lock file) must still succeed, got \(muteResult)")

            let data = try? Data(contentsOf: configFile)
            let config = data.flatMap { try? JSONDecoder().decode(ClaudioConfig.self, from: $0) }
            expect(
                config?.selectedPack == "minimal-chime",
                "the pack selection from the first call must survive the second call untouched")
            expect(config?.isEnabled(.subagentStop) == false, "the mute flip must be reflected")
        }
    }

    // MARK: - 真并发写：这条 read-modify-write 新近才被纳入 config.lock（本轮 /ship 覆盖率审计 #1）
    //
    // 之前只测过「1 个持有者 + 1 个等待者」这种锁竞争，从没有一条测试真正证明过并发写不会撕裂
    // config.json。1:1 镜像 `PlaySuite.swift` 里那条 `DispatchQueue.concurrentPerform` 压力测试
    // 的写法（那条证明的是「恰好一次真正播放」；这条证明的是「文件永远不撕裂、旧键永远不丢」）。

    suite(
        "setEventEnabled: N 个并发写者打在同一个 config.json 上——写完之后文件仍是合法 JSON、三个 v1"
            + " 键与一个未知顶层键全都还在，且每一次调用要么真的成功要么 .lockBusy，绝不静默损坏"
    ) {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let lockFile = root.appendingPathComponent("config.lock")
            writeFixture(
                #"""
                { "selected_pack": "minimal-chime", "master_volume": 0.5, "night_dim": true, "events": { "stop": true } }
                """#, to: configFile)

            let collector = SetEventEnabledOutcomeCollector()
            let iterations = 50
            DispatchQueue.concurrentPerform(iterations: iterations) { index in
                let event = Event.allCases[index % Event.allCases.count]
                let enabled = index % 2 == 0
                let result = setEventEnabled(
                    event, enabled: enabled, configFile: configFile, lockFile: lockFile)
                collector.append(result)
            }

            let outcomes = collector.outcomes
            expect(
                outcomes.count == iterations,
                "every concurrent call must produce an outcome, got \(outcomes.count) of \(iterations)"
            )

            for (index, outcome) in outcomes.enumerated() {
                switch outcome {
                case .success, .failure(.lockBusy):
                    break
                default:
                    expect(
                        false,
                        "call \(index) must be either a real success or .lockBusy — never a"
                            + " torn/corrupted write, got \(outcome)")
                }
            }

            // (a) 文件必须仍然是合法、可解析的 JSON——撕裂的写在这里会直接解析失败。
            guard let data = try? Data(contentsOf: configFile),
                let parsed = try? JSONSerialization.jsonObject(with: data),
                let json = parsed as? [String: Any]
            else {
                expect(
                    false,
                    "经过 \(iterations) 个并发写者之后，config.json 必须仍是一份合法、可解析的 JSON")
                return
            }
            // (b) + (c) 三个 v1 键与那个未知顶层键必须一个不少——并发写绝不能让任何一方的键集合丢失。
            expect(
                Set(json.keys) == Set(["selected_pack", "master_volume", "events", "night_dim"]),
                "并发写之后顶层键集合必须逐一保留（已知键 + 未知键），got \(json.keys.sorted())")
            expect(
                json["night_dim"] as? Bool == true,
                "未知顶层键的值必须原样幸存，got \(String(describing: json["night_dim"]))")
            expect(
                json["selected_pack"] as? String == "minimal-chime",
                "selected_pack 不归 setEventEnabled 拥有，必须纹丝不动，got"
                    + " \(String(describing: json["selected_pack"]))")
            let events = json["events"] as? [String: Any]
            expect(
                events != nil && !(events!.isEmpty),
                "events 表必须仍然存在且非空——并发写不能把它写没了")
        }
    }
}
