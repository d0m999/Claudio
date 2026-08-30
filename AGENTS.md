# Repository Guidance

## Context and Sources of Truth

Claudio uses one domain context across `helper/` and `gui/`. Before changing domain terms,
architecture, or user-visible behavior, read `CONTEXT.md` and the ADRs for the affected branch.
Use glossary terms in code, tests, issues, and docs. Surface an ADR conflict explicitly instead of
silently introducing a second model.

- Sound-pack scanning, snapshots, refresh, or concurrency: read ADRs 0001–0004.
- Sound scopes, defaults, or Surface overrides: read ADR 0005.
- AI Cue providers, credentials, generation, candidates, or adoption: read ADRs 0006–0007.
- Settings navigation, window ownership, or dynamic quiet state: read ADRs 0008–0009; for a
  settings destination, also read `plan/PLAN-SETTINGS-EXPERIENCE.md`.
- Native UI or visual changes: read the current sections of `DESIGN.md`. Dated historical sections
  remain context, but do not override an explicitly current section.
- Contribution and release evidence: read `CONTRIBUTING.md`. GitHub operations, triage labels, and
  domain-doc routing live in `docs/agents/`.

## Architecture and Ownership

`helper/` contains `ClaudioCore`, the `claudio` CLI, and its executable harness. `gui/` contains
Foundation-only `ClaudioGUICore`, localization, shared components, AppKit/SwiftUI presentation, and
the `ClaudioGUI` executable. Keep behavior in the core modules testable without mounting native UI;
keep views and window controllers focused on presentation, routing, and composition.

Preserve one owner for every fact:

- Use the app-lifetime `SoundPackLibrary` actor for sound-pack disk facts and refresh state. Share
  its stream; do not add a second cache or scan owner. Keep reads off `MainActor` and retain the
  existing lock/CAS write boundaries.
- Route settings through typed `SettingsDestination` values and the retained unified settings
  window. A destination organizes an existing domain capability; it does not own duplicate state,
  spawn a parallel settings window, or create another write path.
- Keep host-native schemas inside their adapters and consume shared snapshots in GUI, CLI, and
  diagnostics. Configuration written, capability supported, and current receipt-backed activation
  are separate facts. A failure in one host must not damage or freeze another.
- Resolve sound behavior from Global Sound Defaults plus sparse Surface overrides. `master_volume`
  remains global. Explicitly malformed or stale write targets fail closed; never disguise them by
  falling back to Global state.

Preserve established module names, event IDs, hook command formats, data paths, unknown JSON
fields, future Surface entries, third-party hooks, backups, receipts, and user sound packs unless an
explicit migration owns the change. Keep AI-provider credentials in Keychain and sensitive values
out of config, defaults, logs, manifests, error text, fixtures, and commits.

## Change Workflow

Inspect `git status` before editing and preserve unrelated or in-progress work. Treat the linked
issue or spec as the scope and acceptance boundary; keep the change focused and avoid opportunistic
schema, path, hook, or migration changes. Implementing or committing does not authorize pushing,
releasing, deploying, or changing issue state.

Use Swift 6 and the checked-in `.swift-format`. New localized UI text requires matching English and
`zh-Hans` catalog entries with identical placeholders plus registration in
`ClaudioL10nKey.allKnown`.

Tests live beside each package under `Tests/*Tests/`. Name a new suite `<Feature>Suite.swift`,
expose a `run<Feature>Suites()` function, and register it in that package's `Tests/.../main.swift`.
Add focused regression coverage for changed behavior. Use source-wiring checks only for cross-file
contracts that cannot be expressed through a compiled seam.

## Verification and Evidence

Run relevant gates from the repository root. The two executable harnesses—not `swift test`—are
the project test entry points:

```bash
swift run --package-path helper claudio-tests
swift run --package-path gui claudio-gui-tests
swift build -c debug --package-path gui --product ClaudioGUI
jq empty gui/Sources/ClaudioLocalization/Resources/Localizable.xcstrings
git diff --check
```

For bundle or release-sensitive work, also run the applicable scripts and Release builds documented
in `CONTRIBUTING.md`. `scripts/dev-bundle.sh` produces a current-architecture, ad-hoc-signed local
app; it is inspection evidence, not a universal signed or notarized release artifact.

State evidence narrowly. Harnesses, source scans, builds, and localization checks do not establish
native layout, keyboard/focus order, VoiceOver behavior, real audio, real-host callbacks, both CPU
architectures, signing/notarization, production readiness, or formal acceptance. Report each manual
or external gate as verified or not verified.

## Git and Review

Use concise imperative commits such as `feat(gui): ...`, `fix: ...`, `test(gui): ...`, or
`docs: ...`. Stage only intended paths and keep generated `dist/`, `.build/`, `local-packs/`,
machine-specific files, private prompts/responses, host configuration, receipts, logs, signing
material, and personal/licensed audio out of Git. Pull requests follow `CONTRIBUTING.md`: describe
the user-visible contract, exact verification results, manual evidence, and everything unverified.
