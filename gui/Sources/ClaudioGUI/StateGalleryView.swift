#if DEBUG
import AppKit
import ClaudioCore
import ClaudioGUIComponents
import ClaudioGUICore
import ClaudioLocalization
import SoundPacksWindow
import SwiftUI

/// The repo-internal SwiftUI state gallery (ENGINEERING.md T14 D2) — the in-repo VISUAL
/// TRUTH SOURCE. Renders ONE frame per ``PreviewFixtures`` value across the app's
/// current per-feature state families and all-product host scenarios, plus an explicitly
/// labelled archive for the still-supported Claude-only legacy onboarding components
/// (``OnboardingState``, ``OnboardingActionState``,
/// ``DropZoneState``, ``EventRow``/``CoverageState``, ``PackCard``/``PackCardState``,
/// ``MasterVolumeState`` — PLAN-MASTER-VOLUME.md D33/D38), EXCLUSIVELY off
/// `PreviewFixtures` — no ad-hoc values are constructed anywhere in this file. See
/// `PreviewFixtures`'s own doc comment for why it — and therefore this gallery — is the
/// single source both the gallery and the state tests draw sample values from.
///
/// `#if DEBUG`-gated end to end: every frame here pins a view-model's state via a
/// `#if DEBUG`-only `previewState:` initializer (``OnboardingViewModel``,
/// ``AudioImportViewModel``, both in `ClaudioGUICore`), so this whole file can never
/// compile into a release build — matching those initializers' own scoping exactly.
///
/// COMPILE-ONLY here (CommandLineTools, no Xcode/simulator): `swift build --package-path
/// gui` proves every frame + every `PreviewProvider` below actually compiles; the
/// gallery's real VISUAL truth — what each frame actually *looks* like — is Xcode
/// Canvas, on a real Mac, per this repo's harness notes (`#Preview` does not compile
/// under CommandLineTools; only the classic `PreviewProvider` protocol form is used
/// below).
struct StateGalleryView: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                ProductionPanelGalleryView()
                SettingsWindowRouteGalleryView()
                SettingsExperienceGalleryView()
                EventSettingsLayoutGalleryView()
                ComplexAccessibilityEnvironmentGalleryView()
                AICueExperienceGalleryView()
                GallerySection(title: "Legacy Claude-only onboarding archive（非生产 Panel）") {
                    OnboardingGalleryView()
                    OnboardingActionGalleryView()
                }
                EventRowGalleryView()
                EventHostIndicatorGalleryView()
                PanelPackSectionGalleryView()
                InterfaceTextSizeGalleryView()
                PanelQuitFooterGalleryView()
                MasterVolumeGalleryView()
                PackCardGalleryView()
                ForEach(ClaudioAppLanguage.allCases) { language in
                    ForEach(ClaudioInterfaceTextSize.allCases) { textSize in
                        ForEach(SettingsGalleryAppearance.allCases) { appearance in
                            GallerySection(
                                title:
                                    "Sounds destination · \(language.selfName) · \(textSize.rawValue) · \(appearance.rawValue) (12 production states × 2 widths)"
                            ) {
                                if textSize == .standard && appearance == .light {
                                    SoundPacksWindowStateGalleryView(language: language)
                                        .environment(\.colorScheme, appearance.colorScheme)
                                } else {
                                    SoundPacksWindowStateGalleryView(
                                        language: language,
                                        textSize: textSize
                                    )
                                    .environment(\.colorScheme, appearance.colorScheme)
                                }
                            }
                        }
                    }
                }
                HostIntegrationGalleryView()
            }
            .padding(20)
        }
        // The gallery's own chrome sits on a TOKENIZED surface too, never SwiftUI's
        // untokenized default window background — see ``GalleryFrame``'s note for why that
        // background was a correctness bug in a file DESIGN.md calls the 视觉真相源.
        .background(ClaudioColor.panel(colorScheme))
    }
}

// MARK: - Unified Settings route skeleton (DEBUG only)

struct SettingsWindowRouteGalleryView: View {
    var body: some View {
        GallerySection(title: "Unified Settings · 9 typed route slots") {
            ForEach(ClaudioAppLanguage.allCases) { language in
                ForEach(PreviewFixtures.settingsRouteScenarios) { scenario in
                    GalleryFrame(
                        caption: "\(language.selfName) · \(scenario.destination.rawValue)"
                    ) {
                        SettingsWindowRouteFrame(
                            route: scenario.route,
                            availability: PreviewFixtures.settingsRouteAvailability,
                            language: language)
                    }
                }
            }
        }
        GallerySection(title: "Unified Settings · 6 visible route failures") {
            ForEach(ClaudioAppLanguage.allCases) { language in
                ForEach(PreviewFixtures.settingsRouteFailureScenarios) { scenario in
                    GalleryFrame(caption: "\(language.selfName) · \(scenario.id)") {
                        SettingsWindowRouteFrame(
                            route: scenario.route,
                            availability: scenario.availability,
                            language: language)
                    }
                }
            }
        }
    }
}

struct SettingsExperienceGalleryView: View {
    var body: some View {
        GallerySection(
            title:
                "Unified Settings · 6 basic production destinations · 2 languages × 4 text sizes"
        ) {
            ForEach(ClaudioAppLanguage.allCases) { language in
                ForEach(ClaudioInterfaceTextSize.allCases) { textSize in
                    ForEach(PreviewFixtures.settingsExperienceScenarios) { scenario in
                        GalleryFrame(
                            caption:
                                "\(language.selfName) · \(textSize.rawValue) · \(scenario.rawValue)"
                        ) {
                            SettingsWindowRouteFrame(
                                route: .destination(scenario.destination),
                                availability: PreviewFixtures.settingsRouteAvailability,
                                language: language,
                                textSize: textSize,
                                experienceScenario: scenario)
                        }
                    }
                }
            }
        }
    }
}

private enum EventSettingsGalleryWidth: String, CaseIterable, Identifiable {
    case minimum
    case standard

    var id: String { rawValue }
    var value: CGFloat { self == .minimum ? 680 : 820 }
}

private enum SettingsGalleryAppearance: String, CaseIterable, Identifiable {
    case light
    case dark

    var id: String { rawValue }
    var colorScheme: ColorScheme { self == .light ? .light : .dark }
}

struct EventSettingsLayoutGalleryView: View {
    var body: some View {
        GallerySection(
            title: "Events destination · production mount · 2 languages × 4 text sizes × 2 widths"
        ) {
            ForEach(ClaudioAppLanguage.allCases) { language in
                ForEach(ClaudioInterfaceTextSize.allCases) { textSize in
                    ForEach(SettingsGalleryAppearance.allCases) { appearance in
                        ForEach(EventSettingsGalleryWidth.allCases) { width in
                            GalleryFrame(
                                caption:
                                    "\(language.selfName) · \(textSize.rawValue) · \(appearance.rawValue) · \(width.rawValue)"
                            ) {
                                EventSettingsLayoutFrame(
                                    language: language,
                                    textSize: textSize,
                                    width: width.value
                                )
                                .environment(\.colorScheme, appearance.colorScheme)
                            }
                        }
                    }
                }
            }
        }
    }
}

