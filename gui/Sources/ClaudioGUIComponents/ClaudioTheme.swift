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
        public static let row: CGFloat = 13
        public static let section = row
        public static let tile: CGFloat = 11
        public static let control: CGFloat = 6
        public static let chip = control
        public static let pill: CGFloat = 999
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

    public static func clayHover(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(claudioHex: ClaudioColorHex.clayHoverDark)
            : Color(claudioHex: ClaudioColorHex.clayHoverLight)
    }

    public static func claySoft(_ scheme: ColorScheme) -> Color {
        clay(scheme).opacity(scheme == .dark ? 0.15 : 0.12)
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
        RoundedRectangle(cornerRadius: min(ClaudioTheme.Radius.tile, size / 2))
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

public enum ClaudioIconButtonInteractionState: Equatable, Sendable {
    case rest
    case hovered
    case focused
    case pressed
    case disabled

    public init(
        isEnabled: Bool,
        isHovered: Bool,
        isFocused: Bool,
        isPressed: Bool
    ) {
        if !isEnabled {
            self = .disabled
        } else if isPressed {
            self = .pressed
        } else if isFocused {
            self = .focused
        } else if isHovered {
            self = .hovered
        } else {
            self = .rest
        }
    }

    public func scale(reduceMotion: Bool) -> CGFloat {
        self == .pressed && !reduceMotion ? 0.96 : 1
    }

    public func transitionDuration(reduceMotion: Bool) -> Double? {
        guard !reduceMotion, self != .disabled else { return nil }
        switch self {
        case .hovered, .focused:
            return 0.12
        case .pressed, .rest:
            return 0.10
        case .disabled:
            return nil
        }
    }
}

public struct ClaudioIconButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        ClaudioIconButtonStyleBody(configuration: configuration)
    }
}

private struct ClaudioIconButtonStyleBody: View {
    let configuration: ButtonStyleConfiguration

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @State private var isHovered = false

    private var interactionState: ClaudioIconButtonInteractionState {
        ClaudioIconButtonInteractionState(
            isEnabled: isEnabled,
            isHovered: isHovered,
            isFocused: isFocused,
            isPressed: configuration.isPressed)
    }

    private var foregroundColor: Color {
        switch interactionState {
        case .hovered, .focused:
            colorScheme == .dark
                ? ClaudioTheme.clayHover(colorScheme)
                : ClaudioTheme.clay(colorScheme)
        case .pressed:
            ClaudioTheme.clay(colorScheme)
        case .disabled:
            ClaudioTheme.secondaryText(colorScheme).opacity(0.45)
        case .rest:
            ClaudioTheme.secondaryText(colorScheme)
        }
    }

    private var backgroundColor: Color {
        switch interactionState {
        case .hovered, .focused:
            ClaudioTheme.claySoft(colorScheme)
        case .pressed:
            ClaudioTheme.elevated(colorScheme)
        case .rest, .disabled:
            .clear
        }
    }

    private var transition: Animation? {
        guard let duration = interactionState.transitionDuration(reduceMotion: reduceMotion) else {
            return nil
        }
        return interactionState == .rest
            ? .easeIn(duration: duration)
            : .easeOut(duration: duration)
    }

    var body: some View {
        configuration.label
            .scaleEffect(interactionState.scale(reduceMotion: reduceMotion))
            .frame(
                minWidth: ClaudioTheme.Metrics.iconTarget,
                minHeight: ClaudioTheme.Metrics.iconTarget)
            .foregroundColor(foregroundColor)
            .background(
                RoundedRectangle(cornerRadius: ClaudioTheme.Radius.control)
                    .fill(backgroundColor))
            .contentShape(Rectangle())
            .animation(transition, value: interactionState)
            .onHover { isHovered = $0 }
    }
}

/// A plain compact button contract whose label owns the complete minimum hit target.
public struct ClaudioCompactButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(
                minWidth: ClaudioTheme.Metrics.iconTarget,
                minHeight: ClaudioTheme.Metrics.compactControlHeight
            )
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
                RoundedRectangle(cornerRadius: ClaudioTheme.Radius.row)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.08 : 0))
            )
            .contentShape(Rectangle())
    }
}
