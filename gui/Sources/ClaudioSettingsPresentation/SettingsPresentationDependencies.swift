import ClaudioGUICore

/// The complete dependency set for the General/Login slice shipped by this target today.
/// Later destination moves extend this value atomically instead of reserving optional slots.
package struct SettingsPresentationDependencies {
    package let preferences: ClaudioPreferences
    package let loginItemSettings: LoginItemSettingsModel

    package init(
        preferences: ClaudioPreferences,
        loginItemSettings: LoginItemSettingsModel
    ) {
        self.preferences = preferences
        self.loginItemSettings = loginItemSettings
    }
}
