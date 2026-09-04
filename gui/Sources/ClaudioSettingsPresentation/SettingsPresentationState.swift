import ClaudioGUICore
import ClaudioLocalization

package struct SettingsPlatformActionFailure: Equatable, Sendable {
    package let action: SettingsPlatformAction
    package let result: SettingsPlatformActionResult
}

package enum SettingsWindowPhase: Equatable, Sendable {
    case hidden
    case visibleNonKey
    case key
    case closing
}

package struct SettingsFocusDebt: Equatable, Sendable {
    package let revision: UInt64
    package let destination: SettingsDestination
}

package struct SettingsEventPresentationState: Equatable, Sendable {
    package let route: EventSettingsWindowRoute
    package let routeRequestRevision: UInt64
    package let focusRequestRevision: UInt64
    package let focusTarget: EventSettingsFocusTarget?
    package let previewState: EventSettingsDestinationPreviewState
    package let previewStopRequestRevision: UInt64
    package let aiSessionState: EventSettingsDestinationAISessionState
    package let aiSessionEndRequestRevision: UInt64
}

package enum SettingsPresentationRequest: Equatable, Sendable {
    case route(SettingsRoute?)
    case eventShortcut(EventSettingsWindowRoute)
}

package enum SettingsPresentationCommand: Equatable, Sendable {
    case present(SettingsPresentationRequest)
    case route(SettingsRoute)
    case setLanguageMode(ClaudioLanguageMode)
    case setLoginItemEnabled(Bool)
    case retryLoginItemOperation
    case performPlatformAction(SettingsPlatformAction)
    case eventAudibilityInputsChanged
    case announceDestinationUpdate(String)
    case windowPhaseChanged(SettingsWindowPhase)
    case acknowledgeFocus(revision: UInt64)
    case acknowledgeAnnouncement(id: UInt64, didPost: Bool)
    case windowWillClose
}

package enum SettingsPresentationResult: Equatable, Sendable {
    case unchanged
    case presented(wasAlreadyPresented: Bool)
    case routed
    case rejected(SettingsRouteFailure)
    case platformAction(SettingsPlatformActionResult)
    case closed
}

/// Immutable projection for the retained Settings presentation transaction. Domain facts stay in
/// their existing owners; this value contains only route/lifecycle state, render-ready values and
/// semantic delivery debt.
package struct SettingsPresentationState: Equatable, Sendable {
    package let routeResolution: SettingsRouteResolution
    package let explicitRouteRequestRevision: UInt64
    package let focusDebt: SettingsFocusDebt?
    package let windowPhase: SettingsWindowPhase
    package let activeDestination: SettingsDestination?
    package let eventPresentation: SettingsEventPresentationState
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
