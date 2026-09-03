#if DEBUG
import AppKit
import ClaudioCore
import ClaudioGUICore
import ClaudioLocalization
import Foundation
import SoundPacksWindow

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

    package var selectedDestination: SettingsDestination {
        session.dependencies.navigation.resolution.destination
    }
}

@MainActor
package enum SettingsPresentationFixtures {
    package static func generalLogin(
        temporaryParent: URL = FileManager.default.temporaryDirectory,
        language: ClaudioAppLanguage = .zhHans,
        loginItemRegistration: LoginItemRegistrationState = .disabled,
        platformActionResult: SettingsPlatformActionResult = .performed,
        route: SettingsRoute = .destination(.general),
        availability: SettingsRouteAvailability? = nil,
        textSize: ClaudioInterfaceTextSize = .standard,
        experienceProfile: PreviewFixtures.SettingsExperienceProfile? = nil
    ) -> SettingsPresentationFixture {
        let temporaryRoot = temporaryParent.appendingPathComponent(
            "claudio-settings-presentation-fixture-\(UUID().uuidString)",
            isDirectory: true)
        let actionRecorder = SettingsPresentationActionRecorder(result: platformActionResult)
        let preferences = ClaudioPreferences(previewLanguage: language)
        preferences.setInterfaceTextSize(textSize)
        let generalState = experienceProfile?.general
        let projectedLoginItemRegistration: LoginItemRegistrationState =
            generalState == .permissionRequired ? .requiresApproval : loginItemRegistration
        let loginItemSettings = LoginItemSettingsModel(
            adapter: makeLoginItemServiceAdapter(
                status: { projectedLoginItemRegistration },
                setEnabled: { enabled in
                    if generalState == .writeFailed {
                        throw LoginItemOperationFailureReason.systemRejected
                    }
                    return enabled ? .enabled : .disabled
                }))
        if generalState == .writeFailed {
            loginItemSettings.setEnabled(true)
        }
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
        let hostState = PreviewFixtures.workBuddyVisualScenarios.first {
            $0.phase == .allImplementedBindingsCurrent
        }!.state
        let hostIntegrations = HostIntegrationPresentationStore(state: hostState)
        let shellProjection = SettingsSoundPackShellProjection(
            editorPresentation: soundPacksEditor.presentation,
            sourceRows: hostIntegrations.content.sourceRows)
        let navigation = SettingsWindowPresentationModel<NSRunningApplication>(
            initialRoute: route,
            preferences: preferences,
            availability: availability ?? shellProjection.availability)
        let dynamicQuietPolicy = makeSettingsFixtureDynamicQuietPolicy(
            for: experienceProfile)
        let usageSettings = makeSettingsFixtureUsageSettings(for: experienceProfile)
        let globalShortcutSettings = makeSettingsFixtureShortcutSettings(
            for: experienceProfile)
        let aboutSettings = makeSettingsFixtureAboutSettings(for: experienceProfile)
        let integrationOutcome = IntegrationDestinationActionOutcome(
            content: hostIntegrations.content,
            feedbackKind: .success,
            feedbackMessage: "fixture complete")
        let integrationsModel = IntegrationDestinationModel(
            content: hostIntegrations.content,
            refreshHandler: IntegrationDestinationRefreshHandler { integrationOutcome },
            actionHandler: IntegrationDestinationActionHandler { _ in integrationOutcome },
            preferences: preferences,
            clipboardWriter: IntegrationDestinationClipboardWriter { _ in true })
        let eventSettingsModel = PanelConfigController(
            previewConfigState: .operational(
                ClaudioConfig(selectedPack: "settings-fixture-pack", masterVolume: 0.7)),
            eventRows: Event.allCases.map {
                EventRow(
                    event: $0,
                    coverage: .present(fileName: "\($0.cliName).mp3"),
                    enabled: true)
            },
            environment: AudioImportEnvironment(
                userPacksDirectory: temporaryRoot.appendingPathComponent(
                    "event-packs", isDirectory: true),
                durationProbe: SettingsPresentationFixtureDurationProbe(),
                packsLockFile: temporaryRoot.appendingPathComponent("event-packs.lock")))
        let nativeEffects = SoundPacksEditorNativeEffectsDispatcher(
            adapter: SettingsPresentationFixtureNativeEffectsAdapter())
        let session = SettingsPresentationSession(
            dependencies: SettingsPresentationDependencies(
                navigation: navigation,
                preferences: preferences,
                loginItemSettings: loginItemSettings,
                dynamicQuietPolicy: dynamicQuietPolicy,
                usageSettings: usageSettings,
                globalShortcutSettings: globalShortcutSettings,
                aboutSettings: aboutSettings,
                soundPacksEditorOwner: soundPacksEditor,
                soundPacksEditorNativeEffects: nativeEffects,
                eventSettingsModel: eventSettingsModel,
                eventSettingsSelection: EventSettingsWindowSelection(),
                hostIntegrations: hostIntegrations,
                integrationsModel: integrationsModel,
                integrationsFocusCoordinator: IntegrationDestinationFocusCoordinator(),
                aiCueViewModel: AICueGenerationViewModel(
                    previewState: PreviewFixtures.AICueGalleryScenario.editing.previewState)),
            actions: SettingsPresentationActions(
                handler: { actionRecorder.perform($0) },
                onEventAudibilityInputsChanged: {},
                announce: { _ in }))

        return SettingsPresentationFixture(
            temporaryRoot: temporaryRoot,
            session: session,
            soundPacksEditor: soundPacksEditor,
            actionRecorder: actionRecorder)
    }
}

