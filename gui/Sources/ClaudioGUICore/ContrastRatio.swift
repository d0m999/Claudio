import Foundation

/// WCAG 2.x relative-luminance contrast ratio between two opaque `"RRGGBB"` (optionally
/// `#`-prefixed) hex colors — pure math, no `Color`/`NSColor`, so it runs in this
/// Foundation-only module's dependency-free test harness (ENGINEERING.md T15 D5「对比度」:
/// "做成 token / 数学断言，不靠截图测抗锯齿后的 SF Symbols"). Returns `1.0` (the "no
/// contrast at all" floor) for any hex string that doesn't parse to exactly 6 hex digits,
/// rather than crashing or silently treating a malformed token as passing — fail-closed for
/// a would-be executable design invariant.
///
/// Implements the standard formula: linearize each sRGB channel (gamma-correct the 0–255
/// value into 0–1 linear light), combine into relative luminance `L = 0.2126R + 0.7152G +
/// 0.0722B`, then `(L_lighter + 0.05) / (L_darker + 0.05)`.
public func contrastRatio(_ hexA: String, _ hexB: String) -> Double {
    guard let luminanceA = relativeLuminance(of: hexA),
        let luminanceB = relativeLuminance(of: hexB)
    else {
        return 1.0
    }
    let lighter = max(luminanceA, luminanceB)
    let darker = min(luminanceA, luminanceB)
    return (lighter + 0.05) / (darker + 0.05)
}

private func relativeLuminance(of hex: String) -> Double? {
    var hexString = hex
    if hexString.hasPrefix("#") { hexString.removeFirst() }
    // The `isHexDigit` sweep is NOT redundant with the `UInt32(_:radix:)` parse (T15 review
    // 修复⑤): Swift's `FixedWidthInteger(_:radix:)` accepts a leading SIGN, so `"+FFFFF"` is
    // exactly 6 characters, parses cleanly as `0x0FFFFF`, and would hand back a perfectly
    // plausible — and completely WRONG — luminance for a token that is not a color at all.
    // That silently defeats this function's whole fail-closed contract (see the type doc:
    // a malformed token must never be treated as passing). Every character must be a real hex
    // digit before the parse is trusted.
    guard hexString.count == 6, hexString.allSatisfy(\.isHexDigit),
        let value = UInt32(hexString, radix: 16)
    else { return nil }
    let red = Double((value & 0xFF0000) >> 16) / 255
    let green = Double((value & 0x00FF00) >> 8) / 255
    let blue = Double(value & 0x0000FF) / 255
    return 0.2126 * linearize(red) + 0.7152 * linearize(green) + 0.0722 * linearize(blue)
}

/// sRGB → linear-light gamma correction for a single channel already normalized to `0...1`.
private func linearize(_ channel: Double) -> Double {
    channel <= 0.03928 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
}
