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
    /// One event row's file-name ``Menu`` — `stop.mp3 ▾` / `未配置 ▾` / `文件丢失 ▾`
    /// (PLAN-SOUND-MANAGER.md §2.5/T2, DESIGN.md「行内文件名下拉」). ALL THREE coverage
    /// states share this one control (选文件… / 清除绑定 / 在访达中显示), and picking a file
    /// is legal in every one of them — so unlike ``eventAction(_:)`` this slot is ALWAYS
    /// operable, never conditionally disabled. This is the control an `.unmapped`/`.broken`
    /// row's opening focus now lands on (``EventRow/eventActionOperable``'s new
    /// `previewEnabled && enabled` makes those two states' `.eventAction` permanently
    /// non-operable — see that property's doc comment): the row's actually-fixable control,
    /// not a dead preview button. Sits FIRST in each row's three-slot visual order (leftmost:
    /// the filename sits ahead of 试听/静音), replacing what used to be the row-end drag/
    /// pick-to-bind affordance's implicit ownership of `.eventAction`.
    case eventSound(Event)
    /// One event row's mute toggle (T15 D4).
    case eventMute(Event)
    /// One event row's 试听 ▶ preview button (`EventRowView`). PLAN-SOUND-MANAGER.md §2.5/T2:
    /// UNCONDITIONALLY the preview button in all three coverage states — before T2 this slot
    /// was contested between the preview button (`.present`) and the row-end drag/pick-to-bind
    /// affordance (`.unmapped`/`.broken`), "a SINGLE slot per row regardless of which of the
    /// two it currently is"; T2 gave that affordance its OWN slot (``eventSound(_:)``, the
    /// file-name `Menu`), so there is no second candidate left to contest this one. Always the
    /// same control, always this identity — only whether it's OPERABLE varies (see
    /// ``EventRow/eventActionOperable``).
    case eventAction(Event)
    /// The master volume slider control row (PLAN-MASTER-VOLUME.md D41). Sits after every event
    /// row's action/mute pair and before the pack gallery cards, aligning with the panel's visual
    /// layout (the slider row sits between the event rows and the pack gallery).
    case masterVolume
    // NOTE (cc59d52 / PLAN-SOUND-MANAGER T1): the panel-bottom drop affordance's focus slot
    // `.dropZone` was removed here together with `AudioDropZoneView` (finding ①: it copied bytes
    // but never wrote `manifest.json` — an orphan-maker). A focus target with no rendered control
    // is exactly the ghost the "only real controls claim a slot" rule (see `panelFocusOrder(_:)`'s
    // `.masterVolume` gate) forbids — and it was reachable: `PanelView.applyFirstFocus` opened
    // `.needsPack`/`.malformed`/`.unwritable` focus onto it, i.e. onto nothing. PLAN-SOUND-MANAGER
    // T7 reintroduces a real panel-bottom control ("管理声音包…") as `.manageSounds` — an
    // unconditionally rendered+operable slot that becomes the operational scope's "never nil"
    // anchor. Until then the panel has no bottom affordance, so it claims no slot.
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
    /// 「诚实失败态」卡片上的「在访达中显示 config.json」（/codex review P1，26bba37 follow-up）。
    ///
    /// `.malformed`/`.unwritable` 时 ``PanelView/configFailureNotice(reason:)`` 渲染这颗按钮，而它排在
    /// 面板**最顶端**（顶替掉四行事件、在画廊之上）—— 所以在 ``panelFocusOrder(_:)`` 里它 LEADS 整个
    /// operational 序（焦点序跟随视觉序，a11y-architect FIX 5）。它是那张失败卡上唯一的 bespoke 修复
    /// 动作（画廊在每个 `configState` 都一样），因此开局焦点该落在它上面，而不是越过它落到包卡 / 断开
    /// 连接 / nil。
    ///
    /// 只在这两个 `configState` 出现（`hasConfigFailureNotice`）；`.operational`/`.needsPack` 不渲染
    /// 失败卡，flag 为假，这颗 target 不进序。它**恒可操作**（访达 reveal 无写副作用，含 in-flight），
    /// 但它是**条件性**锚点 —— 不是 operational scope「永不返回 nil」的**无条件**担保者（那把交椅留给
    /// PLAN-SOUND-MANAGER T7 无条件 append 的 `.manageSounds`，见上方 NOTE）；它只是让
    /// `.malformed`/`.unwritable` 这两态在 `.manageSounds` 落地前就已恒非 nil。
    case configReveal
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
    ///
    /// `hasMasterVolume` (fix for a `/codex review` P1, 阶段 C4 收尾): whether the master volume
    /// slider is ACTUALLY ON SCREEN right now.
    ///
    /// PLAN-MASTER-VOLUME.md 阶段 D has landed (`MasterVolumeRow`, 8771946), and
    /// ``PanelView/operationalPanel``'s `.operational` case is the ONLY branch that renders it —
    /// `.needsPack`/`.malformed`/`.unwritable` show the empty-state/failure card instead. So
    /// ``PanelView/applyFirstFocus()`` now passes `isOperational` here, and that IS a valid
    /// proxy: the render decision and the focus decision are the same `switch configState`, read
    /// twice. (Before 阶段 D it was pinned to a literal `false` by a `/codex review` P2, precisely
    /// because `operationalPanel` rendered zero `Slider`s back then — flipping it to
    /// `isOperational` is not a regression of that fix, it is the fix's own stated exit
    /// condition. `ViewWiringSuite` pins both halves and fails the moment either drifts.)
    ///
    /// Still defaults to `false` (fail-closed, same reasoning as `hasDetailToggle`), and that
    /// default is NOT vestigial: this function is Core, it cannot see `configState` and must
    /// never try to derive this itself. A caller must not claim a focus slot for a control it
    /// doesn't independently know is on screen — the coupling has to be re-asserted at each call
    /// site, honestly, every time.
    ///
    /// `hasConfigFailureNotice` (/codex review P1, 26bba37 follow-up): whether the
    /// `.malformed`/`.unwritable` 诚实失败卡 is on screen — it carries the 在访达中显示 config.json
    /// button (``PanelView/configFailureNotice(reason:)``), which renders at the panel TOP and so
    /// LEADS the focus order as ``PanelFocusTarget/configReveal``. Same fail-closed default and same
    /// honesty rule as `hasMasterVolume`: Core can't see `configState`, so the caller must derive it
    /// from the very `switch configState` that decides whether the failure card renders — the render
    /// decision and the focus decision are the same switch, read twice.
    case operational(
        events: [Event], packCardIDs: [String], hasDetailToggle: Bool = false,
        hasMasterVolume: Bool = false, hasConfigFailureNotice: Bool = false)
}

