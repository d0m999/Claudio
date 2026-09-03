import ClaudioGUICore
import ClaudioLocalization

package struct SettingsPlatformActionFailure: Equatable, Sendable {
    package let action: SettingsPlatformAction
    package let result: SettingsPlatformActionResult
}

/// Immutable projection for the real General/Login slice. Domain facts stay in their existing
/// owners; this value contains only render-ready presentation state and semantic delivery debt.
package struct SettingsPresentationState: Equatable, Sendable {
    package let languageMode: ClaudioLanguageMode
    package let language: ClaudioAppLanguage
    package let interfaceTextSize: ClaudioInterfaceTextSize
    package let recoveryIssues: Set<ClaudioPreferenceRecoveryIssue>
    package let loginItemRegistration: LoginItemRegistrationState
    package let loginItemFailure: LoginItemOperationFailure?
    package let platformActionFailure: SettingsPlatformActionFailure?
    package let pendingAnnouncement: SettingsPresentationAnnouncement?
    package let presentationRevision: UInt64
}
