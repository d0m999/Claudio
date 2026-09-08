import ClaudioCore
import ClaudioLocalization
import Combine
import Foundation

/// The read state used by the shared activity projection.  A stale state always carries the
/// last successfully read document; callers never need to manufacture a second cache.
public enum ActivityOverviewReadState: Sendable, Equatable {
    case missing
    case ready
    case unavailable
    case stale(lastUpdated: Date)
}

public enum ActivityOverviewEventAvailability: Sendable, Equatable {
    case supported
    case unsupported
    case unavailable
}

public enum ActivityOverviewStatus: Sendable, Equatable {
    case ready
    case empty
    case unobserved
    case unavailable
    case stale(lastUpdated: Date)
    case partial(since: Date)
}

public enum ActivityIntegrationStatus: Sendable, Equatable {
    case connected
    case awaitingReceipt
    case notConnected
    case unavailable
}

public struct ActivityOverviewCoverage: Sendable, Equatable {
    public let supportedCount: Int
    public let totalCount: Int
    public let supportedHosts: [HostID]
    public let unsupportedHosts: [HostID]

    public init(
        supportedCount: Int,
        totalCount: Int,
        supportedHosts: [HostID],
        unsupportedHosts: [HostID]
    ) {
        self.supportedCount = supportedCount
        self.totalCount = totalCount
        self.supportedHosts = supportedHosts
        self.unsupportedHosts = unsupportedHosts
    }

    public var fractionText: String {
        "\(supportedCount)/\(totalCount)"
    }
}

public struct ActivityOverviewEventPresentation: Identifiable, Sendable, Equatable {
    public let event: Event
    public let availability: ActivityOverviewEventAvailability
    public let coverage: ActivityOverviewCoverage
    public let todayCount: UInt64?
    public let sevenDayCount: UInt64?
    public let todayStatus: ActivityOverviewStatus
    public let sevenDayStatus: ActivityOverviewStatus

    public var id: Event { event }

    public init(
        event: Event,
        availability: ActivityOverviewEventAvailability,
        coverage: ActivityOverviewCoverage,
        todayCount: UInt64?,
        sevenDayCount: UInt64?,
        todayStatus: ActivityOverviewStatus,
        sevenDayStatus: ActivityOverviewStatus
    ) {
        self.event = event
        self.availability = availability
        self.coverage = coverage
        self.todayCount = todayCount
        self.sevenDayCount = sevenDayCount
        self.todayStatus = todayStatus
        self.sevenDayStatus = sevenDayStatus
    }
}

public struct ActivityOverviewBarSegment: Identifiable, Sendable, Equatable {
    public let event: Event
    public let availability: ActivityOverviewEventAvailability
    public let todayCount: UInt64?
    public let sevenDayCount: UInt64?

    public var id: Event { event }

    public init(
        event: Event,
        availability: ActivityOverviewEventAvailability,
        todayCount: UInt64?,
        sevenDayCount: UInt64?
    ) {
        self.event = event
        self.availability = availability
        self.todayCount = todayCount
        self.sevenDayCount = sevenDayCount
    }

    public func count(for range: LocalActivityRange) -> UInt64? {
        switch range {
        case .today: todayCount
        case .sevenDays: sevenDayCount
        }
    }
}

public struct ActivityOverviewSegmentLayout: Identifiable, Sendable, Equatable {
    public let event: Event
    public let width: Double
    public let availability: ActivityOverviewEventAvailability
    public let count: UInt64?

    public var id: Event { event }

    public init(
        event: Event,
        width: Double,
        availability: ActivityOverviewEventAvailability,
        count: UInt64?
    ) {
        self.event = event
        self.width = width
        self.availability = availability
        self.count = count
    }
}

/// Resolves the four visible activity slots.  It owns the minimum hit width and spacing rule so
/// Panel and Settings cannot accidentally grow different bar geometries.  Zero-valued supported
/// events receive a hollow segment; unsupported/unavailable events retain a target but carry their
/// own state for the view to render as stripe/text.
public enum ActivityOverviewBarLayout {
    public static let events: [Event] = [.taskStart, .stop, .notification, .subagentStop]
    public static let minimumTargetWidth: Double = 29
    public static let visibleBarHeight: Double = 13

