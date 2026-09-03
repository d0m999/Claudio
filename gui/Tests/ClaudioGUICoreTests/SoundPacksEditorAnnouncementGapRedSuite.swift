import ClaudioCore
import ClaudioGUICore
import Foundation

@MainActor
func runSoundPacksEditorAnnouncementGapRedSuites() async {
    await suite("[129-ANN-RED] legacy caller 未激活新 interface 时不积累 shadow debt") {
        await withTempDirectory { root in
            let fixture = makeSoundEditorFixture(root: root, packIDs: ["pack-a"])
            await fixture.library.waitUntilIdleForTesting()
            _ = fixture.owner.model.selectPackForInspection("pack-a")
            _ = fixture.owner.model.useSelectedPack()
            await Task.yield()

            expect(
                fixture.owner.presentation.pendingAnnouncement == nil,
                "[129-ANN-RED] Phase 1 旧 production caller 尚未迁移时不能让新 queue 无界积累")
        }
    }

    await suite("[129-ANN-RED] window open 形成可重试 semantic debt") {
        await withTempDirectory { root in
            let fixture = makeSoundEditorFixture(root: root, packIDs: ["pack-a"])
            await waitForSoundEditorReady(fixture.owner, library: fixture.library)
            announcementGapDrain(fixture.owner)

            _ = fixture.owner.send(
                .activate(.sounds(route: .overview, requestRevision: 400)))
            guard let opened = await announcementGapWait(fixture.owner) else {
                expect(false, "[129-ANN-RED] Sounds activation 必须产生 window-open debt")
                return
            }
            expect(
                opened.kind
                    == .windowOpened(
                        SoundPacksWindowAnnouncementFacts(
                            packCount: 1,
                            selectedPackName: "pack-a",
                            libraryPresentationState: .ready)),
                "[129-ANN-RED] window-open debt 必须携带 exact semantic kind/facts")
            expect(
                fixture.owner.send(
                    .acknowledgeAnnouncement(id: opened.id, didPost: false)) == .unchanged
                    && fixture.owner.presentation.pendingAnnouncement?.id == opened.id,
                "[129-ANN-RED] window-open didPost=false 必须保留 exact head")
            expect(
                fixture.owner.send(
                    .acknowledgeAnnouncement(id: opened.id, didPost: true)) == .applied
                    && fixture.owner.presentation.pendingAnnouncement?.id != opened.id,
                "[129-ANN-RED] window-open didPost=true 才能消费 exact head")
        }
    }

    await suite("[129-ANN-RED] inspection selection 形成独立 semantic debt") {
        await withTempDirectory { root in
            let fixture = makeSoundEditorFixture(
                root: root,
                packIDs: ["pack-a", "pack-b"])
            await waitForSoundEditorReady(fixture.owner, library: fixture.library)
            _ = fixture.owner.send(
                .activate(.sounds(route: .overview, requestRevision: 401)))
            announcementGapDrain(fixture.owner)
            guard case .sounds(let sounds) = fixture.owner.presentation.mode,
                let inspectB = sounds.packs.first(where: { $0.id == "pack-b" })?.inspectAction
            else {
                expect(false, "[129-ANN-RED] selection fixture 必须取得 inspect capability")
                return
            }

            expect(
                fixture.owner.send(.invoke(inspectB)) == .applied,
                "[129-ANN-RED] inspect capability 必须同步生效")
            guard let selection = await announcementGapWait(fixture.owner) else {
                expect(false, "[129-ANN-RED] inspection change 必须产生 selection debt")
                return
            }
            expect(
                selection.kind
                    == .selectionChanged(
                        SoundPacksWindowAnnouncementFacts(
                            packCount: 2,
                            selectedPackName: "pack-b",
                            libraryPresentationState: .ready)),
                "[129-ANN-RED] inspection debt 必须携带 exact semantic kind/facts")
            expect(
                fixture.owner.send(
                    .acknowledgeAnnouncement(id: selection.id, didPost: true)) == .applied
                    && fixture.owner.presentation.pendingAnnouncement == nil,
                "[129-ANN-RED] 单次 inspection debt ack 后队列必须为空")
        }
    }

    await suite("[129-ANN-RED] shared library loading→ready transition 保持 FIFO") {
        await withTempDirectory { root in
            let fixture = makeSoundEditorFixture(root: root, packIDs: ["pack-a"])
            await waitForSoundEditorReady(fixture.owner, library: fixture.library)
            _ = fixture.owner.send(
                .activate(.sounds(route: .overview, requestRevision: 402)))
            announcementGapDrain(fixture.owner)
            writeFixture(
                #"{"id":"pack-a","name":"Observed Again","events":{"stop":"stop.mp3"}}"#,
                to: root.appendingPathComponent("packs/pack-a/manifest.json"))
            fixture.library.invalidate(packIDs: ["pack-a"])
            _ = await fixture.library.refreshSnapshot(trigger: .retry)
            await fixture.library.waitUntilIdleForTesting()
            await waitForSoundEditorSelectedPackName(
                fixture.owner,
                expected: "Observed Again")

            guard let loading = await announcementGapWait(fixture.owner) else {
                expect(false, "[129-ANN-RED] shared loading transition 必须形成 semantic debt")
                return
            }
            expect(
                loading.kind
                    == .libraryStateChanged(
                        SoundPacksWindowAnnouncementFacts(
                            packCount: 1,
                            selectedPackName: "pack-a",
                            libraryPresentationState: .refreshing)),
                "[129-ANN-RED] shared loading transition 必须携带 refreshing semantic facts")
            expect(
                fixture.owner.send(
                    .acknowledgeAnnouncement(id: loading.id, didPost: true)) == .applied,
                "[129-ANN-RED] loading transition 必须可按 exact head ack")
            guard let ready = await announcementGapWait(fixture.owner) else {
                expect(false, "[129-ANN-RED] shared ready transition 不得被 loading 吞掉")
                return
            }
            expect(
                ready.kind
                    == .libraryStateChanged(
                        SoundPacksWindowAnnouncementFacts(
                            packCount: 1,
                            selectedPackName: "Observed Again",
                            libraryPresentationState: .ready)),
                "[129-ANN-RED] shared ready transition 必须携带 ready semantic facts")
            expect(
                ready.id != loading.id,
                "[129-ANN-RED] loading/ready 必须是两个单调 semantic identities")
            expect(
                fixture.owner.send(
                    .acknowledgeAnnouncement(id: ready.id, didPost: true)) == .applied
                    && fixture.owner.presentation.pendingAnnouncement == nil,
                "[129-ANN-RED] library FIFO 两个 head 消费后队列必须为空")
        }
    }

    await suite("[129-ANN-RED] failure status 抢占 notice，ack 后恢复较低优先级 head") {
        await withTempDirectory { root in
            let fixture = makeSoundEditorFixture(
                root: root,
                packIDs: ["pack-a", "pack-b"])
            let owner = fixture.owner
            await waitForSoundEditorReady(owner, library: fixture.library)
            _ = owner.send(.activate(.sounds(route: .overview, requestRevision: 403)))
            announcementGapDrain(owner)
            guard case .sounds(let initial) = owner.presentation.mode,
                let inspectB = initial.packs.first(where: { $0.id == "pack-b" })?.inspectAction
            else {
                expect(false, "[129-ANN-RED] priority fixture 必须取得 inspect-B")
                return
            }
            _ = owner.send(.invoke(inspectB))
            await waitForSoundEditorInventory(owner)
            announcementGapDrain(owner)
            guard case .sounds(let inspected) = owner.presentation.mode,
                let useB = inspected.selectedPack?.useAction,
                case .accepted(let useID) = owner.send(.invoke(useB))
            else {
                expect(false, "[129-ANN-RED] priority fixture 必须 accepted use notice")
                return
            }
            await owner.waitForScheduledOperationExitForTesting(useID)
            guard let notice = await announcementGapWait(owner) else {
                expect(false, "[129-ANN-RED] successful use 必须形成 notice debt")
                return
            }
            await waitForSoundEditorInventory(owner)
            guard let assign = announcementGapAssignment(owner, event: .notification),
                await announcementGapFailUnderLock(
                    owner: owner,
                    action: assign,
                    lockFile: fixture.packsLockFile)
            else {
                expect(false, "[129-ANN-RED] priority fixture 必须形成后到的 failure status")
                return
            }
            guard let failure = owner.presentation.pendingAnnouncement,
                failure.id != notice.id
            else {
                expect(false, "[129-ANN-RED] 后到 failure 必须抢占未 ack 的 notice")
                return
            }
            expect(
                owner.send(
                    .acknowledgeAnnouncement(id: notice.id, didPost: false)) == .unchanged
                    && owner.presentation.pendingAnnouncement?.id == failure.id,
                "[129-ANN-RED] post 失败不得消费被 failure 插队的 exact notice")
            expect(
                owner.send(
                    .acknowledgeAnnouncement(id: notice.id, didPost: true)) == .applied
                    && owner.presentation.pendingAnnouncement?.id == failure.id,
                "[129-ANN-RED] 已成功 post 的旧 ID 必须精确移除且不能吞掉新 failure head")
            expect(
                owner.send(
                    .acknowledgeAnnouncement(id: notice.id, didPost: true))
                    == .rejected(.staleAction),
                "[129-ANN-RED] 被精确消费的旧 notice 不得 replay")
            expect(
                owner.send(
                    .acknowledgeAnnouncement(id: failure.id, didPost: true)) == .applied
                    && owner.presentation.pendingAnnouncement == nil,
                "[129-ANN-RED] failure head 必须保持独立并只消费一次")
        }
    }

    await suite("[129-ANN-RED] 同 severity FIFO 与 exact-head acknowledgement") {
        await withTempDirectory { root in
            let fixture = makeSoundEditorFixture(
                root: root,
                packIDs: ["pack-a", "pack-b"])
            let owner = fixture.owner
            await waitForSoundEditorReady(owner, library: fixture.library)
            _ = owner.send(.activate(.sounds(route: .overview, requestRevision: 404)))
            guard case .sounds(let initial) = owner.presentation.mode,
                let inspectB = initial.packs.first(where: { $0.id == "pack-b" })?.inspectAction
            else {
                expect(false, "[129-ANN-RED] FIFO fixture 必须取得 inspect-B")
                return
            }
            _ = owner.send(.invoke(inspectB))
            announcementGapDrain(owner)
            guard case .sounds(let firstPresentation) = owner.presentation.mode,
                let firstAction = firstPresentation.selectedPack?.useAction,
                await announcementGapFailUnderLock(
                    owner: owner,
                    action: firstAction,
                    lockFile: root.appendingPathComponent("config.lock")),
                let first = await announcementGapWait(owner)
            else {
                expect(false, "[129-ANN-RED] FIFO fixture 必须形成首个 failure debt")
                return
            }
            guard case .sounds(let secondPresentation) = owner.presentation.mode,
                let secondAction = secondPresentation.selectedPack?.useAction,
                await announcementGapFailUnderLock(
                    owner: owner,
                    action: secondAction,
                    lockFile: root.appendingPathComponent("config.lock"))
            else {
                expect(false, "[129-ANN-RED] FIFO fixture 必须形成第二个 failure debt")
                return
            }

            expect(
                owner.presentation.pendingAnnouncement?.id == first.id,
                "[129-ANN-RED] 同 severity 的后到 failure 不得越过 FIFO head")
            expect(
                owner.send(
                    .acknowledgeAnnouncement(id: first.id, didPost: false)) == .unchanged
                    && owner.presentation.pendingAnnouncement?.id == first.id,
                "[129-ANN-RED] didPost=false 必须保留 FIFO exact head")
            expect(
                owner.send(
                    .acknowledgeAnnouncement(id: first.id, didPost: true)) == .applied,
                "[129-ANN-RED] didPost=true 必须只消费首个 failure")
            guard let second = owner.presentation.pendingAnnouncement,
                second.id != first.id
            else {
                expect(false, "[129-ANN-RED] 首个 ack 后必须暴露第二个 failure")
                return
            }
            expect(
                owner.send(
                    .acknowledgeAnnouncement(id: first.id, didPost: true))
                    == .rejected(.staleAction)
                    && owner.presentation.pendingAnnouncement?.id == second.id,
                "[129-ANN-RED] 旧 ack 不得吞掉新的 queue head")
            expect(
                owner.send(
                    .acknowledgeAnnouncement(id: second.id, didPost: true)) == .applied
                    && owner.presentation.pendingAnnouncement == nil,
                "[129-ANN-RED] 第二个 exact head 必须独立消费")
        }
    }

    await suite("[129-ANN-RED] fork 只产生 compound debt，不重复 selection debt") {
        await withTempDirectory { root in
            let factory = root.appendingPathComponent("factory-packs/factory-a")
            writeFixture(
                #"{"id":"factory-a","name":"Factory A","license":"CC0","events":{"stop":"stop.mp3"}}"#,
                to: factory.appendingPathComponent("manifest.json"))
            writeFixture("factory-audio", to: factory.appendingPathComponent("stop.mp3"))
            let fixture = makeSoundEditorFixture(
                root: root,
                packIDs: ["factory-a"],
                builtinPackIDs: ["factory-a"])
            let owner = fixture.owner
            await waitForSoundEditorReady(owner, library: fixture.library)
            _ = owner.send(.activate(.sounds(route: .overview, requestRevision: 405)))
            announcementGapDrain(owner)
            guard case .sounds(let sounds) = owner.presentation.mode,
                let fork = sounds.selectedPack?.forkAction,
                case .accepted(let operationID) = owner.send(.invoke(fork))
            else {
                expect(false, "[129-ANN-RED] fork fixture 必须 accepted opaque capability")
                return
            }
            await owner.waitForScheduledOperationExitForTesting(operationID)
            await fixture.library.waitUntilIdleForTesting()
            await waitForSoundEditorSelectionChange(owner, awayFrom: "factory-a")
            guard let compound = await announcementGapWait(owner) else {
                expect(false, "[129-ANN-RED] fork success 必须形成 compound debt")
                return
            }
            expect(
                compound.kind == .operation(kind: .fork, completion: .succeeded),
                "[129-ANN-RED] fork queue head 必须是单一 compound semantic outcome")
            expect(
                owner.send(
                    .acknowledgeAnnouncement(id: compound.id, didPost: true)) == .applied
                    && owner.presentation.pendingAnnouncement == nil,
                "[129-ANN-RED] fork compound ack 后不得残留 programmatic selection debt")
        }
    }

    suite("[129-ANN-RED] I-04 sibling package 可见 kind 但不能构造/恢复 payload") {
        withTempDirectory { root in
            let buildDirectory = URL(fileURLWithPath: CommandLine.arguments[0])
                .standardizedFileURL
                .resolvingSymlinksInPath()
                .deletingLastPathComponent()
            let modules = buildDirectory.appendingPathComponent("Modules", isDirectory: true)
            let moduleMap = buildDirectory.appendingPathComponent(
                "ClaudioVersionC.build/module.modulemap")
            let includeDirectory = guiTestRepositoryRoot()
                .appendingPathComponent("helper/Sources/ClaudioVersionC/include")
            let positive = root.appendingPathComponent("Positive.swift")
            let negative = root.appendingPathComponent("Negative.swift")
            writeFixture(
                """
                import ClaudioGUICore
                func accepts(
                    _ action: SoundPackEditorAction,
                    _ importPermit: SoundPackImportPermit,
                    _ adoptionPermit: SoundPackAdoptionPermit
                ) {
                    _ = action.kind
                    _ = importPermit.id
                    _ = adoptionPermit.id
                }
                """,
                to: positive)
            writeFixture(
                """
                import ClaudioGUICore
                func violates(
                    _ action: SoundPackEditorAction,
                    _ importPermit: SoundPackImportPermit,
                    _ adoptionPermit: SoundPackAdoptionPermit
                ) {
                    _ = SoundPackEditorAction(id: 1, kind: .inspect)
                    _ = SoundPackImportPermit(id: 2)
                    _ = SoundPackAdoptionPermit(id: 3)
                    _ = action.id.rawValue
                    _ = importPermit.id.rawValue
                    _ = adoptionPermit.id.rawValue
                }
                """,
                to: negative)
            let commonArguments = [
                "swiftc", "-swift-version", "6", "-typecheck", "-package-name", "gui",
                "-I", modules.path,
                "-Xcc", "-fmodule-map-file=\(moduleMap.path)",
                "-Xcc", "-I", "-Xcc", includeDirectory.path,
            ]
            let positiveResult = runTestProcess(
                executableURL: URL(fileURLWithPath: "/usr/bin/xcrun"),
                arguments: commonArguments + [positive.path])
            expect(
                positiveResult.status == 0,
                "[129-ANN-RED] I-04 positive sibling probe 必须能命名 package types/kind")

            let negativeResult = runTestProcess(
                executableURL: URL(fileURLWithPath: "/usr/bin/xcrun"),
                arguments: commonArguments + [negative.path])
            expect(
                negativeResult.status != 0
                    && negativeResult.output.contains(
                        "'SoundPackEditorAction' initializer is inaccessible")
                    && negativeResult.output.contains(
                        "'SoundPackImportPermit' initializer is inaccessible")
                    && negativeResult.output.contains(
                        "'SoundPackAdoptionPermit' initializer is inaccessible")
                    && negativeResult.output.contains(
                        "ClaudioGUICore.SoundPackEditorAction.ID.rawValue")
                    && negativeResult.output.contains(
                        "ClaudioGUICore.SoundPackImportPermit.ID.rawValue")
                    && negativeResult.output.contains(
                        "ClaudioGUICore.SoundPackAdoptionPermit.ID.rawValue"),
                "[129-ANN-RED] I-04 negative sibling probe 必须拒绝全部 constructor/raw payload")
        }
    }
}

