import ClaudioGUICore
import Foundation

// MARK: - DropZoneState / AudioImportViewModel: state transitions (DoD: "拖入
// idle/hover/reject×3/success" + "状态正确性下沉 view-model / state fixture 测，非像素快照")

@MainActor
func runAudioImportViewModelSuites() async {
    suite("AudioImportViewModel: starts idle") {
        withTempDirectory { root in
            let environment = makeAudioImportEnvironment(
                userPacksDirectory: root.appendingPathComponent("packs"))
            let viewModel = AudioImportViewModel(packID: "my-pack", environment: environment)
            expect(viewModel.state == .idle, "a freshly-created view-model must start .idle")
        }
    }

    suite("AudioImportViewModel: hover() transitions to .hover; cancelHover() returns to .idle") {
        withTempDirectory { root in
            let environment = makeAudioImportEnvironment(
                userPacksDirectory: root.appendingPathComponent("packs"))
            let viewModel = AudioImportViewModel(packID: "my-pack", environment: environment)

            viewModel.hover()
            expect(viewModel.state == .hover, "hover() must set state to .hover")

            viewModel.cancelHover()
            expect(viewModel.state == .idle, "cancelHover() from .hover must return to .idle")
        }
    }

    await suite(
        "AudioImportViewModel: cancelHover() does NOT clear an existing .reject/.success (only .hover)"
    ) {
        await withTempDirectory { root in
            let environment = makeAudioImportEnvironment(
                userPacksDirectory: root.appendingPathComponent("packs"))
            let viewModel = AudioImportViewModel(packID: "my-pack", environment: environment)

            let sourceURL = root.appendingPathComponent("source/evil.mp3")
            writeFixture(evilShellScriptData(), to: sourceURL)
            await viewModel.handleDrop(sourceURL: sourceURL, suggestedFileName: "evil.mp3")
            expect(
                { if case .reject = viewModel.state { return true } else { return false } }(),
                "setup: handleDrop of a bad file must set .reject")

            viewModel.cancelHover()
            expect(
                { if case .reject = viewModel.state { return true } else { return false } }(),
                "cancelHover() must not clear a .reject state left by a real drop result")
        }
    }

    await suite(
        "AudioImportViewModel: hover() does NOT clobber an existing .reject/.success (mirrors cancelHover()'s guard)"
    ) {
        await withTempDirectory { root in
            let environment = makeAudioImportEnvironment(
                userPacksDirectory: root.appendingPathComponent("packs"))
            let viewModel = AudioImportViewModel(packID: "my-pack", environment: environment)

            let sourceURL = root.appendingPathComponent("source/evil.mp3")
            writeFixture(evilShellScriptData(), to: sourceURL)
            await viewModel.handleDrop(sourceURL: sourceURL, suggestedFileName: "evil.mp3")
            expect(
                { if case .reject = viewModel.state { return true } else { return false } }(),
                "setup: handleDrop of a bad file must set .reject")

            viewModel.hover()
            expect(
                { if case .reject = viewModel.state { return true } else { return false } }(),
                "hover() must not clobber a .reject state left by a real drop result — only .idle should transition to .hover"
            )
        }
    }

    await suite(
        "AudioImportViewModel: handleDrop() on a legal file sets .success and invokes onImportSucceeded"
    ) {
        await withTempDirectory { root in
            let environment = makeAudioImportEnvironment(
                userPacksDirectory: root.appendingPathComponent("packs"))
            let viewModel = AudioImportViewModel(packID: "my-pack", environment: environment)

            var previewedFile: ImportedAudioFile?
            viewModel.onImportSucceeded = { file in previewedFile = file }

            let sourceURL = root.appendingPathComponent("source/chime.wav")
            writeFixture(validWAVData(), to: sourceURL)
            await viewModel.handleDrop(sourceURL: sourceURL, suggestedFileName: "chime.wav")

            guard case .success(let imported) = viewModel.state else {
                expect(false, "expected .success after a legal drop, got \(viewModel.state)")
                return
            }
            expect(imported.fileName == "chime.wav", "state's imported file must be the copied file")
            expect(
                previewedFile == imported,
                "onImportSucceeded must be invoked with the exact same ImportedAudioFile as state")
        }
    }

    await suite("AudioImportViewModel: handleDrop() on a bad file sets .reject and never invokes onImportSucceeded")
    {
        await withTempDirectory { root in
            let environment = makeAudioImportEnvironment(
                userPacksDirectory: root.appendingPathComponent("packs"))
            let viewModel = AudioImportViewModel(packID: "my-pack", environment: environment)

            var invoked = false
            viewModel.onImportSucceeded = { _ in invoked = true }

            let sourceURL = root.appendingPathComponent("source/evil.mp3")
            writeFixture(evilShellScriptData(), to: sourceURL)
            await viewModel.handleDrop(sourceURL: sourceURL, suggestedFileName: "evil.mp3")

            expect(
                viewModel.state == .reject(.nonWhitelistFormat),
                "expected .reject(.nonWhitelistFormat), got \(viewModel.state)")
            expect(!invoked, "onImportSucceeded must never fire for a rejected drop")
        }
    }

    await suite(
        "AudioImportViewModel: multi-file handleDrop() reflects the last accepted file when at least one succeeds"
    ) {
        await withTempDirectory { root in
            let environment = makeAudioImportEnvironment(
                userPacksDirectory: root.appendingPathComponent("packs"))
            let viewModel = AudioImportViewModel(packID: "my-pack", environment: environment)

            let badSource = root.appendingPathComponent("source/evil.mp3")
            writeFixture(evilShellScriptData(), to: badSource)
            let goodSource = root.appendingPathComponent("source/chime.wav")
            writeFixture(validWAVData(), to: goodSource)

            let result = await viewModel.handleDrop(requests: [
                AudioImportRequest(sourceURL: badSource, suggestedFileName: "evil.mp3"),
                AudioImportRequest(sourceURL: goodSource, suggestedFileName: "chime.wav"),
            ])

            expect(result.accepted.count == 1, "batch result must still report exactly one acceptance")
            expect(result.rejected.count == 1, "batch result must still report exactly one rejection")
            guard case .success(let imported) = viewModel.state else {
                expect(false, "expected .success reflecting the accepted file, got \(viewModel.state)")
                return
            }
            expect(imported.fileName == "chime.wav", "state must reflect the accepted file")
        }
    }

    await suite(
        "AudioImportViewModel: multi-file handleDrop() reflects the first rejection when nothing succeeds"
    ) {
        await withTempDirectory { root in
            let environment = makeAudioImportEnvironment(
                userPacksDirectory: root.appendingPathComponent("packs"))
            let viewModel = AudioImportViewModel(packID: "my-pack", environment: environment)

            let firstBad = root.appendingPathComponent("source/one.mp3")
            writeFixture(evilShellScriptData(), to: firstBad)
            let secondBad = root.appendingPathComponent("source/two.mp3")
            writeFixture(evilShellScriptData(), to: secondBad)

            let result = await viewModel.handleDrop(requests: [
                AudioImportRequest(sourceURL: firstBad, suggestedFileName: "one.mp3"),
                AudioImportRequest(sourceURL: secondBad, suggestedFileName: "two.mp3"),
            ])

            expect(result.accepted.isEmpty, "an all-bad batch must accept nothing")
            expect(
                viewModel.state == .reject(.nonWhitelistFormat),
                "expected .reject(.nonWhitelistFormat) reflecting the first rejection, got \(viewModel.state)"
            )
        }
    }

    await suite("AudioImportViewModel: an empty batch handleDrop([]) is a no-op — no state change") {
        await withTempDirectory { root in
            let environment = makeAudioImportEnvironment(
                userPacksDirectory: root.appendingPathComponent("packs"))
            let viewModel = AudioImportViewModel(packID: "my-pack", environment: environment)

            let result = await viewModel.handleDrop(requests: [])

            expect(result.accepted.isEmpty, "an empty batch must accept nothing")
            expect(result.rejected.isEmpty, "an empty batch must reject nothing")
            expect(viewModel.state == .idle, "an empty batch must never move state off .idle")
        }
    }

    // MARK: - retarget(to:): the pack-switch state leak (/codex review [P2])
    //
    // `PanelView.refresh()` used to just assign `.packID = ...` directly on a pack switch,
    // leaving whatever `state` the PREVIOUS pack's last drop produced (a success, a rejection)
    // displayed on the newly-selected pack's panel — the user reads a message about a pack
    // they've already left. `retarget(to:)` fixes this, but has a subtle, load-bearing
    // condition: it resets ONLY when the packID actually CHANGES (`guard newPackID != packID
    // else { return }`), because `refresh()` is ALSO called right after an import/bind
    // completes on the SAME pack — an unconditional reset would erase the very result
    // (especially a FAILURE reason) the user needs to see, re-introducing the silent-error-
    // swallowing this whole branch exists to fix. The two suites below are exactly that pair:
    // one proves the reset happens on a real switch, the other proves it's a no-op when the
    // pack didn't change — an unconditional-reset mutant passes the first and fails the second.

    await suite(
        "AudioImportViewModel.retarget(to:): switching to a DIFFERENT pack clears a lingering .success OR .reject to .idle and repoints packID"
    ) {
        await withTempDirectory { root in
            let environment = makeAudioImportEnvironment(
                userPacksDirectory: root.appendingPathComponent("packs"))

            // A .success left behind by pack-a.
            let successViewModel = AudioImportViewModel(packID: "pack-a", environment: environment)
            let goodSource = root.appendingPathComponent("source/chime.wav")
            writeFixture(validWAVData(), to: goodSource)
            await successViewModel.handleDrop(sourceURL: goodSource, suggestedFileName: "chime.wav")
            guard case .success = successViewModel.state else {
                expect(false, "setup: handleDrop must succeed, got \(successViewModel.state)")
                return
            }

            successViewModel.retarget(to: "pack-b")
            expect(
                successViewModel.state == .idle,
                "retargeting to a DIFFERENT pack must clear a lingering .success to .idle, got"
                    + " \(successViewModel.state)")
            expect(successViewModel.packID == "pack-b", "retarget must repoint packID to the new pack")

            // A .reject left behind by pack-a.
            let rejectViewModel = AudioImportViewModel(packID: "pack-a", environment: environment)
            let evilSource = root.appendingPathComponent("source/evil.mp3")
            writeFixture(evilShellScriptData(), to: evilSource)
            await rejectViewModel.handleDrop(sourceURL: evilSource, suggestedFileName: "evil.mp3")
            guard case .reject = rejectViewModel.state else {
                expect(false, "setup: handleDrop must reject, got \(rejectViewModel.state)")
                return
            }

            rejectViewModel.retarget(to: "pack-b")
            expect(
                rejectViewModel.state == .idle,
                "retargeting to a DIFFERENT pack must clear a lingering .reject to .idle, got"
                    + " \(rejectViewModel.state)")
            expect(rejectViewModel.packID == "pack-b", "retarget must repoint packID to the new pack")
        }
    }

    await suite(
        "AudioImportViewModel.retarget(to:): retargeting to the SAME packID PRESERVES state — the mutation-killer for the `newPackID != packID` guard (an unconditional reset would pass the DIFFERENT-pack test above and only fail here)"
    ) {
        await withTempDirectory { root in
            let environment = makeAudioImportEnvironment(
                userPacksDirectory: root.appendingPathComponent("packs"))
            let viewModel = AudioImportViewModel(packID: "my-pack", environment: environment)

            let sourceURL = root.appendingPathComponent("source/chime.wav")
            writeFixture(validWAVData(), to: sourceURL)
            await viewModel.handleDrop(sourceURL: sourceURL, suggestedFileName: "chime.wav")
            guard case .success(let importedBeforeRetarget) = viewModel.state else {
                expect(false, "setup: handleDrop must succeed, got \(viewModel.state)")
                return
            }

            // This is exactly what `PanelView.refresh()` does right after THIS import completed:
            // it re-asserts the pack the view-model is already pointed at.
            viewModel.retarget(to: "my-pack")

            expect(
                viewModel.state == .success(importedBeforeRetarget),
                "retargeting to the pack it's ALREADY on must PRESERVE the result — wiping it here"
                    + " would erase the success the user just triggered before they ever saw it,"
                    + " got \(viewModel.state)")
            expect(viewModel.packID == "my-pack", "packID must stay unchanged")
        }
    }
}
