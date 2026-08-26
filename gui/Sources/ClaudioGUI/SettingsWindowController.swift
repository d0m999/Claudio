import AppKit
import ClaudioCore
import ClaudioGUICore
import ClaudioLocalization
import Combine
import SoundPacksWindow
import SwiftUI

/// App-lifetime owner of the single retained unified Settings window.
///
/// Its one lazy `NSWindow` survives close, and every close consumes at most one
/// focus/activation handback. While visible it preserves the most recently activated external app,
/// so migrated destinations keep the same handback contract as their former retained windows. The
/// shared preferences expose only destinations whose real content has shipped, so future route
/// galleries stay DEBUG-only without hiding General from users.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let preferences: ClaudioPreferences
    private let loginItemSettings: LoginItemSettingsModel
    private let usageSettings: UsageSettingsModel
    private let globalShortcutSettings: GlobalShortcutSettingsModel
    private let model: SettingsWindowPresentationModel<NSRunningApplication>
    private let soundPacksEditorOwner: SoundPacksEditorOwner
    private let eventSettingsModel: PanelConfigController
    private let eventSettingsSelection: EventSettingsWindowSelection
    private let hostIntegrations: HostIntegrationPresentationStore
    private let integrationsModel: IntegrationsWindowModel
    private let integrationsFocusCoordinator = IntegrationsWindowFocusCoordinator()
    private let aiCueViewModel: AICueGenerationViewModel
    private let audioEnvironment: AudioImportEnvironment
    private let onEventAudibilityInputsChanged: @MainActor () -> Void
    private let onAdoptAICue:
        @MainActor (AICueAdoptionRequest) async -> Result<
            AICueAdoptionOutcome, AICueAdoptionError
        >
    private let dynamicQuietObserver: DynamicQuietSystemObserver
    private var window: NSWindow?
    private var isPresentingWindow = false
    private var focusRestoration: (@MainActor (NSRunningApplication?) -> Void)?
    private var handbackTracker = RetainedWindowHandbackTracker<NSRunningApplication>()
    private var externalActivationCancellable: AnyCancellable?
    private var languageCancellable: AnyCancellable?
    private var integrationsRouteCancellable: AnyCancellable?
    private var soundPackAvailabilityCancellable: AnyCancellable?
    private var soundsRouteAnnouncementCancellable: AnyCancellable?
    private var soundPackSelectionAnnouncementCancellable: AnyCancellable?
    private var soundPackLibraryAnnouncementCancellable: AnyCancellable?
    private var soundPackStatusAnnouncementCancellable: AnyCancellable?

    init(
        preferences: ClaudioPreferences,
        loginItemSettings: LoginItemSettingsModel,
        usageSettings: UsageSettingsModel,
        globalShortcutSettings: GlobalShortcutSettingsModel,
        soundPacksEditorOwner: SoundPacksEditorOwner,
        eventSettingsModel: PanelConfigController,
        eventSettingsSelection: EventSettingsWindowSelection,
        hostIntegrations: HostIntegrationPresentationStore,
        integrationsModel: IntegrationsWindowModel,
        aiCueViewModel: AICueGenerationViewModel,
        audioEnvironment: AudioImportEnvironment,
        onEventAudibilityInputsChanged: @escaping @MainActor () -> Void,
        onAdoptAICue:
            @escaping @MainActor (AICueAdoptionRequest) async -> Result<
                AICueAdoptionOutcome, AICueAdoptionError
            >
    ) {
        self.preferences = preferences
        self.loginItemSettings = loginItemSettings
        self.usageSettings = usageSettings
        self.globalShortcutSettings = globalShortcutSettings
        self.soundPacksEditorOwner = soundPacksEditorOwner
        self.eventSettingsModel = eventSettingsModel
        self.eventSettingsSelection = eventSettingsSelection
        self.hostIntegrations = hostIntegrations
        self.integrationsModel = integrationsModel
        self.aiCueViewModel = aiCueViewModel
        self.audioEnvironment = audioEnvironment
        self.onEventAudibilityInputsChanged = onEventAudibilityInputsChanged
        self.onAdoptAICue = onAdoptAICue
        dynamicQuietObserver = DynamicQuietSystemObserver()
        model = SettingsWindowPresentationModel(
            preferences: preferences,
            availability: settingsRouteAvailability(
                packIDs: Set(soundPacksEditorOwner.model.packCards.map(\.id)),
                libraryState: soundPacksEditorOwner.model.libraryPresentationState,
                publishedSurfaces: Set(
                    hostIntegrations.content.sourceRows.map { $0.host.surfaceID })))
        super.init()

        externalActivationCancellable = NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didActivateApplicationNotification)
            .sink { [weak self] notification in
                MainActor.assumeIsolated {
                    guard
                        let self,
                        let application =
                            notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                            as? NSRunningApplication
                    else { return }
                    self.handbackTracker.noteExternalActivation(
                        application,
                        isWindowVisible: self.window?.isVisible == true,
                        isCurrentApplication: application.processIdentifier
                            == ProcessInfo.processInfo.processIdentifier)
                }
            }

        languageCancellable = preferences.$snapshot
            .map(\.language)
            .removeDuplicates()
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.updateWindowTitle()
                }
            }

        integrationsRouteCancellable = model.$resolution
            .map(\.destination)
            .removeDuplicates()
            .sink { [weak self] destination in
                MainActor.assumeIsolated {
                    self?.updateIntegrationsPresentationState(
                        selectedDestination: destination)
                }
            }

        soundPackAvailabilityCancellable = soundPacksEditorOwner.model.$packCards
            .combineLatest(
                soundPacksEditorOwner.model.$libraryPresentationState,
                hostIntegrations.$content
            )
            .map { cards, libraryState, integrationContent in
                settingsRouteAvailability(
                    packIDs: Set(cards.map(\.id)),
                    libraryState: libraryState,
                    publishedSurfaces: Set(
                        integrationContent.sourceRows.map { $0.host.surfaceID }))
            }
            .removeDuplicates()
            .sink { [weak self] availability in
                MainActor.assumeIsolated {
                    self?.model.updateAvailability(availability)
                }
            }

        installSoundPackAnnouncementObservers()
    }

    func showWindow(
        route: SettingsRoute? = nil,
        returnFocusTo application: NSRunningApplication?,
        onClose restoration: @escaping @MainActor (NSRunningApplication?) -> Void
    ) {
        loginItemSettings.refresh()
        focusRestoration = restoration
        isPresentingWindow = true
        let wasVisible = window?.isVisible == true
        let presentation = model.present(route: route, handback: application)
        let presentedWindow = window ?? makeWindow()
        if !wasVisible {
            handbackTracker.beginPresentation()
        }

        NSApp.activate(ignoringOtherApps: true)
        presentedWindow.makeKeyAndOrderFront(nil)
        updateIntegrationsPresentationState()
        if !presentation.wasAlreadyPresented {
            presentedWindow.makeFirstResponder(presentedWindow.contentViewController?.view)
        }
        // The presentation latch suppresses both the synchronous route publisher and
        // `windowDidBecomeKey`. Pay that announcement debt after the final route has landed so an
        // already-retained General → Sounds deep link or non-key reactivation cannot lose it.
        announceSoundsPresentationIfNeeded(in: presentedWindow)
        isPresentingWindow = false
    }

    /// A global shortcut validates the persisted panel scope before crossing this owner. Unknown
    /// or no-longer-published scopes still open the real Events destination on the safe fallback
    /// carried by `route`, while the embedded destination retains the visible recovery reason.
    func showEventSettingsFromGlobalShortcut(
        _ route: EventSettingsWindowRoute,
        returnFocusTo application: NSRunningApplication?,
        onClose restoration: @escaping @MainActor (NSRunningApplication?) -> Void
    ) {
        eventSettingsSelection.select(route)
        let settingsRoute: SettingsRoute
        if route.unavailableRequestedScopeStoredValue == nil {
            settingsRoute = .events(scope: route.scope, event: route.event)
        } else {
            settingsRoute = .destination(.eventsAndSounds)
        }
        showWindow(
            route: settingsRoute,
            returnFocusTo: application,
            onClose: restoration)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard
            !isPresentingWindow,
            let keyWindow = notification.object as? NSWindow,
            keyWindow === window
        else { return }
        loginItemSettings.refresh()
        updateIntegrationsPresentationState()
        announceLatestSoundPackStatusIfNeeded(in: keyWindow)
    }

    func windowDidResignKey(_ notification: Notification) {
        guard
            let changedWindow = notification.object as? NSWindow,
            changedWindow === window
        else { return }
        updateIntegrationsPresentationState()
    }

    func windowWillClose(_ notification: Notification) {
        guard
            let closingWindow = notification.object as? NSWindow,
            closingWindow === window
        else { return }

        integrationsModel.noteWindowVisibility(false)
        let originalHandback = model.close()
        let handback = handbackTracker.consumeOnClose() ?? originalHandback
        let restoration = focusRestoration
        focusRestoration = nil
        aiCueViewModel.endSession()
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                restoration?(handback)
            }
        }
    }

    private func makeWindow() -> NSWindow {
        let content = SettingsWindowView(
            model: model,
            preferences: preferences,
            dynamicQuietPolicy: dynamicQuietObserver.policy,
            loginItemSettings: loginItemSettings,
            usageSettings: usageSettings,
            globalShortcutSettings: globalShortcutSettings,
            soundPacksEditorOwner: soundPacksEditorOwner,
            eventSettingsModel: eventSettingsModel,
            eventSettingsSelection: eventSettingsSelection,
            hostIntegrations: hostIntegrations,
            integrationsModel: integrationsModel,
            integrationsFocusCoordinator: integrationsFocusCoordinator,
            aiCueViewModel: aiCueViewModel,
            audioEnvironment: audioEnvironment,
            onEventAudibilityInputsChanged: onEventAudibilityInputsChanged,
            onEventPackSwitch: { [weak soundPacksEditorOwner] outcome in
                soundPacksEditorOwner?.completePanelPackSwitch(outcome)
            },
            onAdoptAICue: onAdoptAICue)
        let window = NSWindow(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: SettingsWindowGeometry.defaultWidth,
                height: SettingsWindowGeometry.defaultHeight),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = ClaudioL10n(language: preferences.language).text(.settingsWindowTitle)
        window.contentMinSize = NSSize(
            width: SettingsWindowGeometry.minimumWidth,
            height: SettingsWindowGeometry.minimumHeight)
        window.contentViewController = NSHostingController(rootView: content)
        window.isReleasedWhenClosed = false
        window.autorecalculatesKeyViewLoop = true
        window.delegate = self
        window.setFrameAutosaveName("Claudio.SettingsWindow")
        window.center()
        self.window = window
        return window
    }

    private func updateWindowTitle() {
        window?.title = ClaudioL10n(language: preferences.language).text(.settingsWindowTitle)
    }

    /// In-window actions submit a typed route without creating or presenting another window.
    func request(_ route: SettingsRoute) {
        model.request(route)
    }

    private func updateIntegrationsPresentationState(
        selectedDestination: SettingsDestination? = nil
    ) {
        let state = settingsEmbeddedDestinationState(
            selectedDestination: selectedDestination ?? model.resolution.destination,
            embeddedDestination: .integrations,
            windowIsVisible: window?.isVisible == true,
            windowIsKey: window?.isKeyWindow == true)
        integrationsModel.noteWindowVisibility(state.isVisible)
        integrationsModel.noteWindowKeyState(state.isKey)
    }

    private func installSoundPackAnnouncementObservers() {
        let soundPackModel = soundPacksEditorOwner.model
        soundsRouteAnnouncementCancellable = model.$resolution
            .map(\.destination)
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] destination in
                MainActor.assumeIsolated {
                    guard
                        let self,
                        destination == .sounds,
                        !self.isPresentingWindow
                    else { return }
                    // `@Published` emits before storing `resolution`. Defer one main turn so the
                    // active-route guard reads the landed Sounds destination and SwiftUI has also
                    // had a chance to install the embedded editor in the accessibility tree.
                    DispatchQueue.main.async { [weak self] in
                        MainActor.assumeIsolated {
                            guard let self, let window = self.activeSoundsWindow else { return }
                            self.announceSoundsPresentationIfNeeded(in: window)
                        }
                    }
                }
            }
        soundPackSelectionAnnouncementCancellable = soundPackModel.$selectedPackID
            .dropFirst()
            .sink { [weak self] selectedPackID in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let shouldAnnounce = self.soundPacksEditorOwner
                        .shouldAnnounceSelectionChange(to: selectedPackID)
                    guard shouldAnnounce, let window = self.activeSoundsWindow else { return }
                    SoundPacksWindowAccessibilityBridge.post(
                        .selectionChanged,
                        facts: self.soundPacksEditorOwner.announcementFacts(
                            selectedPackID: selectedPackID,
                            usesEmittedSelection: true),
                        language: self.preferences.language,
                        window: window)
                }
            }
        soundPackLibraryAnnouncementCancellable = soundPackModel.$libraryPresentationState
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] libraryState in
                MainActor.assumeIsolated {
                    guard let self, let window = self.activeSoundsWindow else { return }
                    SoundPacksWindowAccessibilityBridge.post(
                        .libraryStateChanged,
                        facts: self.soundPacksEditorOwner.announcementFacts(
                            libraryPresentationState: libraryState),
                        language: self.preferences.language,
                        window: window)
                }
            }
        soundPackStatusAnnouncementCancellable = soundPackModel.$windowStatuses
            .dropFirst()
            .map { statuses in statuses.max { $0.revision < $1.revision } }
            .compactMap { $0 }
            .sink { [weak self] status in
                MainActor.assumeIsolated {
                    guard let self, let window = self.activeSoundsWindow else { return }
                    self.announceSoundPackStatusIfNeeded(status, in: window)
                }
            }
    }

    private var activeSoundsWindow: NSWindow? {
        guard
            model.resolution.destination == .sounds,
            let window,
            window.isKeyWindow
        else { return nil }
        return window
    }

    private func announceSoundsPresentationIfNeeded(in window: NSWindow) {
        guard activeSoundsWindow === window else { return }
        SoundPacksWindowAccessibilityBridge.post(
            .windowOpened,
            facts: soundPacksEditorOwner.announcementFacts(),
            language: preferences.language,
            window: window)
        announceLatestSoundPackStatusIfNeeded(in: window)
    }

    private func announceLatestSoundPackStatusIfNeeded(in window: NSWindow) {
        guard
            activeSoundsWindow === window,
            let status = soundPacksEditorOwner.model.windowStatuses.max(by: {
                $0.revision < $1.revision
            })
        else { return }
        announceSoundPackStatusIfNeeded(status, in: window)
    }

    private func announceSoundPackStatusIfNeeded(
        _ status: SoundPacksWindowStatus,
        in window: NSWindow
    ) {
        guard
            soundPacksEditorOwner.beginStatusAnnouncementAttempt(
                revision: status.revision,
                isWindowKey: window.isKeyWindow)
        else { return }
        let moment: SoundPacksWindowAnnouncementMoment =
            status.severity == .failure
            ? .writeFailed(
                action: status.action(language: preferences.language),
                reason: status.message(language: preferences.language))
            : .writeSucceeded(message: status.message(language: preferences.language))
        SoundPacksWindowAccessibilityBridge.post(
            moment,
            facts: soundPacksEditorOwner.announcementFacts(),
            language: preferences.language,
            window: window
        ) { [weak self] didPost in
            self?.soundPacksEditorOwner.finishStatusAnnouncementAttempt(
                revision: status.revision,
                didPost: didPost)
        }
    }
}

private func settingsRouteAvailability(
    packIDs: Set<String>,
    libraryState: SoundPackLibraryPresentationState,
    publishedSurfaces: Set<HostSurfaceID>
) -> SettingsRouteAvailability {
    let productScopes = HostID.productVisibleCases.map {
        PanelSoundScopeID.surface($0.surfaceID)
    }
    return SettingsRouteAvailability(
        integrationSurfaces: publishedSurfaces,
        eventScopes: Set(
            [PanelSoundScopeID.global]
                + publishedSurfaces.map(PanelSoundScopeID.surface)),
        soundScopes: Set([PanelSoundScopeID.global] + productScopes),
        soundPackIDs: packIDs,
        soundPackSnapshotIsFresh: libraryState == .ready,
        events: Set(Event.allCases))
}
