import Darwin
import Foundation

public struct SharedRuntimeBootstrapProgress: Sendable, Equatable, Codable {
    public var copiedBinary: Bool
    public var copiedPacks: [String]
    public var salvaged: [SalvagedPack]
    public var packSelection: PackSelectionOutcome?

    public init(
        copiedBinary: Bool = false,
        copiedPacks: [String] = [],
        salvaged: [SalvagedPack] = [],
        packSelection: PackSelectionOutcome? = nil
    ) {
        self.copiedBinary = copiedBinary
        self.copiedPacks = copiedPacks
        self.salvaged = salvaged
        self.packSelection = packSelection
    }
}

public enum SharedRuntimeBootstrapExecution: Sendable, Equatable {
    case completed(SharedRuntimeBootstrapOutcome)
    case failed(error: SetupError, progress: SharedRuntimeBootstrapProgress)

    public var progress: SharedRuntimeBootstrapProgress {
        switch self {
        case .completed(let outcome):
            SharedRuntimeBootstrapProgress(
                copiedBinary: outcome.copiedBinary,
                copiedPacks: outcome.copiedPacks,
                salvaged: outcome.salvaged,
                packSelection: outcome.packSelection)
        case .failed(_, let progress): progress
        }
    }
}

public enum BootstrapReportEvent: Sendable, Equatable, Codable {
    case failure(code: String)
    case helperCopied(path: String)
    case packPublished(packID: String)
    case packSalvaged(packID: String, movedTo: String)
    case selectionChanged(removed: String?, selected: String)
}

public struct BootstrapReportRecord: Sendable, Equatable, Codable, Identifiable {
    public static let currentVersion = 1
    public let version: Int
    public let id: UUID
    public let createdAt: Date
    public var occurrenceCount: Int
    public var events: [BootstrapReportEvent]

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        occurrenceCount: Int = 1,
        events: [BootstrapReportEvent]
    ) {
        version = Self.currentVersion
        self.id = id
        self.createdAt = createdAt
        self.occurrenceCount = occurrenceCount
        self.events = events
    }

    var isPureFailure: Bool {
        !events.isEmpty && events.allSatisfy {
            if case .failure = $0 { return true }
            return false
        }
    }
}

public enum BootstrapReportStoreError: Error, Sendable, Equatable, CustomStringConvertible {
    case queueFull
    case unsafeRecord(path: String)
    case invalidRecord(path: String)
    case io(reason: String)

    public var description: String {
        switch self {
        case .queueFull: "有 32 条尚未确认的启动报告，请先在面板中确认后再重试"
        case .unsafeRecord(let path): "启动报告不是安全的普通文件：\(path)"
        case .invalidRecord(let path): "启动报告损坏或超过 64 KiB：\(path)"
        case .io(let reason): "启动报告存储失败：\(reason)"
        }
    }
}

public struct BootstrapReportStore: Sendable {
    public static let maximumRecordBytes = 64 * 1024
    public static let maximumPendingRecords = 32
    public let directory: URL

    public init(directory: URL = ClaudioPaths.bootstrapReportsDirectory) {
        self.directory = directory
    }

