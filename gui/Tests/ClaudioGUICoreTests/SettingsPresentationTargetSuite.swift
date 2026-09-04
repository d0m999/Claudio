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

    suite("Settings presentation target：Release view tree 不携带 DEBUG recorder modifier") {
        let root = guiTestRepositoryRoot()
        let mountURL = root.appendingPathComponent(
            "gui/Sources/ClaudioSettingsPresentation/SettingsMountIdentity.swift")
        let interactionURL = root.appendingPathComponent(
            "gui/Sources/ClaudioSettingsPresentation/SettingsRootInteraction.swift")
        guard
            let mountSource = try? String(contentsOf: mountURL, encoding: .utf8),
            let interactionSource = try? String(contentsOf: interactionURL, encoding: .utf8)
        else {
            expect(false, "读不到 Settings mount/interaction source")
            return
        }

        let shallowMountFixture = """
            extension View {
                @ViewBuilder
                func settingsMountIdentity(_ identifier: String) -> some View {
                    #if DEBUG
                    modifier(SettingsMountIdentityModifier(identifier: identifier))
                    #else
                    accessibilityIdentifier(identifier)
                    #endif
                }
            }
            #if DEBUG
            private struct SettingsMountIdentityModifier: ViewModifier {}
            #endif
            """
        let shallowInteractionFixture = """
            extension View {
                @ViewBuilder
                func settingsSidebarInteraction() -> some View {
                    #if DEBUG
                    modifier(SettingsSidebarInteractionModifier())
                    #else
                    onMoveCommand { _ in }
                    #endif
                }
                @ViewBuilder
                func settingsExitInteraction() -> some View {
                    #if DEBUG
                    modifier(SettingsExitInteractionModifier())
                    #else
                    onExitCommand {}
                    #endif
                }
            }
            #if DEBUG
            private struct SettingsSidebarInteractionModifier: ViewModifier {}
            private struct SettingsExitInteractionModifier: ViewModifier {}
            #endif
            """
        let handlerStringDecoyMutation =
            shallowInteractionFixture
            .replacingOccurrences(of: "onMoveCommand", with: "debugOnlyMove")
            .replacingOccurrences(of: "onExitCommand", with: "debugOnlyExit")
            + "\nlet handlerNames = \"\"\"\nonMoveCommand\nonExitCommand\n\"\"\"\n"
        let directiveStringDecoyFixture =
            "let decoy = \"\"\"\n#if DEBUG\n\"\"\"\n"
            + "#if DEBUG\nlet debugOnly = true\n#else\nlet releaseOnly = true\n#endif\n"
        let directiveStringDecoyRelease = swiftSourceTakingReleaseBranches(
            directiveStringDecoyFixture)
        expect(
            settingsReleasePresentationSourcesAreShallow(
                mountSource: shallowMountFixture,
                interactionSource: shallowInteractionFixture)
                && !settingsReleasePresentationSourcesAreShallow(
                    mountSource: shallowMountFixture
                        + "\nprivate struct SettingsMountIdentityModifier: ViewModifier {}",
                    interactionSource: shallowInteractionFixture)
                && !settingsReleasePresentationSourcesAreShallow(
                    mountSource: shallowMountFixture,
                    interactionSource:
                        shallowInteractionFixture
                        .replacingOccurrences(of: "onMoveCommand", with: "debugOnlyMove"))
                && !settingsReleasePresentationSourcesAreShallow(
                    mountSource: shallowMountFixture,
                    interactionSource: handlerStringDecoyMutation)
                && directiveStringDecoyRelease?.contains("let releaseOnly = true") == true
                && directiveStringDecoyRelease?.contains("let debugOnly = true") == false,
            "Release branch scanner 必须忽略 string decoy，并识别 leaked metadata 与缺失 native handler mutation"
        )
        expect(
            settingsReleasePresentationSourcesAreShallow(
                mountSource: mountSource,
                interactionSource: interactionSource),
            "Release Settings view tree 必须直接使用 native modifiers，DEBUG recorder modifier 不得进入 production generic shape"
        )
    }

    suite("Settings presentation target：Release projection 删除 caller-specific metadata") {
        let root = guiTestRepositoryRoot()
        let paths = [
            "visual": "gui/Sources/ClaudioSettingsPresentation/SettingsVisualComponents.swift",
            "state": "gui/Sources/ClaudioSettingsPresentation/SettingsPresentationState.swift",
            "navigation": "gui/Sources/ClaudioGUICore/SettingsNavigation.swift",
            "root": "gui/Sources/ClaudioSettingsPresentation/SettingsRootView.swift",
            "selection":
                "gui/Sources/ClaudioSettingsPresentation/EventSettingsWindowSelection.swift",
        ]
        var sources: [String: String] = [:]
        for (name, path) in paths {
            guard
                let source = try? String(
                    contentsOf: root.appendingPathComponent(path),
                    encoding: .utf8)
            else {
                expect(false, "读不到 Settings Release footprint source：\(path)")
                return
            }
            sources[name] = source
        }
        guard let visual = sources["visual"],
            let state = sources["state"],
            let navigation = sources["navigation"],
            let rootView = sources["root"],
            let selection = sources["selection"]
        else {
            expect(false, "Settings Release footprint source map 不完整")
            return
        }

        let shallowVisualFixture = """
            struct SettingsSectionCard: View {
                private let content: AnyView
                init<Content: View>(@ViewBuilder content: () -> Content) {
                    self.content = AnyView(content())
                }
            }
            """
        let shallowStateFixture = """
            package struct SettingsPresentationState {
                package let language: ClaudioAppLanguage
                package let platformActionFailure: SettingsPlatformAction?
            }
            """
        let shallowNavigationFixture = """
            #if DEBUG
            extension SettingsRoute {
                var stableIdentityComponents: [String] { [] }
            }
            #endif
            """
        let shallowSelectionFixture = """
            package final class EventSettingsWindowSelection {
                package private(set) var presentationState: SettingsEventPresentationState
            }
            """
        let typedRootFixture = """
            @ViewBuilder
            private var routeSlot: some View {
                switch destination {
                case .general: generalSettings
                case .integrations: integrationsSettings
                }
            }
            """
        expect(
            settingsReleaseProjectionIsShallow(
                visualSource: shallowVisualFixture,
                stateSource: shallowStateFixture,
                navigationSource: shallowNavigationFixture,
                selectionSource: shallowSelectionFixture,
                rootViewSource: typedRootFixture)
                && !settingsReleaseProjectionIsShallow(
                    visualSource: shallowVisualFixture.replacingOccurrences(
                        of: "struct SettingsSectionCard: View",
                        with: "struct SettingsSectionCard<Content: View>: View"),
                    stateSource: shallowStateFixture,
                    navigationSource: shallowNavigationFixture,
                    selectionSource: shallowSelectionFixture,
                    rootViewSource: typedRootFixture)
                && !settingsReleaseProjectionIsShallow(
                    visualSource: shallowVisualFixture,
                    stateSource: shallowStateFixture
                        + "\npackage let interfaceTextSize: ClaudioInterfaceTextSize",
                    navigationSource: shallowNavigationFixture,
                    selectionSource: shallowSelectionFixture,
                    rootViewSource: typedRootFixture)
                && !settingsReleaseProjectionIsShallow(
                    visualSource: shallowVisualFixture,
                    stateSource: shallowStateFixture,
                    navigationSource: shallowNavigationFixture
                        + "\nvar stableIdentityComponents: [String] { [] }",
                    selectionSource: shallowSelectionFixture,
                    rootViewSource: typedRootFixture)
                && !settingsReleaseProjectionIsShallow(
                    visualSource: shallowVisualFixture,
                    stateSource: shallowStateFixture,
                    navigationSource: shallowNavigationFixture,
                    selectionSource: shallowSelectionFixture,
                    rootViewSource: typedRootFixture
                        + "\nprivate var routeSlot: AnyView { AnyView(generalSettings) }"),
            "Release footprint scanner 必须能杀死 generic card、冗余 projection 与 test-only API leak mutation"
        )
        expect(
            settingsReleaseProjectionIsShallow(
                visualSource: visual,
                stateSource: state,
                navigationSource: navigation,
                selectionSource: selection,
                rootViewSource: rootView),
            "Release Settings projection 只保留真实 consumer facts，card type erasure 必须局限在 module-local visual seam"
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
            .integrations: SettingsPresentationAccessibilityID.destination(.integrations),
            .eventsAndSounds: SettingsPresentationAccessibilityID.destination(.eventsAndSounds),
            .notifications: SettingsPresentationAccessibilityID.destination(.notifications),
            .display: SettingsPresentationAccessibilityID.destination(.display),
            .sounds: SettingsPresentationAccessibilityID.destination(.sounds),
            .usage: SettingsPresentationAccessibilityID.destination(.usage),
            .shortcuts: SettingsPresentationAccessibilityID.destination(.shortcuts),
            .about: SettingsPresentationAccessibilityID.destination(.about),
        ]
        let expectedIdentifiers = SettingsDestination.allCases.compactMap {
            destinationSubtreeIdentifiers[$0]
        }
        let canonicalMounts = zip(SettingsDestination.allCases, expectedIdentifiers).map {
            destination, identifier in
            SettingsDestinationMountObservation(
                destination: destination,
                mountedIdentifiers: [identifier])
        }
        var wrongChildMounts = canonicalMounts
        wrongChildMounts[0] = SettingsDestinationMountObservation(
            destination: .general,
            mountedIdentifiers: [SettingsPresentationAccessibilityID.destination(.integrations)])
        expect(
            settingsDestinationMountsAreComplete(canonicalMounts)
                && !settingsDestinationMountsAreComplete(Array(canonicalMounts.dropLast()))
                && !settingsDestinationMountsAreComplete(wrongChildMounts),
            "mount recorder contract 必须能杀死 EmptyView/missing marker 与 wrong-child/order mutation")
        var productionMounts: [SettingsDestinationMountObservation] = []
        for scenario in PreviewFixtures.settingsRouteScenarios {
            let fixture = SettingsPresentationFixtures.generalLogin(
                route: scenario.route,
                availability: PreviewFixtures.settingsRouteAvailability)
            SettingsMountRecorder.reset()
            let probe = SettingsRootNativeProbe(session: fixture.session)
            productionMounts.append(
                SettingsDestinationMountObservation(
                    destination: scenario.destination,
                    mountedIdentifiers: SettingsMountRecorder.identifiers))
            probe.close()
        }

        expect(
            settingsDestinationMountsAreComplete(productionMounts),
            "固定九个 destination 必须按 sidebar 顺序挂载唯一 compiled production subtree，实得 \(productionMounts.map { ($0.destination.rawValue, $0.mountedIdentifiers) })"
        )
    }

    suite("Settings AI Cue gallery：credential/composer/playing 均进入 production root state") {
        for scenario in PreviewFixtures.aiCueGalleryScenarios {
            let fixture = SettingsPresentationFixtures.generalLogin(
                route: .events(scope: .global, event: .stop),
                availability: PreviewFixtures.settingsRouteAvailability,
                aiCueScenario: scenario)
            SettingsMountRecorder.reset()
            let probe = SettingsRootNativeProbe(session: fixture.session)
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
                    SettingsMountRecorder.identifiers.contains(
                        "event-settings.ai-cue.composer"),
                    "\(scenario.rawValue) 必须经 production root 挂载 compiled composer subtree")
            }
            if scenario.rendersCredentialSheet {
                expect(
                    probe.hasAttachedSheet
                        && SettingsMountRecorder.identifiers.contains(
                            "event-settings.ai-cue.credential-sheet"),
                    "\(scenario.rawValue) 必须经 production root 实际呈现并 mount credential sheet")
            } else {
                expect(
                    !probe.hasAttachedSheet,
                    "\(scenario.rawValue) 非 credential 场景不得产生 native attached sheet")
            }
            probe.close()
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

