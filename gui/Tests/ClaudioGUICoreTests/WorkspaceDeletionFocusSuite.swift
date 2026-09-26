import AppKit
import ClaudioCore
import ClaudioGUICore
import ClaudioSettingsPresentation
import Foundation
import SwiftUI

/// Opt-in key-window regression. Run with system Keyboard navigation off to exercise the
/// focus proxy used when native Buttons are not in the system key-view loop.
@MainActor
func runWorkspaceDeletionFocusSuites() async {
    await suite("workspace delete native focus: cancel restores an activatable remove button") {
        print("  System Keyboard navigation: \(NSApp.isFullKeyboardAccessEnabled ? "on" : "off")")
        let rule = WorkspaceSoundRule(
            directory: WorkspaceDirectory(kind: .directory, path: "/fixture/project"),
            surfaces: [.codex],
            profile: WorkspaceSoundProfile(selectedPack: "workspace", volume: 0.7))
        let fixture = SettingsPresentationFixtures.generalLogin(
            route: .destination(.eventsAndSounds), workspaceRules: [rule])
        let selection = fixture.eventSettingsSelection
        selection.select(EventSettingsWindowRoute(scope: .workspace(rule.id)))
        fixture.eventSettingsModel.selectSoundScope(.workspace(rule.id))
        let hostingView = NSHostingView(rootView: SettingsRootView(session: fixture.session))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_240, height: 820),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        _ = fixture.session.send(.windowPhaseChanged(.key))
        defer { window.orderOut(nil); window.close() }

        let becameKey = await deletionFocusWait { NSApp.isActive && window.isKeyWindow }
        expect(becameKey, "focus regression requires an active native key window")
        guard becameKey else { return }
        hostingView.layoutSubtreeIfNeeded()
        expect(selection.requestDeletion(of: rule), "capture the selected Workspace")

        for activation in [(UInt16(49), " "), (UInt16(36), "\r")] {
            let presented = await deletionFocusWait { window.attachedSheet != nil }
            expect(presented, "production view must present the native delete confirmation")
            guard let sheet = window.attachedSheet else { return }
            expect(
                deletionFocusSendKey(to: sheet, keyCode: 53, characters: "\u{1b}"),
                "Escape must be delivered through the sheet's responder chain")
            let dismissed = await deletionFocusWait {
                window.attachedSheet == nil && window.isKeyWindow
            }
            expect(dismissed, "cancel must finish the sheet and return its parent key window")
            // Yield for the production sheet-end focus request. The subsequent activation
            // assertion checks usable focus; an in-process AX lookup only sees the scroll view.
            await Task.yield()
            hostingView.layoutSubtreeIfNeeded()
            expect(
                selection.deletionPresentation.pending == nil
                    && selection.route.scope == .workspace(rule.id),
                "cancel must preserve the Workspace and consume no delete request")

            expect(
                deletionFocusSendKey(to: window, keyCode: 11, characters: "b"),
                "send an unrelated key to the restored control")
            expect(
                deletionFocusSendKey(
                    to: window, keyCode: activation.0, characters: activation.1,
                    modifiers: .shift),
                "send a modified activation key to the restored control")
            expect(
                selection.deletionPresentation.pending == nil,
                "unrelated and modified keys must not request deletion")
            expect(
                deletionFocusSendKey(
                    to: window, keyCode: activation.0, characters: activation.1),
                "send the unmodified activation key to the restored control")
            let reopened = await deletionFocusWait {
                selection.deletionPresentation.pending?.target.id == rule.id
            }
            expect(reopened, "Space and Return must reopen confirmation for the same Workspace")
            guard reopened else { return }
        }
        selection.cancelDeletion()
        _ = await deletionFocusWait { window.attachedSheet == nil }
    }
}

@MainActor
private func deletionFocusWait(_ condition: () -> Bool) async -> Bool {
    let deadline = Date(timeIntervalSinceNow: 2)
    while !condition(), Date() < deadline {
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return condition()
}

@MainActor
private func deletionFocusSendKey(
    to window: NSWindow, keyCode: UInt16, characters: String,
    modifiers: NSEvent.ModifierFlags = []
) -> Bool {
    for type in [NSEvent.EventType.keyDown, .keyUp] {
        guard
            let event = NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: keyCode)
        else { return false }
        window.sendEvent(event)
    }
    return true
}
