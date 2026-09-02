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
            var cancellables = Set<AnyCancellable>()
            owner.$presentation.sink { observed.append($0.library) }.store(in: &cancellables)

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
            guard case .failed(previousAvailable: true) = owner.presentation.library else {
                expect(false, "refresh failure 必须保留 failed(previous: true) 语义")
                return
            }
            expect(
                owner.presentation.library.failureReason == .locationUnavailable,
                "root 不再是目录时必须投影稳定 semantic reason")
            expect(
                !String(describing: owner.presentation.library.failureReason).contains(root.path),
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
            guard case .failed(previousAvailable: false) = owner.presentation.library else {
                expect(false, "首次加载失败必须是 failed(previous: false)")
                return
            }
            expect(
                owner.presentation.library.failureReason == .locationUnavailable,
                "首次加载失败也必须给出 semantic reason")
            expect(
                !String(describing: owner.presentation.library.failureReason).contains(root.path),
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
                case .failed(let previous) = failed.inventory
            else {
                expect(false, "消失的 pack directory 必须投影 inventory failed")
                return
            }
            expect(previous == nil, "pack-b 首次 inventory failure 不得借用 pack-a 的 previous rows")
            expect(
                failed.inventory.failureReason == .packUnavailable,
                "inventory failure 必须投影稳定 semantic reason")
            expect(
                !String(describing: failed.inventory.failureReason).contains(root.path),
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

    await suite("Sound editor presentation：non-fresh previous 不签 write 或 native capability") {
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

            replaceDirectoryWithRegularFile(packs)
            _ = await fixture.library.refreshSnapshot(trigger: .retry)
            await waitForSoundEditorLibraryFailure(owner, library: fixture.library)
            guard case .failed(previousAvailable: true) = owner.presentation.library,
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
            let stopPreviewAction: SoundPackEditorAction? = stale.stopPreviewAction
            expect(stopPreviewAction == nil, "non-fresh root 不得签 native preview capability")
            expect(
                stale.restoreAllFactoryPacksAction == nil && stale.recoveryActions.isEmpty,
                "non-fresh root 不得签 restore write capability")

            let audioRows = soundEditorAudioRows(in: stale.inventory)
            let assignments = audioRows.flatMap(\.assignments)
            expect(!assignments.isEmpty, "previous inventory 必须保留可渲染 assignment facts")
            let assignmentActions: [SoundPackEditorAction?] = assignments.map(\.action)
            expect(
                assignmentActions.allSatisfy { $0 == nil },
                "non-fresh assignment facts 不得携带 write capability")
            expect(
                audioRows.allSatisfy { $0.deleteAction == nil && $0.revealAction == nil },
                "non-fresh inventory facts 不得携带 delete/reveal capability")
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
    let owner = SoundPacksEditorOwner(
        configFile: configFile,
        lockFile: root.appendingPathComponent("config.lock"),
        environment: environment,
        soundPackLibrary: library,
        refreshCoordinator: SoundPacksRefreshCoordinator())
    return SoundEditorFixture(
        owner: owner,
        library: library,
        recorder: recorder,
        configFile: configFile)
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
    case .loading(let previous), .failed(let previous):
        return previous ?? []
    case .ready(let rows):
        return rows
    }
}
