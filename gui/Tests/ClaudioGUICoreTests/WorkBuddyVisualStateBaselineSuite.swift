import ClaudioCore
import ClaudioGUICore
import ClaudioLocalization
import Foundation

@MainActor
func runWorkBuddyVisualStateBaselineSuites() {
    suite("WorkBuddy Notification：4/5 能力、宿主 ready 与逐绑定回执相互独立") {
        for phase in [
            PreviewFixtures.WorkBuddyVisualPhase.taskStartCurrent, .allImplementedBindingsCurrent,
        ] {
            let scenario = PreviewFixtures.workBuddyVisualScenarios.first { $0.phase == phase }!
            let matrix = scenario.state.matrix
            let facts = integrationDestinationContent(state: scenario.state).facts(for: .workBuddy)!
            expect(facts.bindingReceipts.count == 4, "生产设置页必须获得四条逐绑定回执投影")
            let notificationReceipt = facts.bindingReceipts.first {
                $0.binding.event == .notification
            }!
            for language in [ClaudioAppLanguage.english, .zhHans] {
                let statusKey: ClaudioL10nKey =
                    phase == .taskStartCurrent
                    ? .integrationsBindingAwaitingReceipt : .integrationsBindingCurrentReceipt
                expect(
                    notificationReceipt.text(language: language)
                        == ClaudioL10n(language: language).format(statusKey, "Notification"),
                    "设置页 Notification 必须使用本绑定的双语待回执／当前回执文字")
                let caption = ClaudioL10n(language: language).text(
                    .integrationsWorkBuddySoundsCaption)
                expect(
                    caption.contains(language == .english ? "Default Group" : "默认组"),
                    "声音入口必须说明 WorkBuddy 使用默认组")
            }
            expect(
                matrix.summary(for: .workBuddy) == .ready(supported: 4, total: 5),
                "保留 task_start 决定宿主 ready 的既有合同")
            let cell = matrix.cell(host: .workBuddy, event: .notification)!
            expect(
                cell.state == (phase == .taskStartCurrent ? .awaitingActivation : .audible),
                "Notification 必须有自己的当前回执，不能从宿主 ready 推断")
            let presentation = HostCapabilityCellPresentation(cell: cell)
            for language in [ClaudioAppLanguage.english, .zhHans] {
                let localized = localizedCapabilityCell(presentation, language: language)
                expect(
                    localized.support == .partial && localized.implementation == .implemented,
                    "通知两种 subtype 必须标记部分覆盖且已实现")
                expect(
                    localized.qualificationText?.contains("permission_prompt") == true
                        && localized.qualificationText?.contains("idle_prompt") == true,
                    "双语文案必须限定两个 subtype")
                expect(
                    localized.accessibilityLabel.contains("permission_prompt")
                        && localized.accessibilityLabel.contains("idle_prompt"),
                    "VoiceOver 文本投影必须包含通知范围")
            }
            expect(
                matrix.cell(host: .workBuddy, event: .stopFailure)?.state == .unsupported,
                "StopFailure 仍未实现")
        }
    }

    suite("WorkBuddy 回执投影：宿主级回执、旧代次与错位 binding 均不能冒充 Notification") {
        let id = UUID()
        let notification = HostCapabilityCatalog.binding(
            host: .workBuddy, nativeEvent: "Notification")!
        let start = HostCapabilityCatalog.binding(
            host: .workBuddy, nativeEvent: "UserPromptSubmit")!
        for wrongBinding in [false, true] {
            let evidence = HostReceiptEvidence(
                bindingID: wrongBinding ? start.id : notification.id,
                installationID: wrongBinding ? id : UUID(), nativeEvent: "Notification",
                event: .notification, timestamp: Date(), playbackResult: .played)
            let snapshot = HostIntegrationSnapshot(
                host: .workBuddy, runtime: .ready,
                availability: .available, configuration: .configured, writability: .writable,
                activation: .observed(evidence),
                bindingActivations: [notification.id: .observed(evidence)],
                installationID: id)
            let projected = IntegrationBindingReceiptPresentation(
                binding: notification, snapshot: snapshot)
            expect(
                projected.activation == .awaitingReceipt(installationID: id),
                "错位或旧代次不能显示当前 Notification 回执")
        }
        expect(
            IntegrationBindingReceiptPresentation(
                binding: notification,
                snapshot: .disconnected(host: .workBuddy)
            ).activation == .none,
            "断开后不得显示当前回执")
    }

    suite("WorkBuddy 七态 fixture：仍由生产 manager presentation 进入同一 destination") {
        let scenarios = PreviewFixtures.workBuddyVisualScenarios
        expect(
            scenarios.map(\.phase) == PreviewFixtures.WorkBuddyVisualPhase.allCases,
            "WorkBuddy fixture 必须穷尽七个 phase")
        expect(
            scenarios.map(\.id) == [
                "workbuddy.disconnected", "workbuddy.awaiting", "workbuddy.task-start-current",
                "workbuddy.all-bindings-current", "workbuddy.conflict",
                "workbuddy.repaired-awaiting",
                "workbuddy.disconnected-after-action",
            ],
            "WorkBuddy fixture ID 和顺序必须稳定")
        for scenario in scenarios {
            let content = integrationDestinationContent(state: scenario.state)
            expect(
                content.agents.map(\.host) == HostID.productVisibleCases,
                "\(scenario.id) 必须携带全部产品 Agent 行")
            guard let facts = content.facts(for: .workBuddy) else {
                expect(false, "\(scenario.id) 缺少 WorkBuddy facts")
                continue
            }
            expect(
                facts.coverageText == "4/5",
                "\(scenario.id) 必须保留中性的 4/5 能力事实")
            guard let section = content.connectionSection(for: .workBuddy) else {
                expect(false, "\(scenario.id) 缺少 WorkBuddy 四行连接组")
                continue
            }
            expect(
                section.rows.map(\.kind) == IntegrationConnectionRowKind.allCases,
                "\(scenario.id) 必须渲染准确四行连接组")
        }
    }

    suite("WorkBuddy 七态 status：4/5 不被错误化，连接 Badge 和 Toggle 只由事实决定") {
        let expected: [(PreviewFixtures.WorkBuddyVisualPhase, HostSourceRowStatus, Bool)] = [
            (.disconnected, .notConnected, false),
            (.awaitingActivation, .awaitingActivation, true),
            (.taskStartCurrent, .ready, true),
            (.allImplementedBindingsCurrent, .ready, true),
            (.conflict, .needsAttention, true),
            (.repairedAwaitingActivation, .awaitingActivation, true),
            (.disconnectedAfterAction, .notConnected, false),
        ]
        for (phase, status, isOn) in expected {
            guard
                let scenario = PreviewFixtures.workBuddyVisualScenarios.first(where: {
                    $0.phase == phase
                })
            else {
                expect(false, "缺少 \(phase) fixture")
                continue
            }
            let agent = integrationDestinationContent(state: scenario.state).agent(for: .workBuddy)
            expect(agent?.status == status, "\(phase) 必须投影为 \(status)")
            expect(
                agent?.coverageText == "4/5" && agent?.isOn == isOn, "\(phase) Toggle/coverage 必须诚实"
            )
            expect(agent?.badgeText != "错误", "4/5 本身不得渲染成错误")
        }
    }

    suite("WorkBuddy 七态 localization：英文与 zh-Hans 保留能力覆盖和诊断 literal") {
        for scenario in PreviewFixtures.workBuddyVisualScenarios {
            guard
                let row = hostSourceRowPresentations(from: scenario.state.matrix)
                    .first(where: { $0.host == .workBuddy })
            else {
                expect(false, "\(scenario.id) 缺少 WorkBuddy source row")
                continue
            }
            let english = localizedHostSourceRow(row, language: .english)
            let chinese = localizedHostSourceRow(row, language: .zhHans)
            expect(
                english.title == "WorkBuddy"
                    && english.readinessText.contains("4/5")
                    && chinese.readinessText.contains("4/5"),
                "\(scenario.id) 双语行必须保留 4/5")
            if let detail = row.detailText {
                expect(
                    localizedHostSourceRow(
                        HostSourceRowPresentation(
                            host: .workBuddy,
                            title: row.title,
                            readinessText: row.readinessText,
                            detailText: detail,
                            status: .needsAttention,
                            supportedCount: 2,
                            totalCount: 5),
                        language: .zhHans
                    ).detailText == detail
                        || scenario.phase == .conflict,
                    "外部诊断 literal 不得被 GUI 猜测覆盖")
            }
        }
    }

}