private struct SettingsDestinationMountObservation {
    let destination: SettingsDestination
    let mountedIdentifiers: [String]
}

private func settingsDestinationMountsAreComplete(
    _ observations: [SettingsDestinationMountObservation]
) -> Bool {
    guard observations.map(\.destination) == SettingsDestination.allCases else { return false }
    return observations.allSatisfy { observation in
        let expected = SettingsPresentationAccessibilityID.destination(observation.destination)
        return observation.mountedIdentifiers.filter { identifier in
            identifier == SettingsPresentationAccessibilityID.general
                || identifier.hasPrefix("settings.destination.")
        } == [expected]
    }
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

private func settingsReleasePresentationSourcesAreShallow(
    mountSource: String,
    interactionSource: String
) -> Bool {
    guard let mountRelease = swiftSourceTakingReleaseBranches(mountSource),
        let interactionRelease = swiftSourceTakingReleaseBranches(interactionSource)
    else {
        return false
    }

    return mountRelease.contains("accessibilityIdentifier(identifier)")
        && !mountRelease.contains("SettingsMountIdentityModifier")
        && !mountRelease.contains("SettingsMountReportingView")
        && interactionRelease.contains("onMoveCommand")
        && interactionRelease.contains("onExitCommand")
        && !interactionRelease.contains("SettingsSidebarInteractionModifier")
        && !interactionRelease.contains("SettingsExitInteractionModifier")
        && !interactionRelease.contains("SettingsSidebarInteractionReportingView")
        && !interactionRelease.contains("SettingsExitInteractionReportingView")
}

private func settingsReleaseProjectionIsShallow(
    visualSource: String,
    stateSource: String,
    navigationSource: String,
    selectionSource: String,
    rootViewSource: String
) -> Bool {
    let visual = strippingComments(visualSource)
    let state = strippingComments(stateSource)
    let selection = strippingComments(selectionSource)
    let rootView = strippingComments(rootViewSource)
    guard visual.unmodeledConstructs.isEmpty,
        state.unmodeledConstructs.isEmpty,
        selection.unmodeledConstructs.isEmpty,
        rootView.unmodeledConstructs.isEmpty,
        let releaseNavigation = swiftSourceTakingReleaseBranches(navigationSource)
    else {
        return false
    }
    let visualCode = visual.codeWithoutStringLiterals
    let stateCode = state.codeWithoutStringLiterals
    let selectionCode = selection.codeWithoutStringLiterals
    let rootViewCode = rootView.codeWithoutStringLiterals

    return visualCode.contains("struct SettingsSectionCard: View")
        && !visualCode.contains("struct SettingsSectionCard<")
        && !visualCode.contains("package struct SettingsSectionCard")
        && !visualCode.contains("public struct SettingsSectionCard")
        && visualCode.contains("private let content: AnyView")
        && visualCode.contains("init<Content: View>")
        && visualCode.contains("self.content = AnyView(content())")
        && !stateCode.contains("SettingsPlatformActionFailure")
        && stateCode.contains("package let platformActionFailure: SettingsPlatformAction?")
        && !stateCode.contains("package let languageMode:")
        && !stateCode.contains("package let interfaceTextSize:")
        && !stateCode.contains("package let recoveryIssues:")
        && !releaseNavigation.contains("stableIdentityComponents")
        && !selectionCode.contains("package var focusTarget:")
        && rootViewCode.contains("private var routeSlot: some View")
        && !rootViewCode.contains("AnyView")
}

private func swiftSourceTakingReleaseBranches(_ source: String) -> String? {
    let scanned = strippingComments(source)
    guard scanned.unmodeledConstructs.isEmpty else { return nil }

    var result: [String] = []
    var debugBranches: [Bool] = []
    for line in scanned.code.split(separator: "\n", omittingEmptySubsequences: false) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        switch trimmed {
        case "#if DEBUG":
            debugBranches.append(false)
        case "#else":
            guard !debugBranches.isEmpty, debugBranches[debugBranches.count - 1] == false else {
                return nil
            }
            debugBranches[debugBranches.count - 1] = true
        case "#endif":
            guard !debugBranches.isEmpty else { return nil }
            debugBranches.removeLast()
        default:
            if trimmed.hasPrefix("#if ") || trimmed.hasPrefix("#elseif ") {
                return nil
            }
            if debugBranches.allSatisfy({ $0 }) || debugBranches.isEmpty {
                result.append(String(line))
            }
        }
    }
    guard debugBranches.isEmpty else { return nil }
    return result.joined(separator: "\n")
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
