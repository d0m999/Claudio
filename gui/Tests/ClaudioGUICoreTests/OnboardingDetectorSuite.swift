import ClaudioCore
import ClaudioGUICore
import Foundation

// MARK: - detectOnboardingState: the six-state machine's determination + precedence
// (ENGINEERING.md T7)
//
// Every fixture below builds a tiny on-disk tree under `withTempDirectory` — never the
// real `~/.claude`/`~/.claudio` (see `OnboardingEnvironment`'s doc comment on why a
// `$HOME` override wouldn't even work on Darwin). Precedence order under test:
// claudeCodeNotInstalled > helperMissing > settingsNotWritable > settingsParseFailure >
// {notInstalled, installed}.

/// A tree with `~/.claude/` present and the helper binary installed — the two
/// prerequisites every state past `.helperMissing` requires. Returns the environment plus
/// the concrete `settingsFile`/`claudioBinaryPath` URLs so callers can add a
/// `settings.json` (or leave it absent for `.notInstalled`).
@MainActor
private func makeReadyEnvironment(in root: URL) -> OnboardingEnvironment {
    let claudeDirectory = root.appendingPathComponent("dot-claude", isDirectory: true)
    try? FileManager.default.createDirectory(
        at: claudeDirectory, withIntermediateDirectories: true)
    let settingsFile = claudeDirectory.appendingPathComponent("settings.json")

    let binaryPath = root.appendingPathComponent("dot-claudio/bin/claudio")
    writeExecutableFile(at: binaryPath)

    return OnboardingEnvironment(settingsFile: settingsFile, claudioBinaryPath: binaryPath)
}

