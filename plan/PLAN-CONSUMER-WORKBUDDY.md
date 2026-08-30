# PLAN — WorkBuddy 正式集成与 surface 声音配置

> 状态：**2/5 pre-RC 自动化已收口；当前持久连接与 Current Activation 已获本机窄验收；RC/发布未通过**
>
> 更新：2026-08-31
>
> 本文件本身不构成 commit、push、发布或真实宿主写入授权；2026-08-31 的连接、验收记录、
> commit 与 push 均来自当次独立用户授权。

## 1. 用户结果

- Apps/集成窗口永久列出 Claude Code、Codex、WorkBuddy 三个产品可见 native adapter；未安装不等于
  消失。AX identity 只保留兼容解码和隔离 `DEBUG` tracer，不进入正常产品 registry 或普通 UI。
- WorkBuddy 永久显示五个公共事件，首发诚实标为 2/5 已实现，不用接口声明伪造 5/5。
- popup 只显示当前已配置或可用的事件来源，并允许选择全局默认或某个 surface 的声音配置。
- Events/popup 可编辑已实现事件的 pack 和静音；未实现/不支持事件禁用，不提供假按钮。
- 连接、声音可播放性与真实回执分别呈现；配置完成但尚无回执为 awaiting，不是假绿。

## 2. 稳定契约

### 2.1 产品、surface 与绑定

`HostID` 保持连接 adapter 身份并提供 `HostSurfaceID`；descriptor 声明 product、surface、
mechanism、maturity 和 control surface。每条能力使用稳定 `HostEventBindingID`，并分别记录：

- 宿主接口支持程度：supported / partial / unsupported；
- claudi0 当前实现：implemented / notImplemented；
- 当前 installation 的真实 activation evidence。

WorkBuddy 首发绑定：

| 原生事件 | 公共 Event | 接口 | 当前实现 | 控件 |
|---|---|---|---|---|
| UserPromptSubmit | task_start | supported | implemented | 可配置、可试听 |
| Stop | stop | supported | implemented | 可配置、可试听 |
| StopFailure | stop_failure | supported | notImplemented | 禁用 |
| Notification | notification | partial | notImplemented | 禁用 |
| SubagentStop | subagent_stop | supported | notImplemented | 禁用 |

### 2.2 配置事务

- 只管理用户级 `~/.workbuddy/settings.json`；不改 workspace 配置或声音 config。
- 只增删精确匹配当前 Claudio root、binary、host、binding 与 installation UUID 的 command。
- 复用 `ConfigFileTransaction` 的锁、备份、CAS、symlink 策略和原子发布；畸形、错位、重复、
  代次冲突全部 fail closed。
- Connect/Repair/Disconnect 均为显式动作；Inspect 只读。首次连接不创建 surface 声音覆盖，
  不自动试听。Disconnect 保留声音偏好与历史回执。
- scope 或 marker 失配时 Connect/Repair 必须轮换 installation；Disconnect 只删除当前
  binary/host/binding/installation 的命令，保留同 root 的其它代次。

### 2.3 回执与失效

- current evidence 必须同时匹配 schema 2、installation、host/surface、scope、`HostEventBindingID`、
  原生事件和公共事件；schema 1 只可进入历史。
- WorkBuddy scope fingerprint 绑定 Desktop version、`ClaudioVersion.current` 与已实现 binding 集合。
- app/runtime/binding 变化使旧 activation 失效；普通 claudi0 app 重启不失效。
- 稳定 current 回执用于矩阵；历史回执只用于诊断，不得反向点亮 activation。
- 历史每 surface 20 条、30 天，0600 文件，断开保留；用户只能经有确认的显式动作清除。

### 2.4 声音偏好

- 顶层 `selected_pack`、事件开关为全局默认；`master_volume` 始终全局。
- `surface_overrides[HostSurfaceID]` 只保存明确改过的 pack/事件字段；缺失逐项继承。
- 明确损坏的目标 surface fail closed，不回退到全局包；其他 surface 不受影响。
- popup 选择持久化稳定 surface token；失效 token 回退到 registry 中首个已配置/可用 surface，
  都没有时回退全局。
