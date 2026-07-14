import ClaudioGUICore
import SwiftUI

/// The onboarding panel (ENGINEERING.md T7): renders whichever ``OnboardingState`` the
/// bound ``OnboardingViewModel`` is currently in, per DESIGN.md's "onboarding 卡 / 空态
/// 卡" component spec (44px icon block, title, body, primary pill CTA + ghost secondary
/// CTA). All state determination and copy selection live in `ClaudioGUICore`
/// (`OnboardingViewModel`/`onboardingCopy(for:)`) — this view only lays pixels out.
///
/// T17: the CTAs now DO something. Every decision about what they do
/// (``onboardingPrimaryIntent(for:)`` / ``onboardingSecondaryIntent(for:)``), whether one is
/// currently running, and what a failure says lives in `ClaudioGUICore` and is unit-tested
/// there — this file holds no branch that decides anything. It used to: `if copy.detail != nil
/// { isShowingDetail.toggle() } else { viewModel.performSecondaryAction() }` was a live dispatch
/// decision stranded inside SwiftUI, the exact shape T16 修复⑥ already sank out of a view once.
public struct OnboardingView: View {
    @ObservedObject private var viewModel: OnboardingViewModel
    @Environment(\.colorScheme) private var colorScheme
    /// T17c：in-flight spinner 是这棵视图树里唯一的动画，必须 gate 住「减弱动态效果」——
    /// 见 ``PanelView`` 的 reduced-motion 段（那条绊线正是被 T17 踩响的）。
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Dynamic-Type scale factor for this view's fixed `.system(size:)` text (a11y fix) — see
    /// ``EventRowView``'s `typeScale` for the full rationale.
    @ScaledMetric(relativeTo: .body) private var typeScale: CGFloat = 1

    /// The SHARED focus-state binding this view's primary/secondary CTA buttons report
    /// into (a11y-architect FIX 4, T15): `PanelView` owns the actual `@FocusState` and
    /// passes its projected binding down here, keyed off ``PanelFocusTarget/onboardingPrimaryAction``/
    /// ``PanelFocusTarget/onboardingSecondaryAction`` — the SAME identities
    /// ``panelFocusOrder(_:)`` (`ClaudioGUICore`) already names for this state. Required
    /// (no default) since `PanelView` is this view's only real call site.
    private let focusedTarget: FocusState<PanelFocusTarget?>.Binding

    public init(viewModel: OnboardingViewModel, focusedTarget: FocusState<PanelFocusTarget?>.Binding) {
        self.viewModel = viewModel
        self.focusedTarget = focusedTarget
    }

    public var body: some View {
        // NO `.padding(13)` / `.background(panel)` here (`/ship` 评审): ``PanelView`` is the
        // composition root and ALREADY supplies the panel surface, the 13pt inset, the
        // hairline-strong border and the 15pt corner clip around this view. Re-applying both
        // here stacked a SECOND 13pt inset (26pt net — twice DESIGN.md「间距」's 12–13pt panel
        // padding, on the very first screen a new user sees) and painted a square-cornered fill
        // INSIDE that rounded clip. The gallery (`StateGalleryView`) now paints the same panel
        // surface behind each frame, so the onboarding card still renders on its real surface
        // there too — never on SwiftUI's untokenized default window background.
        VStack(alignment: .leading, spacing: 12) {
            header
            card
        }
    }

    /// 唯一实现住在 ``PanelHeader``（`PanelRows.swift`）—— 此前这里与 `PanelView.header` 是两份逐字
    /// 重复的副本。**这一份还带着一句从来没有人听到过的话**：绿点上原本挂着
    /// `.accessibilityLabel("已接管 Claude Code")`，而绿点的条件是 `state == .installed`，这张卡却**只在
    /// `state != .installed` 时才上屏** —— 那句 label 在 shipping app 里从未被播报过一次。合并之后，
    /// 绿点的 a11y 处理只有一种（`.accessibilityHidden(true)`，因为它说的话已经折进整条 header 的
    /// combine label 里了）。完整推导见 ``PanelHeader`` 的文档。
    ///
    /// `showsTakenOverDot` 照旧读 ``OnboardingState/showsHeaderTakenOverDot``（在这张卡上恒为 `false`），
    /// **不写字面量 `false`**：那个恒假是**正确的**恒假（onboarding 卡按定义就是「还没接管」），把它
    /// 硬编成字面量等于把「为什么它恒假」这件事从代码里删掉。
    private var header: some View {
        PanelHeader(
            showsTakenOverDot: viewModel.state.showsHeaderTakenOverDot,
            accessibilityLabel: PanelHeader.baseLabel)
    }

