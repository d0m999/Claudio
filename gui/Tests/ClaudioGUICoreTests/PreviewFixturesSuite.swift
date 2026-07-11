import ClaudioCore
import ClaudioGUICore
import Foundation

// MARK: - PreviewFixtures: single-source-of-truth + exhaustiveness (ENGINEERING.md T14 D1/D3)
//
// `PreviewFixtures` (`ClaudioGUICore`) is the ONE place every sample state VALUE the state
// gallery (`ClaudioGUI/StateGalleryView.swift`, T14 D2) renders is constructed. This suite
// pins the RUNTIME shape of each fixture array — that every case (and, for the two-level
// DropZoneState/DropRejectionReason pair, every reason) actually appears — on top of
// `PreviewFixtures`'s own compile-time exhaustive `switch`es (which only guarantee "a human
// wrote a branch for this case somewhere", not "the fixture ARRAY itself includes a sample of
// it"). Together (T14 acceptance criterion 3): a new enum case fails THIS PACKAGE's build
// first (`PreviewFixtures`'s guards, plus every other non-`default` `switch` over these four
// types), and even if a human adds just enough of a branch to compile without also adding a
// fixture, this suite's counts/combinations catch that gap at runtime.
//
// Local label functions below (`onboardingStateLabel`, etc.) are deliberately this suite's
// OWN small exhaustive mappings — not a reuse of `PreviewFixtures`'s internal
// `_coverage(_:)` helpers — mirroring `OnboardingStateSuite.swift`'s own `debugLabel(for:)`
// pattern already established in this file's neighbors: production code never needs a
// state → debug-string mapping, so it stays test-only, duplicated per suite rather than
// promoted to `ClaudioGUICore`'s public surface just for a test to consume.

@MainActor
func runPreviewFixturesSuites() {
    suite("PreviewFixtures.assertExhaustive() runs without crashing (compile-time guard sanity)") {
        PreviewFixtures.assertExhaustive()
        expect(true, "assertExhaustive() must return normally for the shipped fixtures")
    }

    // MARK: - OnboardingState: all 6 cases

    suite("PreviewFixtures.onboardingStates covers all 6 OnboardingState cases exactly") {
        expect(
            PreviewFixtures.onboardingStates.count == 6,
            "expected exactly 6 onboarding fixtures (one per case), got"
                + " \(PreviewFixtures.onboardingStates.count)")
        let labels = Set(PreviewFixtures.onboardingStates.map(onboardingStateLabel))
        expect(
            labels
                == [
                    "claudeCodeNotInstalled", "helperMissing", "settingsNotWritable",
                    "settingsParseFailure", "notInstalled", "installed",
                ],
            "onboardingStates must cover exactly the 6 OnboardingState cases, got \(labels)")
    }

    // MARK: - DropZoneState: idle/hover/success + a .reject for each of 6 reasons

    suite(
        "PreviewFixtures.dropZoneStates covers .idle/.hover/.success and every DropRejectionReason case"
    ) {
        let states = PreviewFixtures.dropZoneStates
        expect(states.contains(.idle), "dropZoneStates must include .idle")
        expect(states.contains(.hover), "dropZoneStates must include .hover")
        expect(
            states.contains { if case .success = $0 { return true } else { return false } },
            "dropZoneStates must include a .success case")

        let rejectReasonLabels = Set(
            states.compactMap { state -> String? in
                guard case .reject(let reason) = state else { return nil }
                return dropRejectionReasonLabel(reason)
            })
        expect(
            rejectReasonLabels
                == [
                    "oversize", "nonWhitelistFormat", "pathTraversal", "overDuration",
                    "overwritesBuiltin", "copyFailed",
                ],
            "dropZoneStates must include a .reject for every DropRejectionReason case, got"
                + " \(rejectReasonLabels)")
    }

    suite("PreviewFixtures.dropZoneStates' .success payload is exactly sampleImportedAudioFile") {
        guard case .success(let file) = PreviewFixtures.dropZoneStates.last else {
            expect(false, "the last dropZoneStates fixture must be .success(...)")
            return
        }
        expect(
            file == PreviewFixtures.sampleImportedAudioFile,
            "the gallery's .success frame must render the SAME ImportedAudioFile value this"
                + " suite (and any other consumer) reads from PreviewFixtures — single source,"
                + " not a second copy")
    }

    // MARK: - EventRow: CoverageState × enabled, every combination

    suite("PreviewFixtures.eventRows covers every CoverageState case × enabled (true and false)") {
        let combos = Set(
            PreviewFixtures.eventRows.map { row in
                "\(coverageStateLabel(row.coverage))-\(row.enabled)"
            })
        let expected: Set<String> = [
            "present-true", "present-false",
            "unmapped-true", "unmapped-false",
            "broken-true", "broken-false",
        ]
        expect(
            combos == expected,
            "eventRows must cover every CoverageState × enabled combination exactly, got \(combos)")
    }

    // MARK: - PackCard: PackCardState × isSelected, every combination

    suite("PreviewFixtures.packCards covers every PackCardState case × isSelected (true and false)") {
        let combos = Set(
            PreviewFixtures.packCards.map { card in
                "\(packCardStateLabel(card.state))-\(card.isSelected)"
            })
        let expected: Set<String> = [
            "complete-true", "complete-false",
            "partial-true", "partial-false",
            "broken-true", "broken-false",
        ]
        expect(
            combos == expected,
            "packCards must cover every PackCardState × isSelected combination exactly, got \(combos)"
        )
    }
}

/// Exhaustive over every ``OnboardingState`` case — no `default:` (test-only, mirrors
/// `OnboardingStateSuite.swift`'s own `debugLabel(for:)`).
private func onboardingStateLabel(_ state: OnboardingState) -> String {
    switch state {
    case .claudeCodeNotInstalled: "claudeCodeNotInstalled"
    case .helperMissing: "helperMissing"
    case .settingsNotWritable: "settingsNotWritable"
    case .settingsParseFailure: "settingsParseFailure"
    case .notInstalled: "notInstalled"
    case .installed: "installed"
    }
}

/// Exhaustive over every ``DropRejectionReason`` case — no `default:`.
private func dropRejectionReasonLabel(_ reason: DropRejectionReason) -> String {
    switch reason {
    case .oversize: "oversize"
    case .nonWhitelistFormat: "nonWhitelistFormat"
    case .pathTraversal: "pathTraversal"
    case .overDuration: "overDuration"
    case .overwritesBuiltin: "overwritesBuiltin"
    case .copyFailed: "copyFailed"
    }
}

/// Exhaustive over every ``CoverageState`` case — no `default:`.
private func coverageStateLabel(_ state: CoverageState) -> String {
    switch state {
    case .present: "present"
    case .unmapped: "unmapped"
    case .broken: "broken"
    }
}

/// Exhaustive over every ``PackCardState`` case — no `default:`.
private func packCardStateLabel(_ state: PackCardState) -> String {
    switch state {
    case .complete: "complete"
    case .partial: "partial"
    case .broken: "broken"
    }
}
