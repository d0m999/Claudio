import ClaudioCore
import Foundation

// MARK: - starred_packs: config shape, read model, and the future management-window writer
//
// T16 deliberately establishes the contract without activating the panel's starred-only filter.
// The pure display-set seam below is therefore exercised directly: it operates solely on ids and
// has no URL/FileManager parameter, so a future caller cannot turn panel rendering into a writer.

@MainActor
private func makeStarredPackDirectory(_ id: String, under root: URL) {
    let directory = root.appendingPathComponent(id, isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    writeFixture(#"{ "id": "test-pack", "events": {} }"#, to: directory.appendingPathComponent("manifest.json"))
}

private func readStarredPackIDs(from configFile: URL) -> [String]? {
    guard
        let data = try? Data(contentsOf: configFile),
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
        return nil
    }
    return object["starred_packs"] as? [String]
}

private final class StarredPacksRecordingSpawner: ProcessSpawning, @unchecked Sendable {
    private(set) var callCount = 0

    func spawn(executablePath: String, arguments: [String]) -> Bool {
        callCount += 1
        return true
    }
}

private func starredPacksPlayEnvironment(
    root: URL, configFile: URL, userPacks: URL, spawner: any ProcessSpawning
) -> PlayEnvironment {
    PlayEnvironment(
        lockFile: root.appendingPathComponent(UUID().uuidString + ".play.lock"), configFile: configFile,
        userPacksDirectory: userPacks, bundledPacksDirectory: nil, spawner: spawner,
        debounceStateFile: root.appendingPathComponent(UUID().uuidString + ".play.state"),
        logFile: root.appendingPathComponent(UUID().uuidString + ".log"),
        logLockFile: root.appendingPathComponent(UUID().uuidString + ".log.lock"))
}

@MainActor
func runStarredPacksSuites() {
    suite("ClaudioConfig.starredPacks: missing, empty, and populated arrays remain three distinct read states") {
        let missing = try? JSONDecoder().decode(
            ClaudioConfig.self, from: #"{ "selected_pack": "minimal-chime" }"#.data(using: .utf8)!)
        let empty = try? JSONDecoder().decode(
            ClaudioConfig.self,
            from: #"{ "selected_pack": "minimal-chime", "starred_packs": [] }"#.data(using: .utf8)!)
        let populated = try? JSONDecoder().decode(
            ClaudioConfig.self,
            from: #"{ "selected_pack": "minimal-chime", "starred_packs": ["a", "b"] }"#
                .data(using: .utf8)!)
        let malformed = try? JSONDecoder().decode(
            ClaudioConfig.self,
            from: #"{ "selected_pack": "minimal-chime", "starred_packs": ["a", 2] }"#
                .data(using: .utf8)!)

        expect(missing?.starredPacks == nil, "missing starred_packs must remain nil, not silently become []")
        expect(empty?.starredPacks == [], "an explicit empty starred_packs array is the user's zero-row choice")
        expect(populated?.starredPacks == ["a", "b"], "a valid starred_packs array must decode verbatim")
        expect(
            malformed?.starredPacks == nil,
            "the lenient reader may fold malformed starred_packs to nil only because the panel probes first")
    }

    suite("starred_packs: parser validates only array-of-string shape, never pack-id contents") {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            writeFixture(
                #"{ "selected_pack": "a", "starred_packs": ["", "../not-an-id", "still just text"] }"#,
                to: configFile)

            expect(
                probeConfigRewritable(configFile: configFile) == .rewritable,
                "string contents are not this parser's concern: stale/non-displayable ids must remain a read/write-model concern")
        }
    }

    suite("setStarredPacks: a first mutation materializes defaults with the requested non-built-in star") {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let userPacks = root.appendingPathComponent("packs", isDirectory: true)
            for id in ["builtin-a", "builtin-b", "custom"] { makeStarredPackDirectory(id, under: userPacks) }
            writeFixture(#"{ "selected_pack": "builtin-a", "night_dim": true }"#, to: configFile)

            let result = setStarredPacks(
                ["custom"], configFile: configFile, lockFile: root.appendingPathComponent("config.lock"),
                userPacksDirectory: userPacks, defaultStarredPackIDs: ["builtin-a", "builtin-b"])

            expect(
                result == .success(.updated(ids: ["builtin-a", "builtin-b", "custom"])),
                "the first star mutation must explicitly retain defaults rather than silently dropping them: \(result)")
            expect(
                readStarredPackIDs(from: configFile) == ["builtin-a", "builtin-b", "custom"],
                "the on-disk first mutation must materialize the complete explicit selection")
        }
    }

    suite("setStarredPacks: normalizes duplicate ids, prunes stale ids only while writing, and preserves unrelated keys") {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let userPacks = root.appendingPathComponent("packs", isDirectory: true)
            for id in ["a", "b"] { makeStarredPackDirectory(id, under: userPacks) }
            writeFixture(
                #"{ "selected_pack": "a", "starred_packs": ["stale"], "night_dim": true }"#,
                to: configFile)

            let result = setStarredPacks(
                ["a", "a", "b", "stale"], configFile: configFile,
                lockFile: root.appendingPathComponent("config.lock"), userPacksDirectory: userPacks,
                defaultStarredPackIDs: [])

            expect(
                result == .success(.updated(ids: ["a", "b"])),
                "duplicates must collapse and stale ids must be pruned by the writer, got \(result)")
            expect(
                readStarredPackIDs(from: configFile) == ["a", "b"],
                "the persisted array must be normalized rather than merely rendered as a set")
            let raw = try? Data(contentsOf: configFile)
            let object = raw.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            expect(object?["night_dim"] as? Bool == true, "the starred writer must preserve unrelated top-level keys")
        }
    }

    suite("toggleStarredPack: membership decision uses latest locked JSON and preserves external siblings") {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let lockFile = root.appendingPathComponent("config.lock")
            let userPacks = root.appendingPathComponent("packs", isDirectory: true)
            for id in ["a", "b", "c"] { makeStarredPackDirectory(id, under: userPacks) }
            // A retained window may still remember only [a], while an external writer has already
            // committed b. The atomic API must derive its next value from this file, not that UI.
            writeFixture(
                #"{"selected_pack":"a","starred_packs":["a","b"]}"#,
                to: configFile)

            let added = toggleStarredPack(
                "c",
                configFile: configFile,
                lockFile: lockFile,
                userPacksDirectory: userPacks,
                defaultStarredPackIDs: [])
            expect(
                added == .success(.updated(ids: ["a", "b", "c"])),
                "adding c must preserve externally-added b: \(added)")
            expect(
                readStarredPackIDs(from: configFile) == ["a", "b", "c"],
                "atomic add must persist all unrelated current stars")

            let removed = toggleStarredPack(
                "a",
                configFile: configFile,
                lockFile: lockFile,
                userPacksDirectory: userPacks,
                defaultStarredPackIDs: [])
            expect(
                removed == .success(.updated(ids: ["b", "c"])),
                "removing a must preserve b and c: \(removed)")
        }
    }

    suite("setStarredPacks: rejects more than four distinct existing ids without silently truncating or writing") {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let userPacks = root.appendingPathComponent("packs", isDirectory: true)
            let ids = ["a", "b", "c", "d", "e"]
            for id in ids { makeStarredPackDirectory(id, under: userPacks) }
            let original = #"{ "selected_pack": "a", "starred_packs": ["a"] }"#
            writeFixture(original, to: configFile)

            let result = setStarredPacks(
                ["a", "a", "b", "c", "d", "e"], configFile: configFile,
                lockFile: root.appendingPathComponent("config.lock"), userPacksDirectory: userPacks,
                defaultStarredPackIDs: [])

            expect(
                result == .failure(.tooManyStarredPacks(max: maxStarredPacks)),
                "five distinct existing ids must be rejected, not silently sliced: \(result)")
            expect(
                (try? String(contentsOf: configFile, encoding: .utf8)) == original,
                "a rejected fifth star must leave config.json byte-for-byte untouched")
        }
    }

    suite("setStarredPacks: missing config and a busy config lock both fail closed without creating or changing a file") {
        withTempDirectory { root in
            let missingConfig = root.appendingPathComponent("missing.json")
            let userPacks = root.appendingPathComponent("packs", isDirectory: true)
            makeStarredPackDirectory("a", under: userPacks)
            let missingResult = setStarredPacks(
                ["a"], configFile: missingConfig, lockFile: root.appendingPathComponent("missing.lock"),
                userPacksDirectory: userPacks, defaultStarredPackIDs: [])
            expect(
                missingResult == .failure(.configMissing),
                "a star writer without a selected-pack config must fail closed, got \(missingResult)")
            expect(
                !FileManager.default.fileExists(atPath: missingConfig.path),
                "a fail-closed star mutation must not fabricate config.json")

            let configFile = root.appendingPathComponent("config.json")
            let lockFile = root.appendingPathComponent("config.lock")
            let original = #"{ "selected_pack": "a", "starred_packs": ["a"] }"#
            writeFixture(original, to: configFile)
            let holder = FileLock(path: lockFile.path)
            expect(holder.tryLock(), "test setup: the config lock holder must acquire the lock")
            let busyResult = setStarredPacks(
                [], configFile: configFile, lockFile: lockFile, userPacksDirectory: userPacks,
                defaultStarredPackIDs: [])
            expect(
                busyResult == .failure(.lockBusy),
                "a contended config lock must surface .lockBusy rather than silently discard the mutation")
            holder.unlock()
            expect(
                (try? String(contentsOf: configFile, encoding: .utf8)) == original,
                "a lock-contended star mutation must leave config.json byte-for-byte untouched")
        }
    }

    suite("setStarredPacks: an unreadable pack directory fails closed instead of silently clearing defaults") {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let unreadablePacksPath = root.appendingPathComponent("not-a-directory")
            let original = #"{ "selected_pack": "builtin-a", "night_dim": true }"#
            writeFixture(original, to: configFile)
            writeFixture("not a directory", to: unreadablePacksPath)

            let result = setStarredPacks(
                ["custom"], configFile: configFile, lockFile: root.appendingPathComponent("config.lock"),
                userPacksDirectory: unreadablePacksPath, defaultStarredPackIDs: ["builtin-a"])

            guard case .failure(.userPacksDirectoryUnreadable(let reason)) = result else {
                expect(false, "an unreadable pack directory must fail closed, not be treated as zero packs: \(result)")
                return
            }
            expect(
                reason.contains(unreadablePacksPath.path),
                "the failure must name the unreadable pack directory so the user can repair it")
            expect(
                (try? String(contentsOf: configFile, encoding: .utf8)) == original,
                "a failed pack-directory read must leave the missing-key config untouched, never materialize []")
        }
    }

    suite("starred_packs malformed shapes make probe and every writer fail closed with exactly the same actionable reason") {
        withTempDirectory { root in
            let userPacks = root.appendingPathComponent("packs", isDirectory: true)
            makeStarredPackDirectory("a", under: userPacks)

            for malformed in [
                #"{ "selected_pack": "a", "starred_packs": "a" }"#,
                #"{ "selected_pack": "a", "starred_packs": ["a", 2] }"#,
            ] {
                let configFile = root.appendingPathComponent(UUID().uuidString + ".json")
                let lockFile = root.appendingPathComponent(UUID().uuidString + ".lock")
                writeFixture(malformed, to: configFile)

                guard case .malformed(let probeReason) = probeConfigRewritable(configFile: configFile) else {
                    expect(false, "a malformed starred_packs shape must be reported by probe")
                    continue
                }
                let result = setStarredPacks(
                    ["a"], configFile: configFile, lockFile: lockFile, userPacksDirectory: userPacks,
                    defaultStarredPackIDs: [])
                guard case .failure(.configReadFailure(let writeReason)) = result else {
                    expect(false, "a malformed starred_packs shape must stop the writer, got \(result)")
                    continue
                }
                expect(
                    probeReason == writeReason,
                    "probe and the real write path must expose byte-for-byte identical repair instructions")

                let selectResult = selectPack(
                    "a", configFile: configFile, userPacksDirectory: userPacks, lockFile: lockFile)
                guard case .failure(.configReadFailure(let selectReason)) = selectResult else {
                    expect(false, "a malformed starred_packs shape must stop selectPack too, got \(selectResult)")
                    continue
                }
                expect(
                    selectReason == probeReason,
                    "selectPack must reach the same fail-closed parser reason, never bypass a malformed starred_packs")

                let eventResult = setEventEnabled(
                    .stop, enabled: false, configFile: configFile, lockFile: lockFile)
                guard case .failure(.configReadFailure(let eventReason)) = eventResult else {
                    expect(false, "a malformed starred_packs shape must stop setEventEnabled too, got \(eventResult)")
                    continue
                }
                expect(
                    eventReason == probeReason,
                    "setEventEnabled must reach the same fail-closed parser reason, never bypass a malformed starred_packs")

                let volumeResult = setMasterVolume(0.6, configFile: configFile, lockFile: lockFile)
                guard case .failure(.configReadFailure(let volumeReason)) = volumeResult else {
                    expect(false, "a malformed starred_packs shape must stop setMasterVolume too, got \(volumeResult)")
                    continue
                }
                expect(
                    volumeReason == probeReason,
                    "setMasterVolume must reach the same fail-closed parser reason, never bypass a malformed starred_packs")
                expect(probeReason.contains("starred_packs"), "the repair instruction must name the bad key")
                expect(probeReason.contains("数组"), "the repair instruction must state the required array shape")
                expect(probeReason.contains("claudio 重建"), "the repair instruction must include configRebuildHint")
                let doctorResult = configRewritabilityResult(configFile: configFile)
                expect(doctorResult.severity == .warning, "doctor must surface malformed starred_packs as a warning")
                expect(
                    doctorResult.message.contains("starred_packs"),
                    "doctor must expose the same actionable starred_packs repair instruction")
                expect(
                    (try? String(contentsOf: configFile, encoding: .utf8)) == malformed,
                    "a malformed config must remain untouched after the rejected write")
            }
        }
    }

    suite("existing config writers preserve a valid starred_packs array") {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let lockFile = root.appendingPathComponent("config.lock")
            let userPacks = root.appendingPathComponent("packs", isDirectory: true)
            makeStarredPackDirectory("old", under: userPacks)
            makeStarredPackDirectory("new", under: userPacks)
            writeFixture(
                #"{ "selected_pack": "old", "master_volume": 0.2, "events": {}, "starred_packs": ["old", "new"] }"#,
                to: configFile)

            expect(
                selectPack("new", configFile: configFile, userPacksDirectory: userPacks, lockFile: lockFile)
                    == .success(.selected(packID: "new")),
                "selectPack setup mutation must succeed")
            expect(
                setEventEnabled(.stop, enabled: false, configFile: configFile, lockFile: lockFile)
                    == .success(.updated(event: .stop, enabled: false)),
                "setEventEnabled setup mutation must succeed")
            expect(
                setMasterVolume(0.6, configFile: configFile, lockFile: lockFile) == .success(.updated(volume: 0.6)),
                "setMasterVolume setup mutation must succeed")
            expect(
                readStarredPackIDs(from: configFile) == ["old", "new"],
                "use, mute, and master-volume writes must all preserve starred_packs verbatim")
        }
    }

    suite("play and doctor keep their pre-starred-packs decisions for valid, five-id, and malformed star values") {
        withTempDirectory { root in
            let userPacks = root.appendingPathComponent("packs", isDirectory: true)
            writeFixture(
                #"{ "id": "a", "events": { "stop": "stop.mp3" } }"#,
                to: userPacks.appendingPathComponent("a/manifest.json"))
            writeFixture("audio", to: userPacks.appendingPathComponent("a/stop.mp3"))

            let fixtures: [(label: String, contents: String)] = [
                ("no stars", #"{ "selected_pack": "a" }"#),
                ("five stars", #"{ "selected_pack": "a", "starred_packs": ["a", "b", "c", "d", "e"] }"#),
                ("malformed stars", #"{ "selected_pack": "a", "starred_packs": ["a", 2] }"#),
            ]
            var expectedPlay: PlayOutcome?
            var expectedDoctor: PackIntegrityStatus?

            for fixture in fixtures {
                let configFile = root.appendingPathComponent(fixture.label + ".json")
                writeFixture(fixture.contents, to: configFile)
                let spawner = StarredPacksRecordingSpawner()
                let play = playSoundEvent(
                    "stop",
                    environment: starredPacksPlayEnvironment(
                        root: root, configFile: configFile, userPacks: userPacks, spawner: spawner))
                let doctor = checkPackIntegrity(
                    configFile: configFile, userPacksDirectory: userPacks, bundledPacksDirectory: nil)
                if let expectedPlay, let expectedDoctor {
                    expect(
                        play == expectedPlay,
                        "\(fixture.label) must leave play's pre-existing decision unchanged, got \(play)")
                    expect(
                        doctor == expectedDoctor,
                        "\(fixture.label) must leave doctor's pre-existing integrity decision unchanged, got \(doctor)")
                } else {
                    expectedPlay = play
                    expectedDoctor = doctor
                    expect(play == .played(event: .stop, filePath: userPacks.appendingPathComponent("a/stop.mp3").path),
                           "fixture setup: the baseline play decision must be .played")
                    expect(doctor == .complete(packID: "a", events: ["stop"]),
                           "fixture setup: the baseline doctor decision must be .complete")
                }
            }
        }
    }

    suite("SetStarredPacksError: common config-lock descriptions stay identical to SetEventEnabledError") {
        expect(
            SetStarredPacksError.configReadFailure(reason: "reason").description
                == SetEventEnabledError.configReadFailure(reason: "reason").description,
            "same config read failure must keep one cross-writer description")
        expect(
            SetStarredPacksError.configWriteFailure(reason: "reason").description
                == SetEventEnabledError.configWriteFailure(reason: "reason").description,
            "same config write failure must keep one cross-writer description")
        expect(
            SetStarredPacksError.lockBusy.description == SetEventEnabledError.lockBusy.description,
            "same busy lock must keep one cross-writer description")
        expect(
            SetStarredPacksError.lockFailed(errno: 5).description
                == SetEventEnabledError.lockFailed(errno: 5).description,
            "same lock-system failure must keep one cross-writer description")
        expect(
            SetStarredPacksError.configMissing.description == SetEventEnabledError.configMissing.description,
            "same missing-config policy must keep one cross-writer description")
    }
}
