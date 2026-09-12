import ClaudioCore
import Combine
import Dispatch
import Foundation

public enum EventNoticePresentationPhase: String, Codable, Sendable, Equatable {
    case hidden
    case entering
    case visible
    case exiting
}

public struct EventNoticePauseReason: OptionSet, Sendable, Hashable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let hover = Self(rawValue: 1 << 0)
    public static let keyboardFocus = Self(rawValue: 1 << 1)
    public static let expanded = Self(rawValue: 1 << 2)
}

public enum EventNoticeRecordStatus: String, Codable, Sendable, Equatable {
    case queued
    case displayed
    case collapsed
}

/// One immutable source payload per version, shared by live and frozen projections. This is
/// not another owner or cache: erasing every retained reference releases the source together.
fileprivate final class EventNoticeContent: Sendable, Equatable {
    let notice: HostEventNotice

    init(_ notice: HostEventNotice) { self.notice = notice }

    static func == (lhs: EventNoticeContent, rhs: EventNoticeContent) -> Bool {
        lhs === rhs || lhs.notice == rhs.notice
    }
}

/// A recent notice is a presentation record, not a receipt or activity fact. `notice` becomes
/// nil when its short privacy TTL expires; the event and safe focus identity may remain so the
/// current control does not jump underneath a user.
public struct EventNoticeRecord: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let event: Event
    public let occurredAt: Date?
    fileprivate let content: EventNoticeContent?
    public var notice: HostEventNotice? { content?.notice }
    public let status: EventNoticeRecordStatus
    public let isExpired: Bool
    public let version: UInt64
    public let isActionable: Bool
    public let kind: EventNoticeKind
    public var action: EventNoticeAction? {
        guard let notice else { return nil }
        return EventNoticeAction(
            id: id, version: version, epoch: notice.receiverEpoch,
            installationID: notice.installationID)
    }

    public var source: HostEventSource? { content?.notice.source }
    public var sessionID: String? { source?.sessionID }

    public init(
        id: UUID,
        event: Event,
        occurredAt: Date?,
        notice: HostEventNotice?,
        status: EventNoticeRecordStatus,
        isExpired: Bool,
        version: UInt64 = 1,
        isActionable: Bool = true,
        kind: EventNoticeKind = .transient
    ) {
        self.init(
            id: id, event: event, occurredAt: occurredAt,
            content: notice.map { EventNoticeContent($0) }, status: status,
            isExpired: isExpired, version: version, isActionable: isActionable, kind: kind)
    }

    fileprivate init(
        id: UUID, event: Event, occurredAt: Date?, content: EventNoticeContent?,
        status: EventNoticeRecordStatus, isExpired: Bool, version: UInt64,
        isActionable: Bool, kind: EventNoticeKind
    ) {
        self.id = id
        self.event = event
        self.occurredAt = occurredAt
        self.content = content
        self.status = status
        self.isExpired = isExpired
        self.version = version
        self.isActionable = isActionable
        self.kind = kind
    }
}

public struct EventNoticeModelSnapshot: Sendable, Equatable {
    public let phase: EventNoticePresentationPhase
    public let current: EventNoticeRecord?
    public let recent: [EventNoticeRecord]
    public let pendingCount: Int
    public let pauseReasons: EventNoticePauseReason
    public let remainingTime: TimeInterval?
    public let isExpanded: Bool
    public let isDetail: Bool
    public let totalCount: Int
    public var needsRefresh: Bool { pendingCount > 0 || recent.contains { !$0.isActionable } }
    public let droppedCount: Int
    public let receiverEpoch: UUID

    public init(
        phase: EventNoticePresentationPhase,
        current: EventNoticeRecord?,
        recent: [EventNoticeRecord],
        pendingCount: Int,
        pauseReasons: EventNoticePauseReason,
        remainingTime: TimeInterval?,
        isExpanded: Bool,
        droppedCount: Int,
        receiverEpoch: UUID,
        isDetail: Bool = false,
        totalCount: Int = 0
    ) {
        self.phase = phase
        self.current = current
        self.recent = recent
        self.pendingCount = pendingCount
        self.pauseReasons = pauseReasons
        self.remainingTime = remainingTime
        self.isExpanded = isExpanded
        self.isDetail = isDetail
        self.totalCount = totalCount
        self.droppedCount = droppedCount
        self.receiverEpoch = receiverEpoch
    }
}

