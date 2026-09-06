import Darwin
import Foundation

/// The two user-visible windows supported by the local activity summary.
public enum LocalActivityRange: String, Codable, Sendable, CaseIterable {
    case today
    case sevenDays = "seven_days"
}

/// A stable key for one host surface and one public Claudio event.
public enum LocalActivityCounterKey {
    public static func make(host: HostID, event: Event) -> String {
        "\(host.rawValue):\(event.cliName)"
    }

    public static func split(_ key: String) -> (host: HostID, event: Event)? {
        let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2,
            let host = HostID(rawValue: parts[0]),
            let event = Event(cliName: parts[1])
        else { return nil }
        return (host, event)
    }
}

/// One local Gregorian calendar day. Unknown future host/event keys are retained on disk and
/// ignored only by the current projection.
public struct LocalActivityDayBucket: Codable, Sendable, Equatable {
    public let localDate: String
    public var counts: [String: UInt64]

    private enum CodingKeys: String, CodingKey {
        case localDate = "local_date"
        case counts
    }

    public init(localDate: String, counts: [String: UInt64] = [:]) {
        self.localDate = localDate
        self.counts = counts
    }

    public func count(host: HostID, event: Event) -> UInt64 {
        counts[LocalActivityCounterKey.make(host: host, event: event)] ?? 0
    }
}

/// The bounded, privacy-minimal on-disk summary. It contains no host payload, prompt, response,
/// project path, provider, token, or audio path.
public struct LocalActivitySummaryDocument: Codable, Sendable, Equatable {
    public static let currentSchema = 1

    public let schema: Int
    public let updatedAt: Date
    public let clearedAt: Date?
    public let clearedLocalDate: String?
    public var buckets: [LocalActivityDayBucket]

    private enum CodingKeys: String, CodingKey {
        case schema
        case updatedAt = "updated_at"
        case clearedAt = "cleared_at"
        case clearedLocalDate = "cleared_local_date"
        case buckets
    }

    public init(
        schema: Int = LocalActivitySummaryDocument.currentSchema,
        updatedAt: Date,
        clearedAt: Date? = nil,
        clearedLocalDate: String? = nil,
        buckets: [LocalActivityDayBucket] = []
    ) {
        self.schema = schema
        self.updatedAt = updatedAt
        self.clearedAt = clearedAt
        self.clearedLocalDate = clearedLocalDate
        self.buckets = buckets
    }

    public static func empty(now: Date = Date()) -> Self {
        Self(updatedAt: now)
    }
}

public enum LocalActivitySummaryReadState: Sendable, Equatable {
    case missing
    case ready(LocalActivitySummaryDocument)
    case unavailable
    case stale(LocalActivitySummaryDocument)
}

public struct LocalActivitySummaryReadResult: Sendable, Equatable {
    public let state: LocalActivitySummaryReadState

    public init(state: LocalActivitySummaryReadState) {
        self.state = state
    }
}

public enum LocalActivitySummaryStoreError: Error, Sendable, Equatable {
    case lockBusy
    case lockFailure
    case summaryMissing
    case summaryUnreadable
    case summaryDamaged
    case summaryOversize
    case pendingUnreadable
    case pendingOversize
    case directoryFailure
    case writeFailure
}

public enum LocalActivityRecordOutcome: Sendable, Equatable {
    case committed
    /// The hook did not wait for another writer. A private delta was durably staged instead.
    case deferred
    case staleInstallation
    case failed
}

public struct LocalActivityPendingDelta: Codable, Sendable, Equatable, Hashable {
    public static let currentSchema = 1

    public let schema: Int
    public let occurredAt: Date
    public let localDate: String
    public let host: HostID
    public let event: Event
    public let batchID: UUID?

    private enum CodingKeys: String, CodingKey {
        case schema
        case occurredAt = "occurred_at"
        case localDate = "local_date"
        case host
        case event
        case batchID = "batch_id"
    }

    public init(
        schema: Int = LocalActivityPendingDelta.currentSchema,
        occurredAt: Date,
        localDate: String,
        host: HostID,
        event: Event,
        batchID: UUID? = nil
    ) {
        self.schema = schema
        self.occurredAt = occurredAt
        self.localDate = localDate
        self.host = host
        self.event = event
        self.batchID = batchID
    }

