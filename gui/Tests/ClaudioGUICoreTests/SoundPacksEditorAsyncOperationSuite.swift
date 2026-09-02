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
}
