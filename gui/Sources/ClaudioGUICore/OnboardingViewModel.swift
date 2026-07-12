import Combine
import Foundation

/// Drives the onboarding panel: holds the current ``OnboardingState`` (detected from
/// ``environment``), exposes its ``OnboardingCopy``, re-detects on demand via ``refresh()``,
/// and — since T17 — actually RUNS the state's call-to-action.
///
/// ## T17：CTA 从「一个可选闭包」变成「一个构造注入的执行器」
///
/// T7 留下的接线口是两个 `(@MainActor () -> Void)?`，默认 `nil` = no-op。生产代码里**从来
/// 没有人给它们赋过值**，所以「修复」按钮点下去磁盘一个字节都不变 —— 2026-07-11 真机实测确认
/// （`shasum ~/.claude/settings.json` 不变、`~/.claudio/bin` 仍不存在）。这个类型现在从结构上
/// 让那件事不可能再发生：
///
/// - ``actionRunner`` 是**非可选的、构造时必须给**。忘了接线 = **编译错误**，不是一次全绿的测试。
///   （做成 `var runner: (any OnboardingActionRunning)?` 只是把同一个洞挪高一层：nil 时那句
///   `guard let runner else { refresh(); return }` 与今天的 no-op 一字不差。）
/// - 失败**必须说出来**：``actionState`` 变成 `.failed`，视图渲染它。这个 codebase 已经被
///   「静默失败」咬过三次（`bindResult` / `EventMuteController.lastError` / `switchPack` 的
///   `UseError` 全都写了但没有任何视图读），不能有第四次。
/// - 动作方法是 `async` 的：harness 得能 `await` 到它真的跑完，否则那些「失败真的上报了吗 /
///   `refresh()` 真的跑了吗」的测试只是靠一个瞬时 fake 恰好在一个调度回合内跑完而侥幸全绿。
@MainActor
public final class OnboardingViewModel: ObservableObject {
    /// Where on disk this view-model looks — injectable so previews/tests never touch
    /// the real `~/.claude` / `~/.claudio` (see ``OnboardingEnvironment``'s warning about
    /// `$HOME` not working on Darwin).
    ///
    /// `let`, **不是 `var`**（T17c）：``OnboardingActionEnvironment`` 的文档承诺「探测器在看哪个文件」
    /// 与「安装器在写哪个文件」**结构上不可能分叉**，而那条不变式此前只在构造那一瞬间成立 —— runner
    /// 在 init 时就把自己那份环境**按值**冻住了，任何一次 `viewModel.environment = …` 都会让探测读
    /// 路径 A、安装写路径 B，零编译错误、零红灯。要换环境就重建 view-model（连带重建 runner），
    /// 让「只换一半」结构上不可能。
    public let environment: OnboardingEnvironment

    @Published public private(set) var state: OnboardingState

    /// CTA 动作本身的状态 —— 与 ``state`` 正交的第五族状态（进 `PreviewFixtures` / state gallery）。
    @Published public private(set) var actionState: OnboardingActionState = .idle

    /// 「查看原因」是否展开。**在 view-model 里，不在视图里**：它此前是 `OnboardingView` 的一个
    /// `@State private var isShowingDetail`，连带那句 `if copy.detail != nil { toggle() } else
    /// { performSecondaryAction() }` 的分派 —— 两者都是 SwiftUI 里的判定逻辑，harness 够不到。
    /// 这正是本仓库已经下沉过一次的形状（T16 修复⑥ 的 `previewClaimsActionFocus` /
    /// `panelOpeningFocus`：测试证明函数算得对，却没人盯住视图是否调用它）。
    @Published public private(set) var isShowingDetail: Bool = false