    fileprivate func assigning(batchID: UUID?) -> Self {
        Self(
            schema: schema,
            occurredAt: occurredAt,
            localDate: localDate,
            host: host,
            event: event,
            batchID: batchID)
    }
}

/// The only disk adapter for the local activity summary. It deliberately has no in-memory cache;
/// Panel and Settings share the higher-level model, while this adapter remains a small, synchronous
/// cross-process fact writer suitable for the hook path.
public struct LocalActivitySummaryStore: Sendable {
    public static let maximumSummaryBytes = 64 * 1024
    public static let maximumPendingDeltaBytes = 1024
    public static let maximumPendingEntries = 4096
    public static let bucketCount = 7

    public let summaryFile: URL
    public let lockFile: URL
    public let pendingDirectory: URL

    private var pendingStageLockFile: URL {
        pendingDirectory.deletingLastPathComponent().appendingPathComponent(
            ".activity-pending-stage.lock")
    }

    public init(summaryFile: URL, lockFile: URL, pendingDirectory: URL) {
        self.summaryFile = summaryFile
        self.lockFile = lockFile
        self.pendingDirectory = pendingDirectory
    }

    public static var production: Self {
        Self(
            summaryFile: ClaudioPaths.activitySummaryFile,
            lockFile: ClaudioPaths.activityLockFile,
            pendingDirectory: ClaudioPaths.activityPendingDirectory)
    }

    /// Records an accepted callback. `activeInstallationID` is captured by the hook runner at
    /// the acceptance boundary; a mismatch is never staged as activity.
    public func record(
        host: HostID,
        event: Event,
        installationID: UUID,
        activeInstallationID: UUID?,
        occurredAt: Date,
        timeZone: TimeZone = .current,
        calendar: Calendar = LocalActivitySummaryStore.gregorianCalendar(timeZone: .current)
    ) -> LocalActivityRecordOutcome {
        guard HostCapabilityCatalog.binding(host: host, event: event)?.isAudibleCapability == true
        else { return .failed }
        guard installationID == activeInstallationID else { return .staleInstallation }
        let localDate = Self.localDate(for: occurredAt, timeZone: timeZone, calendar: calendar)
        let delta = LocalActivityPendingDelta(
            occurredAt: occurredAt,
            localDate: localDate,
            host: host,
            event: event)

        let locked = withNonBlockingLock(path: lockFile.path) {
            mergeAndPublish(
                newDeltas: [delta],
                now: occurredAt,
                timeZone: timeZone,
                calendar: calendar)
        }
        switch locked {
        case .ran(let result):
            return result ? .committed : stage(delta)
        case .skipped:
            return stage(delta)
        case .failed:
            return stage(delta)
        }
    }

    /// Reads and, when possible, merges pending deltas under the same activity lock. A caller
    /// that already has a successful snapshot can keep it and label a later failure stale.
    public func read(
        now: Date = Date(),
        timeZone: TimeZone = .current,
        calendar: Calendar? = nil
    ) -> LocalActivitySummaryReadResult {
        let resolvedCalendar = calendar ?? Self.gregorianCalendar(timeZone: timeZone)
        let locked = withNonBlockingLock(path: lockFile.path) {
            let mergeSucceeded = mergePendingAndPublishIfPossible(
                now: now,
                timeZone: timeZone,
                calendar: resolvedCalendar)
            let summary = readSummary()
            guard !mergeSucceeded else { return summary }
            // A readable old summary is still useful, but it is no longer a complete view when
            // pending deltas could not be consumed or published. Preserve it explicitly as stale
            // so the UI never presents old numbers as current.
            switch summary {
            case .ready(let document): return .stale(document)
            case .missing, .unavailable: return .unavailable
            case .stale: return summary
            }
        }
        switch locked {
        case .ran(let state): return LocalActivitySummaryReadResult(state: state)
        case .skipped, .failed:
            return LocalActivitySummaryReadResult(state: .unavailable)
        }
    }

