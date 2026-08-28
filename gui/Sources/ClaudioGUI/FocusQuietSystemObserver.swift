import AppKit
import ClaudioCore
import ClaudioGUICore
@preconcurrency import Combine
import Foundation
@preconcurrency import Intents
@preconcurrency import UserNotifications

/// Owns Focus observation for the application lifetime. It is constructed with the retained
/// Settings owner, not by the Notifications page, so navigation and window close never stop an
/// enabled policy. The short polling interval continually refreshes a 12-second snapshot; an
/// unavailable Focus value publishes false and becomes a visible observer failure.
@MainActor
final class FocusQuietSystemObserver: NSObject {
    let policy: FocusQuietPolicyController

    private let center: INFocusStatusCenter
    private let notificationCenter: UNUserNotificationCenter
    private let notificationAuthorization: FocusQuietNotificationAuthorizationBox
    private var timer: Timer?
    private var activationCancellable: AnyCancellable?

    override init() {
        center = .default
        notificationCenter = .current()
        notificationAuthorization = FocusQuietNotificationAuthorizationBox()
        let center = center
        let notificationCenter = notificationCenter
        let notificationAuthorization = notificationAuthorization
        let publisher = DynamicQuietSnapshotPublisher(
            snapshotFile: ClaudioPaths.dynamicQuietSnapshotFile,
            revisionStateFile: ClaudioPaths.dynamicQuietRevisionStateFile)
        policy = FocusQuietPolicyController(
            defaults: .standard,
            readSystemState: {
                focusQuietSystemState(
                    center: center,
                    notificationAuthorization: notificationAuthorization.value)
            },
            requestAuthorization: { completion in
                // Apple only supplies Focus status when both User Notifications and Focus Status
                // are authorized and the app carries Communication Notifications capability.
                // This closure is reached only from the user's explicit off -> on transition.
                notificationCenter.requestAuthorization(options: [.alert]) { _, _ in
                    center.requestAuthorization { focusAuthorization in
                        notificationCenter.getNotificationSettings { settings in
                            Task { @MainActor in
                                notificationAuthorization.value =
                                    focusQuietNotificationAuthorization(
                                        settings.authorizationStatus)
                                completion(
                                    focusQuietSystemState(
                                        center: center,
                                        notificationAuthorization:
                                            notificationAuthorization.value,
                                        focusAuthorizationOverride: focusAuthorization))
                            }
                        }
                    }
                }
            },
            publish: { focusActive, now in
                if case .success = publisher.publish(
                    focusActive: focusActive,
                    now: now,
                    lifetime: 12)
                {
                    return true
                }
                return false
            })
        super.init()

        timer = Timer.scheduledTimer(
            timeInterval: 5,
            target: self,
            selector: #selector(refreshFocusState),
            userInfo: nil,
            repeats: true)
        activationCancellable = NotificationCenter.default
            .publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.refreshFocusState()
                }
            }
        refreshFocusState()
    }

    @objc private func refreshFocusState() {
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
