import ClaudioCore
import ClaudioGUICore
import Foundation

@MainActor
func runSoundPacksEditorAsyncOperationSuites() async {
    await suite("Sound editor perform：import+bind 消费 permit 且只刷新目标包一次") {
        await withTempDirectory { root in
            let fixture = makeSoundEditorFixture(root: root, packIDs: ["pack-a"])
            let owner = fixture.owner
            _ = owner.send(.activate(.sounds(route: .overview, requestRevision: 10)))
            await waitForSoundEditorReady(owner, library: fixture.library)

            guard case .sounds(let sounds) = owner.presentation.mode,
                let requestImport = sounds.eventRows.first(where: { $0.event == .stop })?
                    .importAction,
                case .nativeEffect(.selectAudioFiles(let permit, _)) =
                    owner.send(.invoke(requestImport))
            else {
                expect(false, "fresh writable Sounds slice 必须签发 import permit")
                return
            }
            let source = root.appendingPathComponent("picked.mp3")
            writeFixture(validMP3ID3Data(), to: source)
            let scansBefore = fixture.recorder.requests.count

            let result = await owner.perform(
                .importAudio(permit: permit, sources: [source], bindTo: .stop))
            guard case .imported(let outcome) = result else {
                expect(false, "有效 permit 必须产生 typed imported outcome")
                return
            }
            expect(
                outcome.accepted.map(\.fileName) == ["picked.mp3"]
                    && outcome.rejected.isEmpty && outcome.boundEvent == .stop,
                "compound import 必须导入并只绑定请求 Event")
            expect(
                regularFileExists(at: root.appendingPathComponent("packs/pack-a/picked.mp3")),
                "accepted bytes 必须落入 permit 捕获的 pack")
            let manifest =
                try? JSONSerialization.jsonObject(
                    with: Data(
                        contentsOf: root.appendingPathComponent("packs/pack-a/manifest.json")))
                as? [String: Any]
            expect(
                (manifest?["events"] as? [String: String])?["stop"] == "picked.mp3",
                "optional bind 必须与 import 在同一 compound mutation 中完成")
            for _ in 0..<512 {
                if fixture.recorder.requests.count > scansBefore { break }
                await Task.yield()
            }
            await fixture.library.waitUntilIdleForTesting()
            expect(
                fixture.recorder.requests.count == scansBefore + 1
                    && fixture.recorder.requests.last?.invalidatedPackIDs == ["pack-a"],
                "compound import+bind 必须 exact invalidation 且只请求一次 shared refresh")

            expect(
                await owner.perform(
                    .importAudio(permit: permit, sources: [source], bindTo: .stop))
                    == .rejected(.stalePermit),
                "import permit 必须 single-use")
        }
    }

    await suite("Sound editor perform：stale permit 在 I/O 前拒绝，A→B→A 不能复活") {
        await withTempDirectory { root in
            let fixture = makeSoundEditorFixture(root: root, packIDs: ["pack-a", "pack-b"])
            let owner = fixture.owner
            _ = owner.send(.activate(.sounds(route: .overview, requestRevision: 11)))
            await waitForSoundEditorReady(owner, library: fixture.library)
            guard let permit = soundEditorImportPermit(owner: owner, bindTo: .stop),
                case .sounds(let atA) = owner.presentation.mode,
                let inspectB = atA.packs.first(where: { $0.id == "pack-b" })?.inspectAction
            else {
                expect(false, "A 必须能签发 import permit 与 inspect-B action")
                return
            }
            _ = owner.send(.invoke(inspectB))
            guard case .sounds(let atB) = owner.presentation.mode,
                let inspectA = atB.packs.first(where: { $0.id == "pack-a" })?.inspectAction
            else {
                expect(false, "B 必须能签发新的 inspect-A action")
                return
            }
            _ = owner.send(.invoke(inspectA))
            let source = root.appendingPathComponent("stale.mp3")
            writeFixture(validMP3ID3Data(), to: source)
            let scansBefore = fixture.recorder.requests.count

            expect(
                await owner.perform(
                    .importAudio(permit: permit, sources: [source], bindTo: .stop))
                    == .rejected(.stalePermit),
                "第一次 A 的 permit 在 A→B→A 后必须 fail closed")
            expect(
                !regularFileExists(at: root.appendingPathComponent("packs/pack-a/stale.mp3"))
                    && fixture.recorder.requests.count == scansBefore,
                "stale-before-start 必须零写入、零 invalidation refresh")
        }
    }

    await suite("Sound editor perform：partial 保留 accepted/rejected 并只刷新一次") {
        await withTempDirectory { root in
            let fixture = makeSoundEditorFixture(root: root, packIDs: ["pack-a"])
            let owner = fixture.owner
            _ = owner.send(.activate(.sounds(route: .overview, requestRevision: 12)))
            await waitForSoundEditorReady(owner, library: fixture.library)
            guard let permit = soundEditorImportPermit(owner: owner, bindTo: nil) else {
                expect(false, "writable Sounds slice 必须提供 generic import permit")
                return
            }
            let valid = root.appendingPathComponent("valid.mp3")
            let rejected = root.appendingPathComponent("rejected.mp3")
            writeFixture(validMP3ID3Data(), to: valid)
            writeFixture(evilShellScriptData(), to: rejected)
            let scansBefore = fixture.recorder.requests.count

            let result = await owner.perform(
                .importAudio(permit: permit, sources: [valid, rejected], bindTo: nil))
            guard case .imported(let outcome) = result else {
                expect(false, "partial batch 必须仍返回 imported outcome")
                return
            }
            expect(
                outcome.accepted.map(\.fileName) == ["valid.mp3"]
                    && outcome.rejected.map(\.sourceFileName) == ["rejected.mp3"],
                "partial outcome 必须同时保留 accepted 与逐项 rejected")
            expect(
                owner.presentation.activities.contains {
                    $0.kind == .importAudio
                        && $0.phase == .partial(accepted: 1, rejected: 1)
                },
                "partial mutation impact 必须进入 coherent activity")
            await waitForSoundEditorScan(fixture, after: scansBefore)
            expect(
                fixture.recorder.requests.count == scansBefore + 1
                    && fixture.recorder.requests.last?.invalidatedPackIDs == ["pack-a"],
                "partial accepted bytes 仍必须 exact refresh 一次")
        }
    }

    await suite("Sound editor perform：A→B→A 发生在 import 中途时保留 orphan 与旧 binding") {
        await withTempDirectory { root in
            let gate = GatedSoundEditorDurationProbe(duration: 1)
            let fixture = makeSoundEditorFixture(
                root: root,
                packIDs: ["pack-a", "pack-b"],
                durationProbe: gate)
            let owner = fixture.owner
            _ = owner.send(.activate(.sounds(route: .overview, requestRevision: 13)))
            await waitForSoundEditorReady(owner, library: fixture.library)
            guard let permit = soundEditorImportPermit(owner: owner, bindTo: .stop) else {
                expect(false, "A 必须提供 Event-bound import permit")
                return
            }
            let source = root.appendingPathComponent("drift.mp3")
            writeFixture(validMP3ID3Data(), to: source)
            let scansBefore = fixture.recorder.requests.count
            let task = Task { @MainActor in
                await owner.perform(
                    .importAudio(permit: permit, sources: [source], bindTo: .stop))
            }
            await gate.waitUntilEntered()
            guard case .sounds(let atA) = owner.presentation.mode,
                let inspectB = atA.packs.first(where: { $0.id == "pack-b" })?.inspectAction
            else {
                gate.release()
                expect(false, "busy root 必须仍带 B inspection capability")
                return
            }
            _ = owner.send(.invoke(inspectB))
            guard case .sounds(let atB) = owner.presentation.mode,
                let inspectA = atB.packs.first(where: { $0.id == "pack-a" })?.inspectAction
            else {
                gate.release()
                expect(false, "中途 B root 必须能返回 A")
                return
            }
            _ = owner.send(.invoke(inspectA))
            gate.release()

            guard case .imported(let outcome) = await task.value else {
                expect(false, "已经落盘的 background import 必须诚实返回 outcome")
                return
            }
            expect(
                outcome.completedInBackground && outcome.boundEvent == nil
                    && outcome.orphan?.fileName == "drift.mp3",
                "A→B→A 必须依 generation 判 background，并把未绑定文件报告为 orphan")
            let manifest = soundEditorManifest(
                root.appendingPathComponent("packs/pack-a/manifest.json"))
            expect(
                (manifest?["events"] as? [String: String])?["stop"] == "stop.mp3",
                "final bind 漂移不得覆盖旧 Event binding")
            expect(
                regularFileExists(at: root.appendingPathComponent("packs/pack-a/drift.mp3")),
                "已经落盘的 captured-target bytes 不得伪装 rollback")
            await waitForSoundEditorScan(fixture, after: scansBefore)
            expect(
                fixture.recorder.requests.count == scansBefore + 1,
                "imported orphan 是 changedDespiteFailure，必须只 refresh 一次")
        }
    }

    await suite("Sound editor perform：in-flight cancel 不伪造 rollback") {
        await withTempDirectory { root in
            let gate = GatedSoundEditorDurationProbe(duration: 1)
            let fixture = makeSoundEditorFixture(
                root: root,
                packIDs: ["pack-a"],
                durationProbe: gate)
            let owner = fixture.owner
            _ = owner.send(.activate(.sounds(route: .overview, requestRevision: 14)))
            await waitForSoundEditorReady(owner, library: fixture.library)
            guard let permit = soundEditorImportPermit(owner: owner, bindTo: .stop) else {
                expect(false, "cancel fixture 必须取得 Event-bound permit")
                return
            }
            let source = root.appendingPathComponent("cancelled.mp3")
            writeFixture(validMP3ID3Data(), to: source)
            let scansBefore = fixture.recorder.requests.count
            let task = Task { @MainActor in
                await owner.perform(
                    .importAudio(permit: permit, sources: [source], bindTo: .stop))
            }
            await gate.waitUntilEntered()
            task.cancel()
            gate.release()

            guard case .imported(let outcome) = await task.value else {
                expect(false, "post-write cancellation 必须返回真实 imported facts")
                return
            }
            expect(
                outcome.accepted.map(\.fileName) == ["cancelled.mp3"]
                    && outcome.boundEvent == nil && outcome.orphan?.fileName == "cancelled.mp3",
                "取消不能 rollback accepted bytes，也不能继续 final bind")
            expect(
                regularFileExists(at: root.appendingPathComponent("packs/pack-a/cancelled.mp3")),
                "post-write cancel 的 imported file 必须保留为 recoverable orphan")
            await waitForSoundEditorScan(fixture, after: scansBefore)
            expect(
                fixture.recorder.requests.count == scansBefore + 1,
                "post-write cancel 是 changed truth，必须 exact refresh 一次")
        }
    }

    await suite("Sound editor perform：serial queue 中尚未执行的 cancel 零写入零假刷新") {
        await withTempDirectory { root in
            let gate = GatedSoundEditorDurationProbe(duration: 1)
            let fixture = makeSoundEditorFixture(
                root: root,
                packIDs: ["pack-a"],
                durationProbe: gate)
            let owner = fixture.owner
            _ = owner.send(.activate(.sounds(route: .overview, requestRevision: 15)))
            await waitForSoundEditorReady(owner, library: fixture.library)
            guard let firstPermit = soundEditorImportPermit(owner: owner, bindTo: nil),
                let queuedPermit = soundEditorImportPermit(owner: owner, bindTo: nil)
            else {
                expect(false, "queue cancellation fixture 必须取得两个独立 permit")
                return
            }
            let firstSource = root.appendingPathComponent("first.mp3")
            let queuedSource = root.appendingPathComponent("queued.mp3")
            writeFixture(validMP3ID3Data(), to: firstSource)
            writeFixture(validMP3ID3Data(), to: queuedSource)
            let scansBefore = fixture.recorder.requests.count
            let firstTask = Task { @MainActor in
                await owner.perform(
                    .importAudio(permit: firstPermit, sources: [firstSource], bindTo: nil))
            }
            await gate.waitUntilEntered()
            let queuedTask = Task { @MainActor in
                await owner.perform(
                    .importAudio(permit: queuedPermit, sources: [queuedSource], bindTo: nil))
            }
            for _ in 0..<512 {
                if owner.presentation.activities.filter({ $0.phase == .busy }).count == 2 { break }
                await Task.yield()
            }
            let queuedOperationID = owner.presentation.activities.last?.operationID
            queuedTask.cancel()
            gate.release()

            _ = await firstTask.value
            expect(
                await queuedTask.value == .rejected(.cancelled),
                "queue 尚未开始 importer 时取消必须返回 no-change cancellation")
            expect(
                !regularFileExists(at: root.appendingPathComponent("packs/pack-a/queued.mp3")),
                "cancelled-before-write 不得落目标 bytes")
            if let queuedOperationID {
                expect(
                    owner.presentation.activities.contains {
                        $0.operationID == queuedOperationID
                            && $0.phase == .cancelled(changedOnDisk: false)
                    },
                    "queued operation 必须以同一 identity settle 为 no-change cancellation")
            } else {
                expect(false, "queued operation 在首 await 前必须发布 busy identity")
            }
            expect(
                await owner.perform(
                    .importAudio(permit: queuedPermit, sources: [queuedSource], bindTo: nil))
                    == .rejected(.stalePermit),
                "cancelled-before-write 仍已单次消费 permit")
            await waitForSoundEditorScan(fixture, after: scansBefore)
            expect(
                fixture.recorder.requests.count == scansBefore + 1
                    && fixture.recorder.requests.last?.invalidatedPackIDs == ["pack-a"],
                "唯一 refresh 必须只来自 firstTask；queued cancel 不得新增 fake refresh")
        }
    }
}