struct ComplexAccessibilityEnvironmentGalleryView: View {
    var body: some View {
        GallerySection(
            title: "Complex Settings · accessibility environment variants"
        ) {
            GalleryFrame(caption: "Increase Contrast") {
                AccessibilityHighContrastGalleryMount(
                    content: EventSettingsLayoutFrame(
                        language: .english,
                        textSize: .standard,
                        width: EventSettingsGalleryWidth.minimum.value
                    ))
            }
            GalleryFrame(caption: "Reduce Transparency") {
                EventSettingsLayoutFrame(
                    language: .zhHans,
                    textSize: .standard,
                    width: EventSettingsGalleryWidth.minimum.value
                )
                .environment(\.settingsReduceTransparencyOverride, true)
            }
            GalleryFrame(caption: "Reduce Motion") {
                EventSettingsLayoutFrame(
                    language: .english,
                    textSize: .maximum,
                    width: EventSettingsGalleryWidth.minimum.value
                )
                .transaction { transaction in
                    transaction.animation = nil
                    transaction.disablesAnimations = true
                }
            }
        }
    }
}

/// AppKit owns the macOS increased-contrast appearance fact. Hosting the unchanged production
/// subtree under that system appearance exercises SwiftUI's real `colorSchemeContrast` projection
/// without adding gallery-only branches to production views.
private struct AccessibilityHighContrastGalleryMount<Content: View>: NSViewRepresentable {
    let content: Content

    func makeNSView(context: Context) -> NSHostingView<Content> {
        let hostingView = NSHostingView(rootView: content)
        hostingView.appearance = NSAppearance(named: .accessibilityHighContrastAqua)
        return hostingView
    }

    func updateNSView(_ hostingView: NSHostingView<Content>, context: Context) {
        hostingView.rootView = content
        hostingView.appearance = NSAppearance(named: .accessibilityHighContrastAqua)
    }
}

@MainActor
private struct EventSettingsLayoutFrame: View {
    @StateObject private var selection: EventSettingsWindowSelection
    @StateObject private var hostIntegrations: HostIntegrationPresentationStore
    @StateObject private var languageStore: ClaudioPreferences
    @StateObject private var aiCueViewModel: AICueGenerationViewModel
    @StateObject private var soundPacksEditorOwner: SoundPacksEditorOwner
    @StateObject private var panelModel: PanelConfigController
    @StateObject private var soundPacksEditorNativeEffects: SoundPacksEditorNativeEffectsDispatcher
    private let width: CGFloat

    init(
        language: ClaudioAppLanguage,
        textSize: ClaudioInterfaceTextSize,
        width: CGFloat
    ) {
        self.width = width
        let preferences = ClaudioPreferences(previewLanguage: language)
        preferences.setInterfaceTextSize(textSize)
        _languageStore = StateObject(wrappedValue: preferences)
        _selection = StateObject(
            wrappedValue: EventSettingsWindowSelection(
                route: EventSettingsWindowRoute(
                    scope: .surface(.workBuddy),
                    event: .stop)))

        let hostState = PreviewFixtures.workBuddyVisualScenarios.first {
            $0.phase == .allImplementedBindingsCurrent
        }!.state
        _hostIntegrations = StateObject(
            wrappedValue: HostIntegrationPresentationStore(
                state: hostState,
                configurationSources: [:]))

        var enabledEvents = Dictionary(
            uniqueKeysWithValues: Event.allCases.map { ($0.cliName, true) })
        enabledEvents[Event.notification.cliName] = false
        let baseConfig = ClaudioConfig(
            selectedPack: "global-pack",
            masterVolume: 0.75,
            eventsEnabled: enabledEvents,
            surfaceOverrides: [
                HostSurfaceID.workBuddy.rawValue: SurfaceSoundOverride(
                    selectedPack: "workbuddy-private",
                    eventsEnabled: [Event.notification.cliName: true])
            ])
        let fixture = EventSettingsGalleryFixture(config: baseConfig)
        _panelModel = StateObject(wrappedValue: fixture.panel)
        _soundPacksEditorOwner = StateObject(wrappedValue: fixture.owner)
        _soundPacksEditorNativeEffects = StateObject(
            wrappedValue: SoundPacksEditorNativeEffectsDispatcher(
                adapter: SettingsGallerySoundPacksEditorNativeEffectsAdapter()))
        _aiCueViewModel = StateObject(
            wrappedValue: AICueGenerationViewModel(
                previewState: PreviewFixtures.AICueGalleryScenario.editing.previewState))
    }

    var body: some View {
        EventSettingsWindowView(
            model: panelModel,
            selection: selection,
            hostIntegrations: hostIntegrations,
            languageStore: languageStore,
            aiCueViewModel: aiCueViewModel,
            soundPacksEditorOwner: soundPacksEditorOwner,
            soundPacksEditorNativeEffects: soundPacksEditorNativeEffects,
            onConfigureSound: { _ in },
            onAudibilityInputsChanged: {},
            onAnnouncement: { _ in }
        )
        .frame(width: width, height: 640)
    }
}

@MainActor
private struct EventSettingsGalleryFixture {
    let panel: PanelConfigController
    let owner: SoundPacksEditorOwner

    init(config: ClaudioConfig) {
        let root = previewStateGalleryRoot.appendingPathComponent(
            "event-settings-\(UUID().uuidString)",
            isDirectory: true)
        let environment = previewAudioImportEnvironment
        let configFile = root.appendingPathComponent("config.json")
        let configLock = root.appendingPathComponent("config.lock")

        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try JSONEncoder().encode(config).write(to: configFile, options: .atomic)
            for (packID, name) in [
                ("global-pack", "Global Signals"),
                ("workbuddy-private", "WorkBuddy Private"),
            ] {
                let pack = environment.userPacksDirectory.appendingPathComponent(
                    packID,
                    isDirectory: true)
                try FileManager.default.createDirectory(at: pack, withIntermediateDirectories: true)
                var events: [String: String] = [:]
                for event in Event.allCases {
                    let fileName = "\(event.cliName).mp3"
                    events[event.cliName] = fileName
                    try Data("gallery-audio".utf8).write(
                        to: pack.appendingPathComponent(fileName))
                }
                let manifest: [String: Any] = [
                    "id": packID,
                    "name": name,
                    "events": events,
                ]
                try JSONSerialization.data(withJSONObject: manifest).write(
                    to: pack.appendingPathComponent("manifest.json"),
                    options: .atomic)
            }
        } catch {
            preconditionFailure("Unable to build isolated Events gallery fixture: \(error)")
        }

        panel = PanelConfigController(
            configFile: configFile,
            lockFile: configLock,
            environment: environment,
            soundPackLibrary: previewStateGallerySoundPackLibrary,
            soundPacksRefreshCoordinator: previewStateGalleryRefreshCoordinator)
        panel.selectSoundSurface(.workBuddy)
        owner = SoundPacksEditorOwner(
            configFile: configFile,
            lockFile: configLock,
            environment: environment,
            soundPackLibrary: previewStateGallerySoundPackLibrary,
            refreshCoordinator: previewStateGalleryRefreshCoordinator)
    }
}

