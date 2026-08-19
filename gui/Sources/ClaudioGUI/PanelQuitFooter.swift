import ClaudioGUIComponents
import ClaudioGUICore
import ClaudioLocalization
import SwiftUI

/// 固定在菜单栏面板滚动区下方的紧凑退出入口。视图只发出退出意图；应用生命周期由
/// `MenuBarController` 注入的闭包负责。
struct PanelQuitFooter: View {
    let language: ClaudioAppLanguage
    let typeScale: CGFloat
    let onQuit: @MainActor () -> Void
    private let focusedTarget: FocusState<PanelFocusTarget?>.Binding

    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    init(
        language: ClaudioAppLanguage,
        typeScale: CGFloat,
        focusedTarget: FocusState<PanelFocusTarget?>.Binding,
        onQuit: @escaping @MainActor () -> Void
    ) {
        self.language = language
        self.typeScale = typeScale
        self.focusedTarget = focusedTarget
        self.onQuit = onQuit
    }

    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            Button(action: onQuit) {
                HStack(spacing: 6) {
                    Image(systemName: "power")
                        .accessibilityHidden(true)
                    Text(l10n.text(.commonClose))
                }
                .font(.system(size: 11 * typeScale, weight: .medium, design: .rounded))
                .foregroundColor(
                    isHighlighted
                        ? ClaudioTheme.text(colorScheme)
                        : ClaudioTheme.secondaryText(colorScheme))
                .padding(.horizontal, 8)
                .frame(minHeight: ClaudioTheme.Metrics.compactControlHeight)
                .fixedSize(horizontal: true, vertical: false)
                .background(
                    RoundedRectangle(cornerRadius: ClaudioTheme.Radius.control)
                        .fill(isHighlighted ? ClaudioTheme.elevated(colorScheme) : .clear))
                .contentShape(RoundedRectangle(cornerRadius: ClaudioTheme.Radius.control))
            }
            .buttonStyle(.borderless)
            .focused(focusedTarget, equals: .quitApplication)
            .onHover { isHovered = $0 }
            .help(l10n.text(.panelQuitApplicationHint))
            .accessibilityLabel(l10n.text(.panelQuitApplication))
            .accessibilityHint(l10n.text(.panelQuitApplicationHint))
            .accessibilityIdentifier("panel.quit")
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 2)
    }

    private var isHighlighted: Bool {
        isHovered || focusedTarget.wrappedValue == .quitApplication
    }

    private var l10n: ClaudioL10n { ClaudioL10n(language: language) }
}
