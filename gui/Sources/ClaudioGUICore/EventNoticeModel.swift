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

/// A recent notice is a presentation record, not a receipt or activity fact. `notice` becomes
/// nil when its short privacy TTL expires; the event and safe focus identity may remain so the
/// current control does not jump underneath a user.
public struct EventNoticeRecord: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let event: Event
    public let occurredAt: Date?
    public let notice: HostEventNotice?
    public let status: EventNoticeRecordStatus
    public let isExpired: Bool

    public var source: HostEventSource? { notice?.source }
    public var sessionID: String? { source?.sessionID }

    public init(
        id: UUID,
        event: Event,
        occurredAt: Date?,
        notice: HostEventNotice?,
        status: EventNoticeRecordStatus,
        isExpired: Bool
    ) {
        self.id = id
        self.event = event
        self.occurredAt = occurredAt
        self.notice = notice
        self.status = status
        self.isExpired = isExpired
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
        receiverEpoch: UUID
    ) {
        self.phase = phase
        self.current = current
        self.recent = recent
        self.pendingCount = pendingCount
        self.pauseReasons = pauseReasons
        self.remainingTime = remainingTime
        self.isExpanded = isExpanded
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
}

/// The scheduler is injected so countdown and stale-callback behavior can be tested without
/// sleeping. Production uses one cancellable DispatchWorkItem per model timer.
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
        let workItem = DispatchWorkItem {
            Task { @MainActor in callback() }
        }
        DispatchQueue.main.asyncAfter(
            deadline: .now() + max(0, delay),
            execute: workItem)
        return EventNoticeCancellation { workItem.cancel() }
    }
}

public final class EventNoticeCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private let cancellation: () -> Void
    private var isCancelled = false

    public init(_ cancellation: @escaping () -> Void) {
        self.cancellation = cancellation
    }

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

/// MainActor owner for the automatic capsule and its short recent list. It intentionally stores
/// only immutable notices in memory and never writes source fields to the existing receipt path.
@MainActor
public final class EventNoticeModel: ObservableObject {
    public static let displayDuration: TimeInterval = 4
    public static let fadeDuration: TimeInterval = 0.18
    public static let retentionDuration: TimeInterval = 30 * 60
    public static let maximumRecentCount = 50

    @Published public private(set) var snapshot: EventNoticeModelSnapshot
    /// The menu-bar/capsule count is deliberately debounced; `snapshot.recent` still records
    /// every accepted UUID immediately and never merges event identities.
    @Published public private(set) var badgeCount = 0
    public private(set) var receiverEpoch: UUID
    public private(set) var isEnabled = true
    public private(set) var isAutomaticallySuppressed = false

    private struct Entry {
        let id: UUID
        let event: Event
        let expiresAt: TimeInterval
        /// Monotonic per-model arrival counter. Ordering is a total (expiresAt, arrivalOrdinal)
        /// key comparison, so same-tick arrivals never depend on sort stability.
        let arrivalOrdinal: UInt64
        var notice: HostEventNotice?
        var status: EventNoticeRecordStatus
        var isExpired: Bool
    }

    private let now: @MainActor () -> TimeInterval
    private let scheduler: EventNoticeScheduler
    private var entries: [Entry] = []
    private var currentID: UUID?
    private var selectedID: UUID?
    private var frozenIDs: Set<UUID> = []
    private var phase: EventNoticePresentationPhase = .hidden
    private var pauseReasons: EventNoticePauseReason = []
    private var isExpanded = false
    private var usesReducedMotion = false
    private var currentDeadline: TimeInterval?
    private var pausedRemaining: TimeInterval?
    private var presentationTimer: EventNoticeCancellation?
    private var expiryTimer: EventNoticeCancellation?
    private var badgeTimer: EventNoticeCancellation?
    private var presentationRevision: UInt64 = 0
    private var expiryRevision: UInt64 = 0
    private var badgeRevision: UInt64 = 0
    private var droppedCount = 0
    private var nextArrivalOrdinal: UInt64 = 0

