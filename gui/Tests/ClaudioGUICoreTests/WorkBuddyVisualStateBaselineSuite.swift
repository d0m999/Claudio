import ClaudioCore
import ClaudioGUICore
import ClaudioLocalization
import Foundation

private struct WorkBuddyLocalizedExpectation {
    let englishReadiness: String
    let chineseReadiness: String
    let englishDetail: String?
    let chineseDetail: String?
    let englishImplementedCellTitles: [String]
    let chineseImplementedCellTitles: [String]
    let actions: [IntegrationsWindowInspectorAction]
    let englishActionTitles: [String]
    let chineseActionTitles: [String]
}

@MainActor
func runWorkBuddyVisualStateBaselineSuites() {
    suite("WorkBuddy pre-RC fixture：七个关键阶段穷尽且保持 Product → Surface → Binding") {
        let scenarios = PreviewFixtures.workBuddyVisualScenarios
        let expectedIDs = [
            "workbuddy.disconnected",
            "workbuddy.awaiting",
            "workbuddy.task-start-current",
            "workbuddy.two-bindings-current",
            "workbuddy.conflict",
            "workbuddy.repaired-awaiting",
            "workbuddy.disconnected-after-action",
        ]

        expect(
            scenarios.map(\.phase) == PreviewFixtures.WorkBuddyVisualPhase.allCases,
            "WorkBuddy fixture 必须直接穷尽 phase enum，不能手写漏态")
        expect(
            scenarios.map(\.id) == expectedIDs,
            "WorkBuddy fixture ID 必须稳定且按验收顺序排列：\(scenarios.map(\.id))")
        expect(Set(scenarios.map(\.id)).count == scenarios.count, "WorkBuddy fixture ID 必须唯一")

        for scenario in scenarios {
            expect(
                scenario.state.snapshots.map(\.host) == HostID.productVisibleCases,
                "\(scenario.id) 必须携带全部产品 Host Surface，不能把 WorkBuddy 提升成孤立产品态")

            let groups = hostSourceProductGroups(
                from: hostSourceRowPresentations(from: scenario.state.matrix))
            expect(
                groups.map(\.product) == [.chatGPT, .claude, .workBuddy]
                    && groups.last?.surfaces.map(\.host) == [.workBuddy],
                "\(scenario.id) 必须保持 Product → Host Surface 层级")

            let workBuddyCells = Event.allCases.compactMap {
                scenario.state.matrix.cell(host: .workBuddy, event: $0)
            }
            expect(workBuddyCells.count == Event.allCases.count, "\(scenario.id) 必须保留五个事件格")
            expect(
                workBuddyCells.map(\.binding)
                    == Event.allCases.compactMap {
                        HostCapabilityCatalog.binding(host: .workBuddy, event: $0)
                    },
                "\(scenario.id) 每格必须复用稳定 Host Event Binding，不能按画面伪造能力")

            guard
                let row = hostSourceRowPresentations(from: scenario.state.matrix)
                    .first(where: { $0.host == .workBuddy })
            else {
                expect(false, "\(scenario.id) 缺少 WorkBuddy 来源行")
                continue
            }
            expect(
                row.supportedCount == 2 && row.totalCount == 5,
                "\(scenario.id) 必须始终诚实保留 2/5 implemented 边界")
        }
    }

    suite("WorkBuddy pre-RC presentation：未连接、awaiting、逐 binding current、冲突与动作后态") {
        let scenarios = Dictionary(
            uniqueKeysWithValues: PreviewFixtures.workBuddyVisualScenarios.map { ($0.phase, $0) })

        func states(
            _ phase: PreviewFixtures.WorkBuddyVisualPhase
        ) -> [AudibilityCellState] {
            Event.allCases.compactMap {
                scenarios[phase]?.state.matrix.cell(host: .workBuddy, event: $0)?.state
            }
        }

        expect(
            states(.disconnected) == [
                .notConnected, .notConnected, .unsupported, .unsupported, .unsupported,
            ],
            "未连接态必须只有两条 implemented binding 可连接，三条未实现事件保持 unsupported")
        expect(
            states(.awaitingActivation)
                == [
                    .awaitingActivation, .awaitingActivation, .unsupported, .unsupported,
                    .unsupported,
                ],
            "awaiting 必须逐 binding 等待当前代次回执")
        expect(
            states(.taskStartCurrent)
                == [.audible, .awaitingActivation, .unsupported, .unsupported, .unsupported],
            "仅 task_start current 时 Stop 不得被宿主级 observed 回执误点亮")
        expect(
            states(.allImplementedBindingsCurrent)
                == [.audible, .audible, .unsupported, .unsupported, .unsupported],
            "两条 current 只能点亮已实现的 task_start 与 stop")
        expect(
            states(.conflict) == [.degraded, .degraded, .unsupported, .unsupported, .unsupported],
            "冲突必须让两条已实现 binding fail closed，不能改变三条未实现能力")
        expect(
            states(.repairedAwaitingActivation)
                == [
                    .awaitingActivation, .awaitingActivation, .unsupported, .unsupported,
                    .unsupported,
                ],
            "Repair 后必须回到等待当前代次回执，不能伪造连接成功")
        expect(
            states(.disconnectedAfterAction)
                == [.notConnected, .notConnected, .unsupported, .unsupported, .unsupported],
            "Disconnect 后必须清除 current activation 并回到未连接")

        guard
            let taskStartSnapshot = scenarios[.taskStartCurrent]?.state.snapshots.first(where: {
                $0.host == .workBuddy
            }),
            let taskStartBinding = HostCapabilityCatalog.binding(
                host: .workBuddy, event: .taskStart),
            let stopBinding = HostCapabilityCatalog.binding(host: .workBuddy, event: .stop)
        else {
            expect(false, "缺少逐 binding current 测试前提")
            return
        }
        if case .observed = taskStartSnapshot.activation(for: taskStartBinding) {
            expect(true, "task_start 必须有 observed current receipt")
        } else {
            expect(false, "task_start 必须有 observed current receipt")
        }
        if case .awaitingReceipt = taskStartSnapshot.activation(for: stopBinding) {
            expect(true, "仅 task_start current 时 Stop 必须保持 awaiting")
        } else {
            expect(false, "仅 task_start current 时 Stop 必须保持 awaiting")
        }
    }

    suite("WorkBuddy pre-RC actions：未实现事件无假动作，Repair/Disconnect 状态动作诚实") {
        for scenario in PreviewFixtures.workBuddyVisualScenarios {
            guard
                let row = hostSourceRowPresentations(from: scenario.state.matrix)
                    .first(where: { $0.host == .workBuddy })
            else {
                expect(false, "\(scenario.id) 缺少 WorkBuddy 行")
                continue
            }

            for event in [Event.stopFailure, .notification, .subagentStop] {
                guard
                    let cell = hostCapabilityMatrixPresentation(from: scenario.state.matrix)
                        .cell(host: .workBuddy, event: event)
                else {
                    expect(false, "\(scenario.id) 缺少 \(event) presentation")
                    continue
                }
                let recovery = integrationsRecoveryAction(for: cell, hostStatus: row.status)
                expect(cell.state == .unsupported, "\(scenario.id)/\(event) 必须保持 disabled")
                expect(
                    recovery == .explainUnsupported(host: .workBuddy, event: event)
                        && recovery.title == nil,
                    "\(scenario.id)/\(event) 只允许只读解释，不能生成 Connect/Repair/声音假动作")
            }

            let actions = integrationsInspectorActions(for: row)
            switch scenario.phase {
            case .disconnected, .disconnectedAfterAction:
                expect(
                    actions == [.connect(.workBuddy), .clearReceiptHistory(.workBuddy)],
                    "\(scenario.id) 只能提供 Connect 与清理脱敏历史")
            case .conflict:
                expect(
                    actions.contains(.repair(.workBuddy))
                        && actions.last == .disconnect(.workBuddy),
                    "冲突态必须提供 Repair，且 Disconnect 保持最后的破坏性动作")
            case .awaitingActivation, .taskStartCurrent, .allImplementedBindingsCurrent,
                .repairedAwaitingActivation:
                expect(
                    !actions.contains(.repair(.workBuddy))
                        && actions.last == .disconnect(.workBuddy),
                    "\(scenario.id) 不得保留已完成的 Repair，且必须允许显式 Disconnect")
            }
        }
    }

    suite("WorkBuddy pre-RC localization：英文与 zh-Hans 关键状态、能力和动作 fail closed") {
        typealias Phase = PreviewFixtures.WorkBuddyVisualPhase
        let disconnectedActions: [IntegrationsWindowInspectorAction] = [
            .connect(.workBuddy), .clearReceiptHistory(.workBuddy),
        ]
        let connectedActions: [IntegrationsWindowInspectorAction] = [
            .redetect, .clearReceiptHistory(.workBuddy), .disconnect(.workBuddy),
        ]
        let disconnected = WorkBuddyLocalizedExpectation(
            englishReadiness: "2/5 not connected",
            chineseReadiness: "2/5 未连接",
            englishDetail: nil,
            chineseDetail: nil,
            englishImplementedCellTitles: ["Not connected", "Not connected"],
            chineseImplementedCellTitles: ["未连接", "未连接"],
            actions: disconnectedActions,
            englishActionTitles: ["Connect WorkBuddy", "Clear WorkBuddy receipt history"],
            chineseActionTitles: ["连接 WorkBuddy", "清除 WorkBuddy 回执历史"])
        let awaiting = WorkBuddyLocalizedExpectation(
            englishReadiness: "2/5 configured",
            chineseReadiness: "2/5 已配置",
            englishDetail: "Submit a prompt to WorkBuddy to confirm the connection",
            chineseDetail: "请向 WorkBuddy 提交一次提示词以确认连接",
            englishImplementedCellTitles: [
                "Awaiting confirmation", "Awaiting confirmation",
            ],
            chineseImplementedCellTitles: ["等待确认", "等待确认"],
            actions: connectedActions,
            englishActionTitles: [
                "Redetect", "Clear WorkBuddy receipt history", "Disconnect WorkBuddy",
            ],
            chineseActionTitles: ["重新检测", "清除 WorkBuddy 回执历史", "断开 WorkBuddy"])
        let taskStartCurrent = WorkBuddyLocalizedExpectation(
            englishReadiness: "2/5 ready",
            chineseReadiness: "2/5 已就绪",
            englishDetail: "2/5 events are implemented in this version; the others are not enabled",
            chineseDetail: "当前版本已实现 2/5；其余能力尚未启用",
            englishImplementedCellTitles: ["Audible", "Awaiting confirmation"],
            chineseImplementedCellTitles: ["可听", "等待确认"],
            actions: connectedActions,
            englishActionTitles: [
                "Redetect", "Clear WorkBuddy receipt history", "Disconnect WorkBuddy",
            ],
            chineseActionTitles: ["重新检测", "清除 WorkBuddy 回执历史", "断开 WorkBuddy"])
        let bothCurrent = WorkBuddyLocalizedExpectation(
            englishReadiness: "2/5 ready",
            chineseReadiness: "2/5 已就绪",
            englishDetail: "2/5 events are implemented in this version; the others are not enabled",
            chineseDetail: "当前版本已实现 2/5；其余能力尚未启用",
            englishImplementedCellTitles: ["Audible", "Audible"],
            chineseImplementedCellTitles: ["可听", "可听"],
            actions: connectedActions,
            englishActionTitles: [
                "Redetect", "Clear WorkBuddy receipt history", "Disconnect WorkBuddy",
            ],
            chineseActionTitles: ["重新检测", "清除 WorkBuddy 回执历史", "断开 WorkBuddy"])
        let conflict = WorkBuddyLocalizedExpectation(
            englishReadiness: "2/5 needs attention",
            chineseReadiness: "2/5 需要处理",
            englishDetail: "A WorkBuddy hook conflicts with a Claudio entry",
            chineseDetail: "检测到与 Claudio 条目冲突的 WorkBuddy hook",
            englishImplementedCellTitles: ["Needs attention", "Needs attention"],
            chineseImplementedCellTitles: ["需要处理", "需要处理"],
            actions: [
                .redetect, .repair(.workBuddy), .clearReceiptHistory(.workBuddy),
                .disconnect(.workBuddy),
            ],
            englishActionTitles: [
                "Redetect", "Repair WorkBuddy connection", "Clear WorkBuddy receipt history",
                "Disconnect WorkBuddy",
            ],
            chineseActionTitles: [
                "重新检测", "修复 WorkBuddy 连接", "清除 WorkBuddy 回执历史", "断开 WorkBuddy",
            ])
        let expectations: [Phase: WorkBuddyLocalizedExpectation] = [
            .disconnected: disconnected,
            .awaitingActivation: awaiting,
            .taskStartCurrent: taskStartCurrent,
            .allImplementedBindingsCurrent: bothCurrent,
            .conflict: conflict,
            .repairedAwaitingActivation: awaiting,
            .disconnectedAfterAction: disconnected,
        ]
        let allPhases = Set(Phase.allCases)
        expect(Set(expectations.keys) == allPhases, "双语状态与动作期望必须穷尽 WorkBuddy phase")

        for scenario in PreviewFixtures.workBuddyVisualScenarios {
            guard
                let source = hostSourceRowPresentations(from: scenario.state.matrix)
                    .first(where: { $0.host == .workBuddy }),
                let expected = expectations[scenario.phase]
            else {
                expect(false, "\(scenario.id) 缺少穷尽的本地化期望")
                continue
            }
            let englishRow = localizedHostSourceRow(source, language: .english)
            let chineseRow = localizedHostSourceRow(source, language: .zhHans)
            expect(
                englishRow.readinessText == expected.englishReadiness
                    && chineseRow.readinessText == expected.chineseReadiness
                    && englishRow.detailText == expected.englishDetail
                    && chineseRow.detailText == expected.chineseDetail,
                "\(scenario.id) 双语 readiness/detail 必须逐字匹配验收矩阵")

            let implementedCells = [Event.taskStart, .stop].compactMap {
                hostCapabilityMatrixPresentation(from: scenario.state.matrix)
                    .cell(host: .workBuddy, event: $0)
            }
            expect(
                implementedCells.map { localizedCapabilityCell($0, language: .english).statusText }
                    == expected.englishImplementedCellTitles
                    && implementedCells.map {
                        localizedCapabilityCell($0, language: .zhHans).statusText
                    } == expected.chineseImplementedCellTitles,
                "\(scenario.id) 双语已实现 binding 状态文案必须逐项匹配")

            let actualActions = integrationsInspectorActions(for: source)
            expect(
                actualActions == expected.actions,
                "\(scenario.id) 动作名册必须按固定顺序完整匹配")
            expect(
                expected.actions.map {
                    localizedIntegrationsInspectorActionTitle(
                        $0, hostStatus: source.status, language: .english)
                } == expected.englishActionTitles
                    && expected.actions.map {
                        localizedIntegrationsInspectorActionTitle(
                            $0, hostStatus: source.status, language: .zhHans)
                    } == expected.chineseActionTitles,
                "\(scenario.id) 实际动作标题必须逐项通过生产本地化投影")

            for event in [Event.stopFailure, .notification, .subagentStop] {
                guard
                    let cell = hostCapabilityMatrixPresentation(from: scenario.state.matrix)
                        .cell(host: .workBuddy, event: event)
                else {
                    expect(false, "\(scenario.id) 缺少本地化能力格")
                    continue
                }
                let englishCell = localizedCapabilityCell(cell, language: .english)
                let chineseCell = localizedCapabilityCell(cell, language: .zhHans)
                expect(
                    englishCell.statusText == "Unsupported"
                        && chineseCell.statusText == "不支持",
                    "\(scenario.id)/\(event) 双语都必须明确标记未实现事件不可用")
                expect(
                    englishCell.qualificationText?.contains("not implemented yet") == true
                        && chineseCell.qualificationText?.contains("尚未实现") == true,
                    "\(scenario.id)/\(event) 双语限定语必须明确当前版本尚未实现")
            }
        }

        let literalDiagnostic = "WorkBuddy diagnostic literal 42"
        let literalRow = HostSourceRowPresentation(
            host: .workBuddy,
            title: "WorkBuddy",
            readinessText: "2/5 需要处理",
            detailText: literalDiagnostic,
            status: .needsAttention,
            supportedCount: 2,
            totalCount: 5)
        expect(
            localizedHostSourceRow(literalRow, language: .english).detailText == literalDiagnostic
                && localizedHostSourceRow(literalRow, language: .zhHans).detailText
                    == literalDiagnostic,
            "未知或外部领域诊断必须保持 literal，GUI 不得猜测或吞掉原文")
    }

    suite("WorkBuddy pre-RC wiring：七态进入生产详情窗双语 gallery") {
        let root = guiTestRepositoryRoot()
        let galleryURL = root.appendingPathComponent(
            "gui/Sources/ClaudioGUI/StateGalleryView.swift")
        guard let gallery = try? String(contentsOf: galleryURL, encoding: .utf8) else {
            expect(false, "读不到 WorkBuddy state gallery wiring")
            return
        }

        expect(
            gallery.contains("ForEach(PreviewFixtures.workBuddyVisualScenarios)")
                && gallery.contains("HostIntegrationStateFrame(")
                && gallery.contains("state: scenario.state"),
            "七个 WorkBuddy fixture 必须经生产 IntegrationsWindowView 进入双语 state gallery")
    }

    suite("WorkBuddy pre-RC wiring：Inspector destructive 动作消费唯一双语标题投影") {
        let root = guiTestRepositoryRoot()
        let viewURL = root.appendingPathComponent(
            "gui/Sources/ClaudioGUI/IntegrationsWindowView.swift")
        guard let view = try? String(contentsOf: viewURL, encoding: .utf8) else {
            expect(false, "读不到 IntegrationsWindowView production wiring")
            return
        }

        let strippedView = strippingComments(view)
        expect(strippedView.unmodeledConstructs.isEmpty, "IntegrationsWindowView scanner 必须理解源码")
        let code = strippedView.codeWithoutStringLiterals
        guard
            let disconnectStart = code.range(of: ".confirmationDialog(")?.lowerBound,
            let clearStart = code.range(
                of: ".confirmationDialog(",
                range: code.index(after: disconnectStart)..<code.endIndex
            )?.lowerBound,
            let confirmationsEnd = code.range(
                of: ".onReceive(", range: clearStart..<code.endIndex
            )?.lowerBound,
            let start = code.range(of: "private func inspectorButton(")?.lowerBound,
            let end = code.range(of: "private func perform(", range: start..<code.endIndex)?
                .lowerBound,
            disconnectStart < clearStart,
            clearStart < confirmationsEnd,
            start < end
        else {
            expect(false, "无法定位 production confirmation/inspectorButton wiring")
            return
        }
        let destructiveConfirmations = [
            (
                "Disconnect", ".disconnect(host)",
                String(code[disconnectStart..<clearStart])
            ),
            (
                "Clear Receipt History", ".clearReceiptHistory(host)",
                String(code[clearStart..<confirmationsEnd])
            ),
        ]
        let inspectorButton = String(code[start..<end])

        for (name, expectedAction, confirmation) in destructiveConfirmations {
            expect(
                confirmation.contains("let title = localizedInspectorActionTitle("),
                "\(name) confirmation 必须生成共享 Inspector 动作标题")
            expect(
                confirmation.contains("\(expectedAction), hostStatus: selectedHostStatus)"),
                "\(name) confirmation 必须把准确 action 交给共享标题投影")
            expect(
                confirmation.contains("Button(title, role: .destructive)"),
                "\(name) confirmation 的可见标题必须消费共享投影")
            expect(
                confirmation.contains(".accessibilityLabel(title)"),
                "\(name) confirmation 的 accessibility label 必须消费同一投影")
        }
        expect(
            inspectorButton.components(separatedBy: "localizedInspectorActionTitle(").count - 1
                == 1,
            "全部 Inspector 分支必须只生成一次共享标题，不得各自复制 localization")
        expect(
            !inspectorButton.contains(".actionDisconnect,")
                && !inspectorButton.contains(".actionClearReceiptHistory,"),
            "Disconnect/Clear Receipt History 不得绕过共享标题投影直接格式化")
        expect(
            inspectorButton.components(separatedBy: "Button(title, role: .destructive)").count
                - 1 == 2,
            "两个 production Inspector destructive 按钮必须分别消费共享标题")
        expect(
            inspectorButton.components(separatedBy: ".accessibilityLabel(title)").count - 1
                == 3,
            "两个 destructive 分支与普通分支必须分别消费共享 accessibility label")
    }

    suite("WorkBuddy pre-RC wiring：完整生产动作链不获得自动试听能力") {
        struct Route {
            let name: String
            let path: String
            let start: String
            let end: String
            let forwarding: String
            let mutationAnchor: String
        }

        let routes = [
            Route(
                name: "View Disconnect confirmation",
                path: "gui/Sources/ClaudioGUI/IntegrationsWindowView.swift",
                start: "pendingDisconnectHost.map {",
                end: "pendingReceiptHistoryHost.map {",
                forwarding: "perform(.disconnect(host))",
                mutationAnchor: "perform(.disconnect(host))"),
            Route(
                name: "View Clear confirmation",
                path: "gui/Sources/ClaudioGUI/IntegrationsWindowView.swift",
                start: "pendingReceiptHistoryHost.map {",
                end: ".onReceive(",
                forwarding: "perform(.clearReceiptHistory(host))",
                mutationAnchor: "perform(.clearReceiptHistory(host))"),
            Route(
                name: "View Recovery button",
                path: "gui/Sources/ClaudioGUI/IntegrationsWindowView.swift",
                start: "private func recoveryButton(",
                end: "private func feedbackRow(",
                forwarding: "performRecovery(action)",
                mutationAnchor: "performRecovery(action)"),
            Route(
                name: "View Inspector button",
                path: "gui/Sources/ClaudioGUI/IntegrationsWindowView.swift",
                start: "private func inspectorButton(",
                end: "private func perform(",
                forwarding: "perform(action)",
                mutationAnchor: "perform(action)"),
            Route(
                name: "View Inspector forwarding",
                path: "gui/Sources/ClaudioGUI/IntegrationsWindowView.swift",
                start: "private func perform(",
                end: "private func performRecovery(",
                forwarding: "model.perform(action)",
                mutationAnchor: "model.perform(action)"),
            Route(
                name: "View Recovery forwarding",
                path: "gui/Sources/ClaudioGUI/IntegrationsWindowView.swift",
                start: "private func performRecovery(",
                end: "private func announceFeedbackIfNeeded(",
                forwarding: "model.performRecovery(action)",
                mutationAnchor: "model.performRecovery(action)"),
            Route(
                name: "Model Inspector action",
                path: "gui/Sources/ClaudioGUI/IntegrationsWindowModel.swift",
                start: "func perform(_ action:",
                end: "func performRecovery(",
                forwarding: "actionHandler(action)",
                mutationAnchor: "actionHandler(action)"),
            Route(
                name: "Model Recovery Connect",
                path: "gui/Sources/ClaudioGUI/IntegrationsWindowModel.swift",
                start: "case .connect(let host):",
                end: "case .upgrade(let host), .repair(let host):",
                forwarding: "await perform(.connect(host))",
                mutationAnchor: "await perform(.connect(host))"),
            Route(
                name: "Model Recovery Repair",
                path: "gui/Sources/ClaudioGUI/IntegrationsWindowModel.swift",
                start: "case .upgrade(let host), .repair(let host):",
                end: "case .redetect:",
                forwarding: "await perform(.repair(host))",
                mutationAnchor: "await perform(.repair(host))"),
            Route(
                name: "MenuBar composition",
                path: "gui/Sources/ClaudioGUI/MenuBarController.swift",
                start: "actionHandler: IntegrationsWindowActionHandler",
                end: "recoveryHandler: IntegrationsWindowRecoveryHandler",
                forwarding: "integrationActionProvider(action)",
                mutationAnchor: "integrationActionProvider(action)"),
            Route(
                name: "App provider",
                path: "gui/Sources/ClaudioGUI/ClaudioGUIApp.swift",
                start: "let integrationActionProvider = HostIntegrationActionProvider",
                end: "menuBarController = MenuBarController",
                forwarding: "integrationBridge.perform(action)",
                mutationAnchor: "integrationBridge.perform(action)"),
            Route(
                name: "Manager bridge",
                path: "gui/Sources/ClaudioGUICore/HostIntegrationManagerBridge.swift",
                start: "public func perform(",
                end: "private func presentationState(",
                forwarding: "manager.connect(requestedHost)",
                mutationAnchor: "manager.connect(requestedHost)"),
        ]
        let playbackTokens = [
            "NSSound", "AVAudio", "AudioPreviewPlaying", "previewPlayer", "audioPlayer",
            "soundPlayer", "audioEnvironment", ".play(", "playSound(",
        ]
        let root = guiTestRepositoryRoot()

        @MainActor
        func routeBody(_ source: String, route: Route) -> String? {
            let stripped = strippingComments(source)
            expect(
                stripped.unmodeledConstructs.isEmpty,
                "\(route.name) action-route scanner 必须理解全部源码构造")
            let code = stripped.codeWithoutStringLiterals
            guard
                let start = code.range(of: route.start)?.lowerBound,
                let end = code.range(of: route.end, range: start..<code.endIndex)?.lowerBound,
                start < end
            else {
                expect(false, "无法定位 \(route.name) production action route")
                return nil
            }
            return String(code[start..<end])
        }

        for route in routes {
            let sourceURL = root.appendingPathComponent(route.path)
            guard let source = try? String(contentsOf: sourceURL, encoding: .utf8),
                let body = routeBody(source, route: route)
            else {
                expect(false, "读不到 \(route.name) production action route")
                continue
            }
            let violations = playbackTokens.filter(body.contains)
            expect(
                body.contains(route.forwarding),
                "\(route.name) 必须保持真实 Inspector action 转发链")
            expect(
                violations.isEmpty,
                "\(route.name) 的 Connect/Repair/Disconnect 路由不得获得播放依赖：\(violations)")

            guard let insertion = source.range(of: route.mutationAnchor)?.lowerBound else {
                expect(false, "无法构造 \(route.name) no-preview mutation")
                continue
            }
            var mutated = source
            mutated.insert(contentsOf: "\nNSSound.beep()\n", at: insertion)
            guard let mutatedBody = routeBody(mutated, route: route) else { continue }
            expect(
                playbackTokens.filter(mutatedBody.contains) == ["NSSound"],
                "\(route.name) 守卫必须能抓到作用域内注入的播放调用")
        }
    }
}
