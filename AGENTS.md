# Repository Guidelines

## Project Structure & Module Organization

Claudio is split into two SwiftPM packages. `helper/` contains the `ClaudioCore` library, the `claudio` CLI, and its executable test harness. `gui/` contains localization, Foundation-only GUI state, shared SwiftUI components, the sound-pack window, and the `ClaudioGUI` app. Tests live beside each package under `Tests/*Tests/` and use `*Suite.swift` files. Bundled sound packs belong in `packs/`; branding and host artwork belong in `assets/`. Use `docs/` for maintained reference material, `plan/` for implementation plans, and `scripts/` for repeatable build or verification tasks. Do not commit generated `dist/`, `.build/`, `local-packs/`, or machine-specific files.

## Build, Test, and Development Commands

Run commands from the repository root:

```bash
swift run --package-path helper claudio-tests
swift run --package-path gui claudio-gui-tests
swift build -c debug --package-path gui --product ClaudioGUI
jq empty gui/Sources/ClaudioLocalization/Resources/Localizable.xcstrings
bash scripts/dev-bundle.sh
bash scripts/check-release-size.sh dist/claudi0.app
git diff --check
```

The first two commands run the dependency-free test executables; `swift test` is not the project test entry point. `dev-bundle.sh` creates a local, current-architecture, ad-hoc-signed app for inspection, not a release artifact.

## Coding Style & Naming Conventions

Use Swift 6 and the checked-in `.swift-format`: four-space indentation, a 100-column target, ordered imports, `UpperCamelCase` types, and `lowerCamelCase` members. Keep `ClaudioCore` and `ClaudioGUICore` logic testable and separate from CLI or SwiftUI presentation code. Preserve established module names, data paths, hook formats, and host-adapter boundaries. New localized UI text must include matching English and `zh-Hans` entries and update `ClaudioL10nKey.allKnown`.

## Testing Guidelines

Name new suites `<Feature>Suite.swift`, expose a `run<Feature>Suites()` function, and register it in the package's `Tests/.../main.swift`. Add focused regression checks for behavioral changes. Treat native macOS UI, VoiceOver, keyboard/focus, both CPU architectures, and real host callbacks as manual evidence beyond CI.

## Commit & Pull Request Guidelines

Follow the existing concise, imperative convention: `feat: ...`, `fix: ...`, `docs: ...`, or scoped forms such as `fix(gui): ...`. Keep commits focused. Pull requests must describe the user-visible problem, changed contracts, exact commands and results, manual checks, and anything not verified. Link relevant issues and include screenshots for visible UI changes.

## Security & Configuration

Never commit prompts, responses, host configuration, receipts, logs, signing credentials, or personal/licensed sound packs. Preserve unknown JSON fields, third-party hooks, backups, receipts, and user data unless an explicit migration requires otherwise.
