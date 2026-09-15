import AppKit
import ClaudioCore
import ClaudioGUICore
import ClaudioSettingsPresentation
import SwiftUI

@MainActor
func runAICueDescriptionSuites() {
    suite("AI 提示音原生描述控件：生成时不挂载可编辑输入器") {
        for scenario in [PreviewFixtures.AICueGalleryScenario.generating, .editing] {
            let fixture = SettingsPresentationFixtures.generalLogin(
                route: .events(scope: .surface(.workBuddy), event: .stop),
                aiCueScenario: scenario)
            let hostingView = NSHostingView(rootView: SettingsRootView(session: fixture.session))
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1_240, height: 820),
                styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = hostingView
            hostingView.layoutSubtreeIfNeeded()
            let inputs = aiCueNativeTextInputs(in: hostingView)
            if scenario == .generating {
                expect(inputs.isEmpty, "生成中的生产树必须移除 NSTextView，不只禁用其 SwiftUI 外壳")
            } else {
                expect(inputs.contains(where: \.isEditable), "编辑态必须实际挂载可编辑输入器，不能空树假通过")
            }
            window.close()
            withExtendedLifetime((window, hostingView)) {}
        }
    }
}

/// Opt-in key-window gate: unlike the default mounting suite, this starts AppKit's event loop
/// and yields the main actor so production focus lifecycle tasks can actually execute.
@MainActor
func runAICueDescriptionFocusSuites() async {
    await suite("AI 提示音原生描述焦点：初次挂载与取消后可直接编辑") {
        let scenarios: [(PreviewFixtures.AICueGalleryScenario, UInt16?, String)] = [
            (.editing, nil, ""),
            (.generating, 49, " "),
            (.generating, 36, "\r"),
        ]
        for (scenario, keyCode, characters) in scenarios {
            let fixture = SettingsPresentationFixtures.generalLogin(aiCueScenario: scenario)
            let hostingView = NSHostingView(rootView: SettingsRootView(session: fixture.session))
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1_240, height: 820),
                styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = hostingView
            window.center()
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            _ = fixture.session.send(.windowPhaseChanged(.key))
            defer { window.orderOut(nil); window.close() }
            hostingView.layoutSubtreeIfNeeded()
            try? await Task.sleep(nanoseconds: 100_000_000)
            expect(window.isKeyWindow, "焦点门禁必须在真正的 key window 上执行")
            let originalDescription = fixture.aiCueViewModel.soundDescription
            if let keyCode {
                expect(aiCueNativeTextInputs(in: hostingView).isEmpty, "生成态没有可写输入器")
                expect(fixture.aiCueViewModel.phase == .generating, "按键前必须仍处于生成态")
                expect(
                    aiCueSendKey(to: window, keyCode: 11, characters: "b"),
                    "必须经由真实窗口派发非激活按键")
                expect(fixture.aiCueViewModel.phase == .generating, "非激活按键不能取消生成")
                expect(
                    aiCueSendKey(
                        to: window, keyCode: 49, characters: " ", modifiers: .command),
                    "必须经由真实窗口派发带修饰键的空格")
                expect(fixture.aiCueViewModel.phase == .generating, "Command-Space 不能取消生成")
                expect(
                    aiCueSendKey(to: window, keyCode: keyCode, characters: characters),
                    "必须经由真实窗口派发取消激活按键")
            }
            let deadline = Date(timeIntervalSinceNow: 1)
            while Date() < deadline,
                !aiCueNativeTextInputs(in: hostingView).contains(where: {
                    $0.isEditable && window.firstResponder === $0
                })
            {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            expect(
                fixture.aiCueViewModel.phase == .editing,
                "\(scenario.rawValue)/\(keyCode ?? 0)：键盘取消必须恢复编辑态")
            expect(
                fixture.aiCueViewModel.soundDescription == originalDescription,
                "取消必须保留原描述")
            expect(
                aiCueNativeTextInputs(in: hostingView).contains(where: {
                    $0.isEditable && window.firstResponder === $0
                }),
                "\(scenario.rawValue)：不点击输入框也必须让真实 NSTextView 成为 first responder")
            if let editor = aiCueNativeTextInputs(in: hostingView).first(where: {
                $0.isEditable && window.firstResponder === $0
            }) {
                editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
                expect(
                    aiCueSendKey(to: window, keyCode: 49, characters: " "),
                    "编辑态必须经由真实窗口派发空格")
                let inputDeadline = Date(timeIntervalSinceNow: 1)
                while Date() < inputDeadline,
                    fixture.aiCueViewModel.soundDescription == originalDescription
                {
                    try? await Task.sleep(nanoseconds: 10_000_000)
                }
                expect(
                    fixture.aiCueViewModel.soundDescription == originalDescription + " ",
                    "恢复编辑后空格必须写入描述，不能被取消激活处理器吞掉")
            }
        }
    }
}

@MainActor
private func aiCueSendKey(
    to window: NSWindow,
    keyCode: UInt16,
    characters: String,
    modifiers: NSEvent.ModifierFlags = []
) -> Bool {
    for type in [NSEvent.EventType.keyDown, .keyUp] {
        guard
            let event = NSEvent.keyEvent(
                with: type,
                location: .zero,
                modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                characters: characters,
                charactersIgnoringModifiers: characters,
                isARepeat: false,
                keyCode: keyCode)
        else { return false }
        window.sendEvent(event)
    }
    return true
}

@MainActor
private func aiCueNativeTextInputs(in view: NSView) -> [NSTextView] {
    (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap { aiCueNativeTextInputs(in: $0) }
}
