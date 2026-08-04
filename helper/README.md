# claudi0（helper）

The user-facing CLI is `claudi0`; existing Claude Code and Codex hooks keep invoking the
legacy-compatible `~/.claudio/bin/claudio` runtime path — see [`../ENGINEERING.md`](../ENGINEERING.md).

The current command contract is below. Legacy Claude Code commands remain available so
existing installations and scripts continue to work; see [`../ENGINEERING.md`](../ENGINEERING.md)
for exit codes, host capability mappings, receipts, and config ownership.

| Command | What it does |
|---|---|
| `claudi0 doctor` | Read-only report for shared runtime plus Claude Code and Codex. An unavailable/unconnected host is a warning; shared-runtime failure or a broken connected host exits nonzero |
| `claudi0 integrations status [--json]` | Inspect both hosts from the same snapshots used by the GUI and doctor |
| `claudi0 integrations connect <claude-code\|codex>` | Idempotently add only claudi0-owned hooks for one host; Codex remains awaiting activation until `/hooks` confirmation and a current-installation receipt |
| `claudi0 integrations disconnect <claude-code\|codex>` | Remove only that host's claudi0 entries; preserve shared runtime, the other host, sound packs, and third-party hooks |
| `claudi0 hook <host> <native-event> --installation-id <uuid>` | New hook entry point: normalize the native event, play without blocking the host, and write a minimal `0600` receipt. Playback/lock/receipt failures never block the host |
| `claudi0 play <event>` | Legacy hook entry point with its existing global debounce and always-exit behavior |
| `claudi0 install` | Claude Code legacy compatibility entry: a complete modern connection is a successful no-op; partial/conflicting/malformed/relocated/mixed modern state fails closed instead of adding a duplicate `play` chain |
| `claudi0 uninstall` | Claude Code legacy compatibility entry: precisely removes those established `claudio play` hooks |
| `claudi0 use <pack-id>` | Switches the active pack (writes `~/.claudio/config.json`) |
| `claudi0 setup` | Legacy-compatible bootstrap: installs the shared helper/packs, picks a default pack, and connects Claude Code. GUI first launch bootstraps shared runtime only; hosts are connected separately |

The stable sound model has five events. `UserPromptSubmit` maps to `task_start` for both
hosts, so Claude Code is **5/5 ready** and Codex is intentionally **4/5 ready**: Codex still
has no `StopFailure` hook. `PermissionRequest` maps to claudi0's `notification` sound only
for authorization requests; a Codex `Stop` is labelled “round ended,” not “task completed.”
Activation requires a current-installation `UserPromptSubmit` receipt. Other current-generation
receipts remain useful as latest-event diagnostics, but cannot prove that the new task-start
hook is trusted. After a Codex connect or upgrade, run `/hooks`, confirm the hook, then submit
one more prompt.

Modern task-start callbacks use a separate per-host 250ms debounce timestamp; lifecycle
events retain their per-host 1.5s timestamp. Every supported `claudi0 hook` invocation exits
0 with zero stdout/stderr bytes, including played, muted, debounced, missing-mapping and
failure outcomes. The receipt contains only installation/host/event/time/result metadata.

## Layout

```
helper/
  Package.swift                     # SwiftPM manifest (macOS 12+, Swift 6)
  Sources/
    ClaudioCore/                    # shared domain: semantic Event keys, host adapters/manager,
                                     # config transactions, receipts, play, doctor, packs, bootstrap
    claudio/Claudio.swift           # @main CLI entry (swift-argument-parser)
    claudio/Subcommands.swift       # doctor / integrations / hook + legacy commands
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
swift run --package-path helper claudio integrations status --json
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
