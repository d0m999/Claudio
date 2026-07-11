import ClaudioGUICore
import Foundation

// MARK: - contrastRatio's hex PARSER, as opposed to its contrast MATH (T15 review 修复⑤).
//
// `ContrastSuite.swift` owns the design-invariant assertions (every DESIGN.md token pair clears
// its WCAG floor) plus the "obviously malformed token fails closed" cases. This suite owns the
// one input class that looked fine and was not: a token that PARSES but is not a color.
//
// `contrastRatio`'s doc comment promises it "returns 1.0 (the 'no contrast at all' floor) for any
// hex string that doesn't parse to exactly 6 hex digits, rather than ... silently treating a
// malformed token as passing — fail-closed for a would-be executable design invariant". That
// promise did NOT hold: Swift's `FixedWidthInteger(_:radix:)` accepts a leading SIGN, so the
// 6-character `"+FFFFF"` parsed cleanly as `0x0FFFFF` and yielded a real, plausible, WRONG
// luminance. A design invariant that can be satisfied by a token which is not a color is not an
// invariant — hence an explicit `isHexDigit` sweep before the parse, pinned here.
//
// Why this matters beyond the toy input: these assertions are the enforcement mechanism for
// DESIGN.md's contrast floors. A malformed token that silently produces a plausible ratio can
// make a REAL contrast violation pass the suite — exactly the failure mode fail-closed exists to
// prevent.

@MainActor
func runContrastHexParsingSuites() {
    suite("contrastRatio: a SIGN-prefixed 6-char token (\"+FFFFF\") fails closed to 1.0 — it parses as an integer, but it is not a color") {
        // The mutant-killer: without the `isHexDigit` sweep, `UInt32("+FFFFF", radix: 16)` succeeds
        // (0x0FFFFF), so this returns the contrast of #0FFFFF against black — a perfectly plausible
        // ~17:1 — instead of the promised fail-closed floor.
        let ratio = contrastRatio("+FFFFF", "000000")
        expect(
            ratio == 1.0,
            "a leading `+` must never be accepted as a hex color: `FixedWidthInteger(_:radix:)`"
                + " parses it, the fail-closed contract forbids trusting it, got \(ratio)")
    }

    suite("contrastRatio: a MINUS-prefixed token (\"-FFFFF\") fails closed to 1.0") {
        // `UInt32` already rejects a negative literal, so this one was accidentally safe — pinned
        // anyway so the sign class is covered as a whole, not just the half that happened to break.
        let ratio = contrastRatio("-FFFFF", "000000")
        expect(ratio == 1.0, "a leading `-` must fail closed, got \(ratio)")
    }

    suite("contrastRatio: a sign-prefixed token is rejected in the SECOND operand too") {
        let ratio = contrastRatio("000000", "+FFFFF")
        expect(
            ratio == 1.0,
            "both operands run through the same guarded parser — neither position may accept a"
                + " sign-prefixed token, got \(ratio)")
    }

    suite("contrastRatio: a sign-prefixed token stays fail-closed even when `#`-prefixed (\"#+FFFF\" — the `#` strip must not open a second door)") {
        // `#` is stripped first, so the remaining 5 characters are too short — but pin it, since a
        // future edit to the strip/length logic could re-expose the sign path.
        expect(contrastRatio("#+FFFF", "000000") == 1.0, "must fail closed")
        // 6 characters AFTER the `#` strip, with a sign: the shape that would slip through if the
        // digit sweep were dropped.
        expect(contrastRatio("#+FFFFF", "000000") == 1.0, "must fail closed")
    }

    suite("contrastRatio: an all-hex 6-char token still parses normally (the digit sweep must not reject VALID colors)") {
        // The other direction of the same guard: `isHexDigit` accepts 0-9/a-f/A-F, so every real
        // token — upper, lower, mixed — must still measure its true ratio. Without this, a mutant
        // that fails ALL tokens closed (returning 1.0 for everything) would pass the suites above.
        expect(
            abs(contrastRatio("000000", "ffffff") - 21.0) < 0.01,
            "lowercase black-vs-white must still measure 21:1, got \(contrastRatio("000000", "ffffff"))")
        expect(
            abs(contrastRatio("000000", "FfFfFf") - 21.0) < 0.01,
            "mixed case must still measure 21:1, got \(contrastRatio("000000", "FfFfFf"))")
    }
}
