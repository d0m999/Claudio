import Foundation

@MainActor
func runPanelSettingsHandbackSuites() {
    suite("Panel 与 Settings 同时存在：收起 Panel 优先恢复可见 Settings") {
        let root = guiTestRepositoryRoot()
        let menuURL = root.appendingPathComponent(
            "gui/Sources/ClaudioGUI/MenuBarController.swift")
        let settingsURL = root.appendingPathComponent(
            "gui/Sources/ClaudioGUI/SettingsWindowController.swift")
        guard
            let menuSource = try? String(contentsOf: menuURL, encoding: .utf8),
            let settingsSource = try? String(contentsOf: settingsURL, encoding: .utf8)
        else {
            expect(false, "读不到 Panel 与 Settings 的原生窗口 owner")
            return
        }

        let menu = strippingComments(menuSource).codeWithoutStringLiterals
        let settings = strippingComments(settingsSource).codeWithoutStringLiterals
        guard let closeStart = menu.range(of: "func popoverDidClose(_ notification: Notification)")
        else {
            expect(false, "读不到 Panel 关闭回调")
            return
        }
        let close = menu[closeStart.lowerBound...]
        let active = close.range(of: "guard NSApp.isActive")?.lowerBound
        let restore = close.range(
            of: "settingsWindowController.restoreVisibleWindowAfterPopoverClose()")?.lowerBound
        let external = close.range(of: "activateHandbackApplication(previous)")?.lowerBound
        expect(
            active != nil && restore != nil && external != nil
                && active! < restore! && restore! < external!,
            "Panel 主动关闭时，只有 claudi0 仍 active 才先恢复可见 Settings；之后才可交还外部 app")

        guard
            let restoration = settings.range(
                of: "func restoreVisibleWindowAfterPopoverClose() -> Bool")
        else {
            expect(false, "Settings owner 必须提供可见窗口的原生焦点恢复")
            return
        }
        let restorationCode = settings[restoration.lowerBound...]
        expect(
            restorationCode.contains("window.isVisible")
                && restorationCode.contains("!window.isMiniaturized")
                && restorationCode.contains("window.isOnActiveSpace")
                && restorationCode.contains("window.makeKeyAndOrderFront(nil)"),
            "仅可见、未最小化的 Settings 窗口能在 Panel 关闭时重新成为 key window")
    }
}
