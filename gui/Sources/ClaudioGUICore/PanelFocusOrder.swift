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
    /// 一条失败行上的「查看原因」（T17）—— 它是一个**可聚焦控件**，不是装饰：WCAG 2.1.1 要求
    /// 键盘用户也能展开那条原因，而这个仓库已经为「成功/拒绝之后只剩鼠标可用」记过一条 P3 账。
    case revealDetail
    /// 运行态面板尾部的「断开连接」（T17，**授权的设计变更**）。
    ///
    /// 它此前是 `OnboardingCopy(.installed).secondaryActionTitle`，而 `.installed` 状态下
    /// `PanelView` 渲染的是 `operationalPanel`、**根本不渲染 `OnboardingView`** —— 于是这颗按钮
    /// 在整个 shipping app 里没有一个像素，只活在 state gallery 里。而 `.notInstalled` 的正文
    /// 白纸黑字向用户承诺「随时可以一键撤销」。T17 给了它一个真入口，那句承诺才不是谎话。
    case disconnect
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
    case onboarding(hasPrimaryAction: Bool, hasSecondaryAction: Bool, hasDetailToggle: Bool = false)
    /// The operational panel is showing: `events` is normally ``Event/allCases`` in its
    /// declared order (kept as an explicit parameter, not hardcoded, so a test can pin
    /// "exactly `Event.allCases`'s order" as its own assertion rather than baking that
    /// assumption into this function); `packCardIDs` mirrors ``PackCard/id``'s gallery order
    /// (``availablePacks(config:environment:)``'s sorted-by-id output).
    case operational(events: [Event], packCardIDs: [String], hasDetailToggle: Bool = false)
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
    case .onboarding(let hasPrimaryAction, let hasSecondaryAction, let hasDetailToggle):
        var order: [PanelFocusTarget] = []
        // 失败行画在按钮**上方** —— 焦点序跟随视觉序（a11y-architect FIX 5）。
        if hasDetailToggle { order.append(.revealDetail) }
        if hasPrimaryAction { order.append(.onboardingPrimaryAction) }
        if hasSecondaryAction { order.append(.onboardingSecondaryAction) }
        return order

    case .operational(let events, let packCardIDs, let hasDetailToggle):
        var order: [PanelFocusTarget] = []
        for event in events {
            order.append(.eventAction(event))
            order.append(.eventMute(event))
        }
        order.append(.dropZone)
        order.append(contentsOf: packCardIDs.map { .packCard(id: $0) })
        // 面板最底部：失败行（若有）在「断开连接」之上 —— 焦点序跟随视觉序。
        if hasDetailToggle { order.append(.revealDetail) }
        order.append(.disconnect)
        return order
    }
}

