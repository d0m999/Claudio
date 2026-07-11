import ClaudioCore
import ClaudioGUICore
import SwiftUI

// MARK: - DESIGN.md token values (hand-maintained subset, grew across T7/T15/T16)
//
// This is **not** yet a canonical, generated design-token module — it remains a
// hand-maintained subset of DESIGN.md's palette, extended in place across T7 (neutral/brand),
// T15 (surface-2) and T16 (per-event colors/glyphs). Consolidating it into a canonical token
// module was originally slated for T14 but was deliberately deferred there (out of scope —
// would churn every shipped view for no state-gallery benefit); it is now tracked as a
// non-blocking leftover in TODOS.md. Until then, every value below is copied verbatim from
// DESIGN.md's color table so views render its exact hex values without inventing new ones
// (project rule: "不经明确授权不得偏离 DESIGN.md"); do not add a color that isn't there.

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

    /// `surface-2` 抬升表面 (T15). Added for `PackGalleryView`'s pack-card background —
    /// ⚠️ DESIGN.md 未定义 pack 卡背景色，这里用既有 token 派生（`surface-2` 是 DESIGN.md
    /// 「配色」表里已有的「抬升」表面语义，最贴近 macOS 壁纸选择器式卡片的既有选项），而非
    /// 新造一个颜色。见 `PackGalleryView`'s doc comment 与 `ContrastSuite.swift` 对
    /// text/text-2 在 `surface-2` 上的对比度断言。
    static func surface2(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: "262320") : Color(hex: "FFFDF7")
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

    /// `clay-soft` — DESIGN.md gives this as `rgba(...)`, not a plain hex (same reason as
    /// ``hairlineStrong(_:)``). Used only by the drop-zone's hover background (T8; DESIGN.md
    /// "拖入 drop-zone": "hover 命中 → 边框 / 文字转黏土 + `clay-soft` 底").
    static func claySoft(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 217 / 255, green: 119 / 255, blue: 87 / 255, opacity: 0.15)
            : Color(red: 196 / 255, green: 99 / 255, blue: 60 / 255, opacity: 0.12)
    }

    /// UI-semantic `success` — used only for the "已接管" header dot in T7's scope.
    static func success(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: "34C759") : Color(hex: "2FA24E")
    }

    /// UI-semantic `error` (真红) — **only** for app self-errors
    /// (DESIGN.md「错误态用色（关键约束）」), never the four-event semantic layer
    /// (`StopFailure` stays amber, out of this file's scope entirely).
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

// MARK: - T16: per-event color + glyph tokens
//
// Same scoping note as the block above — this is still the hand-maintained token subset,
// not a canonical/generated module (that consolidation was deferred out of T14 and is
// tracked as a non-blocking leftover in TODOS.md). Added here only so `EventRowView` can
// render DESIGN.md's exact per-event hex values ("事件色" table) without inventing new ones.
// Every value below is copied verbatim from DESIGN.md; do not add a shade that isn't there.
extension ClaudioColor {
    /// DESIGN.md's per-event accent color (dark / light), keyed by ``Event``.
    /// `Notification`'s value is deliberately the same `clay(_:)` the rest of this file
    /// already defines — DESIGN.md calls this out as "一个招牌绑定": the ONE place the
    /// brand color doubles as a semantic event color, not a coincidence to re-derive.
    static func event(_ event: Event, _ scheme: ColorScheme) -> Color {
        switch event {
        case .stop:
            scheme == .dark ? Color(hex: "34C759") : Color(hex: "2FA24E")
        case .stopFailure:
            // Amber — DESIGN.md: "限流 / 欠费 / 过载 / 认证（非代码 bug）...绝不用红".
            // Light-mode value darkened from DESIGN.md's original #E08600 to #C87A00
            // (≈3.31:1 vs the light panel, up from ~2.73:1) so the glyph clears the project's
            // own ≥3:1 non-text-contrast bar (WCAG 1.4.11) — still amber, never red. Authorized
            // design decision; DESIGN.md's 四事件语义色 table was updated to match this value.
            scheme == .dark ? Color(hex: "FF9F0A") : Color(hex: "C87A00")
        case .notification:
            clay(scheme)
        case .subagentStop:
            scheme == .dark ? Color(hex: "5E5CE6") : Color(hex: "5B59D6")
        }
    }
}

/// SF Symbol per event (DESIGN.md「事件字形」table: `checkmark.circle.fill` /
/// `pause.circle.fill` / `bell.badge.fill` / `checkmark.circle`). `subagentStop` is
/// deliberately **hollow** (`checkmark.circle`, no `.fill`) — DESIGN.md's own note: "空心
/// 勾...更暗", a one-glance "smaller/lesser completion" distinct from `stop`'s solid
/// checkmark, not an inconsistency to "fix".
func eventGlyphName(_ event: Event) -> String {
    switch event {
    case .stop: "checkmark.circle.fill"
    case .stopFailure: "pause.circle.fill"
    case .notification: "bell.badge.fill"
    case .subagentStop: "checkmark.circle"
    }
}
