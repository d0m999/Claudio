import AppKit
import ClaudioGUICore
import ServiceManagement

@MainActor
func makeSystemLoginItemServiceAdapter(bundle: Bundle = .main) -> LoginItemServiceAdapter {
    if #available(macOS 13.0, *) {
        let service = SMAppService.mainApp
        return makeModernLoginItemServiceAdapter(
            status: { service.status.rawValue },
            notRegisteredValue: SMAppService.Status.notRegistered.rawValue,
            enabledValue: SMAppService.Status.enabled.rawValue,
            requiresApprovalValue: SMAppService.Status.requiresApproval.rawValue,
            notFoundValue: SMAppService.Status.notFound.rawValue,
            register: { try service.register() },
            unregister: { try service.unregister() })
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
