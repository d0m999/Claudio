import ClaudioCore
import ClaudioGUICore
import Combine
import Foundation

private enum SoundEditorInjectedMutationFailure: Error, Sendable {
    case restorePublish
}

private final class SoundEditorFailSelectedRestorePublishCalls: @unchecked Sendable {
    private let lock = NSLock()
    private let failingCalls: Set<Int>
    private var callCount = 0

    init(_ failingCalls: Set<Int>) {
        self.failingCalls = failingCalls
    }

    func run() throws {
        lock.lock()
        defer { lock.unlock() }
        callCount += 1
        if failingCalls.contains(callCount) {
            throw SoundEditorInjectedMutationFailure.restorePublish
        }
    }
}

private final class SoundEditorForkCollisionOccupier: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URL] = []

    var destinations: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func occupy(_ destination: URL) throws {
        lock.lock()
        defer { lock.unlock() }
        try Data("external-occupier".utf8).write(to: destination)
        storage.append(destination)
    }
}

/// Coordinates the exact M-07 window without sleeping: an old scan is held immediately before
/// terminal publication, while the restore writer is held immediately before publishing its new
/// pack tree. The follow-up scan is then held until the writer has returned.
private final class SoundEditorMutationPublicationGate: @unchecked Sendable {
    private let lock = NSLock()
    private let oldPublicationEntered = DispatchSemaphore(value: 0)
    private let oldPublicationResume = DispatchSemaphore(value: 0)
    private let followUpRequestEntered = DispatchSemaphore(value: 0)
    private let followUpRequestResume = DispatchSemaphore(value: 0)
    private var armedRequestCount: Int?
    private var requestCount = 0
    private var didPauseOldPublication = false
    private var followUpArrivedBeforeWriterPublishStorage = false

    var followUpArrivedBeforeWriterPublish: Bool {
        lock.lock()
        defer { lock.unlock() }
        return followUpArrivedBeforeWriterPublishStorage
    }

    func arm(afterRequestCount requestCount: Int) {
        lock.lock()
        armedRequestCount = requestCount
        lock.unlock()
    }

    func observeScanRequest() {
        lock.lock()
        requestCount += 1
        let shouldPause = armedRequestCount.map { requestCount == $0 + 2 } ?? false
        lock.unlock()
        guard shouldPause else { return }
        followUpRequestEntered.signal()
        _ = followUpRequestResume.wait(timeout: .now() + 5)
    }

    func pauseArmedOldPublication() {
        lock.lock()
        let shouldPause = armedRequestCount != nil && !didPauseOldPublication
        if shouldPause { didPauseOldPublication = true }
        lock.unlock()
        guard shouldPause else { return }
        oldPublicationEntered.signal()
        _ = oldPublicationResume.wait(timeout: .now() + 5)
    }

    func waitUntilOldPublicationIsPaused() -> Bool {
        oldPublicationEntered.wait(timeout: .now() + 5) == .success
    }

    /// Runs on the synchronous restore writer's MainActor hook.
    func releaseOldPublicationAndAwaitFollowUp() {
        oldPublicationResume.signal()
        let arrived = followUpRequestEntered.wait(timeout: .now() + 5) == .success
        lock.lock()
        followUpArrivedBeforeWriterPublishStorage = arrived
        lock.unlock()
    }