    private var card: some View {
        let copy = viewModel.copy
        let accent = stateAccentColor(viewModel.state.accent, colorScheme)
        let primaryIntent = onboardingPrimaryIntent(for: viewModel.state)
        let secondaryIntent = onboardingSecondaryIntent(for: viewModel.state)

        return VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(accent.opacity(0.15))
                    .frame(width: 44, height: 44)
                Image(systemName: iconName(for: viewModel.state))
                    .foregroundColor(accent)
            }
            .accessibilityHidden(true)

            Text(copy.title)
                .font(.system(size: 15 * typeScale, weight: .semibold))
                .foregroundColor(ClaudioColor.text(colorScheme))

            Text(copy.body)
                .font(.system(size: 12.5 * typeScale))
                .foregroundColor(ClaudioColor.textSecondary(colorScheme))
                .fixedSize(horizontal: false, vertical: true)

            // 这个 STATE 自身的 detail（settings 不可写 / 解析失败的底层 reason），藏在「查看原因」后。
            if viewModel.isShowingDetail, let detail = copy.detail {
                detailText(detail)
            }

            // T17：一次 CTA **动作**失败必须说出来。
            //
            // T17c：**不再按 action 分派**。这张卡与 `PanelView` 的运行态面板互斥地占据屏幕，两边
            // 都无条件渲染「此刻有没有失败」，于是「一个 `.failed` 必须有人画」是结构事实而不是一条
            // 需要人去维护的规则。上一版这里只画 `branch: .takeOver`，而一次**接管**失败完全可能
            // 在 `refresh()` 之后落在 `.installed`（quarantine 修复后点「修复」→ 在选默认包
            // （`config.lock`）或写 hooks（`settings.lock`）那一步撞上锁 → 失败，但二进制和 hooks
            // 都在位）—— 那条失败于是一个像素都没有。见
            // ``onboardingVisibleFailure(actionState:)`` 的完整推导。
            if let failure = onboardingVisibleFailure(actionState: viewModel.actionState) {
                ActionFailureRow(
                    message: failure.message, detail: failure.detail,
                    isShowingDetail: viewModel.isShowingDetail,
                    showsDetailToggle: onboardingShowsFailureDetailToggle(
                        state: viewModel.state, actionState: viewModel.actionState),
                    onToggleDetail: { viewModel.toggleDetail() },
                    focusedTarget: focusedTarget)
            }

            // T17f：一次 CTA 动作**成功了、但替用户做了主**，同样必须说出来。
            //
            // 与上面那条失败行**同一条结构不变式**（无条件渲染，不按 action / state 分派），理由见
            // ``onboardingVisibleNotices(actionState:)``。这张卡实际上很难看到告知——告知只从
            // `.takeOver` 成功而来，而成功必然把 state 推成 `.installed`，那一刻屏幕上是运行态面板、
            // 不是这张卡。**但它仍然必须画在这里**：正是「我推理出这个格子不可达，所以不画它」这句话，
            // 在 T17c 里造出了两个无人认领的格子。两边都无条件画，「不可达」就不需要任何人去证明。
            ForEach(Array(onboardingVisibleNotices(actionState: viewModel.actionState).enumerated()), id: \.offset) { _, notice in
                ActionNoticeRow(message: notice.message)
            }

            if let primaryTitle = copy.primaryActionTitle {
                ctaButton(
                    title: primaryTitle, intent: primaryIntent,
                    focusTarget: .onboardingPrimaryAction,
                    action: { await viewModel.performPrimaryAction() }
                )
                .buttonStyle(.borderedProminent)
                .tint(ClaudioColor.clay(colorScheme))
            }