struct AICueExperienceGalleryView: View {
    var body: some View {
        GallerySection(
            title:
                "Events AI Cue · 4 profiles + credential/composer/failure states · 2 languages × 4 text sizes"
        ) {
            ForEach(ClaudioAppLanguage.allCases) { language in
                ForEach(ClaudioInterfaceTextSize.allCases) { textSize in
                    ForEach(SettingsGalleryAppearance.allCases) { appearance in
                        ForEach(PreviewFixtures.aiCueGalleryScenarios) { scenario in
                            GalleryFrame(
                                caption:
                                    "\(language.selfName) · \(textSize.rawValue) · \(appearance.rawValue) · \(scenario.rawValue)"
                            ) {
                                AICueExperienceStateFrame(
                                    scenario: scenario,
                                    language: language,
                                    textSize: textSize
                                )
                                .environment(\.colorScheme, appearance.colorScheme)
                            }
                        }
                    }
                }
            }
        }
    }
}

@MainActor
private struct AICueExperienceStateFrame: View {
    let scenario: PreviewFixtures.AICueGalleryScenario
    @StateObject private var languageStore: ClaudioPreferences
    @StateObject private var viewModel: AICueGenerationViewModel

    init(
        scenario: PreviewFixtures.AICueGalleryScenario,
        language: ClaudioAppLanguage,
        textSize: ClaudioInterfaceTextSize
    ) {
        self.scenario = scenario
        let preferences = ClaudioPreferences(previewLanguage: language)
        preferences.setInterfaceTextSize(textSize)
        _languageStore = StateObject(wrappedValue: preferences)
        _viewModel = StateObject(
            wrappedValue: AICueGenerationViewModel(previewState: scenario.previewState))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            EventSettingsAICueServiceCard(
                viewModel: viewModel,
                languageStore: languageStore,
                onManageCredential: {})

            if scenario.rendersCredentialSheet {
                EventSettingsAICueCredentialSheet(
                    viewModel: viewModel,
                    languageStore: languageStore)
            } else {
                EventSettingsAICueComposerView(
                    viewModel: viewModel,
                    languageStore: languageStore,
                    eventTitle: localizedEventName(.stop, language: languageStore.language),
                    playingCandidateID: scenario.playingCandidateID,
                    onConfigureCredential: {},
                    onPreviewCandidate: { _ in },
                    onAdoptCandidate: { _ in },
                    onClose: {})
            }
        }
        .frame(width: 720, alignment: .leading)
        .padding(18)
        .environment(\.dynamicTypeSize, languageStore.interfaceTextSize.dynamicTypeSize)
    }
}

@MainActor
private struct SettingsWindowRouteFrame: View {
    @StateObject private var model: SettingsWindowPresentationModel<NSRunningApplication>
    @StateObject private var languageStore: ClaudioPreferences
    @StateObject private var dynamicQuietPolicy: DynamicQuietPolicyController
    @StateObject private var loginItemSettings: LoginItemSettingsModel
    @StateObject private var usageSettings: UsageSettingsModel
    @StateObject private var globalShortcutSettings: GlobalShortcutSettingsModel
    @StateObject private var aboutSettings: AboutSettingsModel
    @StateObject private var soundPacksEditorNativeEffects: SoundPacksEditorNativeEffectsDispatcher

    init(
        route: SettingsRoute,
        availability: SettingsRouteAvailability,
        language: ClaudioAppLanguage,
        textSize: ClaudioInterfaceTextSize = .standard,
        experienceScenario: PreviewFixtures.SettingsExperienceScenario? = nil
    ) {
        let preferences = ClaudioPreferences(previewLanguage: language)
        let experienceProfile = experienceScenario?.profile
        preferences.setInterfaceTextSize(textSize)
        _model = StateObject(
            wrappedValue: SettingsWindowPresentationModel(
                initialRoute: route,
                preferences: preferences,
                availability: availability))
        _languageStore = StateObject(wrappedValue: preferences)
        _dynamicQuietPolicy = StateObject(
            wrappedValue: Self.makeDynamicQuietPolicy(for: experienceProfile))
        _loginItemSettings = StateObject(
            wrappedValue: Self.makeLoginItemSettings(for: experienceProfile))
        _usageSettings = StateObject(
            wrappedValue: Self.makeUsageSettings(for: experienceProfile))
        _globalShortcutSettings = StateObject(
            wrappedValue: Self.makeShortcutSettings(for: experienceProfile))
        _aboutSettings = StateObject(
            wrappedValue: Self.makeAboutSettings(for: experienceProfile))
        _soundPacksEditorNativeEffects = StateObject(
            wrappedValue: SoundPacksEditorNativeEffectsDispatcher(
                adapter: SettingsGallerySoundPacksEditorNativeEffectsAdapter()))
    }

    var body: some View {
        SettingsWindowView(
            model: model,
            preferences: languageStore,
            dynamicQuietPolicy: dynamicQuietPolicy,
            loginItemSettings: loginItemSettings,
            usageSettings: usageSettings,
            globalShortcutSettings: globalShortcutSettings,
            aboutSettings: aboutSettings,
            soundPacksEditorNativeEffects: soundPacksEditorNativeEffects
        )
        .frame(
            width: SettingsWindowGeometry.minimumWidth,
            height: SettingsWindowGeometry.minimumHeight)
    }

    private static func makeLoginItemSettings(
        for profile: PreviewFixtures.SettingsExperienceProfile?
    ) -> LoginItemSettingsModel {
        let state = profile?.general ?? .ready
        let status: LoginItemRegistrationState =
            state == .permissionRequired ? .requiresApproval : .disabled
        let model = LoginItemSettingsModel(
            adapter: makeLoginItemServiceAdapter(
                status: { status },
                setEnabled: { enabled in
                    if state == .writeFailed {
                        throw LoginItemOperationFailureReason.systemRejected
                    }
                    return enabled ? .enabled : .disabled
                },
                openSystemSettings: {}))
        if state == .writeFailed {
            model.setEnabled(true)
        }
        return model
    }

    private static func makeDynamicQuietPolicy(
        for profile: PreviewFixtures.SettingsExperienceProfile?
    ) -> DynamicQuietPolicyController {
        let state = profile?.notifications ?? .ready
        let suiteName = "Claudio.SettingsGallery.\(UUID().uuidString)"
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
        let publicationGate = SettingsPreviewPublicationGate()
        let focusState = FocusQuietSystemState(
            authorization: permissionDenied ? .denied : .authorized,
            isFocused: permissionDenied ? nil : false)
        let calendarState = CalendarQuietSystemState(
            authorization: permissionDenied ? .denied : .authorized,
            events: permissionDenied ? nil : [])
        let model = DynamicQuietPolicyController(
            defaults: defaults,
            readFocusState: { focusState },
            requestFocusAuthorization: { $0(focusState) },
            readCalendarState: { _ in calendarState },
            requestCalendarAuthorization: { $0(calendarState) },
            publish: { _, _, now in
                guard publicationGate.succeeds else { return nil }
                return state == .stale
                    ? now : now.addingTimeInterval(12)
            })
        if state == .writeFailed {
            publicationGate.succeeds = false
            model.refresh()
        }
        return model
    }

