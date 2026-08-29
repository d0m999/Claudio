import Combine
import Foundation

public enum FocusQuietAuthorization: String, Sendable, Equatable {
    case notRequested = "not_requested"
    case authorized
    case denied
    case restricted
}

/// `isFocused == nil` while authorized is an observer failure, not "Focus inactive".
public struct FocusQuietSystemState: Sendable, Equatable {
    public let authorization: FocusQuietAuthorization
    public let isFocused: Bool?

    public init(authorization: FocusQuietAuthorization, isFocused: Bool?) {
        self.authorization = authorization
        self.isFocused = isFocused
    }
}

public enum CalendarQuietAuthorization: String, Sendable, Equatable {
    case notRequested = "not_requested"
    case authorized
    case denied
    case restricted
}

public enum CalendarQuietAvailability: String, Sendable, Equatable {
    case busy
    case free
    case other
}

/// EventKit objects are reduced to this deliberately small value at the adapter boundary.
/// The type cannot carry title, location, URL, attendees, notes, or Calendar identity.
public struct CalendarQuietEventFacts: Sendable, Equatable {
    public let startsAt: Date
    public let endsAt: Date
    public let isAllDay: Bool
    public let availability: CalendarQuietAvailability

    public init(
        startsAt: Date,
        endsAt: Date,
        isAllDay: Bool,
        availability: CalendarQuietAvailability
    ) {
        self.startsAt = startsAt
        self.endsAt = endsAt
        self.isAllDay = isAllDay
        self.availability = availability
    }
}

/// `events == nil` while authorized is an observer failure, not an empty calendar.
public struct CalendarQuietSystemState: Sendable, Equatable {
    public let authorization: CalendarQuietAuthorization
    public let events: [CalendarQuietEventFacts]?

    public init(
        authorization: CalendarQuietAuthorization,
        events: [CalendarQuietEventFacts]?
    ) {
        self.authorization = authorization
        self.events = events
    }
}

/// EventKit authorization reduced to platform-independent cases at the GUI adapter boundary.
/// Keeping this vocabulary outside EventKit makes the macOS 12-13 and 14+ contracts testable.
public enum CalendarQuietAccessStatus: Sendable, Equatable {
    case notDetermined
    case restricted
    case denied
    case authorized
    case fullAccess
    case writeOnly
}

public enum CalendarQuietAccessRequirement: Sendable, Equatable {
    /// `EKAuthorizationStatus.authorized` on macOS 12-13.
    case legacyRead
    /// `EKAuthorizationStatus.fullAccess` on macOS 14+.
    case fullAccess
}

public struct CalendarQuietEventQuery: Sendable, Equatable {
    public let startsAt: Date
    public let endsAt: Date

    public init(startsAt: Date, endsAt: Date) {
        self.startsAt = startsAt
        self.endsAt = endsAt
    }
}

/// Injectable, clock-driven seam used by the concrete EventKit adapter. The query is deliberately
/// limited to one second from `now`; returned events are already reduced to privacy-safe facts.
@MainActor
public struct CalendarQuietEventAdapter {
    private let accessRequirement: CalendarQuietAccessRequirement
    private let readAccessStatus: @MainActor () -> CalendarQuietAccessStatus
    private let readEvents: @MainActor (CalendarQuietEventQuery) -> [CalendarQuietEventFacts]
    private let now: @MainActor () -> Date

    public init(
        accessRequirement: CalendarQuietAccessRequirement,
        readAccessStatus: @escaping @MainActor () -> CalendarQuietAccessStatus,
        readEvents: @escaping @MainActor (CalendarQuietEventQuery) -> [CalendarQuietEventFacts],
        now: @escaping @MainActor () -> Date
    ) {
        self.accessRequirement = accessRequirement
        self.readAccessStatus = readAccessStatus
        self.readEvents = readEvents
        self.now = now
    }

    public func systemState(includeEvents: Bool) -> CalendarQuietSystemState {
        let authorization = calendarQuietAuthorization(
            accessStatus: readAccessStatus(),
            requirement: accessRequirement)
        guard authorization == .authorized else {
            return CalendarQuietSystemState(authorization: authorization, events: nil)
        }
        guard includeEvents else {
            return CalendarQuietSystemState(authorization: .authorized, events: [])
        }

        let queryStart = now()
        let query = CalendarQuietEventQuery(
            startsAt: queryStart,
            endsAt: queryStart.addingTimeInterval(1))
        return CalendarQuietSystemState(
            authorization: .authorized,
            events: readEvents(query))
    }
}

public func calendarQuietAuthorization(
    accessStatus: CalendarQuietAccessStatus,
    requirement: CalendarQuietAccessRequirement
) -> CalendarQuietAuthorization {
    switch accessStatus {
    case .notDetermined:
        return .notRequested
    case .restricted:
        return .restricted
    case .denied, .writeOnly:
        return .denied
    case .authorized:
        return requirement == .legacyRead ? .authorized : .denied
    case .fullAccess:
        return requirement == .fullAccess ? .authorized : .denied
    }
}

