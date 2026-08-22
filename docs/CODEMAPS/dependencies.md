# Dependency Map

<!-- Generated: 2026-08-22 | Files scanned: 286 | Token estimate: ~610 -->

## Package graph

```text
swift-argument-parser (remote, pinned in Package.resolved)
             ↓
helper: ClaudioVersionC → ClaudioCore → claudio / claudio-tests
                                      ↑
gui: ClaudioLocalization → ClaudioGUICore → ClaudioGUIComponents
                                      └──→ SoundPacksWindow → ClaudioGUI / claudio-gui-tests
```

`gui/Package.swift` depends on the local `helper` package. `ClaudioCore` is the shared contract
for CLI, GUI bridge, host adapters, config, events, packs, locks, receipts, and playback.

## Apple/platform dependencies

- macOS 12+; Swift 6 toolchain and SwiftPM.
- Foundation for domain/storage, AppKit/SwiftUI for the menu-bar app and windows, Combine for
  observable UI models, AVFoundation for audio-duration probing, and CoreGraphics/ImageIO for
  asset/screenshot tooling.
- System `afplay` is the runtime audio player. Release assembly additionally uses `lipo`,
  `codesign`, `notarytool`, `hdiutil`, and `xcrun` in CI.

## External integration surfaces

- Claude Code: `~/.claude/settings.json`, native events `UserPromptSubmit`, `Stop`, `StopFailure`,
  `Notification`, `SubagentStop`.
- Codex: `~/.codex/hooks.json`, native events `UserPromptSubmit`, `Stop`, `PermissionRequest`,
  `SubagentStop`; Claudio does not own Codex `notify` or private trust data.
- Local user sound packs and imported audio are treated as user data, not network dependencies.

## Explicit non-dependencies

No HTTP client/server, database, Docker runtime, telemetry service, or cloud API is present in the
current source graph. `.github/workflows` supplies CI/release orchestration but is not a runtime
dependency of the app.
