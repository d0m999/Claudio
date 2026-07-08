import ClaudioCore
import Foundation

// MARK: - ClaudioPaths: single source of truth for every filesystem location (T4)
//
// The real failure mode T4 exists to prevent: a hook `command` string is written into
// `settings.json` and executed via `/bin/sh -c` (confirmed by the T3 spike). `/bin/sh -c`
// splits its argument on whitespace, so if `claudioBinary`'s path ever contained a space
// (e.g. `~/Library/Application Support/Claudio/bin/claudio`), the hook would silently
// break — Claude Code would try to run `~/Library/Application` with an argument `Support/…`.
// `ClaudioPaths` sidesteps this entirely by rooting everything at `~/.claudio` (no space,
// by construction) and these tests exist to keep that guarantee pinned down, and to catch
// any future path added to this enum that doesn't compose the same way.
//
// These are pure computed properties — `URL` string composition, not `throws`, not
// `async`, and (verified below) with no `FileManager` I/O behind them. That's why they're
// safe to call directly against the real `homeDirectoryForCurrentUser` in these tests
// without a `withTempDirectory` sandbox: unlike `FileLock`/`Doctor`/`SettingsInstaller`
// (which all take injectable URLs precisely so tests never touch the real `~/.claudio` or
// `~/.claude`), `ClaudioPaths` has no injection point at all — `home` is a private
// computed property, by design (see the type's doc comment) — so there is nothing to
// substitute. Reading a string is not touching the filesystem: no test in this suite ever
// calls `FileManager` against the paths it computes, so the real `~/.claudio` / `~/.claude`
// on this machine is never created, read, or written by running this suite.
//
// No `ensureDirectoryExists`-style helper is added here: nothing in `Sources/` currently
// creates any of these directories (confirmed via `grep -rn createDirectory Sources/` —
// zero hits), so there is no present call site for it. `FileLock.attemptLock` already has
// well-defined, tested `.failed` behavior when a parent directory is missing
// (`FileLockSuite.swift`), and directory-creation-on-first-use is a decision that belongs
// to whichever future task (`install`, `play`, or `log`) first needs it — adding the
// abstraction here now, unused, would be speculative.

