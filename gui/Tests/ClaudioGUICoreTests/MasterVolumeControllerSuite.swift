import ClaudioCore
import ClaudioGUICore
import Foundation

// MARK: - MasterVolumeController (PLAN-MASTER-VOLUME.md 阶段 C4): a thin `@MainActor` wrapper
// around `setMasterVolume` — these tests pin the wrapper's own bookkeeping (`lastError`,
// forwarding the landed value), not `setMasterVolume`'s read-modify-write itself (that's
// covered exhaustively by `helper/Tests/ClaudioCoreTests/VolumeSuite.swift`). Mirrors
// `EventMuteControllerSuite.swift`'s shape — same lock, same missing-config policy (D23 定稿①).

@MainActor
func runMasterVolumeControllerSuites() {
    suite("MasterVolumeController()'s default lockFile is ClaudioPaths.configLockFile, never playLockFile") {
        // Lock separation (D9): the volume slider's config.json write must never contend with,
        // or be gated by, `play`'s debounce lock — the same contention that used to silently
        // swallow prompt sounds. Type-level only, no injected paths.
        expect(
            MasterVolumeController().lockFile == ClaudioPaths.configLockFile,
            "MasterVolumeController()'s default lockFile must be ClaudioPaths.configLockFile, got "
                + "\(MasterVolumeController().lockFile.path)"
        )
    }

    suite("MasterVolumeController: setVolume writes through, returns the landed value, clearing lastError") {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            writeFixture(#"{ "selected_pack": "minimal-chime" }"#, to: configFile)
            let controller = MasterVolumeController(
                configFile: configFile,
                lockFile: root.appendingPathComponent("config.lock"))

            let landed = controller.setVolume(0.35)
            expect(landed == 0.35, "a clean write must return the landed value, got \(String(describing: landed))")
            expect(controller.lastError == nil, "a successful call must clear lastError")

            let data = try? Data(contentsOf: configFile)
            let config = data.flatMap { try? JSONDecoder().decode(ClaudioConfig.self, from: $0) }
            expect(config?.masterVolume == 0.35, "the underlying config.json must reflect the write")
        }
    }

    suite("MasterVolumeController: a missing config.json fails closed with .configMissing") {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let controller = MasterVolumeController(
                configFile: configFile, lockFile: root.appendingPathComponent("config.lock"))

            let landed = controller.setVolume(0.5)
            expect(landed == nil, "a missing config.json must fail the call, not silently create one")
            expect(
                controller.lastError == .configMissing,
                "lastError must be .configMissing, got \(String(describing: controller.lastError))")
            expect(
                !FileManager.default.fileExists(atPath: configFile.path),
                "a rejected write must not create config.json")
        }
    }

    suite("MasterVolumeController: a corrupt config.json fails and records lastError") {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            writeFixture("{ not valid json", to: configFile)
            let controller = MasterVolumeController(
                configFile: configFile, lockFile: root.appendingPathComponent("config.lock"))

            let landed = controller.setVolume(0.5)
            expect(landed == nil, "a corrupt config.json must fail the call")
            guard case .configReadFailure = controller.lastError else {
                expect(false, "lastError must be .configReadFailure, got \(String(describing: controller.lastError))")
                return
            }
        }
    }

    suite("MasterVolumeController: a contended lock fails and records .lockBusy") {
        withTempDirectory { root in
            let lockFile = root.appendingPathComponent("config.lock")
            let controller = MasterVolumeController(
                configFile: root.appendingPathComponent("config.json"), lockFile: lockFile)

            let holder = FileLock(path: lockFile.path)
            expect(holder.tryLock(), "test setup: holder must acquire config.lock first")

            let landed = controller.setVolume(0.5)
            expect(landed == nil, "a contended lock must fail the call")
            expect(
                controller.lastError == .lockBusy,
                "lastError must be .lockBusy, got \(String(describing: controller.lastError))")

            holder.unlock()
        }
    }

    suite("MasterVolumeController: a second successful call after a failure clears the recorded error") {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            writeFixture("{ not valid json", to: configFile)
            let controller = MasterVolumeController(
                configFile: configFile, lockFile: root.appendingPathComponent("config.lock"))

            expect(controller.setVolume(0.5) == nil, "setup: first call must fail")
            expect(controller.lastError != nil, "setup: lastError must be recorded")

            // Fix the file out from under the controller, then retry.
            writeFixture(#"{ "selected_pack": "minimal-chime" }"#, to: configFile)
            let landed = controller.setVolume(0.5)
            expect(landed == 0.5, "the retried call against a now-valid file must succeed")
            expect(controller.lastError == nil, "a later success must clear the earlier recorded error")
        }
    }

    // MARK: - previewVolume(for:) (D29): forwards ClaudioConfig.masterVolume through
    // AfplayVolume.clamped, no second clamp table re-derived here — that table is already
    // exhaustively covered by helper/Tests/ClaudioCoreTests/VolumeSuite.swift.

    suite("previewVolume(for:): forwards masterVolume through AfplayVolume.clamped, in-range value unchanged") {
        let config = ClaudioConfig(selectedPack: "minimal-chime", masterVolume: 0.35)
        expect(
            previewVolume(for: config) == AfplayVolume.clamped(0.35),
            "previewVolume must forward the exact value AfplayVolume.clamped(_:) would produce")
        expect(previewVolume(for: config) == 0.35, "an in-range value must pass through unchanged")
    }

    suite("previewVolume(for:): default masterVolume forwards straight through") {
        let config = ClaudioConfig(selectedPack: "minimal-chime")
        expect(
            previewVolume(for: config) == ClaudioConfig.defaultMasterVolume,
            "a config with no explicit masterVolume must preview at the documented default")
    }

    suite("previewVolume(for:): defers clamping of out-of-range and non-finite values to AfplayVolume.clamped") {
        // Non-finite values can only be constructed via the public memberwise init — the
        // Decodable path already falls back to the default during decode, so a JSON fixture
        // can never produce a NaN/±infinity ClaudioConfig (see ClaudioConfig.swift).
        let cases: [Double] = [-3.0, 4.2, .nan, .infinity, -.infinity]
        for masterVolume in cases {
            let config = ClaudioConfig(selectedPack: "minimal-chime", masterVolume: masterVolume)
            expect(
                previewVolume(for: config) == AfplayVolume.clamped(masterVolume),
                "previewVolume must not re-derive its own clamp table — it must defer byte-for-byte"
                    + " to AfplayVolume.clamped(_:) for \(masterVolume)")
        }
    }
}
