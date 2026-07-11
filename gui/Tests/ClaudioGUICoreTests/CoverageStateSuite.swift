import ClaudioCore
import ClaudioGUICore
import Foundation

// MARK: - CoverageState / EventRow / packCoverage (ENGINEERING.md T16 D2, DESIGN.md
// "事件行三态"): present/unmapped/broken per event, computed purely from the pack's
// manifest.json + on-disk file presence — this is the state gallery's (T14) and the real
// panel's (T15) shared render-ready fixture.

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

@MainActor
func runCoverageStateSuites() {
    // MARK: - previewEnabled / entersDoctor

    suite("CoverageState: previewEnabled is true ONLY for .present") {
        expect(
            CoverageState.present(fileName: "stop.mp3").previewEnabled,
            ".present must have previewEnabled == true")
        expect(!CoverageState.unmapped.previewEnabled, ".unmapped must have previewEnabled == false")
        expect(
            !CoverageState.broken(fileName: "stop.mp3").previewEnabled,
            ".broken must have previewEnabled == false")
    }

    suite("CoverageState: entersDoctor is true ONLY for .broken") {
        expect(
            !CoverageState.present(fileName: "stop.mp3").entersDoctor,
            ".present must have entersDoctor == false")
        expect(!CoverageState.unmapped.entersDoctor, ".unmapped must have entersDoctor == false")
        expect(
            CoverageState.broken(fileName: "stop.mp3").entersDoctor,
            ".broken must have entersDoctor == true")
    }

    // MARK: - packCoverage: per-event present/unmapped/broken

    suite("packCoverage: an event absent from the manifest reports .unmapped") {
        withTempDirectory { root in
            let userPacks = root.appendingPathComponent("packs")
            writeFixture(
                #"{ "id": "my-pack", "events": { "stop": "stop.mp3" } }"#,
                to: userPacks.appendingPathComponent("my-pack/manifest.json"))
            writeFixture("fake-audio", to: userPacks.appendingPathComponent("my-pack/stop.mp3"))

            let rows = packCoverage(
                packID: "my-pack", config: ClaudioConfig(selectedPack: "my-pack"),
                environment: makeEnvironment(userPacksDirectory: userPacks))

            let notification = rows.first { $0.event == .notification }
            expect(
                notification?.coverage == .unmapped,
                "notification has no manifest entry → .unmapped, got \(String(describing: notification?.coverage))"
            )
        }
    }

    suite("packCoverage: an event mapped to an existing, contained file reports .present") {
        withTempDirectory { root in
            let userPacks = root.appendingPathComponent("packs")
            writeFixture(
                #"{ "id": "my-pack", "events": { "stop": "stop.mp3" } }"#,
                to: userPacks.appendingPathComponent("my-pack/manifest.json"))
            writeFixture("fake-audio", to: userPacks.appendingPathComponent("my-pack/stop.mp3"))

            let rows = packCoverage(
                packID: "my-pack", config: ClaudioConfig(selectedPack: "my-pack"),
                environment: makeEnvironment(userPacksDirectory: userPacks))

            let stop = rows.first { $0.event == .stop }
            expect(
                stop?.coverage == .present(fileName: "stop.mp3"),
                "stop is mapped and the file exists → .present, got \(String(describing: stop?.coverage))"
            )
        }
    }

    suite("packCoverage: an event mapped to a file that doesn't exist on disk reports .broken") {
        withTempDirectory { root in
            let userPacks = root.appendingPathComponent("packs")
            writeFixture(
                #"{ "id": "my-pack", "events": { "stop_failure": "fail.mp3" } }"#,
                to: userPacks.appendingPathComponent("my-pack/manifest.json"))
            // `fail.mp3` is declared but never actually written to disk.

            let rows = packCoverage(
                packID: "my-pack", config: ClaudioConfig(selectedPack: "my-pack"),
                environment: makeEnvironment(userPacksDirectory: userPacks))

            let stopFailure = rows.first { $0.event == .stopFailure }
            expect(
                stopFailure?.coverage == .broken(fileName: "fail.mp3"),
                "stop_failure is mapped but the file is missing → .broken, got \(String(describing: stopFailure?.coverage))"
            )
        }
    }

    suite(
        "packCoverage: an event mapped to a file resolving outside the pack dir (symlink escape) reports .broken, never .present"
    ) {
        withTempDirectory { root in
            let userPacks = root.appendingPathComponent("packs")
            writeFixture(
                #"{ "id": "my-pack", "events": { "notification": "ping.mp3" } }"#,
                to: userPacks.appendingPathComponent("my-pack/manifest.json"))
            let outside = root.appendingPathComponent("outside-secret", isDirectory: true)
            try? FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            let outsideFile = outside.appendingPathComponent("real.mp3")
            writeFixture("fake-audio", to: outsideFile)
            createSymlink(
                at: userPacks.appendingPathComponent("my-pack/ping.mp3"), pointingTo: outsideFile)

            let rows = packCoverage(
                packID: "my-pack", config: ClaudioConfig(selectedPack: "my-pack"),
                environment: makeEnvironment(userPacksDirectory: userPacks))

            let notification = rows.first { $0.event == .notification }
            expect(
                notification?.coverage == .broken(fileName: "ping.mp3"),
                "a containment-failing (symlink-escaping) mapped file must report .broken, never"
                    + " .present, got \(String(describing: notification?.coverage))")
        }
    }

    suite(
        "packCoverage: an event mapped to a filename that is an IN-PACK symlink whose target resolves INSIDE the pack dir reports .present"
    ) {
        withTempDirectory { root in
            let userPacks = root.appendingPathComponent("packs")
            writeFixture(
                #"{ "id": "my-pack", "events": { "stop": "stop-link.mp3" } }"#,
                to: userPacks.appendingPathComponent("my-pack/manifest.json"))
            // The symlink's target is a REAL file, but crucially still INSIDE the pack
            // directory — unlike the escaping-symlink case above, this must satisfy
            // `isReallyContained` and report .present, not .broken.
            let realFile = userPacks.appendingPathComponent("my-pack/real-stop.mp3")
            writeFixture("fake-audio", to: realFile)
            createSymlink(
                at: userPacks.appendingPathComponent("my-pack/stop-link.mp3"), pointingTo: realFile)

            let rows = packCoverage(
                packID: "my-pack", config: ClaudioConfig(selectedPack: "my-pack"),
                environment: makeEnvironment(userPacksDirectory: userPacks))

            let stop = rows.first { $0.event == .stop }
            expect(
                stop?.coverage == .present(fileName: "stop-link.mp3"),
                "an in-pack symlink resolving to a real file still inside the pack dir must"
                    + " report .present, got \(String(describing: stop?.coverage))")
        }
    }

    suite("packCoverage: covers all four v1 events, exactly once each") {
        withTempDirectory { root in
            let userPacks = root.appendingPathComponent("packs")
            writeFixture(
                #"{ "id": "my-pack", "events": {} }"#,
                to: userPacks.appendingPathComponent("my-pack/manifest.json"))

            let rows = packCoverage(
                packID: "my-pack", config: ClaudioConfig(selectedPack: "my-pack"),
                environment: makeEnvironment(userPacksDirectory: userPacks))

            expect(rows.count == Event.allCases.count, "packCoverage must return exactly one row per event")
            expect(
                Set(rows.map(\.event)) == Set(Event.allCases),
                "packCoverage must cover every Event.allCases entry exactly once")
        }
    }

    // MARK: - Pack/manifest resolution failure → every event .unmapped

    suite("packCoverage: an unresolvable packID reports every event as .unmapped") {
        withTempDirectory { root in
            let userPacks = root.appendingPathComponent("packs")
            let rows = packCoverage(
                packID: "ghost-pack", config: ClaudioConfig(selectedPack: "ghost-pack"),
                environment: makeEnvironment(userPacksDirectory: userPacks))

            expect(
                rows.allSatisfy { $0.coverage == .unmapped },
                "an unresolvable pack must report every event .unmapped, got \(rows)")
        }
    }

    suite("packCoverage: a corrupt manifest.json reports every event as .unmapped, never crashes") {
        withTempDirectory { root in
            let userPacks = root.appendingPathComponent("packs")
            writeFixture(
                "{ not valid json", to: userPacks.appendingPathComponent("my-pack/manifest.json"))

            let rows = packCoverage(
                packID: "my-pack", config: ClaudioConfig(selectedPack: "my-pack"),
                environment: makeEnvironment(userPacksDirectory: userPacks))

            expect(
                rows.allSatisfy { $0.coverage == .unmapped },
                "a corrupt manifest must report every event .unmapped, got \(rows)")
        }
    }

    // MARK: - enabled orthogonality (决议③): does NOT change coverage

    suite("packCoverage: enabled=false does not change the computed CoverageState (orthogonal axes)")
    {
        withTempDirectory { root in
            let userPacks = root.appendingPathComponent("packs")
            writeFixture(
                #"{ "id": "my-pack", "events": { "stop": "stop.mp3" } }"#,
                to: userPacks.appendingPathComponent("my-pack/manifest.json"))
            writeFixture("fake-audio", to: userPacks.appendingPathComponent("my-pack/stop.mp3"))

            let mutedConfig = ClaudioConfig(
                selectedPack: "my-pack", eventsEnabled: ["stop": false])
            let rows = packCoverage(
                packID: "my-pack", config: mutedConfig,
                environment: makeEnvironment(userPacksDirectory: userPacks))

            let stop = rows.first { $0.event == .stop }
            expect(
                stop?.coverage == .present(fileName: "stop.mp3"),
                "muting an event must not change its CoverageState — still .present, got"
                    + " \(String(describing: stop?.coverage))")
            expect(stop?.enabled == false, "the row must still reflect enabled == false")
        }
    }

    suite("packCoverage: an event absent from config.events defaults to enabled (opt-out design)") {
        withTempDirectory { root in
            let userPacks = root.appendingPathComponent("packs")
            writeFixture(
                #"{ "id": "my-pack", "events": { "stop": "stop.mp3" } }"#,
                to: userPacks.appendingPathComponent("my-pack/manifest.json"))
            writeFixture("fake-audio", to: userPacks.appendingPathComponent("my-pack/stop.mp3"))

            let rows = packCoverage(
                packID: "my-pack", config: ClaudioConfig(selectedPack: "my-pack"),
                environment: makeEnvironment(userPacksDirectory: userPacks))

            expect(
                rows.allSatisfy(\.enabled),
                "every row must default to enabled == true when config.events doesn't mention it")
        }
    }

    // MARK: - checkPackIntegrity (helper doctor path): a broken (mapped-but-missing) file
    // is surfaced as a pack defect, matching CoverageState.broken's entersDoctor == true.

    suite(
        "checkPackIntegrity: a mapped-but-missing file (the same shape CoverageState calls .broken) is reported by doctor as .incomplete"
    ) {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let packsDir = root.appendingPathComponent("packs")
            writeFixture(#"{ "selected_pack": "my-pack" }"#, to: configFile)
            writeFixture(
                #"{ "id": "my-pack", "events": { "stop": "stop.mp3" } }"#,
                to: packsDir.appendingPathComponent("my-pack/manifest.json"))
            // `stop.mp3` is declared but never written — the exact fixture shape the
            // `packCoverage` suite above pins as `CoverageState.broken`.

            let status = checkPackIntegrity(
                configFile: configFile, userPacksDirectory: packsDir, bundledPacksDirectory: nil)
            expect(
                status == .incomplete(packID: "my-pack", missingFiles: ["stop.mp3"]),
                "a broken (mapped-but-missing) event file must surface via doctor's pack check,"
                    + " got \(status)")
        }
    }
}
