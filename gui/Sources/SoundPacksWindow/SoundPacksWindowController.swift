import AppKit
import ClaudioCore
import ClaudioGUICore
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
    private let refreshCoordinator: SoundPacksRefreshCoordinator
    private lazy var model: SoundPacksWindowModel = SoundPacksWindowModel(
        configFile: configFile,
        lockFile: lockFile,
        environment: environment,
        refreshCoordinator: refreshCoordinator)
    private lazy var focusCoordinator = SoundPacksWindowFocusCoordinator()
    private let userPacksDirectory: URL
    private var window: NSWindow?
    /// The app that owned the keyboard before Claudio opened its popover. The popover transfers
    /// this debt instead of paying it while the management window is becoming key. It is cleared
    /// on every close before any activation attempt, so a retained/reopened window cannot hand
    /// focus to a stale app twice.
    private var handbackApplication: NSRunningApplication?
    private var isClosingWindow = false
    private var externalActivationCancellable: AnyCancellable?
    private var selectionAnnouncementCancellable: AnyCancellable?
    private var audioFailureAnnouncementCancellable: AnyCancellable?
    private var factoryRestoreNoticeAnnouncementCancellable: AnyCancellable?
    private var factoryRestoreFailureAnnouncementCancellable: AnyCancellable?
    private var starredPacksFailureAnnouncementCancellable: AnyCancellable?

    public init(
        configFile: URL,
        lockFile: URL = ClaudioPaths.configLockFile,
        environment: AudioImportEnvironment,
        refreshCoordinator: SoundPacksRefreshCoordinator
    ) {
        self.configFile = configFile
        self.lockFile = lockFile
        self.environment = environment
        self.refreshCoordinator = refreshCoordinator
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
        presentedWindow.makeFirstResponder(presentedWindow.contentViewController?.view)
        focusCoordinator.requestInitialFocus()
        SoundPacksWindowAccessibilityBridge.post(
            .windowOpened,
            facts: accessibilityFacts(),
            window: presentedWindow)
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
            userPacksDirectory: userPacksDirectory,
            focusCoordinator: focusCoordinator)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = "声音包"
        window.contentMinSize = NSSize(width: 560, height: 400)
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
                    guard
                        let self,
                        self.window?.isKeyWindow == true
                    else { return }
                    SoundPacksWindowAccessibilityBridge.post(
                        .selectionChanged,
                        facts: self.accessibilityFacts(selectedPackID: selectedPackID),
                        window: window)
                }
            }
        audioFailureAnnouncementCancellable = model.$audioActionError
            .dropFirst()
            .compactMap { $0 }
            .sink { [weak self] error in
                MainActor.assumeIsolated {
                    guard
                        let self,
                        self.window?.isKeyWindow == true
                    else { return }
                    SoundPacksWindowAccessibilityBridge.post(
                        .writeFailed(action: "音频操作", reason: error.message),
                        facts: self.accessibilityFacts(),
                        window: window)
                }
            }
        factoryRestoreNoticeAnnouncementCancellable = model.$factoryRestoreNotice
            .dropFirst()
            .compactMap { $0 }
            .sink { [weak self] outcome in
                MainActor.assumeIsolated {
                    guard
                        let self,
                        self.window?.isKeyWindow == true
                    else { return }
                    SoundPacksWindowAccessibilityBridge.post(
                        .writeSucceeded(
                            message: factoryPackRestoreNoticeMessage(outcome)),
                        facts: self.accessibilityFacts(),
                        window: window)
                }
            }
        factoryRestoreFailureAnnouncementCancellable = model.$factoryRestoreActionError
            .dropFirst()
            .compactMap { $0 }
            .sink { [weak self] error in
                MainActor.assumeIsolated {
                    guard
                        let self,
                        self.window?.isKeyWindow == true
                    else { return }
                    SoundPacksWindowAccessibilityBridge.post(
                        .writeFailed(
                            action: "恢复出厂声音",
                            reason: error.message),
                        facts: self.accessibilityFacts(),
                        window: window)
                }
            }
        starredPacksFailureAnnouncementCancellable = model.$starredPacksError
            .dropFirst()
            .compactMap { $0 }
            .sink { [weak self] error in
                MainActor.assumeIsolated {
                    guard
                        let self,
                        self.window?.isKeyWindow == true
                    else { return }
                    SoundPacksWindowAccessibilityBridge.post(
                        .writeFailed(
                            action: "更新星标",
                            reason: soundPacksWindowStarredPacksFailureReason(error)),
                        facts: self.accessibilityFacts(),
                        window: window)
                }
            }
        return window
    }

    private func accessibilityFacts() -> SoundPacksWindowAnnouncementFacts {
        accessibilityFacts(selectedPackID: model.selectedPackID)
    }

    /// `@Published` emits its new value before the stored property is replaced. Accepting that
    /// emitted value explicitly keeps a transition to `nil` from accidentally announcing the old
    /// selection.
    private func accessibilityFacts(
        selectedPackID: String?
    ) -> SoundPacksWindowAnnouncementFacts {
        let selectedName = selectedPackID.flatMap { packID in
            model.packCards.first(where: { $0.id == packID }).map {
                SelectedPackMetadata(id: $0.id, name: $0.name).displayName
            }
        }
        return SoundPacksWindowAnnouncementFacts(
            packCount: model.packCards.count,
            selectedPackName: selectedName)
    }
}