    /// 当前这条 ``actionState`` 里的**结果**（一条失败，或一条「我替你做主」的告知），
    /// **有没有真的出现在屏幕上过**（T17d 立的规矩；T17f 把它从「失败」推广到「结果」）。
    ///
    /// ## 为什么告知必须共用这条寿命规则，而不是随手挂上去
    ///
    /// T17d 那个 bug 一字不改地适用于告知，而且**更容易撞上**：用户点「接管」，在几百毫秒的
    /// 复制期间点到别的 app 上 —— `popover.behavior = .transient`，面板**当场关闭**。而 CTA 那句
    /// `Task { await viewModel.performPrimaryAction() }` 不随视图销毁而取消：它继续跑、成功、
    /// 把「你选的包没了，我替你换成了 X」写进 `actionState`。此刻屏幕上**没有任何一个像素属于它**。
    ///
    /// 若这里只认 `.failed`，告知就会落进两个坑之一（取决于 ``panelDidBecomeVisible()`` 怎么写）：
    /// 要么**永远不清**（一条陈旧的告知永久挂在面板底部），要么**一帧没露就被清掉**（用户永远
    /// 不知道他的包被换过）。后者正是 T17d 那个 bug 的形状，在成功路径上重演一次。
    ///
    /// **刻意不是关联值**，两条具体理由（对 `.failed` 与 `.reported` 同样成立）：
    /// ① `PreviewFixtures.onboardingActionStateCoverage` 只按 `detail == nil` 给 `.failed` 分标签，
    ///    多出来的这一维**产生不了新 label** —— `assertExhaustive()` 会在「新变体一帧都没渲染过」
    ///    的情况下照样全绿，正是 `PreviewFixtures` 自己写在文档里警告的「真相源漏了一维」那个形状。
    /// ② 标记「看过了」会**改写 `actionState`**，于是 `PanelView` 的
    ///    `.onChange(of: onboardingViewModel.actionState)` 会二次触发 —— VoiceOver 把同一条失败
    ///    播报两遍，焦点再重置一次。
    ///
    /// 它**不是 `@Published`**：没有任何一个像素读它。它只决定结果的**寿命**，不决定结果的**长相**
    /// （两个渲染点都无条件画「有没有失败」与「有没有告知」，这条结构不变式 T17c 立、T17f 照搬）。
    public private(set) var outcomeHasBeenSeen: Bool = false

    /// 面板此刻是不是真的在屏幕上。由 `MenuBarController` 的两个 `NSPopoverDelegate` 回调驱动
    /// （``PanelFocusCoordinator/showCount`` / ``PanelFocusCoordinator/hideCount``），**不是**
    /// SwiftUI 的 `.onAppear` / `.onDisappear` 推断出来的 —— `PanelFocusCoordinator` 的文档已经
    /// 写明：`NSPopover` 在 show/close 之间**不一定**重建内容视图层级，`@StateObject` 活满整个
    /// 进程，所以 `.onAppear` 根本不是「面板可见」的可靠信号。把「有没有被看见」押在一个没实测过的
    /// AppKit 语义上，就是在造第五轮。
    private var isPanelVisible: Bool = false

    /// 真实副作用的执行者。**非可选**（见类型文档）。
    private let actionRunner: any OnboardingActionRunning

    /// 这个实例是不是被 pin 死状态的预览实例。`true` 时 ``perform(_:)`` 完全不动作 —— 画廊里点一下
    /// 按钮不该把 pin 住的状态重新探测掉。（`init(previewState:)` 的 doc comment 一直这么承诺，
    /// 但此前并不成立：`performPrimaryAction()` 会走到 `refresh()`，对着 `/dev/null` 占位环境重新
    /// 探测，把 pin 的状态静默改写成 `.claudeCodeNotInstalled`。）
    private let isPreviewPinned: Bool

    public init(
        environment: OnboardingEnvironment = OnboardingEnvironment(),
        actionRunner: any OnboardingActionRunning
    ) {
        self.environment = environment
        self.actionRunner = actionRunner
        self.isPreviewPinned = false
        self.state = detectOnboardingState(environment: environment)
    }

