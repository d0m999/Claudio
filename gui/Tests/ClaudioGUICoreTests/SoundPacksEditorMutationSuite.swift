import ClaudioCore
import ClaudioGUICore
import Foundation

@MainActor
func runSoundPacksEditorMutationSuites() async {
    await suite("Sound editor actions：inspect A→B→A 使旧 capability 永久失效且零写入") {
        await withTempDirectory { root in
            let fixture = makeSoundEditorFixture(root: root, packIDs: ["pack-a", "pack-b"])
            let owner = fixture.owner
            _ = owner.send(
                .activate(
                    .sounds(
                        route: .overview,
                        requestRevision: 1)))
            await waitForSoundEditorReady(owner, library: fixture.library)

            guard case .sounds(let initial) = owner.presentation.mode,
                let oldClear = initial.eventRows.first(where: { $0.event == .stop })?.clearAction,
                let inspectB = initial.packs.first(where: { $0.id == "pack-b" })?.inspectAction
            else {
                expect(false, "ready Sounds slice 必须签发检查与清除 capability")
                return
            }
            let manifest = root.appendingPathComponent("packs/pack-a/manifest.json")
            let before = try? Data(contentsOf: manifest)
            let scansBefore = fixture.recorder.requests.count

            expect(owner.send(.invoke(inspectB)) == .applied, "A→B 的 inspect 必须同步应用")
            guard case .sounds(let atB) = owner.presentation.mode,
                let inspectA = atB.packs.first(where: { $0.id == "pack-a" })?.inspectAction
            else {
                expect(false, "B presentation 必须签发新的 A capability")
                return
            }
            expect(owner.send(.invoke(inspectA)) == .applied, "B→A 的 inspect 必须同步应用")
            expect(
                owner.send(.invoke(oldClear)) == .rejected(.staleAction),
                "第一次 A 的 capability 不能在 A→B→A 后复活")
            expect(
                (try? Data(contentsOf: manifest)) == before
                    && fixture.recorder.requests.count == scansBefore,
                "inspect 与 stale replay 必须零磁盘写、零 library refresh")
        }
    }

    await suite("Sound editor actions：star 使用 lock-time CAS 保留外部 sibling") {
        await withTempDirectory { root in
            let fixture = makeSoundEditorFixture(
                root: root,
                packIDs: ["pack-a", "pack-b", "pack-c"],
                starred: ["pack-a"])
            let owner = fixture.owner
            _ = owner.send(.activate(.sounds(route: .overview, requestRevision: 2)))
            await waitForSoundEditorReady(owner, library: fixture.library)
            guard case .sounds(let sounds) = owner.presentation.mode,
                let starC = sounds.packs.first(where: { $0.id == "pack-c" })?.toggleStarAction
            else {
                expect(false, "第三个已安装包必须有 toggle-star capability")
                return
            }

            writeFixture(
                #"{"selected_pack":"pack-a","master_volume":0.37,"events":{"stop":true},"starred_packs":["pack-a","pack-b"],"future":{"keep":true}}"#,
                to: fixture.configFile)
            let scansBefore = fixture.recorder.requests.count
            expect(owner.send(.invoke(starC)) == .applied, "star mutation 必须同步返回真实结果")

            let object =
                try? JSONSerialization.jsonObject(
                    with: Data(contentsOf: fixture.configFile)) as? [String: Any]
            expect(
                object?["starred_packs"] as? [String] == ["pack-a", "pack-b", "pack-c"],
                "CAS toggle 必须保留 action 签发后由外部加入的 sibling")
            expect((object?["master_volume"] as? Double) == 0.37, "star 不得改写全局音量")
            expect(
                (object?["future"] as? [String: Bool])?["keep"] == true,
                "star 必须保留未知顶层字段")
            expect(
                fixture.recorder.requests.count == scansBefore,
                "config-only star 不得触发 SoundPackLibrary scan")
        }
    }

    await suite("Sound editor confirmation：请求零写、confirm 单次消费、busy 同栈发布、公告成功才消费") {
        await withTempDirectory { root in
            let fixture = makeSoundEditorFixture(root: root, packIDs: ["pack-a"])
            let orphan = root.appendingPathComponent("packs/pack-a/orphan.mp3")
            writeFixture("orphan", to: orphan)
            let owner = fixture.owner
            _ = owner.send(.activate(.sounds(route: .overview, requestRevision: 3)))
            await waitForSoundEditorReady(owner, library: fixture.library)
            await waitForSoundEditorInventory(owner)
            guard case .sounds(let sounds) = owner.presentation.mode,
                case .ready(let audio) = sounds.inventory,
                let requestDelete = audio.first(where: { $0.fileName == "orphan.mp3" })?
                    .deleteAction
            else {
                expect(false, "orphan inventory 必须携带 delete capability")
                return
            }
            let scansBefore = fixture.recorder.requests.count

            guard case .confirmation(let confirmation) = owner.send(.invoke(requestDelete)) else {
                expect(false, "第一次 destructive invoke 只能发布 confirmation")
                return
            }
            expect(regularFileExists(at: orphan), "confirmation 阶段不得提前删除文件")
            expect(
                fixture.recorder.requests.count == scansBefore,
                "confirmation 阶段不得 invalidate 或 scan")
            guard case .accepted(let operationID) = owner.send(.invoke(confirmation.confirmAction))
            else {
                expect(false, "confirm 必须同步消费 token 并接受 operation")
                return
            }
            expect(
                owner.presentation.activities.contains {
                    $0.operationID == operationID && $0.phase == .busy
                },
                "send 返回前 busy 必须已经在同一 MainActor stack 可见")
            expect(
                owner.send(.invoke(confirmation.confirmAction)) == .rejected(.staleConfirmation),
                "confirm token 必须 single-use，调度窗口内 replay 也失败关闭")

            await waitForSoundEditorOperation(owner, operationID: operationID)
            await fixture.library.waitUntilIdleForTesting()
            for _ in 0..<8 { await Task.yield() }
            expect(!regularFileExists(at: orphan), "唯一 accepted operation 必须删除孤儿文件")
            expect(
                owner.presentation.activities.contains {
                    $0.operationID == operationID && $0.phase == .succeeded
                },
                "operation 必须以同一 identity settle")
            expect(
                fixture.recorder.requests.count == scansBefore + 1
                    && fixture.recorder.requests.last?.invalidatedPackIDs == ["pack-a"],
                "pack mutation 必须只触发一次 exact shared refresh")

            guard let announcement = owner.presentation.pendingAnnouncement else {
                expect(false, "成功 mutation 必须产生 semantic announcement debt")
                return
            }
            expect(
                owner.send(
                    .acknowledgeAnnouncement(id: announcement.id, didPost: false)) == .unchanged
                    && owner.presentation.pendingAnnouncement?.id == announcement.id,
                "post=false 不得消费 announcement")
            expect(
                owner.send(
                    .acknowledgeAnnouncement(id: announcement.id, didPost: true)) == .applied,
                "只有真实 post 成功才能消费 announcement")
            expect(
                owner.send(
                    .acknowledgeAnnouncement(id: announcement.id, didPost: true))
                    == .rejected(.staleAction),
                "已 ack identity 不得重放")
        }
    }
}

