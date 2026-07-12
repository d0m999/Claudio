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

    /// 面板**重新打开**时，清掉一条已经被看过的失败（T17c）。
    ///
    /// 这是「一条陈旧的接管失败永久挂在一张已经装好的面板上」这个真实顾虑的答案 —— 用**时效性**回答，
    /// 而不是用「按 action 分派到某个分支、于是在别的分支里看不见」回答。后者正是上一版的做法，它造出了
    /// 两个没有任何视图认领的失败格子（见 ``onboardingVisibleFailure(actionState:)``）。
    ///
    /// 时机是 `PanelView` 的 `.onChange(of: focusCoordinator.showCount)` —— 仓库里「popover 刚刚
    /// (重新)可见」的**唯一**信号。于是失败从它发生那一刻起一直可见（包括紧随其后的那次 `refresh()`
    /// 把 state 挪到任何地方），直到用户亲手关掉面板再打开为止。
    ///
    /// 刻意**不**在 ``refresh()`` 里做：`refresh()` 在一次失败的动作之后**立刻**会被调用
    /// （`runDiskAction` 的最后一行），在那里清空会把用户刚触发的失败在他看见之前抹掉 —— 那正是
    /// 这个仓库已经交过三次学费的「静默吞错」。
    public func clearConsumedFailure() {
        guard !isPreviewPinned, !isPerformingAction else { return }
        guard case .failed = actionState else { return }
        actionState = .idle
        isShowingDetail = false
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

        let result = await actionRunner.run(action)

        switch result {
        case .success:
            actionState = .idle
        case .failure(let error):
            actionState = .failed(
                action: action, message: error.message, detail: error.technicalDetail)
        }
        // 无论成败都重新探测：成功 → `.installed`；失败 → 可能变成 `.settingsNotWritable`，也可能
        // 原地不动。面板必须反映磁盘**此刻**的真相，而不是我们以为自己写成功了什么。
        refresh()
    }
}
