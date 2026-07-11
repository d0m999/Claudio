import Combine
import Foundation

/// Drives one drop-zone: holds its current ``DropZoneState``, and turns a raw drop/pick
/// into a state transition by calling into ``importAudioFile(sourceURL:suggestedFileName:packID:environment:)``
/// / ``importAudioFiles(_:packID:environment:)``.
///
/// Deliberately generic over "one drop zone", not "one event row" — T16 (逐事件导入绑定)
/// owns wiring N of these to N event rows; this type only owns the single-zone mechanics
/// T8 is scoped to. Mirrors `OnboardingViewModel`'s shape: an injectable ``environment``,
/// a `@Published private(set)` state, and an optional hook (`onImportSucceeded`, echoing
/// `onPrimaryAction`/`onSecondaryAction`) that the app layer wires to a real side effect —
/// here, auto-preview playback (ENGINEERING.md T8 acceptance criterion 8).
@MainActor
public final class AudioImportViewModel: ObservableObject {
    /// Which user pack this drop-zone imports into. `var`, not `let`, so a future
    /// per-event-row reuse of this type (T16) can repoint it without reallocating a new
    /// view-model per row.
    public var packID: String

    /// Where imports look/write — injectable so previews/tests never touch the real
    /// `~/.claudio/packs/` (see ``AudioImportEnvironment``'s doc comment).
    public var environment: AudioImportEnvironment

    @Published public private(set) var state: DropZoneState = .idle

    /// Invoked with the just-imported file whenever a drop succeeds — the seam the
    /// SwiftUI view uses to trigger auto-preview playback. `nil` (no-op) by default, same
    /// pattern as `OnboardingViewModel.onPrimaryAction`.
    public var onImportSucceeded: (@MainActor (ImportedAudioFile) -> Void)?

    public init(packID: String, environment: AudioImportEnvironment) {
        self.packID = packID
        self.environment = environment
    }

    /// 把这个 view-model 指到另一个包上，并**丢掉属于上一个包的导入结果**。
    ///
    /// ## 为什么不能只改 `packID`（本轮 /ship 评审：`/codex review` [P2]）
    ///
    /// `state` 讲的是「**在某个包里**，上一次导入的结果是什么」——「已加入 stop.mp3」「这个文件不是音频」。
    /// 一旦 `packID` 指向了别的包，这句话就失去了主语：它描述的那件事发生在包 A，而面板现在显示的是包 B。
    /// 旧的 `PanelView.refresh()` 只写 `importViewModel.packID = ...`，于是包 A 的成功 / 拒绝提示会原样
    /// 留在包 B 的面板上，直到下一次导入把它覆盖掉——用户看到的是一条关于一个他已经离开的包的消息。
    ///
    /// ## 为什么判 `packID != self.packID`，而不是无条件清
    ///
    /// 因为 `refresh()` 不只在切包时被调用，**一次导入 / 绑定结束之后也会调**（行末导入要靠它把行刷成
    /// `.present`）。无条件清空等于把用户刚刚触发的那条结果——尤其是**失败**原因——在他看见之前抹掉，
    /// 那会把这一轮刚修好的「绝不静默吞错」又变回静默。只有包**真的换了**，旧结果才失去主语。
    public func retarget(to newPackID: String) {
        guard newPackID != packID else { return }
        packID = newPackID
        state = .idle
    }

    #if DEBUG
        /// Preview-only initializer (ENGINEERING.md T14 D2): pins ``state`` directly to
        /// `previewState`, without running any import pipeline. Mirrors
        /// `OnboardingViewModel(previewState:)`'s exact reasoning: `#if DEBUG`-gated, and
        /// must live in THIS file since ``state``'s setter is `private` (file-scoped, not
        /// module-scoped).
        public convenience init(
            packID: String, environment: AudioImportEnvironment, previewState: DropZoneState
        ) {
            self.init(packID: packID, environment: environment)
            self.state = previewState
        }
    #endif

    /// Called while a drag is hovering the zone — no filesystem work happens here, just
    /// the visual "hover" state (DESIGN.md "拖入 drop-zone": "hover 命中 → 边框/文字转
    /// 黏土 + `clay-soft` 底"). Mirrors ``cancelHover()``'s guard: a drag merely passing
    /// back over the zone must not clobber a `.reject`/`.success` result that's still
    /// meant to stay visible until the *next* drop (see ``cancelHover()``'s doc comment) —
    /// only `.idle` (or an already-active `.hover`) actually transitions.
    public func hover() {
        guard state == .idle || state == .hover else { return }
        state = .hover
    }

    /// Called when a drag leaves the zone without dropping — returns to the neutral
    /// resting state. Deliberately does **not** clear a `.reject`/`.success` state (only
    /// an active hover): once a drop has actually been evaluated, its result should stay
    /// visible until the *next* drop, not disappear the moment the pointer merely passes
    /// back over the zone.
    public func cancelHover() {
        guard state == .hover else { return }
        state = .idle
    }

    /// Handles one dropped/picked file. `async` so the import pipeline — filesystem
    /// metadata, reading up to 5MB into memory, and the (synchronous, potentially slow)
    /// AVFoundation duration probe — runs **off** the `@MainActor` via `Task.detached`,
    /// never freezing the menu-bar UI while a drop is evaluated; only the `@Published`
    /// `state` mutation (and the `onImportSucceeded` hook) hops back onto the main actor
    /// once the outcome is known. The pure validation logic in
    /// ``importAudioFile(sourceURL:suggestedFileName:packID:environment:)`` deliberately
    /// stays synchronous and directly unit-testable — "run it off the main actor" is this
    /// UI boundary's concern, applied here rather than baked into the free function
    /// (swift-reviewer T8 finding: the pipeline must not block `@MainActor`).
    ///
    /// `packID`/`environment` are read into `Sendable` locals first so the detached
    /// closure never captures `self` (a non-`Sendable`, `@MainActor` class).
    public func handleDrop(sourceURL: URL, suggestedFileName: String) async {
        let packID = self.packID
        let environment = self.environment
        let outcome = await Task.detached {
            importAudioFile(
                sourceURL: sourceURL, suggestedFileName: suggestedFileName, packID: packID,
                environment: environment)
        }.value
        switch outcome {
        case .success(let file):
            state = .success(file)
            onImportSucceeded?(file)
        case .rejected(let reason):
            state = .reject(reason)
        }
    }

    /// Handles a multi-file batch (ENGINEERING.md T8 acceptance criterion 7): ``state``
    /// only ever reflects the outcome that matters most to show right now — the last
    /// accepted file if at least one succeeded (there's one drop zone; a batch drop still
    /// just needs *a* preview to confirm something landed), else the first rejection —
    /// while the returned ``AudioImportBatchResult`` carries the *complete* per-file
    /// result so a caller that wants to render every rejection's reason inline (not just
    /// the one reflected in `state`) still can.
    @discardableResult
    public func handleDrop(requests: [AudioImportRequest]) async -> AudioImportBatchResult {
        let packID = self.packID
        let environment = self.environment
        let result = await Task.detached {
            importAudioFiles(requests, packID: packID, environment: environment)
        }.value
        if let lastAccepted = result.accepted.last {
            state = .success(lastAccepted)
            onImportSucceeded?(lastAccepted)
        } else if let firstRejected = result.rejected.first {
            state = .reject(firstRejected.reason)
        }
        return result
    }
}