    public func records() throws -> [BootstrapReportRecord] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        try ensurePrivateDirectoryTree(at: directory)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".json") }
        return try names.map { name in
            let url = directory.appendingPathComponent(name)
            guard case .success(let data) = readRegularFileBounded(
                at: url, maxBytes: Self.maximumRecordBytes, followSymlink: false)
            else { throw BootstrapReportStoreError.invalidRecord(path: url.path) }
            guard let record = try? JSONDecoder().decode(BootstrapReportRecord.self, from: data),
                record.version == BootstrapReportRecord.currentVersion
            else { throw BootstrapReportStoreError.invalidRecord(path: url.path) }
            return record
        }.sorted { $0.createdAt < $1.createdAt }
    }

    public func ensureCapacity() throws {
        if try records().count >= Self.maximumPendingRecords {
            throw BootstrapReportStoreError.queueFull
        }
    }

    @discardableResult
    public func append(events: [BootstrapReportEvent]) throws -> BootstrapReportRecord? {
        try append(BootstrapReportRecord(events: events), mergingPureFailures: true)
    }

    /// Publishes a report whose identity is already durable elsewhere (the bootstrap journal).
    /// Repeating this call after a process dies between publication and journal removal returns
    /// the original record rather than consuming another queue slot or duplicating side effects.
    @discardableResult
    public func append(
        id: UUID,
        createdAt: Date,
        events: [BootstrapReportEvent]
    ) throws -> BootstrapReportRecord? {
        // A journal ID is durable identity, so this path must never collapse into an unrelated
        // pure-failure record. If publication succeeds and journal removal is interrupted, the
        // next replay must either find this exact ID or publish a distinct record with its own ID.
        try append(
            BootstrapReportRecord(id: id, createdAt: createdAt, events: events),
            mergingPureFailures: false)
    }

    private func append(
        _ candidate: BootstrapReportRecord,
        mergingPureFailures: Bool
    ) throws -> BootstrapReportRecord? {
        guard !candidate.events.isEmpty else { return nil }
        var existing = try records()
        if let persisted = existing.first(where: { $0.id == candidate.id }) {
            // UUIDs make a collision vanishingly unlikely, but accepting a different payload for
            // the same durable journal ID would hide facts. Fail closed instead.
            guard persisted.events == candidate.events else {
                throw BootstrapReportStoreError.invalidRecord(
                    path: directory.appendingPathComponent("\(candidate.id.uuidString).json").path)
            }
            return persisted
        }
        if mergingPureFailures,
            candidate.isPureFailure,
            let index = existing.lastIndex(where: {
                $0.isPureFailure && $0.events == candidate.events
            })
        {
            existing[index].occurrenceCount += 1
            try write(existing[index])
            return existing[index]
        }
        guard existing.count < Self.maximumPendingRecords else {
            throw BootstrapReportStoreError.queueFull
        }
        try write(candidate)
        return candidate
    }

    public func acknowledge(_ id: UUID) throws {
        try ensurePrivateDirectoryTree(at: directory)
        let url = directory.appendingPathComponent("\(id.uuidString).json")
        var status = stat()
        let inspected = url.withUnsafeFileSystemRepresentation { path in
            path.map { Darwin.lstat($0, &status) } ?? -1
        }
        guard inspected == 0, status.st_mode & S_IFMT == S_IFREG else {
            throw BootstrapReportStoreError.unsafeRecord(path: url.path)
        }
        guard unlink(url.path) == 0 else {
            throw BootstrapReportStoreError.io(
                reason: String(cString: strerror(errno)))
        }
    }

    /// Extends the matching bootstrap side-effect report with a later hook failure without
    /// replacing or duplicating irreversible facts. If publication of the earlier report did not
    /// succeed, a complete combined record is appended instead.
    @discardableResult
    public func appendFailure(
        code: String,
        preserving progressEvents: [BootstrapReportEvent]
    ) throws -> BootstrapReportRecord? {
        let failure = BootstrapReportEvent.failure(code: code)
        guard !progressEvents.isEmpty else { return try append(events: [failure]) }
        var existing = try records()
        if let index = existing.lastIndex(where: { $0.events == progressEvents }) {
            existing[index].events.insert(failure, at: 0)
            try write(existing[index])
            return existing[index]
        }
        return try append(events: [failure] + progressEvents)
    }

    private func write(_ record: BootstrapReportRecord) throws {
        try ensurePrivateDirectoryTree(at: directory)
        let data = try JSONEncoder().encode(record)
        guard data.count <= Self.maximumRecordBytes else {
            throw BootstrapReportStoreError.invalidRecord(path: record.id.uuidString)
        }
        let final = directory.appendingPathComponent("\(record.id.uuidString).json")
        try writePrivateAtomic(data, to: final)
    }
}

func writePrivateAtomic(_ data: Data, to final: URL) throws {
        try ensurePrivateDirectoryTree(at: final.deletingLastPathComponent())
        let staging = final.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).tmp-XXXXXX")
        var template = Array(staging.path.utf8CString)
        let fd = mkstemp(&template)
        guard fd >= 0 else {
            throw BootstrapReportStoreError.io(reason: String(cString: strerror(errno)))
        }
        let stagingPath = String(cString: template)
        var published = false
        defer {
            _ = close(fd)
            if !published { _ = unlink(stagingPath) }
        }
        guard fchmod(fd, 0o600) == 0 else {
            throw BootstrapReportStoreError.io(reason: String(cString: strerror(errno)))
        }
        let wrote = data.withUnsafeBytes { bytes -> Bool in
            var offset = 0
            while offset < bytes.count {
                let count = write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count <= 0 { return false }
                offset += count
            }
            return fsync(fd) == 0
        }
        guard wrote, rename(stagingPath, final.path) == 0 else {
            throw BootstrapReportStoreError.io(reason: String(cString: strerror(errno)))
        }
        published = true
}