    func allowFollowUpScan() {
        followUpRequestResume.signal()
    }
}

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

    await suite("Sound editor actions：use 同栈 accepted/busy/single-use，取消零写，成功零 scan") {
        await withTempDirectory { root in
            let fixture = makeSoundEditorFixture(root: root, packIDs: ["pack-a", "pack-b"])
            let owner = fixture.owner
            _ = owner.send(.activate(.sounds(route: .overview, requestRevision: 10)))
            await waitForSoundEditorReady(owner, library: fixture.library)
            guard case .sounds(let initial) = owner.presentation.mode,
                let useB = initial.packs.first(where: { $0.id == "pack-b" })?.useAction
            else {
                expect(false, "ready presentation 必须签发 use pack-b capability")
                return
            }
            let configBefore = try? Data(contentsOf: fixture.configFile)
            let scansBefore = fixture.recorder.requests.count

            guard case .accepted(let cancelledID) = owner.send(.invoke(useB)) else {
                expect(false, "use 必须由 owner 同栈接受为 scheduled operation")
                return
            }
            guard
                let busy = owner.presentation.activities.first(where: {
                    $0.operationID == cancelledID
                }),
                let cancel = busy.cancelAction
            else {
                expect(false, "use send 返回前必须以同一 operation ID 发布 busy 与 cancel")
                return
            }
            expect(
                busy.kind == .use && busy.phase == .busy && busy.packID == "pack-b",
                "use busy activity 必须携带稳定 kind/target identity")
            expect(
                (try? Data(contentsOf: fixture.configFile)) == configBefore,
                "owner 首次 yield 前不得写 selected_pack")
            expect(
                owner.send(.invoke(useB)) == .rejected(.staleAction),
                "use capability 必须在 accepted 的同一 stack 内 single-use")

            expect(owner.send(.invoke(cancel)) == .applied, "首次 yield 前 cancel 必须同步应用")
            expect(
                owner.presentation.activities.first(where: {
                    $0.operationID == cancelledID
                })?.phase == .cancelled(changedOnDisk: false),
                "cancel 必须 settle 同一 operation ID，不能另造 completion")
            expect(
                (try? Data(contentsOf: fixture.configFile)) == configBefore
                    && fixture.recorder.requests.count == scansBefore,
                "cancel 同栈返回时必须尚未写 config 或请求 scan")
        }

        await withTempDirectory { root in
            let fixture = makeSoundEditorFixture(root: root, packIDs: ["pack-a", "pack-c"])
            let owner = fixture.owner
            _ = owner.send(.activate(.sounds(route: .overview, requestRevision: 11)))
            await waitForSoundEditorReady(owner, library: fixture.library)
            guard case .sounds(let initial) = owner.presentation.mode,
                let useC = initial.packs.first(where: { $0.id == "pack-c" })?.useAction,
                case .accepted(let completedID) = owner.send(.invoke(useC))
            else {
                expect(false, "独立 success fixture 必须签发并接受 use pack-c")
                return
            }
            let configBefore = try? Data(contentsOf: fixture.configFile)
            let scansBefore = fixture.recorder.requests.count
            let panelRevisionBefore = fixture.refreshCoordinator.panelReloadRevision
            expect(
                owner.presentation.activities.first(where: {
                    $0.operationID == completedID
                })?.phase == .busy,
                "success use 的 busy 必须在 send 返回前可见")
            expect(
                (try? Data(contentsOf: fixture.configFile)) == configBefore,
                "成功 use 也必须先给 SwiftUI 一次绘制 busy 的 yield")
            expect(
                owner.send(.invoke(useC)) == .rejected(.staleAction),
                "success use capability 必须在调度窗口内 single-use")

            await waitForSoundEditorOperation(owner, operationID: completedID)
            let object = soundEditorJSONObject(at: fixture.configFile)
            expect(
                owner.presentation.activities.first(where: {
                    $0.operationID == completedID
                })?.phase == .succeeded,
                "use completion 必须 settle 原 operation ID")
            expect(object?["selected_pack"] as? String == "pack-c", "use 必须写入目标 pack-c")
            expect((object?["future"] as? [String: Bool])?["keep"] == true, "use 必须保留未知 config 字段")
            if case .sounds(let settled) = owner.presentation.mode {
                expect(
                    settled.selectedPack?.id == "pack-c"
                        && settled.selectedPack?.isSelected == true,
                    "use typed success 后 presentation 必须选择 pack-c")
            } else {
                expect(false, "use settle 后必须保留 Sounds presentation")
            }
            expect(
                fixture.recorder.requests.count == scansBefore,
                "成功 use 是 config-only mutation，不得触发 SoundPackLibrary scan")
            expect(
                fixture.refreshCoordinator.panelReloadRevision == panelRevisionBefore + 1,
                "成功 use 必须发布一次 panel projection refresh")
        }
    }

    await suite("Sound editor actions：Surface use 只稀疏改目标 override 并保留 Global/unknown") {
        await withTempDirectory { root in
            let fixture = makeSoundEditorFixture(
                root: root,
                packIDs: ["pack-a", "pack-b", "pack-c"],
                configJSON:
                    #"{"selected_pack":"pack-a","master_volume":0.37,"events":{"stop":true,"notification":false},"starred_packs":["pack-a"],"future":{"keep":true},"surface_overrides":{"workbuddy":{"selected_pack":"pack-a","events":{"stop":false},"future_surface":7},"future-surface":{"selected_pack":"pack-c","future_peer":"keep"}}}"#
            )
            let owner = fixture.owner
            _ = owner.send(
                .activate(
                    .sounds(
                        route: .overview(surface: .workBuddy),
                        requestRevision: 12)))
            await waitForSoundEditorReady(owner, library: fixture.library)
            guard case .sounds(let sounds) = owner.presentation.mode,
                let useB = sounds.packs.first(where: { $0.id == "pack-b" })?.useAction,
                case .accepted(let operationID) = owner.send(.invoke(useB))
            else {
                expect(false, "writable Surface 必须签发并接受 use pack-b")
                return
            }
            let scansBefore = fixture.recorder.requests.count
            let panelRevisionBefore = fixture.refreshCoordinator.panelReloadRevision

            await waitForSoundEditorOperation(owner, operationID: operationID)
            let object = soundEditorJSONObject(at: fixture.configFile)
            let overrides = object?["surface_overrides"] as? [String: Any]
            let workBuddy = overrides?[HostSurfaceID.workBuddy.rawValue] as? [String: Any]
            let futureSurface = overrides?["future-surface"] as? [String: Any]
            expect(
                owner.presentation.activities.first(where: { $0.operationID == operationID })?
                    .phase == .succeeded,
                "Surface use 必须以 typed success settle")
            expect(
                object?["selected_pack"] as? String == "pack-a"
                    && (object?["master_volume"] as? Double) == 0.37
                    && (object?["events"] as? [String: Bool])?[Event.stop.cliName] == true
                    && (object?["events"] as? [String: Bool])?[Event.notification.cliName] == false
                    && object?["starred_packs"] as? [String] == ["pack-a"],
                "Surface use 不得改 Global selected_pack/master_volume/events/stars")
            expect(
                workBuddy?["selected_pack"] as? String == "pack-b"
                    && (workBuddy?["events"] as? [String: Bool])?[Event.stop.cliName] == false
                    && workBuddy?["future_surface"] as? Int == 7,
                "Surface use 只能稀疏替换目标 selected_pack，保留 sibling 与 unknown")
            expect(
                (object?["future"] as? [String: Bool])?["keep"] == true
                    && futureSurface?["selected_pack"] as? String == "pack-c"
                    && futureSurface?["future_peer"] as? String == "keep",
                "Surface use 必须保留顶层与未知 Surface bytes")
            if case .sounds(let settled) = owner.presentation.mode {
                expect(
                    settled.scope == .available(.surface(.workBuddy))
                        && settled.selectedPack?.id == "pack-b",
                    "Surface use 后 presentation 必须投影目标 scope 与 selection")
            } else {
                expect(false, "Surface use settle 后必须留在 Sounds mode")
            }
            expect(
                fixture.recorder.requests.count == scansBefore,
                "Surface use 是 config-only，不得请求 shared scan")
            expect(
                fixture.refreshCoordinator.panelReloadRevision == panelRevisionBefore + 1,
                "Surface use 必须恰好发布一次 panel refresh")
        }
    }

    await suite("Sound editor actions：assign 同栈 accepted/busy，落盘后 exact one refresh") {
        await withTempDirectory { root in
            let fixture = makeSoundEditorFixture(root: root, packIDs: ["pack-a"])
            let owner = fixture.owner
            _ = owner.send(.activate(.sounds(route: .overview, requestRevision: 11)))
            await waitForSoundEditorReady(owner, library: fixture.library)
            await waitForSoundEditorInventory(owner)
            guard case .sounds(let sounds) = owner.presentation.mode,
                case .ready(let audioRows) = sounds.inventory,
                let assignNotification = audioRows.first(where: { $0.fileName == "stop.mp3" })?
                    .assignments.first(where: { $0.event == .notification })?.action
            else {
                expect(false, "inventory-backed stop.mp3 必须签发 notification assign capability")
                return
            }
            let manifest = root.appendingPathComponent("packs/pack-a/manifest.json")
            let manifestBefore = try? Data(contentsOf: manifest)
            let scansBefore = fixture.recorder.requests.count
            let panelRevisionBefore = fixture.refreshCoordinator.panelReloadRevision

            guard case .accepted(let operationID) = owner.send(.invoke(assignNotification)) else {
                expect(false, "assign 必须由 owner 同栈接受为 scheduled operation")
                return
            }
            expect(
                owner.presentation.activities.contains {
                    $0.operationID == operationID && $0.kind == .assign && $0.phase == .busy
                        && $0.packID == "pack-a" && $0.event == .notification
                },
                "assign send 返回前必须发布 stable-ID busy activity")
            expect(
                (try? Data(contentsOf: manifest)) == manifestBefore,
                "assign 的同步 send 返回前必须尚未写 manifest")
            expect(
                owner.send(.invoke(assignNotification)) == .rejected(.staleAction),
                "assign capability 必须在 accepted 的同一 stack 内 single-use")

            await waitForSoundEditorOperation(owner, operationID: operationID)
            await waitForSoundEditorScanCount(fixture.recorder, atLeast: scansBefore + 1)
            await fixture.library.waitUntilIdleForTesting()
            let object = soundEditorJSONObject(at: manifest)
            let events = object?["events"] as? [String: String]
            expect(
                owner.presentation.activities.first(where: {
                    $0.operationID == operationID
                })?.phase == .succeeded,
                "assign completion 必须 settle 原 operation ID")
            expect(
                events?[Event.stop.cliName] == "stop.mp3"
                    && events?[Event.notification.cliName] == "stop.mp3",
                "assign 只新增目标 Event，必须保留 sibling binding")
            expect(
                (object?["future"] as? [String: Bool])?["keep"] == true, "assign 必须保留未知 manifest 字段"
            )
            expect(
                fixture.recorder.requests.count == scansBefore + 1
                    && fixture.recorder.requests.last?.invalidatedPackIDs == ["pack-a"]
                    && fixture.recorder.requests.last?.invalidatesAll == false,
                "assign 必须只触发一次 exact pack-a shared refresh")
            if case .sounds(let settled) = owner.presentation.mode,
                let row = settled.eventRows.first(where: { $0.event == .notification })
            {
                expect(
                    row.audioDisplayName == "stop.mp3",
                    "assign shared settle 后 presentation 必须投影 notification binding")
            } else {
                expect(false, "assign settle 后必须保留 notification presentation row")
            }
            expect(
                fixture.refreshCoordinator.panelReloadRevision == panelRevisionBefore + 1,
                "assign changed 必须恰好发布一次 panel refresh")
        }
    }

    await suite("Sound editor actions：clear noChange 零 refresh，重试成功仍保持同栈 busy") {
        await withTempDirectory { root in
            let fixture = makeSoundEditorFixture(
                root: root,
                packIDs: ["pack-a"],
                manifestJSONByPackID: [
                    "pack-a":
                        #"{"id":"pack-a","name":"Pack A","events":{"stop":"stop.mp3","notification":"stop.mp3"},"future":{"keep":true}}"#
                ])
            let owner = fixture.owner
            _ = owner.send(.activate(.sounds(route: .overview, requestRevision: 12)))
            await waitForSoundEditorReady(owner, library: fixture.library)
            guard case .sounds(let initial) = owner.presentation.mode,
                let clearStop = initial.eventRows.first(where: { $0.event == .stop })?.clearAction
            else {
                expect(false, "present stop mapping 必须签发 clear capability")
                return
            }
            let manifest = root.appendingPathComponent("packs/pack-a/manifest.json")
            let manifestBefore = try? Data(contentsOf: manifest)
            let scansBefore = fixture.recorder.requests.count
            let panelRevisionBefore = fixture.refreshCoordinator.panelReloadRevision
            let holder = FileLock(path: fixture.packsLockFile.path)
            var lockHeld = holder.tryLock()
            expect(lockHeld, "测试前提：必须真实占住注入的 packs.lock")
            defer { if lockHeld { holder.unlock() } }

            guard case .accepted(let failedID) = owner.send(.invoke(clearStop)) else {
                expect(false, "clear 必须先 accepted，writer failure 在 yield 后 settle")
                return
            }
            expect(
                owner.presentation.activities.contains {
                    $0.operationID == failedID && $0.kind == .clear && $0.phase == .busy
                        && $0.packID == "pack-a" && $0.event == .stop
                },
                "clear send 返回前必须发布 stable-ID busy activity")
            expect(
                (try? Data(contentsOf: manifest)) == manifestBefore,
                "clear 首次 yield 前不得改 manifest")
            expect(
                owner.send(.invoke(clearStop)) == .rejected(.staleAction),
                "clear capability 必须在 accepted 的同一 stack 内 single-use")

            await waitForSoundEditorOperation(owner, operationID: failedID)
            await fixture.library.waitUntilIdleForTesting()
            expect(
                owner.presentation.activities.first(where: {
                    $0.operationID == failedID
                })?.phase == .failed(.mutationFailed),
                "真实 packs.lock writer failure 必须 settle 原 operation 为 failure")
            expect(
                (try? Data(contentsOf: manifest)) == manifestBefore
                    && fixture.recorder.requests.count == scansBefore,
                "writer noChange failure 必须零 bytes 变化、零 completion refresh")

            holder.unlock()
            lockHeld = false
            guard case .sounds(let afterFailure) = owner.presentation.mode,
                let retryClear = afterFailure.eventRows.first(where: { $0.event == .stop })?
                    .clearAction,
                case .accepted(let completedID) = owner.send(.invoke(retryClear))
            else {
                expect(false, "writer failure 后必须从新 presentation 重签 clear capability")
                return
            }
            expect(
                owner.presentation.activities.first(where: {
                    $0.operationID == completedID
                })?.phase == .busy,
                "重试 clear 仍必须在 send 返回前发布 busy")
            expect(
                (try? Data(contentsOf: manifest)) == manifestBefore,
                "重试 clear 首次 yield 前仍不得写 manifest")
            expect(
                owner.send(.invoke(retryClear)) == .rejected(.staleAction),
                "重试 capability 也必须 single-use")

            await waitForSoundEditorOperation(owner, operationID: completedID)
            await waitForSoundEditorScanCount(fixture.recorder, atLeast: scansBefore + 1)
            await fixture.library.waitUntilIdleForTesting()
            let object = soundEditorJSONObject(at: manifest)
            let events = object?["events"] as? [String: String]
            expect(
                owner.presentation.activities.first(where: {
                    $0.operationID == completedID
                })?.phase == .succeeded,
                "成功 clear 必须 settle 重试 operation ID")
            expect(events?[Event.stop.cliName] == nil, "clear 只移除 stop binding")
            expect(
                events?[Event.notification.cliName] == "stop.mp3",
                "clear 必须保留 notification sibling binding")
            expect(
                (object?["future"] as? [String: Bool])?["keep"] == true, "clear 必须保留未知 manifest 字段")
            expect(
                fixture.recorder.requests.count == scansBefore + 1
                    && fixture.recorder.requests.last?.invalidatedPackIDs == ["pack-a"]
                    && fixture.recorder.requests.last?.invalidatesAll == false,
                "noChange 失败后成功 clear 仍只能产生一次 exact refresh")
            if case .sounds(let settled) = owner.presentation.mode {
                let stop = settled.eventRows.first(where: { $0.event == .stop })
                let notification = settled.eventRows.first(where: { $0.event == .notification })
                expect(
                    stop?.audioDisplayName == nil && notification?.audioDisplayName == "stop.mp3",
                    "clear settle 后 presentation 只清 stop 并保留 sibling")
            } else {
                expect(false, "clear settle 后必须保留 Sounds presentation")
            }
            expect(
                fixture.refreshCoordinator.panelReloadRevision == panelRevisionBefore + 1,
                "noChange failure + changed retry 必须只发布一次 panel refresh")
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
            let panelRevisionBefore = fixture.refreshCoordinator.panelReloadRevision
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
            if case .sounds(let settled) = owner.presentation.mode {
                expect(
                    settled.packs.first(where: { $0.id == "pack-c" })?.isStarred == true,
                    "star typed success 后 presentation 必须立即投影 pack-c")
            } else {
                expect(false, "star 后必须留在 Sounds presentation")
            }
            expect(
                fixture.refreshCoordinator.panelReloadRevision == panelRevisionBefore + 1,
                "star changed 必须恰好发布一次 panel refresh")
        }
    }

    await suite("Sound editor actions：star cap/default/fifth/broken eligibility 只签真实能力") {
        await withTempDirectory { root in
            let fixture = makeSoundEditorFixture(
                root: root,
                packIDs: ["factory-a"],
                config: ClaudioConfig(selectedPack: "factory-a"),
                builtinPackIDs: ["factory-a"])
            let owner = fixture.owner
            _ = owner.send(.activate(.sounds(route: .overview, requestRevision: 20)))
            await waitForSoundEditorReady(owner, library: fixture.library)
            guard case .sounds(let sounds) = owner.presentation.mode,
                let defaultStar = sounds.packs.first(where: { $0.id == "factory-a" }),
                let removeDefault = defaultStar.toggleStarAction
            else {
                expect(false, "缺 starred_packs 时默认内置星必须可见且可取消")
                return
            }
            expect(defaultStar.isStarred, "默认内置星身份必须来自当前 presentation")
            let scansBefore = fixture.recorder.requests.count
            expect(owner.send(.invoke(removeDefault)) == .applied, "取消默认内置星必须可执行")
            expect(
                soundEditorJSONObject(at: fixture.configFile)?["starred_packs"] as? [String] == [],
                "取消默认星必须物化 starred_packs: []，不能让默认值复活")
            expect(
                fixture.recorder.requests.count == scansBefore,
                "默认星 config-only CAS 不得扫描 sound-pack library")
        }

        await withTempDirectory { root in
            let ids = ["a", "b", "c", "d", "e"]
            let fixture = makeSoundEditorFixture(
                root: root,
                packIDs: ids,
                starred: Array(ids.prefix(4)))
            let owner = fixture.owner
            _ = owner.send(.activate(.sounds(route: .overview, requestRevision: 21)))
            await waitForSoundEditorReady(owner, library: fixture.library)
            guard case .sounds(let sounds) = owner.presentation.mode else {
                expect(false, "四星上限 fixture 必须进入 Sounds")
                return
            }
            expect(
                sounds.packs.first(where: { $0.id == "e" })?.toggleStarAction == nil,
                "已满四星时只能禁用新星 e")
            expect(
                sounds.packs.filter(\.isStarred).allSatisfy { $0.toggleStarAction != nil },
                "已存在的四颗星必须仍可取消")
        }

        await withTempDirectory { root in
            let ids = ["a", "b", "c", "d", "e"]
            let fixture = makeSoundEditorFixture(root: root, packIDs: ids, starred: ids)
            let owner = fixture.owner
            _ = owner.send(.activate(.sounds(route: .overview, requestRevision: 22)))
            await waitForSoundEditorReady(owner, library: fixture.library)
            guard case .sounds(let sounds) = owner.presentation.mode,
                let fifth = sounds.packs.first(where: { $0.id == "e" }),
                let removeFifth = fifth.toggleStarAction
            else {
                expect(false, "历史第五颗星必须保留可取消 capability")
                return
            }
            expect(fifth.isStarred, "第五颗历史星不得从 presentation 消失")
            expect(owner.send(.invoke(removeFifth)) == .applied, "第五颗历史星必须可取消")
            expect(
                soundEditorJSONObject(at: fixture.configFile)?["starred_packs"] as? [String]
                    == Array(ids.prefix(4)),
                "取消第五颗后必须保留其余四颗")
        }

        await withTempDirectory { root in
            let fixture = makeSoundEditorFixture(
                root: root,
                packIDs: ["healthy", "broken"],
                starred: [])
            writeFixture(
                "not-json",
                to: root.appendingPathComponent("packs/broken/manifest.json"))
            let owner = fixture.owner
            _ = owner.send(.activate(.sounds(route: .overview, requestRevision: 23)))
            await waitForSoundEditorReady(owner, library: fixture.library)
            guard case .sounds(let sounds) = owner.presentation.mode,
                let broken = sounds.packs.first(where: { $0.id == "broken" })
            else {
                expect(false, "损坏包必须作为 installed broken card 可见")
                return
            }
            if case .broken = broken.state {
                expect(true, "损坏 fixture 必须由 package presentation 识别")
            } else {
                expect(false, "损坏 fixture 不得伪装为完整/残缺包")
            }
            expect(
                broken.toggleStarAction == nil,
                "未星标 broken pack 不得签新增星 capability")
        }

        await withTempDirectory { root in
            let fixture = makeSoundEditorFixture(
                root: root,
                packIDs: ["healthy", "broken"],
                starred: ["broken"])
            writeFixture(
                "not-json",
                to: root.appendingPathComponent("packs/broken/manifest.json"))
            let owner = fixture.owner
            _ = owner.send(.activate(.sounds(route: .overview, requestRevision: 24)))
            await waitForSoundEditorReady(owner, library: fixture.library)
            guard case .sounds(let sounds) = owner.presentation.mode,
                let broken = sounds.packs.first(where: { $0.id == "broken" }),
                let removeBroken = broken.toggleStarAction
            else {
                expect(false, "已星标 broken pack 必须保留解除 capability")
                return
            }
            expect(broken.isStarred, "broken 不得抹掉既有星身份")
            expect(owner.send(.invoke(removeBroken)) == .applied, "broken 既有星必须可取消")
            expect(
                soundEditorJSONObject(at: fixture.configFile)?["starred_packs"] as? [String] == [],
                "取消 broken 星必须保留正常 CAS 写语义")
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
            let panelRevisionBefore = fixture.refreshCoordinator.panelReloadRevision

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
            await waitForSoundEditorScanCount(fixture.recorder, atLeast: scansBefore + 1)
            await fixture.library.waitUntilIdleForTesting()
            await waitForSoundEditorInventory(owner)
            expect(!regularFileExists(at: orphan), "唯一 accepted operation 必须删除孤儿文件")
            expect(
                owner.presentation.activities.contains {
                    $0.operationID == operationID && $0.phase == .succeeded
                },
                "operation 必须以同一 identity settle")
            expect(
                fixture.recorder.requests.count == scansBefore + 1
                    && fixture.recorder.requests.last?.invalidatedPackIDs == ["pack-a"]
                    && fixture.recorder.requests.last?.invalidatesAll == false,
                "pack mutation 必须只触发一次 exact shared refresh")
            if case .sounds(let settled) = owner.presentation.mode,
                case .ready(let inventory) = settled.inventory
            {
                expect(
                    !inventory.contains(where: { $0.fileName == "orphan.mp3" }),
                    "orphan delete settle 后 presentation inventory 必须移除文件")
            } else {
                expect(false, "orphan delete 后必须发布 settled inventory")
            }
            expect(
                fixture.refreshCoordinator.panelReloadRevision == panelRevisionBefore + 1,
                "orphan changed 必须恰好发布一次 panel refresh")

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

    await suite("Sound editor delete orphan：锁内 stale fact 是 noChange 且只观察 refresh 一次") {
        await withTempDirectory { root in
            let fixture = makeSoundEditorFixture(root: root, packIDs: ["pack-a"])
            let orphan = root.appendingPathComponent("packs/pack-a/orphan.mp3")
            writeFixture("orphan", to: orphan)
            let manifest = root.appendingPathComponent("packs/pack-a/manifest.json")
            let owner = fixture.owner
            _ = owner.send(.activate(.sounds(route: .overview, requestRevision: 32)))
            await waitForSoundEditorReady(owner, library: fixture.library)
            await waitForSoundEditorInventory(owner)
            guard case .sounds(let sounds) = owner.presentation.mode,
                case .ready(let audio) = sounds.inventory,
                let requestDelete = audio.first(where: { $0.fileName == "orphan.mp3" })?
                    .deleteAction,
                case .confirmation(let confirmation) = owner.send(.invoke(requestDelete))
            else {
                expect(false, "stale orphan fixture 必须先签发 confirmation")
                return
            }
            let manifestBefore = try? Data(contentsOf: manifest)
            try? FileManager.default.removeItem(at: orphan)
            let scansBefore = fixture.recorder.requests.count
            let panelRevisionBefore = fixture.refreshCoordinator.panelReloadRevision

            guard case .accepted(let operationID) = owner.send(.invoke(confirmation.confirmAction))
            else {
                expect(false, "stale orphan confirm 必须先接受 operation 再报告 lock-time failure")
                return
            }
            await waitForSoundEditorOperation(owner, operationID: operationID)
            await waitForSoundEditorScanCount(fixture.recorder, atLeast: scansBefore + 1)
            await fixture.library.waitUntilIdleForTesting()
            await waitForSoundEditorInventory(owner)

            expect(
                owner.presentation.activities.first(where: { $0.operationID == operationID })?
                    .phase == .failed(.mutationFailed),
                "stale orphan 必须保留 typed failure，不能伪装删除成功")
            expect(
                (try? Data(contentsOf: manifest)) == manifestBefore
                    && !FileManager.default.fileExists(atPath: orphan.path),
                "writer noChange 不得改 manifest；外部已移除事实必须保持")
            if case .sounds(let settled) = owner.presentation.mode,
                case .ready(let inventory) = settled.inventory
            {
                expect(
                    !inventory.contains(where: { $0.fileName == "orphan.mp3" }),
                    "一次 observation refresh 后 presentation 必须收敛到缺失 orphan")
            } else {
                expect(false, "stale orphan observation 后必须发布 settled inventory")
            }
            expect(
                fixture.recorder.requests.count == scansBefore + 1
                    && fixture.recorder.requests.last?.invalidatedPackIDs == ["pack-a"]
                    && fixture.recorder.requests.last?.invalidatesAll == false,
                "stale orphan noChange 只能请求一次 exact observation refresh")
            expect(
                fixture.refreshCoordinator.panelReloadRevision == panelRevisionBefore,
                "stale orphan noChange 不得发布 mutation completion 到 panel")
            expect(
                owner.presentation.pendingAnnouncement?.kind
                    != .operationSucceeded(.deleteOrphan),
                "stale orphan failure 不得伪造 success announcement")
        }
    }

    await suite("Sound editor confirmation：scope failure 优先返回但仍单次消费") {
        await withTempDirectory { root in
            let fixture = makeSoundEditorFixture(
                root: root,
                packIDs: ["pack-a"],
                config: ClaudioConfig(
                    selectedPack: "pack-a",
                    surfaceOverrides: [
                        HostSurfaceID.workBuddy.rawValue: SurfaceSoundOverride(
                            selectedPack: "pack-a")
                    ]))
            let orphan = root.appendingPathComponent("packs/pack-a/orphan.mp3")
            writeFixture("orphan", to: orphan)
            let owner = fixture.owner
            _ = owner.send(
                .activate(
                    .sounds(
                        route: .overview(surface: .workBuddy),
                        requestRevision: 4)))
            await waitForSoundEditorReady(owner, library: fixture.library)
            await waitForSoundEditorInventory(owner)
            guard case .sounds(let sounds) = owner.presentation.mode,
                case .ready(let audio) = sounds.inventory,
                let requestDelete = audio.first(where: { $0.fileName == "orphan.mp3" })?
                    .deleteAction,
                case .confirmation(let confirmation) = owner.send(.invoke(requestDelete))
            else {
                expect(false, "orphan 必须签发可确认的删除 capability")
                return
            }
            expect(
                owner.send(
                    .activate(
                        .sounds(
                            route: .overview(surface: .workBuddy),
                            requestRevision: 5))) == .applied,
                "相同语义 route 的新 request revision 必须使旧 confirmation capability stale")
            let validConfig = try? Data(contentsOf: fixture.configFile)
            writeFixture(
                #"{"selected_pack":"pack-a","surface_overrides":{"workbuddy":"broken"}}"#,
                to: fixture.configFile)
            let invalidConfig = try? Data(contentsOf: fixture.configFile)
            let scansBefore = fixture.recorder.requests.count
            let panelRevisionBefore = fixture.refreshCoordinator.panelReloadRevision

            expect(
                owner.send(.invoke(confirmation.confirmAction))
                    == .rejected(.scopeUnavailable),
                "同时 stale capability + invalid Surface 时必须先返回 latest scope failure")
            expect(
                owner.presentation.pendingConfirmation == nil,
                "scope failure 的第一次 confirm 尝试仍必须同栈消费并清 UI")
            if case .sounds(let failedScope) = owner.presentation.mode {
                expect(
                    failedScope.scope == .unavailable(.scopeUnavailable),
                    "malformed Surface config 必须显式投影 unavailable，不得借 Global 回落恢复写权")
            } else {
                expect(false, "scope failure 后必须保持 Sounds failure slice")
            }
            expect(
                regularFileExists(at: orphan)
                    && (try? Data(contentsOf: fixture.configFile)) == invalidConfig
                    && fixture.recorder.requests.count == scansBefore,
                "scope failure 只读 latest config，不得改 bytes 或请求 scan")

            if let validConfig { writeFixture(validConfig, to: fixture.configFile) }
            expect(
                owner.send(.invoke(confirmation.confirmAction))
                    == .rejected(.staleConfirmation),
                "scope 修复后同一 confirm token 仍必须 stale")
            await fixture.library.waitUntilIdleForTesting()
            expect(
                regularFileExists(at: orphan)
                    && fixture.recorder.requests.count == scansBefore,
                "scope 修复不得让旧 token 迟到写入或 refresh")
            expect(
                fixture.refreshCoordinator.panelReloadRevision == panelRevisionBefore,
                "scope-first rejection 与 stale replay 都不得发布 panel refresh")
        }
    }

    await suite("Sound editor confirmation：cancel 后 reissue 不复活旧 token") {
        await withTempDirectory { root in
            let fixture = makeSoundEditorFixture(root: root, packIDs: ["pack-a"])
            let orphan = root.appendingPathComponent("packs/pack-a/orphan.mp3")
            writeFixture("orphan", to: orphan)
            let owner = fixture.owner
            _ = owner.send(.activate(.sounds(route: .overview, requestRevision: 5)))
            await waitForSoundEditorReady(owner, library: fixture.library)
            await waitForSoundEditorInventory(owner)
            guard case .sounds(let initial) = owner.presentation.mode,
                case .ready(let initialAudio) = initial.inventory,
                let firstRequest = initialAudio.first(where: { $0.fileName == "orphan.mp3" })?
                    .deleteAction,
                case .confirmation(let first) = owner.send(.invoke(firstRequest))
            else {
                expect(false, "第一次删除请求必须产生 confirmation")
                return
            }
            let scansBefore = fixture.recorder.requests.count

            expect(owner.send(.invoke(first.cancelAction)) == .applied, "cancel 必须同栈消费")
            expect(owner.presentation.pendingConfirmation == nil, "cancel 后 UI 必须立即清除")
            await waitForSoundEditorInventory(owner)
            guard case .sounds(let afterCancel) = owner.presentation.mode else {
                expect(false, "cancel 后必须保持 Sounds mode")
                return
            }
            guard case .ready(let currentAudio) = afterCancel.inventory else {
                expect(false, "cancel 后必须保持 settled inventory")
                return
            }
            guard
                let secondRequest = currentAudio.first(where: { $0.fileName == "orphan.mp3" })?
                    .deleteAction
            else {
                expect(false, "cancel 后新 root 必须重签 delete capability")
                return
            }
            let secondResult = owner.send(.invoke(secondRequest))
            guard case .confirmation(let second) = secondResult else {
                expect(false, "cancel 后必须能显式 reissue，实得 \(secondResult)")
                return
            }

            expect(
                owner.send(.invoke(first.confirmAction)) == .rejected(.staleConfirmation),
                "reissue 后旧 confirm token 不得复活")
            expect(
                owner.send(.invoke(first.cancelAction)) == .rejected(.staleConfirmation),
                "reissue 后旧 cancel token 不得清除新 confirmation")
            expect(
                owner.presentation.pendingConfirmation?.id == second.id,
                "旧 token replay 后必须保留新 confirmation identity")
            expect(owner.send(.invoke(second.cancelAction)) == .applied, "新 cancel token 必须可用")
            expect(
                owner.presentation.pendingConfirmation == nil
                    && regularFileExists(at: orphan)
                    && fixture.recorder.requests.count == scansBefore,
                "cancel/reissue/replay 全程必须零 bytes 变化、零 scan")
        }
    }

    await suite("Sound editor ordering：invalidate-before-write 拒绝旧 terminal 并 exact follow-up") {
        await withTempDirectory { root in
            let gate = SoundEditorMutationPublicationGate()
            let fixture = makeSoundEditorFixture(
                root: root,
                packIDs: ["factory-a"],
                manifestJSONByPackID: [
                    "factory-a":
                        #"{"id":"factory-a","name":"user-initial","events":{"stop":"stop.mp3"}}"#
                ],
                builtinPackIDs: ["factory-a"],
                beforeFactoryPackRestorePublish: {
                    gate.releaseOldPublicationAndAwaitFollowUp()
                },
                beforeReadyPublication: { gate.pauseArmedOldPublication() },
                onScanRequestForTesting: { _ in gate.observeScanRequest() })
            let factoryPack = root.appendingPathComponent("factory-packs/factory-a")
            writeFixture(
                #"{"id":"factory-a","name":"factory-new","events":{"stop":"stop.mp3"}}"#,
                to: factoryPack.appendingPathComponent("manifest.json"))
            writeFixture("factory-new-audio", to: factoryPack.appendingPathComponent("stop.mp3"))
            let owner = fixture.owner
            _ = owner.send(.activate(.sounds(route: .overview, requestRevision: 28)))
            await waitForSoundEditorReady(owner, library: fixture.library)
            guard case .sounds(let sounds) = owner.presentation.mode,
                let restore = sounds.packs.first(where: { $0.id == "factory-a" })?.restoreAction,
                case .confirmation(let confirmation) = owner.send(.invoke(restore))
            else {
                expect(false, "built-in fixture 必须签发 restore confirmation")
                return
            }

            var observedSelectedNames: [String] = []
            let observation = owner.$presentation.sink { presentation in
                guard case .sounds(let slice) = presentation.mode,
                    let name = slice.selectedPack?.name
                else { return }
                observedSelectedNames.append(name)
            }
            defer { observation.cancel() }
            let installedManifest = root.appendingPathComponent("packs/factory-a/manifest.json")
            writeFixture(
                #"{"id":"factory-a","name":"old-in-flight","events":{"stop":"stop.mp3"}}"#,
                to: installedManifest)
            let scansBefore = fixture.recorder.requests.count
            let panelRevisionBefore = fixture.refreshCoordinator.panelReloadRevision
            gate.arm(afterRequestCount: scansBefore)

            await fixture.library.requestRefresh(trigger: .retry)
            guard gate.waitUntilOldPublicationIsPaused() else {
                expect(false, "旧 scan 必须确定性停在 terminal publication 前")
                gate.allowFollowUpScan()
                return
            }
            guard case .accepted(let operationID) = owner.send(.invoke(confirmation.confirmAction))
            else {
                expect(false, "restore confirmation 必须接受 scheduled operation")
                gate.allowFollowUpScan()
                return
            }
            await waitForSoundEditorOperation(owner, operationID: operationID)
            expect(
                gate.followUpArrivedBeforeWriterPublish,
                "writer publish 前必须先由 invalidation fence 拒绝旧 terminal 并排入 follow-up")
            gate.allowFollowUpScan()
            await waitForSoundEditorScanCount(fixture.recorder, atLeast: scansBefore + 2)
            await fixture.library.waitUntilIdleForTesting()
            await waitForSoundEditorSelectedPackName(owner, expected: "factory-new")

            let requests = fixture.recorder.requests
            expect(
                requests.count == scansBefore + 2,
                "一个旧 observation scan 后只能追加一个 coalesced completion scan")
            expect(
                requests.last?.invalidatedPackIDs == ["factory-a"]
                    && requests.last?.invalidatesAll == false,
                "follow-up 必须只携带 exact affected ID，不能退化为 full invalidation")
            expect(
                !observedSelectedNames.contains("old-in-flight"),
                "旧 scan 的 terminal bytes 不得进入 owner presentation")
            expect(
                (try? Data(contentsOf: installedManifest))
                    == (try? Data(contentsOf: factoryPack.appendingPathComponent("manifest.json"))),
                "restore writer 必须发布 factory tree bytes")
            expect(
                owner.presentation.activities.first(where: { $0.operationID == operationID })?
                    .phase == .succeeded,
                "restore ordering operation 必须以 typed success settle")
            expect(
                fixture.refreshCoordinator.panelReloadRevision == panelRevisionBefore + 1,
                "restore changed 必须只发布一次 panel refresh")
        }
    }

    await suite("Sound editor restore：publish 前 noChange failure 零 completion refresh") {
        await withTempDirectory { root in
            let publishFailure = SoundEditorFailSelectedRestorePublishCalls([1])
            let fixture = makeSoundEditorFixture(
                root: root,
                packIDs: ["factory-a"],
                builtinPackIDs: ["factory-a"],
                beforeFactoryPackRestorePublish: { try publishFailure.run() })
            let factoryPack = root.appendingPathComponent("factory-packs/factory-a")
            writeFixture(
                #"{"id":"factory-a","events":{"stop":"stop.mp3"}}"#,
                to: factoryPack.appendingPathComponent("manifest.json"))
            writeFixture("factory-audio", to: factoryPack.appendingPathComponent("stop.mp3"))
            let owner = fixture.owner
            _ = owner.send(.activate(.sounds(route: .overview, requestRevision: 29)))
            await waitForSoundEditorReady(owner, library: fixture.library)
            guard case .sounds(let sounds) = owner.presentation.mode,
                let requestRestore = sounds.packs.first(where: { $0.id == "factory-a" })?
                    .restoreAction
            else {
                expect(false, "selected built-in pack 必须签发 restore capability")
                return
            }
            let userPack = root.appendingPathComponent("packs/factory-a", isDirectory: true)
            try? FileManager.default.removeItem(at: userPack)
            expect(
                !FileManager.default.fileExists(atPath: userPack.path),
                "测试前提：publish failure 前没有可 salvage 的旧 tree")
            let scansBefore = fixture.recorder.requests.count
            let panelRevisionBefore = fixture.refreshCoordinator.panelReloadRevision
            guard case .confirmation(let confirmation) = owner.send(.invoke(requestRestore)),
                case .accepted(let operationID) = owner.send(.invoke(confirmation.confirmAction))
            else {
                expect(false, "restore confirmation 必须接受 scheduled operation")
                return
            }

            await waitForSoundEditorOperation(owner, operationID: operationID)
            await fixture.library.waitUntilIdleForTesting()
            expect(
                owner.presentation.activities.first(where: {
                    $0.operationID == operationID
                })?.phase == .failed(.mutationFailed),
                "publish-before-write failure 必须保留 typed failure")
            expect(
                !FileManager.default.fileExists(atPath: userPack.path),
                "noChange failure 不得发布 staging 或伪造 restored tree")
            expect(
                fixture.recorder.requests.count == scansBefore,
                "writer noChange failure 只能保留 invalidation fence，不得请求 completion refresh")
            expect(
                fixture.refreshCoordinator.panelReloadRevision == panelRevisionBefore,
                "restore noChange failure 不得发布 panel refresh")
        }
    }

    await suite("Sound editor restore：salvage changedDespiteFailure 后 recovery retry 成功") {
        await withTempDirectory { root in
            let publishFailure = SoundEditorFailSelectedRestorePublishCalls([1])
            let fixture = makeSoundEditorFixture(
                root: root,
                packIDs: ["factory-a"],
                starred: ["factory-a"],
                manifestJSONByPackID: [
                    "factory-a":
                        #"{"id":"factory-a","name":"user-modified","events":{"stop":"stop.mp3"},"future":{"keep":true}}"#
                ],
                builtinPackIDs: ["factory-a"],
                beforeFactoryPackRestorePublish: { try publishFailure.run() })
            let userPacks = root.appendingPathComponent("packs", isDirectory: true)
            let installed = userPacks.appendingPathComponent("factory-a", isDirectory: true)
            writeFixture("user-original", to: installed.appendingPathComponent("personal.wav"))
            let factoryPack = root.appendingPathComponent("factory-packs/factory-a")
            writeFixture(
                #"{"id":"factory-a","name":"factory-pristine","events":{"stop":"stop.mp3"},"factory_future":"keep"}"#,
                to: factoryPack.appendingPathComponent("manifest.json"))
            writeFixture("factory-audio", to: factoryPack.appendingPathComponent("stop.mp3"))
            let owner = fixture.owner
            _ = owner.send(.activate(.sounds(route: .overview, requestRevision: 33)))
            await waitForSoundEditorReady(owner, library: fixture.library)
            guard case .sounds(let sounds) = owner.presentation.mode,
                let restore = sounds.packs.first(where: { $0.id == "factory-a" })?.restoreAction,
                case .confirmation(let confirmation) = owner.send(.invoke(restore))
            else {
                expect(false, "installed built-in 必须签发 restore confirmation")
                return
            }
            let configBefore = try? Data(contentsOf: fixture.configFile)
            let scansBeforeFailure = fixture.recorder.requests.count
            let panelBeforeFailure = fixture.refreshCoordinator.panelReloadRevision
            guard case .accepted(let failedID) = owner.send(.invoke(confirmation.confirmAction))
            else {
                expect(false, "restore confirm 必须接受 scheduled operation")
                return
            }

            await waitForSoundEditorOperation(owner, operationID: failedID)
            await waitForSoundEditorScanCount(
                fixture.recorder,
                atLeast: scansBeforeFailure + 1)
            await fixture.library.waitUntilIdleForTesting()
            await waitForSoundEditorRecovery(owner, packID: "factory-a")
            let entriesAfterFailure =
                (try? FileManager.default.contentsOfDirectory(atPath: userPacks.path)) ?? []
            let salvageNames = entriesAfterFailure.filter {
                $0.hasPrefix(".factory-a.pre-restore-")
            }
            let firstSalvage = salvageNames.first.map {
                userPacks.appendingPathComponent($0, isDirectory: true)
            }
            expect(
                owner.presentation.activities.first(where: { $0.operationID == failedID })?
                    .phase == .failed(.mutationFailed),
                "publish failure 必须保留 typed failure，即使旧 tree 已 salvage")
            expect(
                !FileManager.default.fileExists(atPath: installed.path)
                    && salvageNames.count == 1
                    && firstSalvage.map {
                        regularFileExists(at: $0.appendingPathComponent("personal.wav"))
                            && (try? Data(contentsOf: $0.appendingPathComponent("personal.wav")))
                                == Data("user-original".utf8)
                    } == true,
                "changedDespiteFailure 必须保留唯一完整 salvage 且 visible tree 缺失")
            if case .sounds(let failedSlice) = owner.presentation.mode {
                expect(
                    failedSlice.recoveryActions.map(\.packID) == ["factory-a"],
                    "changedDespiteFailure presentation 必须保留 absent-pack recovery")
            } else {
                expect(false, "restore failure 后必须保留 Sounds presentation")
            }
            expect(
                fixture.recorder.requests.count == scansBeforeFailure + 1
                    && fixture.recorder.requests.last?.invalidatedPackIDs == ["factory-a"]
                    && fixture.recorder.requests.last?.invalidatesAll == false,
                "restore changedDespiteFailure 必须一次 exact refresh")
            expect(
                fixture.refreshCoordinator.panelReloadRevision == panelBeforeFailure + 1,
                "restore changedDespiteFailure 必须发布一次 panel refresh")
            expect(
                (try? Data(contentsOf: fixture.configFile)) == configBefore
                    && owner.presentation.pendingAnnouncement?.kind
                        != .operationSucceeded(.restoreFactory),
                "restore failure 必须保留 config/stars 且不能伪造 operation success")

            guard case .sounds(let failedSlice) = owner.presentation.mode,
                let retry = failedSlice.recoveryActions.first(where: { $0.packID == "factory-a" })?
                    .retryAction,
                case .confirmation(let retryConfirmation) = owner.send(.invoke(retry)),
                case .accepted(let retryID) = owner.send(.invoke(retryConfirmation.confirmAction))
            else {
                expect(false, "absent card 的 recovery capability 必须能接受 retry")
                return
            }
            let scansBeforeRetry = fixture.recorder.requests.count
            let panelBeforeRetry = fixture.refreshCoordinator.panelReloadRevision
            await waitForSoundEditorOperation(owner, operationID: retryID)
            await waitForSoundEditorScanCount(fixture.recorder, atLeast: scansBeforeRetry + 1)
            await fixture.library.waitUntilIdleForTesting()
            await waitForSoundEditorSelectedPackName(owner, expected: "factory-pristine")

            expect(
                owner.presentation.activities.first(where: { $0.operationID == retryID })?
                    .phase == .succeeded,
                "retry restore 必须以同一 operation identity typed success settle")
            expect(
                (try? Data(contentsOf: installed.appendingPathComponent("manifest.json")))
                    == (try? Data(contentsOf: factoryPack.appendingPathComponent("manifest.json")))
                    && (try? Data(contentsOf: installed.appendingPathComponent("stop.mp3")))
                        == Data("factory-audio".utf8)
                    && firstSalvage.map {
                        (try? Data(contentsOf: $0.appendingPathComponent("personal.wav")))
                            == Data("user-original".utf8)
                    } == true,
                "retry success 必须发布 factory tree 且保留原 salvage bytes")
            if case .sounds(let settled) = owner.presentation.mode {
                expect(
                    settled.recoveryActions.isEmpty
                        && settled.selectedPack?.id == "factory-a"
                        && settled.selectedPack?.name == "factory-pristine",
                    "retry success presentation 必须清 recovery 并恢复 card")
            } else {
                expect(false, "retry success 后必须保留 Sounds presentation")
            }
            expect(
                fixture.recorder.requests.count == scansBeforeRetry + 1
                    && fixture.recorder.requests.last?.invalidatedPackIDs == ["factory-a"]
                    && fixture.recorder.requests.last?.invalidatesAll == false,
                "retry success 必须一次 exact refresh")
            expect(
                fixture.refreshCoordinator.panelReloadRevision == panelBeforeRetry + 1,
                "retry success 必须一次 panel refresh")
            expect(
                (try? Data(contentsOf: fixture.configFile)) == configBefore,
                "restore/retry 生命周期不得改 selected_pack、stars 或未知 config")
        }
    }

    await suite("Sound editor restore batch：partial/changedDespiteFailure 共存且 exact one refresh") {
        await withTempDirectory { root in
            let ids = ["a-failed", "b-good"]
            let publishFailure = SoundEditorFailSelectedRestorePublishCalls([1])
            let fixture = makeSoundEditorFixture(
                root: root,
                packIDs: ids,
                builtinPackIDs: Set(ids),
                beforeFactoryPackRestorePublish: { try publishFailure.run() })
            let userPacks = root.appendingPathComponent("packs", isDirectory: true)
            let factoryPacks = root.appendingPathComponent("factory-packs", isDirectory: true)
            for id in ids {
                writeFixture(
                    """
                    {"id":"\(id)","name":"factory \(id)","events":{"stop":"stop.mp3"}}
                    """,
                    to: factoryPacks.appendingPathComponent("\(id)/manifest.json"))
                writeFixture(
                    "factory-\(id)",
                    to: factoryPacks.appendingPathComponent("\(id)/stop.mp3"))
                writeFixture(
                    "user-modified-\(id)",
                    to: userPacks.appendingPathComponent("\(id)/stop.mp3"))
            }
            let owner = fixture.owner
            _ = owner.send(.activate(.sounds(route: .overview, requestRevision: 30)))
            await waitForSoundEditorReady(owner, library: fixture.library)
            guard case .sounds(let sounds) = owner.presentation.mode,
                let requestRestoreAll = sounds.restoreAllFactoryPacksAction,
                case .confirmation(let confirmation) = owner.send(.invoke(requestRestoreAll))
            else {
                expect(false, "真实 factory IDs 必须签发 restore-all confirmation")
                return
            }
            let firstUserAudio = userPacks.appendingPathComponent("a-failed/stop.mp3")
            let secondUserAudio = userPacks.appendingPathComponent("b-good/stop.mp3")
            let firstBefore = try? Data(contentsOf: firstUserAudio)
            let secondBefore = try? Data(contentsOf: secondUserAudio)
            let scansBefore = fixture.recorder.requests.count
            let panelRevisionBefore = fixture.refreshCoordinator.panelReloadRevision

            guard case .accepted(let operationID) = owner.send(.invoke(confirmation.confirmAction))
            else {
                expect(false, "restore-all confirm 必须同栈 accepted")
                return
            }
            expect(
                owner.presentation.activities.contains {
                    $0.operationID == operationID && $0.kind == .restoreAllFactory
                        && $0.phase == .busy
                },
                "restore-all send 返回前必须发布 stable-ID busy")
            expect(
                (try? Data(contentsOf: firstUserAudio)) == firstBefore
                    && (try? Data(contentsOf: secondUserAudio)) == secondBefore,
                "restore-all 首次 yield 前不得搬移或覆盖任何 pack")
            expect(
                owner.send(.invoke(confirmation.confirmAction)) == .rejected(.staleConfirmation),
                "restore-all confirmation 必须 single-use")

            await waitForSoundEditorOperation(owner, operationID: operationID)
            await waitForSoundEditorScanCount(fixture.recorder, atLeast: scansBefore + 1)
            await fixture.library.waitUntilIdleForTesting()
            expect(
                owner.presentation.activities.first(where: {
                    $0.operationID == operationID
                })?.phase == .partial(accepted: 1, rejected: 1),
                "一成功 + 一 publish-failed salvage 必须保留 typed partial，不能压成 Bool failure")
            guard case .sounds(let settled) = owner.presentation.mode else {
                expect(false, "restore batch settle 后必须留在 Sounds mode")
                return
            }
            expect(
                settled.recoveryActions.map(\.packID) == ["a-failed"],
                "changedDespiteFailure 必须保留失败 pack 的可执行 recovery identity")
            expect(
                !FileManager.default.fileExists(atPath: firstUserAudio.path)
                    && (try? Data(contentsOf: secondUserAudio)) == Data("factory-b-good".utf8),
                "publish failure 已 salvage A、成功 sibling 已替换 B，两种磁盘事实必须同时可观察")
            expect(
                fixture.recorder.requests.count == scansBefore + 1
                    && fixture.recorder.requests.last?.invalidatedPackIDs == Set(ids)
                    && fixture.recorder.requests.last?.invalidatesAll == false,
                "partial/changedDespiteFailure 整批只能请求一次 exact affected-set refresh")
            expect(
                fixture.refreshCoordinator.panelReloadRevision == panelRevisionBefore + 1,
                "partial/changedDespiteFailure 整批必须恰好发布一次 panel refresh")
            expect(
                owner.presentation.pendingAnnouncement?.kind
                    != .operation(kind: .restoreAllFactory, completion: .succeeded),
                "changedDespiteFailure 不得伪造 restore-all success announcement")
        }
    }

    await suite("Sound editor fork：成功发布隔离 user tree、exact refresh 与单一 compound announcement") {
        await withTempDirectory { root in
            let fixture = makeSoundEditorFixture(
                root: root,
                packIDs: ["factory-a"],
                starred: ["factory-a"],
                builtinPackIDs: ["factory-a"])
            let factoryPack = root.appendingPathComponent("factory-packs/factory-a")
            writeFixture(
                #"{"id":"factory-a","name":"Factory A","license":"CC0","author":"Claudio","events":{"stop":"stop.mp3"},"future":{"keep":true}}"#,
                to: factoryPack.appendingPathComponent("manifest.json"))
            writeFixture("factory-audio", to: factoryPack.appendingPathComponent("stop.mp3"))
            let owner = fixture.owner
            _ = owner.send(.activate(.sounds(route: .overview, requestRevision: 34)))
            await waitForSoundEditorReady(owner, library: fixture.library)
            guard case .sounds(let sounds) = owner.presentation.mode,
                let fork = sounds.packs.first(where: { $0.id == "factory-a" })?.forkAction
            else {
                expect(false, "selected built-in 必须签发 fork capability")
                return
            }
            let sourceBefore = try? Data(
                contentsOf: factoryPack.appendingPathComponent("manifest.json"))
            let configBefore = try? Data(contentsOf: fixture.configFile)
            let scansBefore = fixture.recorder.requests.count
            let panelRevisionBefore = fixture.refreshCoordinator.panelReloadRevision
            guard case .accepted(let operationID) = owner.send(.invoke(fork)) else {
                expect(false, "fork 必须接受 scheduled operation")
                return
            }

            await waitForSoundEditorOperation(owner, operationID: operationID)
            await waitForSoundEditorScanCount(fixture.recorder, atLeast: scansBefore + 1)
            await fixture.library.waitUntilIdleForTesting()
            await waitForSoundEditorSelectionChange(owner, awayFrom: "factory-a")
            guard case .sounds(let settled) = owner.presentation.mode,
                let forked = settled.selectedPack,
                forked.id != "factory-a"
            else {
                expect(false, "fork shared settle 后必须选中新 user card")
                return
            }
            let forkedDirectory = root.appendingPathComponent(
                "packs/\(forked.id)",
                isDirectory: true)
            let forkedManifest = soundEditorJSONObject(
                at: forkedDirectory.appendingPathComponent("manifest.json"))
            expect(
                owner.presentation.activities.first(where: { $0.operationID == operationID })?
                    .phase == .succeeded,
                "fork 必须以 typed success settle 原 operation")
            expect(
                forked.availability == .installed && !forked.isBuiltinReadOnly,
                "forked presentation 必须是 installed user-owned card")
            expect(
                forkedManifest?["id"] as? String == forked.id
                    && forkedManifest?["name"] as? String == "Factory A 的副本"
                    && (forkedManifest?["events"] as? [String: String])?[Event.stop.cliName]
                        == "stop.mp3"
                    && (forkedManifest?["future"] as? [String: Bool])?["keep"] == true
                    && forkedManifest?["license"] == nil
                    && forkedManifest?["author"] == nil
                    && (try? Data(contentsOf: forkedDirectory.appendingPathComponent("stop.mp3")))
                        == Data("factory-audio".utf8),
                "fork 必须先 rewrite manifest 再完整发布 factory bytes，保留 unknown/event")
            expect(
                (try? Data(contentsOf: factoryPack.appendingPathComponent("manifest.json")))
                    == sourceBefore
                    && (try? Data(contentsOf: fixture.configFile)) == configBefore,
                "fork 不得改 factory source、active config、stars 或 unknown config")
            expect(
                fixture.recorder.requests.count == scansBefore + 1
                    && fixture.recorder.requests.last?.invalidatedPackIDs == [forked.id]
                    && fixture.recorder.requests.last?.invalidatesAll == false,
                "fork success 必须只 refresh 新 pack ID 一次")
            expect(
                fixture.refreshCoordinator.panelReloadRevision == panelRevisionBefore + 1,
                "fork changed 必须发布一次 panel refresh")
            expect(
                owner.presentation.pendingAnnouncement?.kind == .operationSucceeded(.fork),
                "fork success 必须排入一个 compound semantic announcement")
        }
    }

    await suite("Sound editor fork：EEXIST exhaustion 不覆盖 occupier 且零 fake refresh") {
        await withTempDirectory { root in
            let occupier = SoundEditorForkCollisionOccupier()
            let fixture = makeSoundEditorFixture(
                root: root,
                packIDs: ["factory-a"],
                builtinPackIDs: ["factory-a"],
                beforeForkPackPublish: { try occupier.occupy($0) })
            let factoryPack = root.appendingPathComponent("factory-packs/factory-a")
            writeFixture(
                #"{"id":"factory-a","name":"Factory A","events":{"stop":"stop.mp3"}}"#,
                to: factoryPack.appendingPathComponent("manifest.json"))
            writeFixture("factory-audio", to: factoryPack.appendingPathComponent("stop.mp3"))
            let owner = fixture.owner
            _ = owner.send(.activate(.sounds(route: .overview, requestRevision: 31)))
            await waitForSoundEditorReady(owner, library: fixture.library)
            guard case .sounds(let sounds) = owner.presentation.mode,
                let fork = sounds.packs.first(where: { $0.id == "factory-a" })?.forkAction
            else {
                expect(false, "selected built-in pack 必须签发 fork capability")
                return
            }
            let sourceManifest = factoryPack.appendingPathComponent("manifest.json")
            let sourceBefore = try? Data(contentsOf: sourceManifest)
            let configBefore = try? Data(contentsOf: fixture.configFile)
            let scansBefore = fixture.recorder.requests.count

            guard case .accepted(let operationID) = owner.send(.invoke(fork)) else {
                expect(false, "fork 必须同栈 accepted")
                return
            }
            expect(
                owner.presentation.activities.contains {
                    $0.operationID == operationID && $0.kind == .fork && $0.phase == .busy
                        && $0.packID == "factory-a"
                },
                "fork send 返回前必须发布 stable-ID busy")
            expect(
                occupier.destinations.isEmpty,
                "fork 首次 yield 前不得创建 staging、candidate 或调用 publish hook")
            expect(
                owner.send(.invoke(fork)) == .rejected(.staleAction),
                "fork capability 必须同栈 single-use")

            await waitForSoundEditorOperation(owner, operationID: operationID)
            await fixture.library.waitUntilIdleForTesting()
            let destinations = occupier.destinations
            let userPacks = root.appendingPathComponent("packs", isDirectory: true)
            let entries = Set(
                (try? FileManager.default.contentsOfDirectory(atPath: userPacks.path)) ?? [])
            let expectedEntries = Set(["factory-a"] + destinations.map(\.lastPathComponent))
            expect(
                !destinations.isEmpty && destinations.count <= 32,
                "fork EEXIST 必须尝试非零次并在合理有限上界内停止")
            expect(
                Set(destinations.map(\.lastPathComponent)).count == destinations.count,
                "fork EEXIST 每次 candidate 必须唯一，不能原地覆盖同一路径")
            expect(
                entries == expectedEntries && entries.allSatisfy { !$0.hasPrefix(".") },
                "exhaustion 只能留下源包与有限外部 occupier，不得发布半包或 staging")
            expect(
                destinations.allSatisfy {
                    (try? Data(contentsOf: $0)) == Data("external-occupier".utf8)
                },
                "RENAME_EXCL 冲突不得覆盖任一外部 occupier bytes")
            expect(
                (try? Data(contentsOf: sourceManifest)) == sourceBefore
                    && (try? Data(contentsOf: fixture.configFile)) == configBefore,
                "fork exhaustion 不得修改 factory source、selection 或 stars")
            expect(
                owner.presentation.activities.first(where: {
                    $0.operationID == operationID
                })?.phase == .failed(.mutationFailed),
                "fork exhaustion 必须 settle 同一 operation 为 failure")
            expect(
                fixture.recorder.requests.count == scansBefore,
                "EEXIST 仅证明外部 occupancy，owner 不得为失败候选发布 fake refresh")
            expect(
                owner.presentation.pendingAnnouncement?.kind
                    != .operation(kind: .fork, completion: .succeeded),
                "fork exhaustion 不得进入 success announcement queue")
        }
    }
}

struct SoundEditorFixture {
    let owner: SoundPacksEditorOwner
    let library: SoundPackLibrary
    let recorder: SoundEditorScanRecorder
    let refreshCoordinator: SoundPacksRefreshCoordinator
    let configFile: URL
    let packsLockFile: URL
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
    starred: [String] = [],
    manifestJSONByPackID: [String: String] = [:],
    durationProbe: (any AudioDurationProbing)? = nil,
    config: ClaudioConfig? = nil,
    configJSON: String? = nil,
    builtinPackIDs: Set<String> = [],
    beforeForkPackPublish: (@Sendable (URL) throws -> Void)? = nil,
    beforeFactoryPackRestorePublish: (@Sendable () throws -> Void)? = nil,
    afterFinalImportCancellationSampleForTesting: (@Sendable () -> Void)? = nil,
    beforeReadyPublication: @escaping @Sendable () -> Void = {},
    onScanRequestForTesting: @escaping @Sendable (SoundPackLibraryScanRequest) -> Void = { _ in }
) -> SoundEditorFixture {
    let packs = root.appendingPathComponent("packs", isDirectory: true)
    let factoryPacks = root.appendingPathComponent("factory-packs", isDirectory: true)
    for packID in builtinPackIDs {
        try! FileManager.default.createDirectory(
            at: factoryPacks.appendingPathComponent(packID, isDirectory: true),
            withIntermediateDirectories: true)
    }
    for packID in packIDs {
        writeFixture(
            manifestJSONByPackID[packID]
                ?? """
                {"id":"\(packID)","name":"\(packID)","events":{"stop":"stop.mp3"},"future":{"keep":true}}
                """,
            to: packs.appendingPathComponent("\(packID)/manifest.json"))
        writeFixture("audio", to: packs.appendingPathComponent("\(packID)/stop.mp3"))
    }
    let configFile = root.appendingPathComponent("config.json")
    if let configJSON {
        writeFixture(configJSON, to: configFile)
    } else if let config {
        writeFixture(try! JSONEncoder().encode(config), to: configFile)
    } else {
        let starredJSON = starred.map { "\"\($0)\"" }.joined(separator: ",")
        writeFixture(
            """
            {"selected_pack":"\(packIDs.first ?? "")","master_volume":0.37,"events":{"stop":true},"starred_packs":[\(starredJSON)],"future":{"keep":true}}
            """,
            to: configFile)
    }
    var configuredEnvironment =
        durationProbe.map {
            AudioImportEnvironment(
                userPacksDirectory: packs,
                factoryPacksDirectory: builtinPackIDs.isEmpty ? nil : factoryPacks,
                durationProbe: $0,
                packsLockFile: injectedPacksLock(under: root))
        }
        ?? makeAudioImportEnvironment(
            userPacksDirectory: packs,
            factoryPacksDirectory: builtinPackIDs.isEmpty ? nil : factoryPacks)
    configuredEnvironment.beforeForkPackPublish = beforeForkPackPublish
    configuredEnvironment.beforeFactoryPackRestorePublish = beforeFactoryPackRestorePublish
    let environment = configuredEnvironment
    let recorder = SoundEditorScanRecorder()
    let scanner = SoundPackLibraryScanner.testingLive(
        environment: environment,
        onRequest: {
            recorder.append($0)
            onScanRequestForTesting($0)
        },
        afterManifestRead: { _ in })
    let library = SoundPackLibrary(
        scanner: scanner,
        inventoryOperation: { packID in
            switch packAudioFiles(packID: packID, environment: environment) {
            case .success(let files): return .available(files)
            case .failure(let error): return .unavailable(error)
            }
        },
        beforeReadyPublication: beforeReadyPublication)
    let refreshCoordinator = SoundPacksRefreshCoordinator()
    let owner: SoundPacksEditorOwner
    if let afterFinalImportCancellationSampleForTesting {
        owner = SoundPacksEditorOwner(
            configFile: configFile,
            lockFile: root.appendingPathComponent("config.lock"),
            environment: environment,
            soundPackLibrary: library,
            refreshCoordinator: refreshCoordinator,
            afterFinalImportCancellationSampleForTesting:
                afterFinalImportCancellationSampleForTesting)
    } else {
        owner = SoundPacksEditorOwner(
            configFile: configFile,
            lockFile: root.appendingPathComponent("config.lock"),
            environment: environment,
            soundPackLibrary: library,
            refreshCoordinator: refreshCoordinator)
    }
    return SoundEditorFixture(
        owner: owner,
        library: library,
        recorder: recorder,
        refreshCoordinator: refreshCoordinator,
        configFile: configFile,
        packsLockFile: environment.packsLockFile)
}

@MainActor
private func soundEditorJSONObject(at file: URL) -> [String: Any]? {
    guard let data = try? Data(contentsOf: file),
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
        return nil
    }
    return object
}