public enum EventNoticeAcceptance: Sendable, Equatable {
    case accepted
    case ignoredDisabled
    case staleEpoch
    case duplicate
    case invalid
    case droppedCapacity
    case staleObservation
}

/// The scheduler is injected so countdown and stale-callback behavior can be tested without
/// sleeping. Production uses one cancellable DispatchSourceTimer per model timer.
public struct EventNoticeScheduler {
    private let scheduleClosure:
        @MainActor (
            TimeInterval,
            @escaping @MainActor () -> Void
        ) -> EventNoticeCancellation

    public init(
        schedule:
            @escaping @MainActor (
                TimeInterval,
                @escaping @MainActor () -> Void
            ) -> EventNoticeCancellation
    ) {
        scheduleClosure = schedule
    }

    @MainActor
    public func schedule(
        after delay: TimeInterval,
        _ callback: @escaping @MainActor () -> Void
    ) -> EventNoticeCancellation {
        scheduleClosure(max(0, delay), callback)
    }

    @MainActor public static let live = Self { delay, callback in
        // Cancelling asyncAfter's work item can retain its closure until the old deadline.
        // A source timer releases that pending handler on cancellation, including a 30min TTL.
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + max(0, delay))
        timer.setEventHandler {
            timer.setEventHandler(handler: nil)
            timer.cancel()
            MainActor.assumeIsolated { callback() }
        }
        timer.resume()
        return EventNoticeCancellation {
            timer.setEventHandler(handler: nil)
            timer.cancel()
        }
    }
}

public final class EventNoticeCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private let cancellation: () -> Void
    private var isCancelled = false

    public init(_ cancellation: @escaping () -> Void) {
        self.cancellation = cancellation
    }

    deinit { cancel() }

    public func cancel() {
        lock.lock()
        guard !isCancelled else {
            lock.unlock()
            return
        }
        isCancelled = true
        lock.unlock()
        cancellation()
    }
}

public enum EventNoticeKind: Sendable, Equatable {
    case transient, permission, needsInput, interrupted, review

    public static func classify(_ notice: HostEventNotice) -> Self {
        switch notice.event {
        case .taskStart, .stop, .subagentStop: return .transient
        case .stopFailure: return .interrupted
        case .notification:
            switch notice.reason {
            case .permission: return .permission
            case .needsInput: return .needsInput
            case .informational: return .transient
            case .review, nil: return .review
            }
        }
    }
}

/// The exact version the user saw. It contains no display/source strings.
public struct EventNoticeAction: Sendable, Equatable, Hashable {
    public let id: UUID
    public let version: UInt64
    public let epoch: UUID
    public let installationID: UUID

    public init(id: UUID, version: UInt64, epoch: UUID, installationID: UUID) {
        self.id = id
        self.version = version
        self.epoch = epoch
        self.installationID = installationID
    }
}

public enum EventNoticeRemovalReason: Sendable, Equatable {
    case userRemoved, exactReturnConfirmed, subsequentSubmission, expired, capacity, privacy
}

public enum EventNoticeActionOutcome: Sendable, Equatable {
    case applied, stale, unavailable
}

public struct EventNoticePrivacyReason: OptionSet, Sendable, Equatable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let screenLocked = Self(rawValue: 1 << 0)
    public static let sleeping = Self(rawValue: 1 << 1)
    public static let inactiveSession = Self(rawValue: 1 << 2)
}

public struct EventNoticeResourceUsage: Sendable, Equatable {
    public let latestVersions: Int
    public let readingVersions: Int
    public let transientVersions: Int
    public let deduplicationEntries: Int
    public let observationEntries: Int
    public let timers: Int
}

