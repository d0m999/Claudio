import ClaudioCore
import ClaudioGUICore
import Foundation

private final class AICueBlockingDurationProbe: AudioDurationProbing, @unchecked Sendable {
    private let entered = DispatchSemaphore(value: 0)
    private let resume = DispatchSemaphore(value: 0)

    func probeDuration(of fileURL: URL) -> TimeInterval? {
        entered.signal()
        resume.wait()
        return 1
    }

    func waitUntilEntered() -> Bool {
        entered.wait(timeout: .now() + 5) == .success
    }

    func allowCompletion() { resume.signal() }
}

@MainActor
func runAICueAdoptionSuites() async {
    suite("AI 提示音采用资格：只允许明确 surface 的独立、可编辑、有效用户包") {
        let cards = ["global-pack", "workbuddy-pack", "codex-pack", "claude-pack"].map {
            aiCuePackCard(id: $0)
        }
        let isolated = ClaudioConfig(
            selectedPack: "global-pack",
            surfaceOverrides: [
                HostSurfaceID.workBuddy.rawValue: SurfaceSoundOverride(
                    selectedPack: "workbuddy-pack"),
                HostSurfaceID.codex.rawValue: SurfaceSoundOverride(selectedPack: "codex-pack"),
                HostSurfaceID.claudeCode.rawValue: SurfaceSoundOverride(
                    selectedPack: "claude-pack"),
            ])

        expect(
            aiCueAdoptionEligibility(
                surface: nil,
                event: .stop,
                selectedPackID: "global-pack",
                config: isolated,
                packCards: cards,
                builtinPackIDs: []) == .ineligible(.surfaceRequired),
            "Global 不是可伪装成来源的采用目标")
        expect(
            aiCueAdoptionEligibility(
                surface: .chatGPTDesktopAX,
                event: .stop,
                selectedPackID: "workbuddy-pack",
                config: isolated,
                packCards: cards,
                builtinPackIDs: []) == .ineligible(.invalidSurface(.chatGPTDesktopAX)),
            "诊断身份不得获得 AI 写权限")
        expect(
            aiCueAdoptionEligibility(
                surface: .workBuddy,
                event: .stop,
                selectedPackID: "workbuddy-pack",
                config: isolated,
                packCards: cards,
                builtinPackIDs: [])
                == .eligible(
                    try! AICueAdoptionTarget(
                        surface: .workBuddy,
                        event: .stop,
                        packID: "workbuddy-pack")),
            "独立用户包必须得到显式三元采用目标")

        var shared = isolated
        shared.surfaceOverrides[HostSurfaceID.codex.rawValue] = SurfaceSoundOverride(
            selectedPack: "workbuddy-pack")
        expect(
            aiCueAdoptionEligibility(
                surface: .workBuddy,
                event: .stop,
                selectedPackID: "workbuddy-pack",
                config: shared,
                packCards: cards,
                builtinPackIDs: [])
                == .ineligible(.sharedPack(consumers: [.surface(.codex)])),
            "其他来源有效选择同一个包时必须 fail closed")
        expect(
            aiCueAdoptionEligibility(
                surface: .workBuddy,
                event: .stop,
                selectedPackID: "workbuddy-pack",
                config: isolated,
                packCards: cards,
                builtinPackIDs: ["workbuddy-pack"])
                == .ineligible(.builtinReadOnly(packID: "workbuddy-pack")),
            "内置包不能直接采用生成音频")
    }

    suite("AI 提示音 manifest：事件绑定与显示名在一次原子 RMW 中发布并保留未知字段") {
        withTempDirectory { root in
            let packs = root.appendingPathComponent("packs", isDirectory: true)
            let pack = packs.appendingPathComponent("my-pack", isDirectory: true)
            let manifest = pack.appendingPathComponent("manifest.json")
            writeFixture(
                #"{"id":"my-pack","name":"我的提示音","future":{"keep":true},"events":{"notification":"old.mp3"},"audio_names":{"other.mp3":"木琴完成"}}"#,
                to: manifest)
            writeFixture(validMP3ID3Data(), to: pack.appendingPathComponent("new.mp3"))
            let environment = makeAudioImportEnvironment(userPacksDirectory: packs)

            let result = bindAICueToManifest(
                event: .stop,
                fileName: "new.mp3",
                displayName: try! AICueDisplayName("木琴完成"),
                packID: "my-pack",
                environment: environment)
            guard case .success(let outcome) = result else {
                expect(false, "合法 AI 绑定必须成功")
                return
            }
            expect(outcome.finalDisplayName == "木琴完成 2", "同名显示名必须原子分配可见后缀")
            let json = try! JSONSerialization.jsonObject(with: Data(contentsOf: manifest))
                as! [String: Any]
            let events = json["events"] as! [String: String]
            let names = json["audio_names"] as! [String: String]
            expect(events[Event.stop.manifestKey] == "new.mp3", "事件必须指向新文件")
            expect(events[Event.notification.manifestKey] == "old.mp3", "兄弟事件必须保留")
            expect(names["new.mp3"] == "木琴完成 2", "最终显示名必须与采用项一起持久化")
            expect((json["future"] as? [String: Bool])?["keep"] == true, "未知顶层字段必须保留")

            let rows = packCoverage(
                packID: "my-pack",
                config: ClaudioConfig(selectedPack: "my-pack"),
                environment: environment)
            expect(
                rows.first(where: { $0.event == .stop })?.audioDisplayName == "木琴完成 2",
                "重开窗口后的事件行必须从 manifest 恢复提示音名称")
        }
    }

    suite("AI 提示音 manifest：可见名称后缀在合法 manifest 上不会饱和碰撞") {
        withTempDirectory { root in
            let packs = root.appendingPathComponent("packs", isDirectory: true)
            let pack = packs.appendingPathComponent("my-pack", isDirectory: true)
            let manifest = pack.appendingPathComponent("manifest.json")
            var names: [String: String] = ["existing-1.mp3": "提示音"]
            for ordinal in 2...9_999 {
                names["existing-\(ordinal).mp3"] = "提示音 \(ordinal)"
            }
            let manifestData = try! JSONSerialization.data(
                withJSONObject: [
                    "id": "my-pack",
                    "events": ["notification": "old.mp3"],
                    "audio_names": names,
                ],
                options: [.sortedKeys])
            expect(manifestData.count < 1_024 * 1_024, "fixture 必须仍是合法、有界 manifest")
            writeFixture(manifestData, to: manifest)
            writeFixture(validMP3ID3Data(), to: pack.appendingPathComponent("new.mp3"))

            let result = bindAICueToManifest(
                event: .stop,
                fileName: "new.mp3",
                displayName: try! AICueDisplayName("提示音"),
                packID: "my-pack",
                environment: makeAudioImportEnvironment(userPacksDirectory: packs))
            guard case .success(let outcome) = result else {
                expect(false, "有界但包含大量名称的 manifest 仍必须可安全分配名称")
                return
            }
            expect(outcome.finalDisplayName == "提示音 10000", "后缀分配不得在 9999 处回退成重复名称")
        }
    }

    suite("AI 提示音 manifest：损坏 audio_names 时旧事件绑定一个字节都不改") {
        withTempDirectory { root in
            let packs = root.appendingPathComponent("packs", isDirectory: true)
            let pack = packs.appendingPathComponent("my-pack", isDirectory: true)
            let manifest = pack.appendingPathComponent("manifest.json")
            writeFixture(
                #"{"id":"my-pack","events":{"stop":"old.mp3"},"audio_names":[]}"#,
                to: manifest)
            writeFixture(validMP3ID3Data(), to: pack.appendingPathComponent("new.mp3"))
            let before = try! Data(contentsOf: manifest)
            let result = bindAICueToManifest(
                event: .stop,
                fileName: "new.mp3",
                displayName: try! AICueDisplayName("新声音"),
                packID: "my-pack",
                environment: makeAudioImportEnvironment(userPacksDirectory: packs))
            guard case .failure(.manifestUnreadable) = result else {
                expect(false, "损坏 audio_names 必须显式失败")
                return
            }
            expect(try! Data(contentsOf: manifest) == before, "失败时旧绑定和未知字节必须原样保留")
        }
    }

    await suite("AI 提示音采用闭环：导入与命名绑定全部成功后才替换旧声音") {
        await withTempDirectory { root in
            let fixture = aiCueAdoptionFixture(root: root, durationProbe: StubDurationProbe(fixedDuration: 1))
            let target = try! fixture.model.captureAICueAdoptionTarget(for: .stop).get()
            let candidate = aiCueCandidate(at: fixture.candidateFile)
            let result = await fixture.model.adoptAICue(
                candidate: candidate,
                displayName: try! AICueDisplayName("小猫两声"),
                target: target)
            guard case .success(let outcome) = result else {
                expect(false, "完整导入与绑定必须成功")
                return
            }
            expect(outcome.finalDisplayName == "小猫两声", "采用结果必须返回最终持久化名称")
            let json = try! JSONSerialization.jsonObject(
                with: Data(contentsOf: fixture.targetManifest)) as! [String: Any]
            let events = json["events"] as! [String: String]
            let names = json["audio_names"] as! [String: String]
            expect(events[Event.stop.manifestKey] == outcome.importedFile.fileName, "成功终态才替换旧事件映射")
            expect(names[outcome.importedFile.fileName] == "小猫两声", "显示名必须绑定采用后的真实文件身份")
        }
    }

    await suite("AI 提示音采用闭环：导入期间目标损坏时旧声音保留，孤儿文件如实返回") {
        await withTempDirectory { root in
            let probe = AICueBlockingDurationProbe()
            let fixture = aiCueAdoptionFixture(root: root, durationProbe: probe)
            let target = try! fixture.model.captureAICueAdoptionTarget(for: .stop).get()
            let candidate = aiCueCandidate(at: fixture.candidateFile)
            let task = Task { @MainActor in
                await fixture.model.adoptAICue(
                    candidate: candidate,
                    displayName: try! AICueDisplayName("竞态提示音"),
                    target: target)
            }
            await Task.yield()
            expect(probe.waitUntilEntered(), "采用必须到达注入的导入时长闸门")
            writeFixture(
                #"{"id":"workbuddy-pack","events":{"stop":"old.mp3"},"audio_names":[]}"#,
                to: fixture.targetManifest)
            probe.allowCompletion()
            let result = await task.value
            guard case .failure(.importedButNotBound(let imported, _)) = result else {
                expect(false, "导入后目标失效必须报告真实 partial state")
                return
            }
            let json = try! JSONSerialization.jsonObject(
                with: Data(contentsOf: fixture.targetManifest)) as! [String: Any]
            let events = json["events"] as! [String: String]
            expect(events[Event.stop.manifestKey] == "old.mp3", "任何绑定失败都必须保留旧声音")
            expect(FileManager.default.fileExists(atPath: imported.destinationURL.path), "已导入的孤儿文件不能被假装回滚或静默删除")
        }
    }
}

