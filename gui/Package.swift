// swift-tools-version: 6.0
import PackageDescription

// claudi0's menu bar app — the SwiftUI front-end delegates shared-runtime bootstrap and every
// host-config inspect/connect/disconnect operation to `ClaudioCore`'s integration manager and
// adapters. Views only consume injected presentation state; they never parse host files themselves.
//
// The target split keeps the menu-bar shell and retained unified Settings destinations testable:
//   - `ClaudioGUICore`: pure Foundation state/view-model logic (no SwiftUI import), so it
//     can be exercised by the same dependency-free test harness `helper/` uses.
//   - `ClaudioGUI`: the executable — SwiftUI `App`/`View` layer, depends on `ClaudioGUICore`.
let package = Package(
    name: "claudio-gui",
    defaultLocalization: "zh-Hans",
    platforms: [.macOS(.v12)],  // ENGINEERING.md: macOS 12+ floor, matching helper/Package.swift.
    // The release workflow builds ClaudioGUI and its macOS 12 LoginItem explicitly. Declaring the
    // main product lets `.github/workflows/release.yml` use `--product ClaudioGUI` instead of a bare
    // `swift build -c release`: the bare form also builds `claudio-gui-tests`, and that
    // target references `#if DEBUG`-gated symbols (`PreviewFixtures`), so it does not — and
    // is not meant to — compile in Release. Release must build the app, not the harness.
    products: [
        .executable(name: "ClaudioGUI", targets: ["ClaudioGUI"]),
        .executable(name: "ClaudioLoginItem", targets: ["ClaudioLoginItem"]),
        // Developer-only native benchmark; no bundle/release step copies this product.
        .executable(
            name: "claudio-sound-pack-benchmark",
            targets: ["claudio-sound-pack-benchmark"]),
    ],
    dependencies: [
        .package(path: "../helper")
    ],
    targets: [
        // Explicit catalog lookup is kept in its own resource-bearing target. ClaudioGUICore's
        // typed preference owner projects system or explicit language into this catalog so every
        // retained surface observes one app-lifetime value.
        .target(
            name: "ClaudioLocalization",
            resources: [
                .process("Resources")
            ]
        ),
        // Pure-Foundation state/view-model layer: shared, testable domain types (no
        // SwiftUI dependency) — mirrors `helper/Sources/ClaudioCore`'s shape exactly.
        .target(
            name: "ClaudioGUICore",
            dependencies: [
                "ClaudioLocalization",
                .product(name: "ClaudioCore", package: "helper")
            ],
            linkerSettings: [
                .linkedFramework("Security")
            ]
        ),
        // Small shared SwiftUI component/token surface. Both the executable panel and unified
        // Settings depend on it, so failure presentation cannot drift into two hand-made
        // copies while the Foundation-only `ClaudioGUICore` remains free of SwiftUI.
        .target(
            name: "ClaudioGUIComponents",
            dependencies: [
                "ClaudioLocalization",
                "ClaudioGUICore",
                .product(name: "ClaudioCore", package: "helper"),
            ]
        ),
        // Reusable Sounds editor view and AppKit accessibility bridge. This remains a library
        // target (no `@main`); the only production NSWindow belongs to `SettingsWindowController`.
        .target(
            name: "SoundPacksWindow",
            dependencies: [
                "ClaudioLocalization",
                "ClaudioGUICore",
                "ClaudioGUIComponents",
                .product(name: "ClaudioCore", package: "helper"),
            ]
        ),
        // The SwiftUI app shell owns the status-item panel and one retained unified Settings
        // window. Its embedded Integrations destination consumes `ClaudioGUICore` presentation
        // values and never opens host config itself, so cutover creates no second truth source.
        //
        // Depends on `ClaudioCore` directly (not just transitively via `ClaudioGUICore`,
        // same reasoning as `claudio-gui-tests` below) since `EventRowView`/`DesignTokens`
        // (T16) render off `Event` — a `ClaudioCore` type — directly, for the same
        // event-color/glyph token mapping every other per-event surface in this codebase
        // keys off ``Event/allCases``.
        .executableTarget(
            name: "ClaudioGUI",
            dependencies: [
                "ClaudioLocalization",
                "ClaudioGUICore",
                "ClaudioGUIComponents",
                "SoundPacksWindow",
                .product(name: "ClaudioCore", package: "helper"),
            ],
            resources: [
                // Template PDFs keep the macOS 12 runtime independent of OS-version-specific
                // SVG decoding. Bundle assembly must copy the generated *_ClaudioGUI.bundle.
                .process("Resources/HostIcons"),
            ],
            linkerSettings: [
                .linkedFramework("Carbon")
            ]
        ),
        // macOS 12 compatibility helper. Packaging embeds this executable in a separately signed
        // Contents/Library/LoginItems app; macOS 13+ registers the main app with SMAppService.
        .executableTarget(
            name: "ClaudioLoginItem",
            linkerSettings: [
                .linkedFramework("AppKit")
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
                "ClaudioLocalization",
                "ClaudioGUICore",
                .product(name: "ClaudioCore", package: "helper"),
            ],
            path: "Tests/ClaudioGUICoreTests"
        ),
        // Release-mode native benchmark harness. It is intentionally not shipped;
        // `scripts/benchmark-sound-pack-library.sh` builds this target explicitly and then runs
        // the already-built executable so SwiftPM compilation time never contaminates latency.
        .executableTarget(
            name: "claudio-sound-pack-benchmark",
            dependencies: [
                "ClaudioGUICore",
                .product(name: "ClaudioCore", package: "helper"),
            ],
            path: "Benchmarks/SoundPackLibraryBenchmark"
        ),
    ]
)
