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

            // T17：一次 CTA **动作**失败必须说出来。与 `PanelView.errorNotice` /
            // `AudioDropZoneView.rejectRow` 同一个形状 —— 面板里每一种失败都长得像同一种东西。
            if case .failed(let message, let detail) = viewModel.actionState {
                ActionFailureRow(
                    message: message, detail: detail,
                    isShowingDetail: viewModel.isShowingDetail, typeScale: typeScale)
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

            if let secondaryTitle = secondaryCTATitle(copy: copy) {
                ctaButton(
                    title: secondaryTitle, intent: secondaryIntent,
                    focusTarget: .onboardingSecondaryAction,
                    action: { await viewModel.performSecondaryAction() }
                )
                .buttonStyle(.bordered)
            }
        }
    }

    /// 次 CTA 的标题。
    ///
    /// 多出来的那一支：一次**动作**失败可能带 technical detail（`SetupError` 的原话），而
    /// `.notInstalled` / `.helperMissing` 这两个状态的 `copy.secondaryActionTitle` 本来是 `nil`、
    /// 根本没有次按钮 —— 于是那条失败原因**没有任何入口可以展开**。这里给它一个。
    ///
    /// 判据是 ``OnboardingActionState``（一个被穷尽测试钉住的模型值），不是视图自己的猜测。
    private func secondaryCTATitle(copy: OnboardingCopy) -> String? {
        if case .failed(_, let detail) = viewModel.actionState, detail != nil,
            copy.secondaryActionTitle == nil
        {
            return "查看原因"
        }
        return copy.secondaryActionTitle
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
                if isRunning {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityHidden(true)
                }
                Text(label)
            }
            .frame(maxWidth: .infinity)
        }
        // 禁用**两颗**按钮，不只是正在跑的那一颗：动作跑到一半时点另一颗会跟它抢同一把
        // `play.lock`。view-model 侧还有一道重入守卫（`@Published` 到按钮的传播不是同步的，
        // 第二次点击可能已经在队列里），两道都要有。
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
    let typeScale: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 11 * typeScale))
                    .foregroundColor(ClaudioColor.error(colorScheme))
                Text(message)
                    .font(.system(size: 11 * typeScale))
                    .foregroundColor(ClaudioColor.textSecondary(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)

            if isShowingDetail, let detail {
                Text(detail)
                    .font(.system(size: 11 * typeScale, design: .monospaced))
                    .monospacedDigit()
                    .foregroundColor(ClaudioColor.textSecondary(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
