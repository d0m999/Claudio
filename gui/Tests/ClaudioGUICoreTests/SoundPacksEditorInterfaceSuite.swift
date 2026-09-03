import ClaudioCore
import ClaudioGUICore
import Combine
import Foundation

@MainActor
func runSoundPacksEditorInterfaceSuites() async {
    await suite("Sound editor Events interface：投影语义资格与 opaque 试听 capability") {
        await withTempDirectory { root in
            let config = ClaudioConfig(
                selectedPack: "global-pack",
                masterVolume: 0.42,
                surfaceOverrides: [
                    HostSurfaceID.workBuddy.rawValue: SurfaceSoundOverride(
                        selectedPack: "workbuddy-pack")
                ])
            let fixture = makeSoundEditorFixture(
                root: root,
                packIDs: ["global-pack", "workbuddy-pack"],
                config: config)
            let owner = fixture.owner
            let route = EventSettingsWindowRoute(
                scope: .surface(.workBuddy),
                event: .stop)

            expect(
                owner.send(
                    .activate(
                        .events(
                            route: route,
                            requestRevision: 131,
                            candidateGenerationID: nil))) == .applied,
                "Events activation 必须同步应用")
            await waitForSoundEditorReady(owner, library: fixture.library)

            guard case .events(let events) = owner.presentation.mode,
                let stop = events.eventAccess.first(where: { $0.event == .stop })
            else {
                expect(false, "ready Events root 必须投影逐事件 access")
                return
            }
            expect(
                stop.adoptionAvailability == .eligible && events.adoptionPermit == nil,
                "合格目标尚无 generation 时必须显示 eligible，但不能提前签发 permit")
            expect(
                stop.previewAvailability == .available(fileName: "stop.mp3")
                    && stop.previewAction != nil,
                "现有安全映射必须只通过 owner-signed preview action 暴露")

            guard let previewAction = stop.previewAction,
                case .nativeEffect(.playAudio(let fileURL, let volume)) =
                    owner.send(.invoke(previewAction))
            else {
                expect(false, "逐事件试听 action 必须返回 exact native effect")
                return
            }
            expect(
                fileURL
                    == root.appendingPathComponent("packs/workbuddy-pack/stop.mp3")
                    && volume == 0.42,
                "native effect 必须携带 owner 复核后的文件与全局 master_volume")
            expect(
                owner.send(.invoke(previewAction)) == .rejected(.staleAction),
                "试听 capability 必须 single-use")

            _ = owner.send(
                .activate(
                    .events(
                        route: EventSettingsWindowRoute(scope: .global, event: .stop),
                        requestRevision: 132,
                        candidateGenerationID: nil)))
            guard case .events(let global) = owner.presentation.mode,
                let globalStop = global.eventAccess.first(where: { $0.event == .stop })
            else {
                expect(false, "Global Events root 必须保持逐事件语义投影")
                return
            }
            expect(
                globalStop.adoptionAvailability == .ineligible(.surfaceRequired),
                "Global 必须由 owner 明确投影为不合格，不能与 nil generation 混淆")
        }
    }

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

            let beforeRefreshRevision = owner.presentation.revision
            guard case .ready = await fixture.library.refreshSnapshot(trigger: .retry) else {
                expect(false, "fixture 必须产生更新的 ready generation")
                return
            }
            for _ in 0..<512 {
                if case .ready = owner.presentation.library,
                    owner.presentation.revision > beforeRefreshRevision
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
            expect(
                afterRefresh.library == .ready,
                "package interface 的 ready status 不得暴露 snapshot revision")
            expect(
                afterRefresh.revision > beforeRefreshRevision
                    && refreshedInspectB != oldInspectB,
                "新 library generation 必须通过 root revision 与新 capability identity 可观察")
            expect(
                owner.send(.invoke(oldInspectB)) == .rejected(.staleAction),
                "旧 library generation 的 capability 必须失效")
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
                owner.send(.invoke(refreshedInspectB)) == .rejected(.staleAction),
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

    await suite("Sound editor presentation：inspection 与 active scope 是两个事实") {
        await withTempDirectory { root in
            let fixture = makeSoundEditorFixture(root: root, packIDs: ["pack-a", "pack-b"])
            let owner = fixture.owner
            _ = owner.send(.activate(.sounds(route: .overview, requestRevision: 21)))
            await waitForSoundEditorReady(owner, library: fixture.library)
            guard case .sounds(let initial) = owner.presentation.mode,
                let inspectB = initial.packs.first(where: { $0.id == "pack-b" })?.inspectAction
            else {
                expect(false, "ready fixture 必须可 inspect pack-b")
                return
            }

            expect(owner.send(.invoke(inspectB)) == .applied, "inspect pack-b 必须应用")
            guard case .sounds(let inspected) = owner.presentation.mode,
                let packA = inspected.packs.first(where: { $0.id == "pack-a" }),
                let packB = inspected.packs.first(where: { $0.id == "pack-b" })
            else {
                expect(false, "inspect 后必须保留两个安装包的 presentation")
                return
            }

            expect(
                packA.isActiveForScope && !packA.isInspected,
                "pack-a 仍是当前 scope 的 active pack，但不再是 inspection selection")
            expect(
                !packB.isActiveForScope && packB.isInspected,
                "pack-b 只是 inspection selection，不能伪装成 active pack")
            expect(packA.useAction == nil, "active pack 不应签发冗余 Use capability")
            expect(packA.deleteAction == nil, "active pack 不得因未被 inspect 就变成可删除")
            expect(packB.useAction != nil, "非 active 的 inspected pack 必须可 Use")
            expect(packB.deleteAction != nil, "未被任何 scope 引用的 inspected pack 必须可删除")
        }
    }

    await suite("Sound editor presentation：Surface active、Global reference 与 inspection 分离") {
        await withTempDirectory { root in
            let fixture = makeSoundEditorFixture(
                root: root,
                packIDs: ["pack-a", "pack-b"],
                config: ClaudioConfig(
                    selectedPack: "pack-a",
                    surfaceOverrides: [
                        HostSurfaceID.workBuddy.rawValue: SurfaceSoundOverride(
                            selectedPack: "pack-b")
                    ]))
            let owner = fixture.owner
            let route = SoundPacksWindowRoute.overview(surface: .workBuddy)
            _ = owner.send(.activate(.sounds(route: route, requestRevision: 29)))
            await waitForSoundEditorReady(owner, library: fixture.library)
            guard case .sounds(let initial) = owner.presentation.mode,
                let inspectA = initial.packs.first(where: { $0.id == "pack-a" })?.inspectAction
            else {
                expect(false, "Surface fixture 必须可 inspect Global 引用的 pack-a")
                return
            }

            expect(owner.send(.invoke(inspectA)) == .applied, "inspect pack-a 必须应用")
            guard case .sounds(let inspected) = owner.presentation.mode,
                let packA = inspected.packs.first(where: { $0.id == "pack-a" }),
                let packB = inspected.packs.first(where: { $0.id == "pack-b" })
            else {
                expect(false, "inspect 后必须保留 Global A 与 Surface B presentation")
                return
            }

            expect(inspected.selectedPack?.id == "pack-a", "inspection selection 必须指向 pack-a")
            expect(
                packA.isInspected && !packA.isActiveForScope,
                "Global A 可被 inspect，但不是 Surface active")
            expect(packA.isReferencedByAnyScope, "Global selected_pack 必须计入跨 scope reference")
            expect(packA.useAction != nil, "被 Global 引用不妨碍将 A 用于当前 Surface")
            expect(packA.deleteAction == nil, "被任一 scope 引用的 A 不得签 Delete")

            expect(
                !packB.isInspected && packB.isActiveForScope, "Surface B 仍 active，但不是 inspection")
            expect(packB.isReferencedByAnyScope, "Surface override 必须计入跨 scope reference")
            expect(packB.useAction == nil, "当前 Surface active B 不得签冗余 Use")
            expect(packB.deleteAction == nil, "当前 Surface 引用的 B 不得签 Delete")
        }
    }

    await suite("Sound editor presentation：CC0 与 factory integrity 可直接渲染") {
        await withTempDirectory { root in
            let packs = root.appendingPathComponent("packs", isDirectory: true)
            let factory = root.appendingPathComponent("factory-packs", isDirectory: true)
            for packID in ["factory-clean", "factory-modified"] {
                let manifest =
                    """
                    {"id":"\(packID)","name":"\(packID)","license":"CC0-1.0","events":{"stop":"stop.mp3"}}
                    """
                writeFixture(
                    manifest,
                    to: packs.appendingPathComponent("\(packID)/manifest.json"))
                writeFixture(
                    manifest,
                    to: factory.appendingPathComponent("\(packID)/manifest.json"))
                writeFixture(
                    "factory-audio",
                    to: factory.appendingPathComponent("\(packID)/stop.mp3"))
                writeFixture(
                    packID == "factory-clean" ? "factory-audio" : "user-modified-audio",
                    to: packs.appendingPathComponent("\(packID)/stop.mp3"))
            }
            let environment = makeAudioImportEnvironment(
                userPacksDirectory: packs,
                factoryPacksDirectory: factory)
            let fixture = makePresentationEditorFixture(
                root: root,
                environment: environment,
                config: ClaudioConfig(selectedPack: "factory-clean"))
            let owner = fixture.owner
            _ = owner.send(.activate(.sounds(route: .overview, requestRevision: 22)))
            await waitForSoundEditorReady(owner, library: fixture.library)

            guard case .sounds(let sounds) = owner.presentation.mode,
                let clean = sounds.packs.first(where: { $0.id == "factory-clean" }),
                let modified = sounds.packs.first(where: { $0.id == "factory-modified" })
            else {
                expect(false, "factory fixture 必须投影 clean 与 modified 两张 card")
                return
            }
            expect(clean.isCC0, "presentation 必须直接携带 manifest 的 CC0 fact")
            expect(clean.factoryIntegrity == true, "未修改 factory pack 必须直接携带 integrity")
            expect(modified.isCC0, "修改本地字节不应抹去 manifest 的 CC0 fact")
            expect(modified.factoryIntegrity == false, "修改 factory pack 必须直接携带 modified fact")
            expect(
                packRowMetaSlots(
                    isCC0: clean.isCC0,
                    state: clean.state,
                    factoryIntegrity: clean.factoryIntegrity
                ).license == .cc0,
                "clean presentation 不借助 raw model 即可渲染 CC0")
            expect(
                packRowMetaSlots(
                    isCC0: modified.isCC0,
                    state: modified.state,
                    factoryIntegrity: modified.factoryIntegrity
                ).license == .modified,
                "modified presentation 不借助 raw model 即可渲染 modified")
        }
    }

    await suite("Sound editor presentation：library lifecycle 与 failure reason 语义化且脱敏") {
        await withTempDirectory { root in
            let packs = root.appendingPathComponent("packs", isDirectory: true)
            writeFixture(
                #"{"id":"pack-a","events":{"stop":"stop.mp3"}}"#,
                to: packs.appendingPathComponent("pack-a/manifest.json"))
            writeFixture("audio", to: packs.appendingPathComponent("pack-a/stop.mp3"))
            let fixture = makePresentationEditorFixture(
                root: root,
                environment: makeAudioImportEnvironment(userPacksDirectory: packs),
                config: ClaudioConfig(selectedPack: "pack-a"))
            let owner = fixture.owner
            var observed = [owner.presentation.library]
            var loadingPreviousSounds: SoundsEditorPresentation?
            var cancellables = Set<AnyCancellable>()
            owner.$presentation.sink { presentation in
                observed.append(presentation.library)
                if presentation.library == .loading(previousAvailable: true),
                    case .sounds(let sounds) = presentation.mode
                {
                    loadingPreviousSounds = sounds
                }
            }.store(in: &cancellables)

            _ = owner.send(.activate(.sounds(route: .overview, requestRevision: 23)))
            await waitForSoundEditorReady(owner, library: fixture.library)
            expect(observed.contains(.unloaded), "owner interface 必须可观察 unloaded status")
            expect(
                observed.contains(.loading(previousAvailable: false)),
                "首次扫描必须可观察 loading(previous: false)")
            expect(
                observed.contains(where: {
                    if case .ready = $0 { return true }
                    return false
                }),
                "成功扫描必须可观察 ready status")

            replaceDirectoryWithRegularFile(packs)
            _ = await fixture.library.refreshSnapshot(trigger: .retry)
            await waitForSoundEditorLibraryFailure(owner, library: fixture.library)
            expect(
                observed.contains(.loading(previousAvailable: true)),
                "refresh 必须保留 loading(previous: true) 语义")
            expect(
                loadingPreviousSounds?.eventRows.first(where: { $0.event == .stop })?
                    .previewAvailability.isAvailable == true
                    && loadingPreviousSounds?.eventRows.first(where: { $0.event == .stop })?
                        .previewAction == nil,
                "refreshing(previous) 可保留 mapped 语义，但不得签发 no-op preview capability")
            guard
                case .failed(
                    previousAvailable: true,
                    reason: let failureReason
                ) = owner.presentation.library
            else {
                expect(false, "refresh failure 必须保留 failed(previous: true) 语义")
                return
            }
            expect(
                failureReason == .locationUnavailable,
                "root 不再是目录时必须投影稳定 semantic reason")
            expect(
                !String(describing: failureReason).contains(root.path),
                "library failure reason 不得泄露临时目录绝对路径")
        }

        await withTempDirectory { root in
            let packs = root.appendingPathComponent("first-load-packs")
            writeFixture("not-a-directory", to: packs)
            let fixture = makePresentationEditorFixture(
                root: root,
                environment: makeAudioImportEnvironment(userPacksDirectory: packs),
                config: ClaudioConfig(selectedPack: "pack-a"))
            let owner = fixture.owner
            _ = owner.send(.activate(.sounds(route: .overview, requestRevision: 24)))
            await waitForSoundEditorLibraryFailure(owner, library: fixture.library)
            guard
                case .failed(
                    previousAvailable: false,
                    reason: let failureReason
                ) = owner.presentation.library
            else {
                expect(false, "首次加载失败必须是 failed(previous: false)")
                return
            }
            expect(
                failureReason == .locationUnavailable,
                "首次加载失败也必须给出 semantic reason")
            expect(
                !String(describing: failureReason).contains(root.path),
                "首次加载 failure reason 不得泄露绝对路径")
        }
    }

    await suite("Sound editor presentation：inventory failure 语义化且脱敏") {
        await withTempDirectory { root in
            let fixture = makeSoundEditorFixture(root: root, packIDs: ["pack-a", "pack-b"])
            let owner = fixture.owner
            _ = owner.send(.activate(.sounds(route: .overview, requestRevision: 25)))
            await waitForSoundEditorReady(owner, library: fixture.library)
            await waitForSoundEditorInventory(owner)
            guard case .sounds(let ready) = owner.presentation.mode,
                let inspectB = ready.packs.first(where: { $0.id == "pack-b" })?.inspectAction
            else {
                expect(false, "fixture 必须可 inspect 尚未读取 inventory 的 pack-b")
                return
            }

            replaceDirectoryWithRegularFile(
                root.appendingPathComponent("packs/pack-b", isDirectory: true))
            expect(
                owner.send(.invoke(inspectB)) == .applied, "inspect pack-b 必须开始真实 inventory read")
            await waitForSoundEditorInventoryFailure(owner)
            guard case .sounds(let failed) = owner.presentation.mode,
                case .failed(
                    previous: let previous,
                    reason: let failureReason
                ) = failed.inventory
            else {
                expect(false, "消失的 pack directory 必须投影 inventory failed")
                return
            }
            expect(previous == nil, "pack-b 首次 inventory failure 不得借用 pack-a 的 previous rows")
            expect(
                failureReason == .packUnavailable,
                "inventory failure 必须投影稳定 semantic reason")
            expect(
                !String(describing: failureReason).contains(root.path),
                "inventory failure reason 不得泄露临时目录绝对路径")
        }
    }

    await suite("Sound editor presentation：broken Event mapping 仍签 clear capability") {
        await withTempDirectory { root in
            let packs = root.appendingPathComponent("packs", isDirectory: true)
            writeFixture(
                #"{"id":"pack-a","name":"pack-a","events":{"stop":"missing.mp3"}}"#,
                to: packs.appendingPathComponent("pack-a/manifest.json"))
            let fixture = makePresentationEditorFixture(
                root: root,
                environment: makeAudioImportEnvironment(userPacksDirectory: packs),
                config: ClaudioConfig(selectedPack: "pack-a"))
            let owner = fixture.owner
            _ = owner.send(.activate(.sounds(route: .overview, requestRevision: 26)))
            await waitForSoundEditorReady(owner, library: fixture.library)
            guard case .sounds(let sounds) = owner.presentation.mode,
                let stop = sounds.eventRows.first(where: { $0.event == .stop })
            else {
                expect(false, "broken fixture 必须投影 stop event row")
                return
            }
            expect(
                stop.coverage == .broken(fileName: "missing.mp3"), "fixture 必须真实产生 broken mapping")
            expect(stop.previewAction == nil, "broken audio 不得签 preview capability")
            expect(stop.clearAction != nil, "broken mapping 仍必须可从 manifest 清除")
        }
    }

    await suite("Sound editor presentation：non-fresh previous 只签 target-free stop/retry") {
        await withTempDirectory { root in
            let packs = root.appendingPathComponent("packs", isDirectory: true)
            let fixture = makeSoundEditorFixture(root: root, packIDs: ["pack-a", "pack-b"])
            let owner = fixture.owner
            _ = owner.send(.activate(.sounds(route: .overview, requestRevision: 27)))
            await waitForSoundEditorReady(owner, library: fixture.library)
            await waitForSoundEditorInventory(owner)
            guard case .sounds(let fresh) = owner.presentation.mode,
                let oldUse = fresh.packs.first(where: { $0.id == "pack-b" })?.useAction
            else {
                expect(false, "fresh fixture 必须先签发 write capability")
                return
            }
            let freshAssignmentActions: [SoundPackEditorAction] = soundEditorAudioRows(
                in: fresh.inventory
            ).flatMap(\.assignments).map(\.action)
            expect(
                !freshAssignmentActions.isEmpty,
                "fresh inventory 必须签发 nonoptional assignment action")

            replaceDirectoryWithRegularFile(packs)
            _ = await fixture.library.refreshSnapshot(trigger: .retry)
            await waitForSoundEditorLibraryFailure(owner, library: fixture.library)
            guard
                case .failed(
                    previousAvailable: true,
                    reason: .locationUnavailable
                ) = owner.presentation.library,
                case .sounds(let stale) = owner.presentation.mode
            else {
                expect(false, "失败 refresh 必须保留 non-fresh previous presentation")
                return
            }
            expect(!stale.packs.isEmpty, "non-fresh previous 仍必须可显示既有 pack facts")
            expect(stale.retryLibraryAction != nil, "retry 是恢复 capability，不是 stale write")
            expect(
                stale.packs.allSatisfy {
                    $0.useAction == nil && $0.toggleStarAction == nil && $0.forkAction == nil
                        && $0.deleteAction == nil && $0.restoreAction == nil
                        && $0.revealAction == nil
                },
                "non-fresh pack facts 不得携带 write/native capability")
            expect(
                stale.eventRows.allSatisfy {
                    $0.importAction == nil && $0.previewAction == nil && $0.clearAction == nil
                },
                "non-fresh Event facts 不得携带 import/preview/clear capability")
            expect(stale.requestImportAction == nil, "non-fresh root 不得签 open-panel capability")
            let stopPreviewAction = stale.stopPreviewAction
            expect(
                stopPreviewAction.kind == .stopPreview,
                "target-free stop 必须保留，供 refresh failure 或 destination switch 安全清理音频")
            expect(
                stale.restoreAllFactoryPacksAction == nil && stale.recoveryActions.isEmpty,
                "non-fresh root 不得签 restore write capability")

            let audioRows = soundEditorAudioRows(in: stale.inventory)
            expect(
                audioRows.allSatisfy { $0.assignments.isEmpty },
                "non-fresh previous inventory 不得保留 assignment affordance")
            expect(
                audioRows.allSatisfy { $0.deleteAction == nil && $0.revealAction == nil },
                "non-fresh inventory facts 不得携带 delete/reveal capability")
            expect(
                owner.send(.invoke(stopPreviewAction)) == .nativeEffect(.stopAudio),
                "non-fresh stop 只能产生 target-free stopAudio effect")
            expect(
                owner.send(.invoke(oldUse)) == .rejected(.staleAction),
                "上一 fresh generation 的 write capability 必须失效")
        }
    }

    await suite("Sound editor presentation：inactive common slice 保留 installed identities") {
        await withTempDirectory { root in
            let fixture = makeSoundEditorFixture(root: root, packIDs: ["pack-a", "pack-b"])
            let owner = fixture.owner
            _ = owner.send(.activate(.sounds(route: .overview, requestRevision: 28)))
            await waitForSoundEditorReady(owner, library: fixture.library)
            expect(
                owner.send(.activate(.inactive)) == .applied, "destination handback 必须进入 inactive")

            expect(owner.presentation.mode == .inactive, "inactive common slice 不得签 mode action")
            expect(
                owner.presentation.installedPackIDs == Set(["pack-a", "pack-b"]),
                "inactive presentation 仍必须提供 Settings availability 所需安装包 identity")
            expect(
                owner.presentation.library.isFresh,
                "installed identity 必须与同一 coherent root 的 freshness 一起可观察")
        }
    }

    await suite("Sound editor presentation：视觉 status 与 announcement debt 生命周期分离") {
        withTempDirectory { root in
            let packID = "factory-a"
            let status = SoundPacksWindowStatus(
                kind: .factoryRestore,
                severity: .failure,
                revision: 701,
                action: "Restore",
                message: "Retained failure",
                recovery: .retryFactoryRestores(packIDs: [packID]))
            let model = SoundPacksWindowModel(
                previewConfig: ClaudioConfig(selectedPack: packID),
                packCards: [
                    PackCard(
                        id: packID,
                        name: "Factory A",
                        isCC0: true,
                        presentEvents: Set(Event.allCases),
                        state: .complete,
                        isSelected: true)
                ],
                selectedPackID: packID,
                selectedEventRows: [],
                builtinPackIDs: [packID],
                windowStatuses: [status],
                environment: makeAudioImportEnvironment(
                    userPacksDirectory: root.appendingPathComponent("packs", isDirectory: true)),
                refreshCoordinator: SoundPacksRefreshCoordinator())
            let owner = SoundPacksEditorOwner(
                model: model,
                userPacksDirectory: root.appendingPathComponent("packs", isDirectory: true))
            _ = owner.send(.activate(.sounds(route: .overview, requestRevision: 701)))

            guard case .sounds(let beforeAck) = owner.presentation.mode,
                beforeAck.windowStatuses == [status],
                let oldRetry = beforeAck.recoveryActions.first?.retryAction
            else {
                expect(false, "render-ready slice 必须携带持久 status 与 owner-signed recovery")
                return
            }

            for _ in 0..<4 {
                guard let announcement = owner.presentation.pendingAnnouncement else { break }
                expect(
                    owner.send(.acknowledgeAnnouncement(id: announcement.id, didPost: true))
                        == .applied,
                    "测试必须消费可访问性 announcement debt")
            }
            guard case .sounds(let afterAck) = owner.presentation.mode,
                afterAck.windowStatuses == [status],
                let currentRetry = afterAck.recoveryActions.first?.retryAction
            else {
                expect(false, "AX ack 后视觉 status/recovery 必须继续持久显示")
                return
            }
            expect(
                currentRetry != oldRetry,
                "当前 recovery capability 必须在 AX ack publication 后重新签发")
            expect(
                owner.send(.invoke(oldRetry)) == .rejected(.staleAction),
                "旧 recovery capability 必须随 owner publication 失效")
        }
    }

    await suite("Sound editor presentation：空库明确区分 factory restore 与安全 root reveal") {
        await withTempDirectory { root in
            let factoryFixture = makeSoundEditorFixture(
                root: root.appendingPathComponent("factory-case"),
                packIDs: [],
                builtinPackIDs: ["factory-a"])
            _ = factoryFixture.owner.send(
                .activate(.sounds(route: .overview, requestRevision: 702)))
            await waitForSoundEditorReady(factoryFixture.owner, library: factoryFixture.library)
            guard case .sounds(let factorySounds) = factoryFixture.owner.presentation.mode,
                case .restoreFactory(let restoreAction) =
                    factorySounds.emptyLibraryRecovery,
                case .confirmation(let confirmation) =
                    factoryFixture.owner.send(.invoke(restoreAction))
            else {
                expect(false, "有 factory 的空库必须只投影 owner-signed restore recovery")
                return
            }
            expect(
                confirmation.kind == .restoreAllFactory,
                "empty factory recovery 必须复用现有 restore-all confirmation seam")

            let revealCaseRoot = root.appendingPathComponent("reveal-case")
            let revealRoot = revealCaseRoot.appendingPathComponent("packs", isDirectory: true)
            let revealFixture = makeSoundEditorFixture(
                root: revealCaseRoot,
                packIDs: [])
            _ = revealFixture.owner.send(
                .activate(.sounds(route: .overview, requestRevision: 703)))
            await waitForSoundEditorReady(revealFixture.owner, library: revealFixture.library)
            guard case .sounds(let revealSounds) = revealFixture.owner.presentation.mode,
                case .revealRoot(let displayValue, let revealAction) =
                    revealSounds.emptyLibraryRecovery,
                case .nativeEffect(.reveal(let revealedURL)) =
                    revealFixture.owner.send(.invoke(revealAction))
            else {
                expect(false, "无 factory 的空库必须提供 owner-signed safe-root reveal")
                return
            }
            expect(
                revealedURL == revealRoot
                    && displayValue == revealRoot.path,
                "空库 Finder AX Value 必须由 owner 投影 display-only path；typed URL 留在 invoke effect")

            let populatedFixture = makeSoundEditorFixture(
                root: root.appendingPathComponent("populated-case"),
                packIDs: ["pack-a"])
            _ = populatedFixture.owner.send(
                .activate(.sounds(route: .overview, requestRevision: 704)))
            await waitForSoundEditorReady(
                populatedFixture.owner,
                library: populatedFixture.library)
            guard case .sounds(let populated) = populatedFixture.owner.presentation.mode else {
                expect(false, "populated fixture 必须进入 Sounds mode")
                return
            }
            expect(
                populated.emptyLibraryRecovery == .none,
                "非空库不得携带 empty-state restore/reveal capability")
        }
    }
}

@MainActor
private func makePresentationEditorFixture(
    root: URL,
    environment: AudioImportEnvironment,
    config: ClaudioConfig
) -> SoundEditorFixture {
    let configFile = root.appendingPathComponent("config.json")
    writeFixture(try! JSONEncoder().encode(config), to: configFile)
    let recorder = SoundEditorScanRecorder()
    let scanner = SoundPackLibraryScanner.testingLive(
        environment: environment,
        onRequest: { recorder.append($0) },
        afterManifestRead: { _ in })
    let library = SoundPackLibrary(
        scanner: scanner,
        inventoryOperation: { packID in
            switch packAudioFiles(packID: packID, environment: environment) {
            case .success(let files): return .available(files)
            case .failure(let error): return .unavailable(error)
            }
        })
    let refreshCoordinator = SoundPacksRefreshCoordinator()
    let owner = SoundPacksEditorOwner(
        configFile: configFile,
        lockFile: root.appendingPathComponent("config.lock"),
        environment: environment,
        soundPackLibrary: library,
        refreshCoordinator: refreshCoordinator)
    return SoundEditorFixture(
        owner: owner,
        library: library,
        recorder: recorder,
        refreshCoordinator: refreshCoordinator,
        configFile: configFile,
        packsLockFile: environment.packsLockFile)
}

@MainActor
private func replaceDirectoryWithRegularFile(_ directory: URL) {
    let backup = directory.deletingLastPathComponent()
        .appendingPathComponent("\(directory.lastPathComponent)-backup", isDirectory: true)
    try! FileManager.default.moveItem(at: directory, to: backup)
    writeFixture("not-a-directory", to: directory)
}

@MainActor
private func waitForSoundEditorLibraryFailure(
    _ owner: SoundPacksEditorOwner,
    library: SoundPackLibrary
) async {
    for _ in 0..<512 {
        if case .failed = owner.presentation.library { return }
        await Task.yield()
    }
    await library.waitUntilIdleForTesting()
    for _ in 0..<16 { await Task.yield() }
}

@MainActor
private func waitForSoundEditorInventoryFailure(_ owner: SoundPacksEditorOwner) async {
    for _ in 0..<512 {
        if case .sounds(let sounds) = owner.presentation.mode,
            case .failed = sounds.inventory
        {
            return
        }
        await Task.yield()
    }
}

private func soundEditorAudioRows(
    in inventory: SoundPackEditorInventoryPresentation
) -> [SoundPackEditorAudioPresentation] {
    switch inventory {
    case .idle:
        return []
    case .loading(let previous):
        return previous ?? []
    case .failed(previous: let previous, reason: _):
        return previous ?? []
    case .ready(let rows):
        return rows
    }
}
