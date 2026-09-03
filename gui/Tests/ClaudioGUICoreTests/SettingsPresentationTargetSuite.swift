import AppKit
import ClaudioGUICore
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
                && settings.dependencies.sorted() == expectedDependencies
                && settings.resourcesCount == 0,
            "SwiftPM graph 必须恰有一个 Settings target、五个精确 direct dependencies 且零资源")
        expect(
            appTarget.dependencies.filter { $0 == "ClaudioSettingsPresentation" }.count == 1
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
                    !$0.dependencies.contains("ClaudioSettingsPresentation")
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
                && !model.contains("import AppKit")
                && !model.contains("import ServiceManagement")
                && !model.contains("SMAppService")
                && !model.contains("SMLoginItemSetEnabled"),
            "Login model 必须保持纯 presentation，不得泄漏 system adapter")
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
            let currentHead = delivery.range(
                of: "settingsPresentationSession.state.pendingAnnouncement"),
            let post = delivery.range(of: "announceBasicSettingsUpdate(sentence)"),
            let acknowledgement = delivery.range(of: "acknowledgeAnnouncement")
        else {
            expect(false, "必须能完整解析 Settings semantic announcement native delivery")
            return
        }

        expect(
            subscription.contains("scheduleSettingsPresentationAnnouncementDelivery()")
                && !subscription.contains("acknowledgeAnnouncement"),
            "$state synchronous sink 只能调度，不能在 @Published willSet 内 post/ack")
        expect(
            scheduler.contains("settingsPresentationAnnouncementDeliveryScheduled")
                && scheduler.contains("DispatchQueue.main.async"),
            "native delivery 必须延后一轮 MainActor，并用单一 in-flight 标记去重")
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
            id: SettingsPresentationAnnouncement.ID(rawValue: announcement.id.rawValue + 1),
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
        var synchronouslyAcknowledgedIDs: [SettingsPresentationAnnouncement.ID] = []
        let cancellable = session.$state.sink { state in
            MainActor.assumeIsolated {
                guard let announcement = state.pendingAnnouncement else { return }
                synchronouslyAcknowledgedIDs.append(announcement.id)
                session.acknowledgeAnnouncement(id: announcement.id, didPost: true)
            }
        }

        expect(session.perform(.openLoginItemsSettings) == .unavailable, "先产生一条真实 debt")
        expect(
            synchronouslyAcknowledgedIDs.map(\.rawValue) == [1]
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
            return nil
        }
        let resources = target["resources"] as? [Any] ?? []
        return DumpedSettingsPackageTarget(
            name: name,
            dependencies: dependencies,
            resourcesCount: resources.count)
    }
}