/// The panel's Tab/Shift+Tab traversal order for its current ``PanelFocusScope`` —
/// ENGINEERING.md's rule, reduced to a pure, orderable list: onboarding CTAs (primary then
/// secondary, whichever exist) OR, once operational, each event row's THREE slots — file-name
/// `Menu` (``PanelFocusTarget/eventSound(_:)``), THEN its 试听 ▶ action, THEN its mute toggle
/// (in ``Event/allCases`` order — this order follows the row's VISUAL reading order
/// left-to-right, ``EventRowView``'s `trailing` renders the file-name control first, then the
/// action control, then `muteIndicator` rightmost; a11y review a11y-architect FIX 5: focus
/// order must track visual order, not an arbitrary model-first convenience — PLAN-SOUND-
/// MANAGER.md §2.5/T2 grew this from two slots to three), then
/// every pack gallery card (in ``availablePacks(config:environment:)``'s own order). On
/// `.malformed`/`.unwritable` the 诚实失败卡's ``PanelFocusTarget/configReveal`` LEADS the whole
/// operational list — it renders above every row/card, so visual order puts it first.
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

    case .operational(let events, let packCardIDs, let hasDetailToggle, let hasMasterVolume,
                      let hasConfigFailureNotice):
        var order: [PanelFocusTarget] = []
        // 诚实失败卡（`.malformed`/`.unwritable`）渲染在面板**最顶端**（顶替四行事件、在画廊之上），
        // 它的「在访达中显示 config.json」按钮是那张卡上唯一的 bespoke 修复动作 —— 所以它 LEADS 焦点序
        // （焦点序跟随视觉序，a11y-architect FIX 5）。只有这两态渲染失败卡；`.operational`/`.needsPack`
        // 的 flag 为假，`.configReveal` 不进序。
        if hasConfigFailureNotice { order.append(.configReveal) }
        // 每行三槽，按视觉序（a11y-architect FIX 5）：文件名 `Menu`（eventSound，最左）→ 试听 ▶
        // （eventAction）→ 静音钮（eventMute，最右）—— PLAN-SOUND-MANAGER.md §2.5/T2 把两槽改成
        // 三槽，`EventRowView.trailing` 渲染的正是这个从左到右的顺序。
        for event in events {
            order.append(.eventSound(event))
            order.append(.eventAction(event))
            order.append(.eventMute(event))
        }
        // 只有滑块真的渲染在屏幕上才进 order —— 不然「不在屏幕上的控件不得占用焦点位」这条
        // 铁律（见 `PanelView.applyFirstFocus` 同一句注释）在这条 case 里就是一句空话
        // （`/codex review` 2626083/47459a7 抓到的 P1：这里曾经无条件 append，`.needsPack`/
        // `.malformed`/`.unwritable` 下会把首焦点指向一个不存在的控件）。
        if hasMasterVolume { order.append(.masterVolume) }
        // `.dropZone` used to be appended here unconditionally; it left with `AudioDropZoneView`
        // (cc59d52 / PLAN-SOUND-MANAGER T1 — see the enum note). T7 re-adds a `.manageSounds` slot
        // in this position once the "管理声音包…" control exists.
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
/// load-bearing word, and `.first` alone does not honor it. Each row's actual FIRST slot is
/// now ``PanelFocusTarget/eventSound(_:)`` (PLAN-SOUND-MANAGER.md §2.5/T2), which is always
/// operable — so `.eventSound` never needs skipping, and (this is the mechanical consequence,
/// pinned by ``PanelFocusOrderSuite``) it is ALSO why this resolver's `nonOperableActionEvents`
/// skip-to-the-next-slot machinery, built pre-T2 for a muted `.present` row's disabled preview,
/// no longer actually fires for opening focus: `.eventSound` precedes `.eventAction` in every
/// row and always answers `.first`'s predicate `true`, so the walk never even REACHES that
/// row's `.eventAction` to decide whether to skip it — mute or coverage state notwithstanding.
/// `.eventAction` (the 试听 ▶ button, one slot to the right of `.eventSound`) can still be
/// present-but-disabled — for a `.present` row that is MUTED (``EventRowView``'s preview
/// `Button` renders `.disabled(true)``), and, since T2, for EVERY `.unmapped`/`.broken` row
/// regardless of mute (``CoverageState/previewEnabled`` is `false` there, so
/// ``EventRow/eventActionOperable`` is `false` unconditionally) — but that only still matters
/// for `panelFocusOrder(_:)`'s Tab-STOP bookkeeping (AppKit's key-loop skips a disabled `NSView`
/// on its own), never for THIS function's return value whenever `events` is non-empty: opening
/// focus is always that first event's `.eventSound`, for every mute/coverage combination.
///
/// `nonOperableActionEvents` names the events whose `.eventAction` slot is currently
/// disabled. It is computed by the view layer (``PanelView``), which alone knows each row's
/// ``CoverageState`` + muted state — deliberately kept OUT of this Foundation-only model, the
/// same reason ``PanelFocusScope`` carries plain ``Event``s rather than `EventRow`s. Every
/// non-action, non-sound target — mute toggles, the master volume slider, gallery cards — is
/// operable and never filtered (the slider only ever appears in a fully-operational panel,
/// PLAN-MASTER-VOLUME.md D23/D41).
///
/// ⚠️ Since T2, this parameter no longer changes THIS function's return value whenever `events`
/// is non-empty (see above: `.eventSound` always wins first). It is kept — rather than deleted —
/// because ``panelFocusOrder(_:)`` still needs `.eventAction`'s operability distinguished from
/// its mere presence for its OWN Tab-STOP semantics, and because ``EventRow/eventActionOperable``
/// (the value this set is built from) still drives ``EventRowView``'s visual disabled styling —
/// a real, still-load-bearing computation, just no longer one this specific resolver's answer
/// depends on. ``PanelFocusOrderSuite`` pins the "any nonOperableActionEvents value resolves to
/// the same first-row `.eventSound`" invariant explicitly, so a future revert of the `.eventSound`
/// slot (which WOULD make this parameter matter again) fails loudly rather than silently.
///
/// ``panelFocusOrder(_:)`` itself is intentionally NOT changed: it still lists every slot
/// including disabled actions, so the per-row Tab-STOP count stays stable across coverage
/// state (``PanelFocusTarget/eventAction(_:)``'s own invariant) and AppKit's real key-loop —
/// which skips disabled `NSView`s on its own — keeps owning Tab traversal. This resolver
/// governs only the ONE thing the pure model actually drives: which control opens focused.
///
/// Returns `nil` when the order contains no OPERABLE target — two ways: a genuinely empty order
/// (onboarding with neither CTA), **or** an onboarding scope whose only targets are the CTAs while
/// `ctaOperable` is `false` (i.e. an action is in flight — both buttons are `.disabled`). The
/// second case is not an oversight: during a `.takeOver`/`.disconnect` there is genuinely nothing
/// operable left in the onboarding card to hold the caret, and pointing it at a disabled control
/// would be a lie. (T17c: the previous wording — "Returns `nil` only for a genuinely empty order"
/// — was written before `ctaOperable` existed and was false the moment it landed.)
///
/// The OPERATIONAL scope returns `nil` in exactly ONE shape: an in-flight panel with zero event
/// rows, zero pack cards, no slider AND no config-failure notice (`ctaOperable == false`, so even
/// the always-appended `.disconnect` is not operable) — the honest counterpart to the onboarding
/// in-flight `nil` below. Concretely that is a `.needsPack` panel with nothing installed while a
/// disconnect is in flight; the two config-broken states can't reach it (next paragraph). In every
/// reachable non-in-flight shape it is non-nil: a `.operational` panel's first row's
/// ``PanelFocusTarget/eventSound(_:)`` is ALWAYS operable (PLAN-SOUND-MANAGER.md §2.5/T2 — it
/// never needs to fall back to that row's mute toggle the way `.eventAction` sometimes did); a
/// `.needsPack` panel's first pack card is (the gallery renders in every `configState`); and
/// when neither exists, the always-appended `.disconnect` (or, when a failure row shows, its
/// `.revealDetail`) anchors it while `ctaOperable`.
///
/// `.malformed`/`.unwritable` are the exception that is ALWAYS non-nil, in-flight or not: their
/// 诚实失败卡 leads the order with `.configReveal` (在访达中显示 config.json), which is
/// unconditionally operable (reveal has no write side-effect), so it anchors those two states even
/// while a disconnect is in flight (/codex review P1, 26bba37 follow-up). It is a CONDITIONAL anchor
/// (only on those two states), NOT the operational scope's unconditional never-nil guarantor — that
/// seat stays reserved for PLAN-SOUND-MANAGER T7's unconditionally-appended `.manageSounds`.
///
/// (Before T1 this could NEVER be nil, because `.dropZone` was appended unconditionally and was
/// always operable. That anchor left with `AudioDropZoneView` — cc59d52 / PLAN-SOUND-MANAGER T1 —
/// because it was a focus slot for a control that no longer rendered, and `PanelView` was opening
/// `.needsPack`/`.malformed`/`.unwritable` focus straight onto it. `.configReveal` now anchors the
/// two config-broken states honestly; PLAN-SOUND-MANAGER T7 adds `.manageSounds` as the
/// unconditional anchor for the remaining shapes, at which point the operational scope is once again
/// never-nil for every shape, in-flight or not.)
///
/// 焦点在 in-flight 期间该落到哪，是一个仍未定的产品问题（见 TODOS「in-flight 期间 onboarding 的
/// 键盘焦点无处可去」）—— 当前行为是**诚实的空**，不是一个已经想清楚的答案。
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
        case .eventSound:
            // PLAN-SOUND-MANAGER.md §2.5/T2: picking a file is legal in EVERY coverage state
            // (`.present`/`.unmapped`/`.broken` all render the same file-name `Menu`, never
            // disabled) — unlike `.eventAction`, this slot has no operability axis to check.
            // This is precisely what lets an `.unmapped` row's opening focus land HERE instead
            // of skipping past a permanently-non-operable `.eventAction` to `.eventMute`.
            return true
        case .eventAction(let event):
            return !nonOperableActionEvents.contains(event)
        case .onboardingPrimaryAction, .onboardingSecondaryAction, .disconnect:
            return ctaOperable
        case .revealDetail:
            // 动作跑到一半时失败行不存在（`runDiskAction` 一开跑就把 actionState 换成 `.running`），
            // 所以这个 target 压根不会在 in-flight 的 order 里 —— 但仍显式跟随 `ctaOperable`，
            // 免得未来某次改动让它悄悄留在一个全禁用的面板上。
            return ctaOperable
        // .masterVolume (PLAN-MASTER-VOLUME.md D23 定稿 + D41): unconditionally operable
        // WHEN PRESENT — but whether it's present at all is now decided upstream by
        // `hasMasterVolume` (``PanelFocusScope/operational(events:packCardIDs:hasDetailToggle:hasMasterVolume:)``),
        // not by this switch. If `hasMasterVolume` was `false`, `panelFocusOrder(_:)` never put
        // `.masterVolume` in the order in the first place, so this arm simply never sees it —
        // this `true` only fires for a slider that is ACTUALLY on screen.
        case .configReveal:
            // 访达 reveal 无写副作用，恒可操作（含 in-flight，`ctaOperable == false` 时照样）—— 与
            // T7 计划中的 `.manageSounds` operability arm 同理。这让 `.malformed`/`.unwritable` 这两态
            // 的 operational scope 永不返回 nil，即便断开动作在飞。
            return true
        case .eventMute, .packCard, .masterVolume:
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
///
/// `hasMasterVolume` defaults to `false` (fail-closed) and must be supplied by the caller as an
/// explicit, honest signal — same reasoning as `hasDetailToggle`. This function is Core: it
/// cannot see `configState` and must never derive the flag itself. `hasConfigFailureNotice` obeys
/// the identical contract (fail-closed default; caller derives it from the `.malformed`/`.unwritable`
/// arm of the same `switch configState` that renders the failure card): it makes `.configReveal`
/// lead the order on those two states (/codex review P1, 26bba37 follow-up).
///
/// PLAN-MASTER-VOLUME.md 阶段 D has landed (8771946): ``PanelView/applyFirstFocus()`` now passes
/// `isOperational`, because `MasterVolumeRow` is rendered by exactly one branch of
/// ``PanelView/operationalPanel`` — the `.operational` one. That makes the two decisions the same
/// `switch configState` read twice, which is what makes the flag honest here.
///
/// History, so nobody re-litigates it: the coupling was first tried in 341d9b7 and reverted by a
/// `/codex review` P2, back when `operationalPanel` rendered zero `Slider`s — `.operational` then
/// genuinely did NOT mean "the slider is on screen", so the caller was pinned to a literal
/// `false`. 阶段 D is the exit condition that P2 itself named. Do NOT "restore" the literal
/// `false`: it would make the slider unreachable by Tab/VoiceOver while it is visibly on screen.
/// `ViewWiringSuite` pins the call site in both directions and fails either way it drifts.
public func panelOpeningFocus(
    rows: [EventRow], packCardIDs: [String], ctaOperable: Bool = true,
    hasDetailToggle: Bool = false, hasMasterVolume: Bool = false,
    hasConfigFailureNotice: Bool = false
) -> PanelFocusTarget? {
    let scope = PanelFocusScope.operational(
        events: rows.map(\.event), packCardIDs: packCardIDs, hasDetailToggle: hasDetailToggle,
        hasMasterVolume: hasMasterVolume, hasConfigFailureNotice: hasConfigFailureNotice)
    let nonOperableActionEvents = Set(rows.filter { !$0.eventActionOperable }.map(\.event))
    return panelFirstFocusTarget(
        scope, nonOperableActionEvents: nonOperableActionEvents, ctaOperable: ctaOperable)
}
