import ClaudioCore
import ClaudioGUICore
import Foundation

// MARK: - panelFocusOrder (ENGINEERING.md T15 D5: popover focus owner model). Pure-value
// tests only — the real AppKit/NSResponder key-loop wiring is compile-only/manual-verify
// (see `ClaudioGUI`'s menu-bar shell).

@MainActor
func runPanelFocusOrderSuites() {
    suite("panelFocusOrder: onboarding with only a primary action → single-item order") {
        let order = panelFocusOrder(.onboarding(hasPrimaryAction: true, hasSecondaryAction: false))
        expect(order == [.onboardingPrimaryAction], "got \(order)")
    }

    suite("panelFocusOrder: onboarding with primary + secondary → both, primary first") {
        let order = panelFocusOrder(.onboarding(hasPrimaryAction: true, hasSecondaryAction: true))
        expect(
            order == [.onboardingPrimaryAction, .onboardingSecondaryAction],
            "primary must come before secondary, got \(order)")
    }

    suite("panelFocusOrder: onboarding .installed shape (no primary, only secondary) → secondary is first focus") {
        // Mirrors `onboardingCopy(for: .installed)`: primaryActionTitle == nil,
        // secondaryActionTitle == "断开连接".
        let order = panelFocusOrder(.onboarding(hasPrimaryAction: false, hasSecondaryAction: true))
        expect(order == [.onboardingSecondaryAction], "got \(order)")
        expect(order.first == .onboardingSecondaryAction, "first focus must be the only actionable control")
    }

    suite("panelFocusOrder: onboarding with neither action → empty order (no crash)") {
        let order = panelFocusOrder(.onboarding(hasPrimaryAction: false, hasSecondaryAction: false))
        expect(order.isEmpty, "got \(order)")
    }

    suite("panelFocusOrder: operational — each row contributes action THEN mute, in Event.allCases order (follows visual left-to-right order)") {
        let order = panelFocusOrder(.operational(events: Event.allCases, packCardIDs: [], hasMasterVolume: true))
        let expected: [PanelFocusTarget] =
            Event.allCases.flatMap { [.eventAction($0), .eventMute($0)] } + [.masterVolume, .disconnect]
        expect(order == expected, "got \(order)")
    }

    suite("panelFocusOrder: operational — first focus is the first row's action control (mute sits rightmost, visually last)") {
        let order = panelFocusOrder(.operational(events: Event.allCases, packCardIDs: [], hasMasterVolume: true))
        expect(
            order.first == .eventAction(Event.allCases.first!),
            "first focus must be the first row's action control, got \(String(describing: order.first))")
    }

    suite("panelFocusOrder: operational — gallery cards come right after the master volume slider, in their given order, with 断开连接 last") {
        let order = panelFocusOrder(
            .operational(events: Event.allCases, packCardIDs: ["alpha-pack", "zeta-pack"], hasMasterVolume: true))
        // rows (action+mute per event) + the master volume slider; then the pack cards; 断开连接 last.
        // `.dropZone` used to sit between the slider and the cards — it left with `AudioDropZoneView`
        // (cc59d52 / PLAN-SOUND-MANAGER T1), so the cards now follow the slider directly.
        let rowCount = Event.allCases.count * 2 + 1  // +1 for .masterVolume
        expect(
            order[rowCount...].elementsEqual([
                .packCard(id: "alpha-pack"), .packCard(id: "zeta-pack"), .disconnect,
            ]),
            "gallery cards must follow the master volume slider in their given order, and 断开连接"
                + " sits last (it is the bottom-most control — focus order tracks visual order), got \(order)")
    }

    suite("panelFocusOrder: .masterVolume's position is pinned — right after the last row's .eventMute, right before the first pack card") {
        let order = panelFocusOrder(.operational(events: Event.allCases, packCardIDs: ["alpha-pack"], hasMasterVolume: true))
        guard let masterVolumeIndex = order.firstIndex(of: .masterVolume) else {
            expect(false, ".masterVolume must appear in the order")
            return
        }
        expect(
            order[masterVolumeIndex - 1] == .eventMute(Event.allCases.last!),
            "masterVolume must immediately follow the last row's mute toggle, got \(order[masterVolumeIndex - 1])")
        expect(
            order[masterVolumeIndex + 1] == .packCard(id: "alpha-pack"),
            "masterVolume must immediately precede the first pack card (the drop zone that used to sit"
                + " between them left with AudioDropZoneView, T1), got \(order[masterVolumeIndex + 1])")
    }

    suite("panelFocusOrder: operational — total count is 2×events + masterVolume + cards + disconnect") {
        let order = panelFocusOrder(
            .operational(events: Event.allCases, packCardIDs: ["a", "b", "c"], hasMasterVolume: true))
        // +1 masterVolume, +3 cards, +1 断开连接（T17）. `.dropZone`'s +1 left with T1.
        expect(
            order.count == Event.allCases.count * 2 + 1 + 3 + 1,
            "expected \(Event.allCases.count * 2 + 1 + 3 + 1) items, got \(order.count)")
    }

    suite("panelFocusOrder: onboarding vs operational produce structurally different orders") {
        let onboardingOrder = panelFocusOrder(.onboarding(hasPrimaryAction: true, hasSecondaryAction: false))
        let operationalOrder = panelFocusOrder(.operational(events: Event.allCases, packCardIDs: [], hasMasterVolume: true))
        expect(
            onboardingOrder != operationalOrder,
            "the two scopes must never coincidentally produce the same order shape")
        expect(
            !onboardingOrder.contains(where: { if case .eventMute = $0 { return true }; return false }),
            "onboarding's order must never contain an operational-only target")
    }

    suite("panelFocusOrder: an empty operational panel (no cards, hasMasterVolume: false — the REAL shape of .needsPack/.malformed/.unwritable, which never render the slider) is just the always-present 断开连接, never claiming a slot for .masterVolume or a removed drop zone") {
        // /codex review P1 (2626083/47459a7): .masterVolume must not appear when the slider is not
        // on screen. cc59d52 (PLAN-SOUND-MANAGER T1) additionally removed `.dropZone` — the panel
        // no longer has a bottom drop affordance, so it claims no slot for one. With zero rows,
        // zero cards and no slider, only the always-appended 断开连接 row remains.
        let order = panelFocusOrder(.operational(events: [], packCardIDs: [], hasMasterVolume: false))
        expect(
            order == [.disconnect],
            "with hasMasterVolume false, zero rows and zero cards, only 断开连接 remains —"
                + " .masterVolume and the (removed) drop zone must NOT appear, got \(order)")
    }

    suite("panelFocusOrder: an empty-rows operational panel with hasMasterVolume: true still surfaces the slider ahead of 断开连接") {
        // The flip side of the test above: hasMasterVolume, not `events` being non-empty, is
        // what gates .masterVolume. Zero rows is only a fixture (production's true .operational
        // state always has 4, see the .masterVolume position test above) — this pins the flag's
        // OWN behavior independent of row count.
        let order = panelFocusOrder(.operational(events: [], packCardIDs: [], hasMasterVolume: true))
        expect(
            order == [.masterVolume, .disconnect],
            "with hasMasterVolume true, the slider still claims its slot even with zero rows, got \(order)")
    }

    // MARK: - panelFirstFocusTarget (ENGINEERING.md「无障碍规格」"打开焦点落首个可操作项" — the
    // OPERABLE half `panelFocusOrder(_:).first` alone does not honor: a muted `.present` row's
    // 试听 ▶ is present-but-disabled, still first in the order, and must NOT get opening focus).

    suite("panelFirstFocusTarget: nothing disabled → first focus is the first row's action (same as order.first)") {
        let scope = PanelFocusScope.operational(events: Event.allCases, packCardIDs: [], hasMasterVolume: true)
        expect(
            panelFirstFocusTarget(scope) == .eventAction(Event.allCases.first!),
            "with every action operable, first focus is the first row's action, got \(String(describing: panelFirstFocusTarget(scope)))")
        expect(
            panelFirstFocusTarget(scope) == panelFocusOrder(scope).first,
            "with nothing disabled the resolver must agree with plain order.first")
    }

    suite("panelFirstFocusTarget: first row's action disabled (muted present) → first focus falls to that row's mute, NOT the dead action") {
        let first = Event.allCases[0]
        let scope = PanelFocusScope.operational(events: Event.allCases, packCardIDs: [], hasMasterVolume: true)
        let target = panelFirstFocusTarget(scope, nonOperableActionEvents: [first])
        expect(
            target == .eventMute(first),
            "first focus must skip the disabled action and land on the SAME row's (always-operable) mute, got \(String(describing: target))")
        expect(
            target != panelFocusOrder(scope).first,
            "the whole point: the resolver must diverge from order.first when order.first is a disabled action")
    }

    suite("panelFirstFocusTarget: for the SAME disabled event, it stays a Tab stop in the full order YET is skipped for opening focus") {
        let first = Event.allCases[0]
        let scope = PanelFocusScope.operational(events: Event.allCases, packCardIDs: [], hasMasterVolume: true)
        // Half A — panelFocusOrder is deliberately UNCHANGED by the fix: the disabled action is
        // still a Tab STOP in the full order (AppKit's key-loop skips disabled NSViews itself; the
        // per-row stop count stays stable). Pin the exact order so a shrink would fail here.
        let fullOrder = panelFocusOrder(scope)
        let expected: [PanelFocusTarget] =
            Event.allCases.flatMap { [.eventAction($0), .eventMute($0)] } + [.masterVolume, .disconnect]
        expect(fullOrder == expected, "the full order (incl. the disabled action) must be unchanged, got \(fullOrder)")
        expect(fullOrder.contains(.eventAction(first)), "the disabled action must remain a Tab stop")
        // Half B — the SAME event, marked non-operable, is skipped for OPENING focus only.
        let firstFocus = panelFirstFocusTarget(scope, nonOperableActionEvents: [first])
        expect(
            firstFocus == .eventMute(first),
            "opening focus must skip the disabled action to the row's mute, got \(String(describing: firstFocus))")
    }

    suite("panelFirstFocusTarget: a NON-first disabled action does not move opening focus (matches by event IDENTITY, not position)") {
        let scope = PanelFocusScope.operational(events: Event.allCases, packCardIDs: [], hasMasterVolume: true)
        // Only the THIRD event's action is disabled — the first row's action is still operable,
        // so opening focus must stay on it. Kills a mutant that skips index 0 whenever the set is
        // non-empty (which every event[0]-based suite above would let through).
        let target = panelFirstFocusTarget(scope, nonOperableActionEvents: [Event.allCases[2]])
        expect(
            target == .eventAction(Event.allCases.first!),
            "a disabled action on a LATER row must not steal the first row's opening focus, got \(String(describing: target))")
    }

    suite("panelFirstFocusTarget: only the FIRST action is skipped, not the whole row — lands on mute(first), never mute(second)") {
        let first = Event.allCases[0]
        let second = Event.allCases[1]
        let scope = PanelFocusScope.operational(events: Event.allCases, packCardIDs: [], hasMasterVolume: true)
        // Both first two rows muted: focus still stops at the first operable slot it reaches,
        // which is the FIRST row's mute (one slot to the right of its disabled action).
        let target = panelFirstFocusTarget(scope, nonOperableActionEvents: [first, second])
        expect(
            target == .eventMute(first),
            "must land on the first row's mute, not skip ahead to a later row, got \(String(describing: target))")
    }

    suite("panelFirstFocusTarget: every action disabled → first focus is still the first row's mute (mute is always operable)") {
        let scope = PanelFocusScope.operational(events: Event.allCases, packCardIDs: [], hasMasterVolume: true)
        let target = panelFirstFocusTarget(scope, nonOperableActionEvents: Set(Event.allCases))
        expect(
            target == .eventMute(Event.allCases.first!),
            "with all actions disabled the first operable target is the first row's mute, got \(String(describing: target))")
    }

    suite("panelFirstFocusTarget: onboarding scope ignores nonOperableActionEvents (it has no action targets)") {
        let scope = PanelFocusScope.onboarding(hasPrimaryAction: true, hasSecondaryAction: true)
        let target = panelFirstFocusTarget(scope, nonOperableActionEvents: Set(Event.allCases))
        expect(
            target == .onboardingPrimaryAction,
            "onboarding first focus is unaffected by action operability, got \(String(describing: target))")
    }

    suite("panelFirstFocusTarget: empty operational panel, hasMasterVolume false, no cards (the REAL .needsPack/.malformed/.unwritable shape with nothing installed) → first focus is the always-present 断开连接, never the (unrendered) slider or a removed drop zone") {
        // /codex review P1 (2626083/47459a7): zero events is NOT "unreachable in shipping code" —
        // `PanelView.applyFirstFocus` passes `rows: []`, `hasMasterVolume: false` whenever
        // `configState` is `.needsPack`/`.malformed`/`.unwritable` (first launch before a pack is
        // picked, or a corrupted/unwritable config.json). cc59d52 (PLAN-SOUND-MANAGER T1) removed
        // `.dropZone` (its view was deleted), so with no rows, no cards and no slider the first —
        // and only — operable target is the always-appended `.disconnect` row. (T7 will give this
        // shape a better landing via `.manageSounds`; until then 断开连接 is the honest one, never
        // a ghost focus slot.)
        let scope = PanelFocusScope.operational(events: [], packCardIDs: [], hasMasterVolume: false)
        expect(
            panelFirstFocusTarget(scope) == .disconnect,
            "with no rows/cards/slider, first focus must be the always-present 断开连接, never"
                + " .masterVolume or a removed drop zone, got \(String(describing: panelFirstFocusTarget(scope)))")
    }

    suite("panelFirstFocusTarget: empty operational panel with pack cards (the COMMON .needsPack 'pick a pack' shape) → first focus is the first pack card, not 断开连接") {
        // The common first-launch shape: no pack selected yet, but packs ARE installed and their
        // cards are on screen (`needsPackNotice` tells the user '点一张卡片'). The pack gallery
        // renders in every `configState`, so opening focus lands on the first pack card — the
        // panel's actual primary action — not skips past it to the destructive 断开连接. Before
        // cc59d52 this landed on the (view-less) `.dropZone`; removing it fixed that.
        let scope = PanelFocusScope.operational(events: [], packCardIDs: ["alpha-pack", "zeta-pack"], hasMasterVolume: false)
        expect(
            panelFirstFocusTarget(scope) == .packCard(id: "alpha-pack"),
            "first focus must be the first pack card, got \(String(describing: panelFirstFocusTarget(scope)))")
    }

    suite("panelFirstFocusTarget: empty operational panel, hasMasterVolume true → first focus IS the master volume slider (never nil)") {
        // The flag's own positive case, kept alongside the negative one above so a future
        // reader can't mistake "gate .masterVolume" for "never show .masterVolume".
        let scope = PanelFocusScope.operational(events: [], packCardIDs: [], hasMasterVolume: true)
        expect(
            panelFirstFocusTarget(scope) == .masterVolume,
            "with the slider truly on screen, first focus is never nil, got \(String(describing: panelFirstFocusTarget(scope)))")
    }

    suite("panelFirstFocusTarget: onboarding with neither CTA → nil (nothing to focus)") {
        let scope = PanelFocusScope.onboarding(hasPrimaryAction: false, hasSecondaryAction: false)
        expect(
            panelFirstFocusTarget(scope) == nil,
            "an empty order has no operable first target, got \(String(describing: panelFirstFocusTarget(scope)))")
    }

    // MARK: - panelOpeningFocus (T16 review 修复⑥) — the COMPOSITION `PanelView` performs when the
    // popover opens: rows → scope, rows → nonOperableActionEvents (via EventRow.eventActionOperable),
    // → panelFirstFocusTarget. Every ingredient above was thoroughly tested while the composition
    // itself lived as private members of a SwiftUI view: reverting the view to plain
    // `panelFocusOrder(scope).first` — i.e. reintroducing the exact bug the resolver exists to fix —
    // left the entire suite green. It is a pure function now, so it can be pinned on this machine.

    suite("panelOpeningFocus: nothing muted → opening focus is the first row's action (agrees with order.first when nothing is disabled)") {
        let rows = Event.allCases.map {
            EventRow(event: $0, coverage: .present(fileName: "\($0.cliName).mp3"), enabled: true)
        }
        let target = panelOpeningFocus(rows: rows, packCardIDs: ["alpha-pack"], hasMasterVolume: true)
        expect(
            target == .eventAction(Event.allCases.first!),
            "with every action operable, opening focus is the first row's action, got \(String(describing: target))")
        expect(
            target == panelFocusOrder(.operational(events: rows.map(\.event), packCardIDs: ["alpha-pack"], hasMasterVolume: true)).first,
            "when nothing is disabled it must AGREE with order.first — the divergence below is not"
                + " an unconditional off-by-one")
    }

    // THE load-bearing assertion of the whole fix: first row is `.present` + MUTED, so its 试听 ▶
    // renders `.disabled(true)` while still owning `.eventAction` and still sitting first in the
    // order. `order.first` would park the opening keyboard caret on that dead control
    // (ENGINEERING.md「无障碍规格」"打开焦点落首个可操作项" — 可操作 is the load-bearing word).
    // The `!=` half is what turns RED the moment anyone reverts to `panelFocusOrder(...).first`.
    suite("panelOpeningFocus: a MUTED .present first row → focus lands on that row's mute toggle, and must NOT equal panelFocusOrder(...).first") {
        let first = Event.allCases[0]
        var rows = Event.allCases.map {
            EventRow(event: $0, coverage: .present(fileName: "\($0.cliName).mp3"), enabled: true)
        }
        rows[0] = EventRow(event: first, coverage: .present(fileName: "\(first.cliName).mp3"), enabled: false)
        let packCardIDs = ["alpha-pack", "zeta-pack"]

        let target = panelOpeningFocus(rows: rows, packCardIDs: packCardIDs, hasMasterVolume: true)
        expect(
            target == .eventMute(first),
            "opening focus must skip the muted row's disabled 试听 ▶ and land on the SAME row's"
                + " (always-operable) mute toggle, got \(String(describing: target))")

        let order = panelFocusOrder(.operational(events: rows.map(\.event), packCardIDs: packCardIDs, hasMasterVolume: true))
        expect(
            target != order.first,
            "the entire point of this function: it must DIVERGE from panelFocusOrder(...).first here"
                + " — order.first is \(String(describing: order.first)), a dimmed control that does nothing")
        expect(
            order.first == .eventAction(first),
            "sanity: the disabled action is still first in the traversal order (and still a Tab stop)"
                + " — the fix changes opening focus only, never the order")
    }

    suite("panelOpeningFocus: an UNMAPPED muted first row keeps opening focus on its action (the import affordance is always operable — mute alone must not divert focus)") {
        let first = Event.allCases[0]
        var rows = Event.allCases.map {
            EventRow(event: $0, coverage: .present(fileName: "\($0.cliName).mp3"), enabled: true)
        }
        rows[0] = EventRow(event: first, coverage: .unmapped, enabled: false)
        let target = panelOpeningFocus(rows: rows, packCardIDs: [], hasMasterVolume: true)
        expect(
            target == .eventAction(first),
            "muting an .unmapped row does NOT disable its action slot (the import affordance), so"
                + " opening focus must stay on it — kills a mutant that keys the skip off `enabled`"
                + " alone rather than EventRow.eventActionOperable, got \(String(describing: target))")
    }

    suite("panelOpeningFocus: every row muted+present → focus lands on the FIRST row's mute (never skips ahead to a later row)") {
        let rows = Event.allCases.map {
            EventRow(event: $0, coverage: .present(fileName: "\($0.cliName).mp3"), enabled: false)
        }
        let target = panelOpeningFocus(rows: rows, packCardIDs: [], hasMasterVolume: true)
        expect(
            target == .eventMute(Event.allCases.first!),
            "the first OPERABLE slot is the first row's mute, got \(String(describing: target))")
    }

    suite("panelOpeningFocus: every row muted → first focus is the first row's mute, NEVER the master volume slider (the slider only wins opening focus when the row list is empty, see the hasMasterVolume-gated tests below)") {
        let rows = Event.allCases.map {
            EventRow(event: $0, coverage: .present(fileName: "\($0.cliName).mp3"), enabled: false)
        }
        let target = panelOpeningFocus(rows: rows, packCardIDs: [], hasMasterVolume: true)
        expect(
            target == .eventMute(Event.allCases.first!),
            "with every row muted, first focus is still the first row's mute, got \(String(describing: target))")
        expect(
            target != .masterVolume,
            "the master volume slider must never steal opening focus away from an operable event"
                + " row toggle, got \(String(describing: target))")
    }

    suite("panelOpeningFocus: zero rows, hasMasterVolume false, with a pack card (the REAL .needsPack 'pick a pack' shape) → first focus is the first pack card, never the (unrendered) slider or a removed drop zone") {
        // /codex review P1 (2626083/47459a7): `PanelView.applyFirstFocus` calls
        // `panelOpeningFocus` with `rows: []` AND `hasMasterVolume: false` together whenever the
        // panel is NOT truly operational — a common real shape (first launch before a pack is
        // picked, or a corrupted/unwritable config.json), not a fixture-only edge case. cc59d52
        // (PLAN-SOUND-MANAGER T1) removed `.dropZone`; the pack gallery is still rendered in every
        // configState, so opening focus now lands on the first pack card — the panel's own primary
        // action ('点一张卡片') — instead of the deleted drop zone. `hasMasterVolume` is a literal
        // `false` because this fixture models a NON-operational panel, and `MasterVolumeRow` is
        // rendered by exactly one branch of `operationalPanel` — the `.operational` one; the real
        // caller passes `isOperational`, so `false` is what it would pass for this shape too.
        expect(
            panelOpeningFocus(rows: [], packCardIDs: ["alpha-pack"], hasMasterVolume: false) == .packCard(id: "alpha-pack"),
            "opening focus must be the first pack card, never .masterVolume or a removed drop zone,"
                + " when the slider isn't actually rendered")
    }

    suite("panelOpeningFocus: zero rows, hasMasterVolume true → the master volume slider, never nil") {
        // The flag's positive case: .masterVolume, always operable, sits ahead of the pack cards
        // in the order whenever it's actually present. Zero rows here is only a fixture (a truly
        // .operational configState always has 4 real rows) — this pins the flag's own behavior.
        expect(
            panelOpeningFocus(rows: [], packCardIDs: ["alpha-pack"], hasMasterVolume: true) == .masterVolume,
            "with the slider on screen, opening focus is never nil and lands on it ahead of the pack cards")
    }
}

