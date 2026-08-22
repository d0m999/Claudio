# Environment Reference

<!-- AUTO-GENERATED:BEGIN source-of-truth -->
当前仓库没有 `.env.example`、`.env.template` 或 `.env.sample`。生产运行时不依赖一组秘密环境
变量；用户配置位于 `~/.claudio/` 和宿主自己的配置文件。下表来自 `Package.swift`、Swift
源码、脚本和 workflow 中的实际读取点。

## Build and release

| Variable | Required | Format / default | Purpose |
|---|---:|---|---|
| `CLAUDIO_VERSION` | Release: yes; local: no | `0.0.0-dev` or unprefixed `MAJOR.MINOR.PATCH` | 注入 CLI/app/release bundle version |
| `CLAUDIO_GUI_BYTES_PER_ARCH` | No | integer; default `4000000` | GUI Mach-O per-architecture size budget |
| `CLAUDIO_HELPER_BYTES_PER_ARCH` | No | integer; default `2500000` | helper Mach-O per-architecture size budget |
| `CLAUDIO_NON_EXECUTABLE_BUNDLE_BYTES` | No | integer; default `1000000` | non-executable bundle size budget |
| `CLAUDIO_LIPO_BIN` | No | executable path; default `lipo` | size gate 使用的 `lipo` |

## Tests and probes

| Variable | Required | Format / default | Purpose |
|---|---:|---|---|
| `CLAUDIO_TEST_ROOT` | Test-only | temporary directory; Debug only | 将 Claudio-owned runtime I/O 重定向到 fixture |
| `CLAUDIO_TEST_HOME` | Test-only | temporary home directory | 隔离 `~/.claude` / `~/.codex` host files |
| `CLAUDIO_TEST_APP_PATH` | No | app path; default `dist/claudi0.app` | native host-card probe 的 bundle |
| `CLAUDIO_TEST_HOST_CARD_STATE` | No | `unequal` | native probe 的固定不等高 host-card state |
| `CLAUDIO_TEST_TEXT_SIZE` | No | `maximum` | native probe 的 interface text size |
| `CLAUDIO_LOCALIZATION_STRICT` | No | `1` enables strict mode | localization catalog consistency check |
| `CLAUDIO_BENCHMARK_PACKS` | No | integer; default `100` | benchmark fixture pack count |
| `CLAUDIO_BENCHMARK_COLD_SAMPLES` | No | integer; default `30` | benchmark cold sample count |
| `CLAUDIO_BENCHMARK_CACHED_SAMPLES` | No | integer; default `100` | benchmark cached sample count |
| `CLAUDIO_BENCHMARK_INCREMENTAL_SAMPLES` | No | integer; default `30` | benchmark incremental sample count |
| `CLAUDIO_BENCHMARK_COLD_LIMIT_MS` | No | number; default `500.0` | cold benchmark limit |
| `CLAUDIO_BENCHMARK_CACHED_LIMIT_MS` | No | number; default `100.0` | cached benchmark limit |

`CLAUDIO_TEST_ROOT`、`CLAUDIO_TEST_HOME` 和 native probe 变量只用于隔离测试。Release helper
必须不包含并且不响应这些 Debug-only test roots；不要把真实用户路径作为测试输入。

`CLAUDIO_NATIVE_HOST_CARD_PROBE` 是 Swift 编译条件，不是 runtime environment variable；通过
`scripts/dev-bundle.sh --native-host-card-probe` 启用。GitHub Actions 另有 `CLAUDIO_CI_*` 内部
变量用于 diff range 计算，不是开发者配置接口。Apple signing/notarization values 只通过
GitHub Actions secrets 注入，不能写入此文档或仓库。
<!-- AUTO-GENERATED:END source-of-truth -->

## Runtime paths

Runtime configuration is file-based rather than `.env`-based:

- `~/.claudio/config.json` — selected pack, master volume, event enablement, starred packs。
- `~/.claudio/packs/` — user sound packs and manifests。
- `~/.claude/settings.json` / `~/.codex/hooks.json` — host-owned hook configuration。

这些路径不属于环境变量；测试必须通过显式临时目录注入，不能触碰运行测试用户的真实 host 配置。
