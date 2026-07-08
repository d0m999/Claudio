import ClaudioCore
import ClaudioGUICore
import Foundation

// MARK: - importAudioFile: the five named rejection reasons + success (T8 acceptance
// criteria 2, 3, 5, 6)

@MainActor
func runAudioImportSuites() {
    suite("importAudioFile: oversize source is rejected with the exact byte counts, human message") {
        withTempDirectory { root in
            let sourceURL = root.appendingPathComponent("source/big.wav")
            var oversized = validWAVData()
            oversized.append(Data(repeating: 0, count: 200))
            writeFixture(oversized, to: sourceURL)

            let environment = makeAudioImportEnvironment(
                userPacksDirectory: root.appendingPathComponent("packs"), maxFileSizeBytes: 100)
            let outcome = importAudioFile(
                sourceURL: sourceURL, suggestedFileName: "big.wav", packID: "my-pack",
                environment: environment)

            guard case .rejected(.oversize(let actualBytes, let maxBytes)) = outcome else {
                expect(false, "expected .rejected(.oversize), got \(outcome)")
                return
            }
            expect(actualBytes > maxBytes, "actualBytes must exceed maxBytes for an oversize reject")
            expect(maxBytes == 100, "maxBytes must echo the injected limit")
            expect(
                !DropRejectionReason.oversize(actualBytes: actualBytes, maxBytes: maxBytes).message
                    .isEmpty, "oversize must carry a non-empty human message")
        }
    }

    suite(
        "importAudioFile: a source that can't actually be read (a directory) is reported as .copyFailed, not misreported as .nonWhitelistFormat"
    ) {
        withTempDirectory { root in
            // A directory is not a regular file, so the regular-file whitelist (step 3)
            // refuses it as `.copyFailed` before any content read — still the real cause,
            // never misreported as `.nonWhitelistFormat`. (Before the whitelist landed this
            // fell through to `Data(contentsOf:)` throwing on the directory; the observable
            // outcome — `.copyFailed`, not `.nonWhitelistFormat` — is unchanged.)
            let sourceURL = root.appendingPathComponent("source/not-a-file.wav")
            try? FileManager.default.createDirectory(
                at: sourceURL, withIntermediateDirectories: true)

            let environment = makeAudioImportEnvironment(
                userPacksDirectory: root.appendingPathComponent("packs"))
            let outcome = importAudioFile(
                sourceURL: sourceURL, suggestedFileName: "not-a-file.wav", packID: "my-pack",
                environment: environment)

            expect(
                { if case .rejected(.copyFailed) = outcome { return true } else { return false } }(),
                "an unreadable source must be reported as .copyFailed (the real cause), not"
                    + " .nonWhitelistFormat, got \(outcome)")
        }
    }

    suite(
        "importAudioFile: a SPECIAL (non-regular) source — a FIFO/named pipe — is refused via metadata, never opened for reading (no hang, no unbounded read)"
    ) {
        withTempDirectory { root in
            // A FIFO is the sharp edge: `attributesOfItem` reports a meaningless small
            // `.size` (so the size cap can't catch it) and it is not a symlink (so the
            // symlink guard doesn't either), yet `Data(contentsOf:)` on a FIFO with no
            // writer blocks forever — a background-task hang / DoS. The `.typeRegular`
            // whitelist must refuse it on metadata alone, before any read. This test would
            // itself HANG on the pre-whitelist code, which is exactly the bug.
            let sourceDirectory = root.appendingPathComponent("source", isDirectory: true)
            try? FileManager.default.createDirectory(
                at: sourceDirectory, withIntermediateDirectories: true)
            let fifoURL = sourceDirectory.appendingPathComponent("pipe.wav")
            let mkfifoResult = fifoURL.path.withCString { mkfifo($0, 0o644) }
            expect(
                mkfifoResult == 0,
                "setup: mkfifo must succeed to model a special (non-regular) source file")

            let userPacksDirectory = root.appendingPathComponent("packs")
            let environment = makeAudioImportEnvironment(userPacksDirectory: userPacksDirectory)
            let outcome = importAudioFile(
                sourceURL: fifoURL, suggestedFileName: "pipe.wav", packID: "my-pack",
                environment: environment)

            guard case .rejected(.copyFailed) = outcome else {
                expect(false, "a FIFO/special-file source must be rejected as .copyFailed, got \(outcome)")
                return
            }
            expect(
                !FileManager.default.fileExists(
                    atPath: userPacksDirectory.appendingPathComponent("my-pack/pipe.wav").path),
                "a refused special-file source must never have written anything into the pack")
        }
    }

    suite("importAudioFile: non-whitelist content is rejected regardless of its .mp3 extension") {
        withTempDirectory { root in
            let sourceURL = root.appendingPathComponent("source/evil.mp3")
            writeFixture(evilShellScriptData(), to: sourceURL)

            let environment = makeAudioImportEnvironment(
                userPacksDirectory: root.appendingPathComponent("packs"))
            let outcome = importAudioFile(
                sourceURL: sourceURL, suggestedFileName: "evil.mp3", packID: "my-pack",
                environment: environment)

            expect(
                outcome == .rejected(.nonWhitelistFormat),
                "a renamed shell script must be rejected by content sniff, got \(outcome)")
        }
    }

    for (name, badFileName) in [
        ("parent-escape", "../../evil.mp3"),
        ("absolute-path", "/etc/evil.mp3"),
        ("nul-byte", "evil\0.mp3"),
        ("empty-name", ""),
    ] {
        suite("importAudioFile: path traversal via \(name) is rejected") {
            withTempDirectory { root in
                let sourceURL = root.appendingPathComponent("source/chime.mp3")
                writeFixture(validMP3ID3Data(), to: sourceURL)

                let environment = makeAudioImportEnvironment(
                    userPacksDirectory: root.appendingPathComponent("packs"))
                let outcome = importAudioFile(
                    sourceURL: sourceURL, suggestedFileName: badFileName, packID: "my-pack",
                    environment: environment)

                expect(
                    outcome == .rejected(.pathTraversal),
                    "\(name) (\(badFileName)) must be rejected as pathTraversal, got \(outcome)")
            }
        }
    }

    suite("importAudioFile: a destination that is a symlink escaping the pack directory is rejected")
    {
        withTempDirectory { root in
            let userPacksDirectory = root.appendingPathComponent("packs")
            let packDirectory = userPacksDirectory.appendingPathComponent(
                "my-pack", isDirectory: true)
            let outside = root.appendingPathComponent("outside-secret", isDirectory: true)
            try? FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            // The destination filename resolves to a symlink already sitting in the pack
            // directory, whose target lies outside it — `safePackFileURL` must reject
            // this exactly like a lexical `../` escape.
            createSymlink(
                at: packDirectory.appendingPathComponent("chime.mp3"), pointingTo: outside)

            let sourceURL = root.appendingPathComponent("source/chime.mp3")
            writeFixture(validMP3ID3Data(), to: sourceURL)

            let environment = makeAudioImportEnvironment(userPacksDirectory: userPacksDirectory)
            let outcome = importAudioFile(
                sourceURL: sourceURL, suggestedFileName: "chime.mp3", packID: "my-pack",
                environment: environment)

            expect(
                outcome == .rejected(.pathTraversal),
                "a destination filename that is a symlink escaping the pack dir must be rejected, got \(outcome)"
            )
        }
    }

    suite(
        "importAudioFile: a SOURCE that is a symlink to a large file is rejected, never planted as a symlink in the pack dir, and never fully read into memory"
    ) {
        withTempDirectory { root in
            // The symlink's *target* is well over the (tiny, injected) size cap — if the
            // size check ever trusted the symlink's own metadata (its target path
            // string's length, not the target's real size), this would sail through the
            // cap entirely. `sniffAudioFormat`-satisfying content on top confirms this
            // isn't accidentally caught by the format whitelist instead.
            let realTarget = root.appendingPathComponent("elsewhere/real-large.wav")
            var largeData = validWAVData()
            largeData.append(Data(repeating: 0, count: 10_000))
            writeFixture(largeData, to: realTarget)

            let symlinkSource = root.appendingPathComponent("source/chime.wav")
            createSymlink(at: symlinkSource, pointingTo: realTarget)

            let userPacksDirectory = root.appendingPathComponent("packs")
            let environment = makeAudioImportEnvironment(
                userPacksDirectory: userPacksDirectory, maxFileSizeBytes: 5 * 1024 * 1024)
            let outcome = importAudioFile(
                sourceURL: symlinkSource, suggestedFileName: "chime.wav", packID: "my-pack",
                environment: environment)

            guard case .rejected(.copyFailed) = outcome else {
                expect(false, "a symlink source must be rejected as .copyFailed, got \(outcome)")
                return
            }
            let destination = userPacksDirectory.appendingPathComponent("my-pack/chime.wav")
            expect(
                !FileManager.default.fileExists(atPath: destination.path),
                "a refused symlink-source import must never have written anything to disk")
        }
    }

    suite(
        "importAudioFile: a SOURCE symlink small enough to pass the (bypassed) size check is still rejected, not silently copied as a symlink"
    ) {
        withTempDirectory { root in
            let realTarget = root.appendingPathComponent("elsewhere/real.wav")
            writeFixture(validWAVData(), to: realTarget)

            let symlinkSource = root.appendingPathComponent("source/chime.wav")
            createSymlink(at: symlinkSource, pointingTo: realTarget)

            let userPacksDirectory = root.appendingPathComponent("packs")
            let environment = makeAudioImportEnvironment(userPacksDirectory: userPacksDirectory)
            let outcome = importAudioFile(
                sourceURL: symlinkSource, suggestedFileName: "chime.wav", packID: "my-pack",
                environment: environment)

            expect(
                { if case .rejected(.copyFailed) = outcome { return true } else { return false } }(),
                "a symlink source must always be refused, even when small enough to pass the size cap, got \(outcome)"
            )
        }
    }

    suite("importAudioFile: over-duration source is rejected with the exact seconds, human message") {
        withTempDirectory { root in
            let sourceURL = root.appendingPathComponent("source/long.wav")
            writeFixture(validWAVData(), to: sourceURL)

            let environment = makeAudioImportEnvironment(
                userPacksDirectory: root.appendingPathComponent("packs"), duration: 10.0,
                maxDurationSeconds: 3.0)
            let outcome = importAudioFile(
                sourceURL: sourceURL, suggestedFileName: "long.wav", packID: "my-pack",
                environment: environment)

            guard case .rejected(.overDuration(let actualSeconds, let maxSeconds)) = outcome else {
                expect(false, "expected .rejected(.overDuration), got \(outcome)")
                return
            }
            expect(actualSeconds == 10.0, "actualSeconds must echo the probed duration")
            expect(maxSeconds == 3.0, "maxSeconds must echo the injected limit")
        }
    }

    suite("importAudioFile: an undeterminable duration (probe returns nil) is rejected too, fail-closed")
    {
        withTempDirectory { root in
            let sourceURL = root.appendingPathComponent("source/mystery.wav")
            writeFixture(validWAVData(), to: sourceURL)

            let environment = makeAudioImportEnvironment(
                userPacksDirectory: root.appendingPathComponent("packs"), duration: nil)
            let outcome = importAudioFile(
                sourceURL: sourceURL, suggestedFileName: "mystery.wav", packID: "my-pack",
                environment: environment)

            guard case .rejected(.overDuration(let actualSeconds, _)) = outcome else {
                expect(false, "expected .rejected(.overDuration) for an unmeasurable file, got \(outcome)")
                return
            }
            expect(actualSeconds == nil, "actualSeconds must be nil when the probe couldn't tell")
            let message = DropRejectionReason.overDuration(actualSeconds: nil, maxSeconds: 3.0)
                .message
            expect(
                !message.isEmpty && !message.lowercased().contains("inf"),
                "an unmeasurable-duration message must be a real sentence, not print 'inf': \(message)"
            )
        }
    }

    suite(
        "importAudioFile: duration is probed on the validated copy's bytes, never by re-opening the original source"
    ) {
        withTempDirectory { root in
            let sourceURL = root.appendingPathComponent("source/chime.wav")
            let sourceBytes = validWAVData()
            writeFixture(sourceBytes, to: sourceURL)

            let probe = RecordingDurationProbe(fixedDuration: 1.0)
            let userPacksDirectory = root.appendingPathComponent("packs")
            let environment = AudioImportEnvironment(
                userPacksDirectory: userPacksDirectory, durationProbe: probe,
                limits: AudioImportLimits())
            let outcome = importAudioFile(
                sourceURL: sourceURL, suggestedFileName: "chime.wav", packID: "my-pack",
                environment: environment)

            guard case .success = outcome else {
                expect(false, "expected .success for a legal file, got \(outcome)")
                return
            }
            // The probe must NOT have been handed the original source path — proving the
            // duration was measured on a separate validated copy, closing the same-user
            // TOCTOU window where `sourceURL` could be swapped between the content read and
            // the probe.
            expect(
                probe.probedURL != nil && probe.probedURL?.path != sourceURL.path,
                "duration must be probed on a copy, not by re-opening the original sourceURL"
                    + " (probedURL=\(String(describing: probe.probedURL?.path)))")
            // ...and the bytes it measured must equal exactly the bytes that were persisted
            // (== the bytes read from source in step 4).
            expect(
                probe.probedBytes == sourceBytes,
                "the bytes handed to duration probing must equal the validated/persisted bytes")
            // The temp file used for probing must not leak — nothing survives outside the
            // pack once import returns.
            expect(
                probe.probedURL.map { !FileManager.default.fileExists(atPath: $0.path) } ?? false,
                "the throwaway duration-probe temp file must be cleaned up after import")
        }
    }

    for (formatName, data) in [
        ("wav", validWAVData()), ("mp3 (id3)", validMP3ID3Data()),
        ("mp3 (frame sync)", validMP3FrameSyncData()), ("aiff", validAIFFData()),
        ("m4a", validM4AData()),
    ] {
        suite("importAudioFile: a legal \(formatName) file copies into the user pack, surfaces filename")
        {
            withTempDirectory { root in
                let sourceURL = root.appendingPathComponent("source/original-name.audio")
                writeFixture(data, to: sourceURL)

                let userPacksDirectory = root.appendingPathComponent("packs")
                let environment = makeAudioImportEnvironment(
                    userPacksDirectory: userPacksDirectory, duration: 1.2)
                let outcome = importAudioFile(
                    sourceURL: sourceURL, suggestedFileName: "chime.audio", packID: "my-pack",
                    environment: environment)

                guard case .success(let imported) = outcome else {
                    expect(false, "expected .success for a legal \(formatName) file, got \(outcome)")
                    return
                }
                expect(imported.packID == "my-pack", "imported.packID must echo the target pack")
                expect(
                    imported.fileName == "chime.audio",
                    "imported.fileName must be the validated destination name, got \(imported.fileName)"
                )
                expect(
                    imported.destinationURL.path
                        == userPacksDirectory.appendingPathComponent("my-pack/chime.audio").path,
                    "destinationURL must be inside the user pack directory")
                expect(imported.duration == 1.2, "imported.duration must echo the probed duration")
                expect(
                    FileManager.default.fileExists(atPath: imported.destinationURL.path),
                    "the file must actually exist on disk at destinationURL after import")
                expect(
                    (try? Data(contentsOf: imported.destinationURL)) == data,
                    "the copied file's bytes must exactly match the source's bytes")
                // The original source is untouched — a *copy*, not a move (acceptance
                // criterion 1: "never reference the original path" also implies the
                // original keeps existing independently of the copy).
                expect(
                    FileManager.default.fileExists(atPath: sourceURL.path),
                    "the original source file must still exist — import COPIES, never moves")
            }
        }
    }

    suite("importAudioFile: re-dropping onto the same filename in an already-owned pack replaces it") {
        withTempDirectory { root in
            let userPacksDirectory = root.appendingPathComponent("packs")
            let environment = makeAudioImportEnvironment(userPacksDirectory: userPacksDirectory)

            let firstSource = root.appendingPathComponent("source/first.wav")
            writeFixture(validWAVData(), to: firstSource)
            let firstOutcome = importAudioFile(
                sourceURL: firstSource, suggestedFileName: "chime.wav", packID: "my-pack",
                environment: environment)
            expect(
                { if case .success = firstOutcome { return true } else { return false } }(),
                "setup: the first import must succeed")

            var secondData = validWAVData()
            secondData.append(Data("second-version-marker".utf8))
            let secondSource = root.appendingPathComponent("source/second.wav")
            writeFixture(secondData, to: secondSource)
            let secondOutcome = importAudioFile(
                sourceURL: secondSource, suggestedFileName: "chime.wav", packID: "my-pack",
                environment: environment)

            guard case .success(let imported) = secondOutcome else {
                expect(false, "expected the re-drop to succeed and replace the file, got \(secondOutcome)")
                return
            }
            expect(
                (try? Data(contentsOf: imported.destinationURL)) == secondData,
                "re-dropping the same filename must replace the previous file's contents, not append/fail"
            )
        }
    }

    suite(
        "importAudioFile: re-dropping onto a filename that is currently an in-pack symlink replaces the link itself, never writes through it"
    ) {
        withTempDirectory { root in
            let userPacksDirectory = root.appendingPathComponent("packs")
            let packDirectory = userPacksDirectory.appendingPathComponent(
                "my-pack", isDirectory: true)

            // A symlink *inside* the pack directory pointing at another file also inside
            // the pack directory is lexically/really contained (unlike the escaping-
            // symlink case above), so `safePackFileURL` lets it through as a valid
            // destination — the write step itself must still not clobber whatever it
            // points to.
            let otherRealFile = packDirectory.appendingPathComponent("other-real.wav")
            let otherOriginalData = validWAVData()
            writeFixture(otherOriginalData, to: otherRealFile)
            createSymlink(
                at: packDirectory.appendingPathComponent("chime.wav"), pointingTo: otherRealFile)

            var newData = validWAVData()
            newData.append(Data("brand-new-content".utf8))
            let newSource = root.appendingPathComponent("source/new.wav")
            writeFixture(newData, to: newSource)

            let environment = makeAudioImportEnvironment(userPacksDirectory: userPacksDirectory)
            let outcome = importAudioFile(
                sourceURL: newSource, suggestedFileName: "chime.wav", packID: "my-pack",
                environment: environment)

            guard case .success(let imported) = outcome else {
                expect(false, "expected the re-drop over an in-pack symlink to succeed, got \(outcome)")
                return
            }
            expect(
                (try? FileManager.default.destinationOfSymbolicLink(atPath: imported.destinationURL.path))
                    == nil,
                "the destination must become a REAL file, not remain/stay a symlink")
            expect(
                (try? Data(contentsOf: imported.destinationURL)) == newData,
                "the destination must contain the newly-imported bytes")
            expect(
                (try? Data(contentsOf: otherRealFile)) == otherOriginalData,
                "the file the old symlink pointed to must be untouched — the import must replace the"
                    + " directory entry, never write through the old symlink to its target")
        }
    }

    // MARK: - Built-in pack collision (T8 acceptance criterion 6)

    suite("importAudioFile: importing into a pack id that exists ONLY as a bundled pack is refused") {
        withTempDirectory { root in
            let userPacksDirectory = root.appendingPathComponent("packs")
            let bundledPacksDirectory = root.appendingPathComponent("bundled")
            // The bundled pack exists on disk; the user has never touched this pack id.
            try? FileManager.default.createDirectory(
                at: bundledPacksDirectory.appendingPathComponent("minimal-chime"),
                withIntermediateDirectories: true)

            let sourceURL = root.appendingPathComponent("source/stop.wav")
            writeFixture(validWAVData(), to: sourceURL)

            let environment = makeAudioImportEnvironment(
                userPacksDirectory: userPacksDirectory, bundledPacksDirectory: bundledPacksDirectory)
            let outcome = importAudioFile(
                sourceURL: sourceURL, suggestedFileName: "stop.wav", packID: "minimal-chime",
                environment: environment)

            expect(
                outcome == .rejected(.overwritesBuiltin(packID: "minimal-chime")),
                "importing into a still-purely-built-in pack id must be refused, got \(outcome)")
            expect(
                !FileManager.default.fileExists(
                    atPath: userPacksDirectory.appendingPathComponent("minimal-chime/stop.wav").path),
                "a refused import must never have written anything to disk")
        }
    }

    suite("importAudioFile: once a user copy of a same-id pack already exists, import proceeds normally")
    {
        withTempDirectory { root in
            let userPacksDirectory = root.appendingPathComponent("packs")
            let bundledPacksDirectory = root.appendingPathComponent("bundled")
            try? FileManager.default.createDirectory(
                at: bundledPacksDirectory.appendingPathComponent("minimal-chime"),
                withIntermediateDirectories: true)
            // The user has ALREADY claimed this pack id (e.g. a prior import, or some
            // other explicit action) — this directory existing is what distinguishes this
            // case from the refusal case above.
            try? FileManager.default.createDirectory(
                at: userPacksDirectory.appendingPathComponent("minimal-chime"),
                withIntermediateDirectories: true)

            let sourceURL = root.appendingPathComponent("source/stop.wav")
            writeFixture(validWAVData(), to: sourceURL)

            let environment = makeAudioImportEnvironment(
                userPacksDirectory: userPacksDirectory, bundledPacksDirectory: bundledPacksDirectory)
            let outcome = importAudioFile(
                sourceURL: sourceURL, suggestedFileName: "stop.wav", packID: "minimal-chime",
                environment: environment)

            guard case .success = outcome else {
                expect(
                    false,
                    "importing into an already-user-owned pack id must succeed even if a same-id bundled pack exists, got \(outcome)"
                )
                return
            }
        }
    }

    suite("importAudioFile: a pack id with no bundled counterpart at all is never treated as a collision")
    {
        withTempDirectory { root in
            let userPacksDirectory = root.appendingPathComponent("packs")
            let bundledPacksDirectory = root.appendingPathComponent("bundled")
            // Bundled root exists, but has nothing for THIS id.
            try? FileManager.default.createDirectory(
                at: bundledPacksDirectory, withIntermediateDirectories: true)

            let sourceURL = root.appendingPathComponent("source/stop.wav")
            writeFixture(validWAVData(), to: sourceURL)

            let environment = makeAudioImportEnvironment(
                userPacksDirectory: userPacksDirectory, bundledPacksDirectory: bundledPacksDirectory)
            let outcome = importAudioFile(
                sourceURL: sourceURL, suggestedFileName: "stop.wav", packID: "brand-new-pack",
                environment: environment)

            guard case .success = outcome else {
                expect(false, "a genuinely new pack id must import successfully, got \(outcome)")
                return
            }
        }
    }
}
