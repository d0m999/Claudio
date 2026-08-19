import ClaudioCore
import Foundation

// MARK: - claudio use: config.json 归属 (ENGINEERING.md「工程落地细节 ⑥」, T17)
//
// `selectPack` validates the pack the exact same way `play` resolves it
// (`resolvePackDirectory`), then writes `config.json`: fresh-create when absent, or
// update-only-`selected_pack`-preserve-the-rest when one already exists.

@MainActor
private func makePackDirectory(at url: URL) {
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    writeFixture(#"{ "id": "test-pack", "events": {} }"#, to: url.appendingPathComponent("manifest.json"))
}

@MainActor
func runUseSuites() {
    suite("selectPack: rejects an unsafe pack id without touching the filesystem") {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let userPacks = root.appendingPathComponent("packs", isDirectory: true)

            let result = selectPack(
                "../evil", configFile: configFile, userPacksDirectory: userPacks,
                lockFile: root.appendingPathComponent("config.lock"))
            expect(
                result == .failure(.invalidPackID("../evil")),
                "path-traversal-shaped id must be rejected before any pack lookup, got \(result)")
            expect(
                !FileManager.default.fileExists(atPath: configFile.path),
                "an invalid id must never create config.json")
        }
    }

    suite("selectPack: fails when the pack doesn't exist in either root") {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let userPacks = root.appendingPathComponent("packs", isDirectory: true)

            let result = selectPack(
                "ghost-pack", configFile: configFile, userPacksDirectory: userPacks,
                lockFile: root.appendingPathComponent("config.lock"))
            expect(
                result == .failure(.packNotFound("ghost-pack")),
                "a pack id that resolves nowhere must fail with .packNotFound, got \(result)")
            expect(
                !FileManager.default.fileExists(atPath: configFile.path),
                "a not-found pack must never create config.json")
        }
    }

    suite("selectPack: fresh install creates config.json with defaults + the selected pack") {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let userPacks = root.appendingPathComponent("packs", isDirectory: true)
            makePackDirectory(at: userPacks.appendingPathComponent("minimal-chime", isDirectory: true))

            let result = selectPack(
                "minimal-chime", configFile: configFile, userPacksDirectory: userPacks,
                lockFile: root.appendingPathComponent("config.lock"))
            expect(
                result == .success(.selected(packID: "minimal-chime")),
                "selecting an existing pack on a fresh install should succeed, got \(result)")

            let data = try? Data(contentsOf: configFile)
            let config = data.flatMap { try? JSONDecoder().decode(ClaudioConfig.self, from: $0) }
            expect(config?.selectedPack == "minimal-chime", "written config.json selects the pack")
            expect(
                config?.masterVolume == ClaudioConfig.defaultMasterVolume,
                "a fresh config.json gets the documented default master_volume")
            expect(config?.eventsEnabled.isEmpty == true, "a fresh config.json has no per-event overrides")
        }
    }

    suite("selectPack: an existing config.json keeps master_volume/events, only selected_pack changes") {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let userPacks = root.appendingPathComponent("packs", isDirectory: true)
            makePackDirectory(at: userPacks.appendingPathComponent("old-pack", isDirectory: true))
            makePackDirectory(at: userPacks.appendingPathComponent("new-pack", isDirectory: true))
            writeFixture(
                #"""
                { "selected_pack": "old-pack", "master_volume": 0.3, "events": { "stop": false } }
                """#, to: configFile)

            let result = selectPack(
                "new-pack", configFile: configFile, userPacksDirectory: userPacks,
                lockFile: root.appendingPathComponent("config.lock"))
            expect(
                result == .success(.selected(packID: "new-pack")),
                "switching to another existing pack should succeed, got \(result)")

            let data = try? Data(contentsOf: configFile)
            let config = data.flatMap { try? JSONDecoder().decode(ClaudioConfig.self, from: $0) }
            expect(config?.selectedPack == "new-pack", "selected_pack updated to the new pack")
            expect(
                config?.masterVolume == 0.3,
                "pre-existing master_volume must survive a pack switch untouched")
            expect(
                config?.isEnabled(.stop) == false,
                "pre-existing per-event overrides must survive a pack switch untouched")
        }
    }

    suite("selectPack: a pack that only exists in the bundled root still resolves") {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let userPacks = root.appendingPathComponent("packs", isDirectory: true)
            let bundledPacks = root.appendingPathComponent("bundled-packs", isDirectory: true)
            makePackDirectory(at: bundledPacks.appendingPathComponent("minimal-chime", isDirectory: true))

            let result = selectPack(
                "minimal-chime", configFile: configFile, userPacksDirectory: userPacks,
                bundledPacksDirectory: bundledPacks,
                lockFile: root.appendingPathComponent("config.lock"))
            expect(
                result == .success(.selected(packID: "minimal-chime")),
                "a pack that only exists in the bundled fallback root must still be selectable, got \(result)"
            )
        }
    }

    suite(
        "selectPack: a configFile whose parent directory is blocked by a regular file fails with .configWriteFailure"
    ) {
        withTempDirectory { root in
            let userPacks = root.appendingPathComponent("packs", isDirectory: true)
            makePackDirectory(at: userPacks.appendingPathComponent("minimal-chime", isDirectory: true))

            // A regular file occupies the path where config.json's parent directory needs
            // to be created — `createDirectory` cannot turn a file into a directory, so the
            // write step surfaces a real error via `.configWriteFailure` (mirrors
            // `PlaySuite`'s equivalent blocking-file fixture for `.lockFailed`). No existing
            // suite in this file exercises `selectPack`'s write-failure path at all.
            let blockingFile = root.appendingPathComponent("blocking-file")
            writeFixture("not a directory", to: blockingFile)
            let configFile = blockingFile.appendingPathComponent("subdir/config.json")

            let result = selectPack(
                "minimal-chime", configFile: configFile, userPacksDirectory: userPacks,
                lockFile: root.appendingPathComponent("config.lock"))
            guard case .failure(.configWriteFailure) = result else {
                expect(
                    false,
                    "a blocked config parent directory must fail with .configWriteFailure, got \(result)"
                )
                return
            }
        }
    }

    suite("selectPack: a corrupt existing config.json aborts without overwriting it") {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let userPacks = root.appendingPathComponent("packs", isDirectory: true)
            makePackDirectory(at: userPacks.appendingPathComponent("minimal-chime", isDirectory: true))
            writeFixture("{ not valid json", to: configFile)

            let result = selectPack(
                "minimal-chime", configFile: configFile, userPacksDirectory: userPacks,
                lockFile: root.appendingPathComponent("config.lock"))
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
        "selectPack: a contended lock fails with .lockBusy instead of silently losing the write (Codex + red team, T17)"
    ) {
        withTempDirectory { root in
            // Regression test: before this fix, selectPack had no lock at all — two
            // concurrent writers could race on config.json's read-modify-write and one
            // update would silently vanish. It now takes `config.lock`, which it shares
            // with the only other config.json writer (`setEventEnabled`) and with nobody
            // else — deliberately NOT `settings.json`'s lock, and deliberately NOT
            // `play`'s debounce lock (阶段 A 锁分离). Contention must surface as a real,
            // distinct error, never a silent no-op reported as success.
            let configFile = root.appendingPathComponent("config.json")
            let userPacks = root.appendingPathComponent("packs", isDirectory: true)
            let lockFile = root.appendingPathComponent("config.lock")
            makePackDirectory(at: userPacks.appendingPathComponent("minimal-chime", isDirectory: true))
            writeFixture(
                #"{ "selected_pack": "old-pack", "master_volume": 0.3 }"#, to: configFile)

            let holder = FileLock(path: lockFile.path)
            expect(holder.tryLock(), "test setup: holder must acquire config.lock first")

            let result = selectPack(
                "minimal-chime", configFile: configFile, userPacksDirectory: userPacks,
                lockFile: lockFile)
            expect(
                result == .failure(.lockBusy),
                "a contended lock must report .lockBusy, not silently succeed, got \(result)")

            holder.unlock()

            let rawContents = try? String(contentsOf: configFile, encoding: .utf8)
            expect(
                rawContents?.contains("old-pack") == true,
                "a lock-contended call must never touch config.json — the prior selection must survive untouched"
            )
        }
    }

    suite("selectPack: unreadable manifest fails before config mutation and preserves exact bytes") {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let original = #"{ "selected_pack": "old", "master_volume": 0.37 }"#
            writeFixture(original, to: configFile)
            let pack = root.appendingPathComponent("packs/broken", isDirectory: true)
            try? FileManager.default.createDirectory(at: pack, withIntermediateDirectories: true)
            writeFixture("{ broken", to: pack.appendingPathComponent("manifest.json"))

            let result = selectPack(
                "broken", configFile: configFile,
                userPacksDirectory: root.appendingPathComponent("packs"),
                lockFile: root.appendingPathComponent("config.lock"))
            guard case .failure(.manifestUnreadable(let packID, _)) = result else {
                expect(false, "broken manifest must return manifestUnreadable, got \(result)")
                return
            }
            expect(packID == "broken", "typed failure must retain pack id")
            expect(
                (try? String(contentsOf: configFile, encoding: .utf8)) == original,
                "manifest rejection must leave config byte-for-byte unchanged")
        }
    }

    suite("nonEmptyRegularFileExists rejects empty regular files, directories, and FIFO") {
        withTempDirectory { root in
            let empty = root.appendingPathComponent("empty.mp3")
            let nonempty = root.appendingPathComponent("sound.mp3")
            let directory = root.appendingPathComponent("directory.mp3")
            let fifo = root.appendingPathComponent("fifo.mp3")
            writeFixture("", to: empty)
            writeFixture("bytes", to: nonempty)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            _ = mkfifo(fifo.path, 0o600)
            expect(!nonEmptyRegularFileExists(at: empty), "zero-byte regular file is not playable")
            expect(nonEmptyRegularFileExists(at: nonempty), "non-empty regular file is playable truth")
            expect(!nonEmptyRegularFileExists(at: directory), "directory is not playable")
            expect(!nonEmptyRegularFileExists(at: fifo), "FIFO is not playable")
        }
    }
}
