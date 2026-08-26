import AppKit
import ClaudioCore
import ClaudioGUICore
import ClaudioLocalization
import Combine
import SwiftUI

/// App-lifetime owner of the one Sound Packs window.
///
/// `MenuBarController` owns this controller. Its app-lifetime editor model is shared eagerly with
/// Settings, while only the legacy `NSWindow` is created on demand and retained after close.
/// Repeated 「管理声音包…」 actions therefore reuse the same window and writable model.
@MainActor
public final class SoundPacksWindowController: NSObject, NSWindowDelegate {
    public let editorOwner: SoundPacksEditorOwner
    private let languageStore: ClaudioPreferences
    private var model: SoundPacksWindowModel { editorOwner.model }
    private lazy var focusCoordinator = SoundPacksWindowFocusCoordinator()
    private var window: NSWindow?
    /// The app that owned the keyboard before Claudio opened its popover. The popover transfers
    /// this debt instead of paying it while the management window is becoming key. It is cleared
    /// on every close before any activation attempt, so a retained/reopened window cannot hand
    /// focus to a stale app twice.
    private var handbackApplication: NSRunningApplication?
    private var focusRestoration: (@MainActor (NSRunningApplication?) -> Bool)?
    private var isClosingWindow = false
    private var externalActivationCancellable: AnyCancellable?
    private var languageCancellable: AnyCancellable?
    private var selectionAnnouncementCancellable: AnyCancellable?
    private var libraryStateAnnouncementCancellable: AnyCancellable?
    private var windowStatusAnnouncementCancellable: AnyCancellable?
    private var pendingRoute: SoundPacksWindowRoute?
    /// Suppresses the delegate callback during `showWindow` so window-open context is announced
    /// before any result that completed while the retained window was hidden.
    private var isPresentingWindow = false

    public init(
        editorOwner: SoundPacksEditorOwner,
        languageStore: ClaudioPreferences
    ) {
        self.editorOwner = editorOwner
        self.languageStore = languageStore
        super.init()

        installLifetimeObservers()
    }

    public convenience init(
        configFile: URL,
        lockFile: URL = ClaudioPaths.configLockFile,
        environment: AudioImportEnvironment,
        soundPackLibrary: SoundPackLibrary,
        refreshCoordinator: SoundPacksRefreshCoordinator,
        languageStore: ClaudioPreferences
    ) {
        self.init(
            editorOwner: SoundPacksEditorOwner(
                configFile: configFile,
                lockFile: lockFile,
                environment: environment,
                soundPackLibrary: soundPackLibrary,
                refreshCoordinator: refreshCoordinator),
            languageStore: languageStore)
    }

    private func installLifetimeObservers() {
        // A standard window may remain visible in the background for a long time. If the user
        // visits another app before returning to close it, the app captured when the window first
        // opened is stale. Track the latest external activation while this window is visible.
        // The cancellable owns the closure, so the capture must stay weak.
        externalActivationCancellable = NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didActivateApplicationNotification)
            .sink { [weak self] notification in
                MainActor.assumeIsolated {
                    guard
                        let self,
                        !self.isClosingWindow,
                        self.window?.isVisible == true,
                        let application =
                            notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                            as? NSRunningApplication,
                        application.processIdentifier != ProcessInfo.processInfo.processIdentifier
                    else { return }
                    self.handbackApplication = application
                }
            }