private func fullyInstalledSettingsJSON(claudioBinaryPath: String) -> String {
    let entries = Event.allCases.map { event in
        #"""
        "\#(event.settingsName)": [ { "hooks": [ { "type": "command", "command": "\#(claudioHookCommand(for: event, claudioBinaryPath: claudioBinaryPath))" } ] } ]
        """#
    }.joined(separator: ",\n")
    return "{ \"hooks\": { \(entries) } }"
}

@MainActor
func runOnboardingDetectorSuites() {
    suite("1. ~/.claude/ absent → .claudeCodeNotInstalled, regardless of anything else") {
        withTempDirectory { root in
            let claudeDirectory = root.appendingPathComponent("never-created-dot-claude")
            let environment = OnboardingEnvironment(
                settingsFile: claudeDirectory.appendingPathComponent("settings.json"),
                claudioBinaryPath: root.appendingPathComponent("dot-claudio/bin/claudio"))

            expect(
                detectOnboardingState(environment: environment) == .claudeCodeNotInstalled,
                "a completely missing ~/.claude/ must read as claudeCodeNotInstalled")
        }
    }

    suite("~/.claude/ exists but is a regular file, not a directory → .claudeCodeNotInstalled") {
        withTempDirectory { root in
            let claudeDirectory = root.appendingPathComponent("dot-claude-as-a-file")
            writeFixture("i am a file, not a directory", to: claudeDirectory)
            let environment = OnboardingEnvironment(
                settingsFile: claudeDirectory.appendingPathComponent("settings.json"),
                claudioBinaryPath: root.appendingPathComponent("dot-claudio/bin/claudio"))

            expect(
                detectOnboardingState(environment: environment) == .claudeCodeNotInstalled,
                "a ~/.claude *file* (not a directory) must not be mistaken for an installed Claude Code"
            )
        }
    }

    suite("2. ~/.claude/ present, helper binary missing → .helperMissing") {
        withTempDirectory { root in
            let claudeDirectory = root.appendingPathComponent("dot-claude", isDirectory: true)
            try? FileManager.default.createDirectory(
                at: claudeDirectory, withIntermediateDirectories: true)
            let environment = OnboardingEnvironment(
                settingsFile: claudeDirectory.appendingPathComponent("settings.json"),
                claudioBinaryPath: root.appendingPathComponent("dot-claudio/bin/claudio"))

            expect(
                detectOnboardingState(environment: environment) == .helperMissing,
                "Claude Code present but no installed helper binary must read as helperMissing")
        }
    }

    suite("2a. helper path exists but is a directory → .helperMissing (not a runnable binary)") {
        withTempDirectory { root in
            let claudeDirectory = root.appendingPathComponent("dot-claude", isDirectory: true)
            try? FileManager.default.createDirectory(
                at: claudeDirectory, withIntermediateDirectories: true)
            // A directory sitting where the binary should be: `fileExists` is true and a
            // 0o755 directory is even "executable" (searchable), so only the explicit
            // not-a-directory guard keeps this from being mistaken for an installed helper.
            let binaryPath = root.appendingPathComponent("dot-claudio/bin/claudio", isDirectory: true)
            try? FileManager.default.createDirectory(
                at: binaryPath, withIntermediateDirectories: true)
            let environment = OnboardingEnvironment(
                settingsFile: claudeDirectory.appendingPathComponent("settings.json"),
                claudioBinaryPath: binaryPath)

            expect(
                detectOnboardingState(environment: environment) == .helperMissing,
                "a directory at the helper binary's path must read as helperMissing, not installed")
        }
    }

    suite("2b. helper path exists but is a non-executable file → .helperMissing (broken install)") {
        withTempDirectory { root in
            let claudeDirectory = root.appendingPathComponent("dot-claude", isDirectory: true)
            try? FileManager.default.createDirectory(
                at: claudeDirectory, withIntermediateDirectories: true)
            // A present-but-non-executable file models a half-finished / corrupted install
            // (e.g. a truncated download, or the execute bit lost). Claude Code could not
            // run it, so onboarding must not claim the helper is installed.
            let binaryPath = root.appendingPathComponent("dot-claudio/bin/claudio")
            writeEmptyFile(at: binaryPath)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o644], ofItemAtPath: binaryPath.path)
            let environment = OnboardingEnvironment(
                settingsFile: claudeDirectory.appendingPathComponent("settings.json"),
                claudioBinaryPath: binaryPath)

            expect(
                detectOnboardingState(environment: environment) == .helperMissing,
                "a non-executable file at the helper binary's path must read as helperMissing")
        }
    }

    suite("2c. helper path exists, executable, but is a 0-byte stub → .helperMissing (truncated install)") {
        withTempDirectory { root in
            let claudeDirectory = root.appendingPathComponent("dot-claude", isDirectory: true)
            try? FileManager.default.createDirectory(
                at: claudeDirectory, withIntermediateDirectories: true)
            // A 0-byte file that already carries the execute bit models a truncated / half-copied
            // install (execute bit set, real bytes never written). It passes `fileExists` *and*
            // `isExecutableFile`, so only the non-zero-size guard keeps it from being mistaken for
            // an installed helper — Claude Code could never actually run an empty file.
            let binaryPath = root.appendingPathComponent("dot-claudio/bin/claudio")
            writeEmptyExecutableFile(at: binaryPath)
            let environment = OnboardingEnvironment(
                settingsFile: claudeDirectory.appendingPathComponent("settings.json"),
                claudioBinaryPath: binaryPath)

            expect(
                detectOnboardingState(environment: environment) == .helperMissing,
                "a 0-byte executable at the helper binary's path must read as helperMissing, not installed")
        }
    }

    suite("4. both prerequisites present, no settings.json at all → .notInstalled") {
        withTempDirectory { root in
            let environment = makeReadyEnvironment(in: root)
            expect(
                detectOnboardingState(environment: environment) == .notInstalled,
                "a never-created settings.json (fresh install) must read as notInstalled")
        }
    }

    suite("3a. settings.json exists but is unwritable → .settingsNotWritable, carries a non-empty reason") {
        withTempDirectory { root in
            let environment = makeReadyEnvironment(in: root)
            writeFixture(#"{ "hooks": {} }"#, to: environment.settingsFile)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o400], ofItemAtPath: environment.settingsFile.path)
            defer {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o600], ofItemAtPath: environment.settingsFile.path)
            }

            let state = detectOnboardingState(environment: environment)
            guard case .settingsNotWritable(let reason) = state else {
                expect(false, "expected .settingsNotWritable, got \(state)")
                return
            }
            expect(!reason.isEmpty, "settingsNotWritable reason must not be empty")
        }
    }

    suite("3b. settings.json is corrupt JSON → .settingsParseFailure, carries a non-empty reason") {
        withTempDirectory { root in
            let environment = makeReadyEnvironment(in: root)
            writeFixture("{ not valid json", to: environment.settingsFile)

            let state = detectOnboardingState(environment: environment)
            guard case .settingsParseFailure(let reason) = state else {
                expect(false, "expected .settingsParseFailure, got \(state)")
                return
            }
            expect(!reason.isEmpty, "settingsParseFailure reason must not be empty")
        }
    }

    suite("3c. settings.json has a malformed hooks shape → .settingsParseFailure") {
        withTempDirectory { root in
            let environment = makeReadyEnvironment(in: root)
            writeFixture(#"{ "hooks": "oops" }"#, to: environment.settingsFile)

            let state = detectOnboardingState(environment: environment)
            if case .settingsParseFailure = state {
                // expected
            } else {
                expect(false, "expected .settingsParseFailure for a malformed hooks shape, got \(state)")
            }
        }
    }

    suite("5a. all four core events' claudio hooks present → .installed") {
        withTempDirectory { root in
            let environment = makeReadyEnvironment(in: root)
            writeFixture(
                fullyInstalledSettingsJSON(claudioBinaryPath: environment.claudioBinaryPath.path),
                to: environment.settingsFile)

            expect(
                detectOnboardingState(environment: environment) == .installed,
                "full 4-event claudio coverage must read as installed")
        }
    }

    suite("5b. only 3 of 4 core events' claudio hooks present → .notInstalled (partial ≠ done)") {
        withTempDirectory { root in
            let environment = makeReadyEnvironment(in: root)
            let path = environment.claudioBinaryPath.path
            writeFixture(
                #"""
                { "hooks": {
                  "Stop": [ { "hooks": [ { "type": "command", "command": "\#(claudioHookCommand(for: .stop, claudioBinaryPath: path))" } ] } ],
                  "StopFailure": [ { "hooks": [ { "type": "command", "command": "\#(claudioHookCommand(for: .stopFailure, claudioBinaryPath: path))" } ] } ],
                  "Notification": [ { "hooks": [ { "type": "command", "command": "\#(claudioHookCommand(for: .notification, claudioBinaryPath: path))" } ] } ]
                } }
                """#, to: environment.settingsFile)

            expect(
                detectOnboardingState(environment: environment) == .notInstalled,
                "3-of-4 event coverage must still read as notInstalled")
        }
    }

    suite("precedence: ~/.claude/ absent wins even when the helper binary is also missing") {
        withTempDirectory { root in
            let environment = OnboardingEnvironment(
                settingsFile: root.appendingPathComponent("never-created-dot-claude/settings.json"),
                claudioBinaryPath: root.appendingPathComponent("never-created-binary/claudio"))

            expect(
                detectOnboardingState(environment: environment) == .claudeCodeNotInstalled,
                "claudeCodeNotInstalled must take precedence over helperMissing")
        }
    }

    suite("precedence: helper missing wins even when settings.json would also be unwritable") {
        withTempDirectory { root in
            let claudeDirectory = root.appendingPathComponent("dot-claude", isDirectory: true)
            try? FileManager.default.createDirectory(
                at: claudeDirectory, withIntermediateDirectories: true)
            let settingsFile = claudeDirectory.appendingPathComponent("settings.json")
            writeFixture(#"{ "hooks": {} }"#, to: settingsFile)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o400], ofItemAtPath: settingsFile.path)
            defer {
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: settingsFile.path)
            }
            // Helper binary deliberately never created.
            let environment = OnboardingEnvironment(
                settingsFile: settingsFile,
                claudioBinaryPath: root.appendingPathComponent("dot-claudio/bin/claudio"))

            expect(
                detectOnboardingState(environment: environment) == .helperMissing,
                "helperMissing must take precedence over settingsNotWritable")
        }
    }

    suite("precedence: settingsNotWritable wins even when the JSON is also corrupt") {
        withTempDirectory { root in
            let environment = makeReadyEnvironment(in: root)
            writeFixture("{ not valid json", to: environment.settingsFile)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o400], ofItemAtPath: environment.settingsFile.path)
            defer {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o600], ofItemAtPath: environment.settingsFile.path)
            }

            let state = detectOnboardingState(environment: environment)
            if case .settingsNotWritable = state {
                // expected — writability is checked before parseability.
            } else {
                expect(false, "expected .settingsNotWritable to win over a parse failure, got \(state)")
            }
        }
    }

    suite("transition: environment changing between two calls changes the detected state (T7 acceptance 1)") {
        withTempDirectory { root in
            let claudeDirectory = root.appendingPathComponent("dot-claude", isDirectory: true)
            try? FileManager.default.createDirectory(
                at: claudeDirectory, withIntermediateDirectories: true)
            let binaryPath = root.appendingPathComponent("dot-claudio/bin/claudio")
            let environment = OnboardingEnvironment(
                settingsFile: claudeDirectory.appendingPathComponent("settings.json"),
                claudioBinaryPath: binaryPath)

            expect(
                detectOnboardingState(environment: environment) == .helperMissing,
                "before the binary exists, state must be helperMissing")

            writeExecutableFile(at: binaryPath)
            expect(
                detectOnboardingState(environment: environment) == .notInstalled,
                "once the binary appears (no settings.json yet), state must transition to notInstalled")

            writeFixture(
                fullyInstalledSettingsJSON(claudioBinaryPath: binaryPath.path),
                to: environment.settingsFile)
            expect(
                detectOnboardingState(environment: environment) == .installed,
                "once the hook is fully present, state must transition to installed")
        }
    }
}