@MainActor
private func announcementGapWait(
    _ owner: SoundPacksEditorOwner
) async -> SoundPackEditorAnnouncement? {
    for _ in 0..<4_096 {
        if let announcement = owner.presentation.pendingAnnouncement { return announcement }
        await Task.yield()
    }
    return nil
}

@MainActor
private func announcementGapDrain(_ owner: SoundPacksEditorOwner) {
    for _ in 0..<256 {
        guard let announcement = owner.presentation.pendingAnnouncement else { return }
        guard
            owner.send(
                .acknowledgeAnnouncement(id: announcement.id, didPost: true)) == .applied
        else {
            expect(false, "[129-ANN-RED] fixture drain 必须只消费当前 exact head")
            return
        }
    }
    expect(false, "[129-ANN-RED] fixture announcement queue 不得无界循环")
}

@MainActor
private func announcementGapAssignment(
    _ owner: SoundPacksEditorOwner,
    event: Event
) -> SoundPackEditorAction? {
    guard case .sounds(let sounds) = owner.presentation.mode,
        case .ready(let inventory) = sounds.inventory
    else { return nil }
    return inventory.first(where: { $0.fileName == "stop.mp3" })?
        .assignments.first(where: { $0.event == event })?.action
}

@MainActor
private func announcementGapFailUnderLock(
    owner: SoundPacksEditorOwner,
    action: SoundPackEditorAction,
    lockFile: URL
) async -> Bool {
    let holder = FileLock(path: lockFile.path)
    guard holder.tryLock() else { return false }
    defer { holder.unlock() }
    guard case .accepted(let operationID) = owner.send(.invoke(action)) else { return false }
    await owner.waitForScheduledOperationExitForTesting(operationID)
    return owner.presentation.activities.first(where: { $0.operationID == operationID })?.phase
        == .failed(.mutationFailed)
}
