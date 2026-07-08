import ClaudioGUICore
import Foundation

// Dependency-free test harness — mirrors `helper/Tests/ClaudioCoreTests/main.swift`
// exactly (down to comment wording), for the same reason: this machine has
// CommandLineTools only (no Xcode), so `swift test` cannot resolve XCTest (absent) or
// Swift Testing (bundled but not exposed to SwiftPM / no macro plugin) here. Green
// signal: `swift run --package-path gui claudio-gui-tests`, exit 0.
//
// `main.swift` is the only file allowed top-level executable statements, so it stays a
// thin orchestrator: shared `expect`/`suite` primitives + calls into per-area suite
// functions defined in sibling files (`OnboardingStateSuite.swift`,
// `OnboardingCopySuite.swift`, `OnboardingDetectorSuite.swift`,
// `OnboardingViewModelSuite.swift`).

var totalChecks = 0
var failures = 0

@MainActor
func expect(
    _ condition: Bool,
    _ message: @autoclosure () -> String,
    file: StaticString = #file,
    line: UInt = #line
) {
    totalChecks += 1
    if !condition {
        failures += 1
        print("  ✗ \(message())  (\(file):\(line))")
    }
}

@MainActor
func suite(_ name: String, _ body: @MainActor () -> Void) {
    print("• \(name)")
    body()
}

runOnboardingStateSuites()
runOnboardingCopySuites()
runOnboardingDetectorSuites()
runOnboardingViewModelSuites()

// MARK: - Summary

print("")
if failures == 0 {
    print("✓ all \(totalChecks) checks passed")
    exit(0)
} else {
    print("✗ \(failures) of \(totalChecks) checks FAILED")
    exit(1)
}
