import ClaudioCore
import Darwin
import Dispatch
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
            expect(
                document?.buckets.first?.count(host: .workBuddy, event: .taskStart) == 1,
                "accepted activity must be counted even without a playback result")
            expect(
                document?.buckets.first?.count(host: .workBuddy, event: .stop) == 0,
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

    suite("Local activity pending timestamps preserve the post-clear subsecond boundary") {
        withTempDirectory { root in
            let lockURL = root.appendingPathComponent("summary.lock")
            let pendingDirectory = root.appendingPathComponent("pending", isDirectory: true)
            let store = LocalActivitySummaryStore(
                summaryFile: root.appendingPathComponent("summary.json"),
                lockFile: lockURL,
                pendingDirectory: pendingDirectory)
            let installation = UUID(uuidString: "22222222-2222-4222-8222-222222222223")!
            let clearedAt = Date(timeIntervalSince1970: 1_900_000_200.125)
            let occurredAt = Date(timeIntervalSince1970: 1_900_000_200.625)

            let clearResult = store.clear(now: clearedAt)
            expect(clearResult.isSuccess, "test must publish the clear boundary")
            if case .success(let document) = clearResult {
                expect(
                    document.buckets.isEmpty && document.clearedAt == clearedAt,
                    "clear should return the exact empty document that crossed the publish boundary"
                )
            }
            let held = FileLock(path: lockURL.path)
            expect(held.attemptLock() == .acquired, "test must hold the activity lock")
            expect(
                store.record(
                    host: .claudeCode,
                    event: .stop,
                    installationID: installation,
                    activeInstallationID: installation,
                    occurredAt: occurredAt) == .deferred,
                "a post-clear callback in the same second must be staged")
            held.unlock()

            if case .ready(let document) = store.read(now: occurredAt).state {
                expect(
                    document.buckets.first?.count(host: .claudeCode, event: .stop) == 1,
                    "fractional pending time must remain later than the fractional clear boundary")
            } else {
                expect(false, "the staged post-clear callback should merge")
            }
        }
    }

    suite("Local activity recovers a published pending batch by identity without recounting") {
        withTempDirectory { root in
            let summary = root.appendingPathComponent("summary.json")
            let pendingDirectory = root.appendingPathComponent("pending", isDirectory: true)
            let store = LocalActivitySummaryStore(
                summaryFile: summary,
                lockFile: root.appendingPathComponent("summary.lock"),
                pendingDirectory: pendingDirectory)
            let installation = UUID(uuidString: "22222222-2222-4222-8222-222222222224")!
            let moment = Date(timeIntervalSince1970: 1_900_000_300)
            expect(
                store.record(
                    host: .claudeCode,
                    event: .stop,
                    installationID: installation,
                    activeInstallationID: installation,
                    occurredAt: moment) == .committed,
                "test must publish the already-counted activity")

            try? FileManager.default.createDirectory(
                at: pendingDirectory,
                withIntermediateDirectories: true)
            let consumedBatchID = UUID(uuidString: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA")!
            writePendingFixture(
                to: pendingDirectory.appendingPathComponent("delta-consumed.json"),
                batchID: consumedBatchID)
            writePendingFixture(
                to: pendingDirectory.appendingPathComponent("delta-new-identical.json"),
                batchID: nil)
            expect(
                setPendingBatchMarker(consumedBatchID, on: summary),
                "test must reproduce the summary-published cleanup-incomplete state")

            if case .ready(let document) = store.read(now: moment).state {
                expect(
                    document.buckets.first?.count(host: .claudeCode, event: .stop) == 2,
                    "the committed identity must be skipped while the identical new file counts once"
                )
            } else {
                expect(false, "crash recovery should leave the summary readable")
            }
            let remaining = try? FileManager.default.contentsOfDirectory(
                at: pendingDirectory,
                includingPropertiesForKeys: nil)
            expect(
                remaining?.filter { $0.pathExtension == "json" }.isEmpty == true,
                "recovery should reclaim only the identities it has consumed")
        }
    }

    suite("Local activity pending staging enforces its hard limit under concurrency") {
        withTempDirectory { root in
            let lockURL = root.appendingPathComponent("summary.lock")
            let pendingDirectory = root.appendingPathComponent("pending", isDirectory: true)
            try? FileManager.default.createDirectory(
                at: pendingDirectory,
                withIntermediateDirectories: true)
            let fixture = pendingFixtureData(batchID: nil)
            for index in 0..<(LocalActivitySummaryStore.maximumPendingEntries - 1) {
                try? fixture.write(
                    to: pendingDirectory.appendingPathComponent("existing-\(index).json"))
            }
            let store = LocalActivitySummaryStore(
                summaryFile: root.appendingPathComponent("summary.json"),
                lockFile: lockURL,
                pendingDirectory: pendingDirectory)
            let held = FileLock(path: lockURL.path)
            expect(held.attemptLock() == .acquired, "test must hold the activity lock")
            let installation = UUID(uuidString: "22222222-2222-4222-8222-222222222225")!
            let outcomes = LocalActivityOutcomeCollector()
            DispatchQueue.concurrentPerform(iterations: 16) { offset in
                outcomes.append(
                    store.record(
                        host: .claudeCode,
                        event: .stop,
                        installationID: installation,
                        activeInstallationID: installation,
                        occurredAt: Date(timeIntervalSince1970: 1_900_000_400 + Double(offset))))
            }
            held.unlock()

            let entries = try? FileManager.default.contentsOfDirectory(
                at: pendingDirectory,
                includingPropertiesForKeys: nil)
            let snapshot = outcomes.snapshot
            expect(
                entries?.count == LocalActivitySummaryStore.maximumPendingEntries,
                "concurrent staging must never create entry 4097")
            expect(
                snapshot.filter { $0 == .deferred }.count == 1
                    && snapshot.filter { $0 == .failed }.count == 15,
                "only the one remaining pending slot may publish")
        }
    }

    suite("Local activity updates preserve unknown fields inside retained date buckets") {
        withTempDirectory { root in
            let summary = root.appendingPathComponent("summary.json")
            let timeZone = TimeZone(secondsFromGMT: 0)!
            let calendar = LocalActivitySummaryStore.gregorianCalendar(timeZone: timeZone)
            let moment = Date(timeIntervalSince1970: 1_900_000_500)
            let localDate = LocalActivitySummaryStore.localDate(
                for: moment,
                timeZone: timeZone,
                calendar: calendar)
            let counter = LocalActivityCounterKey.make(host: .claudeCode, event: .stop)
            let original: [String: Any] = [
                "schema": 1,
                "updated_at": "2030-03-17T17:55:00.000Z",
                "future_top_level": ["kept": true],
                "buckets": [
                    [
                        "local_date": localDate,
                        "counts": [counter: 1, "future-host:future-event": 9],
                        "future_bucket_flag": "keep-me",
                        "future_bucket_object": ["version": 2],
                    ],
                    [
                        "local_date": "2000-01-01",
                        "counts": [counter: 7],
                        "future_bucket_flag": "expired",
                    ],
                ],
            ]
            let originalData = try! JSONSerialization.data(
                withJSONObject: original,
                options: [.prettyPrinted, .sortedKeys])
            try? originalData.write(to: summary)
            let store = LocalActivitySummaryStore(
                summaryFile: summary,
                lockFile: root.appendingPathComponent("summary.lock"),
                pendingDirectory: root.appendingPathComponent("pending", isDirectory: true))
            let installation = UUID(uuidString: "22222222-2222-4222-8222-222222222226")!

            expect(
                store.record(
                    host: .claudeCode,
                    event: .stop,
                    installationID: installation,
                    activeInstallationID: installation,
                    occurredAt: moment,
                    timeZone: timeZone,
                    calendar: calendar) == .committed,
                "a normal update should publish the retained bucket")

            let publishedData = try? Data(contentsOf: summary)
            let published = publishedData.flatMap {
                try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
            }
            let buckets = published?["buckets"] as? [[String: Any]]
            let retained = buckets?.first { $0["local_date"] as? String == localDate }
            let counts = retained?["counts"] as? [String: Any]
            expect(
                (published?["future_top_level"] as? [String: Any])?["kept"] as? Bool == true,
                "top-level future fields must remain untouched")
            expect(
                retained?["future_bucket_flag"] as? String == "keep-me"
                    && (retained?["future_bucket_object"] as? [String: Any])?["version"] as? Int
                        == 2,
                "same-date bucket future fields must survive a normal count update")
            expect(
                activityFixtureUnsignedInteger(counts?[counter]) == 2
                    && activityFixtureUnsignedInteger(counts?["future-host:future-event"]) == 9,
                "owned and future count keys must both survive with the owned count incremented")
            expect(
                buckets?.contains { $0["local_date"] as? String == "2000-01-01" } == false,
                "an expired date must not revive merely to preserve its unknown fields")
        }
    }

    suite("Local activity uses Gregorian calendar dates and clear excludes late old callbacks") {
        let losAngeles = TimeZone(identifier: "America/Los_Angeles")!
        let calendar = LocalActivitySummaryStore.gregorianCalendar(timeZone: losAngeles)
        let beforeDST = calendar.date(
            from: DateComponents(
                calendar: calendar, timeZone: losAngeles, year: 2026, month: 3, day: 8,
                hour: 12))!
        let keys = LocalActivitySummaryStore.dateKeys(
            today: beforeDST,
            timeZone: losAngeles,
            calendar: calendar)
        expect(
            keys.count == LocalActivitySummaryStore.bucketCount, "seven-day window has seven dates")
        expect(
            keys.first == "2026-03-08" && keys[1] == "2026-03-07",
            "date subtraction must follow local calendar days across DST")

        withTempDirectory { root in
            let store = LocalActivitySummaryStore(
                summaryFile: root.appendingPathComponent("summary.json"),
                lockFile: root.appendingPathComponent("summary.lock"),
                pendingDirectory: root.appendingPathComponent("pending", isDirectory: true))
            let installation = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
            let old = beforeDST.addingTimeInterval(-3600)
            expect(
                store.record(
                    host: .workBuddy, event: .stop, installationID: installation,
                    activeInstallationID: installation, occurredAt: old,
                    timeZone: losAngeles, calendar: calendar) == .committed,
                "test precondition: old callback records")
            let clearedAt = beforeDST
            expect(
                store.clear(now: clearedAt, timeZone: losAngeles, calendar: calendar).isSuccess,
                "clear should publish a fresh empty document")
            expect(
                store.record(
                    host: .workBuddy, event: .stop, installationID: installation,
                    activeInstallationID: installation, occurredAt: old,
                    timeZone: losAngeles, calendar: calendar) == .committed,
                "late callback is handled without reviving pre-clear activity")
            let current = beforeDST.addingTimeInterval(1)
            expect(
                store.record(
                    host: .workBuddy, event: .stop, installationID: installation,
                    activeInstallationID: installation, occurredAt: current,
                    timeZone: losAngeles, calendar: calendar) == .committed,
                "post-clear callback records normally")
            if case .ready(let document) = store.read(
                now: current, timeZone: losAngeles, calendar: calendar
            ).state {
                expect(
                    document.buckets.reduce(0) {
                        $0 + $1.count(host: .workBuddy, event: .stop)
                    } == 1, "clear must discard only callbacks at or before clearedAt")
                expect(
                    document.clearedLocalDate == "2026-03-08",
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
            try? FileManager.default.createDirectory(
                at: summary, withIntermediateDirectories: false)
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

extension Result where Failure == LocalActivitySummaryStoreError {
    fileprivate var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}

private func fixtureText(_ url: URL) -> String? {
    try? String(contentsOf: url, encoding: .utf8)
}

private func activityFixtureUnsignedInteger(_ value: Any?) -> UInt64? {
    guard let number = value as? NSNumber else { return nil }
    return number.uint64Value
}

private let pendingBatchMarkerName = "com.claudio.activity.pending-batch"

private func pendingFixtureData(batchID: UUID?) -> Data {
    var object: [String: Any] = [
        "schema": 1,
        "occurred_at": "2030-03-17T17:51:40Z",
        "local_date": "2030-03-18",
        "host": HostID.claudeCode.rawValue,
        "event": Event.stop.cliName,
    ]
    if let batchID {
        object["batch_id"] = batchID.uuidString
    }
    return try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}

private func writePendingFixture(to url: URL, batchID: UUID?) {
    try? pendingFixtureData(batchID: batchID).write(to: url)
}

private func setPendingBatchMarker(_ batchID: UUID, on url: URL) -> Bool {
    let value = Array(batchID.uuidString.utf8)
    return url.path.withCString { path in
        pendingBatchMarkerName.withCString { name in
            value.withUnsafeBytes { bytes in
                setxattr(path, name, bytes.baseAddress, bytes.count, 0, XATTR_NOFOLLOW) == 0
            }
        }
    }
}

private final class LocalActivityOutcomeCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var outcomes: [LocalActivityRecordOutcome] = []

    func append(_ outcome: LocalActivityRecordOutcome) {
        lock.lock()
        outcomes.append(outcome)
        lock.unlock()
    }

    var snapshot: [LocalActivityRecordOutcome] {
        lock.lock()
        defer { lock.unlock() }
        return outcomes
    }
}