private enum BootstrapJournalState: String, Codable {
    case inProgress
    case completed
    case failed
}

private struct BootstrapJournalRecord: Codable {
    let version: Int
    let id: UUID
    let startedAt: Date
    var state: BootstrapJournalState
    var events: [BootstrapReportEvent]
    /// Baseline captured before the journal is published and before bootstrap can mutate user
    /// content. Optional only so an older v1 journal can still fail closed with a generic report.
    let beforeHelperReady: Bool?
    let beforeEntries: [String]?
    let beforeSelection: PackSelectionStatus?
}

private func readJournal(at url: URL) -> BootstrapJournalRecord? {
    guard case .success(let data) = readRegularFileBounded(
        at: url, maxBytes: BootstrapReportStore.maximumRecordBytes, followSymlink: false)
    else { return nil }
    guard let journal = try? JSONDecoder().decode(BootstrapJournalRecord.self, from: data),
        journal.version == 1
    else { return nil }
    return journal
}

private func writeJournal(_ journal: BootstrapJournalRecord, at url: URL) throws {
    let data = try JSONEncoder().encode(journal)
    guard data.count <= BootstrapReportStore.maximumRecordBytes else {
        throw BootstrapReportStoreError.invalidRecord(path: url.path)
    }
    try writePrivateAtomic(data, to: url)
}

private func removeRegularFile(_ url: URL) throws {
    var status = stat()
    let inspected = url.withUnsafeFileSystemRepresentation { path in
        path.map { Darwin.lstat($0, &status) } ?? -1
    }
    if inspected != 0, errno == ENOENT { return }
    guard inspected == 0, status.st_mode & S_IFMT == S_IFREG else {
        throw BootstrapReportStoreError.unsafeRecord(path: url.path)
    }
    guard unlink(url.path) == 0 else {
        throw BootstrapReportStoreError.io(reason: String(cString: strerror(errno)))
    }
}

