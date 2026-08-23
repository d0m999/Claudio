# PLAN — 普通用户 AI 终端兼容（非 TTS）路线图

> 状态：**WorkBuddy 本地实现完成；真实宿主验收与 AX spike 未执行**
>
> 更新：2026-08-23
>
> 本文件是路线图与证据索引，不再混合正式 adapter 实现和 AX 探索。

## 1. 已选择的交付顺序

1. 先交付 WorkBuddy 正式 command-hook adapter、动态宿主/事件绑定模型、surface 声音配置与诚实 UI。
2. 取得真实 WorkBuddy 回执，完成独立的运行时验收。
3. 只有重新获得明确授权后，才执行 ChatGPT Chat 的只读 Accessibility 可行性 spike。
4. AX spike 达到版本矩阵和零误报门槛后，另开生产计划；本路线图不授权 AX 监听或权限申请。

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
- helper 与 GUI 的依赖无关测试、本地 GUI product build 和 localization JSON 必须作为本地代码证据。

## 4. 尚不能宣称完成的证据

- 尚未写入真实 `~/.workbuddy/settings.json`，也未取得当前 WorkBuddy 版本的真实 callback receipt。
- 未做签名发行包、Intel/Apple Silicon 双架构或外部正式验收。
- 未申请 Accessibility 权限、未启动 AX observer、未读取任何 ChatGPT UI 树。
- HTML/SVG 是设计基线，不等于 SwiftUI 视觉验收；正式视觉批准仍需人工检查真实 app。

本地代码完成、真实宿主激活、发布和正式验收是四个独立状态，任何一个不能替代另一个。
