import ClaudioCore
import Foundation

// MARK: - master_volume -> `afplay -v` mapping (T9)
//
// `ClaudioConfig.masterVolume` is a user-facing 0.0–1.0 dial (see `ClaudioConfig.swift`).
// `afplay -v <value>` expects the exact same [0.0, 1.0] range (1.0 = normal volume, values
// below attenuate) — so the mapping itself is the identity function; the only real work is
// **clamping** out-of-range config values and falling back to
// `ClaudioConfig.defaultMasterVolume` for non-finite input (NaN/±inf), since this is a
// `public` pure function any caller — including the GUI's volume slider (T15/T16) — can
// call directly, not just JSON-decoded config where `Double.nan` can't actually appear.
//
// These are pure-function unit tests only. The end-to-end proof that `Play.swift` actually
// threads `config.masterVolume` through this mapping into the real `afplay` spawn
// `arguments` lives in `PlaySuite.swift` (it already owns the `RecordingSpawner` +
// `PlayEnvironment` fixtures this integration needs — no second, unaudited spawn-assertion
// helper here).

@MainActor
func runVolumeSuites() {
    suite("AfplayVolume.clamped: in-range values pass through unchanged") {
        expect(
            AfplayVolume.clamped(0.5) == 0.5,
            "0.5 is already in [0.0, 1.0] and must pass through unchanged")
        expect(
            AfplayVolume.clamped(0.35) == 0.35,
            "0.35 is already in [0.0, 1.0] and must pass through unchanged")
    }

    suite("AfplayVolume.clamped: exact boundary values (0.0 / 1.0) pass through unchanged") {
        expect(AfplayVolume.clamped(0.0) == 0.0, "0.0 is the minimum valid value, must stay 0.0")
        expect(AfplayVolume.clamped(1.0) == 1.0, "1.0 is the maximum valid value, must stay 1.0")
    }

    suite("AfplayVolume.clamped: negative values clamp to 0.0") {
        expect(AfplayVolume.clamped(-0.3) == 0.0, "a negative master_volume must clamp to 0.0")
        expect(
            AfplayVolume.clamped(-1000.0) == 0.0,
            "a wildly negative master_volume must still clamp to 0.0, not underflow")
    }

    suite("AfplayVolume.clamped: values above 1.0 clamp to 1.0") {
        expect(AfplayVolume.clamped(1.5) == 1.0, "a master_volume above 1.0 must clamp to 1.0")
        expect(
            AfplayVolume.clamped(1000.0) == 1.0,
            "a wildly large master_volume must still clamp to 1.0, not pass through")
    }

    suite(
        "AfplayVolume.clamped: non-finite input (NaN / +inf / -inf) falls back to"
            + " ClaudioConfig.defaultMasterVolume, the single documented source of truth"
    ) {
        expect(
            AfplayVolume.clamped(Double.nan) == ClaudioConfig.defaultMasterVolume,
            "NaN must fall back to ClaudioConfig.defaultMasterVolume, not clamp to 0.0/1.0")
        expect(
            AfplayVolume.clamped(Double.infinity) == ClaudioConfig.defaultMasterVolume,
            "+inf must fall back to ClaudioConfig.defaultMasterVolume")
        expect(
            AfplayVolume.clamped(-Double.infinity) == ClaudioConfig.defaultMasterVolume,
            "-inf must fall back to ClaudioConfig.defaultMasterVolume")
    }

    suite("AfplayVolume.afplayArgument: renders the clamped value as a locale-independent string") {
        expect(
            AfplayVolume.afplayArgument(forMasterVolume: 0.5) == "0.5",
            "0.5 must render as \"0.5\" — got"
                + " \(AfplayVolume.afplayArgument(forMasterVolume: 0.5))")
        expect(
            AfplayVolume.afplayArgument(forMasterVolume: 0.0) == "0.0",
            "0.0 must render as \"0.0\" — got"
                + " \(AfplayVolume.afplayArgument(forMasterVolume: 0.0))")
        expect(
            AfplayVolume.afplayArgument(forMasterVolume: 1.0) == "1.0",
            "1.0 must render as \"1.0\" — got"
                + " \(AfplayVolume.afplayArgument(forMasterVolume: 1.0))")
        expect(
            AfplayVolume.afplayArgument(forMasterVolume: ClaudioConfig.defaultMasterVolume)
                == "0.8",
            "the documented default (0.8) must render as \"0.8\" — got"
                + " \(AfplayVolume.afplayArgument(forMasterVolume: ClaudioConfig.defaultMasterVolume))"
        )
        expect(
            !AfplayVolume.afplayArgument(forMasterVolume: 0.5).contains(","),
            "the rendered string must use '.' as the decimal separator regardless of host"
                + " locale (afplay's argv parser is not locale-aware) — must never contain ','")
    }

    suite("AfplayVolume.afplayArgument: a literal -0.0 master_volume renders as \"0.0\", never \"-0.0\"") {
        // A hand-edited `"master_volume": -0.0` in config.json is legal JSON. Without the
        // `+ 0.0` normalization in `clamped`, IEEE-754's signed zero would survive
        // `max(0.0, -0.0)` and render as the argv token `-0.0` (T9 review, LOW). afplay tolerates
        // it, but the argument should still be a clean `0.0`.
        expect(
            AfplayVolume.afplayArgument(forMasterVolume: -0.0) == "0.0",
            "a -0.0 master_volume must render as \"0.0\", not \"-0.0\" — got"
                + " \(AfplayVolume.afplayArgument(forMasterVolume: -0.0))")
    }

    suite("AfplayVolume.afplayArgument: out-of-range and non-finite input renders the clamped/default string") {
        expect(
            AfplayVolume.afplayArgument(forMasterVolume: 1.7) == "1.0",
            "an out-of-range 1.7 must render as the clamped \"1.0\"")
        expect(
            AfplayVolume.afplayArgument(forMasterVolume: -0.2) == "0.0",
            "an out-of-range -0.2 must render as the clamped \"0.0\"")
        expect(
            AfplayVolume.afplayArgument(forMasterVolume: Double.nan)
                == AfplayVolume.afplayArgument(forMasterVolume: ClaudioConfig.defaultMasterVolume),
            "NaN must render identically to the documented default's rendering")
    }
}
