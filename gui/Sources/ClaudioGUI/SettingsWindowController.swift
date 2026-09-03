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
    private let aboutSettings: AboutSettingsModel
    private let model: SettingsWindowPresentationModel<NSRunningApplication>
    private let soundPacksEditorOwner: SoundPacksEditorOwner
    private let soundPacksEditorNativeEffects: SoundPacksEditorNativeEffectsDispatcher
    private let soundPackAnnouncementDelivery: SoundPacksEditorAnnouncementDelivery
    private let eventSettingsModel: PanelConfigController
    private let eventSettingsSelection: EventSettingsWindowSelection
    private let hostIntegrations: HostIntegrationPresentationStore
    private let integrationsModel: IntegrationDestinationModel
    private let integrationsFocusCoordinator = IntegrationDestinationFocusCoordinator()
    private let aiCueViewModel: AICueGenerationViewModel
    private let audioEnvironment: AudioImportEnvironment
    private let onEventAudibilityInputsChanged: @MainActor () -> Void
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
    private var soundPackPresentationAnnouncementCancellable: AnyCancellable?
    private var aboutSurfaceCancellable: AnyCancellable?

    init(
        preferences: ClaudioPreferences,
        loginItemSettings: LoginItemSettingsModel,
        usageSettings: UsageSettingsModel,
        globalShortcutSettings: GlobalShortcutSettingsModel,
        soundPacksEditorOwner: SoundPacksEditorOwner,
        soundPacksEditorNativeEffects: SoundPacksEditorNativeEffectsDispatcher,
        soundPackAccessibilityPoster: any SoundPacksEditorAccessibilityPosting =
            SystemSoundPacksEditorAccessibilityPoster(),
        eventSettingsModel: PanelConfigController,
        eventSettingsSelection: EventSettingsWindowSelection,
        hostIntegrations: HostIntegrationPresentationStore,
        integrationsModel: IntegrationDestinationModel,
        aiCueViewModel: AICueGenerationViewModel,
        audioEnvironment: AudioImportEnvironment,
        onEventAudibilityInputsChanged: @escaping @MainActor () -> Void
    ) {
        self.preferences = preferences
        self.loginItemSettings = loginItemSettings
        self.usageSettings = usageSettings
        self.globalShortcutSettings = globalShortcutSettings
        self.soundPacksEditorOwner = soundPacksEditorOwner
        self.soundPacksEditorNativeEffects = soundPacksEditorNativeEffects
        soundPackAnnouncementDelivery = SoundPacksEditorAnnouncementDelivery(
            poster: soundPackAccessibilityPoster)
        self.eventSettingsModel = eventSettingsModel
        self.eventSettingsSelection = eventSettingsSelection
        self.hostIntegrations = hostIntegrations
        self.integrationsModel = integrationsModel
        self.aiCueViewModel = aiCueViewModel
        self.audioEnvironment = audioEnvironment
        self.onEventAudibilityInputsChanged = onEventAudibilityInputsChanged
        dynamicQuietObserver = DynamicQuietSystemObserver()
        aboutSettings = makeSystemAboutSettingsModel(
            surfaceFacts: hostIntegrations.safeSurfaceFacts)
        model = SettingsWindowPresentationModel(
            preferences: preferences,
            availability: settingsRouteAvailability(
                packIDs: Set(soundPacksEditorOwner.model.packCards.map(\.id)),
                libraryState: soundPacksEditorOwner.model.libraryPresentationState,
                sourceRows: hostIntegrations.content.sourceRows))
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
                    sourceRows: integrationContent.sourceRows)
            }
            .removeDuplicates()
            .sink { [weak self] availability in
                MainActor.assumeIsolated {
                    self?.model.updateAvailability(availability)
                }
            }

        installSoundPackAnnouncementObservers()
        aboutSurfaceCancellable = hostIntegrations.$safeSurfaceFacts
            .removeDuplicates()
            .sink { [weak self] surfaceFacts in
                MainActor.assumeIsolated {
                    self?.aboutSettings.replaceSurfaceFacts(surfaceFacts)
                }
            }
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
        if route != nil, presentation.resolution.failure == nil, let route {
            applyEmbeddedRoute(route)
        }
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
        announcePendingSoundPackEditorAnnouncementIfNeeded(in: presentedWindow)
        isPresentingWindow = false
    }

    /// Prepares a global-shortcut route before the shared close-before-show handoff. Unknown or
    /// no-longer-published scopes still open the real Events destination, while the embedded
    /// selection retains the visible failure reason and never authorizes a fallback write target.
    func prepareEventSettingsRoute(_ route: EventSettingsWindowRoute) -> SettingsRoute {
        eventSettingsSelection.select(route)
        if route.unavailableRequestedScopeStoredValue == nil {
            return .events(scope: route.scope, event: route.event)
        }
        return .destination(.eventsAndSounds)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard
            !isPresentingWindow,
            let keyWindow = notification.object as? NSWindow,
            keyWindow === window
        else { return }
        loginItemSettings.refresh()
        updateIntegrationsPresentationState()
        announcePendingSoundPackEditorAnnouncementIfNeeded(in: keyWindow)
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

        soundPacksEditorNativeEffects.handleLifecycle(
            .settingsWindowWillClose, owner: soundPacksEditorOwner)
        integrationsModel.noteWindowVisibility(false)
        let originalHandback = model.close()
        let handback = handbackTracker.consumeOnClose() ?? originalHandback
        let restoration = focusRestoration
        focusRestoration = nil
        eventSettingsSelection.leaveDestination()
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
            aboutSettings: aboutSettings,
            soundPacksEditorNativeEffects: soundPacksEditorNativeEffects,
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
                _ = soundPacksEditorOwner?.send(.completePanelPackSwitch(outcome))
            },
            onAnnouncement: { [weak self] sentence in
                self?.announceBasicSettingsUpdate(sentence)
            })
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

    private func announceBasicSettingsUpdate(_ sentence: String) {
        guard let window, window.isKeyWindow, !sentence.isEmpty else { return }
        NSAccessibility.post(
            element: window,
            notification: .announcementRequested,
            userInfo: [
                .announcement: sentence,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ])
    }

    /// In-window actions submit a typed route without creating or presenting another window.
    func request(_ route: SettingsRoute) {
        model.request(route)
        guard model.resolution.failure == nil else { return }
        applyEmbeddedRoute(route)
    }

    private func applyEmbeddedRoute(_ route: SettingsRoute) {
        switch route {
        case .integrations(let surface):
            guard
                let host = HostID.productVisibleCases.first(where: { $0.surfaceID == surface })
            else { return }
            _ = integrationsModel.selectHost(host)
        case .events(let scope, let event):
            let eventRoute = EventSettingsWindowRoute(scope: scope, event: event)
            eventSettingsSelection.select(eventRoute)
            eventSettingsModel.selectSoundSurface(eventRoute.surface)
        case .destination, .sounds:
            break
        }
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
                            self.announcePendingSoundPackEditorAnnouncementIfNeeded(in: window)
                        }
                    }
                }
            }
        soundPackPresentationAnnouncementCancellable = soundPacksEditorOwner.$presentation
            .map(\.pendingAnnouncement)
            .removeDuplicates()
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, !self.isPresentingWindow else { return }
                    // `@Published` emits before storing `presentation`. Defer one main turn so the
                    // exact-head eligibility closure observes the landed semantic debt.
                    DispatchQueue.main.async { [weak self] in
                        MainActor.assumeIsolated {
                            guard let self, let window = self.activeSoundsWindow else { return }
                            self.announcePendingSoundPackEditorAnnouncementIfNeeded(in: window)
                        }
                    }
                }
            }
    }

    private var activeSoundsWindow: NSWindow? {
        guard
            model.resolution.destination == .sounds,
            let window,
            window.isVisible,
            window.isKeyWindow
        else { return nil }
        return window
    }

    private func announcePendingSoundPackEditorAnnouncementIfNeeded(in window: NSWindow) {
        guard
            activeSoundsWindow === window,
            let announcement = soundPacksEditorOwner.presentation.pendingAnnouncement
        else { return }
        soundPackAnnouncementDelivery.attempt(
            announcement,
            language: preferences.language,
            window: window,
            isEligible: { [weak self, weak window] in
                guard let self, let window else { return false }
                return self.activeSoundsWindow === window
                    && self.soundPacksEditorOwner.presentation.pendingAnnouncement?.id
                        == announcement.id
            },
            acknowledge: { [weak self] id, didPost in
                guard let self else { return }
                _ = self.soundPacksEditorOwner.send(
                    .acknowledgeAnnouncement(id: id, didPost: didPost))
                if let window = self.activeSoundsWindow {
                    self.announcePendingSoundPackEditorAnnouncementIfNeeded(in: window)
                }
            })
    }
}

private func settingsRouteAvailability(
    packIDs: Set<String>,
    libraryState: SoundPackLibraryPresentationState,
    sourceRows: [HostSourceRowPresentation]
) -> SettingsRouteAvailability {
    let publishedSurfaces = Set(sourceRows.map { $0.host.surfaceID })
    let productScopes = HostID.productVisibleCases.map {
        PanelSoundScopeID.surface($0.surfaceID)
    }
    return SettingsRouteAvailability(
        integrationSurfaces: publishedSurfaces,
        eventScopes: Set(panelSoundScopeIDs(sourceRows: sourceRows)),
        soundScopes: Set([PanelSoundScopeID.global] + productScopes),
        soundPackIDs: packIDs,
        soundPackSnapshotIsFresh: libraryState == .ready,
        events: Set(Event.allCases))
}
