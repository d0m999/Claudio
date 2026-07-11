import ClaudioCore
import ClaudioGUICore
import Foundation

// MARK: - bindEventToManifest (ENGINEERING.md T16 D3): surgical RMW of manifest.json's raw
// JSON, preserving unknown top-level keys and sibling events — never a round-trip through
// PackManifest's Decodable/Encodable, which only models id+events and would silently drop
// name/author/license/version/schema.

@MainActor
private func makeEnvironment(
    userPacksDirectory: URL,
    bundledPacksDirectory: URL? = nil
) -> AudioImportEnvironment {
    AudioImportEnvironment(
        userPacksDirectory: userPacksDirectory,
        bundledPacksDirectory: bundledPacksDirectory,
        durationProbe: StubDurationProbe(fixedDuration: 1.0)
    )
}

/// `Result<Void, ManifestBindError>` isn't `Equatable` (`Void` isn't) — this extracts the
/// `.failure` payload so tests can compare it directly, `nil` for `.success` (a mismatch
/// any assertion below would still correctly flag).
private func failureError(_ result: Result<Void, ManifestBindError>) -> ManifestBindError? {
    if case .failure(let error) = result { return error }
    return nil
}

@MainActor
func runManifestBindingSuites() async {
    suite(
        "bindEventToManifest: binding an unmapped event sets it, and recomputes to .present via packCoverage"
    ) {
        withTempDirectory { root in
            let userPacks = root.appendingPathComponent("packs")
            writeFixture(
                #"{ "id": "my-pack", "events": {} }"#,
                to: userPacks.appendingPathComponent("my-pack/manifest.json"))
            writeFixture("fake-audio", to: userPacks.appendingPathComponent("my-pack/stop.mp3"))
            let environment = makeEnvironment(userPacksDirectory: userPacks)

            let before = packCoverage(
                packID: "my-pack", config: ClaudioConfig(selectedPack: "my-pack"),
                environment: environment)
            expect(
                before.first { $0.event == .stop }?.coverage == .unmapped,
                "setup: stop must start unmapped")

            let result = bindEventToManifest(
                event: .stop, fileName: "stop.mp3", packID: "my-pack", environment: environment)
            guard case .success = result else {
                expect(false, "expected .success, got \(result)")
                return
            }

            let after = packCoverage(
                packID: "my-pack", config: ClaudioConfig(selectedPack: "my-pack"),
                environment: environment)
            expect(
                after.first { $0.event == .stop }?.coverage == .present(fileName: "stop.mp3"),
                "after a successful bind, stop must recompute to .present, got"
                    + " \(String(describing: after.first { $0.event == .stop }?.coverage))")
        }
    }

    suite(
        "bindEventToManifest: preserves unknown top-level keys (name/author/license/schema) and sibling events"
    ) {
        withTempDirectory { root in
            let userPacks = root.appendingPathComponent("packs")
            let manifestFile = userPacks.appendingPathComponent("my-pack/manifest.json")
            writeFixture(
                #"""
                { "id": "my-pack", "name": "极简铃音", "author": "Test Author",
                  "license": "CC0-1.0", "schema": 1,
                  "events": { "notification": "ping.mp3" } }
                """#, to: manifestFile)
            writeFixture("fake-audio", to: userPacks.appendingPathComponent("my-pack/ping.mp3"))
            writeFixture("fake-audio", to: userPacks.appendingPathComponent("my-pack/stop.mp3"))
            let environment = makeEnvironment(userPacksDirectory: userPacks)

            let result = bindEventToManifest(
                event: .stop, fileName: "stop.mp3", packID: "my-pack", environment: environment)
            guard case .success = result else {
                expect(false, "expected .success, got \(result)")
                return
            }

            guard let rewrittenData = try? Data(contentsOf: manifestFile),
                let rewritten = try? JSONSerialization.jsonObject(with: rewrittenData)
                    as? [String: Any]
            else {
                expect(false, "rewritten manifest.json must still be valid JSON")
                return
            }
            expect(rewritten["name"] as? String == "极简铃音", "unknown key `name` must survive the RMW")
            expect(
                rewritten["author"] as? String == "Test Author",
                "unknown key `author` must survive the RMW")
            expect(
                rewritten["license"] as? String == "CC0-1.0",
                "unknown key `license` must survive the RMW")
            expect(rewritten["schema"] as? Int == 1, "unknown key `schema` must survive the RMW")

            guard let events = rewritten["events"] as? [String: String] else {
                expect(false, "rewritten manifest.json must still have an events object")
                return
            }
            expect(
                events["notification"] == "ping.mp3",
                "the sibling `notification` event must survive the RMW untouched, got \(events)")
            expect(
                events["stop"] == "stop.mp3",
                "the newly-bound `stop` event must be set, got \(events)")
        }
    }

    suite("bindEventToManifest: creates the `events` object when the manifest has none at all") {
        withTempDirectory { root in
            let userPacks = root.appendingPathComponent("packs")
            let manifestFile = userPacks.appendingPathComponent("my-pack/manifest.json")
            writeFixture(#"{ "id": "my-pack" }"#, to: manifestFile)
            writeFixture("fake-audio", to: userPacks.appendingPathComponent("my-pack/stop.mp3"))
            let environment = makeEnvironment(userPacksDirectory: userPacks)

            let result = bindEventToManifest(
                event: .stop, fileName: "stop.mp3", packID: "my-pack", environment: environment)
            guard case .success = result else {
                expect(false, "expected .success, got \(result)")
                return
            }

            guard let rewrittenData = try? Data(contentsOf: manifestFile),
                let rewritten = try? JSONSerialization.jsonObject(with: rewrittenData)
                    as? [String: Any],
                let events = rewritten["events"] as? [String: String]
            else {
                expect(false, "rewritten manifest.json must have a valid events object")
                return
            }
            expect(
                events["stop"] == "stop.mp3",
                "a manifest with no prior events object must gain one with the new binding, got \(events)"
            )
        }
    }

    suite(
        "bindEventToManifest: a malformed non-object `events` field (e.g. a JSON array) fails CLOSED — .manifestUnreadable, manifest.json left byte-for-byte unchanged"
    ) {
        withTempDirectory { root in
            let userPacks = root.appendingPathComponent("packs")
            let manifestFile = userPacks.appendingPathComponent("my-pack/manifest.json")
            let originalRawJSON = #"{ "id": "my-pack", "events": ["stop.mp3", "ping.mp3"] }"#
            writeFixture(originalRawJSON, to: manifestFile)
            writeFixture("fake-audio", to: userPacks.appendingPathComponent("my-pack/stop.mp3"))
            let environment = makeEnvironment(userPacksDirectory: userPacks)

            let result = bindEventToManifest(
                event: .stop, fileName: "stop.mp3", packID: "my-pack", environment: environment)

            expect(
                { if case .manifestUnreadable = failureError(result) { return true } else { return false } }(),
                "a non-object `events` field (a JSON array here) must fail CLOSED as"
                    + " .manifestUnreadable, never be silently coerced into a fresh {}, got \(result)"
            )
            expect(
                (try? String(contentsOf: manifestFile, encoding: .utf8)) == originalRawJSON,
                "a rejected bind must leave manifest.json completely untouched on disk")
        }
    }

    suite("bindEventToManifest: rebinding an already-mapped event overwrites its filename") {
        withTempDirectory { root in
            let userPacks = root.appendingPathComponent("packs")
            let manifestFile = userPacks.appendingPathComponent("my-pack/manifest.json")
            writeFixture(
                #"{ "id": "my-pack", "events": { "stop": "old-stop.mp3" } }"#, to: manifestFile)
            writeFixture("fake-audio", to: userPacks.appendingPathComponent("my-pack/old-stop.mp3"))
            writeFixture("fake-audio", to: userPacks.appendingPathComponent("my-pack/new-stop.mp3"))
            let environment = makeEnvironment(userPacksDirectory: userPacks)

            let result = bindEventToManifest(
                event: .stop, fileName: "new-stop.mp3", packID: "my-pack", environment: environment)
            guard case .success = result else {
                expect(false, "expected .success, got \(result)")
                return
            }

            let rows = packCoverage(
                packID: "my-pack", config: ClaudioConfig(selectedPack: "my-pack"),
                environment: environment)
            expect(
                rows.first { $0.event == .stop }?.coverage == .present(fileName: "new-stop.mp3"),
                "rebinding must overwrite the old filename, got"
                    + " \(String(describing: rows.first { $0.event == .stop }?.coverage))")
        }
    }

    suite("bindEventToManifest: an unresolvable packID is rejected as .packNotFound") {
        withTempDirectory { root in
            let userPacks = root.appendingPathComponent("packs")
            let environment = makeEnvironment(userPacksDirectory: userPacks)

            let result = bindEventToManifest(
                event: .stop, fileName: "stop.mp3", packID: "ghost-pack", environment: environment)
            expect(
                failureError(result) == .packNotFound(packID: "ghost-pack"),
                "an unresolvable packID must be rejected as .packNotFound, got \(result)")
        }
    }

    suite("bindEventToManifest: binding into a pack that exists ONLY as a bundled pack is refused") {
        withTempDirectory { root in
            let userPacks = root.appendingPathComponent("packs")
            let bundledPacks = root.appendingPathComponent("bundled")
            writeFixture(
                #"{ "id": "minimal-chime", "events": {} }"#,
                to: bundledPacks.appendingPathComponent("minimal-chime/manifest.json"))
            writeFixture(
                "fake-audio", to: bundledPacks.appendingPathComponent("minimal-chime/stop.mp3"))
            let environment = makeEnvironment(
                userPacksDirectory: userPacks, bundledPacksDirectory: bundledPacks)

            let result = bindEventToManifest(
                event: .stop, fileName: "stop.mp3", packID: "minimal-chime", environment: environment)
            expect(
                failureError(result) == .packNotFound(packID: "minimal-chime"),
                "binding must never write into the read-only bundled pack root, got \(result)")
            expect(
                (try? String(
                    contentsOf: bundledPacks.appendingPathComponent("minimal-chime/manifest.json"),
                    encoding: .utf8))?.contains("stop") == false,
                "the bundled pack's manifest.json must be completely untouched")
        }
    }

    suite("bindEventToManifest: a path-traversal filename is rejected as .unsafeFileName") {
        withTempDirectory { root in
            let userPacks = root.appendingPathComponent("packs")
            writeFixture(
                #"{ "id": "my-pack", "events": {} }"#,
                to: userPacks.appendingPathComponent("my-pack/manifest.json"))
            let environment = makeEnvironment(userPacksDirectory: userPacks)

            let result = bindEventToManifest(
                event: .stop, fileName: "../../evil.mp3", packID: "my-pack", environment: environment)
            expect(
                failureError(result) == .unsafeFileName,
                "a `../`-escaping filename must be rejected as .unsafeFileName, got \(result)")
        }
    }

    suite(
        "bindEventToManifest: a destination filename that is a symlink escaping the pack dir is rejected as .unsafeFileName"
    ) {
        withTempDirectory { root in
            let userPacks = root.appendingPathComponent("packs")
            writeFixture(
                #"{ "id": "my-pack", "events": {} }"#,
                to: userPacks.appendingPathComponent("my-pack/manifest.json"))
            let outside = root.appendingPathComponent("outside-secret", isDirectory: true)
            try? FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            createSymlink(
                at: userPacks.appendingPathComponent("my-pack/evil.mp3"), pointingTo: outside)
            let environment = makeEnvironment(userPacksDirectory: userPacks)

            let result = bindEventToManifest(
                event: .stop, fileName: "evil.mp3", packID: "my-pack", environment: environment)
            expect(
                failureError(result) == .unsafeFileName,
                "a symlink-escaping filename must be rejected as .unsafeFileName, got \(result)")
        }
    }

    suite("bindEventToManifest: a safe filename that doesn't actually exist is rejected as .fileNotFound")
    {
        withTempDirectory { root in
            let userPacks = root.appendingPathComponent("packs")
            writeFixture(
                #"{ "id": "my-pack", "events": {} }"#,
                to: userPacks.appendingPathComponent("my-pack/manifest.json"))
            let environment = makeEnvironment(userPacksDirectory: userPacks)

            let result = bindEventToManifest(
                event: .stop, fileName: "never-imported.mp3", packID: "my-pack",
                environment: environment)
            expect(
                failureError(result) == .fileNotFound(fileName: "never-imported.mp3"),
                "a filename that passes containment but doesn't exist on disk must be rejected as"
                    + " .fileNotFound (never silently bind a phantom file), got \(result)")
        }
    }

    // Distinct from the corrupt-manifest suite below: `{ not valid json` READS fine and only
    // fails `JSONSerialization`, so it exercises the "顶层不是 JSON 对象" guard. A manifest.json
    // that is ABSENT fails one step earlier — inside `loadPackManifestData` — the only
    // `bindEventToManifest` failure branch with no test at all. Reachable for real: importing
    // into a pack directory that exists (importAudioFile created it) but has no manifest yet.
    suite("bindEventToManifest: a MISSING manifest.json (pack dir exists, file present) is rejected as .manifestUnreadable") {
        withTempDirectory { root in
            let userPacks = root.appendingPathComponent("packs")
            // Pack directory + the audio file exist; manifest.json deliberately does NOT.
            writeFixture("fake-audio", to: userPacks.appendingPathComponent("my-pack/stop.mp3"))
            let environment = makeEnvironment(userPacksDirectory: userPacks)

            let result = bindEventToManifest(
                event: .stop, fileName: "stop.mp3", packID: "my-pack", environment: environment)
            guard case .manifestUnreadable(let reason) = failureError(result) else {
                expect(false, "a missing manifest.json must be rejected as .manifestUnreadable, got \(result)")
                return
            }
            expect(
                reason.contains("不存在或不可读"),
                "the reason must be loadPackManifestData's own unreadable message (not the"
                    + " top-level-not-an-object one), got \(reason)")
            expect(
                !FileManager.default.fileExists(
                    atPath: userPacks.appendingPathComponent("my-pack/manifest.json").path),
                "a refused bind must never CREATE a manifest.json — binding only ever edits one"
                    + " that already exists")
        }
    }

    suite(
        "bindEventToManifest: a VALID-JSON but non-object top level (a JSON array) fails closed as .manifestUnreadable, file untouched"
    ) {
        withTempDirectory { root in
            let userPacks = root.appendingPathComponent("packs")
            let manifestFile = userPacks.appendingPathComponent("my-pack/manifest.json")
            // Parses cleanly as JSON, so it clears `JSONSerialization.jsonObject` — but it is
            // an ARRAY, so the `as? [String: Any]` half of the same guard must reject it. A
            // separate sub-path from the `{ not valid json` case below, which never parses.
            let originalRawJSON = #"[{ "id": "my-pack" }]"#
            writeFixture(originalRawJSON, to: manifestFile)
            writeFixture("fake-audio", to: userPacks.appendingPathComponent("my-pack/stop.mp3"))
            let environment = makeEnvironment(userPacksDirectory: userPacks)

            let result = bindEventToManifest(
                event: .stop, fileName: "stop.mp3", packID: "my-pack", environment: environment)
            expect(
                { if case .manifestUnreadable = failureError(result) { return true } else { return false } }(),
                "a valid-JSON top-level ARRAY must fail closed as .manifestUnreadable, never be"
                    + " coerced into an object, got \(result)")
            expect(
                (try? String(contentsOf: manifestFile, encoding: .utf8)) == originalRawJSON,
                "a rejected bind must leave manifest.json byte-for-byte untouched")
        }
    }

    suite("bindEventToManifest: a corrupt manifest.json is rejected as .manifestUnreadable") {
        withTempDirectory { root in
            let userPacks = root.appendingPathComponent("packs")
            writeFixture("{ not valid json", to: userPacks.appendingPathComponent("my-pack/manifest.json"))
            writeFixture("fake-audio", to: userPacks.appendingPathComponent("my-pack/stop.mp3"))
            let environment = makeEnvironment(userPacksDirectory: userPacks)

            let result = bindEventToManifest(
                event: .stop, fileName: "stop.mp3", packID: "my-pack", environment: environment)
            expect(
                { if case .manifestUnreadable = failureError(result) { return true } else { return false } }(),
                "expected .failure(.manifestUnreadable), got \(result)")
        }
    }

    // MARK: - EventRowImportViewModel: import → bind, wired end to end

    await suite("EventRowImportViewModel: a successful drop imports AND binds to the row's event") {
        await withTempDirectory { root in
            let userPacks = root.appendingPathComponent("packs")
            writeFixture(
                #"{ "id": "my-pack", "events": {} }"#,
                to: userPacks.appendingPathComponent("my-pack/manifest.json"))
            let environment = makeEnvironment(userPacksDirectory: userPacks)
            let importViewModel = AudioImportViewModel(packID: "my-pack", environment: environment)
            let rowViewModel = EventRowImportViewModel(
                event: .notification, importViewModel: importViewModel)

            let sourceURL = root.appendingPathComponent("source/chime.wav")
            writeFixture(validWAVData(), to: sourceURL)
            await rowViewModel.handleDrop(sourceURL: sourceURL, suggestedFileName: "chime.wav")

            guard case .success = importViewModel.state else {
                expect(false, "expected the import itself to succeed, got \(importViewModel.state)")
                return
            }
            guard case .success = rowViewModel.bindResult else {
                expect(
                    false,
                    "expected the bind to succeed, got \(String(describing: rowViewModel.bindResult))")
                return
            }

            let rows = packCoverage(
                packID: "my-pack", config: ClaudioConfig(selectedPack: "my-pack"),
                environment: environment)
            expect(
                rows.first { $0.event == .notification }?.coverage == .present(fileName: "chime.wav"),
                "after a real drop through the view-model, notification must recompute to .present,"
                    + " got \(String(describing: rows.first { $0.event == .notification }?.coverage))"
            )
        }
    }

    await suite("EventRowImportViewModel: a rejected import never attempts to bind") {
        await withTempDirectory { root in
            let userPacks = root.appendingPathComponent("packs")
            writeFixture(
                #"{ "id": "my-pack", "events": {} }"#,
                to: userPacks.appendingPathComponent("my-pack/manifest.json"))
            let environment = makeEnvironment(userPacksDirectory: userPacks)
            let importViewModel = AudioImportViewModel(packID: "my-pack", environment: environment)
            let rowViewModel = EventRowImportViewModel(event: .stop, importViewModel: importViewModel)

            let sourceURL = root.appendingPathComponent("source/evil.mp3")
            writeFixture(evilShellScriptData(), to: sourceURL)
            await rowViewModel.handleDrop(sourceURL: sourceURL, suggestedFileName: "evil.mp3")

            guard case .reject = importViewModel.state else {
                expect(false, "setup: the import must be rejected, got \(importViewModel.state)")
                return
            }
            expect(
                rowViewModel.bindResult == nil,
                "a rejected import must never even attempt a bind, got"
                    + " \(String(describing: rowViewModel.bindResult))")
        }
    }

    // The THIRD outcome `EventRowImportViewModel`'s doc comment explicitly promises to keep
    // distinguishable ("two different failure surfaces with two different causes, never folded
    // into one") but nothing tested: the import itself SUCCEEDS (file copied in) while the
    // subsequent bind FAILS. Reachable whenever the pack directory has no readable manifest.json
    // — `importAudioFile` creates the pack dir and copies the file without needing a manifest,
    // then `bindEventToManifest` refuses because there's nothing to read-modify-write.
    await suite(
        "EventRowImportViewModel: an import that SUCCEEDS but whose bind FAILS records .failure in bindResult while state stays .success"
    ) {
        await withTempDirectory { root in
            let userPacks = root.appendingPathComponent("packs")
            // No manifest.json anywhere — the pack dir is created by the import itself.
            let environment = makeEnvironment(userPacksDirectory: userPacks)
            let importViewModel = AudioImportViewModel(packID: "my-pack", environment: environment)
            let rowViewModel = EventRowImportViewModel(event: .stop, importViewModel: importViewModel)

            let sourceURL = root.appendingPathComponent("source/chime.wav")
            writeFixture(validWAVData(), to: sourceURL)
            await rowViewModel.handleDrop(sourceURL: sourceURL, suggestedFileName: "chime.wav")

            guard case .success = importViewModel.state else {
                expect(
                    false,
                    "the IMPORT itself must still succeed (the file really was copied in), got"
                        + " \(importViewModel.state)")
                return
            }
            guard case .failure(let error) = rowViewModel.bindResult else {
                expect(
                    false,
                    "the BIND must fail and be recorded — a successful import with an unreadable"
                        + " manifest must never silently report a clean bind, got"
                        + " \(String(describing: rowViewModel.bindResult))")
                return
            }
            expect(
                { if case .manifestUnreadable = error { return true } else { return false } }(),
                "the recorded bind failure must be .manifestUnreadable, got \(error)")
            expect(
                FileManager.default.fileExists(
                    atPath: userPacks.appendingPathComponent("my-pack/chime.wav").path),
                "the imported file must still be on disk — the failed bind rolls back nothing,"
                    + " which is exactly why the two surfaces stay distinguishable")
        }
    }

    // MARK: - Fail closed on any manifest shape PackManifest could not decode afterwards
    // (T16 review 修复④)
    //
    // These two shapes used to be WRITTEN and reported as a successful bind — and then the very
    // next `loadPackManifest`/`packCoverage` failed to decode the result, so the freshly-bound row
    // rendered 「未配置」 (`.unmapped`) with no error anywhere. A "success" the UI immediately
    // contradicts is the worst of both worlds; refusing is what this path's fail-closed design
    // already intends everywhere else. Each suite asserts BOTH halves: the refusal, and that the
    // malformed manifest was left byte-for-byte untouched.

    suite(
        "bindEventToManifest: an `events` object holding a NON-STRING value ({\"stop\": 1}) fails closed — PackManifest could not decode the result, so the bind must not claim success"
    ) {
        withTempDirectory { root in
            let userPacks = root.appendingPathComponent("packs")
            let manifestFile = userPacks.appendingPathComponent("my-pack/manifest.json")
            // `events` IS a JSON object (so it clears the existing non-object guard) but one of its
            // values is a number — `PackManifest.events` is `[String: String]`, so decoding this
            // throws no matter what we add to it.
            let originalRawJSON = #"{ "id": "my-pack", "events": { "stop": 1 } }"#
            writeFixture(originalRawJSON, to: manifestFile)
            writeFixture("fake-audio", to: userPacks.appendingPathComponent("my-pack/ping.mp3"))
            let environment = makeEnvironment(userPacksDirectory: userPacks)

            let result = bindEventToManifest(
                event: .notification, fileName: "ping.mp3", packID: "my-pack",
                environment: environment)

            expect(
                { if case .manifestUnreadable = failureError(result) { return true } else { return false } }(),
                "must fail closed as .manifestUnreadable rather than write a manifest nothing can"
                    + " decode, got \(result)")
            expect(
                (try? String(contentsOf: manifestFile, encoding: .utf8)) == originalRawJSON,
                "a refused bind must leave the malformed manifest byte-for-byte untouched")
            // The half that makes the old behavior indefensible: had the bind "succeeded", THIS is
            // what the user would have seen for the row they just configured.
            let rows = packCoverage(
                packID: "my-pack", config: ClaudioConfig(selectedPack: "my-pack"),
                environment: environment)
            expect(
                rows.first { $0.event == .notification }?.coverage == .unmapped,
                "coverage still can't decode this manifest — which is exactly why reporting the bind"
                    + " as a success would have left the row silently 未配置, got"
                    + " \(String(describing: rows.first { $0.event == .notification }?.coverage))")
        }
    }

    suite(
        "bindEventToManifest: a manifest with no valid top-level `id` (missing / non-string / empty) fails closed — PackManifest requires a non-empty string id"
    ) {
        // Three shapes, one contract. `id` missing and `id` non-string both make `PackManifest`'s
        // `Decodable` throw outright; an EMPTY id is not a legal pack id anywhere in this codebase
        // (`isSafePackID("")` is false), so a manifest carrying one is malformed too and must never
        // be treated as a live bind target.
        let malformed: [(label: String, json: String)] = [
            ("missing id", #"{ "events": {} }"#),
            ("non-string id", #"{ "id": 42, "events": {} }"#),
            ("empty id", #"{ "id": "", "events": {} }"#),
        ]
        for shape in malformed {
            withTempDirectory { root in
                let userPacks = root.appendingPathComponent("packs")
                let manifestFile = userPacks.appendingPathComponent("my-pack/manifest.json")
                writeFixture(shape.json, to: manifestFile)
                writeFixture("fake-audio", to: userPacks.appendingPathComponent("my-pack/stop.mp3"))
                let environment = makeEnvironment(userPacksDirectory: userPacks)

                let result = bindEventToManifest(
                    event: .stop, fileName: "stop.mp3", packID: "my-pack", environment: environment)

                expect(
                    { if case .manifestUnreadable = failureError(result) { return true } else { return false } }(),
                    "\(shape.label): must fail closed as .manifestUnreadable, never write a manifest"
                        + " PackManifest can't decode and call it a success, got \(result)")
                expect(
                    (try? String(contentsOf: manifestFile, encoding: .utf8)) == shape.json,
                    "\(shape.label): the malformed manifest must be left byte-for-byte untouched")
            }
        }
    }

    // MARK: - EventRowImportViewModel must never re-read MUTABLE state across the `await`
    // (T16 review 修复③ — Codex [P2] + Claude 对抗 F6, two axes of one root cause)
    //
    // `GatedDurationProbe` makes the race deterministic instead of timing-dependent: the import
    // pipeline blocks inside the (off-main-actor) duration probe until this test explicitly
    // releases it, so "a drop is in flight" is a state the test can hold open and act during — no
    // sleeps, no yields-and-hope.

    await suite(
        "EventRowImportViewModel: switching packs MID-IMPORT binds into the pack the bytes were copied into — never the pack selected while the import was in flight (TOCTOU: it would edit a DIFFERENT pack's manifest)"
    ) {
        await withTempDirectory { root in
            let userPacks = root.appendingPathComponent("packs")
            let manifestA = userPacks.appendingPathComponent("pack-a/manifest.json")
            let manifestB = userPacks.appendingPathComponent("pack-b/manifest.json")
            let originalB = #"{ "id": "pack-b", "events": {} }"#
            writeFixture(#"{ "id": "pack-a", "events": {} }"#, to: manifestA)
            writeFixture(originalB, to: manifestB)
            // pack-b ALREADY holds a file of the same name — so a mis-targeted bind would not merely
            // fail with .fileNotFound, it would SUCCEED into the wrong pack's manifest. This is the
            // difference between "the bug is loud" and "the bug silently rewrites another pack".
            writeFixture("fake-audio", to: userPacks.appendingPathComponent("pack-b/chime.wav"))

            let probe = GatedDurationProbe(fixedDuration: 1.0)
            let environment = AudioImportEnvironment(
                userPacksDirectory: userPacks, bundledPacksDirectory: nil, durationProbe: probe)
            let importViewModel = AudioImportViewModel(packID: "pack-a", environment: environment)
            let rowViewModel = EventRowImportViewModel(event: .stop, importViewModel: importViewModel)

            let sourceURL = root.appendingPathComponent("source/chime.wav")
            writeFixture(validWAVData(), to: sourceURL)

            let drop = Task {
                await rowViewModel.handleDrop(sourceURL: sourceURL, suggestedFileName: "chime.wav")
            }
            // Yield so `drop` actually starts and reaches its `Task.detached` suspension; the import
            // then runs off the main actor and parks inside the probe, where we hold it.
            await Task.yield()
            expect(
                probe.waitUntilProbing(timeout: 5) == .success,
                "setup: the import must really be in flight inside the probe, otherwise this test"
                    + " isn't constructing the race at all")

            // Exactly what `PanelView.refresh()` does on a pack switch: repoint every row's packID.
            importViewModel.packID = "pack-b"
            probe.release()
            await drop.value

            guard case .success = rowViewModel.bindResult else {
                expect(
                    false,
                    "the bind must succeed against pack-a (where the bytes landed), got"
                        + " \(String(describing: rowViewModel.bindResult))")
                return
            }
            expect(
                FileManager.default.fileExists(
                    atPath: userPacks.appendingPathComponent("pack-a/chime.wav").path),
                "setup sanity: the import copied the file into pack-a, the pack selected when it began")

            let rowsA = packCoverage(
                packID: "pack-a", config: ClaudioConfig(selectedPack: "pack-a"),
                environment: environment)
            expect(
                rowsA.first { $0.event == .stop }?.coverage == .present(fileName: "chime.wav"),
                "pack-a — the pack that RECEIVED the file — must be the one whose manifest gained the"
                    + " binding, got \(String(describing: rowsA.first { $0.event == .stop }?.coverage))")
            expect(
                (try? String(contentsOf: manifestB, encoding: .utf8)) == originalB,
                "pack-b's manifest must be byte-for-byte untouched: the user switched to it, they"
                    + " never dropped anything into it — binding there would silently rewrite a pack"
                    + " the drop had nothing to do with")
        }
    }

    await suite(
        "EventRowImportViewModel: a CONCURRENT rejected drop on the same row cannot cancel a valid drop's bind (the bind follows the drop's OWN outcome, never the shared `state`) — no orphaned file"
    ) {
        await withTempDirectory { root in
            let userPacks = root.appendingPathComponent("packs")
            writeFixture(
                #"{ "id": "my-pack", "events": {} }"#,
                to: userPacks.appendingPathComponent("my-pack/manifest.json"))

            let probe = GatedDurationProbe(fixedDuration: 1.0)
            let environment = AudioImportEnvironment(
                userPacksDirectory: userPacks, bundledPacksDirectory: nil, durationProbe: probe)
            let importViewModel = AudioImportViewModel(packID: "my-pack", environment: environment)
            let rowViewModel = EventRowImportViewModel(event: .stop, importViewModel: importViewModel)

            let goodURL = root.appendingPathComponent("source/chime.wav")
            writeFixture(validWAVData(), to: goodURL)
            let evilURL = root.appendingPathComponent("source/evil.mp3")
            writeFixture(evilShellScriptData(), to: evilURL)

            // Drop A (valid) goes first and parks inside the probe — its file is on its way in.
            let dropA = Task {
                await rowViewModel.handleDrop(sourceURL: goodURL, suggestedFileName: "chime.wav")
            }
            await Task.yield()
            expect(
                probe.waitUntilProbing(timeout: 5) == .success,
                "setup: drop A must be in flight before drop B is issued")

            // Drop B (content-sniff rejected — a shell script wearing a .mp3 name) never reaches the
            // probe, so it completes FIRST and publishes `.reject` into the row's shared state.
            await rowViewModel.handleDrop(sourceURL: evilURL, suggestedFileName: "evil.mp3")
            guard case .reject = importViewModel.state else {
                expect(false, "setup: drop B must be rejected, got \(importViewModel.state)")
                return
            }

            probe.release()
            await dropA.value

            // A's file was already copied into the pack. If A's bind decision consulted the shared
            // `state` (which B had just set to `.reject`) instead of A's own returned outcome, A
            // would silently skip binding: file on disk, row still 未配置, zero errors reported —
            // an orphan.
            guard case .success = rowViewModel.bindResult else {
                expect(
                    false,
                    "drop A's bind must be driven by A's OWN import outcome, not by whatever the"
                        + " shared state holds after a sibling drop, got"
                        + " \(String(describing: rowViewModel.bindResult))")
                return
            }
            let rows = packCoverage(
                packID: "my-pack", config: ClaudioConfig(selectedPack: "my-pack"),
                environment: environment)
            expect(
                rows.first { $0.event == .stop }?.coverage == .present(fileName: "chime.wav"),
                "the valid drop's file must end up BOUND, never copied-in-but-unbound, got"
                    + " \(String(describing: rows.first { $0.event == .stop }?.coverage))")
        }
    }
}

/// A duration probe that BLOCKS inside ``probeDuration(of:)`` until a test explicitly releases it —
/// the seam that makes "an import is in flight" a state a test can HOLD OPEN, rather than a timing
/// window it has to race (no sleeps, no yield-and-pray).
///
/// It works precisely because ``AudioImportViewModel/handleDrop(requests:)`` runs the import
/// pipeline on a `Task.detached`: the probe blocks a background thread, never the `@MainActor`, so
/// the test can keep driving the view-model (switching packs, issuing a second drop) while the
/// first import sits parked here.
///
/// `@unchecked Sendable`: its only mutable state is the two semaphores, which are themselves
/// thread-safe by construction.
private final class GatedDurationProbe: AudioDurationProbing, @unchecked Sendable {
    private let fixedDuration: TimeInterval?
    /// Signaled BY the probe (on the import's background thread) once it is really running.
    private let probing = DispatchSemaphore(value: 0)
    /// Signaled BY the test to let the parked import finish.
    private let resume = DispatchSemaphore(value: 0)

    init(fixedDuration: TimeInterval?) { self.fixedDuration = fixedDuration }

    func probeDuration(of fileURL: URL) -> TimeInterval? {
        probing.signal()
        resume.wait()
        return fixedDuration
    }

    /// Blocks the caller until the import has actually entered the probe. Bounded by `timeout` so a
    /// mis-constructed test fails an assertion instead of hanging the whole harness forever.
    func waitUntilProbing(timeout seconds: TimeInterval) -> DispatchTimeoutResult {
        probing.wait(timeout: .now() + seconds)
    }

    /// Lets the parked import proceed (copy the bytes in, return its outcome).
    func release() { resume.signal() }
}
