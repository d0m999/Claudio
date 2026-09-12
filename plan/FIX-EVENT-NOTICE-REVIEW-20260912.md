# 事件来源提示条 Review 修复：规格与 Ticket 拆分

日期：2026-09-12（Asia/Singapore）。基线：`main@edb7b7e`（review 对象即 HEAD 提交本身，`edb7b7e^...edb7b7e`）。
来源：本会话最近一次 code review（Standards 轴 9 项 judgement calls + Spec 轴 15 项 findings）。
原始 spec：`plan/PLAN-EVENT-SOURCE-PROMPTS.md`（下称 SPEC，行号指该文件）。

## 1. 逐条核实结果与最小修复

### Spec 轴（行为缺口 / 错误实现）

**F1「有 N 条新提示」显式刷新缺失（SPEC L163）— 确认。**
根因：`EventNoticeModel.refreshRecent()`（EventNoticeModel.swift:343）已实现但无任何 View 调用。
最小修复：`EventNoticeView` 展开状态下当 `snapshot.pendingCount > 0` 时显示刷新按钮，调用 `model.refreshRecent()`；新 l10n key `event-notice.new-notices`（"有 %lld 条新提示" / "%lld new"）。
测试 seam：`EventNoticePresentationSuite` 断言投影逻辑；模型行为已有 EventNoticeModelSuite:182 覆盖。
验收：`swift run --package-path gui claudio-gui-tests`。

**F2 发生时间从不展示（SPEC L133）— 确认。**
根因：`EventNoticeRecord.occurredAt` 仅进模型，`EventNoticeView` 未渲染。
最小修复：展开详情区增加"发生时间"行，`Date.formatted(date: .omitted, time: .shortened)` + 语言 locale（macOS 12 FormatStyle 可用）。新 key `event-notice.occurred-at`。
测试 seam：文本投影提取后由 presentation suite 断言。
验收：同上。

**F3 保留范围文案缺失（SPEC L125）— 确认。**
根因：xcstrings 中无 `本次运行收到的近期提示` / `仅保留最近 50 条`；`droppedCount` 已计算未渲染。
最小修复：展开列表底部加说明行；`droppedCount > 0` 时加溢出说明。新 keys `event-notice.recent-disclaimer`、`event-notice.recent-overflow`。
测试 seam：presentation suite + `jq empty` xcstrings + `allKnown` 注册。
验收：同上 + `jq empty gui/Sources/ClaudioLocalization/Resources/Localizable.xcstrings`。

**F4 receiver 健康状态不上报（SPEC L279）— 确认。**
根因：`EventNoticeRuntime.startReceiver()` catch 后静默吞错（EventNoticeWindowController.swift:312）。
最小修复：ClaudioGUICore 新增 `EventNoticeHealthStore: ObservableObject`（`.ready / .unavailable(code:)`，只存脱敏枚举码）；runtime 在 start/stop/setEnabled 时更新；`SettingsPresentationDependencies` 注入该 store，通知页在 toggle 下方显示不可用状态。
测试 seam：新 suite 断言 store 状态迁移；settings 展示由 wiring/投影测试守边界。
验收：`swift run --package-path gui claudio-gui-tests`。

**F5 G5 presentation suite 与 G8 验收台账缺失（SPEC L246/L249）— 确认。**
最小修复：新建 `gui/Tests/ClaudioGUICoreTests/EventNoticePresentationSuite.swift`（测试提取出的文本/布局投影，导入 ClaudioGUIComponents）；新建 `docs/event-source-prompts-acceptance.md`，逐条记录门禁状态，原生/真机项如实标"未验证"。注册进 gui test main。
验收：harness 绿 + 文件存在。

**F6 gallery 无路由模拟成功/失败（SPEC S8, L21）— 确认。**
根因：`EventNoticeGalleryFrame` 硬编码 `onCopySessionID: { _ in false }`，从不触碰 `SessionNavigationCoordinator`。
最小修复：gallery frame 注入 DEBUG `SessionNavigationCoordinator`（navigate 闭包按按钮返回 .succeeded/.failed），加 "Route OK"/"Route Fail" 控件并显示 result；`onCopySessionID` 改为 `coordinator.markCopied(); return true`。同时给 coordinator 一个真实（DEBUG）调用方，连带消除 S4。
测试 seam：SessionNavigationSuite 已有 coordinator 行为覆盖；gallery 为 DEBUG-only。
验收：`swift build -c debug --package-path gui --product ClaudioGUI`。

