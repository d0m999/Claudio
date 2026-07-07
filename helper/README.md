# claudio (helper)

The `claudio` CLI invoked by Claude Code hooks — see [`../ENGINEERING.md`](../ENGINEERING.md).

This directory is the **v1 base skeleton**: it builds, lints, and tests green so the
work in T1–T16 has a green foundation to grow on. Real subcommand bodies (install /
uninstall / play / doctor internals) land in later tasks.

## Layout

```
helper/
  Package.swift                     # SwiftPM manifest (macOS 12+, Swift 6)
  Sources/
    ClaudioCore/Event.swift         # shared domain: the 4-event name mapping (single source of truth)
    claudio/Claudio.swift           # @main CLI entry (swift-argument-parser)
    claudio/Subcommands.swift       # doctor / play / install / uninstall / use (skeleton)
  Tests/
    ClaudioCoreTests/main.swift     # dependency-free test harness (see note below)
```

## Build / lint / test (green baseline)

```bash
swift build   --package-path helper     # compiles claudio + ClaudioCore (fetches swift-argument-parser)
swift format lint --recursive helper    # lint (the "ruff" equivalent, bundled with Swift 6)
swift run     --package-path helper claudio-tests   # tests → exit 0 == green
```

Try the CLI:

```bash
swift run --package-path helper claudio doctor
swift run --package-path helper claudio --help
```

## Why tests are an executable, not `swift test`

This machine has **CommandLineTools only (no Xcode)**. In that setup `swift test` cannot
resolve **XCTest** (not installed) or **Swift Testing** (bundled but not exposed to
SwiftPM, and its `#expect` macro plugin is unavailable). So the base tests run as a
plain executable target (`claudio-tests`) whose exit code is the pass/fail signal.

When a full **Xcode** is installed, switch to conventional `swift test`:

1. In `Package.swift`, replace the `claudio-tests` `.executableTarget` with a
   `.testTarget(name: "ClaudioCoreTests", dependencies: ["ClaudioCore"])`.
2. Rewrite `Tests/ClaudioCoreTests/main.swift` as `@Test` functions using
   `import Testing` / `#expect(...)` — the assertions map 1:1 to the current `expect` calls.

## Dependencies

- [`swift-argument-parser`](https://github.com/apple/swift-argument-parser) `1.3.0+` — CLI parsing.
