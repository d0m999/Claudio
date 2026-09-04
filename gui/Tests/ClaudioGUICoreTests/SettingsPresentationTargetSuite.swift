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
            "events":
                "gui/Sources/ClaudioSettingsPresentation/EventSettingsWindowView.swift",
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
            let scanned = strippingComments(source)
            guard scanned.unmodeledConstructs.isEmpty else {
                expect(false, "\(path) 含 source audit 无法建模的构造")
                return
            }
            code[name] = scanned.codeWithoutStringLiterals
        }
        guard let component = code["component"], let panel = code["panel"],
            let events = code["events"], let session = code["session"],
            let gallery = code["gallery"],
            let panelSliderScope = settingsBracedBlock(
                after: "private var slider: some View", in: panel),
            let eventSliderScope = settingsBracedBlock(
                after: "private struct EventSettingsMasterVolumeControl: View", in: events),
            let refresh = settingsBracedBlock(after: "private func refreshLoginItem", in: session),
            let setEnabled = settingsBracedBlock(
                after: "private func setLoginItemEnabled", in: session),
            let retry = settingsBracedBlock(
                after: "private func retryLoginItemOperation", in: session)
        else {
            expect(false, "必须能解析 slider/Login deletion wiring")
            return
        }
        let flatComponent = collapsingWhitespace(component)
        let flatPanelSliderScope = collapsingWhitespace(panelSliderScope)
        let flatEventSliderScope = collapsingWhitespace(eventSliderScope)

        expect(
            flatComponent.contains("package struct SharedMasterVolumeSlider: View")
                && !flatComponent.contains("SharedMasterVolumeSlider<")
                && !component.contains("FocusState<")
                && !component.contains("focusedTarget")
                && !component.contains("focusIdentity")
                && !component.contains(".focused("),
            "共享 slider 必须非泛型且不拥有 caller 的 focus identity")
        for (name, scope) in [
            ("Panel", flatPanelSliderScope), ("Events", flatEventSliderScope),
        ] {
            guard let slider = scope.range(of: "SharedMasterVolumeSlider("),
                let focus = scope.range(of: ".focused(focusedTarget, equals: .masterVolume)")
            else {
                expect(false, "\(name) caller 必须同时包含 slider 与 exact focus identity")
                continue
            }
            expect(
                slider.lowerBound < focus.lowerBound,
                "\(name) caller 必须在共享 slider 后接回原 exact focus identity")
        }
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
        let announcementScan = strippingComments(announcementSource)
        let sectionScan = strippingComments(sectionSource)
        let controllerScan = strippingComments(controllerSource)
        guard announcementScan.unmodeledConstructs.isEmpty,
            sectionScan.unmodeledConstructs.isEmpty,
            controllerScan.unmodeledConstructs.isEmpty
        else {
            expect(false, "announcement/section/controller source audit 遇到无法建模的构造")
            return
        }
        let announcement = announcementScan.codeWithoutStringLiterals
        let section = sectionScan.codeWithoutStringLiterals
        let controller = controllerScan.codeWithoutStringLiterals
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
            let subscriptionBody = settingsBracedBlock(
                after: "settingsPresentationCancellable = session.$state",
                in: code),
            let subscriptionPrefix = settingsSinkStatementPrefix(
                after: "settingsPresentationCancellable = session.$state",
                in: code),
            let scheduler = settingsBracedBlock(
                after: "private func scheduleSettingsPresentationAnnouncementDelivery",
                in: code),
            let delivery = settingsBracedBlock(
                after: "private func deliverPendingSettingsPresentationAnnouncement",
                in: code),
            let showWindow = settingsBracedBlock(after: "func showWindow", in: code),
            let didBecomeKey = settingsBracedBlock(after: "func windowDidBecomeKey", in: code),
            let makeKey = showWindow.range(of: "presentedWindow.makeKeyAndOrderFront"),
            let showRetry = showWindow.range(
                of: "scheduleSettingsPresentationAnnouncementDelivery()"),
            let deferredTurn = scheduler.range(of: "DispatchQueue.main.async"),
            let latchGuard = scheduler.range(
                of: "guard !settingsPresentationAnnouncementDeliveryScheduled"),
            let latchSet = scheduler.range(
                of: "settingsPresentationAnnouncementDeliveryScheduled = true"),
            let deferredBody = settingsBracedBlock(
                after: "DispatchQueue.main.async", in: scheduler),
            let latchReset = deferredBody.range(
                of: "settingsPresentationAnnouncementDeliveryScheduled = false"),
            let deferredDelivery = deferredBody.range(
                of: "deliverPendingSettingsPresentationAnnouncement()"),
            let currentHead = delivery.range(
                of: "settingsPresentationSession.state.pendingAnnouncement"),
            let post = delivery.range(of: "NSAccessibility.post("),
            let acknowledgement = delivery.range(of: ".acknowledgeAnnouncement")
        else {
            expect(false, "必须能完整解析 Settings semantic announcement native delivery")
            return
        }

        expect(
            subscriptionBody.contains("state.pendingAnnouncement != nil")
                && subscriptionBody.contains("scheduleSettingsPresentationAnnouncementDelivery()")
                && !subscriptionBody.contains("acknowledgeAnnouncement")
                && !subscriptionPrefix.contains(".map(")
                && !subscriptionPrefix.contains(".removeDuplicates("),
            "$state synchronous sink 必须直接读 emitted state，且只能调度、不能同步 post/ack")
        expect(
            latchGuard.lowerBound < latchSet.lowerBound
                && latchSet.lowerBound < deferredTurn.lowerBound
                && latchReset.lowerBound < deferredDelivery.lowerBound
                && !scheduler[..<deferredTurn.lowerBound].contains(
                    "settingsPresentationSession.state.pendingAnnouncement"),
            "scheduler 必须先 guard/set latch，deferred 内先清 latch 再 delivery，且 async 前不读旧 head")
        expect(
            delivery.contains("settingsPresentationSession.state.windowPhase == .key")
                && delivery.contains("window.isVisible")
                && delivery.contains("window.isKeyWindow")
                && currentHead.lowerBound < post.lowerBound
                && post.lowerBound < acknowledgement.lowerBound,
            "实际 post 前必须重读 exact current head 与 key/visible window，成功后才能 ack")
        expect(
            makeKey.lowerBound < showRetry.lowerBound
                && didBecomeKey.contains(".windowPhaseChanged(.key)")
                && didBecomeKey.contains("scheduleSettingsPresentationAnnouncementDelivery()"),
            "pre-key debt 必须在 showWindow 结束及真实 didBecomeKey 中显式重试")
    }

    suite("Settings native announcement source audit：operator prefix 解析自证有牙") {
        let direct = """
            settingsPresentationCancellable = settingsPresentationSession.$state
                .sink { state in consume(state) }
            """
        let staleChain = """
            settingsPresentationCancellable = settingsPresentationSession.$state
                .map(\\.pendingAnnouncement)
                .removeDuplicates()
                .sink { state in consume(state) }
            """
        guard
            let directPrefix = settingsSinkStatementPrefix(
                after: "settingsPresentationCancellable = settingsPresentationSession.$state",
                in: direct),
            let stalePrefix = settingsSinkStatementPrefix(
                after: "settingsPresentationCancellable = settingsPresentationSession.$state",
                in: staleChain)
        else {
            expect(false, "sink statement prefix 解析失败必须 fail closed")
            return
        }
        expect(
            !directPrefix.contains(".map(") && !directPrefix.contains(".removeDuplicates("),
            "direct sink 正控不得伪造旧 operator chain")
        expect(
            stalePrefix.contains(".map(") && stalePrefix.contains(".removeDuplicates("),
            "旧 map/removeDuplicates chain 必须落入被审计的 sink statement prefix")

        let coordinatedScheduler = """
            {
                guard !settingsPresentationAnnouncementDeliveryScheduled else { return }
                settingsPresentationAnnouncementDeliveryScheduled = true
                DispatchQueue.main.async {
                    settingsPresentationAnnouncementDeliveryScheduled = false
                    deliverPendingSettingsPresentationAnnouncement()
                }
            }
            """
        let missingSetScheduler = """
            {
                guard !settingsPresentationAnnouncementDeliveryScheduled else { return }
                DispatchQueue.main.async {
                    settingsPresentationAnnouncementDeliveryScheduled = false
                    deliverPendingSettingsPresentationAnnouncement()
                }
            }
            """
        let lateResetScheduler = """
            {
                guard !settingsPresentationAnnouncementDeliveryScheduled else { return }
                settingsPresentationAnnouncementDeliveryScheduled = true
                DispatchQueue.main.async {
                    deliverPendingSettingsPresentationAnnouncement()
                    settingsPresentationAnnouncementDeliveryScheduled = false
                }
            }
            """
        expect(
            settingsAnnouncementSchedulerHasLatchContract(coordinatedScheduler)
                && !settingsAnnouncementSchedulerHasLatchContract(missingSetScheduler)
                && !settingsAnnouncementSchedulerHasLatchContract(lateResetScheduler),
            "latch 审计必须接受正确顺序，并拒绝缺 set 或 delivery 后才 reset 的 mutation")
    }

    suite("Settings production tree：九个 typed destination 由唯一 root 穷尽挂载") {
        let root = guiTestRepositoryRoot()
        let presentationDirectory = root.appendingPathComponent(
            "gui/Sources/ClaudioSettingsPresentation", isDirectory: true)
        let executableDirectory = root.appendingPathComponent(
            "gui/Sources/ClaudioGUI", isDirectory: true)
        let migratedFiles = [
            "SettingsRootView.swift",
            "EventSettingsWindowView.swift",
            "EventSettingsAICueView.swift",
            "IntegrationsSettingsDestinationView.swift",
            "UsageSettingsView.swift",
            "ShortcutSettingsView.swift",
            "AboutSettingsView.swift",
            "SettingsVisualComponents.swift",
            "EventSettingsWindowSelection.swift",
            "SettingsStateGalleryView.swift",
        ]
        let legacyFiles = migratedFiles.map { filename in
            filename == "SettingsRootView.swift" ? "SettingsWindowView.swift" : filename
        }
        expect(
            migratedFiles.allSatisfy {
                FileManager.default.fileExists(
                    atPath: presentationDirectory.appendingPathComponent($0).path)
            },
            "完整 production Settings view tree 必须由 ClaudioSettingsPresentation module 拥有")
        expect(
            legacyFiles.allSatisfy {
                !FileManager.default.fileExists(
                    atPath: executableDirectory.appendingPathComponent($0).path)
            },
            "ClaudioGUI 不得保留迁移后 source 或 duplicate SettingsWindowView")

        let rootURL = presentationDirectory.appendingPathComponent("SettingsRootView.swift")
        let controllerURL = executableDirectory.appendingPathComponent(
            "SettingsWindowController.swift")
        let galleryURL = executableDirectory.appendingPathComponent("StateGalleryView.swift")
        guard let rootSource = try? String(contentsOf: rootURL, encoding: .utf8),
            let controllerSource = try? String(contentsOf: controllerURL, encoding: .utf8),
            let gallerySource = try? String(contentsOf: galleryURL, encoding: .utf8)
        else {
            expect(false, "读不到 production Settings root 或 controller wiring")
            return
        }
        let rootScan = strippingComments(rootSource)
        let controllerScan = strippingComments(controllerSource)
        let galleryScan = strippingComments(gallerySource)
        guard rootScan.unmodeledConstructs.isEmpty,
            controllerScan.unmodeledConstructs.isEmpty,
            galleryScan.unmodeledConstructs.isEmpty,
            let routeSlot = settingsBracedBlock(after: "private var routeSlot", in: rootScan.code)
        else {
            expect(false, "production Settings root source audit 必须 fail closed")
            return
        }
        let normalizedRouteSlot = collapsingWhitespace(routeSlot)
        let normalizedController = collapsingWhitespace(controllerScan.code)
        let normalizedGallery = collapsingWhitespace(galleryScan.code)
        let destinationCases = [
            ".general", ".integrations", ".eventsAndSounds", ".notifications", ".display",
            ".sounds", ".usage", ".shortcuts", ".about",
        ]
        expect(
            normalizedRouteSlot.contains("switch destination")
                && destinationCases.allSatisfy {
                    normalizedRouteSlot.contains("case \($0):")
                }
                && !normalizedRouteSlot.contains("default:")
                && !normalizedRouteSlot.contains("AnyView")
                && !normalizedRouteSlot.contains("rawValue"),
            "root 必须用无 default/String/AnyView 的 exhaustive typed switch 穷尽九个 destination")
        expect(
            normalizedController.contains(
                "SettingsRootView(session: settingsPresentationSession)")
                && !normalizedController.contains("SettingsWindowView("),
            "production controller 必须只挂载与 harness 相同的 SettingsRootView(session:) interface")
        expect(
            normalizedGallery.contains("SettingsStateGalleryView(")
                && !normalizedGallery.contains("SettingsRootView(")
                && !normalizedGallery.contains("SettingsPresentationDependencies("),
            "executable gallery 只能挂载 target-owned Settings gallery，不得复制 fixture composition")
    }

    suite("Settings production root：root 与 General identity 挂在各自唯一顶层容器") {
        let rootURL = guiTestRepositoryRoot().appendingPathComponent(
            "gui/Sources/ClaudioSettingsPresentation/SettingsRootView.swift")
        guard let source = try? String(contentsOf: rootURL, encoding: .utf8) else {
            expect(false, "读不到 production SettingsRootView.swift")
            return
        }
        let scan = strippingComments(source)
        guard scan.unmodeledConstructs.isEmpty,
            let rootBody = settingsBracedBlock(
                after: "package var body: some View", in: scan.codeWithoutStringLiterals),
            let generalBody = settingsBracedBlock(
                after: "private var generalSettings: some View",
                in: scan.codeWithoutStringLiterals)
        else {
            expect(false, "Settings root identity source audit 必须 fail closed")
            return
        }
        expect(
            settingsAccessibilityIdentityContract(
                rootBody: rootBody,
                generalBody: generalBody,
                source: scan.codeWithoutStringLiterals),
            "真实 SettingsRootView 顶层 root 与 General 内容容器必须各挂唯一 typed AX identity")

        let rootIdentity =
            ".accessibilityIdentifier(SettingsPresentationAccessibilityID.root)"
        let generalIdentity =
            ".accessibilityIdentifier(SettingsPresentationAccessibilityID.general)"
        let validRoot = "{ GeometryReader { EmptyView() } \(rootIdentity) }"
        let validGeneral = "{ VStack { EmptyView() } \(generalIdentity) }"
        let nestedRoot = "{ GeometryReader { EmptyView() \(rootIdentity) } }"
        let duplicateGeneral =
            "{ VStack { EmptyView() } \(generalIdentity) \(generalIdentity) }"
        let fixtures = [validRoot, validGeneral, nestedRoot, duplicateGeneral].map(
            strippingComments)
        guard fixtures.allSatisfy({ $0.unmodeledConstructs.isEmpty }) else {
            expect(false, "Settings root identity mutation fixtures 必须可由 scanner 完整建模")
            return
        }
        let fixtureCode = fixtures.map(\.codeWithoutStringLiterals)
        expect(
            settingsAccessibilityIdentityContract(
                rootBody: fixtureCode[0],
                generalBody: fixtureCode[1],
                source: fixtureCode[0] + fixtureCode[1])
                && !settingsAccessibilityIdentityContract(
                    rootBody: fixtureCode[2],
                    generalBody: fixtureCode[1],
                    source: fixtureCode[2] + fixtureCode[1])
                && !settingsAccessibilityIdentityContract(
                    rootBody: fixtureCode[0],
                    generalBody: fixtureCode[3],
                    source: fixtureCode[0] + fixtureCode[3]),
            "AX identity 审计必须接受各自顶层唯一 modifier，并拒绝嵌套或重复 mutation")
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
        _ = session.send(.present(.route(nil)))
        adapterState.registration = .requiresApproval
        _ = session.send(.windowPhaseChanged(.key))
        expect(
            session.state.loginItemRegistration == .requiresApproval
                && session.state.pendingAnnouncement?.meaning
                    == .loginItemStatus(.requiresApproval),
            "重获 key 后的 refresh 必须投影最新系统事实并留下语义 announcement debt")
        if let announcement = session.state.pendingAnnouncement {
            _ = session.send(.acknowledgeAnnouncement(id: announcement.id, didPost: true))
        }
        adapterState.registration = .disabled
        _ = session.send(.windowPhaseChanged(.visibleNonKey))
        _ = session.send(.windowPhaseChanged(.key))
        if let announcement = session.state.pendingAnnouncement {
            _ = session.send(.acknowledgeAnnouncement(id: announcement.id, didPost: true))
        }
        _ = session.send(.setLoginItemEnabled(true))
        expect(
            adapterState.requests == [true]
                && session.state.loginItemRegistration == .disabled
                && session.state.loginItemFailure?.reason == .systemRejected,
            "失败必须保留旧系统事实并在同一 presentation state 可见")
        adapterState.shouldFail = false
        _ = session.send(.retryLoginItemOperation)
        expect(
            adapterState.requests == [true, true]
                && session.state.loginItemRegistration == .requiresApproval
                && session.state.loginItemFailure == nil,
            "重试必须重复精确意图并采用 adapter 重读的系统事实")

        expect(
            session.send(.performPlatformAction(.openLoginItemsSettings))
                == .platformAction(.performed)
                && session.send(.performPlatformAction(.openCalendarPrivacySettings))
                    == .platformAction(.performed)
                && platformActions == [.openLoginItemsSettings, .openCalendarPrivacySettings],
            "两个 Settings-only system effect 必须走穷尽 typed dispatcher")
    }

    suite("Settings presentation Login refresh：同一 registration 仍清除旧失败") {
        let preferences = ClaudioPreferences(defaults: UserDefaults())
        let adapterState = SettingsLoginAdapterState()
        let login = LoginItemSettingsModel(
            adapter: makeLoginItemServiceAdapter(
                status: { adapterState.registration },
                setEnabled: { _ in
                    throw LoginItemOperationFailureReason.systemRejected
                }))
        let session = SettingsPresentationSession(
            dependencies: SettingsPresentationDependencies(
                preferences: preferences,
                loginItemSettings: login),
            actions: SettingsPresentationActions { _ in .performed })

        _ = session.send(.setLoginItemEnabled(true))
        expect(
            session.state.loginItemRegistration == .disabled
                && session.state.loginItemFailure?.reason == .systemRejected,
            "失败请求必须保留旧 registration 并公开 failure")
        if let failureAnnouncement = session.state.pendingAnnouncement {
            _ = session.send(
                .acknowledgeAnnouncement(id: failureAnnouncement.id, didPost: true))
        }

        _ = session.send(.present(.route(nil)))
        _ = session.send(.windowPhaseChanged(.key))
        expect(
            session.state.loginItemRegistration == .disabled
                && session.state.loginItemFailure == nil
                && session.state.pendingAnnouncement == nil,
            "同一 registration 的系统 refresh 必须清除旧 failure，且不得产生 status announcement")
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

        expect(
            session.send(.performPlatformAction(.openLoginItemsSettings))
                == .platformAction(.unavailable),
            "typed result 必须无损返回")
        guard let announcement = session.state.pendingAnnouncement else {
            expect(false, "不可用 platform action 必须产生语义 announcement debt")
            return
        }
        _ = session.send(.acknowledgeAnnouncement(id: announcement.id, didPost: false))
        expect(
            session.state.pendingAnnouncement?.id == announcement.id,
            "native post 失败不得消费 announcement debt")
        _ = session.send(
            .acknowledgeAnnouncement(id: announcement.id + 1, didPost: true))
        expect(
            session.state.pendingAnnouncement?.id == announcement.id,
            "陈旧 acknowledgement 不得消费当前 head")
        _ = session.send(.acknowledgeAnnouncement(id: announcement.id, didPost: true))
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
                _ = session.send(
                    .acknowledgeAnnouncement(id: announcement.id, didPost: true))
            }
        }

        expect(
            session.send(.performPlatformAction(.openLoginItemsSettings))
                == .platformAction(.unavailable),
            "先产生一条真实 debt")
        expect(
            synchronouslyAcknowledgedIDs == [1]
                && session.state.pendingAnnouncement == nil
                && session.state.presentationRevision >= 2,
            "@Published willSet 内同步 ack 后 public projection 不得被外层 stale state 覆盖")
        cancellable.cancel()

        _ = session.send(.performPlatformAction(.openLoginItemsSettings))
        let replacedID = session.state.pendingAnnouncement?.id
        _ = session.send(.performPlatformAction(.openCalendarPrivacySettings))
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
            _ = session.send(.acknowledgeAnnouncement(id: replacedID, didPost: true))
        }
        expect(
            session.state.pendingAnnouncement?.id == current.id,
            "旧 head 的成功回执不得消费 replacement")
        _ = session.send(.acknowledgeAnnouncement(id: current.id, didPost: false))
        expect(
            session.state.pendingAnnouncement?.id == current.id,
            "post false 不得消费 exact current head")
        _ = session.send(.acknowledgeAnnouncement(id: current.id, didPost: true))
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
    suite("Settings presentation root：九个 destination 都经同一 compiled production root 挂载") {
        var mountedDestinations = Set<SettingsDestination>()
        for scenario in PreviewFixtures.settingsRouteScenarios {
            let fixture = SettingsPresentationFixtures.generalLogin(
                route: scenario.route,
                availability: PreviewFixtures.settingsRouteAvailability)
            let hostingView = NSHostingView(rootView: fixture.rootView)
            hostingView.frame = NSRect(x: 0, y: 0, width: 980, height: 720)
            hostingView.layoutSubtreeIfNeeded()
            if hostingView.fittingSize.width > 0 && hostingView.fittingSize.height > 0,
                fixture.selectedDestination == scenario.destination
            {
                mountedDestinations.insert(scenario.destination)
            }
        }

        expect(
            mountedDestinations == Set(SettingsDestination.allCases)
                && mountedDestinations.count == 9,
            "固定九个 destination 必须全部由 fixture 与 production 共用的 SettingsRootView(session:) 挂载")
    }

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
                    && first.session.send(
                        .performPlatformAction(.openCalendarPrivacySettings))
                        == .platformAction(.performed)
                    && first.actionRecorder.actions == [.openCalendarPrivacySettings],
                "fixture 必须通过真实 session 与 recording typed action seam 工作")
            expect(
                first.soundPacksEditor.presentation.mode == .inactive,
                "General fixture 的 shared editor 必须保持 inactive，activation 只由 session route transaction 驱动"
            )

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

