import AppKit
import ClaudioGUICore
import ClaudioSettingsPresentation
import Foundation
import SwiftUI

@MainActor
func runSettingsRootInteractionSuites() {
    #if DEBUG
    suite("Settings mounted root：sidebar 整行命中与行外安全区走真实 AppKit event route") {
        let probes: [(SettingsDestination, CGFloat)] = [
            (.integrations, 0.08),
            (.notifications, 0.5),
            (.display, 0.92),
        ]
        for (destination, fraction) in probes {
            let fixture = SettingsPresentationFixtures.generalLogin(
                availability: PreviewFixtures.settingsRouteAvailability)
            let probe = SettingsRootNativeProbe(session: fixture.session)
            expect(
                probe.clickSidebar(destination, horizontalFraction: fraction),
                "settings.sidebar.\(destination.rawValue) 必须能构造真实 mouse down/up")
            expect(
                fixture.session.state.routeResolution.destination == destination,
                "sidebar 行 \(fraction) 位置必须命中同一个 typed destination")
            probe.close()
        }

        let fixture = SettingsPresentationFixtures.generalLogin(
            availability: PreviewFixtures.settingsRouteAvailability)
        let probe = SettingsRootNativeProbe(session: fixture.session)
        expect(
            probe.clickOutsideSidebarRow(.integrations),
            "sidebar 行外测试点必须能投递真实 mouse down/up")
        expect(
            fixture.session.state.routeResolution.destination == .general,
            "sidebar 行外安全区不得误触 destination")
        probe.close()
    }

    suite("Settings mounted root：方向键/Escape modifier 与 raw key capability 边界") {
        let fixture = SettingsPresentationFixtures.generalLogin(
            availability: PreviewFixtures.settingsRouteAvailability)
        SettingsRootInteractionRecorder.reset()
        SettingsMountRecorder.reset()
        let probe = SettingsRootNativeProbe(session: fixture.session)
        expect(
            probe.clickSidebar(.general, horizontalFraction: 0.5),
            "必须先通过真实 mouse event 聚焦当前 sidebar row")
        let deliveredDown = probe.sendKey(keyCode: 125, characters: "\u{F701}")
        let rawDownWasHandled =
            fixture.session.state.routeResolution.destination == .integrations
        if !rawDownWasHandled {
            expect(
                SettingsRootInteractionRecorder.invokeMove(.next, from: .general),
                "无 Full Keyboard Access 时必须调用 mounted modifier 注册的同一 move handler")
        }
        expect(
            deliveredDown
                && fixture.session.state.routeResolution.destination == .integrations
                && SettingsMountRecorder.identifiers.contains(
                    "settings.interaction.sidebar.general"),
            "Down raw event 必须可投递；无 Full Keyboard Access 时同一 mounted modifier driver 仍切 typed destination"
        )
        let deliveredUp = probe.sendKey(keyCode: 126, characters: "\u{F700}")
        let rawUpWasHandled = fixture.session.state.routeResolution.destination == .general
        if !rawUpWasHandled {
            expect(
                SettingsRootInteractionRecorder.invokeMove(.previous, from: .integrations),
                "Up fallback 必须调用 mounted modifier 注册的同一 move handler")
        }
        expect(
            deliveredUp && fixture.session.state.routeResolution.destination == .general,
            "Up raw event 必须可投递；compiled modifier driver 必须回到上一个 typed destination")

        expect(probe.clickContent(x: 360, yFromTop: 190), "必须先通过真实 mouse event 聚焦 content")
        let deliveredEscape = probe.sendKey(keyCode: 53, characters: "\u{1b}")
        if SettingsRootInteractionRecorder.lastExitTarget == nil {
            expect(
                SettingsRootInteractionRecorder.invokeExit(),
                "无稳定 raw keyboard focus 时必须调用 mounted modifier 注册的同一 exit handler")
        }
        expect(
            deliveredEscape
                && SettingsRootInteractionRecorder.lastExitTarget == .sidebar(.general)
                && SettingsMountRecorder.identifiers.contains("settings.interaction.exit"),
            "Escape raw event 必须可投递，且 mounted exit handler 必须把当前 destination 映射回 sidebar focus")
        probe.close()
        SettingsRootInteractionRecorder.stopRecording()
    }

    suite("Settings mounted root：真实 sidebar Button 与 Login toggle 触发 owner") {
        let toggleFixture = SettingsPresentationFixtures.generalLogin(
            loginItemRegistration: .disabled,
            availability: PreviewFixtures.settingsRouteAvailability)
        let toggleProbe = SettingsRootNativeProbe(session: toggleFixture.session)
        expect(
            toggleProbe.clickContentGridUntil {
                toggleFixture.session.state.loginItemRegistration == .enabled
            },
            "真实 Login toggle 必须接受 NSWindow mouse route")
        expect(
            toggleFixture.session.state.loginItemRegistration == .enabled,
            "Login toggle 必须经 session/model seam 更新 projection")
        toggleProbe.close()
    }
    #endif
}

