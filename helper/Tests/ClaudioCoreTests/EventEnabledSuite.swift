import ClaudioCore
import Foundation

// MARK: - setEventEnabled: per-event mute write-back (ENGINEERING.md 决议③, T15 D4)
//
// Mirrors `UseSuite.swift`'s structure exactly — `setEventEnabled` mirrors `selectPack`'s
// shape (flock + read-or-create + atomic write), so its test coverage mirrors `selectPack`'s
// too: flip, field preservation, fresh-create, corrupt-abort, lock contention.

@MainActor
func runEventEnabledSuites() {
    suite("setEventEnabled: fresh install creates config.json with just that one flag set") {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let lockFile = root.appendingPathComponent("play.lock")

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
            let lockFile = root.appendingPathComponent("play.lock")
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
            let lockFile = root.appendingPathComponent("play.lock")
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
            let lockFile = root.appendingPathComponent("play.lock")
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
            let lockFile = root.appendingPathComponent("play.lock")
            let original = #"{ "selected_pack": "minimal-chime", "events": { "stop": true } }"#
            writeFixture(original, to: configFile)

            let holder = FileLock(path: lockFile.path)
            expect(holder.tryLock(), "test setup: holder must acquire play.lock first")

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

            // A regular *file* occupies the path where play.lock's parent directory needs to
            // be — `FileLock`'s ENOENT self-heal (`createDirectory`) cannot turn a file into a
            // directory, so `attemptLock` surfaces a real errno via `.failed` (mirrors
            // `PlaySuite`/`FileLockSuite`'s equivalent fixtures). `.lockFailed` and `.lockBusy`
            // must stay distinct: a broken filesystem is not a "someone else is writing, retry"
            // debounce skip.
            let blockingFile = root.appendingPathComponent("blocking-file")
            writeFixture("not a directory", to: blockingFile)
            let unreachableLockFile =
                blockingFile.appendingPathComponent("subdir").appendingPathComponent("play.lock")

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
            let lockFile = root.appendingPathComponent("play.lock")
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
            let lockFile = root.appendingPathComponent("play.lock")
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

    suite("setEventEnabled: shares play.lock with selectPack — the two calls serialize on the same lock") {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let userPacks = root.appendingPathComponent("packs", isDirectory: true)
            let lockFile = root.appendingPathComponent("play.lock")
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
}
