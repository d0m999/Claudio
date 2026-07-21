import ClaudioCore
import Foundation

/// An injectable, synchronous probe for an audio file's duration — the seam that keeps
/// `ClaudioGUICore` Foundation-only (ENGINEERING.md T8 acceptance criterion 4: "Duration
/// needs AVFoundation, which must NOT be imported into Foundation-only ClaudioGUICore").
/// The real, AVFoundation-backed conformance lives in the `ClaudioGUI` app layer and is
/// injected at call sites there; tests inject a stub returning a fixed value (see
/// `AudioImportSuite.swift`) — the same DI pattern this module already uses throughout
/// (`OnboardingEnvironment`, `DoctorEnvironment` in `helper`).
public protocol AudioDurationProbing: Sendable {
    /// The duration of the audio file at `fileURL`, in seconds, or `nil` if it could not
    /// be determined (corrupt/unreadable). ``importAudioFile(sourceURL:suggestedFileName:packID:environment:)``
    /// treats `nil` as failing the duration cap — fail-closed, rather than silently
    /// letting an unmeasurable file through the size/duration gate.
    func probeDuration(of fileURL: URL) -> TimeInterval?
}

/// Numeric caps enforced by ``importAudioFile(sourceURL:suggestedFileName:packID:environment:)``.
public struct AudioImportLimits: Sendable, Equatable {
    /// ENGINEERING.md 决议 "拖入自带音频": "大小上限（如 5MB）".
    public let maxFileSizeBytes: Int

    /// A provisional cap for a short UI chime. T9 (ENGINEERING.md, not yet landed) owns
    /// the final, objective sound-quality standard ("单音时长上限 ≤~2s" among loudness
    /// normalization / peak limiting / silence trimming). T8 needs *a* concrete number
    /// now to enforce a cap at all — this errs slightly generous (3s) rather than
    /// guessing T9's exact final value, and is trivially retunable in this one place once
    /// T9 lands, without a second call spread across the codebase.
    public let maxDurationSeconds: Double

    public init(
        maxFileSizeBytes: Int = 5 * 1024 * 1024,
        maxDurationSeconds: Double = 3.0
    ) {
        self.maxFileSizeBytes = maxFileSizeBytes
        self.maxDurationSeconds = maxDurationSeconds
    }
}

/// Everything ``importAudioFile(sourceURL:suggestedFileName:packID:environment:)`` needs,
/// injectable for tests so they never touch the real `~/.claudio/packs/` (mirrors
/// `helper`'s `DoctorEnvironment` / gui's `OnboardingEnvironment` pattern exactly — see
/// `OnboardingEnvironment`'s doc comment for why a `$HOME` override wouldn't even work on
/// Darwin; tests must pass concrete fixture `URL`s instead, exactly as every other suite
/// in this package's test harness does with `withTempDirectory`).
public struct AudioImportEnvironment: Sendable {
    /// `~/.claudio/packs/` — copy destinations are always confined under here, never the
    /// read-only bundled pack root (ENGINEERING.md T8 acceptance criterion 1: "Drag-in =
    /// COPY the file into the user pack... never reference the original path").
    public var userPacksDirectory: URL

    /// The read-only, app-bundled pack root, if any (`nil` when there is no bundled pack
    /// distribution to consider, e.g. most test fixtures). Only ever *read* — to decide
    /// ``DropRejectionReason/overwritesBuiltin(packID:)`` — never written to.
    public var bundledPacksDirectory: URL?

    public var durationProbe: any AudioDurationProbing

    public var limits: AudioImportLimits

    /// `~/.claudio/packs.lock` — 序列化 `manifest.json` 两个写者的那把锁（见
    /// ``ClaudioPaths/packsLockFile``）。`bindEventToManifest` / `clearEventBinding` 把它递给
    /// ``mutateManifestJSON(at:lockFile:_:)``。
    ///
    /// ⚠️ 默认值是**真实**路径，和 `userPacksDirectory` 一样。但忘记注入的后果**不一样**：
    /// 忘了 `userPacksDirectory` 的测试会当场断言失败（真实 packs 里没有 fixture），
    /// 而忘了这把锁只会**静默**地去用户机器上开一把真锁 —— 测试照样全绿，只是与正在运行的
    /// Claudio.app 抢锁、并在 `~/.claudio/` 里落一个文件。这个默认值本身由 `LockSeparationSuite` 钉住。
    ///
    /// 所以本包的测试 fixture 一律显式递临时路径（`AudioImportFixtures.swift` 的
    /// `injectedPacksLock(under:)`，全包唯一来源）。
    ///
    /// ⚠️ **这句话在 2026-07-21 之前是假的，别把它读成一直如此**：`makeAudioImportEnvironment`
    /// 与另外三个 suite 私有的 `makeEnvironment` 当时都漏传了它，合计吸收八十余个调用点，全部
    /// 靠这个默认值跑在用户真实 home 上。它们没有当场闹出事，只是因为那些 suite 恰好都不走
    /// `mutateManifestJSON`（本包真的会去持这把锁的只有 `ManifestBindingSuite`）—— 也就是说，
    /// 这条纪律当时**没有任何东西在执行它**，靠的是「碰巧没人用到」。
    ///
    /// 现在也**仍然没有**普查在执行它：新加一个漏传的 fixture 依旧不会有任何断言变红。要的是一条
    /// 扫测试目录的围栏，而围栏得先解决「构造形式白名单永远不完整」那个前提（见
    /// ``callArguments(of:in:)`` 的 doc）。在那之前，这段话是**约定**，不是守卫 —— 如实标注。
    public var packsLockFile: URL

    public init(
        userPacksDirectory: URL = ClaudioPaths.packsDirectory,
        bundledPacksDirectory: URL? = nil,
        durationProbe: any AudioDurationProbing,
        limits: AudioImportLimits = AudioImportLimits(),
        packsLockFile: URL = ClaudioPaths.packsLockFile
    ) {
        self.userPacksDirectory = userPacksDirectory
        self.bundledPacksDirectory = bundledPacksDirectory
        self.durationProbe = durationProbe
        self.limits = limits
        self.packsLockFile = packsLockFile
    }
}
