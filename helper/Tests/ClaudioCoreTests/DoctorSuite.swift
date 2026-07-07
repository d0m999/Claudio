import ClaudioCore
import Foundation

// MARK: - doctor: three real self-checks (ENGINEERING.md T1 handoff)
//
// (a) settings.json 可写 — read-only probe (access/isWritableFile), NEVER writes.
// (b) 包完整 — parses the selected pack's manifest + checks its declared audio files
//     exist; missing config / missing pack / corrupt manifest are all reported as
//     *warnings* (graceful status, not a crash) — a fresh install with no pack yet is
//     expected and must not fail doctor.
// (c) afplay 在位.
//
// Hard failures (→ non-zero exit) are ONLY: afplay missing, settings.json not writable.
// Everything pack-related is a warning in v1 doctor.

@MainActor
func runDoctorSuites() {
    suite("ClaudioConfig decodes required + optional fields with graceful defaults") {
        let full = """
            { "selected_pack": "minimal-chime", "master_volume": 0.5,
              "events": { "stop": false, "notification": true } }
            """.data(using: .utf8)!
        let decodedFull = try? JSONDecoder().decode(ClaudioConfig.self, from: full)
        expect(decodedFull?.selectedPack == "minimal-chime", "selected_pack decodes")
        expect(decodedFull?.masterVolume == 0.5, "master_volume decodes")
        expect(decodedFull?.isEnabled(.stop) == false, "per-event enabled=false honored")
        expect(decodedFull?.isEnabled(.notification) == true, "per-event enabled=true honored")
        expect(
            decodedFull?.isEnabled(.subagentStop) == true,
            "events absent from the map default to enabled (opt-out design)")

        let minimal = """
            { "selected_pack": "minimal-chime" }
            """.data(using: .utf8)!
        let decodedMinimal = try? JSONDecoder().decode(ClaudioConfig.self, from: minimal)
        expect(
            decodedMinimal?.masterVolume == ClaudioConfig.defaultMasterVolume,
            "missing master_volume falls back to the documented default")
        expect(
            decodedMinimal?.isEnabled(.stop) == true,
            "missing events map: every event defaults to enabled")

        let missingSelectedPack = """
            { "master_volume": 0.5 }
            """.data(using: .utf8)!
        let decodedMissingPack = try? JSONDecoder().decode(
            ClaudioConfig.self, from: missingSelectedPack)
        expect(decodedMissingPack == nil, "selected_pack is required; missing it must fail decode")
    }

    suite("resolvePackDirectory prefers the user pack root over the bundled pack") {
        withTempDirectory { root in
            let userPacks = root.appendingPathComponent("user-packs", isDirectory: true)
            let bundledPacks = root.appendingPathComponent("bundled-packs", isDirectory: true)
            let userPackDir = userPacks.appendingPathComponent("minimal-chime", isDirectory: true)
            let bundledPackDir = bundledPacks.appendingPathComponent(
                "minimal-chime", isDirectory: true)
            try? FileManager.default.createDirectory(
                at: userPackDir, withIntermediateDirectories: true)
            try? FileManager.default.createDirectory(
                at: bundledPackDir, withIntermediateDirectories: true)

            let resolved = resolvePackDirectory(
                id: "minimal-chime", userPacksDirectory: userPacks,
                bundledPacksDirectory: bundledPacks)
            expect(
                resolved?.path == userPackDir.path,
                "user pack root must win when a same-id pack exists in both")
        }
    }

    suite("resolvePackDirectory falls back to the bundled pack when no user pack exists") {
        withTempDirectory { root in
            let userPacks = root.appendingPathComponent("user-packs", isDirectory: true)
            let bundledPacks = root.appendingPathComponent("bundled-packs", isDirectory: true)
            let bundledPackDir = bundledPacks.appendingPathComponent(
                "minimal-chime", isDirectory: true)
            try? FileManager.default.createDirectory(
                at: bundledPackDir, withIntermediateDirectories: true)

            let resolved = resolvePackDirectory(
                id: "minimal-chime", userPacksDirectory: userPacks,
                bundledPacksDirectory: bundledPacks)
            expect(resolved?.path == bundledPackDir.path, "bundled pack used as fallback")
        }
    }

    suite("resolvePackDirectory returns nil when the pack exists nowhere") {
        withTempDirectory { root in
            let userPacks = root.appendingPathComponent("user-packs", isDirectory: true)
            let resolved = resolvePackDirectory(
                id: "ghost-pack", userPacksDirectory: userPacks, bundledPacksDirectory: nil)
            expect(resolved == nil, "unknown pack id resolves to nil, not a crash")
        }
    }

    suite("checkPackIntegrity: no config.json at all → .noConfig (fresh install, not an error)") {
        withTempDirectory { root in
            let status = checkPackIntegrity(
                configFile: root.appendingPathComponent("config.json"),
                userPacksDirectory: root.appendingPathComponent("packs"),
                bundledPacksDirectory: nil)
            expect(status == .noConfig, "missing config.json must report .noConfig, not throw")
        }
    }

    suite("checkPackIntegrity: corrupt config.json → .configUnreadable, not a crash") {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            writeFixture("{ not valid json", to: configFile)
            let status = checkPackIntegrity(
                configFile: configFile, userPacksDirectory: root.appendingPathComponent("packs"),
                bundledPacksDirectory: nil)
            if case .configUnreadable = status {
                // expected
            } else {
                expect(false, "expected .configUnreadable, got \(status)")
            }
        }
    }

    suite("checkPackIntegrity: selected pack missing from disk → .packNotFound") {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            writeFixture(#"{ "selected_pack": "ghost-pack" }"#, to: configFile)
            let status = checkPackIntegrity(
                configFile: configFile, userPacksDirectory: root.appendingPathComponent("packs"),
                bundledPacksDirectory: nil)
            expect(
                status == .packNotFound(packID: "ghost-pack"),
                "expected .packNotFound(ghost-pack), got \(status)")
        }
    }

    suite("checkPackIntegrity: corrupt manifest.json → .manifestUnreadable") {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let packsDir = root.appendingPathComponent("packs")
            writeFixture(#"{ "selected_pack": "minimal-chime" }"#, to: configFile)
            writeFixture(
                "{ not valid json",
                to: packsDir.appendingPathComponent("minimal-chime/manifest.json"))

            let status = checkPackIntegrity(
                configFile: configFile, userPacksDirectory: packsDir, bundledPacksDirectory: nil)
            if case .manifestUnreadable(let packID, _) = status {
                expect(packID == "minimal-chime", "manifestUnreadable should carry the pack id")
            } else {
                expect(false, "expected .manifestUnreadable, got \(status)")
            }
        }
    }

    suite("checkPackIntegrity: manifest present but declared audio file missing → .incomplete") {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let packsDir = root.appendingPathComponent("packs")
            writeFixture(#"{ "selected_pack": "minimal-chime" }"#, to: configFile)
            writeFixture(
                #"""
                { "id": "minimal-chime", "events": { "stop": "stop.mp3", "notification": "notification.mp3" } }
                """#,
                to: packsDir.appendingPathComponent("minimal-chime/manifest.json"))
            // Only `stop.mp3` actually exists on disk — `notification.mp3` is missing.
            writeFixture(
                "fake-audio", to: packsDir.appendingPathComponent("minimal-chime/stop.mp3"))

            let status = checkPackIntegrity(
                configFile: configFile, userPacksDirectory: packsDir, bundledPacksDirectory: nil)
            expect(
                status == .incomplete(packID: "minimal-chime", missingFiles: ["notification.mp3"]),
                "expected .incomplete with notification.mp3 missing, got \(status)")
        }
    }

    suite("checkPackIntegrity: all declared audio files present → .complete") {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let packsDir = root.appendingPathComponent("packs")
            writeFixture(#"{ "selected_pack": "minimal-chime" }"#, to: configFile)
            writeFixture(
                #"""
                { "id": "minimal-chime", "events": { "stop": "stop.mp3", "notification": "notification.mp3" } }
                """#,
                to: packsDir.appendingPathComponent("minimal-chime/manifest.json"))
            writeFixture(
                "fake-audio", to: packsDir.appendingPathComponent("minimal-chime/stop.mp3"))
            writeFixture(
                "fake-audio", to: packsDir.appendingPathComponent("minimal-chime/notification.mp3"))

            let status = checkPackIntegrity(
                configFile: configFile, userPacksDirectory: packsDir, bundledPacksDirectory: nil)
            expect(
                status
                    == .complete(packID: "minimal-chime", events: ["notification", "stop"]),
                "expected .complete with both events, got \(status)")
        }
    }

    suite("probeSettingsWritable: existing writable file → .writable") {
        withTempDirectory { root in
            let settingsFile = root.appendingPathComponent("settings.json")
            writeFixture("{}", to: settingsFile)
            expect(
                probeSettingsWritable(settingsFile: settingsFile) == .writable,
                "existing, writable settings.json should report .writable")
        }
    }

    suite("probeSettingsWritable: existing read-only file → .notWritable") {
        withTempDirectory { root in
            let settingsFile = root.appendingPathComponent("settings.json")
            writeFixture("{}", to: settingsFile)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o400], ofItemAtPath: settingsFile.path)
            defer {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o600], ofItemAtPath: settingsFile.path)
            }
            if case .notWritable = probeSettingsWritable(settingsFile: settingsFile) {
                // expected
            } else {
                expect(false, "read-only settings.json should report .notWritable")
            }
        }
    }

    suite("probeSettingsWritable: missing file, writable parent dir → .writable") {
        withTempDirectory { root in
            let settingsFile = root.appendingPathComponent("settings.json")
            expect(
                probeSettingsWritable(settingsFile: settingsFile) == .writable,
                "settings.json not created yet, but parent dir writable → .writable"
                    + " (claudio install will create it)")
        }
    }

    suite("probeSettingsWritable: never actually writes to disk (read-only probe)") {
        withTempDirectory { root in
            let settingsFile = root.appendingPathComponent("settings.json")
            _ = probeSettingsWritable(settingsFile: settingsFile)
            expect(
                !FileManager.default.fileExists(atPath: settingsFile.path),
                "probing writability must never create/touch the real file")
        }
    }

    suite("runDoctorChecks: afplay missing is a hard failure (non-zero exit)") {
        withTempDirectory { root in
            let settingsFile = root.appendingPathComponent("settings.json")
            writeFixture("{}", to: settingsFile)
            let env = DoctorEnvironment(
                afplayPath: root.appendingPathComponent("no-such-afplay").path,
                settingsFile: settingsFile,
                configFile: root.appendingPathComponent("config.json"),
                userPacksDirectory: root.appendingPathComponent("packs"),
                bundledPacksDirectory: nil)
            let report = runDoctorChecks(environment: env)
            expect(report.hasFailure, "missing afplay must set hasFailure (exit non-zero)")
        }
    }

    suite("runDoctorChecks: unwritable settings.json is a hard failure (non-zero exit)") {
        withTempDirectory { root in
            let settingsFile = root.appendingPathComponent("settings.json")
            writeFixture("{}", to: settingsFile)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o400], ofItemAtPath: settingsFile.path)
            defer {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o600], ofItemAtPath: settingsFile.path)
            }
            let env = DoctorEnvironment(
                afplayPath: "/usr/bin/afplay",
                settingsFile: settingsFile,
                configFile: root.appendingPathComponent("config.json"),
                userPacksDirectory: root.appendingPathComponent("packs"),
                bundledPacksDirectory: nil)
            let report = runDoctorChecks(environment: env)
            expect(report.hasFailure, "unwritable settings.json must set hasFailure")
        }
    }

    suite(
        "runDoctorChecks: fresh install with no pack configured is a warning, NOT a hard failure"
    ) {
        withTempDirectory { root in
            let settingsFile = root.appendingPathComponent("settings.json")
            writeFixture("{}", to: settingsFile)
            let env = DoctorEnvironment(
                afplayPath: "/usr/bin/afplay",
                settingsFile: settingsFile,
                configFile: root.appendingPathComponent("config.json"),
                userPacksDirectory: root.appendingPathComponent("packs"),
                bundledPacksDirectory: nil)
            let report = runDoctorChecks(environment: env)
            expect(
                !report.hasFailure,
                "no config.json yet (fresh install) must NOT fail doctor — it's a warning")
            expect(
                report.results.contains { $0.severity == .warning },
                "fresh install should still surface a warning result for visibility")
        }
    }

    suite("runDoctorChecks: everything healthy → no failures, no warnings") {
        withTempDirectory { root in
            let settingsFile = root.appendingPathComponent("settings.json")
            let packsDir = root.appendingPathComponent("packs")
            writeFixture("{}", to: settingsFile)
            writeFixture(
                #"{ "selected_pack": "minimal-chime" }"#,
                to: root.appendingPathComponent("config.json"))
            writeFixture(
                #"{ "id": "minimal-chime", "events": { "stop": "stop.mp3" } }"#,
                to: packsDir.appendingPathComponent("minimal-chime/manifest.json"))
            writeFixture(
                "fake-audio", to: packsDir.appendingPathComponent("minimal-chime/stop.mp3"))

            let env = DoctorEnvironment(
                afplayPath: "/usr/bin/afplay",
                settingsFile: settingsFile,
                configFile: root.appendingPathComponent("config.json"),
                userPacksDirectory: packsDir,
                bundledPacksDirectory: nil)
            let report = runDoctorChecks(environment: env)
            expect(!report.hasFailure, "fully healthy environment must not fail")
            expect(
                !report.results.contains { $0.severity == .warning },
                "fully healthy environment should have no warnings either")
        }
    }
}
