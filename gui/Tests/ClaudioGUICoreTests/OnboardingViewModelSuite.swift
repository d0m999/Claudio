import ClaudioCore
import ClaudioGUICore
import Foundation

// MARK: - OnboardingViewModel: state + copy binding, transitions, CTA hooks (T7)

@MainActor
private func makeReadyEnvironment(in root: URL) -> OnboardingEnvironment {
    let claudeDirectory = root.appendingPathComponent("dot-claude", isDirectory: true)
    try? FileManager.default.createDirectory(
        at: claudeDirectory, withIntermediateDirectories: true)
    return OnboardingEnvironment(
        settingsFile: claudeDirectory.appendingPathComponent("settings.json"),
        claudioBinaryPath: root.appendingPathComponent("dot-claudio/bin/claudio"))
}

@MainActor
func runOnboardingViewModelSuites() {
    suite("init: state matches detectOnboardingState(environment:) for the given fixture") {
        withTempDirectory { root in
            let environment = makeReadyEnvironment(in: root)  // binary not yet created
            let viewModel = OnboardingViewModel(environment: environment)
            expect(
                viewModel.state == .helperMissing,
                "initial state must reflect detection against the injected environment, got \(viewModel.state)"
            )
        }
    }

    suite("copy always matches onboardingCopy(for: state) — never drifts, even across refreshes") {
        withTempDirectory { root in
            let environment = makeReadyEnvironment(in: root)
            let viewModel = OnboardingViewModel(environment: environment)
            expect(
                viewModel.copy == onboardingCopy(for: viewModel.state),
                "copy must equal onboardingCopy(for: state) right after init")

            writeExecutableFile(at: environment.claudioBinaryPath)
            viewModel.refresh()
            expect(
                viewModel.state == .notInstalled,
                "sanity: refresh must have transitioned state, got \(viewModel.state)")
            expect(
                viewModel.copy == onboardingCopy(for: viewModel.state),
                "copy must still equal onboardingCopy(for: state) after refresh() changed state")
        }
    }

    suite("refresh(): re-detects against the current environment (state machine's transition rule)") {
        withTempDirectory { root in
            let environment = makeReadyEnvironment(in: root)
            let viewModel = OnboardingViewModel(environment: environment)
            expect(viewModel.state == .helperMissing, "setup: must start as helperMissing")

            writeExecutableFile(at: environment.claudioBinaryPath)
            viewModel.refresh()
            expect(
                viewModel.state == .notInstalled,
                "refresh() must transition helperMissing -> notInstalled once the binary appears")

            let path = environment.claudioBinaryPath.path
            let entries = Event.allCases.map { event in
                #"""
                "\#(event.settingsName)": [ { "hooks": [ { "type": "command", "command": "\#(claudioHookCommand(for: event, claudioBinaryPath: path))" } ] } ]
                """#
            }.joined(separator: ",\n")
            writeFixture("{ \"hooks\": { \(entries) } }", to: environment.settingsFile)
            viewModel.refresh()
            expect(
                viewModel.state == .installed,
                "refresh() must transition notInstalled -> installed once the hook is fully present")
        }
    }

    suite("refresh(): reflects a NEW environment if `environment` itself is reassigned") {
        withTempDirectory { root in
            let firstEnvironment = makeReadyEnvironment(in: root)  // helperMissing
            let viewModel = OnboardingViewModel(environment: firstEnvironment)
            expect(viewModel.state == .helperMissing, "setup: must start as helperMissing")

            // A completely different fixture, already fully installed.
            let secondRoot = root.appendingPathComponent("second-fixture", isDirectory: true)
            let secondEnvironment = makeReadyEnvironment(in: secondRoot)
            writeExecutableFile(at: secondEnvironment.claudioBinaryPath)
            let path = secondEnvironment.claudioBinaryPath.path
            let entries = Event.allCases.map { event in
                #"""
                "\#(event.settingsName)": [ { "hooks": [ { "type": "command", "command": "\#(claudioHookCommand(for: event, claudioBinaryPath: path))" } ] } ]
                """#
            }.joined(separator: ",\n")
            writeFixture("{ \"hooks\": { \(entries) } }", to: secondEnvironment.settingsFile)

            viewModel.environment = secondEnvironment
            viewModel.refresh()
            expect(
                viewModel.state == .installed,
                "refresh() must use the reassigned `environment`, not the one passed to init")
        }
    }

    suite("performPrimaryAction(): invokes onPrimaryAction, then refreshes against its effect") {
        withTempDirectory { root in
            let environment = makeReadyEnvironment(in: root)
            let viewModel = OnboardingViewModel(environment: environment)
            expect(viewModel.state == .helperMissing, "setup: must start as helperMissing")

            var invoked = false
            viewModel.onPrimaryAction = {
                invoked = true
                // Simulate "the fix landed": create the missing helper binary.
                writeExecutableFile(at: environment.claudioBinaryPath)
            }

            viewModel.performPrimaryAction()
            expect(invoked, "performPrimaryAction() must invoke the injected onPrimaryAction closure")
            expect(
                viewModel.state == .notInstalled,
                "performPrimaryAction() must refresh() after running the action, picking up its effect"
            )
        }
    }

    suite("performSecondaryAction(): invokes onSecondaryAction, then refreshes against its effect") {
        withTempDirectory { root in
            let environment = makeReadyEnvironment(in: root)
            writeExecutableFile(at: environment.claudioBinaryPath)
            let path = environment.claudioBinaryPath.path
            let entries = Event.allCases.map { event in
                #"""
                "\#(event.settingsName)": [ { "hooks": [ { "type": "command", "command": "\#(claudioHookCommand(for: event, claudioBinaryPath: path))" } ] } ]
                """#
            }.joined(separator: ",\n")
            writeFixture("{ \"hooks\": { \(entries) } }", to: environment.settingsFile)

            let viewModel = OnboardingViewModel(environment: environment)
            expect(viewModel.state == .installed, "setup: must start as installed")

            var invoked = false
            viewModel.onSecondaryAction = {
                invoked = true
                // Simulate "断开连接": wipe settings.json back to empty hooks.
                try? FileManager.default.removeItem(at: environment.settingsFile)
            }

            viewModel.performSecondaryAction()
            expect(invoked, "performSecondaryAction() must invoke the injected onSecondaryAction closure")
            expect(
                viewModel.state == .notInstalled,
                "performSecondaryAction() must refresh() after running the action, picking up its effect"
            )
        }
    }

    suite("performPrimaryAction()/performSecondaryAction(): a nil hook is a safe no-op, still refreshes") {
        withTempDirectory { root in
            let environment = makeReadyEnvironment(in: root)
            let viewModel = OnboardingViewModel(environment: environment)
            expect(viewModel.state == .helperMissing, "setup: must start as helperMissing")

            // No onPrimaryAction/onSecondaryAction wired — must not crash, and refresh()
            // still runs (a no-op here since nothing on disk changed).
            viewModel.performPrimaryAction()
            expect(
                viewModel.state == .helperMissing,
                "with no action wired, state must be unchanged (nothing on disk changed) and not crash")

            viewModel.performSecondaryAction()
            expect(
                viewModel.state == .helperMissing,
                "performSecondaryAction() with no action wired must likewise be a safe no-op")
        }
    }
}
