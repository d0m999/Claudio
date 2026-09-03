import ClaudioCore
import ClaudioGUICore
import Foundation

@MainActor
func runSoundPacksEditorGapRedSuites() async {
    await suite("[129-GAP-RED] O-01 empty/all-rejected 保持四平面 no-change 且不泄露绝对路径") {
        await withTempDirectory { root in
            let fixture = makeSoundEditorFixture(root: root, packIDs: ["pack-a"])
            let owner = fixture.owner
            _ = owner.send(.activate(.sounds(route: .overview, requestRevision: 300)))
            await waitForSoundEditorReady(owner, library: fixture.library)

            guard let emptyPermit = gapImportPermit(owner: owner, bindTo: nil) else {
                expect(false, "[129-GAP-RED] O-01 fixture 必须签发 empty import permit")
                return
            }
            let configBefore = try? Data(contentsOf: fixture.configFile)
            let manifestURL = root.appendingPathComponent("packs/pack-a/manifest.json")
            let manifestBefore = try? Data(contentsOf: manifestURL)
            let treeBefore = gapDirectoryEntries(manifestURL.deletingLastPathComponent())
            let presentationBefore = owner.presentation
            let scansBefore = fixture.recorder.requests.count

            let emptyResult = await owner.perform(
                .importAudio(permit: emptyPermit, sources: [], bindTo: nil))
            guard case .imported(let empty) = emptyResult else {
                expect(false, "[129-GAP-RED] empty picker cancel 必须返回 typed unchanged")
                return
            }
            expect(
                empty.accepted.isEmpty && empty.rejected.isEmpty && empty.boundEvent == nil
                    && empty.orphan == nil && empty.completion == .unchanged
                    && !empty.allowsForegroundFollowUp,
                "[129-GAP-RED] empty operation 的 typed plane 必须是 exact unchanged")
            expect(
                owner.presentation == presentationBefore,
                "[129-GAP-RED] empty operation 不得制造 activity/status/announcement publication")
            expect(
                (try? Data(contentsOf: fixture.configFile)) == configBefore
                    && (try? Data(contentsOf: manifestURL)) == manifestBefore
                    && gapDirectoryEntries(manifestURL.deletingLastPathComponent()) == treeBefore,
                "[129-GAP-RED] empty operation 必须保持 config/manifest/tree bytes")
            expect(
                fixture.recorder.requests.count == scansBefore,
                "[129-GAP-RED] empty operation 必须零 invalidation、零 shared refresh")

            guard let rejectedPermit = gapImportPermit(owner: owner, bindTo: nil) else {
                expect(false, "[129-GAP-RED] O-01 fixture 必须重签 all-rejected permit")
                return
            }
            let privateDirectory = root.appendingPathComponent(
                "do-not-leak-this-absolute-source-directory", isDirectory: true)
            let rejectedSource = privateDirectory.appendingPathComponent("private-source.mp3")
            writeFixture(evilShellScriptData(), to: rejectedSource)
            let presentationBeforeRejected = owner.presentation

            let rejectedResult = await owner.perform(
                .importAudio(
                    permit: rejectedPermit,
                    sources: [rejectedSource],
                    bindTo: nil))
            guard case .imported(let rejected) = rejectedResult else {
                expect(
                    false,
                    "[129-GAP-RED] all-rejected 必须返回 typed import rejection")
                return
            }
            expect(
                rejected.accepted.isEmpty && rejected.boundEvent == nil && rejected.orphan == nil
                    && rejected.completion == .failed(.importRejected)
                    && rejected.rejected.count == 1
                    && rejected.rejected.first?.sourceFileName == "private-source.mp3",
                "[129-GAP-RED] all-rejected typed plane 必须保留 basename/reason，但没有 accepted fact")
            let exposedRejectedText = rejected.rejected.map {
                "\($0.sourceFileName) \($0.reason.message)"
            }.joined(separator: " ")
            expect(
                !exposedRejectedText.contains(root.path)
                    && !exposedRejectedText.contains(privateDirectory.path)
                    && rejected.rejected.allSatisfy { !$0.sourceFileName.contains("/") },
                "[129-GAP-RED] rejection presentation 不得泄露 absolute source path")
            expect(
                owner.presentation.revision > presentationBeforeRejected.revision
                    && owner.presentation.activities.contains {
                        $0.kind == .importAudio && $0.phase == .failed(.importRejected)
                    }
                    && owner.presentation.pendingAnnouncement?.kind
                        == .operation(kind: .importAudio, completion: .failed(.importRejected))
                    && owner.presentation.pendingAnnouncement?.actionText == nil
                    && owner.presentation.pendingAnnouncement?.messageText == nil,
                "[129-GAP-RED] all-rejected presentation plane 必须只有 semantic terminal fact")
            expect(
                (try? Data(contentsOf: fixture.configFile)) == configBefore
                    && (try? Data(contentsOf: manifestURL)) == manifestBefore
                    && gapDirectoryEntries(manifestURL.deletingLastPathComponent()) == treeBefore,
                "[129-GAP-RED] all-rejected 必须保持 config/manifest/pack tree")
            expect(
                fixture.recorder.requests.count == scansBefore,
                "[129-GAP-RED] all-rejected 必须零 invalidation、零 shared refresh")
        }
    }

    await suite("[129-GAP-RED] import/adoption 在 source I/O 前刷新 shared observation 并拒绝消失目标") {
        await withTempDirectory { root in
            let probe = GapCountingDurationProbe(duration: 1)
            let fixture = makeSoundEditorFixture(
                root: root,
                packIDs: ["pack-a"],
                durationProbe: probe)
            let owner = fixture.owner
            _ = owner.send(.activate(.sounds(route: .overview, requestRevision: 310)))
            await waitForSoundEditorReady(owner, library: fixture.library)
            guard let permit = gapImportPermit(owner: owner, bindTo: nil) else {
                expect(false, "[129-GAP-RED] pre-import fixture 必须取得 generic permit")
                return
            }
            let targetDirectory = root.appendingPathComponent("packs/pack-a", isDirectory: true)
            do {
                try FileManager.default.removeItem(at: targetDirectory)
            } catch {
                expect(false, "[129-GAP-RED] pre-import fixture 必须能移除 captured target")
                return
            }
            let source = root.appendingPathComponent("picked-after-target-vanished.mp3")
            writeFixture(validMP3ID3Data(), to: source)
            let scansBefore = fixture.recorder.requests.count

            let result = await owner.perform(
                .importAudio(permit: permit, sources: [source], bindTo: nil))
            await fixture.library.waitUntilIdleForTesting()
            expect(
                gapIsPreImportRejection(result),
                "[129-GAP-RED] latest shared observation 必须在 import 前拒绝消失 target")
            expect(
                probe.callCount == 0,
                "[129-GAP-RED] stale shared target 必须在 source duration I/O 前 fail closed")
            expect(
                !FileManager.default.fileExists(atPath: targetDirectory.path),
                "[129-GAP-RED] stale permit 不得重新创建已消失的 installed pack")
            expect(
                fixture.recorder.requests.count == scansBefore + 1,
                "[129-GAP-RED] pre-import revalidation 必须由同一 shared library 恰好观察一次")
        }

        await withTempDirectory { root in
            let probe = GapCountingDurationProbe(duration: 1)
            let fixture = gapAdoptionFixture(root: root, durationProbe: probe)
            let generationID = UUID()
            _ = fixture.owner.send(
                .activate(
                    .events(
                        route: fixture.route,
                        requestRevision: 311,
                        candidateGenerationID: generationID)))
            await waitForSoundEditorReady(fixture.owner, library: fixture.library)
            guard case .events(let events) = fixture.owner.presentation.mode,
                let permit = events.adoptionPermit
            else {
                expect(false, "[129-GAP-RED] pre-adoption fixture 必须取得 permit")
                return
            }
            let targetDirectory = fixture.manifest.deletingLastPathComponent()
            do {
                try FileManager.default.removeItem(at: targetDirectory)
            } catch {
                expect(false, "[129-GAP-RED] pre-adoption fixture 必须能移除 captured target")
                return
            }
            let source = root.appendingPathComponent("candidate-after-target-vanished.mp3")
            writeFixture(validMP3ID3Data(), to: source)
            let scansBefore = fixture.recorder.requests.count

            let result = await fixture.owner.perform(
                .adoptAICue(
                    candidate: gapCandidate(at: source, generationID: generationID),
                    displayName: try! AICueDisplayName("不会采用"),
                    permit: permit))
            await fixture.library.waitUntilIdleForTesting()
            expect(
                gapIsPreImportRejection(result),
                "[129-GAP-RED] adoption 必须以最新 shared observation 在 import 前拒绝")
            expect(
                probe.callCount == 0,
                "[129-GAP-RED] stale adoption target 必须在 candidate duration I/O 前 fail closed")
            expect(
                !FileManager.default.fileExists(atPath: targetDirectory.path),
                "[129-GAP-RED] stale adoption permit 不得复活已消失的 user pack")
            expect(
                fixture.recorder.requests.count == scansBefore + 1,
                "[129-GAP-RED] adoption pre-import 必须复用同一 shared library 精确观察一次")
        }
    }

    await suite("[129-GAP-RED] import/adoption final bind 以 actionEpoch A→B→A fail closed") {
        await withTempDirectory { root in
            let gate = GapDurationGate(duration: 1)
            defer { gate.release() }
            let fixture = makeSoundEditorFixture(
                root: root,
                packIDs: ["pack-a"],
                durationProbe: gate)
            let owner = fixture.owner
            let contextA = SoundPacksEditorContext.sounds(
                route: .overview,
                requestRevision: 320)
            _ = owner.send(.activate(contextA))
            await waitForSoundEditorReady(owner, library: fixture.library)
            guard let permit = gapImportPermit(owner: owner, bindTo: .stop) else {
                expect(false, "[129-GAP-RED] import epoch fixture 必须取得 Event permit")
                return
            }
            let source = root.appendingPathComponent("epoch-import.mp3")
            writeFixture(validMP3ID3Data(), to: source)
            let manifest = root.appendingPathComponent("packs/pack-a/manifest.json")
            let manifestBefore = try? Data(contentsOf: manifest)
            let scansBefore = fixture.recorder.requests.count
            let task = Task { @MainActor in
                await owner.perform(
                    .importAudio(permit: permit, sources: [source], bindTo: .stop))
            }
            guard await gate.waitUntilEntered() else {
                expect(false, "[129-GAP-RED] import 必须停在 deterministic source gate")
                return
            }
            _ = owner.send(.activate(.sounds(route: .overview, requestRevision: 321)))
            _ = owner.send(.activate(contextA))
            gate.release()

            let result = await task.value
            guard case .imported(let outcome) = result else {
                expect(false, "[129-GAP-RED] 已落盘 import 必须返回 orphan truth")
                return
            }
            expect(
                outcome.completedInBackground && outcome.boundEvent == nil
                    && outcome.orphan?.fileName == "epoch-import.mp3"
                    && outcome.completion == .orphan(.targetChanged),
                "[129-GAP-RED] context A→B→A 必须由 actionEpoch 阻止旧 import 重获 foreground")
            expect(
                (try? Data(contentsOf: manifest)) == manifestBefore,
                "[129-GAP-RED] stale actionEpoch 不得覆盖旧 Event binding/unknown fields")
            await gapWaitForScan(fixture, after: scansBefore)
            expect(
                fixture.recorder.requests.count == scansBefore + 1
                    && fixture.recorder.requests.last?.invalidatedPackIDs == ["pack-a"],
                "[129-GAP-RED] actionEpoch orphan 仍必须为 accepted bytes exact refresh 一次")
        }

        await withTempDirectory { root in
            let gate = GapDurationGate(duration: 1)
            defer { gate.release() }
            let fixture = gapAdoptionFixture(root: root, durationProbe: gate)
            let generationID = UUID()
            let contextA = SoundPacksEditorContext.events(
                route: fixture.route,
                requestRevision: 322,
                candidateGenerationID: generationID)
            _ = fixture.owner.send(.activate(contextA))
            await waitForSoundEditorReady(fixture.owner, library: fixture.library)
            guard case .events(let events) = fixture.owner.presentation.mode,
                let permit = events.adoptionPermit
            else {
                expect(false, "[129-GAP-RED] adoption epoch fixture 必须取得 permit")
                return
            }
            let source = root.appendingPathComponent("epoch-candidate.mp3")
            writeFixture(validMP3ID3Data(), to: source)
            let manifestBefore = try? Data(contentsOf: fixture.manifest)
            let scansBefore = fixture.recorder.requests.count
            let task = Task { @MainActor in
                await fixture.owner.perform(
                    .adoptAICue(
                        candidate: gapCandidate(at: source, generationID: generationID),
                        displayName: try! AICueDisplayName("不应覆盖"),
                        permit: permit))
            }
            guard await gate.waitUntilEntered() else {
                expect(false, "[129-GAP-RED] adoption 必须停在 deterministic source gate")
                return
            }
            _ = fixture.owner.send(
                .activate(
                    .events(
                        route: fixture.route,
                        requestRevision: 323,
                        candidateGenerationID: generationID)))
            _ = fixture.owner.send(.activate(contextA))
            gate.release()

            let result = await task.value
            guard case .adoptionOrphan(let imported, let failure) = result else {
                expect(false, "[129-GAP-RED] stale epoch adoption 必须返回 orphan")
                return
            }
            expect(
                failure == .targetChanged && !imported.fileName.isEmpty,
                "[129-GAP-RED] candidate generation 相同也必须由 actionEpoch 拒绝 A→B→A")
            expect(
                (try? Data(contentsOf: fixture.manifest)) == manifestBefore,
                "[129-GAP-RED] stale adoption epoch 必须保留旧 binding/unknown fields")
            await gapWaitForScan(fixture.base, after: scansBefore)
            expect(
                fixture.recorder.requests.count == scansBefore + 1
                    && fixture.recorder.requests.last?.invalidatedPackIDs == ["workbuddy-pack"],
                "[129-GAP-RED] stale adoption epoch 的 imported orphan 必须 exact refresh 一次")
        }
    }

    await suite("[129-GAP-RED] import/adoption final bind 拒绝最新 shared snapshotRevision 漂移") {
        await withTempDirectory { root in
            let gate = GapPostImportGate()
            defer { gate.release() }
            let fixture = makeSoundEditorFixture(
                root: root,
                packIDs: ["pack-a"],
                afterFinalImportCancellationSampleForTesting: { gate.pauseWorker() })
            let owner = fixture.owner
            _ = owner.send(.activate(.sounds(route: .overview, requestRevision: 330)))
            await waitForSoundEditorReady(owner, library: fixture.library)
            guard let permit = gapImportPermit(owner: owner, bindTo: .stop) else {
                expect(false, "[129-GAP-RED] import snapshot fixture 必须取得 permit")
                return
            }
            let source = root.appendingPathComponent("snapshot-import.mp3")
            writeFixture(validMP3ID3Data(), to: source)
            let manifest = root.appendingPathComponent("packs/pack-a/manifest.json")
            let task = Task { @MainActor in
                await owner.perform(
                    .importAudio(permit: permit, sources: [source], bindTo: .stop))
            }
            guard await gate.waitUntilEntered() else {
                expect(false, "[129-GAP-RED] import snapshot 必须停在 publish 后/bind 前")
                return
            }
            let scansBeforeFinalObservation = fixture.recorder.requests.count
            writeFixture("external", to: root.appendingPathComponent("packs/pack-a/external.mp3"))
            writeFixture(
                #"{"id":"pack-a","name":"External Import Revision","events":{"stop":"external.mp3"},"future":{"keep":"external"}}"#,
                to: manifest)
            expect(
                fixture.recorder.requests.count == scansBeforeFinalObservation,
                "[129-GAP-RED] test 不得在 active compound mutation 内自行请求 shared refresh")
            gate.release()

            let result = await task.value
            guard case .imported(let outcome) = result else {
                expect(false, "[129-GAP-RED] snapshot-drift import 必须返回 changed orphan")
                return
            }
            expect(
                outcome.completedInBackground && outcome.boundEvent == nil
                    && outcome.orphan?.fileName == "snapshot-import.mp3"
                    && outcome.completion == .orphan(.targetChanged),
                "[129-GAP-RED] final bind 必须比较 captured/current snapshotRevision")
            expect(
                gapManifestEvent(manifest, event: "stop") == "external.mp3"
                    && gapManifestFuture(manifest, key: "keep") == "external",
                "[129-GAP-RED] snapshot drift 必须保留 external binding 与 unknown sibling")
            await gapWaitForScan(fixture, after: scansBeforeFinalObservation)
            expect(
                fixture.recorder.requests.count == scansBeforeFinalObservation + 1
                    && fixture.recorder.requests.last?.invalidatedPackIDs == ["pack-a"],
                "[129-GAP-RED] owner 必须在 release 后主动完成一次 exact shared observation")
        }

        await withTempDirectory { root in
            let gate = GapPostImportGate()
            defer { gate.release() }
            let fixture = gapAdoptionFixture(
                root: root,
                afterFinalImportSample: { gate.pauseWorker() })
            let generationID = UUID()
            _ = fixture.owner.send(
                .activate(
                    .events(
                        route: fixture.route,
                        requestRevision: 331,
                        candidateGenerationID: generationID)))
            await waitForSoundEditorReady(fixture.owner, library: fixture.library)
            guard case .events(let events) = fixture.owner.presentation.mode,
                let permit = events.adoptionPermit
            else {
                expect(false, "[129-GAP-RED] adoption snapshot fixture 必须取得 permit")
                return
            }
            let source = root.appendingPathComponent("snapshot-candidate.mp3")
            writeFixture(validMP3ID3Data(), to: source)
            let task = Task { @MainActor in
                await fixture.owner.perform(
                    .adoptAICue(
                        candidate: gapCandidate(at: source, generationID: generationID),
                        displayName: try! AICueDisplayName("不应覆盖外部 revision"),
                        permit: permit))
            }
            guard await gate.waitUntilEntered() else {
                expect(false, "[129-GAP-RED] adoption snapshot 必须停在 publish 后/bind 前")
                return
            }
            let scansBeforeFinalObservation = fixture.recorder.requests.count
            writeFixture(
                validMP3ID3Data(),
                to: fixture.manifest.deletingLastPathComponent()
                    .appendingPathComponent("external.mp3"))
            writeFixture(
                #"{"id":"workbuddy-pack","name":"External Adoption Revision","events":{"stop":"external.mp3"},"audio_names":{"external.mp3":"外部声音"},"future":{"keep":"external"}}"#,
                to: fixture.manifest)
            expect(
                fixture.recorder.requests.count == scansBeforeFinalObservation,
                "[129-GAP-RED] adoption test 不得在 active mutation 内自行 await shared refresh")
            gate.release()

            let result = await task.value
            guard case .adoptionOrphan(let imported, let failure) = result else {
                expect(false, "[129-GAP-RED] snapshot-drift adoption 必须返回 orphan")
                return
            }
            expect(
                failure == .targetChanged && !imported.fileName.isEmpty,
                "[129-GAP-RED] adoption final bind 必须比较 captured/current snapshotRevision")
            expect(
                gapManifestEvent(fixture.manifest, event: "stop") == "external.mp3"
                    && gapManifestAudioName(fixture.manifest, file: "external.mp3") == "外部声音"
                    && gapManifestFuture(fixture.manifest, key: "keep") == "external",
                "[129-GAP-RED] adoption snapshot drift 必须保留旧 binding/name/unknown sibling")
            await gapWaitForScan(fixture.base, after: scansBeforeFinalObservation)
            expect(
                fixture.recorder.requests.count == scansBeforeFinalObservation + 1
                    && fixture.recorder.requests.last?.invalidatedPackIDs == ["workbuddy-pack"],
                "[129-GAP-RED] adoption owner 必须在 release 后主动完成一次 exact shared observation")
        }
    }

    await suite("[129-GAP-RED] adoption manifest lock failure 保留旧 binding/unknown 并报告 orphan") {
        await withTempDirectory { root in
            let gate = GapPostImportGate()
            defer { gate.release() }
            let initialManifest =
                #"{"id":"workbuddy-pack","name":"Lock Fixture","events":{"stop":"stop.mp3"},"audio_names":{"stop.mp3":"旧声音"},"future":{"keep":"lock-sibling"}}"#
            let fixture = gapAdoptionFixture(
                root: root,
                manifestJSON: initialManifest,
                afterFinalImportSample: { gate.pauseWorker() })
            let generationID = UUID()
            _ = fixture.owner.send(
                .activate(
                    .events(
                        route: fixture.route,
                        requestRevision: 340,
                        candidateGenerationID: generationID)))
            await waitForSoundEditorReady(fixture.owner, library: fixture.library)
            guard case .events(let events) = fixture.owner.presentation.mode,
                let permit = events.adoptionPermit
            else {
                expect(false, "[129-GAP-RED] lock fixture 必须取得 adoption permit")
                return
            }
            let source = root.appendingPathComponent("lock-candidate.mp3")
            writeFixture(validMP3ID3Data(), to: source)
            let targetDirectory = fixture.manifest.deletingLastPathComponent()
            let entriesBefore = gapDirectoryEntries(targetDirectory)
            let manifestBefore = try? Data(contentsOf: fixture.manifest)
            let scansBefore = fixture.recorder.requests.count
            let task = Task { @MainActor in
                await fixture.owner.perform(
                    .adoptAICue(
                        candidate: gapCandidate(at: source, generationID: generationID),
                        displayName: try! AICueDisplayName("锁失败候选"),
                        permit: permit))
            }
            guard await gate.waitUntilEntered() else {
                expect(false, "[129-GAP-RED] adoption 必须停在 import 完成/final bind 之前")
                return
            }
            let newEntries = gapDirectoryEntries(targetDirectory).subtracting(entriesBefore)
            guard newEntries.count == 1, let importedFileName = newEntries.first else {
                expect(false, "[129-GAP-RED] lock gate 前必须恰好发布一个 imported candidate")
                return
            }
            let holder = FileLock(path: fixture.base.packsLockFile.path)
            expect(holder.tryLock(), "[129-GAP-RED] test prerequisite 必须真实占住注入 packs.lock")
            gate.release()
            let result = await task.value
            holder.unlock()

            guard case .adoptionOrphan(let imported, let failure) = result else {
                expect(false, "[129-GAP-RED] manifest lock failure 必须返回 typed orphan")
                return
            }
            expect(
                failure == .mutationFailed && imported.fileName == importedFileName,
                "[129-GAP-RED] lock/CAS bind failure 必须携 exact imported orphan identity")
            expect(
                (try? Data(contentsOf: fixture.manifest)) == manifestBefore
                    && gapManifestEvent(fixture.manifest, event: "stop") == "stop.mp3"
                    && gapManifestAudioName(fixture.manifest, file: "stop.mp3") == "旧声音"
                    && gapManifestFuture(fixture.manifest, key: "keep") == "lock-sibling",
                "[129-GAP-RED] bind lock failure 必须保留旧 binding/name/unknown fields")
            expect(
                regularFileExists(at: targetDirectory.appendingPathComponent(imported.fileName)),
                "[129-GAP-RED] bind failure 不得伪造 imported candidate rollback")
            await gapWaitForScan(fixture.base, after: scansBefore)
            expect(
                fixture.recorder.requests.count == scansBefore + 1
                    && fixture.recorder.requests.last?.invalidatedPackIDs == ["workbuddy-pack"],
                "[129-GAP-RED] adoption changedDespiteFailure 必须 exact refresh 一次")
            expect(
                fixture.owner.presentation.activities.contains {
                    $0.kind == .adoptAICue
                        && $0.phase
                            == .orphan(fileName: imported.fileName, failure: .mutationFailed)
                }
                    && fixture.owner.presentation.pendingAnnouncement?.kind
                        == .operation(kind: .adoptAICue, completion: .orphan(.mutationFailed)),
                "[129-GAP-RED] bind failure 必须在 presentation/announcement 报告 semantic orphan")
        }
    }

    await suite("[129-GAP-RED] accepted sync action 在 writer 前遇到 A→B→A 必须拒绝") {
        await withTempDirectory { root in
            let fixture = makeSoundEditorFixture(root: root, packIDs: ["pack-a", "pack-b"])
            let owner = fixture.owner
            let contextA = SoundPacksEditorContext.sounds(
                route: .overview,
                requestRevision: 350)
            _ = owner.send(.activate(contextA))
            await waitForSoundEditorReady(owner, library: fixture.library)
            guard case .sounds(let sounds) = owner.presentation.mode,
                let useB = sounds.packs.first(where: { $0.id == "pack-b" })?.useAction,
                case .accepted(let operationID) = owner.send(.invoke(useB))
            else {
                expect(false, "[129-GAP-RED] sync epoch fixture 必须 accepted use-B")
                return
            }
            let configBefore = try? Data(contentsOf: fixture.configFile)
            let scansBefore = fixture.recorder.requests.count
            expect(
                owner.presentation.activities.contains {
                    $0.operationID == operationID && $0.kind == .use && $0.phase == .busy
                },
                "[129-GAP-RED] accepted sync action 必须先在同栈发布 busy")

            _ = owner.send(.activate(.sounds(route: .overview, requestRevision: 351)))
            _ = owner.send(.activate(contextA))
            await owner.waitForScheduledOperationExitForTesting(operationID)

            expect(
                owner.presentation.activities.first(where: { $0.operationID == operationID })?
                    .phase == .failed(.staleAction),
                "[129-GAP-RED] context A→B→A 必须在 writer 前按 actionEpoch settle stale")
            expect(
                (try? Data(contentsOf: fixture.configFile)) == configBefore,
                "[129-GAP-RED] stale accepted sync operation 必须零 config bytes 变化")
            expect(
                fixture.recorder.requests.count == scansBefore,
                "[129-GAP-RED] stale config-only sync operation 必须零 invalidation/scan")
        }
    }
}

