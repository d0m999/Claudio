import ClaudioCore
import ClaudioGUICore
import Foundation

// MARK: - AudioImportEnvironment.builtinPackIDs / forkPack (PLAN-SOUND-MANAGER.md §2.2/§2.3, T6)

/// Writes a minimal-but-complete `manifest.json` fixture as a literal JSON string (mirrors
/// this suite's siblings' preference for raw string literals over `JSONSerialization` when
/// writing fixtures — the exact on-disk bytes are visible at the call site).
@MainActor
private func writeForkSourceManifest(
    id: String,
    name: String? = nil,
    license: String? = nil,
    author: String? = nil,
    events: [String: String] = [:],
    to directory: URL
) {
    var fields = ["\"id\": \"\(id)\""]
    if let name { fields.append("\"name\": \"\(name)\"") }
    if let license { fields.append("\"license\": \"\(license)\"") }
    if let author { fields.append("\"author\": \"\(author)\"") }
    let eventsBody = events.sorted { $0.key < $1.key }
        .map { "\"\($0.key)\": \"\($0.value)\"" }
        .joined(separator: ", ")
    fields.append("\"events\": { \(eventsBody) }")
    let json = "{ \(fields.joined(separator: ", ")) }"
    writeFixture(json, to: directory.appendingPathComponent("manifest.json"))
}

