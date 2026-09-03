import ClaudioGUICore
import ClaudioLocalization

package struct SettingsPresentationAnnouncement: Equatable, Sendable {
    package enum Meaning: Equatable, Sendable {
        case loginItemStatus(LoginItemRegistrationState)
        case loginItemFailure(LoginItemOperationFailure)
        case platformAction(SettingsPlatformAction, SettingsPlatformActionResult)
    }

    package let id: UInt64
    package let meaning: Meaning

    package init(id: UInt64, meaning: Meaning) {
        self.id = id
        self.meaning = meaning
    }
}

extension SettingsPresentationAnnouncement.Meaning {
    package func localizedSentence(language: ClaudioAppLanguage) -> String {
        let l10n = ClaudioL10n(language: language)
        let key: ClaudioL10nKey =
            switch self {
            case .loginItemStatus(let registration):
                switch registration {
                case .disabled: .settingsGeneralLoginItem.disabled
                case .enabled: .settingsGeneralLoginItem.enabled
                case .requiresApproval: .settingsGeneralLoginItem.requiresApproval
                case .unavailable: .settingsGeneralLoginItem.unavailable
                }
            case .loginItemFailure(let failure):
                switch failure.reason {
                case .embeddedLoginItemMissing:
                    .settingsGeneralLoginItem.failureMissing
                case .systemRejected:
                    failure.requestedEnabled
                        ? .settingsGeneralLoginItem.failureEnable
                        : .settingsGeneralLoginItem.failureDisable
                }
            case .platformAction(let action, _):
                switch action {
                case .openLoginItemsSettings:
                    .settingsGeneralLoginItem.unavailable
                case .openCalendarPrivacySettings:
                    .settingsNotificationsOpenCalendarPrivacy
                }
            }
        return l10n.text(key)
    }
}