    public static func resolve(
        segments: [ActivityOverviewBarSegment],
        range: LocalActivityRange,
        availableWidth: Double,
        minimumTargetWidth: Double = Self.minimumTargetWidth,
        spacing: Double = 3
    ) -> [ActivityOverviewSegmentLayout] {
        let ordered = events.map { event in
            segments.first(where: { $0.event == event })
                ?? ActivityOverviewBarSegment(
                    event: event,
                    availability: .unavailable,
                    todayCount: nil,
                    sevenDayCount: nil)
        }
        let count = ordered.count
        guard count > 0 else { return [] }
        let totalSpacing = spacing * Double(max(0, count - 1))
        let usableWidth = max(0, availableWidth - totalSpacing)
        let minimumTotal = minimumTargetWidth * Double(count)
        let weights = ordered.map { segment -> Double in
            guard segment.availability == .supported else { return 1 }
            return max(1, Double(segment.count(for: range) ?? 0))
        }
        let totalWeight = weights.reduce(0, +)
        let remaining = max(0, usableWidth - minimumTotal)
        let widths: [Double]
        if remaining == 0 || totalWeight == 0 {
            widths = Array(
                repeating: max(minimumTargetWidth, usableWidth / Double(count)), count: count)
        } else {
            widths = weights.map { minimumTargetWidth + remaining * ($0 / totalWeight) }
        }
        return zip(ordered, widths).map { segment, width in
            ActivityOverviewSegmentLayout(
                event: segment.event,
                width: width,
                availability: segment.availability,
                count: segment.count(for: range))
        }
    }
}

public struct ActivityOverviewPresentation: Sendable, Equatable {
    public let scope: PanelSoundScopeID
    public let integrationStatus: ActivityIntegrationStatus?
    public let todayMessages: UInt64?
    public let sevenDayMessages: UInt64?
    public let todaySubtasks: UInt64?
    public let sevenDaySubtasks: UInt64?
    public let todayStatus: ActivityOverviewStatus
    public let sevenDayStatus: ActivityOverviewStatus
    public let eventRows: [ActivityOverviewEventPresentation]
    public let barSegments: [ActivityOverviewBarSegment]

    public init(
        scope: PanelSoundScopeID,
        integrationStatus: ActivityIntegrationStatus?,
        todayMessages: UInt64?,
        sevenDayMessages: UInt64?,
        todaySubtasks: UInt64?,
        sevenDaySubtasks: UInt64?,
        todayStatus: ActivityOverviewStatus,
        sevenDayStatus: ActivityOverviewStatus,
        eventRows: [ActivityOverviewEventPresentation],
        barSegments: [ActivityOverviewBarSegment]
    ) {
        self.scope = scope
        self.integrationStatus = integrationStatus
        self.todayMessages = todayMessages
        self.sevenDayMessages = sevenDayMessages
        self.todaySubtasks = todaySubtasks
        self.sevenDaySubtasks = sevenDaySubtasks
        self.todayStatus = todayStatus
        self.sevenDayStatus = sevenDayStatus
        self.eventRows = eventRows
        self.barSegments = barSegments
    }

    public func event(_ event: Event) -> ActivityOverviewEventPresentation? {
        eventRows.first(where: { $0.event == event })
    }
}

public struct ActivityOverviewProjection: Sendable, Equatable {
    public let global: ActivityOverviewPresentation
    public let surfaces: [HostID: ActivityOverviewPresentation]

    public init(
        global: ActivityOverviewPresentation,
        surfaces: [HostID: ActivityOverviewPresentation]
    ) {
        self.global = global
        self.surfaces = surfaces
    }

    public func presentation(for scope: PanelSoundScopeID) -> ActivityOverviewPresentation {
        switch scope {
        case .global: global
        case .surface(let surface):
            surfaces.first(where: { $0.key.surfaceID == surface })?.value
                ?? global
        }
    }
}

