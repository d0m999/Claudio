import ClaudioCore
import ClaudioGUICore
import Foundation

private enum SoundEditorImpactInjectedFailure: Error, LocalizedError, Sendable {
    case restorePublish
    case trash

    var errorDescription: String? {
        switch self {
        case .restorePublish: "impact-restore-publish-failure"
        case .trash: "impact-trash-failure"
        }
    }
}

private final class SoundEditorImpactForkCollisionThenSuccess: @unchecked Sendable {
    private let lock = NSLock()
    private var remainingCollisions: Int
    private var storage: [URL] = []

    init(collisions: Int) {
        remainingCollisions = collisions
    }

    var collisionDestinations: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func occupyUntilSuccess(_ destination: URL) throws {
        lock.lock()
        defer { lock.unlock() }
        guard remainingCollisions > 0 else { return }
        remainingCollisions -= 1
        try Data("impact-external-occupier".utf8).write(to: destination)
        storage.append(destination)
    }
}

private final class SoundEditorImpactRestorePublishFailures: @unchecked Sendable {
    private let lock = NSLock()
    private let failingCalls: Set<Int>
    private var storage = 0

    init(failingCalls: Set<Int>) {
        self.failingCalls = failingCalls
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func run() throws {
        lock.lock()
        defer { lock.unlock() }
        storage += 1
        if failingCalls.contains(storage) {
            throw SoundEditorImpactInjectedFailure.restorePublish
        }
    }
}

private final class SoundEditorImpactIsolationMutation: @unchecked Sendable {
    private let lock = NSLock()
    private var isolatedStorage: URL?
    private var retainedOriginalStorage: URL?

    var isolated: URL? {
        lock.lock()
        defer { lock.unlock() }
        return isolatedStorage
    }

    var retainedOriginal: URL? {
        lock.lock()
        defer { lock.unlock() }
        return retainedOriginalStorage
    }

