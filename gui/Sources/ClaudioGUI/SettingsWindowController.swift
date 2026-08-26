import AppKit
import ClaudioCore
import ClaudioGUICore
import ClaudioLocalization
import Combine
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
    private var window: NSWindow?
    private var focusRestoration: (@MainActor (NSRunningApplication?) -> Void)?
    private var languageCancellable: AnyCancellable?

    init(
        preferences: ClaudioPreferences,
        availability: SettingsRouteAvailability
    ) {
        self.preferences = preferences
        model = SettingsWindowPresentationModel(
            preferences: preferences,
            availability: availability)
        super.init()

        languageCancellable = preferences.$snapshot
            .map(\.language)
            .removeDuplicates()
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
        let content = SettingsWindowView(model: model, preferences: preferences)
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
}
