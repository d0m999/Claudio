import ClaudioCore
import ClaudioGUICore
import ClaudioLocalization
import Foundation

@MainActor
func runWorkspaceSoundPresentationSuites() {
    suite("声音包编辑：工作区使用与复制应用复用现有写入口") {
        withTempDirectory { root in
            let file = root.appendingPathComponent("config.json")
            let packs = root.appendingPathComponent("packs", isDirectory: true)
            for id in ["default-pack", "workspace-pack", "next-pack"] {
                writeFixture(
                    "{\"id\":\"\(id)\",\"name\":\"\(id)\",\"events\":{}}",
                    to: packs.appendingPathComponent("\(id)/manifest.json"))
            }
            var config = ClaudioConfig(selectedPack: "default-pack", masterVolume: 0.2)
            let rule = WorkspaceSoundRule(
                directory: WorkspaceDirectory(kind: .directory, path: root.path),
                surfaces: [.codex],
                profile: WorkspaceSoundProfile(selectedPack: "workspace-pack", volume: 0.7))
            config.workspaceRules = [rule]
            try! JSONEncoder().encode(config).write(to: file)
            let environment = makeAudioImportEnvironment(userPacksDirectory: packs)
            let lock = root.appendingPathComponent("config.lock")
            let controller = PanelConfigController(
                configFile: file, lockFile: lock, environment: environment)
            let model = SoundPacksWindowModel(
                configFile: file, lockFile: lock, environment: environment,
                refreshCoordinator: SoundPacksRefreshCoordinator())
            model.setWorkspacePackWriter { target, packID in
                controller.changeWorkspace(.pack(target, packID))
                    ? .success(()) : .failure(controller.workspaceError ?? .configFailure)
            }
            model.setManagedScope(.workspace(rule.id))
            expect(
                model.config.selectedPack == "workspace-pack"
                    && model.config.masterVolume == 0.7,
                "声音页须投影目标工作区的包及音量")
            expect(model.selectPackForInspection("next-pack"), "测试包应可供检查")
            expect(
                model.useSelectedPack() == .success(.selected(packID: "next-pack")),
                "使用按钮应写入工作区")
            var readback = loadClaudioConfig(from: file)!
            expect(
                readback.selectedPack == "default-pack"
                    && readback.workspaceRules.first?.profile?.selectedPack == "next-pack",
                "工作区使用不得改写默认组")
            expect(model.selectPackForInspection("workspace-pack"), "复制源包应可供检查")
            guard case .success(let copy) = model.copySelectedPack() else {
                expect(false, "复制并应用测试必须先复制包")
                return
            }
            expect(
                model.applyPackSelection(
                    copy.newPackID, toScope: .workspace(rule.id),
                    allowFreshlyPublishedPack: true)
                    == .success(.selected(packID: copy.newPackID)),
                "复制后的包须通过工作区原有配置写入入口应用")
            readback = loadClaudioConfig(from: file)!
            expect(
                readback.selectedPack == "default-pack"
                    && readback.workspaceRules.first?.profile?.selectedPack == copy.newPackID,
                "复制并应用不得改写默认组")

            readback.workspaceRules = []
            try! JSONEncoder().encode(readback).write(to: file)
            expect(model.selectPackForInspection("next-pack"), "过期写入测试仍可检查包")
            expect(
                model.useSelectedPack() == .failure(.workspace(.staleRule)),
                "删除后的工作区须由原有写入口拒绝")
            let englishFailure = localizedWorkspaceError(.staleRule, language: .english)
            let chineseFailure = localizedWorkspaceError(.staleRule, language: .zhHans)
            let useStatus = model.windowStatuses.first(where: { $0.kind == .packUse })
            expect(
                englishFailure != chineseFailure
                    && useStatus?.message(language: .english) == englishFailure
                    && useStatus?.message(language: .zhHans) == chineseFailure,
                "工作区切包失败状态须按当前语言解析，切换语言后不能保留中文 literal")
            expect(
                model.managedScopeFailureStatusText?.resolve(language: .english)
                    == englishFailure,
                "失效工作区的拒写状态须按英文解析")
            guard
                case .failure(.writesStopped) = model.assignSelectedAudioFile(
                    "tone.aiff", to: .stop)
            else {
                expect(false, "失效工作区必须拒绝后续声音映射写入")
                return
            }
            let rejectedStatus = model.windowStatuses.first(where: { $0.kind == .audio })
            expect(
                rejectedStatus?.message(language: .english) == englishFailure
                    && rejectedStatus?.message(language: .zhHans) == chineseFailure,
                "后续拒写状态须保留类型化原因并随语言变化")
            expect(
                loadClaudioConfig(from: file)?.selectedPack == "default-pack"
                    && !model.writesAllowed,
                "陈旧写入不得回退默认组，读回后应停止继续写入")
        }
    }
    suite("工作区编辑与复制应用拒绝同 UUID 换绑的目录") {
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
                    kind: .directory, path: root.appendingPathComponent("a").path),
                surfaces: [.codex],
                profile: WorkspaceSoundProfile(selectedPack: "workspace-pack", volume: 0.7))
            var config = ClaudioConfig(selectedPack: "default-pack", masterVolume: 0.2)
            config.workspaceRules = [original]
            try! JSONEncoder().encode(config).write(to: file)
            let environment = makeAudioImportEnvironment(userPacksDirectory: packs)
            let controller = PanelConfigController(
                configFile: file, lockFile: lock, environment: environment)
            let model = SoundPacksWindowModel(
                configFile: file, lockFile: lock, environment: environment,
                refreshCoordinator: SoundPacksRefreshCoordinator())
            model.setWorkspacePackWriter { target, packID in
                controller.changeWorkspace(.pack(target, packID))
                    ? .success(()) : .failure(controller.workspaceError ?? .configFailure)
            }
            model.setManagedScope(.workspace(original.id))
            controller.selectSoundScope(.workspace(original.id))
            expect(model.selectPackForInspection("next-pack"), "新包可检查")

            let replacement = WorkspaceSoundRule(
                id: original.id,
                directory: WorkspaceDirectory(
                    kind: .directory, path: root.appendingPathComponent("b").path),
                surfaces: [.codex],
                profile: WorkspaceSoundProfile(selectedPack: "workspace-pack", volume: 0.7))
            config.workspaceRules = [replacement]
            try! JSONEncoder().encode(config).write(to: file)
            controller.reload()
            model.reload(followActivePack: false)
            expect(
                !model.writesAllowed && model.config.selectedPack.isEmpty
                    && model.managedScopeFailureStatusText?.resolve(language: .english)
                        == localizedWorkspaceError(.staleRule, language: .english),
                "声音编辑读回同 UUID 新目录后须立即停写并显示本地化失效说明")
            model.setManagedScope(.workspace(original.id))
            expect(!model.writesAllowed, "普通重复激活不得暗中换绑编辑目标")
            expect(
                controller.workspaceError == .staleRule
                    && controller.config.selectedPack.isEmpty
                    && controller.selectedWorkspaceTarget
                        == WorkspaceSoundWriteTarget(rule: original),
                "外部读回换绑不得自动接受新目录")
            expect(
                controller.switchPack(to: "next-pack") != .succeeded
                    && controller.workspaceError == .staleRule,
                "面板切包保留用户原先选中的目录")
            expect(
                controller.setVolume(0.9, for: .workspace(original.id)) == nil
                    && controller.workspaceError == .staleRule,
                "已选工作区音量不得写换绑目录")
            expect(
                controller.selectedWorkspaceWriteTarget == WorkspaceSoundWriteTarget(rule: original)
                    && controller.setVolume(
                        0.95, for: .workspace(original.id),
                        workspaceTarget: WorkspaceSoundWriteTarget(rule: replacement)) == nil
                    && controller.workspaceError == .staleRule,
                "延迟音量不能绕过用户原先捕获的目录目标")
            controller.toggleMute(.stop)
            expect(controller.workspaceError == .staleRule, "事件开关不得写换绑目录")
            expect(
                !controller.changeWorkspace(
                    .surfaces(WorkspaceSoundWriteTarget(rule: original), [.claudeCode]))
                    && controller.workspaceError == .staleRule,
                "适用来源不得写换绑目录")
            expect(
                model.useSelectedPack()
                    == .failure(.writesStopped(statusText: .localized(.workspaceUnavailable))),
                "使用按钮须在读回失效时停写同 UUID 的新目录")
            guard case .success(let copy) = model.copySelectedPack() else {
                expect(false, "复制应先独立成功")
                return
            }
            expect(
                model.applyPackSelection(
                    copy.newPackID, toScope: .workspace(original.id),
                    allowFreshlyPublishedPack: true)
                    == .failure(.writesStopped(statusText: .localized(.workspaceUnavailable))),
                "副本应用须在读回失效时停写同 UUID 的新目录")
            let readback = loadClaudioConfig(from: file)!
            expect(
                readback.selectedPack == "default-pack"
                    && readback.workspaceRules.first?.directory == replacement.directory
                    && readback.workspaceRules.first?.profile == replacement.profile
                    && readback.workspaceRules.first?.surfaces == replacement.surfaces,
                "拒写保留默认组与换绑后的工作区")
            expect(
                FileManager.default.fileExists(
                    atPath: packs.appendingPathComponent("\(copy.newPackID)/manifest.json").path),
                "应用失败仍保留可找回的副本")
            controller.selectSoundScope(
                .workspace(original.id), rebindSelectedWorkspace: true)
            expect(
                controller.workspaceError == nil
                    && controller.setVolume(0.8, for: .workspace(original.id)) == 0.8
                    && loadClaudioConfig(from: file)?.workspaceRules.first?.profile?.volume == 0.8,
                "用户显式重新选择后可编辑当前目录")
            model.setManagedScope(
                .workspace(original.id), rebindSelectedWorkspace: true)
            expect(
                model.writesAllowed && model.config.selectedPack == "workspace-pack"
                    && model.managedScopeFailureStatusText == nil,
                "声音编辑显式重选同一 UUID 后才绑定当前目录")
            expect(
                model.applyPackSelection("next-pack", toScope: .workspace(original.id))
                    == .success(.selected(packID: "next-pack"))
                    && loadClaudioConfig(from: file)?.workspaceRules.first?.profile?.selectedPack
                        == "next-pack"
                    && loadClaudioConfig(from: file)?.selectedPack == "default-pack",
                "重选后的包写入当前目录，默认组保持原值")
        }
    }
    suite("工作区控制器：独立配置、失败原值、失效路由和延迟音量目标") {
        withTempDirectory { root in
            let file = root.appendingPathComponent("config.json")
            let packs = root.appendingPathComponent("packs")
            for id in ["default-pack", "workspace-pack"] {
                writeFixture(
                    "{\"id\":\"\(id)\",\"name\":\"\(id)\",\"events\":{}}",
                    to: packs.appendingPathComponent("\(id)/manifest.json"))
            }
            var config = ClaudioConfig(selectedPack: "default-pack", masterVolume: 0.21)
            let rule = WorkspaceSoundRule(
                directory: WorkspaceDirectory(kind: .directory, path: root.path),
                surfaces: [.codex],
                profile: WorkspaceSoundProfile(selectedPack: "workspace-pack", volume: 0.74))
            config.workspaceRules = [rule]
            try! JSONEncoder().encode(config).write(to: file)
            let model = PanelConfigController(
                configFile: file, lockFile: root.appendingPathComponent("config.lock"),
                environment: AudioImportEnvironment(
                    userPacksDirectory: packs, durationProbe: StubDurationProbe(fixedDuration: 1),
                    packsLockFile: root.appendingPathComponent("packs.lock")))
            model.selectSoundScope(.workspace(rule.id))
            expect(
                model.config.selectedPack == "workspace-pack" && model.config.masterVolume == 0.74,
                "工作区整组独立投影")
            var damaged = config
            damaged.workspaceRules[0].profile = nil
            try! JSONEncoder().encode(damaged).write(to: file)
            model.reloadConfigOnly()
            expect(model.workspaceError == .invalidRule, "损坏规则显示结构性错误")
            try! JSONEncoder().encode(config).write(to: file)
            model.reloadConfigOnly()
            expect(
                model.workspaceError == nil && model.config.selectedPack == "workspace-pack",
                "外部修复后按有效读回清除结构性错误")
            for event in Event.allCases { model.toggleMute(event) }
            expect(Event.allCases.allSatisfy { !model.config.isEnabled($0) }, "五个事件可独立静音")
            expect(
                loadClaudioConfig(from: file)?.eventsEnabled == config.eventsEnabled, "工作区写入不改变默认事件"
            )
            let bytes = try! Data(contentsOf: file)
            _ = model.switchPack(to: "missing-pack")
            expect(
                model.config.selectedPack == "workspace-pack"
                    && model.workspaceError == .invalidPack, "失败保留原包并显示原因")
            expect((try! Data(contentsOf: file)) == bytes, "失败不写配置")
            let delayedVolumeTarget = WorkspaceSoundWriteTarget(rule: rule)
            model.selectSoundScope(.global)
            expect(
                model.setVolume(
                    0.55, for: .workspace(rule.id), workspaceTarget: delayedVolumeTarget) == 0.55,
                "切换后滑块仍写捕获的原工作区")
            expect(model.config.masterVolume == 0.21, "延迟提交不污染当前默认组")
            expect(
                loadClaudioConfig(from: file)?.workspaceRules.first?.profile?.volume == 0.55,
                "工作区音量落盘")
            expect(
                referencedSoundPackIDs(in: loadClaudioConfig(from: file)!).contains(
                    "workspace-pack"), "工作区使用中的包受删除保护")
            let stale = UUID()
            model.selectSoundScope(.workspace(stale))
            expect(
                model.workspaceError == .staleRule && model.config.selectedPack.isEmpty,
                "陈旧详情不回退默认组")
            expect(model.setVolume(0.99, for: .workspace(stale)) == nil, "陈旧音量拒写")
            model.selectSoundScope(.surface(.codex))
            expect(model.setMasterVolume(0.99) == nil, "旧来源音量入口拒写")
            expect(loadClaudioConfig(from: file)?.masterVolume == 0.21, "默认音量始终未变")
        }
    }
    suite("工作区展示：五项试听与宿主支持独立，回调不改变手动选择") {
        var config = ClaudioConfig(selectedPack: "default")
        let rule = WorkspaceSoundRule(
            directory: WorkspaceDirectory(kind: .directory, path: "/fixture/repository"),
            surfaces: [.codex], profile: WorkspaceSoundProfile(selectedPack: "pack", volume: 0.4))
        config.workspaceRules = [rule]
        let scopes = panelSoundScopePresentations(
            sourceRows: [], config: config, language: .english)
        let events = panelEventPresentations(
            rows: Event.allCases.map {
                EventRow(event: $0, coverage: .present(fileName: "tone.aiff"), enabled: true)
            },
            scope: .workspace(rule.id), masterVolume: 0.4, language: .english)
        expect(
            events.count == 5
                && events.allSatisfy { $0.controls.previewEnabled && $0.controls.muteEnabled },
            "Codex 不支持 StopFailure 不应禁止包试听或事件配置")
        expect(
            resolvedPanelSoundScopeSelection(
                storedValue: PanelSoundScopeID.workspace(rule.id).storedValue, scopes: scopes)
                == .workspace(rule.id), "手动选择保持稳定")
        let availability = SettingsRouteAvailability(
            integrationSurfaces: [.codex], eventScopes: Set(scopes.map(\.scope)),
            soundScopes: [.global], soundPackIDs: [], events: Set(Event.allCases))
        expect(
            resolveSettingsRoute(
                .events(scope: .workspace(rule.id), event: nil), availability: availability
            ).failure == nil, "工作区定向路由有效")
        expect(
            resolveSettingsRoute(
                .events(scope: .workspace(UUID()), event: nil), availability: availability
            ).failure != nil, "不存在的工作区路由失败")
    }
}