    public init(
        receiverEpoch: UUID,
        now: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        scheduler: EventNoticeScheduler = .live
    ) {
        self.receiverEpoch = receiverEpoch
        self.now = now
        self.scheduler = scheduler
        snapshot = EventNoticeModelSnapshot(
            phase: .hidden,
            current: nil,
            recent: [],
            pendingCount: 0,
            pauseReasons: [],
            remainingTime: nil,
            isExpanded: false,
            droppedCount: 0,
            receiverEpoch: receiverEpoch)
    }

    public func accept(_ notice: HostEventNotice) -> EventNoticeAcceptance {
        let expirationChanged = expireEntries()
        guard isEnabled else {
            if expirationChanged { publish() }
            return .ignoredDisabled
        }
        guard notice.receiverEpoch == receiverEpoch else {
            if expirationChanged { publish() }
            return .staleEpoch
        }
        guard notice.isSemanticallyValid else {
            if expirationChanged { publish() }
            return .invalid
        }
        guard !entries.contains(where: { $0.id == notice.id }) else {
            if expirationChanged { publish() }
            return .duplicate
        }

        if entries.count >= Self.maximumRecentCount {
            guard
                let index = entries.firstIndex(where: {
                    $0.id != currentID && $0.id != selectedID
                })
            else {
                droppedCount = min(Int.max, droppedCount + 1)
                publish()
                return .droppedCapacity
            }
            entries.remove(at: index)
            droppedCount = min(Int.max, droppedCount + 1)
        }

        let entry = Entry(
            id: notice.id,
            event: notice.event,
            expiresAt: now() + Self.retentionDuration,
            arrivalOrdinal: nextArrivalOrdinal,
            notice: notice,
            status: .queued,
            isExpired: false)
        nextArrivalOrdinal &+= 1
        entries.append(entry)

        let currentIsExpired =
            currentID.flatMap { id in
                entries.first(where: { $0.id == id })?.isExpired
            } ?? false
        if !isAutomaticallySuppressed,
            currentID == nil || currentIsExpired || phase == .hidden || phase == .exiting
        {
            beginDisplaying(id: notice.id, restartReading: true)
        }
        scheduleExpiryTimer()
        publish()
        return .accepted
    }

    @discardableResult
    public func accept<S: Sequence>(contentsOf notices: S) -> [EventNoticeAcceptance]
    where S.Element == HostEventNotice {
        notices.map(accept)
    }

    public func setHovering(_ isHovering: Bool) {
        setPauseReason(.hover, active: isHovering)
    }

    public func setKeyboardFocused(_ isFocused: Bool) {
        setPauseReason(.keyboardFocus, active: isFocused)
    }

    public func setExpanded(_ expanded: Bool) {
        if expanded {
            openRecent()
        } else {
            closeRecent()
        }
    }

    /// Explicitly opening the recent list is a reread action: it freezes the visible list and
    /// gives the selected notice a fresh four-second reading interval.
    public func openRecent() {
        expireEntries()
        guard !entries.isEmpty else { return }
        let id = selectedID ?? currentID ?? entries.last?.id
        guard let id else { return }

        selectedID = id
        isExpanded = true
        frozenIDs = Set(entries.map(\.id))
        pauseReasons.insert(.expanded)
        if currentID != id || phase == .hidden || phase == .exiting {
            beginDisplaying(id: id, restartReading: true)
        } else {
            restartReadingInterval()
        }
        publish()
    }

    public func closeRecent() {
        guard isExpanded || pauseReasons.contains(.expanded) else { return }
        isExpanded = false
        frozenIDs.removeAll()
        pauseReasons.remove(.expanded)
        resumeReadingIfPossible()
        publish()
    }

    public func refreshRecent() {
        expireEntries()
        frozenIDs = Set(entries.map(\.id))
        publish()
    }

