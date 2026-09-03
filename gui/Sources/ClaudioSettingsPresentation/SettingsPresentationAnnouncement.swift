import ClaudioGUICore

package struct SettingsPresentationAnnouncement: Equatable, Sendable, Identifiable {
    package struct ID: RawRepresentable, Equatable, Hashable, Sendable {
        package let rawValue: UInt64

        package init(rawValue: UInt64) {
            self.rawValue = rawValue
        }
    }

    package enum Meaning: Equatable, Sendable {
        case loginItemStatus(LoginItemRegistrationState)
        case loginItemFailure(LoginItemOperationFailure)
        case platformAction(SettingsPlatformAction, SettingsPlatformActionResult)
    }

    package let id: ID
    package let meaning: Meaning

    package init(id: ID, meaning: Meaning) {
        self.id = id
        self.meaning = meaning
    }
}