@MainActor
@discardableResult
func waitForSoundEditorReady(
    _ owner: SoundPacksEditorOwner,
    library: SoundPackLibrary
) async -> Bool {
    for _ in 0..<512 {
        if case .ready = owner.presentation.library { return true }
        await Task.yield()
    }
    await library.waitUntilIdleForTesting()
    for _ in 0..<512 {
        if case .ready = owner.presentation.library { return true }
        await Task.yield()
    }
    expect(false, "等待 SoundPackLibrary ready 超时")
    return false
}

@MainActor
@discardableResult
func waitForSoundEditorInventory(_ owner: SoundPacksEditorOwner) async -> Bool {
    for _ in 0..<512 {
        if case .sounds(let sounds) = owner.presentation.mode,
            case .ready = sounds.inventory
        {
            return true
        }
        await Task.yield()
    }
    expect(false, "等待 sound editor inventory ready 超时")
    return false
}

@MainActor
@discardableResult
func waitForSoundEditorOperation(
    _ owner: SoundPacksEditorOwner,
    operationID: SoundPackEditorOperationID
) async -> Bool {
    for _ in 0..<512 {
        if owner.presentation.activities.contains(where: {
            $0.operationID == operationID && $0.phase != .busy
        }) {
            return true
        }
        await Task.yield()
    }
    expect(false, "等待 sound editor operation settle 超时")
    return false
}