- reset 可删除整个 surface 覆盖；空 object 不落盘；未知 JSON 字段保留。

## 3. UI 分工

- popup：按最终 HTML 原型使用标题摘要、全宽 Global/Surface 作用域菜单、当前来源五个事件、
  两行播放设置组与固定退出 footer；标准宽 312pt、maximum 360pt、高度 400–560pt，并继续支持
  系统浅色/深色。生产面板不再挂载三张来源卡片、紧凑 `Picker`、宿主 chips、声音包画廊或旧
  「管理声音包」行。
- WorkBuddy 作用域稳定显示五行：`UserPromptSubmit`、`Stop` 为已实现且可配置/试听；
  `StopFailure`、`Notification`、`SubagentStop` 显式标为未实现，试听与静音均禁用。Global 行显示
  claudi0 事件 ID 与「全局默认」，不得伪造宿主原生事件名或全局假 `3/5`。
- popup 的「打开设置」携带 `PanelSoundScopeID` 进入保留的「事件与提示音」窗口；该窗口对应
  HTML 原型 `page=events&app=<scope>`，继续显示五事件、能力、当前声音与试听/静音。逐事件编辑再携带
  `HostSurfaceID?` 与 effective pack 委托 Sound Packs Window。Global「使用此包」写顶层 `selected_pack`；
  WorkBuddy 下写稀疏 `surface_overrides[workbuddy].selected_pack`；reset 定向删除 WorkBuddy 覆盖并清掉空
  object。未知字段保留，未知/AX scope fail closed，绝不静默写到 Global。
- Apps/集成窗口：按 Product → Surface 分组展示连接、scope/version 失效、binding 状态、
  latest receipt、Repair、Disconnect、回执历史清除；只列三个产品可见 native surface。
- 来源菜单只列 Global 与已配置或可用 surface；`.notConnected` 仍在集成窗口但不进入 popup。
  首次/失效选择回落首个可用来源，没有可用来源时回落 Global。
- 视觉遵循原生 macOS 信息层级；HTML 为交互主原型，SVG 为只读快照，SwiftUI 视觉批准另行验收。

生产焦点顺序为 `soundScope → bootstrap/config recovery → 可用事件试听/静音 → masterVolume →
openSoundSettings → resetSurface（条件）→ quitApplication`。打开集成窗口时，Host 预选与返回面板
焦点是两个独立参数；关闭「事件与提示音」后焦点返回「打开设置」，关闭其委托的 Sound Packs Window
则返回事件窗口。本轮自动化和本地构建不代表 Issue #20
的签名 RC 原生视觉验收，真实 Tab/Shift-Tab、VoiceOver、增加对比度、降低透明度与双架构仍需人工证据。

## 4. 本地验收

- helper 测试覆盖 transform 幂等、未知字段、第三方 hook、错位/冲突、两条 binding、版本 scope、
  disconnect、surface 解析/写入、回执历史边界与 doctor 三行。
- GUI 测试覆盖动态三 surface 矩阵与 Product → Surface 分组、WorkBuddy 2/5、AX 不进入普通 UI、
  历史 AX token 可解码、surface effective profile、定向写、reset、全局音量、本地化、焦点与
  destructive confirmation 接线；既有 AX tracer 隔离测试继续执行。
- 必须通过：

```bash
bash scripts/local-pre-rc.sh
swift run --package-path helper claudio-tests
swift run --package-path gui claudio-gui-tests
swift build -c debug --package-path gui --product ClaudioGUI
jq empty gui/Sources/ClaudioLocalization/Resources/Localizable.xcstrings
git diff --check
```

### Pre-RC 证据与正式验收链

- Issue #65 已固化七个 WorkBuddy 状态、双语 presentation、fixture 与生产 wiring；它是
  automated evidence，不是 Issue #20 的原生视觉批准。
