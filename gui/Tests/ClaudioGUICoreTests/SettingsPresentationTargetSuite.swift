import AppKit
import ClaudioGUICore
import ClaudioLocalization
import ClaudioSettingsPresentation
import Combine
import Foundation
import SwiftUI

@MainActor
func runSettingsPresentationTargetSuites() {
    suite("Settings presentation target：依赖方向、资源与导入边界固定") {
        let root = guiTestRepositoryRoot()
        let appURL = root.appendingPathComponent("gui/Sources/ClaudioGUI/ClaudioGUIApp.swift")
        let suiteURL = root.appendingPathComponent(
            "gui/Tests/ClaudioGUICoreTests/SettingsPresentationTargetSuite.swift")
        guard let targets = dumpedSettingsPackageTargets(repositoryRoot: root),
            let settings = targets.first(where: { $0.name == "ClaudioSettingsPresentation" }),
            let appTarget = targets.first(where: { $0.name == "ClaudioGUI" }),
            let harnessTarget = targets.first(where: { $0.name == "claudio-gui-tests" }),
            let app = try? String(contentsOf: appURL, encoding: .utf8),
            let suiteSource = try? String(contentsOf: suiteURL, encoding: .utf8)
        else {
            expect(false, "读不到 SwiftPM dump、production composition 或 target suite")
            return
        }
        let expectedDependencies = [
            "ClaudioCore",
            "ClaudioGUIComponents",
            "ClaudioGUICore",
            "ClaudioLocalization",
            "SoundPacksWindow",
        ]

        expect(
            targets.filter { $0.name == "ClaudioSettingsPresentation" }.count == 1
                && settings.dependencyCount == expectedDependencies.count
                && !settings.hasUnparsedDependencies
                && settings.dependencies.sorted() == expectedDependencies
                && settings.resourcesCount == 0,
            "SwiftPM graph 必须恰有一个 Settings target、五个精确 direct dependencies 且零资源")
        expect(
            !appTarget.hasUnparsedDependencies
                && !harnessTarget.hasUnparsedDependencies
                && appTarget.dependencies.filter { $0 == "ClaudioSettingsPresentation" }.count == 1
                && harnessTarget.dependencies.filter {
                    $0 == "ClaudioSettingsPresentation"
                }.count == 1,
            "ClaudioGUI 与 harness 必须分别且仅一次 direct-depend Settings target")
        let lowerTargetNames = [
            "ClaudioLocalization", "ClaudioGUICore", "ClaudioGUIComponents", "SoundPacksWindow",
        ]
        expect(
            targets.filter { lowerTargetNames.contains($0.name) }.count == lowerTargetNames.count
                && targets.filter { lowerTargetNames.contains($0.name) }.allSatisfy {
                    !$0.hasUnparsedDependencies
                        && !$0.dependencies.contains("ClaudioSettingsPresentation")
                },
            "四个下层 target 必须全部存在且零回指，保持 graph acyclic")
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
                && !model.contains("ObservableObject")
                && !model.contains("@Published")
                && !model.contains("import Combine")
                && !model.contains("import AppKit")
                && !model.contains("import ServiceManagement")
                && !model.contains("SMAppService")
                && !model.contains("SMLoginItemSetEnabled"),
            "Login model 必须保持纯 presentation，不得泄漏 system adapter")
    }

    suite("Settings presentation deletion：caller 持有 focus，session 持有 Login 发布") {
        let root = guiTestRepositoryRoot()
        let paths = [
            "component": "gui/Sources/ClaudioGUIComponents/SharedMasterVolumeSlider.swift",
            "panel": "gui/Sources/ClaudioGUI/MasterVolumeRow.swift",
            "events": "gui/Sources/ClaudioGUI/EventSettingsWindowView.swift",
            "session":
                "gui/Sources/ClaudioSettingsPresentation/SettingsPresentationSession.swift",
            "gallery": "gui/Sources/ClaudioGUI/StateGalleryView.swift",
        ]
        var code: [String: String] = [:]
        for (name, path) in paths {
            let url = root.appendingPathComponent(path)
            guard let source = try? String(contentsOf: url, encoding: .utf8) else {
                expect(false, "读不到 \(path)")
                return
            }
            code[name] = strippingComments(source).codeWithoutStringLiterals
        }
        guard let component = code["component"], let panel = code["panel"],
            let events = code["events"], let session = code["session"],
            let gallery = code["gallery"],
            let refresh = settingsBracedBlock(after: "package func refreshLoginItem", in: session),
            let setEnabled = settingsBracedBlock(
                after: "package func setLoginItemEnabled", in: session),
            let retry = settingsBracedBlock(
                after: "package func retryLoginItemOperation", in: session)
        else {
            expect(false, "必须能解析 slider/Login deletion wiring")
            return
        }
        let flatComponent = collapsingWhitespace(component)
        let flatPanel = collapsingWhitespace(panel)
        let flatEvents = collapsingWhitespace(events)

        expect(
            flatComponent.contains("package struct SharedMasterVolumeSlider: View")
                && !flatComponent.contains("SharedMasterVolumeSlider<")
                && !component.contains("FocusState<")
                && !component.contains("focusedTarget")
                && !component.contains("focusIdentity")
                && !component.contains(".focused("),
            "共享 slider 必须非泛型且不拥有 caller 的 focus identity")
        expect(
            flatPanel.contains(
                "onCommit: onCommit) .focused(focusedTarget, equals: .masterVolume)")
                && flatEvents.contains(
                    "onCommit: onCommit ) .focused(focusedTarget, equals: .masterVolume)"),
            "Panel 与 Events caller 必须各自把原 exact focus identity 接回共享 slider")
        expect(
            !session.contains("loginItemSettings.$projection")
                && !session.contains("Set<AnyCancellable>")
                && session.contains("preferenceCancellable: AnyCancellable?"),
            "session 的固定依赖不得保留冗余 Login Combine stream 或 cancellable collection")
        for (name, command) in [
            ("refresh", refresh), ("setEnabled", setEnabled), ("retry", retry),
        ] {
            guard let invocation = command.range(of: "dependencies.loginItemSettings."),
                let adoption = command.range(
                    of: "loginProjection = dependencies.loginItemSettings.projection")
            else {
                expect(false, "\(name) 必须在 command 后同步采纳 Login projection")
                continue
            }
            expect(
                invocation.lowerBound < adoption.lowerBound,
                "\(name) 必须先执行 model command，再同步采纳同一 model projection")
        }
        expect(
            !gallery.contains("@StateObject private var loginItemSettings")
                && !gallery.contains("_loginItemSettings = StateObject"),
            "DEBUG gallery 已由 session 强持有 Login model，不得再保留第二个 StateObject owner")
    }

    suite("Settings presentation deletion：语义 announcement 唯一拥有本地化与 UInt64 head") {
        let root = guiTestRepositoryRoot()
        let announcementURL = root.appendingPathComponent(
            "gui/Sources/ClaudioSettingsPresentation/SettingsPresentationAnnouncement.swift")
        let sectionURL = root.appendingPathComponent(
            "gui/Sources/ClaudioSettingsPresentation/LoginItemSettingsSection.swift")
        let controllerURL = root.appendingPathComponent(
            "gui/Sources/ClaudioGUI/SettingsWindowController.swift")
        guard
            let announcementSource = try? String(
                contentsOf: announcementURL, encoding: .utf8),
            let sectionSource = try? String(contentsOf: sectionURL, encoding: .utf8),
            let controllerSource = try? String(contentsOf: controllerURL, encoding: .utf8)
        else {
            expect(false, "读不到 announcement/section/controller source")
            return
        }
        let announcement = strippingComments(announcementSource).codeWithoutStringLiterals
        let section = strippingComments(sectionSource).codeWithoutStringLiterals
        let controller = strippingComments(controllerSource).codeWithoutStringLiterals
        guard
            let delivery = settingsBracedBlock(
                after: "private func deliverPendingSettingsPresentationAnnouncement",
                in: controller)
        else {
            expect(false, "解析不到 Settings announcement delivery")
            return
        }

        expect(
            announcement.contains("package let id: UInt64")
                && !announcement.contains("Identifiable")
                && !announcement.contains("RawRepresentable")
                && !announcement.contains("struct ID"),
            "exact-head 只需要 UInt64，不得保留无 consumer 的 collection identity witness")
        expect(
            announcement.contains("package func localizedSentence(")
                && section.contains(".localizedSentence(")
                && delivery.contains("announcement.meaning.localizedSentence(")
                && !delivery.contains("settingsGeneralLoginItem")
                && !section.contains("switch session.state.loginItemRegistration")
                && !section.contains("switch failure.reason"),
            "status、failure 与 native announcement 必须复用 Meaning 的单一本地化 owner")
    }

    suite("Settings native announcement：延迟后重验 current head 且窗口恢复会重试") {
        let controllerURL = guiTestRepositoryRoot().appendingPathComponent(
            "gui/Sources/ClaudioGUI/SettingsWindowController.swift")
        guard let controller = try? String(contentsOf: controllerURL, encoding: .utf8) else {
            expect(false, "读不到 SettingsWindowController native wiring")
            return
        }
        let scanned = strippingComments(controller)
        let code = scanned.codeWithoutStringLiterals
        guard scanned.unmodeledConstructs.isEmpty,
            let subscription = settingsBracedBlock(
                after: "settingsPresentationCancellable = settingsPresentationSession.$state",
                in: code),
            let scheduler = settingsBracedBlock(
                after: "private func scheduleSettingsPresentationAnnouncementDelivery",
                in: code),
            let delivery = settingsBracedBlock(
                after: "private func deliverPendingSettingsPresentationAnnouncement",
                in: code),
            let showWindow = settingsBracedBlock(after: "func showWindow", in: code),
            let didBecomeKey = settingsBracedBlock(after: "func windowDidBecomeKey", in: code),
            let unlatch = showWindow.range(of: "isPresentingWindow = false"),
            let showRetry = showWindow.range(
                of: "scheduleSettingsPresentationAnnouncementDelivery()"),
            let deferredTurn = scheduler.range(of: "DispatchQueue.main.async"),
            let currentHead = delivery.range(
                of: "settingsPresentationSession.state.pendingAnnouncement"),
            let post = delivery.range(of: "announceBasicSettingsUpdate(sentence)"),
            let acknowledgement = delivery.range(of: "acknowledgeAnnouncement")
        else {
            expect(false, "必须能完整解析 Settings semantic announcement native delivery")
            return
        }

        expect(
            subscription.contains("guard state.pendingAnnouncement != nil")
                && subscription.contains("scheduleSettingsPresentationAnnouncementDelivery()")
                && !subscription.contains(".map(")
                && !subscription.contains(".removeDuplicates(")
                && !subscription.contains("acknowledgeAnnouncement"),
            "$state synchronous sink 必须直接读 emitted state，且只能调度、不能同步 post/ack")
        expect(
            scheduler.contains("settingsPresentationAnnouncementDeliveryScheduled")
                && !scheduler[..<deferredTurn.lowerBound].contains(
                    "settingsPresentationSession.state.pendingAnnouncement"),
            "scheduler 在 async 前只能去重，不得读取仍处于 @Published willSet 的旧 head")
        expect(
            delivery.contains("!isPresentingWindow")
                && delivery.contains("window.isVisible")
                && delivery.contains("window.isKeyWindow")
                && currentHead.lowerBound < post.lowerBound
                && post.lowerBound < acknowledgement.lowerBound,
            "实际 post 前必须重读 exact current head 与 key/visible window，成功后才能 ack")
        expect(
            unlatch.lowerBound < showRetry.lowerBound
                && didBecomeKey.contains("settingsPresentationSession.refreshLoginItem()")
                && didBecomeKey.contains("scheduleSettingsPresentationAnnouncementDelivery()"),
            "pre-key debt 必须在 showWindow 清 latch 后及真实 didBecomeKey 中显式重试")
    }
}

