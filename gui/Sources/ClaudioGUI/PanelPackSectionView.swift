import ClaudioGUIComponents
import ClaudioGUICore
import SwiftUI

/// 主面板声音包区域的唯一渲染器。生产面板与 DEBUG state gallery 共用它，避免四态只存在于
/// Foundation 模型、却没有逐帧视觉真相。
struct PanelPackSectionView: View {
    let state: PanelPackSectionState
    let typeScale: CGFloat
    let adaptation: PanelLayoutAdaptation
    let onSelect: (PackCard) -> Void
    private let focusedTarget: FocusState<PanelFocusTarget?>.Binding

    @Environment(\.colorScheme) private var colorScheme

    init(
        state: PanelPackSectionState,
        typeScale: CGFloat,
        focusedTarget: FocusState<PanelFocusTarget?>.Binding,
        adaptation: PanelLayoutAdaptation,
        onSelect: @escaping (PackCard) -> Void
    ) {
        self.state = state
        self.typeScale = typeScale
        self.focusedTarget = focusedTarget
        self.adaptation = adaptation
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
                Text("正在读取声音包…")
                    .font(.system(size: 11 * typeScale, design: .rounded))
                    .foregroundColor(ClaudioTheme.secondaryText(colorScheme))
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("正在读取声音包")
            .accessibilityIdentifier("panel.packs.loading")
        case .pinned(let cards):
            PackGalleryView(
                cards: cards,
                focusedTarget: focusedTarget,
                adaptation: adaptation,
                onSelect: onSelect)
        case .noPinnedPacks(let availablePackCount):
            emptyState(
                title: "主面板还没有固定包",
                message: "磁盘上有 \(availablePackCount) 个声音包。请在管理窗口点亮星标，最多显示四个。",
                identifier: "panel.packs.no-pinned")
        case .noPacks:
            emptyState(
                title: "还没有声音包",
                message: "打开管理窗口恢复内置包，或创建并导入自己的声音包。",
                identifier: "panel.packs.none")
        case .readFailed(let reason):
            VStack(alignment: .leading, spacing: 6) {
                Text("无法读取声音包")
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
        .accessibilityLabel("\(title)，\(message)")
        .accessibilityIdentifier(identifier)
    }
}
