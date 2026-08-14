import AppKit
import ClaudioCore
import ClaudioGUICore
import ClaudioLocalization
import SwiftUI

/// The panel's master-volume control row (PLAN-MASTER-VOLUME.md 阶段 D; DESIGN.md「控件行
/// （Control Row）」节): `[「主音量」SF Pro 13] · Spacer · [Slider]` — no event-color tile, no
/// speaker glyph, no percentage readout (D15; the readout is delivered exclusively through
/// ``accessibilityValue``, same as macOS's own system volume slider).
///
/// Every DECISION this row would otherwise have to make itself already happened elsewhere and
/// is independently unit-tested:
///
/// - **"How many disk writes does one drag produce"** is ``VolumeDragSession``'s entire reason
///   to exist (阶段 C1) — this view holds one as private ``@State`` (D8: a drag only invalidates
///   THIS row, never the five event rows + gallery) and only forwards callbacks.
/// - **"What actually gets written, and did it land"** is
///   ``PanelConfigController/setMasterVolume(_:)`` (阶段 D, D27/D39/D43) — this view never talks
///   to `ClaudioCore` directly, it calls ``onCommit`` and reacts to whether that returned a
///   landed value or `nil`.
///
/// so the only thing left for this file to get wrong is composition — exactly the shape
/// `EventRowView`/`AudioDropZoneView` already established.
public struct MasterVolumeRow: View {
    /// The `master_volume` currently on disk (``PanelConfigController/config``'s value) — NOT
    /// this row's own `@State`. Rule 5 (D21): this row must react when it changes out from under
    /// an open panel (another write landed, the popover reopened after an external edit), via
    /// ``VolumeDragSession/rebase(to:)`` — see ``body``'s `.onChange(of:)` below. Without it, a
    /// hand-edited `config.json` would leave the slider showing a value the disk no longer has,
    /// forever (D11's "unchanged means unwritten" means it would never self-heal on its own).
    public let diskVolume: Double
    /// Writes `volume` through ``PanelConfigController/setMasterVolume(_:)`` and returns the
    /// **landed** (clamped) value on success, `nil` on failure — this view never calls
    /// `ClaudioCore` itself, it only resolves ``VolumeDragSession/commitSucceeded(_:)``/
    /// ``VolumeDragSession/commitFailed()`` off whichever this returns.
    public let onCommit: (Double) -> Double?
    /// Owned by `MenuBarController` for the app's whole lifetime, shared with `PanelView` — NOT
    /// constructed here. `.hideCount` is this row's flush signal (D22/D37): `PanelFocusCoordinator`
    /// already has it (T17d), and `MenuBarController.popoverDidClose`'s FIRST statement is already
    /// `notePanelHidden()`, ahead of the `guard NSApp.isActive` that would otherwise skip the most
    /// common close path ("clicked another app"). Reusing it means this row's flush automatically
    /// inherits that ordering guarantee — no second counter, no second AppKit callback to place
    /// correctly.
    @ObservedObject public var focusCoordinator: PanelFocusCoordinator
    /// The SHARED `@FocusState` binding `PanelView` owns (a11y-architect FIX 4) — mirrors
    /// `EventRowView`'s own `focusedTarget` parameter exactly.
    private let focusedTarget: FocusState<PanelFocusTarget?>.Binding
    public let adaptation: PanelLayoutAdaptation
    public let language: ClaudioAppLanguage

    @Environment(\.colorScheme) private var colorScheme
    /// Dynamic-Type scale factor for this row's fixed `.system(size:)` text (a11y fix) — see
    /// `EventRowView`'s `typeScale` for the full rationale.
    @ScaledMetric(relativeTo: .body) private var typeScale: CGFloat = 1

    /// The drag/commit state machine (阶段 C1). Seeded from ``diskVolume`` exactly once, at this
    /// row's first insertion into the view tree — `NSHostingController`'s SwiftUI-side state
    /// persists for the app's whole lifetime (`PanelFocusCoordinator`'s own doc comment), so this
    /// `@State` survives every popover show/close cycle untouched; only ``VolumeDragSession/rebase(to:)``
    /// (below) or a user drag ever moves it again.
    @State private var session: VolumeDragSession