private func aiCuePackCard(id: String) -> PackCard {
    PackCard(
        id: id,
        name: id,
        isCC0: false,
        presentEvents: [],
        state: .partial(present: 0, total: Event.allCases.count),
        isSelected: false)
}

private struct AICueAdoptionFixture {
    let model: SoundPacksWindowModel
    let targetManifest: URL
    let candidateFile: URL
}

@MainActor
private func aiCueAdoptionFixture(
    root: URL,
    durationProbe: any AudioDurationProbing
) -> AICueAdoptionFixture {
    let packs = root.appendingPathComponent("packs", isDirectory: true)
    let configFile = root.appendingPathComponent("config.json")
    let config = ClaudioConfig(
        selectedPack: "global-pack",
        surfaceOverrides: [
            HostSurfaceID.workBuddy.rawValue: SurfaceSoundOverride(
                selectedPack: "workbuddy-pack"),
            HostSurfaceID.codex.rawValue: SurfaceSoundOverride(selectedPack: "codex-pack"),
            HostSurfaceID.claudeCode.rawValue: SurfaceSoundOverride(selectedPack: "claude-pack"),
        ])
    writeFixture(try! JSONEncoder().encode(config), to: configFile)
    for id in ["global-pack", "codex-pack", "claude-pack"] {
        writeFixture(
            "{\"id\":\"\(id)\",\"events\":{}}",
            to: packs.appendingPathComponent("\(id)/manifest.json"))
    }
    let targetManifest = packs.appendingPathComponent("workbuddy-pack/manifest.json")
    writeFixture(
        #"{"id":"workbuddy-pack","events":{"stop":"old.mp3"}}"#,
        to: targetManifest)
    writeFixture(validMP3ID3Data(), to: packs.appendingPathComponent("workbuddy-pack/old.mp3"))
    let candidateFile = root.appendingPathComponent("provider-candidate.mp3")
    writeFixture(validMP3ID3Data(), to: candidateFile)
    let environment = AudioImportEnvironment(
        userPacksDirectory: packs,
        durationProbe: durationProbe,
        packsLockFile: injectedPacksLock(under: root))
    let model = SoundPacksWindowModel(
        configFile: configFile,
        lockFile: root.appendingPathComponent("config.lock"),
        environment: environment,
        refreshCoordinator: SoundPacksRefreshCoordinator())
    model.setManagedSurface(.workBuddy)
    return AICueAdoptionFixture(
        model: model,
        targetManifest: targetManifest,
        candidateFile: candidateFile)
}

private func aiCueCandidate(at fileURL: URL) -> AICueCandidate {
    let generationID = UUID()
    return AICueCandidate(
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
            modelID: ElevenLabsAICueRequestCompiler.soundEffectModelID,
            generationID: generationID,
            requestOrdinal: 1,
            providerRequestID: "fixture"))
}
