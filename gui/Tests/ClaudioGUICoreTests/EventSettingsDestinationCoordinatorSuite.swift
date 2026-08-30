import ClaudioCore
import ClaudioGUICore

@MainActor
func runEventSettingsDestinationCoordinatorSuites() {
    suite("事件设置 destination coordinator：route/focus/preview/AI 生命周期单点收敛") {
        var coordinator = EventSettingsDestinationCoordinator()
        expect(
            coordinator.currentScope == .global
                && coordinator.currentEvent == nil
                && coordinator.routeRequestRevision == 0
                && coordinator.previewState == .idle
                && coordinator.aiSessionState == .idle,
            "初始 route 与两个会话必须是可复现的空闲状态")

        let previewGeneration = coordinator.beginPreviewSequence()
        coordinator.beginAISession(scope: .global, event: .stop)
        expect(
            coordinator.previewState == .running(generation: previewGeneration)
                && coordinator.aiSessionState == .active(scope: .global, event: .stop),
            "显式用户动作必须登记 preview 与 AI session 身份")

        let route = EventSettingsWindowRoute(scope: .surface(.workBuddy), event: .stop)
        expect(coordinator.select(route), "新 typed route 必须产生 transition")
        expect(
            coordinator.route == route
                && coordinator.routeRequestRevision == 1
                && coordinator.previewState == .idle
                && coordinator.previewStopRequestRevision == 1
                && coordinator.aiSessionState == .idle
                && coordinator.aiSessionEndRequestRevision == 1,
            "route 变化必须原子保留目标并停止旧 preview/AI session")
        expect(
            !coordinator.completePreviewSequence(generation: previewGeneration),
            "route 变化后旧 preview generation 不得重新发布完成态")

        coordinator.requestInitialFocus(scopes: [.global, .surface(.workBuddy)])
        expect(
            coordinator.focusRequestRevision == 1 && coordinator.focusTarget == .event(.stop),
            "合法 route 必须生成精确 Event 焦点命令")

        expect(coordinator.markCurrentScopeUnavailable(), "动态消失必须留下 route transition")
        expect(
            coordinator.currentScope == .surface(.workBuddy)
                && coordinator.currentEvent == .stop
                && coordinator.route.unavailableRequestedScopeStoredValue
                    == PanelSoundScopeID.surface(.workBuddy).storedValue,
            "陈旧 Surface 必须保留原 scope/Event，不能改写为 Global")
        coordinator.requestInitialFocus(scopes: [.global])
        expect(
            coordinator.focusTarget == .scope(.global),
            "陈旧 scope 只能把焦点交给恢复入口，不得制造可写 Event 焦点")

        expect(coordinator.clearUnavailableScope(), "Surface 恢复后必须能清除失败标记")
        _ = coordinator.beginPreviewSequence()
        coordinator.beginAISession(scope: .surface(.workBuddy), event: .stop)
        let stopRevision = coordinator.previewStopRequestRevision
        let endRevision = coordinator.aiSessionEndRequestRevision
        coordinator.leaveDestination()
        expect(
            coordinator.previewState == .idle
                && coordinator.previewStopRequestRevision == stopRevision + 1
                && coordinator.aiSessionState == .idle
                && coordinator.aiSessionEndRequestRevision == endRevision + 1,
            "离页/关窗必须发出单调停止命令并清空两个会话")
    }
}
