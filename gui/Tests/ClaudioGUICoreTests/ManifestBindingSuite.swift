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
}
