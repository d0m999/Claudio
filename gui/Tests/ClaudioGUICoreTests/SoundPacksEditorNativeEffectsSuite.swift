import ClaudioCore
import ClaudioGUICore
import Foundation
import SoundPacksWindow

@MainActor
func runSoundPacksEditorNativeEffectsSuites() async {
    await suite("Sound editor native effects：picker 模式、permit 与取消保持一条 typed flow") {
        await withTempDirectory { root in
            let fixture = makeSoundEditorFixture(root: root, packIDs: ["pack-a"])
            let owner = fixture.owner
            _ = owner.send(.activate(.sounds(route: .overview, requestRevision: 601)))
            await waitForSoundEditorReady(owner, library: fixture.library)
            await waitForSoundEditorInventory(owner)

            let first = root.appendingPathComponent("first.mp3")
            let second = root.appendingPathComponent("second.wav")
            let adapter = RecordingSoundPacksEditorNativeEffectsAdapter(
                pickerResults: [[first, second], []])
            let dispatcher = SoundPacksEditorNativeEffectsDispatcher(adapter: adapter)

            guard case .sounds(let sounds) = owner.presentation.mode,
                let genericAction = sounds.requestImportAction,
                case .nativeEffect(let genericEffect) = owner.send(.invoke(genericAction)),
                case .importAudio(let genericPermit, let genericSources, let genericEvent)? =
                    dispatcher.dispatch(genericEffect)
            else {
                expect(false, "generic import 必须经 native effect 产生 typed operation")
                return
            }
            expect(
                genericSources == [first, second] && genericEvent == nil,
                "generic picker 必须保持多选 URL 与 nil Event")

            guard case .sounds(let refreshed) = owner.presentation.mode,
                let eventAction = refreshed.eventRows.first(where: { $0.event == .stop })?
                    .importAction,
                case .nativeEffect(let eventEffect) = owner.send(.invoke(eventAction)),
                case .importAudio(let eventPermit, let eventSources, let event)? =
                    dispatcher.dispatch(eventEffect)
            else {
                expect(false, "Event import 必须经 native effect 产生 typed cancel operation")
                return
            }
            expect(
                eventSources.isEmpty && event == .stop,
                "picker cancel 必须保留 Event 并交回 empty operation 消费 permit")
            expect(
                genericPermit != eventPermit && adapter.pickerModes == [true, false],
                "generic/Event picker 必须各 dispatch 一次并使用独立 permit")
            let cancelled = await owner.perform(
                .importAudio(
                    permit: eventPermit,
                    sources: eventSources,
                    bindTo: event))
            expect(
                cancelled == .rejected(.cancelled),
                "picker cancel 必须消费 permit 并返回 typed cancelled")
            expect(
                await owner.perform(
                    .importAudio(permit: eventPermit, sources: [], bindTo: event))
                    == .rejected(.stalePermit),
                "picker cancel 的 permit 必须 single-use")
        }
    }

    await suite("Sound editor native effects：preview、stop 与 Finder 各 exact once") {
        await withTempDirectory { root in
            let fixture = makeSoundEditorFixture(root: root, packIDs: ["pack-a"])
            let owner = fixture.owner
            _ = owner.send(.activate(.sounds(route: .overview, requestRevision: 602)))
            await waitForSoundEditorReady(owner, library: fixture.library)
            await waitForSoundEditorInventory(owner)
            guard case .sounds(let sounds) = owner.presentation.mode,
                let stopRow = sounds.eventRows.first(where: { $0.event == .stop }),
                let previewAction = stopRow.previewAction,
                case .nativeEffect(let previewEffect) = owner.send(.invoke(previewAction)),
                case .sounds(let afterPreview) = owner.presentation.mode,
                case .nativeEffect(let stopEffect) = owner.send(
                    .invoke(afterPreview.stopPreviewAction)),
                case .sounds(let afterStop) = owner.presentation.mode,
                let revealAction = afterStop.selectedPack?.revealAction,
                case .nativeEffect(let revealEffect) = owner.send(.invoke(revealAction))
            else {
                expect(false, "ready Sounds presentation 必须提供 preview/stop/reveal effects")
                return
            }

            let adapter = RecordingSoundPacksEditorNativeEffectsAdapter()
            let dispatcher = SoundPacksEditorNativeEffectsDispatcher(adapter: adapter)
            expect(dispatcher.dispatch(previewEffect) == nil, "preview 不产生 domain operation")
            expect(dispatcher.dispatch(stopEffect) == nil, "stop 不产生 domain operation")
            expect(dispatcher.dispatch(revealEffect) == nil, "reveal 不产生 domain operation")
            expect(
                adapter.playRequests.count == 1
                    && adapter.stopCount == 1
                    && adapter.revealRequests
                        == [root.appendingPathComponent("packs/pack-a", isDirectory: true)],
                "adapter 必须原样且 exact once 执行 owner 已重验的 native targets")

            let _: any SoundPacksEditorNativeEffectsAdapter =
                SystemSoundPacksEditorNativeEffectsAdapter()
        }
    }

    await suite("Sound editor native effects：drop 在 suspension 前取得独立 single-use permit") {
        await withTempDirectory { root in
            let fixture = makeSoundEditorFixture(root: root, packIDs: ["pack-a"])
            let owner = fixture.owner
            _ = owner.send(.activate(.sounds(route: .overview, requestRevision: 603)))
            await waitForSoundEditorReady(owner, library: fixture.library)
            await waitForSoundEditorInventory(owner)

            guard case .sounds(let sounds) = owner.presentation.mode,
                let importAction = sounds.eventRows.first(where: { $0.event == .stop })?
                    .importAction,
                case .importPermit(let permit, let bindTo) = owner.send(
                    .prepareDrop(importAction))
            else {
                expect(false, "drop 必须从 owner 取得不触发 picker 的 typed permit")
                return
            }
            expect(bindTo == .stop, "drop permit 必须保留 owner-signed Event target")
            expect(
                await owner.perform(
                    .importAudio(permit: permit, sources: [], bindTo: bindTo))
                    == .rejected(.cancelled),
                "provider 取消必须消费 permit、返回 typed cancelled 且不制造 mutation")
            expect(
                await owner.perform(
                    .importAudio(permit: permit, sources: [], bindTo: bindTo))
                    == .rejected(.stalePermit),
                "drop permit 必须 single-use")
        }
    }

    await suite("Sound editor native effects：foreground import follow-up exact once，取消仍消费 permit") {
        await withTempDirectory { root in
            let fixture = makeSoundEditorFixture(root: root, packIDs: ["pack-a"])
            let owner = fixture.owner
            let source = root.appendingPathComponent("new.mp3")
            writeFixture(validMP3ID3Data(), to: source)
            _ = owner.send(.activate(.sounds(route: .overview, requestRevision: 604)))
            await waitForSoundEditorReady(owner, library: fixture.library)
            await waitForSoundEditorInventory(owner)

            let adapter = RecordingSoundPacksEditorNativeEffectsAdapter(
                pickerResults: [[source], []])
            let dispatcher = SoundPacksEditorNativeEffectsDispatcher(adapter: adapter)
            guard case .sounds(let sounds) = owner.presentation.mode,
                let importAction = sounds.requestImportAction,
                case .nativeEffect(let selectedEffect) = owner.send(.invoke(importAction))
            else {
                expect(false, "foreground import 必须先产生 picker effect")
                return
            }
            dispatcher.consume(.nativeEffect(selectedEffect), owner: owner)
            await dispatcher.waitForOperationsToFinishForTesting()
            expect(
                adapter.pickerModes == [true]
                    && adapter.playRequests.count == 1
                    && adapter.playRequests[0].fileURL.lastPathComponent == "new.mp3"
                    && adapter.playRequests[0].volume == 0.37,
                "foreground success 必须只执行一次 owner-signed preview URL/volume")
            await waitForSoundEditorReady(owner, library: fixture.library)
            await waitForSoundEditorInventory(owner)

            guard case .sounds(let refreshed) = owner.presentation.mode,
                let cancelAction = refreshed.requestImportAction,
                case .nativeEffect(let cancelledEffect) = owner.send(.invoke(cancelAction)),
                case .selectAudioFiles(let cancelledPermit, let bindTo) = cancelledEffect
            else {
                expect(false, "第二次 picker 必须提供可验证的取消 permit")
                return
            }
            dispatcher.consume(.nativeEffect(cancelledEffect), owner: owner)
            await dispatcher.waitForOperationsToFinishForTesting()
            expect(
                adapter.pickerModes == [true, true] && adapter.playRequests.count == 1,
                "picker 取消必须 exact once 执行 empty perform 且不触发 preview")
            expect(
                await owner.perform(
                    .importAudio(permit: cancelledPermit, sources: [], bindTo: bindTo))
                    == .rejected(.stalePermit),
                "dispatcher 必须消费取消 permit")
        }
    }

    await suite("Sound editor native effects：drop 无 provider 仍精确消费 owner permit") {
        await withTempDirectory { root in
            let fixture = makeSoundEditorFixture(root: root, packIDs: ["pack-a"])
            let owner = fixture.owner
            _ = owner.send(.activate(.sounds(route: .overview, requestRevision: 605)))
            await waitForSoundEditorReady(owner, library: fixture.library)
            await waitForSoundEditorInventory(owner)
            guard case .sounds(let sounds) = owner.presentation.mode,
                let importAction = sounds.eventRows.first(where: { $0.event == .stop })?
                    .importAction
            else {
                expect(false, "drop 必须有 owner-signed import action")
                return
            }
            let presentationBefore = owner.presentation
            let statusesBefore = sounds.windowStatuses
            let scansBefore = fixture.recorder.requests.count
            let dispatcher = SoundPacksEditorNativeEffectsDispatcher(
                adapter: RecordingSoundPacksEditorNativeEffectsAdapter())

            dispatcher.consumeDrop([], action: importAction, owner: owner)
            await dispatcher.waitForOperationsToFinishForTesting()

            expect(
                owner.send(.prepareDrop(importAction)) == .rejected(.staleAction),
                "无 provider 也必须让 dispatcher 取得并消费单次 permit")
            guard case .sounds(let refreshed) = owner.presentation.mode,
                let retryAction = refreshed.eventRows.first(where: { $0.event == .stop })?
                    .importAction
            else {
                expect(false, "typed cancel 后必须重签可再次使用的 import action")
                return
            }
            expect(
                owner.presentation.revision > presentationBefore.revision
                    && owner.presentation.activities == presentationBefore.activities
                    && owner.presentation.pendingAnnouncement
                        == presentationBefore.pendingAnnouncement
                    && refreshed.windowStatuses == statusesBefore
                    && fixture.recorder.requests.count == scansBefore,
                "typed cancel 只可重签 capability，不得制造 activity/status/announcement 或 shared scan")
            expect(
                {
                    if case .importPermit(_, .stop) = owner.send(.prepareDrop(retryAction)) {
                        return true
                    }
                    return false
                }(),
                "取消后重新渲染的 drop action 必须能再签一次 permit")
        }
    }

    await suite("Sound editor native lifecycle：Settings close 与 Sounds disappear 共享一次 stop") {
        await withTempDirectory { root in
            let fixture = makeSoundEditorFixture(root: root, packIDs: ["pack-a"])
            let owner = fixture.owner
            _ = owner.send(.activate(.sounds(route: .overview, requestRevision: 606)))
            await waitForSoundEditorReady(owner, library: fixture.library)
            await waitForSoundEditorInventory(owner)

            let adapter = RecordingSoundPacksEditorNativeEffectsAdapter()
            let dispatcher = SoundPacksEditorNativeEffectsDispatcher(adapter: adapter)
            guard case .sounds(let sounds) = owner.presentation.mode,
                let previewAction = sounds.eventRows.first(where: { $0.event == .stop })?
                    .previewAction
            else {
                expect(false, "ready Sounds 必须提供 owner-signed preview action")
                return
            }
            dispatcher.consume(owner.send(.invoke(previewAction)), owner: owner)
            expect(adapter.playRequests.count == 1, "测试前置必须由同一 adapter 开始一次试听")

            dispatcher.handleLifecycle(.settingsWindowWillClose, owner: owner)
            expect(adapter.stopCount == 1, "window close 必须由同一 dispatcher exact once 停止试听")
            expect(
                owner.presentation.mode == .inactive,
                "window close 必须在 native stop 后把 editor owner 置为 inactive")

            dispatcher.handleLifecycle(.settingsWindowWillClose, owner: owner)
            dispatcher.handleLifecycle(.soundsViewDisappeared, owner: owner)
            expect(
                adapter.stopCount == 1 && owner.presentation.mode == .inactive,
                "重复 close 与随后 SwiftUI disappear 不得重放已消费的 stop capability")

            _ = owner.send(
                .activate(
                    .events(
                        route: EventSettingsWindowRoute(scope: .global, event: .stop),
                        requestRevision: 607)))
            dispatcher.handleLifecycle(.soundsViewDisappeared, owner: owner)
            expect(
                {
                    if case .events = owner.presentation.mode { return true }
                    return false
                }() && adapter.stopCount == 1,
                "迟到的 Sounds disappear 不得停用已经接管同一 owner 的 Events context")
            dispatcher.handleLifecycle(.settingsWindowWillClose, owner: owner)
            expect(
                owner.presentation.mode == .inactive && adapter.stopCount == 1,
                "Settings close 必须停用 Events context，但不得伪造不存在的第二次 playback stop")
        }
    }

    await suite("Sound editor native effects：Events 只执行 owner-signed preview 且生命周期有序") {
        await withTempDirectory { root in
            let fixture = makeSoundEditorFixture(root: root, packIDs: ["pack-a"])
            let owner = fixture.owner
            _ = owner.send(
                .activate(
                    .events(
                        route: EventSettingsWindowRoute(scope: .global, event: .stop),
                        requestRevision: 608)))
            _ = await waitForSoundEditorReady(owner, library: fixture.library)
            guard case .events(let events) = owner.presentation.mode,
                let previewAction = events.eventAccess.first(where: { $0.event == .stop })?
                    .previewAction
            else {
                expect(false, "fresh Events presentation 必须提供 owner-signed preview action")
                return
            }
            let adapter = RecordingSoundPacksEditorNativeEffectsAdapter(playbackDuration: 0.25)
            let dispatcher = SoundPacksEditorNativeEffectsDispatcher(adapter: adapter)

            expect(
                dispatcher.playPreview(previewAction, owner: owner) == 0.25,
                "Events preview 必须由 native adapter 回传真实播放时长")
            expect(
                adapter.playRequests.map(\.fileURL) == [
                    root.appendingPathComponent("packs/pack-a/stop.mp3")
                ],
                "view 不得派生 URL；dispatcher 只能执行 owner action 产生的 exact target")
            expect(
                dispatcher.playPreview(previewAction, owner: owner) == nil,
                "Events preview action 必须 single-use")

            _ = owner.send(
                .activate(
                    .events(
                        route: EventSettingsWindowRoute(
                            scope: .global,
                            event: .notification),
                        requestRevision: 609)))
            dispatcher.stopPreview(owner: owner)
            expect(
                adapter.stopCount == 1,
                "同页 route/Event 已切换后仍必须由 retained dispatcher 停掉旧试听")
            expect(
                {
                    guard case .events(let current) = owner.presentation.mode else { return false }
                    return current.route.event == .notification
                }(),
                "route 切换 stop 不得 retire 已接管的新 Events context")

            dispatcher.handleLifecycle(.eventsViewDisappeared, owner: owner)
            expect(
                adapter.stopCount == 1 && owner.presentation.mode == .inactive,
                "Events disappear 必须先消费自己的 stop action 再停用 context")

            _ = owner.send(
                .activate(
                    .events(
                        route: EventSettingsWindowRoute(scope: .global, event: .stop),
                        requestRevision: 609)))
            _ = owner.send(.activate(.sounds(route: .overview, requestRevision: 610)))
            dispatcher.handleLifecycle(.eventsViewDisappeared, owner: owner)
            expect(
                {
                    if case .sounds = owner.presentation.mode { return true }
                    return false
                }() && adapter.stopCount == 1,
                "迟到的 Events disappear 不得 clobber 已接管 owner 的 Sounds context")
        }
    }

    await suite("Sound editor native effects：AI candidate 与 Events 共用 retained playback lifecycle")
    {
        await withTempDirectory { root in
            let fixture = makeSoundEditorFixture(root: root, packIDs: ["pack-a"])
            let candidateURL = root.appendingPathComponent("candidate.mp3")
            let generationID = UUID()
            let candidate = AICueCandidate(
                id: UUID(),
                variant: .clear,
                asset: AICueTemporaryAudioAsset(
                    fileURL: candidateURL,
                    byteCount: 12,
                    sniffedFormat: .mp3),
                durationMilliseconds: 250,
                mediaType: "audio/mpeg",
                provenance: AICueCandidateProvenance(
                    providerID: .elevenLabs,
                    profileID: .elevenLabsGlobal,
                    modelID: "fixture",
                    generationID: generationID,
                    requestOrdinal: 1,
                    providerRequestID: nil))
            let adapter = RecordingSoundPacksEditorNativeEffectsAdapter(playbackDuration: 0.25)
            let dispatcher = SoundPacksEditorNativeEffectsDispatcher(adapter: adapter)

            expect(
                dispatcher.playAICueCandidate(candidate, volume: 0.6) == 0.25,
                "candidate 必须经同一 native adapter 开始播放并返回时长")
            expect(
                adapter.playRequests
                    == [.init(fileURL: candidateURL, volume: 0.6)],
                "candidate URL/volume 必须原样进入 retained playback adapter")

            dispatcher.handleLifecycle(.settingsWindowWillClose, owner: fixture.owner)
            dispatcher.handleLifecycle(.settingsWindowWillClose, owner: fixture.owner)
            expect(
                adapter.stopCount == 1,
                "即使 editor context 已 inactive，Settings close 也必须 exact once 停止 candidate")
        }
    }
}

@MainActor
private final class RecordingSoundPacksEditorNativeEffectsAdapter:
    SoundPacksEditorNativeEffectsAdapter
{
    struct PlayRequest: Equatable {
        let fileURL: URL
        let volume: Double
    }

    private var pickerResults: [[URL]]
    private(set) var pickerModes: [Bool] = []
    private(set) var playRequests: [PlayRequest] = []
    private(set) var stopCount = 0
    private(set) var revealRequests: [URL] = []

    private let playbackDuration: TimeInterval?

    init(pickerResults: [[URL]] = [], playbackDuration: TimeInterval? = 1) {
        self.pickerResults = pickerResults
        self.playbackDuration = playbackDuration
    }

    func selectAudioFiles(allowsMultipleSelection: Bool) -> [URL] {
        pickerModes.append(allowsMultipleSelection)
        return pickerResults.isEmpty ? [] : pickerResults.removeFirst()
    }

    func playAudio(fileURL: URL, volume: Double) -> TimeInterval? {
        playRequests.append(PlayRequest(fileURL: fileURL, volume: volume))
        return playbackDuration
    }

    func stopAudio() {
        stopCount += 1
    }

    func revealInFinder(fileURL: URL) {
        revealRequests.append(fileURL)
    }
}