/// Sole owner of reminders, reading versions, lifecycle and deadlines. Views only consume
/// immutable snapshots and return versioned actions. No source data is persisted.
@MainActor
public final class EventNoticeModel: ObservableObject {
    public static let displayDuration: TimeInterval = 4
    public static let fadeDuration: TimeInterval = 0.18
    public static let retentionDuration: TimeInterval = 30 * 60
    public static let maximumRecentCount = 50
    public static let maximumMetadataCount = 256

    @Published public private(set) var snapshot: EventNoticeModelSnapshot
    @Published public private(set) var badgeCount = 0
    public private(set) var receiverEpoch: UUID
    public private(set) var isEnabled = true
    public private(set) var privacyReasons: EventNoticePrivacyReason = []
    public private(set) var isAutomaticallySuppressed = false
    public private(set) var lastRemovalReason: EventNoticeRemovalReason?
    public var resourceUsage: EventNoticeResourceUsage {
        var readingVersions = 0
        for entry in frozen where entry.content != nil { readingVersions += 1 }
        return EventNoticeResourceUsage(
            latestVersions: entries.count, readingVersions: readingVersions,
            transientVersions: transient?.content == nil ? 0 : 1,
            deduplicationEntries: seen.count, observationEntries: observations.count,
            timers: (presentationTimer == nil ? 0 : 1) + (expiryTimer == nil ? 0 : 1)
                + (badgeTimer == nil ? 0 : 1))
    }
    public var canReceive: Bool { isEnabled && privacyReasons.isEmpty }

    private struct Identity: Equatable {
        let epoch: UUID
        let surface: HostSurfaceID
        let installation: UUID
        let project: Data
        let session: Data

        // Byte-exact Data comparisons otherwise expand at every lookup closure under -Osize.
        // Keep one comparison body; String equality would merge canonically equivalent IDs.
        @inline(never)
        static func == (lhs: Identity, rhs: Identity) -> Bool {
            lhs.epoch == rhs.epoch && lhs.surface == rhs.surface
                && lhs.installation == rhs.installation
                && lhs.project == rhs.project && lhs.session == rhs.session
        }

        init?(_ notice: HostEventNotice) {
            guard let source = notice.source, !source.isParentSession,
                source.mainSessionIsKnown == true,
                source.completeness == .complete, let project = source.projectKey,
                let session = source.sessionID, notice.event != .subagentStop
            else { return nil }
            epoch = notice.receiverEpoch
            surface = notice.surface
            installation = notice.installationID
            self.project = Data(project.utf8)
            self.session = Data(session.utf8)
        }
    }

    /// Live and frozen lists share a version handle. Only this model may erase its source;
    /// a replacement always creates a new handle, so older reading versions keep their TTL.
    private final class Entry {
        let id: UUID
        let version: UInt64
        let event: Event
        let kind: EventNoticeKind
        let expiresAt: TimeInterval
        var content: EventNoticeContent?
        var identity: Identity?
        init(
            id: UUID, version: UInt64, event: Event, kind: EventNoticeKind,
            expiresAt: TimeInterval, content: EventNoticeContent?, identity: Identity?
        ) {
            self.id = id
            self.version = version
            self.event = event
            self.kind = kind
            self.expiresAt = expiresAt
            self.content = content
            self.identity = identity
        }
        var notice: HostEventNotice? { content?.notice }
        var action: EventNoticeAction? {
            guard let content else { return nil }
            return EventNoticeAction(
                id: id, version: version, epoch: content.notice.receiverEpoch,
                installationID: content.notice.installationID)
        }
        func matches(_ action: EventNoticeAction) -> Bool {
            guard id == action.id, version == action.version, let content else { return false }
            return content.notice.receiverEpoch == action.epoch
                && content.notice.installationID == action.installationID
        }
        func erase() {
            content = nil
            identity = nil
        }
    }

    private struct Observation {
        let identity: Identity
        let uptime: TimeInterval
        let expiresAt: TimeInterval
    }