@MainActor
func runSettingsPresentationSliceSuites() {
    suite("Settings presentation announcement：语义在单一 owner 穷尽本地化") {
        let english = ClaudioAppLanguage.english
        let zhHans = ClaudioAppLanguage.zhHans
        let englishL10n = ClaudioL10n(language: english)
        let zhHansL10n = ClaudioL10n(language: zhHans)
        let cases: [(SettingsPresentationAnnouncement.Meaning, ClaudioL10nKey)] = [
            (.loginItemStatus(.disabled), .settingsGeneralLoginItem.disabled),
            (.loginItemStatus(.enabled), .settingsGeneralLoginItem.enabled),
            (.loginItemStatus(.requiresApproval), .settingsGeneralLoginItem.requiresApproval),
            (.loginItemStatus(.unavailable), .settingsGeneralLoginItem.unavailable),
            (
                .loginItemFailure(
                    LoginItemOperationFailure(
                        requestedEnabled: true, reason: .embeddedLoginItemMissing)),
                .settingsGeneralLoginItem.failureMissing
            ),
            (
                .loginItemFailure(
                    LoginItemOperationFailure(requestedEnabled: true, reason: .systemRejected)),
                .settingsGeneralLoginItem.failureEnable
            ),
            (
                .loginItemFailure(
                    LoginItemOperationFailure(requestedEnabled: false, reason: .systemRejected)),
                .settingsGeneralLoginItem.failureDisable
            ),
            (
                .platformAction(.openLoginItemsSettings, .unavailable),
                .settingsGeneralLoginItem.unavailable
            ),
            (
                .platformAction(.openCalendarPrivacySettings, .failed),
                .settingsNotificationsOpenCalendarPrivacy
            ),
        ]

        for (meaning, key) in cases {
            expect(
                meaning.localizedSentence(language: english) == englishL10n.text(key)
                    && meaning.localizedSentence(language: zhHans) == zhHansL10n.text(key),
                "每种 semantic announcement 必须在两种语言下映射到同一 catalog key")
        }
    }

    suite("Settings presentation slice：非可选依赖与 Login 失败/重试形成同一 session") {
        let preferences = ClaudioPreferences(defaults: UserDefaults())
        let adapterState = SettingsLoginAdapterState()
        let login = LoginItemSettingsModel(
            adapter: makeLoginItemServiceAdapter(
                status: { adapterState.registration },
                setEnabled: { enabled in
                    adapterState.requests.append(enabled)
                    if adapterState.shouldFail {
                        throw LoginItemOperationFailureReason.systemRejected
                    }
                    adapterState.registration = enabled ? .requiresApproval : .disabled
                    return adapterState.registration
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
        adapterState.registration = .requiresApproval
        session.refreshLoginItem()
        expect(
            session.state.loginItemRegistration == .requiresApproval
                && session.state.pendingAnnouncement?.meaning
                    == .loginItemStatus(.requiresApproval),
            "重获 key 后的 refresh 必须投影最新系统事实并留下语义 announcement debt")
        if let announcement = session.state.pendingAnnouncement {
            session.acknowledgeAnnouncement(id: announcement.id, didPost: true)
        }
        adapterState.registration = .disabled
        session.refreshLoginItem()
        if let announcement = session.state.pendingAnnouncement {
            session.acknowledgeAnnouncement(id: announcement.id, didPost: true)
        }
        session.setLoginItemEnabled(true)
        expect(
            adapterState.requests == [true]
                && session.state.loginItemRegistration == .disabled
                && session.state.loginItemFailure?.reason == .systemRejected,
            "失败必须保留旧系统事实并在同一 presentation state 可见")
        adapterState.shouldFail = false
        session.retryLoginItemOperation()
        expect(
            adapterState.requests == [true, true]
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
            id: announcement.id + 1,
            didPost: true)
        expect(
            session.state.pendingAnnouncement?.id == announcement.id,
            "陈旧 acknowledgement 不得消费当前 head")
        session.acknowledgeAnnouncement(id: announcement.id, didPost: true)
        expect(session.state.pendingAnnouncement == nil, "只有 exact-head 成功回执可消费 debt")
    }

    suite("Settings presentation announcement：同步 subscriber ack 后 projection 保持一致") {
        let session = SettingsPresentationSession(
            dependencies: SettingsPresentationDependencies(
                preferences: ClaudioPreferences(defaults: UserDefaults()),
                loginItemSettings: LoginItemSettingsModel(
                    adapter: makeLoginItemServiceAdapter(
                        status: { .disabled },
                        setEnabled: { enabled in enabled ? .enabled : .disabled }))),
            actions: SettingsPresentationActions { _ in .unavailable })
        var synchronouslyAcknowledgedIDs: [UInt64] = []
        let cancellable = session.$state.sink { state in
            MainActor.assumeIsolated {
                guard let announcement = state.pendingAnnouncement else { return }
                synchronouslyAcknowledgedIDs.append(announcement.id)
                session.acknowledgeAnnouncement(id: announcement.id, didPost: true)
            }
        }

        expect(session.perform(.openLoginItemsSettings) == .unavailable, "先产生一条真实 debt")
        expect(
            synchronouslyAcknowledgedIDs == [1]
                && session.state.pendingAnnouncement == nil
                && session.state.presentationRevision >= 2,
            "@Published willSet 内同步 ack 后 public projection 不得被外层 stale state 覆盖")
        cancellable.cancel()

        _ = session.perform(.openLoginItemsSettings)
        let replacedID = session.state.pendingAnnouncement?.id
        _ = session.perform(.openCalendarPrivacySettings)
        guard let current = session.state.pendingAnnouncement else {
            expect(false, "head replacement 后必须保留最新 debt")
            return
        }
        expect(
            replacedID != nil && current.id != replacedID
                && current.meaning
                    == .platformAction(.openCalendarPrivacySettings, .unavailable),
            "新 debt 必须以新稳定 ID 替换旧 head")
        if let replacedID {
            session.acknowledgeAnnouncement(id: replacedID, didPost: true)
        }
        expect(
            session.state.pendingAnnouncement?.id == current.id,
            "旧 head 的成功回执不得消费 replacement")
        session.acknowledgeAnnouncement(id: current.id, didPost: false)
        expect(
            session.state.pendingAnnouncement?.id == current.id,
            "post false 不得消费 exact current head")
        session.acknowledgeAnnouncement(id: current.id, didPost: true)
        expect(
            session.state.pendingAnnouncement == nil,
            "只有成功的 exact-current acknowledgement 才能清空最终 projection")
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

    #if DEBUG
    suite("Settings presentation fixture：DEBUG seam 随机隔离且只暴露真实 owner") {
        withTempDirectory { fixtureParent in
            let sentinel = fixtureParent.appendingPathComponent("user-path-sentinel")
            let sentinelBytes = Data("do-not-touch".utf8)
            try? sentinelBytes.write(to: sentinel)

            let first = SettingsPresentationFixtures.generalLogin(
                temporaryParent: fixtureParent,
                language: .english,
                loginItemRegistration: .requiresApproval,
                platformActionResult: .performed)
            let second = SettingsPresentationFixtures.generalLogin(
                temporaryParent: fixtureParent)

            expect(
                first.temporaryRoot.deletingLastPathComponent().standardizedFileURL
                    == fixtureParent.standardizedFileURL
                    && second.temporaryRoot.deletingLastPathComponent().standardizedFileURL
                        == fixtureParent.standardizedFileURL
                    && first.temporaryRoot != second.temporaryRoot,
                "每个 fixture 必须在 supplied parent 下使用不同 UUID child root")
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
            let secondHostingView = NSHostingView(rootView: second.rootView)
            secondHostingView.frame = NSRect(x: 0, y: 0, width: 620, height: 520)
            secondHostingView.layoutSubtreeIfNeeded()
            expect(
                hostingView.fittingSize.width > 0 && hostingView.fittingSize.height > 0
                    && secondHostingView.fittingSize.width > 0
                    && secondHostingView.fittingSize.height > 0,
                "两个隔离 fixture 都必须挂载同一个 production SettingsRootView")
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
                && fixture.contains(
                    "temporaryParent: URL = FileManager.default.temporaryDirectory")
                && !fixture.contains("SoundPacksWindowModel")
                && !fixture.contains("homeDirectoryForCurrentUser")
                && !fixture.contains("~/.claudio")
                && !fixture.contains("/Users/"),
            "fixture 必须复用 owner factory，且不得暴露 raw model 或用户路径")
    }
    #endif
}

@MainActor
private final class SettingsLoginAdapterState {
    var registration = LoginItemRegistrationState.disabled
    var shouldFail = true
    var requests: [Bool] = []
}

private func settingsBracedBlock(after marker: String, in source: String) -> String? {
    guard let markerRange = source.range(of: marker),
        let openingBrace = source[markerRange.upperBound...].firstIndex(of: "{")
    else {
        return nil
    }
    var depth = 0
    var index = openingBrace
    while index < source.endIndex {
        switch source[index] {
        case "{":
            depth += 1
        case "}":
            depth -= 1
            if depth == 0 {
                return String(source[openingBrace...index])
            }
        default:
            break
        }
        index = source.index(after: index)
    }
    return nil
}

private struct DumpedSettingsPackageTarget {
    let name: String
    let dependencies: [String]
    let dependencyCount: Int
    let hasUnparsedDependencies: Bool
    let resourcesCount: Int
}

private func dumpedSettingsPackageTargets(
    repositoryRoot: URL
) -> [DumpedSettingsPackageTarget]? {
    let output = Pipe()
    let errors = Pipe()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [
        "swift", "package", "dump-package", "--package-path",
        repositoryRoot.appendingPathComponent("gui", isDirectory: true).path,
    ]
    process.standardOutput = output
    process.standardError = errors
    do {
        try process.run()
    } catch {
        return nil
    }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == EXIT_SUCCESS,
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let targets = object["targets"] as? [[String: Any]]
    else {
        return nil
    }

    return targets.compactMap { target in
        guard let name = target["name"] as? String,
            let rawDependencies = target["dependencies"] as? [[String: Any]]
        else {
            return nil
        }
        let dependencies = rawDependencies.compactMap { dependency -> String? in
            if let byName = dependency["byName"] as? [Any] {
                return byName.first as? String
            }
            if let product = dependency["product"] as? [Any] {
                return product.first as? String
            }
            if let target = dependency["target"] as? [Any] {
                return target.first as? String
            }
            return nil
        }
        let resources = target["resources"] as? [Any] ?? []
        return DumpedSettingsPackageTarget(
            name: name,
            dependencies: dependencies,
            dependencyCount: rawDependencies.count,
            hasUnparsedDependencies: dependencies.count != rawDependencies.count,
            resourcesCount: resources.count)
    }
}
