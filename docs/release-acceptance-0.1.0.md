# claudi0 0.1.0 首发验收记录

状态：**未通过**。本记录是 `0.1.0` 的唯一人工验收账本；本地测试、RC 构建成功或单个截图均不能替代未完成项。

## 产物绑定

| 字段 | 结果 |
|---|---|
| RC version | `0.1.0` |
| Release workflow path | `.github/workflows/release.yml` |
| Release workflow ID | `310455860` |
| Workflow ref | `refs/heads/main` |
| Workflow inputs | 待填 |
| Commit SHA | 待填 |
| GitHub Actions run URL | 待填 |
| GitHub Actions run ID | 待填 |
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

## WorkBuddy 真实回调闭环（Issue #15）

本节记录 2026-08-24（Asia/Singapore）在单独明确授权后，对当前 WorkBuddy installation
执行的一次可逆 Connect → 两条真实回调 → GUI 核对 → Disconnect 闭环。只保存脱敏摘要和
本机证据指针，不保存 WorkBuddy 配置、备份内容、prompt、response、receipt 原文件或日志。
本节通过不改变本账本顶部的 `0.1.0` 整体“未通过”状态，也不构成 RC 或正式发布验收。

### 执行身份与写入前基线

| 字段 | 结果 | 证据等级 |
|---|---|---|
| Issue #14 依赖 | 已关闭；Issue #15 原生 `blocked_by=0` 后才继续 | tracker state |
| 写入授权 | 已在本 ticket 执行会话中单独取得；授权仅覆盖本次可逆 WorkBuddy Connect/Disconnect | manual authorization |
| 写入前 preflight | commit `91eb5fdcb200a529259d701bad66d796134b6e09`；`available` / `ready` / `writable` / `not_configured` / `none` | static configuration |
| WorkBuddy | `com.workbuddy.workbuddy`，version/build `5.3.14`，surface `workbuddy` | static configuration |
| 本机备份 | Issue #15 独立 pre-Connect 备份位于 Git 外，为正规文件、mode `0600` | local-only evidence |
| 备份完整性 | 独立备份与一次性 `settings.json.claudio.bak` 均逐字节匹配写入前配置 | local-only integrity |
| 写入前 hook 基线 | 9 条既有 hook；Claudio/WorkBuddy 自有条目为 0 | redacted structural summary |

### Connect、真实回调与同源状态

Connect 只新增当前 Claudio root/binary 下的两条自有 command hook；写入后共有 11 条 hook，
其中且仅其中 2 条属于当前 WorkBuddy installation。未知顶层字段与全部第三方 hook 的规范化
JSON 哈希保持不变。Connect 后 configuration 为 `configured`，两条 binding 均先进入
`awaiting_receipt`，没有把静态配置冒充 Current Activation。

| Native event → Claudio Event | Binding ID | Current receipt | Sound outcome |
|---|---|---|---|
| `UserPromptSubmit` → `task_start` | `workbuddy:UserPromptSubmit:task_start:none:v1` | schema 2；current installation 与 scope 全部匹配 | `muted` |
| `Stop` → `stop` | `workbuddy:Stop:stop:none:v1` | schema 2；current installation 与 scope 全部匹配 | `muted` |

两条 receipt 均为正规文件、mode `0600`，且 host、surface、installation、binding、schema、
native event、公共 Event 与完整 scope fingerprint 全部匹配。当前 effective profile 无 WorkBuddy
Surface 覆盖，`task_start` 与 `stop` 均继承全局显式静音值，因此两个 `muted` outcome 一致。
只有第一条 receipt 时，`Stop` 仍为 awaiting；Stop receipt 到达后，CLI status 与 doctor 才
分别显示两条 current activation 和 `WorkBuddy 2/5 已就绪`。在 Stop 人工步骤中，用户确认
为形成可停止任务又手动提交一次任务并点击 Stop；最终 latest `UserPromptSubmit` 与 latest `Stop`
因此构成同一组明确人工触发、匹配当前 scope 的 current evidence。更早的一组历史继续按保留契约
存在，但不参与最终闭环的人工 provenance 断言。配置始终只有一个对应自有 hook，不存在重复安装
条目。