@MainActor
private func gapImportPermit(
    owner: SoundPacksEditorOwner,
    bindTo event: Event?
) -> SoundPackImportPermit? {
    guard case .sounds(let sounds) = owner.presentation.mode else { return nil }
    let action =
        event.flatMap { target in
            sounds.eventRows.first(where: { $0.event == target })?.importAction
        } ?? sounds.requestImportAction
    guard let action,
        case .nativeEffect(.selectAudioFiles(let permit, let permittedEvent)) =
            owner.send(.invoke(action)),
        permittedEvent == event
    else { return nil }
    return permit
}

private struct GapAdoptionFixture {
    let base: SoundEditorFixture
    let route: EventSettingsWindowRoute
    let manifest: URL

    var owner: SoundPacksEditorOwner { base.owner }
    var library: SoundPackLibrary { base.library }
    var recorder: SoundEditorScanRecorder { base.recorder }
}

@MainActor
private func gapAdoptionFixture(
    root: URL,
    manifestJSON: String? = nil,
    durationProbe: (any AudioDurationProbing)? = nil,
    afterFinalImportSample: (@Sendable () -> Void)? = nil
) -> GapAdoptionFixture {
    let base = makeSoundEditorFixture(
        root: root,
        packIDs: ["global-pack", "workbuddy-pack"],
        manifestJSONByPackID: manifestJSON.map { ["workbuddy-pack": $0] } ?? [:],
        durationProbe: durationProbe,
        config: ClaudioConfig(
            selectedPack: "global-pack",
            surfaceOverrides: [
                HostSurfaceID.workBuddy.rawValue: SurfaceSoundOverride(
                    selectedPack: "workbuddy-pack")
            ]),
        afterFinalImportCancellationSampleForTesting: afterFinalImportSample)
    return GapAdoptionFixture(
        base: base,
        route: EventSettingsWindowRoute(scope: .surface(.workBuddy), event: .stop),
        manifest: root.appendingPathComponent("packs/workbuddy-pack/manifest.json"))
}