/// Foundation-only semantic seam shared by the menu-bar panel and Activity & Diagnostics.
/// It consumes the bounded activity document and the same capability catalog used by hooks; UI
/// callers never add counts or infer unsupported events from a missing number.
public enum ActivityOverviewProjector {
    public static func project(
        document: LocalActivitySummaryDocument?,
        readState: ActivityOverviewReadState,
        integrationStatuses: [HostID: ActivityIntegrationStatus],
        now: Date,
        timeZone: TimeZone,
        capabilities: [HostID: [HostCapabilityBinding]]
    ) -> ActivityOverviewProjection {
        let hosts = HostID.productVisibleCases
        let global = makePresentation(
            scope: .global,
            hosts: hosts,
            document: document,
            readState: readState,
            integrationStatuses: integrationStatuses,
            now: now,
            timeZone: timeZone,
            capabilities: capabilities)
        let surfaces = Dictionary(
            uniqueKeysWithValues: hosts.map { host in
                let scope = PanelSoundScopeID.surface(host.surfaceID)
                return (
                    host,
                    makePresentation(
                        scope: scope,
                        hosts: [host],
                        document: document,
                        readState: readState,
                        integrationStatuses: integrationStatuses,
                        now: now,
                        timeZone: timeZone,
                        capabilities: capabilities)
                )
            })
        return ActivityOverviewProjection(global: global, surfaces: surfaces)
    }

    public static func project(
        document: LocalActivitySummaryDocument?,
        readState: ActivityOverviewReadState,
        integrationStatuses: [HostID: ActivityIntegrationStatus],
        now: Date,
        timeZone: TimeZone
    ) -> ActivityOverviewProjection {
        project(
            document: document,
            readState: readState,
            integrationStatuses: integrationStatuses,
            now: now,
            timeZone: timeZone,
            capabilities: Dictionary(
                uniqueKeysWithValues: HostID.productVisibleCases.map {
                    ($0, HostCapabilityCatalog.bindings(for: $0))
                }))
    }

    public static func integrationStatus(
        from snapshot: HostIntegrationSnapshot
    ) -> ActivityIntegrationStatus {
        switch snapshot.runtime {
        case .unavailable, .damaged:
            return .unavailable
        case .ready:
            break
        }
        switch snapshot.configuration {
        case .notConfigured:
            return .notConnected
        case .unreadable, .conflict:
            return .unavailable
        case .legacyConnected, .configured, .incomplete:
            break
        }
        switch snapshot.activation {
        case .observed: return .connected
        case .awaitingReceipt: return .awaitingReceipt
        case .none: return .awaitingReceipt
        }
    }

    private static func makePresentation(
        scope: PanelSoundScopeID,
        hosts: [HostID],
        document: LocalActivitySummaryDocument?,
        readState: ActivityOverviewReadState,
        integrationStatuses: [HostID: ActivityIntegrationStatus],
        now: Date,
        timeZone: TimeZone,
        capabilities: [HostID: [HostCapabilityBinding]]
    ) -> ActivityOverviewPresentation {
        let eventRows = Event.allCases.map { event in
            makeEvent(
                event: event,
                hosts: hosts,
                document: document,
                readState: readState,
                now: now,
                timeZone: timeZone,
                capabilities: capabilities)
        }
        let todayStatuses = eventRows.map(\.todayStatus)
        let sevenDayStatuses = eventRows.map(\.sevenDayStatus)
        let todayStatus = aggregateStatus(todayStatuses, supportedEventCount: eventRows.count)
        let sevenDayStatus = aggregateStatus(sevenDayStatuses, supportedEventCount: eventRows.count)
        let taskStart = eventRows.first { $0.event == .taskStart }
        let stop = eventRows.first { $0.event == .stop }
        let subagentStop = eventRows.first { $0.event == .subagentStop }
        let todayMessages = messageCount(taskStart: taskStart, stop: stop, range: .today)
        let sevenDayMessages = messageCount(taskStart: taskStart, stop: stop, range: .sevenDays)
        let todaySubtasks = subagentStop?.todayCount
        let sevenDaySubtasks = subagentStop?.sevenDayCount
        let barSegments = ActivityOverviewBarLayout.events.map { event in
            let row = eventRows.first { $0.event == event }
            return ActivityOverviewBarSegment(
                event: event,
                availability: row?.availability ?? .unavailable,
                todayCount: row?.todayCount,
                sevenDayCount: row?.sevenDayCount)
        }
        return ActivityOverviewPresentation(
            scope: scope,
            integrationStatus: aggregateIntegrationStatus(
                hosts: hosts, statuses: integrationStatuses),
            todayMessages: todayMessages,
            sevenDayMessages: sevenDayMessages,
            todaySubtasks: todaySubtasks,
            sevenDaySubtasks: sevenDaySubtasks,
            todayStatus: todayStatus,
            sevenDayStatus: sevenDayStatus,
            eventRows: eventRows,
            barSegments: barSegments)
    }

