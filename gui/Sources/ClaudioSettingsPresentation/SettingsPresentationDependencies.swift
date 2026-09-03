import AppKit
import ClaudioGUICore
import SoundPacksWindow

/// The complete, nonoptional owner set consumed by the unified Settings presentation tree.
/// Native factories remain in the executable; this value only retains their typed products.
package struct SettingsPresentationDependencies {
    package let navigation: SettingsWindowPresentationModel<NSRunningApplication>
    package let preferences: ClaudioPreferences
    package let loginItemSettings: LoginItemSettingsModel
    package let dynamicQuietPolicy: DynamicQuietPolicyController
    package let usageSettings: UsageSettingsModel
    package let globalShortcutSettings: GlobalShortcutSettingsModel
    package let aboutSettings: AboutSettingsModel
    package let soundPacksEditorOwner: SoundPacksEditorOwner
    package let soundPacksEditorNativeEffects: SoundPacksEditorNativeEffectsDispatcher
    package let eventSettingsModel: PanelConfigController
    package let eventSettingsSelection: EventSettingsWindowSelection
    package let hostIntegrations: HostIntegrationPresentationStore
    package let integrationsModel: IntegrationDestinationModel
    package let integrationsFocusCoordinator: IntegrationDestinationFocusCoordinator
    package let aiCueViewModel: AICueGenerationViewModel

    package init(
        navigation: SettingsWindowPresentationModel<NSRunningApplication>,
        preferences: ClaudioPreferences,
        loginItemSettings: LoginItemSettingsModel,
        dynamicQuietPolicy: DynamicQuietPolicyController,
        usageSettings: UsageSettingsModel,
        globalShortcutSettings: GlobalShortcutSettingsModel,
        aboutSettings: AboutSettingsModel,
        soundPacksEditorOwner: SoundPacksEditorOwner,
        soundPacksEditorNativeEffects: SoundPacksEditorNativeEffectsDispatcher,
        eventSettingsModel: PanelConfigController,
        eventSettingsSelection: EventSettingsWindowSelection,
        hostIntegrations: HostIntegrationPresentationStore,
        integrationsModel: IntegrationDestinationModel,
        integrationsFocusCoordinator: IntegrationDestinationFocusCoordinator,
        aiCueViewModel: AICueGenerationViewModel
    ) {
        self.navigation = navigation
        self.preferences = preferences
        self.loginItemSettings = loginItemSettings
        self.dynamicQuietPolicy = dynamicQuietPolicy
        self.usageSettings = usageSettings
        self.globalShortcutSettings = globalShortcutSettings
        self.aboutSettings = aboutSettings
        self.soundPacksEditorOwner = soundPacksEditorOwner
        self.soundPacksEditorNativeEffects = soundPacksEditorNativeEffects
        self.eventSettingsModel = eventSettingsModel
        self.eventSettingsSelection = eventSettingsSelection
        self.hostIntegrations = hostIntegrations
        self.integrationsModel = integrationsModel
        self.integrationsFocusCoordinator = integrationsFocusCoordinator
        self.aiCueViewModel = aiCueViewModel
    }
}