    #if DEBUG
        /// Preview-only initializer (ENGINEERING.md T14 D2): pins ``state`` — and, since T17,
        /// ``actionState`` — directly, without running ``detectOnboardingState(environment:)`` or
        /// touching disk at all: the state gallery's only way to render a SPECIFIC state
        /// deterministically. `environment` is a harmless, never-resolved placeholder; the runner
        /// is a ``NoopOnboardingActionRunner`` that DECLARES the gallery does not run real actions
        /// (rather than accidentally not running them); and ``perform(_:)`` is a total no-op on a
        /// pinned instance, so a live-Canvas tap can no longer rewrite the pin out from under the
        /// frame. `#if DEBUG`-gated so this never ships in release, and it must live in THIS file
        /// since ``state``'s setter is `private` and Swift's `private` is file-scoped.
        public init(previewState: OnboardingState, actionState: OnboardingActionState = .idle) {
            self.environment = OnboardingEnvironment(
                settingsFile: URL(fileURLWithPath: "/dev/null/claudio-preview-settings.json"),
                claudioBinaryPath: URL(fileURLWithPath: "/dev/null/claudio-preview-binary"))
            self.actionRunner = NoopOnboardingActionRunner()
            self.isPreviewPinned = true
            self.state = previewState
            self.actionState = actionState
        }
    #endif

    /// This state's presentation copy — recomputed from ``state``, never cached, so it
    /// can never drift out of sync with it.
    public var copy: OnboardingCopy {
        onboardingCopy(for: state)
    }

    /// 有没有一个写盘动作正在跑（视图据此禁用按钮 + 显示 spinner）。
    public var isPerformingAction: Bool {
        if case .running = actionState { return true }
        return false
    }

    /// `intent` 这颗按钮此刻是不是正在跑 —— 视图用它决定把 spinner 画在哪一颗上。
    public func isRunning(_ intent: OnboardingActionIntent?) -> Bool {
        guard let action = intent?.diskAction, case .running(let running) = actionState else {
            return false
        }
        return running == action
    }

    /// Re-runs detection against the current ``environment`` and updates ``state``. The
    /// state machine's entire transition rule: call this after anything that might have changed
    /// the on-disk facts (a fix applied outside the app, the panel regaining focus, an action
    /// completing).
    ///
    /// 刻意**不清** ``actionState``：`refresh()` 在一次失败的动作之后也会被调用（`runDiskAction`
    /// 的最后一行），无条件清空会把用户刚触发的那条失败原因在他看见之前抹掉 —— 那等于把刚修好的
    /// 「绝不静默吞错」又变回静默（`/ship` 收口记录 ⑬① 的 `retarget(to:)` 为一模一样的取舍交过学费）。
    /// 清空只发生在**下一次动作真正开始时**（``runDiskAction(_:)`` / `.reDetect`）。
    public func refresh() {
        state = detectOnboardingState(environment: environment)
    }

    /// 跑当前状态的主 CTA。`async`：调用方（视图 / harness）能 await 到它真的跑完。
    public func performPrimaryAction() async {
        await perform(onboardingPrimaryIntent(for: state))
    }

    /// 跑当前状态的次 CTA。
    public func performSecondaryAction() async {
        await perform(onboardingSecondaryIntent(for: state))
    }

    /// 展开 / 收起「查看原因」。
    ///
    /// **一个独立的公开入口，不能复用 `performSecondaryAction()`**：`.installed` 态下次 CTA 是
    /// `.disconnect`，把失败行的「查看原因」接到它上面会**再跑一次断开**。
    /// （`.revealDetail` intent 也走这里，所以「翻这个 flag」全仓只有一个实现。）
    public func toggleDetail() {
        guard !isPreviewPinned, !isPerformingAction else { return }
        isShowingDetail.toggle()
    }