    private static func makeEvent(
        event: Event,
        hosts: [HostID],
        document: LocalActivitySummaryDocument?,
        readState: ActivityOverviewReadState,
        now: Date,
        timeZone: TimeZone,
        capabilities: [HostID: [HostCapabilityBinding]]
    ) -> ActivityOverviewEventPresentation {
        let supportedHosts = hosts.filter { host in
            capabilities[host, default: HostCapabilityCatalog.bindings(for: host)]
                .contains { $0.event == event && $0.isAudibleCapability }
        }
        let unsupportedHosts = hosts.filter { !supportedHosts.contains($0) }
        let coverage = ActivityOverviewCoverage(
            supportedCount: supportedHosts.count,
            totalCount: hosts.count,
            supportedHosts: supportedHosts,
            unsupportedHosts: unsupportedHosts)
        guard !supportedHosts.isEmpty else {
            return ActivityOverviewEventPresentation(
                event: event,
                availability: .unsupported,
                coverage: coverage,
                todayCount: nil,
                sevenDayCount: nil,
                todayStatus: .unobserved,
                sevenDayStatus: .unobserved)
        }
        if case .unavailable = readState {
            return unavailableEvent(event: event, coverage: coverage)
        }
        let keys = LocalActivitySummaryStore.dateKeys(today: now, timeZone: timeZone)
        let todayKeys = Array(keys.prefix(1))
        let todayCount = count(
            document: document,
            hosts: supportedHosts,
            event: event,
            dateKeys: todayKeys)
        let sevenDayCount = count(
            document: document,
            hosts: supportedHosts,
            event: event,
            dateKeys: keys)
        let todayStatus = status(
            readState: readState,
            document: document,
            dateKeys: todayKeys,
            count: todayCount)
        let sevenDayStatus = status(
            readState: readState,
            document: document,
            dateKeys: keys,
            count: sevenDayCount)
        return ActivityOverviewEventPresentation(
            event: event,
            availability: .supported,
            coverage: coverage,
            todayCount: todayCount,
            sevenDayCount: sevenDayCount,
            todayStatus: todayStatus,
            sevenDayStatus: sevenDayStatus)
    }

    private static func unavailableEvent(
        event: Event,
        coverage: ActivityOverviewCoverage
    ) -> ActivityOverviewEventPresentation {
        ActivityOverviewEventPresentation(
            event: event,
            availability: .unavailable,
            coverage: coverage,
            todayCount: nil,
            sevenDayCount: nil,
            todayStatus: .unavailable,
            sevenDayStatus: .unavailable)
    }

    private static func count(
        document: LocalActivitySummaryDocument?,
        hosts: [HostID],
        event: Event,
        dateKeys: [String]
    ) -> UInt64 {
        guard let document else { return 0 }
        let hostSet = Set(hosts)
        return document.buckets
            .filter { dateKeys.contains($0.localDate) }
            .flatMap(\.counts)
            .reduce(into: UInt64(0)) { result, entry in
                guard let key = LocalActivityCounterKey.split(entry.key),
                    hostSet.contains(key.host),
                    key.event == event
                else { return }
                let (sum, overflow) = result.addingReportingOverflow(entry.value)
                result = overflow ? UInt64.max : sum
            }
    }

    private static func status(
        readState: ActivityOverviewReadState,
        document: LocalActivitySummaryDocument?,
        dateKeys: [String],
        count: UInt64
    ) -> ActivityOverviewStatus {
        if let document, let clearedAt = document.clearedAt,
            let clearedDate = document.clearedLocalDate,
            dateKeys.contains(clearedDate)
        {
            return .partial(since: clearedAt)
        }
        switch readState {
        case .missing: return .unobserved
        case .ready: return count == 0 ? .empty : .ready
        case .unavailable: return .unavailable
        case .stale(let lastUpdated): return .stale(lastUpdated: lastUpdated)
        }
    }

