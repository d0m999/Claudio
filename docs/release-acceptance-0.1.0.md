# claudi0 0.1.0 首发验收记录

状态：**未通过**。本记录是 `0.1.0` 的唯一人工验收账本；本地测试、RC 构建成功或单个截图均不能替代未完成项。

## 产物绑定

| 字段 | 结果 |
|---|---|
| Commit SHA | 待填 |
| GitHub Actions run URL / ID | 待填 |
| Actions artifact 名称 | `claudi0-rc-<commit-sha>`（待下载核对） |
| DMG 文件名 | `claudi0-0.1.0.dmg`（待核对） |
| DMG SHA-256 | 待填 |
| Apple Silicon 硬件 / macOS | 待填 |
| Intel 硬件 / macOS 12 | 待填 |
| Claude Code 版本 | 待填 |
| Codex 版本 | 待填 |
| 截图目录或附件 | 待填 |
| 脱敏 receipt 目录或附件 | 待填 |

## WorkBuddy 只读 preflight（Issue #14）

本节是同一份 release acceptance ledger 的 WorkBuddy 扩展，不创建第二份验收真相源。可重复入口为：

```bash
scripts/workbuddy-acceptance-preflight.sh
scripts/workbuddy-acceptance-preflight.sh --json
```

入口按只读顺序采集 WorkBuddy `Inspect`、`integrations status` 与 `doctor`，输出脱敏 Markdown 或 JSON；
它不会调用 `Connect`、`Repair`、`Disconnect`，不会写入用户配置、创建声音覆盖、备份配置或自动试听。
Markdown 与 JSON 均记录 CLI、GUI 和 doctor 状态及证据等级；两者只保留摘要和版本/身份字段，不保存
WorkBuddy 配置、备份、prompt、response、receipt 原文件或日志。入口默认绑定规范化的当前 `git HEAD`；
可选 `--commit-sha <SHA>` 只是当前 `HEAD` 的期望断言，不能用来覆盖或伪造实际 commit 身份。

### 当前只读基线

以下摘要由 2026-08-23、绑定已提交 Issue #14 hardening commit 的一次真实只读运行生成；后续仅账本
提交不改变该实现事实。命令 stdout 未作为原始证据文件写入仓库；本节与入口脚本是可重建的脱敏证据指针。

| 字段 | 结果 | 证据等级 |
|---|---|---|
| Collected at | `2026-08-23T15:00:59Z` | static configuration |
| Commit SHA（preflight 采集 commit） | `91eb5fdcb200a529259d701bad66d796134b6e09` | static configuration |
| Claudio version | `0.0.0-dev` | static configuration |
| WorkBuddy bundle | `com.workbuddy.workbuddy`，version `5.3.14`，build `5.3.14`，`/Applications/WorkBuddy.app` | static configuration |
| macOS / CPU | `26.6.2` / `arm64` | static configuration |
| Host / Surface | `workbuddy` / `workbuddy` | static configuration |
| installation | `none`（尚未连接） | static configuration |
| scope fingerprint | `surface=workbuddy;host=app=short=5.3.14;build=5.3.14;claudio=0.0.0-dev;bindings=workbuddy:Stop:stop:none:v1,workbuddy:UserPromptSubmit:task_start:none:v1` | static configuration |
| Inspect / integrations status | `available` / `ready` / `writable` / `not_configured` / `none`；两次观察一致 | static configuration |
| CLI status / doctor | integrations status 已采集；WorkBuddy doctor 为 warning（未连接）；doctor 总体为 failure（其他宿主存在冲突） | static configuration |
| GUI | `not_run`；需原生 SwiftUI 人工验收 | manual acceptance |
| 声音结果 | `task_start`、`stop` 均 `not_tested`；preflight 不自动试听 | static configuration |

### Host Event Binding 基线

| Native event → Claudio Event | Host Event Binding ID | Implementation | 当前基线 |
|---|---|---|---|
| `UserPromptSubmit` → `task_start` | `workbuddy:UserPromptSubmit:task_start:none:v1` | `implemented` | `implemented_not_activated` |
| `Stop` → `stop` | `workbuddy:Stop:stop:none:v1` | `implemented` | `implemented_not_activated` |
| `StopFailure` → `stop_failure` | `workbuddy:StopFailure:stop_failure:interface_supported_not_implemented:v1` | `not_implemented` | `not_implemented` |
| `Notification` → `notification` | `workbuddy:Notification:notification:interface_partially_supported_not_implemented:v1` | `not_implemented` | `not_implemented` |
| `SubagentStop` → `subagent_stop` | `workbuddy:SubagentStop:subagent_stop:interface_supported_not_implemented:v1` | `not_implemented` | `not_implemented` |

### 证据分层与边界

| 层级 | 当前值 | 含义 |
|---|---|---|
| Static configuration | `recorded` | 版本、Host Surface、binding catalog、只读配置/运行时探针 |
| Current Activation | `not_observed` | 没有当前 installation 下真实宿主回调产生的两条匹配回执 |
| RC | `not_evaluated` | 未以签名 universal RC 产物完成验收 |
| Manual acceptance | `not_evaluated` | GUI、声音实际可听结果、真实 WorkBuddy 事件尚未人工验收 |