    /// 面板真的出现在屏幕上了（`MenuBarController.popoverDidShow` → ``PanelFocusCoordinator/showCount``）。
    ///
    /// ## 它替换掉的那个 bug（T17d 第四轮对抗评审 · Codex 独立发现）
    ///
    /// 上一版叫 `clearConsumedFailure()`：面板每次重开就清掉当前那条 `.failed`，理由是「重开 =
    /// 上一条失败已经被用户看过了」。**那个理由是一个假定，而它在最要命的一条路径上是假的。**
    ///
    /// 用户点「接管 Claude Code」，然后（在几百毫秒的复制二进制 + 复制音频 + flock 期间）点到别的
    /// app 上 —— `popover.behavior = .transient`，面板**当场关闭**。而 CTA 那句
    /// `Task { await viewModel.performPrimaryAction() }` 是一个**不随视图销毁而取消**的非结构化
    /// Task：它继续跑、撞上 `play.lock`（或任何一条 `SetupError`）、失败、把 `actionState` 写成
    /// `.failed`。此刻屏幕上**没有任何一个像素属于它**。用户回来重开面板 → 上一版第一件事就是把它
    /// 当成「看过了」清掉。**用户永远不知道接管失败了。**
    ///
    /// 这是 T17 那句「装完后是哑的」的第四个形状：前三次是死按钮、死错误、没人渲染的格子；这一次，
    /// 失败被**渲染过一次都没有**就清掉了。而它恰恰住在修「死错误」的那次提交里。
    ///
    /// ## 修法：不再假定，而是记录
    ///
    /// 「这条失败有没有被人看见过」在它**诞生的那一刻**就是一个已知事实（面板开着吗？），而不是
    /// 下一次打开时需要猜的东西。``runDiskAction(_:)`` 直接把它记进 ``outcomeHasBeenSeen``。
    /// 于是这里的规则退化成两行，不含任何假定：
    /// - 已经被看过 → 忘掉它（T17c 那条「陈旧失败不该永久挂在一张已经装好的面板上」的顾虑，原样兑现）。
    /// - 还没被看过 → **这一次打开就是它的第一次露面**，标记为已看过，但**绝不清掉**。
    ///
    /// 必须在 `PanelView` 里跑在 `refresh()` / `applyFirstFocus()` **之前**：清掉 `.failed` 会改变
    /// `hasDetailToggle`，而 `applyFirstFocus()` 要按清理**之后**的焦点序落焦，否则光标会落在一颗
    /// 刚被清掉的「查看原因」上。
    public func panelDidBecomeVisible() {
        guard !isPreviewPinned else { return }
        isPanelVisible = true

        // `.failed` / `.reported` 与 `.running` 在枚举层面互斥，所以这里不需要 `!isPerformingAction`
        // —— 一条正在跑的动作永远匹配不上下面两个 case。（上一版带着那个 guard，它是死的。）
        //
        // T17f：`.reported`（一条「我替你做主」的告知）走**一字不差的同一条规则**。它不能被漏掉：
        // 漏掉 = 那条告知永远不会被清（陈旧地挂在一张早就装好的面板上），或者更糟——若有人顺手在
        // 别处清了它，它会在用户看见之前消失。`switch` 穷尽、无 `default:`，加新态会编译红。
        switch actionState {
        case .idle, .running:
            return
        case .failed, .reported:
            break
        }

        if outcomeHasBeenSeen {
            actionState = .idle
            isShowingDetail = false
            outcomeHasBeenSeen = false
        } else {
            outcomeHasBeenSeen = true
        }
    }

    /// 面板不在屏幕上了（`MenuBarController.popoverDidClose` → ``PanelFocusCoordinator/hideCount``）。
    ///
    /// 只更新「面板可见吗」这一个事实。**刻意不碰 `actionState`**：一条在面板关闭之后才诞生的失败
    /// 必须活到用户下一次打开为止 —— 那正是上面那段文档里的整个 bug。
    public func panelDidHide() {
        guard !isPreviewPinned else { return }
        isPanelVisible = false
    }

