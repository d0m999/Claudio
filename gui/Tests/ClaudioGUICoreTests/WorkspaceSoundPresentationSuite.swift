import ClaudioCore
import ClaudioGUICore
import ClaudioLocalization
import Foundation

@MainActor
func runWorkspaceSoundPresentationSuites() {
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
            model.selectSoundScope(.global)
            expect(model.setVolume(0.55, for: .workspace(rule.id)) == 0.55, "切换后滑块仍写捕获的原工作区")
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
