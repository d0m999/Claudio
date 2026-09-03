import ClaudioCore
import ClaudioGUICore
import Foundation

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

        var globalShared = isolated
        globalShared.selectedPack = "workbuddy-pack"
        expect(
            aiCueAdoptionEligibility(
                surface: .workBuddy,
                event: .stop,
                selectedPackID: "workbuddy-pack",
                config: globalShared,
                packCards: cards,
                builtinPackIDs: [])
                == .ineligible(.sharedPack(consumers: [.global])),
            "Global Sound Defaults 选择目标包时必须保留既有共享检测")

        var diagnosticShared = isolated
        diagnosticShared.surfaceOverrides[HostSurfaceID.chatGPTDesktopAX.rawValue] =
            SurfaceSoundOverride(selectedPack: "workbuddy-pack")
        expect(
            aiCueAdoptionEligibility(
                surface: .workBuddy,
                event: .stop,
                selectedPackID: "workbuddy-pack",
                config: diagnosticShared,
                packCards: cards,
                builtinPackIDs: [])
                == .ineligible(
                    .sharedPack(consumers: [.surface(.chatGPTDesktopAX)])),
            "诊断 Surface 的有效 override 也必须作为 pack-wide 消费者参与隔离审核")

        var multipleSharedConsumers = diagnosticShared
        multipleSharedConsumers.surfaceOverrides[HostSurfaceID.codex.rawValue] =
            SurfaceSoundOverride(selectedPack: "workbuddy-pack")
        expect(
            aiCueAdoptionEligibility(
                surface: .workBuddy,
                event: .stop,
                selectedPackID: "workbuddy-pack",
                config: multipleSharedConsumers,
                packCards: cards,
                builtinPackIDs: [])
                == .ineligible(
                    .sharedPack(
                        consumers: [
                            .surface(.chatGPTDesktopAX),
                            .surface(.codex),
                        ])),
            "共享消费者顺序必须按稳定 Surface token 决定，不能依赖字典迭代")

        var unknownOverride = isolated
        unknownOverride.surfaceOverrides["future-surface"] = SurfaceSoundOverride(
            selectedPack: "unrelated-pack")
        expect(
            aiCueAdoptionEligibility(
                surface: .workBuddy,
                event: .stop,
                selectedPackID: "workbuddy-pack",
                config: unknownOverride,
                packCards: cards,
                builtinPackIDs: []) == .ineligible(.configurationUnavailable),
            "无法分类的未来 override token 必须 fail closed，即使当前值看似未共享目标包")

        var malformedOverride = isolated
        malformedOverride.invalidSurfaceOverrideKeys.insert("future-malformed")
        expect(
            aiCueAdoptionEligibility(
                surface: .workBuddy,
                event: .stop,
                selectedPackID: "workbuddy-pack",
                config: malformedOverride,
                packCards: cards,
                builtinPackIDs: []) == .ineligible(.configurationUnavailable),
            "损坏的原始 override token 必须在任何 pack-wide 写入前 fail closed")

        var malformedOverridesStructure = isolated
        malformedOverridesStructure.surfaceOverridesMalformed = true
        expect(
            aiCueAdoptionEligibility(
                surface: .workBuddy,
                event: .stop,
                selectedPackID: "workbuddy-pack",
                config: malformedOverridesStructure,
                packCards: cards,
                builtinPackIDs: []) == .ineligible(.configurationUnavailable),
            "整体 surface_overrides 结构损坏时必须在任何写入前 fail closed")
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
            let json =
                try! JSONSerialization.jsonObject(with: Data(contentsOf: manifest))
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