    private static func makeUsageSettings(
        for profile: PreviewFixtures.SettingsExperienceProfile?
    ) -> UsageSettingsModel {
        let state = profile?.usage ?? .empty
        let empty = usagePresentation(state: .missing, hasEvents: false)
        let presentation: UsageActivityPresentation
        switch state {
        case .ready, .stale:
            presentation = usagePresentation(state: .available, hasEvents: true)
        case .unreadable:
            presentation = usagePresentation(state: .unreadable, hasEvents: false)
        case .loading, .empty, .writeFailed:
            presentation = empty
        }
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

    private static func usagePresentation(
        state: UsageHistorySourceState,
        hasEvents: Bool
    ) -> UsageActivityPresentation {
        let events =
            hasEvents
            ? [
                UsageEventActivity(
                    event: .stop,
                    resultCounts: [
                        UsagePlaybackResultCount(result: .played, count: 4),
                        UsagePlaybackResultCount(result: .muted, count: 1),
                    ])
            ] : []
        return UsageActivityPresentation(
            surfaces: HostID.productVisibleCases.map {
                UsageSurfaceActivity(
                    host: $0,
                    retainedCount: hasEvents ? 5 : 0,
                    events: events,
                    sourceState: state)
            },
            log: UsageDiagnosticLogSnapshot(
                path: "/Users/example/.claudio/claudio.log",
                state: state == .unreadable
                    ? .unreadable : (hasEvents ? .available(sizeBytes: 512) : .missing),
                failures: []))
    }

    private static func makeShortcutSettings(
        for profile: PreviewFixtures.SettingsExperienceProfile?
    ) -> GlobalShortcutSettingsModel {
        let state = profile?.shortcuts ?? .empty
        let readyShortcut = GlobalShortcut(
            shortcutID: .togglePanel,
            keyCode: 0,
            modifiers: [.command, .control])
        let persisted = try? JSONEncoder().encode(readyShortcut)
        let model = GlobalShortcutSettingsModel(
            adapter: GlobalHotKeyAdapter(
                register: { _ in
                    if state == .writeFailed {
                        throw GlobalShortcutAdapterError.conflict
                    }
                },
                unregister: { _ in },
                setActionHandler: { _ in }),
            persistence: GlobalShortcutPersistenceAdapter(
                read: { action in
                    state == .ready && action == .togglePanel
                        ? persisted : nil
                },
                persist: { _, _ in }),
            actionHandler: { _ in })
        if state == .writeFailed {
            model.replace(.togglePanel, keyCode: 0, modifiers: [.command, .control])
        }
        return model
    }

    private static func makeAboutSettings(
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
}

@MainActor
private final class SettingsGallerySoundPacksEditorNativeEffectsAdapter:
    SoundPacksEditorNativeEffectsAdapter
{
    func selectAudioFiles(allowsMultipleSelection: Bool) -> [URL] { [] }
    func playAudio(fileURL: URL, volume: Double) -> TimeInterval? { nil }
    func stopAudio() {}
    func revealInFinder(fileURL: URL) {}
}

@MainActor
private final class SettingsPreviewPublicationGate {
    var succeeds = true
}

// MARK: - Production Agent panel (2 languages × 4 sizes × critical states)

private enum ProductionPanelGalleryScenario: String, CaseIterable, Identifiable {
    case workBuddy = "WorkBuddy 2/5 operational"
    case workBuddyAwaitingExpanded = "WorkBuddy awaiting · scope expanded"
    case needsPack = "needsPack recovery"
    case configFailure = "config failure"
    case libraryFailure = "sound library failure"
    case surfaceFailure = "WorkBuddy surface override failure"

    var id: String { rawValue }
}

struct ProductionPanelGalleryView: View {
    var body: some View {
        GallerySection(
            title: "Production Agent Panel · 2 languages × 4 sizes × 6 critical states"
        ) {
            ForEach(ClaudioAppLanguage.allCases) { language in
                ForEach(ClaudioInterfaceTextSize.allCases) { textSize in
                    ForEach(ProductionPanelGalleryScenario.allCases) { scenario in
                        GalleryFrame(
                            caption:
                                "\(language.selfName) · \(textSize.rawValue) · \(scenario.rawValue)"
                        ) {
                            ProductionPanelStateFrame(
                                language: language,
                                textSize: textSize,
                                scenario: scenario)
                        }
                    }
                }
            }
        }
    }
}

@MainActor
private struct ProductionPanelStateFrame: View {
    let language: ClaudioAppLanguage
    let textSize: ClaudioInterfaceTextSize
    let scenario: ProductionPanelGalleryScenario

    @StateObject private var focusCoordinator: PanelFocusCoordinator
    @StateObject private var hostIntegrations: HostIntegrationPresentationStore
    @StateObject private var bootstrapReports: BootstrapReportPresentationStore
    @StateObject private var languageStore: ClaudioPreferences
    private let panelModel: PanelConfigController
    private let selectedScope: PanelSoundScopeID
    private let soundScopeExpanded: Bool

    init(
        language: ClaudioAppLanguage,
        textSize: ClaudioInterfaceTextSize,
        scenario: ProductionPanelGalleryScenario
    ) {
        self.language = language
        self.textSize = textSize
        self.scenario = scenario

        let hostPhase: PreviewFixtures.WorkBuddyVisualPhase =
            scenario == .workBuddyAwaitingExpanded
            ? .awaitingActivation : .allImplementedBindingsCurrent
        let hostState = PreviewFixtures.workBuddyVisualScenarios.first {
            $0.phase == hostPhase
        }!.state
        soundScopeExpanded = scenario == .workBuddyAwaitingExpanded
        _focusCoordinator = StateObject(wrappedValue: PanelFocusCoordinator())
        _hostIntegrations = StateObject(
            wrappedValue: HostIntegrationPresentationStore(
                state: hostState,
                configurationSources: [:]))
        _bootstrapReports = StateObject(
            wrappedValue: BootstrapReportPresentationStore(
                store: BootstrapReportStore(
                    directory: URL(fileURLWithPath: "/dev/null/claudio-preview-reports"))))
        let languageStore = ClaudioPreferences(previewLanguage: language)
        languageStore.setInterfaceTextSize(textSize)
        _languageStore = StateObject(wrappedValue: languageStore)

        let baseConfig = ClaudioConfig(
            selectedPack: "gallery-pack",
            masterVolume: 0.8,
            eventsEnabled: Dictionary(
                uniqueKeysWithValues: Event.allCases.map { ($0.cliName, true) }))
        let presentRows = Event.allCases.map {
            EventRow(
                event: $0,
                coverage: .present(fileName: "\($0.cliName).aiff"),
                enabled: true)
        }

        switch scenario {
        case .workBuddy, .workBuddyAwaitingExpanded:
            selectedScope = .surface(.workBuddy)
            panelModel = PanelConfigController(
                previewConfigState: .operational(baseConfig),
                selectedSurface: .workBuddy,
                eventRows: presentRows,
                selectedPackMetadata: SelectedPackMetadata(
                    id: "gallery-pack",
                    name: "Orbit Signals"),
                environment: previewAudioImportEnvironment)
        case .needsPack:
            selectedScope = .global
            panelModel = PanelConfigController(
                previewConfigState: .needsPack,
                libraryPresentationState: .ready,
                environment: previewAudioImportEnvironment)
        case .configFailure:
            selectedScope = .global
            panelModel = PanelConfigController(
                previewConfigState: .malformed(
                    reason: language == .english
                        ? "config.json contains an invalid master_volume value."
                        : "config.json 的 master_volume 值无效。"),
                libraryPresentationState: .ready,
                environment: previewAudioImportEnvironment)
        case .libraryFailure:
            selectedScope = .global
            panelModel = PanelConfigController(
                previewConfigState: .operational(baseConfig),
                selectedPackMetadata: SelectedPackMetadata(
                    id: "gallery-pack",
                    name: "Orbit Signals"),
                libraryPresentationState: .loadFailed(
                    reason: language == .english
                        ? "The sound pack library could not be read."
                        : "无法读取声音包库。"),
                environment: previewAudioImportEnvironment)
        case .surfaceFailure:
            var invalidBase = baseConfig
            invalidBase.invalidSurfaceOverrideKeys = [HostSurfaceID.workBuddy.rawValue]
            let failedEffective = ClaudioConfig(
                selectedPack: "",
                masterVolume: baseConfig.masterVolume,
                eventsEnabled: Dictionary(
                    uniqueKeysWithValues: Event.allCases.map { ($0.cliName, false) }))
            selectedScope = .surface(.workBuddy)
            panelModel = PanelConfigController(
                previewConfigState: .operational(invalidBase),
                effectiveConfig: failedEffective,
                selectedSurface: .workBuddy,
                surfaceSoundIssue: language == .english
                    ? "The WorkBuddy sound override is damaged; playback stopped without falling back to Global."
                    : "WorkBuddy 的声音覆盖已损坏；已停止播放，且未回退到 Global。",
                eventRows: Event.allCases.map {
                    EventRow(event: $0, coverage: .unmapped, enabled: false)
                },
                libraryPresentationState: .ready,
                environment: previewAudioImportEnvironment)
        }
    }

    var body: some View {
        PanelView(
            previewPanelModel: panelModel,
            previewScope: selectedScope,
            previewSoundScopeExpanded: soundScopeExpanded,
            audioEnvironment: previewAudioImportEnvironment,
            focusCoordinator: focusCoordinator,
            hostIntegrations: hostIntegrations,
            bootstrapReports: bootstrapReports,
            languageStore: languageStore
        )
        .frame(height: 560)
    }
}

// MARK: - OnboardingState (6 fixtures)

struct OnboardingGalleryView: View {
    var body: some View {
        GallerySection(title: "Legacy OnboardingState (\(PreviewFixtures.onboardingStates.count))")
        {
            ForEach(Array(PreviewFixtures.onboardingStates.enumerated()), id: \.offset) {
                _, state in
                GalleryFrame(caption: onboardingStateCaption(state)) {
                    OnboardingStateFrame(state: state)
                }
            }
        }
    }
}

/// One onboarding frame — owns its own `@FocusState` (SwiftUI requires the property
/// wrapper to be declared on a concrete `View`, not conjured ad hoc per loop iteration),
/// mirroring `PanelView`'s real `focusedTarget` ownership at a per-frame scale.
private struct OnboardingStateFrame: View {
    let state: OnboardingState
    /// T17: the CTA's own state, pinned alongside `state` (both are `#if DEBUG` preview-init
    /// parameters). `.idle` for the six plain ``OnboardingState`` frames.
    var actionState: OnboardingActionState = .idle
    @FocusState private var focusedTarget: PanelFocusTarget?

    var body: some View {
        OnboardingView(
            viewModel: OnboardingViewModel(previewState: state, actionState: actionState),
            focusedTarget: $focusedTarget
        )
        .frame(width: CGFloat(standardPanelWidth))
    }
}

// MARK: - OnboardingActionState (T17: the CTA's own state — in-flight / failed)

/// The two visual states T17 introduces — a CTA that is RUNNING (disabled + spinner + a
/// changed label) and a CTA that FAILED (a rejection row, optionally with a 「查看原因」
/// disclosure). Without this section they would be the first states in the repo that no frame
/// of the 视觉真相源 has ever rendered — in either theme — while `assertExhaustive()` stayed
/// green, because `onboardingStates` still covers its own six cases perfectly.
///
/// Rendered against `.notInstalled` (the state a first-run user actually presses 接管 from),
/// except `.running(.disconnect)` which only exists in `.installed`.
struct OnboardingActionGalleryView: View {
    var body: some View {
        GallerySection(
            title: "Legacy OnboardingActionState (\(PreviewFixtures.onboardingActionStates.count))"
        ) {
            ForEach(
                Array(PreviewFixtures.onboardingActionStates.enumerated()), id: \.offset
            ) { _, actionState in
                GalleryFrame(caption: onboardingActionStateCaption(actionState)) {
                    OnboardingStateFrame(
                        state: hostState(for: actionState), actionState: actionState)
                }
            }
        }
    }

    /// 哪个 ``OnboardingState`` 承载这一帧。`.running(.disconnect)` 只可能发生在 `.installed`
    /// （断开是它的次 CTA）；`.reported` 同理 —— 告知只从一次**成功的接管**而来，而成功必然让
    /// `refresh()` 把 state 推成 `.installed`（T17f）。其余都用 `.notInstalled` —— 新用户真正
    /// 按下「接管」的那个状态。
    ///
    /// ⚠️ **诚实标注**：这一帧渲染的是 `OnboardingStateFrame` → `OnboardingView`，而真机上
    /// `.installed` 渲染的是 `PanelView` 的运行态面板 —— 也就是说画廊在这里展示的是告知行的
    /// **长相**（字形 / 颜色 / 断行 / Dynamic Type），不是它**真实的落位**。`.running(.disconnect)`
    /// 早就有同一条错位，本次没有引入新的债。真实落位由 `ViewWiringSuite` 的两条文本绊线守着
    /// （两个渲染点都必须调 `onboardingVisibleNotices`）。
    private func hostState(for actionState: OnboardingActionState) -> OnboardingState {
        if case .running(.disconnect) = actionState { return .installed }
        if case .reported = actionState { return .installed }
        return .notInstalled
    }
}

private func onboardingActionStateCaption(_ state: OnboardingActionState) -> String {
    switch state {
    case .idle: ".idle"
    case .running(.takeOver): ".running(.takeOver) × .notInstalled"
    case .running(.disconnect): ".running(.disconnect) × .installed"
    case .failed(let action, _, let detail):
        detail == nil
            ? ".failed(\(action), detail: nil) × .notInstalled"
            : ".failed(\(action), detail: …) × .notInstalled（可展开）"
    case .reported(let notices):
        ".reported(\(notices.count) 条) × .installed —— 我替你做了主"
    }
}

/// A developer-facing (not user-facing) label for the gallery caption — exhaustive over
/// every ``OnboardingState`` case, no `default:`, so a 7th case fails this file to
/// compile until it's captioned too (on top of ``PreviewFixtures``'s own guard).
private func onboardingStateCaption(_ state: OnboardingState) -> String {
    switch state {
    case .claudeCodeNotInstalled: ".claudeCodeNotInstalled"
    case .helperMissing: ".helperMissing"
    case .settingsNotWritable(let reason): ".settingsNotWritable(reason: \"\(reason)\")"
    case .settingsParseFailure(let reason): ".settingsParseFailure(reason: \"\(reason)\")"
    case .notInstalled: ".notInstalled"
    case .installed: ".installed"
    }
}

// MARK: - EventRow / CoverageState (6 fixtures)

struct EventRowGalleryView: View {
    var body: some View {
        GallerySection(title: "EventRow / CoverageState (\(PreviewFixtures.eventRows.count))") {
            ForEach(Array(PreviewFixtures.eventRows.enumerated()), id: \.offset) { _, row in
                GalleryFrame(caption: eventRowCaption(row)) {
                    EventRowStateFrame(row: row)
                }
            }
        }
    }
}

private struct EventRowStateFrame: View {
    let row: EventRow
    @FocusState private var focusedTarget: PanelFocusTarget?

    var body: some View {
        // 生产事件行只负责扫读、显式编辑路由、手工试听与自动事件静音；画廊不写磁盘。
        EventRowView(
            row: row,
            previewAvailability: eventPreviewAvailability(
                coverage: row.coverage,
                masterVolume: 1),
            focusedTarget: $focusedTarget,
            onPreview: {}
        )
        .frame(width: CGFloat(standardPanelWidth))
    }
}

private func eventRowCaption(_ row: EventRow) -> String {
    "\(row.event.cliName) · \(coverageStateCaption(row.coverage)) · enabled=\(row.enabled)"
}

/// Exhaustive over every ``CoverageState`` case, no `default:`.
private func coverageStateCaption(_ state: CoverageState) -> String {
    switch state {
    case .present: ".present"
    case .unmapped: ".unmapped"
    case .broken: ".broken"
    }
}

// MARK: - Event-row host indicators (5 approved fact states)

struct EventHostIndicatorGalleryView: View {
    var body: some View {
        GallerySection(
            title: "Event host indicators (\(PreviewFixtures.eventHostIndicatorScenarios.count))"
        ) {
            ForEach(PreviewFixtures.eventHostIndicatorScenarios) { scenario in
                GalleryFrame(caption: "\(scenario.id) · \(scenario.title)") {
                    EventHostIndicatorStateFrame(scenario: scenario)
                }
            }
        }
    }
}

private struct EventHostIndicatorStateFrame: View {
    let scenario: PreviewFixtures.EventHostIndicatorScenario
    @FocusState private var focusedTarget: PanelFocusTarget?

    var body: some View {
        let matrix = hostCapabilityMatrixPresentation(from: scenario.state.matrix)
        EventRowView(
            row: scenario.row,
            hostIndicators: eventHostIndicatorPresentations(
                event: scenario.row.event,
                matrix: matrix),
            previewAvailability: .available(fileName: "\(scenario.row.event.cliName).mp3"),
            focusedTarget: $focusedTarget,
            adaptation: scenario.adaptation
        )
        .frame(width: CGFloat(scenario.adaptation.panelWidth))
    }
}

// MARK: - Product UI refactor states

struct PanelPackSectionGalleryView: View {
    var body: some View {
        GallerySection(
            title: "PanelPackSectionState (\(PreviewFixtures.panelPackSectionStates.count))"
        ) {
            ForEach(
                Array(PreviewFixtures.panelPackSectionStates.enumerated()),
                id: \.offset
            ) { _, state in
                GalleryFrame(caption: panelPackSectionCaption(state)) {
                    PanelPackSectionStateFrame(state: state)
                }
            }
        }
    }
}

private struct PanelPackSectionStateFrame: View {
    let state: PanelPackSectionState
    @FocusState private var focusedTarget: PanelFocusTarget?

    var body: some View {
        PanelPackSectionView(
            state: state,
            typeScale: 1,
            focusedTarget: $focusedTarget,
            adaptation: panelLayoutAdaptation(for: .standard),
            onSelect: { _ in }
        )
        .frame(width: CGFloat(standardPanelWidth))
    }
}

private func panelPackSectionCaption(_ state: PanelPackSectionState) -> String {
    switch state {
    case .loading: ".loading"
    case .pinned(let cards): ".pinned(\(cards.count))"
    case .noPinnedPacks(let count): ".noPinnedPacks(available: \(count))"
    case .noPacks: ".noPacks"
    case .readFailed: ".readFailed"
    }
}

struct InterfaceTextSizeGalleryView: View {
    var body: some View {
        GallerySection(
            title: "Interface + EventRow C layout (2 languages × 4 sizes × 3 mapping states)"
        ) {
            ForEach(PreviewFixtures.eventRowLayoutScenarios) { scenario in
                GalleryFrame(
                    caption:
                        "\(scenario.language.selfName) · .\(scenario.interfaceTextSize.rawValue)"
                ) {
                    InterfaceTextSizeFrame(scenario: scenario)
                }
            }
        }
    }
}

private struct InterfaceTextSizeFrame: View {
    let scenario: PreviewFixtures.EventRowLayoutScenario
    @StateObject private var languageStore: ClaudioPreferences
    @FocusState private var focusedTarget: PanelFocusTarget?

    init(scenario: PreviewFixtures.EventRowLayoutScenario) {
        self.scenario = scenario
        let store = ClaudioPreferences(defaults: UserDefaults())
        store.setLanguage(scenario.language)
        _languageStore = StateObject(wrappedValue: store)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            InterfaceSettingsPopoverContent(
                selection: .constant(scenario.interfaceTextSize),
                languageStore: languageStore)
            Text(panelSummary)
                .font(ClaudioTheme.font(.productTitle))
            ForEach(scenario.samples) { sample in
                EventRowView(
                    row: sample.row,
                    hostIndicators: localizedEventHostIndicators(
                        eventHostIndicatorPresentations(
                            event: sample.row.event,
                            matrix: hostCapabilityMatrixPresentation(from: sample.state.matrix)),
                        language: scenario.language),
                    previewAvailability: eventPreviewAvailability(
                        coverage: sample.row.coverage,
                        masterVolume: 1),
                    language: scenario.language,
                    focusedTarget: $focusedTarget,
                    adaptation: scenario.adaptation)
            }
        }
        .frame(
            width: CGFloat(scenario.adaptation.panelWidth),
            alignment: .leading
        )
        .environment(\.dynamicTypeSize, scenario.interfaceTextSize.dynamicTypeSize)
    }

    private var panelSummary: String {
        let l10n = ClaudioL10n(language: scenario.language)
        let header = l10n.format(.panelHeaderWithPack, Int64(2), "极简铃" as NSString)
        return "\(header) · \(l10n.plural(.panelAudibleEventsCount, count: 4))"
    }
}

// MARK: - Fixed panel quit footer (2 languages × 4 interface text sizes)

struct PanelQuitFooterGalleryView: View {
    var body: some View {
        GallerySection(title: "Panel quit footer (2 languages × 4 sizes · 312/360pt)") {
            ForEach(ClaudioAppLanguage.allCases) { language in
                ForEach(ClaudioInterfaceTextSize.allCases) { interfaceTextSize in
                    GalleryFrame(
                        caption: "\(language.selfName) · .\(interfaceTextSize.rawValue)"
                    ) {
                        PanelQuitFooterStateFrame(
                            language: language,
                            interfaceTextSize: interfaceTextSize)
                    }
                }
            }
        }
    }
}

private struct PanelQuitFooterStateFrame: View {
    let language: ClaudioAppLanguage
    let interfaceTextSize: ClaudioInterfaceTextSize
    @FocusState private var focusedTarget: PanelFocusTarget?

