# Claudio Architecture

<!-- Generated: 2026-08-22 | Files scanned: 286 | Token estimate: ~650 -->

## Shape

Claudio is a macOS menu-bar utility split into two local SwiftPM packages:

```text
Claude Code settings.json ─┐
                            ├─ HostIntegrationManager ── hook/receipt ── Play ── afplay
Codex hooks.json ───────────┘          │
                                       └─ shared bootstrap/config/pack files

ClaudioGUIApp ─ AppDelegate ─ MenuBarController ─┬─ NSPopover / PanelView
                                                ├─ retained IntegrationsWindow
                                                └─ retained SoundPacksWindow
```

## Package boundaries

- `helper/`: `ClaudioCore` (Foundation-only domain/runtime), `claudio` CLI, and executable test harness.
- `gui/`: localization, `ClaudioGUICore` state, shared SwiftUI components, two window surfaces,
  the `ClaudioGUI` executable, GUI harness, and benchmark.
- `helper` is the GUI package's local dependency; views do not parse host configuration directly.

## Entrypoints

- `helper/Sources/claudio/Claudio.swift`: `claudi0` command root.
- `gui/Sources/ClaudioGUI/ClaudioGUIApp.swift`: `@main` menu-bar app and composition root.
- `helper/Tests/.../main.swift`, `gui/Tests/.../main.swift`: dependency-free executable harnesses.
- `scripts/dev-bundle.sh`, `.github/workflows/ci.yml`, `.github/workflows/release.yml`: local and CI
  build/release assembly.

## Main data flow

1. `ClaudioGUIAppDelegate` injects `SetupEnvironment`, `AudioImportEnvironment`, the shared
   `HostIntegrationManager`, and the app-lifetime `SoundPackLibrary`.
2. `HostIntegrationManager` serializes shared bootstrap and delegates host-specific JSON transforms
   to Claude Code/Codex adapters.
3. A host callback enters `claudi0 hook`, maps native events through `HostCapabilityCatalog`,
   writes a minimal receipt, and invokes the asynchronous `Play` pipeline.
4. GUI state reads the same snapshots/config/pack facts and renders presentation models; UI actions
   return through `HostIntegrationManagerBridge`, config mutations, or pack import/restore flows.

## Cross-cutting rules

`ConfigFileTransaction`, `FileLock`, bounded reads, JSON-safe writes, CAS checks, and atomic
replacement protect user configuration. The app has no HTTP server, database, or service process.
