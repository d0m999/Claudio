import ClaudioCore
import ClaudioGUICore
import Foundation

/// Keeps the production config-lock identity in the app composition layer while allowing the
/// retained event-settings window to use the same config read/write owner as the menu-bar panel.
@MainActor
func makeEventSettingsConfigController(
    configFile: URL,
    environment: AudioImportEnvironment,
    soundPackLibrary: SoundPackLibrary,
    soundPacksRefreshCoordinator: SoundPacksRefreshCoordinator,
    afterFullReload: @escaping @MainActor (ClaudioConfig) -> Void
) -> PanelConfigController {
    PanelConfigController(
        configFile: configFile,
        lockFile: ClaudioPaths.configLockFile,
        environment: environment,
        soundPackLibrary: soundPackLibrary,
        afterFullReload: afterFullReload,
        soundPacksRefreshCoordinator: soundPacksRefreshCoordinator)
}