/// Calendar busy uses a half-open interval: an event starts suppressing at `startsAt` and stops
/// exactly at `endsAt`. All-day, free, tentative, unavailable, and malformed intervals are ignored.
public func calendarQuietIsBusy(
    events: [CalendarQuietEventFacts],
    at now: Date
) -> Bool {
    events.contains { event in
        !event.isAllDay
            && event.availability == .busy
            && event.startsAt < event.endsAt
            && event.startsAt <= now
            && now < event.endsAt
    }
}

/// Registers the app-lifetime refresh timer in common modes so menu and control tracking cannot
/// suspend renewal of the short-lived Dynamic Quiet snapshot.
@MainActor
package func scheduleDynamicQuietRefreshTimer(
    _ timer: Timer,
    on runLoop: RunLoop = .main
) -> Timer {
    runLoop.add(timer, forMode: .common)
    return timer
}

public enum DynamicQuietCurrentReason: String, Sendable, Equatable {
    case policiesDisabled = "policies_disabled"
    case permissionRequired = "permission_required"
    case noDynamicQuiet = "no_dynamic_quiet"
    case focusActive = "focus_active"
    case calendarBusy = "calendar_busy"
    case focusAndCalendarBusy = "focus_and_calendar_busy"
    case observerFailure = "observer_failure"
}

public enum DynamicQuietSnapshotHealth: String, Sendable, Equatable {
    case current
    case publicationFailed = "publication_failed"
    case expired
}

public struct DynamicQuietPresentation: Sendable, Equatable {
    public let focusIsEnabled: Bool
    public let focusAuthorization: FocusQuietAuthorization
    public let calendarIsEnabled: Bool
    public let calendarAuthorization: CalendarQuietAuthorization
    public let currentReason: DynamicQuietCurrentReason
    public let hasObserverFailure: Bool
    public let snapshotHealth: DynamicQuietSnapshotHealth

    public init(
        focusIsEnabled: Bool,
        focusAuthorization: FocusQuietAuthorization,
        calendarIsEnabled: Bool,
        calendarAuthorization: CalendarQuietAuthorization,
        currentReason: DynamicQuietCurrentReason,
        hasObserverFailure: Bool,
        snapshotHealth: DynamicQuietSnapshotHealth
    ) {
        self.focusIsEnabled = focusIsEnabled
        self.focusAuthorization = focusAuthorization
        self.calendarIsEnabled = calendarIsEnabled
        self.calendarAuthorization = calendarAuthorization
        self.currentReason = currentReason
        self.hasObserverFailure = hasObserverFailure
        self.snapshotHealth = snapshotHealth
    }
}

/// App-lifetime Dynamic Quiet State owner. The system adapter supplies two independent minimized
/// facts, while this controller is the only place that combines them and publishes one snapshot.
@MainActor
public final class DynamicQuietPolicyController: ObservableObject {
    public static let focusDefaultsKey = "Claudio.Notifications.FocusQuietEnabled"
    public static let calendarDefaultsKey = "Claudio.Notifications.CalendarQuietEnabled"

    @Published public private(set) var presentation: DynamicQuietPresentation

    private let defaults: UserDefaults
    private let readFocusState: @MainActor () -> FocusQuietSystemState
    private let requestFocusAuthorization:
        @MainActor (@escaping @MainActor (FocusQuietSystemState) -> Void) -> Void
    private let readCalendarState: @MainActor (Bool) -> CalendarQuietSystemState
    private let requestCalendarAuthorization:
        @MainActor (@escaping @MainActor (CalendarQuietSystemState) -> Void) -> Void
    /// Returns the expiry written into the successfully published snapshot, or `nil` on failure.
    private let publish: @MainActor (Bool, Bool, Date) -> Date?
    private let now: @MainActor () -> Date
    private var lastSuccessfulPublicationExpiry: Date?

    public init(
        defaults: UserDefaults,
        readFocusState: @escaping @MainActor () -> FocusQuietSystemState,
        requestFocusAuthorization:
            @escaping @MainActor (
                @escaping @MainActor (FocusQuietSystemState) -> Void
            ) -> Void,
        readCalendarState: @escaping @MainActor (Bool) -> CalendarQuietSystemState,
        requestCalendarAuthorization:
            @escaping @MainActor (
                @escaping @MainActor (CalendarQuietSystemState) -> Void
            ) -> Void,
        publish: @escaping @MainActor (Bool, Bool, Date) -> Date?,
        now: @escaping @MainActor () -> Date = { Date() }
    ) {
        self.defaults = defaults
        self.readFocusState = readFocusState
        self.requestFocusAuthorization = requestFocusAuthorization
        self.readCalendarState = readCalendarState
        self.requestCalendarAuthorization = requestCalendarAuthorization
        self.publish = publish
        self.now = now

        let focusEnabled = defaults.object(forKey: Self.focusDefaultsKey) as? Bool ?? false
        let calendarEnabled = defaults.object(forKey: Self.calendarDefaultsKey) as? Bool ?? false
        let focusState = readFocusState()
        let calendarState = readCalendarState(calendarEnabled)
        presentation = DynamicQuietPresentation(
            focusIsEnabled: focusEnabled,
            focusAuthorization: focusState.authorization,
            calendarIsEnabled: calendarEnabled,
            calendarAuthorization: calendarState.authorization,
            currentReason: .policiesDisabled,
            hasObserverFailure: false,
            snapshotHealth: .expired)
        apply(
            focusState: focusState,
            calendarState: calendarState,
            focusEnabled: focusEnabled,
            calendarEnabled: calendarEnabled)
    }