本次安全摘要为 `read_only=true`、`invoked_mutating_actions=[]`、`automatic_audio_preview=false`、
`raw_user_data_persisted=false`。未连接、未形成 Current Activation 和未执行人工/RC 验收均保持原样，不能由本地绿色测试推断为通过。

## 自动化与分发门禁

- [ ] `workflow_dispatch(version=0.1.0)` 从 `main` 完成，且只产生 SHA 绑定的 Actions artifact。
- [ ] helper / GUI harness、CLI 子进程 contracts、universal build、签名、公证、staple、checksum 全部通过。
- [ ] workflow 从最终挂载 DMG 复验 app/helper 架构、版本、资源、symlink、`codesign`、`spctl`、`stapler` 和 SHA-256。
- [ ] 从 Actions 下载的 DMG 与记录中的 SHA-256 一致。
- [ ] Apple Silicon 当前系统完成安装、启动、基础播放。
- [ ] Intel / macOS 12 完成安装、启动、基础播放。
- [ ] 隔离测试账户连接真实 Claude Code 与 Codex；Claude 为 5/5、Codex 为 4/5。
- [ ] 真实事件产生脱敏 `played`、`muted`、`not_ready` receipt，installation / host / event 绑定正确。

## 视觉矩阵（48 帧）

每格必须链接到独立截图或写明附件文件名；`maximum` 不得裁切。表面：菜单栏面板、声音包窗口、连接与诊断窗口。

| 表面 / 文字档 | 浅色中文 | 浅色英文 | 深色中文 | 深色英文 |
|---|---|---|---|---|
| 面板 / compact | 待验 | 待验 | 待验 | 待验 |
| 面板 / standard | 待验 | 待验 | 待验 | 待验 |
| 面板 / large | 待验 | 待验 | 待验 | 待验 |
| 面板 / maximum | 待验 | 待验 | 待验 | 待验 |
| 声音包 / compact | 待验 | 待验 | 待验 | 待验 |
| 声音包 / standard | 待验 | 待验 | 待验 | 待验 |
| 声音包 / large | 待验 | 待验 | 待验 | 待验 |
| 声音包 / maximum | 待验 | 待验 | 待验 | 待验 |
| 连接与诊断 / compact | 待验 | 待验 | 待验 | 待验 |
| 连接与诊断 / standard | 待验 | 待验 | 待验 | 待验 |
| 连接与诊断 / large | 待验 | 待验 | 待验 | 待验 |
| 连接与诊断 / maximum | 待验 | 待验 | 待验 | 待验 |

附加 spot check：

- [ ] 三个表面 × 增加对比度。
- [ ] 三个表面 × 降低透明度。

## 键盘矩阵（24 条流程）

每格执行：初始焦点、完整 `Tab` / `Shift-Tab`、`Esc`、retained-window 关闭后的焦点归还。

| 表面 / 文字档 | 中文 FKA 关 | 中文 FKA 开 | 英文 FKA 关 | 英文 FKA 开 |
|---|---|---|---|---|
| 面板 / standard | 待验 | 待验 | 待验 | 待验 |
| 面板 / maximum | 待验 | 待验 | 待验 | 待验 |
| 声音包 / standard | 待验 | 待验 | 待验 | 待验 |
| 声音包 / maximum | 待验 | 待验 | 待验 | 待验 |
| 连接与诊断 / standard | 待验 | 待验 | 待验 | 待验 |
| 连接与诊断 / maximum | 待验 | 待验 | 待验 | 待验 |

## VoiceOver 矩阵（12 条流程）

每格核对 label、hint、value、selected；禁用试听必须跳过，装饰图标不得重复，bootstrap 报告首次可见时只完整播报一次。

| 表面 / 文字档 | 中文 | 英文 |
|---|---|---|
| 面板 / standard | 待验 | 待验 |
| 面板 / maximum | 待验 | 待验 |
| 声音包 / standard | 待验 | 待验 |
| 声音包 / maximum | 待验 | 待验 |
| 连接与诊断 / standard | 待验 | 待验 |
| 连接与诊断 / maximum | 待验 | 待验 |

## 正式发布后终验

只有上面全部通过后才允许另行授权创建并推送 `v0.1.0`。tag workflow 创建正式 Release 后：

- [ ] 重新下载 Release 中的 DMG 与 `SHA256SUMS.txt` 并校验。
- [ ] 重新执行 Gatekeeper、安装、覆盖升级、卸载和真实宿主 smoke。
- [ ] Release notes、支持矩阵、已知限制与安装说明完整。
- [ ] 若启用 Homebrew，cask SHA 与正式 DMG 一致，并在干净环境完成安装/升级。

任何 Intel、VoiceOver、Apple 凭据或真实回执缺失均保持本记录“未通过”；不得用本地绿色或自报结果改成通过。