**F7 设置与顶部列表不互斥（SPEC L135）— 确认。**
根因：`presentSettings` 不收起提示窗；提示窗交互打开时 settings 窗口保持。
最小修复：① MenuBarController.presentSettings 先调 `eventNoticeWindowController.close()`；② `SettingsWindowController` 新增 `closeForMutualExclusion()`（置 nil focusRestoration 后 close，避免触发 popover 重开抢夺焦点）；③ `EventNoticeWindowController` 增加注入的 `onWillBecomeInteractive`，MenuBarController 将其接到 settings 的互斥关闭。
测试 seam：`ViewWiringSuite` 只守 composition 边界（AGENTS 允许）。
验收：harness 绿 + build。

**F8 关闭无焦点归还（SPEC L135）— 确认。**
根因：`EventNoticeWindowController.close()` 只 dismiss 模型。
最小修复：注入 `handbackFocusOnClose` 闭包（MenuBarController 实现：popover 显示中则 popover 窗口 makeKey + `focusCoordinator.requestFocus(.recentNotices)`；否则归还 `previousApp`）。仅在 `isInteractive && window.isKeyWindow && NSApp.isActive` 时调用（focus ownership 未被用户转移）。
验收：build；原生焦点行为标"未验证"入台账。

**F9 Release 尺寸门禁上调无 spec 授权 — 确认（事实），处置见下。**
`scripts/check-release-size.sh` 5,500,000 → 5,600,000。本功能确实新增大量 GUI 代码。处置：实施末期以 Release 构建实测 GUI 二进制；若 >5.5MB 则保留新基线并在验收台账记录决定与证据；若 ≤5.5MB 则回退门禁与配套文档。
验收：`bash scripts/check-release-size.sh`（若有 dist）或实测 `.build/release/ClaudioGUI` 尺寸。

**F10 session label 在 helper 侧硬编码英文（SPEC L109）— 确认。**
根因：`HostEventSource.swift:267` 生成 `"session · \(prefix)"` 并随 IPC 传输，GUI 无法本地化；gallery fixture 同样硬编码。
最小修复：parser 与 gallery fixture 不再生成默认 sessionLabel（留 nil，保留字段供未来可信标题）；GUI 投影在 `sessionLabel == nil && sessionID != nil` 时生成本地化"会话 · <短ID>"。新 key `event-notice.session-short`（"会话 · %@" / "Session · %@"）。
测试 seam：HostEventSourceSuite 更新断言（sessionLabel 为 nil）；presentation suite 断言双语投影。
验收：两包 harness。

**F11 未考虑刘海 safeAreaInsets（SPEC L131）— 确认。**
根因：`positionWindow()` 只用 `visibleFrame.maxY - 12`。
最小修复：ClaudioGUIComponents 新增纯函数 `EventNoticePlacement.topAnchorY(visibleFrame:screenFrame:safeAreaTop:height:)`：`visible.maxY - 12 - height - max(0, safeAreaTop - (frame.maxY - visible.maxY))`；controller 使用 `screen.safeAreaInsets.top`。
测试 seam：EventNoticePresentationSuite 断言刘海/普通屏/菜单栏隐藏三态。
验收：harness 绿。

**F12 相同时间排序不稳定（SPEC L125）— 确认。**
根因：`visibleEntries()` 用 Swift `sorted`（非稳定）仅按 expiresAt。
最小修复：`Entry` 增加 `arrivalOrdinal: UInt64`（模型内递增计数器），比较器改为 `(expiresAt, arrivalOrdinal)` 双键降序——全序、确定、不依赖排序稳定性。
测试 seam：EventNoticeModelSuite 新增同 expiresAt 双条断言次序。
验收：harness 绿。

**F13 发送失败无固定诊断码（SPEC L278）— 确认。**
根因：`HostHookRunner.swift:192` `_ = eventNoticeSender(notice)` 丢弃结果。
最小修复：`if case .dropped(let failure) = …` 时 `appendLogLine(event:reason:"事件提示发送失败（\(failure.rawValue)）"…)`——复用既有脱敏日志路径，不输出 payload。
测试 seam：HostHookRunnerSuite 注入返回 `.dropped(.wouldBlock)` 的 sender + 临时 logFile，断言日志含 `would_block` 且原链路不变。
验收：`swift run --package-path helper claudio-tests`。

**F14 焦点序分支位置错误（SPEC L327/T6）— 确认。**
根因：`PanelFocusOrder.swift:89` operational 分支为 `[.soundScope, .recentNotices]`；视觉顺序中近期入口在 header（settings 旁、sound scope 之上）。
最小修复：改为 `[.recentNotices, .soundScope]`；同步 PanelFocusOrderSuite 三处期望。
验收：harness 绿。

### Standards 轴（judgement calls）

**F15 sanitize/displayBytes 重复（Duplicated Code）— 确认。**
`containsUnsafeScalar` 两处（HostEventSource.swift:97、352）；`sourceDisplayBytes` 两处（:346、:550）；折叠前导在 sanitizeIdentifier/sanitizeLabel 重复。
最小修复：单一 `HostEventSource.containsUnsafeScalar`（internal）与 `HostEventSource.displayBytes(of:)`；提取 `normalizeWhitespace` 共用前导。
验收：helper harness。

