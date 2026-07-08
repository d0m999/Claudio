import ClaudioGUICore
import SwiftUI

// MARK: - DESIGN.md token values, scoped to what OnboardingView needs (T7)
//
// This is **not** the canonical design-token module — that's T14 (仓库内 state gallery)
// / T15 (面板 a11y)'s job, once the full four-event panel exists and needs the complete
// palette (spacing scale, radii, all four event colors, etc). Until then, this file
// exists only so `OnboardingView` can render DESIGN.md's exact hex values without
// inventing new ones (project rule: "不经明确授权不得偏离 DESIGN.md"). Every value below
// is copied verbatim from DESIGN.md's color table; do not add a color that isn't there.

extension Color {
    /// A `Color` from a `"RRGGBB"` (or `"#RRGGBB"`) hex string, as used throughout
    /// DESIGN.md's token table.
    init(hex: String) {
        var hexString = hex
        if hexString.hasPrefix("#") { hexString.removeFirst() }
        var value: UInt64 = 0
        Scanner(string: hexString).scanHexInt64(&value)
        let red = Double((value & 0xFF0000) >> 16) / 255
        let green = Double((value & 0x00FF00) >> 8) / 255
        let blue = Double(value & 0x0000FF) / 255
        self.init(red: red, green: green, blue: blue)
    }
}

/// DESIGN.md's neutral + brand + UI-semantic tokens, resolved per `ColorScheme` since
/// this module deliberately avoids an `NSColor` dynamic-provider dependency for T7's
/// scope. Dark values are DESIGN.md's primary tone ("暗色为主基调"); light values are the
/// documented light-mode counterparts.
enum ClaudioColor {
    static func text(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: "F4EBDD") : Color(hex: "201D19")
    }

    static func textSecondary(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: "B0AEA5") : Color(hex: "6F665B")
    }

    static func panel(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: "1A1815") : Color(hex: "FFFDF8")
    }

    /// `hairline-strong` — DESIGN.md gives this as `rgba(...)`, not a plain hex, hence
    /// the explicit `red:green:blue:opacity:` form instead of ``Color/init(hex:)``.
    static func hairlineStrong(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 245 / 255, green: 235 / 255, blue: 221 / 255, opacity: 0.16)
            : Color(red: 20 / 255, green: 20 / 255, blue: 19 / 255, opacity: 0.16)
    }

    /// `clay` — the sole brand accent.
    static func clay(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: "D97757") : Color(hex: "C4633C")
    }

    /// UI-semantic `success` — used only for the "已接管" header dot in T7's scope.
    static func success(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: "34C759") : Color(hex: "2FA24E")
    }

    /// UI-semantic `error` (真红) — **only** for app self-errors (DESIGN.md 125), never
    /// the four-event semantic layer (`StopFailure` stays amber, out of this file's
    /// scope entirely).
    static func error(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: "FF453A") : Color(hex: "E0453A")
    }
}

/// Maps an ``OnboardingAccent`` (from `ClaudioGUICore`, a Foundation-only semantic token
/// name) to its actual `Color`, per-`ColorScheme` — the one place `OnboardingAccent`
/// meets an actual pixel value, kept out of `ClaudioGUICore` so that module never needs
/// to import SwiftUI (see `gui/Package.swift`'s target-layout note).
func stateAccentColor(_ accent: OnboardingAccent, _ scheme: ColorScheme) -> Color {
    switch accent {
    case .neutral: ClaudioColor.textSecondary(scheme)
    case .error: ClaudioColor.error(scheme)
    case .brand: ClaudioColor.clay(scheme)
    case .success: ClaudioColor.success(scheme)
    }
}
