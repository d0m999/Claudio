import ClaudioCore
import ClaudioGUICore
import ClaudioSettingsPresentation
import Foundation

@MainActor
func runSoundPacksEditorOwnerSuites() {
    suite("Sounds 普通同作用域导航保留正在检查的包并读回配置") {
        withTempDirectory { root in
            let file = root.appendingPathComponent("config.json")
            let packs = root.appendingPathComponent("packs", isDirectory: true)
            for id in ["active-pack", "inspected-pack"] {
                writeFixture(
                    "{\"id\":\"\(id)\",\"name\":\"\(id)\",\"events\":{}}",
                    to: packs.appendingPathComponent("\(id)/manifest.json"))
            }
            var config = ClaudioConfig(selectedPack: "active-pack", masterVolume: 0.2)
            try! JSONEncoder().encode(config).write(to: file)
            let owner = SoundPacksEditorOwner(
                configFile: file, lockFile: root.appendingPathComponent("config.lock"),
                environment: makeAudioImportEnvironment(userPacksDirectory: packs),
                refreshCoordinator: SoundPacksRefreshCoordinator())
            let route = SoundPacksWindowRoute.overview(scope: .global)
            _ = owner.send(.activate(.sounds(route: route, requestRevision: 1)))
            guard case .sounds(let initial) = owner.presentation.mode,
                let inspect = initial.packs.first(where: { $0.id == "inspected-pack" })?
                    .inspectAction
            else {
                expect(false, "Sounds 应提供另一声音包的检查动作")
                return
            }
            expect(owner.send(.invoke(inspect)) == .applied, "用户可检查非当前使用的包")
            // Other Settings destinations leave this retained owner untouched.
            config.masterVolume = 0.4
            try! JSONEncoder().encode(config).write(to: file)
            _ = owner.send(.activate(.sounds(route: route, requestRevision: 2)))
            guard case .sounds(let revisited) = owner.presentation.mode else {
                expect(false, "返回 Sounds 应交付编辑器")
                return
            }
            expect(
                revisited.selectedPack?.id == "inspected-pack"
                    && revisited.masterVolume == 0.4,
                "普通同作用域导航保留检查选择，同时读回新的配置")
        }
    }

    suite("SoundPacks editor route：试听失败保留旧目录，激活时拒绝同 UUID 换绑") {
        withTempDirectory { root in
            let file = root.appendingPathComponent("config.json")
            let lock = root.appendingPathComponent("config.lock")
            let packs = root.appendingPathComponent("packs", isDirectory: true)
            for id in ["default-pack", "workspace-pack", "next-pack"] {
                writeFixture(
                    "{\"id\":\"\(id)\",\"name\":\"\(id)\",\"events\":{}}",
                    to: packs.appendingPathComponent("\(id)/manifest.json"))
            }
            let original = WorkspaceSoundRule(
                directory: WorkspaceDirectory(
                    kind: .directory, path: root.appendingPathComponent("before").path),
                surfaces: [.codex],
                profile: WorkspaceSoundProfile(selectedPack: "workspace-pack", volume: 0.7))
            var config = ClaudioConfig(selectedPack: "default-pack", masterVolume: 0.2)
            config.workspaceRules = [original]
            try! JSONEncoder().encode(config).write(to: file)
            let environment = makeAudioImportEnvironment(userPacksDirectory: packs)
            let controller = PanelConfigController(
                configFile: file, lockFile: lock, environment: environment)
            controller.selectSoundScope(.workspace(original.id))
            let selection = EventSettingsWindowSelection(
                route: EventSettingsWindowRoute(scope: .workspace(original.id)))
            expect(
                selection.notePreviewFailure(
                    event: .stop, scope: .workspace(original.id), packID: "workspace-pack",
                    reason: .assetChanged, sourcePackReadOnly: true,
                    workspaceTarget: controller.selectedWorkspaceTarget),
                "试听失败须记录当时选中的目录身份")
            let captured = selection.previewFailure?.workspaceTarget
            expect(captured == WorkspaceSoundWriteTarget(rule: original), "失败事实不得只保留 UUID")

            let replacement = WorkspaceSoundRule(
                id: original.id,
                directory: WorkspaceDirectory(
                    kind: .directory, path: root.appendingPathComponent("after").path),
                surfaces: [.codex],
                profile: WorkspaceSoundProfile(selectedPack: "workspace-pack", volume: 0.7))
            config.workspaceRules = [replacement]
            try! JSONEncoder().encode(config).write(to: file)
            controller.reload()
            expect(
                captured == selection.previewFailure?.workspaceTarget
                    && controller.selectedWorkspaceTarget == captured,
                "延迟修复与面板已选目标均不得被读回的新目录替换")

            let owner = SoundPacksEditorOwner(
                configFile: file, lockFile: lock, environment: environment,
                refreshCoordinator: SoundPacksRefreshCoordinator())
            owner.configureWorkspacePackWriter { target, packID in
                controller.changeWorkspace(.pack(target, packID))
                    ? .success(()) : .failure(controller.workspaceError ?? .configFailure)
            }
            let delayedRoute = SoundPacksWindowRoute.copyAndApply(
                scope: .workspace(original.id), packID: "workspace-pack", event: .stop,
                workspaceTarget: captured)
            _ = owner.send(.activate(.sounds(route: delayedRoute, requestRevision: 1)))
            guard case .sounds(let rejected) = owner.presentation.mode else {
                expect(false, "Sounds 激活必须交付失败态")
                return
            }
            expect(
                rejected.route == delayedRoute
                    && rejected.scope
                        == .unavailable(
                            scope: .workspace(original.id), reason: .scopeUnavailable)
                    && rejected.packs.allSatisfy {
                        $0.useAction == nil && $0.copyAndApplyAction == nil
                    }
                    && loadClaudioConfig(from: file)?.selectedPack == "default-pack"
                    && loadClaudioConfig(from: file)?.workspaceRules.first?.profile?.selectedPack
                        == "workspace-pack",
                "旧深链激活不得捕获新目录、签发应用写入或改写默认组")

            let delayedEventRoute = EventSettingsWindowRoute(
                scope: .workspace(original.id), event: .stop, workspaceTarget: captured,
                unavailableRequestedScopeStoredValue: PanelSoundScopeID.workspace(original.id)
                    .storedValue)
            _ = owner.send(.activate(.events(route: delayedEventRoute, requestRevision: 2)))
            guard case .events(let rejectedEvents) = owner.presentation.mode else {
                expect(false, "失效 Events 快捷入口必须交付 Events presentation")
                return
            }
            expect(
                rejectedEvents.route == delayedEventRoute
                    && rejectedEvents.scope
                        == .unavailable(
                            scope: .workspace(original.id), reason: .scopeUnavailable)
                    && rejectedEvents.packs.allSatisfy { $0.useAction == nil }
                    && rejectedEvents.adoptionPermit == nil,
                "Events 共享编辑器不得把旧工作区入口换绑到新目录或签发写入权限")

            let unavailableRawRoute = EventSettingsWindowRoute(
                scope: .global, event: .stop,
                unavailableRequestedScopeStoredValue: "future-surface")
            _ = owner.send(.activate(.events(route: unavailableRawRoute, requestRevision: 3)))
            guard case .events(let unavailableRaw) = owner.presentation.mode else {
                expect(false, "未知 raw scope 必须交付 Events 失败展示")
                return
            }
            expect(
                unavailableRaw.scope == .unavailable(scope: .global, reason: .scopeUnavailable)
                    && unavailableRaw.packs.allSatisfy { $0.useAction == nil }
                    && unavailableRaw.eventAccess.allSatisfy {
                        $0.previewAction == nil
                            && $0.adoptionAvailability == .ineligible(.writesStopped)
                    }
                    && unavailableRaw.adoptionPermit == nil,
                "展示用默认组不能为未知来源快捷入口签发试听或写入动作")

            let pinnedOverview = SoundPacksWindowRoute.overview(
                scope: .workspace(original.id), workspaceTarget: captured)
            _ = owner.send(.activate(.sounds(route: pinnedOverview, requestRevision: 2)))
            guard case .sounds(let rejectedOverview) = owner.presentation.mode else {
                expect(false, "Events 概览激活必须交付失败态")
                return
            }
            expect(
                rejectedOverview.scope
                    == .unavailable(
                        scope: .workspace(original.id), reason: .scopeUnavailable)
                    && rejectedOverview.packs.allSatisfy { $0.useAction == nil },
                "来自旧工作区的 Events 概览也不能换绑并签发使用动作")

            _ = owner.send(
                .activate(
                    .sounds(
                        route: .overview(scope: .workspace(original.id)), requestRevision: 3)))
            guard case .sounds(let repeated) = owner.presentation.mode else {
                expect(false, "重复概览请求必须交付 Sounds")
                return
            }
            expect(
                repeated.scope
                    == .unavailable(
                        scope: .workspace(original.id), reason: .scopeUnavailable),
                "普通重复导航即使 revision 改变，也不能接受同 UUID 新目录")

            controller.selectSoundScope(
                .workspace(original.id), rebindSelectedWorkspace: true)
            let reselectedRoute = SoundPacksWindowRoute.overview(
                scope: .workspace(original.id),
                workspaceTarget: controller.selectedWorkspaceTarget)
            _ = owner.send(.activate(.sounds(route: reselectedRoute, requestRevision: 4)))
            guard case .sounds(let rebound) = owner.presentation.mode else {
                expect(false, "显式工作区重选必须交付 Sounds")
                return
            }
            expect(
                rebound.scope == .available(.workspace(original.id)),
                "用户显式重选同 UUID 后，新目录锚点才能恢复编辑")
            _ = owner.send(.activate(.sounds(route: delayedRoute, requestRevision: 5)))
            guard case .sounds(let oldAgain) = owner.presentation.mode else {
                expect(false, "旧深链再次激活必须交付 Sounds")
                return
            }
            expect(
                oldAgain.scope
                    == .unavailable(
                        scope: .workspace(original.id), reason: .scopeUnavailable),
                "显式重选后再次使用旧链接仍须拒绝原目录身份")
            let currentRoute = SoundPacksWindowRoute.editEvent(
                scope: .workspace(original.id), packID: "workspace-pack", event: .stop,
                workspaceTarget: WorkspaceSoundWriteTarget(rule: replacement))
            _ = owner.send(.activate(.sounds(route: currentRoute, requestRevision: 6)))
            guard case .sounds(let current) = owner.presentation.mode else {
                expect(false, "新目录深链必须交付 Sounds")
                return
            }
            expect(
                current.scope == .available(.workspace(original.id)),
                "新选择生成的目录锚点可安全进入编辑器")
        }
    }

    suite("SoundPacks editor owner：Events 切包只在真实成功后刷新共享编辑器") {
        withTempDirectory { root in
            let coordinator = SoundPacksRefreshCoordinator()
            let environment = makeAudioImportEnvironment(
                userPacksDirectory: root.appendingPathComponent("packs", isDirectory: true))
            let owner = SoundPacksEditorOwner(
                configFile: root.appendingPathComponent("config.json"),
                lockFile: root.appendingPathComponent("config.lock"),
                environment: environment,
                refreshCoordinator: coordinator)

            expect(
                owner.send(.completePanelPackSwitch(.failed(.invalidPackID("bad"))))
                    == .unchanged,
                "失败 typed completion 必须明确返回 unchanged")
            expect(
                coordinator.windowReloadRevision == 0,
                "失败的 Events pack 选择不得发布虚假 editor refresh")
            expect(
                owner.send(.completePanelPackSwitch(.succeeded)) == .applied,
                "成功 typed completion 必须明确返回 applied")
            expect(
                coordinator.windowReloadRevision == 1,
                "成功的 Events pack 选择必须通知同一 Settings Sounds editor")
        }
    }

    suite("SoundPacks gallery restore failure：retry status 与 model lifecycle 共享身份") {
        let packID = "minimal-chime"
        let retryStatus = SoundPacksWindowStatus(
            kind: .factoryRestore,
            severity: .failure,
            revision: 101,
            action: "恢复出厂声音",
            message: "发布失败",
            recovery: .retryFactoryRestores(packIDs: [packID]))
        let retryError = SoundPacksWindowFactoryRestoreActionError.restore(
            packID: packID,
            error: .publishFailed(reason: "发布失败", salvaged: nil),
            retainedSalvages: [])
        let model = SoundPacksWindowModel(
            previewConfig: ClaudioConfig(selectedPack: packID),
            packCards: [
                PackCard(
                    id: packID,
                    name: "Minimal Chime",
                    isCC0: true,
                    presentEvents: Set(Event.allCases),
                    state: .complete,
                    isSelected: true)
            ],
            selectedPackID: packID,
            selectedEventRows: [],
            builtinPackIDs: [packID],
            windowStatuses: [retryStatus],
            factoryRestoreActionError: retryError,
            environment: makeAudioImportEnvironment(
                userPacksDirectory: URL(fileURLWithPath: "/dev/null/claudio-preview-packs")),
            refreshCoordinator: SoundPacksRefreshCoordinator())

        expect(
            model.factoryRestoreRetryPackID == packID
                && model.factoryRestoreRetryPackIDs == [packID]
                && model.selectedPackIsBuiltinReadOnly,
            "可见 Retry、失败 lifecycle 与 builtin selection 必须指向同一 pack")
    }

    suite("SoundPacks editor owner：manifest 恢复能力绑定失败时包身份") {
        withTempDirectory { root in
            let packs = root.appendingPathComponent("packs")
            let manifest = packs.appendingPathComponent("pack-a/manifest.json")
            let status = SoundPacksWindowStatus(
                kind: .audio, severity: .failure, revision: 41,
                action: "分配声音", message: "manifest 错误", packID: "pack-a",
                recovery: .manifest(
                    packID: "pack-a", path: manifest.path, issue: .unreadable,
                    retry: .assign(fileName: "spare.wav", event: .stop)))
            let cards = ["pack-a", "pack-b"].map { id in
                PackCard(
                    id: id, name: id, isCC0: false, presentEvents: Set(Event.allCases),
                    state: .complete, isSelected: id == "pack-a")
            }
            let owner = SoundPacksEditorOwner.stateGalleryFixture(
                previewConfig: ClaudioConfig(selectedPack: "pack-a"),
                packCards: cards, selectedPackID: "pack-a", selectedEventRows: [],
                windowStatuses: [status],
                environment: makeAudioImportEnvironment(userPacksDirectory: packs))
            guard case .sounds(let sounds) = owner.presentation.mode,
                let recovery = sounds.manifestRecoveryActions.first,
                let retry = recovery.retryAction,
                let inspectOther = sounds.packs.first(where: { $0.id == "pack-b" })?.inspectAction
            else {
                expect(false, "manifest failure must project Finder and retry capabilities")
                return
            }
            expect(
                recovery.packID == "pack-a" && recovery.path == manifest.path,
                "recovery must retain the failing pack and manifest path")
            expect(
                owner.send(.invoke(inspectOther)) == .applied,
                "fixture must switch to the other pack")
            expect(
                owner.send(.invoke(retry)) == .rejected(.staleAction),
                "retry from the previous selection must not mutate the new pack")
        }
    }
}
