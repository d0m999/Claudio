import ClaudioCore
import Foundation

/// Drives one event row's drag/pick-to-bind affordance (ENGINEERING.md T16 D3): wraps an
/// ``AudioImportViewModel`` for the drop/pick mechanics — hover / reject / success — T8
/// already built and tested (identical hardening pipeline, identical `DropZoneState`), and
/// adds the one behavior a per-event row needs on top of a plain drop zone: once a file
/// lands, BIND it to ``event`` in the pack's `manifest.json`
/// (``bindEventToManifest(event:fileName:packID:environment:)``), so the row's
/// ``CoverageState`` (recomputed on the next ``packCoverage(packID:config:environment:)``
/// call) reflects `.present` right after.
///
/// Composition over reuse-by-mutation: this type owns *when* to call `bindEventToManifest`
/// (synchronously, right after `importViewModel.handleDrop` returns and only when its
/// outcome was `.success`) rather than repurposing `AudioImportViewModel`'s existing
/// `onImportSucceeded` hook — that hook is already the seam `AudioDropZoneView` wires for
/// T8's auto-preview playback, and a second, unrelated caller silently overwriting it would
/// be exactly the kind of hidden coupling this codebase's "many small files, low coupling"
/// convention avoids. `AudioImportViewModel` itself is untouched by T16 — its own doc
/// comment already anticipated this: "`packID`, not `let`, so a future per-event-row reuse
/// of this type (T16) can repoint it without reallocating a new view-model per row."
@MainActor
public final class EventRowImportViewModel: ObservableObject {
    /// Which of the four v1 events this row's drops bind to.
    public let event: Event

    /// The underlying single-drop-zone mechanics (hover/reject/success), reused verbatim.
    public let importViewModel: AudioImportViewModel

    /// The most recent bind attempt's outcome — `nil` before any drop has landed on this
    /// row. Distinct from `importViewModel.state`'s own `.reject`: a failed *import* never
    /// reaches the bind step at all (``bindResult`` is left untouched in that case), so a
    /// view can tell "the import itself failed" (`importViewModel.state == .reject`) apart
    /// from "the import succeeded but binding the manifest failed" (`bindResult ==
    /// .failure`) — two different failure surfaces with two different causes, never folded
    /// into one (project rule: never silently misreport the real cause).
    @Published public private(set) var bindResult: Result<Void, ManifestBindError>?

    public init(event: Event, importViewModel: AudioImportViewModel) {
        self.event = event
        self.importViewModel = importViewModel
    }

    /// Handles one dropped/picked file for this row: imports it via ``importViewModel``,
    /// then — only on a successful import — binds the resulting file to ``event``. `async`
    /// for the same reason ``AudioImportViewModel/handleDrop(sourceURL:suggestedFileName:)``
    /// is: the import pipeline it wraps already runs off the main actor via
    /// `Task.detached`; this function just awaits that, then performs the (fast, local-disk)
    /// bind synchronously back on the main actor once the outcome is known.
    ///
    /// ## Never re-read mutable state across the `await` (T16 review 修复③)
    /// Both the import OUTCOME and the pack the bind writes into come from values this call
    /// OWNS — the batch overload's returned ``AudioImportBatchResult`` and, inside it, the
    /// imported file's own ``ImportedAudioFile/packID`` (stamped by
    /// ``importAudioFile(sourceURL:suggestedFileName:packID:environment:)`` at the moment the
    /// bytes were actually copied). Neither is re-read off ``importViewModel`` after the
    /// suspension, and that is the entire point:
    ///
    /// - `importViewModel.packID` is MUTABLE and really does change mid-flight —
    ///   `PanelView.refresh()` repoints every row's `packID` on a pack switch. A user who
    ///   switches packs while an import is in flight would otherwise have the file copied into
    ///   pack A (where the pipeline started) but the manifest binding written into pack B —
    ///   silently editing a DIFFERENT pack than the one that received the file.
    /// - `importViewModel.state` is likewise mutable and shared across every drop on this row;
    ///   deciding "did MY drop succeed?" by reading whatever `state` happens to hold after the
    ///   await would let a sibling drop's outcome answer for this one (leaving this drop's
    ///   already-copied file bound to nothing — an orphan, with no error surfaced anywhere).
    ///
    /// Uses ``AudioImportViewModel/handleDrop(requests:)`` (the one-element batch) precisely
    /// because it RETURNS the per-file outcome; the single-file overload only publishes it to
    /// `state`. State transitions/`onImportSucceeded` are identical for a one-element batch.
    ///
    /// ## Concurrency invariant (no lock needed today — do not silently break this)
    /// The raw manifest read-modify-write inside ``bindEventToManifest(event:fileName:packID:environment:)``
    /// is safe against concurrent per-row binds ONLY because that function is fully
    /// SYNCHRONOUS, and every caller of it — this function — invokes it on the `@MainActor`
    /// with no `await`/suspension point between its internal manifest read and its internal
    /// write. That means two event rows binding into the SAME pack (e.g. two drops landing
    /// in quick succession) serialize on the main actor: the second call's read is
    /// guaranteed to happen strictly after the first call's write already landed — no lost
    /// update. `manifest.json` also has no other writer anywhere in this codebase (the CLI
    /// only ever writes `config.json`; `doctor`/`play` only ever read `manifest.json`). If
    /// `bindEventToManifest` is ever made `async` or moved off the main actor, per-pack
    /// write serialization (e.g. an actor, or a file lock mirroring `helper`'s `FileLock`)
    /// MUST be added at that point — this note is the tripwire for that future refactor, not
    /// a claim that the current synchronous/`@MainActor` structure needs one now.
    public func handleDrop(sourceURL: URL, suggestedFileName: String) async {
        // 在 await 之前捕获环境（与 packID 同理：它也是 `var`，绝不跨挂起点重读可变状态）。
        let environment = importViewModel.environment
        let result = await importViewModel.handleDrop(
            requests: [
                AudioImportRequest(sourceURL: sourceURL, suggestedFileName: suggestedFileName)
            ])
        // 只认这一笔导入自己的返回值 —— 不读 importViewModel.state。
        guard let file = result.accepted.first else { return }
        // packID 用 file.packID：字节真正被复制进去的那个包，而不是此刻 importViewModel 指向的包
        // （用户可能已经切了包）。
        bindResult = bindEventToManifest(
            event: event, fileName: file.fileName, packID: file.packID,
            environment: environment)
    }
}
