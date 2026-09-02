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
            expect(await gate.waitUntilEntered(), "import 必须到达 deterministic duration gate")
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
            expect(
                owner.presentation.activities.contains {
                    $0.kind == .importAudio
                        && $0.phase
                            == .orphan(fileName: "drift.mp3", failure: .targetChanged)
                },
                "A→B→A completion 必须以 exact orphan/targetChanged activity settle")
            if case .sounds(let current) = owner.presentation.mode {
                expect(
                    current.selectedPack?.id == "pack-a",
                    "background completion 不得覆盖当前 foreground A generation")
            } else {
                expect(false, "background completion 不得改变当前 Sounds mode")
            }
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
            expect(await gate.waitUntilEntered(), "cancel test 必须到达 deterministic duration gate")
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
            expect(await gate.waitUntilEntered(), "first queued job 必须持有 serial executor")
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

    await suite("Sound editor activity：cancelAction 必须取消真实 queued import") {
        await withTempDirectory { root in
            let gate = GatedSoundEditorDurationProbe(duration: 1)
            let fixture = makeSoundEditorFixture(
                root: root,
                packIDs: ["pack-a"],
                durationProbe: gate)
            let owner = fixture.owner
            let context = SoundPacksEditorContext.sounds(
                route: .overview,
                requestRevision: 16)
            _ = owner.send(.activate(context))
            await waitForSoundEditorReady(owner, library: fixture.library)
            guard let occupyingPermit = soundEditorImportPermit(owner: owner, bindTo: nil),
                let cancelledPermit = soundEditorImportPermit(owner: owner, bindTo: .stop)
            else {
                expect(false, "UI cancel fixture 必须取得两个独立 permit")
                return
            }

            let occupyingSource = root.appendingPathComponent("occupying.mp3")
            let cancelledSource = root.appendingPathComponent("ui-cancelled.mp3")
            writeFixture(validMP3ID3Data(), to: occupyingSource)
            writeFixture(validMP3ID3Data(), to: cancelledSource)
            let manifestURL = root.appendingPathComponent("packs/pack-a/manifest.json")
            let manifestBefore = try? Data(contentsOf: manifestURL)
            let scansBefore = fixture.recorder.requests.count

            let occupyingTask = Task { @MainActor in
                await owner.perform(
                    .importAudio(
                        permit: occupyingPermit,
                        sources: [occupyingSource],
                        bindTo: nil))
            }
            expect(
                await gate.waitUntilEntered(),
                "首个 import 必须占用 deterministic serial executor gate")
            let cancelledTask = Task { @MainActor in
                await owner.perform(
                    .importAudio(
                        permit: cancelledPermit,
                        sources: [cancelledSource],
                        bindTo: .stop))
            }
            for _ in 0..<512 {
                if owner.presentation.activities.filter({ $0.phase == .busy }).count == 2 {
                    break
                }
                await Task.yield()
            }
            guard
                let activity = owner.presentation.activities.last(where: {
                    $0.kind == .importAudio && $0.event == .stop && $0.phase == .busy
                }), let cancelAction = activity.cancelAction
            else {
                gate.release()
                _ = await occupyingTask.value
                _ = await cancelledTask.value
                expect(false, "queued import 必须同步发布可调用的 activity.cancelAction")
                return
            }

            expect(
                owner.send(.invoke(cancelAction)) == .applied,
                "presentation cancelAction 必须在同一 MainActor stack 消费")
            expect(
                owner.presentation.activities.contains {
                    $0.operationID == activity.operationID
                        && $0.phase == .cancelled(changedOnDisk: false)
                        && $0.cancelAction == nil
                },
                "UI cancel 必须立即撤销 capability 并发布 no-change cancellation")
            gate.release()

            _ = await occupyingTask.value
            let cancelledResult = await cancelledTask.value
            await waitForSoundEditorScan(fixture, after: scansBefore)
            expect(
                cancelledResult == .rejected(.cancelled),
                "UI cancel 必须传到真实 async operation，不能只改 presentation")
            expect(
                regularFileExists(
                    at: root.appendingPathComponent("packs/pack-a/occupying.mp3"))
                    && !regularFileExists(
                        at: root.appendingPathComponent("packs/pack-a/ui-cancelled.mp3")),
                "queued UI cancel 只能保留 occupier bytes，不能开始被取消的写入")
            expect(
                (try? Data(contentsOf: manifestURL)) == manifestBefore,
                "queued UI cancel 不得继续执行 late Event bind")
            expect(
                owner.presentation.activities.contains {
                    $0.operationID == activity.operationID
                        && $0.phase == .cancelled(changedOnDisk: false)
                },
                "async completion 不得把已取消 activity 改写为 success")
            expect(
                fixture.recorder.requests.count == scansBefore + 1
                    && fixture.recorder.requests.last?.invalidatedPackIDs == ["pack-a"],
                "唯一 scan payload 必须来自 occupier；queued cancel 不得制造第二次 refresh")
        }
    }

    await suite("Sound editor perform：AI adoption 绑定 candidate generation 并 compound 刷新一次") {
        await withTempDirectory { root in
            let config = ClaudioConfig(
                selectedPack: "global-pack",
                surfaceOverrides: [
                    HostSurfaceID.workBuddy.rawValue: SurfaceSoundOverride(
                        selectedPack: "workbuddy-pack")
                ])
            let fixture = makeSoundEditorFixture(
                root: root,
                packIDs: ["global-pack", "workbuddy-pack"],
                config: config)
            let owner = fixture.owner
            let generationID = UUID()
            let route = EventSettingsWindowRoute(
                scope: .surface(.workBuddy),
                event: .stop)
            _ = owner.send(
                .activate(
                    .events(
                        route: route,
                        requestRevision: 20,
                        candidateGenerationID: generationID)))
            await waitForSoundEditorReady(owner, library: fixture.library)
            guard case .events(let events) = owner.presentation.mode,
                let permit = events.adoptionPermit
            else {
                expect(false, "fresh isolated user pack + active generation 必须签发 adoption permit")
                return
            }
            let source = root.appendingPathComponent("candidate.mp3")
            writeFixture(validMP3ID3Data(), to: source)
            let candidate = soundEditorCandidate(at: source, generationID: generationID)
            let scansBefore = fixture.recorder.requests.count

            let result = await owner.perform(
                .adoptAICue(
                    candidate: candidate,
                    displayName: try! AICueDisplayName("木琴完成"),
                    permit: permit))
            guard case .adopted(let outcome) = result else {
                expect(false, "matching candidate generation 必须返回 adopted outcome")
                return
            }
            let manifest = soundEditorManifest(
                root.appendingPathComponent("packs/workbuddy-pack/manifest.json"))
            expect(
                (manifest?["events"] as? [String: String])?["stop"]
                    == outcome.importedFile.fileName
                    && (manifest?["audio_names"] as? [String: String])?[
                        outcome.importedFile.fileName
                    ] == "木琴完成",
                "adoption 必须在一个原子 manifest writer 中提交 Event 与 display name")
            await waitForSoundEditorScan(fixture, after: scansBefore)
            expect(
                fixture.recorder.requests.count == scansBefore + 1
                    && fixture.recorder.requests.last?.invalidatedPackIDs == ["workbuddy-pack"],
                "adoption import+bind 必须只有一次 exact shared refresh")
            expect(
                await owner.perform(
                    .adoptAICue(
                        candidate: candidate,
                        displayName: try! AICueDisplayName("木琴完成"),
                        permit: permit)) == .rejected(.stalePermit),
                "adoption permit 必须 single-use")
        }
    }

    await suite("Sound editor activity：in-flight cancelAction 保留 adoption orphan 且不继续 bind") {
        await withTempDirectory { root in
            let gate = GatedSoundEditorDurationProbe(duration: 1)
            let fixture = makeIsolatedAdoptionFixture(root: root, durationProbe: gate)
            let owner = fixture.owner
            let generationID = UUID()
            _ = owner.send(
                .activate(
                    .events(
                        route: fixture.route,
                        requestRevision: 201,
                        candidateGenerationID: generationID)))
            await waitForSoundEditorReady(owner, library: fixture.library)
            guard case .events(let events) = owner.presentation.mode,
                let permit = events.adoptionPermit
            else {
                expect(false, "in-flight cancel fixture 必须取得 adoption permit")
                return
            }

            let source = root.appendingPathComponent("in-flight-cancel-candidate.mp3")
            let sourceBytes = validMP3ID3Data()
            writeFixture(sourceBytes, to: source)
            let candidate = soundEditorCandidate(at: source, generationID: generationID)
            let targetDirectory = fixture.manifest.deletingLastPathComponent()
            let entriesBefore = soundEditorDirectoryEntries(targetDirectory)
            let manifestBefore = try? Data(contentsOf: fixture.manifest)
            let scansBefore = fixture.recorder.requests.count

            let task = Task { @MainActor in
                await owner.perform(
                    .adoptAICue(
                        candidate: candidate,
                        displayName: try! AICueDisplayName("取消候选"),
                        permit: permit))
            }
            expect(
                await gate.waitUntilEntered(),
                "adoption 必须先进入真实 importer，再触发 presentation cancel")
            guard
                let activity = owner.presentation.activities.last(where: {
                    $0.kind == .adoptAICue && $0.phase == .busy
                }), let cancelAction = activity.cancelAction
            else {
                gate.release()
                _ = await task.value
                expect(false, "in-flight adoption 必须同步发布 cancelAction")
                return
            }
            expect(
                owner.send(.invoke(cancelAction)) == .applied,
                "in-flight cancelAction 必须同步命中当前 operation identity")
            gate.release()

            let result = await task.value
            var imported: ImportedAudioFile?
            var isCancelledOrphan = false
            switch result {
            case .adoptionOrphan(let file, let failure):
                imported = file
                isCancelledOrphan = failure == .cancelled
            case .adopted(let outcome):
                imported = outcome.importedFile
            default:
                break
            }
            await waitForSoundEditorScan(fixture.base, after: scansBefore)

            expect(
                isCancelledOrphan,
                "in-flight UI cancel 必须到达 operation，并返回 changedDespiteFailure orphan")
            if let imported {
                expect(
                    (try? Data(
                        contentsOf: targetDirectory.appendingPathComponent(imported.fileName)))
                        == sourceBytes,
                    "取消不伪造 rollback：已经导入的 candidate bytes 必须可恢复")
                expect(
                    owner.presentation.activities.contains {
                        $0.operationID == activity.operationID
                            && $0.phase
                                == .orphan(fileName: imported.fileName, failure: .cancelled)
                            && $0.cancelAction == nil
                    },
                    "presentation 必须用同一 identity settle exact cancelled orphan")
            } else {
                expect(false, "in-flight cancellation 必须报告落盘文件 identity")
            }
            expect(
                soundEditorDirectoryEntries(targetDirectory).subtracting(entriesBefore).count == 1,
                "in-flight cancel 只能留下一个 recoverable orphan，不得产生额外 pack bytes")
            expect(
                (try? Data(contentsOf: fixture.manifest)) == manifestBefore,
                "in-flight cancel 不得继续写 Event/display-name binding")
            expect(
                fixture.recorder.requests.count == scansBefore + 1
                    && fixture.recorder.requests.last?.invalidatedPackIDs == ["workbuddy-pack"],
                "in-flight cancel 的 changed bytes 必须只有一次 exact refresh payload")
        }
    }

    await suite("Sound editor perform：AI generation 在 import 前漂移时零 I/O 且 permit 已消费") {
        await withTempDirectory { root in
            let fixture = makeIsolatedAdoptionFixture(root: root)
            let owner = fixture.owner
            let firstGeneration = UUID()
            let nextGeneration = UUID()
            _ = owner.send(
                .activate(
                    .events(
                        route: fixture.route,
                        requestRevision: 21,
                        candidateGenerationID: firstGeneration)))
            await waitForSoundEditorReady(owner, library: fixture.library)
            guard case .events(let first) = owner.presentation.mode,
                let stalePermit = first.adoptionPermit
            else {
                expect(false, "first generation 必须取得 adoption permit")
                return
            }
            _ = owner.send(
                .activate(
                    .events(
                        route: fixture.route,
                        requestRevision: 21,
                        candidateGenerationID: nextGeneration)))
            let source = root.appendingPathComponent("stale-candidate.mp3")
            writeFixture(validMP3ID3Data(), to: source)
            let staleCandidate = soundEditorCandidate(
                at: source,
                generationID: firstGeneration)
            let targetDirectory = root.appendingPathComponent("packs/workbuddy-pack")
            let beforeFiles = Set(
                (try? FileManager.default.contentsOfDirectory(atPath: targetDirectory.path)) ?? [])
            let scansBefore = fixture.recorder.requests.count

            expect(
                await owner.perform(
                    .adoptAICue(
                        candidate: staleCandidate,
                        displayName: try! AICueDisplayName("过期候选"),
                        permit: stalePermit)) == .rejected(.stalePermit),
                "旧 generation permit 必须在 importer 前 fail closed")
            let afterFiles = Set(
                (try? FileManager.default.contentsOfDirectory(atPath: targetDirectory.path)) ?? [])
            expect(
                afterFiles == beforeFiles && fixture.recorder.requests.count == scansBefore,
                "pre-import generation drift 必须零 pack bytes、零 shared refresh")
            expect(
                await owner.perform(
                    .adoptAICue(
                        candidate: staleCandidate,
                        displayName: try! AICueDisplayName("过期候选"),
                        permit: stalePermit)) == .rejected(.stalePermit),
                "被拒绝的旧 generation permit 同样必须 single-use")
        }
    }

    await suite("Sound editor perform：AI generation A→B→A 在 import 前不能复活旧 permit") {
        await withTempDirectory { root in
            let fixture = makeIsolatedAdoptionFixture(root: root)
            let owner = fixture.owner
            let generationA = UUID()
            let generationB = UUID()
            let contextA = SoundPacksEditorContext.events(
                route: fixture.route,
                requestRevision: 211,
                candidateGenerationID: generationA)
            _ = owner.send(.activate(contextA))
            await waitForSoundEditorReady(owner, library: fixture.library)
            guard case .events(let initial) = owner.presentation.mode,
                let oldPermit = initial.adoptionPermit
            else {
                expect(false, "generation A 必须签发 adoption permit")
                return
            }

            _ = owner.send(
                .activate(
                    .events(
                        route: fixture.route,
                        requestRevision: 211,
                        candidateGenerationID: generationB)))
            _ = owner.send(.activate(contextA))
            guard case .events(let returnedA) = owner.presentation.mode,
                let currentPermit = returnedA.adoptionPermit
            else {
                expect(false, "返回 generation A 后必须签发当前 generation 的新 permit")
                return
            }

            let source = root.appendingPathComponent("pre-import-aba.mp3")
            writeFixture(validMP3ID3Data(), to: source)
            let candidate = soundEditorCandidate(at: source, generationID: generationA)
            let targetDirectory = fixture.manifest.deletingLastPathComponent()
            let entriesBefore = soundEditorDirectoryEntries(targetDirectory)
            let manifestBefore = try? Data(contentsOf: fixture.manifest)
            let scansBefore = fixture.recorder.requests.count

            let result = await owner.perform(
                .adoptAICue(
                    candidate: candidate,
                    displayName: try! AICueDisplayName("往返候选"),
                    permit: oldPermit))
            expect(
                result == .rejected(.stalePermit),
                "candidate UUID 回到 A 也不能复活第一次 A 的 permit")
            expect(
                currentPermit != oldPermit,
                "coherent Events presentation 必须只携带返回后新签发的 permit")
            expect(
                soundEditorDirectoryEntries(targetDirectory) == entriesBefore,
                "pre-import A→B→A stale 必须零 pack bytes")
            expect(
                (try? Data(contentsOf: fixture.manifest)) == manifestBefore,
                "pre-import A→B→A stale 必须零 manifest mutation")
            expect(
                !owner.presentation.activities.contains { $0.kind == .adoptAICue }
                    && fixture.recorder.requests.count == scansBefore,
                "pre-import stale 不得发布假 activity 或 scan payload")
        }
    }

    await suite("Sound editor perform：AI generation 在 final bind 前漂移会保留旧 binding 与 orphan") {
        await withTempDirectory { root in
            let gate = GatedSoundEditorDurationProbe(duration: 1)
            let fixture = makeIsolatedAdoptionFixture(root: root, durationProbe: gate)
            let owner = fixture.owner
            let firstGeneration = UUID()
            let nextGeneration = UUID()
            _ = owner.send(
                .activate(
                    .events(
                        route: fixture.route,
                        requestRevision: 22,
                        candidateGenerationID: firstGeneration)))
            await waitForSoundEditorReady(owner, library: fixture.library)
            guard case .events(let first) = owner.presentation.mode,
                let permit = first.adoptionPermit
            else {
                expect(false, "first generation 必须取得 adoption permit")
                return
            }
            let source = root.appendingPathComponent("drifting-candidate.mp3")
            writeFixture(validMP3ID3Data(), to: source)
            let candidate = soundEditorCandidate(at: source, generationID: firstGeneration)
            let scansBefore = fixture.recorder.requests.count
            let task = Task { @MainActor in
                await owner.perform(
                    .adoptAICue(
                        candidate: candidate,
                        displayName: try! AICueDisplayName("漂移候选"),
                        permit: permit))
            }
            expect(await gate.waitUntilEntered(), "adoption 必须到达 deterministic duration gate")
            _ = owner.send(
                .activate(
                    .events(
                        route: fixture.route,
                        requestRevision: 22,
                        candidateGenerationID: nextGeneration)))
            let replacementPermit: SoundPackAdoptionPermit?
            if case .events(let next) = owner.presentation.mode {
                replacementPermit = next.adoptionPermit
            } else {
                replacementPermit = nil
            }
            gate.release()

            guard case .adoptionOrphan(let imported, let failure) = await task.value else {
                expect(false, "post-import generation drift 必须返回 typed orphan")
                return
            }
            expect(
                failure == .targetChanged && replacementPermit != nil
                    && replacementPermit != permit,
                "旧 operation 必须后台失败，当前 generation 保持自己的新 permit")
            let manifest = soundEditorManifest(fixture.manifest)
            expect(
                (manifest?["events"] as? [String: String])?["stop"] == "stop.mp3"
                    && (manifest?["future"] as? [String: Bool])?["keep"] == true,
                "final drift 不得覆盖旧 binding 或未知 manifest sibling")
            expect(
                regularFileExists(
                    at: fixture.manifest.deletingLastPathComponent()
                        .appendingPathComponent(imported.fileName)),
                "已经导入的 candidate 必须保留为 recoverable orphan")
            expect(
                owner.presentation.activities.contains {
                    $0.kind == .adoptAICue
                        && $0.phase
                            == .orphan(fileName: imported.fileName, failure: .targetChanged)
                },
                "coherent presentation 必须保留 exact adoption orphan reason")
            await waitForSoundEditorScan(fixture.base, after: scansBefore)
            expect(
                fixture.recorder.requests.count == scansBefore + 1
                    && fixture.recorder.requests.last?.invalidatedPackIDs == ["workbuddy-pack"],
                "post-import adoption drift 是 changedDespiteFailure，只能 exact refresh 一次")
        }
    }

    await suite("Sound editor perform：AI generation A→B→A 在 final bind 前仍是 orphan") {
        await withTempDirectory { root in
            let gate = GatedSoundEditorDurationProbe(duration: 1)
            let fixture = makeIsolatedAdoptionFixture(root: root, durationProbe: gate)
            let owner = fixture.owner
            let generationA = UUID()
            let generationB = UUID()
            let contextA = SoundPacksEditorContext.events(
                route: fixture.route,
                requestRevision: 221,
                candidateGenerationID: generationA)
            _ = owner.send(.activate(contextA))
            await waitForSoundEditorReady(owner, library: fixture.library)
            guard case .events(let initial) = owner.presentation.mode,
                let permit = initial.adoptionPermit
            else {
                expect(false, "generation A 必须签发 in-flight adoption permit")
                return
            }

            let source = root.appendingPathComponent("pre-bind-aba.mp3")
            let sourceBytes = validMP3ID3Data()
            writeFixture(sourceBytes, to: source)
            let candidate = soundEditorCandidate(at: source, generationID: generationA)
            let targetDirectory = fixture.manifest.deletingLastPathComponent()
            let entriesBefore = soundEditorDirectoryEntries(targetDirectory)
            let manifestBefore = try? Data(contentsOf: fixture.manifest)
            let scansBefore = fixture.recorder.requests.count
            let task = Task { @MainActor in
                await owner.perform(
                    .adoptAICue(
                        candidate: candidate,
                        displayName: try! AICueDisplayName("绑定前往返"),
                        permit: permit))
            }
            expect(
                await gate.waitUntilEntered(),
                "A operation 必须到达 deterministic pre-bind gate")
            _ = owner.send(
                .activate(
                    .events(
                        route: fixture.route,
                        requestRevision: 221,
                        candidateGenerationID: generationB)))
            _ = owner.send(.activate(contextA))
            gate.release()

            let result = await task.value
            var imported: ImportedAudioFile?
            var isTargetChangedOrphan = false
            switch result {
            case .adoptionOrphan(let file, let failure):
                imported = file
                isTargetChangedOrphan = failure == .targetChanged
            case .adopted(let outcome):
                imported = outcome.importedFile
            default:
                break
            }
            await waitForSoundEditorScan(fixture.base, after: scansBefore)

            expect(
                isTargetChangedOrphan,
                "final bind 必须校验 candidate generation epoch，不能因 UUID 回到 A 而成功")
            expect(
                (try? Data(contentsOf: fixture.manifest)) == manifestBefore,
                "pre-bind A→B→A 不得覆盖旧 Event binding 或未知 manifest sibling")
            if let imported {
                expect(
                    (try? Data(
                        contentsOf: targetDirectory.appendingPathComponent(imported.fileName)))
                        == sourceBytes
                        && soundEditorDirectoryEntries(targetDirectory)
                            .subtracting(entriesBefore) == [imported.fileName],
                    "已落盘 candidate 必须作为唯一 recoverable orphan 留存")
                expect(
                    owner.presentation.activities.contains {
                        $0.kind == .adoptAICue
                            && $0.phase
                                == .orphan(fileName: imported.fileName, failure: .targetChanged)
                    },
                    "presentation 必须用 exact targetChanged reason settle orphan")
            } else {
                expect(false, "pre-bind drift 必须返回 imported orphan identity")
            }
            if case .events(let current) = owner.presentation.mode {
                expect(
                    current.adoptionPermit != nil && current.adoptionPermit != permit,
                    "返回 A 的 foreground presentation 必须保留自己的新 permit")
            } else {
                expect(false, "background completion 不得覆盖当前 Events mode")
            }
            expect(
                fixture.recorder.requests.count == scansBefore + 1
                    && fixture.recorder.requests.last?.invalidatedPackIDs == ["workbuddy-pack"],
                "pre-bind orphan 是 changedDespiteFailure，只能 exact refresh 一次")
        }
    }

    await suite("Sound editor perform：scope failure 首次调用也必须消费 permit") {
        await withTempDirectory { root in
            let validConfig = ClaudioConfig(
                selectedPack: "pack-a",
                surfaceOverrides: [
                    HostSurfaceID.workBuddy.rawValue: SurfaceSoundOverride(
                        selectedPack: "pack-a")
                ])
            let fixture = makeSoundEditorFixture(
                root: root,
                packIDs: ["pack-a"],
                config: validConfig)
            let owner = fixture.owner
            let context = SoundPacksEditorContext.sounds(
                route: .overview(surface: .workBuddy),
                requestRevision: 231)
            _ = owner.send(.activate(context))
            await waitForSoundEditorReady(owner, library: fixture.library)
            guard let permit = soundEditorImportPermit(owner: owner, bindTo: .stop) else {
                expect(false, "健康 Surface scope 必须签发 Event-bound import permit")
                return
            }

            let source = root.appendingPathComponent("scope-replay.mp3")
            writeFixture(validMP3ID3Data(), to: source)
            let targetDirectory = root.appendingPathComponent("packs/pack-a")
            let entriesBefore = soundEditorDirectoryEntries(targetDirectory)
            let manifestURL = targetDirectory.appendingPathComponent("manifest.json")
            let manifestBefore = try? Data(contentsOf: manifestURL)
            let validConfigBytes = try? Data(contentsOf: fixture.configFile)
            let scansBefore = fixture.recorder.requests.count

            writeFixture(
                #"{"selected_pack":"pack-a","surface_overrides":"broken","future":{"keep":true}}"#,
                to: fixture.configFile)
            let firstResult = await owner.perform(
                .importAudio(permit: permit, sources: [source], bindTo: .stop))
            expect(
                firstResult == .rejected(.scopeUnavailable),
                "最新损坏 scope 必须优先 fail closed")
            expect(
                soundEditorDirectoryEntries(targetDirectory) == entriesBefore
                    && (try? Data(contentsOf: manifestURL)) == manifestBefore
                    && fixture.recorder.requests.count == scansBefore,
                "scope rejection 必须同时保持 bytes/manifest/scan payload 不变")

            if let validConfigBytes {
                writeFixture(validConfigBytes, to: fixture.configFile)
            } else {
                expect(false, "fixture 必须可恢复有效 config bytes")
                return
            }
            let replayResult = await owner.perform(
                .importAudio(permit: permit, sources: [source], bindTo: .stop))
            await waitForSoundEditorScan(fixture, after: scansBefore)

            expect(
                replayResult == .rejected(.stalePermit),
                "scope failure 也必须在首个 perform 同步消费 permit，修复 config 后不能 replay")
            expect(
                soundEditorDirectoryEntries(targetDirectory) == entriesBefore,
                "被 scope failure 消费的 permit 不得在 replay 时写入 bytes")
            expect(
                (try? Data(contentsOf: manifestURL)) == manifestBefore,
                "被消费 permit 的 replay 不得写 Event binding")
            if case .sounds(let sounds) = owner.presentation.mode {
                expect(
                    sounds.route == .overview(surface: .workBuddy)
                        && sounds.selectedPack?.id == "pack-a"
                        && !owner.presentation.activities.contains { $0.kind == .importAudio },
                    "no-change rejection 必须保留当前 Sounds presentation 且不伪造 activity")
            } else {
                expect(false, "scope replay 不得改变当前 Sounds mode")
            }
            expect(
                fixture.recorder.requests.count == scansBefore,
                "两次 no-change rejection 都不得发布 SoundPackLibrary scan payload")
        }
    }

    await suite("Sound editor perform：identical activate 也必须使旧 permit stale") {
        await withTempDirectory { root in
            let fixture = makeSoundEditorFixture(root: root, packIDs: ["pack-a"])
            let owner = fixture.owner
            let context = SoundPacksEditorContext.sounds(
                route: .overview,
                requestRevision: 232)
            _ = owner.send(.activate(context))
            await waitForSoundEditorReady(owner, library: fixture.library)
            guard let oldPermit = soundEditorImportPermit(owner: owner, bindTo: .stop) else {
                expect(false, "初次 activation 必须签发 import permit")
                return
            }

            _ = owner.send(.activate(context))
            guard let replacementPermit = soundEditorImportPermit(owner: owner, bindTo: .stop)
            else {
                expect(false, "identical reactivation 必须签发当前 epoch 的 replacement permit")
                return
            }
            let source = root.appendingPathComponent("reactivated.mp3")
            writeFixture(validMP3ID3Data(), to: source)
            let targetDirectory = root.appendingPathComponent("packs/pack-a")
            let entriesBefore = soundEditorDirectoryEntries(targetDirectory)
            let manifestURL = targetDirectory.appendingPathComponent("manifest.json")
            let manifestBefore = try? Data(contentsOf: manifestURL)
            let scansBefore = fixture.recorder.requests.count

            let result = await owner.perform(
                .importAudio(permit: oldPermit, sources: [source], bindTo: .stop))
            await waitForSoundEditorScan(fixture, after: scansBefore)
            expect(
                replacementPermit != oldPermit && result == .rejected(.stalePermit),
                "每次 activate 都是新 action epoch；旧 permit 不能因 context 值相同而存活")
            expect(
                soundEditorDirectoryEntries(targetDirectory) == entriesBefore,
                "identical-reactivation stale 必须零 pack bytes")
            expect(
                (try? Data(contentsOf: manifestURL)) == manifestBefore,
                "identical-reactivation stale 必须零 manifest mutation")
            if case .sounds(let sounds) = owner.presentation.mode {
                expect(
                    sounds.selectedPack?.id == "pack-a"
                        && !owner.presentation.activities.contains { $0.kind == .importAudio },
                    "stale replay 必须保持当前 presentation 且不发布假 activity")
            } else {
                expect(false, "identical activation 不得改变 Sounds mode")
            }
            expect(
                fixture.recorder.requests.count == scansBefore,
                "identical-reactivation stale 不得产生 scan payload")
        }
    }

    await suite("Sound editor presentation：built-in 与 shared user pack 不签 adoption permit") {
        await withTempDirectory { root in
            let sharedConfig = ClaudioConfig(
                selectedPack: "global-pack",
                surfaceOverrides: [
                    HostSurfaceID.workBuddy.rawValue: SurfaceSoundOverride(
                        selectedPack: "shared-pack"),
                    HostSurfaceID.codex.rawValue: SurfaceSoundOverride(
                        selectedPack: "shared-pack"),
                ])
            let shared = makeSoundEditorFixture(
                root: root,
                packIDs: ["global-pack", "shared-pack"],
                config: sharedConfig)
            let route = EventSettingsWindowRoute(
                scope: .surface(.workBuddy),
                event: .stop)
            _ = shared.owner.send(
                .activate(
                    .events(
                        route: route,
                        requestRevision: 23,
                        candidateGenerationID: UUID())))
            await waitForSoundEditorReady(shared.owner, library: shared.library)
            if case .events(let events) = shared.owner.presentation.mode {
                expect(events.adoptionPermit == nil, "被另一 Surface 共享的 user pack 不得签 permit")
            } else {
                expect(false, "shared-pack fixture 必须保持 Events mode")
            }

            await withTempDirectory { builtinRoot in
                let builtin = makeSoundEditorFixture(
                    root: builtinRoot,
                    packIDs: ["global-pack", "workbuddy-pack"],
                    config: ClaudioConfig(
                        selectedPack: "global-pack",
                        surfaceOverrides: [
                            HostSurfaceID.workBuddy.rawValue: SurfaceSoundOverride(
                                selectedPack: "workbuddy-pack")
                        ]),
                    builtinPackIDs: ["workbuddy-pack"])
                _ = builtin.owner.send(
                    .activate(
                        .events(
                            route: route,
                            requestRevision: 24,
                            candidateGenerationID: UUID())))
                await waitForSoundEditorReady(builtin.owner, library: builtin.library)
                if case .events(let events) = builtin.owner.presentation.mode {
                    expect(events.adoptionPermit == nil, "built-in pack 不得签 adoption permit")
                } else {
                    expect(false, "built-in fixture 必须保持 Events mode")
                }
            }
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

private func soundEditorDirectoryEntries(_ directory: URL) -> Set<String> {
    Set((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
}

private func soundEditorCandidate(at fileURL: URL, generationID: UUID) -> AICueCandidate {
    AICueCandidate(
        id: UUID(),
        variant: .clear,
        asset: AICueTemporaryAudioAsset(
            fileURL: fileURL,
            byteCount: validMP3ID3Data().count,
            sniffedFormat: .mp3),
        durationMilliseconds: 1_000,
        mediaType: "audio/mpeg",
        provenance: AICueCandidateProvenance(
            providerID: .elevenLabs,
            profileID: .elevenLabsGlobal,
            modelID: "eleven_text_to_sound_v2",
            generationID: generationID,
            requestOrdinal: 1,
            providerRequestID: nil))
}

private struct IsolatedAdoptionFixture {
    let base: SoundEditorFixture
    let route: EventSettingsWindowRoute
    let manifest: URL

    var owner: SoundPacksEditorOwner { base.owner }
    var library: SoundPackLibrary { base.library }
    var recorder: SoundEditorScanRecorder { base.recorder }
}

@MainActor
private func makeIsolatedAdoptionFixture(
    root: URL,
    durationProbe: (any AudioDurationProbing)? = nil
) -> IsolatedAdoptionFixture {
    let base = makeSoundEditorFixture(
        root: root,
        packIDs: ["global-pack", "workbuddy-pack"],
        durationProbe: durationProbe,
        config: ClaudioConfig(
            selectedPack: "global-pack",
            surfaceOverrides: [
                HostSurfaceID.workBuddy.rawValue: SurfaceSoundOverride(
                    selectedPack: "workbuddy-pack")
            ]))
    return IsolatedAdoptionFixture(
        base: base,
        route: EventSettingsWindowRoute(scope: .surface(.workBuddy), event: .stop),
        manifest: root.appendingPathComponent("packs/workbuddy-pack/manifest.json"))
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
    func waitUntilEntered() async -> Bool {
        for _ in 0..<4_096 {
            if hasEntered { return true }
            await Task.yield()
        }
        return false
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}
