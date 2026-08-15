import ClaudioVersionC

/// The version embedded in every Claudio executable built from this package.
///
/// Local builds default to `0.0.0-dev`. A release build must set `CLAUDIO_VERSION` to the
/// validated, unprefixed tag version before SwiftPM evaluates `Package.swift`.
public enum ClaudioVersion {
    public static let current = String(cString: claudio_build_version())
}
