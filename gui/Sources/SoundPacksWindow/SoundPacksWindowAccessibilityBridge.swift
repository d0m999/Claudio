import AppKit
import ClaudioGUICore
import ClaudioLocalization

/// One render-ready request at the AppKit accessibility seam. The semantic editor owner remains
/// independent of AppKit and localization; the system poster only executes these supplied values.
package struct SoundPacksEditorAccessibilityRequest: Equatable, Sendable {
    package let sentence: String
    package let priority: Int
}

/// Resolves the owner's semantic announcement without inspecting raw model state, paths, pack
/// content, or candidate data. Priority is carried by the owner so failure ordering cannot drift
/// from the queue that selected the current head.
@MainActor
package func soundPacksEditorAccessibilityRequest(
    _ announcement: SoundPackEditorAnnouncement,
    language: ClaudioAppLanguage
) -> SoundPacksEditorAccessibilityRequest {
    let sentence: String
    switch announcement.kind {
    case .windowOpened(let facts):
        sentence = soundPacksWindowAnnouncement(
            .windowOpened,
            facts: facts,
            language: language)
    case .libraryStateChanged(let facts):
        sentence = soundPacksWindowAnnouncement(
            .libraryStateChanged,
            facts: facts,
            language: language)
    case .selectionChanged(let facts):
        sentence = soundPacksWindowAnnouncement(
            .selectionChanged,
            facts: facts,
            language: language)
    case .windowStatus:
        let action = announcement.actionText?.resolve(language: language) ?? ""
        let message =
            announcement.messageText?.resolve(language: language)
            ?? ClaudioL10n(language: language).text(.soundPacksOperationFailed)
        let moment: SoundPacksWindowAnnouncementMoment =
            announcement.priority == .failure
            ? .writeFailed(action: action, reason: message)
            : .writeSucceeded(message: message)
        sentence = soundPacksWindowAnnouncement(
            moment,
            facts: SoundPacksWindowAnnouncementFacts(
                packCount: 0,
                selectedPackName: nil),
            language: language)
    case .operation(let kind, let completion):
        sentence = soundPacksEditorOperationAnnouncement(
            kind: kind,
            completion: completion,
            language: language)
    }

    let priority: NSAccessibilityPriorityLevel =
        announcement.priority == .failure ? .high : .medium
    return SoundPacksEditorAccessibilityRequest(
        sentence: sentence,
        priority: priority.rawValue)
}

/// Privacy-preserving fallback for operation debts that intentionally carry no raw status text.
/// The action label and completion shape are exhaustive, localized, and contain no target values.
@MainActor
package func soundPacksEditorOperationAnnouncement(
    kind: SoundPackEditorActivityKind,
    completion: SoundPackEditorOperationCompletion,
    language: ClaudioAppLanguage
) -> String {
    let l10n = ClaudioL10n(language: language)
    let actionKey: ClaudioL10nKey
    switch kind {
    case .use:
        actionKey = .soundPacksStatusUsePack
    case .toggleStar:
        actionKey = .soundPacksStatusUpdateStars
    case .fork:
        actionKey = .soundPacksStatusCopyPack
    case .importAudio:
        actionKey = .soundPacksStatusAddAudio
    case .assign:
        actionKey = .soundPacksChooseBind
    case .clear:
        actionKey = .soundPacksClearBinding
    case .deletePack:
        actionKey = .soundPacksStatusDeletePack
    case .deleteOrphan:
        actionKey = .soundPacksOrphanDelete
    case .restoreFactory:
        actionKey = .soundPacksStatusRestoreFactory
    case .restoreAllFactory:
        actionKey = .soundPacksStatusRestoreBuiltins
    case .adoptAICue:
        actionKey = .aiCueUseForEvent
    }
    let action = l10n.text(actionKey)

    switch completion {
    case .unchanged:
        return l10n.format(.soundPacksAnnouncementOperationUnchanged, action)
    case .succeeded:
        return l10n.format(.soundPacksAnnouncementOperationSucceeded, action)
    case .partial(let accepted, let rejected):
        return l10n.format(
            .soundPacksAnnouncementOperationPartial,
            action,
            "\(accepted)",
            "\(rejected)")
    case .failed:
        return l10n.format(.soundPacksAnnouncementOperationFailed, action)
    case .cancelled(let changedOnDisk):
        return l10n.format(
            changedOnDisk
                ? .soundPacksAnnouncementOperationCancelledAfterChanges
                : .soundPacksAnnouncementOperationCancelled,
            action)
    case .orphan:
        return l10n.format(.soundPacksAnnouncementOperationOrphan, action)
    }
}
