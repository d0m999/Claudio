import ClaudioCore
import ClaudioLocalization
import Combine
import Darwin
import Foundation

public enum UsageHistorySourceState: Sendable, Equatable {
    case available
    case missing
    case damaged(skippedItemCount: Int)
    case unreadable
}

public struct UsageHistorySourceSnapshot: Sendable, Equatable {
    public let host: HostID
    public let receipts: [HostHookReceipt]
    public let state: UsageHistorySourceState

    public init(
        host: HostID,
        receipts: [HostHookReceipt],
        state: UsageHistorySourceState
    ) {
        self.host = host
        self.receipts = receipts
        self.state = state
    }
}

public struct UsageLogFailureSummary: Sendable, Equatable {
    public let timestamp: Date
    public let event: Event?
    public let category: LogFailureCategory

    public init(timestamp: Date, event: Event?, category: LogFailureCategory) {
        self.timestamp = timestamp
        self.event = event
        self.category = category
    }
}

public enum UsageDiagnosticLogState: Sendable, Equatable {
    case available(sizeBytes: Int)
    case missing
    case damaged(sizeBytes: Int, skippedLineCount: Int)
    case unreadable
}

public struct UsageDiagnosticLogSnapshot: Sendable, Equatable {
    public let path: String
    public let state: UsageDiagnosticLogState
    public let failures: [UsageLogFailureSummary]

    public init(
        path: String,
        state: UsageDiagnosticLogState,
        failures: [UsageLogFailureSummary]
    ) {
        self.path = path
        self.state = state
        self.failures = failures
    }
}

public enum UsagePlaybackResultCategory: String, Sendable, Equatable, CaseIterable {
    case played
    case muted
    case debounced
    case failed

    fileprivate static func project(_ result: HostHookPlaybackResult) -> Self {
        switch result {
        case .played: .played
        case .muted: .muted
        case .debounced: .debounced
        case .notReady, .unsupportedEvent, .playbackFailed: .failed
        }
    }
}

public struct UsagePlaybackResultCount: Sendable, Equatable, Identifiable {
    public let result: UsagePlaybackResultCategory
    public let count: Int
    public var id: String { result.rawValue }

    public init(result: UsagePlaybackResultCategory, count: Int) {
        self.result = result
        self.count = count
    }
}

public struct UsageEventActivity: Sendable, Equatable, Identifiable {
    public let event: Event
    public let resultCounts: [UsagePlaybackResultCount]
    public var id: String { event.rawValue }

    public init(event: Event, resultCounts: [UsagePlaybackResultCount]) {
        self.event = event
        self.resultCounts = resultCounts
    }
}

public struct UsageSurfaceActivity: Sendable, Equatable, Identifiable {
    public let host: HostID
    public let retainedCount: Int
    public let events: [UsageEventActivity]
    public let sourceState: UsageHistorySourceState
    public var id: String { host.surfaceID.rawValue }

    public init(
        host: HostID,
        retainedCount: Int,
        events: [UsageEventActivity],
        sourceState: UsageHistorySourceState
    ) {
        self.host = host
        self.retainedCount = retainedCount
        self.events = events
        self.sourceState = sourceState
    }
}

public struct UsageProviderDisclosure: Sendable, Equatable, Identifiable {
    public let profileID: AICueProviderProfileID
    public let displayNameKey: ClaudioL10nKey
    public let regionID: String?
    public var id: AICueProviderProfileID { profileID }

    public init(profile: AICueProviderProfile) {
        profileID = profile.id
        displayNameKey = profile.displayNameKey
        regionID = profile.regionID
    }

    /// Mirrors the accepted allowlist in ADR-0006. These are disclosure identities, not activity
    /// records, credential status, provider responses, or inferred billing facts.
    public static var allowlisted: [UsageProviderDisclosure] {
        AICueProviderRegistry().profiles().map(UsageProviderDisclosure.init(profile:))
    }
}

public struct UsageActivityPresentation: Sendable, Equatable {
    public let surfaces: [UsageSurfaceActivity]
    public let log: UsageDiagnosticLogSnapshot
    public let providerDisclosures: [UsageProviderDisclosure]

