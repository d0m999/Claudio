import AppKit
import ClaudioCore
import ClaudioGUICore
import ClaudioLocalization
import Foundation
import SoundPacksWindow

@MainActor
func runSoundPacksEditorAccessibilityPostingSuites() async {
    suite("SoundPacks editor accessibility：operation semantic renderer 穷尽动作且不泄露目标") {
        let kinds: [SoundPackEditorActivityKind] = [
            .use, .toggleStar, .fork, .importAudio, .assign, .clear, .deletePack,
            .deleteOrphan, .restoreFactory, .restoreAllFactory, .adoptAICue,
        ]
        let rendered = kinds.map {
            soundPacksEditorOperationAnnouncement(
                kind: $0,
                completion: .succeeded,
                language: .zhHans)
        }

        expect(
            rendered.count == kinds.count && rendered.allSatisfy { !$0.isEmpty },
            "每个 operation kind 都必须有可播报的语义文案")
        expect(
            rendered[0] == "用这个包已完成。"
                && rendered[3] == "添加音频已完成。"
                && rendered[10] == "用于此事件已完成。",
            "operation 播报必须复用既有 action label，不从 pack/file/candidate 重建文案")
        expect(
            soundPacksEditorOperationAnnouncement(
                kind: .importAudio,
                completion: .partial(accepted: 2, rejected: 1),
                language: .english)
                == "Add Audio partially completed: 2 succeeded, 1 failed.",
            "partial 必须保持英文占位符顺序")
        expect(
            soundPacksEditorOperationAnnouncement(
                kind: .adoptAICue,
                completion: .orphan(.mutationFailed),
                language: .zhHans)
                == "用于此事件未能完成。已保留导入音频以供恢复。",
            "orphan 必须说明已保留可恢复事实，但不泄露文件或 candidate")
        expect(
            soundPacksEditorOperationAnnouncement(
                kind: .clear,
                completion: .unchanged,
                language: .english)
                == "Clear Binding made no changes."
                && soundPacksEditorOperationAnnouncement(
                    kind: .deletePack,
                    completion: .failed(.mutationFailed),
                    language: .english)
                    == "Move Sound Pack to Trash failed."
                && soundPacksEditorOperationAnnouncement(
                    kind: .importAudio,
                    completion: .cancelled(changedOnDisk: false),
                    language: .english)
                    == "Add Audio was cancelled."
                && soundPacksEditorOperationAnnouncement(
                    kind: .importAudio,
                    completion: .cancelled(changedOnDisk: true),
                    language: .english)
                    == "Add Audio was cancelled after some changes were saved.",
            "unchanged/failed/cancelled 必须穷尽 changed-on-disk 事实且不暴露内部 failure case")
    }

    await suite("SoundPacks editor accessibility：visible/key/active gate 与 exact-ID ack 保持原子") {
        await withTempDirectory { root in
            let environment = makeAudioImportEnvironment(
                userPacksDirectory: root.appendingPathComponent("packs", isDirectory: true))
            let owner = SoundPacksEditorOwner.stateGalleryFixture(
                previewConfig: ClaudioConfig(selectedPack: "global-pack"),
                packCards: [
                    PackCard(
                        id: "pack-a",
                        name: "Pack A",
                        isCC0: true,
                        presentEvents: [],
                        state: .complete,
                        isSelected: false)
                ],
                selectedPackID: nil,
                selectedEventRows: [],
                environment: environment)
            guard let opened = owner.presentation.pendingAnnouncement else {
                expect(false, "Sounds activate 必须产生 window-opened semantic debt")
                return
            }

            let poster = RecordingSoundPacksEditorAccessibilityPoster()
            let delivery = SoundPacksEditorAnnouncementDelivery(poster: poster)
            let window = NSWindow()
            var isEligible = false
            var acknowledgements: [(SoundPackEditorAnnouncement.ID, Bool)] = []

            delivery.attempt(
                opened,
                language: .zhHans,
                window: window,
                isEligible: {
                    isEligible && owner.presentation.pendingAnnouncement?.id == opened.id
                },
                acknowledge: { id, didPost in
                    acknowledgements.append((id, didPost))
                    _ = owner.send(.acknowledgeAnnouncement(id: id, didPost: didPost))
                })
            expect(
                poster.attempts.isEmpty && acknowledgements.isEmpty,
                "hidden/non-key/inactive 合并 gate 失败时不得进入 native adapter 或消费 debt")

            isEligible = true
            delivery.attempt(
                opened,
                language: .zhHans,
                window: window,
                isEligible: {
                    isEligible && owner.presentation.pendingAnnouncement?.id == opened.id
                },
                acknowledge: { id, didPost in
                    acknowledgements.append((id, didPost))
                    _ = owner.send(.acknowledgeAnnouncement(id: id, didPost: didPost))
                })
            delivery.attempt(
                opened,
                language: .zhHans,
                window: window,
                isEligible: {
                    isEligible && owner.presentation.pendingAnnouncement?.id == opened.id
                },
                acknowledge: { _, _ in
                    expect(false, "同一 announcement ID 在首次 post 完成前不得双播")
                })
            expect(
                poster.attempts.count == 1
                    && poster.attempts[0].request.priority
                        == NSAccessibilityPriorityLevel.medium.rawValue,
                "window-opened notice 只能发起一次 medium-priority post")

            guard case .sounds(let sounds) = owner.presentation.mode,
                let useAction = sounds.packs.first?.useAction,
                case .accepted(let operationID) = owner.send(.invoke(useAction))
            else {
                expect(false, "owner fixture 必须签发可失败的 use capability")
                return
            }
            await owner.waitForScheduledOperationExitForTesting(operationID)
            guard
                let failure = owner.presentation.pendingAnnouncement,
                failure.id != opened.id
            else {
                expect(false, "旧 post 期间的 failure 必须提升为新 queue head")
                return
            }
            expect(
                poster.attempts[0].request.sentence
                    == "声音包管理窗口。共 1 个声音包。尚未选择要检查的声音包。",
                "已签发的 window-opened request 必须是完整语义句")

            poster.completeFirstAttempt()
            expect(
                acknowledgements.count == 1
                    && acknowledgements[0].0 == opened.id
                    && acknowledgements[0].1 == false
                    && owner.presentation.pendingAnnouncement?.id == failure.id,
                "高优先级 debt 抢占 head 后，旧异步 post 只能 false-ack 旧 ID，不得消费新 head")

            delivery.attempt(
                failure,
                language: .zhHans,
                window: window,
                isEligible: {
                    isEligible && owner.presentation.pendingAnnouncement?.id == failure.id
                },
                acknowledge: { id, didPost in
                    acknowledgements.append((id, didPost))
                    _ = owner.send(.acknowledgeAnnouncement(id: id, didPost: didPost))
                })
            expect(
                poster.attempts.count == 1
                    && poster.attempts[0].request.priority
                        == NSAccessibilityPriorityLevel.high.rawValue
                    && poster.attempts[0].request.sentence
                        == "用这个包失败。",
                "failure head 必须以 exact semantic sentence 和 high priority 进入 adapter，实得 "
                    + "\(poster.attempts.map(\.request))")
            poster.completeFirstAttempt()
            expect(
                acknowledgements.count == 2
                    && acknowledgements[1].0 == failure.id
                    && acknowledgements[1].1
                    && owner.presentation.pendingAnnouncement?.id == opened.id,
                "native post 成功后只能 true-ack 本次 exact failure ID，原 notice debt 仍可补播")
        }
    }
}

@MainActor
private final class RecordingSoundPacksEditorAccessibilityPoster:
    SoundPacksEditorAccessibilityPosting
{
    struct Attempt {
        let request: SoundPacksEditorAccessibilityRequest
        let isEligible: @MainActor @Sendable () -> Bool
        let completion: @MainActor @Sendable (Bool) -> Void
    }

    private(set) var attempts: [Attempt] = []

    func post(
        _ request: SoundPacksEditorAccessibilityRequest,
        window _: NSWindow,
        isEligible: @escaping @MainActor @Sendable () -> Bool,
        completion: @escaping @MainActor @Sendable (Bool) -> Void
    ) {
        attempts.append(
            Attempt(
                request: request,
                isEligible: isEligible,
                completion: completion))
    }

    func completeFirstAttempt() {
        let attempt = attempts.removeFirst()
        attempt.completion(attempt.isEligible())
    }
}