            // 次 CTA 直接来自 copy —— **不再合成**任何按钮。
            //
            // T17 第一版在这里合成过一颗「查看原因」（当 `copy.secondaryActionTitle == nil` 且动作
            // 失败带 detail 时）。它的 action 走 `performSecondaryAction()`，而
            // `onboardingSecondaryIntent(.notInstalled)` 是 **nil** → `perform(nil)` → 只 refresh。
            // **点了什么都不会发生** —— 一颗真正的死按钮，正是这次提交要杀死的那一类 bug，在杀死它的
            // 那次提交里以另一种形状回来了。现在「查看原因」是失败行**自己**的一部分（见
            // ``ActionFailureRow``），有自己的焦点身份与自己的入口（``OnboardingViewModel/toggleDetail()``）。
            if let secondaryTitle = copy.secondaryActionTitle {
                ctaButton(
                    title: secondaryTitle, intent: secondaryIntent,
                    focusTarget: .onboardingSecondaryAction,
                    action: { await viewModel.performSecondaryAction() }
                )
                .buttonStyle(.bordered)
            }
        }
    }

    /// 一颗 CTA。`Button` 的 action 是同步的，而 view-model 的动作是 `async`（harness 要能 await
    /// 到它跑完），所以这里包一层 `Task` —— 它继承 `@MainActor`，view-model 的重入守卫照常成立。
    private func ctaButton(
        title: String, intent: OnboardingActionIntent?, focusTarget: PanelFocusTarget,
        action: @escaping () async -> Void
    ) -> some View {
        let isRunning = viewModel.isRunning(intent)
        let label = isRunning ? (runningTitle(for: intent) ?? title) : title

        return Button {
            Task { await action() }
        } label: {
            HStack(spacing: 6) {
                // `reduceMotion` 时不画（T17c）：进行态由 label（「正在接管…」）与禁用态承担，
                // 不靠这圈转动。见 ``PanelView`` 的 reduced-motion 段。
                if isRunning, !reduceMotion {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityHidden(true)
                }
                Text(label)
            }
            .frame(maxWidth: .infinity)
        }
        // 禁用**两颗**按钮，不只是正在跑的那一颗：动作跑到一半时点另一颗会跟它抢同一把锁 ——
        // `performFirstRunSetup` 里是 `config.lock`（`selectPack` × 2）与 `settings.lock`
        // （`installClaudioHooks` × 1），三次里任意一次都能 `.lockBusy`，而那是一条**用户自己
        // 制造出来的**假失败。view-model 侧还有一道重入守卫（`@Published` 到按钮的传播不是同步的，
        // 第二次点击可能已经在队列里），两道都要有。
        //
        // ⚠️ 阶段 A 锁分离之前，这里写的是「抢同一把 `play.lock`」。那句话是**假的** —— 而它是
        // ``OnboardingViewModel/performPrimaryAction()`` 里那条警告点名要保的**孪生守卫**：那边
        // 已经改对了，这边（同一条论据的另一半）漏了整整一刀。守卫本身一个字都不用动，死的只是
        // 它的理由。别顺着一句死论据把一道活守卫删了。
        .disabled(viewModel.isPerformingAction)
        // label 随 in-flight 变（「接管 Claude Code」→「正在接管…」），VoiceOver 因此也读得到
        // 进行态 —— 而不是对着一颗突然变灰的按钮无话可说。
        .accessibilityLabel(label)
        .focused(focusedTarget, equals: focusTarget)
    }

    private func runningTitle(for intent: OnboardingActionIntent?) -> String? {
        guard let action = intent?.diskAction else { return nil }
        return onboardingActionRunningTitle(action)
    }

    private func detailText(_ detail: String) -> some View {
        Text(detail)
            .font(.system(size: 11 * typeScale, design: .monospaced))
            .monospacedDigit()
            // `text-2`，**不是**真红（`/ship` 评审实证）：真红当正文，亮色下只有 4.07:1，
            // 达不到 WCAG ≥4.5:1 的文本门槛。真红只留给**图标**（非文本，门槛 ≥3:1）——
            // 这张卡的错误身份已经由上方 44pt 图标块的态色字形承担了（DESIGN.md「onboarding
            // 卡」: "态色 15% 底 + 态色字形"），正文不必再上一遍真红。DESIGN.md 品牌色未改。
            .foregroundColor(ClaudioColor.textSecondary(colorScheme))
            .fixedSize(horizontal: false, vertical: true)
    }

    private func iconName(for state: OnboardingState) -> String {
        switch state {
        case .claudeCodeNotInstalled: "questionmark.circle"
        case .helperMissing: "exclamationmark.triangle.fill"
        case .settingsNotWritable: "lock.slash.fill"
        case .settingsParseFailure: "exclamationmark.triangle.fill"
        case .notInstalled: "waveform.circle.fill"
        case .installed: "checkmark.circle.fill"
        }
    }
}
