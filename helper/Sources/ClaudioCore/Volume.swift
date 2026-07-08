import Foundation

/// Pure mapping from ``ClaudioConfig/masterVolume`` (a user-facing 0.0–1.0 dial, see
/// `ClaudioConfig.swift`) to the exact `afplay -v <value>` argument (T9,
/// ENGINEERING.md 384/465: "`master_volume`(0.0–1.0)→`afplay -v` 映射含默认值与越界钳制").
///
/// `afplay -v` uses the identical `[0.0, 1.0]` scale (`1.0` = normal volume, lower values
/// attenuate) — see `man afplay` — so there is no unit conversion here, only **clamping**.
/// This lives in its own file/type (not inline in `Play.swift`) so it stays a dependency-free
/// pure function the GUI's volume slider (T15/T16) can call directly, not something coupled
/// to `PlayEnvironment`/spawn plumbing.
public enum AfplayVolume {
    /// Clamps `masterVolume` into `afplay -v`'s valid `[0.0, 1.0]` range.
    ///
    /// - A finite value below `0.0` clamps to `0.0`; above `1.0` clamps to `1.0`.
    /// - A **non-finite** value (`NaN`, `+infinity`, `-infinity`) falls back to
    ///   ``ClaudioConfig/defaultMasterVolume`` — the single documented default (declared in
    ///   `ClaudioConfig.swift`, never duplicated as a second literal here) — rather than
    ///   being force-clamped into a misleading `0.0`/`1.0`. `ClaudioConfig`'s own JSON decoder
    ///   can never actually produce a non-finite `Double` from `master_volume` (a malformed
    ///   value there already falls back to the default during decode), but this is a
    ///   `public` pure function any other caller (e.g. a GUI slider before it's even written
    ///   to `config.json`) can call directly, so it defends against non-finite input anyway.
    public static func clamped(_ masterVolume: Double) -> Double {
        guard masterVolume.isFinite else { return ClaudioConfig.defaultMasterVolume }
        // The trailing `+ 0.0` normalizes a literal `-0.0` input to a clean `+0.0`: IEEE-754
        // keeps the sign bit through `max(0.0, -0.0)` (they compare equal, so `max` returns the
        // second, still-negative zero), which would otherwise render as `"-0.0"` in
        // ``afplayArgument(forMasterVolume:)``. Harmless for every other finite value (adding
        // `+0.0` is exact) — see the T9 review's LOW finding on `"master_volume": -0.0`.
        return min(1.0, max(0.0, masterVolume)) + 0.0
    }

    /// Renders ``clamped(_:)``'s result as the exact string `afplay -v` should receive as its
    /// argument. Uses Swift's `Double` -> `String` conversion, which always uses `.` as the
    /// decimal separator regardless of the host's locale (unlike `NumberFormatter`/
    /// `String(format:)`, which can localize to `,` on some locales) — `afplay`'s argument
    /// parser is not locale-aware, so a `,` here would silently break volume control.
    public static func afplayArgument(forMasterVolume masterVolume: Double) -> String {
        String(clamped(masterVolume))
    }
}