    /// Clear is the only operation allowed to rebuild a damaged summary. It leaves receipts,
    /// activation markers, configuration and diagnostic logs untouched.
    public func clear(
        now: Date = Date(),
        timeZone: TimeZone = .current,
        calendar: Calendar? = nil
    ) -> Result<LocalActivitySummaryDocument, LocalActivitySummaryStoreError> {
        let resolvedCalendar = calendar ?? Self.gregorianCalendar(timeZone: timeZone)
        let localDate = Self.localDate(for: now, timeZone: timeZone, calendar: resolvedCalendar)
        let document = LocalActivitySummaryDocument(
            updatedAt: now,
            clearedAt: now,
            clearedLocalDate: localDate,
            buckets: [])
        let locked: LockedRun<LocalActivitySummaryDocument?> = withNonBlockingLock(
            path: lockFile.path
        ) {
            guard case .success(let pending) = readPendingEntries() else { return nil }
            let consumed = pending.filter { $0.delta.occurredAt <= now }
            let retained = pending.filter { $0.delta.occurredAt > now }
            let batchID = consumed.isEmpty ? nil : UUID()
            guard rewritePendingEntries(consumed, assigning: batchID),
                rewritePendingEntries(retained, assigning: nil)
            else { return nil }
            let data = encode(document: document, preserving: nil)
            guard publish(data, to: summaryFile, consumedPendingBatchID: batchID) else {
                return nil
            }
            if let batchID {
                let claimed = consumed.map {
                    PendingEntry(url: $0.url, delta: $0.delta.assigning(batchID: batchID))
                }
                if removePendingEntries(claimed, batchID: batchID) {
                    removeConsumedPendingBatchMarker(batchID, from: summaryFile)
                }
            }
            return document
        }
        switch locked {
        case .ran(.some(let published)): return .success(published)
        case .ran(.none): return .failure(.writeFailure)
        case .skipped: return .failure(.lockBusy)
        case .failed: return .failure(.lockFailure)
        }
    }

    public static func gregorianCalendar(timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }

