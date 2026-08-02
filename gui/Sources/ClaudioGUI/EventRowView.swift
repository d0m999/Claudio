import ClaudioCore
import ClaudioGUIComponents
import ClaudioGUICore
import SwiftUI

/// 主面板的一条事件状态行。映射写入已全部迁到 `SoundPacksWindow`；这里仅负责扫读、
/// 路由到编辑器、手工试听和真实事件静音。
public struct EventRowView: View {
    public let row: EventRow
    public let hostCoverage: EventHostCoveragePresentation?
    public let previewAvailability: EventPreviewAvailability
    public let adaptation: PanelLayoutAdaptation
    public let onOpenEditor: () -> Void
    public let onPreview: () -> Void
    public let onToggleMute: () -> Void

    private let focusedTarget: FocusState<PanelFocusTarget?>.Binding
    @Environment(\.colorScheme) private var colorScheme

    public init(
        row: EventRow,
        hostCoverage: EventHostCoveragePresentation? = nil,
        previewAvailability: EventPreviewAvailability? = nil,
        focusedTarget: FocusState<PanelFocusTarget?>.Binding,
        adaptation: PanelLayoutAdaptation = panelLayoutAdaptation(for: .standard),
        onOpenEditor: @escaping () -> Void = {},
        onPreview: @escaping () -> Void = {},
        onToggleMute: @escaping () -> Void = {}
    ) {
        self.row = row
        self.hostCoverage = hostCoverage
        self.previewAvailability = previewAvailability
            ?? eventPreviewAvailability(coverage: row.coverage, masterVolume: 1)
        self.focusedTarget = focusedTarget
        self.adaptation = adaptation
        self.onOpenEditor = onOpenEditor
        self.onPreview = onPreview
        self.onToggleMute = onToggleMute
    }

    public var body: some View {
        Group {
            if adaptation.rowWrapsToTwoLines {
                VStack(alignment: .leading, spacing: 6) {
                    identityButton
                    HStack(spacing: 6) {
                        coverageCapsule
                        Spacer(minLength: 6)
                        previewButton
                        muteButton
                    }
                }
            } else {
                HStack(spacing: 8) {
                    identityButton
                    Spacer(minLength: 6)
                    coverageCapsule
                    previewButton
                    muteButton
                }
            }
        }
        .frame(minHeight: adaptation.rowWrapsToTwoLines ? 52 : 32)
        .accessibilityElement(children: .contain)
    }

    private var identityButton: some View {
        Button(action: onOpenEditor) {
            HStack(spacing: 8) {
                ClaudioEventGlyph(event: row.event)
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.event.displayName)
                        .font(ClaudioTheme.font(.body).weight(.medium))
                        .foregroundColor(ClaudioTheme.text(colorScheme))
                    Text(hostCoverage?.visibleText ?? row.event.cliName)
                        .font(ClaudioTheme.font(.caption))
                        .foregroundColor(ClaudioTheme.secondaryText(colorScheme))
                        .lineLimit(adaptation.rowWrapsToTwoLines ? 2 : 1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focused(focusedTarget, equals: .eventSound(row.event))
        .accessibilityLabel(identityAccessibilityLabel)
        .accessibilityValue(coverageText)
        .accessibilityHint("打开声音包窗口并定位到这个事件")
        .accessibilityIdentifier("panel.event.\(row.event.rawValue).editor")
    }

    private var coverageCapsule: some View {
        ClaudioStatusCapsule(coverageText)
            .help(coverageHelp)
            .accessibilityLabel("映射状态，\(coverageHelp)")
    }

    private var previewButton: some View {
        Button(action: onPreview) {
            Image(systemName: "play.fill")
        }
        .buttonStyle(ClaudioIconButtonStyle())
        .foregroundColor(
            previewAvailability.isAvailable
                ? ClaudioTheme.event(row.event, colorScheme)
                : ClaudioTheme.secondaryText(colorScheme))
        .disabled(!previewAvailability.isAvailable)
        .focused(focusedTarget, equals: .eventAction(row.event))
        .help(previewAvailability.accessibilityHint)
        .accessibilityLabel("试听 \(row.event.displayName)")
        .accessibilityValue(
            previewAvailability.isAvailable
                ? "可以试听；事件\(row.enabled ? "已启用" : "已静音")"
                : previewAvailability.unavailableReason ?? "不可试听")
        .accessibilityHint(previewAvailability.accessibilityHint)
        .accessibilityIdentifier("panel.event.\(row.event.rawValue).preview")
    }

    private var muteButton: some View {
        Button(action: onToggleMute) {
            Image(systemName: row.enabled ? "speaker.wave.2" : "speaker.slash.fill")
        }
        .buttonStyle(ClaudioIconButtonStyle())
        .foregroundColor(
            row.enabled
                ? ClaudioTheme.secondaryText(colorScheme)
                : ClaudioTheme.clay(colorScheme))
        .focused(focusedTarget, equals: .eventMute(row.event))
        .help(row.enabled ? "静音真实事件自动播放" : "恢复真实事件自动播放")
        .accessibilityLabel(
            row.enabled ? "静音 \(row.event.displayName) 自动播放" : "取消静音 \(row.event.displayName) 自动播放")
        .accessibilityValue(row.enabled ? "已启用" : "已静音")
        .accessibilityHint("只影响宿主真实事件；不影响手工试听")
        .accessibilityAddTraits(row.enabled ? [] : .isSelected)
        .accessibilityIdentifier("panel.event.\(row.event.rawValue).mute")
    }

    private var identityAccessibilityLabel: String {
        var parts = [
            eventRowIdentityAccessibilityLabel(
                eventDisplayName: row.event.displayName,
                coverage: row.coverage,
                enabled: row.enabled)
        ]
        if let hostCoverage { parts.append(hostCoverage.accessibilityLabel) }
        return parts.joined(separator: "，")
    }

    private var coverageText: String {
        switch row.coverage {
        case .present: "已映射"
        case .unmapped: "未配置"
        case .broken: "需修复"
        }
    }

    private var coverageHelp: String {
        switch row.coverage {
        case .present(let fileName): "已映射 \(fileName)"
        case .unmapped: "尚未绑定声音文件"
        case .broken(let fileName): "\(fileName) 缺失或损坏"
        }
    }
}