    private static func messageCount(
        taskStart: ActivityOverviewEventPresentation?,
        stop: ActivityOverviewEventPresentation?,
        range: LocalActivityRange
    ) -> UInt64? {
        guard let taskStart, let stop,
            taskStart.availability == .supported,
            stop.availability == .supported
        else { return nil }
        let left = range == .today ? taskStart.todayCount : taskStart.sevenDayCount
        let right = range == .today ? stop.todayCount : stop.sevenDayCount
        guard let left, let right else { return nil }
        let (sum, overflow) = left.addingReportingOverflow(right)
        return overflow ? UInt64.max : sum
    }

    private static func aggregateStatus(
        _ statuses: [ActivityOverviewStatus],
        supportedEventCount: Int
    ) -> ActivityOverviewStatus {
        guard supportedEventCount > 0 else { return .unobserved }
        if let status = statuses.first(where: {
            if case .unavailable = $0 { return true }
            return false
        }) {
            return status
        }
        if let status = statuses.first(where: {
            if case .stale = $0 { return true }
            return false
        }) {
            return status
        }
        if let status = statuses.first(where: {
            if case .partial = $0 { return true }
            return false
        }) {
            return status
        }
        if statuses.contains(where: {
            if case .ready = $0 { return true }
            return false
        }) {
            return .ready
        }
        if statuses.contains(where: {
            if case .empty = $0 { return true }
            return false
        }) {
            return .empty
        }
        return .unobserved
    }

    private static func aggregateIntegrationStatus(
        hosts: [HostID],
        statuses: [HostID: ActivityIntegrationStatus]
    ) -> ActivityIntegrationStatus? {
        guard !hosts.isEmpty else { return nil }
        let values = hosts.compactMap { statuses[$0] }
        guard !values.isEmpty else { return nil }
        if values.contains(.connected) { return .connected }
        if values.contains(.awaitingReceipt) { return .awaitingReceipt }
        if values.contains(.unavailable) { return .unavailable }
        return .notConnected
    }
}

public struct ActivityDiagnosticsLoadResult: Sendable, Equatable {
    public let readResult: LocalActivitySummaryReadResult
    public let integrationStatuses: [HostID: ActivityIntegrationStatus]
    public let log: ActivityDiagnosticLogSnapshot

    public init(
        readResult: LocalActivitySummaryReadResult,
        integrationStatuses: [HostID: ActivityIntegrationStatus] = [:],
        log: ActivityDiagnosticLogSnapshot
    ) {
        self.readResult = readResult
        self.integrationStatuses = integrationStatuses
        self.log = log
    }
}

public struct ActivityDiagnosticsPresentation: Sendable, Equatable {
    public let projection: ActivityOverviewProjection
    public let log: ActivityDiagnosticLogSnapshot

    public init(
        projection: ActivityOverviewProjection,
        log: ActivityDiagnosticLogSnapshot
    ) {
        self.projection = projection
        self.log = log
    }

    public static func empty(now: Date = Date(), timeZone: TimeZone = .current)
        -> ActivityDiagnosticsPresentation
    {
        let projection = ActivityOverviewProjector.project(
            document: nil,
            readState: .missing,
            integrationStatuses: [:],
            now: now,
            timeZone: timeZone)
        return ActivityDiagnosticsPresentation(
            projection: projection,
            log: ActivityDiagnosticLogSnapshot(path: "", state: .missing, failures: []))
    }
}

public enum ActivityDiagnosticsAction: Sendable, Equatable, Hashable {
    case clearActivity
    case clearLog
    case revealLog
    case copyLogPath
}

public enum ActivityDiagnosticsFailure: Error, Sendable, Equatable {
    case activityLockBusy
    case activityClearFailed
    case logLockBusy
    case logClearFailed
    case finderFailed
    case clipboardFailed
}

public struct ActivityDiagnosticsFeedback: Sendable, Equatable {
    public let action: ActivityDiagnosticsAction
    public let failure: ActivityDiagnosticsFailure?

    public init(action: ActivityDiagnosticsAction, failure: ActivityDiagnosticsFailure?) {
        self.action = action
        self.failure = failure
    }
}