    public static func localDate(
        for date: Date,
        timeZone: TimeZone,
        calendar: Calendar = LocalActivitySummaryStore.gregorianCalendar(timeZone: .current)
    ) -> String {
        var calendar = calendar
        calendar.timeZone = timeZone
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0)
    }

    public static func dateKeys(
        today: Date,
        timeZone: TimeZone,
        calendar: Calendar? = nil
    ) -> [String] {
        var calendar = calendar ?? gregorianCalendar(timeZone: timeZone)
        calendar.timeZone = timeZone
        let start = calendar.startOfDay(for: today)
        return (0..<bucketCount).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: start) else {
                return nil
            }
            return localDate(for: date, timeZone: timeZone, calendar: calendar)
        }
    }

    // MARK: - Locked merge

    private func mergePendingAndPublishIfPossible(
        now: Date,
        timeZone: TimeZone,
        calendar: Calendar
    ) -> Bool {
        let pending = readPendingEntries()
        guard case .success(let entries) = pending else { return false }
        guard !entries.isEmpty else { return true }
        return mergeAndPublish(
            // `mergeAndPublish` reads the pending directory itself so record() can merge
            // the pending set with its new callback. Passing `entries` here as well would
            // count every deferred callback twice on the first successful read.
            newDeltas: [],
            now: now,
            timeZone: timeZone,
            calendar: calendar)
    }

    private func mergeAndPublish(
        newDeltas: [LocalActivityPendingDelta],
        now: Date,
        timeZone: TimeZone,
        calendar: Calendar
    ) -> Bool {
        let loaded = readRawSummary()
        let current: LocalActivitySummaryDocument
        let raw: [String: Any]?
        let consumedPendingBatchID: UUID?
        switch loaded {
        case .missing:
            current = LocalActivitySummaryDocument(updatedAt: now)
            raw = nil
            consumedPendingBatchID = nil
        case .ready(let document, let object, let batchID):
            current = document
            raw = object
            consumedPendingBatchID = batchID
        case .unavailable:
            return false
        }

        let pendingResult = readPendingEntries()
        guard case .success(let pending) = pendingResult,
            case .success(let pendingBatch) = preparePendingBatch(
                pending,
                consumedBatchID: consumedPendingBatchID)
        else { return false }
        let mergedDeltas = (pendingBatch?.entries.map(\.delta) ?? []) + newDeltas
        let activeDeltas = mergedDeltas.filter { delta in
            guard let clearedAt = current.clearedAt else { return true }
            return delta.occurredAt > clearedAt
        }
        var buckets = Dictionary(
            uniqueKeysWithValues: current.buckets.map { ($0.localDate, $0.counts) })
        for delta in activeDeltas {
            var counts = buckets[delta.localDate, default: [:]]
            let key = LocalActivityCounterKey.make(host: delta.host, event: delta.event)
            counts[key] = Self.saturatingIncrement(counts[key] ?? 0)
            buckets[delta.localDate] = counts
        }
        let keys = Set(Self.dateKeys(today: now, timeZone: timeZone, calendar: calendar))
        let orderedBuckets =
            buckets
            .filter { keys.contains($0.key) }
            .sorted { $0.key < $1.key }
            .map { LocalActivityDayBucket(localDate: $0.key, counts: $0.value) }
        let next = LocalActivitySummaryDocument(
            schema: LocalActivitySummaryDocument.currentSchema,
            updatedAt: now,
            clearedAt: current.clearedAt,
            clearedLocalDate: current.clearedLocalDate,
            buckets: orderedBuckets)
        let encoded = encode(document: next, preserving: raw)
        guard encoded.count <= Self.maximumSummaryBytes,
            publish(
                encoded,
                to: summaryFile,
                consumedPendingBatchID: pendingBatch?.id)
        else {
            return false
        }
        if let pendingBatch,
            removePendingEntries(pendingBatch.entries, batchID: pendingBatch.id)
        {
            removeConsumedPendingBatchMarker(pendingBatch.id, from: summaryFile)
        }
        return true
    }

    private func stage(_ delta: LocalActivityPendingDelta) -> LocalActivityRecordOutcome {
        let stageLock = FileLock(path: pendingStageLockFile.path)
        guard stageLock.lock() == .acquired else { return .failed }
        defer { stageLock.unlock() }
        do {
            try ensurePrivateDirectoryTree(at: pendingDirectory)
            guard
                let entries = try? FileManager.default.contentsOfDirectory(
                    at: pendingDirectory,
                    includingPropertiesForKeys: nil,
                    options: []),
                entries.count < Self.maximumPendingEntries
            else { return .failed }
            let data = try JSONEncoder.activityEncoder.encode(delta)
            guard data.count <= Self.maximumPendingDeltaBytes else { return .failed }
            let destination = pendingDirectory.appendingPathComponent(
                "delta-\(UUID().uuidString).json")
            guard publish(data, to: destination) else { return .failed }
            return .deferred
        } catch {
            return .failed
        }
    }

    private enum RawSummary {
        case missing
        case ready(LocalActivitySummaryDocument, [String: Any], UUID?)
        case unavailable
    }

    private struct PendingEntry {
        let url: URL
        let delta: LocalActivityPendingDelta
    }

    private struct PendingBatch {
        let id: UUID
        let entries: [PendingEntry]
    }

    private func readSummary() -> LocalActivitySummaryReadState {
        switch readRawSummary() {
        case .missing: .missing
        case .ready(let document, _, _): .ready(document)
        case .unavailable: .unavailable
        }
    }

    private func readRawSummary() -> RawSummary {
        switch readRegularFileBounded(
            at: summaryFile,
            maxBytes: Self.maximumSummaryBytes,
            followSymlink: false)
        {
        case .success(let data):
            guard
                let object = try? JSONSerialization.jsonObject(with: data),
                let dictionary = object as? [String: Any],
                let document = decodeDocument(dictionary),
                case .success(let batchID) = readConsumedPendingBatchMarker(from: summaryFile)
            else { return .unavailable }
            return .ready(document, dictionary, batchID)
        case .unreadable, .notRegularFile, .oversize:
            var status = stat()
            if lstat(summaryFile.path, &status) != 0, errno == ENOENT { return .missing }
            return .unavailable
        }
    }

    private func readPendingEntries() -> Result<[PendingEntry], LocalActivitySummaryStoreError> {
        var status = stat()
        guard lstat(pendingDirectory.path, &status) == 0 else {
            return errno == ENOENT ? .success([]) : .failure(.pendingUnreadable)
        }
        guard status.st_mode & S_IFMT == S_IFDIR else { return .failure(.pendingUnreadable) }
        guard
            let names = try? FileManager.default.contentsOfDirectory(
                at: pendingDirectory,
                includingPropertiesForKeys: nil,
                options: []),
            names.count <= Self.maximumPendingEntries
        else { return .failure(.pendingOversize) }

        var entries: [PendingEntry] = []
        for url in names.sorted(by: { $0.path < $1.path }) {
            guard url.pathExtension == "json" else { continue }
            switch readRegularFileBounded(
                at: url,
                maxBytes: Self.maximumPendingDeltaBytes,
                followSymlink: false)
            {
            case .success(let data):
                guard
                    let delta = try? JSONDecoder.activityDecoder.decode(
                        LocalActivityPendingDelta.self, from: data),
                    delta.schema == LocalActivityPendingDelta.currentSchema,
                    Event.allCases.contains(delta.event),
                    HostID.productVisibleCases.contains(delta.host)
                else { return .failure(.pendingUnreadable) }
                entries.append(PendingEntry(url: url, delta: delta))
            case .oversize: return .failure(.pendingOversize)
            case .notRegularFile, .unreadable: return .failure(.pendingUnreadable)
            }
        }
        return .success(entries)
    }

    private func preparePendingBatch(
        _ entries: [PendingEntry],
        consumedBatchID: UUID?
    ) -> Result<PendingBatch?, LocalActivitySummaryStoreError> {
        var remaining = entries
        if let consumedBatchID {
            let consumed = remaining.filter { $0.delta.batchID == consumedBatchID }
            guard removePendingEntries(consumed, batchID: consumedBatchID) else {
                return .failure(.pendingUnreadable)
            }
            remaining.removeAll { $0.delta.batchID == consumedBatchID }
        }
        guard !remaining.isEmpty else { return .success(nil) }

        let existingBatchIDs = Set(remaining.compactMap(\.delta.batchID))
        let batchID = existingBatchIDs.sorted { $0.uuidString < $1.uuidString }.first ?? UUID()
        let selected = remaining.filter {
            $0.delta.batchID == nil || $0.delta.batchID == batchID
        }
        guard
            rewritePendingEntries(
                selected.filter { $0.delta.batchID == nil },
                assigning: batchID)
        else { return .failure(.writeFailure) }
        return .success(
            PendingBatch(
                id: batchID,
                entries: selected.map {
                    PendingEntry(url: $0.url, delta: $0.delta.assigning(batchID: batchID))
                }))
    }

    private func rewritePendingEntries(
        _ entries: [PendingEntry],
        assigning batchID: UUID?
    ) -> Bool {
        for entry in entries {
            guard
                let data = try? JSONEncoder.activityEncoder.encode(
                    entry.delta.assigning(batchID: batchID)),
                data.count <= Self.maximumPendingDeltaBytes,
                publish(
                    data,
                    to: entry.url,
                    stagingDirectory: pendingDirectory.deletingLastPathComponent())
            else { return false }
        }
        return true
    }

    private func removePendingEntries(_ entries: [PendingEntry], batchID: UUID) -> Bool {
        var removedEveryEntry = true
        for entry in entries {
            switch readRegularFileBounded(
                at: entry.url,
                maxBytes: Self.maximumPendingDeltaBytes,
                followSymlink: false)
            {
            case .success(let data):
                guard
                    let current = try? JSONDecoder.activityDecoder.decode(
                        LocalActivityPendingDelta.self,
                        from: data),
                    current.batchID == batchID
                else {
                    removedEveryEntry = false
                    continue
                }
                if unlink(entry.url.path) != 0, errno != ENOENT {
                    removedEveryEntry = false
                }
            case .unreadable:
                var status = stat()
                if lstat(entry.url.path, &status) == 0 || errno != ENOENT {
                    removedEveryEntry = false
                }
            case .notRegularFile, .oversize:
                removedEveryEntry = false
            }
        }
        return removedEveryEntry
    }

    private func decodeDocument(_ object: [String: Any]) -> LocalActivitySummaryDocument? {
        guard let schema = activityUnsignedInteger(object["schema"]),
            schema == UInt64(LocalActivitySummaryDocument.currentSchema),
            let updated = object["updated_at"] as? String,
            let updatedAt = activityISO8601Date(from: updated)
        else { return nil }
        let hasClearedAt = object["cleared_at"] != nil
        let hasClearedLocalDate = object["cleared_local_date"] != nil
        guard hasClearedAt == hasClearedLocalDate else { return nil }
        let clearedAt: Date?
        let clearedLocalDate: String?
        if hasClearedAt {
            guard let rawClearedAt = object["cleared_at"] as? String,
                let parsedClearedAt = activityISO8601Date(from: rawClearedAt),
                let rawClearedLocalDate = object["cleared_local_date"] as? String,
                isValidActivityLocalDate(rawClearedLocalDate)
            else { return nil }
            clearedAt = parsedClearedAt
            clearedLocalDate = rawClearedLocalDate
        } else {
            clearedAt = nil
            clearedLocalDate = nil
        }
        guard let rawBuckets = object["buckets"] as? [[String: Any]],
            rawBuckets.count <= Self.bucketCount
        else { return nil }
        var buckets: [LocalActivityDayBucket] = []
        for rawBucket in rawBuckets {
            guard let localDate = rawBucket["local_date"] as? String,
                isValidActivityLocalDate(localDate),
                !buckets.contains(where: { $0.localDate == localDate }),
                let rawCounts = rawBucket["counts"] as? [String: Any]
            else { return nil }
            var counts: [String: UInt64] = [:]
            for (key, value) in rawCounts {
                guard let number = activityUnsignedInteger(value) else {
                    return nil
                }
                counts[key] = number
            }
            buckets.append(LocalActivityDayBucket(localDate: localDate, counts: counts))
        }
        return LocalActivitySummaryDocument(
            schema: Int(schema),
            updatedAt: updatedAt,
            clearedAt: clearedAt,
            clearedLocalDate: clearedLocalDate,
            buckets: buckets)
    }

    private func encode(
        document: LocalActivitySummaryDocument,
        preserving object: [String: Any]?
    ) -> Data {
        var output = object ?? [:]
        output["schema"] = document.schema
        output["updated_at"] = activityISO8601String(from: document.updatedAt)
        if let clearedAt = document.clearedAt {
            output["cleared_at"] = activityISO8601String(from: clearedAt)
        } else {
            output.removeValue(forKey: "cleared_at")
        }
        if let clearedLocalDate = document.clearedLocalDate {
            output["cleared_local_date"] = clearedLocalDate
        } else {
            output.removeValue(forKey: "cleared_local_date")
        }
        let originalBuckets = (object?["buckets"] as? [[String: Any]]) ?? []
        let originalBucketsByDate = Dictionary(
            uniqueKeysWithValues: originalBuckets.compactMap { bucket -> (String, [String: Any])? in
                guard let localDate = bucket["local_date"] as? String else { return nil }
                return (localDate, bucket)
            })
        output["buckets"] = document.buckets.map { bucket in
            var outputBucket = originalBucketsByDate[bucket.localDate] ?? [:]
            outputBucket["local_date"] = bucket.localDate
            outputBucket["counts"] = bucket.counts.reduce(into: [String: Any]()) { result, entry in
                result[entry.key] = NSNumber(value: entry.value)
            }
            return outputBucket
        }
        return
            (try? JSONSerialization.data(
                withJSONObject: output, options: [.prettyPrinted, .sortedKeys]))
            ?? Data("{}".utf8)
    }

    private func publish(
        _ data: Data,
        to destination: URL,
        consumedPendingBatchID: UUID? = nil,
        stagingDirectory: URL? = nil
    ) -> Bool {
        let destinationDirectory = destination.deletingLastPathComponent()
        let stagingDirectory = stagingDirectory ?? destinationDirectory
        do {
            try ensurePrivateDirectoryTree(at: destinationDirectory)
            if stagingDirectory != destinationDirectory {
                try ensurePrivateDirectoryTree(at: stagingDirectory)
            }
        } catch { return false }
        var existing = stat()
        let inspected = lstat(destination.path, &existing)
        if inspected == 0 {
            guard existing.st_mode & S_IFMT == S_IFREG else { return false }
        } else {
            guard errno == ENOENT else { return false }
        }
        let templateURL = stagingDirectory.appendingPathComponent(
            ".\(destination.lastPathComponent).tmp-XXXXXX")
        var template = templateURL.path.utf8CString
        let descriptor = template.withUnsafeMutableBufferPointer { buffer in
            mkstemp(buffer.baseAddress!)
        }
        guard descriptor >= 0 else { return false }
        let stagingPath = template.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        var needsClose = true
        defer {
            if needsClose { _ = close(descriptor) }
            _ = unlink(stagingPath)
        }
        guard fchmod(descriptor, 0o600) == 0 else { return false }
        if let consumedPendingBatchID {
            let marker = Array(consumedPendingBatchID.uuidString.utf8)
            let marked = pendingBatchMarkerName.withCString { name in
                marker.withUnsafeBytes { bytes in
                    fsetxattr(descriptor, name, bytes.baseAddress, bytes.count, 0, 0)
                }
            }
            guard marked == 0 else { return false }
        }
        var offset = 0
        while offset < data.count {
            let written = data.withUnsafeBytes { buffer in
                write(descriptor, buffer.baseAddress!.advanced(by: offset), data.count - offset)
            }
            guard written > 0 else { return false }
            offset += written
        }
        guard fsync(descriptor) == 0, close(descriptor) == 0 else {
            needsClose = false
            return false
        }
        needsClose = false
        return rename(stagingPath, destination.path) == 0
    }

    private func readConsumedPendingBatchMarker(
        from url: URL
    ) -> Result<UUID?, LocalActivitySummaryStoreError> {
        let size = url.path.withCString { path in
            pendingBatchMarkerName.withCString { name in
                getxattr(path, name, nil, 0, 0, XATTR_NOFOLLOW)
            }
        }
        if size < 0 {
            return errno == ENOATTR ? .success(nil) : .failure(.summaryUnreadable)
        }
        guard size > 0, size <= 64 else { return .failure(.summaryUnreadable) }
        var bytes = [UInt8](repeating: 0, count: size)
        let readCount = url.path.withCString { path in
            pendingBatchMarkerName.withCString { name in
                bytes.withUnsafeMutableBytes { buffer in
                    getxattr(path, name, buffer.baseAddress, buffer.count, 0, XATTR_NOFOLLOW)
                }
            }
        }
        guard readCount == size,
            let value = String(bytes: bytes, encoding: .utf8),
            let batchID = UUID(uuidString: value)
        else { return .failure(.summaryUnreadable) }
        return .success(batchID)
    }

    private func removeConsumedPendingBatchMarker(_ batchID: UUID, from url: URL) {
        guard case .success(let currentBatchID) = readConsumedPendingBatchMarker(from: url),
            currentBatchID == batchID
        else {
            return
        }
        _ = url.path.withCString { path in
            pendingBatchMarkerName.withCString { name in
                removexattr(path, name, XATTR_NOFOLLOW)
            }
        }
    }

    private static func saturatingIncrement(_ value: UInt64) -> UInt64 {
        value == UInt64.max ? value : value + 1
    }
}

