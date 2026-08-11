/// The visible message and VoiceOver label for `PanelView`'s `.needsPack` empty-state card
/// (PLAN-SOUND-MANAGER.md T7).
///
/// This decision lives in the importable Core target so its actual strings can be unit-tested.
/// `PanelView` consumes both fields from the same value: the visual message and accessibility
/// label cannot independently drift between the "visible pack choices" and "zero rows" shapes.
public struct NeedsPackNoticeCopy: Sendable, Equatable {
    public let message: String
    public let accessibilityLabel: String

    public init(message: String, accessibilityLabel: String) {
        self.message = message
        self.accessibilityLabel = accessibilityLabel
    }
}

/// Returns the `.needsPack` copy for the panel's current display-set shape.
///
/// - With visible pack choices, the primary action is selecting one of those rows.
/// - With zero rows, the only useful recovery action is the always-rendered
///   "管理声音包…" button, which reveals the packs folder during T7's phase-1 bridge.
public func needsPackNoticeCopy(
    hasVisiblePackChoices: Bool,
    language: ClaudioAppLanguage = .zhHans
) -> NeedsPackNoticeCopy {
    let l10n = ClaudioL10n(language: language)
    let message = l10n.text(
        hasVisiblePackChoices
            ? .panelSelectPackWithChoicesMessage
            : .panelSelectPackWithoutChoicesMessage)
    return NeedsPackNoticeCopy(
        message: message,
        accessibilityLabel: "\(l10n.text(.panelSelectPack))。\(message)")
}
import ClaudioLocalization