struct SoundEditorFixture {
    let owner: SoundPacksEditorOwner
    let library: SoundPackLibrary
    let recorder: SoundEditorScanRecorder
    let configFile: URL
}

final class SoundEditorScanRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [SoundPackLibraryScanRequest] = []

    var requests: [SoundPackLibraryScanRequest] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ request: SoundPackLibraryScanRequest) {
        lock.lock()
        storage.append(request)
        lock.unlock()
    }
}

@MainActor
func makeSoundEditorFixture(
    root: URL,
    packIDs: [String],
    starred: [String] = []
) -> SoundEditorFixture {
    let packs = root.appendingPathComponent("packs", isDirectory: true)
    for packID in packIDs {
        writeFixture(
            """
            {"id":"\(packID)","name":"\(packID)","events":{"stop":"stop.mp3"},"future":{"keep":true}}
            """,
            to: packs.appendingPathComponent("\(packID)/manifest.json"))
        writeFixture("audio", to: packs.appendingPathComponent("\(packID)/stop.mp3"))
    }
    let configFile = root.appendingPathComponent("config.json")
    let starredJSON = starred.map { "\"\($0)\"" }.joined(separator: ",")
    writeFixture(
        """
        {"selected_pack":"\(packIDs.first ?? "")","master_volume":0.37,"events":{"stop":true},"starred_packs":[\(starredJSON)],"future":{"keep":true}}
        """,
        to: configFile)
    let environment = makeAudioImportEnvironment(userPacksDirectory: packs)
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
func waitForSoundEditorReady(
    _ owner: SoundPacksEditorOwner,
    library: SoundPackLibrary
) async {
    for _ in 0..<512 {
        if case .ready = owner.presentation.library { return }
        await Task.yield()
    }
    await library.waitUntilIdleForTesting()
    for _ in 0..<16 { await Task.yield() }
}

@MainActor
func waitForSoundEditorInventory(_ owner: SoundPacksEditorOwner) async {
    for _ in 0..<512 {
        if case .sounds(let sounds) = owner.presentation.mode,
            case .ready = sounds.inventory
        {
            return
        }
        await Task.yield()
    }
}

@MainActor
func waitForSoundEditorOperation(
    _ owner: SoundPacksEditorOwner,
    operationID: SoundPackEditorOperationID
) async {
    for _ in 0..<512 {
        if owner.presentation.activities.contains(where: {
            $0.operationID == operationID && $0.phase != .busy
        }) {
            return
        }
        await Task.yield()
    }
}
