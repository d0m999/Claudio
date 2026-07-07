import ClaudioCore
import Foundation

// Dependency-free test harness.
//
// This machine has CommandLineTools only (no Xcode), so `swift test` cannot resolve
// XCTest (absent) or Swift Testing (bundled but not exposed to SwiftPM / no macro
// plugin). These checks therefore run as a plain executable: `swift run claudio-tests`,
// exit 0 == green. Once a full Xcode is installed, move each `suite`/`expect` block
// into a `.testTarget` as `@Test` functions with `#expect` — the assertions map 1:1.

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

// MARK: - Event mapping: single source of truth (ENGINEERING.md 决议 · 指令)

suite("v1 has exactly the four core events") {
    expect(Event.allCases.count == 4, "expected 4 events, got \(Event.allCases.count)")
    expect(
        Set(Event.allCases.map(\.cliName))
            == ["stop", "stop_failure", "notification", "subagent_stop"],
        "cliName set mismatch: \(Event.allCases.map(\.cliName))"
    )
}

suite("settingsName / cliName round-trip, manifestKey == cliName") {
    for event in Event.allCases {
        expect(
            Event(settingsName: event.settingsName) == event, "settingsName round-trip: \(event)")
        expect(Event(cliName: event.cliName) == event, "cliName round-trip: \(event)")
        expect(event.manifestKey == event.cliName, "manifestKey == cliName: \(event)")
    }
}

suite("SubagentStop is never lowercased into subagentstop") {
    expect(Event.subagentStop.settingsName == "SubagentStop", "settingsName")
    expect(Event.subagentStop.cliName == "subagent_stop", "cliName")
    expect(
        Event(cliName: Event.subagentStop.settingsName.lowercased()) == nil,
        "lowercased 'SubagentStop' must not match a cliName"
    )
}

suite("StopFailure is mapped (verified real via spike, 决议 2)") {
    expect(Event(settingsName: "StopFailure") == .stopFailure, "StopFailure -> .stopFailure")
    expect(Event.stopFailure.cliName == "stop_failure", "stop_failure")
}

suite("non-core events (v2 / out of scope) are rejected") {
    for name in ["SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse"] {
        expect(Event(settingsName: name) == nil, "reject settingsName: \(name)")
    }
    expect(Event(cliName: "session_start") == nil, "reject cliName: session_start")
}

// MARK: - Summary

print("")
if failures == 0 {
    print("✓ all \(totalChecks) checks passed")
    exit(0)
} else {
    print("✗ \(failures) of \(totalChecks) checks FAILED")
    exit(1)
}
