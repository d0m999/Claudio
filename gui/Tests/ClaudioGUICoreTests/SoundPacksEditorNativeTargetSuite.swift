import ClaudioCore
import ClaudioGUICore
import Foundation

private struct SoundEditorNativeTargetFixture {
    let owner: SoundPacksEditorOwner
    let library: SoundPackLibrary
    let packsDirectory: URL
}

private enum StaleNativeTargetKind: String, CaseIterable {
    case packReveal
    case mappedPreview
    case inventoryReveal
}

@MainActor
private func makeSoundEditorNativeTargetFixture(
    root: URL,
    selectedPackID: String,
    masterVolume: Double = 0.43
) -> SoundEditorNativeTargetFixture {
    let packsDirectory = root.appendingPathComponent("packs", isDirectory: true)
    let configFile = root.appendingPathComponent("config.json")
    writeFixture(
        try! JSONEncoder().encode(
            ClaudioConfig(selectedPack: selectedPackID, masterVolume: masterVolume)),
        to: configFile)
    let environment = makeAudioImportEnvironment(userPacksDirectory: packsDirectory)
    let library = SoundPackLibrary(environment: environment)
    let owner = SoundPacksEditorOwner(
        configFile: configFile,
        lockFile: root.appendingPathComponent("config.lock"),
        environment: environment,
        soundPackLibrary: library,
        refreshCoordinator: SoundPacksRefreshCoordinator())
    return SoundEditorNativeTargetFixture(
        owner: owner,
        library: library,
        packsDirectory: packsDirectory)
}

@MainActor
private func activateNativeTargetFixture(
    _ fixture: SoundEditorNativeTargetFixture,
    requestRevision: UInt64
) async -> SoundsEditorPresentation? {
    _ = fixture.owner.send(
        .activate(.sounds(route: .overview, requestRevision: requestRevision)))
    await waitForSoundEditorReady(fixture.owner, library: fixture.library)
    await waitForSoundEditorInventory(fixture.owner)
    guard case .sounds(let sounds) = fixture.owner.presentation.mode else { return nil }
    return sounds
}

@MainActor
private func waitForNativeTargetLibraryFailure(
    _ owner: SoundPacksEditorOwner
) async {
    for _ in 0..<512 {
        if case .failed = owner.presentation.library { return }
        await Task.yield()
    }
}