extension SettingsPresentationActions {
    package init(
        _ handler: @escaping @MainActor (SettingsPlatformAction) -> SettingsPlatformActionResult
    ) {
        self.init(
            handler: handler,
            onEventAudibilityInputsChanged: {},
            announce: { _ in })
    }
}

@MainActor
extension SettingsPresentationDependencies {
    package init(
        preferences: ClaudioPreferences,
        loginItemSettings: LoginItemSettingsModel
    ) {
        let temporaryRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "claudio-settings-dependency-fixture-\(UUID().uuidString)",
            isDirectory: true)
        let environment = AudioImportEnvironment(
            userPacksDirectory: temporaryRoot.appendingPathComponent("packs", isDirectory: true),
            durationProbe: SettingsPresentationFixtureDurationProbe(),
            packsLockFile: temporaryRoot.appendingPathComponent("packs.lock"))
        let soundPacksEditorOwner = SoundPacksEditorOwner.stateGalleryFixture(
            previewConfig: ClaudioConfig(selectedPack: "settings-fixture-pack"),
            packCards: [],
            selectedPackID: nil,
            selectedEventRows: [],
            environment: environment)
        let hostState = PreviewFixtures.workBuddyVisualScenarios.first {
            $0.phase == .allImplementedBindingsCurrent
        }!.state
        let hostIntegrations = HostIntegrationPresentationStore(state: hostState)
        let shellProjection = SettingsSoundPackShellProjection(
            editorPresentation: soundPacksEditorOwner.presentation,
            sourceRows: hostIntegrations.content.sourceRows)
        let integrationOutcome = IntegrationDestinationActionOutcome(
            content: hostIntegrations.content,
            feedbackKind: .success,
            feedbackMessage: "fixture complete")
        self.init(
            navigation: SettingsWindowPresentationModel<NSRunningApplication>(
                preferences: preferences,
                availability: shellProjection.availability),
            preferences: preferences,
            loginItemSettings: loginItemSettings,
            dynamicQuietPolicy: makeSettingsFixtureDynamicQuietPolicy(for: nil),
            usageSettings: makeSettingsFixtureUsageSettings(for: nil),
            globalShortcutSettings: makeSettingsFixtureShortcutSettings(for: nil),
            aboutSettings: makeSettingsFixtureAboutSettings(for: nil),
            soundPacksEditorOwner: soundPacksEditorOwner,
            soundPacksEditorNativeEffects: SoundPacksEditorNativeEffectsDispatcher(
                adapter: SettingsPresentationFixtureNativeEffectsAdapter()),
            eventSettingsModel: PanelConfigController(
                previewConfigState: .operational(
                    ClaudioConfig(selectedPack: "settings-fixture-pack")),
                environment: environment),
            eventSettingsSelection: EventSettingsWindowSelection(),
            hostIntegrations: hostIntegrations,
            integrationsModel: IntegrationDestinationModel(
                content: hostIntegrations.content,
                refreshHandler: IntegrationDestinationRefreshHandler { integrationOutcome },
                actionHandler: IntegrationDestinationActionHandler { _ in integrationOutcome }),
            integrationsFocusCoordinator: IntegrationDestinationFocusCoordinator(),
            aiCueViewModel: AICueGenerationViewModel(
                previewState: PreviewFixtures.AICueGalleryScenario.editing.previewState))
    }
}

@MainActor
private func makeSettingsFixtureDynamicQuietPolicy(
    for profile: PreviewFixtures.SettingsExperienceProfile?
) -> DynamicQuietPolicyController {
    let state = profile?.notifications ?? .ready
    let suiteName = "Claudio.SettingsPresentationFixture.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    let policyEnabled = profile?.destination == .notifications
    if policyEnabled {
        defaults.setVolatileDomain(
            [
                DynamicQuietPolicyController.focusDefaultsKey: true,
                DynamicQuietPolicyController.calendarDefaultsKey: true,
            ],
            forName: suiteName)
    }
    let permissionDenied = state == .permissionRequired
    let focus = FocusQuietSystemState(
        authorization: permissionDenied ? .denied : .authorized,
        isFocused: permissionDenied ? nil : false)
    let calendar = CalendarQuietSystemState(
        authorization: permissionDenied ? .denied : .authorized,
        events: permissionDenied ? nil : [])
    let publicationGate = SettingsPresentationFixturePublicationGate()
    let model = DynamicQuietPolicyController(
        defaults: defaults,
        readFocusState: { focus },
        requestFocusAuthorization: { $0(focus) },
        readCalendarState: { _ in calendar },
        requestCalendarAuthorization: { $0(calendar) },
        publish: { _, _, now in
            guard publicationGate.succeeds else { return nil }
            return state == .stale ? now : now.addingTimeInterval(12)
        })
    if state == .writeFailed {
        publicationGate.succeeds = false
        model.refresh()
    }
    return model
}