    public init(
        surfaces: [UsageSurfaceActivity],
        log: UsageDiagnosticLogSnapshot,
        providerDisclosures: [UsageProviderDisclosure] = UsageProviderDisclosure.allowlisted
    ) {
        self.surfaces = surfaces
        self.log = log
        self.providerDisclosures = providerDisclosures
    }

    public static let empty = UsageActivityPresentation(
        surfaces: HostID.productVisibleCases.map {
            UsageSurfaceActivity(
                host: $0,
                retainedCount: 0,
                events: [],
                sourceState: .missing)
        },
        log: UsageDiagnosticLogSnapshot(path: "", state: .missing, failures: []))
}

public enum UsageActivityProjector {
    public static let retentionInterval = HostHookReceiptStore.historyRetention
    public static let retainedLimitPerSurface = HostHookReceiptStore.historyLimitPerSurface

    public static func project(
        historySources: [UsageHistorySourceSnapshot],
        log: UsageDiagnosticLogSnapshot,
        now: Date
    ) -> UsageActivityPresentation {
        let sourceByHost = Dictionary(
            historySources.map { ($0.host, $0) },
            uniquingKeysWith: { first, _ in first })
        let cutoff = now.addingTimeInterval(-retentionInterval)
        let surfaces = HostID.productVisibleCases.map { host -> UsageSurfaceActivity in
            let source = sourceByHost[host]
            let retained = (source?.receipts ?? [])
                .filter { receipt in
                    receipt.host == host
                        && receipt.timestamp >= cutoff
                        && receipt.timestamp <= now
                }
                .sorted { $0.timestamp > $1.timestamp }
                .prefix(retainedLimitPerSurface)
            let retainedReceipts = Array(retained)
            let events = Event.allCases.compactMap { event -> UsageEventActivity? in
                let eventReceipts = retainedReceipts.filter { $0.semanticEvent == event }
                guard !eventReceipts.isEmpty else { return nil }
                let counts = UsagePlaybackResultCategory.allCases.compactMap {
                    result -> UsagePlaybackResultCount? in
                    let count = eventReceipts.filter {
                        UsagePlaybackResultCategory.project($0.playbackResult) == result
                    }.count
                    return count == 0 ? nil : UsagePlaybackResultCount(result: result, count: count)
                }
                return UsageEventActivity(event: event, resultCounts: counts)
            }
            return UsageSurfaceActivity(
                host: host,
                retainedCount: retainedReceipts.count,
                events: events,
                sourceState: source?.state ?? .missing)
        }
        return UsageActivityPresentation(surfaces: surfaces, log: log)
    }
}

public enum UsageActivityStoreError: Error, Sendable, Equatable {
    case historyLockBusy
    case logLockBusy
    case lockFailure
    case historyClearFailure
    case logClearFailure
}

/// Disk adapter for the two facts the Usage page is allowed to inspect. It never reads config,
/// credentials, sound packs, generated candidates, host payloads, or provider responses.
public struct UsageActivityStore: Sendable {
    public static let maximumLogBytes = 1 << 20
    public static let maximumFailureSummaries = 5

    public let receiptStore: HostHookReceiptStore
    public let logFile: URL
    public let logLockFile: URL
    public let historyManagementLockFile: URL

    public init(
        receiptStore: HostHookReceiptStore,
        logFile: URL,
        logLockFile: URL,
        historyManagementLockFile: URL
    ) {
        self.receiptStore = receiptStore
        self.logFile = logFile
        self.logLockFile = logLockFile
        self.historyManagementLockFile = historyManagementLockFile
    }

    /// Production composition keeps all Usage disk ownership in one audited adapter. The app
    /// layer receives this store and never chooses or aliases a lock path of its own.
    public static func production() -> UsageActivityStore {
        UsageActivityStore(
            receiptStore: HostHookReceiptStore(
                receiptsRoot: ClaudioPaths.receiptsDirectory,
                locksRoot: ClaudioPaths.receiptLocksDirectory,
                installationsRoot: ClaudioPaths.activeInstallationsDirectory,
                installationLocksRoot: ClaudioPaths.activeInstallationLocksDirectory),
            logFile: ClaudioPaths.logFile,
            logLockFile: ClaudioPaths.logLockFile,
            historyManagementLockFile: ClaudioPaths.integrationsDirectory.appendingPathComponent(
                "receipt-history-management.lock"))
    }