**F16 sourcePayload/receiverEpoch/eventNoticeSender 三件套（Data Clumps）— 确认。**
最小修复：新增 `public struct HostEventNoticeChannel { sourcePayload, receiverEpoch, sender }`，`HostHookEnvironment` 与 `systemHostHookEnvironment` 改收单参数；Subcommands 组装；更新受影响测试。
验收：helper harness。

**F17 Middle Man ×2 — 确认。**
`EventNoticeWindowActionRouter` 仅转发 3 个动作；`EventNoticeModel.receive(_:)` 无调用方。
最小修复：删除 router，contentView 移到 `super.init()` 之后以 `[weak self]` 直连；删除 `receive`。
验收：两包 harness + build。

**F18 SessionNavigationCoordinator 无生产调用方（Speculative Generality）— 确认，但按 SPEC D5/4A 不得删除。**
处置：F6 的 gallery 接线使其获得 DEBUG 真实调用方，满足 spec 的模拟入口；不新增生产承诺。
验收：build。

**F19 命名不当 ×3（Mysterious Name）— 确认。**
`suspendForPower/resumeAfterPower` 同时服务锁屏（MenuBarController:419-432）→ `suspendForSystemPrivacy/resumeAfterSystemPrivacy`；`descriptorFD`（EventNoticeTransport.swift:81，实为 socket）→ `socketFD`；`screenForFirstNotice()` 实读鼠标 → `screenUnderPointer()`（行为符合 SPEC L131"指针所在显示器"，仅改名）。
验收：两包 harness + build。

**F20 EventNoticeWindowController.swift 四类同居（Divergent Change）— 确认。**
最小修复：`EventNoticeIngress` → 新 `EventNoticeIngress.swift`；`EventNoticeRuntime` → 新 `EventNoticeRuntime.swift`；窗口文件只留 controller。
验收：build + harness。

**F21 dynamicQuietIsActive Feature Envy — 确认。**
最小修复：`DynamicQuietPresentation` 增加 `var suppressesAutomaticPresentations: Bool`（按 currentReason 三态），MenuBarController 两处改用并删除自由函数。
验收：gui harness。

**F22 FileLock O_NOFOLLOW|O_CLOEXEC 越界改动 — 确认，但予以保留。**
依据：SPEC L119 要求 endpoint ownership/mode/no-follow 检查复用 bounded-file/lock 模式；receiver 的 owner lock 正走 FileLock，此硬化与本功能安全边界同向且已有 AtomicWriteSuite 覆盖。记入台账，不回退。
验收：helper harness（既有覆盖）。

**F23 spec 文件未跟踪 — 确认，无法在本流程内解决。**
`plan/PLAN-EVENT-SOURCE-PROMPTS.md` untracked；本流程未获 commit 授权。列入最终报告，建议用户授权后提交。

## 2. Tickets（依赖序）

| # | 内容 | Findings | 依赖 |
|---|---|---|---|
| K1 | helper：sanitize 去重、HostEventNoticeChannel、F13 诊断码、F10 parser 去默认 label | F15 F16 F13 F10(helper) | — |
| K2 | 模型：稳定排序、删 receive | F12 F17a | — |
| K3 | l10n keys + 文本投影提取 + View 接线（刷新/时间/保留文案/本地化短标签） | F1 F2 F3 F10(GUI) | K1 K2 |
| K4 | DynamicQuietPresentation.suppressesAutomaticPresentations | F21 | — |
| K5 | GUI 文件拆分、router 删除、改名、safe-area 布局投影 | F17b F19 F20 F11 | K3 |
| K6 | receiver health store + 设置页展示 | F4 | K5 |
| K7 | 焦点序修正 + suite | F14 | — |
| K8 | 互斥显示 + 焦点归还 | F7 F8 | K5 |
| K9 | gallery 路由模拟 | F6 F18 | K3 |
| K10 | EventNoticePresentationSuite + 验收台账 | F5 F22(记录) | K3 K5 |
| K11 | 尺寸门禁实测与处置 | F9 | 全部代码 |

每个 ticket 独立可验收：K1/K2/K4/K7 各自 harness；K3/K5/K6/K8/K9 gui harness + build；K10 harness + 文件检查；K11 release build 实测。

## 3. 全局验收命令

```bash
swift run --package-path helper claudio-tests
swift run --package-path gui claudio-gui-tests
swift build -c debug --package-path gui --product ClaudioGUI
jq empty gui/Sources/ClaudioLocalization/Resources/Localizable.xcstrings
git diff --check
```

不做：commit/push/release；原生焦点、VoiceOver、IME、多屏、真实 hook 端到端保持"未验证"并写入台账。
