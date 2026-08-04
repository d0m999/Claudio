import ClaudioCore
import Foundation

// MARK: - Event mapping: single source of truth (ENGINEERING.md 决议 · 指令)

@MainActor
func runEventSuites() {
    suite("事件协议固定为五个声音语义，任务开始排第一") {
        expect(Event.allCases.count == 5, "expected 5 events, got \(Event.allCases.count)")
        expect(
            Event.allCases.map(\.cliName)
                == ["task_start", "stop", "stop_failure", "notification", "subagent_stop"],
            "cliName set mismatch: \(Event.allCases.map(\.cliName))"
        )
        expect(Event.taskStart.displayName == "任务开始", "任务开始主文案")
        expect(Event.taskStart.settingsName == "UserPromptSubmit", "宿主映射只经 capability 暴露")
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

    suite("rawValue is pinned to cliName, never Swift's default camelCase derivation") {
        for event in Event.allCases {
            expect(
                event.rawValue == event.cliName,
                "rawValue must equal cliName (not a default-derived spelling like"
                    + " 'stopFailure'/'subagentStop'): \(event)")
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
        for name in ["SessionStart", "SessionEnd", "PreToolUse"] {
            expect(Event(settingsName: name) == nil, "reject settingsName: \(name)")
        }
        expect(Event(cliName: "session_start") == nil, "reject cliName: session_start")
    }
}
