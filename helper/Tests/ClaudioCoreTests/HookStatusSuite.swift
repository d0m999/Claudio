import ClaudioCore
import Foundation

// MARK: - detectHookInstallStatus: read-only "already taken over?" probe (T7 handoff)
//
// GUI onboarding (T7) needs this to distinguish "已接管" from "未接管" without ever
// calling `installClaudioHooks` (a real write) just to answer that question. These tests
// pin the read-only classification against the exact same fixture shapes
// `SettingsInstallerSuite.swift` uses for `install`/`uninstall`, so the two can never
// silently drift apart.

private let testClaudioBinaryPath = "/Users/tester/.claudio/bin/claudio"

@MainActor
func runHookStatusSuites() {
    suite("detectHookInstallStatus: no settings.json at all → .notInstalled, never creates one") {
        withTempDirectory { root in
            let settingsFile = root.appendingPathComponent("settings.json")

            let status = detectHookInstallStatus(
                settingsFile: settingsFile, claudioBinaryPath: testClaudioBinaryPath)
            expect(
                status == .notInstalled,
                "missing settings.json should read as .notInstalled, got \(status)")
            expect(
                !FileManager.default.fileExists(atPath: settingsFile.path),
                "a read-only probe must never create settings.json")
        }
    }

    suite("detectHookInstallStatus: freshly installed by installClaudioHooks reads back as .installed") {
        withTempDirectory { root in
            let settingsFile = root.appendingPathComponent("settings.json")
            let lockFile = root.appendingPathComponent("settings.lock")

            let installResult = installClaudioHooks(
                settingsFile: settingsFile, claudioBinaryPath: testClaudioBinaryPath,
                lockFile: lockFile)
            expect(installResult == .success(.installed), "setup: install must succeed")

            let status = detectHookInstallStatus(
                settingsFile: settingsFile, claudioBinaryPath: testClaudioBinaryPath)
            expect(
                status == .installed,
                "a real install's result must read back as .installed, got \(status)")
        }
    }

    suite("detectHookInstallStatus: three of four events installed → still .notInstalled (partial)") {
        withTempDirectory { root in
            let settingsFile = root.appendingPathComponent("settings.json")
            // Missing SubagentStop entirely — mirrors "user manually removed one event's
            // hook" or "install got interrupted partway", neither of which should read
            // as a fully-taken-over state.
            writeFixture(
                #"""
                { "hooks": {
                  "Stop": [ { "hooks": [ { "type": "command", "command": "\#(claudioHookCommand(for: .stop, claudioBinaryPath: testClaudioBinaryPath))" } ] } ],
                  "StopFailure": [ { "hooks": [ { "type": "command", "command": "\#(claudioHookCommand(for: .stopFailure, claudioBinaryPath: testClaudioBinaryPath))" } ] } ],
                  "Notification": [ { "hooks": [ { "type": "command", "command": "\#(claudioHookCommand(for: .notification, claudioBinaryPath: testClaudioBinaryPath))" } ] } ]
                } }
                """#, to: settingsFile)

            let status = detectHookInstallStatus(
                settingsFile: settingsFile, claudioBinaryPath: testClaudioBinaryPath)
            expect(
                status == .notInstalled,
                "3-of-4 core events present must still read as .notInstalled (partial ≠ done), got \(status)")
        }
    }

    suite("detectHookInstallStatus: claudio hooks coexisting with another tool's hooks still read as .installed") {
        withTempDirectory { root in
            let settingsFile = root.appendingPathComponent("settings.json")
            writeFixture(
                #"""
                { "hooks": {
                  "Stop": [
                    { "hooks": [ { "type": "command", "command": "vibe-island stop" } ] },
                    { "hooks": [ { "type": "command", "command": "\#(claudioHookCommand(for: .stop, claudioBinaryPath: testClaudioBinaryPath))" } ] }
                  ],
                  "StopFailure": [ { "hooks": [ { "type": "command", "command": "\#(claudioHookCommand(for: .stopFailure, claudioBinaryPath: testClaudioBinaryPath))" } ] } ],
                  "Notification": [ { "hooks": [ { "type": "command", "command": "\#(claudioHookCommand(for: .notification, claudioBinaryPath: testClaudioBinaryPath))" } ] } ],
                  "SubagentStop": [ { "hooks": [ { "type": "command", "command": "\#(claudioHookCommand(for: .subagentStop, claudioBinaryPath: testClaudioBinaryPath))" } ] } ]
                } }
                """#, to: settingsFile)

            let status = detectHookInstallStatus(
                settingsFile: settingsFile, claudioBinaryPath: testClaudioBinaryPath)
            expect(
                status == .installed,
                "full claudio coverage alongside another tool's hook must read as .installed, got \(status)")
        }
    }

    suite("detectHookInstallStatus: an entry with our command but a missing \"type\" → .notInstalled (not a runnable command hook)") {
        withTempDirectory { root in
            let settingsFile = root.appendingPathComponent("settings.json")
            // All four events carry our exact command string, but SubagentStop's entry is
            // missing its `"type": "command"` — Claude Code would NOT fire it as a command
            // hook, so a read-only "已接管?" probe must not count it as installed. If it
            // did, onboarding would show "已接好" for a config that never actually plays a
            // sound on subagent-stop.
            writeFixture(
                #"""
                { "hooks": {
                  "Stop": [ { "hooks": [ { "type": "command", "command": "\#(claudioHookCommand(for: .stop, claudioBinaryPath: testClaudioBinaryPath))" } ] } ],
                  "StopFailure": [ { "hooks": [ { "type": "command", "command": "\#(claudioHookCommand(for: .stopFailure, claudioBinaryPath: testClaudioBinaryPath))" } ] } ],
                  "Notification": [ { "hooks": [ { "type": "command", "command": "\#(claudioHookCommand(for: .notification, claudioBinaryPath: testClaudioBinaryPath))" } ] } ],
                  "SubagentStop": [ { "hooks": [ { "command": "\#(claudioHookCommand(for: .subagentStop, claudioBinaryPath: testClaudioBinaryPath))" } ] } ]
                } }
                """#, to: settingsFile)

            let status = detectHookInstallStatus(
                settingsFile: settingsFile, claudioBinaryPath: testClaudioBinaryPath)
            expect(
                status == .notInstalled,
                "an entry matching only on command (no \"type\": \"command\") must not read as .installed, got \(status)")
        }
    }

    suite("detectHookInstallStatus: an entry with our command but a non-command \"type\" → .notInstalled") {
        withTempDirectory { root in
            let settingsFile = root.appendingPathComponent("settings.json")
            // Same command string, but `"type"` is something other than "command" — again
            // not a runnable command hook, so it must not count as installed.
            writeFixture(
                #"""
                { "hooks": {
                  "Stop": [ { "hooks": [ { "type": "prompt", "command": "\#(claudioHookCommand(for: .stop, claudioBinaryPath: testClaudioBinaryPath))" } ] } ],
                  "StopFailure": [ { "hooks": [ { "type": "command", "command": "\#(claudioHookCommand(for: .stopFailure, claudioBinaryPath: testClaudioBinaryPath))" } ] } ],
                  "Notification": [ { "hooks": [ { "type": "command", "command": "\#(claudioHookCommand(for: .notification, claudioBinaryPath: testClaudioBinaryPath))" } ] } ],
                  "SubagentStop": [ { "hooks": [ { "type": "command", "command": "\#(claudioHookCommand(for: .subagentStop, claudioBinaryPath: testClaudioBinaryPath))" } ] } ]
                } }
                """#, to: settingsFile)

            let status = detectHookInstallStatus(
                settingsFile: settingsFile, claudioBinaryPath: testClaudioBinaryPath)
            expect(
                status == .notInstalled,
                "an entry with a non-\"command\" type must not read as .installed, got \(status)")
        }
    }

    suite("detectHookInstallStatus: corrupt JSON syntax → .settingsUnreadable(.parseFailure), never writes") {
        withTempDirectory { root in
            let settingsFile = root.appendingPathComponent("settings.json")
            let corrupt = "{ not valid json"
            writeFixture(corrupt, to: settingsFile)

            let status = detectHookInstallStatus(
                settingsFile: settingsFile, claudioBinaryPath: testClaudioBinaryPath)
            if case .settingsUnreadable(.parseFailure) = status {
                // expected
            } else {
                expect(false, "expected .settingsUnreadable(.parseFailure), got \(status)")
            }
            expect(
                (try? String(contentsOf: settingsFile, encoding: .utf8)) == corrupt,
                "a read-only probe must never touch a corrupt file")
        }
    }

    suite("detectHookInstallStatus: malformed hooks shape → .settingsUnreadable(.malformedHooksSection)") {
        withTempDirectory { root in
            let settingsFile = root.appendingPathComponent("settings.json")
            writeFixture(#"{ "hooks": "oops" }"#, to: settingsFile)

            let status = detectHookInstallStatus(
                settingsFile: settingsFile, claudioBinaryPath: testClaudioBinaryPath)
            if case .settingsUnreadable(.malformedHooksSection) = status {
                // expected
            } else {
                expect(false, "expected .settingsUnreadable(.malformedHooksSection), got \(status)")
            }
        }
    }

    suite("detectHookInstallStatus: uninstalling drops back to .notInstalled") {
        withTempDirectory { root in
            let settingsFile = root.appendingPathComponent("settings.json")
            let lockFile = root.appendingPathComponent("settings.lock")

            let installResult = installClaudioHooks(
                settingsFile: settingsFile, claudioBinaryPath: testClaudioBinaryPath,
                lockFile: lockFile)
            expect(installResult == .success(.installed), "setup: install must succeed")

            let afterInstall = detectHookInstallStatus(
                settingsFile: settingsFile, claudioBinaryPath: testClaudioBinaryPath)
            expect(afterInstall == .installed, "setup: must read .installed before uninstalling")

            let uninstallResult = uninstallClaudioHooks(
                settingsFile: settingsFile, claudioBinaryPath: testClaudioBinaryPath,
                lockFile: lockFile)
            expect(
                uninstallResult == .success(.uninstalled(count: 4)),
                "setup: uninstall must remove all 4, got \(uninstallResult)")

            let afterUninstall = detectHookInstallStatus(
                settingsFile: settingsFile, claudioBinaryPath: testClaudioBinaryPath)
            expect(
                afterUninstall == .notInstalled,
                "after a full uninstall, status must read back as .notInstalled, got \(afterUninstall)")
        }
    }

    suite("detectHookInstallStatus: a different claudio binary path's hooks do not count as installed") {
        withTempDirectory { root in
            let settingsFile = root.appendingPathComponent("settings.json")
            let lockFile = root.appendingPathComponent("settings.lock")
            let staleBinaryPath = "/Users/tester/.claudio-OLD/bin/claudio"

            let installResult = installClaudioHooks(
                settingsFile: settingsFile, claudioBinaryPath: staleBinaryPath, lockFile: lockFile)
            expect(installResult == .success(.installed), "setup: install (stale path) must succeed")

            // Querying with today's binary path must not match yesterday's — this is the
            // same exact-match-only contract `claudioHookCommand` enforces for
            // install/uninstall (ENGINEERING.md 工程落地细节 ③), now exercised read-only.
            let status = detectHookInstallStatus(
                settingsFile: settingsFile, claudioBinaryPath: testClaudioBinaryPath)
            expect(
                status == .notInstalled,
                "hooks installed under a different (stale) binary path must not read as .installed, got \(status)"
            )
        }
    }
}