    public func load(now: Date = Date()) -> UsageActivityPresentation {
        UsageActivityProjector.project(
            historySources: HostID.productVisibleCases.map {
                historySource(host: $0, now: now)
            },
            log: diagnosticLog(),
            now: now)
    }

    public func clearHistory() -> Result<Void, UsageActivityStoreError> {
        let locked = withNonBlockingLock(path: historyManagementLockFile.path) {
            switch receiptStore.clearReceiptHistory(hosts: HostID.productVisibleCases) {
            case .success:
                return Result<Void, UsageActivityStoreError>.success(())
            case .failure(.lockBusy):
                return .failure(.historyLockBusy)
            case .failure(.lockFailed):
                return .failure(.lockFailure)
            case .failure:
                return .failure(.historyClearFailure)
            }
        }
        switch locked {
        case .ran(let result): return result
        case .skipped: return .failure(.historyLockBusy)
        case .failed: return .failure(.lockFailure)
        }
    }

    public func clearLog() -> Result<Void, UsageActivityStoreError> {
        let locked = withNonBlockingLock(path: logLockFile.path) {
            guard Darwin.unlink(logFile.path) == 0 || errno == ENOENT else {
                return Result<Void, UsageActivityStoreError>.failure(.logClearFailure)
            }
            return Result<Void, UsageActivityStoreError>.success(())
        }
        switch locked {
        case .ran(let result): return result
        case .skipped: return .failure(.logLockBusy)
        case .failed: return .failure(.lockFailure)
        }
    }

    private func historySource(host: HostID, now: Date) -> UsageHistorySourceSnapshot {
        let snapshot = receiptStore.receiptHistorySnapshot(host: host, now: now)
        let state: UsageHistorySourceState =
            switch snapshot.state {
            case .available: .available
            case .missing: .missing
            case .damaged(let count): .damaged(skippedItemCount: count)
            case .unreadable: .unreadable
            }
        return UsageHistorySourceSnapshot(host: host, receipts: snapshot.receipts, state: state)
    }

    private func diagnosticLog() -> UsageDiagnosticLogSnapshot {
        let path = logFile.path
        switch readRegularFileBounded(
            at: logFile,
            maxBytes: Self.maximumLogBytes,
            followSymlink: false)
        {
        case .success(let data):
            let entries = parseRecentLogEntries(data, maxLines: Int.max)
            let totalLineCount = data.split(separator: UInt8(ascii: "\n")).count
            let skippedLineCount = max(0, totalLineCount - entries.count)
            let failures = entries.suffix(Self.maximumFailureSummaries).map { entry in
                UsageLogFailureSummary(
                    timestamp: entry.timestamp,
                    event: Event(cliName: entry.event),
                    category: entry.redactedFailureCategory)
            }
            let state: UsageDiagnosticLogState =
                skippedLineCount == 0
                ? .available(sizeBytes: data.count)
                : .damaged(sizeBytes: data.count, skippedLineCount: skippedLineCount)
            return UsageDiagnosticLogSnapshot(path: path, state: state, failures: failures)
        case .notRegularFile, .oversize:
            return UsageDiagnosticLogSnapshot(path: path, state: .unreadable, failures: [])
        case .unreadable:
            var status = stat()
            if lstat(path, &status) != 0, errno == ENOENT {
                return UsageDiagnosticLogSnapshot(path: path, state: .missing, failures: [])
            }
            return UsageDiagnosticLogSnapshot(path: path, state: .unreadable, failures: [])
        }
    }

}

public enum UsageSettingsAction: Sendable, Equatable, Hashable {
    case clearHistory
    case clearLog
    case revealLog
    case copyLogPath
}

public enum UsageSettingsFailure: Error, Sendable, Equatable {
    case historyLockBusy
    case logLockBusy
    case historyClearFailed
    case logClearFailed
    case finderFailed
    case clipboardFailed
}

public struct UsageSettingsFeedback: Sendable, Equatable {
    public let action: UsageSettingsAction
    public let failure: UsageSettingsFailure?

    public init(action: UsageSettingsAction, failure: UsageSettingsFailure?) {
        self.action = action
        self.failure = failure
    }
}

