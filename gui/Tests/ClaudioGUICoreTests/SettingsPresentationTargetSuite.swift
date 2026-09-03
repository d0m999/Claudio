import AppKit
import ClaudioGUICore
import ClaudioSettingsPresentation
import Foundation
import SwiftUI

@MainActor
func runSettingsPresentationTargetSuites() {
    suite("Settings presentation target：依赖方向、资源与导入边界固定") {
        let root = guiTestRepositoryRoot()
        let packageURL = root.appendingPathComponent("gui/Package.swift")
        let appURL = root.appendingPathComponent("gui/Sources/ClaudioGUI/ClaudioGUIApp.swift")
        let suiteURL = root.appendingPathComponent(
            "gui/Tests/ClaudioGUICoreTests/SettingsPresentationTargetSuite.swift")
        guard let package = try? String(contentsOf: packageURL, encoding: .utf8),
            let app = try? String(contentsOf: appURL, encoding: .utf8),
            let suiteSource = try? String(contentsOf: suiteURL, encoding: .utf8)
        else {
            expect(false, "读不到 Package、production composition 或 target suite")
            return
        }

        expect(
            package.contains("name: \"ClaudioSettingsPresentation\"")
                && package.contains("\"ClaudioSettingsPresentation\","),
            "Package 必须声明 ClaudioSettingsPresentation 并让 composition roots 直接依赖")
        expect(
            package.contains("\"ClaudioLocalization\"")
                && package.contains("\"ClaudioGUICore\"")
                && package.contains("\"ClaudioGUIComponents\"")
                && package.contains("\"SoundPacksWindow\"")
                && package.contains(".product(name: \"ClaudioCore\", package: \"helper\")"),
            "Settings target 必须直接声明五个既有下游依赖")
        expect(
            app.contains("import ClaudioSettingsPresentation")
                && suiteSource.contains("import ClaudioSettingsPresentation"),
            "production 与 compiled harness 必须 import 同一 Settings presentation module")
    }

    suite("Settings presentation target：共享 slider 与纯 Login model 已迁到正确 owner") {
        let root = guiTestRepositoryRoot()
        let componentURL = root.appendingPathComponent(
            "gui/Sources/ClaudioGUIComponents/SharedMasterVolumeSlider.swift")
        let oldSliderURL = root.appendingPathComponent(
            "gui/Sources/ClaudioGUI/SharedMasterVolumeSlider.swift")
        let modelURL = root.appendingPathComponent(
            "gui/Sources/ClaudioSettingsPresentation/LoginItemSettingsModel.swift")

        expect(
            FileManager.default.fileExists(atPath: componentURL.path)
                && !FileManager.default.fileExists(atPath: oldSliderURL.path),
            "SharedMasterVolumeSlider 必须由 Components 拥有且旧定义消失")
        guard let model = try? String(contentsOf: modelURL, encoding: .utf8) else {
            expect(false, "LoginItemSettingsModel 必须位于 Settings presentation target")
            return
        }
        expect(
            model.contains("final class LoginItemSettingsModel")
                && !model.contains("import AppKit")
                && !model.contains("import ServiceManagement")
                && !model.contains("SMAppService")
                && !model.contains("SMLoginItemSetEnabled"),
            "Login model 必须保持纯 presentation，不得泄漏 system adapter")
    }
}

