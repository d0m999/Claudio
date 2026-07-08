import ClaudioCore
import Foundation

// MARK: - install/uninstall: settings.json 接管 (ENGINEERING.md "settings.json 接管：追加而非
// 覆盖" + 工程落地细节 ①②③⑤, T2)
//
// Fixture-driven per T2 spec ("先写 fixture 测试"). Every fixture below is a realistic
// settings.json shape: another tool's hook group coexisting in the same event array
// (vibe-island-style, hangs off every event) and a PreToolUse/Bash hook (block-no-verify
// style) that claudio must never touch (T3 spike: both are real, not hypothetical).

private let testClaudioBinaryPath = "/Users/tester/.claudio/bin/claudio"

private func readRawString(at url: URL) -> String? {
    try? String(contentsOf: url, encoding: .utf8)
}

private func readJSONObject(at url: URL) -> [String: Any]? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
}

private func hooksArray(_ root: [String: Any]?, event: String) -> [[String: Any]]? {
    guard let hooks = root?["hooks"] as? [String: Any] else { return nil }
    return hooks[event] as? [[String: Any]]
}

private func commands(inGroup group: [String: Any]) -> [String] {
    guard let inner = group["hooks"] as? [[String: Any]] else { return [] }
    return inner.compactMap { $0["command"] as? String }
}

