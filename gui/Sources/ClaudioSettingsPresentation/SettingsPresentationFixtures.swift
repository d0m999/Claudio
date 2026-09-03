#if DEBUG
import ClaudioCore
import ClaudioGUICore
import ClaudioLocalization
import Foundation

/// Recording adapter for DEBUG galleries and the executable harness. It exercises the same
/// concrete, closed action dispatcher as production without importing native system frameworks.
@MainActor
package final class SettingsPresentationActionRecorder {
    package private(set) var actions: [SettingsPlatformAction] = []
    private let result: SettingsPlatformActionResult

    package init(result: SettingsPlatformActionResult) {
        self.result = result
    }

    package func perform(_ action: SettingsPlatformAction) -> SettingsPlatformActionResult {
        actions.append(action)
        return result
    }
}

/// Production-shape DEBUG fixture composed only from the public presentation seams. The sound
/// editor remains owned by `SoundPacksEditorOwner`; no raw model or runtime library is exposed.
@MainActor
package struct SettingsPresentationFixture {
    package let temporaryRoot: URL
    package let session: SettingsPresentationSession
    package let soundPacksEditor: SoundPacksEditorOwner
    package let actionRecorder: SettingsPresentationActionRecorder

    package var rootView: SettingsRootView {
        SettingsRootView(session: session)
    }
}

@MainActor
package enum SettingsPresentationFixtures {
    package static func generalLogin(
        language: ClaudioAppLanguage = .zhHans,
        loginItemRegistration: LoginItemRegistrationState = .disabled,
        platformActionResult: SettingsPlatformActionResult = .performed
    ) -> SettingsPresentationFixture {
        let temporaryRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "claudio-settings-presentation-fixture-\(UUID().uuidString)",
            isDirectory: true)
        let actionRecorder = SettingsPresentationActionRecorder(result: platformActionResult)
        let loginItemSettings = LoginItemSettingsModel(
            adapter: makeLoginItemServiceAdapter(
                status: { loginItemRegistration },
                setEnabled: { enabled in enabled ? .enabled : .disabled }))
        let session = SettingsPresentationSession(
            dependencies: SettingsPresentationDependencies(
                preferences: ClaudioPreferences(previewLanguage: language),
                loginItemSettings: loginItemSettings),
            actions: SettingsPresentationActions { actionRecorder.perform($0) })
        let soundPacksEditor = SoundPacksEditorOwner.stateGalleryFixture(
            previewConfig: ClaudioConfig(
                selectedPack: "settings-fixture-pack",
                masterVolume: 0.7),
            packCards: [
                PackCard(
                    id: "settings-fixture-pack",
                    name: "Settings Fixture Pack",
                    isCC0: true,
                    presentEvents: Set(Event.allCases),
                    state: .complete,
                    isSelected: true)
            ],
            selectedPackID: "settings-fixture-pack",
            selectedEventRows: Event.allCases.map {
                EventRow(
                    event: $0,
                    coverage: .present(fileName: "\($0.cliName).mp3"),
                    enabled: true)
            },
            environment: AudioImportEnvironment(
                userPacksDirectory: temporaryRoot.appendingPathComponent(
                    "packs", isDirectory: true),
                durationProbe: SettingsPresentationFixtureDurationProbe(),
                packsLockFile: temporaryRoot.appendingPathComponent("packs.lock")))

        return SettingsPresentationFixture(
            temporaryRoot: temporaryRoot,
            session: session,
            soundPacksEditor: soundPacksEditor,
            actionRecorder: actionRecorder)
    }
}

private struct SettingsPresentationFixtureDurationProbe: AudioDurationProbing {
    func probeDuration(of _: URL) -> TimeInterval? { 0.25 }
}
#endif
