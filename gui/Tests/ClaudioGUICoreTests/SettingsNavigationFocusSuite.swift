import AppKit
import ClaudioCore
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

    await suite("Settings native focus: Sounds title leads to the first page action") {
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
        expect(
            probe.clickSidebar(.sounds, horizontalFraction: 0.5),
            "open Sounds through the real sidebar")
        let routed = await settingsNavigationFocusWait { fixture.session.state.focusDebt == nil }
        expect(routed, "the mounted root must consume the Sounds title focus request")
        await Task.yield()

        expect(probe.sendKey(keyCode: 48, characters: "\t"), "Tab must leave the Sounds title")
        expect(
            probe.sendKey(keyCode: 49, characters: " "),
            "Space must activate the first Sounds action")
        let activated = await settingsNavigationFocusWait {
            guard case .sounds(let sounds) = fixture.soundPacksEditor.presentation.mode else {
                return false
            }
            return sounds.draft != nil
        }
        expect(
            activated && fixture.session.state.routeResolution.destination == .sounds,
            "Tab/Space from the Sounds title must create a draft instead of selecting a sidebar row"
        )
    }

    await suite("Settings native focus: Events title leads to the first sound scope") {
        expect(
            NSApp.isFullKeyboardAccessEnabled,
            "enable system Keyboard navigation for this regression")
        guard NSApp.isFullKeyboardAccessEnabled else { return }
        let rule = WorkspaceSoundRule(
            directory: WorkspaceDirectory(kind: .directory, path: "/fixture/keyboard-scope"),
            surfaces: [.codex],
            profile: WorkspaceSoundProfile(selectedPack: "settings-fixture-pack", volume: 0.7))
        let fixture = SettingsPresentationFixtures.generalLogin(
            route: .destination(.about), workspaceRules: [rule])
        let workspace = PanelSoundScopeID.workspace(rule.id)
        fixture.eventSettingsSelection.select(EventSettingsWindowRoute(scope: workspace))
        fixture.eventSettingsModel.selectSoundScope(workspace)
        let probe = SettingsRootNativeProbe(session: fixture.session)
        defer { probe.close() }
        probe.activate()
        let active = await settingsNavigationFocusWait { probe.isActiveKeyWindow }
        expect(active, "the native focus regression requires an active key window")
        guard active else { return }
        _ = fixture.session.send(.windowPhaseChanged(.key))
        let ready = await settingsNavigationFocusWait { fixture.session.state.focusDebt == nil }
        expect(ready, "the mounted root must consume the initial title focus request")
        expect(
            probe.clickSidebar(.eventsAndSounds, horizontalFraction: 0.5),
            "open Events through the real sidebar")
        let routed = await settingsNavigationFocusWait { fixture.session.state.focusDebt == nil }
        expect(routed, "the mounted root must consume the Events title focus request")
        await Task.yield()
        expect(
            fixture.eventSettingsSelection.route.scope == workspace,
            "ordinary navigation must preserve the workspace until the first scope action is activated"
        )

        expect(probe.sendKey(keyCode: 48, characters: "\t"), "Tab must leave the Events title")
        expect(
            probe.sendKey(keyCode: 49, characters: " "), "Space must activate the first sound scope"
        )
        let activated = await settingsNavigationFocusWait {
            fixture.eventSettingsSelection.route.scope == .global
                && fixture.eventSettingsModel.selectedSoundScope == .global
        }
        expect(
            activated && fixture.session.state.routeResolution.destination == .eventsAndSounds,
            "Tab/Space from the Events title must select Default Group instead of a sidebar row")
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
