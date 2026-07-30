import AppKit
import ClaudioGUICore
import Combine
import SwiftUI

/// App-lifetime owner of the one Sound Packs window.
///
/// `MenuBarController` owns this controller. The `NSWindow` itself is lazy because most menu-bar
/// sessions never open management, and retained after close so repeated 「管理声音包…」 actions
/// reuse the same window/model instead of growing a second editor.
@MainActor
public final class SoundPacksWindowController: NSObject, NSWindowDelegate {
    private let model: SoundPacksWindowModel
    private let userPacksDirectory: URL
    private var window: NSWindow?
    /// The app that owned the keyboard before Claudio opened its popover. The popover transfers
    /// this debt instead of paying it while the management window is becoming key. It is cleared
    /// on every close before any activation attempt, so a retained/reopened window cannot hand
    /// focus to a stale app twice.
    private var handbackApplication: NSRunningApplication?
    private var isClosingWindow = false
    private var externalActivationCancellable: AnyCancellable?

    public init(
        configFile: URL,
        environment: AudioImportEnvironment,
        refreshCoordinator: SoundPacksRefreshCoordinator
    ) {
        model = SoundPacksWindowModel(
            configFile: configFile,
            environment: environment,
            refreshCoordinator: refreshCoordinator)
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
    }

    public func showWindow(returnFocusTo application: NSRunningApplication?) {
        isClosingWindow = false
        // Re-presenting an already-open window from Claudio itself has no new external app to
        // record; retain the existing debt until the window really closes.
        if let application {
            handbackApplication = application
        }
        model.reload(followActivePack: true)
        let presentedWindow = window ?? makeWindow()
        NSApp.activate(ignoringOtherApps: true)
        presentedWindow.makeKeyAndOrderFront(nil)
    }

    public func windowWillClose(_ notification: Notification) {
        isClosingWindow = true
        let previous = handbackApplication
        handbackApplication = nil

        guard
            let closingWindow = notification.object as? NSWindow,
            closingWindow === window,
            NSApp.isActive
        else { return }

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
            userPacksDirectory: userPacksDirectory)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = "声音包"
        window.contentMinSize = NSSize(width: 560, height: 400)
        window.contentViewController = NSHostingController(rootView: content)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setFrameAutosaveName("Claudio.SoundPacksWindow")
        window.center()
        self.window = window
        return window
    }
}
