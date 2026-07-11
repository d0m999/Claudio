import ClaudioGUICore
import Foundation

// MARK: - OnboardingState: pure value-type properties (T7)
//
// `OnboardingState` itself does no I/O and makes no decisions about *when* each case
// applies (that's `OnboardingDetectorSuite.swift`) — these tests only pin down the
// state → {header dot, app-self-error, accent} mappings T7's acceptance criteria are
// written against, independent of how a state was arrived at.

// Single-source (ENGINEERING.md T14 D1/D3): the exact same 6 states the state gallery
// (`ClaudioGUI/StateGalleryView.swift`) renders, not a second, independently-maintained
// hardcoded array — see `PreviewFixtures`'s own doc comment for why it's the one place
// every fixture state VALUE in this repo is constructed.
private let allSixStates: [OnboardingState] = PreviewFixtures.onboardingStates

@MainActor
func runOnboardingStateSuites() {
    suite("OnboardingState: exactly six cases exist (the T7 state machine's full surface)") {
        // Not a runtime-checkable count (Swift enums don't reflect case count without
        // `CaseIterable`), but every other suite in this file enumerates `allSixStates`
        // by hand — if a 7th case is ever added, the compiler forces every `switch` in
        // `OnboardingState.swift`/`OnboardingCopy.swift` to be updated (no `default:`
        // anywhere in this module), and this comment is the one place a human then also
        // needs to update `allSixStates` to keep these suites exhaustive.
        expect(allSixStates.count == 6, "sanity: this fixture must list exactly six states")
    }

    suite("showsHeaderTakenOverDot is true for .installed only (acceptance criterion 2)") {
        for state in allSixStates {
            let expected = (state == .installed)
            expect(
                state.showsHeaderTakenOverDot == expected,
                "showsHeaderTakenOverDot mismatch for \(state): expected \(expected)")
        }
    }

    suite("isAppSelfError is true for helperMissing/settingsNotWritable/settingsParseFailure only") {
        let expectedErrorStates: Set<String> = [
            "helperMissing", "settingsNotWritable", "settingsParseFailure",
        ]
        let actual: [(OnboardingState, Bool)] = allSixStates.map { ($0, $0.isAppSelfError) }
        for (state, isError) in actual {
            let label = debugLabel(for: state)
            expect(
                isError == expectedErrorStates.contains(label),
                "isAppSelfError mismatch for \(state) (label \(label)): got \(isError)")
        }
    }

    suite("accent: neutral/error/error/error/brand/success, matching DESIGN.md「错误态用色（关键约束）」exactly") {
        expect(OnboardingState.claudeCodeNotInstalled.accent == .neutral, "claudeCodeNotInstalled must be .neutral (non-blocking, DESIGN.md「错误态用色（关键约束）」)")
        expect(OnboardingState.helperMissing.accent == .error, "helperMissing must be .error (DESIGN.md「错误态用色（关键约束）」lists it alongside settings errors)")
        expect(OnboardingState.settingsNotWritable(reason: "x").accent == .error, "settingsNotWritable must be .error")
        expect(OnboardingState.settingsParseFailure(reason: "x").accent == .error, "settingsParseFailure must be .error")
        expect(OnboardingState.notInstalled.accent == .brand, "notInstalled must be .brand (actionable, not an error)")
        expect(OnboardingState.installed.accent == .success, "installed must be .success")
    }

    suite("Equatable: reason payloads participate in equality (not just the case)") {
        expect(
            OnboardingState.settingsNotWritable(reason: "a") != .settingsNotWritable(reason: "b"),
            "two settingsNotWritable states with different reasons must not be equal")
        expect(
            OnboardingState.settingsNotWritable(reason: "same")
                == .settingsNotWritable(reason: "same"),
            "two settingsNotWritable states with identical reasons must be equal")
        expect(
            OnboardingState.settingsParseFailure(reason: "a") != .settingsParseFailure(reason: "b"),
            "two settingsParseFailure states with different reasons must not be equal")
        expect(
            OnboardingState.claudeCodeNotInstalled != .helperMissing,
            "distinct cases without payloads must not be equal")
    }
}

/// Test-only debug label distinguishing the six cases by name, since `OnboardingState`
/// deliberately has no `CaseIterable`/raw-value conformance (it isn't a flat enum — two
/// cases carry a `reason` payload). Kept private to this file; production code never
/// needs a state → string mapping (that's what `onboardingCopy(for:)` is for).
private func debugLabel(for state: OnboardingState) -> String {
    switch state {
    case .claudeCodeNotInstalled: "claudeCodeNotInstalled"
    case .helperMissing: "helperMissing"
    case .settingsNotWritable: "settingsNotWritable"
    case .settingsParseFailure: "settingsParseFailure"
    case .notInstalled: "notInstalled"
    case .installed: "installed"
    }
}