    private let now: @MainActor () -> TimeInterval
    private let scheduler: EventNoticeScheduler
    /// Empty in production. Only adapters with real submission-order evidence may opt in.
    private let verifiedSubmissionSurfaces: Set<HostSurfaceID>
    private var epochStartedAt: TimeInterval
    private var entries: [Entry] = []  // oldest update first
    private var frozen: [Entry] = []  // complete reading versions, newest first
    private var transient: Entry?
    private var currentID: UUID?
    private var protectedAction: EventNoticeAction?
    private var seen: [(id: UUID, expiresAt: TimeInterval)] = []
    private var observations: [Observation] = []
    private var phase: EventNoticePresentationPhase = .hidden
    private var pauseReasons: EventNoticePauseReason = []
    private var isExpanded = false
    private var isDetail = false
    private var usesReducedMotion = false
    private var currentDeadline: TimeInterval?
    private var pausedRemaining: TimeInterval?
    private var presentationTimer: EventNoticeCancellation?
    private var expiryTimer: EventNoticeCancellation?
    private var badgeTimer: EventNoticeCancellation?
    private var presentationRevision: UInt64 = 0
    private var expiryRevision: UInt64 = 0
    private var badgeRevision: UInt64 = 0
    private var expiryDeadline: TimeInterval?
    private var droppedCount = 0
    private var isReducingBatch = false
    private var owesImmediateBadge = false

    public init(
        receiverEpoch: UUID,
        now: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        scheduler: EventNoticeScheduler = .live,
        verifiedSubmissionSurfaces: Set<HostSurfaceID> = []
    ) {
        self.receiverEpoch = receiverEpoch
        self.now = now
        self.scheduler = scheduler
        self.verifiedSubmissionSurfaces = verifiedSubmissionSurfaces
        epochStartedAt = now()
        snapshot = EventNoticeModelSnapshot(
            phase: .hidden, current: nil, recent: [], pendingCount: 0, pauseReasons: [],
            remainingTime: nil, isExpanded: false, droppedCount: 0, receiverEpoch: receiverEpoch)
    }

    @discardableResult
    public func accept(_ notice: HostEventNotice) -> EventNoticeAcceptance {
        expireEntries()
        defer { publish() }
        guard canReceive else { return .ignoredDisabled }
        guard notice.receiverEpoch == receiverEpoch else { return .staleEpoch }
        guard notice.isSemanticallyValid, let host = notice.host,
            HostCapabilityCatalog.binding(host: host, nativeEvent: notice.nativeEvent)?
                .isAudibleCapability == true
        else { return .invalid }
        guard !seen.contains(where: { $0.id == notice.id }),
            !entries.contains(where: { $0.content?.notice.id == notice.id }),
            !frozen.contains(where: { $0.content?.notice.id == notice.id }),
            transient?.content?.notice.id != notice.id
        else { return .duplicate }
        seen.append((notice.id, now() + Self.retentionDuration))
        if seen.count > Self.maximumMetadataCount { seen.removeFirst() }

        let identity = Identity(notice)
        let existingIndex = identity.flatMap { index(for: $0) }
        let existing = existingIndex.map { entries[$0] }
        let observation = validObservation(notice)
        let kind = EventNoticeKind.classify(notice)
        if let identity, let observation,
            kind != .transient
                || (notice.event == .taskStart
                    && verifiedSubmissionSurfaces.contains(notice.surface))
        {
            let metadataTime = observations.first(where: { $0.identity == identity })?.uptime
            let latestTime = existing?.notice.flatMap(validObservation)
            if let previous = [metadataTime, latestTime].compactMap({ $0 }).max(),
                observation <= previous
            {
                return .staleObservation
            }
            observations.removeAll { $0.identity == identity }
            observations.append(
                Observation(
                    identity: identity, uptime: observation,
                    expiresAt: now() + Self.retentionDuration))
            if observations.count > Self.maximumMetadataCount { observations.removeFirst() }
        }

        if notice.event == .taskStart, verifiedSubmissionSurfaces.contains(notice.surface),
            identity != nil, let observation,
            let previous = existing,
            let previousNotice = previous.notice,
            let previousTime = validObservation(previousNotice),
            observation > previousTime, let action = previous.action
        {
            _ = remove(action, reason: .subsequentSubmission)
        }

        if kind == .transient {
            // No queue: ordinary sources live only in the currently displayed transient slot.
            if canAutomaticallyDisplay {
                let entry = makeEntry(notice, kind: kind, identity: identity)
                transient = entry
                frozen.removeAll()
                beginDisplaying(entry)
            }
            return .accepted
        }

        let entry: Entry
        if let index = existingIndex {
            let previous = entries.remove(at: index)
            guard previous.version < UInt64.max else {
                entries.insert(previous, at: index)
                droppedCount = saturatedIncrement(droppedCount)
                return .droppedCapacity
            }
            entry = makeEntry(
                notice, kind: kind, identity: identity, id: previous.id,
                version: previous.version + 1)
        } else {
            if entries.count >= Self.maximumRecentCount {
                guard
                    let index = entries.firstIndex(where: {
                        $0.id != currentID && $0.id != protectedAction?.id
                    })
                else {
                    droppedCount = saturatedIncrement(droppedCount)
                    return .droppedCapacity
                }
                eraseReadingVersion(id: entries[index].id)
                entries.remove(at: index)
                droppedCount = saturatedIncrement(droppedCount)
                lastRemovalReason = .capacity
            }
            entry = makeEntry(notice, kind: kind, identity: identity)
        }
        entries.append(entry)
        if canAutomaticallyDisplay {
            frozen = [entry]
            beginDisplaying(entry)
        }
        return .accepted
    }