private func gapCandidate(at fileURL: URL, generationID: UUID) -> AICueCandidate {
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

private func gapIsPreImportRejection(_ result: SoundPacksEditorOperationResult) -> Bool {
    guard case .rejected(let failure) = result else { return false }
    return failure == .stalePermit || failure == .packUnavailable || failure == .targetChanged
}

private func gapDirectoryEntries(_ directory: URL) -> Set<String> {
    Set((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
}

private func gapManifestObject(_ file: URL) -> [String: Any]? {
    guard let data = try? Data(contentsOf: file) else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
}

private func gapManifestEvent(_ file: URL, event: String) -> String? {
    (gapManifestObject(file)?["events"] as? [String: String])?[event]
}

private func gapManifestAudioName(_ file: URL, file audioFile: String) -> String? {
    (gapManifestObject(file)?["audio_names"] as? [String: String])?[audioFile]
}

private func gapManifestFuture(_ file: URL, key: String) -> String? {
    (gapManifestObject(file)?["future"] as? [String: String])?[key]
}

@MainActor
private func gapWaitForScan(_ fixture: SoundEditorFixture, after count: Int) async {
    await waitForSoundEditorScanCount(fixture.recorder, atLeast: count + 1)
    await fixture.library.waitUntilIdleForTesting()
}

private final class GapCountingDurationProbe: AudioDurationProbing, @unchecked Sendable {
    private let lock = NSLock()
    private let duration: TimeInterval?
    private var calls = 0

    init(duration: TimeInterval?) {
        self.duration = duration
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    func probeDuration(of _: URL) -> TimeInterval? {
        lock.lock()
        calls += 1
        lock.unlock()
        return duration
    }
}

private final class GapDurationGate: AudioDurationProbing, @unchecked Sendable {
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

    private var hasEntered: Bool {
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

private final class GapPostImportGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var entered = false
    private var released = false

    func pauseWorker() {
        condition.lock()
        entered = true
        condition.broadcast()
        while !released { condition.wait() }
        condition.unlock()
    }

    private var hasEntered: Bool {
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
