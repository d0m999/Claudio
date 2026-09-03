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

    suite("集成 destination accessibility wiring：真实 Toggle、选中行背景、四行与窗口可见性守卫") {
        let root = guiTestRepositoryRoot()
        guard
            let view = try? String(
                contentsOf: root.appendingPathComponent(
                    "gui/Sources/ClaudioSettingsPresentation/IntegrationsSettingsDestinationView.swift"
                ),
                encoding: .utf8),
            let controller = try? String(
                contentsOf: root.appendingPathComponent(
                    "gui/Sources/ClaudioGUI/SettingsWindowController.swift"),
                encoding: .utf8)
        else {
            expect(false, "读不到集成 destination accessibility wiring")
            return
        }
        let stripped = strippingComments(view)
        expect(stripped.unmodeledConstructs.isEmpty, "destination source scanner 必须理解源码")
        expect(
            view.contains("Toggle(")
                && view.contains("get: { agent.isOn }")
                && view.contains("model.requestToggle(for: agent.host)"),
            "Agent 行必须连接真实 manager-derived Toggle，不得本地乐观翻转")
        expect(
            view.contains("model.selectedHost == agent.host")
                && view.contains(
                    ".accessibilityAddTraits(model.selectedHost == agent.host ? .isSelected : [])"),
            "选择控件必须独立表达 selected 语义")
        expect(
            view.contains("IntegrationConnectionRowKind.allCases")
                || view.contains("ForEach(section.rows)"),
            "连接组必须消费 typed 四行 presentation")
        expect(
            view.contains("model.isWindowVisible, model.isWindowKey")
                && view.contains("onAnnouncement?(sentence)"),
            "VoiceOver 反馈只允许在 destination 可见且窗口为 key 时播报")
        expect(
            controller.contains("integrationsModel.noteWindowVisibility")
                && controller.contains("integrationsModel.noteWindowKeyState"),
            "统一 Settings controller 必须注入真实窗口生命周期事实")
        expect(
            !view.contains("NSSound") && !view.contains("AVAudio") && !view.contains("readLine"),
            "展示层不得自行试听、访问宿主文件或启动额外输入链")
    }
}
