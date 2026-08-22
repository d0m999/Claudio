# CLI and Runtime Architecture

<!-- Generated: 2026-08-22 | Files scanned: 286 | Token estimate: ~720 -->

There is no HTTP backend or API route table. The “backend” is the local CLI plus `ClaudioCore`.

## Commands / routes

```text
claudi0 hook <host> <native-event> --installation-id <uuid>
  → HostHookRunner.handle → HostCapabilityCatalog → HostHookReceiptStore → Play/afplay

claudi0 integrations status [--json]
  → HostIntegrationManager.refresh → adapters.inspect → HostIntegrationSnapshot
claudi0 integrations connect <claude-code|codex>
  → shared bootstrap → adapter.connect → transactional host config
claudi0 integrations disconnect <claude-code|codex>
  → adapter.disconnect → remove only Claudio-owned entries

claudi0 doctor       → runDoctorChecks (read-only health report)
claudi0 play <event> → playSoundEvent (legacy, global debounce)
claudi0 install      → legacy Claude Code hook pipeline
claudi0 uninstall    → exact legacy hook removal
claudi0 use <pack>   → config mutation selecting a sound pack
claudi0 setup        → shared runtime bootstrap + legacy Claude Code setup
```

## Service → storage mapping

- `HostIntegrationManager` actor → `ClaudeCodeIntegrationAdapter` / `CodexIntegrationAdapter` →
  `ConfigFileTransaction`, `ClaudeCodeHooksTransform`, `CodexHooksTransform`.
- `SystemSharedRuntimeBootstrapper` / `Setup` → `ClaudioPaths`, bundled helper, `packs/`,
  `config.json`, bootstrap journal and reports.
- `HostHookRunner` → `HostHookReceiptStore`, active-installation marker, host-specific debounce
  state and `Play`.
- `Play` → `ClaudioConfig` read, `PackManifest` lookup, `FileLock`, `afplay` process spawn.
- `Doctor` → bounded filesystem probes and integration inspection; it does not write or play audio.

## Safety / middleware chain

`SafeFileRead` and JSON depth/size limits precede parsing. `ConfigFileTransaction` applies
symlink policy, backup/CAS checks, locks, and atomic replacement. `FileLock` is non-blocking at
the public hook path; hook outcomes are intentionally silent and return success so a sound failure
cannot block the host workflow.

## Key files

- `helper/Sources/claudio/Subcommands.swift`: CLI surface and command dispatch.
- `helper/Sources/ClaudioCore/HostIntegrationManager.swift`: shared actor and bootstrap seam.
- `helper/Sources/ClaudioCore/ConcreteHostIntegrationAdapters.swift`: host ownership boundaries.
- `helper/Sources/ClaudioCore/HostHookRunner.swift`, `Play.swift`: callback and playback path.
- `helper/Sources/ClaudioCore/ConfigFileTransaction.swift`, `FileLock.swift`: write/concurrency gates.
