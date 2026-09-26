import AppKit
import ClaudioGUICore
import Foundation

@testable import ClaudioSettingsPresentation

/// Opt-in native key-view regression; requires system Keyboard navigation to be enabled.
@MainActor
func runSettingsNavigationFocusSuites() async {
    await suite("Settings native focus: navigation after Tab and Shift-Tab reaches the new page") {
        expect(
            NSApp.isFullKeyboardAccessEnabled,
            "enable system Keyboard navigation for this regression")
        guard NSApp.isFullKeyboardAccessEnabled else { return }
        let fixture = SettingsPresentationFixtures.generalLogin(route: .destination(.about))
        let probe = SettingsRootNativeProbe(session: fixture.session)
        defer { probe.close() }
        probe.activate()
        let active = await settingsNavigationFocusWait { probe.isActiveKeyWindow }
        expect(active, "the native focus regression requires an active key window")
        guard active else { return }
        _ = fixture.session.send(.windowPhaseChanged(.key))
        let ready = await settingsNavigationFocusWait { fixture.session.state.focusDebt == nil }
        expect(ready, "the mounted root must consume the initial title focus request")
        await Task.yield()

        expect(
            probe.sendKey(keyCode: 48, characters: "\t"),
            "Tab must reach the About page's first action")
        expect(
            probe.sendKey(keyCode: 48, characters: "\t", modifiers: .shift),
            "Shift-Tab must return from the first action to the About title")
        expect(
            probe.clickSidebar(.display, horizontalFraction: 0.5),
            "switch destinations through the real sidebar mouse route after keyboard traversal")
        expect(
            fixture.session.state.routeResolution.destination == .display,
            "the click must select Display")
        expect(probe.isActiveKeyWindow, "navigation must retain the native key window")
        expect(
            fixture.session.state.windowPhase == .key,
            "the presentation session must still own key focus")
        let routed = await settingsNavigationFocusWait { fixture.session.state.focusDebt == nil }
        expect(routed, "the mounted root must consume the new destination's focus request")
        await Task.yield()

        let preferences = fixture.session.dependencies.preferences
        let previousStatusDot = preferences.showsMenuBarStatusDot
        expect(probe.sendKey(keyCode: 48, characters: "\t"), "Tab must leave the new Display title")
        expect(
            probe.sendKey(keyCode: 49, characters: " "),
            "Space must activate the first Display control")
        let activated = await settingsNavigationFocusWait {
            preferences.showsMenuBarStatusDot != previousStatusDot
        }
        expect(
            activated && fixture.session.state.routeResolution.destination == .display,
            "after Tab/Shift-Tab then navigation, Tab/Space must toggle Display instead of a sidebar row"
        )
    }
}

@MainActor
private func settingsNavigationFocusWait(_ condition: () -> Bool) async -> Bool {
    let deadline = Date(timeIntervalSinceNow: 2)
    while !condition(), Date() < deadline {
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return condition()
}
