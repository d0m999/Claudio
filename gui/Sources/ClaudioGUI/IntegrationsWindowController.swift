import AppKit
import ClaudioGUICore
import Combine
import SwiftUI

/// App-lifetime owner of Claudio's one retained integrations window.
///
/// The menu-bar handoff supplies a focus-restoration closure naming the exact trigger that opened
/// this window. While visible, the controller also tracks the latest external foreground app and
/// returns it with that closure. Both values are consumed once on close, so a retained reopen can
/// never focus an obsolete control or hand activation to a stale application.
@MainActor
final class IntegrationsWindowController: NSObject, NSWindowDelegate {
    private let model: IntegrationsWindowModel
    private let focusCoordinator = IntegrationsWindowFocusCoordinator()
    private var window: NSWindow?
    private var focusRestoration: (@MainActor (NSRunningApplication?) -> Void)?
    private var handbackTracker = RetainedWindowHandbackTracker<NSRunningApplication>()
    private var externalActivationCancellable: AnyCancellable?

    init(model: IntegrationsWindowModel) {
        self.model = model
        super.init()

        // A retained standard window may stay visible while the user visits several other apps.
        // The popover's original previous-app debt is then stale, so remember the latest external
        // activation and return it when this window closes. The tracker owns the visible/closing
        // policy; this subscription only translates AppKit notifications into typed inputs.
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
    }

    func showWindow(
        returnFocusTo restoration: @escaping @MainActor (NSRunningApplication?) -> Void
    ) {
        focusRestoration = restoration
        let wasVisible = window?.isVisible == true
        let presentedWindow = window ?? makeWindow()
        if !wasVisible {
            handbackTracker.beginPresentation()
        }

        model.noteWindowVisibility(true)
        NSApp.activate(ignoringOtherApps: true)
        presentedWindow.makeKeyAndOrderFront(nil)
        guard !wasVisible else { return }

        presentedWindow.makeFirstResponder(presentedWindow.contentViewController?.view)
        focusCoordinator.requestInitialFocus()
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

        model.noteWindowVisibility(false)
        let handbackApplication = handbackTracker.consumeOnClose()
        let restoration = focusRestoration
        focusRestoration = nil
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                restoration?(handbackApplication)
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
            contentRect: NSRect(x: 0, y: 0, width: 840, height: 620),
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
