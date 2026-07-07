// swift-tools-version: 6.0
import PackageDescription

// Claudio helper — the `claudio` CLI invoked by Claude Code hooks.
// v1 base: builds a green foundation (ClaudioCore + CLI surface + tests).
// Real subcommand bodies land in T2–T6 (see ../ENGINEERING.md).
let package = Package(
    name: "claudio",
    platforms: [.macOS(.v12)],  // ENGINEERING.md: macOS 12+
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0")
    ],
    targets: [
        // Pure-Foundation core: shared, testable domain types (no CLI deps).
        .target(name: "ClaudioCore"),
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
