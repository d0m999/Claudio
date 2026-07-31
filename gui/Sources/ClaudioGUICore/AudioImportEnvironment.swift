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
    /// distribution to consider, e.g. most test fixtures). Only ever *read* — fed to
    /// ``resolvePackDirectory(id:userPacksDirectory:bundledPacksDirectory:)`` to decide pack
    /// **lookup order** — never written to.
    ///
    /// ⚠️ As of T6 (PLAN-SOUND-MANAGER.md §2.3) this field no longer has anything to do with
    /// deciding ``DropRejectionReason/builtinReadOnly(packID:)`` — that used to be true (the
    /// now-deleted `isBuiltinOnlyPackID`), but reusing this field for that decision was
    /// rejected: it would mean flipping it from `nil` to a real path makes a pack that only
    /// exists in the app bundle (not yet copied into the user root) visible in the gallery —
    /// while `play` (`PlayEnvironment.bundledPacksDirectory` is always `nil`) can't see it at
    /// all, a false negative `Setup.swift:503-505` already documents having been burned by.
    /// The built-in-readonly decision now lives entirely on ``builtinPackIDs`` (derived from
    /// ``factoryPacksDirectory``), which is completely independent of this field.
    public var bundledPacksDirectory: URL?

    /// **出厂包的拷贝源** —— `Claudio.app/Contents/Resources/packs/` 的真实路径，仅供拷贝，
    /// **绝不是查找根**（PLAN-SOUND-MANAGER.md §2.3）。
    ///
    /// 与 ``bundledPacksDirectory`` 职责正交，两个字段长得像但回答的是两个不同的问题：
    ///   · `bundledPacksDirectory` 回答「去哪找」—— 喂给
    ///     ``resolvePackDirectory(id:userPacksDirectory:bundledPacksDirectory:)``，决定的是
    ///     **包的查找顺序**（GUI 生产侧恒 `nil`，与 helper `play` 的查找结果逐字一致）。
    ///   · `factoryPacksDirectory` 回答「出厂包从哪拷来」—— 只喂给 ``builtinPackIDs``（派生
    ///     只读判据）与 T6 `forkPack(fromID:newID:environment:)`（`PackFork.swift`，拷贝源），
    ///     从不参与任何「这个包存不存在 / 查得到查不到」的判断。
    ///
    /// ⚠️⚠️ **绝不能被传给 `resolvePackDirectory`。** 那样会让一个只存在于
    /// `Contents/Resources/packs/`、还没被拷进用户根的包在面板画廊里可见 —— 而 helper 的
    /// `play` 看不见它（`PlayEnvironment.bundledPacksDirectory` 恒 `nil`），一次假阴性
    /// （`Setup.swift:503-505` 已经踩过并写下了这个警告）。
    ///
    /// `nil`（`swift run ClaudioGUI` 无 bundle、以及全部测试 fixture 的默认状态）= 没有任何
    /// 包是内置的 = 没有任何包是只读的。与 `bundledHelperBinary(in: .main)` 在无 bundle 时
    /// 回落 `nil` 的诚实降级同构。
    public var factoryPacksDirectory: URL?

    /// 派生，**不是第二个真相源**——`factoryPacksDirectory` 下真实子目录名的集合（`nil` →
    /// 空集）。`environment.builtinPackIDs.contains(packID)` 是「这个包只读吗」唯一合法的判据
    /// （PLAN-SOUND-MANAGER.md §2.3：`manifest.author == "Claudio"` 与硬编码 id 清单都被否
    /// 掉的理由，以及为什么不能复用 `bundledPacksDirectory`，都写在那一节）。
    ///
    /// 复用 ``packDirectoryIDs(in:)``（`PackGallery.swift`，本模块内可见）——同一份「列目录 +
    /// 排点开头条目 + 排非目录条目」逻辑，不重新发明第二遍。
    public var builtinPackIDs: Set<String> {
        guard let factoryPacksDirectory else { return [] }
        return Set(packDirectoryIDs(in: factoryPacksDirectory))
    }

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

    /// 在导入已分配唯一候选、但尚未以不可覆盖语义发布之前调用的测试钩子。生产构造不传时为
    /// `nil`；测试用它在精确的 TOCTOU 窗口放入一个外部目录项，验证最终发布会重新分配名称而非
    /// 覆盖该项。回调是同步的，且必须自行满足 `Sendable`。
    public var beforeExclusivePublish: (@Sendable (URL) -> Void)?

    /// `forkPack` 已完成 factory copy 与 manifest rewrite、但尚未执行最终独占目录发布时调用。
    /// 与音频导入的 ``beforeExclusivePublish`` 分开：两者处于不同写路径，复用同一个 hook 会让
    /// 测试注入的语义随调用者漂移。生产默认 `nil`；测试可在这里抢占 final URL，或抛错验证
    /// 非 `EEXIST` 发布失败的清理与错误映射。
    public var beforeForkPackPublish: (@Sendable (URL) throws -> Void)?

    /// T12 `restoreFactoryPack` 的目录发布失败注入点。它在旧目录已经完整 salvage、出厂副本仍只
    /// 存在于点前缀 staging 时同步调用；生产构造恒为 `nil`。测试用它证明这一精确中断点不会暴露
    /// 半份包，并且失败结果仍携带用户旧目录的可告知路径。
    public var beforeFactoryPackRestorePublish: (@Sendable () throws -> Void)?

    /// T12 `restoreFactoryPack` 的 salvage 失败注入点。它在完整 factory staging 已准备好、旧
    /// 安装仍在原位时同步调用；生产构造恒为 `nil`。测试用它证明搬移失败会清理 staging、保留
    /// 用户原目录，并且不会发布一次假刷新。
    public var beforeFactoryPackRestoreSalvage: (@Sendable () throws -> Void)?

    public init(
        userPacksDirectory: URL = ClaudioPaths.packsDirectory,
        bundledPacksDirectory: URL? = nil,
        factoryPacksDirectory: URL? = nil,
        durationProbe: any AudioDurationProbing,
        limits: AudioImportLimits = AudioImportLimits(),
        packsLockFile: URL,
        beforeExclusivePublish: (@Sendable (URL) -> Void)? = nil,
        beforeForkPackPublish: (@Sendable (URL) throws -> Void)? = nil,
        beforeFactoryPackRestorePublish: (@Sendable () throws -> Void)? = nil,
        beforeFactoryPackRestoreSalvage: (@Sendable () throws -> Void)? = nil
    ) {
        self.userPacksDirectory = userPacksDirectory
        self.bundledPacksDirectory = bundledPacksDirectory
        self.factoryPacksDirectory = factoryPacksDirectory
        self.durationProbe = durationProbe
        self.limits = limits
        self.packsLockFile = packsLockFile
        self.beforeExclusivePublish = beforeExclusivePublish
        self.beforeForkPackPublish = beforeForkPackPublish
        self.beforeFactoryPackRestorePublish = beforeFactoryPackRestorePublish
        self.beforeFactoryPackRestoreSalvage = beforeFactoryPackRestoreSalvage
    }
}
