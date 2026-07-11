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
        VStack(alignment: .leading, spacing: 12) {
            header
            card
        }
        .padding(13)
        .background(ClaudioColor.panel(colorScheme))
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
                    .foregroundColor(ClaudioColor.error(colorScheme))
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