    @MainActor
    func replaceIsolatedEntryAndOccupyOriginal(_ isolated: URL) throws {
        let isolationDirectory = isolated.deletingLastPathComponent()
        let retainedOriginal = isolationDirectory.appendingPathComponent(
            "original-retained-delete-me",
            isDirectory: true)
        try FileManager.default.moveItem(at: isolated, to: retainedOriginal)
        writeFixture("replacement", to: isolated.appendingPathComponent("replacement.txt"))
        let userPacks = isolationDirectory.deletingLastPathComponent()
        writeFixture(
            "external-occupier",
            to: userPacks.appendingPathComponent("delete-me/external.txt"))
        lock.lock()
        isolatedStorage = isolated
        retainedOriginalStorage = retainedOriginal
        lock.unlock()
    }
}

@MainActor
func runSoundPacksEditorMutationImpactGapRedSuites() async {
    await suite("Sound editor impact：assign packs.lock failure 保留 typed debt 且零主动 scan") {
        await withTempDirectory { root in
            let fixture = makeSoundEditorFixture(root: root, packIDs: ["pack-a"])
            let owner = fixture.owner
            _ = owner.send(.activate(.sounds(route: .overview, requestRevision: 101)))
            await waitForSoundEditorReady(owner, library: fixture.library)
            await waitForSoundEditorInventory(owner) { inventory in
                inventory.contains { $0.fileName == "stop.mp3" }
            }
            guard case .sounds(let sounds) = owner.presentation.mode,
                case .ready(let files) = sounds.inventory,
                let assign = files.first(where: { $0.fileName == "stop.mp3" })?
                    .assignments.first(where: { $0.event == .notification })?.action
            else {
                expect(false, "assign lock failure fixture 必须签发 compiled owner capability")
                return
            }
            let manifest = root.appendingPathComponent("packs/pack-a/manifest.json")
            let bytesBefore = try? Data(contentsOf: manifest)
            let scansBefore = fixture.recorder.requests.count
            let panelBefore = fixture.refreshCoordinator.panelReloadRevision
            let holder = FileLock(path: fixture.packsLockFile.path)
            let locked = holder.tryLock()
            expect(locked, "测试前提：必须真实持有 packs.lock")
            defer { if locked { holder.unlock() } }

            guard case .accepted(let operationID) = owner.send(.invoke(assign)) else {
                expect(false, "assign 必须先 accepted，再在 writer 内报告 lockBusy")
                return
            }
            await waitForSoundEditorOperation(owner, operationID: operationID)
            await fixture.library.waitUntilIdleForTesting()

            expect(
                owner.presentation.activities.first(where: { $0.operationID == operationID })?
                    .phase == .failed(.mutationFailed),
                "assign lockBusy 必须保留 typed failure terminal，不能伪装成功")
            expect(
                (try? Data(contentsOf: manifest)) == bytesBefore,
                "assign lockBusy 不得改 manifest bytes")
            expect(
                fixture.recorder.requests.count == scansBefore,
                "assign noChange failure 不得主动请求 shared scan")
            expect(
                fixture.refreshCoordinator.panelReloadRevision == panelBefore,
                "assign noChange failure 不得伪造 panel mutation completion")
            expect(
                owner.presentation.pendingAnnouncement?.kind == .windowStatus(.audio)
                    && owner.presentation.pendingAnnouncement?.kind
                        != .operation(kind: .assign, completion: .succeeded),
                "assign lockBusy 必须保留 audio failure debt，且不能生成 success debt")
        }
    }

    await suite("Sound editor impact：fork 两次 EEXIST 后成功只为最终 published ID scan 一次") {
        await withTempDirectory { root in
            let collisions = SoundEditorImpactForkCollisionThenSuccess(collisions: 2)
            let fixture = makeSoundEditorFixture(
                root: root,
                packIDs: ["factory-a"],
                builtinPackIDs: ["factory-a"],
                beforeForkPackPublish: { try collisions.occupyUntilSuccess($0) })
            let factoryPack = root.appendingPathComponent("factory-packs/factory-a")
            writeFixture(
                #"{"id":"factory-a","name":"Factory A","events":{"stop":"stop.mp3"}}"#,
                to: factoryPack.appendingPathComponent("manifest.json"))
            writeFixture("factory-audio", to: factoryPack.appendingPathComponent("stop.mp3"))
            let owner = fixture.owner
            _ = owner.send(.activate(.sounds(route: .overview, requestRevision: 102)))
            await waitForSoundEditorReady(owner, library: fixture.library)
            guard case .sounds(let sounds) = owner.presentation.mode,
                let fork = sounds.packs.first(where: { $0.id == "factory-a" })?.forkAction,
                case .accepted(let operationID) = owner.send(.invoke(fork))
            else {
                expect(false, "built-in fixture 必须签发并接受 fork")
                return
            }
            let scansBefore = fixture.recorder.requests.count

            await waitForSoundEditorOperation(owner, operationID: operationID)
            await waitForSoundEditorScanCount(fixture.recorder, atLeast: scansBefore + 1)
            await fixture.library.waitUntilIdleForTesting()
            await waitForSoundEditorSelectionChange(owner, awayFrom: "factory-a")
            guard case .sounds(let settled) = owner.presentation.mode,
                let forked = settled.selectedPack,
                forked.id != "factory-a"
            else {
                expect(false, "EEXIST retry 最终成功后必须选择 published user pack")
                return
            }

            let occupied = collisions.collisionDestinations
            expect(occupied.count == 2, "fixture 必须精确注入两次 publish-time EEXIST")
            expect(
                occupied.allSatisfy {
                    (try? Data(contentsOf: $0)) == Data("impact-external-occupier".utf8)
                },
                "fork retry 不得覆盖任何 EEXIST occupier bytes")
            expect(
                owner.presentation.activities.first(where: { $0.operationID == operationID })?
                    .phase == .succeeded,
                "只有最终 published candidate 可 settle fork success")
            let attemptedIDs = Set(occupied.map(\.lastPathComponent) + [forked.id])
            expect(
                fixture.recorder.requests.count == scansBefore + 1
                    && fixture.recorder.requests.last?.invalidatedPackIDs == attemptedIDs
                    && fixture.recorder.requests.last?.invalidatesAll == false,
                "碰撞 candidate 不得各自 scan；最终 success 只能以 exact attempted IDs refresh 一次")
        }
    }

    await suite("Sound editor impact：user delete 普通 trashFailed 回滚原 tree 且零主动 scan") {
        await withTempDirectory { root in
            let fixture = makeSoundEditorFixture(
                root: root,
                packIDs: ["active", "delete-me"],
                manifestJSONByPackID: [
                    "delete-me":
                        #"{"id":"delete-me","name":"Original","events":{"stop":"stop.mp3"},"future":{"keep":true}}"#
                ],
                moveUserPackToTrashForTesting: { _ in
                    throw SoundEditorImpactInjectedFailure.trash
                })
            let owner = fixture.owner
            _ = owner.send(.activate(.sounds(route: .overview, requestRevision: 103)))
            await waitForSoundEditorReady(owner, library: fixture.library)
            guard case .sounds(let initial) = owner.presentation.mode,
                let inspect = initial.packs.first(where: { $0.id == "delete-me" })?.inspectAction
            else {
                expect(false, "inactive user pack 必须可 inspect")
                return
            }
            expect(owner.send(.invoke(inspect)) == .applied, "inspect delete-me 必须应用")
            guard case .sounds(let inspected) = owner.presentation.mode,
                let delete = inspected.selectedPack?.deleteAction,
                case .confirmation(let confirmation) = owner.send(.invoke(delete)),
                case .accepted(let operationID) = owner.send(.invoke(confirmation.confirmAction))
            else {
                expect(false, "user delete 必须经 confirmation 后 accepted")
                return
            }
            let installed = root.appendingPathComponent("packs/delete-me", isDirectory: true)
            let manifest = installed.appendingPathComponent("manifest.json")
            let bytesBefore = try? Data(contentsOf: manifest)
            let scansBefore = fixture.recorder.requests.count
            let panelBefore = fixture.refreshCoordinator.panelReloadRevision

            await waitForSoundEditorOperation(owner, operationID: operationID)
            await fixture.library.waitUntilIdleForTesting()

            expect(
                owner.presentation.activities.first(where: { $0.operationID == operationID })?
                    .phase == .failed(.mutationFailed),
                "trashFailed 必须保留 failure terminal")
            expect(
                (try? Data(contentsOf: manifest)) == bytesBefore,
                "普通 trashFailed 必须把完整 tree 回滚到原路径并保留 unknown bytes")
            expect(
                fixture.recorder.requests.count == scansBefore,
                "回滚成功的 trashFailed 是 noChange，不得主动 scan")
            expect(
                fixture.refreshCoordinator.panelReloadRevision == panelBefore,
                "普通 trashFailed 不得发布 changed panel completion")
            expect(
                owner.presentation.pendingAnnouncement?.kind == .windowStatus(.packDeletion)
                    && owner.presentation.pendingAnnouncement?.messageText?.resolve(
                        language: .english
                    ).contains("impact-trash-failure") == true,
                "typed trash failure reason 必须通过 packDeletion debt 保留")
        }
    }

    await suite("Sound editor impact：isolationChangedRetained 保留 typed path 并 exact refresh") {
        await withTempDirectory { root in
            let mutation = SoundEditorImpactIsolationMutation()
            let fixture = makeSoundEditorFixture(
                root: root,
                packIDs: ["active", "delete-me"],
                manifestJSONByPackID: [
                    "delete-me":
                        #"{"id":"delete-me","name":"Original","events":{"stop":"stop.mp3"},"future":{"keep":true}}"#
                ],
                afterUserPackIsolationForTesting: {
                    try mutation.replaceIsolatedEntryAndOccupyOriginal($0)
                })
            let owner = fixture.owner
            let installed = root.appendingPathComponent("packs/delete-me", isDirectory: true)
            writeFixture("only-copy", to: installed.appendingPathComponent("personal.wav"))
            _ = owner.send(.activate(.sounds(route: .overview, requestRevision: 110)))
            await waitForSoundEditorReady(owner, library: fixture.library)
            guard case .sounds(let initial) = owner.presentation.mode,
                let inspect = initial.packs.first(where: { $0.id == "delete-me" })?.inspectAction
            else {
                expect(false, "isolation-retained fixture 必须可 inspect")
                return
            }
            expect(owner.send(.invoke(inspect)) == .applied, "inspect delete-me 必须应用")
            guard case .sounds(let inspected) = owner.presentation.mode,
                let delete = inspected.selectedPack?.deleteAction,
                case .confirmation(let confirmation) = owner.send(.invoke(delete)),
                case .accepted(let operationID) = owner.send(.invoke(confirmation.confirmAction))
            else {
                expect(false, "isolation-retained delete 必须 accepted")
                return
            }
            let scansBefore = fixture.recorder.requests.count
            let panelBefore = fixture.refreshCoordinator.panelReloadRevision

            await waitForSoundEditorOperation(owner, operationID: operationID)
            await waitForSoundEditorScanCount(fixture.recorder, atLeast: scansBefore + 1)
            await fixture.library.waitUntilIdleForTesting()
            guard let isolated = mutation.isolated,
                let retainedOriginal = mutation.retainedOriginal
            else {
                expect(false, "post-isolation seam 必须报告两个 retained tree identity")
                return
            }
            expect(
                owner.presentation.activities.first(where: { $0.operationID == operationID })?
                    .phase == .failed(.mutationFailed),
                "isolationChangedRetained 必须保留 failure terminal")
            expect(
                (try? Data(contentsOf: retainedOriginal.appendingPathComponent("personal.wav")))
                    == Data("only-copy".utf8)
                    && (try? Data(contentsOf: isolated.appendingPathComponent("replacement.txt")))
                        == Data("replacement".utf8)
                    && (try? Data(contentsOf: installed.appendingPathComponent("external.txt")))
                        == Data("external-occupier".utf8),
                "identity drift 后原 tree、可疑 replacement 与 concurrent occupier 必须全部保留")
            expect(
                owner.presentation.pendingAnnouncement?.kind == .windowStatus(.packDeletion)
                    && owner.presentation.pendingAnnouncement?.messageText
                        == .localized(.soundPacksPackDeleteIsolationRetained, isolated.path),
                "isolationChangedRetained typed path 必须原样进入 packDeletion debt")
            expect(
                fixture.recorder.requests.count == scansBefore + 1
                    && fixture.recorder.requests.last?.invalidatedPackIDs == ["delete-me"]
                    && fixture.recorder.requests.last?.invalidatesAll == false,
                "isolationChangedRetained 必须 exact refresh 一次")
            expect(
                fixture.refreshCoordinator.panelReloadRevision == panelBefore + 1,
                "isolationChangedRetained 是 changedDespiteFailure，必须刷新 panel")
        }
    }

    await suite("Sound editor impact：orphan packs.lock failure 保留旧 truth 且零主动 scan") {
        await withTempDirectory { root in
            let fixture = makeSoundEditorFixture(root: root, packIDs: ["pack-a"])
            let orphan = root.appendingPathComponent("packs/pack-a/orphan.mp3")
            writeFixture("orphan", to: orphan)
            let owner = fixture.owner
            _ = owner.send(.activate(.sounds(route: .overview, requestRevision: 104)))
            await waitForSoundEditorReady(owner, library: fixture.library)
            await waitForSoundEditorInventory(owner) { inventory in
                inventory.contains { $0.fileName == "orphan.mp3" }
            }
            guard case .sounds(let sounds) = owner.presentation.mode,
                case .ready(let files) = sounds.inventory,
                let request = files.first(where: { $0.fileName == "orphan.mp3" })?.deleteAction,
                case .confirmation(let confirmation) = owner.send(.invoke(request))
            else {
                expect(false, "orphan fixture 必须签发 delete confirmation")
                return
            }
            let scansBefore = fixture.recorder.requests.count
            let panelBefore = fixture.refreshCoordinator.panelReloadRevision
            let holder = FileLock(path: fixture.packsLockFile.path)
            let locked = holder.tryLock()
            expect(locked, "测试前提：必须真实持有 packs.lock")
            defer { if locked { holder.unlock() } }
            guard case .accepted(let operationID) = owner.send(.invoke(confirmation.confirmAction))
            else {
                expect(false, "orphan confirmation 必须 accepted")
                return
            }

            await waitForSoundEditorOperation(owner, operationID: operationID)
            await fixture.library.waitUntilIdleForTesting()
            expect(
                owner.presentation.activities.first(where: { $0.operationID == operationID })?
                    .phase == .failed(.mutationFailed),
                "orphan lockBusy 必须保留 failure terminal")
            expect(regularFileExists(at: orphan), "lockBusy 不得删除 orphan bytes")
            expect(
                fixture.recorder.requests.count == scansBefore,
                "普通 orphan lock failure 不得触发 observation 或 completion scan")
            expect(
                fixture.refreshCoordinator.panelReloadRevision == panelBefore,
                "orphan noChange failure 不得发布 panel completion")
            expect(
                owner.presentation.pendingAnnouncement?.kind == .windowStatus(.audio),
                "orphan lockBusy 必须保留 audio failure debt")
        }
    }

    await suite("Sound editor impact：retry publishFailed nil 保留既有 salvage 且零新 scan") {
        await withTempDirectory { root in
            let failures = SoundEditorImpactRestorePublishFailures(failingCalls: [1, 2])
            let fixture = makeSoundEditorFixture(
                root: root,
                packIDs: ["factory-a"],
                builtinPackIDs: ["factory-a"],
                beforeFactoryPackRestorePublish: { try failures.run() })
            let installed = root.appendingPathComponent("packs/factory-a", isDirectory: true)
            writeFixture("first-salvage", to: installed.appendingPathComponent("personal.wav"))
            let factory = root.appendingPathComponent("factory-packs/factory-a")
            writeFixture(
                #"{"id":"factory-a","name":"Factory","events":{"stop":"stop.mp3"}}"#,
                to: factory.appendingPathComponent("manifest.json"))
            writeFixture("factory", to: factory.appendingPathComponent("stop.mp3"))
            let owner = fixture.owner
            _ = owner.send(.activate(.sounds(route: .overview, requestRevision: 105)))
            await waitForSoundEditorReady(owner, library: fixture.library)
            guard case .sounds(let sounds) = owner.presentation.mode,
                let restore = sounds.packs.first(where: { $0.id == "factory-a" })?.restoreAction,
                case .confirmation(let firstConfirmation) = owner.send(.invoke(restore)),
                case .accepted(let firstID) = owner.send(.invoke(firstConfirmation.confirmAction))
            else {
                expect(false, "initial restore 必须 accepted")
                return
            }
            let firstScans = fixture.recorder.requests.count
            await waitForSoundEditorOperation(owner, operationID: firstID)
            await waitForSoundEditorScanCount(fixture.recorder, atLeast: firstScans + 1)
            await fixture.library.waitUntilIdleForTesting()
            await waitForSoundEditorRecovery(owner, packID: "factory-a")
            guard case .sounds(let failed) = owner.presentation.mode,
                let retry = failed.recoveryActions.first(where: { $0.packID == "factory-a" })?
                    .retryAction,
                case .confirmation(let retryConfirmation) = owner.send(.invoke(retry))
            else {
                expect(false, "changedDespiteFailure 必须签发 retry recovery")
                return
            }
            let salvageBefore = soundEditorImpactSalvages(in: root, packID: "factory-a")
            let scansBeforeRetry = fixture.recorder.requests.count
            let panelBeforeRetry = fixture.refreshCoordinator.panelReloadRevision
            guard
                case .accepted(let retryID) = owner.send(
                    .invoke(retryConfirmation.confirmAction))
            else {
                expect(false, "retry restore 必须 accepted")
                return
            }

            await waitForSoundEditorOperation(owner, operationID: retryID)
            await fixture.library.waitUntilIdleForTesting()
            await waitForSoundEditorRecovery(owner, packID: "factory-a")
            let salvageAfter = soundEditorImpactSalvages(in: root, packID: "factory-a")
            expect(failures.callCount == 2, "fixture 必须精确失败 initial 与 retry publish")
            expect(
                owner.presentation.activities.first(where: { $0.operationID == retryID })?.phase
                    == .failed(.mutationFailed),
                "retry publishFailed(salvaged:nil) 必须保留 failure terminal")
            expect(
                salvageBefore.count == 1 && salvageAfter == salvageBefore
                    && salvageAfter.first.map {
                        (try? Data(contentsOf: $0.appendingPathComponent("personal.wav")))
                            == Data("first-salvage".utf8)
                    } == true,
                "nil salvage retry 不得丢弃或替换先前 retained salvage")
            expect(
                fixture.recorder.requests.count == scansBeforeRetry,
                "retry publishFailed(salvaged:nil) 是 noChange，不得请求新 scan")
            expect(
                fixture.refreshCoordinator.panelReloadRevision == panelBeforeRetry,
                "nil salvage retry 不得发布 changed panel completion")
        }
    }

    await suite("Sound editor impact：retry 新 salvage 追加保留并 exact refresh 一次") {
        await withTempDirectory { root in
            let failures = SoundEditorImpactRestorePublishFailures(failingCalls: [1, 2])
            let fixture = makeSoundEditorFixture(
                root: root,
                packIDs: ["factory-a"],
                builtinPackIDs: ["factory-a"],
                beforeFactoryPackRestorePublish: { try failures.run() })
            let installed = root.appendingPathComponent("packs/factory-a", isDirectory: true)
            writeFixture("first-salvage", to: installed.appendingPathComponent("first.wav"))
            let factory = root.appendingPathComponent("factory-packs/factory-a")
            writeFixture(
                #"{"id":"factory-a","name":"Factory","events":{"stop":"stop.mp3"}}"#,
                to: factory.appendingPathComponent("manifest.json"))
            writeFixture("factory", to: factory.appendingPathComponent("stop.mp3"))
            let owner = fixture.owner
            _ = owner.send(.activate(.sounds(route: .overview, requestRevision: 106)))
            await waitForSoundEditorReady(owner, library: fixture.library)
            guard case .sounds(let sounds) = owner.presentation.mode,
                let restore = sounds.packs.first(where: { $0.id == "factory-a" })?.restoreAction,
                case .confirmation(let firstConfirmation) = owner.send(.invoke(restore)),
                case .accepted(let firstID) = owner.send(.invoke(firstConfirmation.confirmAction))
            else {
                expect(false, "initial restore 必须 accepted")
                return
            }
            let firstScans = fixture.recorder.requests.count
            await waitForSoundEditorOperation(owner, operationID: firstID)
            await waitForSoundEditorScanCount(fixture.recorder, atLeast: firstScans + 1)
            await fixture.library.waitUntilIdleForTesting()
            await waitForSoundEditorRecovery(owner, packID: "factory-a")

            writeFixture(
                #"{"id":"factory-a","name":"Concurrent","events":{"stop":"stop.mp3"}}"#,
                to: installed.appendingPathComponent("manifest.json"))
            writeFixture("second-salvage", to: installed.appendingPathComponent("second.wav"))
            guard case .sounds(let failed) = owner.presentation.mode,
                let retry = failed.recoveryActions.first(where: { $0.packID == "factory-a" })?
                    .retryAction,
                case .confirmation(let retryConfirmation) = owner.send(.invoke(retry))
            else {
                expect(false, "initial salvage failure 必须保留 retry")
                return
            }
            let scansBeforeRetry = fixture.recorder.requests.count
            let panelBeforeRetry = fixture.refreshCoordinator.panelReloadRevision
            guard
                case .accepted(let retryID) = owner.send(
                    .invoke(retryConfirmation.confirmAction))
            else {
                expect(false, "retry with concurrent tree 必须 accepted")
                return
            }

            await waitForSoundEditorOperation(owner, operationID: retryID)
            await waitForSoundEditorScanCount(fixture.recorder, atLeast: scansBeforeRetry + 1)
            await fixture.library.waitUntilIdleForTesting()
            await waitForSoundEditorRecovery(owner, packID: "factory-a")
            let salvages = soundEditorImpactSalvages(in: root, packID: "factory-a")
            let retainedNames = Set(
                salvages.flatMap { salvage in
                    ((try? FileManager.default.contentsOfDirectory(atPath: salvage.path)) ?? [])
                })
            expect(
                owner.presentation.activities.first(where: { $0.operationID == retryID })?.phase
                    == .failed(.mutationFailed),
                "retry publishFailed(salvaged:nonnil) 必须保留 failure terminal")
            expect(
                salvages.count == 2
                    && retainedNames.contains("first.wav")
                    && retainedNames.contains("second.wav")
                    && !FileManager.default.fileExists(atPath: installed.path),
                "changedDespiteFailure retry 必须追加而非覆盖全部 salvage truth")
            expect(
                fixture.recorder.requests.count == scansBeforeRetry + 1
                    && fixture.recorder.requests.last?.invalidatedPackIDs == ["factory-a"]
                    && fixture.recorder.requests.last?.invalidatesAll == false,
                "retry nonnil salvage 必须 exact refresh 一次")
            expect(
                fixture.refreshCoordinator.panelReloadRevision == panelBeforeRetry + 1,
                "retry changedDespiteFailure 必须发布一次 panel completion")
        }
    }

    await suite("Sound editor impact：restore batch all-success 只 scan 一次 exact attempted IDs") {
        await withTempDirectory { root in
            let ids = ["factory-a", "factory-b"]
            let fixture = makeSoundEditorFixture(
                root: root,
                packIDs: ids,
                builtinPackIDs: Set(ids))
            let userPacks = root.appendingPathComponent("packs", isDirectory: true)
            let factoryPacks = root.appendingPathComponent("factory-packs", isDirectory: true)
            for id in ids {
                writeFixture(
                    #"{"id":"\#(id)","name":"\#(id)","events":{"stop":"stop.mp3"}}"#,
                    to: factoryPacks.appendingPathComponent("\(id)/manifest.json"))
                writeFixture(
                    "factory-\(id)", to: factoryPacks.appendingPathComponent("\(id)/stop.mp3"))
                writeFixture(
                    "user-\(id)", to: userPacks.appendingPathComponent("\(id)/personal.wav"))
            }
            let owner = fixture.owner
            _ = owner.send(.activate(.sounds(route: .overview, requestRevision: 107)))
            await waitForSoundEditorReady(owner, library: fixture.library)
            guard case .sounds(let sounds) = owner.presentation.mode,
                let request = sounds.restoreAllFactoryPacksAction,
                case .confirmation(let confirmation) = owner.send(.invoke(request)),
                case .accepted(let operationID) = owner.send(.invoke(confirmation.confirmAction))
            else {
                expect(false, "all-success batch 必须 accepted")
                return
            }
            let scansBefore = fixture.recorder.requests.count
            let panelBefore = fixture.refreshCoordinator.panelReloadRevision

            await waitForSoundEditorOperation(owner, operationID: operationID)
            await waitForSoundEditorScanCount(fixture.recorder, atLeast: scansBefore + 1)
            await fixture.library.waitUntilIdleForTesting()
            expect(
                owner.presentation.activities.first(where: { $0.operationID == operationID })?
                    .phase == .succeeded,
                "all-success aggregate 必须保留 succeeded terminal")
            expect(
                ids.allSatisfy {
                    (try? Data(
                        contentsOf: userPacks.appendingPathComponent("\($0)/stop.mp3")))
                        == Data("factory-\($0)".utf8)
                },
                "all-success 必须发布全部 factory bytes")
            expect(
                fixture.recorder.requests.count == scansBefore + 1
                    && fixture.recorder.requests.last?.invalidatedPackIDs == Set(ids)
                    && fixture.recorder.requests.last?.invalidatesAll == false,
                "all-success batch 只能为 exact attempted IDs 请求一次 scan")
            expect(
                fixture.refreshCoordinator.panelReloadRevision == panelBefore + 1,
                "all-success batch 必须只发布一次 panel completion")
        }
    }

    await suite("Sound editor impact：restore batch all-noChange 保留 exact failures 且零 scan") {
        await withTempDirectory { root in
            let ids = ["factory-a", "factory-b"]
            let failures = SoundEditorImpactRestorePublishFailures(failingCalls: [1, 2])
            let fixture = makeSoundEditorFixture(
                root: root,
                packIDs: ids,
                builtinPackIDs: Set(ids),
                beforeFactoryPackRestorePublish: { try failures.run() })
            let factoryPacks = root.appendingPathComponent("factory-packs", isDirectory: true)
            for id in ids {
                writeFixture(
                    #"{"id":"\#(id)","name":"\#(id)","events":{"stop":"stop.mp3"}}"#,
                    to: factoryPacks.appendingPathComponent("\(id)/manifest.json"))
                writeFixture(
                    "factory-\(id)", to: factoryPacks.appendingPathComponent("\(id)/stop.mp3"))
            }
            let owner = fixture.owner
            _ = owner.send(.activate(.sounds(route: .overview, requestRevision: 108)))
            await waitForSoundEditorReady(owner, library: fixture.library)
            guard case .sounds(let sounds) = owner.presentation.mode,
                let request = sounds.restoreAllFactoryPacksAction
            else {
                expect(false, "all-noChange batch fixture 必须签发 restore-all")
                return
            }
            let userPacks = root.appendingPathComponent("packs", isDirectory: true)
            for id in ids {
                try? FileManager.default.removeItem(
                    at: userPacks.appendingPathComponent(id, isDirectory: true))
            }
            guard case .confirmation(let confirmation) = owner.send(.invoke(request)),
                case .accepted(let operationID) = owner.send(.invoke(confirmation.confirmAction))
            else {
                expect(false, "all-noChange batch 必须 accepted")
                return
            }
            let scansBefore = fixture.recorder.requests.count
            let panelBefore = fixture.refreshCoordinator.panelReloadRevision

            await waitForSoundEditorOperation(owner, operationID: operationID)
            await fixture.library.waitUntilIdleForTesting()
            expect(failures.callCount == ids.count, "batch 必须精确尝试每个 factory ID 一次")
            expect(
                owner.presentation.activities.first(where: { $0.operationID == operationID })?
                    .phase == .failed(.mutationFailed),
                "all-noChange aggregate 必须保留 typed failure terminal")
            guard case .sounds(let settled) = owner.presentation.mode else {
                expect(false, "all-noChange settle 后必须保留 Sounds mode")
                return
            }
            expect(
                settled.recoveryActions.map(\.packID) == ids,
                "all-noChange batch 必须保留 exact attempted failure IDs")
            expect(
                soundEditorImpactSalvages(in: root, packID: "factory-a").isEmpty
                    && soundEditorImpactSalvages(in: root, packID: "factory-b").isEmpty,
                "publishFailed(salvaged:nil) 不得伪造 salvage")
            expect(
                fixture.recorder.requests.count == scansBefore,
                "all-no-persistent-change batch 不得主动 scan")
            expect(
                fixture.refreshCoordinator.panelReloadRevision == panelBefore,
                "all-noChange batch 不得发布 changed panel completion")
        }
    }

    await suite("Sound editor DEBUG：transaction quiescence 等待 writer、shared scan 与 settle") {
        await withTempDirectory { root in
            let fixture = makeSoundEditorFixture(root: root, packIDs: ["pack-a"])
            let owner = fixture.owner
            _ = owner.send(.activate(.sounds(route: .overview, requestRevision: 109)))
            await waitForSoundEditorReady(owner, library: fixture.library)
            guard case .sounds(let sounds) = owner.presentation.mode,
                let clear = sounds.eventRows.first(where: { $0.event == .stop })?.clearAction
            else {
                expect(false, "quiescence fixture 必须签发 clear capability")
                return
            }
            let scansBefore = fixture.recorder.requests.count
            guard case .accepted(let operationID) = owner.send(.invoke(clear)) else {
                expect(false, "clear 必须 accepted")
                return
            }

            // Missing at fixed 2a5c3f7: one owner-level DEBUG join must cover the complete
            // transaction, including a task that may already have removed its per-ID entry and
            // the shared observation refresh it requested. Tests must not guess with yield loops.
            await owner.waitForMutationTransactionsToQuiesceForTesting()

            expect(
                owner.presentation.activities.first(where: { $0.operationID == operationID })?
                    .phase == .succeeded,
                "quiescence 返回时 scheduled operation 必须已 settle")
            expect(
                fixture.recorder.requests.count == scansBefore + 1
                    && fixture.recorder.requests.last?.invalidatedPackIDs == ["pack-a"],
                "quiescence 返回时 exact shared refresh 必须已完成")
            guard case .sounds(let settled) = owner.presentation.mode else {
                expect(false, "quiescence 后必须保留 Sounds mode")
                return
            }
            expect(
                settled.eventRows.first(where: { $0.event == .stop })?.coverage == .unmapped,
                "quiescence 返回时 presentation 必须来自最终 shared observation")
        }
    }
}

private func soundEditorImpactSalvages(in root: URL, packID: String) -> [URL] {
    let packs = root.appendingPathComponent("packs", isDirectory: true)
    let names = (try? FileManager.default.contentsOfDirectory(atPath: packs.path)) ?? []
    return names.sorted().compactMap { name in
        guard name.hasPrefix(".\(packID).pre-restore-") else { return nil }
        return packs.appendingPathComponent(name, isDirectory: true)
    }
}