@MainActor
private func soundEditorImportPermit(
    owner: SoundPacksEditorOwner,
    bindTo event: Event?
) -> SoundPackImportPermit? {
    guard case .sounds(let sounds) = owner.presentation.mode else { return nil }
    let action: SoundPackEditorAction?
    if let event {
        action = sounds.eventRows.first(where: { $0.event == event })?.importAction
    } else {
        action = sounds.requestImportAction
    }
    guard let action,
        case .nativeEffect(.selectAudioFiles(let permit, let permittedEvent)) =
            owner.send(.invoke(action)),
        permittedEvent == event
    else { return nil }
    return permit
}

@MainActor
private func waitForSoundEditorScan(_ fixture: SoundEditorFixture, after count: Int) async {
    for _ in 0..<512 {
        if fixture.recorder.requests.count > count { break }
        await Task.yield()
    }
    await fixture.library.waitUntilIdleForTesting()
}

private func soundEditorManifest(_ url: URL) -> [String: Any]? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
}

private final class GatedSoundEditorDurationProbe: AudioDurationProbing, @unchecked Sendable {
    private let condition = NSCondition()
    private let duration: TimeInterval?
    private var entered = false
    private var released = false

    init(duration: TimeInterval?) {
        self.duration = duration
    }

    func probeDuration(of _: URL) -> TimeInterval? {
        condition.lock()
        entered = true
        condition.broadcast()
        while !released { condition.wait() }
        condition.unlock()
        return duration
    }

    var hasEntered: Bool {
        condition.lock()
        defer { condition.unlock() }
        return entered
    }

    @MainActor
    func waitUntilEntered() async {
        for _ in 0..<512 {
            if hasEntered { return }
            await Task.yield()
        }
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}
