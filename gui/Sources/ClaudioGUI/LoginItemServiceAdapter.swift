import AppKit
import ClaudioGUICore
import Combine
import ServiceManagement

@MainActor
func makeSystemLoginItemServiceAdapter(bundle: Bundle = .main) -> (
    status: () -> LoginItemRegistrationState,
    setEnabled: (Bool) throws -> LoginItemRegistrationState,
    openSystemSettings: (() -> Void)?
) {
    if #available(macOS 13.0, *) {
        let service = SMAppService.mainApp
        return makeModernLoginItemServiceAdapter(
            status: { service.status.rawValue },
            notRegisteredValue: SMAppService.Status.notRegistered.rawValue,
            enabledValue: SMAppService.Status.enabled.rawValue,
            requiresApprovalValue: SMAppService.Status.requiresApproval.rawValue,
            notFoundValue: SMAppService.Status.notFound.rawValue,
            register: { try service.register() },
            unregister: { try service.unregister() },
            openSystemSettings: {
                SMAppService.openSystemSettingsLoginItems()
            })
    }

    let embeddedBundleURL = bundle.bundleURL
        .appendingPathComponent("Contents/Library/LoginItems", isDirectory: true)
        .appendingPathComponent(claudioLegacyLoginItemBundleName, isDirectory: true)
    return makeLegacyLoginItemServiceAdapter(
        embeddedBundleURL: embeddedBundleURL,
        registrationIsEnabled: legacyLoginItemIsRegistered,
        setEnabled: { identifier, enabled in
            SMLoginItemSetEnabled(identifier as CFString, enabled)
        })
}

/// Apple's ServiceManagement header keeps this deprecated API as the recommended macOS 12 query
/// for showing the state of a login item registered through `SMLoginItemSetEnabled`.
private func legacyLoginItemIsRegistered(_ identifier: String) -> Bool? {
    guard
        let unmanagedJobs = SMCopyAllJobDictionaries(kSMDomainUserLaunchd),
        let jobs = unmanagedJobs.takeRetainedValue() as? [[String: Any]]
    else {
        return nil
    }
    return jobs.contains { $0["Label"] as? String == identifier }
}

/// SwiftUI observation stays in the executable target; the Foundation-only projector remains the
/// single owner of registration, failure-preservation, and retry behavior.
@MainActor
final class LoginItemSettingsModel: ObservableObject {
    @Published private(set) var projection:
        (
            registration: LoginItemRegistrationState,
            failure: (
                requestedEnabled: Bool,
                reason: LoginItemOperationFailureReason
            )?
        )
    private let adapter:
        (
            status: () -> LoginItemRegistrationState,
            setEnabled: (Bool) throws -> LoginItemRegistrationState,
            openSystemSettings: (() -> Void)?
        )

    init(
        adapter: (
            status: () -> LoginItemRegistrationState,
            setEnabled: (Bool) throws -> LoginItemRegistrationState,
            openSystemSettings: (() -> Void)?
        )
    ) {
        self.adapter = adapter
        projection = makeLoginItemSettingsProjection(registration: adapter.status())
    }

    func refresh() {
        projection = makeLoginItemSettingsProjection(registration: adapter.status())
    }

    func setEnabled(_ enabled: Bool) {
        projection = projectLoginItemRequest(enabled, from: projection, using: adapter)
    }

    func retryFailedOperation() {
        guard let failure = projection.failure else { return }
        projection = projectLoginItemRequest(
            failure.requestedEnabled,
            from: makeLoginItemSettingsProjection(registration: projection.registration),
            using: adapter)
    }

    func openSystemSettings() {
        adapter.openSystemSettings?()
    }
}