private func directoryEntryNames(_ directory: URL) -> Set<String> {
    Set((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
}

private func progressAfterFailure(
    environment: SetupEnvironment,
    beforeHelperReady: Bool,
    beforeEntries: Set<String>,
    beforeSelection: PackSelectionStatus
) -> SharedRuntimeBootstrapProgress {
    let afterEntries = directoryEntryNames(environment.userPacksDirectory)
    let added = afterEntries.subtracting(beforeEntries)
    let copied = added.filter { !$0.hasPrefix(".") && isSafePackID($0) }.sorted()
    let salvaged = added.filter { $0.hasPrefix(".") && $0.contains(".broken-") }.sorted().map {
        name in
        let suffix = name.dropFirst()
        let packID = suffix.components(separatedBy: ".broken-").first ?? String(suffix)
        return SalvagedPack(
            packID: packID,
            movedTo: environment.userPacksDirectory.appendingPathComponent(name).path)
    }
    var selection: PackSelectionOutcome?
    let afterSelection = packSelection(configFile: environment.configFile)
    if beforeSelection != afterSelection,
        case .selected(let selected) = afterSelection
    {
        let removed: String?
        if case .selected(let previous) = beforeSelection { removed = previous } else { removed = nil }
        selection = removed.map { .repairedDeadSelection(removed: $0, selected: selected) }
            ?? .selectedDefault(packID: selected)
    }
    return SharedRuntimeBootstrapProgress(
        copiedBinary: !beforeHelperReady
            && inspectSharedRuntimeHelper(at: environment.claudioBinaryDestination) == .ready,
        copiedPacks: copied,
        salvaged: salvaged,
        packSelection: selection)
}

/// The journal's own lock is deliberately separate from `packs.lock` and `settings.lock`: it
/// protects the larger recovery -> bootstrap -> report-publication protocol, not one individual
/// file mutation. Unlike `play`'s debounce lock, bootstrap waits for the active owner because a
/// skip would either lose setup work or misclassify a live journal as a crashed process.
private func withBootstrapJournalLock<T>(
    environment: SetupEnvironment,
    _ body: () -> T
) -> Result<T, BootstrapReportStoreError> {
    let journal = environment.bootstrapJournalFile
    let lockFile = journal.deletingLastPathComponent()
        .appendingPathComponent(".\(journal.lastPathComponent).lock")
    do {
        try ensurePrivateDirectoryTree(at: lockFile.deletingLastPathComponent())
    } catch {
        return .failure(.io(reason: "无法准备 bootstrap 锁目录：\(error)"))
    }
    let lock = FileLock(path: lockFile.path)
    switch lock.lock() {
    case .acquired:
        defer { lock.unlock() }
        return .success(body())
    case .busy:
        // `lock()` waits after its initial non-blocking probe, so this is unreachable. Keep a
        // fail-closed branch in case a future implementation grows an explicit cancellation path.
        return .failure(.io(reason: "bootstrap 锁在等待后仍处于忙碌状态"))
    case .failed(let code):
        return .failure(.io(reason: "无法获取 bootstrap 锁：\(String(cString: strerror(code)))"))
    }
}

/// Journaled bootstrap entry point used by the app/manager. The compatibility Result API remains
/// available for older CLI/tests, but new callers retain facts even when a later step fails.
public func performSharedRuntimeBootstrapExecution(
    environment: SetupEnvironment
) -> SharedRuntimeBootstrapExecution {
    switch withBootstrapJournalLock(environment: environment, {
        performSharedRuntimeBootstrapExecutionLocked(environment: environment)
    }) {
    case .success(let execution): return execution
    case .failure(let error):
        return .failed(
            error: .reportingUnavailable(reason: error.description),
            progress: SharedRuntimeBootstrapProgress())
    }
}

private func performSharedRuntimeBootstrapExecutionLocked(
    environment: SetupEnvironment
) -> SharedRuntimeBootstrapExecution {
    let store = BootstrapReportStore(directory: environment.bootstrapReportsDirectory)
    do {
        if let previous = readJournal(at: environment.bootstrapJournalFile) {
            if previous.state == .inProgress || !previous.events.isEmpty {
                var recoveryEvents = previous.events
                if recoveryEvents.isEmpty,
                    let beforeHelperReady = previous.beforeHelperReady,
                    let beforeEntries = previous.beforeEntries,
                    let beforeSelection = previous.beforeSelection
                {
                    let recoveredProgress = progressAfterFailure(
                        environment: environment,
                        beforeHelperReady: beforeHelperReady,
                        beforeEntries: Set(beforeEntries),
                        beforeSelection: beforeSelection)
                    let recoveredExecution = SharedRuntimeBootstrapExecution.failed(
                        error: .reportingUnavailable(reason: "interrupted_bootstrap"),
                        progress: recoveredProgress)
                    let sideEffectEvents = bootstrapReportEvents(
                        execution: recoveredExecution,
                        helperPath: environment.claudioBinaryDestination
                    ).dropFirst()
                    if !sideEffectEvents.isEmpty
                        || SystemSharedRuntimeBootstrapper(environment: environment).inspect()
                            != .ready
                    {
                        recoveryEvents = [.failure(code: "interrupted_bootstrap")]
                            + Array(sideEffectEvents)
                    }
                } else if recoveryEvents.isEmpty {
                    recoveryEvents = [.failure(code: "interrupted_bootstrap")]
                }
                if !recoveryEvents.isEmpty {
                    _ = try store.append(
                        id: previous.id,
                        createdAt: previous.startedAt,
                        events: recoveryEvents)
                }
            }
            try removeRegularFile(environment.bootstrapJournalFile)
        } else if FileManager.default.fileExists(atPath: environment.bootstrapJournalFile.path) {
            throw BootstrapReportStoreError.invalidRecord(path: environment.bootstrapJournalFile.path)
        }
        // Reconcile an already-published final journal before checking capacity. A crash after
        // append but before unlink must be able to remove its journal even when it occupied the
        // last queue slot.
        try store.ensureCapacity()
    } catch {
        return .failed(
            error: .reportingUnavailable(reason: String(describing: error)),
            progress: SharedRuntimeBootstrapProgress())
    }

    let beforeHelperReady =
        inspectSharedRuntimeHelper(at: environment.claudioBinaryDestination) == .ready
    let beforeEntries = directoryEntryNames(environment.userPacksDirectory)
    let beforeSelection = packSelection(configFile: environment.configFile)
    var journal = BootstrapJournalRecord(
        version: 1,
        id: UUID(),
        startedAt: Date(),
        state: .inProgress,
        events: [],
        beforeHelperReady: beforeHelperReady,
        beforeEntries: beforeEntries.sorted(),
        beforeSelection: beforeSelection)
    do { try writeJournal(journal, at: environment.bootstrapJournalFile) } catch {
        return .failed(
            error: .reportingUnavailable(reason: String(describing: error)),
            progress: SharedRuntimeBootstrapProgress())
    }
    do { try environment.afterBootstrapJournalPersisted() } catch {
        // Deliberately retain the in-progress journal. A real process death has the same durable
        // state; the next launch reconciles it against disk before attempting any new mutation.
        return .failed(
            error: .reportingUnavailable(reason: String(describing: error)),
            progress: SharedRuntimeBootstrapProgress())
    }

    let execution: SharedRuntimeBootstrapExecution
    switch performSharedRuntimeBootstrap(environment: environment) {
    case .success(let outcome): execution = .completed(outcome)
    case .failure(let error):
        execution = .failed(
            error: error,
            progress: progressAfterFailure(
                environment: environment,
                beforeHelperReady: beforeHelperReady,
                beforeEntries: beforeEntries,
                beforeSelection: beforeSelection))
    }

    journal.state = {
        if case .completed = execution { return .completed }
        return .failed
    }()
    journal.events = bootstrapReportEvents(
        execution: execution, helperPath: environment.claudioBinaryDestination)
    do {
        try writeJournal(journal, at: environment.bootstrapJournalFile)
        _ = try store.append(
            id: journal.id,
            createdAt: journal.startedAt,
            events: journal.events)
        try environment.afterBootstrapReportPublished()
        try removeRegularFile(environment.bootstrapJournalFile)
    } catch {
        // Keep the final journal as the recovery source for the next launch. Never erase facts
        // merely because their report publication failed.
    }
    return execution
}

public func performFirstRunSetupExecution(
    environment: SetupEnvironment
) -> SharedRuntimeBootstrapExecution {
    let bootstrap = performSharedRuntimeBootstrapExecution(environment: environment)
    guard case .completed = bootstrap else { return bootstrap }
    switch installClaudioHooks(
        settingsFile: environment.settingsFile,
        claudioBinaryPath: environment.claudioBinaryDestination.path,
        lockFile: environment.settingsLockFile)
    {
    case .success:
        return bootstrap
    case .failure(let error):
        let failed = SharedRuntimeBootstrapExecution.failed(
            error: .installFailure(error), progress: bootstrap.progress)
        let store = BootstrapReportStore(directory: environment.bootstrapReportsDirectory)
        let progressEvents = bootstrapReportEvents(
            execution: bootstrap, helperPath: environment.claudioBinaryDestination)
        _ = try? store.appendFailure(
            code: bootstrapErrorCode(.installFailure(error)), preserving: progressEvents)
        return failed
    }
}

public func bootstrapErrorCode(_ error: SetupError) -> String {
    switch error {
    case .binaryCopyFailure: "binary_copy_failure"
    case .packsLockBusy: "packs_lock_busy"
    case .packsLockFailed: "packs_lock_failed"
    case .packCopyFailure: "pack_copy_failure"
    case .binaryQuarantined: "binary_quarantined"
    case .noAvailablePack: "no_available_pack"
    case .selectedPackUnresolvable: "selected_pack_unresolvable"
    case .configUnusable: "config_unusable"
    case .useFailure: "pack_selection_failure"
    case .installFailure: "host_hook_install_failure"
    case .reportingUnavailable: "bootstrap_reporting_unavailable"
    }
}

public func bootstrapReportEvents(
    execution: SharedRuntimeBootstrapExecution,
    helperPath: URL
) -> [BootstrapReportEvent] {
    var events: [BootstrapReportEvent] = []
    if case .failed(let error, _) = execution {
        events.append(.failure(code: bootstrapErrorCode(error)))
    }
    let progress = execution.progress
    if progress.copiedBinary { events.append(.helperCopied(path: helperPath.path)) }
    events.append(contentsOf: progress.copiedPacks.map { .packPublished(packID: $0) })
    events.append(contentsOf: progress.salvaged.map {
        .packSalvaged(packID: $0.packID, movedTo: $0.movedTo)
    })
    if let selection = progress.packSelection {
        switch selection {
        case .untouched: break
        case .selectedDefault(let packID):
            events.append(.selectionChanged(removed: nil, selected: packID))
        case .repairedDeadSelection(let removed, let selected):
            events.append(.selectionChanged(removed: removed, selected: selected))
        }
    }
    return events
}
