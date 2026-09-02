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
