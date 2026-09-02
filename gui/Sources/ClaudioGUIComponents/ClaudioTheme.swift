import ClaudioCore
import ClaudioGUICore
import Foundation
import SwiftUI

private extension Color {
    init(claudioHex: String) {
        var value: UInt64 = 0
        Scanner(string: claudioHex).scanHexInt64(&value)
        self.init(
            red: Double((value & 0xFF0000) >> 16) / 255,
            green: Double((value & 0x00FF00) >> 8) / 255,
            blue: Double(value & 0x0000FF) / 255)
    }
}

/// 三个产品界面的共享视觉底座。标准窗口只使用实色表面；渐变只由菜单栏面板调用。
public enum ClaudioTheme {
    public enum Radius {
        public static let panel: CGFloat = 18
        public static let section: CGFloat = 13
        public static let control: CGFloat = 11
    }

    public enum Metrics {
        public static let iconTarget: CGFloat = 28
        public static let compactControlHeight: CGFloat = 28
        public static let regularControlHeight: CGFloat = 32
        public static let hairline: CGFloat = 1
    }

    public enum FontRole {
        case productTitle
        case sectionTitle
        case body
        case secondary
        case caption
        case technical
    }

    public static func font(_ role: FontRole) -> Font {
        switch role {
        case .productTitle: .system(.title3, design: .rounded).weight(.semibold)
        case .sectionTitle: .system(.headline, design: .rounded).weight(.semibold)
        case .body: .system(.body, design: .rounded)
        case .secondary: .system(.subheadline, design: .rounded)
        case .caption: .system(.caption, design: .rounded)
        case .technical: .system(.caption, design: .monospaced)
        }
    }

    public static func text(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(claudioHex: ClaudioColorHex.textDark)
            : Color(claudioHex: ClaudioColorHex.textLight)
    }

    public static func secondaryText(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(claudioHex: ClaudioColorHex.text2Dark)
            : Color(claudioHex: ClaudioColorHex.text2Light)
    }

    public static func panel(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(claudioHex: ClaudioColorHex.panelDark)
            : Color(claudioHex: ClaudioColorHex.panelLight)
    }

    public static func elevated(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(claudioHex: ClaudioColorHex.surface2Dark)
            : Color(claudioHex: ClaudioColorHex.surface2Light)
    }

    public static func surface(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(claudioHex: ClaudioColorHex.surfaceDark)
            : Color(claudioHex: ClaudioColorHex.surfaceLight)
    }

    public static func clay(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(claudioHex: ClaudioColorHex.clayDark)
            : Color(claudioHex: ClaudioColorHex.clayLight)
    }

    public static func success(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(claudioHex: ClaudioColorHex.successDark)
            : Color(claudioHex: ClaudioColorHex.successLight)
    }

    public static func error(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(claudioHex: ClaudioColorHex.errorDark)
            : Color(claudioHex: ClaudioColorHex.errorLight)
    }

    public static func hairline(_ scheme: ColorScheme) -> Color {
        let base = scheme == .dark
            ? Color(claudioHex: ClaudioColorHex.hairlineBaseDark)
            : Color(claudioHex: ClaudioColorHex.hairlineBaseLight)
        return base.opacity(scheme == .dark ? 0.16 : 0.14)
    }

    public static func event(_ event: Event, _ scheme: ColorScheme) -> Color {
        let hex: String
        switch (event, scheme) {
        case (.taskStart, .dark): hex = ClaudioColorHex.taskStartDark
        case (.taskStart, _): hex = ClaudioColorHex.taskStartLight
        case (.stop, .dark): hex = ClaudioColorHex.stopDark
        case (.stop, _): hex = ClaudioColorHex.stopLight
        case (.stopFailure, .dark): hex = ClaudioColorHex.stopFailureDark
        case (.stopFailure, _): hex = ClaudioColorHex.stopFailureLight
        case (.notification, .dark): hex = ClaudioColorHex.notificationDark
        case (.notification, _): hex = ClaudioColorHex.notificationLight
        case (.subagentStop, .dark): hex = ClaudioColorHex.subagentStopDark
        case (.subagentStop, _): hex = ClaudioColorHex.subagentStopLight
        }
        return Color(claudioHex: hex)
    }

