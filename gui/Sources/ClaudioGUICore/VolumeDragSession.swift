import ClaudioCore
import Foundation

/// The panel's master-volume slider reduced to a pure, testable state machine: it owns the
/// single question 「一次拖动应该产生几次写盘」 and every rule that hangs off it.
///
/// This type exists because that question is the load-bearing decision of the whole feature,
/// and SwiftUI is where such decisions go to die untested. `PanelFocusOrder.swift` already
/// documents this project's scar: a pure function had thorough tests while *the view code that
/// decided what to pass it* had none — so reverting the view to the buggy one-liner left every
/// test green. The fix was not "write a view test" (impossible on a CommandLineTools-only
/// machine); it was to **sink the decision out of the view** until the view has no branch left
/// to drift. This type owns that decision end to end — whatever view eventually wires it up
/// should have nothing left to get wrong beyond forwarding callbacks and rendering ``draft``.
///
/// ## The six rules
///
/// 1. **Drag writes nothing.** `config.json`'s writers take a lock and do synchronous, blocking
///    disk I/O; a per-frame write would do that 60–120×/second on the main actor. Nothing
///    observes an intermediate value anyway — `claudio play` re-reads `config.json` on every
///    single spawn — so the intermediate values are pure cost. Only ``end()`` (and
///    ``flushPending()``, rule 2) can turn a drag into a commit.
///
/// 2. **A dirty session MUST still be flushed.** "Drag writes nothing" is a performance rule,
///    and it becomes *data loss* the moment a drag ends by any route other than a normal
///    release — the popover closing, the panel leaving the operational state, the app quitting.
///    The user let go of a control that visibly moved; the value must land. The flush signal
///    this type expects to be driven by is the popover-close notification the panel already has
///    wired for unrelated reasons (a reliable, already-verified-on-device signal — SwiftUI's own
///    view-teardown callbacks are not reliable inside an AppKit popover container, per this
///    project's prior record), with process termination as a backstop that a force-quit or
///    `killall` does not reach. Neither of those facts is this type's problem to solve — it only
///    has to guarantee that calling ``flushPending()`` at any such moment returns a value
///    whenever one is owed.
///
/// 3. **Unchanged means unwritten.** A commit is produced only when ``draft`` actually differs
///    from ``baseline`` (the value last known to be on disk). This is what protects a
///    hand-edited `"master_volume": 0.42` — a value the lenient read path accepts and the panel
///    happily displays, but which is not on this slider's grid. Opening the panel does not
///    rewrite it; clicking the thumb without moving it does not rewrite it. Only actually
///    dragging (or adjusting, rule 6) to a different grid point does — and then the user has
///    asked for a grid value, and gets one.
///
/// 4. **Never show a value the disk does not have.** ``commitFailed()`` snaps ``draft`` back to
///    ``baseline``. A failed write (`.lockBusy`, a corrupt config, a read-only home) that left
///    the thumb parked at 30% while the file still said 80% would be the panel lying about
///    state — in an app whose entire premise is 「不回头也知道状态」.
///
/// 5. **The disk can move without this session's help.** `config.json` can change out from
///    under an open panel — another write landed, the popover reopened after an external edit —
///    and ``rebase(to:)`` is how that new truth gets in. While a drag is in flight the user's
///    hand wins: only ``baseline`` moves, so the in-flight drag still resolves against what
///    actually reaches disk once it ends, instead of being clobbered mid-gesture.
///
/// 6. **Non-drag input commits immediately.** VoiceOver's adjustable increment/decrement and the
///    keyboard's arrow keys move a slider's value without ever bracketing it the way a real drag
///    does — there is no "began" before it and no "ended" after it. ``adjust(to:)`` is their
///    path: it resolves to a commit in the same call that receives the value, gated the
///    opposite way from ``drag(to:)`` (only while *not* dragging). Skipping this rule does not
///    just lose one keystroke's worth of a write — it leaves the control silently unusable from
///    the keyboard (WCAG 2.1.1), a worse failure than any of the data-loss scenarios the other
///    rules guard against.
///
/// ## Why `drag(to:)` and `adjust(to:)` gate on opposite `isDragging` states
///
/// They are two distinct input sources that must never resolve the same in-flight value at
/// once: a mouse/trackpad drag is bracketed by ``begin()``/``end()``, while VoiceOver's
/// adjustable increment/decrement and the keyboard's arrow keys arrive as a single, unbracketed
/// value change with no bracket of their own. Gating each entry point on the state the *other*
/// one owns keeps them from interleaving — a stray accessibility event cannot jump ``draft`` out
/// from under an in-progress drag, and a drag update cannot be mistaken for the non-drag commit
/// path ``adjust(to:)`` exists to serve. Removing this gate on the accessibility side would
/// leave VoiceOver and keyboard input with no reachable write path at all — a control a
/// screen-reader or keyboard-only user cannot move — which is why rule 6 exists in the first
/// place.
public struct VolumeDragSession: Sendable, Equatable {
    /// The grid the slider snaps to (see ``snap(_:)``): 21 stops over `[0.0, 1.0]` — fine enough
    /// that the control never feels notchy, coarse enough that `config.json` holds numbers a
    /// human recognizes (`0.35`, `0.8`) rather than wherever a mouse pixel happened to land. The
    /// grid is enforced entirely by ``snap(_:)``; nothing here asks the rendered control to
    /// quantize on its own.
    ///
    /// ``ClaudioConfig/defaultMasterVolume`` (0.8) lands exactly on this grid (16 stops up from
    /// `0.0`), so the default value is not itself off-grid.
    public static let step: Double = 0.05

