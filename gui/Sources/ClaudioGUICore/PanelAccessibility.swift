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
public func needsPackNoticeCopy(hasVisiblePackChoices: Bool) -> NeedsPackNoticeCopy {
    let instruction =
        hasVisiblePackChoices
        ? "点一个声音包，Claudio 会建好配置。"
        : "选择「管理声音包…」，在访达中添加声音包后再回来选择。"
    let message = "还没有选中任何声音包。\(instruction)"
    return NeedsPackNoticeCopy(
        message: message,
        accessibilityLabel: "先选包。\(message)")
}