    public func selectRecent(id: UUID) {
        expireEntries()
        guard entries.contains(where: { $0.id == id }) else { return }
        selectedID = id
        isExpanded = true
        pauseReasons.insert(.expanded)
        if !frozenIDs.contains(id) { frozenIDs.insert(id) }
        beginDisplaying(id: id, restartReading: true)
        publish()
    }

    public func dismiss(animated: Bool = true) {
        guard phase != .hidden else { return }
        isExpanded = false
        frozenIDs.removeAll()
        pauseReasons = []
        currentDeadline = nil
        pausedRemaining = nil
        invalidatePresentationTimer()
        if !animated || usesReducedMotion {
            finishDismissal()
            return
        }
        phase = .exiting
        let revision = presentationRevision
        presentationTimer = scheduler.schedule(after: Self.fadeDuration) { [weak self] in
            guard let self, self.presentationRevision == revision else { return }
            self.finishDismissal()
        }
        publish()
    }

    public func hideImmediately() {
        guard phase != .hidden || currentID != nil else { return }
        invalidatePresentationTimer()
        if let currentID { mark(id: currentID, status: .collapsed) }
        phase = .hidden
        currentID = nil
        selectedID = nil
        isExpanded = false
        frozenIDs.removeAll()
        pauseReasons = []
        currentDeadline = nil
        pausedRemaining = nil
        publish()
    }

    /// Dynamic Quiet suppresses automatic display only. Releasing quiet does not replay records
    /// that arrived during the quiet interval.
    public func setAutomaticallySuppressed(_ suppressed: Bool) {
        guard isAutomaticallySuppressed != suppressed else { return }
        isAutomaticallySuppressed = suppressed
        if suppressed { hideImmediately() }
        publish()
    }

    public func setReducedMotion(_ reducedMotion: Bool) {
        guard usesReducedMotion != reducedMotion else { return }
        usesReducedMotion = reducedMotion
        if reducedMotion, (phase == .entering || phase == .exiting) {
            invalidatePresentationTimer()
            if phase == .entering {
                completeEntrance()
            } else {
                finishDismissal()
            }
        }
        publish()
    }

    /// Turning the preference off is a privacy boundary. The epoch changes so in-flight packets
    /// from the previous enabled period cannot be accepted after the preference is restored.
    public func setEnabled(_ enabled: Bool) {
        guard isEnabled != enabled else { return }
        isEnabled = enabled
        clearPresentationAndRecords(newReceiverEpoch: UUID())
        publish(immediateBadge: true)
    }

    public func clearForPrivacy(newReceiverEpoch: UUID = UUID()) {
        clearPresentationAndRecords(newReceiverEpoch: newReceiverEpoch)
        publish(immediateBadge: true)
    }

    public func replaceReceiverEpoch(_ epoch: UUID) {
        guard receiverEpoch != epoch else { return }
        clearPresentationAndRecords(newReceiverEpoch: epoch)
        publish(immediateBadge: true)
    }

    public func setPauseReason(_ reason: EventNoticePauseReason, active: Bool) {
        let wasPaused = !pauseReasons.isEmpty
        if active { pauseReasons.insert(reason) } else { pauseReasons.remove(reason) }
        let isPaused = !pauseReasons.isEmpty
        guard wasPaused != isPaused else {
            publish()
            return
        }

        expireEntries()
        if isPaused {
            if phase == .visible, let deadline = currentDeadline {
                pausedRemaining = max(0, deadline - now())
                currentDeadline = nil
                invalidatePresentationTimer()
            }
        } else {
            resumeReadingIfPossible()
        }
        publish()
    }

    /// Useful for deterministic tests and for a future diagnostics surface. Production timers
    /// call the same expiration path through the injected scheduler.
    public func expireNow() {
        expireEntries()
        publish()
    }

