import ClaudioCore
import ClaudioGUICore
import ClaudioSettingsPresentation
import Combine

@MainActor
func runEventSettingsWindowSelectionSuites() {
    suite("事件设置 selection：route/focus/preview/AI 生命周期单点收敛") {
        let selection = EventSettingsWindowSelection()
        expect(
            selection.presentationState.route.scope == .global
                && selection.presentationState.route.event == nil
                && selection.presentationState.routeRequestRevision == 0
                && selection.presentationState.previewState == .idle
                && selection.presentationState.aiSessionState == .idle,
            "初始 route 与两个会话必须是可复现的空闲状态")

        let previewGeneration = selection.beginPreviewSequence()
        selection.beginAISession(scope: .global, event: .stop)
        expect(
            selection.presentationState.previewState == .running(generation: previewGeneration)
                && selection.presentationState.aiSessionState
                    == .active(scope: .global, event: .stop),
            "显式用户动作必须登记 preview 与 AI session 身份")

        let route = EventSettingsWindowRoute(scope: .surface(.workBuddy), event: .stop)
        selection.select(route)
        expect(
            selection.presentationState.route == route
                && selection.presentationState.routeRequestRevision == 1
                && selection.presentationState.previewState == .idle
                && selection.presentationState.previewStopRequestRevision == 1
                && selection.presentationState.aiSessionState == .idle
                && selection.presentationState.aiSessionEndRequestRevision == 1,
            "route 变化必须原子保留目标并停止旧 preview/AI session")
        expect(
            !selection.completePreviewSequence(generation: previewGeneration),
            "route 变化后旧 preview generation 不得重新发布完成态")

        selection.requestInitialFocus(scopes: [.global, .surface(.workBuddy)])
        expect(
            selection.presentationState.focusRequestRevision == 1
                && selection.presentationState.focusTarget == .event(.stop),
            "合法 route 必须生成精确 Event 焦点命令")

        selection.markCurrentScopeUnavailable()
        expect(
            selection.presentationState.route.scope == .surface(.workBuddy)
                && selection.presentationState.route.event == .stop
                && selection.presentationState.route.unavailableRequestedScopeStoredValue
                    == PanelSoundScopeID.surface(.workBuddy).storedValue,
            "陈旧 Surface 必须保留原 scope/Event，不能改写为 Global")
        selection.requestInitialFocus(scopes: [.global])
        expect(
            selection.presentationState.focusTarget == .scope(.global),
            "陈旧 scope 只能把焦点交给恢复入口，不得制造可写 Event 焦点")

        selection.clearUnavailableScope()
        _ = selection.beginPreviewSequence()
        selection.beginAISession(scope: .surface(.workBuddy), event: .stop)
        let stopRevision = selection.presentationState.previewStopRequestRevision
        let endRevision = selection.presentationState.aiSessionEndRequestRevision
        selection.leaveDestination()
        expect(
            selection.presentationState.previewState == .idle
                && selection.presentationState.previewStopRequestRevision == stopRevision + 1
                && selection.presentationState.aiSessionState == .idle
                && selection.presentationState.aiSessionEndRequestRevision == endRevision + 1,
            "离页/关窗必须发出单调停止命令并清空两个会话")
    }

    suite("事件设置 selection：同步 subscriber 重入仍发布最终 coherent projection") {
        let selection = EventSettingsWindowSelection()
        _ = selection.beginPreviewSequence()
        var observed: [SettingsEventPresentationState] = []
        let cancellable = selection.$presentationState.dropFirst().sink { state in
            observed.append(state)
            if state.previewStopRequestRevision == 1 {
                selection.notePreviewStopped()
            }
        }

        selection.requestPreviewStop()

        expect(
            selection.presentationState.previewState == .idle
                && selection.presentationState.previewStopRequestRevision == 1
                && observed.last == selection.presentationState,
            "willSet 同步重入后最终 public projection 必须匹配 selection authoritative state")
        withExtendedLifetime(cancellable) {}
    }
}
