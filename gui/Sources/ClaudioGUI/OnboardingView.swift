import ClaudioGUICore
import SwiftUI

/// The onboarding panel (ENGINEERING.md T7): renders whichever ``OnboardingState`` the
/// bound ``OnboardingViewModel`` is currently in, per DESIGN.md's "onboarding 卡 / 空态
/// 卡" component spec (44px icon block, title, body, primary pill CTA + ghost secondary
/// CTA). All state determination and copy selection live in `ClaudioGUICore`
/// (`OnboardingViewModel`/`onboardingCopy(for:)`) — this view only lays pixels out.
public struct OnboardingView: View {
    @ObservedObject private var viewModel: OnboardingViewModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var isShowingDetail = false
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

            if isShowingDetail, let detail = copy.detail {
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

            if let primaryTitle = copy.primaryActionTitle {
                Button {
                    viewModel.performPrimaryAction()
                } label: {
                    Text(primaryTitle)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(ClaudioColor.clay(colorScheme))
                .accessibilityLabel(primaryTitle)
                .focused(focusedTarget, equals: .onboardingPrimaryAction)
            }

            if let secondaryTitle = copy.secondaryActionTitle {
                Button {
                    if copy.detail != nil {
                        isShowingDetail.toggle()
                    } else {
                        viewModel.performSecondaryAction()
                    }
                } label: {
                    Text(secondaryTitle)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel(secondaryTitle)
                .focused(focusedTarget, equals: .onboardingSecondaryAction)
            }
        }
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
