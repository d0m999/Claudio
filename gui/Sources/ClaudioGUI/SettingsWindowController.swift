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
/// focus/activation handback. The shared preferences expose only destinations whose real content
/// has shipped, so future route galleries stay DEBUG-only without hiding General from users.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let preferences: ClaudioPreferences
    private let model: SettingsWindowPresentationModel<NSRunningApplication>
    private let soundPacksEditorOwner: SoundPacksEditorOwner
    private var window: NSWindow?
    private var isPresentingWindow = false
    private var focusRestoration: (@MainActor (NSRunningApplication?) -> Void)?
    private var languageCancellable: AnyCancellable?
    private var soundPackAvailabilityCancellable: AnyCancellable?
    private var soundsRouteAnnouncementCancellable: AnyCancellable?
    private var soundPackSelectionAnnouncementCancellable: AnyCancellable?
    private var soundPackLibraryAnnouncementCancellable: AnyCancellable?
    private var soundPackStatusAnnouncementCancellable: AnyCancellable?

    init(
        preferences: ClaudioPreferences,
        soundPacksEditorOwner: SoundPacksEditorOwner
    ) {
        self.preferences = preferences
        self.soundPacksEditorOwner = soundPacksEditorOwner
        model = SettingsWindowPresentationModel(
            preferences: preferences,
            availability: settingsRouteAvailability(
                packIDs: Set(soundPacksEditorOwner.model.packCards.map(\.id)),
                libraryState: soundPacksEditorOwner.model.libraryPresentationState))
        super.init()

        languageCancellable = preferences.$snapshot
            .map(\.language)
            .removeDuplicates()
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.updateWindowTitle()
                }
            }

        soundPackAvailabilityCancellable = soundPacksEditorOwner.model.$packCards
            .combineLatest(soundPacksEditorOwner.model.$libraryPresentationState)
            .map { cards, libraryState in
                settingsRouteAvailability(
                    packIDs: Set(cards.map(\.id)),
                    libraryState: libraryState)
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
        focusRestoration = restoration
        isPresentingWindow = true
        let presentation = model.present(route: route, handback: application)
        let presentedWindow = window ?? makeWindow()

        NSApp.activate(ignoringOtherApps: true)
        presentedWindow.makeKeyAndOrderFront(nil)
        if !presentation.wasAlreadyPresented {
            presentedWindow.makeFirstResponder(presentedWindow.contentViewController?.view)
        }
        // The presentation latch suppresses both the synchronous route publisher and
        // `windowDidBecomeKey`. Pay that announcement debt after the final route has landed so an
        // already-retained General → Sounds deep link or non-key reactivation cannot lose it.
        announceSoundsPresentationIfNeeded(in: presentedWindow)
        isPresentingWindow = false
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard
            !isPresentingWindow,
            let keyWindow = notification.object as? NSWindow,
            keyWindow === window
        else { return }
        announceLatestSoundPackStatusIfNeeded(in: keyWindow)
    }

    func windowWillClose(_ notification: Notification) {
        guard
            let closingWindow = notification.object as? NSWindow,
            closingWindow === window
        else { return }

        let handback = model.close()
        let restoration = focusRestoration
        focusRestoration = nil
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
            soundPacksEditorOwner: soundPacksEditorOwner)
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
    libraryState: SoundPackLibraryPresentationState
) -> SettingsRouteAvailability {
    let productScopes = HostID.productVisibleCases.map {
        PanelSoundScopeID.surface($0.surfaceID)
    }
    return SettingsRouteAvailability(
        integrationSurfaces: [],
        eventScopes: [.global],
        soundScopes: Set([PanelSoundScopeID.global] + productScopes),
        soundPackIDs: packIDs,
        soundPackSnapshotIsFresh: libraryState == .ready,
        events: Set(Event.allCases))
}
