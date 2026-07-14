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
        let order = panelFocusOrder(.operational(events: Event.allCases, packCardIDs: []))
        let expected: [PanelFocusTarget] =
            Event.allCases.flatMap { [.eventAction($0), .eventMute($0)] } + [.masterVolume, .dropZone, .disconnect]
        expect(order == expected, "got \(order)")
    }

    suite("panelFocusOrder: operational — first focus is the first row's action control (mute sits rightmost, visually last)") {
        let order = panelFocusOrder(.operational(events: Event.allCases, packCardIDs: []))
        expect(
            order.first == .eventAction(Event.allCases.first!),
            "first focus must be the first row's action control, got \(String(describing: order.first))")
    }

    suite("panelFocusOrder: operational — drop zone comes after every row, before any gallery card") {
        let order = panelFocusOrder(
            .operational(events: Event.allCases, packCardIDs: ["alpha-pack", "zeta-pack"]))
        guard let dropZoneIndex = order.firstIndex(of: .dropZone) else {
            expect(false, "dropZone must appear in the order")
            return
        }
        // +1 accounts for .masterVolume, which sits between the last row and the drop zone.
        let rowCount = Event.allCases.count * 2 + 1
        expect(dropZoneIndex == rowCount, "dropZone must sit right after all row controls (incl. the master volume slider), got index \(dropZoneIndex)")
        expect(
            order[(dropZoneIndex + 1)...].elementsEqual([
                .packCard(id: "alpha-pack"), .packCard(id: "zeta-pack"), .disconnect,
            ]),
            "gallery cards must follow the drop zone in their given order, and 断开连接 sits last"
                + " (it is the bottom-most control — focus order tracks visual order), got \(order)")
    }

    suite("panelFocusOrder: .masterVolume's position is pinned — right after the last row's .eventMute, right before .dropZone") {
        let order = panelFocusOrder(.operational(events: Event.allCases, packCardIDs: ["alpha-pack"]))
        guard let masterVolumeIndex = order.firstIndex(of: .masterVolume) else {
            expect(false, ".masterVolume must appear in the order")
            return
        }
        expect(
            order[masterVolumeIndex - 1] == .eventMute(Event.allCases.last!),
            "masterVolume must immediately follow the last row's mute toggle, got \(order[masterVolumeIndex - 1])")
        expect(
            order[masterVolumeIndex + 1] == .dropZone,
            "masterVolume must immediately precede the drop zone, got \(order[masterVolumeIndex + 1])")
    }

    suite("panelFocusOrder: operational — total count is 2×events + dropZone + cards + disconnect") {
        let order = panelFocusOrder(
            .operational(events: Event.allCases, packCardIDs: ["a", "b", "c"]))
        // +1 masterVolume, +1 dropZone, +3 cards, +1 断开连接（T17）
        expect(
            order.count == Event.allCases.count * 2 + 1 + 1 + 3 + 1,
            "expected \(Event.allCases.count * 2 + 1 + 1 + 3 + 1) items, got \(order.count)")
    }

    suite("panelFocusOrder: onboarding vs operational produce structurally different orders") {
        let onboardingOrder = panelFocusOrder(.onboarding(hasPrimaryAction: true, hasSecondaryAction: false))
        let operationalOrder = panelFocusOrder(.operational(events: Event.allCases, packCardIDs: []))
        expect(
            onboardingOrder != operationalOrder,
            "the two scopes must never coincidentally produce the same order shape")
        expect(
            !onboardingOrder.contains(where: { if case .eventMute = $0 { return true }; return false }),
            "onboarding's order must never contain an operational-only target")
    }

    suite("panelFocusOrder: an empty operational panel (no cards) still ends at the drop zone + 断开连接") {
        let order = panelFocusOrder(.operational(events: [], packCardIDs: []))
        // .masterVolume is unconditional in the .operational scope (not gated on events being
        // non-empty) — zero rows is only a fixture, production always has 4 (see below).
        expect(
            order == [.masterVolume, .dropZone, .disconnect],
            "with zero rows and zero cards, only the master volume slider, drop zone, and"
                + " 断开连接 remain, got \(order)")
    }

    // MARK: - panelFirstFocusTarget (ENGINEERING.md「无障碍规格」"打开焦点落首个可操作项" — the
    // OPERABLE half `panelFocusOrder(_:).first` alone does not honor: a muted `.present` row's
    // 试听 ▶ is present-but-disabled, still first in the order, and must NOT get opening focus).

    suite("panelFirstFocusTarget: nothing disabled → first focus is the first row's action (same as order.first)") {
        let scope = PanelFocusScope.operational(events: Event.allCases, packCardIDs: [])
        expect(
            panelFirstFocusTarget(scope) == .eventAction(Event.allCases.first!),
            "with every action operable, first focus is the first row's action, got \(String(describing: panelFirstFocusTarget(scope)))")
        expect(
            panelFirstFocusTarget(scope) == panelFocusOrder(scope).first,
            "with nothing disabled the resolver must agree with plain order.first")
    }

    suite("panelFirstFocusTarget: first row's action disabled (muted present) → first focus falls to that row's mute, NOT the dead action") {
        let first = Event.allCases[0]
        let scope = PanelFocusScope.operational(events: Event.allCases, packCardIDs: [])
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
        let scope = PanelFocusScope.operational(events: Event.allCases, packCardIDs: [])
        // Half A — panelFocusOrder is deliberately UNCHANGED by the fix: the disabled action is
        // still a Tab STOP in the full order (AppKit's key-loop skips disabled NSViews itself; the
        // per-row stop count stays stable). Pin the exact order so a shrink would fail here.
        let fullOrder = panelFocusOrder(scope)
        let expected: [PanelFocusTarget] =
            Event.allCases.flatMap { [.eventAction($0), .eventMute($0)] } + [.masterVolume, .dropZone, .disconnect]
        expect(fullOrder == expected, "the full order (incl. the disabled action) must be unchanged, got \(fullOrder)")
        expect(fullOrder.contains(.eventAction(first)), "the disabled action must remain a Tab stop")
        // Half B — the SAME event, marked non-operable, is skipped for OPENING focus only.
        let firstFocus = panelFirstFocusTarget(scope, nonOperableActionEvents: [first])
        expect(
            firstFocus == .eventMute(first),
            "opening focus must skip the disabled action to the row's mute, got \(String(describing: firstFocus))")
    }

    suite("panelFirstFocusTarget: a NON-first disabled action does not move opening focus (matches by event IDENTITY, not position)") {
        let scope = PanelFocusScope.operational(events: Event.allCases, packCardIDs: [])
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
        let scope = PanelFocusScope.operational(events: Event.allCases, packCardIDs: [])
        // Both first two rows muted: focus still stops at the first operable slot it reaches,
        // which is the FIRST row's mute (one slot to the right of its disabled action).
        let target = panelFirstFocusTarget(scope, nonOperableActionEvents: [first, second])
        expect(
            target == .eventMute(first),
            "must land on the first row's mute, not skip ahead to a later row, got \(String(describing: target))")
    }

    suite("panelFirstFocusTarget: every action disabled → first focus is still the first row's mute (mute is always operable)") {
        let scope = PanelFocusScope.operational(events: Event.allCases, packCardIDs: [])
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

    suite("panelFirstFocusTarget: empty operational panel → first focus is the master volume slider (never nil)") {
        let scope = PanelFocusScope.operational(events: [], packCardIDs: [])
        // Zero events is only a fixture — production always renders 4 rows (packCoverage's
        // branches are both `Event.allCases.map`, see CoverageState.swift), so .masterVolume
        // being first here (ahead of .dropZone) is unreachable in shipping code.
        expect(
            panelFirstFocusTarget(scope) == .masterVolume,
            "an operational panel always contains the master volume slider ahead of the drop"
                + " zone, so first focus is never nil, got \(String(describing: panelFirstFocusTarget(scope)))")
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
        let target = panelOpeningFocus(rows: rows, packCardIDs: ["alpha-pack"])
        expect(
            target == .eventAction(Event.allCases.first!),
            "with every action operable, opening focus is the first row's action, got \(String(describing: target))")
        expect(
            target == panelFocusOrder(.operational(events: rows.map(\.event), packCardIDs: ["alpha-pack"])).first,
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

        let target = panelOpeningFocus(rows: rows, packCardIDs: packCardIDs)
        expect(
            target == .eventMute(first),
            "opening focus must skip the muted row's disabled 试听 ▶ and land on the SAME row's"
                + " (always-operable) mute toggle, got \(String(describing: target))")

        let order = panelFocusOrder(.operational(events: rows.map(\.event), packCardIDs: packCardIDs))
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
        let target = panelOpeningFocus(rows: rows, packCardIDs: [])
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
        let target = panelOpeningFocus(rows: rows, packCardIDs: [])
        expect(
            target == .eventMute(Event.allCases.first!),
            "the first OPERABLE slot is the first row's mute, got \(String(describing: target))")
    }

    suite("panelOpeningFocus: every row muted → first focus is the first row's mute, NEVER the master volume slider (the slider only wins opening focus when the row list is empty — an unreachable-in-production fixture, see above)") {
        let rows = Event.allCases.map {
            EventRow(event: $0, coverage: .present(fileName: "\($0.cliName).mp3"), enabled: false)
        }
        let target = panelOpeningFocus(rows: rows, packCardIDs: [])
        expect(
            target == .eventMute(Event.allCases.first!),
            "with every row muted, first focus is still the first row's mute, got \(String(describing: target))")
        expect(
            target != .masterVolume,
            "the master volume slider must never steal opening focus away from an operable event"
                + " row toggle, got \(String(describing: target))")
    }

    suite("panelOpeningFocus: zero rows (packs still loading) → the master volume slider, never nil") {
        // Zero rows is only a fixture (production always has 4, see the .operational fixture
        // note above) — .masterVolume, always operable, sits ahead of .dropZone in the order.
        expect(
            panelOpeningFocus(rows: [], packCardIDs: ["alpha-pack"]) == .masterVolume,
            "an operational panel always contains the master volume slider, so opening focus is never nil")
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
        // 全 unmapped：每行的 action 槽是永远可操作的导入入口，所以首焦点仍是第一行。
        expect(
            panelOpeningFocus(rows: rows, packCardIDs: [], ctaOperable: false)
                == .eventAction(Event.allCases[0]),
            "operational 面板里首焦点本来就不是断开连接，禁用它不该改变这一点")

        // 极端情形：没有事件行、没有包卡 —— 唯一的候选是 masterVolume（恒可操作，且排在 dropZone
        // 之前）、dropZone、disconnect（disabled）。零行只是 fixture，生产恒 4 行。
        expect(
            panelOpeningFocus(rows: [], packCardIDs: [], ctaOperable: false) == .masterVolume,
            "断开被禁用时，焦点该落在仍然可操作的主音量滑块上")
    }
}
