import ClaudioGUIComponents
import ClaudioGUICore
import ClaudioLocalization
import SwiftUI

package enum SettingsPresentationAccessibilityID {
    package static let root = "settings.presentation.root"
    package static let general = "settings.presentation.general"
    package static let loginItemToggle = "settings.general.login-item.toggle"
}

/// The Login Item section rendered by the importable Settings root. All mutations and system
/// effects return through the session seam.
@MainActor
struct LoginItemSettingsSection: View {
    @ObservedObject private var session: SettingsPresentationSession

    init(session: SettingsPresentationSession) {
        self.session = session
    }

    var body: some View {
        let l10n = ClaudioL10n(language: session.state.language)
        let loginItemStatusText = SettingsPresentationAnnouncement.Meaning.loginItemStatus(
            session.state.loginItemRegistration
        ).localizedSentence(language: session.state.language)
        VStack(alignment: .leading, spacing: 10) {
            Text(l10n.text(.settingsGeneralLoginItem.description))
                .foregroundColor(.secondary)

            Toggle(
                l10n.text(.settingsGeneralLoginItem.toggle),
                isOn: enabledBinding
            )
            .disabled(!session.state.loginItemRegistration.canToggle)
            .accessibilityHint(l10n.text(.settingsGeneralLoginItem.hint))
            .accessibilityValue(loginItemStatusText)
            .accessibilityIdentifier(SettingsPresentationAccessibilityID.loginItemToggle)

            Text(loginItemStatusText)
                .foregroundColor(.secondary)

            if session.state.loginItemRegistration == .requiresApproval {
                Button(l10n.text(.settingsGeneralLoginItem.openSettings)) {
                    session.send(.performPlatformAction(.openLoginItemsSettings))
                }
                .accessibilityHint(l10n.text(.settingsGeneralLoginItem.openSettingsHint))
                .accessibilityIdentifier("settings.general.login-item.open-settings")
            }

            if let failure = session.state.loginItemFailure {
                VStack(alignment: .leading, spacing: 8) {
                    FailureRow(
                        message: SettingsPresentationAnnouncement.Meaning.loginItemFailure(
                            failure
                        ).localizedSentence(language: session.state.language)
                    )

                    Button(l10n.text(.commonRetry)) {
                        session.send(.retryLoginItemOperation)
                    }
                    .accessibilityIdentifier("settings.general.login-item.retry")
                }
            }

            if session.state.platformActionFailure == .openLoginItemsSettings {
                FailureRow(message: l10n.text(.settingsGeneralLoginItem.unavailable))
                    .accessibilityIdentifier("settings.general.login-item.settings-failure")
            }
        }
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { session.state.loginItemRegistration.isOn },
            set: { _ = session.send(.setLoginItemEnabled($0)) })
    }

}