    /// One bounded reduction for runtime ingress; unconsumed messages stay in the mailbox.
    @discardableResult
    public func acceptBatch(_ notices: [HostEventNotice]) -> [EventNoticeAcceptance] {
        var results: [EventNoticeAcceptance] = []
        let started = ProcessInfo.processInfo.systemUptime
        isReducingBatch = true
        for notice in notices.prefix(32) {
            results.append(accept(notice))
            if ProcessInfo.processInfo.systemUptime - started >= 0.004 { break }
        }
        isReducingBatch = false
        if !results.isEmpty { publish() }
        return results
    }

    @discardableResult
    public func accept<S: Sequence>(contentsOf notices: S) -> [EventNoticeAcceptance]
    where S.Element == HostEventNotice {
        var results: [EventNoticeAcceptance] = []
        var buffer: [HostEventNotice] = []
        func reduceBuffer() {
            while !buffer.isEmpty {
                let reduced = acceptBatch(buffer)
                results.append(contentsOf: reduced)
                buffer.removeFirst(reduced.count)
            }
        }
        for notice in notices {
            buffer.append(notice)
            if buffer.count == 32 { reduceBuffer() }
        }
        reduceBuffer()
        return results
    }

    public func setHovering(_ value: Bool) { setPauseReason(.hover, active: value) }
    public func setKeyboardFocused(_ value: Bool) { setPauseReason(.keyboardFocus, active: value) }
    public func setExpanded(_ value: Bool) { value ? openRecent() : closeRecent() }

    public func openRecent() {
        guard canReceive else { return }
        expireEntries()
        invalidatePresentationTimer()
        if !isExpanded {
            frozen = entries.reversed()
            currentID = nil
            transient = nil
        }
        isExpanded = true
        isDetail = false
        phase = .visible
        setPauseReason(.expanded, active: true)
        publish(immediateBadge: true)
    }

    /// Esc from list collapses it; it never removes reminders or starts a replay queue.
    public func closeRecent() { dismiss() }

    public func refreshRecent() {
        guard isExpanded else { return }
        expireEntries()
        frozen = entries.reversed()
        currentID = nil
        transient = nil
        isDetail = false
        publish()
    }

    @discardableResult
    public func viewSource(_ action: EventNoticeAction) -> EventNoticeActionOutcome {
        expireEntries()
        guard let entry = actionableEntry(action) else { publish(); return .stale }
        invalidatePresentationTimer()
        if !isExpanded { frozen = entries.reversed() }
        if entry.kind == .transient { transient = entry }
        currentID = entry.id
        isExpanded = true
        isDetail = true
        phase = .visible
        setPauseReason(.expanded, active: true)
        publish()
        return .applied
    }

    public func closeDetail() {
        guard isDetail else { return }
        isDetail = false
        currentID = nil
        transient = nil
        publish()
    }

