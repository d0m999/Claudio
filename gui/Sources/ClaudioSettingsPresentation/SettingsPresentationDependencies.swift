import ClaudioGUICore
import SoundPacksWindow

/// The complete, nonoptional owner set consumed by the unified Settings presentation tree.
/// Native factories remain in the executable; this value only retains their typed products.
package struct SettingsPresentationDependencies {
    package let preferences: ClaudioPreferences
    package let loginItemSettings: LoginItemSettingsModel
    package let dynamicQuietPolicy: DynamicQuietPolicyController
    package let activityDiagnostics: ActivityDiagnosticsModel
    package let globalShortcutSettings: GlobalShortcutSettingsModel
    package let aboutSettings: AboutSettingsModel
    package let soundPacksEditorOwner: SoundPacksEditorOwner
    package let soundPacksEditorNativeEffects: SoundPacksEditorNativeEffectsDispatcher
    package let eventSettingsModel: PanelConfigController
    package let hostIntegrations: HostIntegrationPresentationStore
    package let integrationsModel: IntegrationDestinationModel
    package let aiCueViewModel: AICueGenerationViewModel

    package init(
        preferences: ClaudioPreferences,
        loginItemSettings: LoginItemSettingsModel,
        dynamicQuietPolicy: DynamicQuietPolicyController,
        activityDiagnostics: ActivityDiagnosticsModel,
        globalShortcutSettings: GlobalShortcutSettingsModel,
        aboutSettings: AboutSettingsModel,
        soundPacksEditorOwner: SoundPacksEditorOwner,
        soundPacksEditorNativeEffects: SoundPacksEditorNativeEffectsDispatcher,
        eventSettingsModel: PanelConfigController,
        hostIntegrations: HostIntegrationPresentationStore,
        integrationsModel: IntegrationDestinationModel,
        aiCueViewModel: AICueGenerationViewModel
    ) {
        self.preferences = preferences
        self.loginItemSettings = loginItemSettings
        self.dynamicQuietPolicy = dynamicQuietPolicy
        self.activityDiagnostics = activityDiagnostics
        self.globalShortcutSettings = globalShortcutSettings
        self.aboutSettings = aboutSettings
        self.soundPacksEditorOwner = soundPacksEditorOwner
        self.soundPacksEditorNativeEffects = soundPacksEditorNativeEffects
        self.eventSettingsModel = eventSettingsModel
        self.hostIntegrations = hostIntegrations
        self.integrationsModel = integrationsModel
        self.aiCueViewModel = aiCueViewModel
    }
}
