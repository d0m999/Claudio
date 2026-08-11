import ClaudioGUIComponents
import ClaudioGUICore
import ClaudioLocalization
import SwiftUI

/// 主面板声音包区域的唯一渲染器。生产面板与 DEBUG state gallery 共用它，避免四态只存在于
/// Foundation 模型、却没有逐帧视觉真相。
struct PanelPackSectionView: View {
    let state: PanelPackSectionState
    let typeScale: CGFloat
    let adaptation: PanelLayoutAdaptation
    let language: ClaudioAppLanguage
    let onSelect: (PackCard) -> Void
    private let focusedTarget: FocusState<PanelFocusTarget?>.Binding

    @Environment(\.colorScheme) private var colorScheme

    init(
        state: PanelPackSectionState,
        typeScale: CGFloat,
        focusedTarget: FocusState<PanelFocusTarget?>.Binding,
        adaptation: PanelLayoutAdaptation,
        language: ClaudioAppLanguage = .zhHans,
        onSelect: @escaping (PackCard) -> Void
    ) {
        self.state = state
        self.typeScale = typeScale
        self.focusedTarget = focusedTarget
        self.adaptation = adaptation
        self.language = language
        self.onSelect = onSelect
    }

    @ViewBuilder
    var body: some View {
        switch state {
        case .loading:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityHidden(true)
                Text(l10n.text(.panelPacksLoading))
                    .font(.system(size: 11 * typeScale, design: .rounded))
                    .foregroundColor(ClaudioTheme.secondaryText(colorScheme))
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(l10n.text(.panelPacksLoading))
            .accessibilityIdentifier("panel.packs.loading")
        case .pinned(let cards):
            PackGalleryView(
                cards: cards,
                focusedTarget: focusedTarget,
                adaptation: adaptation,
                language: language,
                onSelect: onSelect)
        case .noPinnedPacks(let availablePackCount):
            emptyState(
                title: l10n.text(.panelPacksNoPinnedTitle),
                message: l10n.format(.panelPacksNoPinnedMessage, Int64(availablePackCount)),
                identifier: "panel.packs.no-pinned")
        case .noPacks:
            emptyState(
                title: l10n.text(.panelPacksNoneTitle),
                message: l10n.text(.panelPacksNoneMessage),
                identifier: "panel.packs.none")
        case .readFailed(let reason):
            VStack(alignment: .leading, spacing: 6) {
                Text(l10n.text(.panelPacksReadFailed))
                    .font(.system(size: 12 * typeScale, weight: .semibold, design: .rounded))
                    .foregroundColor(ClaudioTheme.text(colorScheme))
                FailureRow(message: reason)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("panel.packs.read-failed")
        }
    }

    private func emptyState(title: String, message: String, identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 12 * typeScale, weight: .semibold, design: .rounded))
                .foregroundColor(ClaudioTheme.text(colorScheme))
            Text(message)
                .font(.system(size: 11 * typeScale, design: .rounded))
                .foregroundColor(ClaudioTheme.secondaryText(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(language == .english
            ? "\(title), \(message)"
            : "\(title)，\(message)")
        .accessibilityIdentifier(identifier)
    }

    private var l10n: ClaudioL10n { ClaudioL10n(language: language) }
}
