import ClaudioCore
import ClaudioGUICore
import ClaudioLocalization
import Foundation

@MainActor
func runWorkBuddyVisualStateBaselineSuites() {
    suite("WorkBuddy 七态 fixture：仍由生产 manager presentation 进入同一 destination") {
        let scenarios = PreviewFixtures.workBuddyVisualScenarios
        expect(
            scenarios.map(\.phase) == PreviewFixtures.WorkBuddyVisualPhase.allCases,
            "WorkBuddy fixture 必须穷尽七个 phase")
        expect(
            scenarios.map(\.id) == [
                "workbuddy.disconnected", "workbuddy.awaiting", "workbuddy.task-start-current",
                "workbuddy.two-bindings-current", "workbuddy.conflict",
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
                facts.coverageText == "2/5",
                "\(scenario.id) 必须保留中性的 2/5 能力事实")
            guard let section = content.connectionSection(for: .workBuddy) else {
                expect(false, "\(scenario.id) 缺少 WorkBuddy 四行连接组")
                continue
            }
            expect(
                section.rows.map(\.kind) == IntegrationConnectionRowKind.allCases,
                "\(scenario.id) 必须渲染准确四行连接组")
        }
    }

    suite("WorkBuddy 七态 status：2/5 不被错误化，连接 Badge 和 Toggle 只由事实决定") {
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
                agent?.coverageText == "2/5" && agent?.isOn == isOn, "\(phase) Toggle/coverage 必须诚实"
            )
            expect(agent?.badgeText != "错误", "2/5 本身不得渲染成错误")
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
                    && english.readinessText.contains("2/5")
                    && chinese.readinessText.contains("2/5"),
                "\(scenario.id) 双语行必须保留 2/5")
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

    suite("WorkBuddy production gallery wiring：七态进入新 destination，另有 disconnect in-flight 帧") {
        let root = guiTestRepositoryRoot()
        guard
            let gallery = try? String(
                contentsOf: root.appendingPathComponent(
                    "gui/Sources/ClaudioGUI/StateGalleryView.swift"),
                encoding: .utf8),
            let view = try? String(
                contentsOf: root.appendingPathComponent(
                    "gui/Sources/ClaudioSettingsPresentation/IntegrationsSettingsDestinationView.swift"
                ),
                encoding: .utf8)
        else {
            expect(false, "读不到 production destination/gallery source")
            return
        }
        expect(
            gallery.contains("ForEach(PreviewFixtures.workBuddyVisualScenarios)")
                && gallery.contains("workbuddy.disconnect-in-flight")
                && gallery.contains("previewInFlightAction: .disconnect(.workBuddy)"),
            "七态之外必须固定提供 disconnect in-flight gallery 帧")
        expect(
            gallery.contains("IntegrationsSettingsDestinationView(")
                && gallery.contains("state: scenario.state"),
            "WorkBuddy fixture 必须进入同一生产 Integrations destination")
        expect(
            view.contains("Toggle(")
                && view.contains("IntegrationConnectionRowKind")
                && view.contains("integrations.destination.info-callout")
                && !view.contains("Inspector")
                && !view.contains("capabilityMatrix"),
            "新 destination 必须包含真实 Toggle/四行组且不再渲染旧 Inspector/矩阵")
    }
}