    var body: some View {
        PanelQuitFooter(
            language: language,
            typeScale: CGFloat(interfaceTextSize.scale),
            focusedTarget: $focusedTarget,
            onQuit: {}
        )
        .frame(
            width: CGFloat(
                panelLayoutAdaptation(
                    for: panelTypeSizeTier(for: interfaceTextSize)
                ).panelWidth)
        )
        .environment(\.dynamicTypeSize, interfaceTextSize.dynamicTypeSize)
    }
}

// MARK: - MasterVolumeState (6 fixtures, PLAN-MASTER-VOLUME.md D33/D38)

struct MasterVolumeGalleryView: View {
    var body: some View {
        GallerySection(
            title: "MasterVolumeState (\(PreviewFixtures.masterVolumeStates.count))"
        ) {
            ForEach(Array(PreviewFixtures.masterVolumeStates.enumerated()), id: \.offset) {
                _, state in
                GalleryFrame(caption: masterVolumeStateCaption(state)) {
                    MasterVolumeStateFrame(state: state)
                }
            }
        }
    }
}

/// One master-volume frame. The gallery never actually writes anything — every frame's state
/// is fully determined by ``PreviewFixtures/MasterVolumeState``, so ``onCommit`` is a no-op
/// that always reports failure (never invoked in practice, since nothing here drags the
/// slider) and ``focusCoordinator`` is a fresh, never-observed instance (mirrors this file's
/// other frames constructing throwaway view-models pinned to no particular state).
///
/// D39: `.writeFailed` is rendered by `PanelView`, not `MasterVolumeRow` itself — this frame
/// reproduces that exact split (row, then a SEPARATE error row) for the `.failed` case, rather
/// than inventing a shape `MasterVolumeRow` alone could never produce on its own.
private struct MasterVolumeStateFrame: View {
    let state: PreviewFixtures.MasterVolumeState
    @FocusState private var focusedTarget: PanelFocusTarget?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            MasterVolumeRow(
                diskVolume: volume,
                onCommit: { _ in nil },
                focusCoordinator: PanelFocusCoordinator(),
                focusedTarget: $focusedTarget,
                adaptation: panelLayoutAdaptation(for: .standard),
                language: .zhHans)
            if case .failed(_, let message) = state {
                FailureRow(message: message)
            }
        }
        .frame(width: CGFloat(standardPanelWidth))
    }

    private var volume: Double {
        switch state {
        case .value(let volume): volume
        case .failed(let volume, _): volume
        }
    }

    /// 直接渲染产品用的那一个 ``FailureRow``（`PanelRows.swift`）—— 展柜画的就是真身，不是它的仿品。
    ///
    /// 【这里原本是第七份手抄副本，而它的注释把整个病灶说穿了】原文：
    ///
    /// > Mirrors `PanelView.errorNotice`'s shape **verbatim** … this repo's established
    /// > 「拒绝行」 pattern is **duplicated per-view rather than shared** …, since each already
    /// > lives as a `private` method on a `View` with **no public surface for another file to call**.
    ///
    /// 那句话是**对当时事实的准确描述**，也正是复制粘贴自我繁殖的机制：前五份全是 `private`，于是
    /// 第六个想用它的人**只能再抄一份** —— 而每一份新副本，都被前面那些副本正当化了。抄到第七份时，
    /// 「大家都是抄的」本身成了继续抄下去的理由。
    ///
    /// 它还有一个副本独有的 bug：字号是裸 `size: 11`，**没有乘 `typeScale`** —— 展柜里这一行字
    /// 从来不跟随 Dynamic Type。换成 `FailureRow` 之后它**免费**获得了跟随（组件自带
    /// `@ScaledMetric`），这一条谁都没去修过，它是被这次合并顺手带走的。
    ///
    /// 现在那个「no public surface」不成立了：``FailureRow`` 就是那个 surface。
}