private func settingsSinkStatementPrefix(after marker: String, in source: String) -> String? {
    guard let markerRange = source.range(of: marker),
        let sinkRange = source.range(
            of: ".sink",
            range: markerRange.upperBound..<source.endIndex),
        let openingBrace = source[sinkRange.upperBound...].firstIndex(of: "{")
    else {
        return nil
    }
    return String(source[markerRange.lowerBound..<openingBrace])
}

private func settingsAnnouncementSchedulerHasLatchContract(_ source: String) -> Bool {
    guard let deferredTurn = source.range(of: "DispatchQueue.main.async"),
        let latchGuard = source.range(
            of: "guard !settingsPresentationAnnouncementDeliveryScheduled"),
        let latchSet = source.range(
            of: "settingsPresentationAnnouncementDeliveryScheduled = true"),
        let deferredBody = settingsBracedBlock(after: "DispatchQueue.main.async", in: source),
        let latchReset = deferredBody.range(
            of: "settingsPresentationAnnouncementDeliveryScheduled = false"),
        let delivery = deferredBody.range(
            of: "deliverPendingSettingsPresentationAnnouncement()")
    else {
        return false
    }
    return latchGuard.lowerBound < latchSet.lowerBound
        && latchSet.lowerBound < deferredTurn.lowerBound
        && latchReset.lowerBound < delivery.lowerBound
}

