import ClaudioCore
import ClaudioGUICore
import Foundation

@MainActor
func runAICueAdoptionSuites() async {
    suite("legacy Surface adoption is retired; pack-scoped adoption owns editing") {
        expect(
            aiCueAdoptionEligibility(
                surface: .codex, event: .stop, selectedPackID: "pack",
                config: ClaudioConfig(selectedPack: "pack"), packCards: [], builtinPackIDs: [])
                == .ineligible(.writesStopped),
            "stale source route cannot mutate a pack or hidden sound settings")
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
