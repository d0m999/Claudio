import AppKit
import ClaudioSettingsPresentation
import ServiceManagement

/// Native adapter for the closed Settings platform-action vocabulary. System frameworks and
/// availability checks stay in the executable; the importable presentation target receives only
/// typed results.
@MainActor
func makeSystemSettingsPresentationActions() -> SettingsPresentationActions {
    SettingsPresentationActions { action in
        switch action {
        case .openLoginItemsSettings:
            guard #available(macOS 13.0, *) else { return .unavailable }
            SMAppService.openSystemSettingsLoginItems()
            return .performed
        case .openCalendarPrivacySettings:
            guard
                let url = URL(
                    string:
                        "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars"
                )
            else { return .failed }
            return NSWorkspace.shared.open(url) ? .performed : .failed
        }
    }
}