    public func setFocusEnabled(_ enabled: Bool) {
        guard enabled != presentation.focusIsEnabled else { return }
        defaults.set(enabled, forKey: Self.focusDefaultsKey)
        let focusState = readFocusState()
        apply(
            focusState: focusState,
            calendarState: readCalendarState(presentation.calendarIsEnabled),
            focusEnabled: enabled,
            calendarEnabled: presentation.calendarIsEnabled)

        guard enabled, focusState.authorization == .notRequested else { return }
        requestFocusAuthorization { [weak self] authorizedState in
            guard let self, self.presentation.focusIsEnabled else { return }
            self.apply(
                focusState: authorizedState,
                calendarState: self.readCalendarState(self.presentation.calendarIsEnabled),
                focusEnabled: true,
                calendarEnabled: self.presentation.calendarIsEnabled)
        }
    }

    public func setCalendarEnabled(_ enabled: Bool) {
        guard enabled != presentation.calendarIsEnabled else { return }
        defaults.set(enabled, forKey: Self.calendarDefaultsKey)
        let calendarState = readCalendarState(enabled)
        apply(
            focusState: readFocusState(),
            calendarState: calendarState,
            focusEnabled: presentation.focusIsEnabled,
            calendarEnabled: enabled)

        guard enabled, calendarState.authorization == .notRequested else { return }
        requestCalendarAuthorization { [weak self] authorizedState in
            guard let self, self.presentation.calendarIsEnabled else { return }
            self.apply(
                focusState: self.readFocusState(),
                calendarState: authorizedState,
                focusEnabled: self.presentation.focusIsEnabled,
                calendarEnabled: true)
        }
    }

    /// Called by the app-lifetime observer for timer, app activation, EventKit change, wake, and
    /// time-zone change signals. Navigation and window close never participate.
    public func refresh() {
        apply(
            focusState: readFocusState(),
            calendarState: readCalendarState(presentation.calendarIsEnabled),
            focusEnabled: presentation.focusIsEnabled,
            calendarEnabled: presentation.calendarIsEnabled)
    }

    private func apply(
        focusState: FocusQuietSystemState,
        calendarState: CalendarQuietSystemState,
        focusEnabled: Bool,
        calendarEnabled: Bool
    ) {
        let publicationDate = now()
        let focusActive =
            focusEnabled && focusState.authorization == .authorized
            && focusState.isFocused == true
        let calendarBusy =
            calendarEnabled && calendarState.authorization == .authorized
            && calendarState.events.map { calendarQuietIsBusy(events: $0, at: publicationDate) }
                == true
        let focusObserverFailed =
            focusEnabled && focusState.authorization == .authorized && focusState.isFocused == nil
        let calendarObserverFailed =
            calendarEnabled && calendarState.authorization == .authorized
            && calendarState.events == nil
        let hasObserverFailure = focusObserverFailed || calendarObserverFailed
        let hasPermissionFailure =
            (focusEnabled && focusState.authorization != .authorized)
            || (calendarEnabled && calendarState.authorization != .authorized)

        let reason: DynamicQuietCurrentReason
        switch (focusActive, calendarBusy) {
        case (true, true): reason = .focusAndCalendarBusy
        case (true, false): reason = .focusActive
        case (false, true): reason = .calendarBusy
        case (false, false) where hasObserverFailure: reason = .observerFailure
        case (false, false) where hasPermissionFailure: reason = .permissionRequired
        case (false, false) where !focusEnabled && !calendarEnabled: reason = .policiesDisabled
        case (false, false): reason = .noDynamicQuiet
        }

        let publishedExpiry = publish(focusActive, calendarBusy, publicationDate)
        let health: DynamicQuietSnapshotHealth
        if let publishedExpiry {
            lastSuccessfulPublicationExpiry = publishedExpiry
            health = publicationDate < publishedExpiry ? .current : .expired
        } else if let expiry = lastSuccessfulPublicationExpiry, publicationDate < expiry {
            health = .publicationFailed
        } else {
            health = .expired
        }

        presentation = DynamicQuietPresentation(
            focusIsEnabled: focusEnabled,
            focusAuthorization: focusState.authorization,
            calendarIsEnabled: calendarEnabled,
            calendarAuthorization: calendarState.authorization,
            currentReason: reason,
            hasObserverFailure: hasObserverFailure,
            snapshotHealth: health)
    }
}
