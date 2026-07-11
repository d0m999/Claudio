import ClaudioCore
import Foundation

/// One focusable control in the panel, keyed by a stable identity — a test (and the AppKit
/// focus-chain bridge `ClaudioGUI`'s menu-bar shell wires, T15 D2, compile-only/manual-verify
/// here) can name a SPECIFIC control, not just count how many there are.
///
/// ENGINEERING.md「无障碍规格」: "打开焦点落首个可操作项；Tab / Shift+Tab 遍历；空格 / 回车
/// 触发；Esc 关闭；关闭后焦点回菜单栏 status item" — this type + ``panelFocusOrder(_:)``
/// model the ORDER that traversal rule walks; the actual `NSResponder`/key-loop wiring that
/// makes Tab/Esc/VoiceOver really work is AppKit, compile-only here (see `ClaudioGUI`'s
/// menu-bar shell doc comments).
///
/// `Hashable` (a11y-architect FIX 4, on top of the `Sendable`/`Equatable` this already had):
/// SwiftUI's `@FocusState<Value>` requires `Value: Hashable` — `PanelView` keys its real
/// `@FocusState` off this exact type, so the pure focus-ORDER model
/// (``panelFocusOrder(_:)``) and the live SwiftUI focus binding share one identity space,
/// never two independently-drifting ones.
public enum PanelFocusTarget: Sendable, Hashable {
    case onboardingPrimaryAction
    case onboardingSecondaryAction
    /// One event row's mute toggle (T15 D4).
    case eventMute(Event)
    /// One event row's trailing action — 试听 ▶ when ``CoverageState/present(fileName:)``,
    /// the drag/pick-to-bind affordance when `unmapped`/`broken` (`EventRowView`, T16). A
    /// SINGLE slot per row regardless of which of the two it currently is: the row always
    /// renders exactly one of them, so the tab STOP count per row never changes with
    /// coverage state, only what activating it does.
    case eventAction(Event)
    case dropZone
    case packCard(id: String)
}

/// Everything ``panelFocusOrder(_:)`` needs to know about the panel's CURRENT shape —
/// deliberately not `PanelViewModel`/`EventRow`/`PackCard` themselves, so this model stays
/// testable against plain fixture values without constructing a whole panel's worth of
/// on-disk state.
public enum PanelFocusScope: Sendable, Equatable {
    /// The onboarding card is showing (``OnboardingState`` ≠ some fully-operational state).
    /// `hasPrimaryAction`/`hasSecondaryAction` mirror ``OnboardingCopy/primaryActionTitle``/
    /// ``OnboardingCopy/secondaryActionTitle`` being non-`nil` — a state like `.installed`
    /// has no primary action (`nil` title) but does have a secondary one ("断开连接").
    case onboarding(hasPrimaryAction: Bool, hasSecondaryAction: Bool)
    /// The operational panel is showing: `events` is normally ``Event/allCases`` in its
    /// declared order (kept as an explicit parameter, not hardcoded, so a test can pin
    /// "exactly `Event.allCases`'s order" as its own assertion rather than baking that
    /// assumption into this function); `packCardIDs` mirrors ``PackCard/id``'s gallery order
    /// (``availablePacks(config:environment:)``'s sorted-by-id output).
    case operational(events: [Event], packCardIDs: [String])
}

/// The panel's Tab/Shift+Tab traversal order for its current ``PanelFocusScope`` —
/// ENGINEERING.md's rule, reduced to a pure, orderable list: onboarding CTAs (primary then
/// secondary, whichever exist) OR, once operational, each event row's action slot THEN its
/// mute toggle (in ``Event/allCases`` order — this order follows the row's VISUAL reading
/// order left-to-right, ``EventRowView``'s `trailing` renders the action control before
/// `muteIndicator`, which sits rightmost; a11y review a11y-architect FIX 5: focus order must
/// track visual order, not an arbitrary model-first convenience), then the drop zone, then
/// every pack gallery card (in ``availablePacks(config:environment:)``'s own order).
/// `order.first` is where focus lands the instant the panel opens (ENGINEERING.md: "打开
/// 焦点落首个可操作项").
public func panelFocusOrder(_ scope: PanelFocusScope) -> [PanelFocusTarget] {
    switch scope {
    case .onboarding(let hasPrimaryAction, let hasSecondaryAction):
        var order: [PanelFocusTarget] = []
        if hasPrimaryAction { order.append(.onboardingPrimaryAction) }
        if hasSecondaryAction { order.append(.onboardingSecondaryAction) }
        return order

    case .operational(let events, let packCardIDs):
        var order: [PanelFocusTarget] = []
        for event in events {
            order.append(.eventAction(event))
            order.append(.eventMute(event))
        }
        order.append(.dropZone)
        order.append(contentsOf: packCardIDs.map { .packCard(id: $0) })
        return order
    }
}