    /// “糖果盘”只属于 transient 面板；标准窗口保持单一温暖实色。
    public static func panelGradient(_ scheme: ColorScheme) -> LinearGradient {
        let colors: [Color]
        if scheme == .dark {
            colors = [panel(scheme), elevated(scheme)]
        } else {
            colors = [
                Color(claudioHex: ClaudioColorHex.panelLight),
                Color(claudioHex: ClaudioColorHex.panelDeepLight),
            ]
        }
        return LinearGradient(
            colors: colors,
            startPoint: .top,
            endPoint: .bottom)
    }
}

public extension ClaudioInterfaceTextSize {
    var dynamicTypeSize: DynamicTypeSize {
        switch self {
        case .compact: .medium
        case .standard: .large
        case .large: .xxLarge
        case .maximum: .accessibility2
        }
    }
}

public func claudioEventGlyphName(_ event: Event) -> String {
    switch event {
    case .taskStart: "paperplane.fill"
    case .stop: "checkmark.circle.fill"
    case .stopFailure: "pause.circle.fill"
    case .notification: "bell.badge.fill"
    case .subagentStop: "checkmark.circle"
    }
}

public struct ClaudioEventGlyph: View {
    public let event: Event
    public var size: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    public init(event: Event, size: CGFloat = 24) {
        self.event = event
        self.size = size
    }

    public var body: some View {
        RoundedRectangle(cornerRadius: min(6, size / 4))
            .fill(ClaudioTheme.event(event, colorScheme).opacity(0.15))
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: claudioEventGlyphName(event))
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundColor(ClaudioTheme.event(event, colorScheme))
            }
            .accessibilityHidden(true)
    }
}

public struct ClaudioStatusCapsule: View {
    public let text: String
    public var isEmphasized: Bool
    @Environment(\.colorScheme) private var colorScheme

    public init(_ text: String, isEmphasized: Bool = false) {
        self.text = text
        self.isEmphasized = isEmphasized
    }

    public var body: some View {
        Text(text)
            .font(ClaudioTheme.font(.caption).weight(.semibold))
            .foregroundColor(
                isEmphasized ? ClaudioTheme.clay(colorScheme) : ClaudioTheme.secondaryText(colorScheme))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(
                        isEmphasized
                            ? ClaudioTheme.clay(colorScheme).opacity(0.12)
                            : ClaudioTheme.elevated(colorScheme)))
            .overlay(Capsule().stroke(ClaudioTheme.hairline(colorScheme)))
            .accessibilityLabel(text)
    }
}

public struct ClaudioIconButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme

    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(
                minWidth: ClaudioTheme.Metrics.iconTarget,
                minHeight: ClaudioTheme.Metrics.iconTarget)
            .foregroundColor(ClaudioTheme.secondaryText(colorScheme))
            .background(
                RoundedRectangle(cornerRadius: ClaudioTheme.Radius.control)
                    .fill(configuration.isPressed ? ClaudioTheme.elevated(colorScheme) : .clear))
            .contentShape(Rectangle())
    }
}

/// A full-width button contract for rows whose entire visible surface represents one action.
/// The label owns its visual content; this style supplies the minimum target, rectangular hit
/// testing, and pressed feedback without introducing domain state or selection semantics.
public struct ClaudioFullRowButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(
                maxWidth: .infinity,
                minHeight: ClaudioTheme.Metrics.compactControlHeight,
                alignment: .leading
            )
            .overlay(
                RoundedRectangle(cornerRadius: ClaudioTheme.Radius.control)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.08 : 0))
            )
            .contentShape(Rectangle())
    }
}
