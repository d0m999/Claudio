# PLAN — ChatGPT Chat Accessibility 只读可行性 Spike

> 状态：**Issue #17 已执行并得到可复现技术 no-go；AX Beta 保持 unavailable**
>
> 更新：2026-08-24
>
> 本计划不授权申请 Accessibility 权限、启动 observer、读取 UI 树或修改任何宿主配置。

## 0. 工具与真实证据的边界

Issue #16 已完成与生产 adapter 隔离的 `DEBUG`、GUI-only tracer：普通启动、后台启动和自动化
harness 不会隐式启动 observer；显式启动仍需场景编号、精确版本 allowlist 和启用标志三项同时存在。
allowlist 绑定 bundle、签名、版本/build、framework、CPU 与经允许结构事实验证的 Chat surface；typed
属性白名单、同一 surface lineage、observer 生命周期、submit/end detector 和受限 evidence schema 均有
脱敏 fixture 回归。

Issue #17 已在单独明确授权和用户手动授予 Accessibility 后执行。当前 ChatGPT
`26.818.31338` / `6892` 连续 10 次无法形成稳定 surface anchor facts，因而没有生成 allowlist
signature，也没有启动 observer。后续场景按 fail-closed 条款停止，结论为技术 no-go；完整脱敏记录见
[ChatGPT Chat AX Spike 结果](../docs/chat-ax-spike-issue-17.md)。AX Beta 继续保持 unavailable。

## 1. 问题与最窄范围

只回答一个问题：在精确版本的 ChatGPT Desktop 普通 Chat surface 中，能否仅使用结构/状态信号，
可靠识别“用户提交开始”和“生成结束”，且不读取 prompt/response 正文。首个 spike 不覆盖 Work、
Codex view、Claude Desktop、错误、通知、授权请求、subagent 或任何生产开关。

## 2. Issue #17 执行流程与停止点

1. 记录 app bundle ID、签名、Short Version、build、Web/AX framework 版本和 CPU 架构。
2. 用户手动授予 Accessibility；claudi0 不绕过系统提示，不自动点击宿主。
3. 若 identity 前置门通过，才只读枚举角色、identifier、enabled/selected/value type 与结构变化；
   本次未到达该阶段，且始终禁止读取或记录文本值。
4. 若形成 stable identity，才建立版本 allowlist；本次未形成 surface signature，未建立 allowlist。
5. identity 前置门连续 10 次失败后按规定停止；没有越过门槛执行后续真实场景。

## 3. 场景矩阵与门槛

至少覆盖：普通提交、流式结束、Stop、空/失败响应、切换会话、重开 app、前后台切换、多窗口、
Codex view 负控、长响应。每个场景至少 10 次；通过门槛为：

- 已标注提交/结束均被识别；
- 零 false positive；
- 零 duplicate；
- 不读取/持久化 prompt、response、会话标题或剪贴板；
- 不建立全局键盘监听；
- observer 只在 claudi0 GUI 存活、用户显式启用且版本 allowlist 命中时运行。

任一门槛失败即停止，不通过猜测按钮文案、计时器或读取正文补洞。

本次在场景动作开始前即命中该停止条件：10/10 次 `readAnchorFacts` 返回 `nil`，observer 启动次数为
0。普通提交、流式结束、Stop、空或失败响应、切换会话、重开 app、前后台、多窗口、Codex view
负控和长响应均诚实记录为 `not_evaluated`，不把未执行项记作通过。

## 4. Spike 产物

- 精确版本/签名矩阵与场景逐次结果；
- 允许使用的 AX 属性白名单和确认未读取的属性清单；
- false-positive/duplicate 统计与重现步骤；
- 是否值得另开生产实现计划的明确结论。

Issue #17 的以上产物已记录在
[docs/chat-ax-spike-issue-17.md](../docs/chat-ax-spike-issue-17.md)；结论为 no-go，不另开生产规格。

Spike 通过也不等于生产授权。生产化必须另行决定权限 UX、版本更新策略、receipt scope、后台生命周期、
隐私说明、GUI-only adapter 边界和失效/回滚方案。
