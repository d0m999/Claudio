import ClaudioCore
import ClaudioGUICore
import Foundation

@MainActor
func runSoundPacksEditorOwnerSuites() {
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