@MainActor
@discardableResult
func waitForSoundEditorSelectedPackName(
    _ owner: SoundPacksEditorOwner,
    expected name: String
) async -> Bool {
    for _ in 0..<512 {
        if case .sounds(let sounds) = owner.presentation.mode,
            sounds.selectedPack?.name == name
        {
            return true
        }
        await Task.yield()
    }
    expect(false, "等待 selected pack name \(name) 超时")
    return false
}

@MainActor
@discardableResult
func waitForSoundEditorSelectionChange(
    _ owner: SoundPacksEditorOwner,
    awayFrom packID: String
) async -> Bool {
    for _ in 0..<512 {
        if case .sounds(let sounds) = owner.presentation.mode,
            let selected = sounds.selectedPack,
            selected.id != packID
        {
            return true
        }
        await Task.yield()
    }
    expect(false, "等待 selection 离开 \(packID) 超时")
    return false
}

@MainActor
@discardableResult
func waitForSoundEditorRecovery(
    _ owner: SoundPacksEditorOwner,
    packID: String
) async -> Bool {
    for _ in 0..<512 {
        if case .sounds(let sounds) = owner.presentation.mode,
            sounds.recoveryActions.contains(where: { $0.packID == packID })
        {
            return true
        }
        await Task.yield()
    }
    expect(false, "等待 restore recovery \(packID) 超时")
    return false
}

@MainActor
@discardableResult
func waitForSoundEditorScanCount(
    _ recorder: SoundEditorScanRecorder,
    atLeast expectedCount: Int
) async -> Bool {
    for _ in 0..<512 {
        if recorder.requests.count >= expectedCount { return true }
        await Task.yield()
    }
    expect(
        false,
        "等待 shared scan request 超时：期待至少 \(expectedCount)，实际 \(recorder.requests.count)")
    return false
}
