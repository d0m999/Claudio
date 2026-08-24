# PLAN — 普通用户 AI 终端兼容（非 TTS）路线图

> 状态：**WorkBuddy 2/5 真实宿主闭环完成并已断开；Chat AX Issue #17 得到技术 no-go**
>
> 更新：2026-08-24
>
> 本文件是路线图与证据索引，不再混合正式 adapter 实现和 AX 探索。

## 1. 已选择的交付顺序

1. 已交付 WorkBuddy 正式 command-hook adapter、动态宿主/事件绑定模型、surface 声音配置与诚实 UI。
2. 已取得两条真实 WorkBuddy 回执，完成可逆 Connect → callback → GUI 核对 → Disconnect 验收。
3. ChatGPT Chat 的只读 Accessibility 可行性 spike 已在单独授权后执行，并在 identity 门失败关闭。
4. 当前技术 no-go 不满足生产计划门槛；本路线图不授权继续 AX 监听或权限申请。

## 2. 子计划

- [PLAN-CONSUMER-WORKBUDDY.md](PLAN-CONSUMER-WORKBUDDY.md)：正式 adapter、绑定、回执、
  surface 声音偏好、popup/集成窗口、doctor、测试与真实验收边界。
- [PLAN-CONSUMER-AX-SPIKE.md](PLAN-CONSUMER-AX-SPIKE.md)：ChatGPT Chat 首个只读 AX spike，
  版本签名、场景矩阵、隐私边界和停止条件。
- 描述式 TTS 不在本路线图内，见
  [PLAN-CONSUMER-TTS-EXECUTION.md](PLAN-CONSUMER-TTS-EXECUTION.md)。

## 3. 当前本地实现事实

- `HostProductID`、`HostSurfaceID`、descriptor、`HostEventBindingID` 与 implementation/qualifier
  已进入 Core；固定公共事件仍为五个。
- registry 现含 Claude Code、Codex、WorkBuddy 三个稳定 native-hook surface，以及归入 Claude / ChatGPT
  产品的两个 GUI-only AX Beta 不可用占位；完整窗口按 Product → Surface 分组，popup 不显示不可用占位。
- WorkBuddy 稳定展示五行，但首发只有 `UserPromptSubmit → task_start` 与 `Stop → stop` 两条已实现；
  `StopFailure`、`SubagentStop` 为接口支持但尚未实现，`Notification` 为部分支持且尚未实现。
- WorkBuddy 连接只外科式管理用户级 `~/.workbuddy/settings.json` 中属于当前 installation 的两条
  command hook；第三方条目和未知 JSON 保留。
- 三个 native adapter 的 activation 均按 installation、surface、binding 和 scope fingerprint 判定；
  宿主/Claudio 版本或绑定集合变化会使旧证据失效，显式 Repair 轮换 installation 后才发布新 scope。
- current receipt 使用 schema 2；schema 1 旧回执只保留为脱敏历史，不能合成当前 binding 或点亮 activation。
- 脱敏回执历史与 current activation 分离：每 surface 最多 20 条、保留 30 天、断开保留，
  集成窗口提供确认后清除动作。
- `surface_overrides` 对 pack/事件使用稀疏继承；损坏覆盖 fail closed；`master_volume` 仅全局。
- popup 只为已配置/可用来源提供声音 scope；完整窗口始终列出稳定 native surface 与 AX Beta 占位。
- ChatGPT Chat 隔离 tracer 已作为 `DEBUG`、GUI-only、默认关闭的工具进入代码；只有 GUI 存活、
  三项显式启动输入完整且精确 allowlist/surface identity 命中时才会启动 observer。脱敏 fixture 已走通
  observer → detector → 受限 evidence 路径；这仍不是授权后的真实 ChatGPT 场景证据。
- helper 与 GUI 的依赖无关测试、本地 GUI product build 和 localization JSON 必须作为本地代码证据。

## 4. 已完成与仍未完成的证据边界

- Issue #15 已在单独授权下完成真实 WorkBuddy 2/5 callback 闭环；Disconnect 后 Current Activation
  已清空，自有 hooks 已移除，第三方 hooks、未知字段、声音配置、备份与脱敏历史均按契约保留。
- 未做签名发行包、Intel/Apple Silicon 双架构或外部正式验收。
- Issue #17 已在单独授权和用户手动授予 Accessibility 后执行：当前 ChatGPT
  `26.818.31338` / `6892` 的 surface identity preflight 连续 10 次无法形成 stable anchor facts，
  observer 启动次数为 0，按 fail-closed 条款得到技术 no-go。其余真实场景为 `not_evaluated`，没有读取
  prompt、response、会话标题、剪贴板或完整 UI tree；见
  [脱敏结果](../docs/chat-ax-spike-issue-17.md)。
- HTML/SVG 是设计基线，不等于 SwiftUI 视觉验收；正式视觉批准仍需人工检查真实 app。

本地代码完成、一次真实宿主验收、当前激活、真实 AX 矩阵、发布和正式验收是独立状态，任何一个不能
替代另一个。
