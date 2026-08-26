import AppKit
import ClaudioCore
import ClaudioGUICore
import ClaudioLocalization
import Combine
import SwiftUI

/// App-lifetime owner of the one Sound Packs window.
///
/// `MenuBarController` owns this controller. The `NSWindow` and its disk-backed model are lazy
/// because most menu-bar sessions never open management, and retained after close so repeated
/// 「管理声音包…」 actions reuse the same window/model instead of growing a second editor.
@MainActor
public final class SoundPacksWindowController: NSObject, NSWindowDelegate {
    private let configFile: URL
    private let lockFile: URL
    private let environment: AudioImportEnvironment
    private let soundPackLibrary: SoundPackLibrary
    private let refreshCoordinator: SoundPacksRefreshCoordinator
    private let languageStore: ClaudioPreferences
    private lazy var model: SoundPacksWindowModel = SoundPacksWindowModel(
        configFile: configFile,
        lockFile: lockFile,
        environment: environment,
        soundPackLibrary: soundPackLibrary,
        refreshCoordinator: refreshCoordinator)
    private lazy var focusCoordinator = SoundPacksWindowFocusCoordinator()
    private let userPacksDirectory: URL
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
    private var statusAnnouncementTracker = SoundPacksWindowStatusAnnouncementTracker()
    private var pendingRoute: SoundPacksWindowRoute?
    /// Suppresses the delegate callback during `showWindow` so window-open context is announced
    /// before any result that completed while the retained window was hidden.
    private var isPresentingWindow = false

    public init(
        configFile: URL,
        lockFile: URL = ClaudioPaths.configLockFile,
        environment: AudioImportEnvironment,
        soundPackLibrary: SoundPackLibrary,
        refreshCoordinator: SoundPacksRefreshCoordinator,
        languageStore: ClaudioPreferences
    ) {
        self.configFile = configFile
        self.lockFile = lockFile
        self.environment = environment
        self.soundPackLibrary = soundPackLibrary
        self.refreshCoordinator = refreshCoordinator
        self.languageStore = languageStore
        userPacksDirectory = environment.userPacksDirectory
        super.init()

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
        switch resolveSoundPacksWindowRoute(
            route,
            availablePackIDs: Set(model.packCards.map(\.id)),
            libraryState: model.libraryPresentationState)
        {
        case .resolved(let resolvedRoute):
            pendingRoute = nil
            model.setManagedSurface(resolvedRoute.surface)
            if let packID = resolvedRoute.editTarget?.packID {
                effectiveRoute =
                    model.selectPackForInspection(packID)
                    ? resolvedRoute : .overview(surface: resolvedRoute.surface)
            } else {
                effectiveRoute = resolvedRoute
            }
        case .pending(let route):
            pendingRoute = route
            model.setManagedSurface(route.surface)
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
                facts: accessibilityFacts(),
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
            userPacksDirectory: userPacksDirectory,
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
                    if self.model.consumeSelectionAnnouncementSuppression(for: selectedPackID) {
                        return
                    }
                    guard self.window?.isKeyWindow == true else { return }
                    SoundPacksWindowAccessibilityBridge.post(
                        .selectionChanged,
                        facts: self.accessibilityFacts(selectedPackID: selectedPackID),
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
                        facts: self.accessibilityFacts(
                            selectedPackID: self.model.selectedPackID,
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
        libraryState: SoundPackLibraryPresentationState
    ) {
        guard let pendingRoute, window?.isVisible == true else { return }
        switch resolveSoundPacksWindowRoute(
            pendingRoute,
            availablePackIDs: Set(model.packCards.map(\.id)),
            libraryState: libraryState)
        {
        case .pending:
            return
        case .resolved(let route):
            self.pendingRoute = nil
            model.setManagedSurface(route.surface)
            if let packID = route.editTarget?.packID,
                model.selectPackForInspection(packID)
            {
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
            statusAnnouncementTracker.beginAttempt(
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
            facts: accessibilityFacts(),
            language: languageStore.language,
            window: window
        ) { [weak self] didPost in
            self?.statusAnnouncementTracker.finishAttempt(
                revision: status.revision,
                didPost: didPost)
        }
    }

    private func accessibilityFacts() -> SoundPacksWindowAnnouncementFacts {
        accessibilityFacts(
            selectedPackID: model.selectedPackID,
            libraryPresentationState: model.libraryPresentationState)
    }

    /// `@Published` emits its new value before the stored property is replaced. Accepting that
    /// emitted value explicitly keeps a transition to `nil` from accidentally announcing the old
    /// selection.
    private func accessibilityFacts(
        selectedPackID: String?,
        libraryPresentationState: SoundPackLibraryPresentationState? = nil
    ) -> SoundPacksWindowAnnouncementFacts {
        let selectedName = selectedPackID.flatMap { packID in
            model.packCards.first(where: { $0.id == packID }).map {
                SelectedPackMetadata(id: $0.id, name: $0.name).displayName
            }
        }
        return SoundPacksWindowAnnouncementFacts(
            packCount: model.packCards.count,
            selectedPackName: selectedName,
            libraryPresentationState:
                libraryPresentationState ?? model.libraryPresentationState)
    }
}
