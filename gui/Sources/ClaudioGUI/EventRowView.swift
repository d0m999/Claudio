import AppKit
import ClaudioCore
import ClaudioGUIComponents
import ClaudioGUICore
import ClaudioLocalization
import Foundation
import SwiftUI

/// SwiftPM's generated `Bundle.module` accessor looks beside `Bundle.main.bundleURL`, which is
/// correct for `swift run` but not for our hand-assembled macOS app: its resource bundle lives in
/// `Contents/Resources`. Resolve that packaged location explicitly and keep `.module` only as the
/// development/Xcode Preview fallback. The assembly scripts enforce the same exactly-one contract.
private let hostIconResourceBundle: Bundle = {
    guard Bundle.main.bundleURL.pathExtension == "app" else {
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
            preconditionFailure("Cannot inspect Claudio app resources: \(error)")
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
    public let language: ClaudioAppLanguage
    public let adaptation: PanelLayoutAdaptation
    public let onOpenEditor: () -> Void
    public let onPreview: () -> Void
    public let onToggleMute: () -> Void

    private let focusedTarget: FocusState<PanelFocusTarget?>.Binding
    @Environment(\.colorScheme) private var colorScheme
    @ScaledMetric(relativeTo: .body) private var eventTitleSize: CGFloat = 12.5

    /// Host chips are factual status indicators, not controls. The PDF Logo remains fixed while
    /// its caption and the event title follow the panel's four interface-text tiers.
    private let hostIndicatorSize: CGFloat = 12
    private let identitySpacing: CGFloat = 6
    private let chipSpacing: CGFloat = 4

    public init(
        row: EventRow,
        hostIndicators: [EventHostIndicatorPresentation] = [],
        previewAvailability: EventPreviewAvailability? = nil,
        language: ClaudioAppLanguage = .zhHans,
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
        self.language = language
        self.focusedTarget = focusedTarget
        self.adaptation = adaptation
        self.onOpenEditor = onOpenEditor
        self.onPreview = onPreview
        self.onToggleMute = onToggleMute
    }

    public var body: some View {
        Group {
            if adaptation.eventActionsMoveBelow {
                VStack(alignment: .leading, spacing: 6) {
                    identityButton
                    actionButtons
                        .padding(.leading, 24 + identitySpacing)
                }
            } else {
                // Center ordinary actions against the complete identity stack. The trailing
                // clearance on that stack keeps both the title and chips clear of the overlay.
                ZStack(alignment: .trailing) {
                    identityButton
                    actionButtons
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    private var l10n: ClaudioL10n { ClaudioL10n(language: language) }

    private var identityButton: some View {
        Button(action: onOpenEditor) {
            HStack(alignment: .center, spacing: identitySpacing) {
                ClaudioEventGlyph(event: row.event)
                VStack(alignment: .leading, spacing: 6) {
                    Text(localizedEventName(row.event, language: language))
                        .font(.system(size: eventTitleSize, design: .rounded).weight(.medium))
                        .foregroundColor(ClaudioTheme.text(colorScheme))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                        .layoutPriority(1)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    statusChips
                    .accessibilityHidden(true)
                }
                .padding(
                    .trailing,
                    adaptation.eventActionsMoveBelow ? 0 : actionOverlayClearance)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
        .focused(focusedTarget, equals: .eventSound(row.event))
        .accessibilityLabel(identityAccessibilityLabel)
        .accessibilityValue(coverageAccessibilityValue)
        .accessibilityHint(l10n.text(.eventEditorHint))
        .accessibilityIdentifier("panel.event.\(row.event.rawValue).editor")
    }

    private var actionOverlayClearance: CGFloat {
        (ClaudioTheme.Metrics.iconTarget * 2) + 6
    }

    @ViewBuilder
    private var statusChips: some View {
        if adaptation.eventActionsMoveBelow {
            // The maximum tier is wider and already moves actions below the row, so the three
            // status chips can stay on one line without competing with the action buttons.
            HStack(spacing: chipSpacing) {
                hostIndicatorGroup
                coverageChip
            }
        } else {
            // Every 312pt tier keeps actions overlaid on the trailing edge. Put the mapping chip
            // on its own line so the two host chips and English "Not configured"/"Needs repair"
            // never compete for the 224pt identity-column width left by those actions.
            VStack(alignment: .leading, spacing: chipSpacing) {
                hostIndicatorGroup
                coverageChip
            }
        }
    }

    private var actionButtons: some View {
        HStack(spacing: 6) {
            previewButton
            muteButton
        }
        .fixedSize()
    }

    private var coverageChip: some View {
        HStack(spacing: 4) {
            if case .broken = row.coverage {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(ClaudioTheme.error(colorScheme))
                    .accessibilityHidden(true)
            }
            Text(coverageText)
        }
        .font(ClaudioTheme.font(.caption).weight(.semibold))
        .foregroundColor(ClaudioTheme.secondaryText(colorScheme))
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(coverageChipFillColor))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(coverageChipBorderColor, style: coverageChipStrokeStyle))
        .fixedSize()
        .help(coverageHelp)
        .accessibilityHidden(true)
    }

    private var hostIndicatorGroup: some View {
        HStack(spacing: chipSpacing) {
            ForEach(hostIndicators) { indicator in
                hostIndicatorChip(indicator)
            }
        }
        .fixedSize()
        .accessibilityHidden(true)
    }

    private func hostIndicatorChip(
        _ indicator: EventHostIndicatorPresentation
    ) -> some View {
        let activeColor = hostIndicatorColor(indicator)
        return HStack(spacing: 4) {
            hostIndicatorImage(for: indicator.host)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: hostIndicatorSize, height: hostIndicatorSize)
                .foregroundColor(activeColor)
            Text(indicator.compactDisplayName)
                .foregroundColor(ClaudioTheme.secondaryText(colorScheme))
        }
        .font(ClaudioTheme.font(.caption).weight(.semibold))
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(
                    indicator.state.usesActiveColor
                        ? activeColor.opacity(0.12)
                        : Color.clear))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(
                    indicator.state.usesActiveColor
                        ? Color.clear
                        : ClaudioTheme.secondaryText(colorScheme),
                    lineWidth: 1))
        .fixedSize()
        .help(hostIndicatorHelp(indicator))
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
        .help(localizedEventPreviewHint(previewAvailability, language: language))
        .accessibilityLabel(
            l10n.format(
                .eventPreviewLabel,
                localizedEventName(row.event, language: language) as NSString))
        .accessibilityValue(
            previewAvailability.isAvailable
                ? l10n.text(row.enabled ? .eventPreviewAvailableEnabled : .eventPreviewAvailableMuted)
                : l10n.text(.eventPreviewUnavailable))
        .accessibilityHint(localizedEventPreviewHint(previewAvailability, language: language))
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
        .help(
            row.enabled
                ? l10n.format(.eventMute, localizedEventName(row.event, language: language) as NSString)
                : l10n.format(.eventUnmute, localizedEventName(row.event, language: language) as NSString))
        .accessibilityLabel(
            row.enabled
                ? l10n.format(.eventMute, localizedEventName(row.event, language: language) as NSString)
                : l10n.format(.eventUnmute, localizedEventName(row.event, language: language) as NSString))
        .accessibilityValue(l10n.text(row.enabled ? .eventEnabled : .eventMuted))
        .accessibilityHint(l10n.text(.eventMuteHint))
        .accessibilityAddTraits(row.enabled ? [] : .isSelected)
        .accessibilityIdentifier("panel.event.\(row.event.rawValue).mute")
    }

    private var identityAccessibilityLabel: String {
        let sound: String
        switch row.coverage {
        case .present(let fileName):
            sound = l10n.format(.eventCoveragePresentFile, fileName as NSString)
        case .unmapped:
            sound = l10n.text(.eventCoverageUnmapped)
        case .broken:
            sound = l10n.text(.eventCoverageBroken)
        }
        let state = l10n.text(row.enabled ? .eventEnabled : .eventMuted)
        var parts = [localizedEventName(row.event, language: language), sound, state]
        parts.append(contentsOf: hostIndicators.map { indicator in
            let host = localizedHostName(indicator.host, language: language)
            let status = localizedEventHostIndicatorStatus(indicator.state, language: language)
            return [host, status, indicator.qualificationText]
                .compactMap { $0 }
                .joined(separator: language == .english ? ", " : "，")
        })
        return parts.joined(separator: language == .english ? ", " : "，")
    }

    private func hostIndicatorColor(_ indicator: EventHostIndicatorPresentation) -> Color {
        guard indicator.state.usesActiveColor else {
            return ClaudioTheme.secondaryText(colorScheme)
        }
        let palette = eventHostIndicatorPalette(for: indicator.host)
        return Color(hex: colorScheme == .dark ? palette.darkHex : palette.lightHex)
    }

    private func hostIndicatorHelp(_ indicator: EventHostIndicatorPresentation) -> String {
        let separator = language == .english ? ", " : "，"
        return [
            localizedHostName(indicator.host, language: language),
            localizedEventHostIndicatorStatus(indicator.state, language: language),
            indicator.qualificationText,
        ]
        .compactMap { $0 }
        .joined(separator: separator)
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
        case .present: l10n.text(.eventCoveragePresent)
        case .unmapped: l10n.text(.eventCoverageUnmapped)
        case .broken: l10n.text(.eventCoverageBroken)
        }
    }

    private var coverageAccessibilityValue: String {
        switch row.coverage {
        case .present:
            return coverageText
        case .unmapped, .broken:
            return [coverageText, coverageHelp]
                .joined(separator: language == .english ? ", " : "，")
        }
    }

    private var coverageHelp: String {
        switch row.coverage {
        case .present(let fileName):
            return l10n.format(.eventCoveragePresentFile, fileName as NSString)
        case .unmapped:
            return l10n.text(.eventPreviewUnmapped)
        case .broken(let fileName):
            return l10n.format(.eventCoverageBrokenFile, fileName as NSString)
        }
    }

    private var coverageChipFillColor: Color {
        switch row.coverage {
        case .present:
            ClaudioTheme.elevated(colorScheme)
        case .unmapped:
            Color.clear
        case .broken:
            ClaudioTheme.error(colorScheme).opacity(0.12)
        }
    }

    private var coverageChipBorderColor: Color {
        switch row.coverage {
        case .present:
            ClaudioTheme.hairline(colorScheme)
        case .unmapped:
            ClaudioTheme.secondaryText(colorScheme)
        case .broken:
            ClaudioTheme.error(colorScheme)
        }
    }

    private var coverageChipStrokeStyle: StrokeStyle {
        switch row.coverage {
        case .present, .broken:
            StrokeStyle(lineWidth: 1)
        case .unmapped:
            StrokeStyle(lineWidth: 1, dash: [3, 2])
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