private func settingsAccessibilityIdentityContract(
    rootBody: String,
    generalBody: String,
    source: String
) -> Bool {
    let rootIdentity =
        ".accessibilityIdentifier(SettingsPresentationAccessibilityID.root)"
    let generalIdentity =
        ".accessibilityIdentifier(SettingsPresentationAccessibilityID.general)"
    let normalizedRoot = collapsingWhitespace(rootBody)
    let normalizedGeneral = collapsingWhitespace(generalBody)
    let normalizedSource = collapsingWhitespace(source)
    return settingsHasSingleTopLevelMarker(rootIdentity, in: normalizedRoot)
        && settingsHasSingleTopLevelMarker(generalIdentity, in: normalizedGeneral)
        && normalizedSource.components(separatedBy: rootIdentity).count - 1 == 1
        && normalizedSource.components(separatedBy: generalIdentity).count - 1 == 1
        && !normalizedRoot.contains(generalIdentity)
        && !normalizedGeneral.contains(rootIdentity)
}

private func settingsHasSingleTopLevelMarker(_ marker: String, in scope: String) -> Bool {
    guard scope.components(separatedBy: marker).count - 1 == 1,
        let markerRange = scope.range(of: marker)
    else {
        return false
    }
    var braceDepth = 0
    for character in scope[..<markerRange.lowerBound] {
        if character == "{" {
            braceDepth += 1
        } else if character == "}" {
            braceDepth -= 1
        }
    }
    return braceDepth == 1
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
