import ClaudioCore
import ClaudioGUICore
import ClaudioSettingsPresentation
import Combine
import Foundation

@MainActor
private func makeWriteRetryModel(
    config: ClaudioConfig, root: URL
) -> (model: PanelConfigController, configFile: URL, lockFile: URL) {
    let configFile = root.appendingPathComponent("config.json")
    let lockFile = root.appendingPathComponent("config.lock")
    let packs = root.appendingPathComponent("packs")
    for id in ["default-pack", "workspace-pack"] {
        writeFixture(
            "{\"id\":\"\(id)\",\"name\":\"\(id)\",\"events\":{}}",
            to: packs.appendingPathComponent("\(id)/manifest.json"))
    }
    writeFixture(try! JSONEncoder().encode(config), to: configFile)
    return (
        PanelConfigController(
            configFile: configFile, lockFile: lockFile,
            environment: makeAudioImportEnvironment(userPacksDirectory: packs)),
        configFile, lockFile
    )
}

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

        selection.requestInitialFocus(
            scopes: [.global, .surface(.workBuddy)],
            for: .events(scope: .surface(.workBuddy), event: .stop))
        expect(
            selection.presentationState.focusRequestRevision == 1
                && selection.presentationState.focusTarget == .event(.stop),
            "合法 route 必须生成精确 Event 焦点命令")

        selection.requestInitialFocus(
            scopes: [.global, .surface(.workBuddy)], for: .destination(.eventsAndSounds))
        expect(
            selection.presentationState.focusRequestRevision == 2
                && selection.presentationState.focusTarget == .title
                && selection.route == route,
            "普通导航必须聚焦标题，同时保留上次深链的选择与事件")

        selection.markCurrentScopeUnavailable()
        expect(
            selection.presentationState.route.scope == .surface(.workBuddy)
                && selection.presentationState.route.event == .stop
                && selection.presentationState.route.unavailableRequestedScopeStoredValue
                    == PanelSoundScopeID.surface(.workBuddy).storedValue,
            "陈旧 Surface 必须保留原 scope/Event，不能改写为 Global")
        selection.requestInitialFocus(
            scopes: [.global], for: .destination(.eventsAndSounds))
        expect(
            selection.presentationState.focusTarget == .unavailableScope,
            "陈旧 scope 必须聚焦可见不可用说明，不得制造可写 Event 焦点")

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
                event: .stop, scope: .global, packID: "pack-a", reason: .assetChanged,
                sourcePackReadOnly: true),
            "当前组点击时资产失效应留下可见失败事实")
        expect(
            selection.previewFailure?.event == .stop
                && selection.previewFailure?.packID == "pack-a"
                && selection.previewFailure?.reason == .assetChanged
                && selection.previewFailure?.sourcePackReadOnly == true,
            "失败反馈必须绑定点击时的声音包、事件和只读状态")
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

    suite("默认组锁忙重试：原值不变才显式提交，旧动作只消费一次") {
        withTempDirectory { root in
            let config = ClaudioConfig(selectedPack: "default-pack", masterVolume: 0.4)
            let fixture = makeWriteRetryModel(config: config, root: root)
            let selection = EventSettingsWindowSelection()
            let holder = FileLock(path: fixture.lockFile.path)
            guard holder.tryLock() else { expect(false, "前提：取得配置锁"); return }
            let retry = EventSettingsWriteRetry(
                scope: .global, workspaceDirectory: nil,
                operation: .volume(before: 0.4, requested: 0.7))
            expect(fixture.model.setVolume(0.7, for: .global) == nil, "锁忙不得写入音量")
            selection.noteWriteResult(retry, using: fixture.model)
            expect(selection.writeRetry == retry, "仅锁忙结果保留原动作")
            holder.unlock()

            expect(selection.retryWrite(using: fixture.model), "用户点击重试后可写原作用域")
            expect(
                loadClaudioConfig(from: fixture.configFile)?.masterVolume == 0.7
                    && selection.writeRetry == nil && selection.writeRetryFailure == nil,
                "重读原值后写入一次，成功清理重试状态")
            let landed = try! Data(contentsOf: fixture.configFile)
            expect(
                !selection.retryWrite(using: fixture.model)
                    && (try! Data(contentsOf: fixture.configFile)) == landed,
                "旧动作已消费，第二次调用不重放")
        }
    }

    suite("默认组锁忙重试：外部改值或配置损坏均拒绝重放并给出原因") {
        for damagedReadback in [false, true] {
            withTempDirectory { root in
                let config = ClaudioConfig(selectedPack: "default-pack", masterVolume: 0.4)
                let fixture = makeWriteRetryModel(config: config, root: root)
                let selection = EventSettingsWindowSelection()
                let holder = FileLock(path: fixture.lockFile.path)
                guard holder.tryLock() else { expect(false, "前提：取得配置锁"); return }
                let retry = EventSettingsWriteRetry(
                    scope: .global, workspaceDirectory: nil,
                    operation: .volume(before: 0.4, requested: 0.7))
                _ = fixture.model.setVolume(0.7, for: .global)
                selection.noteWriteResult(retry, using: fixture.model)
                holder.unlock()
                if damagedReadback {
                    writeFixture("{broken", to: fixture.configFile)
                } else {
                    var changed = config
                    changed.masterVolume = 0.6
                    writeFixture(try! JSONEncoder().encode(changed), to: fixture.configFile)
                }
                let beforeRetry = try! Data(contentsOf: fixture.configFile)
                expect(!selection.retryWrite(using: fixture.model), "读回异常不得提交旧音量")
                expect(
                    (try! Data(contentsOf: fixture.configFile)) == beforeRetry
                        && selection.writeRetry == nil
                        && selection.writeRetryFailure
                            == (damagedReadback ? .readbackUnavailable : .targetChanged),
                    "失败原因留在 selection 中供可见错误与播报使用")
            }
        }
    }

    suite("切包与事件开关：读回已变化时不重放旧请求") {
        for retryingPack in [true, false] {
            withTempDirectory { root in
                let config = ClaudioConfig(selectedPack: "default-pack", masterVolume: 0.4)
                let fixture = makeWriteRetryModel(config: config, root: root)
                let selection = EventSettingsWindowSelection()
                let holder = FileLock(path: fixture.lockFile.path)
                guard holder.tryLock() else { expect(false, "前提：取得配置锁"); return }
                let retry: EventSettingsWriteRetry
                if retryingPack {
                    retry = EventSettingsWriteRetry(
                        scope: .global, workspaceDirectory: nil,
                        operation: .pack(before: "default-pack", requested: "workspace-pack"))
                    _ = fixture.model.switchPack(to: "workspace-pack")
                } else {
                    retry = EventSettingsWriteRetry(
                        scope: .global, workspaceDirectory: nil,
                        operation: .event(.stop, before: config.isEnabled(.stop)))
                    fixture.model.toggleMute(.stop)
                }
                selection.noteWriteResult(retry, using: fixture.model)
                holder.unlock()
                expect(selection.writeRetry == retry, "锁忙保留被点击的原操作")

                var changed = config
                if retryingPack {
                    changed.selectedPack = "workspace-pack"
                } else {
                    changed.eventsEnabled[Event.stop.cliName] = false
                }
                writeFixture(try! JSONEncoder().encode(changed), to: fixture.configFile)
                let beforeRetry = try! Data(contentsOf: fixture.configFile)
                expect(
                    !selection.retryWrite(using: fixture.model)
                        && selection.writeRetryFailure == .targetChanged
                        && (try! Data(contentsOf: fixture.configFile)) == beforeRetry,
                    "外部写者改变原值后，切包和开关均不得被重放")
            }
        }
    }

    suite("工作区锁忙重试：同一 ID 改绑目录不可写入新目标或默认组") {
        withTempDirectory { root in
            let rule = WorkspaceSoundRule(
                directory: WorkspaceDirectory(kind: .directory, path: root.path),
                surfaces: [.codex],
                profile: WorkspaceSoundProfile(selectedPack: "workspace-pack", volume: 0.5))
            var config = ClaudioConfig(selectedPack: "default-pack", masterVolume: 0.21)
            config.workspaceRules = [rule]
            let fixture = makeWriteRetryModel(config: config, root: root)
            fixture.model.selectSoundScope(.workspace(rule.id))
            let selection = EventSettingsWindowSelection(
                route: EventSettingsWindowRoute(scope: .workspace(rule.id)))
            let holder = FileLock(path: fixture.lockFile.path)
            guard holder.tryLock() else { expect(false, "前提：取得配置锁"); return }
            let retry = EventSettingsWriteRetry(
                scope: .workspace(rule.id), workspaceDirectory: rule.directory,
                operation: .volume(before: 0.5, requested: 0.9))
            expect(fixture.model.setVolume(0.9, for: .workspace(rule.id)) == nil, "锁忙拒写")
            selection.noteWriteResult(retry, using: fixture.model)
            holder.unlock()
            expect(selection.writeRetry == retry, "工作区锁忙保留捕获的 ID 与目录")

            let replacement = WorkspaceSoundRule(
                id: rule.id,
                directory: WorkspaceDirectory(
                    kind: .directory, path: root.appendingPathComponent("other").path),
                surfaces: [.codex],
                profile: WorkspaceSoundProfile(selectedPack: "workspace-pack", volume: 0.5))
            config.workspaceRules = [replacement]
            writeFixture(try! JSONEncoder().encode(config), to: fixture.configFile)
            let beforeRetry = try! Data(contentsOf: fixture.configFile)
            expect(!selection.retryWrite(using: fixture.model), "改绑目录使旧目标失效")
            expect(
                (try! Data(contentsOf: fixture.configFile)) == beforeRetry
                    && loadClaudioConfig(from: fixture.configFile)?.masterVolume == 0.21
                    && selection.unavailableRequestedScopeStoredValue
                        == PanelSoundScopeID.workspace(rule.id).storedValue
                    && selection.writeRetryFailure == .targetChanged,
                "无写入、无默认组回落，原工作区呈现失效与重试取消反馈")
        }
    }

    suite("工作区适用来源：原列表变化后拒绝重放") {
        withTempDirectory { root in
            let rule = WorkspaceSoundRule(
                directory: WorkspaceDirectory(kind: .directory, path: root.path),
                surfaces: [.codex],
                profile: WorkspaceSoundProfile(selectedPack: "workspace-pack", volume: 0.5))
            var config = ClaudioConfig(selectedPack: "default-pack")
            config.workspaceRules = [rule]
            let fixture = makeWriteRetryModel(config: config, root: root)
            fixture.model.selectSoundScope(.workspace(rule.id))
            let selection = EventSettingsWindowSelection(
                route: EventSettingsWindowRoute(scope: .workspace(rule.id)))
            let holder = FileLock(path: fixture.lockFile.path)
            guard holder.tryLock() else { expect(false, "前提：取得配置锁"); return }
            let retry = EventSettingsWriteRetry(
                scope: .workspace(rule.id), workspaceDirectory: rule.directory,
                operation: .surfaces(before: [.codex], requested: [.codex, .claudeCode]))
            expect(
                !fixture.model.changeWorkspace(
                    .surfaces(WorkspaceSoundWriteTarget(rule: rule), [.codex, .claudeCode])),
                "锁忙拒绝适用来源写入")
            selection.noteWriteResult(retry, using: fixture.model)
            holder.unlock()
            expect(selection.writeRetry == retry, "捕获原工作区及适用来源")

            config.workspaceRules[0].surfaces = [.claudeCode]
            writeFixture(try! JSONEncoder().encode(config), to: fixture.configFile)
            let beforeRetry = try! Data(contentsOf: fixture.configFile)
            expect(
                !selection.retryWrite(using: fixture.model)
                    && selection.writeRetryFailure == .targetChanged
                    && (try! Data(contentsOf: fixture.configFile)) == beforeRetry,
                "原工作区仍在但适用来源变更时不重放旧写入")
        }
    }

    suite("发布冲突的读回仍保留 typed 恢复事实") {
        let selection = EventSettingsWindowSelection()
        let config = ClaudioConfig(selectedPack: "default-pack")
        let recovery = URL(fileURLWithPath: "/fixture/recovery.json")
        _ = selection.finishConflictReadback(
            scope: .global, configState: .operational(config),
            source: .workspace(.publishedConflict(recoveryPath: recovery.path)),
            recoveryFiles: [recovery])
        expect(
            selection.conflictWasReadBack && selection.conflictRecoveryFiles == [recovery],
            "手动读回保留结果不确定性与真实恢复路径")
        selection.select(EventSettingsWindowRoute(scope: .workspace(UUID())))
        expect(
            !selection.conflictWasReadBack && selection.conflictRecoveryFiles.isEmpty,
            "换作用域后不展示旧冲突的恢复文件")
    }

    suite("冲突读回：不可用配置保留 typed 失败，不宣称已读回") {
        let recovery = URL(fileURLWithPath: "/fixture/conflict-recovery.json")
        let originalError = WorkspaceSoundError.publishedConflict(recoveryPath: recovery.path)
        let source = EventSettingsConflictSource.workspace(originalError)
        let config = ClaudioConfig(selectedPack: "current")
        for state in [
            PanelConfigState.malformed(reason: "fixture"),
            .needsPack,
            .unwritable(reason: "fixture"),
        ] {
            let selection = EventSettingsWindowSelection()
            expect(
                !selection.finishConflictReadback(
                    scope: .global, configState: state, source: source,
                    recoveryFiles: [recovery])
                    && !selection.conflictWasReadBack
                    && selection.conflictReadbackState
                        == .unavailable(source: source, recoveryFiles: [recovery])
                    && selection.unresolvedConflict == source
                    && selection.conflictRecoveryFiles == [recovery],
                "读回不能建立 operational 配置时必须保留原错误与恢复路径")
            expect(
                selection.finishConflictReadback(
                    scope: .global, configState: .operational(config), source: source,
                    recoveryFiles: [recovery])
                    && selection.conflictWasReadBack
                    && selection.conflictReadbackState == .readBack(recoveryFiles: [recovery])
                    && selection.unresolvedConflict == nil,
                "后续明确读回有效配置才能显示读回断言")
        }

        var malformedRules = config
        malformedRules.workspaceRulesMalformed = true
        let malformedRuleSelection = EventSettingsWindowSelection()
        expect(
            !malformedRuleSelection.finishConflictReadback(
                scope: .global, configState: .operational(malformedRules),
                source: source, recoveryFiles: [recovery])
                && malformedRuleSelection.unresolvedConflict == source,
            "配置可解析但工作区规则损坏时也不能断言可靠读回")

        let write = PanelWriteFailure(
            reason: .configPublishedButFailed(
                reason: "fixture", recoveryPath: recovery.path),
            message: "typed fixture", recoveryFile: recovery, source: .mute)
        let selection = EventSettingsWindowSelection()
        expect(
            !selection.finishConflictReadback(
                scope: .global, configState: .needsPack,
                source: .writes([write]), recoveryFiles: [recovery])
                && selection.unresolvedConflict == .writes([write])
                && selection.conflictRecoveryFiles == [recovery],
            "普通写错误在 reload 清空控制器错误后仍须保留 typed 失败与恢复文件")
        selection.select(EventSettingsWindowRoute(scope: .workspace(UUID())))
        expect(
            selection.unresolvedConflict == nil && selection.conflictRecoveryFiles.isEmpty,
            "离开原作用域应清理读回失败的暂存证据")
    }

    suite("删除锁忙重试：原目标重新确认，不复用已消费请求") {
        withTempDirectory { root in
            let rule = WorkspaceSoundRule(
                directory: WorkspaceDirectory(kind: .directory, path: root.path),
                surfaces: [.codex],
                profile: WorkspaceSoundProfile(selectedPack: "workspace-pack", volume: 0.5))
            var config = ClaudioConfig(selectedPack: "default-pack")
            config.workspaceRules = [rule]
            let fixture = makeWriteRetryModel(config: config, root: root)
            fixture.model.selectSoundScope(.workspace(rule.id))
            let selection = EventSettingsWindowSelection(
                route: EventSettingsWindowRoute(scope: .workspace(rule.id)))
            expect(selection.requestDeletion(of: rule), "首次删除应要求确认")
            let first = selection.deletionPresentation.pending!
            expect(selection.consumeDeletion(first), "首次确认只消费一次")
            _ = selection.finishDeletion(
                first, succeeded: false, error: .lockBusy,
                configState: fixture.model.configState)
            let beforeRetry = try! Data(contentsOf: fixture.configFile)
            expect(selection.retryDeletion(using: fixture.model), "锁忙后的显式重试只重新打开确认")
            let second = selection.deletionPresentation.pending!
            expect(second.id != first.id && !selection.consumeDeletion(first), "旧确认令牌不得重放")
            selection.cancelDeletion()
            expect(
                selection.deletionPresentation.pending == nil
                    && selection.presentationState.focusTarget == .workspaceRemove(rule.id)
                    && (try! Data(contentsOf: fixture.configFile)) == beforeRetry,
                "取消新确认返回原删除按钮，不产生写入")
        }
    }

    suite("删除锁忙重试：同一 ID 改绑目录时明确拒绝旧目标") {
        withTempDirectory { root in
            let rule = WorkspaceSoundRule(
                directory: WorkspaceDirectory(kind: .directory, path: root.path),
                surfaces: [.codex],
                profile: WorkspaceSoundProfile(selectedPack: "workspace-pack", volume: 0.5))
            let target = WorkspaceSoundDeleteTarget(rule: rule)
            var config = ClaudioConfig(selectedPack: "default-pack")
            config.workspaceRules = [rule]
            let fixture = makeWriteRetryModel(config: config, root: root)
            fixture.model.selectSoundScope(.workspace(rule.id))
            let selection = EventSettingsWindowSelection(
                route: EventSettingsWindowRoute(scope: .workspace(rule.id)))
            expect(selection.requestDeletion(of: rule), "首次删除必须先请求确认")
            let request = selection.deletionPresentation.pending!
            expect(selection.consumeDeletion(request), "首次确认只消费一次")
            _ = selection.finishDeletion(
                request, succeeded: false, error: .lockBusy,
                configState: fixture.model.configState)

            let replacement = WorkspaceSoundRule(
                id: rule.id,
                directory: WorkspaceDirectory(
                    kind: .directory, path: root.appendingPathComponent("other").path),
                surfaces: [.codex],
                profile: WorkspaceSoundProfile(selectedPack: "workspace-pack", volume: 0.5))
            config.workspaceRules = [replacement]
            writeFixture(try! JSONEncoder().encode(config), to: fixture.configFile)
            let beforeRetry = try! Data(contentsOf: fixture.configFile)
            expect(
                !selection.retryDeletion(using: fixture.model)
                    && selection.deletionPresentation.pending == nil
                    && selection.deletionPresentation.feedback
                        == .failed(target, .staleRule, .replaced)
                    && (try! Data(contentsOf: fixture.configFile)) == beforeRetry,
                "读回同 ID 的新目录不得发确认或写入，必须告知旧目标已变化")
        }
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
