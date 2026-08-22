# Claudio Runbook

本手册描述当前本地 app、CLI、宿主连接和 release workflow。它不把静态配置、自动化测试或
本地 bundle 等同于真实 host callback、生产发布或人工验收。

<!-- AUTO-GENERATED:BEGIN local-operation -->
## 本地构建与健康检查

```bash
swift run --package-path helper claudio-tests
swift run --package-path gui claudio-gui-tests
swift build -c debug --package-path gui --product ClaudioGUI
bash scripts/dev-bundle.sh
open dist/claudi0.app
```

CLI 使用 app bundle 中的 helper 或已安装的 `~/.claudio/bin/claudi0`：

```bash
claudi0 doctor
claudi0 integrations status --json
claudi0 integrations connect claude-code
claudi0 integrations connect codex
claudi0 integrations disconnect <claude-code|codex>
```

`doctor` 是只读检查；`integrations status --json` 是机器可读快照。Codex connect 写入
`~/.codex/hooks.json` 后仍需用户在 Codex 输入 `/hooks` 确认并提交一次提示词，只有当前
installation 的真实 `UserPromptSubmit` receipt 才算 observed。
<!-- AUTO-GENERATED:END local-operation -->

<!-- AUTO-GENERATED:BEGIN health-and-troubleshooting -->
## 健康信号与常见问题

本项目没有 HTTP health endpoint、后台 daemon 或 telemetry service。健康信号是 CLI 快照、
脱敏 receipt、`claudio.log` 和构建/测试结果。

| Symptom | First checks | Safe response |
|---|---|---|
| app 不出声 | `claudi0 doctor`、`config.json`、selected pack manifest/audio、主音量/事件静音 | 修复或在 GUI 导入/选择声音包；不要手改覆盖未知 JSON 字段 |
| host 显示未连接 | `claudi0 integrations status --json`、对应 host 配置路径 | 对目标 host 显式 `connect`；不要覆盖第三方 hooks |
| host 配置不可读/不可写 | 文件权限、symlink、外部并发修改、对应 lock | 停止重复操作，保留原文件和 backup，先消除权限/外部写入原因 |
| Codex 等待确认 | `/hooks` 尚未确认，或尚无当前 installation receipt | 在 Codex 完成确认并提交一次提示词；不要用旧 Stop receipt 冒充激活 |
| app 可能是旧 bundle | 重新运行 `bash scripts/dev-bundle.sh`，检查 `dist/claudi0.app` 的时间和进程 | 退出旧进程后再 `open`，不要把旧 bundle 的 UI 结果当成当前源码证据 |
| release size gate 失败 | `bash scripts/check-release-size.sh dist/claudi0.app` 的具体预算和架构输出 | 修复 bundle 组成/预算问题；不要删除用户数据或绕过 gate |

所有连接/断开操作只修改对应 adapter 自有条目；另一宿主、第三方配置、shared runtime、
声音包、backup 和 receipt 应保持不变。
<!-- AUTO-GENERATED:END health-and-troubleshooting -->

<!-- AUTO-GENERATED:BEGIN release-and-rollback -->
## Release、回滚与升级

正式 release 由 `.github/workflows/release.yml` 负责：

1. `workflow_dispatch` 只接受 `main` 上的首个 `0.1.0` RC，或推送严格匹配的 `vMAJOR.MINOR.PATCH` tag。
2. workflow 校验 Apple Developer ID / notarization secrets，分别构建 arm64 与 x86_64 helper/GUI，
   用 `lipo` 合并 universal binary，再组装 app、DMG、签名、公证、staple、checksum 和 release metadata。
3. CI 在交付前运行 helper/GUI harness、hook/legacy contracts、localization JSON、size/layout gates。

本地 `dev-bundle.sh` 只用于当前架构 inspection，不能证明 universal、Developer ID、notarization
或发布成功。release 失败时保留 CI artifact 和日志，先修复 workflow gate；不要用未签名本地
bundle 代替发布产物。

回滚不需要数据库 migration：保留 `~/.claudio/`、用户 sound packs、host 配置和 receipts，替换
app 为上一份已验证的 app/DMG，然后重新运行 `doctor` 与 `integrations status --json`。只有明确的
迁移需求才允许改变用户数据；普通回滚不删除目录、不清理第三方 hooks。
<!-- AUTO-GENERATED:END release-and-rollback -->

<!-- AUTO-GENERATED:BEGIN escalation -->
## Alerting and escalation

- 编译、harness、CI 或 release gate 失败：记录完整命令、commit SHA、workflow run 和首个错误，
  由维护者处理；不要只报告“CI 红了”。
- native UI、VoiceOver、keyboard/focus、真实 host callback 或 audio 失败：附 macOS 版本、CPU、
  bundle 路径、复现步骤和是否有真实 receipt，并将其标记为 manual evidence。
- 发现 prompt、response、host config、receipt、log、credential 或 licensed personal audio 泄露：
  立即停止外部发送，按 `SECURITY.md` 走安全披露，不把材料加入 issue/commit。
<!-- AUTO-GENERATED:END escalation -->