    /// Compatibility for callers selecting a visible row; never resolves a stale row to latest.
    public func selectRecent(id: UUID) {
        guard let record = snapshot.recent.first(where: { $0.id == id }), let action = record.action
        else { return }
        _ = viewSource(action)
    }

    public func isCurrent(_ action: EventNoticeAction) -> Bool {
        actionableEntry(action) != nil
    }

    public func sourceNotice(for action: EventNoticeAction) -> HostEventNotice? {
        actionableEntry(action)?.notice
    }

    public func protect(_ action: EventNoticeAction?) {
        protectedAction = action.flatMap { isCurrent($0) ? $0 : nil }
    }

    @discardableResult
    public func remove(_ action: EventNoticeAction, reason: EventNoticeRemovalReason = .userRemoved)
        -> EventNoticeActionOutcome
    {
        expireEntries()
        guard
            reason == .userRemoved || reason == .exactReturnConfirmed
                || reason == .subsequentSubmission,
            isCurrent(action), let index = entries.firstIndex(where: { $0.matches(action) })
        else { publish(); return .stale }
        entries.remove(at: index)
        eraseReadingVersion(id: action.id)
        if protectedAction == action { protectedAction = nil }
        lastRemovalReason = reason
        publish(immediateBadge: true)
        return .applied
    }

    @discardableResult
    public func copySessionID(_ action: EventNoticeAction, write exportSessionID: (String) -> Bool)
        -> Bool
    {
        expireEntries()
        defer { publish() }
        guard let session = actionableEntry(action)?.notice?.source?.sessionID else { return false }
        return exportSessionID(session)
    }

    public func dismiss(animated: Bool = true) {
        guard phase != .hidden else { return }
        isExpanded = false
        isDetail = false
        pauseReasons = []
        currentDeadline = nil
        pausedRemaining = nil
        invalidatePresentationTimer()
        if !animated || usesReducedMotion { finishDismissal(); return }
        phase = .exiting
        let revision = presentationRevision
        presentationTimer = scheduler.schedule(after: Self.fadeDuration) { [weak self] in
            guard let self, self.presentationRevision == revision else { return }
            self.finishDismissal()
        }
        publish()
    }

    public func hideImmediately() {
        invalidatePresentationTimer()
        finishDismissal()
    }

    public func setAutomaticallySuppressed(_ value: Bool) {
        guard isAutomaticallySuppressed != value else { return }
        isAutomaticallySuppressed = value
        if value && !isExpanded { hideImmediately() }
        publish()
    }

    public func setReducedMotion(_ value: Bool) {
        usesReducedMotion = value
        if value && phase == .entering { completeEntrance() }
        if value && phase == .exiting { hideImmediately() }
    }

    public func setEnabled(_ value: Bool) {
        guard isEnabled != value else { return }
        isEnabled = value
        clearForPrivacy()
    }

    public func setSystemPrivacy(_ reason: EventNoticePrivacyReason, active: Bool) {
        let previous = privacyReasons
        if active { privacyReasons.formUnion(reason) } else { privacyReasons.subtract(reason) }
        guard previous != privacyReasons else { return }
        if active { clearForPrivacy() }
    }

    public func clearForPrivacy(newReceiverEpoch: UUID = UUID()) {
        invalidatePresentationTimer()
        expiryTimer?.cancel()
        expiryTimer = nil
        expiryDeadline = nil
        expiryRevision &+= 1
        receiverEpoch = newReceiverEpoch
        epochStartedAt = now()
        entries.removeAll()
        frozen.removeAll()
        transient = nil
        currentID = nil
        protectedAction = nil
        seen.removeAll()
        observations.removeAll()
        phase = .hidden
        pauseReasons = []
        isExpanded = false
        isDetail = false
        currentDeadline = nil
        pausedRemaining = nil
        droppedCount = 0
        lastRemovalReason = .privacy
        publish(immediateBadge: true)
    }

    public func replaceReceiverEpoch(_ epoch: UUID) {
        if epoch != receiverEpoch { clearForPrivacy(newReceiverEpoch: epoch) }
    }

