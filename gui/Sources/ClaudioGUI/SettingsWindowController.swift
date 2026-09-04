import AppKit
import ClaudioGUICore
import ClaudioLocalization
import ClaudioSettingsPresentation
import Combine
import SwiftUI

/// Thin AppKit adapter around the app-lifetime Settings presentation session. Destination route,
/// focus, lifecycle and announcement intent stay in the importable session; this owner retains
/// exactly one native window and the activation handback debt attached to it.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let settingsPresentationSession: SettingsPresentationSession
    private var window: NSWindow?
    private var focusRestoration: (@MainActor (NSRunningApplication?) -> Void)?
    private var handbackTracker = RetainedWindowHandbackTracker<NSRunningApplication>()
    private var externalActivationCancellable: AnyCancellable?
    private var settingsPresentationCancellable: AnyCancellable?
    private var settingsPresentationAnnouncementDeliveryScheduled = false

    init(session: SettingsPresentationSession) {
        settingsPresentationSession = session
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

        settingsPresentationCancellable = session.$state
            .sink { [weak self] state in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.updateWindowTitle(language: state.language)
                    if state.pendingAnnouncement != nil {
                        self.scheduleSettingsPresentationAnnouncementDelivery()
                    }
                }
            }
    }

    func showWindow(
        request: SettingsPresentationRequest = .route(nil),
        returnFocusTo application: NSRunningApplication?,
        onClose restoration: @escaping @MainActor (NSRunningApplication?) -> Void
    ) {
        focusRestoration = restoration
        let wasVisible = window?.isVisible == true
        _ = settingsPresentationSession.send(.present(request))
        let presentedWindow = window ?? makeWindow()
        if !wasVisible {
            handbackTracker.beginPresentation(returnTo: application)
        }

        if !wasVisible || !presentedWindow.isKeyWindow {
            _ = settingsPresentationSession.send(.windowPhaseChanged(.visibleNonKey))
        }
        NSApp.activate(ignoringOtherApps: true)
        presentedWindow.makeKeyAndOrderFront(nil)
        _ = settingsPresentationSession.send(
            .windowPhaseChanged(presentedWindow.isKeyWindow ? .key : .visibleNonKey))
        if !wasVisible {
            presentedWindow.makeFirstResponder(presentedWindow.contentViewController?.view)
        }
        scheduleSettingsPresentationAnnouncementDelivery()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard
            let keyWindow = notification.object as? NSWindow,
            keyWindow === window
        else { return }
        _ = settingsPresentationSession.send(.windowPhaseChanged(.key))
        scheduleSettingsPresentationAnnouncementDelivery()
    }

    func windowDidResignKey(_ notification: Notification) {
        guard
            let changedWindow = notification.object as? NSWindow,
            changedWindow === window
        else { return }
        _ = settingsPresentationSession.send(.windowPhaseChanged(.visibleNonKey))
    }

    func windowWillClose(_ notification: Notification) {
        guard
            let closingWindow = notification.object as? NSWindow,
            closingWindow === window
        else { return }

        _ = settingsPresentationSession.send(.windowWillClose)
        let handback = handbackTracker.consumeOnClose()
        let restoration = focusRestoration
        focusRestoration = nil
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                restoration?(handback)
            }
        }
    }

    private func makeWindow() -> NSWindow {
        let content = SettingsRootView(session: settingsPresentationSession)
        let window = NSWindow(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: SettingsWindowGeometry.defaultWidth,
                height: SettingsWindowGeometry.defaultHeight),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = ClaudioL10n(
            language: settingsPresentationSession.state.language
        ).text(.settingsWindowTitle)
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

    private func updateWindowTitle(language: ClaudioAppLanguage) {
        window?.title = ClaudioL10n(language: language).text(.settingsWindowTitle)
    }

    private func scheduleSettingsPresentationAnnouncementDelivery() {
        guard !settingsPresentationAnnouncementDeliveryScheduled else { return }
        settingsPresentationAnnouncementDeliveryScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.settingsPresentationAnnouncementDeliveryScheduled = false
                self.deliverPendingSettingsPresentationAnnouncement()
            }
        }
    }

    private func deliverPendingSettingsPresentationAnnouncement() {
        guard
            settingsPresentationSession.state.windowPhase == .key,
            let announcement = settingsPresentationSession.state.pendingAnnouncement,
            let window,
            window.isVisible,
            window.isKeyWindow
        else { return }
        let sentence = announcement.meaning.localizedSentence(
            language: settingsPresentationSession.state.language)
        guard !sentence.isEmpty else { return }
        NSAccessibility.post(
            element: window,
            notification: .announcementRequested,
            userInfo: [
                .announcement: sentence,
                .priority: announcement.meaning.priority,
            ])
        _ = settingsPresentationSession.send(
            .acknowledgeAnnouncement(id: announcement.id, didPost: true))
    }
}