        languageCancellable = languageStore.$snapshot
            .map(\.language)
            .removeDuplicates()
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.updateWindowTitle()
                }
            }
    }

    public func showWindow(
        route: SoundPacksWindowRoute = .overview,
        returnFocusTo application: NSRunningApplication?,
        onClose: (@MainActor (NSRunningApplication?) -> Bool)? = nil
    ) {
        isClosingWindow = false
        focusRestoration = onClose
        // Re-presenting an already-open window from Claudio itself has no new external app to
        // record; retain the existing debt until the window really closes.
        if let application {
            handbackApplication = application
        }

        let wasAlreadyCreated = window != nil
        let wasVisible = window?.isVisible == true
        let presentedWindow = window ?? makeWindow()
        if shouldReloadSoundPacksWindowOnShow(
            wasAlreadyCreated: wasAlreadyCreated,
            isVisible: wasVisible)
        {
            model.reload(followActivePack: false)
        }
        let effectiveRoute: SoundPacksWindowRoute
        switch editorOwner.apply(route: route) {
        case .resolved(let resolvedRoute):
            pendingRoute = nil
            effectiveRoute = resolvedRoute
        case .pending(let route):
            pendingRoute = route
            effectiveRoute = .overview(surface: route.surface)
        }
        NSApp.activate(ignoringOtherApps: true)
        isPresentingWindow = true
        presentedWindow.makeKeyAndOrderFront(nil)
        if shouldPrepareSoundPacksWindowForPresentation(isVisible: wasVisible) {
            presentedWindow.makeFirstResponder(presentedWindow.contentViewController?.view)
            focusCoordinator.requestInitialFocus(route: effectiveRoute)
            SoundPacksWindowAccessibilityBridge.post(
                .windowOpened,
                facts: editorOwner.announcementFacts(),
                language: languageStore.language,
                window: presentedWindow)
        }
        if wasVisible, !effectiveRoute.isOverview {
            focusCoordinator.requestRoute(effectiveRoute)
        }
        announceLatestWindowStatusIfNeeded(in: presentedWindow)
        isPresentingWindow = false
    }

    /// Headless adoption entry used by the retained Events & Sounds window. It reuses the same
    /// disk-backed model and package-lock publication path as manual sound-pack editing without
    /// forcing the management window onscreen.
    public func adoptAICue(
        _ request: AICueAdoptionRequest
    ) async -> Result<AICueAdoptionOutcome, AICueAdoptionError> {
        model.setManagedSurface(request.target.surface)
        return await model.adoptAICue(request)
    }

    public func windowDidBecomeKey(_ notification: Notification) {
        guard
            !isPresentingWindow,
            let keyWindow = notification.object as? NSWindow,
            keyWindow === window
        else { return }
        announceLatestWindowStatusIfNeeded(in: keyWindow)
    }

    public func windowWillClose(_ notification: Notification) {
        guard
            let closingWindow = notification.object as? NSWindow,
            closingWindow === window
        else { return }

        isClosingWindow = true
        pendingRoute = nil
        let previous = handbackApplication
        handbackApplication = nil
        let restoration = focusRestoration
        focusRestoration = nil

        if let restoration {
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard !restoration(previous) else { return }
                    self.completeCloseHandoff(to: previous)
                }
            }
            return
        }

        completeCloseHandoff(to: previous)
    }

    private func completeCloseHandoff(to previous: NSRunningApplication?) {
        guard NSApp.isActive else { return }

        guard
            let previous,
            !previous.isTerminated,
            previous.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else {
            // A standard window does not deactivate its application when it closes. Claudio is an
            // LSUIElement/accessory app, so leaving it active with zero windows would swallow the
            // user's keyboard invisibly even when there is no surviving app proxy to reactivate.
            NSApp.deactivate()
            return
        }

        if #available(macOS 14.0, *) {
            NSApp.yieldActivation(to: previous)
            previous.activate()
        } else {
            previous.activate(options: [])
            NSApp.deactivate()
        }
    }

    private func makeWindow() -> NSWindow {
        let content = SoundPacksWindowView(
            model: model,
            userPacksDirectory: editorOwner.userPacksDirectory,
            focusCoordinator: focusCoordinator,
            languageStore: languageStore)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = ClaudioL10n(language: languageStore.language).text(.soundPacksWindowTitle)
        window.contentMinSize = NSSize(width: 640, height: 480)
        window.contentViewController = NSHostingController(rootView: content)
        window.isReleasedWhenClosed = false
        window.autorecalculatesKeyViewLoop = true
        window.delegate = self
        window.setFrameAutosaveName("Claudio.SoundPacksWindow")
        window.center()
        self.window = window
        selectionAnnouncementCancellable = model.$selectedPackID
            .dropFirst()
            .sink { [weak self] selectedPackID in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let shouldAnnounce = self.editorOwner.shouldAnnounceSelectionChange(
                        to: selectedPackID)
                    guard shouldAnnounce, self.window?.isKeyWindow == true else { return }
                    SoundPacksWindowAccessibilityBridge.post(
                        .selectionChanged,
                        facts: self.editorOwner.announcementFacts(
                            selectedPackID: selectedPackID,
                            usesEmittedSelection: true),
                        language: self.languageStore.language,
                        window: window)
                }
            }
        libraryStateAnnouncementCancellable = model.$libraryPresentationState
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] libraryState in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.resolvePendingRouteIfPossible(libraryState: libraryState)
                    guard self.window?.isKeyWindow == true else { return }
                    SoundPacksWindowAccessibilityBridge.post(
                        .libraryStateChanged,
                        facts: self.editorOwner.announcementFacts(
                            libraryPresentationState: libraryState),
                        language: self.languageStore.language,
                        window: window)
                }
            }
        windowStatusAnnouncementCancellable = model.$windowStatuses
            .dropFirst()
            .map { statuses in statuses.max { $0.revision < $1.revision } }
            .compactMap { $0 }
            .sink { [weak self] status in
                MainActor.assumeIsolated {
                    self?.announceWindowStatusIfNeeded(status, in: window)
                }
            }
        return window
    }

    private func updateWindowTitle() {
        window?.title = ClaudioL10n(language: languageStore.language).text(.soundPacksWindowTitle)
    }

    private func resolvePendingRouteIfPossible(
        libraryState _: SoundPackLibraryPresentationState
    ) {
        guard let pendingRoute, window?.isVisible == true else { return }
        switch editorOwner.apply(route: pendingRoute) {
        case .pending:
            return
        case .resolved(let route):
            self.pendingRoute = nil
            if route.editTarget != nil {
                focusCoordinator.requestRoute(route)
            } else if route.isOverview {
                focusCoordinator.requestRoute(.overview(surface: route.surface))
            }
        }
    }

    private func announceLatestWindowStatusIfNeeded(in window: NSWindow) {
        guard let status = model.windowStatuses.max(by: { $0.revision < $1.revision }) else {
            return
        }
        announceWindowStatusIfNeeded(status, in: window)
    }

    private func announceWindowStatusIfNeeded(
        _ status: SoundPacksWindowStatus,
        in window: NSWindow
    ) {
        guard
            editorOwner.beginStatusAnnouncementAttempt(
                revision: status.revision,
                isWindowKey: window.isKeyWindow)
        else { return }
        let event: SoundPacksWindowAnnouncementMoment =
            status.severity == .failure
            ? .writeFailed(
                action: status.action(language: languageStore.language),
                reason: status.message(language: languageStore.language))
            : .writeSucceeded(message: status.message(language: languageStore.language))
        SoundPacksWindowAccessibilityBridge.post(
            event,
            facts: editorOwner.announcementFacts(),
            language: languageStore.language,
            window: window
        ) { [weak self] didPost in
            self?.editorOwner.finishStatusAnnouncementAttempt(
                revision: status.revision,
                didPost: didPost)
        }
    }

}
