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

    private var header: some View {
        HStack(spacing: 6) {
            Text("Claudio")
                .font(.system(size: 15 * typeScale, weight: .semibold))
                .foregroundColor(ClaudioColor.text(colorScheme))
            if viewModel.state.showsHeaderTakenOverDot {
                Circle()
                    .fill(ClaudioColor.success(colorScheme))
                    .frame(width: 8, height: 8)
                    .accessibilityLabel("已接管 Claude Code")
            }
            Spacer()
        }
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
                    focusedTarget: focusedTarget, typeScale: typeScale)
            }

            // T17f：一次 CTA 动作**成功了、但替用户做了主**，同样必须说出来。
            //
            // 与上面那条失败行**同一条结构不变式**（无条件渲染，不按 action / state 分派），理由见
            // ``onboardingVisibleNotices(actionState:)``。这张卡实际上很难看到告知——告知只从
            // `.takeOver` 成功而来，而成功必然把 state 推成 `.installed`，那一刻屏幕上是运行态面板、
            // 不是这张卡。**但它仍然必须画在这里**：正是「我推理出这个格子不可达，所以不画它」这句话，
            // 在 T17c 里造出了两个无人认领的格子。两边都无条件画，「不可达」就不需要任何人去证明。
            ForEach(Array(onboardingVisibleNotices(actionState: viewModel.actionState).enumerated()), id: \.offset) { _, notice in
                ActionNoticeRow(message: notice.message, typeScale: typeScale)
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

// MARK: - Shared failure row

/// 一次 CTA **动作**失败的渲染 —— DESIGN.md 既有的「拒绝行」形状（真红 `circle-x` 字形 +
/// `text-2` 说明），与 ``PanelView`` 的 `errorNotice(_:)` 和 ``AudioDropZoneView`` 的
/// `rejectRow(_:)` 完全一致：面板里每一种失败都长得像同一种东西。
///
/// 真红只上**图标**（非文本，≥3:1），文案走 `text-2`（≥4.5:1）—— 真红当正文亮色下只有 4.07:1，
/// 不达文本门槛（`/ship` 评审实证）。
///
/// 有**两个**调用方：`OnboardingView`（接管 / 修复 失败）与 `PanelView` 的运行态面板尾部
/// （断开 失败 —— 那一刻 onboarding 卡根本不在屏幕上，因为 `.installed` 渲染的是 operational
/// 面板）。所以它不能是任何一方的私有成员。
struct ActionFailureRow: View {
    let message: String
    let detail: String?
    let isShowingDetail: Bool
    /// 这条失败行自己该不该长出一颗「查看原因」—— 由纯函数
    /// ``onboardingShowsFailureDetailToggle(state:actionState:)`` 决定，**不是视图猜的**。
    /// `false` 的两种情形：没有 detail 可看；或这个 state 的次 CTA 本身就是「查看原因」。
    let showsDetailToggle: Bool
    let onToggleDetail: () -> Void
    let focusedTarget: FocusState<PanelFocusTarget?>.Binding
    let typeScale: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if showsDetailToggle {
                // 整条行就是那颗按钮 —— 一个控件、一个焦点身份。键盘 / VoiceOver 用户能够到它
                // （WCAG 2.1.1：一条本该键盘可完成的操作，不能退化成仅指针可用）。
                Button(action: onToggleDetail) {
                    messageRow
                }
                .buttonStyle(.plain)
                .accessibilityLabel(message)
                .accessibilityHint(isShowingDetail ? "收起原因" : "展开原因")
                .focused(focusedTarget, equals: .revealDetail)
            } else {
                messageRow
            }

            if isShowingDetail, let detail {
                Text(detail)
                    .font(.system(size: 11 * typeScale, design: .monospaced))
                    .monospacedDigit()
                    .foregroundColor(ClaudioColor.textSecondary(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var messageRow: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 11 * typeScale))
                .foregroundColor(ClaudioColor.error(colorScheme))
            Text(message)
                .font(.system(size: 11 * typeScale))
                .foregroundColor(ClaudioColor.textSecondary(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
            if showsDetailToggle {
                Spacer(minLength: 4)
                Image(systemName: isShowingDetail ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9 * typeScale))
                    .foregroundColor(ClaudioColor.textSecondary(colorScheme))
            }
        }
        // ≥24×24 命中区（a11y-architect FIX 6）。
        .frame(minHeight: 24)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// 一条「Claudio 替你做了主」的告知行（T17f）—— ``ActionFailureRow`` 的孪生兄弟。
///
/// 和它一样，有**两个**调用方（`OnboardingView` 的卡 / `PanelView` 的运行态面板尾部），所以同样
/// 不能是任何一方的私有成员。实际上告知**几乎总是**画在运行态面板那一侧：告知只从一次成功的
/// 「接管」而来，而成功必然让 `state` 变成 `.installed`。
///
/// ## 三处与失败行**刻意不同**，每一处都有理由
///
/// ① **字形是 ⚠（`exclamationmark.triangle.fill`），不是 ✗（`xmark.circle.fill`）**，
///    **颜色是暖琥珀 `warning`，不是真红 `error`**：setup **成功了**。磁盘上是一个能响的安装。
///    DESIGN.md「错误态用色（关键约束）」把真红**限定**给三种 app 自身错误——把一次成功染成真红
///    就是在对用户撒谎，而这个产品的立身之本就是不撒谎。
///    同时它也**不能**是中性灰：那正是 CLI 侧那行注释明令禁止的形状（「⚠ 而不是 ·：…绝不能让它
///    混在几条 · 里悄悄过去」）。琥珀是唯一同时满足「不是错误」与「不许被忽略」的答案。
///
/// ② **没有「查看原因」披露**：告知不是错误，没有底层 `Error.description` 可摊开——话本身就是
///    全部内容（包名、新包名、搬到哪儿，全在那一句里）。于是它**不长任何可聚焦控件**，
///    `PanelFocusTarget` / `panelFocusOrder` 一个字都不用改。少一个控件，就少一条
///    「焦点序里有它、屏幕上没有它」的翻车路径（T17c 真的这么翻过）。
///
/// ③ **不参与 `isShowingDetail`**：同 ②。
///
/// 与失败行**相同**的那两条（不是巧合，是同一条纪律）：文案一律 `text-2`（琥珀只做图标——
/// 亮色 `#B87000` 过 ≥3:1 的 WCAG 1.4.11，**不过** ≥4.5:1 的 1.4.3），以及
/// `.accessibilityElement(children: .combine)`，让 VoiceOver 把「⚠ + 整句话」读成一个元素。
struct ActionNoticeRow: View {
    let message: String
    let typeScale: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11 * typeScale))
                .foregroundColor(ClaudioColor.warning(colorScheme))
            Text(message)
                .font(.system(size: 11 * typeScale))
                .foregroundColor(ClaudioColor.textSecondary(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(minHeight: 24)
        .accessibilityElement(children: .combine)
    }
}
