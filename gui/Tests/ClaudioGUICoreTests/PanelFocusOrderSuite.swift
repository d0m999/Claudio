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

    suite("panelFocusOrder: operational — each row contributes eventSound THEN action THEN mute, in Event.allCases order (follows visual left-to-right order, PLAN-SOUND-MANAGER.md §2.5/T2's 3-slot row)") {
        let order = panelFocusOrder(.operational(events: Event.allCases, packCardIDs: [], hasMasterVolume: true))
        let expected: [PanelFocusTarget] =
            Event.allCases.flatMap { [.eventSound($0), .eventAction($0), .eventMute($0)]
            } + [.masterVolume, .manageSounds, .quitApplication]
        expect(order == expected, "got \(order)")
    }

    suite("panelFocusOrder: operational — first focus is the first row's file-name Menu (eventSound sits leftmost, visually first; mute sits rightmost, visually last)") {
        let order = panelFocusOrder(.operational(events: Event.allCases, packCardIDs: [], hasMasterVolume: true))
        expect(
            order.first == .eventSound(Event.allCases.first!),
            "first focus must be the first row's file-name Menu, got \(String(describing: order.first))")
    }

    suite("panelFocusOrder: production 双宿主形状固定 Claude → Codex → 五事件 → 音量 → 声音包 → 管理") {
        let order = panelFocusOrder(
            .operational(
                events: Event.allCases,
                packCardIDs: ["minimal-chime"],
                hasMasterVolume: true,
                hostSources: HostID.allCases))
        let expected: [PanelFocusTarget] = [
            .hostSource(.claudeCode), .hostSource(.codex),
        ] + Event.allCases.flatMap {
            [.eventSound($0), .eventAction($0), .eventMute($0)]
        } + [
            .masterVolume, .packCard(id: "minimal-chime"), .manageSounds, .quitApplication,
        ]
        expect(order == expected, "production focus order drifted: \(order)")
        expect(
            panelFirstFocusTarget(
                .operational(
                    events: [], packCardIDs: [], hasMasterVolume: false,
                    hasConfigFailureNotice: true, hostSources: HostID.allCases))
                == .hostSource(.claudeCode),
            "宿主行必须领先 config 修复卡；一侧坏掉也不能让焦点跳过来源区")
        expect(
            panelOpeningFocus(
                rows: [], packCardIDs: [], hasMasterVolume: false,
                hostSources: HostID.allCases) == .hostSource(.claudeCode),
            "production opening focus 必须落 Claude 来源行")
    }

    suite("panelFocusOrder: operational — gallery cards come right after the master volume slider, then 管理声音包, with 退出应用 last") {
        let order = panelFocusOrder(
            .operational(events: Event.allCases, packCardIDs: ["alpha-pack", "zeta-pack"], hasMasterVolume: true))
        // rows (sound+action+mute per event) + the master volume slider; then cards, management, quit.
        // `.dropZone` used to sit between the slider and the cards — it left with `AudioDropZoneView`
        // (cc59d52 / PLAN-SOUND-MANAGER T1), so the cards now follow the slider directly.
        let rowCount = Event.allCases.count * 3 + 1  // +1 for .masterVolume
        expect(
            order[rowCount...].elementsEqual([
                .packCard(id: "alpha-pack"), .packCard(id: "zeta-pack"), .manageSounds,
                .quitApplication,
            ]),
            "gallery cards must follow the master volume slider in their given order, 管理声音包"
                + " must follow the cards, and 退出应用 sits last, got \(order)")
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

    suite("panelFocusOrder: operational — total count is 3×events + masterVolume + cards + manageSounds + quitApplication") {
        let order = panelFocusOrder(
            .operational(events: Event.allCases, packCardIDs: ["a", "b", "c"], hasMasterVolume: true))
        // +1 masterVolume, +3 cards, +1 管理声音包, +1 退出应用。3× events
        // since PLAN-SOUND-MANAGER.md §2.5/T2 grew each row from 2 slots (action, mute) to 3
        // (sound, action, mute).
        expect(
            order.count == Event.allCases.count * 3 + 1 + 3 + 1 + 1,
            "expected \(Event.allCases.count * 3 + 1 + 3 + 1 + 1) items, got \(order.count)")
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

    suite("panelFocusOrder: an empty operational panel (no cards, hasMasterVolume: false, no config-failure notice) is [.manageSounds, .quitApplication]") {
        // /codex review P1 (2626083/47459a7): .masterVolume must not appear when the slider is not
        // on screen. cc59d52 (PLAN-SOUND-MANAGER T1) additionally removed `.dropZone` — the panel
        // no longer has a bottom drop affordance. T7's real, always-rendered 管理声音包 control
        // replaces the safe bottom landing; the fixed quit footer follows without taking first focus.
        //
        // This is the `.needsPack`-with-nothing shape ONLY. `.malformed`/`.unwritable` also render
        // zero rows / no slider, but they carry the 诚实失败卡's `.configReveal` (hasConfigFailureNotice:
        // true), which leads the order — pinned separately below (26bba37 follow-up). Keeping this
        // fixture at the default `hasConfigFailureNotice: false` is what makes it the needsPack case.
        let order = panelFocusOrder(.operational(events: [], packCardIDs: [], hasMasterVolume: false))
        expect(
            order == [.manageSounds, .quitApplication],
            "with hasMasterVolume false, zero rows and zero cards, 管理声音包 must be the first"
                + " safe target and 退出应用 must remain last, got \(order)")
    }

    suite("panelFocusOrder: an empty-rows operational panel with hasMasterVolume: true still surfaces the slider ahead of quit") {
        // The flip side of the test above: hasMasterVolume, not `events` being non-empty, is
        // what gates .masterVolume. Zero rows is only a fixture (production's true .operational
        // state always has 5, see the .masterVolume position test above) — this pins the flag's
        // OWN behavior independent of row count.
        let order = panelFocusOrder(.operational(events: [], packCardIDs: [], hasMasterVolume: true))
        expect(
            order == [.masterVolume, .manageSounds, .quitApplication],
            "with hasMasterVolume true, the slider still claims its slot even with zero rows,"
                + " ahead of 管理声音包 and 退出应用, got \(order)")
    }

    // MARK: - .configReveal (/codex review P1, 26bba37 follow-up): the 诚实失败卡's
    // 「在访达中显示 config.json」 is a real focus target that LEADS the order on
    // `.malformed`/`.unwritable` — the two states that render the failure card at the panel top.

    suite("panelFocusOrder: the config-failure shape (.malformed/.unwritable, no cards) leads with .configReveal, then .manageSounds, then .quitApplication") {
        // These two states render `configFailureNotice` at the TOP of the panel; its reveal button
        // is visually first, so it must lead the focus order. No pack cards installed here →
        // .configReveal, then the always-rendered .manageSounds, then .quitApplication. Contrast the
        // .needsPack-nothing shape above: it has NO failure notice and so leads with .manageSounds.
        let order = panelFocusOrder(
            .operational(events: [], packCardIDs: [], hasMasterVolume: false, hasConfigFailureNotice: true))
        expect(
            order == [.configReveal, .manageSounds, .quitApplication],
            ".configReveal must lead the config-failure shape, with 管理声音包 still present"
                + " ahead of 退出应用, got \(order)")
    }

    suite("panelFocusOrder: the config-failure shape WITH pack cards leads with .configReveal, then cards, .manageSounds, and .quitApplication (never folds into the plain .needsPack card order)") {
        // `.malformed`/`.unwritable` can still have packs installed (the gallery renders in every
        // configState). The reveal button is above the gallery, so .configReveal leads, THEN the
        // cards. This is the exact case the pre-fix tests wrongly folded into the .needsPack
        // 'first pack card' assertion — the reveal button was skipped entirely.
        let order = panelFocusOrder(
            .operational(
                events: [], packCardIDs: ["alpha-pack", "zeta-pack"], hasMasterVolume: false,
                hasConfigFailureNotice: true))
        expect(
            order == [
                .configReveal, .packCard(id: "alpha-pack"), .packCard(id: "zeta-pack"),
                .manageSounds, .quitApplication,
            ],
            ".configReveal must lead, ahead of the pack cards; 管理声音包 must follow the cards"
                + " and 退出应用 must remain last, got \(order)")
    }

    suite("panelFocusOrder: quit appears exactly once and is always last in every operational shape, never onboarding") {
        let operationalShapes: [PanelFocusScope] = [
            .operational(events: Event.allCases, packCardIDs: [], hasMasterVolume: true),
            .operational(events: [], packCardIDs: [], hasMasterVolume: false),
            .operational(
                events: [], packCardIDs: ["alpha-pack"], hasMasterVolume: false,
                hasConfigFailureNotice: true, hostSources: HostID.allCases),
        ]
        for scope in operationalShapes {
            let order = panelFocusOrder(scope)
            expect(
                order.filter { $0 == .quitApplication }.count == 1,
                "every operational order must contain quit exactly once, got \(order)")
            expect(order.last == .quitApplication, "quit must always be last, got \(order)")
        }
        for scope in [
            PanelFocusScope.onboarding(hasPrimaryAction: true, hasSecondaryAction: true),
            .onboarding(hasPrimaryAction: false, hasSecondaryAction: false),
        ] {
            expect(
                !panelFocusOrder(scope).contains(.quitApplication),
                "onboarding must never contain quit: \(panelFocusOrder(scope))")
        }
    }

    // MARK: - panelFirstFocusTarget (ENGINEERING.md「无障碍规格」"打开焦点落首个可操作项"). Before
    // PLAN-SOUND-MANAGER.md §2.5/T2, `.eventAction` (试听 ▶) was each row's FIRST slot, and a
    // muted `.present` row's disabled preview needed an explicit skip-to-mute resolver — that is
    // what the whole `nonOperableActionEvents` mechanism below was built for. T2 inserted
    // ``PanelFocusTarget/eventSound(_:)`` (the file-name `Menu`) BEFORE `.eventAction` in every
    // row, and it is UNCONDITIONALLY operable (picking a file is always legal, mute or coverage
    // state notwithstanding — see ``panelFirstFocusTarget(_:nonOperableActionEvents:ctaOperable:)``'s
    // own `case .eventSound: return true`). The mechanical consequence, pinned below: whenever
    // `events` is non-empty, the very FIRST entry `panelFocusOrder(_:)` produces is that first
    // event's `.eventSound`, which is always operable — so `panelFirstFocusTarget`/
    // `panelOpeningFocus` NEVER even reaches `.eventAction` to decide whether to skip it.
    // `nonOperableActionEvents` no longer moves OPENING focus at all (it still describes real,
    // disabled `.eventAction` Tab stops AppKit's own key-loop skips during normal Tab traversal —
    // `panelFocusOrder(_:)` itself is unchanged and still lists them).

    suite("panelFirstFocusTarget: nothing disabled → first focus is the first row's file-name Menu (eventSound), same as order.first") {
        let scope = PanelFocusScope.operational(events: Event.allCases, packCardIDs: [], hasMasterVolume: true)
        expect(
            panelFirstFocusTarget(scope) == .eventSound(Event.allCases.first!),
            "with every action operable, first focus is the first row's eventSound, got \(String(describing: panelFirstFocusTarget(scope)))")
        expect(
            panelFirstFocusTarget(scope) == panelFocusOrder(scope).first,
            "with nothing disabled the resolver must agree with plain order.first")
    }

    suite("panelFirstFocusTarget: first row's action disabled (muted present) → first focus is STILL that row's eventSound — the disabled action is never even reached") {
        let first = Event.allCases[0]
        let scope = PanelFocusScope.operational(events: Event.allCases, packCardIDs: [], hasMasterVolume: true)
        let target = panelFirstFocusTarget(scope, nonOperableActionEvents: [first])
        expect(
            target == .eventSound(first),
            "eventSound precedes the disabled action in the SAME row and is unconditionally"
                + " operable, so opening focus lands there — it no longer needs to skip past the"
                + " disabled action to the row's mute the way it did pre-T2, got \(String(describing: target))")
        expect(
            target == panelFocusOrder(scope).first,
            "post-T2 this AGREES with plain order.first — eventSound's unconditional operability"
                + " means the resolver never diverges from it for a disabled FIRST-row action"
                + " (contrast the pre-T2 behavior, where order.first was the disabled action itself)")
    }

    suite("panelFirstFocusTarget: the full order (incl. the disabled action) is unchanged by disabling it — the disabled action remains a Tab stop, only opening focus is unaffected by it") {
        let first = Event.allCases[0]
        let scope = PanelFocusScope.operational(events: Event.allCases, packCardIDs: [], hasMasterVolume: true)
        // panelFocusOrder is deliberately UNCHANGED by disabling an action: it's still a Tab STOP
        // in the full order (AppKit's key-loop skips disabled NSViews itself; the per-row stop
        // count stays stable). Pin the exact order so a shrink would fail here.
        let fullOrder = panelFocusOrder(scope)
        let expected: [PanelFocusTarget] =
            Event.allCases.flatMap { [.eventSound($0), .eventAction($0), .eventMute($0)]
            } + [.masterVolume, .manageSounds, .quitApplication]
        expect(fullOrder == expected, "the full order (incl. the disabled action) must be unchanged, got \(fullOrder)")
        expect(fullOrder.contains(.eventAction(first)), "the disabled action must remain a Tab stop")
    }

    suite("panelFirstFocusTarget: nonOperableActionEvents no longer moves OPENING focus at all — empty / first-only / non-first / every event all resolve to the SAME first row's eventSound") {
        let scope = PanelFocusScope.operational(events: Event.allCases, packCardIDs: [], hasMasterVolume: true)
        let expected = PanelFocusTarget.eventSound(Event.allCases.first!)
        // Kills the pre-T2-shaped mutant that still skips to `.eventMute(first)` whenever the
        // first row's action is in the disabled set — that mechanism is dead now that eventSound
        // (unconditionally operable, and positioned BEFORE .eventAction in every row) always wins.
        for nonOperable: Set<Event> in [
            [], [Event.allCases[0]], [Event.allCases[2]], [Event.allCases[0], Event.allCases[1]],
            Set(Event.allCases),
        ] {
            expect(
                panelFirstFocusTarget(scope, nonOperableActionEvents: nonOperable) == expected,
                "nonOperableActionEvents: \(nonOperable) must not change opening focus away from"
                    + " the first row's eventSound, got"
                    + " \(String(describing: panelFirstFocusTarget(scope, nonOperableActionEvents: nonOperable)))")
        }
    }

    suite("panelFirstFocusTarget: onboarding scope ignores nonOperableActionEvents (it has no action targets)") {
        let scope = PanelFocusScope.onboarding(hasPrimaryAction: true, hasSecondaryAction: true)
        let target = panelFirstFocusTarget(scope, nonOperableActionEvents: Set(Event.allCases))
        expect(
            target == .onboardingPrimaryAction,
            "onboarding first focus is unaffected by action operability, got \(String(describing: target))")
    }

    suite("panelFirstFocusTarget: empty operational panel, hasMasterVolume false, no cards, no config-failure notice → first focus stays .manageSounds ahead of quit") {
        // /codex review P1 (2626083/47459a7): zero events is NOT "unreachable in shipping code" —
        // `PanelView.applyFirstFocus` passes `rows: []`, `hasMasterVolume: false` whenever
        // `configState` is `.needsPack` (first launch before a pack is picked). cc59d52
        // (PLAN-SOUND-MANAGER T1) removed `.dropZone` (its view was deleted), so with no rows, no
        // cards and no slider, T7's always-rendered `.manageSounds` is the first safe, useful
        // operable target. The fixed `.quitApplication` follows but must never win opening focus.
        //
        // This is `.needsPack` ONLY. `.malformed`/`.unwritable` share the zero-rows/no-slider shape
        // but ADD the 诚实失败卡's `.configReveal` (hasConfigFailureNotice: true), which leads —
        // pinned in the next two suites (26bba37 follow-up). The default `hasConfigFailureNotice:
        // false` here is exactly what makes this the needsPack case, not the config-broken ones.
        let scope = PanelFocusScope.operational(events: [], packCardIDs: [], hasMasterVolume: false)
        expect(
            panelFirstFocusTarget(scope) == .manageSounds,
            "with no rows/cards/slider/failure-notice, first focus must be the safe 管理声音包"
                + " control, ahead of quit, got \(String(describing: panelFirstFocusTarget(scope)))")
        expect(
            panelFocusOrder(scope) == [.manageSounds, .quitApplication],
            "零事件、零包状态应保留声音包恢复入口，并把退出入口固定在末位")
    }

    suite("panelFirstFocusTarget: the config-failure shape (.malformed/.unwritable, no cards) → first focus is .configReveal, never 断开连接 (26bba37 follow-up)") {
        // The exact `.malformed`/`.unwritable` opening-focus decision Codex's P1 flagged: the
        // 诚实失败卡's 「在访达中显示 config.json」 is visually first and operable, so it — not the
        // destructive 断开连接 below it — is where keyboard/VoiceOver focus lands when the panel opens
        // on a corrupt/unwritable config.
        let scope = PanelFocusScope.operational(
            events: [], packCardIDs: [], hasMasterVolume: false, hasConfigFailureNotice: true)
        expect(
            panelFirstFocusTarget(scope) == .configReveal,
            "config-broken states open focused on .configReveal, not 断开连接, got \(String(describing: panelFirstFocusTarget(scope)))")
    }

    suite("panelFirstFocusTarget: the config-failure shape WITH pack cards → first focus is STILL .configReveal, never the first pack card (the pre-fix bug: reveal button was skipped to the gallery)") {
        // `.malformed`/`.unwritable` with packs installed. Before this fix the focus model was blind
        // to the reveal button and landed on `.packCard("alpha-pack")` — skipping the panel's own
        // top-of-card recovery action. It must lead with .configReveal.
        let scope = PanelFocusScope.operational(
            events: [], packCardIDs: ["alpha-pack", "zeta-pack"], hasMasterVolume: false,
            hasConfigFailureNotice: true)
        expect(
            panelFirstFocusTarget(scope) == .configReveal,
            "the reveal button leads even when pack cards are installed, got \(String(describing: panelFirstFocusTarget(scope)))")
    }

    suite("panelFirstFocusTarget: empty operational panel with pack cards (the COMMON .needsPack 'pick a pack' shape) → first focus is the first pack card, not 断开连接") {
        // The common first-launch shape: no pack selected yet, but packs ARE installed and their
        // cards are on screen (`needsPackNotice` tells the user '点一个声音包'). The pack gallery
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

    suite("panelOpeningFocus: nothing muted → opening focus is the first row's eventSound (agrees with order.first)") {
        let rows = Event.allCases.map {
            EventRow(event: $0, coverage: .present(fileName: "\($0.cliName).mp3"), enabled: true)
        }
        let target = panelOpeningFocus(rows: rows, packCardIDs: ["alpha-pack"], hasMasterVolume: true)
        expect(
            target == .eventSound(Event.allCases.first!),
            "opening focus is the first row's file-name Menu, got \(String(describing: target))")
        expect(
            target == panelFocusOrder(.operational(events: rows.map(\.event), packCardIDs: ["alpha-pack"], hasMasterVolume: true)).first,
            "it must AGREE with order.first")
    }

    // PLAN-SOUND-MANAGER.md §2.5/T2: first row is `.present` + MUTED, so its 试听 ▶ (`.eventAction`)
    // renders `.disabled(true)` — but `.eventSound` (the file-name `Menu`) now sits BEFORE it in the
    // same row and is UNCONDITIONALLY operable, so opening focus lands there regardless, and (unlike
    // the pre-T2 shape, where a muted first row's disabled action WAS order.first and the resolver
    // had to diverge from it) this now AGREES with plain `panelFocusOrder(...).first` — there is
    // nothing left to skip past.
    suite("panelOpeningFocus: a MUTED .present first row → focus is STILL that row's eventSound (mute never reaches, let alone disables, the file-name Menu)") {
        let first = Event.allCases[0]
        var rows = Event.allCases.map {
            EventRow(event: $0, coverage: .present(fileName: "\($0.cliName).mp3"), enabled: true)
        }
        rows[0] = EventRow(event: first, coverage: .present(fileName: "\(first.cliName).mp3"), enabled: false)
        let packCardIDs = ["alpha-pack", "zeta-pack"]

        let target = panelOpeningFocus(rows: rows, packCardIDs: packCardIDs, hasMasterVolume: true)
        expect(
            target == .eventSound(first),
            "opening focus lands on the muted row's file-name Menu — mute only disables the preview"
                + " button one slot to its right, got \(String(describing: target))")

        let order = panelFocusOrder(.operational(events: rows.map(\.event), packCardIDs: packCardIDs, hasMasterVolume: true))
        expect(
            target == order.first,
            "post-T2 this AGREES with panelFocusOrder(...).first — order.first is"
                + " \(String(describing: order.first)), and it's already operable, so the resolver"
                + " has nothing to diverge from (contrast pre-T2, where order.first WAS the muted"
                + " row's disabled action)")
        expect(
            order.contains(.eventAction(first)) && order.firstIndex(of: .eventAction(first))! > 0,
            "sanity: the disabled action is still a Tab stop, just no longer first in the row"
                + " (eventSound precedes it) — the fix changes NEITHER the order NOR, in this"
                + " shape, opening focus's divergence from it")
    }

    suite("panelOpeningFocus: an UNMAPPED muted first row's opening focus is ALSO its eventSound (the row's actually-fixable, always-operable control — mute is irrelevant to reaching it)") {
        let first = Event.allCases[0]
        var rows = Event.allCases.map {
            EventRow(event: $0, coverage: .present(fileName: "\($0.cliName).mp3"), enabled: true)
        }
        rows[0] = EventRow(event: first, coverage: .unmapped, enabled: false)
        let target = panelOpeningFocus(rows: rows, packCardIDs: [], hasMasterVolume: true)
        expect(
            target == .eventSound(first),
            "an .unmapped row's file-name Menu is always operable regardless of mute or coverage,"
                + " so opening focus lands there — kills a mutant that keys the skip off `enabled`"
                + " alone rather than the eventSound/eventAction slot split, got \(String(describing: target))")
    }

    suite("panelOpeningFocus: every row muted+present → focus still lands on the FIRST row's eventSound (never a later row, never the disabled action, never the mute)") {
        let rows = Event.allCases.map {
            EventRow(event: $0, coverage: .present(fileName: "\($0.cliName).mp3"), enabled: false)
        }
        let target = panelOpeningFocus(rows: rows, packCardIDs: [], hasMasterVolume: true)
        expect(
            target == .eventSound(Event.allCases.first!),
            "the first slot, eventSound, is unconditionally operable regardless of every row being"
                + " muted, got \(String(describing: target))")
    }

    suite("panelOpeningFocus: every row muted → first focus is the first row's eventSound, NEVER the master volume slider (the slider only wins opening focus when the row list is empty, see the hasMasterVolume-gated tests below)") {
        let rows = Event.allCases.map {
            EventRow(event: $0, coverage: .present(fileName: "\($0.cliName).mp3"), enabled: false)
        }
        let target = panelOpeningFocus(rows: rows, packCardIDs: [], hasMasterVolume: true)
        expect(
            target == .eventSound(Event.allCases.first!),
            "with every row muted, first focus is still the first row's eventSound, got \(String(describing: target))")
        expect(
            target != .masterVolume,
            "the master volume slider must never steal opening focus away from an operable event"
                + " row control, got \(String(describing: target))")
    }

    suite("panelOpeningFocus: zero rows, hasMasterVolume false, with a pack card (the REAL .needsPack 'pick a pack' shape) → first focus is the first pack card, never the (unrendered) slider or a removed drop zone") {
        // /codex review P1 (2626083/47459a7): `PanelView.applyFirstFocus` calls
        // `panelOpeningFocus` with `rows: []` AND `hasMasterVolume: false` together on the
        // `.needsPack` shape (first launch, packs installed but none picked) — a common real shape,
        // not a fixture-only edge case. (`.malformed`/`.unwritable` also pass zero rows but carry
        // `hasConfigFailureNotice: true`, so they lead with `.configReveal`, not the first card —
        // that's the config-broken case, pinned in its own suites, 26bba37 follow-up.) cc59d52
        // (PLAN-SOUND-MANAGER T1) removed `.dropZone`; the pack gallery is still rendered in every
        // configState, so opening focus now lands on the first pack card — the panel's own primary
        // action ('点一个声音包') — instead of the deleted drop zone. `hasMasterVolume` is a literal
        // `false` because this fixture models a NON-operational panel, and `MasterVolumeRow` is
        // rendered by exactly one branch of `operationalPanel` — the `.operational` one.
        // `.manageSounds` follows the cards, so the existing first-card assertion remains intact.
        expect(
            panelOpeningFocus(rows: [], packCardIDs: ["alpha-pack"], hasMasterVolume: false) == .packCard(id: "alpha-pack"),
            "opening focus must be the first pack card, never .masterVolume or a removed drop zone,"
                + " when the slider isn't actually rendered")
    }

    suite("panelOpeningFocus: zero rows, hasMasterVolume true → the master volume slider, never nil") {
        // The flag's positive case: .masterVolume, always operable, sits ahead of the pack cards
        // in the order whenever it's actually present. Zero rows here is only a fixture (a truly
        // .operational configState always has 5 real rows) — this pins the flag's own behavior.
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
        // 全 unmapped：PLAN-SOUND-MANAGER.md §2.5/T2 后，每行真正永远可操作的槽是 eventSound（文件名
        // Menu），不再是 action（试听 ▶ 在 unmapped/broken 上恒禁用）——首焦点仍落第一行，只是落在
        // eventSound 上。4 行真事件、ctaOperable: false、`hasMasterVolume: true` —— 阶段 D
        // （MasterVolumeRow，8771946）落地后这整个组合都是**真实**操作态的形状，不再是为测 flag 而拼的
        // 虚构值：`.operational` 面板今天确实渲染滑块，真实调用方（`PanelView.applyFirstFocus`）传的就是
        // `isOperational`。
        expect(
            panelOpeningFocus(rows: rows, packCardIDs: [], ctaOperable: false, hasMasterVolume: true)
                == .eventSound(Event.allCases[0]),
            "operational 面板里首焦点本来就不是断开连接，禁用它不该改变这一点；ctaOperable 只影响"
                + " onboarding CTA / .disconnect / .revealDetail，从不影响 eventSound 的操作性")

        // 极端情形：没有事件行、没有包卡、hasMasterVolume: false、也没有失败卡 —— 这是 `.needsPack`
        // **一无所有**的真实形状（`/codex review` P1，2626083/47459a7），且此刻有动作在飞
        // （ctaOperable == false）。cc59d52（PLAN-SOUND-MANAGER T1）删掉 `.dropZone` 后，T7 的
        // `.manageSounds` 接过 always-rendered、always-operable landing。`.disconnect` is
        // disabled in-flight, but the safe Finder reveal remains usable, so this shape is non-nil.
        //
        // 注意这**不含** `.malformed`/`.unwritable`：那两态带失败卡的 `.configReveal`（恒可操作），
        // in-flight 也非 nil —— 见下一条断言（26bba37 follow-up）。
        expect(
            panelOpeningFocus(
                rows: [], packCardIDs: [], ctaOperable: false, hasMasterVolume: false)
                == .manageSounds,
            "needsPack 一无所有且断开在飞时，首焦点仍必须是恒可操作的 .manageSounds，"
                + "不是 nil 或被禁用的断开连接")

        // `.malformed`/`.unwritable` 的 in-flight 强化：断开跑到一半，`.disconnect` 禁用，但失败卡的
        // `.configReveal`（访达 reveal 无写副作用）照样可操作 —— 首焦点落在它上面，绝不 nil。这正是
        // Codex P1 想要的诚实：config 坏掉时，开局焦点是那颗「在访达中显示 config.json」的修复入口。
        expect(
            panelOpeningFocus(
                rows: [], packCardIDs: [], ctaOperable: false, hasMasterVolume: false,
                hasConfigFailureNotice: true) == .configReveal,
            "config 坏 + 断开在飞时，首焦点必须是恒可操作的 .configReveal，而不是 nil 或被禁用的断开连接")
    }
}
