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

    /// `~/.claudio/packs.lock` — 序列化整个 `packs/` 子树写者的那把锁（见
    /// ``ClaudioPaths/packsLockFile``）。`bindEventToManifest` / `clearEventBinding` 把它递给
    /// ``mutateManifestJSON(at:lockFile:_:)`` 序列化 `manifest.json` 的读-改-写；
    /// ``importAudioFile(sourceURL:suggestedFileName:packID:environment:)`` 把它递给
    /// `withNonBlockingLock` 序列化「建包目录 + 落音频文件」那一步——与
    /// `performFirstRunSetup` 的目录级包发布循环共用同一把（三个写者，同一把锁）。
    ///
    /// ## 它**没有**默认值，而兄弟字段有 —— 这个不对称是刻意的
    ///
    /// `userPacksDirectory` 留着 `ClaudioPaths.packsDirectory` 那个默认值，这一把不留。理由是两者
    /// 漏传的**失败模式不一样**：忘了 `userPacksDirectory` 的测试会当场断言失败（真实 packs 目录里
    /// 没有 fixture），**响**的那一类；而忘了这把锁只会**静默**地去用户机器上开一把真锁 —— 测试
    /// 照样全绿，只是与正在运行的 Claudio.app 抢锁、并在 `~/.claudio/` 里落一个文件。
    ///
    /// 静默那一类不能靠纪律，只能靠编译器。
    ///
    /// ## 实测的那次实锤（`/codex review 95d16a5,b89a0ee,37745f2` 的 P1-A）
    ///
    /// 默认值还在的时候，往 `gui/Tests` 里加一个漏传它、又走 `clearEventBinding` 的 fixture：
    /// 编译通过、**2421 条断言全绿**，而把真实的 `~/.claudio/packs.lock` 挪开之后再跑，那个文件被
    /// **重新创建**出来（0 字节、`0600`，正是 `FileLock` 的 `open(O_CREAT, 0o600)` 留下的签名）。
    /// 不是推理，是把用户 home 上那个文件挪开再看它长不长回来。
    ///
    /// ⚠️ **别把这段读成「一直如此」**：`makeAudioImportEnvironment` 与另外三个 suite 私有的
    /// `makeEnvironment` 曾经都漏传了它，合计吸收八十余个调用点，全部靠那个默认值跑在用户真实
    /// home 上（b89a0ee 修的就是它们）。它们没有当场闹出事，只是因为那些 suite 恰好都不走
    /// `mutateManifestJSON` —— 这条纪律当时**没有任何东西在执行它**，靠的是「碰巧没人用到」。
    ///
    /// ## 现在执行它的是编译器，而「编译器在执行它」这件事由一条源码绊线钉住
    ///
    /// 把默认值加回去是一次**纯放宽**：现存调用点全都显式传着值，加完 `swift build` 零诊断。
    /// 编译器强制的是默认值的*后果*，从不是它的*不存在* —— 这个仓库为同一句话立过两个判例
    /// （`@MainActor` 与「同步无挂起点」，都记在 `ManifestBinding.swift` 的 doc 里）。守住它的是
    /// `ViewWiringSuite` 那条「`AudioImportEnvironment` 的 `packsLockFile` 不许有默认值」。
    ///
    /// 测试侧一律递临时路径（`AudioImportFixtures.swift` 的 `injectedPacksLock(under:)`，全包唯一
    /// 来源，那句「唯一」由一条构造点普查钉着）。生产侧两个构造点显式写出真实路径，各自有绊线看着。
    ///
    /// ⚠️ 如实标注**还剩什么没关**：编译器逼的是「必须传」，不是「必须传对」。一个测试显式写
    /// `packsLockFile: ClaudioPaths.packsLockFile` 依然会去用户 home 上开锁。那一种是**响**的
    /// （写下这一行的人知道自己在写什么，且它会出现在 diff 里），与本刀治的「静默漏传」不是一类；
    /// 不声称封死。
    public var packsLockFile: URL

    public init(
        userPacksDirectory: URL = ClaudioPaths.packsDirectory,
        bundledPacksDirectory: URL? = nil,
        durationProbe: any AudioDurationProbing,
        limits: AudioImportLimits = AudioImportLimits(),
        packsLockFile: URL
    ) {
        self.userPacksDirectory = userPacksDirectory
        self.bundledPacksDirectory = bundledPacksDirectory
        self.durationProbe = durationProbe
        self.limits = limits
        self.packsLockFile = packsLockFile
    }
}
