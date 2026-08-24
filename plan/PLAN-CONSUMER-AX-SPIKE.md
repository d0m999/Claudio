# PLAN — ChatGPT Chat Accessibility 只读可行性 Spike

> 状态：**隔离 tracer 工具完成；真实证据门未开启；未授权执行 #17**
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

这些结果只证明工具边界和候选检测器可执行，不证明当前 ChatGPT 安装可行。Issue #17 的真实场景矩阵
尚未执行，当前没有 Accessibility 授权、真实 observer receipt、pass 或 no-go 结论；AX Beta 继续保持
unavailable。

## 1. 问题与最窄范围

只回答一个问题：在精确版本的 ChatGPT Desktop 普通 Chat surface 中，能否仅使用结构/状态信号，
可靠识别“用户提交开始”和“生成结束”，且不读取 prompt/response 正文。首个 spike 不覆盖 Work、
Codex view、Claude Desktop、错误、通知、授权请求、subagent 或任何生产开关。

## 2. Issue #17 授权后才能执行的步骤

1. 记录 app bundle ID、签名、Short Version、build、Web/AX framework 版本和 CPU 架构。
2. 用户手动授予 Accessibility；claudi0 不绕过系统提示，不自动点击宿主。
3. 只读枚举角色、identifier、enabled/selected/value type 与结构变化；禁止读取或记录文本值。
4. 建立版本 allowlist；版本、签名、surface 或必要结构不匹配立即 fail closed。
5. 对每个候选信号重复至少 10 次，并在重开窗口、切会话、取消、网络失败和多窗口下验证。

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

## 4. Spike 产物

- 精确版本/签名矩阵与场景逐次结果；
- 允许使用的 AX 属性白名单和确认未读取的属性清单；
- false-positive/duplicate 统计与重现步骤；
- 是否值得另开生产实现计划的明确结论。

Spike 通过也不等于生产授权。生产化必须另行决定权限 UX、版本更新策略、receipt scope、后台生命周期、
隐私说明、GUI-only adapter 边界和失效/回滚方案。
