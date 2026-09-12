import AppKit
import ClaudioCore
import ClaudioGUIComponents
import ClaudioGUICore
import ClaudioLocalization
import Combine
import Foundation
import SwiftUI

/// Retained, non-activating native surface for the C-direction prompt. Automatic delivery only
/// orders the panel; explicit interaction is the only path that makes it key.
@MainActor
final class EventNoticeWindowController: NSObject, NSWindowDelegate {
    let model: EventNoticeModel

    private let languageStore: ClaudioPreferences
    private let onWillBecomeInteractive: @MainActor () -> (@MainActor () -> Void)?
    private var focusRestoration: (@MainActor () -> Void)?
    private let navigation: SessionNavigationCoordinator
    private let window: NSPanel
    private var snapshotCancellable: AnyCancellable?
    private var screenCancellable: AnyCancellable?
    private var animationRevision: UInt64 = 0
    private var presentationScreen: NSScreen?
    private var isInteractive = false
    private var renderedPhase: EventNoticePresentationPhase = .hidden

    init(
        model: EventNoticeModel,
        languageStore: ClaudioPreferences,
        onWillBecomeInteractive: @escaping @MainActor () -> (@MainActor () -> Void)? = { nil }
    ) {
        self.model = model
        navigation = SessionNavigationCoordinator(model: model)
        self.languageStore = languageStore
        self.onWillBecomeInteractive = onWillBecomeInteractive
        window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 92),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: true)

        super.init()

        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .floating
        window.hidesOnDeactivate = false
        window.becomesKeyOnlyIfNeeded = true
        window.isFloatingPanel = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.ignoresMouseEvents = false
        window.delegate = self
        window.title = "claudi0 event notice"
        window.contentView = EventNoticeHostingView(
            rootView: EventNoticeView(
                model: model,
                languageStore: languageStore,
                onViewSource: { [weak self] notice in
                    self?.viewSource(notice)
                },
                onOpenRecent: { [weak self] in
                    self?.openInteractive()
                },
                onCopySessionID: { [weak self] sessionID in
                    self?.copySessionID(sessionID) ?? false
                },
                onClose: { [weak self] in
                    self?.close()
                }))

        snapshotCancellable = model.$snapshot.sink { [weak self] snapshot in
            self?.render(snapshot)
        }
        screenCancellable = NotificationCenter.default
            .publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in
                self?.repositionIfVisible()
            }
    }

    func openInteractive() {
        model.openRecent()
        guard model.snapshot.isExpanded else { return }
        becomeInteractive()
    }

    private func becomeInteractive() {
        if !isInteractive { focusRestoration = onWillBecomeInteractive() }
        isInteractive = true
        positionWindow()
        window.alphaValue = 1
        window.makeKeyAndOrderFront(nil)
        model.setKeyboardFocused(true)
    }

    func viewSource(_ action: EventNoticeAction) {
        guard model.viewSource(action) == .applied else { return }
        becomeInteractive()
    }

    @discardableResult
    func copySessionID(_ action: EventNoticeAction) -> Bool {
        navigation.copy(action) { sessionID in
            NSPasteboard.general.clearContents()
            return NSPasteboard.general.setString(sessionID, forType: .string)
        }
    }

    func close() {
        // Focus handback is only owed while this window still owns the key status; if the user
        // already moved focus elsewhere, giving anything back would override their choice.
        let owesHandback = isInteractive && window.isKeyWindow && NSApp.isActive
        let restoration = focusRestoration
        focusRestoration = nil
        isInteractive = false
        navigation.reset()
        model.setKeyboardFocused(false)
        model.dismiss()
        if owesHandback { restoration?() }
    }

    func clearForPrivacy() {
        focusRestoration = nil
        isInteractive = false
        presentationScreen = nil
        window.orderOut(nil)
        navigation.reset()
        model.clearForPrivacy()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard isInteractive else { return }
        model.setKeyboardFocused(true)
    }

    func windowDidResignKey(_ notification: Notification) {
        model.setKeyboardFocused(false)
    }

    private func render(_ snapshot: EventNoticeModelSnapshot) {
        let phaseChanged = renderedPhase != snapshot.phase
        renderedPhase = snapshot.phase
        guard (snapshot.current != nil || snapshot.isExpanded), snapshot.phase != .hidden else {
            // Privacy clears arrive through the runtime's shared model as well as this adapter.
            // End the old interaction here so its return target cannot survive into a new epoch.
            focusRestoration = nil
            isInteractive = false
            if snapshot.phase == .hidden { presentationScreen = nil }
            if window.isVisible { window.orderOut(nil) }
            return
        }
        positionWindow(snapshot: snapshot)
        animationRevision &+= 1
        let revision = animationRevision
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        switch snapshot.phase {
        case .entering, .visible:
            if !window.isVisible {
                window.alphaValue = reduceMotion ? 1 : 0; window.orderFront(nil)
            }
            if reduceMotion {
                window.alphaValue = 1
            } else if phaseChanged {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = EventNoticeModel.fadeDuration
                    window.animator().alphaValue = 1
                }
            }
        case .exiting:
            if reduceMotion {
                window.alphaValue = 0
                window.orderOut(nil)
            } else {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = EventNoticeModel.fadeDuration
                    context.completionHandler = { [weak self] in
                        guard let self, self.animationRevision == revision else { return }
                        self.window.orderOut(nil)
                    }
                    window.animator().alphaValue = 0
                }
            }
        case .hidden:
            window.orderOut(nil)
        }
    }

    private func repositionIfVisible() {
        guard window.isVisible else { return }
        positionWindow()
    }

    private func positionWindow(snapshot: EventNoticeModelSnapshot? = nil) {
        if let presentationScreen,
            !NSScreen.screens.contains(where: { $0 === presentationScreen })
        {
            self.presentationScreen = nil
        }
        let screen = presentationScreen ?? screenUnderPointer() ?? NSScreen.main
        guard let screen else { return }
        if presentationScreen == nil { presentationScreen = screen }
        let visible = screen.visibleFrame
        let width = EventNoticePlacement.clampedWidth(visibleFrame: visible)
        let preferredHeight = EventNoticeView.preferredHeight(for: snapshot ?? model.snapshot)
        let availableHeight = EventNoticePlacement.availableHeight(
            screenFrame: screen.frame, visibleFrame: visible, safeAreaTop: screen.safeAreaInsets.top
        )
        let height = min(preferredHeight, availableHeight)
        let x = EventNoticePlacement.clampedX(visibleFrame: visible, width: width)
        let y = EventNoticePlacement.topAnchorY(
            screenFrame: screen.frame,
            visibleFrame: visible,
            safeAreaTop: screen.safeAreaInsets.top,
            height: height)
        let frame = NSRect(x: x, y: y, width: width, height: height)
        if window.frame != frame { window.setFrame(frame, display: true) }
    }

    /// The first notice of a burst pins to the display under the pointer (SPEC 原生呈现:
    /// 首条固定落在指针所在显示器); the burst then stays on that screen.
    private func screenUnderPointer() -> NSScreen? {
        let point = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { $0.frame.contains(point) })
    }
}
