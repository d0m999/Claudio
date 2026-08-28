import ClaudioGUICore
import Foundation

@MainActor
func runFocusQuietPolicySuites() {
    suite("Focus policy：默认关闭，只有显式 toggle-on 请求权限") {
        withTemporaryFocusDefaults { defaults in
            let system = FocusQuietSystemBox(
                FocusQuietSystemState(authorization: .notRequested, isFocused: nil))
            var requestCount = 0
            var publications: [Bool] = []
            let controller = FocusQuietPolicyController(
                defaults: defaults,
                readSystemState: { system.state },
                requestAuthorization: { completion in
                    requestCount += 1
                    system.state = FocusQuietSystemState(
                        authorization: .authorized, isFocused: true)
                    completion(system.state)
                },
                publish: { focusActive, _ in
                    publications.append(focusActive)
                    return true
                },
                now: { Date(timeIntervalSince1970: 1_000) })

            expect(!controller.presentation.isEnabled, "Focus 策略必须默认关闭")
            expect(requestCount == 0, "初始化不得请求权限")
            controller.refresh()
            expect(requestCount == 0, "未显式开启时 refresh 不得请求权限")

            controller.setEnabled(true)
            expect(requestCount == 1, "显式 toggle-on 且未请求时必须恰好请求一次")
            expect(
                controller.presentation
                    == FocusQuietPresentation(
                        isEnabled: true,
                        authorization: .authorized,
                        currentReason: .focusActive,
                        publicationFailed: false),
                "授权完成且 Focus active 必须发布生效状态")
            expect(publications.last == true, "Focus active 必须发布 true 原因")
            expect(defaults.bool(forKey: FocusQuietPolicyController.defaultsKey), "策略必须持久化")

            controller.setEnabled(false)
            expect(requestCount == 1, "关闭策略不得再次请求权限")
            expect(publications.last == false, "关闭策略必须立即发布 false 清理旧状态")
            expect(
                controller.presentation.currentReason == .policyDisabled,
                "关闭状态必须显示当前原因")
        }
    }

    suite("Focus policy：拒绝、限制、撤权与 observer failure 都 fail safe 发布 false") {
        withTemporaryFocusDefaults { defaults in
            defaults.set(true, forKey: FocusQuietPolicyController.defaultsKey)
            let system = FocusQuietSystemBox(
                FocusQuietSystemState(authorization: .denied, isFocused: nil))
            var publications: [Bool] = []
            let controller = FocusQuietPolicyController(
                defaults: defaults,
                readSystemState: { system.state },
                requestAuthorization: { _ in
                    expect(false, "已保存 enabled 的 app-lifetime 恢复不得弹授权框")
                },
                publish: { active, _ in
                    publications.append(active)
                    return true
                })

            expect(controller.presentation.authorization == .denied, "拒绝状态必须可见")
            expect(
                controller.presentation.currentReason == .permissionRequired,
                "拒绝时必须显示权限原因")
            expect(publications.last == false, "拒绝时 automatic playback 必须 fail safe")

            system.state = FocusQuietSystemState(authorization: .restricted, isFocused: nil)
            controller.refresh()
            expect(controller.presentation.authorization == .restricted, "限制状态必须可见")
            expect(publications.last == false, "限制状态不得静默")

            system.state = FocusQuietSystemState(authorization: .authorized, isFocused: nil)
            controller.refresh()
            expect(
                controller.presentation.currentReason == .observerFailure,
                "已授权但无布尔事实必须显示 observer failure")
            expect(publications.last == false, "observer failure 不得制造无限静默")

            system.state = FocusQuietSystemState(authorization: .authorized, isFocused: false)
            controller.refresh()
            expect(
                controller.presentation.currentReason == .noDynamicQuiet,
                "Focus inactive 必须显示当前无静默原因")
            expect(publications.last == false, "Focus inactive 必须恢复 automatic playback")
        }
    }

    suite("Focus policy：snapshot 写失败可见且不冒充 publication 成功") {
        withTemporaryFocusDefaults { defaults in
            defaults.set(true, forKey: FocusQuietPolicyController.defaultsKey)
            let controller = FocusQuietPolicyController(
                defaults: defaults,
                readSystemState: {
                    FocusQuietSystemState(authorization: .authorized, isFocused: true)
                },
                requestAuthorization: { _ in },
                publish: { _, _ in false })
            expect(controller.presentation.currentReason == .focusActive, "系统事实仍应如实投影")
            expect(controller.presentation.publicationFailed, "写失败必须是独立可见状态")
        }
    }

    suite("Notifications wiring：单一 Focus 策略、内部事件路由与 manual preview 边界") {
        guard
            let view = focusQuietSource("gui/Sources/ClaudioGUI/SettingsWindowView.swift"),
            let owner = focusQuietSource(
                "gui/Sources/ClaudioGUI/FocusQuietSystemObserver.swift"),
            let settingsController = focusQuietSource(
                "gui/Sources/ClaudioGUI/SettingsWindowController.swift"),
            let preview = focusQuietSource(
                "gui/Sources/ClaudioGUIComponents/AudioPreviewPlayer.swift"),
            let play = focusQuietSource("helper/Sources/ClaudioCore/Play.swift"),
            let devBundle = focusQuietSource("scripts/dev-bundle.sh"),
            let release = focusQuietSource(".github/workflows/release.yml"),
            let entitlements = focusQuietSource("gui/ClaudioGUI.entitlements")
        else {
            expect(false, "缺少 Focus policy production wiring 源文件")
            return
        }

        expect(
            view.contains("settings.notifications.focus-toggle")
                && view.contains("focusQuietPolicy.setEnabled($0)")
                && !view.contains("ForEach(Event.allCases)"),
            "通知页只能提供一条 Focus 策略，不能复制五个 Event 开关")
        expect(
            view.contains("model.request(.destination(.eventsAndSounds))")
                && view.contains("settings.notifications.open-events"),
            "通知页必须通过 typed internal route 前往事件页")
        expect(
            settingsController.contains("private let focusQuietObserver")
                && settingsController.contains("FocusQuietSystemObserver()")
                && owner.contains("Timer.scheduledTimer(")
                && owner.contains("NSApplication.didBecomeActiveNotification")
                && !view.contains("onDisappear")
                && !view.contains("invalidate()"),
            "Focus observer 必须属于 retained app-lifetime owner，页面离开不得停止")
        expect(
            owner.contains("import UserNotifications")
                && owner.contains("notificationCenter.requestAuthorization(options: [.alert])")
                && owner.contains("center.requestAuthorization")
                && owner.contains("getNotificationSettings"),
            "只有显式 toggle-on closure 才能请求 UserNotifications 与 Focus 两项必要授权")
        expect(
            play.contains("dynamicQuietDecision(environment:")
                && play.contains("case dynamicQuiet(event: Event)")
                && !preview.contains("DynamicQuiet")
                && !preview.contains("dynamicQuiet"),
            "Dynamic Quiet 只能进入 helper automatic playback，manual preview 保持独立")
        expect(
            devBundle.contains("NSFocusStatusUsageDescription")
                && release.contains("NSFocusStatusUsageDescription")
                && entitlements.contains(
                    "com.apple.developer.usernotifications.communication")
                && devBundle.contains("--entitlements \"$repo_root/gui/ClaudioGUI.entitlements\"")
                && release.contains("--entitlements gui/ClaudioGUI.entitlements"),
            "开发与发布 bundle 都必须声明用途并把 Communication Notifications capability 签入 app")
    }
}

@MainActor
private func withTemporaryFocusDefaults(_ body: (UserDefaults) -> Void) {
    let suiteName = "FocusQuietPolicySuite.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    defer { defaults.removePersistentDomain(forName: suiteName) }
    body(defaults)
}

private func focusQuietSource(_ relativePath: String) -> String? {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    return try? String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
}

@MainActor
private final class FocusQuietSystemBox {
    var state: FocusQuietSystemState

    init(_ state: FocusQuietSystemState) {
        self.state = state
    }
}
