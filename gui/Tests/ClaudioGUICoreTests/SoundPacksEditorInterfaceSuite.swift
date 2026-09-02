import ClaudioCore
import ClaudioGUICore
import Combine
import Foundation

@MainActor
func runSoundPacksEditorInterfaceSuites() async {
    await suite("Sound editor interface：一次 transition 只发布一个 coherent root") {
        await withTempDirectory { root in
            let packs = root.appendingPathComponent("packs", isDirectory: true)
            writeFixture(
                #"{"id":"pack-a","events":{"stop":"stop.mp3"}}"#,
                to: packs.appendingPathComponent("pack-a/manifest.json"))
            writeFixture("audio", to: packs.appendingPathComponent("pack-a/stop.mp3"))
            let environment = makeAudioImportEnvironment(userPacksDirectory: packs)
            let library = SoundPackLibrary(environment: environment)
            guard case .ready(let snapshot) = await library.refreshSnapshot(trigger: .initial)
            else {
                expect(false, "fixture 必须产生 ready snapshot")
                return
            }
            let model = SoundPacksWindowModel(
                previewConfig: ClaudioConfig(selectedPack: "pack-a"),
                packCards: [],
                selectedPackID: nil,
                selectedEventRows: [],
                libraryPresentationState: .loading,
                environment: environment,
                refreshCoordinator: SoundPacksRefreshCoordinator())
            let owner = SoundPacksEditorOwner(
                model: model,
                userPacksDirectory: environment.userPacksDirectory)

            expect(owner.presentation.mode == .inactive, "owner 初始必须是 inactive slice")
            expect(
                owner.presentation.library == .loading(previousAvailable: false),
                "初始 library 必须诚实投影 loading")

            var emissions: [SoundPacksEditorPresentation] = []
            var cancellables = Set<AnyCancellable>()
            owner.$presentation.dropFirst().sink { emissions.append($0) }.store(in: &cancellables)

            let route = SoundPacksWindowRoute.editEvent(
                surface: nil,
                packID: "pack-a",
                event: .stop)
            expect(
                owner.send(.activate(.sounds(route: route, requestRevision: 7))) == .applied,
                "activate 必须同步应用")
            expect(emissions.count == 1, "activate 的多字段 model transition 只能发布一个 root")
            guard case .sounds(let pending) = owner.presentation.mode else {
                expect(false, "activate Sounds 必须发布 sounds slice")
                return
            }
            expect(
                pending.routeState == .pendingFreshSnapshot,
                "fresh ready 前 deep link 必须保持 pending")

            model.consumeSoundPackLibraryStateForTesting(.ready(snapshot))
            expect(emissions.count == 2, "library settle 必须只再发布一个完整 root")
            guard case .sounds(let ready) = owner.presentation.mode else {
                expect(false, "ready 后仍必须是 sounds slice")
                return
            }
            expect(
                ready.routeState == .resolved(route)
                    && ready.selectedPack?.id == "pack-a"
                    && ready.eventRows.first(where: { $0.event == .stop })?.coverage
                        == .present(fileName: "stop.mp3"),
                "ready root 必须同时包含新 route、selection 与 event rows")
        }
    }

    await suite("Sound editor interface：reentrant subscriber 不能让旧 root 覆盖新 root") {
        await withTempDirectory { root in
            let fixture = makeSoundEditorFixture(root: root, packIDs: ["pack-a", "pack-b"])
            let owner = fixture.owner
            _ = owner.send(.activate(.sounds(route: .overview, requestRevision: 8)))
            await waitForSoundEditorReady(owner, library: fixture.library)
            guard case .sounds(let initial) = owner.presentation.mode,
                initial.selectedPack?.id == "pack-a",
                let inspectB = initial.packs.first(where: { $0.id == "pack-b" })?.inspectAction
            else {
                expect(false, "ready fixture 必须从 pack-a 签发 inspect pack-b capability")
                return
            }

            var emittedSelections: [String?] = []
            var reentrantResult: SoundPacksEditorCommandResult?
            var didReenter = false
            var cancellables = Set<AnyCancellable>()
            owner.$presentation.dropFirst().sink { emitted in
                guard case .sounds(let sounds) = emitted.mode else { return }
                emittedSelections.append(sounds.selectedPack?.id)
                guard !didReenter, sounds.selectedPack?.id == "pack-b",
                    let inspectA = sounds.packs.first(where: { $0.id == "pack-a" })?.inspectAction
                else { return }
                didReenter = true
                reentrantResult = owner.send(.invoke(inspectA))
            }.store(in: &cancellables)

            expect(owner.send(.invoke(inspectB)) == .applied, "outer inspect 必须应用")
            expect(reentrantResult == .applied, "subscriber 中的 reentrant inspect 必须应用")
            expect(
                emittedSelections.prefix(2).elementsEqual(["pack-b", "pack-a"]),
                "subscriber 必须按 B→A 观察两个完整 root")
            guard case .sounds(let final) = owner.presentation.mode else {
                expect(false, "reentrant transition 后必须保持 sounds slice")
                return
            }
            expect(final.selectedPack?.id == "pack-a", "最新 A root 不能被 outer B setter 覆盖")
            guard let finalInspectB = final.packs.first(where: { $0.id == "pack-b" })?.inspectAction
            else {
                expect(false, "最终 A root 必须携带自己的 capability ledger")
                return
            }
            expect(
                owner.send(.invoke(finalInspectB)) == .applied,
                "最终可见 root 的 capability 必须与 owner ledger 一致")
        }
    }

    await suite("Sound editor interface：duplicate terminal 不虚增 revision 或重签 capability") {
        await withTempDirectory { root in
            let fixture = makeSoundEditorFixture(root: root, packIDs: ["pack-a", "pack-b"])
            let owner = fixture.owner
            let context = SoundPacksEditorContext.sounds(route: .overview, requestRevision: 9)
            _ = owner.send(.activate(context))
            await waitForSoundEditorReady(owner, library: fixture.library)
            await waitForSoundEditorInventory(owner)
            guard case .sounds(let beforeSounds) = owner.presentation.mode,
                let oldInspectB = beforeSounds.packs.first(where: { $0.id == "pack-b" })?
                    .inspectAction
            else {
                expect(false, "ready fixture 必须签发 inspect pack-b capability")
                return
            }
            let before = owner.presentation
            let staleLibraryState = await fixture.library.stateForTesting()
            var emissions: [SoundPacksEditorPresentation] = []
            var cancellables = Set<AnyCancellable>()
            owner.$presentation.dropFirst().sink { emissions.append($0) }.store(in: &cancellables)

            await fixture.library.replayStateForTesting()
            for _ in 0..<64 { await Task.yield() }

            expect(emissions.isEmpty, "完全相同的 library terminal 不得再发布")
            expect(owner.presentation == before, "duplicate terminal 不得虚增 revision 或换 capability")

            guard
                case .ready(let refreshedSnapshot) =
                    await fixture.library.refreshSnapshot(trigger: .retry)
            else {
                expect(false, "fixture 必须产生更新的 ready generation")
                return
            }
            for _ in 0..<512 {
                if owner.presentation.library
                    == .ready(snapshotRevision: refreshedSnapshot.revision)
                {
                    break
                }
                await Task.yield()
            }
            await waitForSoundEditorInventory(owner)
            let afterRefresh = owner.presentation
            guard case .sounds(let refreshedSounds) = afterRefresh.mode,
                let refreshedInspectB = refreshedSounds.packs.first(where: { $0.id == "pack-b" })?
                    .inspectAction
            else {
                expect(false, "新一代 ready root 必须重签 capability")
                return
            }
            emissions.removeAll()

            await fixture.library.replayStateForTesting(staleLibraryState)
            for _ in 0..<64 { await Task.yield() }
            expect(emissions.isEmpty, "较旧 library terminal 不得触发假 settle")
            expect(owner.presentation == afterRefresh, "stale terminal 不得回滚 root 或重签 capability")

            expect(owner.send(.activate(context)) == .applied, "显式重复 activate 仍必须应用")
            guard case .sounds(let reactivated) = owner.presentation.mode,
                let newInspectB = reactivated.packs.first(where: { $0.id == "pack-b" })?
                    .inspectAction
            else {
                expect(false, "reactivate 后必须重签当前 root")
                return
            }
            expect(
                owner.presentation.revision == afterRefresh.revision + 1
                    && newInspectB != refreshedInspectB,
                "显式 activate 必须换代，不能被 semantic no-op 吞掉")
            expect(
                owner.send(.invoke(oldInspectB)) == .rejected(.staleAction),
                "reactivate 前 capability 必须失效")
            expect(owner.send(.invoke(newInspectB)) == .applied, "reactivate 新 capability 必须可用")
        }
    }

    suite("Sound editor interface：fresh missing 保留 typed route 并显示 stale failure") {
        let environment = makeAudioImportEnvironment(
            userPacksDirectory: URL(fileURLWithPath: "/dev/null/editor-interface-packs"))
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
        let route = SoundPacksWindowRoute.editEvent(
            surface: nil,
            packID: "missing-pack",
            event: .notification)

        _ = owner.send(.activate(.sounds(route: route, requestRevision: 11)))
        guard case .sounds(let sounds) = owner.presentation.mode else {
            expect(false, "Sounds route 必须保持 sounds slice")
            return
        }
        expect(
            sounds.route == route
                && sounds.routeState == .staleTarget(packID: "missing-pack"),
            "fresh missing 不能伪装成成功 overview")
        expect(sounds.packs.isEmpty && sounds.selectedPack == nil, "missing target 不得合成已安装包")
    }
}