    /// Values closer together than this count as the same value for ``isDirty``'s purposes —
    /// Double equality alone is too fragile to gate a disk write on. Historically (before
    /// ``snap(_:)`` was written to divide rather than multiply) this margin was load-bearing: 7
    /// of the 21 grid stops (15/30/35/60/70/85/95%) landed one ULP away from the same value
    /// reached any other way — e.g. parsed straight out of `config.json` — so an exact-equality
    /// dirty check would have judged an untouched slider "changed". ``snap(_:)``'s divide-first
    /// formula closes that gap at the source: all 21 stops are now bit-for-bit identical to
    /// their literal, however they were produced. This constant stays anyway, as cheap
    /// insurance against float noise from any future comparison path that does not route
    /// through ``snap(_:)``.
    private static let epsilon: Double = 1e-9

    /// The value last known to be on disk. Not necessarily on the ``step`` grid: a user may have
    /// hand-edited `config.json` to `0.42`, and rule 3 exists to keep that value alive.
    public private(set) var baseline: Double

    /// What the slider currently shows. Equals ``baseline`` except while a drag is in flight, or
    /// between an ``adjust(to:)``/``end()``/``flushPending()`` call and its resolution via
    /// ``commitSucceeded(_:)``/``commitFailed()``.
    public private(set) var draft: Double

    /// Whether a mouse/trackpad drag is in flight (``begin()`` seen, ``end()`` not yet seen).
    /// Gates ``drag(to:)`` and, inversely, ``adjust(to:)`` — see the type note.
    public private(set) var isDragging: Bool

    /// Whether ``draft`` has diverged from ``baseline`` and therefore still owes the disk a
    /// write. This is the flag rule 2 exists to service.
    public var isDirty: Bool { !VolumeDragSession.approximatelyEqual(draft, baseline) }

    /// - Parameter baseline: the `master_volume` currently in `config.json`. Taken verbatim —
    ///   NOT snapped to the ``step`` grid (rule 3).
    public init(baseline: Double) {
        let safe = AfplayVolume.clamped(baseline)
        self.baseline = safe
        self.draft = safe
        self.isDragging = false
    }

    /// A real mouse/trackpad drag started.
    public mutating func begin() {
        isDragging = true
    }

    /// The slider's value binding moved during a drag. Ignored unless ``begin()`` was called and
    /// ``end()`` has not yet resolved it (rule 6's gate) — snapped onto the grid and clamped, so
    /// no caller can push an off-grid, out-of-range, or non-finite value into ``draft``.
    public mutating func drag(to value: Double) {
        guard isDragging else { return }
        draft = VolumeDragSession.snap(value)
    }

    /// The drag ended normally.
    ///
    /// - Returns: the value to write, or `nil` if the drag left the value where it found it
    ///   (rule 3). A non-`nil` return obliges the caller to attempt the write and report back
    ///   through ``commitSucceeded(_:)``/``commitFailed()``.
    public mutating func end() -> Double? {
        isDragging = false
        return isDirty ? draft : nil
    }