@MainActor
private func inventoryRows(
    _ inventory: SoundPackEditorInventoryPresentation
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

@MainActor
func runSoundPacksEditorNativeTargetSuites() async {
    await suite("Sound editor native target：installed empty pack 仍可签发目录 reveal") {
        await withTempDirectory { root in
            let packDirectory = root.appendingPathComponent("packs/empty-pack", isDirectory: true)
            writeFixture(
                #"{"id":"empty-pack","name":"Empty","events":{}}"#,
                to: packDirectory.appendingPathComponent("manifest.json"))
            let fixture = makeSoundEditorNativeTargetFixture(
                root: root,
                selectedPackID: "empty-pack")

            guard
                let sounds = await activateNativeTargetFixture(fixture, requestRevision: 41),
                let pack = sounds.packs.first(where: { $0.id == "empty-pack" }),
                let reveal = pack.revealAction
            else {
                expect(false, "fresh installed empty pack 必须携带目录 reveal capability")
                return
            }
            expect(pack.availability == .installed, "empty pack 必须是已安装事实而非 missing placeholder")
            expect(
                fixture.owner.send(.invoke(reveal))
                    == .nativeEffect(.reveal(fileURL: packDirectory.standardizedFileURL)),
                "empty pack reveal 必须原样返回 shared snapshot 已验证的目录 URL")
        }
    }

    await suite("Sound editor native target：mapped preview 携带 shared URL 与 Global master volume") {
        await withTempDirectory { root in
            let packDirectory = root.appendingPathComponent("packs/pack-a", isDirectory: true)
            let audioFile = packDirectory.appendingPathComponent("stop.mp3")
            writeFixture(
                #"{"id":"pack-a","events":{"stop":"stop.mp3"}}"#,
                to: packDirectory.appendingPathComponent("manifest.json"))
            writeFixture("audio", to: audioFile)
            let fixture = makeSoundEditorNativeTargetFixture(
                root: root,
                selectedPackID: "pack-a",
                masterVolume: 0.43)

            guard
                let sounds = await activateNativeTargetFixture(fixture, requestRevision: 42),
                let row = sounds.eventRows.first(where: { $0.event == .stop }),
                let preview = row.previewAction
            else {
                expect(false, "fresh mapped regular file 必须携带 preview capability")
                return
            }
            expect(
                row.coverage == .present(fileName: "stop.mp3"),
                "preview capability 必须由同一 shared fact 的 present coverage 支撑")
            expect(
                fixture.owner.send(.invoke(preview))
                    == .nativeEffect(
                        .playAudio(fileURL: audioFile.standardizedFileURL, volume: 0.43)),
                "preview effect 必须携带已验证 URL 与 Global master volume，不让 adapter 重算")
        }
    }

    await suite("Sound editor native target：inventory direct regular file 可签发 reveal") {
        await withTempDirectory { root in
            let packDirectory = root.appendingPathComponent("packs/pack-a", isDirectory: true)
            let inventoryFile = packDirectory.appendingPathComponent("loose.wav")
            writeFixture(
                #"{"id":"pack-a","events":{}}"#,
                to: packDirectory.appendingPathComponent("manifest.json"))
            writeFixture("audio", to: inventoryFile)
            let fixture = makeSoundEditorNativeTargetFixture(
                root: root,
                selectedPackID: "pack-a")

            guard
                let sounds = await activateNativeTargetFixture(fixture, requestRevision: 43),
                case .ready(let audio) = sounds.inventory,
                let row = audio.first(where: { $0.fileName == "loose.wav" }),
                let reveal = row.revealAction
            else {
                expect(false, "shared inventory 的 direct regular file 必须携带 reveal capability")
                return
            }
            expect(row.isOrphan, "未被 manifest 引用的 direct file 必须保留 orphan 事实")
            expect(
                fixture.owner.send(.invoke(reveal))
                    == .nativeEffect(.reveal(fileURL: inventoryFile.standardizedFileURL)),
                "inventory reveal 必须原样返回 loader 已验证的 direct-entry URL")
        }
    }

    await suite("Sound editor native target：escape symlink、broken mapping 与 missing pack 不签 target")
    {
        await withTempDirectory { root in
            let packDirectory = root.appendingPathComponent("packs/unsafe-pack", isDirectory: true)
            let outsideAudio = root.appendingPathComponent("outside.mp3")
            let escapingLink = packDirectory.appendingPathComponent("escape.mp3")
            writeFixture("outside", to: outsideAudio)
            writeFixture(
                #"{"id":"unsafe-pack","events":{"stop":"escape.mp3","notification":"missing.wav"}}"#,
                to: packDirectory.appendingPathComponent("manifest.json"))
            writeFixture("safe", to: packDirectory.appendingPathComponent("direct.wav"))
            createSymlink(at: escapingLink, pointingTo: outsideAudio)
            let fixture = makeSoundEditorNativeTargetFixture(
                root: root,
                selectedPackID: "unsafe-pack")

            guard let sounds = await activateNativeTargetFixture(fixture, requestRevision: 44)
            else {
                expect(false, "unsafe fixture 必须到达 Sounds ready slice")
                return
            }
            let symlinkRow = sounds.eventRows.first(where: { $0.event == .stop })
            let missingRow = sounds.eventRows.first(where: { $0.event == .notification })
            expect(
                symlinkRow?.coverage == .broken(fileName: "escape.mp3")
                    && symlinkRow?.previewAction == nil,
                "逃出 pack root 的 symlink 必须是 broken，且不得签 preview")
            expect(
                missingRow?.coverage == .broken(fileName: "missing.wav")
                    && missingRow?.previewAction == nil,
                "缺失映射必须是 broken，且不得签 preview")
            let rows = inventoryRows(sounds.inventory)
            expect(
                !rows.contains(where: { $0.fileName == "escape.mp3" })
                    && !rows.contains(where: { $0.fileName == "missing.wav" }),
                "symlink 与 missing entry 不得进入 direct-file inventory，自然不能签 reveal")
            expect(
                rows.first(where: { $0.fileName == "direct.wav" })?.revealAction != nil,
                "负向 fixture 必须同时证明真正 direct regular file 仍可签 reveal")
        }

        await withTempDirectory { root in
            let installed = root.appendingPathComponent("packs/pack-a", isDirectory: true)
            writeFixture(
                #"{"id":"pack-a","events":{}}"#,
                to: installed.appendingPathComponent("manifest.json"))
            let fixture = makeSoundEditorNativeTargetFixture(
                root: root,
                selectedPackID: "missing-pack")

            guard
                let sounds = await activateNativeTargetFixture(fixture, requestRevision: 45),
                let missing = sounds.packs.first(where: { $0.id == "missing-pack" })
            else {
                expect(false, "fresh snapshot 必须保留 selected missing placeholder")
                return
            }
            expect(
                missing.availability == .missingSelectedPlaceholder
                    && missing.revealAction == nil,
                "missing pack identity 可以展示，但不得签 invented directory reveal")
        }
    }

    await suite("Sound editor native target：refresh 发布前消费旧 immutable fact，不做 click-time stat") {
        for (offset, kind) in StaleNativeTargetKind.allCases.enumerated() {
            await withTempDirectory { root in
                let packDirectory = root.appendingPathComponent("packs/pack-a", isDirectory: true)
                let mappedFile = packDirectory.appendingPathComponent("stop.mp3")
                let inventoryFile = packDirectory.appendingPathComponent("loose.wav")
                writeFixture(
                    #"{"id":"pack-a","events":{"stop":"stop.mp3"}}"#,
                    to: packDirectory.appendingPathComponent("manifest.json"))
                writeFixture("mapped", to: mappedFile)
                writeFixture("orphan", to: inventoryFile)
                let fixture = makeSoundEditorNativeTargetFixture(
                    root: root,
                    selectedPackID: "pack-a",
                    masterVolume: 0.43)

                guard
                    let sounds = await activateNativeTargetFixture(
                        fixture,
                        requestRevision: 50 + UInt64(offset))
                else {
                    expect(false, "\(kind.rawValue) fixture 必须到达 ready")
                    return
                }
                let action: SoundPackEditorAction
                let expectedEffect: SoundPackEditorNativeEffect
                let targetToMove: URL
                switch kind {
                case .packReveal:
                    guard let signed = sounds.selectedPack?.revealAction else {
                        expect(false, "pack reveal 必须先由 ready snapshot 签发")
                        return
                    }
                    action = signed
                    expectedEffect = .reveal(fileURL: packDirectory.standardizedFileURL)
                    targetToMove = packDirectory
                case .mappedPreview:
                    guard
                        let signed = sounds.eventRows.first(where: { $0.event == .stop })?
                            .previewAction
                    else {
                        expect(false, "mapped preview 必须先由 ready snapshot 签发")
                        return
                    }
                    action = signed
                    expectedEffect = .playAudio(
                        fileURL: mappedFile.standardizedFileURL,
                        volume: 0.43)
                    targetToMove = mappedFile
                case .inventoryReveal:
                    guard
                        let signed = inventoryRows(sounds.inventory)
                            .first(where: { $0.fileName == "loose.wav" })?.revealAction
                    else {
                        expect(false, "inventory reveal 必须先由 ready inventory 签发")
                        return
                    }
                    action = signed
                    expectedEffect = .reveal(fileURL: inventoryFile.standardizedFileURL)
                    targetToMove = inventoryFile
                }

                let signedRevision = fixture.owner.presentation.revision
                fixture.library.invalidate(packIDs: ["pack-a"])
                let movedTarget = root.appendingPathComponent("moved-\(kind.rawValue)")
                do {
                    try FileManager.default.moveItem(at: targetToMove, to: movedTarget)
                } catch {
                    expect(false, "必须能在 refresh publication 前移走 \(kind.rawValue)：\(error)")
                    return
                }
                expect(
                    !FileManager.default.fileExists(atPath: targetToMove.path),
                    "测试必须真的移走 \(kind.rawValue) target")
                expect(
                    fixture.owner.presentation.revision == signedRevision
                        && fixture.owner.presentation.library.isFresh,
                    "移走磁盘 target 本身不得伪造新的 shared-library publication")
                expect(
                    fixture.owner.send(.invoke(action)) == .nativeEffect(expectedEffect),
                    "\(kind.rawValue) invoke 必须消费签发 generation 的 immutable URL fact；"
                        + "这是 stale-while-refresh，不是 click-time stat")

                // 旧实现的 preview fallback 会自行请求 refresh；等它结束再销毁 temp tree，避免
                // 预期 RED 的后台读取越过 fixture 生命周期。正确实现这里不会发起额外 scan。
                await Task.yield()
                await fixture.library.waitUntilIdleForTesting()
            }
        }
    }

    await suite("Sound editor native target：shared failure 换代使旧 action stale 且不重签 target") {
        await withTempDirectory { root in
            let packDirectory = root.appendingPathComponent("packs/pack-a", isDirectory: true)
            writeFixture(
                #"{"id":"pack-a","events":{"stop":"stop.mp3"}}"#,
                to: packDirectory.appendingPathComponent("manifest.json"))
            writeFixture("mapped", to: packDirectory.appendingPathComponent("stop.mp3"))
            writeFixture("orphan", to: packDirectory.appendingPathComponent("loose.wav"))
            let fixture = makeSoundEditorNativeTargetFixture(
                root: root,
                selectedPackID: "pack-a")

            guard
                let ready = await activateNativeTargetFixture(fixture, requestRevision: 60),
                let oldPackReveal = ready.selectedPack?.revealAction,
                let oldPreview = ready.eventRows.first(where: { $0.event == .stop })?.previewAction,
                let oldInventoryReveal = inventoryRows(ready.inventory)
                    .first(where: { $0.fileName == "loose.wav" })?.revealAction
            else {
                expect(false, "ready generation 必须先签发三种 target capability")
                return
            }
            let readyPresentationRevision = fixture.owner.presentation.revision
            let retainedPacks = root.appendingPathComponent("retained-packs", isDirectory: true)
            do {
                try FileManager.default.moveItem(
                    at: fixture.packsDirectory,
                    to: retainedPacks)
            } catch {
                expect(false, "必须能隔离 packs root 以制造真实 shared failure：\(error)")
                return
            }
            writeFixture("not a directory", to: fixture.packsDirectory)
            fixture.library.invalidate(packIDs: ["pack-a"])
            let terminal = await fixture.library.refreshSnapshot(trigger: .retry)
            guard case .failed(let previous, _) = terminal, previous != nil else {
                expect(false, "真实非目录 packs root 必须发布 failed(previous) terminal")
                return
            }
            await waitForNativeTargetLibraryFailure(fixture.owner)

            guard case .sounds(let failed) = fixture.owner.presentation.mode else {
                expect(false, "shared failure 后必须保留 Sounds value slice")
                return
            }
            expect(
                fixture.owner.presentation.revision > readyPresentationRevision,
                "failed(previous) 必须是新的 coherent presentation generation")
            expect(
                fixture.owner.send(.invoke(oldPackReveal)) == .rejected(.staleAction)
                    && fixture.owner.send(.invoke(oldPreview)) == .rejected(.staleAction)
                    && fixture.owner.send(.invoke(oldInventoryReveal)) == .rejected(.staleAction),
                "新 shared generation 必须永久作废旧 pack/preview/inventory capability")
            expect(
                failed.packs.first(where: { $0.id == "pack-a" })?.revealAction == nil,
                "failed(previous) 可保留 pack identity，但不得重签目录 target")
            expect(
                failed.eventRows.first(where: { $0.event == .stop })?.previewAction == nil,
                "failed(previous) 可保留 coverage，但不得重签 preview target")
            expect(
                inventoryRows(failed.inventory).allSatisfy { $0.revealAction == nil },
                "failed(previous) 可保留 inventory rows，但不得重签文件 target")
            expect(
                failed.requestImportAction == nil,
                "non-fresh previous facts 不得签发另一个 target-dependent native picker")
        }
    }

    suite("Sound editor native target：MainActor owner/model 不调用同步 filesystem resolver") {
        let sourceRoot = guiTestRepositoryRoot().appendingPathComponent(
            "gui/Sources/ClaudioGUICore",
            isDirectory: true)
        let files = ["SoundPacksEditorOwner.swift", "SoundPacksWindowModel.swift"]
        let forbiddenResolvers = [
            "resolvePackDirectory",
            "safePackFileURL",
            "regularFileExists",
            "nonEmptyRegularFileExists",
        ]

        for file in files {
            let url = sourceRoot.appendingPathComponent(file)
            guard let source = try? String(contentsOf: url, encoding: .utf8) else {
                expect(false, "必须能读取 \(file) 才能验证线程合同")
                continue
            }
            let scanned = strippingComments(source)
            expect(scanned.unmodeledConstructs.isEmpty, "\(file) source guard 必须完整解析")
            expect(
                scanned.codeWithoutStringLiterals.contains("@MainActor\npublic final class"),
                "\(file) guard 必须先正向证明被审类型仍由 MainActor 隔离")
            let hits = forbiddenResolvers.filter { resolver in
                !callArguments(of: resolver, in: scanned.codeWithoutStringLiterals).isEmpty
            }
            expect(
                hits.isEmpty,
                "\(file) 的 MainActor 路径只能消费 immutable shared facts，不得同步调用："
                    + hits.joined(separator: ", "))
        }
    }
}
