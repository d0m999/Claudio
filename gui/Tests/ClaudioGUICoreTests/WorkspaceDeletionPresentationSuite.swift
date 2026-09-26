import AppKit
import ClaudioCore
import ClaudioGUICore
import ClaudioSettingsPresentation
import Foundation
import SwiftUI

@MainActor
func runWorkspaceDeletionPresentationSuites() {
    suite("workspace delete selection: cancel, leave and repeated confirmation never submit") {
        let rule = deletionPresentationRule()
        let target = WorkspaceSoundDeleteTarget(rule: rule)
        let selection = EventSettingsWindowSelection()
        expect(
            !selection.requestDeletion(of: rule), "Default Group cannot request Workspace deletion")
        selection.select(EventSettingsWindowRoute(scope: .workspace(rule.id)))
        expect(selection.requestDeletion(of: rule), "selected Workspace can request confirmation")
        let cancelledRequest = selection.deletionPresentation.pending!
        expect(
            cancelledRequest.target == target
                && !selection.requestDeletion(of: rule),
            "confirmation retains exact captured identity and cannot be opened twice")
        selection.cancelDeletion()
        expect(
            selection.deletionPresentation.pending == nil
                && selection.presentationState.focusTarget == .workspaceRemove(rule.id)
                && !selection.consumeDeletion(cancelledRequest),
            "cancel restores the remove-button focus target and consumes no write capability")

        expect(selection.requestDeletion(of: rule), "a new user request may reopen confirmation")
        let request = selection.deletionPresentation.pending!
        expect(
            request != cancelledRequest && request.target == cancelledRequest.target
                && !selection.consumeDeletion(cancelledRequest),
            "old confirmation cannot consume a newer request for the same target")
        expect(selection.consumeDeletion(request), "first exact confirm consumes request")
        expect(!selection.consumeDeletion(request), "repeated confirm cannot submit twice")
        let config = deletionPresentationConfig(rule: rule)
        expect(
            !selection.finishDeletion(
                request, succeeded: false, error: .lockBusy,
                configState: .operational(config))
                && selection.route.scope == .workspace(rule.id)
                && selection.presentationState.focusTarget == .workspaceDeleteFeedback
                && selection.deletionPresentation.feedback == .failed(target, .lockBusy, nil),
            "rejected write keeps selection and emits typed, focusable delete feedback")
        expect(
            !selection.finishDeletion(
                request, succeeded: true, error: nil,
                configState: .operational(config)),
            "settled target cannot apply a delayed success")

        expect(selection.requestDeletion(of: rule), "a later attempt requires a fresh request")
        let newer = selection.deletionPresentation.pending!
        expect(selection.consumeDeletion(newer), "new request has its own in-flight token")
        expect(
            !selection.finishDeletion(
                request, succeeded: true, error: nil,
                configState: .operational(config))
                && selection.route.scope == .workspace(rule.id),
            "stale success after a newer request cannot settle its in-flight operation")
        _ = selection.finishDeletion(
            newer, succeeded: false, error: .lockBusy,
            configState: .operational(config))
        expect(selection.requestDeletion(of: rule), "new confirmation can be opened after settle")
        let leaving = selection.deletionPresentation.pending!
        selection.leaveDestination()
        expect(
            selection.deletionPresentation.pending == nil
                && selection.deletionPresentation.feedback == nil
                && !selection.consumeDeletion(leaving),
            "leaving destination clears confirmation without submitting it")
    }

    suite("workspace delete selection: success and publication readback preserve scope semantics") {
        let rule = deletionPresentationRule()
        let target = WorkspaceSoundDeleteTarget(rule: rule)
        var config = deletionPresentationConfig(rule: rule)
        for (state, expected) in [
            (PanelConfigState.operational(config), WorkspaceDeleteReadback.originalPresent),
            (PanelConfigState.operational(ClaudioConfig(selectedPack: "default")), .absent),
            (PanelConfigState.unwritable(reason: "fixture"), .unavailable),
        ] {
            let selection = EventSettingsWindowSelection(
                route: EventSettingsWindowRoute(scope: .workspace(rule.id)))
            expect(selection.requestDeletion(of: rule), "each conflict needs a fresh request")
            let request = selection.deletionPresentation.pending!
            expect(selection.consumeDeletion(request), "each conflict consumes once")
            expect(
                !selection.finishDeletion(
                    request, succeeded: false, error: .publishedConflict(), configState: state)
                    && selection.route.scope == .workspace(rule.id)
                    && selection.deletionPresentation.feedback
                        == .failed(target, .publishedConflict(), expected),
                "published conflict displays actual readback without selecting Default Group")
            if expected == .absent {
                expect(
                    selection.unavailableRequestedScopeStoredValue != nil,
                    "absent readback makes the retained scope unavailable for writes")
            }
        }

        let replacement = WorkspaceSoundRule(
            id: rule.id,
            directory: WorkspaceDirectory(kind: .directory, path: "/fixture/another-project"),
            surfaces: [.codex],
            profile: WorkspaceSoundProfile(selectedPack: "workspace", volume: 0.7))
        config.workspaceRules = [replacement]
        let selection = EventSettingsWindowSelection(
            route: EventSettingsWindowRoute(scope: .workspace(rule.id)))
        expect(selection.requestDeletion(of: rule), "replacement readback requires a new request")
        let replacementRequest = selection.deletionPresentation.pending!
        expect(selection.consumeDeletion(replacementRequest), "replacement request consumes once")
        _ = selection.finishDeletion(
            replacementRequest, succeeded: false, error: .publishedConflict(),
            configState: .operational(config))
        expect(
            selection.deletionPresentation.feedback
                == .failed(target, .publishedConflict(), .replaced)
                && selection.unavailableRequestedScopeStoredValue != nil,
            "same UUID rebound to another directory is disclosed as replacement")

        let refreshed = EventSettingsWindowSelection(
            route: EventSettingsWindowRoute(scope: .workspace(rule.id)))
        expect(refreshed.requestDeletion(of: rule), "unreadable conflict starts from fresh request")
        let refreshRequest = refreshed.deletionPresentation.pending!
        expect(refreshed.consumeDeletion(refreshRequest), "unreadable conflict consumes once")
        _ = refreshed.finishDeletion(
            refreshRequest, succeeded: false, error: .publishedConflict(),
            configState: .unwritable(reason: "fixture"))
        refreshed.refreshDeletionReadback(configState: .operational(config))
        expect(
            refreshed.deletionPresentation.feedback
                == .failed(target, .publishedConflict(), .replaced)
                && refreshed.unavailableRequestedScopeStoredValue != nil,
            "explicit reload updates conflict evidence and blocks replacement under the old scope")

        let successful = EventSettingsWindowSelection(
            route: EventSettingsWindowRoute(scope: .workspace(rule.id)))
        expect(successful.requestDeletion(of: rule), "successful attempt requires a fresh request")
        let successRequest = successful.deletionPresentation.pending!
        expect(successful.consumeDeletion(successRequest), "success consumes captured target")
        expect(
            successful.finishDeletion(
                successRequest, succeeded: true, error: nil,
                configState: .operational(deletionPresentationConfig(rule: rule)))
                && successful.route.scope == .global
                && successful.deletionPresentation.feedback == .succeeded(target)
                && successful.presentationState.focusTarget == .workspaceDeleteResult,
            "successful deletion selects Default Group and focuses its visible result")
    }

    #if DEBUG
    suite("workspace delete session: a deep-linked deletion returns to the Default Group") {
        withTempDirectory { root in
            let rule = deletionPresentationRule()
            let file = root.appendingPathComponent("config.json")
            let packs = root.appendingPathComponent("packs", isDirectory: true)
            for id in ["default", "workspace"] {
                writeFixture(
                    "{\"id\":\"\(id)\",\"name\":\"\(id)\",\"events\":{}}",
                    to: packs.appendingPathComponent("\(id)/manifest.json"))
            }
            try! JSONEncoder().encode(deletionPresentationConfig(rule: rule)).write(to: file)
            let model = PanelConfigController(
                configFile: file, lockFile: root.appendingPathComponent("config.lock"),
                environment: makeAudioImportEnvironment(userPacksDirectory: packs))
            let fixture = SettingsPresentationFixtures.generalLogin(
                route: .events(scope: .workspace(rule.id), event: .stop),
                workspaceRules: [rule], eventSettingsModel: model)
            let selection = fixture.eventSettingsSelection
            expect(
                fixture.session.state.routeResolution.failure == nil
                    && selection.route.scope == .workspace(rule.id),
                "the live settings session must accept the Workspace deep link")
            expect(selection.requestDeletion(of: rule), "request captures the deep-linked rule")
            let request = selection.deletionPresentation.pending!
            expect(selection.consumeDeletion(request), "confirmation consumes exactly once")
            let succeeded = model.changeWorkspace(.remove(request.target))
            expect(succeeded, "the normal config writer must remove the requested rule")
            let selectedDefault = selection.finishDeletion(
                request, succeeded: succeeded, error: model.workspaceError,
                configState: model.configState)
            if selectedDefault { model.selectSoundScope(.global) }
            expect(
                selectedDefault && selection.route.scope == .global
                    && fixture.session.state.routeResolution.failure == nil
                    && selection.deletionPresentation.feedback == .succeeded(request.target)
                    && selection.presentationState.focusTarget == .workspaceDeleteResult,
                "config publication must not leave the shell on the removed deep link")
            model.reload()
            expect(
                fixture.session.state.routeResolution.failure == nil
                    && selection.route.scope == .global,
                "later config readback must keep the successful Default Group destination")
        }
    }

    suite("workspace scope handoff: explicit selection cannot mask an unavailable request") {
        let rule = deletionPresentationRule()
        let available = SettingsRouteAvailability(
            integrationSurfaces: Set(HostID.productVisibleCases.map(\.surfaceID)),
            eventScopes: [.global], soundScopes: [.global], soundPackIDs: [],
            events: Set(Event.allCases))
        for selectsDefault in [false, true] {
            let fixture = SettingsPresentationFixtures.generalLogin(
                route: .events(scope: .workspace(rule.id), event: .stop),
                workspaceRules: [rule])
            if selectsDefault {
                fixture.eventSettingsSelection.select(EventSettingsWindowRoute(scope: .global))
            }
            fixture.session.replaceAvailabilityForTesting(available)
            expect(
                (fixture.session.state.routeResolution.failure == nil) == selectsDefault,
                "removing the original target keeps failure unless the user already selected Default Group"
            )
        }

        let fixture = SettingsPresentationFixtures.generalLogin(
            route: .events(scope: .workspace(rule.id), event: .stop),
            workspaceRules: [rule])
        let missingScope = PanelSoundScopeID.workspace(UUID())
        let rejectedRoute = SettingsRoute.events(scope: missingScope, event: .stop)
        _ = fixture.session.send(.route(rejectedRoute))
        let rejectedResolution = fixture.session.state.routeResolution
        expect(rejectedResolution.failure != nil, "an unknown Workspace request must be rejected")
        fixture.eventSettingsSelection.select(EventSettingsWindowRoute(scope: .global))
        expect(
            fixture.session.state.routeResolution == rejectedResolution,
            "a retained child cannot replace the failure for a different requested Workspace")
    }

    suite("workspace delete mounted Events: confirmation and failure survive unavailable details") {
        let rule = deletionPresentationRule()
        let fixture = SettingsPresentationFixtures.generalLogin(
            route: .destination(.eventsAndSounds), workspaceRules: [rule])
        let selection = fixture.eventSettingsSelection
        selection.select(EventSettingsWindowRoute(scope: .workspace(rule.id)))
        fixture.eventSettingsModel.selectSoundScope(.workspace(rule.id))
        _ = NSApplication.shared
        SettingsMountRecorder.reset()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_240, height: 820),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let hostingView = NSHostingView(rootView: SettingsRootView(session: fixture.session))
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        hostingView.layoutSubtreeIfNeeded()
        expect(
            SettingsMountRecorder.identifiers.contains("settings.destination.events-and-sounds")
                && SettingsMountRecorder.identifiers.contains("workspace.remove"),
            "production Events destination and Workspace delete button must be mounted")

        expect(selection.requestDeletion(of: rule), "mounted view receives captured request")
        let confirmationDeadline = Date().addingTimeInterval(1)
        while window.attachedSheet == nil && window.sheets.isEmpty
            && Date() < confirmationDeadline
        {
            hostingView.layoutSubtreeIfNeeded()
            _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.03))
        }
        expect(
            window.attachedSheet != nil || !window.sheets.isEmpty,
            "mounted production view must present native confirmation")
        selection.cancelDeletion()
        hostingView.layoutSubtreeIfNeeded()
        _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.03))
        expect(selection.deletionPresentation.pending == nil, "mounted cancellation clears request")

        expect(selection.requestDeletion(of: rule), "a new request can be confirmed")
        let request = selection.deletionPresentation.pending!
        expect(selection.consumeDeletion(request), "test consumes the same captured request")
        _ = selection.finishDeletion(
            request, succeeded: false, error: .staleRule,
            configState: .operational(ClaudioConfig(selectedPack: "default")))
        expect(
            selection.unavailableRequestedScopeStoredValue != nil,
            "stale target remains selected but becomes unwritable")
        SettingsMountRecorder.reset()
        for _ in 0..<3 {
            hostingView.layoutSubtreeIfNeeded()
            _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.03))
        }
        expect(
            SettingsMountRecorder.identifiers.contains("workspace.delete.failure"),
            "typed deletion failure stays mounted when details are no longer writable")
        window.close()
        withExtendedLifetime((window, hostingView)) {}
    }
    #endif
}

private func deletionPresentationRule() -> WorkspaceSoundRule {
    WorkspaceSoundRule(
        directory: WorkspaceDirectory(kind: .directory, path: "/fixture/project"),
        surfaces: [.codex],
        profile: WorkspaceSoundProfile(selectedPack: "workspace", volume: 0.7))
}

private func deletionPresentationConfig(rule: WorkspaceSoundRule) -> ClaudioConfig {
    var config = ClaudioConfig(selectedPack: "default")
    config.workspaceRules = [rule]
    return config
}

/// Opt-in key-window regression. Run with system Keyboard navigation off to exercise the
/// focus proxy used when native Buttons are not in the system key-view loop.
@MainActor
func runWorkspaceDeletionFocusSuites() async {
    await suite("workspace delete native focus: cancel restores an activatable remove button") {
        print("  System Keyboard navigation: \(NSApp.isFullKeyboardAccessEnabled ? "on" : "off")")
        let rule = deletionPresentationRule()
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