    /// 每一颗 CTA 最终都走这里。`switch` 穷尽、无 `default:` —— 加一个 intent 会编译红。
    private func perform(_ intent: OnboardingActionIntent?) async {
        // 画廊里 pin 死的实例：点一下什么都不该发生。
        guard !isPreviewPinned else { return }
        // 重入守卫：双击「接管」会让两个 `performFirstRunSetup` 抢同一把 `play.lock`，其中一个
        // 必然拿到 `.lockBusy` —— 用户会看到一条**他自己制造出来的**假失败。视图侧的
        // `.disabled(isPerformingAction)` 挡不住它：`@Published` 到按钮的传播不是同步的，
        // 第二次点击可能已经在队列里了。
        guard !isPerformingAction else { return }
        guard let intent else {
            // 这个状态没有这颗 CTA（视图本来也不会渲染它）。仍然重新探测一次，绝不崩。
            refresh()
            return
        }

        switch intent {
        case .revealDetail:
            toggleDetail()

        case .reDetect:
            // 一个字节都不写：用户的 Claude Code 没装 / 配置文件没权限 / 格式坏了 —— 都不是
            // Claudio 该替他动手的东西。只重新看一眼磁盘。
            actionState = .idle
            outcomeHasBeenSeen = false
            refresh()

        case .takeOver:
            await runDiskAction(.takeOver)

        case .disconnect:
            await runDiskAction(.disconnect)
        }
    }

    private func runDiskAction(_ action: OnboardingDiskAction) async {
        actionState = .running(action)
        isShowingDetail = false
        outcomeHasBeenSeen = false

        let result = await actionRunner.run(action)

        switch result {
        case .success(let outcome):
            // **T17f 的整个修复就是这一行。**
            //
            // 上一版是 `case .success: actionState = .idle` —— `outcome` 连**绑都没绑**。于是
            // `SetupOutcome` 里那两条 setup 明确承诺过「必须让他知道」的事（读不出的包被搬走了 /
            // 他选的包没了、已替他换掉）在这里**掉在地上**：面板一声不吭地切到运行态、亮起绿点，
            // 而用户的包已经被换过、他的目录已经被搬走。CLI 侧那行 ⚠ 只对开终端的人响。
            //
            // 政策不在这里：``onboardingActionState(afterSuccess:)`` 是纯函数（真值表钉死），
            // 它也是 `.reported` 的唯一构造入口，负责保证「没什么可说就回 `.idle`」。
            actionState = onboardingActionState(afterSuccess: outcome)
        case .failure(let error):
            actionState = .failed(
                action: action, message: error.message, detail: error.technicalDetail)
        }

        // **T17d 的整个修复就是这一行**（T17f 把它从「失败」抬到「结果」，见下）。
        //
        // 「这条结果会不会被人看见」不是下一次开面板时该去假定的事，它在此刻就是一个事实：
        // - 面板此刻开着 → 两个渲染点都无条件画「有没有失败 / 有没有告知」（T17c 的结构不变式），
        //   所以它这一帧就在屏幕上 → 算看过，用户下次开面板时可以忘掉它。
        // - 面板此刻关着 → 用户点完「接管」就切走了，`.transient` popover 早已关闭，而这个 `Task`
        //   不随视图销毁而取消，于是结果诞生在一块没人看的屏幕上 → **不算看过**，它必须活到
        //   用户下一次打开、真正露一次面为止。
        //
        // T17f：这一行原本长在 `case .failure` 里。抬出来是**必须的**，不是整理代码 —— 一条
        // 「我替你换了包」的告知同样可能诞生在一块关着的面板上（而且**更容易**：它走的是成功路径，
        // 用户点完「接管」切走去干别的，正是最自然的动作）。留在 `.failure` 里，告知就会带着
        // `outcomeHasBeenSeen == false` 出生却没有人认领这条规则。
        //
        // `switch` 穷尽、无 `default:`：将来再加一个动作态，这里会**编译红**，而不是默默漏掉它的寿命。
        switch actionState {
        case .failed, .reported:
            outcomeHasBeenSeen = isPanelVisible
        case .idle, .running:
            // 成功且无话可说（`.idle`）——没有任何东西需要被「看见」。
            outcomeHasBeenSeen = false
        }
        // 无论成败都重新探测：成功 → `.installed`；失败 → 可能变成 `.settingsNotWritable`，也可能
        // 原地不动。面板必须反映磁盘**此刻**的真相，而不是我们以为自己写成功了什么。
        refresh()
    }
}