/// Exhaustive over every ``MasterVolumeState`` case, no `default:`.
private func masterVolumeStateCaption(_ state: PreviewFixtures.MasterVolumeState) -> String {
    switch state {
    case .value(let volume): ".value(\(volume))"
    case .failed(let volume, let message):
        ".failed(volume: \(volume), message: \"\(message.prefix(24))…\")"
    }
}

// MARK: - PackCard / PackCardState (6 fixtures)

struct PackCardGalleryView: View {
    var body: some View {
        GallerySection(title: "PackCard / PackCardState (\(PreviewFixtures.packCards.count))") {
            ForEach(Array(PreviewFixtures.packCards.enumerated()), id: \.offset) { _, card in
                GalleryFrame(caption: packCardCaption(card)) {
                    PackCardStateFrame(card: card)
                }
            }
        }
    }
}

private struct PackCardStateFrame: View {
    let card: PackCard
    @FocusState private var focusedTarget: PanelFocusTarget?

    var body: some View {
        // `PackCardView` itself is `private` to `PackGalleryView.swift` — a single-card
        // array is the only way to render exactly one card via the public
        // `PackGalleryView` API, never a second, parallel card-rendering path.
        PackGalleryView(cards: [card], focusedTarget: $focusedTarget, language: .zhHans)
    }
}