@MainActor
final class SettingsRootNativeProbe {
    private let window: NSWindow
    private let hostingView: NSHostingView<SettingsRootView>
    private let size = NSSize(width: 1_240, height: 820)
    private var eventNumber = 1

    init(session: SettingsPresentationSession) {
        _ = NSApplication.shared
        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        hostingView = NSHostingView(rootView: SettingsRootView(session: session))
        hostingView.frame = NSRect(origin: .zero, size: size)
        window.contentView = hostingView
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        refresh()
    }

    var hasAttachedSheet: Bool {
        refresh()
        return window.attachedSheet != nil || !window.sheets.isEmpty
    }

    func clickSidebar(
        _ destination: SettingsDestination,
        horizontalFraction: CGFloat
    ) -> Bool {
        guard let index = SettingsDestination.allCases.firstIndex(of: destination), index <= 6
        else { return false }
        let sidebarWidth = CGFloat(
            settingsSidebarWidth(windowWidth: size.width, interfaceTextSize: .standard))
        let x = 12 + (sidebarWidth - 24) * horizontalFraction
        let yFromTop = 72.5 + CGFloat(index) * 39
        return click(windowPoint: NSPoint(x: x, y: size.height - yFromTop))
    }

    func clickOutsideSidebarRow(_ destination: SettingsDestination) -> Bool {
        guard let index = SettingsDestination.allCases.firstIndex(of: destination), index <= 6
        else { return false }
        let sidebarWidth = CGFloat(
            settingsSidebarWidth(windowWidth: size.width, interfaceTextSize: .standard))
        let yFromTop = 72.5 + CGFloat(index) * 39
        return click(windowPoint: NSPoint(x: sidebarWidth + 4, y: size.height - yFromTop))
    }

    func clickContent(x: CGFloat, yFromTop: CGFloat) -> Bool {
        click(windowPoint: NSPoint(x: x, y: size.height - yFromTop))
    }

    func clickContentGridUntil(_ condition: @MainActor () -> Bool) -> Bool {
        if condition() { return true }
        for yFromTop in stride(from: CGFloat(260), through: 500, by: 12) {
            for x in stride(from: CGFloat(300), through: 760, by: 16) {
                guard clickContent(x: x, yFromTop: yFromTop) else { return false }
                if condition() { return true }
            }
        }
        return false
    }

    func sendKey(keyCode: UInt16, characters: String) -> Bool {
        guard
            let down = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                characters: characters,
                charactersIgnoringModifiers: characters,
                isARepeat: false,
                keyCode: keyCode),
            let up = NSEvent.keyEvent(
                with: .keyUp,
                location: .zero,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                characters: characters,
                charactersIgnoringModifiers: characters,
                isARepeat: false,
                keyCode: keyCode)
        else { return false }
        window.sendEvent(down)
        window.sendEvent(up)
        refresh()
        return true
    }

    func close() {
        window.orderOut(nil)
        window.close()
    }

    private func click(windowPoint: NSPoint) -> Bool {
        guard
            let down = NSEvent.mouseEvent(
                with: .leftMouseDown,
                location: windowPoint,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: eventNumber,
                clickCount: 1,
                pressure: 1),
            let up = NSEvent.mouseEvent(
                with: .leftMouseUp,
                location: windowPoint,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: eventNumber + 1,
                clickCount: 1,
                pressure: 1)
        else { return false }
        eventNumber += 2
        window.sendEvent(down)
        window.sendEvent(up)
        refresh()
        return true
    }

    private func refresh() {
        hostingView.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
    }
}
