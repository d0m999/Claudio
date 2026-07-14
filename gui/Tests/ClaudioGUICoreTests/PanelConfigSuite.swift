import ClaudioCore
import ClaudioGUICore
import Foundation

// MARK: - loadPanelConfig (ENGINEERING.md T15 D1 panel glue, rewritten for D23): the panel's
// complete verdict on config.json — combining the read axis (packSelection) and the write axis
// (probeConfigRewritable) into one ``PanelConfigState``. Never crashes over a missing/corrupt
// config.json, but — unlike the pre-D23 shape — no longer collapses "nobody has chosen a pack
// yet" (self-heal is open) and "the file itself is broken" (self-heal is NOT open, needs an
// honest failure state + a fix instruction) into the same empty-pack default.

@MainActor
func runPanelConfigSuites() {
    suite("loadPanelConfig: a missing config.json is .needsPack — not an error, the self-heal path (picking a pack) is open") {
        withTempDirectory { root in
            let state = loadPanelConfig(from: root.appendingPathComponent("config.json"))
            expect(state == .needsPack, "a missing file must report .needsPack, got \(state)")
            expect(
                state.resolvedConfig.selectedPack == "",
                "resolvedConfig must still hand back an empty-pack default for read models"
                    + " (packCoverage/availablePacks), got \(state.resolvedConfig.selectedPack)")
            expect(
                state.resolvedConfig.masterVolume == ClaudioConfig.defaultMasterVolume,
                "resolvedConfig's default must match the documented default master_volume")
        }
    }

    suite("loadPanelConfig: a corrupt config.json is .malformed with an actionable reason — never .needsPack (D23: these two used to be the same empty-pack fallback, hiding that self-heal is NOT open here)") {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            writeFixture("{ not valid json", to: configFile)
            let state = loadPanelConfig(from: configFile)
            guard case .malformed(let reason) = state else {
                expect(false, "a corrupt file must report .malformed, got \(state)")
                return
            }
            expect(!reason.isEmpty, "the malformed reason must not be empty")
            expect(
                state.resolvedConfig.selectedPack == "",
                "resolvedConfig must still be crash-safe for a malformed file, got"
                    + " \(state.resolvedConfig.selectedPack)")
        }
    }

    suite("loadPanelConfig: selected_pack is an empty string is .needsPack, same as a missing file") {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            writeFixture(#"{ "selected_pack": "" }"#, to: configFile)
            let state = loadPanelConfig(from: configFile)
            expect(state == .needsPack, "an empty selected_pack must report .needsPack, got \(state)")
        }
    }

    suite("loadPanelConfig: a well-formed config.json decodes exactly into .operational") {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            writeFixture(
                #"{ "selected_pack": "minimal-chime", "master_volume": 0.42, "events": { "stop": false } }"#,
                to: configFile)
            let state = loadPanelConfig(from: configFile)
            guard case .operational(let config) = state else {
                expect(false, "a well-formed config must report .operational, got \(state)")
                return
            }
            expect(config.selectedPack == "minimal-chime", "got \(config.selectedPack)")
            expect(config.masterVolume == 0.42, "got \(config.masterVolume)")
            expect(config.isEnabled(.stop) == false, "got \(config.isEnabled(.stop))")
        }
    }

    suite(
        "loadPanelConfig: selected_pack parses fine but master_volume is a string (读得动、写不动)"
            + " — must be .malformed, never .operational (D23 定稿②'s whole reason for existing:"
            + " the read axis alone would call this usable, and every click would then fail)"
    ) {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            writeFixture(
                #"{ "selected_pack": "lofi", "master_volume": "0.35" }"#, to: configFile)
            let state = loadPanelConfig(from: configFile)
            guard case .malformed = state else {
                expect(
                    false,
                    "a config that reads as selected but fails the write axis must be .malformed,"
                        + " not .operational — got \(state)")
                return
            }
        }
    }

    suite("loadPanelConfig: content is fine but the parent directory is read-only → .unwritable, not .operational") {
        guard geteuid() != 0 else {
            print("  ⚠︎ 跳过：当前以 root 运行，chmod 只读目录挡不住 root 写入")
            return
        }
        withTempDirectory { root in
            let restrictedDirectory = root.appendingPathComponent("restricted", isDirectory: true)
            try? FileManager.default.createDirectory(
                at: restrictedDirectory, withIntermediateDirectories: true)
            let configFile = restrictedDirectory.appendingPathComponent("config.json")
            writeFixture(#"{ "selected_pack": "lofi" }"#, to: configFile)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o500], ofItemAtPath: restrictedDirectory.path)
            defer {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o700], ofItemAtPath: restrictedDirectory.path)
            }

            let state = loadPanelConfig(from: configFile)
            guard case .unwritable(let reason) = state else {
                expect(false, "a config whose directory is read-only must be .unwritable, got \(state)")
                return
            }
            expect(reason.contains(restrictedDirectory.path), "got \(reason)")
        }
    }
}
