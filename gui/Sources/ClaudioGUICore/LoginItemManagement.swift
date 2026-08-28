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

/// Result-level Settings fact. A failure is one optional tuple so requested operation and reason
/// cannot become independently nil while the previously read registration fact stays unchanged.
package func makeLoginItemSettingsProjection(
    registration: LoginItemRegistrationState
) -> (
    registration: LoginItemRegistrationState,
    failure: (
        requestedEnabled: Bool,
        reason: LoginItemOperationFailureReason
    )?
) {
    (registration, nil)
}

/// Injectable ServiceManagement boundary. Production supplies SMAppService/legacy calls while
/// tests own deterministic system status and errors without registering a real login item.
@MainActor
package func makeLoginItemServiceAdapter(
    status: @escaping () -> LoginItemRegistrationState,
    setEnabled: @escaping (Bool) throws -> LoginItemRegistrationState,
    openSystemSettings: (() -> Void)? = nil
) -> (
    status: () -> LoginItemRegistrationState,
    setEnabled: (Bool) throws -> LoginItemRegistrationState,
    openSystemSettings: (() -> Void)?
) {
    (status, setEnabled, openSystemSettings)
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
    status: @escaping () -> Int,
    notRegisteredValue: Int,
    enabledValue: Int,
    requiresApprovalValue: Int,
    notFoundValue: Int,
    register: @escaping () throws -> Void,
    unregister: @escaping () throws -> Void,
    openSystemSettings: @escaping () -> Void
) -> (
    status: () -> LoginItemRegistrationState,
    setEnabled: (Bool) throws -> LoginItemRegistrationState,
    openSystemSettings: (() -> Void)?
) {
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
        },
        openSystemSettings: openSystemSettings)
}

@MainActor
package func makeLegacyLoginItemServiceAdapter(
    embeddedBundleURL: URL,
    registrationIsEnabled: @escaping (String) -> Bool?,
    setEnabled: @escaping (String, Bool) -> Bool
) -> (
    status: () -> LoginItemRegistrationState,
    setEnabled: (Bool) throws -> LoginItemRegistrationState,
    openSystemSettings: (() -> Void)?
) {
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
    from current: (
        registration: LoginItemRegistrationState,
        failure: (
            requestedEnabled: Bool,
            reason: LoginItemOperationFailureReason
        )?
    ),
    using adapter: (
        status: () -> LoginItemRegistrationState,
        setEnabled: (Bool) throws -> LoginItemRegistrationState,
        openSystemSettings: (() -> Void)?
    )
) -> (
    registration: LoginItemRegistrationState,
    failure: (
        requestedEnabled: Bool,
        reason: LoginItemOperationFailureReason
    )?
) {
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
        return (current.registration, (enabled, reason))
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
