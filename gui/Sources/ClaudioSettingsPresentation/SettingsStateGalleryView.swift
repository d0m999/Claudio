#if DEBUG
import ClaudioGUICore
import ClaudioLocalization
import SwiftUI

/// Target-owned Settings gallery slice. The executable gallery supplies only its surrounding
/// frame; every scenario mounts the same production ``SettingsRootView`` through an explicit,
/// isolated fixture from this module.
@MainActor
package struct SettingsStateGalleryView: View {
    @StateObject private var session: SettingsPresentationSession

    package init(
        route: SettingsRoute,
        availability: SettingsRouteAvailability,
        language: ClaudioAppLanguage,
        textSize: ClaudioInterfaceTextSize = .standard,
        experienceProfile: PreviewFixtures.SettingsExperienceProfile? = nil,
        aiCueScenario: PreviewFixtures.AICueGalleryScenario? = nil,
        integrationScenario: PreviewFixtures.HostIntegrationScenario? = nil,
        integrationInFlightAction: HostIntegrationUserAction? = nil
    ) {
        let fixture = SettingsPresentationFixtures.generalLogin(
            language: language,
            route: route,
            availability: availability,
            textSize: textSize,
            experienceProfile: experienceProfile,
            aiCueScenario: aiCueScenario,
            integrationScenario: integrationScenario,
            integrationInFlightAction: integrationInFlightAction)
        _session = StateObject(wrappedValue: fixture.session)
    }

    package var body: some View {
        SettingsRootView(session: session)
    }
}
#endif