@MainActor
public struct ActivityDiagnosticsOperations {
    public let load: @Sendable () async -> ActivityDiagnosticsLoadResult
    public let clearActivity:
        @Sendable () async -> Result<
            ActivityDiagnosticsLoadResult, ActivityDiagnosticsFailure
        >
    public let clearLog:
        @Sendable () async -> Result<
            ActivityDiagnosticLogSnapshot, ActivityDiagnosticsFailure
        >
    public let revealLog: @MainActor () -> Bool
    public let copyLogPath: @MainActor () -> Bool

    public init(
        load: @escaping @Sendable () async -> ActivityDiagnosticsLoadResult,
        clearActivity:
            @escaping @Sendable () async -> Result<
                ActivityDiagnosticsLoadResult, ActivityDiagnosticsFailure
            >,
        clearLog:
            @escaping @Sendable () async -> Result<
                ActivityDiagnosticLogSnapshot, ActivityDiagnosticsFailure
            >,
        revealLog: @escaping @MainActor () -> Bool,
        copyLogPath: @escaping @MainActor () -> Bool
    ) {
        self.load = load
        self.clearActivity = clearActivity
        self.clearLog = clearLog
        self.revealLog = revealLog
        self.copyLogPath = copyLogPath
    }
}

@MainActor
public final class ActivityDiagnosticsModel: ObservableObject {
    @Published public private(set) var presentation: ActivityDiagnosticsPresentation
    @Published public private(set) var isRefreshing = false
    @Published public private(set) var activeActions: Set<ActivityDiagnosticsAction> = []
    @Published public private(set) var feedback: ActivityDiagnosticsFeedback?

    private let operations: ActivityDiagnosticsOperations
    private var revision: UInt64 = 0
    private var lastSuccessfulDocument: LocalActivitySummaryDocument?
    private var currentDocument: LocalActivitySummaryDocument?
    private var currentReadState: ActivityOverviewReadState = .missing
    private var currentIntegrationStatuses: [HostID: ActivityIntegrationStatus] = [:]

    public var isOperationActive: Bool {
        isRefreshing || !activeActions.isEmpty
    }

    public init(
        initialPresentation: ActivityDiagnosticsPresentation = .empty(),
        operations: ActivityDiagnosticsOperations
    ) {
        presentation = initialPresentation
        self.operations = operations
    }

    #if DEBUG
    public convenience init(
        previewPresentation: ActivityDiagnosticsPresentation,
        previewLoadResult: ActivityDiagnosticsLoadResult? = nil,
        previewClearActivityResult:
            Result<ActivityDiagnosticsLoadResult, ActivityDiagnosticsFailure>? = nil,
        previewIsRefreshing: Bool = false,
        previewFeedback: ActivityDiagnosticsFeedback? = nil
    ) {
        let fallbackLoadResult = ActivityDiagnosticsLoadResult(
            readResult: LocalActivitySummaryReadResult(state: .missing),
            log: previewPresentation.log)
        self.init(
            initialPresentation: previewPresentation,
            operations: ActivityDiagnosticsOperations(
                load: {
                    previewLoadResult ?? fallbackLoadResult
                },
                clearActivity: {
                    previewClearActivityResult ?? .success(fallbackLoadResult)
                },
                clearLog: { .success(previewPresentation.log) },
                revealLog: { true },
                copyLogPath: { true }))
        isRefreshing = previewIsRefreshing
        feedback = previewFeedback
    }
    #endif

    public func refresh() {
        guard !isOperationActive else { return }
        revision &+= 1
        let currentRevision = revision
        isRefreshing = true
        Task { [weak self] in
            guard let self else { return }
            let result = await operations.load()
            guard revision == currentRevision else { return }
            apply(result)
            isRefreshing = false
        }
    }

    public func clearActivity() {
        perform(
            .clearActivity,
            operation: { [operations] in await operations.clearActivity() },
            apply: { [weak self] result in
                self?.lastSuccessfulDocument = nil
                self?.apply(result)
            })
    }

