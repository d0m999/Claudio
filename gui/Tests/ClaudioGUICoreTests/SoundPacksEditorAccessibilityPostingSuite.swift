import ClaudioCore
import ClaudioGUICore
import ClaudioLocalization
import Foundation
import SoundPacksWindow

@MainActor
func runSoundPacksEditorAccessibilityPostingSuites() {
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

}
