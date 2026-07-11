// swift-tools-version: 6.0
import PackageDescription

// Claudio's menu bar app — the SwiftUI front-end that talks to the `claudio` helper
// binary/config, never the other way around (`ClaudioCore` writes `~/.claude/settings.json`
// only through the CLI; the GUI reads state, it never edits it directly).
//
// v1 scope (T7, ENGINEERING.md): onboarding state machine + view + view-model only. The
// menu bar shell itself (NSStatusItem/NSPopover) is T8/T15 — this package's target
// layout leaves room for that without needing to be restructured later:
//   - `ClaudioGUICore`: pure Foundation state/view-model logic (no SwiftUI import), so it
//     can be exercised by the same dependency-free test harness `helper/` uses.
//   - `ClaudioGUI`: the executable — SwiftUI `App`/`View` layer, depends on `ClaudioGUICore`.
let package = Package(
    name: "claudio-gui",
    platforms: [.macOS(.v12)],  // ENGINEERING.md: macOS 12+ floor, matching helper/Package.swift.
    dependencies: [
        .package(path: "../helper")
    ],
    targets: [
        // Pure-Foundation state/view-model layer: shared, testable domain types (no
        // SwiftUI dependency) — mirrors `helper/Sources/ClaudioCore`'s shape exactly.
        .target(
            name: "ClaudioGUICore",
            dependencies: [
                .product(name: "ClaudioCore", package: "helper")
            ]
        ),
        // The SwiftUI app shell. Minimal for T7 (just enough to host `OnboardingView`
        // for manual/visual verification) — the real menu bar skeleton lands in T8/T15.
        //
        // Depends on `ClaudioCore` directly (not just transitively via `ClaudioGUICore`,
        // same reasoning as `claudio-gui-tests` below) since `EventRowView`/`DesignTokens`
        // (T16) render off `Event` — a `ClaudioCore` type — directly, for the same
        // event-color/glyph token mapping every other per-event surface in this codebase
        // keys off ``Event/allCases``.
        .executableTarget(
            name: "ClaudioGUI",
            dependencies: [
                "ClaudioGUICore",
                .product(name: "ClaudioCore", package: "helper"),
            ]
        ),
        // Tests run as a dependency-free executable harness, exactly like
        // `helper/Tests/ClaudioCoreTests`: this machine has CommandLineTools only (no
        // Xcode), so neither XCTest nor Swift Testing is available to `swift test`.
        // Green signal: `swift run --package-path gui claudio-gui-tests` (exit 0).
        //
        // Depends on `ClaudioCore` directly (not just transitively via `ClaudioGUICore`)
        // so fixtures can build realistic `settings.json` hook entries through
        // `claudioHookCommand(for:claudioBinaryPath:)` — the single source of truth for
        // that string format — instead of re-deriving/hardcoding it a second time.
        .executableTarget(
            name: "claudio-gui-tests",
            dependencies: [
                "ClaudioGUICore",
                .product(name: "ClaudioCore", package: "helper"),
            ],
            path: "Tests/ClaudioGUICoreTests"
        ),
    ]
)
