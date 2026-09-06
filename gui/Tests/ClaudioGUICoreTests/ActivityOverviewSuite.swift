import ClaudioCore
import ClaudioGUICore
import Foundation

@MainActor
func runActivityOverviewSuites() {
    suite("Activity projection shares event counts, message semantics and capability coverage") {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let timeZone = TimeZone(secondsFromGMT: 0)!
        let today = LocalActivitySummaryStore.dateKeys(today: now, timeZone: timeZone).first!
        let capabilities = previewActivityCapabilities()
        let document = LocalActivitySummaryDocument(
            updatedAt: now,
            buckets: [
                LocalActivityDayBucket(
                    localDate: today,
                    counts: [
                        LocalActivityCounterKey.make(host: .claudeCode, event: .taskStart): 2,
                        LocalActivityCounterKey.make(host: .claudeCode, event: .stop): 3,
                        LocalActivityCounterKey.make(host: .codex, event: .taskStart): 4,
                        LocalActivityCounterKey.make(host: .codex, event: .stop): 1,
                        LocalActivityCounterKey.make(host: .workBuddy, event: .subagentStop): 5,
                    ])
            ])
        let projection = ActivityOverviewProjector.project(
            document: document,
            readState: .ready,
            integrationStatuses: [:],
            now: now,
            timeZone: timeZone,
            capabilities: capabilities)

        expect(projection.global.todayMessages == 10,
            "Global messages must equal task_start + stop across supported hosts")
        expect(projection.surfaces[.codex]?.todayMessages == 5,
            "a Surface message total must not include another Surface")
        expect(projection.surfaces[.codex]?.event(.subagentStop)?.availability == .unsupported,
            "unsupported Surface events must remain unsupported rather than zero")
        expect(projection.global.event(.subagentStop)?.coverage.fractionText == "2/3",
            "Global coverage must show the real supporting Surface count")
        expect(projection.global.todaySubtasks == 5,
            "subtask count must remain a separate activity metric")
    }

    suite("Activity projection distinguishes unavailable, stale, partial and empty states") {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let timeZone = TimeZone(secondsFromGMT: 0)!
        let today = LocalActivitySummaryStore.dateKeys(today: now, timeZone: timeZone).first!
        let capabilities = previewActivityCapabilities()
        let document = LocalActivitySummaryDocument(
            updatedAt: now,
            clearedAt: now.addingTimeInterval(-60),
            clearedLocalDate: today,
            buckets: [LocalActivityDayBucket(localDate: today, counts: [:])])
        let partial = ActivityOverviewProjector.project(
            document: document,
            readState: .ready,
            integrationStatuses: [:],
            now: now,
            timeZone: timeZone,
            capabilities: capabilities)
        expect(partial.global.todayStatus == .partial(since: now.addingTimeInterval(-60)),
            "clear must mark the still-overlapping today range partial")

        let stale = ActivityOverviewProjector.project(
            document: document,
            readState: .stale(lastUpdated: document.updatedAt),
            integrationStatuses: [:],
            now: now,
            timeZone: timeZone,
            capabilities: capabilities)
        expect({
            if case .partial = stale.global.todayStatus { return true }
            return false
        }(), "partial takes precedence while the cleared date remains in range")

        let unavailable = ActivityOverviewProjector.project(
            document: nil,
            readState: .unavailable,
            integrationStatuses: [:],
            now: now,
            timeZone: timeZone,
            capabilities: capabilities)
        expect(unavailable.global.event(.stop)?.todayCount == nil,
            "unavailable summary must not manufacture zeroes")
        expect(unavailable.global.event(.stop)?.todayStatus == .unavailable,
            "unavailable summary must be explicit in the projection")
    }

    suite("Activity bar preserves stable order and minimum keyboard hit widths") {
        let segments = Event.allCases.map { event in
            ActivityOverviewBarSegment(
                event: event,
                availability: event == .taskStart || event == .stop ? .supported : .unsupported,
                todayCount: event == .taskStart || event == .stop ? 100 : nil,
                sevenDayCount: event == .taskStart || event == .stop ? 100 : nil)
        }
        let layouts = ActivityOverviewBarLayout.resolve(
            segments: segments,
            range: .today,
            availableWidth: 312)
        expect(layouts.map(\.event) == ActivityOverviewBarLayout.events,
            "the visible four slots must keep their public order")
        expect(layouts.allSatisfy { $0.width >= ActivityOverviewBarLayout.minimumTargetWidth },
            "every segment must preserve the minimum interactive target")
        expect(layouts.first?.availability == .supported && layouts[1].event == .stop,
            "the first two slots must be user initiated and response ended")
    }
}

private func previewActivityCapabilities() -> [HostID: [HostCapabilityBinding]] {
    Dictionary(uniqueKeysWithValues: HostID.productVisibleCases.map { host in
        let events: [Event]
        switch host {
        case .claudeCode: events = [.taskStart, .stop, .notification, .subagentStop]
        case .codex: events = [.taskStart, .stop, .notification]
        case .workBuddy: events = Event.allCases
        default: events = []
        }
        return (
            host,
            events.map {
                HostCapabilityBinding(
                    host: host,
                    event: $0,
                    nativeEvent: "native.\($0.cliName)",
                    support: .supported)
            })
    })
}