@MainActor
func runPackForkSuites() {

    // MARK: - AudioImportEnvironment.builtinPackIDs

    suite("AudioImportEnvironment.builtinPackIDs: nil factoryPacksDirectory ⇒ empty set") {
        withTempDirectory { root in
            let environment = makeAudioImportEnvironment(
                userPacksDirectory: root.appendingPathComponent("packs"))
            expect(
                environment.builtinPackIDs.isEmpty,
                "builtinPackIDs must be empty when factoryPacksDirectory is nil, got"
                    + " \(environment.builtinPackIDs)")
        }
    }

    suite(
        "AudioImportEnvironment.builtinPackIDs: real subdirectories only — dot-prefixed dirs"
            + " and plain files are excluded"
    ) {
        withTempDirectory { root in
            let factory = root.appendingPathComponent("factory")
            try? FileManager.default.createDirectory(
                at: factory.appendingPathComponent("minimal-chime"),
                withIntermediateDirectories: true)
            try? FileManager.default.createDirectory(
                at: factory.appendingPathComponent("sunny-chime"),
                withIntermediateDirectories: true)
            // Dot-prefixed — must be excluded (mirrors `Setup.swift`'s own filter: a scratch
            // directory left by a killed publish must never be counted as a real pack).
            try? FileManager.default.createDirectory(
                at: factory.appendingPathComponent(".hidden-scratch"),
                withIntermediateDirectories: true)
            // A plain regular file sitting at a pack-id-shaped path — must be excluded, it
            // isn't a directory.
            writeFixture("not a pack", to: factory.appendingPathComponent("stray-file"))

            let environment = makeAudioImportEnvironment(
                userPacksDirectory: root.appendingPathComponent("packs"),
                factoryPacksDirectory: factory)

            expect(
                environment.builtinPackIDs == ["minimal-chime", "sunny-chime"],
                "builtinPackIDs must be exactly the real subdirectories, got"
                    + " \(environment.builtinPackIDs)")
        }
    }

    // MARK: - nextForkPackID (pure function)

    suite("nextForkPackID: no collision ⇒ <fromID>-copy") {
        expect(
            nextForkPackID(for: "minimal-chime", existingUserPackIDs: []) == "minimal-chime-copy",
            "expected minimal-chime-copy with no existing collisions")
    }

    suite("nextForkPackID: -copy taken ⇒ -copy-2, then -copy and -copy-2 both taken ⇒ -copy-3") {
        expect(
            nextForkPackID(for: "minimal-chime", existingUserPackIDs: ["minimal-chime-copy"])
                == "minimal-chime-copy-2",
            "expected -copy-2 once -copy is taken")
        expect(
            nextForkPackID(
                for: "minimal-chime",
                existingUserPackIDs: ["minimal-chime-copy", "minimal-chime-copy-2"])
                == "minimal-chime-copy-3",
            "expected -copy-3 once -copy and -copy-2 are both taken")
    }

    // MARK: - forkPack: success path

    suite(
        "forkPack: success — new manifest id/name are rewritten, license/author removed,"
            + " events and audio files preserved"
    ) {
        withTempDirectory { root in
            let factory = root.appendingPathComponent("factory")
            let userPacksDirectory = root.appendingPathComponent("packs")
            let sourceDirectory = factory.appendingPathComponent("minimal-chime")
            writeForkSourceManifest(
                id: "minimal-chime", name: "极简铃", license: "CC0-1.0", author: "Claudio",
                events: ["stop": "stop.mp3", "notification": "ping.mp3"], to: sourceDirectory)
            writeFixture("fake-audio-stop", to: sourceDirectory.appendingPathComponent("stop.mp3"))
            writeFixture("fake-audio-ping", to: sourceDirectory.appendingPathComponent("ping.mp3"))

            let environment = makeAudioImportEnvironment(
                userPacksDirectory: userPacksDirectory, factoryPacksDirectory: factory)
            let result = forkPack(
                fromID: "minimal-chime", newID: "minimal-chime-copy", environment: environment)

            guard case .success = result else {
                expect(false, "expected forkPack to succeed, got \(result)")
                return
            }

            let destination = userPacksDirectory.appendingPathComponent("minimal-chime-copy")
            guard
                let data = try? Data(contentsOf: destination.appendingPathComponent("manifest.json")),
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                expect(false, "expected a readable manifest.json at the forked destination")
                return
            }

            expect(
                json["id"] as? String == "minimal-chime-copy",
                "id must be rewritten to newID, got \(String(describing: json["id"]))")
            expect(
                json["name"] as? String == "极简铃 的副本",
                "name must be '<原name> 的副本', got \(String(describing: json["name"]))")
            expect(json["license"] == nil, "license key must be entirely removed")
            expect(json["author"] == nil, "author key must be entirely removed")
            expect(
                (json["events"] as? [String: String])
                    == ["stop": "stop.mp3", "notification": "ping.mp3"],
                "events must be preserved byte-for-byte, got \(String(describing: json["events"]))")
            expect(
                (try? Data(contentsOf: destination.appendingPathComponent("stop.mp3")))
                    == "fake-audio-stop".data(using: .utf8),
                "audio files must be copied over unchanged")
            expect(
                (try? Data(contentsOf: destination.appendingPathComponent("ping.mp3")))
                    == "fake-audio-ping".data(using: .utf8),
                "audio files must be copied over unchanged")
        }
    }

    suite("forkPack: no `name` in the source manifest ⇒ the copy's name falls back to fromID") {
        withTempDirectory { root in
            let factory = root.appendingPathComponent("factory")
            let userPacksDirectory = root.appendingPathComponent("packs")
            let sourceDirectory = factory.appendingPathComponent("plain-pack")
            writeForkSourceManifest(id: "plain-pack", to: sourceDirectory)

            let environment = makeAudioImportEnvironment(
                userPacksDirectory: userPacksDirectory, factoryPacksDirectory: factory)
            let result = forkPack(
                fromID: "plain-pack", newID: "plain-pack-copy", environment: environment)

            guard case .success = result else {
                expect(false, "expected forkPack to succeed, got \(result)")
                return
            }
            let destination = userPacksDirectory.appendingPathComponent("plain-pack-copy")
            guard
                let data = try? Data(contentsOf: destination.appendingPathComponent("manifest.json")),
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                expect(false, "expected a readable manifest.json at the forked destination")
                return
            }
            expect(
                json["name"] as? String == "plain-pack 的副本",
                "expected the name to fall back to fromID, got \(String(describing: json["name"]))")
        }
    }

    // MARK: - forkPack: refusals, checked before any disk write where the plan requires it

    suite(
        "forkPack: refuses when userPacksDirectory/newID already exists — the source manifest's"
            + " bytes are left completely untouched"
    ) {
        withTempDirectory { root in
            let factory = root.appendingPathComponent("factory")
            let userPacksDirectory = root.appendingPathComponent("packs")
            let sourceDirectory = factory.appendingPathComponent("minimal-chime")
            writeForkSourceManifest(id: "minimal-chime", to: sourceDirectory)
            let sourceManifestFile = sourceDirectory.appendingPathComponent("manifest.json")
            let originalBytes = try? Data(contentsOf: sourceManifestFile)

            // The destination already has SOMETHING at it — doesn't even need to be a usable
            // pack (PLAN-SOUND-MANAGER.md §2.2: "若已经存在任何东西...一律拒绝").
            writeFixture(
                "junk", to: userPacksDirectory.appendingPathComponent("minimal-chime-copy/junk.txt"))

            let environment = makeAudioImportEnvironment(
                userPacksDirectory: userPacksDirectory, factoryPacksDirectory: factory)
            let result = forkPack(
                fromID: "minimal-chime", newID: "minimal-chime-copy", environment: environment)

            guard case .failure(let error) = result, case .destinationAlreadyExists = error else {
                expect(false, "expected .destinationAlreadyExists, got \(result)")
                return
            }
            expect(
                (try? Data(contentsOf: sourceManifestFile)) == originalBytes,
                "a refused fork must leave the source manifest byte-for-byte untouched")
        }
    }

    suite("forkPack: refuses an unsafe newID (path traversal) before any disk write") {
        withTempDirectory { root in
            let factory = root.appendingPathComponent("factory")
            let userPacksDirectory = root.appendingPathComponent("packs")
            try? FileManager.default.createDirectory(
                at: userPacksDirectory, withIntermediateDirectories: true)
            let sourceDirectory = factory.appendingPathComponent("minimal-chime")
            writeForkSourceManifest(id: "minimal-chime", to: sourceDirectory)

            let environment = makeAudioImportEnvironment(
                userPacksDirectory: userPacksDirectory, factoryPacksDirectory: factory)
            let result = forkPack(fromID: "minimal-chime", newID: "../evil", environment: environment)

            guard case .failure(let error) = result, case .unsafeNewID = error else {
                expect(false, "expected .unsafeNewID, got \(result)")
                return
            }
            let entriesAfter =
                (try? FileManager.default.contentsOfDirectory(atPath: userPacksDirectory.path)) ?? []
            expect(
                entriesAfter.isEmpty,
                "an unsafe newID must be refused before any disk write, found \(entriesAfter)")
        }
    }

    suite("forkPack: refuses an unsafe fromID before any disk write") {
        withTempDirectory { root in
            let factory = root.appendingPathComponent("factory")
            let userPacksDirectory = root.appendingPathComponent("packs")
            try? FileManager.default.createDirectory(
                at: userPacksDirectory, withIntermediateDirectories: true)

            let environment = makeAudioImportEnvironment(
                userPacksDirectory: userPacksDirectory, factoryPacksDirectory: factory)
            let result = forkPack(fromID: "../evil", newID: "safe-copy", environment: environment)

            guard case .failure(let error) = result, case .unsafeSourceID = error else {
                expect(false, "expected .unsafeSourceID, got \(result)")
                return
            }
            let entriesAfter =
                (try? FileManager.default.contentsOfDirectory(atPath: userPacksDirectory.path)) ?? []
            expect(
                entriesAfter.isEmpty,
                "an unsafe fromID must be refused before any disk write, found \(entriesAfter)")
        }
    }

    // MARK: - forkPack: mid-failure leaves only a dot-prefixed staging dir, never a half-pack

    suite(
        "forkPack: a corrupt source manifest fails the mutateManifestJSON step — nothing"
            + " non-dot-prefixed ever appears at the final path"
    ) {
        withTempDirectory { root in
            let factory = root.appendingPathComponent("factory")
            let userPacksDirectory = root.appendingPathComponent("packs")
            let sourceDirectory = factory.appendingPathComponent("broken-pack")
            // Not a JSON object at all — mutateManifestJSON's own fail-closed guard rejects it
            // (`manifest.json 顶层不是 JSON 对象`).
            writeFixture(
                "{ not valid json", to: sourceDirectory.appendingPathComponent("manifest.json"))

            let environment = makeAudioImportEnvironment(
                userPacksDirectory: userPacksDirectory, factoryPacksDirectory: factory)
            let result = forkPack(
                fromID: "broken-pack", newID: "broken-pack-copy", environment: environment)

            guard case .failure(let error) = result, case .manifestRewriteFailed = error else {
                expect(false, "expected .manifestRewriteFailed, got \(result)")
                return
            }
            let entriesAfter =
                (try? FileManager.default.contentsOfDirectory(atPath: userPacksDirectory.path)) ?? []
            expect(
                entriesAfter.allSatisfy { $0.hasPrefix(".") },
                "every surviving entry under userPacksDirectory after a failed fork must be"
                    + " dot-prefixed (a tmp scratch dir at worst) — never a visible half-finished"
                    + " pack, got \(entriesAfter)")
            expect(
                !entriesAfter.contains("broken-pack-copy"),
                "a failed fork must never leave a non-dot-prefixed entry at the final path,"
                    + " got \(entriesAfter)")
        }
    }

    suite("forkPack: factoryPacksDirectory nil ⇒ .sourceUnavailable, before any disk write") {
        withTempDirectory { root in
            let userPacksDirectory = root.appendingPathComponent("packs")
            try? FileManager.default.createDirectory(
                at: userPacksDirectory, withIntermediateDirectories: true)

            let environment = makeAudioImportEnvironment(userPacksDirectory: userPacksDirectory)
            let result = forkPack(
                fromID: "minimal-chime", newID: "minimal-chime-copy", environment: environment)

            guard case .failure(let error) = result, case .sourceUnavailable = error else {
                expect(false, "expected .sourceUnavailable, got \(result)")
                return
            }
            let entriesAfter =
                (try? FileManager.default.contentsOfDirectory(atPath: userPacksDirectory.path)) ?? []
            expect(
                entriesAfter.isEmpty,
                "a nil factoryPacksDirectory must be refused before any disk write, found"
                    + " \(entriesAfter)")
        }
    }

    // MARK: - Structural: factoryPacksDirectory never leaks into resolvePackDirectory / the
    // gallery's enumeration (PLAN-SOUND-MANAGER.md §2.3's explicitly-required assertion).

    suite(
        "structural: a pack id that exists ONLY under factoryPacksDirectory never appears in"
            + " availablePacks() — factoryPacksDirectory never reaches resolvePackDirectory"
    ) {
        withTempDirectory { root in
            let factory = root.appendingPathComponent("factory")
            let userPacksDirectory = root.appendingPathComponent("packs")
            try? FileManager.default.createDirectory(
                at: userPacksDirectory, withIntermediateDirectories: true)
            writeForkSourceManifest(
                id: "factory-only-pack", to: factory.appendingPathComponent("factory-only-pack"))

            let environment = makeAudioImportEnvironment(
                userPacksDirectory: userPacksDirectory, factoryPacksDirectory: factory)
            let config = ClaudioConfig(selectedPack: "")
            let cards = availablePacks(config: config, environment: environment)

            expect(
                !cards.contains { $0.id == "factory-only-pack" },
                "a pack id that exists only under factoryPacksDirectory must never be surfaced by"
                    + " availablePacks() — surfacing it would prove factoryPacksDirectory leaked"
                    + " into lookup/enumeration, got \(cards.map(\.id))")
        }
    }
}