@MainActor
func runSettingsPresentationSliceSuites() {
    suite("Settings presentation slice：非可选依赖与 Login 失败/重试形成同一 session") {
        let preferences = ClaudioPreferences(defaults: UserDefaults())
        var registration = LoginItemRegistrationState.disabled
        var shouldFail = true
        var requests: [Bool] = []
        let login = LoginItemSettingsModel(
            adapter: makeLoginItemServiceAdapter(
                status: { registration },
                setEnabled: { enabled in
                    requests.append(enabled)
                    if shouldFail {
                        throw LoginItemOperationFailureReason.systemRejected
                    }
                    registration = enabled ? .requiresApproval : .disabled
                    return registration
                }))
        var platformActions: [SettingsPlatformAction] = []
        let session = SettingsPresentationSession(
            dependencies: SettingsPresentationDependencies(
                preferences: preferences,
                loginItemSettings: login),
            actions: SettingsPresentationActions { action in
                platformActions.append(action)
                return .performed
            })

        expect(
            session.state.loginItemRegistration == .disabled
                && session.state.language == preferences.language,
            "session 初始投影必须来自两个必填 owner，而不是 placeholder")
        session.setLoginItemEnabled(true)
        expect(
            requests == [true]
                && session.state.loginItemRegistration == .disabled
                && session.state.loginItemFailure?.reason == .systemRejected,
            "失败必须保留旧系统事实并在同一 presentation state 可见")
        shouldFail = false
        session.retryLoginItemOperation()
        expect(
            requests == [true, true]
                && session.state.loginItemRegistration == .requiresApproval
                && session.state.loginItemFailure == nil,
            "重试必须重复精确意图并采用 adapter 重读的系统事实")

        expect(
            session.perform(.openLoginItemsSettings) == .performed
                && session.perform(.openCalendarPrivacySettings) == .performed
                && platformActions == [.openLoginItemsSettings, .openCalendarPrivacySettings],
            "两个 Settings-only system effect 必须走穷尽 typed dispatcher")
    }

    suite("Settings presentation announcement：稳定 ID 只接受 exact-head 成功确认") {
        let preferences = ClaudioPreferences(defaults: UserDefaults())
        let login = LoginItemSettingsModel(
            adapter: makeLoginItemServiceAdapter(
                status: { .disabled },
                setEnabled: { enabled in enabled ? .enabled : .disabled }))
        let session = SettingsPresentationSession(
            dependencies: SettingsPresentationDependencies(
                preferences: preferences,
                loginItemSettings: login),
            actions: SettingsPresentationActions { _ in .unavailable })

        expect(session.perform(.openLoginItemsSettings) == .unavailable, "typed result 必须无损返回")
        guard let announcement = session.state.pendingAnnouncement else {
            expect(false, "不可用 platform action 必须产生语义 announcement debt")
            return
        }
        session.acknowledgeAnnouncement(id: announcement.id, didPost: false)
        expect(
            session.state.pendingAnnouncement?.id == announcement.id,
            "native post 失败不得消费 announcement debt")
        session.acknowledgeAnnouncement(
            id: SettingsPresentationAnnouncement.ID(rawValue: announcement.id.rawValue + 1),
            didPost: true)
        expect(
            session.state.pendingAnnouncement?.id == announcement.id,
            "陈旧 acknowledgement 不得消费当前 head")
        session.acknowledgeAnnouncement(id: announcement.id, didPost: true)
        expect(session.state.pendingAnnouncement == nil, "只有 exact-head 成功回执可消费 debt")
    }

    suite("Settings presentation root：compiled harness 挂载 production General/Login slice") {
        let preferences = ClaudioPreferences(defaults: UserDefaults())
        let session = SettingsPresentationSession(
            dependencies: SettingsPresentationDependencies(
                preferences: preferences,
                loginItemSettings: LoginItemSettingsModel(
                    adapter: makeLoginItemServiceAdapter(
                        status: { .requiresApproval },
                        setEnabled: { _ in .requiresApproval }))),
            actions: SettingsPresentationActions { _ in .performed })
        let root = SettingsRootView(session: session)
        let hostingView = NSHostingView(rootView: root)
        hostingView.frame = NSRect(x: 0, y: 0, width: 620, height: 520)
        hostingView.layoutSubtreeIfNeeded()

        expect(
            hostingView.fittingSize.width > 0 && hostingView.fittingSize.height > 0,
            "production SettingsRootView 必须可由真实 SwiftUI/AppKit seam 挂载")
        expect(
            SettingsPresentationAccessibilityID.root == "settings.presentation.root"
                && SettingsPresentationAccessibilityID.loginItemToggle
                    == "settings.general.login-item.toggle",
            "root 与真实 Login 控件必须暴露稳定、非 test-only 的 accessibility identity")
    }

    suite("Settings presentation fixture：DEBUG seam 随机隔离且只暴露真实 owner") {
        withTempDirectory { sentinelRoot in
            let sentinel = sentinelRoot.appendingPathComponent("user-path-sentinel")
            let sentinelBytes = Data("do-not-touch".utf8)
            try? sentinelBytes.write(to: sentinel)

            let first = SettingsPresentationFixtures.generalLogin(
                language: .english,
                loginItemRegistration: .requiresApproval,
                platformActionResult: .performed)
            let second = SettingsPresentationFixtures.generalLogin()
            let temporaryRoot = FileManager.default.temporaryDirectory.standardizedFileURL.path

            expect(
                first.temporaryRoot.standardizedFileURL.path.hasPrefix(temporaryRoot)
                    && first.temporaryRoot != second.temporaryRoot,
                "每个 fixture 必须使用唯一的系统临时根")
            expect(
                first.session.state.loginItemRegistration == .requiresApproval
                    && first.session.perform(.openCalendarPrivacySettings) == .performed
                    && first.actionRecorder.actions == [.openCalendarPrivacySettings],
                "fixture 必须通过真实 session 与 recording typed action seam 工作")
            expect(
                first.soundPacksEditor.presentation.mode != .inactive,
                "fixture 必须只交付 SoundPacksEditorOwner/presentation seam")

            let hostingView = NSHostingView(rootView: first.rootView)
            hostingView.frame = NSRect(x: 0, y: 0, width: 620, height: 520)
            hostingView.layoutSubtreeIfNeeded()
            expect(
                hostingView.fittingSize.width > 0 && hostingView.fittingSize.height > 0,
                "fixture 必须挂载同一个 production SettingsRootView")
            expect(
                (try? Data(contentsOf: sentinel)) == sentinelBytes,
                "fixture construction 与 mount 不得访问 supplied sentinel user path")
        }
    }

    suite("Settings presentation fixture：整文件 DEBUG 且无 raw/user-path 逃逸") {
        let fixtureURL = guiTestRepositoryRoot().appendingPathComponent(
            "gui/Sources/ClaudioSettingsPresentation/SettingsPresentationFixtures.swift")
        guard let fixture = try? String(contentsOf: fixtureURL, encoding: .utf8) else {
            expect(false, "读不到 SettingsPresentationFixtures.swift")
            return
        }
        expect(
            fixture.hasPrefix("#if DEBUG\n") && fixture.hasSuffix("#endif\n"),
            "fixture source 必须从首行到末行由 DEBUG guard 包住")
        expect(
            fixture.contains("SoundPacksEditorOwner.stateGalleryFixture(")
                && !fixture.contains("SoundPacksWindowModel")
                && !fixture.contains("homeDirectoryForCurrentUser")
                && !fixture.contains("~/.claudio")
                && !fixture.contains("/Users/"),
            "fixture 必须复用 owner factory，且不得暴露 raw model 或用户路径")
    }
}
