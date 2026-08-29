# 统一设置集成验收与证据交接

本清单是九个设置目的页的维护门禁与人工交接入口。它不替代
`plan/PLAN-SETTINGS-EXPERIENCE.md`、`CONTEXT.md`、ADR 0005–0009 或 release 流程，也不把
fixture、源代码扫描、构建或 ad-hoc bundle 升格为原生 UI、真实系统、真实 Provider 或发布证据。

## 自动门禁

从仓库根目录传入实施前固定 commit：

```bash
bash scripts/verify-settings-experience.sh <BASE_SHA>
```

脚本确认 `<BASE_SHA>` 是 `HEAD` 的祖先且 working tree/index 没有 tracked 或 untracked 改动，然后执行：

- helper 与 GUI executable harness；
- GUI Debug build、localization JSON、开发 bundle 与 release-size 检查；
- working tree 和 `<BASE_SHA>...HEAD` 的 `git diff --check`；
- 全仓 `swift format lint --strict --recursive helper gui` 与基线快照的诊断差分；
- #102 所要求的 suite 都仍在两个手工注册的 executable harness 中。

基线和 `HEAD` 的 format 诊断按 `path:line:column:severity:rule` 精确比较。既有诊断会被报告为基线，
但任何新增诊断都会使门禁失败；这不表示既有诊断已经修复。

## 自动证据覆盖

| 合同 | 主要 executable suite |
|---|---|
| 九个 destination 恰好一次、production 无 placeholder、唯一 retained window、旧三窗口不挂载、声音写入 owner 唯一 | `SettingsNavigationSuite`、`SoundPacksEditorOwnerSuite`、`IntegrationsWindowWiringSuite` |
| Host Surface 能力、receipt/current activation、Sound Scope 与 Effective Profile | `HostIntegrationModelSuite`、`HostIntegrationPresentationSuite`、`HostHookReceiptSuite`、`SurfaceSoundPreferencesSuite` |
| allowlisted registry、route-derived capability、slot/policy 与逐 profile 隔离 | `AICueProviderContractsSuite`、`AICueCredentialSuite`、`AICueGenerationDispatcherSuite` |
| exact-origin 认证注入、redirect 拒绝、unary/SSE wire 与 decoded ceiling | `AICueHTTPTransportSuite`、`AICueSSETransportSuite`、`AICuePayloadDecodingSuite` |
| ElevenLabs legacy account、MiniMax hex MP3、Qwen SSE PCM→WAV | `AICueElevenLabsProviderSuite`、`AICueMiniMaxProviderSuite`、`QwenAICueProviderSuite` |
| Qwen 保存零请求、60 秒 deadline、3 候选、late-result cleanup 与 adoption rollback | `AICueCredentialSuite`、`AICueGenerationEngineSuite`、`AICueGenerationViewModelSuite`、`AICueAdoptionSuite` |
| Dynamic Quiet State、receipt retention 与手工试听正交 | `DynamicQuietStateSuite`、`DynamicQuietPolicySuite`、`HostHookRunnerSuite` |
| 每 Surface 20 条/30 天、诊断脱敏、独立清理与失败保留旧事实 | `UsageActivitySuite` |
| Carbon shortcut 注册、替换事务、冲突回滚与损坏持久化 fail closed | `GlobalShortcutsSuite` |
| 登录项状态、显示偏好、关于页脱敏摘要与双语 catalog | `LoginItemManagementSuite`、`DisplayPreferencesSuite`、`AboutInformationSuite`、`LocalizationSuite` |

这些 suite 使用受控 fixture，不会读取真实 API key、请求真实 Provider、修改真实 host、注册真实登录项，
或证明声音质量。若 suite 文件存在但从 `main.swift` 移除，总门禁会先在注册检查失败。

## 安全与隐私判据

自动回归必须保持以下边界：

- Provider/profile、origin/path、model、voice、region 与 credential slot 只能来自 allowlisted registry；
- 不允许跨 Provider/region fallback；认证只在 exact origin/path 校验后注入，redirect target 得到零请求；
- 真实 API Key、`Authorization`、完整 Sound Description、未经脱敏的 Provider response、个人声音包名与
  绝对路径不得进入 config、日志、receipt、manifest、诊断摘要、仓库 fixture 或交接材料；受控 sentinel
  只用于证明这些边界，并且必须明显不可能是真实 credential；
