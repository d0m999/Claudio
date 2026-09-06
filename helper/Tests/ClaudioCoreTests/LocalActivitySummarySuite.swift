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

    suite("Local activity pending staging never waits for its quota lock") {
        withTempDirectory { root in
            let lockURL = root.appendingPathComponent("summary.lock")
            let pendingDirectory = root.appendingPathComponent("pending", isDirectory: true)
            let store = LocalActivitySummaryStore(
                summaryFile: root.appendingPathComponent("summary.json"),
                lockFile: lockURL,
                pendingDirectory: pendingDirectory)
            let activityLock = FileLock(path: lockURL.path)
            let stagingLock = FileLock(
                path: root.appendingPathComponent(".activity-pending-stage.lock").path)
            expect(activityLock.attemptLock() == .acquired, "test must hold the activity lock")
            expect(stagingLock.attemptLock() == .acquired, "test must hold the staging lock")

            let installation = UUID(uuidString: "22222222-2222-4222-8222-222222222227")!
            let started = DispatchSemaphore(value: 0)
            let completion = DispatchSemaphore(value: 0)
            let outcomes = LocalActivityOutcomeCollector()
            DispatchQueue.global().async {
                started.signal()
                outcomes.append(
                    store.record(
                        host: .claudeCode,
                        event: .stop,
                        installationID: installation,
                        activeInstallationID: installation,
                        occurredAt: Date(timeIntervalSince1970: 1_900_000_150)))
                completion.signal()
            }

            let workerStarted = started.wait(timeout: .now() + .seconds(1)) == .success
            expect(workerStarted, "test worker must start before measuring lock wait time")
            let returnedWithoutWaiting =
                workerStarted
                && completion.wait(timeout: .now() + .milliseconds(250)) == .success
            expect(
                returnedWithoutWaiting,
                "a contended staging quota lock must never block the host hook")
            stagingLock.unlock()
            if !returnedWithoutWaiting {
                _ = completion.wait(timeout: .now() + .seconds(1))
            }
            activityLock.unlock()
            expect(
                outcomes.snapshot == [.failed],
                "staging contention must fail closed without waiting for the lock")
        }
    }

    suite("Local activity host records defer existing pending backlog work") {
        withTempDirectory { root in
            let summary = root.appendingPathComponent("summary.json")
            let pendingDirectory = root.appendingPathComponent("pending", isDirectory: true)
            let store = LocalActivitySummaryStore(
                summaryFile: summary,
                lockFile: root.appendingPathComponent("summary.lock"),
                pendingDirectory: pendingDirectory)
            let installation = UUID(uuidString: "22222222-2222-4222-8222-222222222228")!
            let moment = Date(timeIntervalSince1970: 1_900_000_300)
            let timeZone = TimeZone(secondsFromGMT: 0)!
            let calendar = LocalActivitySummaryStore.gregorianCalendar(timeZone: timeZone)
            expect(
                store.record(
                    host: .claudeCode,
                    event: .stop,
                    installationID: installation,
                    activeInstallationID: installation,
                    occurredAt: moment,
                    timeZone: timeZone,
                    calendar: calendar) == .committed,
                "test must start with one committed activity fact")
            try? FileManager.default.createDirectory(
                at: pendingDirectory,
                withIntermediateDirectories: true)
            writePendingFixture(
                to: pendingDirectory.appendingPathComponent("delta-existing.json"),
                batchID: nil)

            expect(
                store.record(
                    host: .claudeCode,
                    event: .stop,
                    installationID: installation,
                    activeInstallationID: installation,
                    occurredAt: moment.addingTimeInterval(1),
                    timeZone: timeZone,
                    calendar: calendar) == .deferred,
                "the host hook must stage only its callback when a pending backlog exists")

            let pendingFiles =
                (try? FileManager.default.contentsOfDirectory(
                    at: pendingDirectory,
                    includingPropertiesForKeys: nil))?
                .filter { $0.pathExtension == "json" }
            expect(pendingFiles?.count == 2, "the hook must leave both pending deltas staged")
            expect(
                pendingFiles?.allSatisfy { url in
                    guard let data = try? Data(contentsOf: url),
                        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                    else { return false }
                    return object["batch_id"] == nil
                } == true,
                "the hook must not assign batch identity to the existing backlog")

            if case .ready(let document) = store.read(
                now: moment.addingTimeInterval(1),
                timeZone: timeZone,
                calendar: calendar
            ).state {
                expect(
                    document.buckets.first?.count(host: .claudeCode, event: .stop) == 3,
                    "the next read must merge each committed and deferred callback once")
            } else {
                expect(false, "the deferred backlog should merge on the next read")
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
            let clearedAt = Date(timeIntervalSince1970: 1_900_000_200.1231)
            let occurredAt = Date(timeIntervalSince1970: 1_900_000_200.1232)

            let clearResult = store.clear(now: clearedAt)
            expect(clearResult.isSuccess, "test must publish the clear boundary")
            if case .success(let document) = clearResult {
                expect(
                    document.buckets.isEmpty && document.clearedAt == clearedAt,
                    "clear should return the exact empty document that crossed the publish boundary"
                )
            }
            let clearedObject = (try? Data(contentsOf: store.summaryFile)).flatMap {
                try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
            }
            expect(
                (clearedObject?["updated_at"] as? String).flatMap(legacyActivityDate) != nil
                    && (clearedObject?["cleared_at"] as? String).flatMap(legacyActivityDate) != nil,
                "schema 1 summary timestamps must remain rollback-readable ISO-8601 strings")
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
            let stagedObject =
                (try? FileManager.default.contentsOfDirectory(
                    at: pendingDirectory,
                    includingPropertiesForKeys: nil))?
                .first(where: { $0.pathExtension == "json" })
                .flatMap { try? Data(contentsOf: $0) }
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            expect(
                (stagedObject?["occurred_at"] as? String).flatMap(legacyActivityDate) != nil,
                "schema 1 pending timestamps must remain rollback-readable ISO-8601 strings")
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

    suite("Local activity migrates numeric schema 1 timestamps back to compatible strings") {
        withTempDirectory { root in
            let summary = root.appendingPathComponent("summary.json")
            let pendingDirectory = root.appendingPathComponent("pending", isDirectory: true)
            try? FileManager.default.createDirectory(
                at: pendingDirectory,
                withIntermediateDirectories: true)
            let timeZone = TimeZone(secondsFromGMT: 0)!
            let calendar = LocalActivitySummaryStore.gregorianCalendar(timeZone: timeZone)
            let moment = Date(timeIntervalSince1970: 1_900_000_250.123_456)
            let localDate = LocalActivitySummaryStore.localDate(
                for: moment,
                timeZone: timeZone,
                calendar: calendar)
            let numericSummary: [String: Any] = [
                "schema": 1,
                "updated_at": NSNumber(value: moment.addingTimeInterval(-1).timeIntervalSince1970),
                "buckets": [],
            ]
            let numericPending: [String: Any] = [
                "schema": 1,
                "occurred_at": NSNumber(value: moment.timeIntervalSince1970),
                "local_date": localDate,
                "host": HostID.claudeCode.rawValue,
                "event": Event.stop.cliName,
            ]
            try? JSONSerialization.data(
                withJSONObject: numericSummary,
                options: [.sortedKeys]
            ).write(to: summary)
            try? JSONSerialization.data(
                withJSONObject: numericPending,
                options: [.sortedKeys]
            ).write(to: pendingDirectory.appendingPathComponent("numeric-delta.json"))
            let store = LocalActivitySummaryStore(
                summaryFile: summary,
                lockFile: root.appendingPathComponent("summary.lock"),
                pendingDirectory: pendingDirectory)

            if case .ready(let document) = store.read(
                now: moment,
                timeZone: timeZone,
                calendar: calendar
            ).state {
                expect(
                    document.buckets.first?.count(host: .claudeCode, event: .stop) == 1,
                    "numeric timestamps from the brief schema 1 regression must remain readable")
            } else {
                expect(false, "numeric schema 1 data should migrate on the next successful read")
            }
            let migrated = (try? Data(contentsOf: summary)).flatMap {
                try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
            }
            expect(
                (migrated?["updated_at"] as? String).flatMap(legacyActivityDate) != nil,
                "the migrated summary must restore the rollback-compatible string encoding")
        }
    }

    suite("Local activity pure reads migrate numeric schema 1 timestamps") {
        withTempDirectory { root in
            let summary = root.appendingPathComponent("summary.json")
            let moment = Date(timeIntervalSince1970: 1_900_000_260.123_456)
            let numericSummary: [String: Any] = [
                "schema": 1,
                "updated_at": NSNumber(value: moment.timeIntervalSince1970),
                "cleared_at": NSNumber(value: moment.addingTimeInterval(-1).timeIntervalSince1970),
                "cleared_local_date": "2030-03-17",
                "buckets": [],
                "future_top_level": ["kept": true],
            ]
            try? JSONSerialization.data(
                withJSONObject: numericSummary,
                options: [.sortedKeys]
            ).write(to: summary)
            let store = LocalActivitySummaryStore(
                summaryFile: summary,
                lockFile: root.appendingPathComponent("summary.lock"),
                pendingDirectory: root.appendingPathComponent("pending", isDirectory: true))

            if case .ready(let document) = store.read(now: moment).state {
                expect(
                    document.updatedAt == moment
                        && document.clearedAt == moment.addingTimeInterval(-1),
                    "a numeric schema 1 summary must remain readable without pending deltas")
            } else {
                expect(false, "a pure read should migrate a numeric schema 1 summary")
            }
            let migrated = (try? Data(contentsOf: summary)).flatMap {
                try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
            }
            expect(
                (migrated?["updated_at"] as? String).flatMap(legacyActivityDate) != nil
                    && (migrated?["cleared_at"] as? String).flatMap(legacyActivityDate) != nil,
                "pure reads must restore rollback-compatible schema 1 timestamp strings")
            expect(
                (migrated?["future_top_level"] as? [String: Any])?["kept"] as? Bool == true,
                "timestamp migration must preserve unknown top-level fields")
        }
    }

    suite("Local activity failed clear preserves a published batch without recounting") {
        withTempDirectory { root in
            let summaryDirectory = root.appendingPathComponent("summary", isDirectory: true)
            try? FileManager.default.createDirectory(
                at: summaryDirectory,
                withIntermediateDirectories: true)
            let summary = summaryDirectory.appendingPathComponent("activity.json")
            let pendingDirectory = root.appendingPathComponent("pending", isDirectory: true)
            let store = LocalActivitySummaryStore(
                summaryFile: summary,
                lockFile: root.appendingPathComponent("summary.lock"),
                pendingDirectory: pendingDirectory)
            let installation = UUID(uuidString: "22222222-2222-4222-8222-222222222229")!
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
            let consumedBatchID = UUID(uuidString: "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB")!
            writePendingFixture(
                to: pendingDirectory.appendingPathComponent("delta-consumed.json"),
                batchID: consumedBatchID)
            expect(
                setPendingBatchMarker(consumedBatchID, on: summary),
                "test must reproduce the summary-published cleanup-incomplete state")

            guard setFixtureACL(["+a", "everyone deny delete_child"], on: summaryDirectory) else {
                expect(false, "test must prevent replacement of the regular summary")
                return
            }
            defer { _ = setFixtureACL(["-N"], on: summaryDirectory) }
            expect(
                store.clear(now: moment.addingTimeInterval(10)).isSuccess == false,
                "test must force empty-summary publication to fail")
            let pendingAfterClear =
                (try? FileManager.default.contentsOfDirectory(
                    at: pendingDirectory,
                    includingPropertiesForKeys: nil))?
                .filter { $0.pathExtension == "json" }
            expect(
                pendingAfterClear?.count == 1,
                "failed clear must retain the published pending batch for crash recovery")
            expect(
                pendingBatchMarkerIsMissing(on: summary) == false,
                "failed clear must retain the old summary batch marker")
            _ = setFixtureACL(["-N"], on: summaryDirectory)

            if case .ready(let document) = store.read(now: moment.addingTimeInterval(10)).state {
                expect(
                    document.buckets.first?.count(host: .claudeCode, event: .stop) == 1,
                    "failed clear recovery must not replay the already published batch")
            } else {
                expect(false, "the old summary should remain readable after failed clear")
            }
        }
    }

    suite("Local activity failed clear preserves pending facts beside a damaged summary") {
        withTempDirectory { root in
            let summaryDirectory = root.appendingPathComponent("summary", isDirectory: true)
            try? FileManager.default.createDirectory(
                at: summaryDirectory,
                withIntermediateDirectories: true)
            let summary = summaryDirectory.appendingPathComponent("activity.json")
            writeFixture("{", to: summary)
            let pendingDirectory = root.appendingPathComponent("pending", isDirectory: true)
            try? FileManager.default.createDirectory(
                at: pendingDirectory,
                withIntermediateDirectories: true)
            let store = LocalActivitySummaryStore(
                summaryFile: summary,
                lockFile: root.appendingPathComponent("summary.lock"),
                pendingDirectory: pendingDirectory)
            let consumedBatchID = UUID(uuidString: "CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC")!
            writePendingFixture(
                to: pendingDirectory.appendingPathComponent("delta-consumed.json"),
                batchID: consumedBatchID)
            expect(
                setPendingBatchMarker(consumedBatchID, on: summary),
                "test must attach a valid batch marker to the damaged summary")

            guard setFixtureACL(["+a", "everyone deny delete_child"], on: summaryDirectory) else {
                expect(false, "test must prevent replacement of the damaged summary")
                return
            }
            defer { _ = setFixtureACL(["-N"], on: summaryDirectory) }
            let clearAt = Date(timeIntervalSince1970: 1_900_000_310)
            expect(
                store.clear(now: clearAt).isSuccess == false,
                "test must force damaged-summary replacement to fail")
            let pendingAfterFailure =
                (try? FileManager.default.contentsOfDirectory(
                    at: pendingDirectory,
                    includingPropertiesForKeys: nil))?
                .filter { $0.pathExtension == "json" }
            expect(
                pendingAfterFailure?.count == 1,
                "failed clear must not delete the only retryable activity fact")
            expect(
                pendingBatchMarkerIsMissing(on: summary) == false,
                "failed clear must leave the damaged summary marker untouched")

            _ = setFixtureACL(["-N"], on: summaryDirectory)
            expect(
                store.clear(now: clearAt).isSuccess,
                "the retained pending fact must allow a later clear retry to succeed")
            let pendingAfterRetry =
                (try? FileManager.default.contentsOfDirectory(
                    at: pendingDirectory,
                    includingPropertiesForKeys: nil))?
                .filter { $0.pathExtension == "json" }
            expect(
                pendingAfterRetry?.isEmpty == true,
                "successful clear retry should reclaim its pre-boundary pending fact")
            expect(
                pendingBatchMarkerIsMissing(on: summary),
                "successful clear retry should replace the damaged marker-bearing summary")
        }
    }

    suite("Local activity reads stay ready when cleared pending cleanup is denied") {
        withTempDirectory { root in
            let summary = root.appendingPathComponent("summary.json")
            let pendingDirectory = root.appendingPathComponent("pending", isDirectory: true)
            try? FileManager.default.createDirectory(
                at: pendingDirectory,
                withIntermediateDirectories: true)
            writePendingFixture(
                to: pendingDirectory.appendingPathComponent("delta-before-clear.json"),
                batchID: nil,
                occurredAt: "2030-03-17T17:51:40Z",
                localDate: "2030-03-17")
            let store = LocalActivitySummaryStore(
                summaryFile: summary,
                lockFile: root.appendingPathComponent("summary.lock"),
                pendingDirectory: pendingDirectory)

            guard setFixtureACL(["+a", "everyone deny delete_child"], on: pendingDirectory) else {
                expect(false, "test must prevent pending deletion and replacement")
                return
            }
            defer { _ = setFixtureACL(["-N"], on: pendingDirectory) }
            let clearAt = Date(timeIntervalSince1970: 1_900_000_310)
            expect(
                store.clear(now: clearAt).isSuccess,
                "clear may succeed after atomically publishing its boundary")
            let pendingAfterClear =
                (try? FileManager.default.contentsOfDirectory(
                    at: pendingDirectory,
                    includingPropertiesForKeys: nil))?
                .filter { $0.pathExtension == "json" }
            expect(
                pendingAfterClear?.count == 1,
                "the fixture must retain the pre-clear delta when cleanup is denied")

            if case .ready(let document) = store.read(now: clearAt.addingTimeInterval(1)).state {
                expect(
                    document.buckets.isEmpty,
                    "a retained pre-clear delta must be ignored without requiring a rewrite")
            } else {
                expect(false, "cleared pending cleanup failure must not make later reads stale")
            }

            expect(
                setFixtureACL(["-N"], on: pendingDirectory),
                "test must restore pending deletion access")
            _ = store.read(now: clearAt.addingTimeInterval(2))
            let pendingAfterRecovery =
                (try? FileManager.default.contentsOfDirectory(
                    at: pendingDirectory,
                    includingPropertiesForKeys: nil))?
                .filter { $0.pathExtension == "json" }
            expect(
                pendingAfterRecovery?.isEmpty == true,
                "a later read should reclaim ignored pending after deletion access returns")
        }
    }

    suite("Local activity clear retains post-boundary facts from a published batch") {
        withTempDirectory { root in
            let summary = root.appendingPathComponent("summary.json")
            let pendingDirectory = root.appendingPathComponent("pending", isDirectory: true)
            let store = LocalActivitySummaryStore(
                summaryFile: summary,
                lockFile: root.appendingPathComponent("summary.lock"),
                pendingDirectory: pendingDirectory)
            let installation = UUID(uuidString: "22222222-2222-4222-8222-222222222230")!
            let timeZone = TimeZone(secondsFromGMT: 0)!
            let calendar = LocalActivitySummaryStore.gregorianCalendar(timeZone: timeZone)
            let occurredAt = Date(timeIntervalSince1970: 1_900_000_320)
            let clearAt = occurredAt.addingTimeInterval(-10)
            let oldOccurredAt = clearAt.addingTimeInterval(-10)
            expect(
                store.record(
                    host: .claudeCode,
                    event: .stop,
                    installationID: installation,
                    activeInstallationID: installation,
                    occurredAt: oldOccurredAt,
                    timeZone: timeZone,
                    calendar: calendar) == .committed,
                "test must publish the pre-clear activity fact")
            expect(
                store.record(
                    host: .claudeCode,
                    event: .stop,
                    installationID: installation,
                    activeInstallationID: installation,
                    occurredAt: occurredAt,
                    timeZone: timeZone,
                    calendar: calendar) == .committed,
                "test must publish the future activity fact")

            try? FileManager.default.createDirectory(
                at: pendingDirectory,
                withIntermediateDirectories: true)
            let consumedBatchID = UUID(uuidString: "DDDDDDDD-DDDD-4DDD-8DDD-DDDDDDDDDDDD")!
            writePendingFixture(
                to: pendingDirectory.appendingPathComponent("delta-old.json"),
                batchID: consumedBatchID,
                localDate: "2030-03-17")
            writePendingFixture(
                to: pendingDirectory.appendingPathComponent("delta-future.json"),
                batchID: consumedBatchID,
                occurredAt: "2030-03-17T17:52:00Z",
                localDate: "2030-03-17")
            expect(
                setPendingBatchMarker(consumedBatchID, on: summary),
                "test must reproduce a published batch awaiting cleanup")

            expect(
                store.clear(now: clearAt, timeZone: timeZone, calendar: calendar).isSuccess,
                "clear should publish its earlier boundary")
            let pendingAfterClear =
                (try? FileManager.default.contentsOfDirectory(
                    at: pendingDirectory,
                    includingPropertiesForKeys: nil))?
                .filter { $0.pathExtension == "json" }
            expect(
                pendingAfterClear?.count == 1,
                "clear must retain a published delta later than its boundary")

            if case .ready(let document) = store.read(
                now: occurredAt,
                timeZone: timeZone,
                calendar: calendar
            ).state {
                expect(
                    document.buckets.first?.count(host: .claudeCode, event: .stop) == 1,
                    "the retained post-clear delta must be counted exactly once")
            } else {
                expect(false, "the retained post-clear delta should remain readable")
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
            let timeZone = TimeZone(secondsFromGMT: 0)!
            let calendar = LocalActivitySummaryStore.gregorianCalendar(timeZone: timeZone)
            expect(
                store.record(
                    host: .claudeCode,
                    event: .stop,
                    installationID: installation,
                    activeInstallationID: installation,
                    occurredAt: moment,
                    timeZone: timeZone,
                    calendar: calendar) == .committed,
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

            if case .ready(let document) = store.read(
                now: moment,
                timeZone: timeZone,
                calendar: calendar
            ).state {
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

private func legacyActivityDate(from string: String) -> Date? {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fractional.date(from: string) {
        return date
    }
    let wholeSeconds = ISO8601DateFormatter()
    wholeSeconds.formatOptions = [.withInternetDateTime]
    return wholeSeconds.date(from: string)
}

private let pendingBatchMarkerName = "com.claudio.activity.pending-batch"

private func pendingFixtureData(
    batchID: UUID?,
    occurredAt: String = "2030-03-17T17:51:40Z",
    localDate: String = "2030-03-18"
) -> Data {
    var object: [String: Any] = [
        "schema": 1,
        "occurred_at": occurredAt,
        "local_date": localDate,
        "host": HostID.claudeCode.rawValue,
        "event": Event.stop.cliName,
    ]
    if let batchID {
        object["batch_id"] = batchID.uuidString
    }
    return try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}

private func writePendingFixture(
    to url: URL,
    batchID: UUID?,
    occurredAt: String = "2030-03-17T17:51:40Z",
    localDate: String = "2030-03-18"
) {
    try? pendingFixtureData(
        batchID: batchID,
        occurredAt: occurredAt,
        localDate: localDate
    ).write(to: url)
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

private func pendingBatchMarkerIsMissing(on url: URL) -> Bool {
    let size = url.path.withCString { path in
        pendingBatchMarkerName.withCString { name in
            getxattr(path, name, nil, 0, 0, XATTR_NOFOLLOW)
        }
    }
    return size < 0 && errno == ENOATTR
}

private func setFixtureACL(_ arguments: [String], on url: URL) -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/chmod")
    process.arguments = arguments + [url.path]
    do {
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    } catch {
        return false
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
