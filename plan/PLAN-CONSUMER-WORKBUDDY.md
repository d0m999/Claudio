# PLAN — WorkBuddy 正式集成与 surface 声音配置

> 状态：**本地实现完成，真实 WorkBuddy 回执验收待执行**
>
> 更新：2026-08-23
>
> 不授权 commit、push、发布或修改真实 `~/.workbuddy/settings.json`。

## 1. 用户结果

- Apps/集成窗口永久列出 Claude Code、Codex、WorkBuddy 三个稳定 adapter；未安装不等于消失。
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

### 2.3 回执与失效

- current evidence 必须同时匹配 schema、installation、host/surface、`HostEventBindingID`、原生事件
  和公共事件。
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
- Apps/集成窗口：连接、授权、scope/version 失效、binding 状态、latest receipt、Repair、Disconnect、
  回执历史清除。
- Events：声音/pack/静音/试听；只列配置或可用 surface；AX 未生产化前完全隐藏。
- 视觉遵循原生 macOS 信息层级；HTML 为交互主原型，SVG 为只读快照，SwiftUI 视觉批准另行验收。

## 4. 本地验收

- helper 测试覆盖 transform 幂等、未知字段、第三方 hook、错位/冲突、两条 binding、版本 scope、
  disconnect、surface 解析/写入、回执历史边界与 doctor 三行。
- GUI 测试覆盖动态三宿主矩阵、WorkBuddy 2/5、surface effective profile、定向写、reset、全局音量、
  本地化、焦点与 destructive confirmation 接线。
- 必须通过：

```bash
swift run --package-path helper claudio-tests
swift run --package-path gui claudio-gui-tests
swift build -c debug --package-path gui --product ClaudioGUI
jq empty gui/Sources/ClaudioLocalization/Resources/Localizable.xcstrings
git diff --check
```

## 5. 真实验收（尚未授权/执行）

在单独授权后，记录 WorkBuddy/Claudio 精确版本，备份真实配置，显式 Connect，分别触发
`UserPromptSubmit` 与 `Stop`，验证两条 current-binding receipt、声音结果、doctor 和 UI；再 Disconnect
并验证第三方条目、未知配置、surface 偏好和历史保留。没有这份 receipt 前，只能称本地实现完成。
