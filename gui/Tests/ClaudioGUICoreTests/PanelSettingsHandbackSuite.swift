import AppKit
import ClaudioGUIComponents
import ClaudioGUICore
import Foundation

@MainActor
func runPanelSettingsHandbackSuites() {
    suite("Settings 活动 sheet 持有焦点时，Panel 关闭应还给该 sheet") {
        _ = NSApplication.shared
        let settings = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled], backing: .buffered, defer: false)
        let sheet = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 120),
            styleMask: [.titled], backing: .buffered, defer: false)
        let unrelated = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.titled], backing: .buffered, defer: false)
        settings.isReleasedWhenClosed = false
        sheet.isReleasedWhenClosed = false
        unrelated.isReleasedWhenClosed = false
        settings.orderFront(nil)
        settings.beginSheet(sheet)
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))

        expect(sheet.sheetParent === settings, "回归场景必须是真实附属于 Settings 的 sheet")
        expect(settingsWindowOwnsKeyFocus(settings, keyWindow: sheet), "sheet key 焦点属于 Settings")
        expect(settingsWindowRestorationTarget(settings) === sheet, "关闭 Panel 应恢复当前 sheet")
        expect(!settingsWindowOwnsKeyFocus(settings, keyWindow: nil), "无 key window 时不得恢复 Settings")
        expect(
            !settingsWindowOwnsKeyFocus(settings, keyWindow: unrelated), "其他窗口不得被误认为 Settings sheet"
        )
        settings.endSheet(sheet)
        expect(settingsWindowRestorationTarget(settings) === settings, "sheet 关闭后恢复主窗口")
        expect(settingsWindowOwnsKeyFocus(settings, keyWindow: settings), "主窗口 key 焦点仍属于 Settings")
        sheet.close()
        settings.close()
        unrelated.close()
    }

    suite("Panel 关闭只恢复打开前占据焦点的 Settings") {
        var handback = PanelSettingsHandback()
        handback.begin(settingsWasForeground: true)
        expect(handback.takeSettingsRestoration(), "从前台 Settings 打开 Panel 应恢复 Settings")
        expect(!handback.takeSettingsRestoration(), "一次关闭只消费一次 Settings 恢复资格")

        handback.begin(settingsWasForeground: false)
        expect(!handback.takeSettingsRestoration(), "后台可见 Settings 不得抢走原 app 焦点")

        handback.begin(settingsWasForeground: true)
        handback.begin(settingsWasForeground: false)
        expect(!handback.takeSettingsRestoration(), "新一次打开必须覆盖上次的焦点状态")
    }

    suite("Panel 与 Settings 的原生窗口焦点记录和归还接入同一决策") {
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
        guard let showStart = menu.range(of: "private func showPopover()") else {
            expect(false, "读不到 Panel 打开路径")
            return
        }
        let show = menu[showStart.lowerBound...]
        let capture = show.range(of: "panelSettingsHandback.begin(")?.lowerBound
        let keyWindowInput = show.range(
            of: "settingsWasForeground: settingsWindowController.hasForegroundKeyWindow")?
            .lowerBound
        let presentation = show.range(of: "popover.show(relativeTo:")?.lowerBound
        expect(
            capture != nil && keyWindowInput != nil && presentation != nil
                && capture! < keyWindowInput! && keyWindowInput! < presentation!,
            "必须在 Panel 展示前记录 Settings 是否持有前台 key 焦点")

        guard let closeStart = menu.range(of: "func popoverDidClose(_ notification: Notification)")
        else {
            expect(false, "读不到 Panel 关闭回调")
            return
        }
        let close = menu[closeStart.lowerBound...]
        let active = close.range(of: "guard NSApp.isActive")?.lowerBound
        let decision = close.range(of: "panelSettingsHandback.takeSettingsRestoration()")?
            .lowerBound
        let restorationGuard = close.range(of: "if restoreSettings &&")?.lowerBound
        let restore = close.range(
            of: "settingsWindowController.restoreVisibleWindowAfterPopoverClose()")?.lowerBound
        let external = close.range(of: "activateHandbackApplication(previous)")?.lowerBound
        expect(
            active != nil && decision != nil && restorationGuard != nil && restore != nil
                && external != nil && decision! < active! && active! < restorationGuard!
                && restorationGuard! < restore! && restore! < external!,
            "Panel 主动关闭时，只在打开前 Settings 占据焦点且仍可恢复时归还它；否则交还原 app")

        guard
            let restoration = settings.range(
                of: "func restoreVisibleWindowAfterPopoverClose() -> Bool")
        else {
            expect(false, "Settings owner 必须提供可见窗口的原生焦点恢复")
            return
        }
        let restorationCode = settings[restoration.lowerBound...]
        expect(
            settings.contains("guard NSApp.isActive, let window else { return false }")
                && settings.contains(
                    "settingsWindowOwnsKeyFocus(window, keyWindow: NSApp.keyWindow)")
                && settings.contains("settingsWindowRestorationTarget(window)")
                && restorationCode.contains("window.isVisible")
                && restorationCode.contains("!window.isMiniaturized")
                && restorationCode.contains("window.isOnActiveSpace")
                && restorationCode.contains("target.isVisible")
                && restorationCode.contains("target.isOnActiveSpace")
                && restorationCode.contains("target.makeKeyAndOrderFront(nil)"),
            "Settings owner 必须将可见且仍活动的 sheet 恢复为 key window")
    }
}
