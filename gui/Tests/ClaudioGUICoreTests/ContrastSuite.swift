import ClaudioGUICore
import Foundation

// MARK: - contrastRatio + DESIGN.md token pairs (ENGINEERING.md T15 D5「对比度」): pins
// DESIGN.md line 127's "行内文字 ≥ 4.5:1" as an executable invariant. Every hex value below
// is copied verbatim from DESIGN.md's 配色 table (== `ClaudioGUI/DesignTokens.swift`'s own
// literal values, duplicated here — not imported — because this dependency-free harness
// target does not, and should not, depend on the SwiftUI-only `ClaudioGUI` target; see
// `ContrastRatio.swift`'s doc comment). Do not add a color that isn't in DESIGN.md's table.

private enum DesignToken {
    // `text` / `text-2` (面板文字).
    static let textDark = "F4EBDD"
    static let textLight = "201D19"
    static let text2Dark = "B0AEA5"
    static let text2Light = "6F665B"

    // `panel` (面板底).
    static let panelDark = "1A1815"
    static let panelLight = "FFFDF8"

    // `surface-2` (抬升表面) — the pack-card background T15 D3 derives from an EXISTING
    // token (⚠️ DESIGN.md 未定义 pack 卡背景，见 `PackGalleryView` 行内注释).
    static let surface2Dark = "262320"
    static let surface2Light = "FFFDF7"

    // 四事件语义色（DESIGN.md「四事件语义色」表，逐值照抄 == `ClaudioColor.event(_:_:)`）.
    static let stopDark = "34C759"
    static let stopLight = "2FA24E"
    static let stopFailureDark = "FF9F0A"
    // Darkened from DESIGN.md's original #E08600 (~2.73:1, below the ≥3:1 glyph floor) to
    // #C87A00 (≈3.31:1) per the authorized design decision; DESIGN.md's table updated to match.
    static let stopFailureLight = "C87A00"
    static let notificationDark = "D97757"
    static let notificationLight = "C4633C"
    static let subagentStopDark = "5E5CE6"
    static let subagentStopLight = "5B59D6"
}

