import ClaudioCore
import Foundation

// Dependency-free test harness.
//
// This machine has CommandLineTools only (no Xcode), so `swift test` cannot resolve
// XCTest (absent) or Swift Testing (bundled but not exposed to SwiftPM / no macro
// plugin). These checks therefore run as a plain executable: `swift run claudio-tests`,
// exit 0 == green. Once a full Xcode is installed, move each `suite`/`expect` block
// into a `.testTarget` as `@Test` functions with `#expect` — the assertions map 1:1.
//
// `main.swift` is the only file allowed top-level executable statements, so it stays a
// thin orchestrator: shared `expect`/`suite` primitives + calls into per-area suite
// functions defined in sibling files (`EventSuite.swift`, `FileLockSuite.swift`,
// `DoctorSuite.swift`, `PathsSuite.swift`, `PlaySuite.swift`, `LogSuite.swift`,
// `HookStatusSuite.swift`), matching the project's "many small files" convention.

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

runEventSuites()
runFileLockSuites()
runDoctorSuites()
runSettingsInstallerSuites()
runPathsSuites()
runPlaySuites()
runLogSuites()
runHookStatusSuites()

// MARK: - Summary

print("")
if failures == 0 {
    print("✓ all \(totalChecks) checks passed")
    exit(0)
} else {
    print("✗ \(failures) of \(totalChecks) checks FAILED")
    exit(1)
}