    /// The session is being torn down by something that is not the end of a drag (rule 2).
    ///
    /// - Returns: the value to write if this session still owes the disk one, else `nil`. Safe
    ///   to call unconditionally and repeatedly: a clean session returns `nil`, and a session
    ///   whose commit already landed (``commitSucceeded(_:)`` already moved ``baseline``)
    ///   returns `nil` too.
    public mutating func flushPending() -> Double? {
        isDragging = false
        return isDirty ? draft : nil
    }

    /// A non-drag value change arrived — VoiceOver's adjustable increment/decrement, a keyboard
    /// arrow key (rule 6). Unlike ``drag(to:)``, this both updates ``draft`` *and* resolves to a
    /// commit in the same call, because this input source has no matching "ended" event to
    /// resolve it later.
    ///
    /// - Returns: the value to write, or `nil` — either because a real drag is in flight (the
    ///   mouse/trackpad owns ``draft`` until it lets go) or because the snapped value left
    ///   ``draft`` unchanged (rule 3). A non-`nil` return carries the same obligation as
    ///   ``end()``'s.
    public mutating func adjust(to value: Double) -> Double? {
        guard !isDragging else { return nil }
        draft = VolumeDragSession.snap(value)
        return isDirty ? draft : nil
    }

    /// The write landed. `landed` is the value the writer says actually reached disk (already
    /// clamped by the writer), which is what ``baseline`` must become — not the value that was
    /// *requested*.
    public mutating func commitSucceeded(_ landed: Double) {
        let safe = AfplayVolume.clamped(landed)
        baseline = safe
        draft = safe
    }

    /// The write failed. The disk still holds ``baseline``, so that is what the slider must show
    /// (rule 4). The caller is separately responsible for surfacing *why* — this type never
    /// swallows the error, it only refuses to lie about the value.
    public mutating func commitFailed() {
        draft = baseline
    }

    /// `config.json` was re-read (a pack switch, a popover reopen, another process wrote it) and
    /// its `master_volume` is now `value` (rule 5). Adopts it as the new truth — unless a drag
    /// is in flight, in which case the user's hand wins and only ``baseline`` moves, so the
    /// in-flight drag still resolves against what is actually on disk once it ends.
    public mutating func rebase(to value: Double) {
        let safe = AfplayVolume.clamped(value)
        baseline = safe
        if !isDragging { draft = safe }
    }

    /// Snaps `value` onto the ``step`` grid, clamped into `[0.0, 1.0]`.
    ///
    /// Computed by rounding `value / step` to the nearest whole grid index, then dividing that
    /// index by the number of grid stops (`20`) to land back in `[0.0, 1.0]` — division both
    /// times, never a multiplication back out by ``step`` (D45): the two are different Double
    /// computations, and multiplying the rounded index back out lands 7 of the 21 stops
    /// (15/30/35/60/70/85/95%) one ULP off their literal (`0.35000000000000003` instead of
    /// `0.35`), which `JSONSafeWrite`'s shortest-round-trip renderer would then write to
    /// `config.json` byte-for-byte, untouched by any later read. Dividing instead reaches the
    /// exact same 21 Doubles a human typing `0.35` into the file by hand would (verified
    /// bit-for-bit, all 21 stops).
    ///
    /// The trailing clamp exists for `value`'s domain — out-of-range or non-finite input,
    /// already handled once by the leading ``AfplayVolume/clamped(_:)`` call above — not because
    /// the grid arithmetic itself can leave `[0.0, 1.0]`. It provably cannot: dividing the
    /// already-clamped value by ``step`` lands in `[0, 20]`, rounding keeps an integer in that
    /// same range, and dividing an integer in `[0, 20]` by `20` cannot produce a Double outside
    /// `[0.0, 1.0]`. The second clamp is redundant on that path and kept only because it costs
    /// nothing.
    public static func snap(_ value: Double) -> Double {
        let safe = AfplayVolume.clamped(value)
        let index = (safe / step).rounded()
        return AfplayVolume.clamped(index / 20)
    }

    private static func approximatelyEqual(_ lhs: Double, _ rhs: Double) -> Bool {
        abs(lhs - rhs) <= epsilon
    }
}
