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

    await suite("Settings native focus: the first sound-pack list stop accepts arrow navigation") {
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
        guard case .sounds(let sounds) = fixture.soundPacksEditor.presentation.mode else {
            expect(false, "the Sounds editor must be mounted")
            return
        }
        let originalPackID = sounds.selectedPack?.id
        expect(
            sounds.packs.count > 1 && originalPackID != nil,
            "the list needs distinct inspectable packs")
        expect(probe.sendKey(keyCode: 48, characters: "\t"), "Tab must reach New Pack")
        expect(
            probe.sendKey(keyCode: 48, characters: "\t"), "the next Tab must reach the native list")
        expect(
            probe.sendKey(keyCode: 125, characters: "\u{F701}"),
            "Down must navigate the list at its first Tab stop")
        let selected = await settingsNavigationFocusWait {
            guard case .sounds(let current) = fixture.soundPacksEditor.presentation.mode else {
                return false
            }
            return current.selectedPack?.id != originalPackID
        }
        expect(
            selected, "the list's first Tab stop must inspect the next pack without an extra Tab")
        expect(
            probe.sendKey(keyCode: 126, characters: "\u{F700}"),
            "Up must remain owned by the native list")
        let restored = await settingsNavigationFocusWait {
            guard case .sounds(let current) = fixture.soundPacksEditor.presentation.mode else {
                return false
            }
            return current.selectedPack?.id == originalPackID
        }
        expect(restored, "the list must retain arrow navigation after its selection changes")
    }

    await suite("Settings native focus: an empty sound-pack list contributes no Tab stop") {
        expect(
            NSApp.isFullKeyboardAccessEnabled,
            "enable system Keyboard navigation for this regression")
        guard NSApp.isFullKeyboardAccessEnabled else { return }
        await withTempDirectory { root in
            let owner = SoundPacksEditorOwner.stateGalleryFixture(
                previewConfig: ClaudioConfig(selectedPack: "missing-pack"),
                packCards: [], selectedPackID: nil, selectedEventRows: [],
                environment: makeAudioImportEnvironment(
                    userPacksDirectory: root.appendingPathComponent("packs", isDirectory: true)),
                activation: nil)
            let fixture = SettingsPresentationFixtures.generalLogin(
                route: .destination(.about), soundPacksEditor: owner)
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
                "open empty Sounds through the real sidebar")
            let routed = await settingsNavigationFocusWait {
                fixture.session.state.focusDebt == nil
            }
            expect(routed, "the mounted root must consume the Sounds title focus request")
            await Task.yield()
            guard case .sounds(let sounds) = owner.presentation.mode else {
                expect(false, "the empty Sounds editor must be mounted")
                return
            }
            expect(sounds.packs.isEmpty, "the native list must have no inspectable pack")
            expect(probe.sendKey(keyCode: 48, characters: "\t"), "Tab must reach New Pack")
            expect(
                probe.sendKey(keyCode: 48, characters: "\t"),
                "Tab must skip the empty list and reach the provider picker")
            expect(
                !probe.isNativeListFocused,
                "an empty native List must not take a keyboard focus stop")
            guard !probe.isNativeListFocused else { return }
            expect(
                probe.sendKey(keyCode: 48, characters: "\t"), "Tab must reach credential management"
            )
            expect(
                probe.sendKey(keyCode: 49, characters: " "), "Space must open the credential sheet")
            let opened = await settingsNavigationFocusWait { probe.hasAttachedSheet }
            expect(
                opened,
                "empty-list traversal must reach the next real action without a phantom Tab stop")
        }
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
