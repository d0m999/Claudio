import ClaudioCore
import ClaudioGUICore
import Foundation

@MainActor
func runSoundPacksEditorCharacterizationSuites() async {
    await suite("Sound editor baseline：library lifecycle 与 deep link 保留当前决议语义") {
        await withTempDirectory { root in
            let packs = root.appendingPathComponent("packs", isDirectory: true)
            writeFixture(
                #"{"id":"pack-a","name":"Pack A","events":{"stop":"stop.mp3"}}"#,
                to: packs.appendingPathComponent("pack-a/manifest.json"))
            writeFixture("audio", to: packs.appendingPathComponent("pack-a/stop.mp3"))
            let environment = makeAudioImportEnvironment(userPacksDirectory: packs)
            let library = SoundPackLibrary(environment: environment)
            guard case .ready(let snapshot) = await library.refreshSnapshot(trigger: .initial)
            else {
                expect(false, "fixture 必须先产生 fresh ready snapshot")
                return
            }

            let model = SoundPacksWindowModel(
                previewConfig: ClaudioConfig(selectedPack: "pack-a"),
                packCards: [],
                selectedPackID: nil,
                selectedEventRows: [],
                libraryPresentationState: .ready,
                environment: environment,
                refreshCoordinator: SoundPacksRefreshCoordinator())
            let owner = SoundPacksEditorOwner(
                model: model,
                userPacksDirectory: environment.userPacksDirectory)
            let missingRoute = SoundPacksWindowRoute.editEvent(
                surface: nil,
                packID: "missing-pack",
                event: .stop)

            model.consumeSoundPackLibraryStateForTesting(.unloaded)
            expect(model.libraryPresentationState == .loading, "unloaded 投影为首次 loading")
            expect(
                owner.apply(route: missingRoute) == .pending(missingRoute),
                "unloaded 尚无事实，必须保留 deep link")

            model.consumeSoundPackLibraryStateForTesting(.loading(previous: nil))
            expect(model.libraryPresentationState == .loading, "无 previous 的 loading 仍是首次加载")
            expect(
                owner.apply(route: missingRoute) == .pending(missingRoute),
                "loading 不能把缺卡片当成缺包事实")

            model.consumeSoundPackLibraryStateForTesting(.ready(snapshot))
            expect(
                model.libraryPresentationState == .ready
                    && model.packCards.map(\.id) == ["pack-a"],
                "ready 必须交付 fresh pack facts")
            expect(
                owner.apply(route: missingRoute) == .resolved(.overview(surface: nil)),
                "b64336f baseline：fresh ready 证实缺包后降级 overview；#129 改为可见 stale failure")

            model.consumeSoundPackLibraryStateForTesting(.loading(previous: snapshot))
            expect(
                model.libraryPresentationState == .refreshing
                    && model.packCards.map(\.id) == ["pack-a"],
                "带 previous 的 loading 必须继续交付陈旧快照")
            expect(
                owner.apply(route: missingRoute) == .pending(missingRoute),
                "刷新期间不能用 previous 永久否定 deep link")

            model.consumeSoundPackLibraryStateForTesting(
                .failed(previous: snapshot, error: .scanFailed(reason: "refresh failed")))
            guard case .refreshFailed(let refreshReason) = model.libraryPresentationState else {
                expect(false, "带 previous 的失败必须投影 refreshFailed")
                return
            }
            expect(
                refreshReason == "refresh failed" && model.packCards.map(\.id) == ["pack-a"],
                "refreshFailed 必须保留上次真实 pack facts 与原失败")
            expect(
                owner.apply(route: missingRoute) == .pending(missingRoute),
                "failed(previous) 不能把旧快照当成 fresh 缺失证明")

            let hardFailureModel = SoundPacksWindowModel(
                previewConfig: ClaudioConfig(selectedPack: "pack-a"),
                packCards: [
                    PackCard(
                        id: "stale-fixture",
                        name: "Stale Fixture",
                        isCC0: false,
                        presentEvents: [],
                        state: .complete,
                        isSelected: true)
                ],
                selectedPackID: "stale-fixture",
                selectedEventRows: [],
                environment: environment,
                refreshCoordinator: SoundPacksRefreshCoordinator())
            hardFailureModel.consumeSoundPackLibraryStateForTesting(
                .failed(previous: nil, error: .scanFailed(reason: "initial failed")))
            expect(
                hardFailureModel.libraryPresentationState
                    == .loadFailed(reason: "initial failed")
                    && hardFailureModel.packCards.isEmpty
                    && hardFailureModel.selectedPackID == nil,
                "首次 failed(nil) 必须清掉未证实 fixture，不得保留假选择")
        }
    }

    suite("Sound editor baseline：陈旧破坏性目标与重复确认都零额外副作用") {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let lockFile = root.appendingPathComponent("config.lock")
            let packs = root.appendingPathComponent("packs", isDirectory: true)
            let pack = packs.appendingPathComponent("pack-a", isDirectory: true)
            let orphan = pack.appendingPathComponent("orphan.mp3")
            writeFixture(
                #"{"selected_pack":"pack-a","events":{},"future":{"keep":true}}"#,
                to: configFile)
            writeFixture(
                #"{"id":"pack-a","events":{"stop":"used.mp3"}}"#,
                to: pack.appendingPathComponent("manifest.json"))
            writeFixture("used", to: pack.appendingPathComponent("used.mp3"))
            writeFixture("orphan", to: orphan)
            let configBefore = try? Data(contentsOf: configFile)
            let coordinator = SoundPacksRefreshCoordinator()
            let model = SoundPacksWindowModel(
                configFile: configFile,
                lockFile: lockFile,
                environment: makeAudioImportEnvironment(userPacksDirectory: packs),
                refreshCoordinator: coordinator)

            let stale = model.deleteSelectedOrphanAudioFileAfterConfirmation(
                "orphan.mp3",
                expectedPackID: "previous-pack")
            if case .failure(.selectionChanged) = stale {
                expect(true, "选择代次漂移拒绝旧确认目标")
            } else {
                expect(false, "选择代次漂移必须拒绝旧确认目标，实得 \(stale)")
            }
            expect(
                regularFileExists(at: orphan)
                    && (try? Data(contentsOf: configFile)) == configBefore
                    && coordinator.panelReloadRevision == 0,
                "陈旧确认必须保持文件/config 字节并发布零 refresh")

            let confirmed = model.deleteSelectedOrphanAudioFileAfterConfirmation(
                "orphan.mp3",
                expectedPackID: "pack-a")
            if case .success = confirmed {
                expect(true, "第一次有效确认执行原写路径")
            } else {
                expect(false, "第一次有效确认必须执行原写路径，实得 \(confirmed)")
            }
            expect(!regularFileExists(at: orphan), "有效确认必须移除目标孤儿文件")
            expect(coordinator.panelReloadRevision == 1, "真实 pack mutation 必须恰好一次 refresh")

            let replayed = model.deleteSelectedOrphanAudioFileAfterConfirmation(
                "orphan.mp3",
                expectedPackID: "pack-a")
            if case .failure(.delete(.fileNotFound(fileName: "orphan.mp3"))) = replayed {
                expect(true, "同一确认重放不能再次成功")
            } else {
                expect(false, "同一确认重放必须命中当前磁盘事实，实得 \(replayed)")
            }
            expect(
                coordinator.panelReloadRevision == 1
                    && (try? Data(contentsOf: configFile)) == configBefore,
                "重复确认只能得到当前事实失败，不得再 refresh 或改 config")
        }
    }

    suite("Sound editor baseline：view confirmation 只消费 owner 的 opaque capability") {
        guard
            let source = soundEditorCharacterizationSource(
                "gui/Sources/SoundPacksWindow/SoundPacksWindowView.swift")
        else {
            expect(false, "读不到当前 SoundPacksWindowView source seam")
            return
        }

        expect(
            source.contains("presentation.pendingConfirmation")
                && source.contains("invoke(confirmation.confirmAction)")
                && source.contains("invoke(confirmation.cancelAction)")
                && source.contains("cancelConfirmation("),
            "dismiss、confirm 与 cancel 必须统一回送 owner 签发的 confirmation capability")
        for forbidden in [
            "@State private var pendingPermanentDeletion",
            "@State private var pendingUserPackDeletion",
            "@State private var pendingFactoryPackRestore",
            "deleteSelectedOrphanAudioFileAfterConfirmation(",
            "deleteSelectedUserPackAfterConfirmation(",
            "restoreSelectedFactoryPackAfterConfirmation(",
            "retryFailedFactoryPackRestoreAfterConfirmation(",
            "restoreAllFactoryPacksAfterConfirmation()",
        ] {
            expect(
                !source.contains(forbidden),
                "view 不得保留本地 confirmation 状态或直调 raw model 写入：\(forbidden)")
        }
    }

}

private func soundEditorCharacterizationSource(_ relativePath: String) -> String? {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    return try? String(
        contentsOf: root.appendingPathComponent(relativePath),
        encoding: .utf8)
}
