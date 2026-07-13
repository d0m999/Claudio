import ClaudioCore
import ClaudioGUICore
import Foundation

// MARK: - EventMuteController (ENGINEERING.md T15 D4 GUI-side wiring): a thin `@MainActor`
// wrapper around `setEventEnabled` — these tests pin the wrapper's own bookkeeping
// (`lastError`), not `setEventEnabled`'s read-modify-write itself (that's covered
// exhaustively by `helper/Tests/ClaudioCoreTests/EventEnabledSuite.swift`).

@MainActor
func runEventMuteControllerSuites() {
    suite("EventMuteController()'s default lockFile is ClaudioPaths.configLockFile, never playLockFile") {
        // Lock separation (D9): the mute button's config.json write must never contend with, or
        // be gated by, `play`'s debounce lock — that contention is exactly what was silently
        // swallowing prompt sounds before this split. Type-level only, no injected paths.
        expect(
            EventMuteController().lockFile == ClaudioPaths.configLockFile,
            "EventMuteController()'s default lockFile must be ClaudioPaths.configLockFile, got "
                + "\(EventMuteController().lockFile.path)"
        )
    }

    suite(
        "EventMuteController: setEnabled fails closed with .configMissing when config.json"
            + " doesn't exist yet (D23 定稿① — it used to silently create one with an empty"
            + " selected_pack; setEventEnabled no longer does that, see EventEnabledSuite.swift)"
    ) {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let controller = EventMuteController(
                configFile: configFile, lockFile: root.appendingPathComponent("config.lock"))

            let succeeded = controller.setEnabled(.stop, enabled: false)
            expect(!succeeded, "a missing config.json must fail the call, not silently create one")
            expect(
                controller.lastError == .configMissing,
                "lastError must be .configMissing, got \(String(describing: controller.lastError))")
            expect(
                !FileManager.default.fileExists(atPath: configFile.path),
                "a rejected write must not create config.json")
        }
    }

    suite("EventMuteController: setEnabled writes through and returns true, clearing lastError") {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            // D23 定稿①之后，setEventEnabled 对缺失的 config fail closed——这条「干净写入成功」的
            // 覆盖率必须针对一份已经存在的 config.json（切包/自举已经建好的那种正常状态），而不是
            // 依赖静音钮自己新建一份。
            writeFixture(#"{ "selected_pack": "minimal-chime" }"#, to: configFile)
            let controller = EventMuteController(
                configFile: configFile,
                lockFile: root.appendingPathComponent("config.lock"))

            let succeeded = controller.setEnabled(.stop, enabled: false)
            expect(succeeded, "a clean write must return true")
            expect(controller.lastError == nil, "a successful call must clear lastError")

            let data = try? Data(contentsOf: configFile)
            let config = data.flatMap { try? JSONDecoder().decode(ClaudioConfig.self, from: $0) }
            expect(config?.isEnabled(.stop) == false, "the underlying config.json must reflect the flip")
        }
    }

    suite("EventMuteController: a corrupt config.json fails and records lastError") {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            writeFixture("{ not valid json", to: configFile)
            let controller = EventMuteController(
                configFile: configFile, lockFile: root.appendingPathComponent("config.lock"))

            let succeeded = controller.setEnabled(.stop, enabled: false)
            expect(!succeeded, "a corrupt config.json must fail the call")
            guard case .configReadFailure = controller.lastError else {
                expect(false, "lastError must be .configReadFailure, got \(String(describing: controller.lastError))")
                return
            }
        }
    }

    suite("EventMuteController: a contended lock fails and records .lockBusy") {
        withTempDirectory { root in
            let lockFile = root.appendingPathComponent("config.lock")
            let controller = EventMuteController(
                configFile: root.appendingPathComponent("config.json"), lockFile: lockFile)

            let holder = FileLock(path: lockFile.path)
            expect(holder.tryLock(), "test setup: holder must acquire config.lock first")

            let succeeded = controller.setEnabled(.stop, enabled: false)
            expect(!succeeded, "a contended lock must fail the call")
            expect(controller.lastError == .lockBusy, "lastError must be .lockBusy, got \(String(describing: controller.lastError))")

            holder.unlock()
        }
    }

    suite("EventMuteController: a second successful call after a failure clears the recorded error") {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            writeFixture("{ not valid json", to: configFile)
            let controller = EventMuteController(
                configFile: configFile, lockFile: root.appendingPathComponent("config.lock"))

            expect(!controller.setEnabled(.stop, enabled: false), "setup: first call must fail")
            expect(controller.lastError != nil, "setup: lastError must be recorded")

            // Fix the file out from under the controller, then retry.
            writeFixture(#"{ "selected_pack": "minimal-chime" }"#, to: configFile)
            let succeeded = controller.setEnabled(.stop, enabled: false)
            expect(succeeded, "the retried call against a now-valid file must succeed")
            expect(controller.lastError == nil, "a later success must clear the earlier recorded error")
        }
    }
}