GUI 人工核对确认两条 `muted` current receipt、2/5 状态，以及 `StopFailure`、`Notification`、
`SubagentStop` 始终为 notImplemented。GUI 没有单独展示或人工抄录完整 installation UUID 与
scope fingerprint；这两个匹配事实来自 CLI、active-installation marker 与 receipt 的交叉核对，
不把 UI 可见性夸大为完整原始身份展示。

### Disconnect 与保留性证明

Disconnect 后的只读 preflight 采集于 `2026-08-23T16:37:37Z`，绑定 commit
`c88c02a892e4479efc6fc0f433db60955e12044d`。WorkBuddy 回到 `not_configured`、
Current Activation `none`，active installation marker 已移除；两条 binding 回到
`implemented_not_activated`，三条未实现能力保持不变。

| 保留项 | Disconnect 后结果 |
|---|---|
| WorkBuddy 未知字段与第三方 hooks | Disconnect 后规范化 JSON 摘要与写入前一致；9 条既有 hook 全部保留，自有条目为 0 |
| 声音默认值与 Surface 覆盖 | Disconnect 后规范化配置摘要与写入前一致 |
| 备份 | 独立 pre-Connect 备份与一次性 WorkBuddy 备份均保留 |
| 脱敏证据 | 两个 latest receipt 与 retained receipt history 均保留；Disconnect 后因 current installation 已撤销，历史不能重新点亮 Current Activation |
| 其它宿主 | 既有 Claude Code / Codex installation 与冲突状态未修改；doctor 总体 failure 仍来自这两个 #15 范围外事实 |

本闭环未发现需要放宽 receipt、scope、配置事务或 fail-closed 契约的缺陷。执行中一度使用了
会把 JSON 布尔 `false` 错当回退条件的 `jq //` 诊断表达式；改用 `has(key)` 后确认 effective
profile 与两个 `muted` receipt 一致，该诊断错误未修改任何产品代码或用户配置。

## 自动化与分发门禁

触发前必须先在本节顶部记录目标 `main` commit、`0.1.0`、三项 workflow 输入和单独运行授权。
`Workflow inputs` 使用无空白单行 JSON：
`{"version":"0.1.0","target_commit":"<approved-40-character-main-sha>","release_authorized":true}`。
只有目标 commit 已存在于远程 `main` 且授权已取得，才可执行；`release_authorized=true` 只是该授权的
attestation，不是授权来源：

```bash
gh workflow run release.yml --ref main \
  -f version=0.1.0 \
  -f target_commit=<approved-40-character-main-sha> \
  -f release_authorized=true
```

运行成功后，先在顶部填入 run URL、run ID、artifact 名称、最终 DMG 文件名和 SHA-256；下载
`claudi0-rc-<commit-sha>` 后，再以本账本作为唯一期望身份源，对 artifact 自带的
`RC_MANIFEST.json` 做二次绑定：

```bash
bash scripts/verify-release-candidate.sh \
  --artifact-dir <downloaded-artifact-directory> \
  --ledger docs/release-acceptance-0.1.0.md
```

- [ ] 三项 dispatch 输入与单独授权已预先记录；`target_commit` 同时匹配远程 `main` 触发 SHA 和 checkout HEAD。
- [ ] RC workflow 完成，且只产生 SHA 绑定的 Actions artifact；未创建 tag、Release 或 tap 更新。
- [ ] helper / GUI harness、CLI 子进程 contracts、universal build、签名、公证、staple、checksum 全部通过。
- [ ] helper/app 的 Developer ID team 与 hardened runtime 匹配；app 与 DMG 分别 notarize/staple 通过。
- [ ] workflow 从最终挂载 DMG 复验 app/helper 架构、版本、资源、symlink、`codesign`、`spctl`、`stapler`、体积和 SHA-256。
- [ ] 下载后的 verifier 同时匹配 live run、artifact、官方 archive digest、commit、版本、DMG 文件名、manifest/checksum 和实际 DMG 字节。
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