    public func clearLog() {
        guard !isOperationActive else { return }
        revision &+= 1
        let currentRevision = revision
        activeActions.insert(.clearLog)
        Task { [weak self] in
            guard let self else { return }
            let result = await operations.clearLog()
            guard revision == currentRevision else { return }
            switch result {
            case .success(let log):
                let current = presentation
                presentation = ActivityDiagnosticsPresentation(
                    projection: current.projection,
                    log: log)
                feedback = ActivityDiagnosticsFeedback(action: .clearLog, failure: nil)
            case .failure(let failure):
                feedback = ActivityDiagnosticsFeedback(action: .clearLog, failure: failure)
            }
            activeActions.remove(.clearLog)
        }
    }

    public func revealLog() {
        guard !isOperationActive else { return }
        activeActions.insert(.revealLog)
        feedback = ActivityDiagnosticsFeedback(
            action: .revealLog,
            failure: operations.revealLog() ? nil : .finderFailed)
        activeActions.remove(.revealLog)
    }

    public func copyLogPath() {
        guard !isOperationActive else { return }
        activeActions.insert(.copyLogPath)
        feedback = ActivityDiagnosticsFeedback(
            action: .copyLogPath,
            failure: operations.copyLogPath() ? nil : .clipboardFailed)
        activeActions.remove(.copyLogPath)
    }

    public func dismissFeedback() {
        feedback = nil
    }

    /// The host manager owns connection facts. Updating them reuses the same activity document
    /// and projector rather than making Panel or Settings recalculate a second projection.
    public func updateIntegrationStatuses(_ statuses: [HostID: ActivityIntegrationStatus]) {
        currentIntegrationStatuses = statuses
        rebuildProjection(now: Date())
    }

    private func perform(
        _ action: ActivityDiagnosticsAction,
        operation:
            @escaping @Sendable () async -> Result<
                ActivityDiagnosticsLoadResult, ActivityDiagnosticsFailure
            >,
        apply: @escaping @MainActor (ActivityDiagnosticsLoadResult) -> Void
    ) {
        guard !isOperationActive else { return }
        revision &+= 1
        let currentRevision = revision
        activeActions.insert(action)
        Task { [weak self] in
            guard let self else { return }
            let result = await operation()
            guard revision == currentRevision else { return }
            switch result {
            case .success(let loadResult):
                apply(loadResult)
                feedback = ActivityDiagnosticsFeedback(action: action, failure: nil)
            case .failure(let failure):
                feedback = ActivityDiagnosticsFeedback(action: action, failure: failure)
            }
            activeActions.remove(action)
        }
    }

    private func apply(_ result: ActivityDiagnosticsLoadResult) {
        let readState: ActivityOverviewReadState
        let document: LocalActivitySummaryDocument?
        switch result.readResult.state {
        case .missing:
            if let lastSuccessfulDocument {
                document = lastSuccessfulDocument
                readState = .stale(lastUpdated: lastSuccessfulDocument.updatedAt)
            } else {
                document = nil
                readState = .missing
            }
        case .ready(let loaded):
            lastSuccessfulDocument = loaded
            document = loaded
            readState = .ready
        case .stale(let loaded):
            lastSuccessfulDocument = loaded
            document = loaded
            readState = .stale(lastUpdated: loaded.updatedAt)
        case .unavailable:
            document = lastSuccessfulDocument
            readState =
                lastSuccessfulDocument.map {
                    .stale(lastUpdated: $0.updatedAt)
                } ?? .unavailable
        }
        let now = Date()
        currentDocument = document
        currentReadState = readState
        // The disk adapter deliberately does not read host connection state.  An empty map
        // therefore means "keep the app-lifetime manager's latest snapshot", not "all hosts
        // disappeared".  A non-empty map is an explicit refresh from the composition root.
        if !result.integrationStatuses.isEmpty {
            currentIntegrationStatuses = result.integrationStatuses
        }
        presentation = ActivityDiagnosticsPresentation(
            projection: ActivityOverviewProjector.project(
                document: document,
                readState: readState,
                integrationStatuses: currentIntegrationStatuses,
                now: now,
                timeZone: .current),
            log: result.log)
    }

    private func rebuildProjection(now: Date) {
        presentation = ActivityDiagnosticsPresentation(
            projection: ActivityOverviewProjector.project(
                document: currentDocument,
                readState: currentReadState,
                integrationStatuses: currentIntegrationStatuses,
                now: now,
                timeZone: .current),
            log: presentation.log)
    }
}
