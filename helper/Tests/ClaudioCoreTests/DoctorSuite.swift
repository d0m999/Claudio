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
// (e) claudio 固定路径二进制在位 — same hard-failure severity as (c) afplay.
//
// Hard failures (→ non-zero exit) are ONLY: afplay missing, settings.json not writable,
// claudio 固定路径二进制缺失. Everything pack-related is a warning in v1 doctor.

/// A stand-in for the fixed-path claudio binary check (e) — there's no always-present
/// real system binary to point at (unlike `/usr/bin/afplay` for check (c)), so tests that
/// need check (e) to report healthy create one of these instead of relying on
/// `DoctorEnvironment`'s default (the real machine path, which doesn't exist on a test
/// runner that's never actually run `claudio setup`).
private func makeExecutableFixture(at url: URL) {
    try? FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? Data("#!fake-claudio-binary-fixture".utf8).write(to: url)
    try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
}

/// A canned ``CommandRunning`` double for doctor-level tests that don't care about version
/// detection specifics (e.g. "everything healthy") but must NOT let check (f)'s Claude Code
/// half depend on whatever `claude` install (if any) happens to be on the machine actually
/// running these tests — without this, that check would use the real
/// ``SystemCommandRunner`` default and make the test's pass/fail outcome silently
/// machine-dependent (T13).
private struct FakeCommandRunner: CommandRunning {
    let result: CommandRunResult
    func run(executablePath: String, arguments: [String], timeout: TimeInterval) -> CommandRunResult
    {
        result
    }
}

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

    suite("resolvePackDirectory rejects a pack id occupied by a plain file, not a directory") {
        withTempDirectory { root in
            let userPacks = root.appendingPathComponent("user-packs", isDirectory: true)
            // `minimal-chime` exists at the expected path, but as a regular file — not a
            // directory. `fileExists(atPath:)` alone would return true here and let this
            // resolve, only to fail later (with a confusing error) when something tries to
            // read `manifest.json` inside what it assumed was a directory (`/codex review`
            // 2026-07-08).
            writeFixture("i am a file, not a pack directory", to: userPacks.appendingPathComponent("minimal-chime"))

            let resolved = resolvePackDirectory(
                id: "minimal-chime", userPacksDirectory: userPacks, bundledPacksDirectory: nil)
            expect(
                resolved == nil,
                "a plain file occupying the pack-id path must not resolve as a pack directory")
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

    suite("isSafePackID rejects traversal / separators / empty, accepts plain ids") {
        expect(isSafePackID("minimal-chime"), "a plain pack id is safe")
        expect(isSafePackID("pack_v2.1"), "dots and underscores in one component are safe")
        expect(!isSafePackID(""), "empty id is unsafe")
        expect(!isSafePackID("."), "`.` is unsafe")
        expect(!isSafePackID(".."), "`..` is unsafe")
        expect(!isSafePackID("../evil"), "parent traversal is unsafe")
        expect(!isSafePackID("a/b"), "a path separator is unsafe")
        expect(!isSafePackID("/abs"), "an absolute path is unsafe")
    }

    suite("isSafePackID is not fooled by a combining mark fused onto the separator") {
        // "/" (U+002F) immediately followed by a combining accent (U+0301) fuses into ONE
        // grapheme cluster, so a grapheme-level `contains("/")` misses it — but the kernel
        // still honors the raw 0x2F and would escape the pack root one level up. The guard
        // must reject at the Unicode-scalar level (T1 review P2, adversarial verify).
        let sneaky = "..\u{2F}\u{301}x"  // "../" + combining mark + "x", raw 0x2F present
        expect(sneaky.contains("/") == false, "sanity: grapheme-level contains is fooled here")
        expect(
            !isSafePackID(sneaky),
            "a `/` hidden under a combining mark must still be rejected (scalar-level check)")
    }

    suite("resolvePackDirectory refuses a `../` pack id even when the target exists") {
        withTempDirectory { root in
            let userPacks = root.appendingPathComponent("packs", isDirectory: true)
            // A real directory OUTSIDE the pack root that `../evil` would reach if the
            // guard weren't there.
            let escaped = root.appendingPathComponent("evil", isDirectory: true)
            try? FileManager.default.createDirectory(
                at: escaped, withIntermediateDirectories: true)
            let resolved = resolvePackDirectory(
                id: "../evil", userPacksDirectory: userPacks, bundledPacksDirectory: nil)
            expect(
                resolved == nil,
                "a `../` pack id must resolve to nil, never escape the pack root")
        }
    }

    suite("resolvePackDirectory refuses a pack directory that is a symlink escaping the pack root")
    {
        withTempDirectory { root in
            let userPacks = root.appendingPathComponent("userPacks", isDirectory: true)
            // A real directory OUTSIDE the pack root, with its own manifest.json, that an
            // escaping symlink named `evil` would reach if the guard weren't there.
            let outside = root.appendingPathComponent("outside-secret", isDirectory: true)
            writeFixture(
                #"{ "id": "evil", "events": {} }"#,
                to: outside.appendingPathComponent("manifest.json"))
            createSymlink(
                at: userPacks.appendingPathComponent("evil", isDirectory: true), pointingTo: outside
            )

            let resolved = resolvePackDirectory(
                id: "evil", userPacksDirectory: userPacks, bundledPacksDirectory: nil)
            expect(
                resolved == nil,
                "a pack directory that is a symlink resolving outside the pack root must never resolve"
            )
        }
    }

    suite(
        "resolvePackDirectory refuses a CHAINED symlink pack directory (symlink -> symlink -> outside)"
    ) {
        withTempDirectory { root in
            let userPacks = root.appendingPathComponent("userPacks", isDirectory: true)
            // A real directory OUTSIDE the pack root, reachable only via TWO hops of
            // symlink indirection: `userPacks/evil` -> `link2` -> `outside-secret`. Each
            // hop is individually a valid, existing path, but the final target still
            // lies outside the pack root. `URL.resolvingSymlinksInPath()` is documented
            // as realpath(3)-based and should already walk the *entire* chain (not just
            // the first hop) — this proves that empirically rather than trusting the docs.
            let outside = root.appendingPathComponent("outside-secret", isDirectory: true)
            writeFixture(
                #"{ "id": "evil", "events": {} }"#,
                to: outside.appendingPathComponent("manifest.json"))
            let link2 = root.appendingPathComponent("link2", isDirectory: true)
            createSymlink(at: link2, pointingTo: outside)
            createSymlink(
                at: userPacks.appendingPathComponent("evil", isDirectory: true), pointingTo: link2)

            let resolved = resolvePackDirectory(
                id: "evil", userPacksDirectory: userPacks, bundledPacksDirectory: nil)
            expect(
                resolved == nil,
                "a pack directory reached via a chain of symlinks ending outside the pack root"
                    + " must never resolve"
            )
        }
    }

    suite(
        "resolvePackDirectory still finds a real bundled pack when the user pack is an escaping symlink"
    ) {
        withTempDirectory { root in
            let userPacks = root.appendingPathComponent("userPacks", isDirectory: true)
            let bundledPacks = root.appendingPathComponent("bundledPacks", isDirectory: true)
            let outside = root.appendingPathComponent("outside-secret", isDirectory: true)
            // The symlink target must actually exist on disk (same pattern as the
            // preceding test), just without a manifest.json inside it — otherwise a
            // dangling symlink would already fail `fileExists` on its own, and this test
            // wouldn't be exercising the escape guard at all.
            try? FileManager.default.createDirectory(
                at: outside, withIntermediateDirectories: true)
            createSymlink(
                at: userPacks.appendingPathComponent("minimal-chime", isDirectory: true),
                pointingTo: outside)
            let bundledPackDir = bundledPacks.appendingPathComponent(
                "minimal-chime", isDirectory: true)
            try? FileManager.default.createDirectory(
                at: bundledPackDir, withIntermediateDirectories: true)

            let resolved = resolvePackDirectory(
                id: "minimal-chime", userPacksDirectory: userPacks,
                bundledPacksDirectory: bundledPacks)
            expect(
                resolved?.path == bundledPackDir.path,
                "an escaping user-pack symlink must not block falling through to a real bundled pack"
            )
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

    // MARK: - checkPackIntegrity's config.json read must go through the same bounded,
    // regular-file-gated door as `play` and `probeConfigRewritable` (`readConfigFileBounded`,
    // SafeFileRead.swift) — `doctor` is precisely the tool a user reaches for to diagnose a
    // hostile/oversized config.json, so it must never itself hang or crash on one.

    suite("checkPackIntegrity: config.json is a DIRECTORY → .configUnreadable, not a crash") {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            try? FileManager.default.createDirectory(
                at: configFile, withIntermediateDirectories: true)
            let status = checkPackIntegrity(
                configFile: configFile, userPacksDirectory: root.appendingPathComponent("packs"),
                bundledPacksDirectory: nil)
            guard case .configUnreadable = status else {
                expect(false, "a directory-shaped config.json must report .configUnreadable, got \(status)")
                return
            }
        }
    }

    suite("checkPackIntegrity: config.json is a FIFO → .configUnreadable, doctor still returns (never hangs)") {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            makeFIFO(at: configFile)

            let started = Date()
            let status = checkPackIntegrity(
                configFile: configFile, userPacksDirectory: root.appendingPathComponent("packs"),
                bundledPacksDirectory: nil)
            let elapsed = Date().timeIntervalSince(started)

            guard case .configUnreadable = status else {
                expect(false, "a FIFO-shaped config.json must report .configUnreadable, got \(status)")
                return
            }
            expect(elapsed < 5, "doctor must never hang reading a FIFO-shaped config.json, took \(elapsed)s")
        }
    }

    suite(
        "checkPackIntegrity: a VALID (fully decodable) but oversize (> 64 KiB) config.json is"
            + " rejected by the size gate → .configUnreadable, even though the pack it names is"
            + " otherwise complete (proving the size bound is what's rejecting it, not a"
            + " coincidental decode failure — a raw, unbounded Data(contentsOf:) would read and"
            + " decode this exact file successfully and report .complete instead)"
    ) {
        withTempDirectory { root in
            let packsDir = root.appendingPathComponent("packs")
            let configFile = root.appendingPathComponent("config.json")
            let padding = String(repeating: "x", count: (1 << 16) + 100)
            writeFixture(
                #"{ "selected_pack": "minimal-chime", "padding": "\#(padding)" }"#, to: configFile)
            writeFixture(
                #"{ "id": "minimal-chime", "events": { "stop": "stop.mp3" } }"#,
                to: packsDir.appendingPathComponent("minimal-chime/manifest.json"))
            writeFixture(
                "fake-audio", to: packsDir.appendingPathComponent("minimal-chime/stop.mp3"))

            let status = checkPackIntegrity(
                configFile: configFile, userPacksDirectory: packsDir, bundledPacksDirectory: nil)
            guard case .configUnreadable(let reason) = status else {
                expect(
                    false,
                    "an oversize config.json must report .configUnreadable even though the pack"
                        + " it names is otherwise complete, got \(status)")
                return
            }
            expect(
                reason.contains("\(maxConfigFileBytes)"),
                "the reason should mention the byte bound so a user can act on it, got \(reason)")
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

    suite(
        "checkPackIntegrity: manifest.json itself being a symlink escaping the pack dir → .manifestUnreadable"
    ) {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let packsDir = root.appendingPathComponent("packs")
            writeFixture(#"{ "selected_pack": "minimal-chime" }"#, to: configFile)
            // A real manifest.json OUTSIDE the pack directory — this must never be read as
            // if it were `minimal-chime`'s own manifest.json just because a symlink of
            // that name sits inside a real pack directory.
            let outsideManifest = root.appendingPathComponent("secret-manifest.json")
            writeFixture(#"{ "id": "minimal-chime", "events": {} }"#, to: outsideManifest)
            createSymlink(
                at: packsDir.appendingPathComponent("minimal-chime/manifest.json"),
                pointingTo: outsideManifest)

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

    suite("checkPackIntegrity: a manifest event escaping the pack dir is missing, not complete") {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let packsDir = root.appendingPathComponent("packs")
            writeFixture(#"{ "selected_pack": "minimal-chime" }"#, to: configFile)
            // Manifest points `stop` at a file OUTSIDE the pack directory via `../`.
            writeFixture(
                #"{ "id": "minimal-chime", "events": { "stop": "../evil.mp3" } }"#,
                to: packsDir.appendingPathComponent("minimal-chime/manifest.json"))
            // That external file really exists (under packsDir, outside the pack dir):
            // a naive fileExists would find it and falsely report the pack .complete.
            writeFixture("fake-audio", to: packsDir.appendingPathComponent("evil.mp3"))

            let status = checkPackIntegrity(
                configFile: configFile, userPacksDirectory: packsDir, bundledPacksDirectory: nil)
            expect(
                status == .incomplete(packID: "minimal-chime", missingFiles: ["../evil.mp3"]),
                "an escaping event path must be reported missing, not complete — got \(status)")
        }
    }

    suite(
        "checkPackIntegrity: a declared event file that is a symlink escaping the pack dir is missing, not complete"
    ) {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let packsDir = root.appendingPathComponent("packs")
            writeFixture(#"{ "selected_pack": "minimal-chime" }"#, to: configFile)
            writeFixture(
                #"{ "id": "minimal-chime", "events": { "stop": "stop.mp3" } }"#,
                to: packsDir.appendingPathComponent("minimal-chime/manifest.json"))
            // A real file OUTSIDE the pack directory that the symlink below points at.
            let outsideFile = root.appendingPathComponent("secret.mp3")
            writeFixture("fake-audio", to: outsideFile)
            // `stop.mp3` inside the pack directory is a symlink resolving to that outside
            // file — the lexical path string still looks contained, but the bytes read
            // would come from outside the pack.
            createSymlink(
                at: packsDir.appendingPathComponent("minimal-chime/stop.mp3"),
                pointingTo: outsideFile)

            let status = checkPackIntegrity(
                configFile: configFile, userPacksDirectory: packsDir, bundledPacksDirectory: nil)
            expect(
                status == .incomplete(packID: "minimal-chime", missingFiles: ["stop.mp3"]),
                "an event file resolving outside the pack dir via symlink must be reported missing, got \(status)"
            )
        }
    }

    suite(
        "checkPackIntegrity: NFC/NFD Unicode-normalization mismatch between the manifest-declared"
            + " filename and the on-disk symlink name does not bypass the escape guard"
    ) {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let packsDir = root.appendingPathComponent("packs")
            writeFixture(#"{ "selected_pack": "minimal-chime" }"#, to: configFile)
            // The manifest declares the event file using the PRECOMPOSED (NFC) form of "é"
            // (U+00E9, a single scalar).
            let nfcName = "caf\u{00E9}.mp3"
            // The on-disk symlink is created using the CANONICALLY EQUIVALENT but
            // byte-different DECOMPOSED (NFD) form: "e" (U+0065) followed by COMBINING
            // ACUTE ACCENT (U+0301) — two scalars, not one.
            let nfdName = "cafe\u{0301}.mp3"
            expect(
                !nfcName.unicodeScalars.elementsEqual(nfdName.unicodeScalars),
                "sanity: NFC and NFD spellings of \"café.mp3\" are different scalar sequences")
            writeFixture(
                #"{ "id": "minimal-chime", "events": { "stop": "\#(nfcName)" } }"#,
                to: packsDir.appendingPathComponent("minimal-chime/manifest.json"))
            // A real file OUTSIDE the pack directory that the escaping symlink below points at.
            let outsideFile = root.appendingPathComponent("secret.mp3")
            writeFixture("fake-audio", to: outsideFile)
            // The on-disk symlink uses the NFD spelling, while the manifest declared the NFC
            // spelling — an attacker's attempt to have `isContained`'s lexical / grapheme-level
            // string comparison see two "different" paths while both sides actually name the
            // same underlying directory entry. macOS (Foundation + APFS) resolves lookups
            // normalization-insensitively, so this must NOT let the escaping symlink be missed
            // by `isReallyContained`.
            createSymlink(
                at: packsDir.appendingPathComponent("minimal-chime/\(nfdName)"),
                pointingTo: outsideFile)

            let status = checkPackIntegrity(
                configFile: configFile, userPacksDirectory: packsDir, bundledPacksDirectory: nil)
            expect(
                status == .incomplete(packID: "minimal-chime", missingFiles: [nfcName]),
                "an NFC-declared event file resolved by an NFD-named on-disk symlink escaping"
                    + " the pack dir must be reported missing, never complete — got \(status)")
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

    suite(
        "checkPackIntegrity: an empty events object remains .complete and doctor explains that no audio was declared"
    ) {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let packsDir = root.appendingPathComponent("packs")
            let settingsFile = root.appendingPathComponent("settings.json")
            let claudioBinaryPath = root.appendingPathComponent("claudio")
            writeFixture("{}", to: settingsFile)
            writeFixture(#"{ "selected_pack": "minimal-chime" }"#, to: configFile)
            writeFixture(
                #"{ "id": "minimal-chime", "events": {} }"#,
                to: packsDir.appendingPathComponent("minimal-chime/manifest.json"))
            makeExecutableFixture(at: claudioBinaryPath)

            let status = checkPackIntegrity(
                configFile: configFile, userPacksDirectory: packsDir, bundledPacksDirectory: nil)
            expect(
                status == .complete(packID: "minimal-chime", events: []),
                "an empty events object is a legal all-silent pack: doctor must keep .complete, got \(status)"
            )

            let report = runDoctorChecks(
                environment: DoctorEnvironment(
                    afplayPath: "/usr/bin/afplay",
                    settingsFile: settingsFile,
                    configFile: configFile,
                    userPacksDirectory: packsDir,
                    bundledPacksDirectory: nil,
                    logFile: root.appendingPathComponent("claudio.log"),
                    claudioBinaryPath: claudioBinaryPath.path,
                    commandRunner: FakeCommandRunner(
                        result: .completed(exitCode: 0, stdout: "2.1.206 (Claude Code)")),
                    currentMacOSVersion: { SemanticVersion(major: 15, minor: 0, patch: 0) }))
            let packResult = report.results.first { $0.name == "pack" }
            expect(packResult?.severity == .ok, "the empty pack remains an ok doctor result")
            expect(
                packResult?.message
                    == "✓ 声音包 `minimal-chime` 未声明事件；无需检查音频文件",
                "doctor must explain that its ok result means no audio was declared, not imply 0/4 coverage is complete"
            )
        }
    }

    suite(
        "checkPackIntegrity: a fully legitimate real (non-symlink) pack resolved via the"
            + " bundled fallback still reports .complete"
    ) {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let userPacksDir = root.appendingPathComponent("packs")
            let bundledPacksDir = root.appendingPathComponent("bundled-packs")
            writeFixture(#"{ "selected_pack": "minimal-chime" }"#, to: configFile)
            // No user pack exists at all — only a real, plain (non-symlink) bundled pack
            // directory with a real manifest.json and real audio files. The symlink-escape
            // guard (`isReallyContained`, layered onto `resolvePackDirectory` and
            // `safePackFileURL`) must only reject symlink escapes, never an entirely
            // ordinary real pack resolved through the real bundled fallback path.
            writeFixture(
                #"""
                { "id": "minimal-chime", "events": { "stop": "stop.mp3", "notification": "notification.mp3" } }
                """#,
                to: bundledPacksDir.appendingPathComponent("minimal-chime/manifest.json"))
            writeFixture(
                "fake-audio", to: bundledPacksDir.appendingPathComponent("minimal-chime/stop.mp3")
            )
            writeFixture(
                "fake-audio",
                to: bundledPacksDir.appendingPathComponent("minimal-chime/notification.mp3"))

            let status = checkPackIntegrity(
                configFile: configFile, userPacksDirectory: userPacksDir,
                bundledPacksDirectory: bundledPacksDir)
            expect(
                status
                    == .complete(packID: "minimal-chime", events: ["notification", "stop"]),
                "a legitimate real pack resolved through the real bundled fallback must still"
                    + " report .complete, got \(status)")
        }
    }

    suite(
        "resolvePackDirectory refuses a pack directory that is a DANGLING symlink (target never existed)"
    ) {
        withTempDirectory { root in
            let userPacks = root.appendingPathComponent("userPacks", isDirectory: true)
            // Unlike the earlier escaping-symlink tests, `neverExisted` is never created —
            // this is a dangling symlink, not merely an out-of-root one. Empirically,
            // `URL.resolvingSymlinksInPath()` does NOT resolve a dangling symlink to its
            // (nonexistent) target; it silently falls back to the lexical, unresolved
            // path of the symlink itself (still lexically under `userPacks`), so
            // `isReallyContained` alone would call this "contained". The guard still
            // holds end to end only because `resolvePackDirectory`'s final
            // `fileManager.fileExists(atPath:)` check follows the symlink for real and
            // correctly reports `false` for a target that isn't there — this test pins
            // that combination so a future refactor that drops the trailing `fileExists`
            // gate (e.g. trusting `isReallyContained` alone) would be caught.
            let neverExisted = root.appendingPathComponent("never-existed", isDirectory: true)
            createSymlink(
                at: userPacks.appendingPathComponent("evil", isDirectory: true),
                pointingTo: neverExisted)

            let resolved = resolvePackDirectory(
                id: "evil", userPacksDirectory: userPacks, bundledPacksDirectory: nil)
            expect(
                resolved == nil,
                "a pack directory that is a dangling symlink (target never existed) must never"
                    + " resolve, got \(String(describing: resolved))")
        }
    }

    // MARK: - loadPackManifest / loadPackManifestData (T16 shared manifest loader)
    //
    // `checkPackIntegrity`'s manifest-reading block above was extracted into these two
    // `public` functions verbatim (T16: "共享 PackManifest 模块与运行时查找顺序同源") so
    // `gui`'s `ClaudioGUICore` can reuse the exact same `isReallyContained`-gated read/decode
    // path instead of growing a second, unaudited one. The suites above already pin
    // `checkPackIntegrity`'s observable behavior end-to-end (corrupt manifest / symlink
    // escape / NFC-NFD); these pin the extracted functions directly.

    suite("loadPackManifest: decodes a well-formed manifest.json") {
        withTempDirectory { root in
            let packDirectory = root.appendingPathComponent("minimal-chime", isDirectory: true)
            writeFixture(
                #"{ "id": "minimal-chime", "events": { "stop": "stop.mp3" } }"#,
                to: packDirectory.appendingPathComponent("manifest.json"))

            let result = loadPackManifest(in: packDirectory)
            guard case .success(let manifest) = result else {
                expect(false, "expected .success, got \(result)")
                return
            }
            expect(manifest.id == "minimal-chime", "decoded manifest must carry the right id")
            expect(
                manifest.events == ["stop": "stop.mp3"],
                "decoded manifest must carry the declared events map")
        }
    }

    suite("loadPackManifest: missing manifest.json → .unreadable, not a crash") {
        withTempDirectory { root in
            let packDirectory = root.appendingPathComponent("ghost-pack", isDirectory: true)
            let result = loadPackManifest(in: packDirectory)
            if case .failure(.unreadable(let reason)) = result {
                expect(
                    reason.contains("manifest.json"),
                    "the .unreadable reason should name manifest.json, got \(reason)")
            } else {
                expect(false, "expected .failure(.unreadable), got \(result)")
            }
        }
    }

    suite("loadPackManifest: corrupt JSON → .decodeFailed") {
        withTempDirectory { root in
            let packDirectory = root.appendingPathComponent("minimal-chime", isDirectory: true)
            writeFixture("{ not valid json", to: packDirectory.appendingPathComponent("manifest.json"))

            let result = loadPackManifest(in: packDirectory)
            if case .failure(.decodeFailed(let reason)) = result {
                expect(!reason.isEmpty, "the .decodeFailed reason must carry a real message")
            } else {
                expect(false, "expected .failure(.decodeFailed), got \(result)")
            }
        }
    }

    suite("loadPackManifest: manifest.json as a symlink escaping the pack dir → .unreadable") {
        withTempDirectory { root in
            let packDirectory = root.appendingPathComponent("minimal-chime", isDirectory: true)
            let outsideManifest = root.appendingPathComponent("secret-manifest.json")
            writeFixture(#"{ "id": "minimal-chime", "events": {} }"#, to: outsideManifest)
            createSymlink(
                at: packDirectory.appendingPathComponent("manifest.json"), pointingTo: outsideManifest)

            let result = loadPackManifest(in: packDirectory)
            expect(
                { if case .failure(.unreadable) = result { return true } else { return false } }(),
                "a manifest.json symlink escaping the pack dir must be .unreadable, got \(result)")
        }
    }

    suite("loadPackManifestData: returns the exact raw bytes on disk, unparsed") {
        withTempDirectory { root in
            let packDirectory = root.appendingPathComponent("minimal-chime", isDirectory: true)
            // Deliberately includes an unknown top-level key `loadPackManifest`'s decode to
            // `PackManifest` would silently drop — `loadPackManifestData` must hand back the
            // raw bytes untouched, preserving it, since `gui`'s manifest-binding write path
            // (T16) needs exactly that to avoid data loss on unknown keys.
            let rawJSON = #"{ "id": "minimal-chime", "name": "极简铃音", "events": { "stop": "stop.mp3" } }"#
            writeFixture(rawJSON, to: packDirectory.appendingPathComponent("manifest.json"))

            let result = loadPackManifestData(in: packDirectory)
            guard case .success(let data) = result else {
                expect(false, "expected .success, got \(result)")
                return
            }
            expect(
                String(data: data, encoding: .utf8) == rawJSON,
                "loadPackManifestData must return the exact on-disk bytes, unknown keys included")
        }
    }

    suite("loadPackManifest: reason surfaces the same human message checkPackIntegrity always used") {
        withTempDirectory { root in
            let packDirectory = root.appendingPathComponent("ghost-pack", isDirectory: true)
            let result = loadPackManifest(in: packDirectory)
            guard case .failure(let error) = result else {
                expect(false, "expected .failure, got \(result)")
                return
            }
            expect(
                error.reason.contains("manifest.json") && error.reason.contains("不存在或不可读"),
                "the .unreadable reason must keep the exact human message, got \(error.reason)")
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

    suite("probeSettingsWritable: existing writable file still requires atomic-publish parent access") {
        withTempDirectory { root in
            let parent = root.appendingPathComponent("host-config", isDirectory: true)
            try! FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            let settingsFile = parent.appendingPathComponent("settings.json")
            writeFixture("{}", to: settingsFile)
            try! FileManager.default.setAttributes(
                [.posixPermissions: 0o500], ofItemAtPath: parent.path)
            defer {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o700], ofItemAtPath: parent.path)
            }

            guard case .notWritable(let reason) = probeSettingsWritable(settingsFile: settingsFile)
            else {
                expect(false, "现有 inode 可写但父目录不能 staging/rename 时不得报告 writable")
                return
            }
            expect(
                reason.contains("原子替换") && reason.contains(parent.path),
                "阻塞理由必须指向真正无法发布的父目录，got \(reason)")
        }
    }

    suite("probeSettingsWritable: preserved symlink requires its target parent to publish") {
        withTempDirectory { root in
            let dotfiles = root.appendingPathComponent("dotfiles", isDirectory: true)
            let hostDirectory = root.appendingPathComponent("host", isDirectory: true)
            try! FileManager.default.createDirectory(at: dotfiles, withIntermediateDirectories: true)
            try! FileManager.default.createDirectory(
                at: hostDirectory, withIntermediateDirectories: true)
            let target = dotfiles.appendingPathComponent("settings.json")
            let settingsFile = hostDirectory.appendingPathComponent("settings.json")
            writeFixture("{}", to: target)
            try! FileManager.default.createSymbolicLink(
                at: settingsFile, withDestinationURL: target)
            try! FileManager.default.setAttributes(
                [.posixPermissions: 0o500], ofItemAtPath: dotfiles.path)
            defer {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o700], ofItemAtPath: dotfiles.path)
            }

            guard case .notWritable(let reason) = probeSettingsWritable(settingsFile: settingsFile)
            else {
                expect(false, "preserveTarget 会在 target parent 发布，不得只检查 symlink parent")
                return
            }
            expect(
                reason.contains("原子替换") && reason.contains(dotfiles.path),
                "阻塞理由必须指向 symlink target parent，got \(reason)")
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

    suite("probeSettingsWritable: parent path exists but is a regular file → .notWritable") {
        withTempDirectory { root in
            // `notADir` is a writable file, not a directory. `install` still can't create
            // `settings.json` under it, so the probe must report .notWritable rather than
            // be fooled into .writable by the parent being writable (T1 review P2).
            let notADir = root.appendingPathComponent("notADir")
            writeFixture("i am a file", to: notADir)
            let settingsFile = notADir.appendingPathComponent("settings.json")
            if case .notWritable = probeSettingsWritable(settingsFile: settingsFile) {
                // expected
            } else {
                expect(false, "a non-directory parent must report .notWritable")
            }
        }
    }

    // MARK: - (g) config.json 可重写：fail-closed 写路径唯一的可见性出口
    //
    // 写路径（静音钮 / 切包）对畸形 config **fail closed**，而宽松读路径（`play` / `doctor` 的
    // `ClaudioConfig`）照常工作——于是一份 `{"events":{"stop":1}}` 的 config 会让 App 里所有写操作
    // **永久失败**，声音却一切正常；`setup` 因为 config 已存在也不会重建它。用户唯一能观察到的现象是
    // 「点静音没反应」。doctor 的职责就是诊断：这几条钉死它必须把那个隐形状态说出来、并给出可执行的
    // 修复指令，同时**不**把一台声音一切正常的机器报成硬失败。

    suite("runDoctorChecks: 畸形 config（旧读路径照常能读）→ config 检查报 warning，且指令可执行") {
        withTempDirectory { root in
            let settingsFile = root.appendingPathComponent("settings.json")
            let packsDir = root.appendingPathComponent("packs")
            let configFile = root.appendingPathComponent("config.json")
            writeFixture("{}", to: settingsFile)
            // 关键：这份 config 的 `selected_pack` 是好的，只有 `events.stop` 是数字 1。宽松读路径把
            // 它读成「events 解不出来 → 空表」，于是包检查照样 .complete、声音照响——用户完全看不出
            // 自己已经被锁死在一个写不进的 config 上。
            writeFixture(
                #"{ "selected_pack": "minimal-chime", "events": { "stop": 1 } }"#, to: configFile)
            writeFixture(
                #"{ "id": "minimal-chime", "events": { "stop": "stop.mp3" } }"#,
                to: packsDir.appendingPathComponent("minimal-chime/manifest.json"))
            writeFixture(
                "fake-audio", to: packsDir.appendingPathComponent("minimal-chime/stop.mp3"))
            let claudioBinaryPath = root.appendingPathComponent("claudio")
            makeExecutableFixture(at: claudioBinaryPath)

            let env = DoctorEnvironment(
                afplayPath: "/usr/bin/afplay",
                settingsFile: settingsFile,
                configFile: configFile,
                userPacksDirectory: packsDir,
                bundledPacksDirectory: nil,
                logFile: root.appendingPathComponent("claudio.log"),
                claudioBinaryPath: claudioBinaryPath.path,
                commandRunner: FakeCommandRunner(
                    result: .completed(exitCode: 0, stdout: "2.1.206 (Claude Code)")),
                currentMacOSVersion: { SemanticVersion(major: 15, minor: 0, patch: 0) })
            let report = runDoctorChecks(environment: env)

            guard let configResult = report.results.first(where: { $0.name == "config" }) else {
                expect(false, "doctor 必须有一条 config 检查，got \(report.results.map(\.name))")
                return
            }
            expect(
                configResult.severity == .warning,
                "畸形 config 必须被 doctor 看见（这是用户唯一的诊断途径），got \(configResult.severity)")
            expect(
                configResult.message.contains("events.stop")
                    && configResult.message.contains("true/false")
                    && configResult.message.contains("删除该文件"),
                "doctor 报出来的必须是可执行的修复指令，而不是一句「config 有问题」，got"
                    + " \(configResult.message)")
            expect(
                !report.hasFailure,
                "声音一切正常的机器不该被报成硬失败——坏的只是写路径，doctor 不该非零退出")
            // 「播放不受影响」不是一句安慰，它是这条 warning 存在的全部理由：证明给自己看。
            expect(
                report.results.contains { $0.name == "pack" && $0.severity == .ok },
                "宽松读路径照常工作：包检查仍然是绿的——正因如此，畸形 config 才是**隐形**的，"
                    + "也正因如此 doctor 必须主动报它")
        }
    }

    suite("runDoctorChecks: 全新安装（还没有 config.json）→ config 检查是 .ok，绝不假报警") {
        withTempDirectory { root in
            let env = healthyDoctorEnvironment(
                root: root,
                commandRunner: FakeCommandRunner(
                    result: .completed(exitCode: 0, stdout: "2.1.206 (Claude Code)")),
                currentMacOSVersion: { SemanticVersion(major: 15, minor: 0, patch: 0) })
            // `healthyDoctorEnvironment` 会写一份合法 config——删掉它，模拟「一次都还没写过」。
            try? FileManager.default.removeItem(at: env.configFile)

            let report = runDoctorChecks(environment: env)
            let configResult = report.results.first { $0.name == "config" }
            expect(
                configResult?.severity == .ok,
                "还没有 config.json 只是「还没写过」（写路径会新建它），不是畸形，got"
                    + " \(String(describing: configResult))")
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
                bundledPacksDirectory: nil,
                logFile: root.appendingPathComponent("claudio.log"))
            let report = runDoctorChecks(environment: env)
            expect(report.hasFailure, "missing afplay must set hasFailure (exit non-zero)")
        }
    }

    suite(
        "runDoctorChecks: missing claudio binary at the fixed hooks path is a hard failure (non-zero exit)"
    ) {
        withTempDirectory { root in
            // Regression test (Claude adversarial review, /ship pre-landing, T17): the
            // fixed-path binary settings.json's hooks actually invoke was never checked by
            // doctor at all — a state where `claudio setup` skipped the binary copy (the
            // bug fixed in the same commit as this test) would report a healthy doctor
            // while every hook silently failed. Same severity class as afplay missing.
            let settingsFile = root.appendingPathComponent("settings.json")
            writeFixture("{}", to: settingsFile)
            let env = DoctorEnvironment(
                afplayPath: "/usr/bin/afplay",
                settingsFile: settingsFile,
                configFile: root.appendingPathComponent("config.json"),
                userPacksDirectory: root.appendingPathComponent("packs"),
                bundledPacksDirectory: nil,
                logFile: root.appendingPathComponent("claudio.log"),
                claudioBinaryPath: root.appendingPathComponent("no-such-claudio").path)
            let report = runDoctorChecks(environment: env)
            expect(
                report.hasFailure,
                "a missing claudio binary at the fixed hooks path must set hasFailure (exit non-zero)"
            )
            expect(
                report.results.contains { $0.name == "claudio-binary" && $0.severity == .failure },
                "the claudio-binary check must specifically report .failure, got \(report.results)")
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
                bundledPacksDirectory: nil,
                logFile: root.appendingPathComponent("claudio.log"))
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
            let claudioBinaryPath = root.appendingPathComponent("claudio")
            makeExecutableFixture(at: claudioBinaryPath)
            let env = DoctorEnvironment(
                afplayPath: "/usr/bin/afplay",
                settingsFile: settingsFile,
                configFile: root.appendingPathComponent("config.json"),
                userPacksDirectory: root.appendingPathComponent("packs"),
                bundledPacksDirectory: nil,
                logFile: root.appendingPathComponent("claudio.log"),
                claudioBinaryPath: claudioBinaryPath.path)
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

            let claudioBinaryPath = root.appendingPathComponent("claudio")
            makeExecutableFixture(at: claudioBinaryPath)
            let env = DoctorEnvironment(
                afplayPath: "/usr/bin/afplay",
                settingsFile: settingsFile,
                configFile: root.appendingPathComponent("config.json"),
                userPacksDirectory: packsDir,
                bundledPacksDirectory: nil,
                logFile: root.appendingPathComponent("claudio.log"),
                claudioBinaryPath: claudioBinaryPath.path,
                // Deterministic, machine-independent stand-ins for check (f) — otherwise
                // this test's "no warnings at all" assertion would silently depend on
                // whether/which `claude` is installed on whatever machine runs the tests.
                commandRunner: FakeCommandRunner(
                    result: .completed(exitCode: 0, stdout: "2.1.206 (Claude Code)")),
                currentMacOSVersion: { SemanticVersion(major: 15, minor: 0, patch: 0) })
            let report = runDoctorChecks(environment: env)
            expect(!report.hasFailure, "fully healthy environment must not fail")
            expect(
                !report.results.contains { $0.severity == .warning },
                "fully healthy environment should have no warnings either, got \(report.results)")
        }
    }

    suite("summarizeRecentLogFailures: no claudio.log at all (fresh install) → .ok, never a hard failure") {
        withTempDirectory { root in
            let result = summarizeRecentLogFailures(logFile: root.appendingPathComponent("claudio.log"))
            expect(result.severity == .ok, "a log that was never written must report .ok, not a warning")
        }
    }

    suite("summarizeRecentLogFailures: recent failures are surfaced as a warning, never .failure") {
        withTempDirectory { root in
            let logFile = root.appendingPathComponent("claudio.log")
            appendLogLine(
                event: "stop", reason: "afplay 启动失败：/usr/bin/afplay", to: logFile,
                lockFile: root.appendingPathComponent("claudio.log.lock"))

            let result = summarizeRecentLogFailures(logFile: logFile)
            expect(
                result.severity == .warning,
                "a recent failure must be a warning (never .failure — the log itself is"
                    + " diagnostic, not authoritative), got \(result.severity)")
            expect(
                result.message.contains("stop") && result.message.contains("afplay"),
                "the summary message should name the event and mention the reason, got"
                    + " \(result.message)")
        }
    }

    suite("runDoctorChecks: a recent claudio.log failure surfaces as a warning, not hasFailure") {
        withTempDirectory { root in
            let settingsFile = root.appendingPathComponent("settings.json")
            let packsDir = root.appendingPathComponent("packs")
            let logFile = root.appendingPathComponent("claudio.log")
            writeFixture("{}", to: settingsFile)
            writeFixture(
                #"{ "selected_pack": "minimal-chime" }"#,
                to: root.appendingPathComponent("config.json"))
            writeFixture(
                #"{ "id": "minimal-chime", "events": { "stop": "stop.mp3" } }"#,
                to: packsDir.appendingPathComponent("minimal-chime/manifest.json"))
            writeFixture(
                "fake-audio", to: packsDir.appendingPathComponent("minimal-chime/stop.mp3"))
            appendLogLine(
                event: "stop", reason: "afplay 启动失败：/usr/bin/afplay", to: logFile,
                lockFile: root.appendingPathComponent("claudio.log.lock"))

            let claudioBinaryPath = root.appendingPathComponent("claudio")
            makeExecutableFixture(at: claudioBinaryPath)
            let env = DoctorEnvironment(
                afplayPath: "/usr/bin/afplay",
                settingsFile: settingsFile,
                configFile: root.appendingPathComponent("config.json"),
                userPacksDirectory: packsDir,
                bundledPacksDirectory: nil,
                logFile: logFile,
                claudioBinaryPath: claudioBinaryPath.path)
            let report = runDoctorChecks(environment: env)
            expect(
                !report.hasFailure,
                "a recent claudio.log failure must NOT set hasFailure — otherwise every"
                    + " app currently in a warning state would look hard-broken")
            expect(
                report.results.contains { $0.name == "log" && $0.severity == .warning },
                "the log check must surface a warning result when recent failures exist")
        }
    }

    // MARK: - (f) 版本兼容 (T13): doctor-level integration — see `VersionCompatibilitySuite.swift`
    // for the pure `checkClaudeCodeVersion`/`SemanticVersion` unit tests this builds on.

    func healthyDoctorEnvironment(
        root: URL, commandRunner: any CommandRunning,
        currentMacOSVersion: @escaping @Sendable () -> SemanticVersion = { .currentMacOS() }
    ) -> DoctorEnvironment {
        let settingsFile = root.appendingPathComponent("settings.json")
        let packsDir = root.appendingPathComponent("packs")
        writeFixture("{}", to: settingsFile)
        writeFixture(
            #"{ "selected_pack": "minimal-chime" }"#, to: root.appendingPathComponent("config.json"))
        writeFixture(
            #"{ "id": "minimal-chime", "events": { "stop": "stop.mp3" } }"#,
            to: packsDir.appendingPathComponent("minimal-chime/manifest.json"))
        writeFixture("fake-audio", to: packsDir.appendingPathComponent("minimal-chime/stop.mp3"))
        let claudioBinaryPath = root.appendingPathComponent("claudio")
        makeExecutableFixture(at: claudioBinaryPath)
        return DoctorEnvironment(
            afplayPath: "/usr/bin/afplay",
            settingsFile: settingsFile,
            configFile: root.appendingPathComponent("config.json"),
            userPacksDirectory: packsDir,
            bundledPacksDirectory: nil,
            logFile: root.appendingPathComponent("claudio.log"),
            claudioBinaryPath: claudioBinaryPath.path,
            commandRunner: commandRunner,
            currentMacOSVersion: currentMacOSVersion)
    }

    suite(
        "runDoctorChecks: a Claude Code version below the verified minimum surfaces a"
            + " human warning — never hasFailure, exit code stays 0 (T13 acceptance 2)"
    ) {
        withTempDirectory { root in
            let env = healthyDoctorEnvironment(
                root: root,
                commandRunner: FakeCommandRunner(
                    result: .completed(exitCode: 0, stdout: "2.1.99 (Claude Code)")))
            let report = runDoctorChecks(environment: env)
            expect(
                !report.hasFailure,
                "a below-minimum Claude Code version must never set hasFailure (exit code 0)")
            let versionResult = report.results.first { $0.name == "claude-code-version" }
            expect(
                versionResult?.severity == .warning,
                "expected a .warning claude-code-version result, got \(String(describing: versionResult))"
            )
            expect(
                versionResult?.message.contains("StopFailure") == true,
                "the warning should explain the StopFailure implication in plain language, got"
                    + " \(String(describing: versionResult?.message))")
        }
    }

    suite(
        "runDoctorChecks: an undetectable Claude Code version (claude not on PATH) is a"
            + " warning too, never hasFailure"
    ) {
        withTempDirectory { root in
            let env = healthyDoctorEnvironment(
                root: root,
                commandRunner: FakeCommandRunner(result: .completed(exitCode: 127, stdout: "")))
            let report = runDoctorChecks(environment: env)
            expect(!report.hasFailure, "an undetectable Claude Code version must never fail doctor")
            expect(
                report.results.contains { $0.name == "claude-code-version" && $0.severity == .warning },
                "expected a .warning claude-code-version result, got \(report.results)")
        }
    }

    suite(
        "runDoctorChecks: a Claude Code version at/above the verified minimum reports .ok"
    ) {
        withTempDirectory { root in
            let env = healthyDoctorEnvironment(
                root: root,
                commandRunner: FakeCommandRunner(
                    result: .completed(exitCode: 0, stdout: "2.1.206 (Claude Code)")))
            let report = runDoctorChecks(environment: env)
            expect(
                report.results.contains { $0.name == "claude-code-version" && $0.severity == .ok },
                "expected an .ok claude-code-version result, got \(report.results)")
        }
    }

    suite(
        "runDoctorChecks: macos-version check is always .ok, even when the injected current"
            + " version is below the documented floor (anchor 3: informational, never a real"
            + " gate — this branch is provably unreachable on a real machine)"
    ) {
        withTempDirectory { root in
            let env = healthyDoctorEnvironment(
                root: root,
                commandRunner: FakeCommandRunner(
                    result: .completed(exitCode: 0, stdout: "2.1.206 (Claude Code)")),
                currentMacOSVersion: { SemanticVersion(major: 10, minor: 15, patch: 0) })
            let report = runDoctorChecks(environment: env)
            expect(!report.hasFailure, "an injected below-floor macOS version must never fail doctor")
            expect(
                report.results.contains { $0.name == "macos-version" && $0.severity == .ok },
                "macos-version must report .ok regardless of the comparison result — it is"
                    + " purely informational by design, got \(report.results)")
        }
    }

    // MARK: - doctor 的 `.absent` 文案必须与「谁能创建 config.json」的**真实行为**一致
    //
    // 这条守的不是一句话好不好听，是一次**已经发生过**的漂移（`/codex review 573336d` [P2]）：
    // D23 定稿①（`573336d`）把 `setEventEnabled` 改成对缺失的 config **fail closed**，那一刻起静音
    // 再也不会创建 config.json —— 而 doctor 的 `.absent` 文案还在原地写着「首次选包 / **静音**时会
    // 自动创建」。行为改了，文案没跟着改，因为**没有任何东西**把这两者绑在一起：`.absent` 这一支的
    // 文案在整个测试套件里一次都没被碰过。
    //
    // 于是把两半焊在同一个测试里：下面先用**真实磁盘**验「静音确实创建不了 config」，再验「doctor 那
    // 句话没有反过来向用户许诺它能」。任何一半单独改动，这条都会红 —— 而这正是它存在的意义：doctor 是
    // 「静默失败必须有诊断轨迹」（决议 6）的唯一出口，一个说假话的 doctor 诊断的不是这台机器。
    suite("doctor `.absent` 文案 ↔ 行为：静音创建不了 config.json，那句话就不许说它能") {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let lockFile = root.appendingPathComponent("config.lock")

            // ① 行为（真实磁盘）：config.json 不存在时，静音必须 fail closed 且不留下任何文件。
            let outcome = setEventEnabled(
                .stop, enabled: false, configFile: configFile, lockFile: lockFile)
            guard case .failure(let error) = outcome else {
                expect(
                    false,
                    "静音在缺失的 config.json 上必须失败（D23 定稿①）—— 它成功了，说明毒源回来了："
                        + "「还没有人选过包」又一次被伪装成「选过，选的是空」。得到：\(outcome)")
                return
            }
            expect(
                error == .configMissing,
                "必须是 .configMissing（而不是笼统的读写失败）—— 面板靠它重路由到「先选包」空态卡。"
                    + "得到：\(error)")
            expect(
                !FileManager.default.fileExists(atPath: configFile.path),
                "被拒绝的那次写，一个字节都不许落盘")

            // ② 文案：doctor 在同一份磁盘状态上说的那句话，不许与①矛盾。
            let message = configRewritabilityResult(configFile: configFile).message
            expect(
                !message.contains("静音"),
                "doctor 的 `.absent` 文案不许再宣称静音会创建 config.json —— ① 刚刚在真实磁盘上证明了"
                    + "它不会。（要在这句话里**提及**静音也不是不行，比如「在那之前静音开关无处可写」——"
                    + "但那必须是一次**睁着眼**的改动：请连同这条断言一起改，别让文案再一次悄悄跑到行为"
                    + "前面去。）得到：\(message)")
            expect(
                message.contains("选包"),
                "`.absent` 文案必须告诉用户 config.json 到底**由什么**创建 —— 现在全仓唯一有资格从无到有"
                    + "建出它的写者是 `selectPack`（`claudio use` / 面板选包 / 首次自举），这由"
                    + " `MissingConfigPolicy` 在类型层面保证。只说「还没有」不说「怎么才会有」，用户就得"
                    + "自己猜。得到：\(message)")
        }
    }

    // MARK: - `.malformed` 的严重级**只由 case 决定，与 reason 的文本内容无关**
    //
    // ## 它逮的那一刀（红队 9cccc9c，worktree 实测存活）
    //
    // 有人往 `configRewritabilityResult` 的 `case .malformed(let reason)` 里塞一句
    // `guard reason.contains("events") else { return .ok「可安全重写」 }` —— 只有 reason 里带 "events"
    // 的畸形才报 warning，其余（`master_volume` 是字符串、顶层不是对象、`selected_pack` 缺失……）一律
    // 谎报为「✓ config.json 可安全重写」。两套测试**全绿**：整个套件里**唯一**碰过 malformed doctor
    // 渲染的测试（上面第 806 行那条）恰好用的是 `{"events":{"stop":1}}`，reason 含 "events"，落进未改动的
    // warning 分支，把变异完整掩盖。用户后果：手改 `master_volume` 成非法值后，App 里静音 / 切包永久
    // 失效、声音照响，他跑 `doctor` 求诊断，doctor 打绿勾担保机器健康 —— 他永远找不到该修的那份文件。
    //
    // 这条病的形状是老熟人：**一个测试的覆盖范围比它的名字小**。上面那条叫「畸形 config → warning」，
    // 它守的却只是「**events 畸形**的 config → warning」。修法不是再补一个 case，是把不变式本身钉死：
    // doctor 对 config 的严重级是 `probeConfigRewritable` 的**返回 case** 的函数，**不是** reason 字符串
    // 的函数。下面喂一组 reason 两两不同的畸形，逐一验「→ warning、文案是『畸形』那句、且绝不是
    // 『可安全重写』」——任何一条「按 reason 文本放行」的旁路，都会在**非 events 的那几份**上当场变红。
    suite("configRewritabilityResult: 任意 reason 的畸形 config 都必须 warning，绝不因 reason 文本翻成 ok") {
        // (标签, config.json 字节)。三份的 malformed reason 各不相同，且**都不含 "events"** 中的两份，
        // 正是掩盖那条变异的 events fixture 照不到的地方。
        let malformedConfigs: [(label: String, bytes: String)] = [
            ("master_volume 是字符串", #"{ "selected_pack": "x", "master_volume": "0.5" }"#),
            ("顶层不是 JSON 对象", #"[1, 2, 3]"#),
            ("events 畸形（与第 806 行同类，确保围栏也盖住它）", #"{ "selected_pack": "x", "events": { "stop": 1 } }"#),
        ]
        for fixture in malformedConfigs {
            withTempDirectory { root in
                let configFile = root.appendingPathComponent("config.json")
                writeFixture(fixture.bytes, to: configFile)

                // 前提：这份 fixture 确实被探针判成 .malformed（否则下面验的是别的东西）。
                guard case .malformed = probeConfigRewritable(configFile: configFile) else {
                    expect(
                        false,
                        "[\(fixture.label)] 本该是 .malformed，探针却没这么说 —— 这条围栏喂错了输入，"
                            + "得到：\(probeConfigRewritable(configFile: configFile))")
                    return
                }

                let result = configRewritabilityResult(configFile: configFile)
                expect(
                    result.severity == .warning,
                    "[\(fixture.label)] 畸形 config 必须报 warning，与 reason 里写了什么**无关** —— "
                        + "severity 一旦开始看 reason 文本（比如「不含 events 就放行」），doctor 就会对"
                        + "一整类畸形谎报健康。得到 severity：\(result.severity)")
                expect(
                    result.message.contains("畸形") && !result.message.contains("可安全重写"),
                    "[\(fixture.label)] 文案必须是「畸形 …一直失败」那句，绝不能是「✓ 可安全重写」—— "
                        + "后者是对 fail-closed 写路径的假担保。得到：\(result.message)")
            }
        }
    }
}
