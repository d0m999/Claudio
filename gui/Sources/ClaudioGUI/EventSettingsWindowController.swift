import AppKit
import ClaudioGUICore
import ClaudioLocalization
import Combine
import SwiftUI

@MainActor
final class EventSettingsWindowSelection: ObservableObject {
    @Published private(set) var route: EventSettingsWindowRoute
    @Published private(set) var focusRequestRevision = 0

    init(route: EventSettingsWindowRoute = EventSettingsWindowRoute(scope: .global)) {
        self.route = route
    }

    func select(_ route: EventSettingsWindowRoute) {
        guard self.route != route else { return }
        self.route = route
    }

    func requestInitialFocus() {
        focusRequestRevision += 1
    }
}

/// App-lifetime owner of the retained Events & Sounds window.
///
/// The window keeps the selected sound scope as a typed route. Closing it reopens the menu-bar
/// panel and restores the exact button that initiated the transition; opening SoundPacks from an
/// event returns to this retained window instead.
@MainActor
final class EventSettingsWindowController: NSObject, NSWindowDelegate {
    private let model: PanelConfigController
    private let hostIntegrations: HostIntegrationPresentationStore
    private let languageStore: ClaudioLanguageStore
    private let aiCueViewModel: AICueGenerationViewModel
    private let audioEnvironment: AudioImportEnvironment
    private let onConfigureSound: @MainActor (SoundPacksWindowRoute) -> Void
    private let onAudibilityInputsChanged: @MainActor () -> Void
    private let onAdoptAICue:
        @MainActor (AICueAdoptionRequest) async -> Result<
            AICueAdoptionOutcome, AICueAdoptionError
        >
    private let selection = EventSettingsWindowSelection()
    private var window: NSWindow?
    private var focusRestoration: (@MainActor (NSRunningApplication?) -> Void)?
    private var handbackTracker = RetainedWindowHandbackTracker<NSRunningApplication>()
    private var externalActivationCancellable: AnyCancellable?
    private var languageCancellable: AnyCancellable?

    init(
        model: PanelConfigController,
        hostIntegrations: HostIntegrationPresentationStore,
        languageStore: ClaudioLanguageStore,
        aiCueViewModel: AICueGenerationViewModel,
        audioEnvironment: AudioImportEnvironment,
        onConfigureSound: @escaping @MainActor (SoundPacksWindowRoute) -> Void,
        onAudibilityInputsChanged: @escaping @MainActor () -> Void,
        onAdoptAICue:
            @escaping @MainActor (AICueAdoptionRequest) async -> Result<
                AICueAdoptionOutcome, AICueAdoptionError
            >
    ) {
        self.model = model
        self.hostIntegrations = hostIntegrations
        self.languageStore = languageStore
        self.aiCueViewModel = aiCueViewModel
        self.audioEnvironment = audioEnvironment
        self.onConfigureSound = onConfigureSound
        self.onAudibilityInputsChanged = onAudibilityInputsChanged
        self.onAdoptAICue = onAdoptAICue
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

        languageCancellable = languageStore.$language
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.updateWindowTitle()
                }
            }
    }

    func showWindow(
        route: EventSettingsWindowRoute,
        returnFocusTo restoration: @escaping @MainActor (NSRunningApplication?) -> Void
    ) {
        focusRestoration = restoration
        model.reload()
        model.selectSoundSurface(route.surface)
        selection.select(route)

        let wasVisible = window?.isVisible == true
        let presentedWindow = window ?? makeWindow()
        if !wasVisible {
            handbackTracker.beginPresentation()
        }

        NSApp.activate(ignoringOtherApps: true)
        presentedWindow.makeKeyAndOrderFront(nil)
        guard !wasVisible else { return }
        presentedWindow.makeFirstResponder(presentedWindow.contentViewController?.view)
        selection.requestInitialFocus()
    }

    @discardableResult
    func restoreKeyWindow() -> Bool {
        guard let window, window.isVisible else { return false }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        return true
    }

    func windowWillClose(_ notification: Notification) {
        guard
            let closingWindow = notification.object as? NSWindow,
            closingWindow === window
        else { return }

        let handbackApplication = handbackTracker.consumeOnClose()
        let restoration = focusRestoration
        focusRestoration = nil
        aiCueViewModel.endSession()
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                restoration?(handbackApplication)
            }
        }
    }

    private func makeWindow() -> NSWindow {
        let content = EventSettingsWindowView(
            model: model,
            selection: selection,
            hostIntegrations: hostIntegrations,
            languageStore: languageStore,
            aiCueViewModel: aiCueViewModel,
            audioEnvironment: audioEnvironment,
            onConfigureSound: onConfigureSound,
            onAudibilityInputsChanged: onAudibilityInputsChanged,
            onAdoptAICue: onAdoptAICue)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = ClaudioL10n(language: languageStore.language).text(.eventSettingsWindowTitle)
        window.contentMinSize = NSSize(width: 680, height: 520)
        window.contentViewController = NSHostingController(rootView: content)
        window.isReleasedWhenClosed = false
        window.autorecalculatesKeyViewLoop = true
        window.delegate = self
        window.setFrameAutosaveName("Claudio.EventSettingsWindow")
        window.center()
        self.window = window
        return window
    }

    private func updateWindowTitle() {
        window?.title = ClaudioL10n(language: languageStore.language).text(
            .eventSettingsWindowTitle)
    }
}
