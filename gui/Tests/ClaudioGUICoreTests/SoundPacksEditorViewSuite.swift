import AppKit
import ClaudioCore
import ClaudioGUICore
import ClaudioLocalization
import SoundPacksWindow
import SwiftUI

@MainActor
func runSoundPacksEditorViewSuites() async {
    await suite("Sound editor view：compiled seam 只接受 owner presentation 与 native adapter") {
        await withTempDirectory { root in
            let status = SoundPacksWindowStatus(
                kind: .factoryRestore,
                severity: .failure,
                revision: 701,
                action: "Restore",
                message: "Retained",
                recovery: .retryFactoryRestores(packIDs: ["pack-a"]))
            let model = SoundPacksWindowModel(
                previewConfig: ClaudioConfig(selectedPack: "pack-a", masterVolume: 0.4),
                packCards: [
                    PackCard(
                        id: "pack-a",
                        name: "Pack A",
                        isCC0: false,
                        presentEvents: [.stop],
                        state: .partial(present: 1, total: Event.allCases.count),
                        isSelected: true)
                ],
                selectedPackID: "pack-a",
                selectedEventRows: Event.allCases.map {
                    EventRow(
                        event: $0,
                        coverage: $0 == .stop
                            ? .present(fileName: "stop.mp3") : .unmapped,
                        enabled: true)
                },
                windowStatuses: [status],
                environment: makeAudioImportEnvironment(
                    userPacksDirectory: root.appendingPathComponent("packs", isDirectory: true)),
                refreshCoordinator: SoundPacksRefreshCoordinator())
            let owner = SoundPacksEditorOwner(
                model: model,
                userPacksDirectory: root.appendingPathComponent("packs", isDirectory: true))
            _ = owner.send(.activate(.sounds(route: .overview, requestRevision: 701)))

            guard case .sounds(let sounds) = owner.presentation.mode else {
                expect(false, "owner 必须发布 Sounds presentation")
                return
            }
            expect(
                sounds.windowStatuses == [status]
                    && sounds.recoveryActions.map(\.packID) == ["pack-a"],
                "持久可见 status 与 recovery action 必须同属 render-ready interface")
            expect(
                sounds.eventRows.first(where: { $0.event == .notification })?
                    .previewAvailability == .unmapped,
                "View 所需的试听可用性必须由 owner 以 render-ready semantic value 提供")

            let dispatcher = SoundPacksEditorNativeEffectsDispatcher(
                adapter: NoOpSoundPacksEditorNativeEffectsAdapter())
            let _: any ObservableObject = dispatcher
            let preferences = ClaudioPreferences(defaults: UserDefaults())
            let view = SoundPacksWindowView(
                editorOwner: owner,
                focusCoordinator: SoundPacksWindowFocusCoordinator(),
                languageStore: preferences,
                nativeEffects: dispatcher)
            let hostingView = NSHostingView(rootView: view)
            hostingView.frame = NSRect(x: 0, y: 0, width: 760, height: 560)
            hostingView.layoutSubtreeIfNeeded()
            expect(
                hostingView.fittingSize.width > 0 && hostingView.fittingSize.height > 0,
                "owner-only production view 必须可由真实 SwiftUI/AppKit seam 编译并挂载")

            let embedded = EmbeddedSoundPacksEditorView(
                editorOwner: owner,
                route: .overview,
                routeRequestRevision: 702,
                languageStore: preferences,
                nativeEffects: dispatcher)
            let embeddedHost = NSHostingView(rootView: embedded)
            embeddedHost.frame = NSRect(x: 0, y: 0, width: 760, height: 560)
            embeddedHost.layoutSubtreeIfNeeded()
            expect(
                embeddedHost.fittingSize.width > 0 && embeddedHost.fittingSize.height > 0,
                "Settings embedded view 必须复用同一 owner/native interface")
        }
    }

    suite("Sound editor gallery：compiled production interface 不需要用户路径") {
        let gallery = SoundPacksWindowStateGalleryView(
            language: .english,
            textSize: .standard)
        let hostingView = NSHostingView(rootView: gallery)
        hostingView.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        hostingView.layoutSubtreeIfNeeded()
        expect(
            hostingView.fittingSize.width > 0 && hostingView.fittingSize.height > 0,
            "Gallery 必须由 production view interface 编译并挂载")
    }

    suite("Sound editor focus：同一 route request 只推进一次，settlement 与重新打开仍推进") {
        var tracker = SoundPacksEditorFocusApplicationTracker()
        let pending = SoundPacksEditorFocusProjection(
            requestRevision: 801,
            routeState: .pendingFreshSnapshot)
        let resolved = SoundPacksEditorFocusProjection(
            requestRevision: 801,
            routeState: .resolved(.overview))
        expect(
            tracker.recordAndShouldApply(pending, force: false),
            "新 route request 必须推进一次 focus")
        expect(
            !tracker.recordAndShouldApply(pending, force: false),
            "activate 后相同 projection 的 onChange 不得重复抢焦点")
        expect(
            tracker.recordAndShouldApply(resolved, force: false),
            "pending→resolved settlement 必须推进一次精确 route focus")
        expect(
            tracker.recordAndShouldApply(resolved, force: true),
            "窗口重新出现时即使 route 未变也必须恢复 initial focus")
    }

    await suite("Sound editor gallery：真实 owner busy fixture 不执行 writer 仍发布写入中状态") {
        await withTempDirectory { root in
            let fixture = makeSoundEditorFixture(root: root, packIDs: ["pack-a", "pack-b"])
            let owner = fixture.owner
            _ = owner.send(.activate(.sounds(route: .overview, requestRevision: 802)))
            await waitForSoundEditorReady(owner, library: fixture.library)
            guard case .sounds(let sounds) = owner.presentation.mode,
                let useAction = sounds.packs.first(where: { $0.id == "pack-b" })?.useAction
            else {
                expect(false, "busy Gallery fixture 必须先取得真实 owner write capability")
                return
            }
            let configBefore = try? Data(contentsOf: fixture.configFile)
            let scansBefore = fixture.recorder.requests.count
            expect(
                owner.freezeAcceptedOperationForStateGalleryFixture(useAction),
                "Gallery 必须经真实 owner accepted transition 构造 deterministic busy")
            for _ in 0..<8 { await Task.yield() }
            expect(
                owner.presentation.activities.contains { $0.kind == .use && $0.phase == .busy },
                "Gallery busy fixture 必须保留 owner presentation 的真实 write-in-progress activity")
            guard case .sounds(let busy) = owner.presentation.mode else {
                expect(false, "busy fixture 必须保留 Sounds presentation")
                return
            }
            expect(
                busy.selectedPack?.id == "pack-a" && busy.selectedPack?.isActiveForScope == true
                    && (try? Data(contentsOf: fixture.configFile)) == configBefore
                    && fixture.recorder.requests.count == scansBefore,
                "同步取消 scheduled Task 后必须保持 selected/config facts 且零 writer、零 refresh")
        }
    }
}

@MainActor
private final class NoOpSoundPacksEditorNativeEffectsAdapter:
    SoundPacksEditorNativeEffectsAdapter
{
    func selectAudioFiles(allowsMultipleSelection: Bool) -> [URL] { [] }
    func playAudio(fileURL: URL, volume: Double) {}
    func stopAudio() {}
    func revealInFinder(fileURL: URL) {}
}
