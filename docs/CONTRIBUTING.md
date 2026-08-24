# Claudio Contributor Reference

本页同步当前 SwiftPM targets、CLI、脚本和 CI 入口。项目策略的手写主文档仍是根目录的
[CONTRIBUTING.md](../CONTRIBUTING.md)；发生冲突时以根文档和 `AGENTS.md` 为准。

<!-- AUTO-GENERATED:BEGIN setup-and-commands -->
## 开发环境与命令

| Command | Purpose |
|---|---|
| `swift run --package-path helper claudio-tests` | 运行 `ClaudioCore`/CLI executable harness |
| `swift run --package-path gui claudio-gui-tests` | 运行 GUI Foundation-state executable harness |
| `swift build -c debug --package-path gui --product ClaudioGUI` | 构建 Debug 菜单栏 app |
| `swift build -c release --package-path gui --product ClaudioGUI` | 构建 Release app |
| `jq empty gui/Sources/ClaudioLocalization/Resources/Localizable.xcstrings` | 校验 localization JSON |
| `bash scripts/dev-bundle.sh` | 组装当前架构、ad-hoc 签名的 `dist/claudi0.app` |
| `bash scripts/check-release-size.sh dist/claudi0.app` | 检查 app 的架构和体积预算 |
| `bash scripts/local-pre-rc.sh` | 在 clean HEAD 上运行本机 pre-RC 基线并写入 `dist/local-pre-rc-report.json` |
| `bash scripts/test-hook-cli-contract.sh` | 校验真实 CLI hook 的 exit/output 和 Debug root 隔离 |
| `bash scripts/test-legacy-install-cli-contract.sh` | 校验 legacy install 的用户配置保持契约 |
| `bash scripts/verify-release-candidate.sh ...` | 对照 GitHub run/artifact 元数据复验已下载 RC |
| `bash scripts/benchmark-sound-pack-library.sh` | 构建并运行 Release sound-pack benchmark |
| `git diff --check` | 检查 patch whitespace |

Prerequisites: macOS 12+, Swift 6 / Xcode Command Line Tools, and `jq`. `helper/` and `gui/`
are separate packages; always pass the explicit package path and production product. The project
uses executable test harnesses rather than `swift test` because the supported local environment
does not assume XCTest or Swift Testing.
<!-- AUTO-GENERATED:END setup-and-commands -->

<!-- AUTO-GENERATED:BEGIN script-reference -->
## Scripts

| Script | Function |
|---|---|
| `scripts/dev-bundle.sh [--native-host-card-probe]` | Build the local inspection bundle; never a release artifact |
| `scripts/check-release-size.sh [APP]` | Enforce per-architecture GUI/helper and bundle budgets |
| `scripts/local-pre-rc.sh` | Run the commit-bound local pre-RC gates and write `dist/local-pre-rc-report.json` |
| `scripts/copy-bundled-packs.sh SOURCE DEST` | Validate the license ledger and copy all bundled packs |
| `scripts/test-hook-cli-contract.sh` | Run Debug/Release hook subprocess contract checks |
| `scripts/test-legacy-install-cli-contract.sh` | Test legacy install with isolated `CLAUDIO_TEST_*` roots |
| `scripts/test-host-card-height.sh` | Native AppKit screenshot regression probe |
| `scripts/benchmark-sound-pack-library.sh` | Measure cold/cached/incremental pack-library performance |
| `scripts/notarize-release-artifact.sh APP_OR_DMG` | Notarize, staple, and assess one signed release container |
| `scripts/verify-release-signature.sh KIND TEAM_ID ARTIFACT` | Verify one Developer ID release signature |
| `scripts/verify-release-candidate.sh --artifact-dir DIR --ledger LEDGER` | Bind a downloaded RC to its acceptance ledger and live evidence |
| `scripts/generate-brand-assets.swift` | Generate branding raster/icon assets |
| `scripts/generate-host-icon-pdf.swift INPUT.svg OUTPUT.pdf` | Convert a host SVG to a 24×24 PDF |
| `scripts/scan-host-card-height.swift SCREENSHOT.png` | Scan the host-card border rows in a screenshot |

The native probe and screenshot scripts require a real built app and macOS UI permissions; their
success is separate from the dependency-free harnesses.
<!-- AUTO-GENERATED:END script-reference -->

<!-- AUTO-GENERATED:BEGIN testing-and-style -->
## Testing, style, and review

- Add behavior regressions to the relevant `*Suite.swift` executable harness and register the suite
  in that package's `Tests/.../main.swift`.
- Keep `ClaudioCore` and `ClaudioGUICore` testable and separate from CLI/SwiftUI presentation.
- Use the checked-in `.swift-format`: Swift 6, four-space indentation, ordered imports, and a
  100-column target. New localization keys require both English and `zh-Hans` entries plus
  `ClaudioL10nKey.allKnown`.
- Before review, run both harnesses, the relevant build, `jq empty`, and `git diff --check`.
- Treat native menu-bar behavior, VoiceOver, keyboard/focus, Dynamic Type, audio playback, both
  CPU architectures, and real host callbacks as manual evidence beyond automated checks.

No repository pre-commit hook or formatter workflow is declared in the current source tree.
<!-- AUTO-GENERATED:END testing-and-style -->

<!-- AUTO-GENERATED:BEGIN pull-request-checklist -->
## Pull request checklist

- Explain the user-visible problem and changed contracts.
- List exact commands and results, including any failed or skipped checks.
- Separate automated evidence from native UI, VoiceOver, real-host, signing, notarization, and
  formal acceptance evidence.
- Keep `dist/`, `.build/`, `local-packs/`, prompts, responses, host configuration, receipts, logs,
  credentials, and personal/licensed sound packs out of commits.
- Preserve unknown JSON fields, third-party hooks, backups, receipts, and user data unless an
  explicit migration is part of the change.
<!-- AUTO-GENERATED:END pull-request-checklist -->
