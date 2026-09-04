import ClaudioCore
import ClaudioGUICore
import ClaudioLocalization
import Foundation

@MainActor
func runWorkBuddyKeyboardAccessibilitySuites() {
    suite("集成 destination 焦点：Agent、Toggle、四行组与 toast 使用 typed target") {
        let coordinator = IntegrationDestinationFocusCoordinator()
        expect(
            coordinator.requestRevision == 0 && coordinator.requestedTarget == nil,
            "初始焦点不得携带陈旧请求")
        coordinator.requestFocus(.agent(.workBuddy))
        expect(
            coordinator.requestRevision == 1
                && coordinator.requestedTarget == .agent(.workBuddy)
                && coordinator.consumeRequest(1)
                && !coordinator.consumeRequest(1),
            "Surface deep link 必须一次性精确聚焦 WorkBuddy Agent")
        coordinator.requestFocus(.toggle(.workBuddy))
        expect(
            coordinator.requestRevision == 2
                && coordinator.requestedTarget == .toggle(.workBuddy)
                && coordinator.consumeRequest(2),
            "Agent 名称与 Toggle 必须是两个独立焦点控件")
        coordinator.requestFocus(.connectionRow(.eventsAndSounds))
        expect(
            coordinator.requestedTarget == .connectionRow(.eventsAndSounds)
                && coordinator.consumeRequest(3),
            "事件管理所在第三行必须拥有稳定焦点 target")
        coordinator.requestFocus(.copyConfigurationSource(.workBuddy))
        expect(coordinator.consumeRequest(4), "配置来源复制必须使用第二行独立焦点 target")
        coordinator.requestFocus(.title)
        coordinator.cancelPendingRequest()
        expect(
            coordinator.requestedTarget == nil && !coordinator.consumeRequest(5),
            "取消请求必须清掉未消费的陈旧焦点")
    }

    suite("WorkBuddy 七态焦点边界：切换 Agent 不改变四行顺序，也不把未实现事件加入焦点") {
        for scenario in PreviewFixtures.workBuddyVisualScenarios {
            let content = integrationDestinationContent(state: scenario.state)
            guard let section = content.connectionSection(for: .workBuddy) else {
                expect(false, "\(scenario.id) 缺少 connection section")
                continue
            }
            expect(
                section.rows.map(\.kind) == IntegrationConnectionRowKind.allCases,
                "\(scenario.id) 焦点遍历必须严格保持四行 contract")
            expect(
                !section.rows.contains { $0.title.contains("能力矩阵") },
                "\(scenario.id) 不得把旧矩阵格塞入 destination 焦点")
        }
        expect(
            IntegrationDestinationFocusTarget.agent(.workBuddy)
                != IntegrationDestinationFocusTarget.toggle(.workBuddy),
            "选择控件和 Toggle 必须保持不同身份")
    }

}
