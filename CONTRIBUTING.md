# Contributing to Claudio

Thank you for helping improve Claudio. Small, focused changes with evidence are easiest to review.

## Before you start

- Search existing issues and pull requests first.
- Use an issue for user-visible behavior changes, new host integrations, sound-pack format changes, or release/distribution changes.
- Never include private prompts, responses, project paths, host configuration, receipts, logs, signing credentials, or licensed personal sound packs in an issue or commit.
- Keep `local-packs/`, `dist/`, `.build/`, and machine-specific artifacts out of Git.

## Development environment

- macOS 12 or later.
- Xcode Command Line Tools with Swift 6.
- `jq` for validating the string catalog.

Clone the repository and run commands from its root. The helper and GUI are separate Swift packages; always pass the explicit package path and product shown below.

## Build and test

```bash
swift run --package-path helper claudio-tests
swift run --package-path gui claudio-gui-tests

swift build -c debug --package-path gui --product ClaudioGUI
swift build -c release --package-path gui --product ClaudioGUI

jq empty gui/Sources/ClaudioLocalization/Resources/Localizable.xcstrings
bash scripts/dev-bundle.sh
bash scripts/check-release-size.sh dist/claudi0.app
git diff --check
```

`scripts/dev-bundle.sh` produces an ad-hoc signed, current-architecture app for local inspection only. It is not equivalent to the universal, Developer ID signed, notarized release artifact.

## Change rules

- Preserve existing host hooks, unknown JSON keys, user sound packs, configuration, backups, and receipts unless the issue explicitly defines a migration.
- Keep Claude Code and Codex adapters independent. A failure in one host must not damage or freeze the other.
- Treat a written configuration and a real hook receipt as different states.
- Keep UI semantics, keyboard focus order, hit targets, Dynamic Type layouts, and VoiceOver output aligned.
- Add or update the executable harness checks for behavior changes. Static source scans should guard cross-file contracts only when a compile-time link cannot.
- Add English and `zh-Hans` entries with matching placeholders for every localization key, and update `ClaudioL10nKey.allKnown`.
- Do not commit generated `dist/` bundles or personal/imported audio.
- Do not change the hook command format, configuration schema, or user-data paths as part of an unrelated change.

## Pull requests

Describe:

1. The user-visible problem and intended behavior.
2. The files or contracts changed.
3. Commands run and their exact result.
4. Manual checks performed, especially native UI, VoiceOver, keyboard/focus, and real-host callbacks.
5. Anything not verified.

CI is required but does not establish native macOS or real-host acceptance. Maintainers may ask for Apple Silicon and Intel evidence for release-sensitive changes.

By contributing, you agree that your contribution is licensed under the repository's [MIT License](LICENSE) and that you will follow the [Code of Conduct](CODE_OF_CONDUCT.md).
