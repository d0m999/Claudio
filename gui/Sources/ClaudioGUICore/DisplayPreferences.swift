import ClaudioLocalization
import Foundation

/// User-facing panel width choices. The stored raw values are stable preference tokens; the
/// effective point width is resolved separately against localized content safety requirements.
public enum ClaudioPanelWidthPreference: String, CaseIterable, Sendable {
    case automatic
    case compact
    case roomy

    public static let defaultsKey = "Claudio.PanelWidthPreference"
    public static let defaultValue: ClaudioPanelWidthPreference = .automatic

    public init(storedValue: String?) {
        self = storedValue.flatMap(Self.init(rawValue:)) ?? Self.defaultValue
    }

    public func localizedDisplayName(_ language: ClaudioAppLanguage) -> String {
        let l10n = ClaudioL10n(language: language)
        return switch self {
        case .automatic: l10n.text(.settingsDisplay.panelWidthAutomatic)
        case .compact: l10n.text(.settingsDisplay.panelWidthCompact)
        case .roomy: l10n.text(.settingsDisplay.panelWidthRoomy)
        }
    }
}

public let roomyPanelWidth: Double = 400

/// Auditable content-width table for every supported language and interface text size. These are
/// lower bounds, not preferred widths: explicit Compact and Roomy choices are both clamped through
/// the same resolver so localized labels and event controls never become horizontally clipped.
public func panelContentSafeMinimumWidth(
    language: ClaudioAppLanguage,
    interfaceTextSize: ClaudioInterfaceTextSize
) -> Double {
    switch (language, interfaceTextSize) {
    case (.zhHans, .compact), (.zhHans, .standard): standardPanelWidth
    case (.zhHans, .large): 336
    case (.zhHans, .maximum): 368
    case (.english, .compact): 320
    case (.english, .standard): 328
    case (.english, .large): 360
    case (.english, .maximum): 392
    }
}

/// Resolves one display preference without reading SwiftUI or UserDefaults. Automatic selects the
/// midpoint between the current content-safe floor and Roomy, so all three user-facing choices
/// remain visibly distinct. Explicit Compact and Roomy values are clamped through the same floor.
public func panelWidthResolution(
    preference: ClaudioPanelWidthPreference,
    language: ClaudioAppLanguage,
    interfaceTextSize: ClaudioInterfaceTextSize
) -> (effectiveWidth: Double, isClamped: Bool) {
    let safeMinimumWidth = panelContentSafeMinimumWidth(
        language: language,
        interfaceTextSize: interfaceTextSize)
    let requestedWidth =
        switch preference {
        case .automatic:
            safeMinimumWidth + ((roomyPanelWidth - safeMinimumWidth) / 2)
        case .compact:
            standardPanelWidth
        case .roomy:
            roomyPanelWidth
        }
    let effectiveWidth = max(requestedWidth, safeMinimumWidth)
    return (effectiveWidth, effectiveWidth > requestedWidth)
}
