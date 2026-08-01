import AppKit
import SwiftUI

/// App-lifetime owner of Claudio's one retained integrations window.
///
/// The future menu-bar handoff supplies a focus-restoration closure naming the exact trigger that
/// opened this window. The closure is consumed once on close and cleared before invocation, so a
/// retained reopen can never focus an obsolete control.
@MainActor
final class IntegrationsWindowController: NSObject, NSWindowDelegate {
    private let model: IntegrationsWindowModel
    private let focusCoordinator = IntegrationsWindowFocusCoordinator()
    private var window: NSWindow?
    private var focusRestoration: (@MainActor () -> Void)?

    init(model: IntegrationsWindowModel) {
        self.model = model
        super.init()
    }

    func showWindow(returnFocusTo restoration: @escaping @MainActor () -> Void) {
        focusRestoration = restoration
        let wasVisible = window?.isVisible == true
        let presentedWindow = window ?? makeWindow()

        model.noteWindowVisibility(true)
        NSApp.activate(ignoringOtherApps: true)
        presentedWindow.makeKeyAndOrderFront(nil)
        guard !wasVisible else { return }

        presentedWindow.makeFirstResponder(presentedWindow.contentViewController?.view)
        focusCoordinator.requestInitialFocus()
    }

    func windowWillClose(_ notification: Notification) {
        guard
            let closingWindow = notification.object as? NSWindow,
            closingWindow === window
        else { return }

        model.noteWindowVisibility(false)
        let restoration = focusRestoration
        focusRestoration = nil
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                restoration?()
            }
        }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard let changedWindow = notification.object as? NSWindow, changedWindow === window
        else { return }
        model.noteWindowKeyState(true)
    }

    func windowDidResignKey(_ notification: Notification) {
        guard let changedWindow = notification.object as? NSWindow, changedWindow === window
        else { return }
        model.noteWindowKeyState(false)
    }

    private func makeWindow() -> NSWindow {
        let content = IntegrationsWindowView(
            model: model,
            focusCoordinator: focusCoordinator)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = "Claudio · 集成"
        window.contentMinSize = NSSize(width: 640, height: 520)
        window.contentViewController = NSHostingController(rootView: content)
        window.isReleasedWhenClosed = false
        window.autorecalculatesKeyViewLoop = true
        window.delegate = self
        window.setFrameAutosaveName("Claudio.IntegrationsWindow")
        window.center()
        self.window = window
        return window
    }

}