private func packCardCaption(_ card: PackCard) -> String {
    "\(card.id) · \(packCardStateCaption(card.state)) · isSelected=\(card.isSelected)"
}

/// Exhaustive over every ``PackCardState`` case, no `default:`.
private func packCardStateCaption(_ state: PackCardState) -> String {
    switch state {
    case .complete: ".complete"
    case .partial(let present, let total): ".partial(\(present)/\(total))"
    case .broken: ".broken"
    }
}

// MARK: - Host integrations (all-product + WorkBuddy pre-RC scenarios)

/// 全部产品宿主展柜直接渲染生产 ``IntegrationsSettingsDestinationView``；WorkBuddy 的七态
/// 继续进入同一份 production view，不在 gallery 复制第二套展示组件。
struct HostIntegrationGalleryView: View {
    var body: some View {
        let scenarioCount =
            PreviewFixtures.hostIntegrationScenarios.count
            + PreviewFixtures.workBuddyVisualScenarios.count + 1
        GallerySection(
            title: "Host integrations · 2 languages (\(scenarioCount))"
        ) {
            ForEach(ClaudioAppLanguage.allCases) { language in
                ForEach(ClaudioInterfaceTextSize.allCases) { textSize in
                    ForEach(SettingsGalleryAppearance.allCases) { appearance in
                        ForEach(PreviewFixtures.hostIntegrationScenarios) { scenario in
                            GalleryFrame(
                                caption:
                                    "\(language.selfName) · \(textSize.rawValue) · \(appearance.rawValue) · \(scenario.id) · \(scenario.title)"
                            ) {
                                HostIntegrationStateFrame(
                                    scenario: scenario,
                                    language: language,
                                    textSize: textSize
                                )
                                .environment(\.colorScheme, appearance.colorScheme)
                            }
                        }
                        ForEach(PreviewFixtures.workBuddyVisualScenarios) { scenario in
                            GalleryFrame(
                                caption:
                                    "\(language.selfName) · \(textSize.rawValue) · \(appearance.rawValue) · \(scenario.id) · \(scenario.title)"
                            ) {
                                HostIntegrationStateFrame(
                                    scenario: PreviewFixtures.HostIntegrationScenario(
                                        id: scenario.id,
                                        title: scenario.title,
                                        state: scenario.state),
                                    language: language,
                                    textSize: textSize
                                )
                                .environment(\.colorScheme, appearance.colorScheme)
                            }
                        }
                        if let disconnectScenario = PreviewFixtures.workBuddyVisualScenarios.first(
                            where: { $0.phase == .taskStartCurrent })
                        {
                            GalleryFrame(
                                caption:
                                    "\(language.selfName) · \(textSize.rawValue) · \(appearance.rawValue) · workbuddy.disconnect-in-flight · WorkBuddy 断开中"
                            ) {
                                HostIntegrationStateFrame(
                                    scenario: PreviewFixtures.HostIntegrationScenario(
                                        id: "workbuddy.disconnect-in-flight",
                                        title: "WorkBuddy 断开中",
                                        state: disconnectScenario.state),
                                    language: language,
                                    textSize: textSize,
                                    previewInFlightAction: .disconnect(.workBuddy)
                                )
                                .environment(\.colorScheme, appearance.colorScheme)
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct HostIntegrationStateFrame: View {
    @StateObject private var model: IntegrationDestinationModel
    @StateObject private var focusCoordinator = IntegrationDestinationFocusCoordinator()
    @StateObject private var languageStore: ClaudioPreferences

    init(
        scenario: PreviewFixtures.HostIntegrationScenario,
        language: ClaudioAppLanguage,
        textSize: ClaudioInterfaceTextSize = .standard,
        previewInFlightAction: HostIntegrationUserAction? = nil
    ) {
        let languageStore = ClaudioPreferences(defaults: UserDefaults())
        languageStore.setLanguage(language)
        languageStore.setInterfaceTextSize(textSize)
        _languageStore = StateObject(wrappedValue: languageStore)
        let store = HostIntegrationPresentationStore(
            state: scenario.state,
            configurationSources: [
                .claudeCode: "~/.claude/settings.json",
                .codex: "~/.codex/hooks.json",
                .workBuddy: "~/.workbuddy/settings.json",
            ])
        let content = store.content
        let unchanged = IntegrationDestinationActionOutcome(
            content: content,
            feedbackKind: .information,
            feedbackMessage: "预览不会修改配置")
        let model = IntegrationDestinationModel(
            content: content,
            refreshHandler: IntegrationDestinationRefreshHandler { unchanged },
            actionHandler: IntegrationDestinationActionHandler { _ in unchanged },
            preferences: languageStore,
            clipboardWriter: IntegrationDestinationClipboardWriter { _ in true })
        if let previewInFlightAction {
            model.pinPreviewInFlight(previewInFlightAction)
        }
        _model = StateObject(wrappedValue: model)
    }

    var body: some View {
        IntegrationsSettingsDestinationView(
            model: model,
            focusCoordinator: focusCoordinator,
            languageStore: languageStore,
            onManageEvents: nil,
            onAnnouncement: nil
        )
        .frame(width: 820, height: 700)
    }
}

// MARK: - Shared gallery chrome

private struct GallerySection<Content: View>: View {
    let title: String
    let content: Content
    @Environment(\.colorScheme) private var colorScheme

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .monospacedDigit()
                // 既有 token，不是 SwiftUI 默认 `.primary`。
                .foregroundColor(ClaudioColor.text(colorScheme))
            content
        }
    }
}

private struct GalleryFrame<Content: View>: View {
    let caption: String
    let content: Content
    @Environment(\.colorScheme) private var colorScheme

    init(caption: String, @ViewBuilder content: () -> Content) {
        self.caption = caption
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(caption)
                .font(.system(size: 10, design: .monospaced))
                .monospacedDigit()
                // 既有 token（`text-2`），不是非 token 的 `.secondary`。
                .foregroundColor(ClaudioColor.textSecondary(colorScheme))
            // LOAD-BEARING (`/ship` 评审): every framed view here — ``EventRowView``,
            // ``PackGalleryView``, ``OnboardingView`` — paints NO surface of its own; in
            // production ``PanelView`` (the composition root) supplies it. Without this
            // background, the gallery rendered all five event colors, every
            // glyph tile and every reject row on SwiftUI's **untokenized default window
            // background** — and that surface is precisely what every contrast assertion in
            // `ContrastSuite` is talking about. A 视觉真相源 (DESIGN.md line 134) that shows
            // the colors on the wrong surface is worse than no gallery: it makes a
            // contrast failure look fine (which is exactly how the glyph-tile ≥3:1 failure
            // this pass fixes survived review). `panel` in both schemes — the same token
            // `PanelView` uses.
            content
                .background(ClaudioColor.panel(colorScheme))
        }
        .padding(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                // 既有 token，不是非 token 的 `Color.gray.opacity(0.2)`。
                .strokeBorder(ClaudioColor.hairlineStrong(colorScheme))
        )
    }
}

// MARK: - Preview-only support environment (never touches user data)

/// A fixed-duration stub — the gallery never actually imports a file (every drop-zone
/// frame's state is pinned via `previewState:`, not produced by running the pipeline),
/// so this is only ever present to satisfy ``AudioImportEnvironment``'s required
/// `durationProbe` parameter.
private struct PreviewDurationProbe: AudioDurationProbing {
    func probeDuration(of fileURL: URL) -> TimeInterval? { 1.0 }
}

/// One isolated temporary root backs every DEBUG gallery dependency. Production initializers can
/// therefore exercise their normal scan/refresh contracts without reading Claudio's user data.
private let previewStateGalleryRoot = FileManager.default.temporaryDirectory
    .appendingPathComponent("claudio-state-gallery-\(UUID().uuidString)", isDirectory: true)

private let previewAudioImportEnvironment = AudioImportEnvironment(
    userPacksDirectory: previewStateGalleryRoot.appendingPathComponent(
        "packs",
        isDirectory: true),
    durationProbe: PreviewDurationProbe(),
    packsLockFile: previewStateGalleryRoot.appendingPathComponent("packs.lock")
)

@MainActor
private let previewStateGallerySoundPackLibrary = SoundPackLibrary(
    environment: previewAudioImportEnvironment)

@MainActor
private let previewStateGalleryRefreshCoordinator = SoundPacksRefreshCoordinator()

// MARK: - Preview providers (classic `PreviewProvider` ONLY — `#Preview` does not
// compile under CommandLineTools, see this file's header doc comment)

struct OnboardingGalleryView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            OnboardingGalleryView().preferredColorScheme(.light)
            OnboardingGalleryView().preferredColorScheme(.dark)
        }
    }
}

struct EventRowGalleryView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            EventRowGalleryView().preferredColorScheme(.light)
            EventRowGalleryView().preferredColorScheme(.dark)
        }
    }
}

struct EventHostIndicatorGalleryView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            EventHostIndicatorGalleryView().preferredColorScheme(.light)
            EventHostIndicatorGalleryView().preferredColorScheme(.dark)
        }
    }
}

struct MasterVolumeGalleryView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            MasterVolumeGalleryView().preferredColorScheme(.light)
            MasterVolumeGalleryView().preferredColorScheme(.dark)
        }
    }
}

struct PanelQuitFooterGalleryView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            PanelQuitFooterGalleryView().preferredColorScheme(.light)
            PanelQuitFooterGalleryView().preferredColorScheme(.dark)
        }
    }
}

struct PackCardGalleryView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            PackCardGalleryView().preferredColorScheme(.light)
            PackCardGalleryView().preferredColorScheme(.dark)
        }
    }
}

struct HostIntegrationGalleryView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            HostIntegrationGalleryView().preferredColorScheme(.light)
            HostIntegrationGalleryView().preferredColorScheme(.dark)
        }
    }
}

/// The combined, one-screen gallery (T14 acceptance criterion 2: "browsable in one
/// Xcode Canvas screen").
struct StateGalleryView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            StateGalleryView().preferredColorScheme(.light)
            StateGalleryView().preferredColorScheme(.dark)
        }
    }
}
#endif
