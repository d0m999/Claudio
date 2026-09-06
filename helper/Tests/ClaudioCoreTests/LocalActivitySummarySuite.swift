import ClaudioCore
import Foundation

@MainActor
func runLocalActivitySummarySuites() {
    suite("Local activity records only the accepted installation and keeps playback independent") {
        withTempDirectory { root in
            let store = LocalActivitySummaryStore(
                summaryFile: root.appendingPathComponent("summary.json"),
                lockFile: root.appendingPathComponent("summary.lock"),
                pendingDirectory: root.appendingPathComponent("pending", isDirectory: true))
            let installation = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
            let moment = Date(timeIntervalSince1970: 1_900_000_000)

            expect(
                store.record(
                    host: .workBuddy,
                    event: .taskStart,
                    installationID: installation,
                    activeInstallationID: installation,
                    occurredAt: moment) == .committed,
                "accepted callback should commit an activity fact")
            expect(
                store.record(
                    host: .workBuddy,
                    event: .stop,
                    installationID: UUID(),
                    activeInstallationID: installation,
                    occurredAt: moment) == .staleInstallation,
                "stale installation callback must never be staged")

            let readResult = store.read(now: moment)
            let document: LocalActivitySummaryDocument?
            if case .ready(let value) = readResult.state {
                document = value
            } else {
                document = nil
            }
            expect(document?.buckets.first?.count(host: .workBuddy, event: .taskStart) == 1,
                "accepted activity must be counted even without a playback result")
            expect(document?.buckets.first?.count(host: .workBuddy, event: .stop) == 0,
                "stale installation must not affect the summary")
            expect(
                store.record(
                    host: .workBuddy,
                    event: .notification,
                    installationID: installation,
                    activeInstallationID: installation,
                    occurredAt: moment) == .failed,
                "a declared but not implemented host capability must not count directly")
        }
    }

    suite("Local activity lock contention defers then merges without loss") {
        withTempDirectory { root in
            let lockURL = root.appendingPathComponent("summary.lock")
            let store = LocalActivitySummaryStore(
                summaryFile: root.appendingPathComponent("summary.json"),
                lockFile: lockURL,
                pendingDirectory: root.appendingPathComponent("pending", isDirectory: true))
            let installation = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
            let moment = Date(timeIntervalSince1970: 1_900_000_100)
            let lock = FileLock(path: lockURL.path)
            expect(lock.attemptLock() == .acquired, "test must hold the activity lock")
            expect(
                store.record(
                    host: .claudeCode,
                    event: .stop,
                    installationID: installation,
                    activeInstallationID: installation,
                    occurredAt: moment) == .deferred,
                "a busy hook lock must create a private pending delta")
            lock.unlock()

            let result = store.read(now: moment)
            if case .ready(let document) = result.state {
                expect(
                    document.buckets.first?.count(host: .claudeCode, event: .stop) == 1,
                    "the next successful read must merge the pending delta")
            } else {
                expect(false, "pending delta merge should produce a readable summary")
            }
        }
    }

    suite("Local activity uses Gregorian calendar dates and clear excludes late old callbacks") {
        let losAngeles = TimeZone(identifier: "America/Los_Angeles")!
        let calendar = LocalActivitySummaryStore.gregorianCalendar(timeZone: losAngeles)
        let beforeDST = calendar.date(from: DateComponents(
            calendar: calendar, timeZone: losAngeles, year: 2026, month: 3, day: 8,
            hour: 12))!
        let keys = LocalActivitySummaryStore.dateKeys(
            today: beforeDST,
            timeZone: losAngeles,
            calendar: calendar)
        expect(keys.count == LocalActivitySummaryStore.bucketCount, "seven-day window has seven dates")
        expect(keys.first == "2026-03-08" && keys[1] == "2026-03-07",
            "date subtraction must follow local calendar days across DST")

        withTempDirectory { root in
            let store = LocalActivitySummaryStore(
                summaryFile: root.appendingPathComponent("summary.json"),
                lockFile: root.appendingPathComponent("summary.lock"),
                pendingDirectory: root.appendingPathComponent("pending", isDirectory: true))
            let installation = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
            let old = beforeDST.addingTimeInterval(-3600)
            expect(store.record(
                host: .workBuddy, event: .stop, installationID: installation,
                activeInstallationID: installation, occurredAt: old,
                timeZone: losAngeles, calendar: calendar) == .committed,
                "test precondition: old callback records")
            let clearedAt = beforeDST
            expect(store.clear(now: clearedAt, timeZone: losAngeles, calendar: calendar).isSuccess,
                "clear should publish a fresh empty document")
            expect(store.record(
                host: .workBuddy, event: .stop, installationID: installation,
                activeInstallationID: installation, occurredAt: old,
                timeZone: losAngeles, calendar: calendar) == .committed,
                "late callback is handled without reviving pre-clear activity")
            let current = beforeDST.addingTimeInterval(1)
            expect(store.record(
                host: .workBuddy, event: .stop, installationID: installation,
                activeInstallationID: installation, occurredAt: current,
                timeZone: losAngeles, calendar: calendar) == .committed,
                "post-clear callback records normally")
            if case .ready(let document) = store.read(
                now: current, timeZone: losAngeles, calendar: calendar).state {
                expect(document.buckets.reduce(0) {
                    $0 + $1.count(host: .workBuddy, event: .stop)
                } == 1, "clear must discard only callbacks at or before clearedAt")
                expect(document.clearedLocalDate == "2026-03-08",
                    "clear retains the local calendar date for partial-range projection")
            } else {
                expect(false, "cleared summary should remain readable")
            }
        }
    }

    suite("Local activity clear fails closed on a summary symlink") {
        withTempDirectory { root in
            let summary = root.appendingPathComponent("summary.json")
            let target = root.appendingPathComponent("outside.json")
            writeFixture("outside", to: target)
            do {
                try FileManager.default.createSymbolicLink(at: summary, withDestinationURL: target)
            } catch {
                expect(false, "test fixture must create a summary symlink")
                return
            }
            let store = LocalActivitySummaryStore(
                summaryFile: summary,
                lockFile: root.appendingPathComponent("summary.lock"),
                pendingDirectory: root.appendingPathComponent("pending", isDirectory: true))
            expect(
                store.clear().isSuccess == false,
                "clear must not replace a symlink with an activity summary")
            expect(
                (try? FileManager.default.destinationOfSymbolicLink(atPath: summary.path))
                    == target.path,
                "the rejected symlink must remain untouched")
            expect(fixtureText(target) == "outside", "the symlink target must remain untouched")
        }
    }

    suite("Local activity clear fails closed on a non-regular summary node") {
        withTempDirectory { root in
            let summary = root.appendingPathComponent("summary.json", isDirectory: true)
            try? FileManager.default.createDirectory(at: summary, withIntermediateDirectories: false)
            let store = LocalActivitySummaryStore(
                summaryFile: summary,
                lockFile: root.appendingPathComponent("summary.lock"),
                pendingDirectory: root.appendingPathComponent("pending", isDirectory: true))
            expect(
                store.clear().isSuccess == false,
                "clear must not replace a directory with an activity summary")
            var isDirectory: ObjCBool = false
            expect(
                FileManager.default.fileExists(atPath: summary.path, isDirectory: &isDirectory)
                    && isDirectory.boolValue,
                "the rejected non-regular summary node must remain a directory")
        }
    }
}

private extension Result where Success == Void, Failure == LocalActivitySummaryStoreError {
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}

private func fixtureText(_ url: URL) -> String? {
    try? String(contentsOf: url, encoding: .utf8)
}
