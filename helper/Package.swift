// swift-tools-version: 6.0
import Foundation
import PackageDescription

// Build-time single source of truth for the CLI version. Local builds deliberately identify
// themselves as development builds; the release workflow injects the validated tag version via
// CLAUDIO_VERSION before compiling either architecture.
let claudioBuildVersion: String = {
    let candidate = ProcessInfo.processInfo.environment["CLAUDIO_VERSION"] ?? "0.0.0-dev"
    let releasePattern = #"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$"#
    let isReleaseVersion = candidate.range(of: releasePattern, options: .regularExpression) != nil
    precondition(
        candidate == "0.0.0-dev" || isReleaseVersion,
        "CLAUDIO_VERSION must be 0.0.0-dev or an unprefixed MAJOR.MINOR.PATCH value")
    return candidate
}()

// claudi0 helper — the legacy `claudio` binary remains the runtime invoked by existing hooks.
// v1 base: builds a green foundation (ClaudioCore + CLI surface + tests).
// Real subcommand bodies land in T2–T6 (see ../ENGINEERING.md).
let package = Package(
    name: "claudio",
    platforms: [.macOS(.v12)],  // ENGINEERING.md: macOS 12+
    // Explicit `products` (SwiftPM 6 no longer auto-vends every target as a product):
    // only `ClaudioCore` is exposed, so the `gui/` package (T7+, a sibling local-path
    // dependency) can reuse its read-only detection APIs (`probeSettingsWritable`,
    // `detectHookInstallStatus`, `ClaudioPaths`, ...) instead of reimplementing them —
    // "single source of truth" per this repo's existing convention. The `claudio` CLI
    // executable and `claudio-tests` harness are intentionally NOT products: nothing
    // outside this package needs to link against either.
    products: [
        .library(name: "ClaudioCore", targets: ["ClaudioCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0")
    ],
    targets: [
        // Tiny C bridge used to embed a string-valued build setting in the Swift binary. Swift's
        // conditional compilation flags are boolean-only, so routing the validated Package.swift
        // value through a C macro avoids generated or rewritten source files.
        .target(
            name: "ClaudioVersionC",
            cSettings: [
                .define("CLAUDIO_VERSION", to: "\"\(claudioBuildVersion)\"")
            ]
        ),
        // Pure-Foundation core: shared, testable domain types (no CLI deps).
        .target(name: "ClaudioCore", dependencies: ["ClaudioVersionC"]),
        // The `claudio` executable — thin CLI shell over ClaudioCore.
        .executableTarget(
            name: "claudio",
            dependencies: [
                "ClaudioCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        // Tests run as a dependency-free executable harness: this machine has
        // CommandLineTools only (no Xcode), so neither XCTest nor Swift Testing is
        // available to `swift test`. Green signal: `swift run claudio-tests` (exit 0).
        // Once a full Xcode is installed, swap this for a `.testTarget` and rewrite
        // the harness as `import Testing` @Test functions (see Tests/ header).
        .executableTarget(
            name: "claudio-tests",
            dependencies: ["ClaudioCore"],
            path: "Tests/ClaudioCoreTests"
        ),
    ]
)
