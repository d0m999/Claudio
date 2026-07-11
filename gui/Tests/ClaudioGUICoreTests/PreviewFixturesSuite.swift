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
    // Replaces the former `expect(true, ...)` tautology (T14 review 修复②), which could never
    // fail yet still counted as a check. `assertExhaustive()` now RETURNS the `family.case`
    // labels its four exhaustive `switch`es actually visited, so this compares that set against
    // the complete expected roster: a fixture array that stops covering one of its enum's cases
    // (a case whose `switch` branch exists but is never REACHED — which compiles perfectly)
    // turns this red.
    suite("PreviewFixtures.assertExhaustive() visits every case of all FIVE state families") {
        let visited = PreviewFixtures.assertExhaustive()
        let expected: Set<String> = [
            "onboarding.claudeCodeNotInstalled", "onboarding.helperMissing",
            "onboarding.settingsNotWritable", "onboarding.settingsParseFailure",
            "onboarding.notInstalled", "onboarding.installed",
            // T17 —— 第五族：CTA 动作自身的状态。少了它，「进行中的 CTA」与「失败的 CTA」这两个
            // 新视觉态**从来不会被任何一帧渲染**，而这条断言仍然全绿（因为 onboardingStates 依然
            // 完美覆盖它自己那六个 case）——正是 /ship 收口记录 ③ 那次翻车的形状。
            "onboardingAction.idle",
            "onboardingAction.running.takeOver", "onboardingAction.running.disconnect",
            "onboardingAction.failed.withDetail", "onboardingAction.failed.noDetail",
            "dropZone.idle", "dropZone.hover", "dropZone.success",
            "dropZone.reject.oversize", "dropZone.reject.nonWhitelistFormat",
            "dropZone.reject.pathTraversal", "dropZone.reject.overDuration",
            "dropZone.reject.overwritesBuiltin", "dropZone.reject.copyFailed",
            "coverage.present", "coverage.unmapped", "coverage.broken",
            "packCard.complete", "packCard.partial", "packCard.broken",
        ]
        expect(
            visited == expected,
            "the shipped fixtures must exercise every case of all five state families;"
                + " missing \(expected.subtracting(visited)), unexpected \(visited.subtracting(expected))"
        )
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

    // MARK: - EventRow: the SECOND axis — every Event (T14 review 修复①)
    //
    // `CoverageState × enabled` was the only axis anything pinned, and `Event` — the axis this
    // app is ABOUT — was never checked at all: the shipped fixtures used only stop/stopFailure/
    // notification, so SubagentStop's indigo glyph, its display name and its tile color were
    // rendered exactly zero times by the repo's "exhaustive visual truth source". Driven off
    // `Event.allCases` (compiler-synthesized), not a hand-written list, so a fifth event turns
    // this red without anyone needing to remember this file exists.

    suite("PreviewFixtures.eventRows covers every Event case (the gallery is the EXHAUSTIVE visual truth source — an unrendered event is an unreviewed event)") {
        let events = Set(PreviewFixtures.eventRows.map(\.event))
        expect(
            events == Set(Event.allCases),
            "eventRows must render every Event at least once; missing"
                + " \(Set(Event.allCases).subtracting(events).map(\.cliName).sorted())")
    }

    // MARK: - PackCard: PackCardState × isSelected, every combination — plus the 2×2 glyph grid's
    // own event axis (`PackGalleryView` renders Event.allCases on EVERY card, styled
    // present-or-absent, so each event must appear in BOTH styles across the fixture set).

    suite("PreviewFixtures.packCards' 2×2 glyph grid renders every Event in BOTH present and absent styles") {
        let present = PreviewFixtures.packCards.reduce(into: Set<Event>()) {
            $0.formUnion($1.presentEvents)
        }
        expect(
            present == Set(Event.allCases),
            "every event must appear PRESENT on at least one card (the .complete cards), missing"
                + " \(Set(Event.allCases).subtracting(present).map(\.cliName).sorted())")

        let absent = PreviewFixtures.packCards.reduce(into: Set<Event>()) { accumulated, card in
            accumulated.formUnion(Set(Event.allCases).subtracting(card.presentEvents))
        }
        expect(
            absent == Set(Event.allCases),
            "every event must appear ABSENT on at least one card (the .broken/.partial cards),"
                + " missing \(Set(Event.allCases).subtracting(absent).map(\.cliName).sorted())")
    }

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