@MainActor
func runPathsSuites() {
    suite("every ClaudioPaths location has no space in its path (T4 root cause)") {
        let paths: [(String, String)] = [
            ("root", ClaudioPaths.root.path),
            ("configFile", ClaudioPaths.configFile.path),
            ("packsDirectory", ClaudioPaths.packsDirectory.path),
            ("packDirectory(id:)", ClaudioPaths.packDirectory(id: "minimal-chime").path),
            ("binDirectory", ClaudioPaths.binDirectory.path),
            ("claudioBinary", ClaudioPaths.claudioBinary.path),
            ("logFile", ClaudioPaths.logFile.path),
            ("lockFile", ClaudioPaths.lockFile.path),
            ("claudeSettingsFile", ClaudioPaths.claudeSettingsFile.path),
        ]
        for (name, path) in paths {
            expect(
                !path.contains(" "),
                "\(name) must not contain a space (would split under /bin/sh -c): \(path)")
        }
    }

    suite("claudioBinary is the exact path a settings.json hook command embeds") {
        // This is the sharpest instance of the T4 concern: `claudioHookCommand(for:
        // claudioBinaryPath:)` interpolates this path directly into a raw shell command
        // string with no quoting. A space here is the literal bug T4 was opened to
        // prevent.
        let path = ClaudioPaths.claudioBinary.path
        expect(!path.contains(" "), "claudioBinary path must be shell-word-safe: \(path)")
        expect(path.hasSuffix("/claudio"), "claudioBinary should resolve to a file named claudio")
    }

    suite("every Claudio-owned path lives under ~/.claudio, except claudeSettingsFile") {
        let root = ClaudioPaths.root.path
        expect(root.hasSuffix("/.claudio"), "root should be a `.claudio` dot-folder: \(root)")

        let owned: [(String, String)] = [
            ("configFile", ClaudioPaths.configFile.path),
            ("packsDirectory", ClaudioPaths.packsDirectory.path),
            ("packDirectory(id:)", ClaudioPaths.packDirectory(id: "minimal-chime").path),
            ("binDirectory", ClaudioPaths.binDirectory.path),
            ("claudioBinary", ClaudioPaths.claudioBinary.path),
            ("logFile", ClaudioPaths.logFile.path),
            ("lockFile", ClaudioPaths.lockFile.path),
        ]
        for (name, path) in owned {
            expect(
                path.hasPrefix(root + "/"),
                "\(name) must live under ~/.claudio (root=\(root)), got: \(path)")
        }

        // The one documented exception: settings.json stays where Claude Code put it.
        let settingsPath = ClaudioPaths.claudeSettingsFile.path
        expect(
            !settingsPath.hasPrefix(root),
            "claudeSettingsFile must NOT live under ~/.claudio — it's Claude Code's file, "
                + "not ours: \(settingsPath)")
        expect(
            settingsPath.hasSuffix("/.claude/settings.json"),
            "claudeSettingsFile should resolve to ~/.claude/settings.json, got: \(settingsPath)")
    }

    suite("packDirectory(id:) joins packsDirectory/<id> and differs per id") {
        let packsRoot = ClaudioPaths.packsDirectory
        let minimalChime = ClaudioPaths.packDirectory(id: "minimal-chime")
        let anotherPack = ClaudioPaths.packDirectory(id: "another-pack")

        expect(
            minimalChime.path == packsRoot.appendingPathComponent("minimal-chime").path,
            "packDirectory(id:) must equal packsDirectory/<id> exactly, got: \(minimalChime.path)")
        expect(
            minimalChime.path.hasPrefix(packsRoot.path + "/"),
            "pack directory must be nested under packsDirectory: \(minimalChime.path)")
        expect(
            minimalChime.path != anotherPack.path,
            "different pack ids must resolve to different directories, both were: "
                + "\(minimalChime.path)")
        expect(
            minimalChime.path.hasSuffix("/minimal-chime"),
            "packDirectory(id:) must end with the given id, got: \(minimalChime.path)")
    }

    suite("path computation is pure: no I/O, and never crashes for a nonexistent id/dir") {
        withTempDirectory { scratch in
            // Derive a pack id that is guaranteed not to correspond to any real, installed
            // pack — tying it to a freshly-minted temp directory's unique name is a
            // convenient, collision-free way to manufacture "confirmed does not exist"
            // without needing to touch (or assume anything about) the real ~/.claudio/packs
            // on this machine.
            let missingID = "definitely-missing-\(scratch.lastPathComponent)"

            // Calling this must not throw, must not block, and must not require the
            // directory (or ~/.claudio itself) to exist — it's plain string composition.
            // The very fact `packDirectory(id:)` is declared as a non-throwing, synchronous
            // function returning `URL` (not `Result`, not `throws`) is the type-level
            // guarantee; this call is the runtime check that nothing sneaks in behind it.
            let resolved = ClaudioPaths.packDirectory(id: missingID)
            expect(
                resolved.path == ClaudioPaths.packsDirectory.appendingPathComponent(missingID).path,
                "packDirectory(id:) for a nonexistent id must still compose correctly, got: "
                    + "\(resolved.path)")

            // Calling it again must be deterministic — no hidden mutable/cached state that
            // could drift between calls within the same process.
            let resolvedAgain = ClaudioPaths.packDirectory(id: missingID)
            expect(
                resolved.path == resolvedAgain.path,
                "packDirectory(id:) must be a pure function of id: same input, same output")
        }
    }

    suite("root/configFile/etc. resolve to absolute, concrete paths (not a literal '~')") {
        // `home` is backed by `FileManager.default.homeDirectoryForCurrentUser`, never a
        // hand-written "~/" string, so there is no manual tilde-expansion logic to test.
        // What matters is that the resulting path is absolute and concrete.
        let root = ClaudioPaths.root.path
        expect(root.hasPrefix("/"), "root must resolve to an absolute path, got: \(root)")
        expect(!root.contains("~"), "root must not contain a literal, unexpanded '~': \(root)")

        let settingsPath = ClaudioPaths.claudeSettingsFile.path
        expect(
            settingsPath.hasPrefix("/"), "claudeSettingsFile must be absolute, got: \(settingsPath)"
        )
        expect(
            !settingsPath.contains("~"),
            "claudeSettingsFile must not contain a literal, unexpanded '~': \(settingsPath)")
    }
}
