import ClaudioCore
import ClaudioGUICore
import Foundation

@MainActor
func runSoundPacksEditorOwnerSuites() {
    suite("SoundPacks editor owner：Scope→pack→Event 路由驱动唯一磁盘模型") {
        withTempDirectory { root in
            let packs = root.appendingPathComponent("packs", isDirectory: true)
            let pack = packs.appendingPathComponent("pack-a", isDirectory: true)
            writeFixture(
                #"{"id":"pack-a","events":{"stop":"stop.mp3"}}"#,
                to: pack.appendingPathComponent("manifest.json"))
            writeFixture("audio", to: pack.appendingPathComponent("stop.mp3"))
            let configFile = root.appendingPathComponent("config.json")
            let configLock = root.appendingPathComponent("config.lock")
            let config = ClaudioConfig(
                selectedPack: "global-pack",
                surfaceOverrides: [
                    HostSurfaceID.workBuddy.rawValue: SurfaceSoundOverride(
                        selectedPack: "pack-a")
                ])
            writeFixture(try! JSONEncoder().encode(config), to: configFile)
            let environment = makeAudioImportEnvironment(userPacksDirectory: packs)
            let owner = SoundPacksEditorOwner(
                configFile: configFile,
                lockFile: configLock,
                environment: environment,
                refreshCoordinator: SoundPacksRefreshCoordinator())
            let route = SoundPacksWindowRoute.editEvent(
                surface: .workBuddy,
                packID: "pack-a",
                event: .stop)

            expect(owner.apply(route: route) == .resolved(route), "存在的 typed 路由必须原样解析")
            expect(owner.model.managedSurface == .workBuddy, "owner 必须把 Scope 交给共享模型")
            expect(owner.model.selectedPackID == "pack-a", "owner 必须在共享模型选中 typed pack")
            expect(
                owner.model.config.selectedPack == "pack-a",
                "Surface scope 必须投影自己的 effective pack，而非 Global 包")
            expect(
                owner.model.selectedEventRows.contains {
                    $0.event == .stop && $0.coverage == .present(fileName: "stop.mp3")
                },
                "typed Event 必须落到该 pack 的真实映射行")
        }
    }

    suite("SoundPacks editor owner：未完成 snapshot 保持 pending，ready 缺失才降级") {
        withTempDirectory { root in
            let environment = makeAudioImportEnvironment(
                userPacksDirectory: root.appendingPathComponent("packs", isDirectory: true))
            let route = SoundPacksWindowRoute.editEvent(
                surface: nil,
                packID: "delayed-pack",
                event: .notification)
            let pendingModel = SoundPacksWindowModel(
                previewConfig: ClaudioConfig(selectedPack: "global-pack"),
                packCards: [],
                selectedPackID: nil,
                selectedEventRows: [],
                libraryPresentationState: .loading,
                environment: environment,
                refreshCoordinator: SoundPacksRefreshCoordinator())
            let pendingOwner = SoundPacksEditorOwner(
                model: pendingModel,
                userPacksDirectory: environment.userPacksDirectory)

            expect(
                pendingOwner.apply(route: route) == .pending(route),
                "loading 不能把尚未出现的 deep link 误判为永久缺失")

            let readyModel = SoundPacksWindowModel(
                previewConfig: ClaudioConfig(selectedPack: "global-pack"),
                packCards: [],
                selectedPackID: nil,
                selectedEventRows: [],
                libraryPresentationState: .ready,
                environment: environment,
                refreshCoordinator: SoundPacksRefreshCoordinator())
            let readyOwner = SoundPacksEditorOwner(
                model: readyModel,
                userPacksDirectory: environment.userPacksDirectory)

            expect(
                readyOwner.apply(route: route) == .resolved(.overview(surface: nil)),
                "只有 fresh ready snapshot 证明 pack 缺失后才可降级 overview")
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
                && model.selectedPackCanRestoreFactory,
            "可见 Retry、失败 lifecycle 与 builtin selection 必须指向同一 pack")
    }
}
