import Foundation

package enum LoginItemRegistrationState: Equatable, Sendable {
    case disabled
    case enabled
    case requiresApproval
    case unavailable

    package var isOn: Bool {
        switch self {
        case .enabled, .requiresApproval: true
        case .disabled, .unavailable: false
        }
    }

    package var canToggle: Bool { self != .unavailable }

}

package enum LoginItemOperationFailureReason: Error, Equatable, Sendable {
    case embeddedLoginItemMissing
    case systemRejected
}

package struct LoginItemOperationFailure: Equatable, Sendable {
    package let requestedEnabled: Bool
    package let reason: LoginItemOperationFailureReason

    package init(requestedEnabled: Bool, reason: LoginItemOperationFailureReason) {
        self.requestedEnabled = requestedEnabled
        self.reason = reason
    }
}

package struct LoginItemSettingsProjection: Equatable, Sendable {
    package let registration: LoginItemRegistrationState
    package let failure: LoginItemOperationFailure?

    package init(
        registration: LoginItemRegistrationState,
        failure: LoginItemOperationFailure?
    ) {
        self.registration = registration
        self.failure = failure
    }
}

package struct LoginItemServiceAdapter {
    package let status: @MainActor () -> LoginItemRegistrationState
    package let setEnabled: @MainActor (Bool) throws -> LoginItemRegistrationState

    package init(
        status: @escaping @MainActor () -> LoginItemRegistrationState,
        setEnabled: @escaping @MainActor (Bool) throws -> LoginItemRegistrationState
    ) {
        self.status = status
        self.setEnabled = setEnabled
    }
}

/// Result-level Settings fact. A failure is one optional tuple so requested operation and reason
/// cannot become independently nil while the previously read registration fact stays unchanged.
package func makeLoginItemSettingsProjection(
    registration: LoginItemRegistrationState
) -> LoginItemSettingsProjection {
    LoginItemSettingsProjection(registration: registration, failure: nil)
}

/// Injectable ServiceManagement boundary. Production supplies SMAppService/legacy calls while
/// tests own deterministic system status and errors without registering a real login item.
@MainActor
package func makeLoginItemServiceAdapter(
    status: @escaping @MainActor () -> LoginItemRegistrationState,
    setEnabled: @escaping @MainActor (Bool) throws -> LoginItemRegistrationState
) -> LoginItemServiceAdapter {
    LoginItemServiceAdapter(status: status, setEnabled: setEnabled)
}

package func projectModernLoginItemStatus(
    rawValue: Int,
    notRegisteredValue: Int,
    enabledValue: Int,
    requiresApprovalValue: Int,
    notFoundValue: Int
) -> LoginItemRegistrationState {
    if rawValue == notRegisteredValue { return .disabled }
    if rawValue == enabledValue { return .enabled }
    if rawValue == requiresApprovalValue { return .requiresApproval }
    if rawValue == notFoundValue { return .unavailable }
    return .unavailable
}

@MainActor
package func makeModernLoginItemServiceAdapter(
    status: @escaping @MainActor () -> Int,
    notRegisteredValue: Int,
    enabledValue: Int,
    requiresApprovalValue: Int,
    notFoundValue: Int,
    register: @escaping @MainActor () throws -> Void,
    unregister: @escaping @MainActor () throws -> Void
) -> LoginItemServiceAdapter {
    func projectedStatus() -> LoginItemRegistrationState {
        projectModernLoginItemStatus(
            rawValue: status(),
            notRegisteredValue: notRegisteredValue,
            enabledValue: enabledValue,
            requiresApprovalValue: requiresApprovalValue,
            notFoundValue: notFoundValue)
    }

    return makeLoginItemServiceAdapter(
        status: projectedStatus,
        setEnabled: { enabled in
            do {
                if enabled {
                    try register()
                } else {
                    try unregister()
                }
            } catch {
                throw LoginItemOperationFailureReason.systemRejected
            }
            return projectedStatus()
        })
}

@MainActor
package func makeLegacyLoginItemServiceAdapter(
    embeddedBundleURL: URL,
    registrationIsEnabled: @escaping @MainActor (String) -> Bool?,
    setEnabled: @escaping @MainActor (String, Bool) -> Bool
) -> LoginItemServiceAdapter {
    func projectedStatus() -> LoginItemRegistrationState {
        guard embeddedLegacyLoginItemIsUsable(at: embeddedBundleURL) else {
            return .unavailable
        }
        guard
            let isEnabled = registrationIsEnabled(
                claudioLegacyLoginItemBundleIdentifier)
        else {
            return .unavailable
        }
        return isEnabled ? .enabled : .disabled
    }

    return makeLoginItemServiceAdapter(
        status: projectedStatus,
        setEnabled: { enabled in
            guard embeddedLegacyLoginItemIsUsable(at: embeddedBundleURL) else {
                throw LoginItemOperationFailureReason.embeddedLoginItemMissing
            }
            guard
                setEnabled(claudioLegacyLoginItemBundleIdentifier, enabled),
                registrationIsEnabled(claudioLegacyLoginItemBundleIdentifier) == enabled
            else {
                throw LoginItemOperationFailureReason.systemRejected
            }
            return enabled ? .enabled : .disabled
        })
}

@MainActor
package func projectLoginItemRequest(
    _ enabled: Bool,
    from current: LoginItemSettingsProjection,
    using adapter: LoginItemServiceAdapter
) -> LoginItemSettingsProjection {
    guard current.registration.canToggle, current.registration.isOn != enabled else {
        return current
    }

    do {
        return makeLoginItemSettingsProjection(registration: try adapter.setEnabled(enabled))
    } catch {
        let reason: LoginItemOperationFailureReason =
            if case LoginItemOperationFailureReason.embeddedLoginItemMissing = error {
                .embeddedLoginItemMissing
            } else {
                .systemRejected
            }
        return LoginItemSettingsProjection(
            registration: current.registration,
            failure: LoginItemOperationFailure(requestedEnabled: enabled, reason: reason))
    }
}

package let claudioLegacyLoginItemBundleName = "claudi0 LoginItem.app"
package let claudioLegacyLoginItemBundleIdentifier = "com.claudio.app.login-item"
package let claudioLegacyLoginItemExecutableName = "claudi0-login-item"

/// Validates the exact app layout the macOS 12 compatibility API requires. Packaging gates are
/// responsible for signing this nested app before distribution.
package func embeddedLegacyLoginItemIsUsable(at bundleURL: URL) -> Bool {
    guard let bundle = Bundle(url: bundleURL),
        bundle.bundleIdentifier == claudioLegacyLoginItemBundleIdentifier,
        let executableURL = bundle.executableURL,
        executableURL.lastPathComponent == claudioLegacyLoginItemExecutableName,
        FileManager.default.isExecutableFile(atPath: executableURL.path)
    else {
        return false
    }
    return true
}