    public func setPauseReason(_ reason: EventNoticePauseReason, active: Bool) {
        let wasPaused = !pauseReasons.isEmpty
        if active { pauseReasons.formUnion(reason) } else { pauseReasons.subtract(reason) }
        expireEntries()
        if !wasPaused && !pauseReasons.isEmpty, phase == .visible, let deadline = currentDeadline {
            pausedRemaining = max(0, deadline - now())
            currentDeadline = nil
            invalidatePresentationTimer()
        } else if wasPaused && pauseReasons.isEmpty {
            resumeReading()
        }
        publish()
    }

    public func expireNow() { expireEntries(); publish(immediateBadge: true) }

    private var canAutomaticallyDisplay: Bool {
        !isAutomaticallySuppressed && !isExpanded && (phase == .hidden || phase == .exiting)
    }

    private var currentEntry: Entry? {
        guard let currentID else { return nil }
        if transient?.id == currentID { return transient }
        return frozen.first { $0.id == currentID }
    }

    /// Resolve the complete identity once per arrival, before any transition mutates entries.
    private func index(for identity: Identity) -> Int? {
        for index in entries.indices {
            if entries[index].identity == identity {
                return index
            }
        }
        return nil
    }

    private func actionableEntry(_ action: EventNoticeAction) -> Entry? {
        guard canReceive, action.epoch == receiverEpoch else { return nil }
        let entry =
            entries.first(where: { $0.matches(action) })
            ?? (transient?.matches(action) == true ? transient : nil)
        guard let entry, entry.content != nil, entry.expiresAt > now() else { return nil }
        return entry
    }

    private func validObservation(_ notice: HostEventNotice) -> TimeInterval? {
        guard let observation = notice.observedUptime, observation.isFinite,
            observation >= epochStartedAt, observation <= now(), observation > 0
        else { return nil }
        return observation
    }

    private func makeEntry(
        _ notice: HostEventNotice, kind: EventNoticeKind, identity: Identity?,
        id: UUID? = nil, version: UInt64 = 1
    ) -> Entry {
        Entry(
            id: id ?? notice.id, version: version, event: notice.event, kind: kind,
            expiresAt: now() + Self.retentionDuration, content: EventNoticeContent(notice),
            identity: identity)
    }

    private func beginDisplaying(_ entry: Entry) {
        currentID = entry.id
        phase = .entering
        currentDeadline = nil
        pausedRemaining = nil
        invalidatePresentationTimer()
        if usesReducedMotion { completeEntrance(); return }
        let revision = presentationRevision
        presentationTimer = scheduler.schedule(after: Self.fadeDuration) { [weak self] in
            guard let self, self.presentationRevision == revision else { return }
            self.completeEntrance()
        }
    }

    private func completeEntrance() {
        guard phase == .entering, currentEntry?.content != nil else { return }
        invalidatePresentationTimer()
        phase = .visible
        pausedRemaining = Self.displayDuration
        resumeReading()
        publish()
    }

    private func resumeReading() {
        guard phase == .visible, pauseReasons.isEmpty, currentEntry?.content != nil else { return }
        currentDeadline = now() + (pausedRemaining ?? Self.displayDuration)
        pausedRemaining = nil
        invalidatePresentationTimer()
        let revision = presentationRevision
        presentationTimer = scheduler.schedule(after: max(0, currentDeadline! - now())) {
            [weak self] in
            guard let self, self.presentationRevision == revision else { return }
            self.dismiss()
        }
    }

    private func finishDismissal() {
        presentationTimer = nil
        currentID = nil
        transient = nil
        frozen.removeAll()
        isExpanded = false
        isDetail = false
        phase = .hidden
        pauseReasons = []
        currentDeadline = nil
        pausedRemaining = nil
        publish()
    }

    private func eraseReadingVersion(id: UUID) {
        for index in frozen.indices where frozen[index].id == id { frozen[index].erase() }
    }

