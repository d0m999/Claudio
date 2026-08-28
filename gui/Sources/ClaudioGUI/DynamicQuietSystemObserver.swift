import AppKit
import ClaudioCore
import ClaudioGUICore
@preconcurrency import Combine
@preconcurrency import EventKit
import Foundation
@preconcurrency import Intents
@preconcurrency import UserNotifications

/// Owns Focus and Calendar observation for the application lifetime. It is constructed with the
/// retained Settings owner, not by the Notifications page, so navigation and window close never
/// stop an enabled policy. Every signal republishes both minimized reasons in one short-lived
/// Dynamic Quiet State snapshot.
@MainActor
final class DynamicQuietSystemObserver: NSObject {
    let policy: DynamicQuietPolicyController

    private let focusCenter: INFocusStatusCenter
    private let notificationCenter: UNUserNotificationCenter
    private let notificationAuthorization: FocusQuietNotificationAuthorizationBox
    private let calendarAdapter: CalendarQuietEventStoreAdapter
    private var timer: Timer?
    private var cancellables: Set<AnyCancellable> = []

    override init() {
        focusCenter = .default
        notificationCenter = .current()
        notificationAuthorization = FocusQuietNotificationAuthorizationBox()
        calendarAdapter = CalendarQuietEventStoreAdapter()
        let focusCenter = focusCenter
        let notificationCenter = notificationCenter
        let notificationAuthorization = notificationAuthorization
        let calendarAdapter = calendarAdapter
        let publisher = DynamicQuietSnapshotPublisher(
            snapshotFile: ClaudioPaths.dynamicQuietSnapshotFile,
            revisionStateFile: ClaudioPaths.dynamicQuietRevisionStateFile)
        policy = DynamicQuietPolicyController(
            defaults: .standard,
            readFocusState: {
                focusQuietSystemState(
                    center: focusCenter,
                    notificationAuthorization: notificationAuthorization.value)
            },
            requestFocusAuthorization: { completion in
                // This closure is reached only from the user's explicit Focus off -> on change.
                notificationCenter.requestAuthorization(options: [.alert]) { _, _ in
                    focusCenter.requestAuthorization { focusAuthorization in
                        notificationCenter.getNotificationSettings { settings in
                            Task { @MainActor in
                                notificationAuthorization.value =
                                    focusQuietNotificationAuthorization(
                                        settings.authorizationStatus)
                                completion(
                                    focusQuietSystemState(
                                        center: focusCenter,
                                        notificationAuthorization:
                                            notificationAuthorization.value,
                                        focusAuthorizationOverride: focusAuthorization))
                            }
                        }
                    }
                }
            },
            readCalendarState: { includeEvents in
                calendarAdapter.systemState(includeEvents: includeEvents)
            },
            requestCalendarAuthorization: { completion in
                calendarAdapter.requestAuthorization(completion)
            },
            publish: { focusActive, calendarBusy, now in
                if case .success(let snapshot) = publisher.publish(
                    focusActive: focusActive,
                    calendarBusy: calendarBusy,
                    now: now)
                {
                    return Date(timeIntervalSince1970: snapshot.expiresAtEpochSeconds)
                }
                return nil
            })
        super.init()

        timer = Timer.scheduledTimer(
            timeInterval: 5,
            target: self,
            selector: #selector(refreshDynamicQuietState),
            userInfo: nil,
            repeats: true)
        installRefreshSignals()
        refreshDynamicQuietState()
    }

    private func installRefreshSignals() {
        NotificationCenter.default
            .publisher(for: NSApplication.didBecomeActiveNotification)
            .merge(with: NotificationCenter.default.publisher(for: .EKEventStoreChanged))
            .merge(
                with: NotificationCenter.default.publisher(
                    for: NSNotification.Name.NSSystemTimeZoneDidChange)
            )
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.refreshDynamicQuietState()
                }
            }
            .store(in: &cancellables)

        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didWakeNotification)
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.refreshDynamicQuietState()
                }
            }
            .store(in: &cancellables)
    }

    @objc private func refreshDynamicQuietState() {
        notificationCenter.getNotificationSettings { [weak self] settings in
            Task { @MainActor in
                guard let self else { return }
                self.notificationAuthorization.value = focusQuietNotificationAuthorization(
                    settings.authorizationStatus)
                self.policy.refresh()
            }
        }
    }
}

private enum FocusQuietNotificationAuthorization {
    case notRequested
    case authorized
    case denied
}

