import ClaudioCore
import ClaudioGUICore
import ClaudioLocalization
import Foundation

private let workBuddyUnavailableEvents: [Event] = [
    .stopFailure, .notification, .subagentStop,
]

private struct WorkBuddyKeyboardExpectation {
    let status: HostSourceRowStatus
    let semanticRecovery: IntegrationsRecoveryAction
    let primaryRecovery: IntegrationsRecoveryAction
    let visibleInspectorActions: [IntegrationsWindowInspectorAction]
}

private func workBuddyKeyboardExpectation(
    _ phase: PreviewFixtures.WorkBuddyVisualPhase
) -> WorkBuddyKeyboardExpectation {
    switch phase {
    case .disconnected, .disconnectedAfterAction:
        return WorkBuddyKeyboardExpectation(
            status: .notConnected,
            semanticRecovery: .connect(.workBuddy),
            primaryRecovery: .connect(.workBuddy),
            visibleInspectorActions: [.clearReceiptHistory(.workBuddy)])
    case .awaitingActivation, .taskStartCurrent, .allImplementedBindingsCurrent,
        .repairedAwaitingActivation:
        let awaiting = phase == .awaitingActivation || phase == .repairedAwaitingActivation
        return WorkBuddyKeyboardExpectation(
            status: awaiting ? .awaitingActivation : .ready,
            semanticRecovery: awaiting ? .redetect(.workBuddy) : .none,
            primaryRecovery: .none,
            visibleInspectorActions: [
                .clearReceiptHistory(.workBuddy), .disconnect(.workBuddy),
            ])
    case .conflict:
        return WorkBuddyKeyboardExpectation(
            status: .needsAttention,
            semanticRecovery: .repair(.workBuddy),
            primaryRecovery: .repair(.workBuddy),
            visibleInspectorActions: [
                .clearReceiptHistory(.workBuddy), .disconnect(.workBuddy),
            ])
    }
}

private func workBuddySource(_ path: String) -> String? {
    try? String(
        contentsOf: guiTestRepositoryRoot().appendingPathComponent(path),
        encoding: .utf8)
}

private func workBuddySourceRegion(
    _ source: String,
    from startToken: String,
    to endToken: String
) -> String? {
    guard
        let start = source.range(of: startToken)?.lowerBound,
        let end = source.range(of: endToken, range: start..<source.endIndex)?.lowerBound,
        start < end
    else { return nil }
    return String(source[start..<end])
}

