import Foundation

@MainActor
func runSettingsPresentationLifecycleSuites() {
    suite("Settings session deletion contract：route、phase 与 lifecycle 只有一个 owner") {
        let root = guiTestRepositoryRoot()
        let sessionURL = root.appendingPathComponent(
            "gui/Sources/ClaudioSettingsPresentation/SettingsPresentationSession.swift")
        let stateURL = root.appendingPathComponent(
            "gui/Sources/ClaudioSettingsPresentation/SettingsPresentationState.swift")
        let rootViewURL = root.appendingPathComponent(
            "gui/Sources/ClaudioSettingsPresentation/SettingsRootView.swift")
        let controllerURL = root.appendingPathComponent(
            "gui/Sources/ClaudioGUI/SettingsWindowController.swift")
        let navigationURL = root.appendingPathComponent(
            "gui/Sources/ClaudioGUICore/SettingsNavigation.swift")
        guard
            let session = try? String(contentsOf: sessionURL, encoding: .utf8),
            let state = try? String(contentsOf: stateURL, encoding: .utf8),
            let rootView = try? String(contentsOf: rootViewURL, encoding: .utf8),
            let controller = try? String(contentsOf: controllerURL, encoding: .utf8),
            let navigation = try? String(contentsOf: navigationURL, encoding: .utf8)
        else {
            expect(false, "读不到 Settings session/controller/navigation ownership source")
            return
        }

        expect(
            session.contains("func send(")
                && session.contains("SettingsPresentationCommand")
                && state.contains("SettingsRouteResolution")
                && state.contains("SettingsWindowPhase")
                && state.contains("focusDebt"),
            "session state/command 必须共同拥有 typed route、window phase 与 focus debt")
        expect(
            rootView.contains("settingsPresentationSession.send(.route(")
                && !rootView.contains("SettingsWindowPresentationModel")
                && !rootView.contains("model.request("),
            "production root 必须只通过 session command 路由，不得保留第二 navigation owner")

        let forbiddenControllerOwners = [
            "SettingsWindowPresentationModel",
            "SoundPacksEditorOwner",
            "PanelConfigController",
            "EventSettingsWindowSelection",
            "HostIntegrationPresentationStore",
            "IntegrationDestinationModel",
            "AICueGenerationViewModel",
            "settingsSoundPackShellProjections(",
        ]
        expect(
            forbiddenControllerOwners.allSatisfy { !controller.contains($0) },
            "AppKit controller 不得持有 destination model/publisher 或 raw Sound Pack owner")
        expect(
            !navigation.contains("SettingsWindowPresentationModel<")
                && !navigation.contains("pendingHandback"),
            "ClaudioGUICore 只能保留纯 route/revision reducer，旧泛型 handback wrapper 必须删除")
    }
}