private let pendingBatchMarkerName = "com.claudio.activity.pending-batch"

private func activityISO8601Formatter() -> ISO8601DateFormatter {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
}

private func activityISO8601String(from date: Date) -> String {
    activityISO8601Formatter().string(from: date)
}

private func activityISO8601Date(from string: String) -> Date? {
    if let fractional = activityISO8601Formatter().date(from: string) {
        return fractional
    }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: string)
}

private func activityUnsignedInteger(_ value: Any?) -> UInt64? {
    guard let number = value as? NSNumber,
        String(cString: number.objCType) != "c",
        number.doubleValue.isFinite,
        number.doubleValue >= 0
    else { return nil }
    let result = number.uint64Value
    return number.stringValue == String(result) ? result : nil
}

private func isValidActivityLocalDate(_ value: String) -> Bool {
    let pieces = value.split(separator: "-", omittingEmptySubsequences: false)
    guard pieces.count == 3,
        pieces[0].count == 4,
        pieces[1].count == 2,
        pieces[2].count == 2,
        let year = Int(pieces[0]),
        let month = Int(pieces[1]),
        let day = Int(pieces[2]),
        year > 0,
        (1...12).contains(month),
        (1...31).contains(day)
    else { return false }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day))
    else { return false }
    return calendar.component(.year, from: date) == year
        && calendar.component(.month, from: date) == month
        && calendar.component(.day, from: date) == day
}

extension JSONEncoder {
    fileprivate static var activityEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(activityISO8601String(from: date))
        }
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

extension JSONDecoder {
    fileprivate static var activityDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            guard let date = activityISO8601Date(from: value) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Invalid ISO-8601 activity date")
            }
            return date
        }
        return decoder
    }
}
