import AppKit
import ClaudioCore
import ClaudioGUIComponents
import ClaudioGUICore
import Foundation
import SwiftUI

/// SwiftPM's generated `Bundle.module` accessor looks beside `Bundle.main.bundleURL`, which is
/// correct for `swift run` but not for our hand-assembled macOS app: its resource bundle lives in
/// `Contents/Resources`. Resolve that packaged location explicitly and keep `.module` only as the
/// development/Xcode Preview fallback. The assembly scripts enforce the same exactly-one contract.
private let hostIconResourceBundle: Bundle = {
    guard Bundle.main.bundleURL.lastPathComponent == "claudi0.app" else {
        return .module
    }
    guard let resourcesURL = Bundle.main.resourceURL else {
        preconditionFailure("claudi0.app is missing Contents/Resources")
    }

    let candidates: [URL]
    do {
        candidates = try FileManager.default.contentsOfDirectory(
            at: resourcesURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        .filter { $0.lastPathComponent.hasSuffix("_ClaudioGUI.bundle") }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    } catch {
        preconditionFailure("Cannot inspect claudi0.app resources: \(error)")
    }

    guard candidates.count == 1 else {
        preconditionFailure(
            "Expected exactly one *_ClaudioGUI.bundle in Contents/Resources, found \(candidates.count)")
    }
    guard let bundle = Bundle(url: candidates[0]) else {
        preconditionFailure("Cannot load GUI resource bundle at \(candidates[0].path)")
    }
    return bundle
}()

/// 主面板的一条事件状态行。映射写入已全部迁到 `SoundPacksWindow`；这里仅负责扫读、
/// 路由到编辑器、手工试听和真实事件静音。
public struct EventRowView: View {
    public let row: EventRow
    public let hostIndicators: [EventHostIndicatorPresentation]
    public let previewAvailability: EventPreviewAvailability
    public let adaptation: PanelLayoutAdaptation
    public let onOpenEditor: () -> Void
    public let onPreview: () -> Void
    public let onToggleMute: () -> Void

    private let focusedTarget: FocusState<PanelFocusTarget?>.Binding
    @Environment(\.colorScheme) private var colorScheme
    @ScaledMetric(relativeTo: .body) private var eventTitleSize: CGFloat = 12.5

    /// Host marks are factual status indicators, not controls. Keep their geometry fixed while
    /// the event title follows the panel's four interface-text tiers.
    private let hostIndicatorSize: CGFloat = 18

    public init(
        row: EventRow,
        hostIndicators: [EventHostIndicatorPresentation] = [],
        previewAvailability: EventPreviewAvailability? = nil,
        focusedTarget: FocusState<PanelFocusTarget?>.Binding,
        adaptation: PanelLayoutAdaptation = panelLayoutAdaptation(for: .standard),
        onOpenEditor: @escaping () -> Void = {},
        onPreview: @escaping () -> Void = {},
        onToggleMute: @escaping () -> Void = {}
    ) {
        self.row = row
        self.hostIndicators = hostIndicators
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
                // The standard panel leaves 286pt after padding. Keep the gaps compact so the
                // fixed status/Logo/action slots still leave the longest event title intact.
                HStack(spacing: 6) {
                    identityButton
                    coverageCapsule
                    previewButton
                    muteButton
                }
            }
        }
        .frame(minHeight: adaptation.rowWrapsToTwoLines ? 52 : 37)
        .accessibilityElement(children: .contain)
    }

    private var identityButton: some View {
        Button(action: onOpenEditor) {
            HStack(spacing: 6) {
                ClaudioEventGlyph(event: row.event)
                Text(row.event.displayName)
                    .font(.system(size: eventTitleSize, design: .rounded).weight(.medium))
                    .foregroundColor(ClaudioTheme.text(colorScheme))
                    .lineLimit(1)
                    .layoutPriority(1)
                Spacer(minLength: 0)
                hostIndicatorGroup
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
        .focused(focusedTarget, equals: .eventSound(row.event))
        .accessibilityLabel(identityAccessibilityLabel)
        .accessibilityValue(coverageText)
        .accessibilityHint("打开声音包窗口并定位到这个事件")
        .accessibilityIdentifier("panel.event.\(row.event.rawValue).editor")
    }

    private var coverageCapsule: some View {
        ClaudioStatusCapsule(coverageText)
            .fixedSize()
            .help(coverageHelp)
            .accessibilityLabel("映射状态，\(coverageHelp)")
    }

    private var hostIndicatorGroup: some View {
        HStack(spacing: 4) {
            ForEach(hostIndicators) { indicator in
                hostIndicatorImage(for: indicator.host)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: hostIndicatorSize, height: hostIndicatorSize)
                    .foregroundColor(hostIndicatorColor(indicator))
                    .help(indicator.helpText)
                    .accessibilityHidden(true)
            }
        }
        .fixedSize()
        .accessibilityHidden(true)
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
            EventMuteSpeakerIcon(
                isMuted: !row.enabled,
                color: row.enabled
                    ? ClaudioTheme.secondaryText(colorScheme)
                    : ClaudioTheme.clay(colorScheme))
                .accessibilityHidden(true)
        }
        .buttonStyle(ClaudioIconButtonStyle())
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
        parts.append(contentsOf: hostIndicators.map(\.accessibilityLabel))
        return parts.joined(separator: "，")
    }

    private func hostIndicatorColor(_ indicator: EventHostIndicatorPresentation) -> Color {
        guard indicator.state.usesActiveColor else {
            return ClaudioTheme.secondaryText(colorScheme).opacity(0.75)
        }
        let palette = eventHostIndicatorPalette(for: indicator.host)
        return Color(hex: colorScheme == .dark ? palette.darkHex : palette.lightHex)
    }

    private func hostIndicatorImage(for host: HostID) -> Image {
        let assetName = eventHostIndicatorAssetName(for: host)
        guard let image = hostIconResourceBundle.image(forResource: NSImage.Name(assetName)) else {
            preconditionFailure("Missing host indicator resource: \(assetName).pdf")
        }
        image.isTemplate = true
        return Image(nsImage: image)
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

/// Mockup 已修正的 24×24 扬声器几何。静音只降低两道声波的不透明度并叠加斜线；按钮本身的
/// 行为、颜色、焦点和无障碍身份仍由 ``EventRowView`` 拥有。
private struct EventMuteSpeakerIcon: View {
    let isMuted: Bool
    let color: Color

    var body: some View {
        ZStack {
            SpeakerBodyShape()
                .fill(color)
            SpeakerWaveShape(radius: 4, startX: 16, startY: 9.2, endY: 14.8)
                .stroke(
                    color.opacity(isMuted ? 0.24 : 1),
                    style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
            SpeakerWaveShape(radius: 8, startX: 18.8, startY: 6.5, endY: 17.5)
                .stroke(
                    color.opacity(isMuted ? 0.24 : 1),
                    style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
            if isMuted {
                SpeakerSlashShape()
                    .stroke(
                        color,
                        style: StrokeStyle(lineWidth: 2.1, lineCap: .round, lineJoin: .round))
            }
        }
        .frame(width: 24, height: 24)
    }
}

private struct SpeakerBodyShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: speakerPoint(x: 3.5, y: 9, in: rect))
        path.addLine(to: speakerPoint(x: 3.5, y: 15, in: rect))
        path.addLine(to: speakerPoint(x: 7.5, y: 15, in: rect))
        path.addLine(to: speakerPoint(x: 12.5, y: 19, in: rect))
        path.addLine(to: speakerPoint(x: 12.5, y: 5, in: rect))
        path.addLine(to: speakerPoint(x: 7.5, y: 9, in: rect))
        path.closeSubpath()
        return path
    }
}

private struct SpeakerWaveShape: Shape {
    let radius: CGFloat
    let startX: CGFloat
    let startY: CGFloat
    let endY: CGFloat

    func path(in rect: CGRect) -> Path {
        let halfChord = (endY - startY) / 2
        let centerX = startX - sqrt(radius * radius - halfChord * halfChord)
        let angle = asin(halfChord / radius) * 180 / .pi
        let scale = min(rect.width, rect.height) / 24
        var path = Path()
        path.addArc(
            center: speakerPoint(x: centerX, y: (startY + endY) / 2, in: rect),
            radius: radius * scale,
            startAngle: .degrees(-Double(angle)),
            endAngle: .degrees(Double(angle)),
            clockwise: false)
        return path
    }
}

private struct SpeakerSlashShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: speakerPoint(x: 4, y: 4.5, in: rect))
        path.addLine(to: speakerPoint(x: 20, y: 20, in: rect))
        return path
    }
}

private func speakerPoint(x: CGFloat, y: CGFloat, in rect: CGRect) -> CGPoint {
    CGPoint(
        x: rect.minX + x * rect.width / 24,
        y: rect.minY + y * rect.height / 24)
}
