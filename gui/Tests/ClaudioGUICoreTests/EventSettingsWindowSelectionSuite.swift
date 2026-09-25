import ClaudioCore
import ClaudioGUICore
import ClaudioSettingsPresentation
import Combine
import Foundation

@MainActor
func runEventSettingsWindowSelectionSuites() {
    suite("事件设置 selection：route/focus/preview/AI 生命周期单点收敛") {
        let selection = EventSettingsWindowSelection()
        expect(
            selection.presentationState.route.scope == .global
                && selection.presentationState.route.event == nil
                && selection.presentationState.routeRequestRevision == 0
                && selection.presentationState.previewState == .idle
                && selection.presentationState.aiSessionState == .idle
                && !selection.presentationState.credentialSheetIsPresented
                && selection.presentationState.playingCandidateID == nil,
            "初始 route 与 destination-local transient state 必须是可复现的空闲状态")

        let previewGeneration = selection.beginPreviewSequence()
        selection.beginAISession(scope: .global, event: .stop)
        let candidateID = UUID()
        selection.presentCredentialSheet()
        selection.beginCandidatePreview(id: candidateID)
        expect(
            selection.presentationState.previewState == .running(generation: previewGeneration)
                && selection.presentationState.aiSessionState
                    == .active(scope: .global, event: .stop)
                && selection.presentationState.credentialSheetIsPresented
                && selection.presentationState.playingCandidateID == candidateID,
            "显式用户动作必须登记 preview、AI session、credential sheet 与 candidate 身份")

        let route = EventSettingsWindowRoute(scope: .surface(.workBuddy), event: .stop)
        selection.select(route)
        expect(
            selection.presentationState.route == route
                && selection.presentationState.routeRequestRevision == 1
                && selection.presentationState.previewState == .idle
                && selection.presentationState.previewStopRequestRevision == 1
                && selection.presentationState.aiSessionState == .idle
                && selection.presentationState.aiSessionEndRequestRevision == 1
                && !selection.presentationState.credentialSheetIsPresented
                && selection.presentationState.playingCandidateID == nil,
            "route 变化必须原子保留目标并停止旧 destination-local transient state")
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
        selection.presentCredentialSheet()
        selection.beginCandidatePreview(id: candidateID)
        let stopRevision = selection.presentationState.previewStopRequestRevision
        let endRevision = selection.presentationState.aiSessionEndRequestRevision
        selection.leaveDestination()
        expect(
            selection.presentationState.previewState == .idle
                && selection.presentationState.previewStopRequestRevision == stopRevision + 1
                && selection.presentationState.aiSessionState == .idle
                && selection.presentationState.aiSessionEndRequestRevision == endRevision + 1
                && !selection.presentationState.credentialSheetIsPresented
                && selection.presentationState.playingCandidateID == nil,
            "离页/关窗必须发出单调停止命令并清空全部 destination-local transient state")

        selection.presentCredentialSheet()
        selection.dismissCredentialSheet()
        selection.beginCandidatePreview(id: candidateID)
        selection.noteCandidatePreviewStopped()
        expect(
            !selection.presentationState.credentialSheetIsPresented
                && selection.presentationState.playingCandidateID == nil,
            "production dismiss/preview-stop command 必须与 route cleanup 复用同一个 coherent state seam")
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

    suite("设置试听失败：点击后保留目标，换组清理，音量恢复只聚焦原组") {
        let selection = EventSettingsWindowSelection()
        expect(
            selection.notePreviewFailure(
                event: .stop, scope: .global, packID: "pack-a", reason: .assetChanged),
            "当前组点击时资产失效应留下可见失败事实")
        expect(
            selection.previewFailure?.event == .stop
                && selection.previewFailure?.packID == "pack-a"
                && selection.previewFailure?.reason == .assetChanged,
            "失败反馈必须绑定点击时的声音包和事件")
        expect(selection.requestGroupVolumeFocus(for: .global), "音量恢复应聚焦当前组")
        expect(
            selection.presentationState.focusTarget == .masterVolume,
            "音量恢复应通过 selection 焦点请求进入真实控件")
        let otherScope = PanelSoundScopeID.workspace(UUID())
        selection.select(EventSettingsWindowRoute(scope: otherScope))
        expect(selection.previewFailure == nil, "切换作用域应清除旧试听失败")
        expect(
            !selection.notePreviewFailure(
                event: .stop, scope: .global, packID: "pack-a", reason: .playbackFailed)
                && !selection.requestGroupVolumeFocus(for: .global),
            "旧作用域的迟到结果与恢复请求不能影响新作用域")
    }

    suite("设置锁忙重试：读回变更或失效作用域时拒绝旧动作") {
        let selection = EventSettingsWindowSelection()
        let config = ClaudioConfig(selectedPack: "before", masterVolume: 0.4)
        let retry = EventSettingsWriteRetry(
            scope: .global, workspaceDirectory: nil,
            operation: .pack(before: "before", requested: "after"))
        selection.noteLockFailureRetry(retry)
        expect(
            selection.writeRetry == retry
                && retry.canRetry(
                    route: selection.route, selectedScope: .global,
                    configState: .operational(config),
                    config: config, workspaceRule: nil),
            "锁忙原动作仅在原作用域和原配置仍成立时可显式重试")
        expect(
            !retry.canRetry(
                route: selection.route, selectedScope: .global,
                configState: .operational(config),
                config: ClaudioConfig(selectedPack: "changed"), workspaceRule: nil),
            "读回显示包已变化时不得重复旧切包")
        expect(
            !retry.canRetry(
                route: selection.route, selectedScope: .global,
                configState: .malformed(reason: "invalid"),
                config: config, workspaceRule: nil),
            "配置读回不可写时不得重放锁忙动作")
        selection.markCurrentScopeUnavailable()
        expect(
            selection.writeRetry == nil
                && !retry.canRetry(
                    route: selection.route, selectedScope: .global,
                    configState: .operational(config),
                    config: config, workspaceRule: nil),
            "失效目标不得退回默认组重试")

        let recovery = URL(fileURLWithPath: "/fixture/recovery.json")
        selection.clearUnavailableScope()
        selection.noteConflictReadback(recoveryFiles: [recovery])
        expect(
            selection.conflictWasReadBack && selection.conflictRecoveryFiles == [recovery],
            "发布冲突的手动读回保留结果不确定性与真实恢复路径")
        selection.select(EventSettingsWindowRoute(scope: .workspace(UUID())))
        expect(
            !selection.conflictWasReadBack && selection.conflictRecoveryFiles.isEmpty,
            "换作用域后不能展示旧冲突的恢复文件")

        let rule = WorkspaceSoundRule(
            directory: WorkspaceDirectory(kind: .directory, path: "/fixture/workspace"),
            surfaces: [.codex],
            profile: WorkspaceSoundProfile(selectedPack: "before", volume: 0.4))
        let scoped = EventSettingsWriteRetry(
            scope: .workspace(rule.id), workspaceDirectory: rule.directory,
            operation: .event(.stop, before: true))
        let scopedRoute = EventSettingsWindowRoute(scope: .workspace(rule.id))
        expect(
            scoped.canRetry(
                route: scopedRoute, selectedScope: .workspace(rule.id),
                configState: .operational(config),
                config: config, workspaceRule: rule),
            "工作区重试应命中原规则身份")
        expect(
            !scoped.canRetry(
                route: scopedRoute, selectedScope: .workspace(rule.id),
                configState: .operational(config),
                config: config, workspaceRule: nil),
            "工作区被移除后不能重放事件开关")
        let surfaceRetry = EventSettingsWriteRetry(
            scope: .workspace(rule.id), workspaceDirectory: rule.directory,
            operation: .surfaces(before: [.codex], requested: [.codex, .claudeCode]))
        var changedRule = rule
        changedRule.surfaces = [.claudeCode]
        expect(
            surfaceRetry.canRetry(
                route: scopedRoute, selectedScope: .workspace(rule.id),
                configState: .operational(config),
                config: config, workspaceRule: rule)
                && !surfaceRetry.canRetry(
                    route: scopedRoute, selectedScope: .workspace(rule.id),
                    configState: .operational(config),
                    config: config, workspaceRule: changedRule),
            "适用来源读回变化后不得重放旧切换")
    }

    suite("删除锁忙重试：原目标重新确认，不复用已消费请求") {
        let rule = WorkspaceSoundRule(
            directory: WorkspaceDirectory(kind: .directory, path: "/fixture/retry-workspace"),
            surfaces: [.codex],
            profile: WorkspaceSoundProfile(selectedPack: "pack-a", volume: 0.5))
        let selection = EventSettingsWindowSelection(
            route: EventSettingsWindowRoute(scope: .workspace(rule.id)))
        expect(selection.requestDeletion(of: rule), "首次删除应要求确认")
        let first = selection.deletionPresentation.pending!
        expect(selection.consumeDeletion(first), "首次确认只消费一次")
        var config = ClaudioConfig(selectedPack: "pack-a")
        config.workspaceRules = [rule]
        _ = selection.finishDeletion(
            first, succeeded: false, error: .lockBusy, configState: .operational(config))
        expect(selection.requestDeletionRetry(of: rule), "锁忙后的显式重试应重新打开确认")
        let second = selection.deletionPresentation.pending!
        expect(second.id != first.id && !selection.consumeDeletion(first), "旧确认令牌不得重放")
        selection.cancelDeletion()
        expect(selection.deletionPresentation.pending == nil, "取消新确认不执行删除")
    }

    suite("删除发布冲突：关联恢复路径不会吞掉实际读回") {
        let rule = WorkspaceSoundRule(
            directory: WorkspaceDirectory(kind: .directory, path: "/fixture/conflict-workspace"),
            surfaces: [.codex],
            profile: WorkspaceSoundProfile(selectedPack: "pack-a", volume: 0.5))
        let selection = EventSettingsWindowSelection(
            route: EventSettingsWindowRoute(scope: .workspace(rule.id)))
        _ = selection.requestDeletion(of: rule)
        let request = selection.deletionPresentation.pending!
        _ = selection.consumeDeletion(request)
        var config = ClaudioConfig(selectedPack: "pack-a")
        config.workspaceRules = [rule]
        _ = selection.finishDeletion(
            request, succeeded: false,
            error: .publishedConflict(recoveryPath: "/fixture/recovery.json"),
            configState: .operational(config))
        guard case .failed(_, let error, let readback) = selection.deletionPresentation.feedback
        else {
            expect(false, "发布冲突必须保留失败反馈")
            return
        }
        expect(
            error.isPublishedConflict && error.recoveryPath == "/fixture/recovery.json"
                && readback == .originalPresent,
            "非空恢复路径不能掩盖已发布冲突，也不能丢失当前配置读回")
        selection.refreshDeletionReadback(configState: .operational(config))
        guard
            case .failed(_, let refreshedError, let refreshedReadback) =
                selection.deletionPresentation.feedback
        else {
            expect(false, "重新载入后仍须保留 typed 冲突")
            return
        }
        expect(
            refreshedError.recoveryPath == error.recoveryPath
                && refreshedReadback == .originalPresent,
            "再次读回不能抹掉原冲突的恢复路径")
    }

    suite("陈旧删除：读回原规则仍要求显式重新选择") {
        let rule = WorkspaceSoundRule(
            directory: WorkspaceDirectory(kind: .directory, path: "/fixture/stale-workspace"),
            surfaces: [.codex],
            profile: WorkspaceSoundProfile(selectedPack: "pack-a", volume: 0.5))
        let selection = EventSettingsWindowSelection(
            route: EventSettingsWindowRoute(scope: .workspace(rule.id)))
        _ = selection.requestDeletion(of: rule)
        let request = selection.deletionPresentation.pending!
        _ = selection.consumeDeletion(request)
        var config = ClaudioConfig(selectedPack: "pack-a")
        config.workspaceRules = [rule]
        _ = selection.finishDeletion(
            request, succeeded: false, error: .staleRule,
            configState: .operational(config))
        guard
            case .failed(_, .staleRule, .originalPresent) =
                selection.deletionPresentation.feedback
        else {
            expect(false, "陈旧删除应同时保留 typed 失败与读回事实")
            return
        }
        expect(
            selection.unavailableRequestedScopeStoredValue
                == PanelSoundScopeID.workspace(rule.id).storedValue,
            "即使原规则仍存在也不能直接恢复旧路由写入")
        selection.select(EventSettingsWindowRoute(scope: .workspace(rule.id)))
        expect(
            selection.unavailableRequestedScopeStoredValue == nil
                && selection.deletionPresentation.feedback == nil,
            "用户重新选择读回后的同一规则才重建路由")
    }
}