    private func expireEntries() {
        let time = now()
        let previousCount = entries.count
        entries.removeAll { $0.expiresAt <= time }
        if entries.count < previousCount { lastRemovalReason = .expired }
        // Each reading version has its own deadline, even if a newer version extended the row.
        for index in frozen.indices where frozen[index].expiresAt <= time { frozen[index].erase() }
        if let value = transient, value.expiresAt <= time { transient?.erase() }
        seen.removeAll { $0.expiresAt <= time }
        observations.removeAll { $0.expiresAt <= time }
        if let action = protectedAction, !isCurrent(action) { protectedAction = nil }
        if currentEntry?.content == nil, currentID != nil {
            currentDeadline = nil
            pausedRemaining = nil
            invalidatePresentationTimer()
            if phase != .hidden { phase = .visible }
        }
    }

    private func scheduleExpiry() {
        // Find the earliest deadline without copying source-bearing entries or building
        // temporary arrays on every event batch.
        var earliest = TimeInterval.infinity
        for entry in entries { earliest = min(earliest, entry.expiresAt) }
        for entry in frozen where entry.content != nil { earliest = min(earliest, entry.expiresAt) }
        if let transient, transient.content != nil { earliest = min(earliest, transient.expiresAt) }
        for item in seen { earliest = min(earliest, item.expiresAt) }
        for item in observations { earliest = min(earliest, item.expiresAt) }
        let deadline = earliest.isFinite ? earliest : nil
        guard deadline != expiryDeadline else { return }
        expiryTimer?.cancel()
        expiryTimer = nil
        expiryDeadline = deadline
        expiryRevision &+= 1
        guard let deadline else { return }
        let revision = expiryRevision
        expiryTimer = scheduler.schedule(after: max(0, deadline - now())) { [weak self] in
            guard let self, self.expiryRevision == revision else { return }
            self.expiryDeadline = nil
            self.expiryTimer = nil
            self.expireEntries()
            self.publish(immediateBadge: true)
        }
    }

    private func invalidatePresentationTimer() {
        presentationRevision &+= 1
        presentationTimer?.cancel()
        presentationTimer = nil
    }

    private func record(_ entry: Entry) -> EventNoticeRecord {
        EventNoticeRecord(
            id: entry.id, event: entry.event, occurredAt: entry.content?.notice.occurredAt,
            content: entry.content, status: entry.id == currentID ? .displayed : .collapsed,
            isExpired: entry.content == nil, version: entry.version,
            isActionable: entry.action.map(isCurrent) ?? false, kind: entry.kind)
    }

    private func publish(immediateBadge: Bool = false) {
        owesImmediateBadge = owesImmediateBadge || immediateBadge
        guard !isReducingBatch else { return }
        scheduleExpiry()
        var pendingRefreshCount = 0
        if isExpanded {
            for entry in entries where !frozen.contains(where: { $0.action == entry.action }) {
                pendingRefreshCount += 1
            }
        }
        let updated = EventNoticeModelSnapshot(
            phase: phase, current: currentEntry.map(record),
            recent: (isExpanded ? frozen : Array(entries.reversed())).map(record),
            pendingCount: pendingRefreshCount, pauseReasons: pauseReasons,
            remainingTime: currentDeadline.map { max(0, $0 - now()) } ?? pausedRemaining,
            isExpanded: isExpanded, droppedCount: droppedCount, receiverEpoch: receiverEpoch,
            isDetail: isDetail, totalCount: entries.count)
        if snapshot != updated { snapshot = updated }
        if owesImmediateBadge {
            badgeRevision &+= 1
            badgeTimer?.cancel()
            badgeTimer = nil
            if badgeCount != entries.count { badgeCount = entries.count }
            owesImmediateBadge = false
        } else if badgeCount != entries.count && badgeTimer == nil {
            // Throttle from the FIRST change. A sustained stream cannot postpone this deadline.
            let revision = badgeRevision
            badgeTimer = scheduler.schedule(after: 0.1) { [weak self] in
                guard let self, self.badgeRevision == revision else { return }
                self.badgeTimer = nil
                self.badgeCount = self.entries.count
            }
        }
    }

    private func saturatedIncrement(_ value: Int) -> Int { value == Int.max ? value : value + 1 }
}