@MainActor
func runSettingsInstallerSuites() {
    suite("installClaudioHooks: fresh settings.json (none exists) installs all four events, no backup") {
        withTempDirectory { root in
            let settingsFile = root.appendingPathComponent("settings.json")
            let lockFile = root.appendingPathComponent("play.lock")

            let result = installClaudioHooks(
                settingsFile: settingsFile, claudioBinaryPath: testClaudioBinaryPath,
                lockFile: lockFile)
            expect(result == .success(.installed), "fresh install should report .installed, got \(result)")

            let json = readJSONObject(at: settingsFile)
            for event in Event.allCases {
                let groups = hooksArray(json, event: event.settingsName) ?? []
                expect(groups.count == 1, "\(event.settingsName): expected exactly 1 hook group, got \(groups.count)")
                expect(
                    commands(inGroup: groups.first ?? [:])
                        == [claudioHookCommand(for: event, claudioBinaryPath: testClaudioBinaryPath)],
                    "\(event.settingsName): command mismatch")
            }

            let backupFile = root.appendingPathComponent("settings.json.claudio.bak")
            expect(
                !FileManager.default.fileExists(atPath: backupFile.path),
                "no backup should be created when settings.json didn't exist before install")
        }
    }

    suite("installClaudioHooks: idempotent — second call makes no changes, no duplicate entries") {
        withTempDirectory { root in
            let settingsFile = root.appendingPathComponent("settings.json")
            let lockFile = root.appendingPathComponent("play.lock")

            let first = installClaudioHooks(
                settingsFile: settingsFile, claudioBinaryPath: testClaudioBinaryPath,
                lockFile: lockFile)
            expect(first == .success(.installed), "first install should be .installed")

            let second = installClaudioHooks(
                settingsFile: settingsFile, claudioBinaryPath: testClaudioBinaryPath,
                lockFile: lockFile)
            expect(
                second == .success(.alreadyInstalled),
                "second install should be .alreadyInstalled, got \(second)")

            let json = readJSONObject(at: settingsFile)
            for event in Event.allCases {
                let groups = hooksArray(json, event: event.settingsName) ?? []
                expect(
                    groups.count == 1,
                    "\(event.settingsName): idempotent install must not duplicate, got \(groups.count) groups")
            }
        }
    }

    suite("installClaudioHooks: appends alongside an existing other-tool hook without overwriting it") {
        withTempDirectory { root in
            let settingsFile = root.appendingPathComponent("settings.json")
            let lockFile = root.appendingPathComponent("play.lock")
            writeFixture(
                #"""
                {
                  "permissions": { "allow": ["Bash(git *)"] },
                  "hooks": {
                    "Stop": [ { "hooks": [ { "type": "command", "command": "vibe-island stop" } ] } ],
                    "PreToolUse": [
                      { "matcher": "Bash", "hooks": [ { "type": "command", "command": "block-no-verify" } ] }
                    ]
                  }
                }
                """#, to: settingsFile)

            let result = installClaudioHooks(
                settingsFile: settingsFile, claudioBinaryPath: testClaudioBinaryPath,
                lockFile: lockFile)
            expect(result == .success(.installed), "install alongside other hooks should be .installed")

            let json = readJSONObject(at: settingsFile)

            let stopGroups = hooksArray(json, event: "Stop") ?? []
            expect(stopGroups.count == 2, "Stop should now have 2 groups (vibe-island + claudio), got \(stopGroups.count)")
            expect(
                stopGroups.contains { commands(inGroup: $0) == ["vibe-island stop"] },
                "vibe-island's Stop group must survive untouched")
            expect(
                stopGroups.contains {
                    commands(inGroup: $0)
                        == [claudioHookCommand(for: .stop, claudioBinaryPath: testClaudioBinaryPath)]
                },
                "claudio's own Stop group must be appended")

            let preToolUse = hooksArray(json, event: "PreToolUse") ?? []
            expect(preToolUse.count == 1, "PreToolUse (not one of claudio's 4 events) must be untouched")
            expect(
                (preToolUse.first?["matcher"] as? String) == "Bash",
                "PreToolUse matcher must survive untouched")
            expect(
                commands(inGroup: preToolUse.first ?? [:]) == ["block-no-verify"],
                "block-no-verify command must survive untouched")

            let permissions = json?["permissions"] as? [String: Any]
            expect(permissions != nil, "unrelated top-level 'permissions' key must survive untouched")
        }
    }

    suite("installClaudioHooks: backs up the pre-claudio original exactly once, never overwrites it") {
        withTempDirectory { root in
            let settingsFile = root.appendingPathComponent("settings.json")
            let lockFile = root.appendingPathComponent("play.lock")
            let backupFile = root.appendingPathComponent("settings.json.claudio.bak")
            let originalContent = #"{ "hooks": { "Stop": [ { "hooks": [ { "type": "command", "command": "vibe-island stop" } ] } ] } }"#
            writeFixture(originalContent, to: settingsFile)

            let first = installClaudioHooks(
                settingsFile: settingsFile, claudioBinaryPath: testClaudioBinaryPath,
                lockFile: lockFile)
            expect(first == .success(.installed), "first install should be .installed")
            expect(
                readRawString(at: backupFile) == originalContent,
                "backup must hold the exact pre-claudio original bytes")

            // Simulate drift: settings.json changed on disk (one event's claudio hook
            // removed, unrelated content mutated) so the *next* install performs a real
            // second write — the backup must still reflect the very first original, not
            // this later state (ENGINEERING.md: "一次性备份").
            writeFixture(
                #"""
                { "MUTATED_MARKER": true, "hooks": {
                  "Stop": [ { "hooks": [ { "type": "command", "command": "vibe-island stop" } ] } ],
                  "StopFailure": [ { "hooks": [ { "type": "command", "command": "\#(claudioHookCommand(for: .stopFailure, claudioBinaryPath: testClaudioBinaryPath))" } ] } ]
                } }
                """#, to: settingsFile)

            let second = installClaudioHooks(
                settingsFile: settingsFile, claudioBinaryPath: testClaudioBinaryPath,
                lockFile: lockFile)
            expect(
                second == .success(.installed),
                "second install must perform a real write (missing events re-added), got \(second)")
            expect(
                readRawString(at: backupFile) == originalContent,
                "backup must remain the FIRST original even after a later real write ('一次性')")
        }
    }

    suite("installClaudioHooks: a failed backup copy aborts install, settings.json left untouched") {
        withTempDirectory { root in
            let settingsDir = root.appendingPathComponent("settings-dir", isDirectory: true)
            let settingsFile = settingsDir.appendingPathComponent("settings.json")
            let lockFile = root.appendingPathComponent("play.lock")
            let originalContent = #"{ "hooks": { "Stop": [ { "hooks": [ { "type": "command", "command": "vibe-island stop" } ] } ] } }"#
            writeFixture(originalContent, to: settingsFile)

            // Strip write permission from the *directory*: the existing settings.json
            // file itself stays individually writable (so the writability probe still
            // reports .writable), but creating a NEW sibling entry — the
            // settings.json.claudio.bak backup — needs write+execute on the directory
            // and must fail with EACCES.
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o500], ofItemAtPath: settingsDir.path)
            defer {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o700], ofItemAtPath: settingsDir.path)
            }

            let result = installClaudioHooks(
                settingsFile: settingsFile, claudioBinaryPath: testClaudioBinaryPath,
                lockFile: lockFile)
            if case .failure(.backupFailure) = result {
                // expected
            } else {
                expect(false, "expected .backupFailure when the backup copy can't be created, got \(result)")
            }
            expect(
                readRawString(at: settingsFile) == originalContent,
                "settings.json must be left untouched when the backup step fails — a failed"
                    + " backup must never be silently ignored and let install overwrite anyway")
            expect(
                !FileManager.default.fileExists(
                    atPath: settingsDir.appendingPathComponent("settings.json.claudio.bak").path),
                "no partial/corrupt backup should exist after a failed backup attempt")
        }
    }

    suite("uninstallClaudioHooks: no settings.json at all → .notInstalled, no file created") {
        withTempDirectory { root in
            let settingsFile = root.appendingPathComponent("settings.json")
            let lockFile = root.appendingPathComponent("play.lock")

            let result = uninstallClaudioHooks(
                settingsFile: settingsFile, claudioBinaryPath: testClaudioBinaryPath,
                lockFile: lockFile)
            expect(
                result == .success(.notInstalled),
                "uninstall with no settings.json should be .notInstalled, got \(result)")
            expect(
                !FileManager.default.fileExists(atPath: settingsFile.path),
                "uninstall must never create settings.json")
        }
    }

    suite("uninstallClaudioHooks: no claudio hooks present → .notInstalled, file left byte-identical") {
        withTempDirectory { root in
            let settingsFile = root.appendingPathComponent("settings.json")
            let lockFile = root.appendingPathComponent("play.lock")
            let originalContent = #"{ "hooks": { "Stop": [ { "hooks": [ { "type": "command", "command": "vibe-island stop" } ] } ] } }"#
            writeFixture(originalContent, to: settingsFile)

            let result = uninstallClaudioHooks(
                settingsFile: settingsFile, claudioBinaryPath: testClaudioBinaryPath,
                lockFile: lockFile)
            expect(
                result == .success(.notInstalled),
                "uninstall with no claudio hooks should be .notInstalled, got \(result)")
            expect(
                readRawString(at: settingsFile) == originalContent,
                "file must be left byte-identical when there is nothing to remove")
        }
    }

    suite("uninstallClaudioHooks: precisely removes claudio entries, preserves other-tool hooks") {
        withTempDirectory { root in
            let settingsFile = root.appendingPathComponent("settings.json")
            let lockFile = root.appendingPathComponent("play.lock")
            writeFixture(
                #"""
                { "hooks": {
                  "Stop": [
                    { "hooks": [ { "type": "command", "command": "vibe-island stop" } ] },
                    { "hooks": [ { "type": "command", "command": "\#(claudioHookCommand(for: .stop, claudioBinaryPath: testClaudioBinaryPath))" } ] }
                  ],
                  "Notification": [
                    { "hooks": [ { "type": "command", "command": "\#(claudioHookCommand(for: .notification, claudioBinaryPath: testClaudioBinaryPath))" } ] }
                  ],
                  "PreToolUse": [
                    { "matcher": "Bash", "hooks": [ { "type": "command", "command": "block-no-verify" } ] }
                  ]
                } }
                """#, to: settingsFile)

            let result = uninstallClaudioHooks(
                settingsFile: settingsFile, claudioBinaryPath: testClaudioBinaryPath,
                lockFile: lockFile)
            expect(result == .success(.uninstalled(count: 2)), "expected 2 removed (Stop + Notification), got \(result)")

            let json = readJSONObject(at: settingsFile)

            let stopGroups = hooksArray(json, event: "Stop") ?? []
            expect(stopGroups.count == 1, "Stop should keep only vibe-island's group, got \(stopGroups.count)")
            expect(
                commands(inGroup: stopGroups.first ?? [:]) == ["vibe-island stop"],
                "vibe-island's Stop group must survive untouched")

            let hooksSection = json?["hooks"] as? [String: Any]
            expect(
                hooksSection?["Notification"] == nil,
                "Notification key must be removed entirely once its only group is emptied")

            let preToolUse = hooksArray(json, event: "PreToolUse") ?? []
            expect(preToolUse.count == 1, "PreToolUse must be untouched")
            expect(
                (preToolUse.first?["matcher"] as? String) == "Bash",
                "PreToolUse matcher must survive untouched")
        }
    }

    suite("uninstallClaudioHooks: removes only claudio's entry from a group shared with another tool") {
        withTempDirectory { root in
            let settingsFile = root.appendingPathComponent("settings.json")
            let lockFile = root.appendingPathComponent("play.lock")
            writeFixture(
                #"""
                { "hooks": {
                  "Stop": [
                    { "hooks": [
                        { "type": "command", "command": "vibe-island stop" },
                        { "type": "command", "command": "\#(claudioHookCommand(for: .stop, claudioBinaryPath: testClaudioBinaryPath))" }
                    ] }
                  ]
                } }
                """#, to: settingsFile)

            let result = uninstallClaudioHooks(
                settingsFile: settingsFile, claudioBinaryPath: testClaudioBinaryPath,
                lockFile: lockFile)
            expect(result == .success(.uninstalled(count: 1)), "expected 1 removed, got \(result)")

            let json = readJSONObject(at: settingsFile)
            let stopGroups = hooksArray(json, event: "Stop") ?? []
            expect(stopGroups.count == 1, "the shared group itself must survive (not dropped), got \(stopGroups.count)")
            expect(
                commands(inGroup: stopGroups.first ?? [:]) == ["vibe-island stop"],
                "only claudio's entry must be removed from the shared inner hooks array")
        }
    }

    suite("installClaudioHooks: a leftover entry with our command but no \"type\" is not counted as installed — install self-heals with a real command hook") {
        withTempDirectory { root in
            let settingsFile = root.appendingPathComponent("settings.json")
            let lockFile = root.appendingPathComponent("play.lock")
            // A pre-existing Stop entry carries claudio's exact command string but is
            // missing its "type": "command" — Claude Code would never fire it. The
            // idempotency check (strict `groupContainsCommand`) must treat Stop as
            // not-yet-ours and append a proper, runnable entry (a real write → .installed),
            // rather than seeing the bare command string and skipping the fix.
            writeFixture(
                #"""
                { "hooks": {
                  "Stop": [ { "hooks": [ { "command": "\#(claudioHookCommand(for: .stop, claudioBinaryPath: testClaudioBinaryPath))" } ] } ]
                } }
                """#, to: settingsFile)

            let result = installClaudioHooks(
                settingsFile: settingsFile, claudioBinaryPath: testClaudioBinaryPath,
                lockFile: lockFile)
            expect(
                result == .success(.installed),
                "install must self-heal past a typeless leftover (a real write, not .alreadyInstalled), got \(result)")

            let json = readJSONObject(at: settingsFile)
            let stopGroups = hooksArray(json, event: "Stop") ?? []
            expect(
                stopGroups.count == 2,
                "Stop should keep the malformed leftover group and gain a freshly-appended proper one, got \(stopGroups.count)")
            let hasRunnableStop = stopGroups.contains { group in
                guard let inner = group["hooks"] as? [[String: Any]] else { return false }
                return inner.contains {
                    ($0["type"] as? String) == "command"
                        && ($0["command"] as? String)
                            == claudioHookCommand(for: .stop, claudioBinaryPath: testClaudioBinaryPath)
                }
            }
            expect(hasRunnableStop, "install must have appended a real { type: command } hook for Stop")

            expect(
                detectHookInstallStatus(
                    settingsFile: settingsFile, claudioBinaryPath: testClaudioBinaryPath) == .installed,
                "after self-heal, all four events must read back as .installed")
        }
    }

    suite("uninstallClaudioHooks: still removes a leftover entry carrying our command even without a \"type\" (loose, command-only match)") {
        withTempDirectory { root in
            let settingsFile = root.appendingPathComponent("settings.json")
            let lockFile = root.appendingPathComponent("play.lock")
            // The detect/install tightening must NOT make uninstall leave malformed cruft
            // behind: `removeHookEntries` matches on `command` alone, so a typeless leftover
            // carrying our command still gets cleaned up.
            writeFixture(
                #"""
                { "hooks": {
                  "Stop": [ { "hooks": [ { "command": "\#(claudioHookCommand(for: .stop, claudioBinaryPath: testClaudioBinaryPath))" } ] } ]
                } }
                """#, to: settingsFile)

            let result = uninstallClaudioHooks(
                settingsFile: settingsFile, claudioBinaryPath: testClaudioBinaryPath,
                lockFile: lockFile)
            expect(
                result == .success(.uninstalled(count: 1)),
                "uninstall must remove the typeless leftover carrying our command, got \(result)")

            let json = readJSONObject(at: settingsFile)
            let hooksSection = json?["hooks"] as? [String: Any]
            expect(
                hooksSection?["Stop"] == nil,
                "Stop key must be removed once its only (malformed) claudio entry is gone")
        }
    }

    suite("corrupt JSON syntax: install and uninstall both abort without writing or backing up") {
        withTempDirectory { root in
            let settingsFile = root.appendingPathComponent("settings.json")
            let lockFile = root.appendingPathComponent("play.lock")
            let corrupt = "{ not valid json"
            writeFixture(corrupt, to: settingsFile)

            let installResult = installClaudioHooks(
                settingsFile: settingsFile, claudioBinaryPath: testClaudioBinaryPath,
                lockFile: lockFile)
            if case .failure(.parseFailure) = installResult {
                // expected
            } else {
                expect(false, "expected .parseFailure from install, got \(installResult)")
            }
            expect(readRawString(at: settingsFile) == corrupt, "install must never touch a corrupt file")
            expect(
                !FileManager.default.fileExists(
                    atPath: root.appendingPathComponent("settings.json.claudio.bak").path),
                "no backup must be created when parse fails")

            let uninstallResult = uninstallClaudioHooks(
                settingsFile: settingsFile, claudioBinaryPath: testClaudioBinaryPath,
                lockFile: lockFile)
            if case .failure(.parseFailure) = uninstallResult {
                // expected
            } else {
                expect(false, "expected .parseFailure from uninstall, got \(uninstallResult)")
            }
            expect(readRawString(at: settingsFile) == corrupt, "uninstall must never touch a corrupt file")
        }
    }

    suite("malformed hooks shape: \"hooks\" is not an object → abort without writing") {
        withTempDirectory { root in
            let settingsFile = root.appendingPathComponent("settings.json")
            let lockFile = root.appendingPathComponent("play.lock")
            let malformed = #"{ "hooks": "oops" }"#
            writeFixture(malformed, to: settingsFile)

            let result = installClaudioHooks(
                settingsFile: settingsFile, claudioBinaryPath: testClaudioBinaryPath,
                lockFile: lockFile)
            if case .failure(.malformedHooksSection) = result {
                // expected
            } else {
                expect(false, "expected .malformedHooksSection, got \(result)")
            }
            expect(readRawString(at: settingsFile) == malformed, "malformed-shape file must be left untouched")
        }
    }

    suite("malformed hooks shape: an event's array is not an array → abort without writing") {
        withTempDirectory { root in
            let settingsFile = root.appendingPathComponent("settings.json")
            let lockFile = root.appendingPathComponent("play.lock")
            let malformed = #"{ "hooks": { "Stop": { "not": "an array" } } }"#
            writeFixture(malformed, to: settingsFile)

            let result = uninstallClaudioHooks(
                settingsFile: settingsFile, claudioBinaryPath: testClaudioBinaryPath,
                lockFile: lockFile)
            if case .failure(.malformedHooksSection) = result {
                // expected
            } else {
                expect(false, "expected .malformedHooksSection, got \(result)")
            }
            expect(readRawString(at: settingsFile) == malformed, "malformed-shape file must be left untouched")
        }
    }

    suite("installClaudioHooks: unwritable settings.json (read-only) aborts via the writability probe") {
        withTempDirectory { root in
            let settingsFile = root.appendingPathComponent("settings.json")
            let lockFile = root.appendingPathComponent("play.lock")
            let original = #"{ "hooks": {} }"#
            writeFixture(original, to: settingsFile)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o400], ofItemAtPath: settingsFile.path)
            defer {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o600], ofItemAtPath: settingsFile.path)
            }

            let result = installClaudioHooks(
                settingsFile: settingsFile, claudioBinaryPath: testClaudioBinaryPath,
                lockFile: lockFile)
            if case .failure(.notWritable) = result {
                // expected
            } else {
                expect(false, "expected .notWritable, got \(result)")
            }
            expect(readRawString(at: settingsFile) == original, "read-only file must be left untouched")
        }
    }

    suite("installClaudioHooks: missing parent directory aborts via the writability probe, no crash") {
        withTempDirectory { root in
            let settingsFile = root.appendingPathComponent("no-such-dir", isDirectory: true)
                .appendingPathComponent("settings.json")
            let lockFile = root.appendingPathComponent("play.lock")

            let result = installClaudioHooks(
                settingsFile: settingsFile, claudioBinaryPath: testClaudioBinaryPath,
                lockFile: lockFile)
            if case .failure(.notWritable) = result {
                // expected
            } else {
                expect(false, "expected .notWritable, got \(result)")
            }
            expect(
                !FileManager.default.fileExists(atPath: settingsFile.path),
                "install must not create anything when the parent directory is missing")
        }
    }

    suite("installClaudioHooks: a busy lock is reported as .lockBusy and never writes (non-blocking)") {
        withTempDirectory { root in
            let settingsFile = root.appendingPathComponent("settings.json")
            let lockFile = root.appendingPathComponent("play.lock")
            let holder = FileLock(path: lockFile.path)
            expect(holder.tryLock(), "holder should acquire the lock first")

            let result = installClaudioHooks(
                settingsFile: settingsFile, claudioBinaryPath: testClaudioBinaryPath,
                lockFile: lockFile)
            expect(result == .failure(.lockBusy), "expected .lockBusy while the lock is held, got \(result)")
            expect(
                !FileManager.default.fileExists(atPath: settingsFile.path),
                "install must not create settings.json when it can't acquire the lock")

            holder.unlock()
        }
    }

    suite("uninstallClaudioHooks: a busy lock is reported as .lockBusy and never writes (non-blocking)") {
        withTempDirectory { root in
            let settingsFile = root.appendingPathComponent("settings.json")
            let lockFile = root.appendingPathComponent("play.lock")
            let original = #"{ "hooks": { "Stop": [ { "hooks": [ { "type": "command", "command": "\#(claudioHookCommand(for: .stop, claudioBinaryPath: testClaudioBinaryPath))" } ] } ] } }"#
            writeFixture(original, to: settingsFile)
            let holder = FileLock(path: lockFile.path)
            expect(holder.tryLock(), "holder should acquire the lock first")

            let result = uninstallClaudioHooks(
                settingsFile: settingsFile, claudioBinaryPath: testClaudioBinaryPath,
                lockFile: lockFile)
            expect(result == .failure(.lockBusy), "expected .lockBusy while the lock is held, got \(result)")
            expect(readRawString(at: settingsFile) == original, "uninstall must not write while the lock is held")

            holder.unlock()
        }
    }

    suite(
        "installClaudioHooks: first-run production topology — settings.json's directory exists but"
            + " the lock file's directory (~/.claudio/ equivalent) never has, and install must still succeed"
    ) {
        withTempDirectory { root in
            // Real first-run shape (T4 review HIGH): `~/.claude/` (settings.json's parent)
            // already exists because Claude Code itself created it, but `~/.claudio/`
            // (the lock file's parent) has never been created by anything — this repo has
            // no code path that creates it up front. Modeled here as two *separate*
            // sibling roots so the settings.json parent pre-exists while the lock file's
            // parent starts out completely missing.
            let claudeDir = root.appendingPathComponent("dot-claude", isDirectory: true)
            try? FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
            let settingsFile = claudeDir.appendingPathComponent("settings.json")

            let claudioDir = root.appendingPathComponent("dot-claudio", isDirectory: true)
            expect(
                !FileManager.default.fileExists(atPath: claudioDir.path),
                "sanity: the lock file's parent directory must not exist before install runs"
                    + " — this is exactly the never-run-before-onboarding gap (T4 review HIGH)")
            let lockFile = claudioDir.appendingPathComponent("play.lock")

            let result = installClaudioHooks(
                settingsFile: settingsFile, claudioBinaryPath: testClaudioBinaryPath,
                lockFile: lockFile)
            expect(
                result == .success(.installed),
                "first-run install must succeed (not .lockFailed) even when the lock file's"
                    + " directory has never been created, got \(result)")
            expect(
                FileManager.default.fileExists(atPath: claudioDir.path),
                "installing must have self-healed the lock file's missing parent directory")
        }
    }

    suite(
        "uninstallClaudioHooks: first-run production topology — never-created lock directory"
            + " must not cause .lockFailed even when there's nothing to uninstall"
    ) {
        withTempDirectory { root in
            let claudeDir = root.appendingPathComponent("dot-claude", isDirectory: true)
            try? FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
            let settingsFile = claudeDir.appendingPathComponent("settings.json")

            let claudioDir = root.appendingPathComponent("dot-claudio", isDirectory: true)
            let lockFile = claudioDir.appendingPathComponent("play.lock")

            // Uninstall in a "never installed before" scenario is expected to report
            // .notInstalled — the point of this test is that it must reach that outcome
            // via the normal path, not fail earlier with .lockFailed just because
            // ~/.claudio/ was never created.
            let result = uninstallClaudioHooks(
                settingsFile: settingsFile, claudioBinaryPath: testClaudioBinaryPath,
                lockFile: lockFile)
            expect(
                result == .success(.notInstalled),
                "uninstall with a never-created lock directory must reach .notInstalled,"
                    + " not .lockFailed, got \(result)")
        }
    }

    suite("install then uninstall round-trips: pre-existing hooks and unrelated keys survive both operations") {
        withTempDirectory { root in
            let settingsFile = root.appendingPathComponent("settings.json")
            let lockFile = root.appendingPathComponent("play.lock")
            writeFixture(
                #"""
                { "env": { "FOO": "bar" }, "hooks": {
                  "Stop": [ { "hooks": [ { "type": "command", "command": "vibe-island stop" } ] } ],
                  "StopFailure": [ { "hooks": [ { "type": "command", "command": "vibe-island stop_failure" } ] } ],
                  "Notification": [ { "hooks": [ { "type": "command", "command": "vibe-island notification" } ] } ],
                  "SubagentStop": [ { "hooks": [ { "type": "command", "command": "vibe-island subagent_stop" } ] } ],
                  "PreToolUse": [ { "matcher": "Bash", "hooks": [ { "type": "command", "command": "block-no-verify" } ] } ]
                } }
                """#, to: settingsFile)

            let installResult = installClaudioHooks(
                settingsFile: settingsFile, claudioBinaryPath: testClaudioBinaryPath,
                lockFile: lockFile)
            expect(installResult == .success(.installed), "install should succeed, got \(installResult)")

            let afterInstall = readJSONObject(at: settingsFile)
            for event in Event.allCases {
                let groups = hooksArray(afterInstall, event: event.settingsName) ?? []
                expect(groups.count == 2, "\(event.settingsName): expected vibe-island + claudio, got \(groups.count)")
            }

            let uninstallResult = uninstallClaudioHooks(
                settingsFile: settingsFile, claudioBinaryPath: testClaudioBinaryPath,
                lockFile: lockFile)
            expect(
                uninstallResult == .success(.uninstalled(count: 4)),
                "uninstall should remove exactly the 4 claudio entries, got \(uninstallResult)")

            let afterUninstall = readJSONObject(at: settingsFile)
            for (event, expectedCommand) in [
                (Event.stop, "vibe-island stop"),
                (Event.stopFailure, "vibe-island stop_failure"),
                (Event.notification, "vibe-island notification"),
                (Event.subagentStop, "vibe-island subagent_stop"),
            ] {
                let groups = hooksArray(afterUninstall, event: event.settingsName) ?? []
                expect(
                    groups.count == 1 && commands(inGroup: groups.first ?? [:]) == [expectedCommand],
                    "\(event.settingsName): vibe-island's hook must survive the round trip untouched, got \(groups)")
            }

            let preToolUse = hooksArray(afterUninstall, event: "PreToolUse") ?? []
            expect(preToolUse.count == 1, "PreToolUse must survive the round trip untouched")
            expect(
                (preToolUse.first?["matcher"] as? String) == "Bash",
                "PreToolUse matcher must survive the round trip untouched")

            let env = afterUninstall?["env"] as? [String: String]
            expect(env == ["FOO": "bar"], "unrelated top-level 'env' key must survive the round trip untouched")
        }
    }
}
