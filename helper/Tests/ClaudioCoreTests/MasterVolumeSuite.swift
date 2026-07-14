import ClaudioCore
import Foundation

// MARK: - setMasterVolume: master-volume write-back (ENGINEERING.md 面板 UI 线框「🔊 主音量」)
//
// Mirrors `EventEnabledSuite.swift`'s structure exactly (which itself mirrors `UseSuite.swift`) —
// `setMasterVolume` shares `setEventEnabled`'s locking + atomic-write shape (flock + atomic write)
// AND its D23 定稿① missing-config policy (fail closed, never fabricate a selection), so its test
// coverage mirrors both: flip, clamp, field preservation, corrupt-abort, lock contention,
// missing-config fail-closed.

@MainActor
func runMasterVolumeSuites() {
    suite(
        "setMasterVolume: an existing config.json only changes master_volume, everything else survives"
    ) {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let lockFile = root.appendingPathComponent("config.lock")
            writeFixture(
                #"""
                { "selected_pack": "minimal-chime", "master_volume": 0.2, "events": { "notification": false } }
                """#, to: configFile)

            let result = setMasterVolume(0.65, configFile: configFile, lockFile: lockFile)
            expect(
                result == .success(.updated(volume: 0.65)),
                "setting an in-range volume should succeed with the exact value landed, got \(result)")

            let data = try? Data(contentsOf: configFile)
            let config = data.flatMap { try? JSONDecoder().decode(ClaudioConfig.self, from: $0) }
            expect(
                config?.selectedPack == "minimal-chime",
                "selected_pack must survive a volume change untouched")
            expect(config?.masterVolume == 0.65, "master_volume must reflect the new value")
            expect(
                config?.isEnabled(.notification) == false,
                "a pre-existing event override must survive a volume change untouched")
        }
    }

    suite("setMasterVolume: a value above 1.0 clamps to 1.0 via AfplayVolume.clamped, never written raw") {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let lockFile = root.appendingPathComponent("config.lock")
            writeFixture(#"{ "selected_pack": "minimal-chime" }"#, to: configFile)

            let result = setMasterVolume(1.7, configFile: configFile, lockFile: lockFile)
            expect(
                result == .success(.updated(volume: 1.0)),
                "an out-of-range-high volume must clamp to 1.0, got \(result)")

            let data = try? Data(contentsOf: configFile)
            let config = data.flatMap { try? JSONDecoder().decode(ClaudioConfig.self, from: $0) }
            expect(
                config?.masterVolume == 1.0,
                "the value that landed on disk must already be clamped, got"
                    + " \(String(describing: config?.masterVolume))")
        }
    }

    suite("setMasterVolume: a value below 0.0 clamps to 0.0 via AfplayVolume.clamped, never written raw") {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let lockFile = root.appendingPathComponent("config.lock")
            writeFixture(#"{ "selected_pack": "minimal-chime" }"#, to: configFile)

            let result = setMasterVolume(-0.3, configFile: configFile, lockFile: lockFile)
            expect(
                result == .success(.updated(volume: 0.0)),
                "an out-of-range-low volume must clamp to 0.0, got \(result)")

            let data = try? Data(contentsOf: configFile)
            let config = data.flatMap { try? JSONDecoder().decode(ClaudioConfig.self, from: $0) }
            expect(
                config?.masterVolume == 0.0,
                "the value that landed on disk must already be clamped, got"
                    + " \(String(describing: config?.masterVolume))")
        }
    }

    suite("setMasterVolume: a literal negative zero clamps to a clean +0.0, not a rendered -0.0") {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let lockFile = root.appendingPathComponent("config.lock")
            writeFixture(#"{ "selected_pack": "minimal-chime" }"#, to: configFile)

            let result = setMasterVolume(-0.0, configFile: configFile, lockFile: lockFile)
            guard case .success(.updated(let landed)) = result else {
                expect(false, "negative zero must still succeed, got \(result)")
                return
            }
            expect(
                landed.sign == .plus,
                "landed volume's sign must be normalized to +0.0, got sign \(landed.sign)")

            let rawContents = try? String(contentsOf: configFile, encoding: .utf8)
            expect(
                rawContents?.contains("-0") != true,
                "the on-disk rendering must never contain a literal -0, got"
                    + " \(String(describing: rawContents))")
        }
    }

    suite(
        "setMasterVolume: non-finite input (NaN/±infinity) falls back to the documented default,"
            + " never reaches the encoder raw"
    ) {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let lockFile = root.appendingPathComponent("config.lock")
            writeFixture(#"{ "selected_pack": "minimal-chime" }"#, to: configFile)

            for input in [Double.nan, Double.infinity, -Double.infinity] {
                let result = setMasterVolume(input, configFile: configFile, lockFile: lockFile)
                expect(
                    result == .success(.updated(volume: ClaudioConfig.defaultMasterVolume)),
                    "a non-finite input (\(input)) must land as the documented default, got \(result)")
            }
        }
    }

    suite(
        "setMasterVolume: a missing config.json fails closed with .configMissing and creates nothing"
            + "（同 setEventEnabled 的 D23 定稿①：这个调用没有任何 pack 上下文，凭空新建等于伪造一次谁也"
            + " 没做过的选择——这个签名从一开始就没有 freshSelectedPack 参数，D13 已判死）"
    ) {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let lockFile = root.appendingPathComponent("config.lock")

            let result = setMasterVolume(0.5, configFile: configFile, lockFile: lockFile)
            expect(
                result == .failure(.configMissing),
                "setting the volume with no config.json must fail closed, got \(result)")
            expect(
                !FileManager.default.fileExists(atPath: configFile.path),
                "a rejected volume write must not leave any config.json behind — mutation check:"
                    + " flipping performSetMasterVolume's `onMissing: .failClosed` back to"
                    + " `.createFresh(selectedPack: \"\")` must turn this RED")
        }
    }

    suite("setMasterVolume: a corrupt existing config.json aborts without overwriting it") {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let lockFile = root.appendingPathComponent("config.lock")
            writeFixture("{ not valid json", to: configFile)

            let result = setMasterVolume(0.5, configFile: configFile, lockFile: lockFile)
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
        "setMasterVolume: an existing-but-unreadable config.json (a directory at its path) fails with .configReadFailure"
    ) {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let lockFile = root.appendingPathComponent("config.lock")
            try? FileManager.default.createDirectory(at: configFile, withIntermediateDirectories: true)

            let result = setMasterVolume(0.5, configFile: configFile, lockFile: lockFile)
            guard case .failure(.configReadFailure(let reason)) = result else {
                expect(false, "an unreadable config.json must fail with .configReadFailure, got \(result)")
                return
            }
            expect(
                reason.contains("无法读取"),
                "an unreadable (not merely corrupt) config.json must carry the read-failure reason,"
                    + " got \(reason)")
        }
    }

    suite(
        "setMasterVolume: a contended lock fails with .lockBusy instead of silently losing the write"
    ) {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let lockFile = root.appendingPathComponent("config.lock")
            let original = #"{ "selected_pack": "minimal-chime", "master_volume": 0.3 }"#
            writeFixture(original, to: configFile)

            let holder = FileLock(path: lockFile.path)
            expect(holder.tryLock(), "test setup: holder must acquire config.lock first")

            let result = setMasterVolume(0.9, configFile: configFile, lockFile: lockFile)
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
        "setMasterVolume: a real lock filesystem error is reported as .lockFailed, never conflated with .lockBusy"
    ) {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let original = #"{ "selected_pack": "minimal-chime" }"#
            writeFixture(original, to: configFile)

            // A regular *file* occupies the path where config.lock's parent directory needs to
            // be — mirrors `EventEnabledSuite`/`PlaySuite`/`FileLockSuite`'s equivalent fixture.
            let blockingFile = root.appendingPathComponent("blocking-file")
            writeFixture("not a directory", to: blockingFile)
            let unreachableLockFile =
                blockingFile.appendingPathComponent("subdir").appendingPathComponent("config.lock")

            let result = setMasterVolume(0.5, configFile: configFile, lockFile: unreachableLockFile)
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

    suite("setMasterVolume: a write failure is reported as .configWriteFailure, never a silent success") {
        guard geteuid() != 0 else {
            print("  ⚠︎ 跳过：当前以 root 运行，chmod 只读目录挡不住 root 写入")
            return
        }
        withTempDirectory { root in
            let restrictedDirectory = root.appendingPathComponent("restricted", isDirectory: true)
            try? FileManager.default.createDirectory(
                at: restrictedDirectory, withIntermediateDirectories: true)
            let configFile = restrictedDirectory.appendingPathComponent("config.json")
            let lockFile = root.appendingPathComponent("config.lock")
            writeFixture(#"{ "selected_pack": "pika" }"#, to: configFile)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o500], ofItemAtPath: restrictedDirectory.path)
            defer {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o700], ofItemAtPath: restrictedDirectory.path)
            }

            let result = setMasterVolume(0.5, configFile: configFile, lockFile: lockFile)
            guard case .failure(.configWriteFailure) = result else {
                expect(
                    false,
                    "an existing config.json whose directory is read-only must fail with"
                        + " .configWriteFailure, got \(result)")
                return
            }
        }
    }

    suite(
        "setMasterVolume: unknown top-level keys, events, and selected_pack all survive untouched"
    ) {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let lockFile = root.appendingPathComponent("config.lock")
            writeFixture(
                #"""
                { "selected_pack": "pikachu", "master_volume": 0.1, "night_dim": true, "events": { "stop": false, "notification": true } }
                """#, to: configFile)

            let result = setMasterVolume(0.77, configFile: configFile, lockFile: lockFile)
            expect(
                result == .success(.updated(volume: 0.77)),
                "setup: volume change should succeed, got \(result)")

            guard let data = try? Data(contentsOf: configFile),
                let parsed = try? JSONSerialization.jsonObject(with: data),
                let json = parsed as? [String: Any]
            else {
                expect(false, "config.json must remain valid JSON after a volume change")
                return
            }
            expect(
                json["selected_pack"] as? String == "pikachu",
                "selected_pack is not owned by setMasterVolume, must be untouched")
            expect(json["night_dim"] as? Bool == true, "an unknown top-level key must survive verbatim")
            let events = json["events"] as? [String: Any]
            expect(events?["stop"] as? Bool == false, "sibling events keys must survive untouched")
            expect(events?["notification"] as? Bool == true, "sibling events keys must survive untouched")
            expect(json["master_volume"] as? Double == 0.77, "master_volume must reflect the new value")
        }
    }

    suite("SetMasterVolumeError: every case carries a distinct, human-readable description") {
        // `CustomStringConvertible` here is a user-facing surface (the same shape `setEventEnabled`'s
        // own errors take), so its five messages are behavior, not decoration.
        let messages = [
            SetMasterVolumeError.configReadFailure(reason: "boom").description,
            SetMasterVolumeError.configWriteFailure(reason: "boom").description,
            SetMasterVolumeError.lockBusy.description,
            SetMasterVolumeError.lockFailed(errno: 13).description,
            SetMasterVolumeError.configMissing.description,
        ]
        expect(
            Set(messages).count == 5, "each error case must render a distinct message, got \(messages)")
        expect(
            messages[0].contains("未修改文件"),
            "a read failure must promise the file was left untouched, got \(messages[0])")
        expect(messages[1].contains("写入失败"), "got \(messages[1])")
        expect(messages[2].contains("请稍后重试"), "a busy lock must tell the user to retry, got \(messages[2])")
        expect(messages[3].contains("13"), "a lock failure must surface the real errno, got \(messages[3])")
        expect(
            messages[4].contains("选") && messages[4].contains("config.json"),
            "a missing-config failure must point the user at picking a pack, got \(messages[4])")
    }

    suite(
        "setMasterVolume: shares config.lock with selectPack and setEventEnabled — all three serialize on the same lock"
    ) {
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
                "setup: setEventEnabled succeeds")

            let volumeResult = setMasterVolume(0.42, configFile: configFile, lockFile: lockFile)
            expect(
                volumeResult == .success(.updated(volume: 0.42)),
                "setMasterVolume after selectPack + setEventEnabled (same lock file) must still"
                    + " succeed, got \(volumeResult)")

            let data = try? Data(contentsOf: configFile)
            let config = data.flatMap { try? JSONDecoder().decode(ClaudioConfig.self, from: $0) }
            expect(
                config?.selectedPack == "minimal-chime",
                "the pack selection from the first call must survive")
            expect(config?.isEnabled(.subagentStop) == false, "the mute flip from the second call must survive")
            expect(config?.masterVolume == 0.42, "the volume change must be reflected")
        }
    }
}
