import ClaudioCore
import Foundation

// MARK: - Event mapping: single source of truth (ENGINEERING.md 决议 · 指令)

@MainActor
func runEventSuites() {
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
                Event(settingsName: event.settingsName) == event,
                "settingsName round-trip: \(event)")
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
}
