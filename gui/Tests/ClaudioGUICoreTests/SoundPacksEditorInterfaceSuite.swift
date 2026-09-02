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
