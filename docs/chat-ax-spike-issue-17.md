# ChatGPT Chat AX Spike 结果（Issue #17）

状态：**技术 no-go，AX Beta 保持 unavailable**。

本记录只保存脱敏版本身份、逐次结果、计数与复现步骤。未保存 prompt、response、会话标题、
完整 UI tree、原始 AX identifier、进程地址或调试日志。

## 执行边界

- 执行日期：2026-08-24（Asia/Singapore）。
- 代码基线：`efe382d8998467895ca2ac7a6f372664db0eb59b`。
- Issue #16 已关闭，Issue #17 的 `blocked_by` 为 0 后才继续。
- 已取得仅覆盖 Issue #17 隔离 AX observer 的单独明确授权；Accessibility 由用户手动授予。
- 未自动点击系统设置、未控制 ChatGPT UI、未建立全局键盘监听，也未使用 OCR、按钮文案、
  正文、剪贴板或计时器补洞。
- tracer 使用独立 `DEBUG`、GUI-only、本地 ad-hoc bundle；普通产品与 AX Beta 状态未改变。

## 精确版本身份

| 字段 | 结果 |
|---|---|
| ChatGPT app | `/Applications/ChatGPT.app` |
| Bundle / signing identifier | `com.openai.codex` / `com.openai.codex` |
| Short Version / build | `26.818.31338` / `6892` |
| Team / CDHash | `2DC432GLL2` / `38611f3ab7750b1422775c93d5219a9c247a7d13` |
| App 签名 | Developer ID Application；磁盘严格验证通过；notarization ticket 已 staple |
| Framework | `Codex Framework.framework` `151.0.7922.170` / `7922.170` |
| Framework | `Sparkle.framework` `2.9.1` / `2054` |
| ChatGPT Mach-O | thin `arm64` |
| macOS / build | `26.6.2` / `25G83` |
| CPU | Apple M1 / `arm64` |
| tracer bundle | `com.claudio.app.axspike`；ad-hoc；CDHash `27db96370baf8ef8b0b0888e8e7641a291c00e53` |
| Accessibility | 用户手动授予；tracer 进程内 `AXIsProcessTrusted()` 为 true |

执行前后重新核对 ChatGPT Short Version、build、signing identifier、Team 与 CDHash，均未漂移。

## 允许读取与明确未读取

Surface identity preflight 只允许以下结构事实：

- 关系：`AXFocusedWindow`、`AXFocusedUIElement`、`AXParent`；
- 属性：`AXRole`、`AXSubrole`、`AXIdentifier`、`AXWindowNumber`；
- 非 AX 身份：bundle、签名、Short Version、build、framework、CPU 架构。

未请求或序列化 `AXValue`、文本内容、help、description、title、children、prompt、response、
会话标题或剪贴板。原始 `AXIdentifier` 只允许参与内存中的 surface digest 计算；本次连稳定
anchor facts 都未形成，因此没有生成或保存 surface signature。

## Fail-closed preflight 矩阵

预期：普通 Chat surface 在精确版本身份下形成两次一致的 focused-window lineage 与 anchor facts，
随后才能生成 surface signature、建立 exact allowlist 并启动 observer。

| 尝试 | Expected | Observed | Observer 生命周期 | 禁止属性 | 结果 |
|---:|---|---|---|---|---|
| 1 | stable anchor facts | `readAnchorFacts -> nil` | `never_started` | 未触及 | `fail_closed` |
| 2 | stable anchor facts | `readAnchorFacts -> nil` | `never_started` | 未触及 | `fail_closed` |
| 3 | stable anchor facts | `readAnchorFacts -> nil` | `never_started` | 未触及 | `fail_closed` |
| 4 | stable anchor facts | `readAnchorFacts -> nil` | `never_started` | 未触及 | `fail_closed` |
| 5 | stable anchor facts | `readAnchorFacts -> nil` | `never_started` | 未触及 | `fail_closed` |
| 6 | stable anchor facts | `readAnchorFacts -> nil` | `never_started` | 未触及 | `fail_closed` |
| 7 | stable anchor facts | `readAnchorFacts -> nil` | `never_started` | 未触及 | `fail_closed` |
| 8 | stable anchor facts | `readAnchorFacts -> nil` | `never_started` | 未触及 | `fail_closed` |
| 9 | stable anchor facts | `readAnchorFacts -> nil` | `never_started` | 未触及 | `fail_closed` |
| 10 | stable anchor facts | `readAnchorFacts -> nil` | `never_started` | 未触及 | `fail_closed` |

汇总：10 次尝试、0 个 stable identity、0 个 surface signature、0 次 observer start、0 个结构
signal、0 个 semantic event、0 次内容读取、0 个持久化原始日志。由于 observer 从未启动，
false positive、duplicate 与 submit/end 漏报率均为 `not_evaluated`，不能记作通过。

## 未执行场景

普通提交、流式结束、Stop、空或失败响应、切换会话、重开 app、前后台、多窗口、Codex view
负控和长响应均为 `not_evaluated`。这是 identity 前置门连续 10 次失败后的规定停止结果，不是遗漏后
补零；继续执行这些场景无法产生受 allowlist 约束的证据，反而会越过 fail-closed 契约。

## 复现步骤

1. 核对上表中的 ChatGPT、framework、macOS、CPU 与 tracer identity，任一不匹配即停止。
2. 用户手动授予 tracer Accessibility，并手动打开普通 Chat surface；不由工具控制 UI。
3. 仅向 `ChatAXDebugLaunchRequest` 提供 enable、scenario 与当前精确身份；surface signature 使用不在
   allowlist 中的 sentinel，仅用于进入 identity discovery，不能授权 observer。
4. 在 `SystemChatAXSurfaceSignatureReader.readAnchorFacts` 的 success/fail 返回点观察控制流，不输出
   anchor 字段。当前版本稳定到达 fail 返回点，从未到达 success 返回点。
5. 每次退出本地 tracer 后重新执行，共 10 次；确认 ChatGPT 身份未漂移且 observer 未启动。

## 结论

当前 `26.818.31338` / `6892` ChatGPT 安装无法在既定、无正文的结构白名单内形成可 allowlist 的
稳定 Chat surface identity。Issue #17 因此得到可复现技术 no-go；不扩大读取面，不建立生产 adapter，
不启用声音、Current Activation 或普通用户开关，也不创建生产化规格。AX Beta 继续保持 unavailable。