- Issue #66 已固化焦点顺序、可访问性语义、动作 owner 与播报去重；它是 automated evidence，
  不证明 Issue #21 的真实 Tab/Shift-Tab、Full Keyboard Access 或 VoiceOver 播报。
- 上述实现连同 Issue #64 发布合同已在 clean checkout 的 `scripts/local-pre-rc.sh` 中聚合通过；
  产物只有当前架构与 ad-hoc 身份，证据等级为 `pre_rc_only`。精确 commit、架构与计数只维护在
  唯一验收账本。

| Issue | 当前状态 | 保持未验证的正式事实 |
|---|---|---|
| #18 | `OPEN` | 签名 universal RC |
| #19 | `OPEN` | Apple Silicon 与 Intel WorkBuddy RC 真机矩阵 |
| #20 | `OPEN` | 原生 SwiftUI 视觉矩阵 |
| #21 | `OPEN` | 键盘、焦点归还与 VoiceOver 矩阵 |
| #22 | `OPEN` | 正式路线图验收与人工批准 |

完整 commit、命令、结果与证据分层只维护在
[0.1.0 验收账本](../docs/release-acceptance-0.1.0.md#pre-rc-自动化基线issues-6466)，不创建第二份账本。

## 5. 真实验收结果（Issue #15 历史闭环与当前持久连接）

2026-08-24 在单独授权下已完成可逆 Connect → callback → GUI 核对 → Disconnect：

- `UserPromptSubmit → task_start` 与 `Stop → stop` 均产生 schema 2、匹配当前
  binding/installation/scope 的真实回执；声音结果因有效配置继承全局静音而均为 `muted`。
- GUI 人工核对确认 WorkBuddy 为 2/5；`StopFailure`、`Notification`、`SubagentStop` 始终为
  `notImplemented`，没有用接口声明伪造实现。
- Disconnect 后自有 hooks 与 active installation marker 已移除，Current Activation 为 `none`；
  第三方 hooks、未知字段、声音偏好、备份和脱敏历史按契约保留。
- 本闭环是历史真实宿主证据，不是当前激活、RC、发布或正式验收。

2026-08-31 在 WorkBuddy `5.4.4` 上再次完成 Connect 与真实回执验证，并按用户明确批准保持连接：

- `UserPromptSubmit → task_start` 与 `Stop → stop` 均为当前 installation/scope 下的 schema 2
  Current Activation；最终 preflight 为 `configured` / `observed`，WorkBuddy doctor 为 `ok`。
- 两条声音结果均为 `muted`；这证明回调与播放策略执行，不构成肉耳听音通过。
- 连接与诊断页显示 `WorkBuddy 2/5 已就绪`，声音作用域显示
  `WorkBuddy 2/5 · 已激活`；其余三个事件继续为 `notImplemented`。
- 第三方 hooks、未知字段、声音配置、其它宿主状态与 Git 外 `0600` 备份均按契约保留；
  最终保留 9 条第三方 hook 与 2 条 Claudio 自有 hook，未执行 Disconnect。
- 本机当前 installation 的 2/5 持久连接与 Current Activation 窄验收正式通过；该结论不批准
  5/5、肉耳听音、双架构、VoiceOver、签名、公证、RC、生产或发布。

完整脱敏证据与时间线只记录在
[0.1.0 验收账本](../docs/release-acceptance-0.1.0.md#workbuddy-持久连接与-25-当前激活正式验收2026-08-31)。

## 6. 剩余三个事件的 evidence-first 门

`StopFailure`、`Notification`、`SubagentStop` 必须分别创建独立计划/Issue。每项在实现前都要取得
当前 WorkBuddy 版本的可重复触发证据、最小且不含用户内容的 callback contract、负向/重复触发结果和
fail-closed 停止条件；实现后再分别验证 binding、installation、scope、GUI/声音和可逆 Disconnect。
任一事件通过都不能把 WorkBuddy 状态提前写成 5/5。