@MainActor
func runContrastSuites() {
    suite("contrastRatio: sanity — pure black on pure white is the known 21:1 maximum") {
        let ratio = contrastRatio("000000", "FFFFFF")
        expect(abs(ratio - 21.0) < 0.01, "expected ~21.0, got \(ratio)")
    }

    suite("contrastRatio: identical colors have a ratio of exactly 1.0 (no contrast)") {
        let ratio = contrastRatio("D97757", "D97757")
        expect(abs(ratio - 1.0) < 0.0001, "expected 1.0, got \(ratio)")
    }

    suite("contrastRatio: is symmetric — argument order does not matter") {
        let a = contrastRatio(DesignToken.textDark, DesignToken.panelDark)
        let b = contrastRatio(DesignToken.panelDark, DesignToken.textDark)
        expect(a == b, "contrastRatio must be symmetric, got \(a) vs \(b)")
    }

    suite("contrastRatio: a malformed hex string fails closed to 1.0, never crashes") {
        let ratio = contrastRatio("not-a-hex-color", DesignToken.panelDark)
        expect(ratio == 1.0, "a malformed token must fail closed to the no-contrast floor, got \(ratio)")
    }

    // MARK: - DESIGN.md line 127: 行内文字 ≥ 4.5:1 (WCAG AA, normal text)

    let textPairs: [(name: String, ratio: Double)] = [
        ("text/panel dark", contrastRatio(DesignToken.textDark, DesignToken.panelDark)),
        ("text/panel light", contrastRatio(DesignToken.textLight, DesignToken.panelLight)),
        // text-2/panel — this SAME pair is what T16 FIX B relies on: the muted-state
        // secondary text (row filename/id, "未配置"/"文件丢失" labels) is ALWAYS rendered
        // in `text-2` regardless of enabled/muted/coverage state (EventRowView never dims
        // opacity), so pinning this pair pins the muted-state text floor too — there is no
        // separate "muted" hex to test.
        ("text-2/panel dark (incl. muted-state secondary text)", contrastRatio(DesignToken.text2Dark, DesignToken.panelDark)),
        ("text-2/panel light (incl. muted-state secondary text)", contrastRatio(DesignToken.text2Light, DesignToken.panelLight)),
        // pack-card text (T15 D3) — card background derived as `surface-2` (see
        // `DesignToken.surface2*`'s doc comment).
        ("text/surface-2 dark (pack-card name)", contrastRatio(DesignToken.textDark, DesignToken.surface2Dark)),
        ("text/surface-2 light (pack-card name)", contrastRatio(DesignToken.textLight, DesignToken.surface2Light)),
        ("text-2/surface-2 dark (pack-card N/4 count)", contrastRatio(DesignToken.text2Dark, DesignToken.surface2Dark)),
        ("text-2/surface-2 light (pack-card N/4 count)", contrastRatio(DesignToken.text2Light, DesignToken.surface2Light)),
    ]

    for pair in textPairs {
        suite("contrast: \(pair.name) is ≥ 4.5:1 (DESIGN.md line 127, WCAG AA normal text)") {
            expect(
                pair.ratio >= 4.5,
                "\(pair.name) must be ≥ 4.5:1, got \(pair.ratio) — DESIGN.md's in-panel text"
                    + " contrast floor has been violated")
        }
    }

    // MARK: - ENGINEERING.md「无障碍规格」: 事件色字形对面板表面 ≥ 3:1 (WCAG 1.4.11,
    // non-text contrast) — a11y-architect FIX 3. Every ``Event`` × both `ColorScheme`s ×
    // both surfaces the glyph can render on (`panel` — the row background; `surface-2` —
    // the pack-card background, T15 D3) is enumerated below, so this is the SAME coverage
    // shape as the text-pair table above, just against the ≥3:1 non-text floor instead of
    // ≥4.5:1.
    //
    // Every pair asserts ≥3.0 HARD, including StopFailure's light-mode amber: DESIGN.md's
    // original #E08600 measured ~2.73:1 against the light panel (below this floor), so it was
    // darkened — via an authorized design decision — to #C87A00 (≈3.31:1); the whole table now
    // clears ≥3:1 with no exceptions.
    struct EventContrastPair {
        let name: String
        let hex: String
        let background: String
    }

    let hardEventPairs: [EventContrastPair] = [
        EventContrastPair(name: "Stop dark vs panel", hex: DesignToken.stopDark, background: DesignToken.panelDark),
        EventContrastPair(name: "Stop dark vs surface-2", hex: DesignToken.stopDark, background: DesignToken.surface2Dark),
        EventContrastPair(name: "Stop light vs panel", hex: DesignToken.stopLight, background: DesignToken.panelLight),
        EventContrastPair(name: "Stop light vs surface-2", hex: DesignToken.stopLight, background: DesignToken.surface2Light),
        EventContrastPair(name: "StopFailure dark vs panel", hex: DesignToken.stopFailureDark, background: DesignToken.panelDark),
        EventContrastPair(name: "StopFailure dark vs surface-2", hex: DesignToken.stopFailureDark, background: DesignToken.surface2Dark),
        EventContrastPair(name: "StopFailure light vs panel", hex: DesignToken.stopFailureLight, background: DesignToken.panelLight),
        EventContrastPair(name: "StopFailure light vs surface-2", hex: DesignToken.stopFailureLight, background: DesignToken.surface2Light),
        EventContrastPair(name: "Notification dark vs panel", hex: DesignToken.notificationDark, background: DesignToken.panelDark),
        EventContrastPair(name: "Notification dark vs surface-2", hex: DesignToken.notificationDark, background: DesignToken.surface2Dark),
        EventContrastPair(name: "Notification light vs panel", hex: DesignToken.notificationLight, background: DesignToken.panelLight),
        EventContrastPair(name: "Notification light vs surface-2", hex: DesignToken.notificationLight, background: DesignToken.surface2Light),
        EventContrastPair(name: "SubagentStop dark vs panel", hex: DesignToken.subagentStopDark, background: DesignToken.panelDark),
        EventContrastPair(name: "SubagentStop dark vs surface-2", hex: DesignToken.subagentStopDark, background: DesignToken.surface2Dark),
        EventContrastPair(name: "SubagentStop light vs panel", hex: DesignToken.subagentStopLight, background: DesignToken.panelLight),
        EventContrastPair(name: "SubagentStop light vs surface-2", hex: DesignToken.subagentStopLight, background: DesignToken.surface2Light),
    ]

    for pair in hardEventPairs {
        let ratio = contrastRatio(pair.hex, pair.background)
        suite("contrast: \(pair.name) is ≥ 3:1 (ENGINEERING.md 无障碍规格, WCAG 1.4.11 non-text)") {
            expect(
                ratio >= 3.0,
                "\(pair.name) must be ≥ 3:1, got \(ratio) — ENGINEERING.md's event-glyph"
                    + " non-text contrast floor has been violated")
        }
    }

}
