#if DEBUG
import AppKit
import ClaudioCore
import ClaudioGUICore
import ClaudioLocalization
import Combine
import SwiftUI

/// App-lifetime owner of the single retained unified Settings window skeleton.
///
/// The owner remains DEBUG-only until real destination views migrate. Its one lazy `NSWindow`
/// survives close, and every close consumes at most one focus/activation handback.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let languageStore: ClaudioLanguageStore
    private let model: SettingsWindowPresentationModel<NSRunningApplication>
    private var window: NSWindow?
    private var focusRestoration: (@MainActor (NSRunningApplication?) -> Void)?
    private var languageCancellable: AnyCancellable?

    init(
        languageStore: ClaudioLanguageStore,
        availability: SettingsRouteAvailability
    ) {
        self.languageStore = languageStore
        model = SettingsWindowPresentationModel(availability: availability)
        super.init()

        languageCancellable = languageStore.$language
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.updateWindowTitle()
                }
            }
    }

    func showWindow(
        route: SettingsRoute? = nil,
        returnFocusTo application: NSRunningApplication?,
        onClose restoration: @escaping @MainActor (NSRunningApplication?) -> Void
    ) {
        focusRestoration = restoration
        let presentation = model.present(route: route, handback: application)
        let presentedWindow = window ?? makeWindow()

        NSApp.activate(ignoringOtherApps: true)
        presentedWindow.makeKeyAndOrderFront(nil)
        guard !presentation.wasAlreadyPresented else { return }
        presentedWindow.makeFirstResponder(presentedWindow.contentViewController?.view)
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
        let content = SettingsWindowView(model: model, languageStore: languageStore)
        let window = NSWindow(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: SettingsWindowGeometry.defaultWidth,
                height: SettingsWindowGeometry.defaultHeight),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = ClaudioL10n(language: languageStore.language).text(.settingsWindowTitle)
        window.contentMinSize = NSSize(
            width: SettingsWindowGeometry.minimumWidth,
            height: SettingsWindowGeometry.minimumHeight)
        window.contentViewController = NSHostingController(rootView: content)
        window.isReleasedWhenClosed = false
        window.autorecalculatesKeyViewLoop = true
        window.delegate = self
        window.setFrameAutosaveName("Claudio.SettingsWindow.Debug")
        window.center()
        self.window = window
        return window
    }

    private func updateWindowTitle() {
        window?.title = ClaudioL10n(language: languageStore.language).text(.settingsWindowTitle)
    }
}
#endif