@MainActor
private final class FocusQuietNotificationAuthorizationBox {
    var value: FocusQuietNotificationAuthorization = .notRequested
}

private func focusQuietNotificationAuthorization(
    _ status: UNAuthorizationStatus
) -> FocusQuietNotificationAuthorization {
    switch status {
    case .notDetermined:
        return .notRequested
    case .authorized, .provisional:
        return .authorized
    case .denied:
        return .denied
    @unknown default:
        return .denied
    }
}

@MainActor
private func focusQuietSystemState(
    center: INFocusStatusCenter,
    notificationAuthorization: FocusQuietNotificationAuthorization,
    focusAuthorizationOverride: INFocusStatusAuthorizationStatus? = nil
) -> FocusQuietSystemState {
    switch notificationAuthorization {
    case .notRequested:
        return FocusQuietSystemState(authorization: .notRequested, isFocused: nil)
    case .denied:
        return FocusQuietSystemState(authorization: .denied, isFocused: nil)
    case .authorized:
        break
    }

    let authorization = focusAuthorizationOverride ?? center.authorizationStatus
    switch authorization {
    case .notDetermined:
        return FocusQuietSystemState(authorization: .notRequested, isFocused: nil)
    case .restricted:
        return FocusQuietSystemState(authorization: .restricted, isFocused: nil)
    case .denied:
        return FocusQuietSystemState(authorization: .denied, isFocused: nil)
    case .authorized:
        return FocusQuietSystemState(
            authorization: .authorized,
            isFocused: center.focusStatus.isFocused)
    @unknown default:
        return FocusQuietSystemState(authorization: .restricted, isFocused: nil)
    }
}

@MainActor
private final class CalendarQuietEventStoreAdapter {
    private let eventStore: EKEventStore
    private let adapter: CalendarQuietEventAdapter

    init(
        eventStore: EKEventStore = EKEventStore(),
        now: @escaping @MainActor () -> Date = { Date() }
    ) {
        self.eventStore = eventStore
        let accessRequirement: CalendarQuietAccessRequirement
        if #available(macOS 14.0, *) {
            accessRequirement = .fullAccess
        } else {
            accessRequirement = .legacyRead
        }
        adapter = CalendarQuietEventAdapter(
            accessRequirement: accessRequirement,
            readAccessStatus: {
                calendarQuietAccessStatus(EKEventStore.authorizationStatus(for: .event))
            },
            readEvents: { query in
                let predicate = eventStore.predicateForEvents(
                    withStart: query.startsAt,
                    end: query.endsAt,
                    calendars: nil)
                return eventStore.events(matching: predicate).map { event in
                    CalendarQuietEventFacts(
                        startsAt: event.startDate,
                        endsAt: event.endDate,
                        isAllDay: event.isAllDay,
                        availability: calendarQuietAvailability(event.availability))
                }
            },
            now: now)
    }

    func requestAuthorization(
        _ completion: @escaping @MainActor (CalendarQuietSystemState) -> Void
    ) {
        // This method is reached only from the user's explicit Calendar off -> on change.
        if #available(macOS 14.0, *) {
            eventStore.requestFullAccessToEvents { [weak self] _, _ in
                Task { @MainActor in
                    guard let self else { return }
                    completion(self.systemState(includeEvents: true))
                }
            }
        } else {
            eventStore.requestAccess(to: .event) { [weak self] _, _ in
                Task { @MainActor in
                    guard let self else { return }
                    completion(self.systemState(includeEvents: true))
                }
            }
        }
    }

    func systemState(includeEvents: Bool) -> CalendarQuietSystemState {
        adapter.systemState(includeEvents: includeEvents)
    }
}

private func calendarQuietAccessStatus(
    _ status: EKAuthorizationStatus
) -> CalendarQuietAccessStatus {
    if #available(macOS 14.0, *) {
        switch status {
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        case .authorized: return .authorized
        case .fullAccess: return .fullAccess
        case .writeOnly: return .writeOnly
        @unknown default: return .restricted
        }
    }
    if status == .notDetermined { return .notDetermined }
    if status == .restricted { return .restricted }
    if status == .authorized { return .authorized }
    return .denied
}

private func calendarQuietAvailability(
    _ availability: EKEventAvailability
) -> CalendarQuietAvailability {
    switch availability {
    case .busy:
        return .busy
    case .free:
        return .free
    case .tentative, .unavailable, .notSupported:
        return .other
    @unknown default:
        return .other
    }
}
