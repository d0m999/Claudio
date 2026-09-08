import ClaudioGUICore
import ClaudioLocalization
import SoundPacksWindow

package struct SettingsPresentationAnnouncement: Equatable, Sendable {
    package enum Meaning: Equatable, Sendable {
        case loginItemStatus(LoginItemRegistrationState)
        case loginItemFailure(LoginItemOperationFailure)
        case platformAction(SettingsPlatformAction, SettingsPlatformActionResult)
        case destinationUpdate(String)
        case soundPacks(SoundPacksEditorAccessibilityRequest)
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
        switch self {
        case .destinationUpdate(let sentence):
            return sentence
        case .soundPacks(let request):
            return request.sentence
        case .loginItemStatus, .loginItemFailure, .platformAction:
            break
        }
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
            case .destinationUpdate, .soundPacks:
                preconditionFailure("render-ready announcements returned above")
            }
        return l10n.text(key)
    }

    package var priority: Int {
        switch self {
        case .soundPacks(let request): request.priority
        case .loginItemFailure, .platformAction: 90
        case .loginItemStatus, .destinationUpdate: 50
        }
    }
}