@MainActor
public struct UsageSettingsOperations {
    public let load: () async -> UsageActivityPresentation
    public let clearHistory: () async -> Result<UsageActivityPresentation, UsageSettingsFailure>
    public let clearLog: () async -> Result<UsageActivityPresentation, UsageSettingsFailure>
    public let revealLog: () -> Bool
    public let copyLogPath: () -> Bool

    public init(
        load: @escaping () async -> UsageActivityPresentation,
        clearHistory: @escaping () async -> Result<UsageActivityPresentation, UsageSettingsFailure>,
        clearLog: @escaping () async -> Result<UsageActivityPresentation, UsageSettingsFailure>,
        revealLog: @escaping () -> Bool,
        copyLogPath: @escaping () -> Bool
    ) {
        self.load = load
        self.clearHistory = clearHistory
        self.clearLog = clearLog
        self.revealLog = revealLog
        self.copyLogPath = copyLogPath
    }
}

@MainActor
public final class UsageSettingsModel: ObservableObject {
    @Published public private(set) var presentation: UsageActivityPresentation
    @Published public private(set) var isRefreshing = false
    @Published public private(set) var activeActions: Set<UsageSettingsAction> = []
    @Published public private(set) var feedback: UsageSettingsFeedback?

    private let operations: UsageSettingsOperations
    private var presentationRevision: UInt64 = 0

    public var isOperationActive: Bool {
        isRefreshing || !activeActions.isEmpty
    }

    public init(
        initialPresentation: UsageActivityPresentation = .empty,
        operations: UsageSettingsOperations
    ) {
        presentation = initialPresentation
        self.operations = operations
    }

    #if DEBUG
    public convenience init(
        previewPresentation: UsageActivityPresentation,
        isRefreshing: Bool = false,
        feedback: UsageSettingsFeedback? = nil
    ) {
        self.init(
            initialPresentation: previewPresentation,
            operations: UsageSettingsOperations(
                load: { previewPresentation },
                clearHistory: { .success(previewPresentation) },
                clearLog: { .success(previewPresentation) },
                revealLog: { true },
                copyLogPath: { true }))
        self.isRefreshing = isRefreshing
        self.feedback = feedback
    }
    #endif

    public func refresh() {
        guard !isOperationActive else { return }
        presentationRevision &+= 1
        let revision = presentationRevision
        isRefreshing = true
        Task { [weak self] in
            guard let self else { return }
            let presentation = await operations.load()
            if presentationRevision == revision {
                self.presentation = presentation
            }
            isRefreshing = false
        }
    }

    public func clearHistory() {
        performMutation(.clearHistory, operation: operations.clearHistory)
    }

    public func clearLog() {
        performMutation(.clearLog, operation: operations.clearLog)
    }

    public func revealLog() {
        guard !isOperationActive else { return }
        activeActions.insert(.revealLog)
        let succeeded = operations.revealLog()
        feedback = UsageSettingsFeedback(
            action: .revealLog,
            failure: succeeded ? nil : .finderFailed)
        activeActions.remove(.revealLog)
    }

    public func copyLogPath() {
        guard !isOperationActive else { return }
        activeActions.insert(.copyLogPath)
        let succeeded = operations.copyLogPath()
        feedback = UsageSettingsFeedback(
            action: .copyLogPath,
            failure: succeeded ? nil : .clipboardFailed)
        activeActions.remove(.copyLogPath)
    }

    public func dismissFeedback() {
        feedback = nil
    }

    private func performMutation(
        _ action: UsageSettingsAction,
        operation: @escaping () async -> Result<UsageActivityPresentation, UsageSettingsFailure>
    ) {
        guard !isOperationActive else { return }
        presentationRevision &+= 1
        let revision = presentationRevision
        activeActions.insert(action)
        Task { [weak self] in
            guard let self else { return }
            switch await operation() {
            case .success(let presentation):
                if presentationRevision == revision {
                    self.presentation = presentation
                    feedback = UsageSettingsFeedback(action: action, failure: nil)
                }
            case .failure(let failure):
                // Do not refresh after failure: the last successfully observed facts remain
                // visible until an explicit retry establishes a new snapshot.
                if presentationRevision == revision {
                    feedback = UsageSettingsFeedback(action: action, failure: failure)
                }
            }
            activeActions.remove(action)
        }
    }
}