@MainActor
private func makeSettingsFixtureUsageSettings(
    for profile: PreviewFixtures.SettingsExperienceProfile?
) -> UsageSettingsModel {
    let state = profile?.usage ?? .empty
    let hasEvents = state == .ready || state == .stale
    let sourceState: UsageHistorySourceState = state == .unreadable ? .unreadable : .available
    let events =
        hasEvents
        ? [
            UsageEventActivity(
                event: .stop,
                resultCounts: [UsagePlaybackResultCount(result: .played, count: 4)])
        ] : []
    let presentation = UsageActivityPresentation(
        surfaces: HostID.productVisibleCases.map {
            UsageSurfaceActivity(
                host: $0,
                retainedCount: hasEvents ? 4 : 0,
                events: events,
                sourceState: state == .empty || state == .loading || state == .writeFailed
                    ? .missing : sourceState)
        },
        log: UsageDiagnosticLogSnapshot(
            path: "/preview/claudio.log",
            state: state == .unreadable
                ? .unreadable : (hasEvents ? .available(sizeBytes: 512) : .missing),
            failures: []))
    let feedback: UsageSettingsFeedback? =
        switch state {
        case .stale:
            UsageSettingsFeedback(action: .clearHistory, failure: .historyClearFailed)
        case .writeFailed:
            UsageSettingsFeedback(action: .copyLogPath, failure: .clipboardFailed)
        case .loading, .ready, .empty, .unreadable:
            nil
        }
    return UsageSettingsModel(
        previewPresentation: presentation,
        isRefreshing: state == .loading,
        feedback: feedback)
}

@MainActor
private func makeSettingsFixtureShortcutSettings(
    for profile: PreviewFixtures.SettingsExperienceProfile?
) -> GlobalShortcutSettingsModel {
    let state = profile?.shortcuts ?? .empty
    let shortcut = GlobalShortcut(
        shortcutID: .togglePanel,
        keyCode: 0,
        modifiers: [.command, .control])
    let persisted = try? JSONEncoder().encode(shortcut)
    let model = GlobalShortcutSettingsModel(
        adapter: GlobalHotKeyAdapter(
            register: { _ in
                if state == .writeFailed { throw GlobalShortcutAdapterError.conflict }
            },
            unregister: { _ in },
            setActionHandler: { _ in }),
        persistence: GlobalShortcutPersistenceAdapter(
            read: { action in
                state == .ready && action == .togglePanel ? persisted : nil
            },
            persist: { _, _ in }),
        actionHandler: { _ in })
    if state == .writeFailed {
        model.replace(.togglePanel, keyCode: 0, modifiers: [.command, .control])
    }
    return model
}

@MainActor
private func makeSettingsFixtureAboutSettings(
    for profile: PreviewFixtures.SettingsExperienceProfile?
) -> AboutSettingsModel {
    let state = profile?.about ?? .ready
    let empty = state == .empty
    let model = AboutSettingsModel(
        bundleFacts: empty
            ? projectAboutBundleFacts(
                AboutBundleFactsInput(
                    brandName: nil,
                    productName: nil,
                    version: nil,
                    build: nil,
                    architecture: nil,
                    minimumSystemVersion: nil,
                    operatingSystemVersion: "15.6.1"))
            : PreviewFixtures.aboutBundleFacts,
        resources: empty
            ? AboutBundledResourceKind.allCases.map {
                AboutBundledResource(kind: $0, url: nil)
            } : PreviewFixtures.aboutBundledResources,
        pathFacts: empty
            ? AboutPathKind.allCases.map {
                AboutPathExistenceFact(kind: $0, exists: false)
            } : PreviewFixtures.aboutPathFacts,
        surfaceFacts: empty ? [] : PreviewFixtures.aboutSurfaceFacts,
        actions: AboutSettingsActions(
            copy: { _ in state != .writeFailed },
            open: { _ in state != .writeFailed }))
    if state == .writeFailed {
        model.copyDiagnostics()
    }
    return model
}

private struct SettingsPresentationFixtureDurationProbe: AudioDurationProbing {
    func probeDuration(of _: URL) -> TimeInterval? { 0.25 }
}

@MainActor
private final class SettingsPresentationFixturePublicationGate {
    var succeeds = true
}

@MainActor
private final class SettingsPresentationFixtureNativeEffectsAdapter:
    SoundPacksEditorNativeEffectsAdapter
{
    func selectAudioFiles(allowsMultipleSelection _: Bool) -> [URL] { [] }
    func playAudio(fileURL _: URL, volume _: Double) -> TimeInterval? { nil }
    func stopAudio() {}
    func revealInFinder(fileURL _: URL) {}
}
#endif