    private func beginDisplaying(id: UUID, restartReading: Bool) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        if let currentID, currentID != id {
            mark(id: currentID, status: .collapsed)
        }
        currentID = id
        selectedID = id
        entries[index].status = .displayed
        if entries[index].isExpired {
            phase = .visible
            currentDeadline = nil
            pausedRemaining = nil
            invalidatePresentationTimer()
            return
        }
        phase = .entering
        currentDeadline = nil
        pausedRemaining = nil
        invalidatePresentationTimer()
        let delay = usesReducedMotion ? 0 : Self.fadeDuration
        let revision = presentationRevision
        presentationTimer = scheduler.schedule(after: delay) { [weak self] in
            guard let self, self.presentationRevision == revision else { return }
            self.completeEntrance()
        }
        if !restartReading { return }
    }

    private func completeEntrance() {
        guard phase == .entering, let currentID,
            let entry = entries.first(where: { $0.id == currentID })
        else { return }
        phase = .visible
        presentationTimer = nil
        guard !entry.isExpired else {
            currentDeadline = nil
            pausedRemaining = nil
            publish()
            return
        }
        if pauseReasons.isEmpty {
            currentDeadline = now() + Self.displayDuration
            pausedRemaining = nil
            scheduleReadingTimeout()
        } else {
            currentDeadline = nil
            pausedRemaining = Self.displayDuration
        }
        publish()
    }

    private func restartReadingInterval() {
        guard let currentID,
            let entry = entries.first(where: { $0.id == currentID })
        else { return }
        phase = .visible
        currentDeadline = nil
        pausedRemaining = Self.displayDuration
        invalidatePresentationTimer()
        guard !entry.isExpired else {
            pausedRemaining = nil
            return
        }
        if pauseReasons.isEmpty {
            currentDeadline = now() + Self.displayDuration
            pausedRemaining = nil
            scheduleReadingTimeout()
        }
    }

    private func resumeReadingIfPossible() {
        guard phase == .visible, let currentID, pauseReasons.isEmpty,
            let entry = entries.first(where: { $0.id == currentID }), !entry.isExpired
        else { return }
        let duration = pausedRemaining ?? Self.displayDuration
        currentDeadline = now() + max(0, duration)
        pausedRemaining = nil
        scheduleReadingTimeout()
    }

    private func scheduleReadingTimeout() {
        invalidatePresentationTimer()
        guard let currentDeadline else { return }
        let revision = presentationRevision
        presentationTimer = scheduler.schedule(after: max(0, currentDeadline - now())) {
            [weak self] in
            guard let self, self.presentationRevision == revision else { return }
            self.expireDisplayedNotice()
        }
    }

    private func expireDisplayedNotice() {
        guard phase == .visible, currentID != nil, pauseReasons.isEmpty else { return }
        currentDeadline = nil
        pausedRemaining = nil
        phase = .exiting
        invalidatePresentationTimer()
        let revision = presentationRevision
        presentationTimer = scheduler.schedule(after: usesReducedMotion ? 0 : Self.fadeDuration) {
            [weak self] in
            guard let self, self.presentationRevision == revision else { return }
            self.finishDismissal()
        }
        publish()
    }

    private func finishDismissal() {
        presentationTimer = nil
        if let currentID { mark(id: currentID, status: .collapsed) }
        currentID = nil
        selectedID = nil
        phase = .hidden
        currentDeadline = nil
        pausedRemaining = nil
        publish()
    }

    private func mark(id: UUID, status: EventNoticeRecordStatus) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].status = status
    }

    private func clearPresentationAndRecords(newReceiverEpoch: UUID) {
        invalidatePresentationTimer()
        invalidateExpiryTimer()
        receiverEpoch = newReceiverEpoch
        entries.removeAll()
        currentID = nil
        selectedID = nil
        frozenIDs.removeAll()
        phase = .hidden
        pauseReasons = []
        isExpanded = false
        currentDeadline = nil
        pausedRemaining = nil
        droppedCount = 0
    }

    @discardableResult
    private func expireEntries() -> Bool {
        let currentTime = now()
        var changed = false
        for index in entries.indices
        where !entries[index].isExpired && entries[index].expiresAt <= currentTime {
            entries[index].isExpired = true
            entries[index].notice = nil
            changed = true
            if entries[index].id == currentID {
                currentDeadline = nil
                pausedRemaining = nil
                invalidatePresentationTimer()
                if phase != .hidden { phase = .visible }
            }
        }
        let countBeforeRemoval = entries.count
        entries.removeAll { entry in
            entry.isExpired && entry.id != currentID && entry.id != selectedID
        }
        let removed = entries.count != countBeforeRemoval
        if changed { scheduleExpiryTimer() }
        return changed || removed
    }

    private func scheduleExpiryTimer() {
        invalidateExpiryTimer()
        guard
            let nextExpiry =
                entries
                .filter({ !$0.isExpired })
                .map(\.expiresAt)
                .min()
        else { return }
        let revision = expiryRevision
        expiryTimer = scheduler.schedule(after: max(0, nextExpiry - now())) { [weak self] in
            guard let self, self.expiryRevision == revision else { return }
            self.expireEntries()
            self.publish()
        }
    }

    private func invalidatePresentationTimer() {
        presentationRevision &+= 1
        presentationTimer?.cancel()
        presentationTimer = nil
    }

    private func invalidateExpiryTimer() {
        expiryRevision &+= 1
        expiryTimer?.cancel()
        expiryTimer = nil
    }

    private func invalidateBadgeTimer() {
        badgeRevision &+= 1
        badgeTimer?.cancel()
        badgeTimer = nil
    }

    private func visibleEntries() -> [Entry] {
        let filtered: [Entry]
        if isExpanded, !frozenIDs.isEmpty {
            filtered = entries.filter { frozenIDs.contains($0.id) }
        } else {
            filtered = entries
        }
        return filtered.sorted {
            ($0.expiresAt, $0.arrivalOrdinal) > ($1.expiresAt, $1.arrivalOrdinal)
        }
    }

    private func record(_ entry: Entry) -> EventNoticeRecord {
        EventNoticeRecord(
            id: entry.id,
            event: entry.event,
            occurredAt: entry.notice?.occurredAt,
            notice: entry.notice,
            status: entry.status,
            isExpired: entry.isExpired)
    }

    private func publish(immediateBadge: Bool = false) {
        let previousPendingCount = snapshot.pendingCount
        let recentEntries = visibleEntries()
        let recent = recentEntries.map(record)
        let current = currentID.flatMap { id in
            entries.first(where: { $0.id == id }).map(record)
        }
        let pendingCount: Int
        if isExpanded {
            pendingCount = max(0, entries.count - frozenIDs.count)
        } else if currentID == nil {
            pendingCount = entries.count
        } else {
            pendingCount = max(0, entries.count - 1)
        }
        let remaining: TimeInterval?
        if let currentDeadline {
            remaining = max(0, currentDeadline - now())
        } else {
            remaining = pausedRemaining
        }
        snapshot = EventNoticeModelSnapshot(
            phase: phase,
            current: current,
            recent: recent,
            pendingCount: pendingCount,
            pauseReasons: pauseReasons,
            remainingTime: remaining,
            isExpanded: isExpanded,
            droppedCount: droppedCount,
            receiverEpoch: receiverEpoch)

        if immediateBadge {
            invalidateBadgeTimer()
            badgeCount = pendingCount
        } else if previousPendingCount != pendingCount {
            invalidateBadgeTimer()
            let revision = badgeRevision
            badgeTimer = scheduler.schedule(after: 0.1) { [weak self] in
                guard let self, self.badgeRevision == revision else { return }
                self.badgeCount = self.snapshot.pendingCount
                self.badgeTimer = nil
            }
        }
    }
}