// MARK: - T17: a CTA that is mid-flight cannot hold focus

@MainActor
func runPanelFocusInFlightSuites() {
    suite("panelFirstFocusTarget: 动作跑到一半时，禁用的 CTA 不能拿首焦点（onboarding）") {
        let scope = PanelFocusScope.onboarding(hasPrimaryAction: true, hasSecondaryAction: true)

        expect(
            panelFirstFocusTarget(scope, ctaOperable: true) == .onboardingPrimaryAction,
            "空闲时首焦点当然是主 CTA")
        expect(
            panelFirstFocusTarget(scope, ctaOperable: false) == nil,
            "in-flight 期间两颗 CTA 都 .disabled —— 焦点不能停在一个已经死掉的控件上。"
                + "键盘用户在「接管」上按完空格之后，caret 必须有人接管，而不是悬在那儿")
    }

    suite("panelOpeningFocus: 断开跑到一半时，禁用的「断开连接」不能拿首焦点（operational）") {
        let rows = Event.allCases.map { event in
            EventRow(event: event, coverage: .unmapped, enabled: true)
        }
        // 全 unmapped：每行的 action 槽是永远可操作的导入入口，所以首焦点仍是第一行。4 行真事件、
        // ctaOperable: false、`hasMasterVolume: true` —— 阶段 D（MasterVolumeRow，8771946）落地后
        // 这整个组合都是**真实**操作态的形状，不再是为测 flag 而拼的虚构值：`.operational` 面板
        // 今天确实渲染滑块，真实调用方（`PanelView.applyFirstFocus`）传的就是 `isOperational`。
        expect(
            panelOpeningFocus(rows: rows, packCardIDs: [], ctaOperable: false, hasMasterVolume: true)
                == .eventAction(Event.allCases[0]),
            "operational 面板里首焦点本来就不是断开连接，禁用它不该改变这一点")

        // 极端情形：没有事件行、没有包卡、hasMasterVolume: false —— 这正是 `.needsPack`/
        // `.malformed`/`.unwritable` 的真实形状（`/codex review` P1，2626083/47459a7），且此刻有
        // 动作在飞（ctaOperable == false）。cc59d52（PLAN-SOUND-MANAGER T1）删掉 `.dropZone` 后，
        // 面板底部不再有恒可操作的落点；唯一的 `.disconnect` 又被 in-flight 禁用 —— 于是首焦点
        // 诚实地是 nil（与 onboarding in-flight 同型），而不是一个已删控件的幽灵。T7 的
        // `.manageSounds`（in-flight 也恒可操作）会把这一格重新变成非 nil。
        expect(
            panelOpeningFocus(rows: [], packCardIDs: [], ctaOperable: false, hasMasterVolume: false) == nil,
            "断开被禁用、滑块不在屏幕上、且拖放区已随 T1 删除时，没有可操作控件，首焦点诚实为 nil")
    }
}
