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
        let expected: [PanelFocusTarget] = Event.allCases.flatMap { [.eventAction($0), .eventMute($0)] } + [.dropZone]
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
        let rowCount = Event.allCases.count * 2
        expect(dropZoneIndex == rowCount, "dropZone must sit right after all row controls, got index \(dropZoneIndex)")
        expect(
            order[(dropZoneIndex + 1)...].elementsEqual([.packCard(id: "alpha-pack"), .packCard(id: "zeta-pack")]),
            "gallery cards must follow the drop zone in their given order, got \(order)")
    }

    suite("panelFocusOrder: operational — total count is 2×events + dropZone + cards") {
        let order = panelFocusOrder(
            .operational(events: Event.allCases, packCardIDs: ["a", "b", "c"]))
        expect(
            order.count == Event.allCases.count * 2 + 1 + 3,
            "expected \(Event.allCases.count * 2 + 1 + 3) items, got \(order.count)")
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

    suite("panelFocusOrder: an empty operational panel (no cards) still ends at the drop zone") {
        let order = panelFocusOrder(.operational(events: [], packCardIDs: []))
        expect(order == [.dropZone], "with zero rows and zero cards, only the drop zone remains, got \(order)")
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
        let expected: [PanelFocusTarget] = Event.allCases.flatMap { [.eventAction($0), .eventMute($0)] } + [.dropZone]
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

    suite("panelFirstFocusTarget: empty operational panel → first focus is the drop zone (never nil)") {
        let scope = PanelFocusScope.operational(events: [], packCardIDs: [])
        expect(
            panelFirstFocusTarget(scope) == .dropZone,
            "an operational panel always ends at the drop zone, so first focus is never nil, got \(String(describing: panelFirstFocusTarget(scope)))")
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

    suite("panelOpeningFocus: zero rows (packs still loading) → the drop zone, never nil") {
        expect(
            panelOpeningFocus(rows: [], packCardIDs: ["alpha-pack"]) == .dropZone,
            "an operational panel always contains the drop zone, so opening focus is never nil")
    }
}
