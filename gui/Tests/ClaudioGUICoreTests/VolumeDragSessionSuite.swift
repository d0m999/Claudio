import ClaudioCore
import ClaudioGUICore
import Foundation

// MARK: - VolumeDragSession (ENGINEERING.md T15 主音量滑块, PLAN-MASTER-VOLUME.md 阶段 C1 —
// D6/D11/D12/D21/D24/D26). Pure state-machine tests only — no SwiftUI, no view; this type owns
// the entire "一次拖动应该产生几次写盘" decision so the view has nothing left to get wrong
// beyond forwarding callbacks (see `PanelFocusOrder.swift`'s prior scar on this exact shape of
// bug: a pure function fully tested, the view code that fed it, not at all).

@MainActor
func runVolumeDragSessionSuites() {
    // MARK: - init

    suite("VolumeDragSession.init: baseline and draft both start at the given value, verbatim") {
        let session = VolumeDragSession(baseline: 0.42)
        expect(session.baseline == 0.42, "baseline must be taken verbatim (not snapped), got \(session.baseline)")
        expect(session.draft == 0.42, "draft must start equal to baseline, got \(session.draft)")
        expect(session.isDragging == false, "a freshly constructed session is not mid-drag")
        expect(session.isDirty == false, "a freshly constructed session owes the disk nothing")
    }

    suite("VolumeDragSession.init: an out-of-range baseline is clamped, not stored verbatim") {
        let high = VolumeDragSession(baseline: 1.5)
        expect(high.baseline == 1.0, "got \(high.baseline)")
        let low = VolumeDragSession(baseline: -0.3)
        expect(low.baseline == 0.0, "got \(low.baseline)")
    }

    // MARK: - Rule 1/2: a full begin→drag×N→end sequence commits exactly once

    suite("VolumeDragSession: 1 began + N dragged + 1 ended = 恰好 1 次 commit") {
        var session = VolumeDragSession(baseline: 0.8)
        session.begin()
        for v in [0.1, 0.22, 0.3, 0.41, 0.55, 0.63] {
            session.drag(to: v)
        }
        var commits: [Double] = []
        if let commit = session.end() { commits.append(commit) }
        expect(commits.count == 1, "a single drag gesture must produce exactly one commit, got \(commits.count)")
        expect(session.isDragging == false, "end() must clear isDragging")
    }

    suite("VolumeDragSession: drag(to:) is ignored entirely unless begin() was called first") {
        var session = VolumeDragSession(baseline: 0.8)
        session.drag(to: 0.2)  // no begin() — must be a no-op
        expect(session.draft == 0.8, "an un-begun drag(to:) must not move draft, got \(session.draft)")
        expect(session.end() == nil, "nothing changed, so end() must not produce a commit")
    }

    // MARK: - Rule 2: a dirty session that never sees end() must still be flushable

    suite("VolumeDragSession: 只 dragged 没 ended → flushPending() 必须吐出 commit（不是 0）") {
        var session = VolumeDragSession(baseline: 0.8)
        session.begin()
        session.drag(to: 0.3)
        let flushed = session.flushPending()
        expect(flushed != nil, "a dirty in-flight drag must not be silently dropped on teardown")
        expect(
            flushed == VolumeDragSession.snap(0.3),
            "flush must hand back the snapped draft, got \(String(describing: flushed))")
        expect(session.isDragging == false, "flushPending() must also clear isDragging")
    }

    suite("VolumeDragSession: flushPending() on a session with nothing pending returns nil, repeatedly") {
        var session = VolumeDragSession(baseline: 0.8)
        expect(session.flushPending() == nil, "an untouched session owes nothing")
        expect(session.flushPending() == nil, "calling it again must still be safe and still nil")
    }

    // MARK: - Rule 3: unchanged means unwritten

    suite("VolumeDragSession: 未拖动 → 0 commit") {
        var session = VolumeDragSession(baseline: 0.8)
        expect(session.end() == nil, "end() without a drag must not commit")
        expect(session.flushPending() == nil, "flushPending() without a drag must not commit")
    }

    suite("VolumeDragSession: baseline 0.42（不在网格上）未拖动 → 0 commit") {
        var session = VolumeDragSession(baseline: 0.42)
        expect(session.isDirty == false, "an untouched off-grid baseline is not dirty")
        expect(session.flushPending() == nil, "opening the panel must never rewrite a hand-edited value")
    }

    suite("VolumeDragSession: dragging back to the exact baseline leaves the session clean") {
        var session = VolumeDragSession(baseline: 0.3)
        session.begin()
        session.drag(to: 0.55)
        session.drag(to: 0.3)  // snaps back to exactly the baseline
        expect(session.isDirty == false, "returning to baseline mid-drag must not count as a change")
        expect(session.end() == nil, "no net change means no commit")
    }

    // MARK: - Rule 4: a failed write must never leave the disk lied about

    suite("VolumeDragSession: commitFailed() 后 draft == baseline") {
        var session = VolumeDragSession(baseline: 0.8)
        session.begin()
        session.drag(to: 0.2)
        let pending = session.end()
        expect(pending != nil, "sanity: the drag must have produced something to write")
        session.commitFailed()
        expect(
            session.draft == session.baseline,
            "a failed write must snap the visible value back, got draft=\(session.draft) baseline=\(session.baseline)")
        expect(session.draft == 0.8, "and specifically back to what disk still holds, got \(session.draft)")
    }

    suite("VolumeDragSession: commitSucceeded(_:) adopts the landed value as the new baseline AND draft") {
        var session = VolumeDragSession(baseline: 0.8)
        session.begin()
        session.drag(to: 0.2)
        _ = session.end()
        session.commitSucceeded(0.2)
        expect(session.baseline == 0.2, "got \(session.baseline)")
        expect(session.draft == 0.2, "got \(session.draft)")
        expect(session.isDirty == false, "a session immediately after a successful commit owes nothing")
    }

    // MARK: - snap()

    suite("VolumeDragSession.snap: 0.42 → 0.40") {
        expect(VolumeDragSession.snap(0.42) == 0.40, "got \(VolumeDragSession.snap(0.42))")
    }

    suite("VolumeDragSession.snap: an already-on-grid value is a fixed point (0.8 恒等)") {
        expect(VolumeDragSession.snap(0.8) == 0.8, "got \(VolumeDragSession.snap(0.8))")
    }

    suite("VolumeDragSession.snap: out-of-range and non-finite input are clamped, never carried through") {
        expect(VolumeDragSession.snap(1.4) == 1.0, "got \(VolumeDragSession.snap(1.4))")
        expect(VolumeDragSession.snap(-0.4) == 0.0, "got \(VolumeDragSession.snap(-0.4))")
        expect(
            VolumeDragSession.snap(.nan) == ClaudioConfig.defaultMasterVolume,
            "NaN must fall back to the documented default, got \(VolumeDragSession.snap(.nan))")
    }

    suite("VolumeDragSession.snap: all 21 grid stops render as the same short literal a human would type (≤4 characters)") {
        let expectedRenders = [
            "0.0", "0.05", "0.1", "0.15", "0.2", "0.25", "0.3", "0.35", "0.4", "0.45", "0.5",
            "0.55", "0.6", "0.65", "0.7", "0.75", "0.8", "0.85", "0.9", "0.95", "1.0",
        ]
        for k in 0...20 {
            let value = Double(k) / 20
            let snapped = VolumeDragSession.snap(value)
            let rendered = String(snapped)
            expect(
                rendered.count <= 4,
                "grid stop \(k)/20 rendered as \"\(rendered)\" (\(rendered.count) chars) — must be ≤4")
            expect(
                rendered == expectedRenders[k],
                "grid stop \(k)/20 rendered as \"\(rendered)\", expected \"\(expectedRenders[k])\""
                    + " — a dirty float would print a ~17-digit tail here")
        }
    }

    // MARK: - Rule 5 (D21): rebase(to:) adopts an external disk change

    suite("VolumeDragSession.rebase: 非拖动时采纳外部新值（baseline 与 draft 一起动）") {
        var session = VolumeDragSession(baseline: 0.8)
        session.rebase(to: 0.3)
        expect(session.baseline == 0.3, "got \(session.baseline)")
        expect(session.draft == 0.3, "not-dragging must let the disk's new value show through, got \(session.draft)")
        expect(session.isDirty == false, "adopting the disk's own value must never look like a pending change")
    }

    suite("VolumeDragSession.rebase: 拖动中不抢手（只有 baseline 动，draft 保持用户手里的值）") {
        var session = VolumeDragSession(baseline: 0.8)
        session.begin()
        session.drag(to: 0.4)
        session.rebase(to: 0.3)  // e.g. another process wrote config.json mid-drag
        expect(session.baseline == 0.3, "baseline must still track the disk, got \(session.baseline)")
        expect(
            session.draft == VolumeDragSession.snap(0.4),
            "the user's hand must win while dragging — draft must not jump, got \(session.draft)")
        expect(
            session.isDirty == true,
            "draft (0.4-ish) now differs from the rebased baseline (0.3), so the drag still owes a"
                + " write once it ends")
    }

    suite("VolumeDragSession.rebase: clamps non-finite/out-of-range input like init does") {
        var session = VolumeDragSession(baseline: 0.8)
        session.rebase(to: 2.0)
        expect(session.baseline == 1.0, "got \(session.baseline)")
    }

    // MARK: - Rule 6 (D26): adjust(to:) is the non-drag commit path (VoiceOver / arrow keys)

    suite("VolumeDragSession.adjust: !isDragging 时必须 commit（对偶于 drag(to:) 被忽略）") {
        var session = VolumeDragSession(baseline: 0.8)
        let committed = session.adjust(to: 0.35)
        expect(committed != nil, "a real value change via adjust(to:) while not dragging must commit")
        expect(committed == 0.35, "got \(String(describing: committed))")
        expect(session.draft == 0.35, "draft must reflect the adjustment immediately, got \(session.draft)")
    }

    suite("VolumeDragSession.adjust: unchanged value → nil (rule 3 applies here too)") {
        var session = VolumeDragSession(baseline: 0.8)
        let committed = session.adjust(to: 0.8)
        expect(
            committed == nil,
            "adjusting to the value already on disk must not count as a change, got \(String(describing: committed))")
        expect(session.isDirty == false, "got dirty=\(session.isDirty)")
    }

    suite("VolumeDragSession.adjust: ignored while a real drag is in flight (the mouse/trackpad owns draft)") {
        var session = VolumeDragSession(baseline: 0.8)
        session.begin()
        session.drag(to: 0.3)
        let committed = session.adjust(to: 0.9)
        expect(committed == nil, "adjust(to:) must be a no-op mid-drag, got \(String(describing: committed))")
        expect(
            session.draft == VolumeDragSession.snap(0.3),
            "adjust(to:) must not have moved draft, got \(session.draft)")
    }

    suite("VolumeDragSession.adjust: after commitSucceeded, a further identical adjust is a no-op") {
        var session = VolumeDragSession(baseline: 0.8)
        let first = session.adjust(to: 0.5)
        expect(first == 0.5, "got \(String(describing: first))")
        session.commitSucceeded(0.5)
        let second = session.adjust(to: 0.5)
        expect(
            second == nil,
            "adjusting to the now-current baseline again must not re-commit, got \(String(describing: second))")
    }
}