    public init(
        diskVolume: Double,
        onCommit: @escaping (Double) -> Double?,
        focusCoordinator: PanelFocusCoordinator,
        focusedTarget: FocusState<PanelFocusTarget?>.Binding,
        adaptation: PanelLayoutAdaptation = panelLayoutAdaptation(for: .standard),
        language: ClaudioAppLanguage = .zhHans
    ) {
        self.diskVolume = diskVolume
        self.onCommit = onCommit
        self.focusCoordinator = focusCoordinator
        self.focusedTarget = focusedTarget
        self.adaptation = adaptation
        self.language = language
        _session = State(initialValue: VolumeDragSession(baseline: diskVolume))
    }

    public var body: some View {
        Group {
            if adaptation.rowWrapsToTwoLines {
                // "更大" tier (D17/D44 — the term is `.largest`, NOT `.larger`): label on top,
                // the slider spanning the full row below. Master-volume and pack rows continue
                // to share `rowWrapsToTwoLines`; EventRow's separate maximum-only action placement
                // does not change this control-row contract (DESIGN.md「控件行」).
                VStack(alignment: .leading, spacing: 2) {
                    label
                    slider
                }
            } else {
                HStack(spacing: 8) {
                    label
                    Spacer(minLength: 8)
                    slider
                }
            }
        }
        .frame(minHeight: adaptation.rowWrapsToTwoLines ? 44 : 28)
        // Rule 5 / D21 — see `diskVolume`'s own doc comment above.
        .onChange(of: diskVolume) { newValue in
            session.rebase(to: newValue)
        }
        // D22/D37 — see `focusCoordinator`'s own doc comment above.
        .onChange(of: focusCoordinator.hideCount) { _ in
            flush()
        }
        // D22-bis (the backstop `.hideCount` cannot cover): the popover is never closed on a
        // real ⌘Q/logout/shutdown, so `notePanelHidden()` never fires on that path. This has to
        // be a genuine Combine subscription (`.onReceive`), not `.onChange` on some bumped
        // counter — the app is mid-termination, and SwiftUI's own update pass is not guaranteed
        // to run again before the process actually exits, so bumping a `@Published` value would
        // accomplish nothing. `NotificationCenter`'s publisher calls this closure SYNCHRONOUSLY,
        // on whatever thread the notification was posted from (main, here) — no dispatch, no
        // render pass required — so the write this triggers has a chance to actually complete
        // before termination proceeds.
        //
        // Honest limitations (D32) — TWO of them, and neither is "the value lands anyway ✅":
        //
        // 1. This covers ⌘Q / logout / shutdown only. A force-quit or `killall` does not deliver
        //    this notification at all: that drag is simply lost.
        // 2. Even on the paths it DOES cover, the write can still fail. `setMasterVolume` takes
        //    `config.lock` NON-blockingly (`flock(LOCK_EX | LOCK_NB)`, `FileLock.swift:85` —
        //    ENGINEERING.md 决议 1+5 make that mandatory), so a second config writer holding the
        //    lock at this exact moment returns `.lockBusy`. `commit(_:)` then rolls the draft back
        //    and `PanelConfigController.masterVolumeError` is set as always — but the app is
        //    terminating, so that error row has NO AUDIENCE: nobody ever sees it, and the drag is
        //    silently lost.
        //
        // Both windows are known and ACCEPTED (D32), not covered. Do not let a later edit of this
        // comment — or of ENGINEERING.md — quietly upgrade them into "值照常落盘 ✅".
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            flush()
        }
    }

    private var label: some View {
        Text(ClaudioL10n(language: language).text(.panelMasterVolume))
            .font(.system(size: 13 * typeScale))
            .foregroundColor(ClaudioColor.text(colorScheme))
            // Purely visual — the slider below carries the identical label through its own
            // ``accessibilityLabel``, and VoiceOver reads a label when the cursor LANDS on a
            // control, not on this static text. Leaving this un-hidden would give VoiceOver a
            // second, redundant "主音量" stop right before the actual control.
            .accessibilityHidden(true)
    }

    private var slider: some View {
        Slider(
            value: Binding(
                get: { session.draft },
                set: { newValue in
                    // D26: the binding's setter is also where VoiceOver's adjustable
                    // increment/decrement and the keyboard's arrow keys arrive — SwiftUI reports
                    // those exactly like a value change through this same setter, with no
                    // matching "began"/"ended" bracket. Routing on `session.isDragging` sends a
                    // real mouse/trackpad drag to `drag(to:)` (no commit yet) and everything else
                    // straight through `adjust(to:)` (commits immediately) — the dual gate
                    // `VolumeDragSession` itself documents.
                    if session.isDragging {
                        session.drag(to: newValue)
                    } else {
                        commit(session.adjust(to: newValue))
                    }
                }
            ),
            in: 0...1,
            onEditingChanged: { editing in
                if editing {
                    session.begin()
                } else {
                    commit(session.end())
                }
            }
        )
        // D4: the sole brand-accent entry point for a native control — never a hand-drawn
        // track/thumb (DESIGN.md「控件行」: 原生外壳，不自绘).
        //
        // Whether `.tint` survives HERE is structurally untestable by CI (D25): `ContrastSuite` is
        // pure hex math over `ClaudioGUICore`, which does not even link SwiftUI — it cannot see an
        // NSSlider. The ONLY gate is a human running 走查 ⑨ (set the system accent to red, open the
        // panel, confirm the fill is clay and not red) — **re-run every time the control row is
        // touched**, this row's own creation included.
        //
        // ✅ VERIFIED on-device for THIS row, 2026-07-14 (8771946), system accent set to red:
        //   - slider fill        `#AE6E41`  (G−B = 45 — orange-brown), same family as
        //   - clay glyph         `#B5754A`  in the same panel (so both went through the same
        //                                    render/screenshot pipeline — this is the comparison
        //                                    that matters, not raw equality with `#D97757`)
        //   - system red accent  `#D55A53`  (G−B = 7 — red)
        //   - positive control first: a BARE `Slider` under the same conditions rendered RED,
        //     proving the red accent was actually in effect. Without that control, a clay fill
        //     would "pass" even if the accent had never been applied — the probe has to prove
        //     itself before it can prove anything else.
        //   (走查 ⑥ same run: no tick-mark band under the track — the `step:` trap of D24 avoided.)
        //
        // This block used to end with "That run is still owed." — written before the run and never
        // updated after it. DESIGN.md's Decisions Log said the same. Both were false, and in the
        // worst direction: they cried wolf on a discipline that is real, teaching the next reader
        // to discount "走查 ⑨ 欠账" the one time it actually means something (`/codex review 8771946`).
        .tint(ClaudioColor.clay(colorScheme))
        .focused(focusedTarget, equals: .masterVolume)
        .accessibilityLabel(ClaudioL10n(language: language).text(.panelMasterVolume))
        // The readout macOS's own system volume slider uses — no on-screen "80%" text (D15).
        .accessibilityValue("\(Int((session.draft * 100).rounded()))%")
    }

    /// Rule 2 (both `focusCoordinator.hideCount` and `willTerminateNotification` funnel here):
    /// a dirty session MUST still be flushed even when it never sees a normal `end()`. Safe to
    /// call unconditionally and repeatedly — a clean session's ``VolumeDragSession/flushPending()``
    /// returns `nil` and this is a no-op.
    private func flush() {
        commit(session.flushPending())
    }

    /// Resolves a pending commit (from `end()`/`adjust(to:)`/`flush()`) against ``onCommit``:
    /// success snaps ``session``'s baseline AND draft to the landed value (rule 4's "never show a
    /// value the disk doesn't have" satisfied the cheap way — the write's own return already tells
    /// us the truth, no re-read needed); failure rolls `draft` straight back to `baseline` — a
    /// snap, never animated (D18).
    private func commit(_ pendingValue: Double?) {
        guard let pendingValue else { return }
        if let landed = onCommit(pendingValue) {
            session.commitSucceeded(landed)
        } else {
            session.commitFailed()
        }
    }
}
