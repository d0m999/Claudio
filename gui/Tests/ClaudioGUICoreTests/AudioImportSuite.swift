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
        "importAudioFile: a source EXACTLY at the size cap imports; one byte over is rejected — the bounded read's cap edge"
    ) {
        withTempDirectory { root in
            // The bound read caps memory at `maxFileSizeBytes + 1` bytes and rejects anything
            // that reaches that ceiling. Its sharp edge is the boundary: a file of exactly
            // `maxFileSizeBytes` bytes must still import, while `maxFileSizeBytes + 1` must be
            // rejected. The general oversize test above is far over the cap; this pins the
            // off-by-one at the cap itself.
            let atCap = validWAVData()
            let capBytes = atCap.count

            // Exactly at the cap: passes the size gate, imports.
            let atCapSource = root.appendingPathComponent("source/at-cap.wav")
            writeFixture(atCap, to: atCapSource)
            let atCapOutcome = importAudioFile(
                sourceURL: atCapSource, suggestedFileName: "at-cap.wav", packID: "my-pack",
                environment: makeAudioImportEnvironment(
                    userPacksDirectory: root.appendingPathComponent("packs-at-cap"),
                    maxFileSizeBytes: capBytes))
            expect(
                { if case .success = atCapOutcome { return true } else { return false } }(),
                "a source exactly at the size cap must import, got \(atCapOutcome)")

            // One byte over the cap: rejected as oversize.
            var overCap = validWAVData()
            overCap.append(Data([0x00]))
            let overCapSource = root.appendingPathComponent("source/over-cap.wav")
            writeFixture(overCap, to: overCapSource)
            let overCapOutcome = importAudioFile(
                sourceURL: overCapSource, suggestedFileName: "over-cap.wav", packID: "my-pack",
                environment: makeAudioImportEnvironment(
                    userPacksDirectory: root.appendingPathComponent("packs-over-cap"),
                    maxFileSizeBytes: capBytes))
            guard case .rejected(.oversize(let actualBytes, let maxBytes)) = overCapOutcome else {
                expect(false, "one byte over the cap must be rejected as .oversize, got \(overCapOutcome)")
                return
            }
            expect(maxBytes == capBytes, "maxBytes must echo the injected cap")
            expect(
                actualBytes > maxBytes,
                "actualBytes (\(actualBytes)) must exceed the cap (\(maxBytes))")
        }
    }

    suite(
        "importAudioFile: a valid file larger than the 64 KiB read chunk imports byte-for-byte — exercises the multi-iteration bounded read"
    ) {
        withTempDirectory { root in
            // Every other fixture is tiny (tens of bytes), so the helper's chunked read loop
            // only ever runs a single partial 64 KiB iteration. A real audio file under the
            // 5 MB cap runs it 3+ times — the actual production path. Pad a valid WAV well past
            // one chunk and assert the persisted bytes equal the source exactly, so any
            // accumulation/boundary regression (mis-sliced buffer, off-by-one in `want`) that
            // silently corrupts large imports is caught.
            var big = validWAVData()
            big.append(Data(repeating: 0xAB, count: 200_000))  // ~195 KiB, spans ~4 chunks
            let sourceURL = root.appendingPathComponent("source/large.wav")
            writeFixture(big, to: sourceURL)

            let environment = makeAudioImportEnvironment(
                userPacksDirectory: root.appendingPathComponent("packs"))
            let outcome = importAudioFile(
                sourceURL: sourceURL, suggestedFileName: "large.wav", packID: "my-pack",
                environment: environment)

            guard case .success(let imported) = outcome else {
                expect(false, "a valid >64 KiB file must import, got \(outcome)")
                return
            }
            expect(
                imported.fileSizeBytes == big.count,
                "fileSizeBytes must equal the full source length (\(big.count)), got \(imported.fileSizeBytes)"
            )
            expect(
                (try? Data(contentsOf: imported.destinationURL)) == big,
                "the persisted bytes must equal the source byte-for-byte across chunk boundaries")
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
        "importAudioFile: a SPECIAL (non-regular) source — a FIFO/named pipe — is opened without blocking (O_NONBLOCK) and refused by the fstat regular-file gate, never read (no hang, no unbounded read)"
    ) {
        withTempDirectory { root in
            // A FIFO is the sharp edge: it is not a symlink (so O_NOFOLLOW doesn't catch it)
            // and `Data(contentsOf:)` on a FIFO with no writer blocks forever — a
            // background-task hang / DoS. The bound-read path opens it with `O_NONBLOCK` (so
            // the open itself never blocks) and then `fstat`s the descriptor, refusing it as
            // a non-regular file before a single byte is read. This test would itself HANG on
            // a naive open/`Data(contentsOf:)` path, which is exactly the bug.
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

    suite(
        "importAudioFile: a SPECIAL source that opens fine but is not a regular file — a character device (/dev/null) — is refused on the descriptor's real type, never read"
    ) {
        withTempDirectory { root in
            // Companion to the FIFO case: a FIFO models "the open would block / the read
            // hangs"; /dev/null models "the open succeeds but the descriptor is still not a
            // regular file" (a character device). The single `open` + `fstat` whitelist must
            // refuse it on the descriptor's real type, before any read — proving the
            // regular-file gate covers devices, not just FIFOs. `/dev/null` is a stable,
            // always-present char device on every macOS host, so no fixture setup is needed.
            let userPacksDirectory = root.appendingPathComponent("packs")
            let environment = makeAudioImportEnvironment(userPacksDirectory: userPacksDirectory)
            let outcome = importAudioFile(
                sourceURL: URL(fileURLWithPath: "/dev/null"), suggestedFileName: "null.wav",
                packID: "my-pack", environment: environment)

            guard case .rejected(.copyFailed) = outcome else {
                expect(false, "a character-device source must be rejected as .copyFailed, got \(outcome)")
                return
            }
            expect(
                !FileManager.default.fileExists(
                    atPath: userPacksDirectory.appendingPathComponent("my-pack/null.wav").path),
                "a refused device source must never have written anything into the pack")
        }
    }

    suite(
        "importAudioFile: a source that does not exist at import time (e.g. a vanished NSItemProvider temp file) is rejected as .copyFailed, never crashes"
    ) {
        withTempDirectory { root in
            // The `.unreadable` branch: open() fails with ENOENT (not ELOOP), the path is
            // neither a symlink nor an openable special file — a real case when the dropped
            // temp file is cleaned up between drop and processing. Must reject cleanly, never
            // trap or misreport as .nonWhitelistFormat.
            let missing = root.appendingPathComponent("source/never-created.wav")
            let environment = makeAudioImportEnvironment(
                userPacksDirectory: root.appendingPathComponent("packs"))
            let outcome = importAudioFile(
                sourceURL: missing, suggestedFileName: "never-created.wav", packID: "my-pack",
                environment: environment)

            expect(
                { if case .rejected(.copyFailed) = outcome { return true } else { return false } }(),
                "a nonexistent source must be rejected as .copyFailed, got \(outcome)")
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

    suite(
        "importAudioFile: an unsafe packID (path traversal) is rejected before any pack directory is even touched"
    ) {
        withTempDirectory { root in
            let sourceURL = root.appendingPathComponent("source/chime.mp3")
            writeFixture(validMP3ID3Data(), to: sourceURL)

            let userPacksDirectory = root.appendingPathComponent("packs")
            let environment = makeAudioImportEnvironment(userPacksDirectory: userPacksDirectory)
            let outcome = importAudioFile(
                sourceURL: sourceURL, suggestedFileName: "chime.mp3", packID: "../evil",
                environment: environment)

            expect(
                outcome == .rejected(.pathTraversal),
                "an unsafe packID must be rejected as .pathTraversal before any content check, got \(outcome)"
            )
            expect(
                !FileManager.default.fileExists(atPath: userPacksDirectory.path),
                "an unsafe packID must never even create the user packs root directory")
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

            guard case .rejected(.copyFailed(let reason)) = outcome else {
                expect(false, "a symlink source must be rejected as .copyFailed, got \(outcome)")
                return
            }
            // Pin the ELOOP→.symbolicLink classification: a symlink source must carry the
            // symlink-specific guidance, not the generic '读不到这个文件' read-failure copy
            // (both surface as .copyFailed, so matching the case alone can't tell them apart).
            expect(
                reason.contains("链接") || reason.lowercased().contains("symlink"),
                "a symlink source must carry the symlink-specific message, got: \(reason)")
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
                limits: AudioImportLimits(),
                packsLockFile: injectedPacksLock(besideUserPacks: userPacksDirectory))
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

    suite(
        "importAudioFile: a same-name import gets -2, preserves 中断了's bound bytes, and later collisions advance to -3"
    ) {
        withTempDirectory { root in
            let userPacksDirectory = root.appendingPathComponent("packs")
            let environment = makeAudioImportEnvironment(userPacksDirectory: userPacksDirectory)
            let packDirectory = userPacksDirectory.appendingPathComponent("my-pack", isDirectory: true)

            // This is the T14 user-visible failure shape: 中断了 already owns a.mp3. A
            // later import for 干完了 has the same suggested filename but different bytes;
            // it must get a new name instead of silently changing 中断了's sound.
            var interruptedData = validWAVData()
            interruptedData.append(Data("interrupted-event-original".utf8))
            writeFixture(
                #"{ "id": "my-pack", "events": { "stop_failure": "a.mp3" } }"#,
                to: packDirectory.appendingPathComponent("manifest.json"))
            writeFixture(interruptedData, to: packDirectory.appendingPathComponent("a.mp3"))

            var secondData = validWAVData()
            secondData.append(Data("second-version-marker".utf8))
            let secondSource = root.appendingPathComponent("source/second.wav")
            writeFixture(secondData, to: secondSource)
            let secondOutcome = importAudioFile(
                sourceURL: secondSource, suggestedFileName: "a.mp3", packID: "my-pack",
                environment: environment)

            guard case .success(let imported) = secondOutcome else {
                expect(false, "expected the same-name import to succeed with a unique name, got \(secondOutcome)")
                return
            }
            expect(
                imported.fileName == "a-2.mp3",
                "a collision with a.mp3 must use the independent next name a-2.mp3, got \(imported.fileName)"
            )
            expect(
                (try? Data(contentsOf: packDirectory.appendingPathComponent("a.mp3"))) == interruptedData,
                "中断了's pre-existing a.mp3 bytes must remain byte-for-byte unchanged"
            )
            expect(
                (try? Data(contentsOf: imported.destinationURL)) == secondData,
                "the new same-name import must write its bytes only to a-2.mp3"
            )
            expect(
                { if case .success = bindEventToManifest(
                    event: .stop, fileName: imported.fileName, packID: "my-pack", environment: environment)
                { return true } else { return false } }(),
                "干完了 must be able to bind the distinct a-2.mp3 result"
            )

            var thirdData = validWAVData()
            thirdData.append(Data("third-version-marker".utf8))
            let thirdSource = root.appendingPathComponent("source/third.wav")
            writeFixture(thirdData, to: thirdSource)
            let thirdOutcome = importAudioFile(
                sourceURL: thirdSource, suggestedFileName: "a.mp3", packID: "my-pack",
                environment: environment)

            guard case .success(let thirdImported) = thirdOutcome else {
                expect(false, "expected a second collision to advance to a-3.mp3, got \(thirdOutcome)")
                return
            }
            expect(
                thirdImported.fileName == "a-3.mp3",
                "a collision with both a.mp3 and a-2.mp3 must advance to a-3.mp3, got \(thirdImported.fileName)"
            )
            expect(
                (try? Data(contentsOf: packDirectory.appendingPathComponent("a.mp3"))) == interruptedData,
                "later collisions must still never modify 中断了's bound a.mp3 bytes"
            )
            expect(
                (try? Data(contentsOf: packDirectory.appendingPathComponent("a-2.mp3"))) == secondData,
                "later collisions must leave the first distinct import's a-2.mp3 bytes untouched"
            )
            expect(
                (try? Data(contentsOf: thirdImported.destinationURL)) == thirdData,
                "a-3.mp3 must contain only the third import's bytes"
            )
        }
    }

    suite(
        "importAudioFile: a same-name import beside an in-pack symlink creates -2 and leaves the link and its target untouched"
    ) {
        withTempDirectory { root in
            let userPacksDirectory = root.appendingPathComponent("packs")
            let packDirectory = userPacksDirectory.appendingPathComponent(
                "my-pack", isDirectory: true)

            // A symlink *inside* the pack directory pointing at another file also inside
            // the pack directory is lexically/really contained (unlike the escaping-
            // symlink case above), so `safePackFileURL` lets it through as a valid
            // destination. T14 treats even this occupied directory entry as a collision:
            // the import must allocate chime-2.wav without replacing the link or writing
            // through it to its target.
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
                expect(false, "expected the collision beside an in-pack symlink to succeed, got \(outcome)")
                return
            }
            expect(
                imported.fileName == "chime-2.wav",
                "an occupied symlink entry must reserve chime.wav and allocate chime-2.wav, got \(imported.fileName)"
            )
            expect(
                (try? FileManager.default.destinationOfSymbolicLink(atPath: packDirectory
                    .appendingPathComponent("chime.wav").path)) != nil,
                "the original chime.wav directory entry must remain a symlink"
            )
            expect(
                (try? Data(contentsOf: imported.destinationURL)) == newData,
                "the unique chime-2.wav destination must contain the newly-imported bytes")
            expect(
                (try? Data(contentsOf: otherRealFile)) == otherOriginalData,
                "the symlink target must be untouched — the import must not write through or replace the old link")
        }
    }

    suite(
        "importAudioFile: a same-name import beside a dangling in-pack symlink creates -2 and preserves the dangling link"
    ) {
        withTempDirectory { root in
            let userPacksDirectory = root.appendingPathComponent("packs")
            let packDirectory = userPacksDirectory.appendingPathComponent(
                "my-pack", isDirectory: true)
            let danglingLink = packDirectory.appendingPathComponent("chime.wav")
            let missingTarget = packDirectory.appendingPathComponent("missing-target.wav")

            // `FileManager.fileExists` follows links and reports this as absent. T14 must
            // use lstat semantics instead: the directory entry still exists and must never
            // be atomically replaced merely because its target is currently missing.
            createSymlink(at: danglingLink, pointingTo: missingTarget)

            var newData = validWAVData()
            newData.append(Data("dangling-link-collision".utf8))
            let newSource = root.appendingPathComponent("source/new.wav")
            writeFixture(newData, to: newSource)

            let environment = makeAudioImportEnvironment(userPacksDirectory: userPacksDirectory)
            let outcome = importAudioFile(
                sourceURL: newSource, suggestedFileName: "chime.wav", packID: "my-pack",
                environment: environment)

            guard case .success(let imported) = outcome else {
                expect(false, "expected the collision beside a dangling symlink to succeed, got \(outcome)")
                return
            }
            expect(
                imported.fileName == "chime-2.wav",
                "a dangling symlink must reserve chime.wav and allocate chime-2.wav, got \(imported.fileName)"
            )
            expect(
                (try? FileManager.default.destinationOfSymbolicLink(atPath: danglingLink.path))
                    == missingTarget.path,
                "the original chime.wav directory entry must remain the same dangling symlink"
            )
            expect(
                !FileManager.default.fileExists(atPath: missingTarget.path),
                "the dangling symlink's absent target must remain absent; import must not write through it"
            )
            expect(
                (try? Data(contentsOf: imported.destinationURL)) == newData,
                "the unique chime-2.wav destination must contain the imported bytes")
        }
    }

    // MARK: - Built-in pack collision (T8 acceptance criterion 6; T6 — PLAN-SOUND-MANAGER.md
    // §2.3 — moved the judging criterion from `bundledPacksDirectory` to `builtinPackIDs`
    // (derived from `factoryPacksDirectory`), completely decoupling the two.

    suite("importAudioFile: importing into a pack id in environment.builtinPackIDs is refused") {
        withTempDirectory { root in
            let userPacksDirectory = root.appendingPathComponent("packs")
            let factoryPacksDirectory = root.appendingPathComponent("factory")
            // "minimal-chime" is a built-in pack — its factory copy exists. The user has never
            // touched this pack id under userPacksDirectory.
            try? FileManager.default.createDirectory(
                at: factoryPacksDirectory.appendingPathComponent("minimal-chime"),
                withIntermediateDirectories: true)

            let sourceURL = root.appendingPathComponent("source/stop.wav")
            writeFixture(validWAVData(), to: sourceURL)

            let environment = makeAudioImportEnvironment(
                userPacksDirectory: userPacksDirectory, factoryPacksDirectory: factoryPacksDirectory)
            let outcome = importAudioFile(
                sourceURL: sourceURL, suggestedFileName: "stop.wav", packID: "minimal-chime",
                environment: environment)

            expect(
                outcome == .rejected(.builtinReadOnly(packID: "minimal-chime")),
                "importing into a built-in pack id must be refused, got \(outcome)")
            expect(
                !FileManager.default.fileExists(
                    atPath: userPacksDirectory.appendingPathComponent("minimal-chime/stop.wav").path),
                "a refused import must never have written anything to disk")
        }
    }

    suite(
        "importAudioFile: T6 decoupling — a pack id that exists ONLY in bundledPacksDirectory"
            + " (not in builtinPackIDs) is no longer refused; it imports normally"
    ) {
        withTempDirectory { root in
            let userPacksDirectory = root.appendingPathComponent("packs")
            let bundledPacksDirectory = root.appendingPathComponent("bundled")
            // The OLD (pre-T6) `isBuiltinOnlyPackID` judging criterion would have refused this
            // exact setup — a pack id existing only via `bundledPacksDirectory`, with no user
            // copy yet. `factoryPacksDirectory` is deliberately left `nil` here: the new
            // criterion (`environment.builtinPackIDs`, derived solely from
            // `factoryPacksDirectory`) must not even glance at `bundledPacksDirectory`. This is
            // a REAL behavior change from the old code, not just a renamed case — assert the
            // change, not just the surviving half.
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

            guard case .success = outcome else {
                expect(
                    false,
                    "a pack id present only in bundledPacksDirectory must import successfully now"
                        + " that builtinPackIDs is decoupled from it — got \(outcome)")
                return
            }
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

    // MARK: - packsLockFile: importAudioFile's persist step is a third writer of the same
    // `packs/` subtree `bindEventToManifest`/`clearEventBinding` and `performFirstRunSetup`
    // already serialize on (mirrors `ManifestBindingSuite`'s "包目录锁" section exactly — same
    // lock, same non-blocking semantics, same failure-mode reasoning).

    suite(
        "importAudioFile: 包锁被占住时必须报 .lockBusy，且不许创建目录 / 写入任何文件"
    ) {
        withTempDirectory { root in
            let userPacksDirectory = root.appendingPathComponent("packs")
            let packsLock = injectedPacksLock(besideUserPacks: userPacksDirectory)
            let environment = AudioImportEnvironment(
                userPacksDirectory: userPacksDirectory,
                durationProbe: StubDurationProbe(fixedDuration: 1.0),
                limits: AudioImportLimits(),
                packsLockFile: packsLock)

            let sourceURL = root.appendingPathComponent("source/stop.wav")
            writeFixture(validWAVData(), to: sourceURL)

            // 同进程内用第二个 `open(2)` 抢占同一把锁 —— 与 `ManifestBindingSuite` 同一手法：
            // `FileLock` 自己 `open` 一次，`flock` 争用不看是不是同进程。
            let outcome = withNonBlockingLock(path: packsLock.path) {
                importAudioFile(
                    sourceURL: sourceURL, suggestedFileName: "stop.wav", packID: "my-pack",
                    environment: environment)
            }
            guard case .ran(let result) = outcome else {
                expect(false, "测试自身的前提坏了：外层那把锁没拿到（\(outcome)）")
                return
            }
            expect(
                result == .rejected(.lockBusy),
                "包锁被别人占住时 importAudioFile 必须返回 `.rejected(.lockBusy)`，实得 \(result)。"
                    + "`withNonBlockingLock` 是**非阻塞**的：争用即 `.skipped`，创建目录 + 写入这两步"
                    + "根本不跑。")

            // body 没跑，就不许有任何磁盘痕迹 —— 钉的是「建目录 + 写文件」整段都在锁的作用域里，
            // 不是「锁在某处存在」。
            let packDirectory = userPacksDirectory.appendingPathComponent("my-pack")
            expect(
                !FileManager.default.fileExists(atPath: packDirectory.path),
                "importAudioFile 因为锁忙而拒绝，却创建了 \(packDirectory.path) —— 说明"
                    + "「建目录 + 写文件」没有**整段**在锁的作用域里。")
        }
    }

    suite(
        "importAudioFile: 成功导入之后必须把包锁还回去（不许一直持有）"
    ) {
        withTempDirectory { root in
            let userPacksDirectory = root.appendingPathComponent("packs")
            let packsLock = injectedPacksLock(besideUserPacks: userPacksDirectory)
            let environment = AudioImportEnvironment(
                userPacksDirectory: userPacksDirectory,
                durationProbe: StubDurationProbe(fixedDuration: 1.0),
                limits: AudioImportLimits(),
                packsLockFile: packsLock)

            let sourceURL = root.appendingPathComponent("source/stop.wav")
            writeFixture(validWAVData(), to: sourceURL)
            let outcome = importAudioFile(
                sourceURL: sourceURL, suggestedFileName: "stop.wav", packID: "my-pack",
                environment: environment)
            guard case .success = outcome else {
                expect(false, "前提：这次 import 应当成功，实得 \(outcome)")
                return
            }

            // 锁还回去了 ⇒ 现在还能再拿到。拿不到 = 上一次调用把锁一直攥着，于是**下一次**
            // import、bind、以及任何一次 `claudio setup`，都会永久 `.lockBusy`。
            let reacquired = withNonBlockingLock(path: packsLock.path) { true }
            guard case .ran = reacquired else {
                expect(
                    false,
                    "一次成功的 import 之后包锁没有被释放（实得 \(reacquired)）—— 之后每一次"
                        + " import / bind / `claudio setup` 都会永久报「忙」")
                return
            }
            expect(true, "成功路径释放了包锁")
        }
    }
}
