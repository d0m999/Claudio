# PLAN — WorkBuddy 正式集成与 surface 声音配置

> 状态：**2/5 真实 WorkBuddy callback 闭环已完成并 Disconnect；Current Activation 为 none**
>
> 更新：2026-08-24
>
> 不授权 commit、push、发布或修改真实 `~/.workbuddy/settings.json`。

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

- popup：当前 surface 摘要、Global/Surface scope、pack、事件静音、试听和 reset；不显示全局假 `3/5`。
- Apps/集成窗口：按 Product → Surface 分组展示连接、scope/version 失效、binding 状态、
  latest receipt、Repair、Disconnect、回执历史清除；只列三个产品可见 native surface。
- Events：声音/pack/静音/试听；只列配置或可用 surface；AX 未生产化前完全隐藏。
- 视觉遵循原生 macOS 信息层级；HTML 为交互主原型，SVG 为只读快照，SwiftUI 视觉批准另行验收。

## 4. 本地验收

- helper 测试覆盖 transform 幂等、未知字段、第三方 hook、错位/冲突、两条 binding、版本 scope、
  disconnect、surface 解析/写入、回执历史边界与 doctor 三行。
- GUI 测试覆盖动态三 surface 矩阵与 Product → Surface 分组、WorkBuddy 2/5、AX 不进入普通 UI、
  历史 AX token 可解码、surface effective profile、定向写、reset、全局音量、本地化、焦点与
  destructive confirmation 接线；既有 AX tracer 隔离测试继续执行。
- 必须通过：

```bash
swift run --package-path helper claudio-tests
swift run --package-path gui claudio-gui-tests
swift build -c debug --package-path gui --product ClaudioGUI
jq empty gui/Sources/ClaudioLocalization/Resources/Localizable.xcstrings
git diff --check
```

## 5. 真实验收结果（Issue #15）

2026-08-24 在单独授权下已完成可逆 Connect → callback → GUI 核对 → Disconnect：

- `UserPromptSubmit → task_start` 与 `Stop → stop` 均产生 schema 2、匹配当前
  binding/installation/scope 的真实回执；声音结果因有效配置继承全局静音而均为 `muted`。
- GUI 人工核对确认 WorkBuddy 为 2/5；`StopFailure`、`Notification`、`SubagentStop` 始终为
  `notImplemented`，没有用接口声明伪造实现。
- Disconnect 后自有 hooks 与 active installation marker 已移除，Current Activation 为 `none`；
  第三方 hooks、未知字段、声音偏好、备份和脱敏历史按契约保留。
- 本闭环是历史真实宿主证据，不是当前激活、RC、发布或正式验收。

完整脱敏证据与时间线只记录在
[0.1.0 验收账本](../docs/release-acceptance-0.1.0.md#workbuddy-真实回调闭环issue-15)。

## 6. 剩余三个事件的 evidence-first 门

`StopFailure`、`Notification`、`SubagentStop` 必须分别创建独立计划/Issue。每项在实现前都要取得
当前 WorkBuddy 版本的可重复触发证据、最小且不含用户内容的 callback contract、负向/重复触发结果和
fail-closed 停止条件；实现后再分别验证 binding、installation、scope、GUI/声音和可逆 Disconnect。
任一事件通过都不能把 WorkBuddy 状态提前写成 5/5。