@MainActor
func runWorkBuddyKeyboardAccessibilitySuites() {
    suite("WorkBuddy pre-RC 焦点：七态保持 Product → Surface → binding → 必要动作") {
        let visualOrder = hostSurfacePresentationOrder()
        let expectedCellTargets: [IntegrationsWindowFocusTarget] = Event.allCases.flatMap { event in
            visualOrder.map { .capabilityCell(host: $0, event: event) }
        }

        for scenario in PreviewFixtures.workBuddyVisualScenarios {
            let expectation = workBuddyKeyboardExpectation(scenario.phase)
            let rows = hostSourceRowPresentations(from: scenario.state.matrix)
            let matrix = hostCapabilityMatrixPresentation(
                from: scenario.state.matrix,
                hostOrder: visualOrder)
            guard
                let row = rows.first(where: { $0.host == .workBuddy }),
                let taskStart = matrix.cell(host: .workBuddy, event: .taskStart)
            else {
                expect(false, "\(scenario.id) 缺少 WorkBuddy 来源或 task_start binding")
                continue
            }

            let semanticRecovery = integrationsRecoveryAction(
                for: taskStart,
                hostStatus: row.status)
            let scope = IntegrationsWindowFocusScope(
                matrix: matrix,
                hostOrder: visualOrder,
                inspectorActions: expectation.visibleInspectorActions,
                recoveryAction: expectation.primaryRecovery,
                configurationPathHost: .workBuddy)
            let order = integrationsWindowFocusOrder(scope)
            let hostTargets = visualOrder.map(IntegrationsWindowFocusTarget.hostCard)

            expect(
                row.status == expectation.status,
                "\(scenario.id) 必须把阶段投影成准确来源状态")
            expect(
                semanticRecovery == expectation.semanticRecovery,
                "\(scenario.id) task_start 必须生成准确的 Connect/Redetect/Repair/none 意图")
            expect(
                Array(order.prefix(hostTargets.count)) == hostTargets,
                "\(scenario.id) 首焦点段必须严格按 Product → Host Surface 顺序")
            expect(
                Array(order.dropFirst(hostTargets.count).prefix(expectedCellTargets.count))
                    == expectedCellTargets,
                "\(scenario.id) binding 焦点必须按事件行与 Surface 列稳定遍历")

            let workBuddyBindingEvents = order.compactMap { target -> Event? in
                guard case .capabilityCell(let host, let event) = target, host == .workBuddy else {
                    return nil
                }
                return event
            }
            expect(
                workBuddyBindingEvents == Event.allCases,
                "\(scenario.id) WorkBuddy 五条 binding 必须各有且只有一个选择焦点")

            var expectedTail: [IntegrationsWindowFocusTarget] = [
                .toolbarRedetect,
                .copyConfigurationPath(.workBuddy),
            ]
            if expectation.primaryRecovery.title != nil {
                expectedTail.append(.recoveryAction(expectation.primaryRecovery))
            }
            expectedTail.append(
                contentsOf: expectation.visibleInspectorActions.map { .inspectorAction($0) })
            expect(
                order == hostTargets + expectedCellTargets + expectedTail,
                "\(scenario.id) 必须 fail-closed 锁定完整 Product → Surface → binding → 动作焦点序")
            expect(
                order.filter { $0 == .toolbarRedetect }.count == 1,
                "\(scenario.id) toolbar Redetect 必须恰有一个模型焦点 target")
            expect(
                expectation.primaryRecovery == .none
                    || order.filter { $0 == .recoveryAction(expectation.primaryRecovery) }.count
                        == 1,
                "\(scenario.id) Connect/Repair 主动作必须恰有一个模型焦点 owner")
        }
    }

    suite("WorkBuddy pre-RC 无障碍呈现：七态 label 完整且三条未实现事件只读") {
        for scenario in PreviewFixtures.workBuddyVisualScenarios {
            let rows = hostSourceRowPresentations(from: scenario.state.matrix)
            let matrix = hostCapabilityMatrixPresentation(from: scenario.state.matrix)
            guard let rawRow = rows.first(where: { $0.host == .workBuddy }) else {
                expect(false, "\(scenario.id) 缺少 WorkBuddy 来源行")
                continue
            }

            for language in ClaudioAppLanguage.allCases {
                let row = localizedHostSourceRow(rawRow, language: language)
                expect(
                    row.accessibilityLabel.contains(row.title)
                        && row.accessibilityLabel.contains(row.readinessText)
                        && row.detailText.map(row.accessibilityLabel.contains) != false,
                    "\(scenario.id)/\(language) 来源 label 必须包含产品、连接状态与限定语")

                for event in Event.allCases {
                    guard let rawCell = matrix.cell(host: .workBuddy, event: event) else {
                        expect(false, "\(scenario.id) 缺少 \(event.rawValue) cell")
                        continue
                    }
                    let cell = localizedCapabilityCell(rawCell, language: language)
                    expect(
                        cell.accessibilityLabel.contains(cell.host.displayName)
                            && cell.accessibilityLabel.contains(
                                localizedEventName(event, language: language))
                            && cell.accessibilityLabel.contains(cell.statusText)
                            && cell.qualificationText.map(cell.accessibilityLabel.contains)
                                != false,
                        "\(scenario.id)/\(language)/\(event.rawValue) label 必须独立成句")
                }
            }

            for event in workBuddyUnavailableEvents {
                guard let cell = matrix.cell(host: .workBuddy, event: event) else {
                    expect(false, "\(scenario.id) 缺少未实现事件 \(event.rawValue)")
                    continue
                }
                let recovery = integrationsRecoveryAction(for: cell, hostStatus: rawRow.status)
                let scope = IntegrationsWindowFocusScope(
                    matrix: matrix,
                    inspectorActions: [],
                    recoveryAction: recovery)
                expect(
                    cell.state == .unsupported && recovery.title == nil,
                    "\(scenario.id)/\(event.rawValue) 只能提供只读不支持说明")
                expect(
                    !integrationsWindowFocusOrder(scope).contains(.recoveryAction(recovery)),
                    "\(scenario.id)/\(event.rawValue) 不得进入可执行 recovery 焦点路径")
            }
        }
    }

    suite("WorkBuddy pre-RC AX 边界：占位不进入产品路径，也不获得伪配置复制动作") {
        let matrix = hostCapabilityMatrixPresentation(
            from: PreviewFixtures.workBuddyVisualScenarios[0].state.matrix)
        expect(
            HostID.productVisibleCases == [.claudeCode, .codex, .workBuddy]
                && matrix.hostColumns == hostSurfacePresentationOrder(),
            "产品焦点与矩阵必须只包含三个 native-hook Surface")
        expect(
            Set(matrix.hostColumns).isDisjoint(with: [.chatGPTDesktopAX, .claudeDesktopAX]),
            "Accessibility Beta identity 不得进入产品 binding 焦点")

        for host in [HostID.chatGPTDesktopAX, .claudeDesktopAX] {
            let bindings = HostCapabilityCatalog.bindings(for: host)
            expect(
                bindings.allSatisfy {
                    $0.nativeEvent == nil
                        && $0.qualification == .accessibilityBetaUnavailable
                        && !$0.isAudibleCapability
                },
                "\(host.displayName) 只能保留无原生事件、不可执行的诊断占位")
            let placeholder = HostCapabilityCellPresentation(
                host: host,
                event: .taskStart,
                state: .unsupported,
                qualificationText: "Accessibility Beta 候选尚未实现")
            expect(
                integrationsRecoveryAction(for: placeholder, hostStatus: .notConnected).title
                    == nil,
                "\(host.displayName) 占位不得生成 Connect/Repair 动作")
        }

        guard
            let menu = workBuddySource("gui/Sources/ClaudioGUI/MenuBarController.swift"),
            let model = workBuddySource("gui/Sources/ClaudioGUI/IntegrationsWindowModel.swift"),
            let view = workBuddySource("gui/Sources/ClaudioGUI/IntegrationsWindowView.swift"),
            let sources = workBuddySourceRegion(
                menu,
                from: "configurationSources: [",
                to: "])")
        else {
            expect(false, "读不到生产配置来源与 copy-path wiring")
            return
        }
        expect(
            sources.contains(".claudeCode:")
                && sources.contains(".codex:")
                && sources.contains(".workBuddy:")
                && !sources.contains("chatGPTDesktopAX")
                && !sources.contains("claudeDesktopAX"),
            "生产配置来源只能注入三个真实 native-hook Surface")
        expect(
            model.contains("guard let inspector, let configurationSource")
                && view.contains("if let configurationSource = inspector.configurationSource")
                && view.contains(
                    "configurationPathHost: model.inspector?.configurationSource == nil"),
            "缺少配置来源必须同时关闭复制、路径控件和焦点 target")
    }

    suite("WorkBuddy pre-RC wiring：label/hint/value/selected/disabled/destructive 语义齐全") {
        guard
            let view = workBuddySource("gui/Sources/ClaudioGUI/IntegrationsWindowView.swift"),
            let sourceButton = workBuddySourceRegion(
                view,
                from: "private func sourceSummaryButton(",
                to: "private var selectionSummary"),
            let capabilityButton = workBuddySourceRegion(
                view,
                from: "private func capabilityCellButton(",
                to: "private var inspectorSection"),
            let recoveryButton = workBuddySourceRegion(
                view,
                from: "private func recoveryButton(",
                to: "private func feedbackRow("),
            let inspectorButton = workBuddySourceRegion(
                view,
                from: "private func inspectorButton(",
                to: "private func perform("),
            let toolbar = workBuddySourceRegion(
                view,
                from: ".toolbar {",
                to: ".confirmationDialog(")
        else {
            expect(false, "无法定位 IntegrationsWindow 生产控件 wiring")
            return
        }

        let commonSelectionSemantics = [
            ".accessibilityValue(",
            ".integrationsSelected : .integrationsNotSelected",
            ".accessibilityHint(l10n.text(.integrationsCellHint))",
            ".accessibilityAddTraits(model.selection == selection ? .isSelected : [])",
        ]
        let selectionControls: [(name: String, source: String, required: [String])] = [
            (
                "宿主卡",
                sourceButton,
                [".accessibilityLabel(sourceRowAccessibilityLabel(row))"]
                    + commonSelectionSemantics
            ),
            (
                "binding",
                capabilityButton,
                [".accessibilityLabel(cell.accessibilityLabel)"] + commonSelectionSemantics
            ),
        ]
        for control in selectionControls {
            expect(
                control.required.allSatisfy(control.source.contains),
                "\(control.name) 必须独立具备 label/hint/value/selected 合同")
            for snippet in control.required {
                let mutated = control.source.replacingOccurrences(of: snippet, with: "")
                expect(
                    !control.required.allSatisfy(mutated.contains),
                    "\(control.name) 语义守卫必须能抓到删除：\(snippet)")
            }
        }
        expect(
            sourceButton.contains(".accessibilityHidden(true)")
                && capabilityButton.contains(".accessibilityHidden(true)"),
            "状态图标与进度装饰不得形成重复可访问性节点")
        expect(
            recoveryButton.contains(".disabled(model.isPerformingAction)")
                && recoveryButton.contains(".accessibilityLabel(localizedRecoveryTitle(action))")
                && recoveryButton.contains(".accessibilityHint(recoveryAccessibilityHint(action))"),
            "主恢复动作必须暴露 label/hint，并在动作中禁用")
        expect(
            inspectorButton.components(separatedBy: ".disabled(model.isPerformingAction)").count
                - 1 == 3
                && inspectorButton.components(separatedBy: "role: .destructive").count - 1 == 2
                && inspectorButton.components(separatedBy: ".accessibilityLabel(title)").count - 1
                    == 3,
            "Inspector 三分支必须全部禁用/标注，Disconnect 与清历史保持 destructive")
        expect(
            toolbar.contains("perform(.redetect)")
                && toolbar.contains(".disabled(model.isPerformingAction)")
                && toolbar.contains(
                    ".accessibilityLabel(l10n.text(.integrationsRedetectLabel))")
                && toolbar.contains(
                    ".accessibilityHint(l10n.text(.integrationsRedetectHint))"),
            "awaiting 的唯一 Redetect 动作必须在 toolbar 暴露 label/hint 与 disabled 语义")
    }

    suite("WorkBuddy pre-RC wiring：每个必要焦点 target 在各生产分支恰有一个 owner") {
        guard let view = workBuddySource("gui/Sources/ClaudioGUI/IntegrationsWindowView.swift")
        else {
            expect(false, "读不到 IntegrationsWindowView focus wiring")
            return
        }
        let stripped = strippingComments(view)
        expect(stripped.unmodeledConstructs.isEmpty, "焦点 owner scanner 必须理解生产源码")
        let code = stripped.codeWithoutStringLiterals
        let singleOwners = [
            ".focused($focusedTarget, equals: .toolbarRedetect)",
            ".focused($focusedTarget, equals: .hostCard(row.host))",
            ".focused($focusedTarget, equals: "
                + ".capabilityCell(host: cell.host, event: cell.event))",
            ".focused($focusedTarget, equals: .copyConfigurationPath(inspector.host))",
            ".focused($focusedTarget, equals: .dismissFeedback(revision: feedback.revision))",
            ".focused($focusedTarget, equals: .recoveryAction(action))",
        ]
        let inspectorOwner = ".focused($focusedTarget, equals: .inspectorAction(action))"
        guard
            let inspector = workBuddySourceRegion(
                code,
                from: "private func inspectorButton(",
                to: "private func perform("),
            let disconnect = workBuddySourceRegion(
                inspector,
                from: "case .disconnect",
                to: "case .clearReceiptHistory"),
            let clearReceipts = workBuddySourceRegion(
                inspector,
                from: "case .clearReceiptHistory",
                to: "default:"),
            let ordinaryStart = inspector.range(of: "default:")?.lowerBound
        else {
            expect(false, "无法定位 Inspector 三个互斥焦点 owner 分支")
            return
        }
        let ordinary = String(inspector[ordinaryStart...])
        let inspectorBranches = [disconnect, clearReceipts, ordinary]

        expect(
            singleOwners.allSatisfy {
                code.components(separatedBy: $0).count - 1 == 1
            },
            "非分支纯焦点 target 必须各有一个生产 FocusState owner")
        for owner in singleOwners {
            expect(
                code.replacingOccurrences(of: owner, with: "")
                    .components(separatedBy: owner).count - 1 == 0,
                "焦点 owner 守卫必须能抓到缺失：\(owner)")
            expect(
                (code + owner).components(separatedBy: owner).count - 1 == 2,
                "焦点 owner 守卫必须能抓到重复：\(owner)")
        }
        for (index, branch) in inspectorBranches.enumerated() {
            expect(
                branch.components(separatedBy: inspectorOwner).count - 1 == 1,
                "Inspector 分支 \(index) 必须恰有一个 action 焦点 owner")
            expect(
                branch.replacingOccurrences(of: inspectorOwner, with: "")
                    .components(separatedBy: inspectorOwner).count - 1 == 0
                    && (branch + inspectorOwner).components(separatedBy: inspectorOwner).count - 1
                        == 2,
                "Inspector 分支 \(index) owner 守卫必须能抓到缺失和重复")
        }
        let focusComposition = [
            "inspectorActions: visibleInspectorActions",
            "recoveryAction: primaryRecoveryAction",
            "configurationPathHost: model.inspector?.configurationSource == nil",
            "integrationsWindowFocusOrder(focusScope)",
        ]
        expect(
            focusComposition.allSatisfy(view.contains),
            "生产 FocusState 必须消费可见动作、主恢复、可空配置来源与纯焦点序")
    }

    suite("WorkBuddy pre-RC 播报：装饰隐藏、出口唯一、revision 去重不被 nil 重置") {
        guard
            let view = workBuddySource("gui/Sources/ClaudioGUI/IntegrationsWindowView.swift"),
            let theme = workBuddySource("gui/Sources/ClaudioGUIComponents/ClaudioTheme.swift"),
            let feedbackRow = workBuddySourceRegion(
                view,
                from: "private func feedbackRow(",
                to: "private func inspectorButton(")
        else {
            expect(false, "读不到 IntegrationsWindow 播报/装饰 wiring")
            return
        }
        expect(
            feedbackRow.contains(".accessibilityHidden(true)")
                && theme.contains("public struct ClaudioEventGlyph")
                && theme.contains(".accessibilityHidden(true)"),
            "反馈图标与事件 glyph 必须从可访问性树隐藏")
        expect(
            view.components(separatedBy: "NSAccessibility.post(").count - 1 == 1
                && view.components(separatedBy: "feedbackAnnouncer.consume(").count - 1 == 1,
            "生产主动播报与去重消费必须各收口到唯一出口")

        let now = Date(timeIntervalSince1970: 66)
        var feedback = IntegrationsFeedbackModel()
        let firstRevision = feedback.present(
            host: .workBuddy,
            kind: .information,
            message: "WorkBuddy 已配置",
            accessibilityAnnouncement: "WorkBuddy，2/5 已配置，等待确认",
            now: now)
        var announcer = IntegrationsFeedbackAnnouncementModel()
        let first = feedback.current
        expect(
            announcer.consume(first) == first?.accessibilityLabel
                && announcer.consume(first) == nil,
            "同一 WorkBuddy feedback revision 必须只主动播报一次")
        expect(
            announcer.consume(nil) == nil && announcer.consume(first) == nil,
            "关闭/过期 nil 不得重置已消费 revision")

        feedback.dismiss(revision: firstRevision, now: now)
        _ = feedback.present(
            host: .workBuddy,
            kind: .success,
            message: "WorkBuddy 已修复",
            accessibilityAnnouncement: "WorkBuddy，2/5 已配置，修复后等待确认",
            now: now)
        expect(
            announcer.consume(feedback.current) == feedback.current?.accessibilityLabel,
            "新的 WorkBuddy revision 必须产生一条新的完整播报")
    }
}
