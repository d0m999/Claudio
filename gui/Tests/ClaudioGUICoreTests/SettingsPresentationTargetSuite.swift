import AppKit
import ClaudioGUICore
import ClaudioLocalization
import ClaudioSettingsPresentation
import Combine
import Foundation
import SwiftUI

@MainActor
func runSettingsPresentationTargetSuites() {
    suite("Settings presentation target：direct dependencies、resources 与 DAG 固定") {
        let root = guiTestRepositoryRoot()
        guard let targets = dumpedSettingsPackageTargets(repositoryRoot: root),
            let settings = targets.first(where: { $0.name == "ClaudioSettingsPresentation" }),
            let appTarget = targets.first(where: { $0.name == "ClaudioGUI" }),
            let harnessTarget = targets.first(where: { $0.name == "claudio-gui-tests" })
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
    }

    suite("Settings presentation target：root 以下 child view 保持 module-local") {
        let root = guiTestRepositoryRoot()
        let childViews = [
            "EventSettingsAICueServiceCard": "EventSettingsAICueView.swift",
            "EventSettingsAICueComposerView": "EventSettingsAICueView.swift",
            "EventSettingsAICueCredentialSheet": "EventSettingsAICueView.swift",
            "EventSettingsWindowView": "EventSettingsWindowView.swift",
            "IntegrationsSettingsDestinationView": "IntegrationsSettingsDestinationView.swift",
            "LoginItemSettingsSection": "LoginItemSettingsSection.swift",
        ]
        var sources: [String: String] = [:]
        for (_, file) in childViews {
            let url = root.appendingPathComponent(
                "gui/Sources/ClaudioSettingsPresentation/\(file)")
            guard let source = try? String(contentsOf: url, encoding: .utf8) else {
                expect(false, "读不到 Settings child view source：\(file)")
                return
            }
            let scanned = strippingComments(source)
            guard scanned.unmodeledConstructs.isEmpty else {
                expect(false, "Settings child view access audit 遇到无法建模的构造：\(file)")
                return
            }
            sources[file] = scanned.codeWithoutStringLiterals
        }

        expect(
            settingsChildViewsAreModuleLocal(
                childViews: ["LocalView": "Fixture.swift"],
                sources: ["Fixture.swift": "struct LocalView: View {}"])
                && !settingsChildViewsAreModuleLocal(
                    childViews: ["LeakedView": "Fixture.swift"],
                    sources: ["Fixture.swift": "package struct LeakedView: View {}"]),
            "child view access audit 必须能区分 module-local 与 package-visible declaration")
        expect(
            settingsChildViewsAreModuleLocal(childViews: childViews, sources: sources),
            "只有 SettingsRootView/SettingsStateGalleryView 是跨 target mount seam；child views 不得 package-visible"
        )
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
        let destinationSubtreeIdentifiers: [SettingsDestination: String] = [
            .general: SettingsPresentationAccessibilityID.general,
            .integrations: "integrations.destination.scroll",
            .eventsAndSounds: "event-settings.header",
            .notifications: "settings.notifications.dynamic-quiet-policy",
            .display: "settings.display.text-size",
            .sounds: "settings.sounds.editor",
            .usage: "settings.usage.refresh",
            .shortcuts: "settings.shortcuts.toggle-panel",
            .about: "settings.about.identity",
        ]
        var mountedDestinations: [SettingsDestination] = []
        for scenario in PreviewFixtures.settingsRouteScenarios {
            let fixture = SettingsPresentationFixtures.generalLogin(
                route: scenario.route,
                availability: PreviewFixtures.settingsRouteAvailability)
            let hostingView = NSHostingView(rootView: SettingsRootView(session: fixture.session))
            hostingView.frame = NSRect(x: 0, y: 0, width: 980, height: 720)
            hostingView.layoutSubtreeIfNeeded()
            if hostingView.fittingSize.width > 0 && hostingView.fittingSize.height > 0,
                fixture.session.state.routeResolution.destination == scenario.destination,
                let identifier = destinationSubtreeIdentifiers[scenario.destination],
                settingsAXDescendant(identifier: identifier, in: hostingView) != nil
            {
                mountedDestinations.append(scenario.destination)
            }
        }

        expect(
            mountedDestinations == SettingsDestination.allCases,
            "固定九个 destination 必须按 sidebar 顺序挂载可从真实 AX tree 观察的唯一 production subtree，实得 \(mountedDestinations)")
    }

    suite("Settings AI Cue gallery：credential/composer/playing 均进入 production root state") {
        for scenario in PreviewFixtures.aiCueGalleryScenarios {
            let fixture = SettingsPresentationFixtures.generalLogin(
                route: .events(scope: .global, event: .stop),
                availability: PreviewFixtures.settingsRouteAvailability,
                aiCueScenario: scenario)
            let hostingView = NSHostingView(rootView: SettingsRootView(session: fixture.session))
            hostingView.frame = NSRect(x: 0, y: 0, width: 1_240, height: 820)
            hostingView.layoutSubtreeIfNeeded()
            let state = fixture.session.state.eventPresentation
            let scenarioSession = scenario.previewState.session

            expect(
                state.credentialSheetIsPresented == scenario.rendersCredentialSheet,
                "\(scenario.rawValue) credential sheet visibility 必须来自 selection coherent state")
            expect(
                state.playingCandidateID == scenario.playingCandidateID,
                "\(scenario.rawValue) playing candidate 必须来自 selection coherent state")
            if let scenarioSession {
                expect(
                    state.route.scope == scenarioSession.scope
                        && state.route.event == scenarioSession.event,
                    "\(scenario.rawValue) composer route 必须与 fixture session scope/Event 对齐")
                expect(
                    settingsAXDescendant(
                        identifier: "event-settings.ai-cue.composer",
                        in: hostingView) != nil,
                    "\(scenario.rawValue) 必须经 production root AX subtree 挂载 composer")
            }
            if scenario.rendersCredentialSheet {
                expect(
                    settingsAXDescendant(
                        identifier: "event-settings.ai-cue.credential-sheet",
                        in: hostingView) != nil,
                    "\(scenario.rawValue) 必须经 production root 实际呈现 credential sheet")
            }
        }
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

            let hostingView = NSHostingView(rootView: SettingsRootView(session: first.session))
            hostingView.frame = NSRect(x: 0, y: 0, width: 620, height: 520)
            hostingView.layoutSubtreeIfNeeded()
            let secondHostingView = NSHostingView(
                rootView: SettingsRootView(session: second.session))
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

    #endif
}

@MainActor
private func settingsAXDescendant(identifier: String, in root: NSView) -> Any? {
    var pending: [Any] = [root]
    var visited = Set<ObjectIdentifier>()
    while let current = pending.popLast() {
        let object = current as AnyObject
        let identity = ObjectIdentifier(object)
        guard visited.insert(identity).inserted else { continue }
        if settingsAXIdentifier(of: current) == identifier { return current }
        pending.append(contentsOf: settingsAXChildren(of: current))
    }
    return nil
}

@MainActor
private func settingsAXChildren(of element: Any) -> [Any] {
    if let view = element as? NSView { return view.accessibilityChildren() ?? [] }
    if let element = element as? NSAccessibilityElement {
        return element.accessibilityChildren() ?? []
    }
    return []
}

@MainActor
private func settingsAXIdentifier(of element: Any) -> String? {
    if let view = element as? NSView { return view.accessibilityIdentifier() }
    if let element = element as? NSAccessibilityElement {
        return element.accessibilityIdentifier()
    }
    return nil
}

@MainActor
private final class SettingsLoginAdapterState {
    var registration = LoginItemRegistrationState.disabled
    var shouldFail = true
    var requests: [Bool] = []
}

private struct DumpedSettingsPackageTarget {
    let name: String
    let dependencies: [String]
    let dependencyCount: Int
    let hasUnparsedDependencies: Bool
    let resourcesCount: Int
}

private func settingsChildViewsAreModuleLocal(
    childViews: [String: String],
    sources: [String: String]
) -> Bool {
    childViews.allSatisfy { type, file in
        guard let source = sources[file] else { return false }
        return source.contains("struct \(type): View")
            && !source.contains("package struct \(type): View")
            && !source.contains("public struct \(type): View")
    }
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
