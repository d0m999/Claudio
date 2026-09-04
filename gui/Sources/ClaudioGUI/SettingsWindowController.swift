import AppKit
import ClaudioCore
import ClaudioGUICore
import ClaudioLocalization
import ClaudioSettingsPresentation
import Combine
import SoundPacksWindow
import SwiftUI

@MainActor
private final class SettingsPresentationNativeCallbacks {
    weak var controller: SettingsWindowController?

    func announce(_ sentence: String) {
        controller?.announceBasicSettingsUpdate(sentence)
    }
}

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
    private let settingsPresentationSession: SettingsPresentationSession
    private let aboutSettings: AboutSettingsModel
    private let model: SettingsWindowPresentationModel<NSRunningApplication>
    private let soundPacksEditorOwner: SoundPacksEditorOwner
    private let soundPacksEditorNativeEffects: SoundPacksEditorNativeEffectsDispatcher
    private let soundPackAnnouncementDelivery: SoundPacksEditorAnnouncementDelivery
    private let eventSettingsModel: PanelConfigController
    private let eventSettingsSelection: EventSettingsWindowSelection
    private let hostIntegrations: HostIntegrationPresentationStore
    private let integrationsModel: IntegrationDestinationModel
    private let aiCueViewModel: AICueGenerationViewModel
    private let dynamicQuietObserver: DynamicQuietSystemObserver
    private let presentationCallbacks: SettingsPresentationNativeCallbacks
    private var window: NSWindow?
    private var isPresentingWindow = false
    private var focusRestoration: (@MainActor (NSRunningApplication?) -> Void)?
    private var handbackTracker = RetainedWindowHandbackTracker<NSRunningApplication>()
    private var externalActivationCancellable: AnyCancellable?
    private var languageCancellable: AnyCancellable?
    private var integrationsRouteCancellable: AnyCancellable?
    private var soundPackPresentationCancellable: AnyCancellable?
    private var soundsRouteAnnouncementCancellable: AnyCancellable?
    private var aboutSurfaceCancellable: AnyCancellable?
    private var settingsPresentationCancellable: AnyCancellable?
    private var settingsPresentationAnnouncementDeliveryScheduled = false

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
        onEventAudibilityInputsChanged: @escaping @MainActor () -> Void
    ) {
        self.preferences = preferences
        self.soundPacksEditorOwner = soundPacksEditorOwner
        self.soundPacksEditorNativeEffects = soundPacksEditorNativeEffects
        soundPackAnnouncementDelivery = SoundPacksEditorAnnouncementDelivery(
            poster: soundPackAccessibilityPoster)
        self.eventSettingsModel = eventSettingsModel
        self.eventSettingsSelection = eventSettingsSelection
        self.hostIntegrations = hostIntegrations
        self.integrationsModel = integrationsModel
        let integrationsFocusCoordinator = IntegrationDestinationFocusCoordinator()
        self.aiCueViewModel = aiCueViewModel
        let dynamicQuietObserver = DynamicQuietSystemObserver()
        self.dynamicQuietObserver = dynamicQuietObserver
        let aboutSettings = makeSystemAboutSettingsModel(
            surfaceFacts: hostIntegrations.safeSurfaceFacts)
        self.aboutSettings = aboutSettings
        let initialSoundPackProjection = SettingsSoundPackShellProjection(
            editorPresentation: soundPacksEditorOwner.presentation,
            sourceRows: hostIntegrations.content.sourceRows)
        let model = SettingsWindowPresentationModel<NSRunningApplication>(
            preferences: preferences,
            availability: initialSoundPackProjection.availability)
        self.model = model
        let presentationCallbacks = SettingsPresentationNativeCallbacks()
        self.presentationCallbacks = presentationCallbacks
        settingsPresentationSession = SettingsPresentationSession(
            dependencies: SettingsPresentationDependencies(
                navigation: model,
                preferences: preferences,
                loginItemSettings: loginItemSettings,
                dynamicQuietPolicy: dynamicQuietObserver.policy,
                usageSettings: usageSettings,
                globalShortcutSettings: globalShortcutSettings,
                aboutSettings: aboutSettings,
                soundPacksEditorOwner: soundPacksEditorOwner,
                soundPacksEditorNativeEffects: soundPacksEditorNativeEffects,
                eventSettingsModel: eventSettingsModel,
                eventSettingsSelection: eventSettingsSelection,
                hostIntegrations: hostIntegrations,
                integrationsModel: integrationsModel,
                integrationsFocusCoordinator: integrationsFocusCoordinator,
                aiCueViewModel: aiCueViewModel),
            actions: makeSystemSettingsPresentationActions(
                onEventAudibilityInputsChanged: onEventAudibilityInputsChanged,
                announce: { sentence in presentationCallbacks.announce(sentence) }))
        super.init()
        presentationCallbacks.controller = self

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

        soundPackPresentationCancellable = settingsSoundPackShellProjections(
            editor: soundPacksEditorOwner,
            hostIntegrations: hostIntegrations
        ).sink { [weak self] projection in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.model.updateAvailability(projection.availability)
                guard projection.pendingAnnouncement != nil, !self.isPresentingWindow else {
                    return
                }
                // `@Published` emits before storing `presentation`. Availability consumes the
                // emitted coherent value immediately, but native delivery waits one main turn so
                // its exact-head eligibility closure reads the landed owner presentation.
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, let window = self.activeSoundsWindow else { return }
                        self.announcePendingSoundPackEditorAnnouncementIfNeeded(in: window)
                    }
                }
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
        settingsPresentationCancellable = settingsPresentationSession.$state
            .sink { [weak self] state in
                MainActor.assumeIsolated {
                    guard state.pendingAnnouncement != nil else { return }
                    self?.scheduleSettingsPresentationAnnouncementDelivery()
                }
            }
    }

    func showWindow(
        route: SettingsRoute? = nil,
        returnFocusTo application: NSRunningApplication?,
        onClose restoration: @escaping @MainActor (NSRunningApplication?) -> Void
    ) {
        settingsPresentationSession.refreshLoginItem()
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
        scheduleSettingsPresentationAnnouncementDelivery()
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
        settingsPresentationSession.refreshLoginItem()
        updateIntegrationsPresentationState()
        announcePendingSoundPackEditorAnnouncementIfNeeded(in: keyWindow)
        scheduleSettingsPresentationAnnouncementDelivery()
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
        let content = SettingsRootView(session: settingsPresentationSession)
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

    @discardableResult
    fileprivate func announceBasicSettingsUpdate(_ sentence: String) -> Bool {
        guard let window, window.isVisible, window.isKeyWindow, !sentence.isEmpty else {
            return false
        }
        NSAccessibility.post(
            element: window,
            notification: .announcementRequested,
            userInfo: [
                .announcement: sentence,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ])
        return true
    }

    private func scheduleSettingsPresentationAnnouncementDelivery() {
        guard !settingsPresentationAnnouncementDeliveryScheduled else { return }
        settingsPresentationAnnouncementDeliveryScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.settingsPresentationAnnouncementDeliveryScheduled = false
                self.deliverPendingSettingsPresentationAnnouncement()
            }
        }
    }

    private func deliverPendingSettingsPresentationAnnouncement() {
        guard
            !isPresentingWindow,
            let announcement = settingsPresentationSession.state.pendingAnnouncement,
            let window,
            window.isVisible,
            window.isKeyWindow
        else { return }
        let sentence = announcement.meaning.localizedSentence(language: preferences.language)
        guard announceBasicSettingsUpdate(sentence) else { return }
        settingsPresentationSession.acknowledgeAnnouncement(
            id: announcement.id,
            didPost: true)
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