- 真实 smoke 只可在另行授权后使用可撤销限额 key；不得把 key、header、完整请求/响应或音频带入
  issue、Git、截图或日志。

## 原生设置窗口手工清单

以下各项必须绑定待验 bundle 的 commit、macOS、CPU、语言和 app 路径。未填写证据链接或观察记录时，
状态保持 `NOT VERIFIED`，不能因自动门禁通过而勾选。

| 项目 | 状态 | 必须记录 |
|---|---|---|
| 单一窗口与九页导航 | NOT VERIFIED | panel/deep link/页间路由、重复打开、关闭后 handback |
| 键盘与焦点 | NOT VERIFIED | Tab/Shift-Tab、方向键、Return/Space、Escape、焦点顺序 |
| VoiceOver | NOT VERIFIED | 九页标题、状态、错误、帮助、状态点关闭后的完整语义 |
| 四文字档与窗口尺寸 | NOT VERIFIED | 中文/英文 × 四档，1240×820、960×640、放大，无水平裁切 |
| 外观与动画 | NOT VERIFIED | light/dark、Increase Contrast、Reduce Transparency、Reduce Motion |
| profile 选择与披露 | NOT VERIFIED | 四 profile 各自供应商、地区、费用/配额、留存/模型改进边界 |
| credential 状态 | NOT VERIFIED | missing/verified/deferred/rejected/pending/unavailable 与替换/取消/删除 |
| 能力阻止 | NOT VERIFIED | MiniMax/Qwen 非 speech、unsupported locale 在读 key/联网前可见失败 |
| 生成到采用 | NOT VERIFIED | 显式生成、3 候选、试听、命名、采用、target drift 与失败回滚 |

## 真实系统、Provider 与发布交接

每行必须单独给证据；一行成功不能替代另一行。默认均为 `NOT RUN / NOT VERIFIED`。

| 门禁 | 默认状态 | 证据要求 |
|---|---|---|
| 签名 app 登录项 | NOT RUN / NOT VERIFIED | 注册、批准、注销、重新登录、移动 app 后状态 |
| Focus | NOT RUN / NOT VERIFIED | 首次授权、拒绝/撤销、开关、observer failure，且不记录名称 |
| Calendar | NOT RUN / NOT VERIFIED | 授权、busy/all-day/free/变更，且无标题/位置/参与人泄露 |
| Carbon hot key | NOT RUN / NOT VERIFIED | 冲突、布局变化、前后台、睡眠唤醒、注销 |
| 真实音频 | NOT RUN / NOT VERIFIED | `NSSound` 试听、主音量、Dynamic Quiet 只抑制 automatic |
| ElevenLabs | NOT RUN / NOT VERIFIED | 独立限额 key、read-only probe、生成/试听/采用与费用记录 |
| MiniMax global | NOT RUN / NOT VERIFIED | 独立限额 key、get-voice probe、hex MP3 生成/试听/采用 |
| Qwen Singapore | NOT RUN / NOT VERIFIED | 独立 region key、保存零请求、首次显式生成验证、SSE PCM→WAV |
| Qwen Beijing | NOT RUN / NOT VERIFIED | 独立 region key 与独立 smoke；不得复用 Singapore 结论 |
| Apple Silicon | NOT RUN / NOT VERIFIED | 目标架构的原生手验和产物身份 |
| Intel | NOT RUN / NOT VERIFIED | x86_64 原生手验和产物身份 |
| Developer ID 签名 | NOT RUN / NOT VERIFIED | identity、hardened runtime、嵌套签名与 Gatekeeper |
| notarization/staple | NOT RUN / NOT VERIFIED | Apple notarization 与 staple 结果 |
| release/正式验收 | NOT RUN / NOT VERIFIED | 授权 workflow、CI、交付物、checksum 与维护者签字 |

`scripts/dev-bundle.sh` 只生成当前架构的 ad-hoc-signed inspection bundle。它可以证明本机构建、资源
组成、ad-hoc codesign 结构与 per-architecture size gate；不能证明上表任一真实系统或 release 项。