/// The control focus lands on the instant the panel opens — the FIRST entry of
/// ``panelFocusOrder(_:)`` that is actually OPERABLE.
///
/// ENGINEERING.md「无障碍规格」: "打开焦点落首个可操作项" — 可操作 (OPERABLE) is the
/// load-bearing word, and `.first` alone does not honor it: an event row whose 试听 ▶ is
/// present-but-disabled (its sound is MUTED, so ``EventRowView``'s preview `Button` renders
/// `.disabled(true)`) is still the row's `.eventAction` slot and still sits FIRST in
/// ``panelFocusOrder(_:)``'s list, so `panelFocusOrder(scope).first` would park the opening
/// keyboard caret on a dimmed control that does nothing. This resolver skips those, landing
/// focus on the first genuinely-operable target instead — for a muted first row that is its
/// own (always-operable) mute toggle, one slot to the right.
///
/// `nonOperableActionEvents` names the events whose `.eventAction` slot is currently
/// disabled. It is computed by the view layer (``PanelView``), which alone knows each row's
/// ``CoverageState`` + muted state — deliberately kept OUT of this Foundation-only model, the
/// same reason ``PanelFocusScope`` carries plain ``Event``s rather than `EventRow`s. Only the
/// present-AND-muted case belongs here: `unmapped`/`broken` rows' action slot is the
/// always-operable import affordance, not the (also-rendered, but no-longer-focus-owning)
/// disabled preview button (see ``EventRowView``). Every non-action target — mute toggles,
/// the drop zone, gallery cards — is operable and never filtered.
///
/// ``panelFocusOrder(_:)`` itself is intentionally NOT changed: it still lists every slot
/// including disabled actions, so the per-row Tab-STOP count stays stable across coverage
/// state (``PanelFocusTarget/eventAction(_:)``'s own invariant) and AppKit's real key-loop —
/// which skips disabled `NSView`s on its own — keeps owning Tab traversal. This resolver
/// governs only the ONE thing the pure model actually drives: which control opens focused.
///
/// Returns `nil` only for a genuinely empty order (e.g. onboarding with neither CTA); an
/// operational panel always ends in ``PanelFocusTarget/dropZone``, so it never returns `nil`.
/// `ctaOperable` (T17) names whether the onboarding CTA controls — the two onboarding buttons and
/// the operational panel's 断开连接 — are currently ENABLED. They are not, for the whole duration
/// of a `.takeOver`/`.disconnect` (``OnboardingActionState/running(_:)``): the view disables them
/// so a second click cannot race the first. Without this, the caret keeps pointing at a control
/// that is on screen but dead, and a keyboard user who presses 空格 on 「接管」 finds the focus
/// simply gone — the panel's whole "打开焦点落首个可操作项" contract, but broken by a transition
/// INSIDE the panel rather than at open. 可操作 is load-bearing here for exactly the same reason it
/// is for a muted row's disabled 试听 ▶.
public func panelFirstFocusTarget(
    _ scope: PanelFocusScope,
    nonOperableActionEvents: Set<Event> = [],
    ctaOperable: Bool = true
) -> PanelFocusTarget? {
    panelFocusOrder(scope).first { target in
        switch target {
        case .eventAction(let event):
            return !nonOperableActionEvents.contains(event)
        case .onboardingPrimaryAction, .onboardingSecondaryAction, .disconnect:
            return ctaOperable
        case .revealDetail:
            // 动作跑到一半时失败行不存在（`runDiskAction` 一开跑就把 actionState 换成 `.running`），
            // 所以这个 target 压根不会在 in-flight 的 order 里 —— 但仍显式跟随 `ctaOperable`，
            // 免得未来某次改动让它悄悄留在一个全禁用的面板上。
            return ctaOperable
        case .eventMute, .dropZone, .packCard:
            return true
        }
    }
}

/// The control an OPERATIONAL panel opens focused on, computed from the panel's actual rows —
/// the whole composition ``PanelView`` performs when it opens: build the ``PanelFocusScope`` from
/// the rows' events, derive `nonOperableActionEvents` from each row's own
/// ``EventRow/eventActionOperable`` decision, and resolve through
/// ``panelFirstFocusTarget(_:nonOperableActionEvents:)`` — never through plain
/// `panelFocusOrder(_:).first`, which would park the opening keyboard caret on a muted first
/// row's disabled 试听 ▶ (ENGINEERING.md「无障碍规格」"打开焦点落首个可操作项" — 可操作 is
/// load-bearing).
///
/// Exists as a pure function so that composition is TESTABLE (T16 review 修复⑥). Its three
/// steps were previously private members of `PanelView`, i.e. inside SwiftUI, i.e. unreachable
/// from this machine's dependency-free harness: `panelFirstFocusTarget` had thorough tests while
/// the code that DECIDES WHAT TO PASS IT had none, so reverting the view to `order.first` — the
/// exact bug — left every test green. `PanelView` now delegates here, and
/// ``PanelFocusOrderSuite`` pins the muted-first-row case (including the assertion that the
/// result must NOT equal `panelFocusOrder(_:).first`).
///
/// Onboarding is deliberately out of scope: it has no rows, so it has no `.eventAction` targets
/// to filter — ``panelFirstFocusTarget(_:nonOperableActionEvents:)`` handles that scope directly.
public func panelOpeningFocus(
    rows: [EventRow], packCardIDs: [String], ctaOperable: Bool = true,
    hasDetailToggle: Bool = false
) -> PanelFocusTarget? {
    let scope = PanelFocusScope.operational(
        events: rows.map(\.event), packCardIDs: packCardIDs, hasDetailToggle: hasDetailToggle)
    let nonOperableActionEvents = Set(rows.filter { !$0.eventActionOperable }.map(\.event))
    return panelFirstFocusTarget(
        scope, nonOperableActionEvents: nonOperableActionEvents, ctaOperable: ctaOperable)
}
