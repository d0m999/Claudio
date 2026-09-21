# claudi0 前端交互 / UX 审查（2026-09-18）

> **方法**：四路并行只读审查（异步与加载反馈 / 错误呈现与恢复路径 / 键盘可达性与 VoiceOver / UI 状态一致性），
> 全部 finding 经主审逐行复核：坐实的保留，复核后不成立的明确否定。
> **范围**：`gui/Sources/` 全部 SwiftUI 视图层与 view-model。基线 `main@ae40823`（工作树含未提交 WIP）。
> **证据等级**：逐条标注「已复核」（主审亲自读过 file:line）或「子代理报告，未独立复核」。
> 本文件不修改任何产品代码。

## 结论先行

`gui/` 的交互工程质量**远高于一般 2C 项目**。以下能力已核实就位（亲读确认），不要再重做：

- **焦点 handback**：`MenuBarController.swift:108-112` 用 `previousApp` 记账，`popoverDidClose`（:793-817）
  归还宿主 app，`NSApp.activate(ignoringOtherApps:)` 的取舍有逐条 API 证伪的推导注释（:534-565）。
- **in-flight 状态**：AI 生成有 `isBusy` + `generationTask` + 取消按钮 + deadline（`AICueGenerationViewModel`
  / `AICueGenerationEngine`）；onboarding 双 CTA 禁用 + 「正在接管…」label（`OnboardingView.swift:178-211`）。
- **无乐观 UI**：静音 / 音量 / 切包 / 星标全部「先写盘成功后重读投影」，失败不改 UI 值。
- **revision 竞态防护**：`SoundPackLibrary`（invalidation revision）、`EventNoticeModel`（三处）、
  `SoundPacksWindowModel`、`MenuBarController.hostIntegrationRefreshRevision` 均有守卫。
- **破坏性操作**：删除声音包 / 恢复出厂 / 断开宿主 / 清回执 / 删凭据全部有
  `.confirmationDialog` + `role: .destructive`。
- **动态效果**：`accessibilityReduceMotion` 几乎全覆盖；`FailureRow` 等关键组件用 `@ScaledMetric`。

真正剩下的缺口：**1 个 P0、2 个 P1、1 个 P2**，全部小改动且互相独立（交互轴，见上）。
**2026-09-18 第二轮补充**：另做了一轮「视觉一致性」轴审查（token / 字体 / 圆角 / 本地化），
发现 **1 个 P0、1 个 P1 + 1 批 P2 打磨项**，全部逐行复核带 file:line 证据，见文末「第二部分」。
**2026-09-18 用户复核拍板**：两轮结论已经用户逐条对照源码 / DESIGN.md / ADR 复核并拍板——
各项判断与现行执行顺序见文末「决策记录与执行顺序」（快捷键 P0 与 Dynamic Type 修法未采纳、
设置页 P0 降级为定向采纳、`.refreshFailed` 与 `surfaceSoundIssue` 升为优先修）。

---

## P0 · 全新安装没有任何键盘入口（推断链，未真机验证）

> **决策（2026-09-18 用户复核）**：**暂不按本条修法采纳。**「没有预设快捷键」属实，但「键盘 / VoiceOver
> 完全无法进入」是未经真机验证的推断：应用有带无障碍标签的菜单栏状态按钮（`MenuBarController.swift:317`），
> 且 PLAN-SETTINGS-EXPERIENCE.md:184 把全局快捷键定义为用户自行注册。先在全新安装环境走完整键盘、
> VoiceOver 入口；若确实不可达，再决定默认入口及冲突处理。本条原分析保留为决策依据。

**证据（已复核）**：

| 事实 | 位置 |
|---|---|
| 全局快捷键动作 `togglePanel` / `openSettings` / `openCurrentScopeEvents` 已定义 | `ClaudioGUICore/GlobalShortcuts.swift:5-7` |
| 全仓 **0 处** `register(defaults:)` / `userDefaults.register` 播种默认快捷键 | grep 全 `gui/Sources/` 零命中 |
| `restorePersistedRegistrations()` 只恢复 `persistence.read(action)` 非空的项 | `GlobalShortcuts.swift:486-514` |
| `MenuBarController.swift` 无任何 `keyEquivalent` / Carbon 默认注册 | grep 零命中 |
| `.appSettings`（⌘,）命令组被主动清空 | `ClaudioGUIApp.swift:29-31` |
| app 为 `.accessory`，无 Dock 图标 | `ClaudioGUIApp.swift:48-51` |

**后果**：首次安装后，键盘 / VoiceOver / 运动障碍用户没有任何键盘路径打开面板——到不了设置页，
也就永远配不出快捷键。死锁。

**修法**：app 启动时给三个 action 各播一个默认 Carbon 快捷键（如 ⌃⌥Space 打开面板），用户可在
Settings → 快捷键修改；已持久化的值不覆盖。半天工作量，独立 PR。

---

## P1 · Dynamic Type 布局降级被写死为「永不降级」

> **决策（2026-09-18 用户复核）**：**保留问题线索，不采纳现成修法。**布局固定为标准档属实
> （`PanelView.swift:855`），但现行 DESIGN.md:136 明确规定生产界面固定紧凑密度、系统缩放另行验收；
> 文档举的 `PackGalleryView` 截断例子也不是当前生产面板挂载路径。应先用原生界面复现具体裁切，
> 再设计必要的重排，并同步厘清旧注释与现行规范。

**证据（已复核）**：

- `ClaudioGUICore/PanelLayout.swift:27-29`：`panelLayoutAdaptation()` 无参数，恒返回全 `false` 的
  `PanelLayoutAdaptation`；`rowWrapsToTwoLines` / `eventActionsMoveBelow` / `hidesWaveform` 永不生效。
- `ClaudioPanelPresentation/PanelView.swift:857-862`：硬编码 `hidesWaveform: false, rowWrapsToTwoLines: false, eventActionsMoveBelow: false`。
- `SoundPacksWindowView.swift:1620-1622`：`layoutAdaptation: soundPacksWindowLayoutAdaptation(for: .standard)` 同样固定。
- 字号本身走 `@ScaledMetric`（`FailureRow` / `EventRowView` / `MasterVolumeRow` / `OnboardingView` 等
  9 个文件），**会**随系统文字大小放大；布局**不会**重排 → 大字档下正文折行 / 溢出 / 尾部截断。
- 注释仍在承诺降级：`MasterVolumeRow.swift:79-83`、`EventRowView.swift:93`、
  `PackGalleryView.swift:114-117`、`SoundPacksWindowAccessibility.swift:192-196`（"400% text scaling"）。
  ——又一次「措辞比覆盖范围大」，下一个人照注释承诺去用会失望。

**直接后果**：`PackGalleryView.swift:168-169` 包名 `.lineLimit(1).truncationMode(.tail)`、
`PanelView` 事件行操作叠加位恒定（`EventRowView.swift:131`），大字档被裁切。

**修法**：把 tier 接回 `@Environment(\.dynamicTypeSize)`，至少启用 `.accessibility` 档；
同时把四处过期注释改成实话。

---

## P1 · 主面板不呈现 `.refreshFailed`

> **决策（2026-09-18 用户复核）**：**直接采纳，优先修。**已亲读复核：`.refreshFailed` 走
> `EmptyView()`（`PanelView.swift:678-679`）而事件区继续渲染旧快照，违反 ADR 0002 的明确要求
> （「刷新失败且已有旧快照时……明确呈现『刷新失败，正在显示上次结果』与重试入口」）。保留内容，
> 在事件区加轻量提示和重试。

**证据（已复核）**：

- `PanelView.libraryUnavailableSection` 只对 `.loadFailed` 出 FailureRow + 重试；
  `.refreshFailed` 走 `EmptyView`（`.ready / .refreshing / .refreshFailed` 三态同分支）。
- `ProductUIModels.swift:45-51`：`.refreshFailed` 的 `hasUsableSnapshot == true`，事件区继续用陈旧快照渲染——
  不闪屏是对的，但用户**零提示**地看几秒前的旧状态。
- `SoundPacksWindowAccessibility.swift:390`（管理窗口）对 `.refreshFailed(reason:)` 是**有**呈现的——
  两处不一致。

**修法**：`.refreshFailed` 时在事件区顶部加一行轻量「刷新失败，显示的是上次结果 · 重试」，
不替换内容；口径照抄管理窗口那边的现成实现。

---

## P2 · 错误文案夹带内部细节

> **决策（2026-09-18 用户复核）**：**采纳问题，重写修法。**面板错误项（`PanelWriteFailures.swift:124`）
> 目前直接用 helper 的中文 `description`；应投影成中英双语、可操作的 UI 文案（typed reason 已存在，
> l10n 基建 838 条已就位）。恢复配置所需的路径不能一律藏进日志，应通过明确的恢复入口按需展示。

**证据（已复核）**：

- `SetEventEnabledError.description`（`helper/Sources/ClaudioCore/EventEnabled.swift:39-54`）是
  **手写的中文用户文案**，不是 Swift 反射——方向正确，不要按「22 处零本地化」理解。
- 但 `reason` 关联值仍带：
  - `errno N`：「无法获取文件锁（errno 35）」——对 2C 用户无意义（`MasterVolume.swift:76` 等）；
  - 绝对路径：`找不到声音包 "xxx"（~/.claudio/packs/xxx/ 不存在）`（`Use.swift:40`）、
    「外部版本保留于 /Users/.../recovery.json」（`ConfigFileTransaction.swift:79`）；
  - 英文 POSIX 描述（底层 reason 透传）。

**修法**：errno / 绝对路径 / POSIX 原文只进诊断日志（`doctor` / 活动诊断页），UI 侧按 typed
`PanelWriteFailureReason` 映射成人话 + 重试入口。typed reason 体系（`PanelWriteFailures.swift:40-49`）
已经存在，只差文案映射这一层。

---

## 复核后否定的误报（不要照抄进 issue）

| 误报 | 复核结论 |
|---|---|
| 「AI 生成只有不确定 spinner 且无取消」 | **不成立**。`EventSettingsAICueView.swift:392-408` 在 `.generating` 下同时有 `ProgressView` + `.aiCueGenerating` 文案 + 取消按钮，且 `.task {}` 把焦点自动移到取消；`cancelGenerationButton`（:436-452）含 FKA 关闭时的 `onKeyPress` 兜底。 |
| 「`PanelWriteFailures.swift:151` 的 `preconditionFailure` 是崩溃风险」 | **不可达**。`panelWriteFailureItems` 在每个写者入口都先 `!= .configMissing` 过滤（`PanelWriteFailures.swift:71/79`），panic 是防御性断言，不是 bug。 |
| 「`error.description` 是 Swift 反射、22 处零本地化」 | **夸大**。`CustomStringConvertible` 手写中文文案（`EventEnabled.swift:39-54` 等）；真正的问题是 reason 关联值里的 errno / 路径细节（见 P2）。 |

## 子代理报告、未独立复核的次要问题（列为待核对）

以下条目来自四路子代理，主审未逐行复核，使用前先验证 file:line：

1. `AICueGenerationViewModel.swift:412-444`：`.adopting` 阶段不可取消、无本地超时上限（对比 generation 有取消）。
2. ~~`PanelConfigController.swift:512-516`：`clearWriteFailures()` 清三个写者错误但**不清 `surfaceSoundIssue`**；~~
   **（2026-09-18 复核确认，提升为优先修复）**：已亲读——外部重读路径 `reloadConfigReadModel`
   （`PanelConfigController.swift:668`）重建全部 config 派生读模型但不清 `surfaceSoundIssue`；
   静音写成功、切包成功、重置覆盖成功和切换作用域是既有清除路径。该 issue 又禁止事件写入
   （`PanelView.swift:595` `configWritesAllowed: surfaceSoundIssue == nil`）。文末决策将自动清除收窄到
   有效读回确认已恢复的结构性覆盖损坏；写失败类不凭读回自动清除。
3. `PanelConfigController.swift:720-751`：面板消费库状态无 revision 校验（与窗口模型不对称，
   目前靠 `bufferingNewest(1)` + 单 actor 顺序兜底）。
4. `PanelView.swift:226-227` 与 `:271`：`headerAccessibilityLabel` 在根容器（`.contain`）与内部 header
   挂同一句 → VoiceOver 读两遍。
5. `MasterVolumeRow.swift:100-111`：说明文字整段 `accessibilityHidden(true)`，滑块无 hint。
6. `EventSettingsAICueView`：生成完成 / 失败 / 采用成功无 VoiceOver 播报（对照 `SettingsSoundsAICueView` 有播报）。
7. ~~`SoundPacksWindowModel.swift:580/1491`：`starredPacksError` 赋值后未在任何 View 渲染——疑似静默吞掉。~~
   **（2026-09-18 复核否定，不成立）**：失败经 `setWindowStatus(kind: .starredPacks, severity: .failure)`
   发布（`SoundPacksWindowModel.swift:1482-1499`），窗口 `windowStatusRegion` 渲染 `windowStatuses`
   （`SoundPacksWindowView.swift:692`）——用户可见层正确，不构成静默吞错。
8. `EventNoticeWindowController.swift:146-192`：事项通知自动出现全程无播报（是否补低优先级播报属产品决策）。
9. `AudioImportViewModel` / `DropZoneState`：导入无 `.importing` 态、无并发去重；目前**无生产调用点**
   （面板导入已迁 `SoundPacksWindow`），属公共 API 既有缺口 + 回归风险。

## 建议执行顺序

1. **P0** 默认快捷键播种（独立 PR，半天）。
2. **P1** Dynamic Type 布局接回环境档 + 四处过期注释改实话。
3. **P1** 主面板 `.refreshFailed` 呈现（照抄管理窗口现成口径）。
4. **P2** 错误文案：errno / 路径收进诊断，UI 走 typed reason 映射。
5. 待核对清单 2（`surfaceSoundIssue` 寿命）建议随 P2 一并处理。

---

# 第二部分 · 视觉一致性审查（2026-09-18 第二轮 · 已复核）

> **方法**：六组取证（字号直方图 / rounded 覆盖 / 圆角直方图 / hex 初始化器 / 系统色旁路 / 平台惯例）+
> 本地化完整性脚本 + 人工精读 PanelView、PanelSoundScopePicker、SettingsRootView、ClaudioGUIApp、
> ActivityDiagnosticsView、FailureRow、MasterVolumeRow、EventNoticeView、IntegrationsSettingsDestinationView、
> ClaudioTheme、ClaudioColorHex。全部 finding 主审亲自读过 file:line。基线 `main@7678046`。
> 本部分同样不修改任何产品代码。

## 总体判断（视觉轴）

做得好的（三条，亲读确认，保持）：

1. **颜色单一真相源 + 真实复合底对比度断言**：`ClaudioColorHex`（hex 字面量全 gui/ 只出现这一次）+
   `compositedHex()`（对「事件色 15% 自染 tile」真实渲染底求 ≥3:1）+ `ContrastSuite` ——
   教科书级的防漂移结构（`ClaudioGUICore/ClaudioColorHex.swift` 全文）。
2. **交互状态机完备**：`ClaudioIconButtonInteractionState`（`ClaudioTheme.swift:266-307`）覆盖
   rest/hovered/focused/pressed/disabled 五态；`ClaudioIconButtonStyle`、活动段按钮、作用域选择器
   三处全部 gate `accessibilityReduceMotion`（`PanelView.swift:1088-1091`、`PanelSoundScopePicker.swift:122-127`）。
3. **作用域选择器交互细节全对**：键盘导航 `onMoveCommand`/`onExitCommand`（`PanelSoundScopePicker.swift:183-184`）、
   外部点击监听（AppKit local monitor，:615-637）、焦点归还触发卡（:547-552）、行内动作 29pt 命中目标（:334）、
   双编码选中态（claySoft 底 + clay 描边 + isSelected trait）。

| 维度 | 评价 |
|---|---|
| 面板 + 通知胶囊 + 声音包窗口 + 集成页 | token 一致性高（ClaudioTheme / FailureRow 全走真相源） |
| 设置目的页（通用/通知/显示/用量/快捷键/关于） | **第二套调色板，系统色旁路** —— 唯一的结构性问题 |
| 字体 | 86 处 `.system()` 中 21 处缺 `design: .rounded`，含 15 种字号取值 |
| 圆角 | 65 处 token 驱动（好），另有 15 处阶外字面量 |
| 本地化 | 838 条全齐（`panel.audible-events.count` 为复数变体误报，值已译） |
| 危险操作 | 全部有 confirmationDialog/alert + role: .destructive（4+ 处亲读） |

## P0 · 设置目的页使用第二套调色板（系统色旁路 token）

> **决策（2026-09-18 用户复核）**：**定向采纳，降级为 P1。**错误卡（`SettingsRootView.swift:413`）和
> 用量反馈（`ActivityDiagnosticsView.swift:320`）确有系统色旁路，但设置窗口外壳（`SettingsRootView.swift:69`
> 侧栏底 `elevated`、`:95` `.tint(clay)`）已使用 `ClaudioTheme`——「整层第二套调色板」及 **P0** 判级过重。
> 正确修法是逐个可见组件统一语义色（`.secondary` → `secondaryText`、`Color.red/.orange/.green` →
> `ClaudioTheme.error/warning/success`、`Color.primary.opacity(0.06)` → `claySoft`），并核对明暗与高对比度。
> **保留不变的一点**：替换时新增的用色对（`error @12%` 复合底、`warning` 图标 vs panel/surface-2）必须
> 逐对补进 `ContrastSuite`——这两对目前没人量过，与「没人渲染过 = 没人量过」先例同一条。

ClaudioTheme 已有全部所需 token（`success`/`warning`/`error`/`secondaryText`/`elevated`/`claySoft`），
但设置目的页整层绕开它，直接用系统色。**修它是为了让后续每个设置页改动都变便宜** —— 现在下一个
新目的页大概率照抄系统色模式，漂移会持续扩大。

**证据（全部亲读）**：

| 旁路 | 位置 |
|---|---|
| `Color.red.opacity(0.08)` 错误卡底 + `.red` 图标（系统性红 `#FF3B30` ≠ `error` `#E0453A`，完全绕开 ContrastSuite） | `SettingsRootView.swift:419-422, 580-583, 719-722` |
| `.orange` 图标（observer-failure 告知 —— DESIGN.md 明确 warning 亮色已调深 `#B87000`，`.orange` 亮色 ≈`#FF9500` 对 panel 对比不足，且无人量过） | `SettingsRootView.swift:569` |
| `.green` / `.red` 三元式（用量页操作反馈 —— 应为 `ClaudioTheme.success`/`error`） | `ActivityDiagnosticsView.swift:326` |
| `Color.secondary.opacity(0.06)` 卡片底（系统冷灰 ≠ 暖 `surface`/`elevated`） | `ActivityDiagnosticsView.swift:144, 195` |
| `Color.primary.opacity(0.06)` 选中宿主行底（≠ `claySoft`）+ `cornerRadius: 8` 阶外 | `IntegrationsSettingsDestinationView.swift:214-217` |
| `Color(nsColor: .windowBackgroundColor)` 页面底（系统冷灰 ≠ 温暖实色 token） | `IntegrationsSettingsDestinationView.swift:78` |
| `.foregroundColor(.secondary)`（系统次要色 ≠ 暖 `text-2` `#75685A`，暗色下冷灰 vs 暖灰肉眼可辨） | `SettingsRootView` ×12、`ActivityDiagnosticsView` ×14、`AboutSettingsView` ×6、`ShortcutSettingsView` ×4、`EventSettingsWindowView` ×2、`LoginItemSettingsSection` ×2（共 ~40 处） |

**修法**：设置目的页整层替换为 ClaudioTheme token（`.secondary` → `secondaryText`、`Color.red.opacity(0.08)`
→ `error.opacity(0.12)` + `error` 图标、`.orange` → `warning`、`.green`/`.red` 三元式 → `success`/`error`、
`Color.primary.opacity(0.06)` → `claySoft`、卡底 → `elevated`）。替换后把新用色对（`error @12%` 复合底、
`warning` 图标 vs panel/surface-2）补进 `ContrastSuite` —— 那两对目前没人量过（同一条「没人渲染过 =
没人量过」先例的第七次机会，别再踩）。

## P1 · 字体 rounded 漂移：86 处 `.system()` 中 21 处缺 `design: .rounded`

> **决策（2026-09-18 用户复核）**：**定向采纳，只改实际文字。**21 处补 `design: .rounded` 成立；
> 但文档原提议把设置页 30pt 标题直接换成 `ClaudioTheme.font(.productTitle)`（title3 ≈ 20pt semibold）
> **不能机械替换**——那会改变标题层级。30pt 标题应先在 DESIGN.md 字号阶梯登记（或另立设置页标题角色），
> 并经原生外观核对后再定层级；rounded 补齐本身同样需要明暗两态走查。

DESIGN.md ① 明确「App chrome = SF Pro Rounded（`.fontDesign(.rounded)`）」，全库 `.fontDesign` 为 0 处
（无容器级兜底），21 处调用真实渲染为 SF Pro 直体。python 配平括号逐调用扫描：

| 缺 rounded 的调用 | 位置 |
|---|---|
| 设置页标题 `size: 30, weight: .bold`（同时 30pt 在 DESIGN.md 字号阶梯之外 —— 阶梯最大 15） | `SettingsRootView.swift:346`、`IntegrationsSettingsDestinationView.swift:119` |
| `.headline` / `.caption` / `.caption2` / `.footnote` 裸用 | `SettingsRootView.swift:141, 163, 436, 470, 488, 512`、`ActivityDiagnosticsView.swift:133, 139, 152, 168, 172, 175, 191, 204, 214, 224, 237, 253, 293` 等 |
| 警告行 / 失败行（共享组件，面板与窗口都在用） | `PanelRows.swift:89, 92`、`FailureRow.swift:65, 69, 75` |
| 关闭钮 10pt bold / 退回钮 28×28 | `EventNoticeView.swift:145` |
| chevron（10pt / 8pt bold） | `PanelSoundScopePicker.swift:95, 319` |
| `@ScaledMetric` 驱动的 `size:` 无 design | `MasterVolumeRow.swift:55`、`OnboardingView.swift:24`、`PackGalleryView.swift:98` |
| AI 提示音标题 18pt semibold | `EventSettingsAICueView.swift:32` |

**修法**：统一补 `design: .rounded`（视觉上是直角字→圆角字的微调，需要肉眼过一遍，但纯机械替换）；
同时把设置页 30pt 标题要么登记进 DESIGN.md 字号阶梯、要么收敛到 token（`ClaudioTheme.font(.productTitle)`
已存在且是 rounded——`ClaudioTheme.swift:59`，直接用它即可消掉两处 30pt 直体）。

## P2 · 打磨项（表格：问题 | 证据）

| 问题 | 证据 |
|---|---|
| 字号取值 15 种、阶梯（次要/状态=11）外跑着 8/8.5/9/9.5/10/10.5/11.5/12.5/13.5 —— 要么是刻意的紧凑密度未登记进 DESIGN.md，要么是失控 | 直方图：11×20、10×8、9×7、12×6、9.5×5、13×4、12.5×4、8.5×3、10.5×2、13.5/15/18/25/30×1（合计 73 处） |
| 阶外圆角字面量：5（活动段/能力徽标 ×5）、8（集成页选中底）、10（路由失败卡）、12（feedback toast/Onboarding/StateGallery） | `PanelView.swift:496, 499, 974`、`EventSettingsWindowView.swift:1277, 1296`、`IntegrationsSettingsDestinationView.swift:214, 369-370`、`SettingsRootView.swift:723`、`OnboardingView.swift:85`、`StateGalleryView.swift:1324` |
| hex→Color 解析三份并行实现（同一模块内重复） | `DesignTokens.swift:29 init(hex:)`、`ClaudioTheme.swift:7 init(claudioHex:)`、`FailureRow.swift:22 init(failureRowHex:)` —— 后两者同在 ClaudioGUIComponents，把 `claudioHex` init 从 fileprivate 改 internal 即可消掉两份 |
| feedback toast 用 `.regularMaterial`（vibrancy）—— DESIGN.md 材质决策明确拒绝毛玻璃（会被壁纸染色），Toast 在窗口层级风险较低但违反同一规范 | `IntegrationsSettingsDestinationView.swift:369` |
| AI 描述框占位文案 `textSecondary.opacity(0.75)` —— 占位文案降低对比是通用做法（非正文），但 `#75685A` @75% 对白底约 3.9:1，建议登记进对比度注或改用 `text-muted` | `EventSettingsAICueView.swift:336` **（2026-09-18 更正：原估值 3.9:1 有误。以亮色 `#75685A` @75% 合成到白色表面精确计算为 ≈3.22:1；建议的 `text-muted` 替代 ≈2.62:1 更差，已否决。当前用色值得修，替代色不采纳——正确方向是占位文案单独调深或登记实测值）** |
| 用量页表格列头固定宽 52/52/42pt，英文 "Last 7 days" 在 caption2 下可能截断 | `ActivityDiagnosticsView.swift:217-222` |
| 用量页区块标题（`.headline`）无 `.accessibilityAddTraits(.isHeader)` —— VoiceOver 转子在该页缺锚点（`destinationTitle` 有，页内五个区块没有） | `ActivityDiagnosticsView.swift:152, 168, 214, 253, 293` |
| `contextMenu` 全库 0 处 —— 声音包行/事件行无右键菜单（macOS 惯例，「在访达中显示」等动作可挂） | grep 全库零命中 |
| 复数变体误报澄清：`panel.audible-events.count` 双语已译（en one/other、zh other），脚本初判漏了 variations 结构 | `Localizable.xcstrings:2260` |
| 面板活动段命中目标 29pt 达标、空态/移除钮 28pt 达标、Esc 层级退出（详情→列表→收起）亲读确认 | `PanelView.swift:433, 437`、`EventNoticeView.swift:85-87, 312` |

## 第二部分建议执行顺序

> **（2026-09-18 用户复核后被文末「决策记录与执行顺序」取代，保留为决策依据）**

1. **P0** 设置目的页整层切 ClaudioTheme token（替换后把 `error @12%` 复合底、`warning` 图标两对新断言补进
   `ContrastSuite`——先量再合入，别让新用色又变成「没人量过的值」）。
2. **P1** 21 处补 `design: .rounded`；设置页标题直接换 `ClaudioTheme.font(.productTitle)`，30pt 是否入阶梯写进 DESIGN.md。
3. **P2** `FailureRow`/`ClaudioTheme` 的 hex init 合并（fileprivate → internal，零像素改动）。
4. **P2** 阶外圆角/字号要么收敛进 token、要么在 DESIGN.md 登记为「设置窗口档」（与面板紧凑档并列），二选一后由 `.swift-format` 或新守卫钉死。
5. **P2** 用量页区块标题补 `.isHeader`、表格列头改自适应宽、feedback toast 材质换实色——三项互相独立，可合并一个小 PR。

---

# 决策记录与执行顺序（2026-09-18 用户复核拍板）

> 用户对照 `main@7678046` 源码、DESIGN.md:136 与 ADR 逐条复核两轮审查结论；主审对其中三处代码主张
> （`.refreshFailed` 分支、`surfaceSoundIssue` 清理缺口、星标失败发布链）已亲读二次核实，全部成立。
> 本节是现行的执行顺序；上文各条目的原「建议」保留为决策依据，不再逐条改动。

| 建议 | 决策 | 理由（复核后） |
|---|---|---|
| 主面板显示 `.refreshFailed` | **直接采纳，优先修** | `PanelView.swift:678-679` 确认 `.refreshFailed` 走 `EmptyView()` 而旧快照继续渲染，违反 ADR 0002。保留内容，事件区加轻量提示 + 重试 |
| `surfaceSoundIssue` 长期驻留 | **提升为优先核查并修复** | `PanelConfigController.swift:668` 重读路径不清该错误；既有清除路径共四条，issue 又禁止事件写入（`PanelView.swift:595`）。仅在有效读回确认结构性覆盖恢复后自动清除；写失败类保持现有清除路径 |
| 错误文案 errno / 路径 | **采纳问题，重写修法** | `PanelWriteFailures.swift:124` 直接用 helper 中文 `description`；应投影成中英双语、可操作文案；恢复路径经明确恢复入口按需展示，不一律藏日志 |
| 设置页主题色 / 圆角字体 | **定向采纳，降级为 P1** | 系统色旁路属实（错误卡、用量反馈），但设置窗口外壳已用 `ClaudioTheme`，「整层第二套调色板」与 P0 过重。逐组件统一语义色 + 明暗/高对比度核对；rounded 只改实际文字，30pt 标题不能机械换 `.productTitle`（会改层级），先登记阶梯或另立角色 |
| 首装自动注册全局快捷键 | **暂不按 P0 修法采纳** | 「没有预设快捷键」属实；「完全无法进入」未经真机验证。菜单栏状态按钮带无障碍标签（`MenuBarController.swift:317`），PLAN-SETTINGS-EXPERIENCE.md:184 定义快捷键为用户自行注册。先走查全新安装环境的完整键盘 / VoiceOver 入口，不可达再决策 |
| 旧四档布局接回 `dynamicTypeSize` | **保留问题线索，不采纳修法** | DESIGN.md:136 明确生产固定紧凑密度、系统缩放另行验收；`PackGalleryView` 例子非当前生产路径。先原生复现具体裁切再设计重排，同步厘清旧注释 |
| 星标失败静默吞掉 | **剔除（不成立）** | 失败经 `setWindowStatus` 发布并渲染（`SoundPacksWindowModel.swift:1482`、`SoundPacksWindowView.swift:692`），已主审亲读确认 |
| AI 占位对比度 | **采纳问题，更正数值与修法** | 精确合成计算 `#75685A` @75% 对白 ≈**3.22:1**（原 3.9:1 有误）；`text-muted` 替代 ≈2.62:1 更差，已否决。占位文案单独调深或登记实测值，替代色不采纳 |

**执行顺序**（用户拍板）：

1. 刷新失败提示（`.refreshFailed` 轻量提示 + 重试，照 ADR 0002 口径）。
2. `surfaceSoundIssue` 清理（仅自动清除经有效读回确认已恢复的结构性覆盖损坏；写失败类保持现有清除路径）。
3. 错误文案双语可操作投影（typed reason → l10n；恢复路径按需展示）。
4. 视觉一致性分批：逐组件统一语义色 + ContrastSuite 补对、rounded 补齐（明暗走查）、hex 解析去重（低优先级）。
5. 原生核验项：全新安装键盘 / VoiceOver 入口、Dynamic Type 具体裁切、用量页列头与页内标题语义、明暗与高对比度。
   验收记录（`docs/settings-experience-acceptance.md:76`）已将键盘、VoiceOver、布局和外观列为未验证，
   上述核验完成前不得标为已验证。

**未验证声明**：上述用户复核阶段为只读，未改实现代码、未运行构建或原生验收；所有真机项（键盘、VoiceOver、布局、外观、
明暗/高对比度、Reduce Motion）仍未走查。

# 实施决策（2026-09-18 grill-with-docs 两轮拷问拍板）

> 在「决策记录与执行顺序」之上，经两轮 11 问把 HOW 与过程全部敲定；两轮均按推荐项通过，
> R2-Q1 经用户校准一处表述（见修复②第 6 项）。配套文档：`docs/adr/0017-clear-surface-sound-issue-only-on-read-back-recovery.md`；
> `CONTEXT.md` 新增「写失败列表」「刷新失败提示」「Surface 声音问题」三条词汇。

## 修复① 刷新失败提示（PR 1）

1. **形态与位置**：独立轻量提示行，放声音作用域与事件区之间（FailureRow 形态：真红图标 + text-2 文案 + 重试按钮）。
   不并入写失败列表——读失败与写失败是两个语义域；事件区继续展示旧快照且控件保持可交互。
2. **范围收窄**：只呈现 `.refreshFailed`（有可用旧快照时）；`.refreshing` 不加常驻指示。呈现决策走
   `ProductUIModels` 纯函数（seam 已存在：`hasUsableSnapshot` / `canRetry`），harness 直接断言，不做 source-wiring。
3. **VoiceOver 与文案粒度**：提示行首次出现时经 `onAnnounce` 播报一次「刷新失败，正在显示上次结果」，
   同一失败期间不重复播报；文案不带 reason。l10n key `panel.library.refreshFailed`（无格式参数）；
   重试按钮独立标识 `panel.library.refresh-retry`（与 `.loadFailed` 的 `panel.library.retry` 互斥、互不复用）。
4. **验收**：原生验收（键盘焦点顺序、VoiceOver、Reduce Motion）作为合并前置——重试按钮是新增焦点控件，
   提示行插入会改变既有焦点序。

## 修复② Surface 声音问题清除（PR 2）

5. **检测口径**：真实读回条件重估——重载时仅当配置有效读回、当前 Surface 覆盖重新解析为健康，
   才自动清除结构性损坏类；读回失败或覆盖仍损坏时继续 fail closed。
6. **范围（R2-Q1，用户校准后定稿）**：自动清除**只覆盖结构性损坏类**。写失败瞬时类（锁忙、锁失败、读写失败）
   不凭读回自动清除；保留既有四条清除路径：静音写成功、切包成功、重置覆盖成功、切换作用域。
   **校准限定**：切换作用域只丢弃瞬时问题提示，不证明写入能力恢复；issue 置位时写控件已被
   `configWritesAllowed` 门禁用，因此「写成功清除」不是当前界面可直接执行的重试入口，不得在文案或
   设计中如此承诺。来源区分用内部类型化标签（覆盖损坏 / 写失败），文案不承担身份
   （与 `PanelWriteFailureReason` 的 typed-identity 先例一致）。依据 **ADR 0017**。
7. **测试与验收**：新增清除生命周期 suite（置值 → 重载条件消失 → 清除 / 重载条件仍在 → 保留，两条都断）；
   harness 断言充分则原生验证后置，但 PR 描述须逐条声明未验证项。

## 修复③ 双语错误文案（PR 3）

8. **文案体系**：分类映射三句式（发生了什么 + 影响 + 怎么办），先覆盖三个写者（静音 / 切包 / 主音量）
   与顶层 `configFailure` 路径；恢复入口复用 `onRevealConfig` 既有通道；zh-Hans + en 占位符一致，
   注册 `Localizable.xcstrings` + `ClaudioL10nKey.allKnown`。
9. **技术细节承载**：底层错误码与技术串不进界面，只进日志与「活动与诊断」；不做 disclosure 展开层、
   不做副文案小字（发现成本高且稀释可行动性）。
10. **测试与验收**：新增文案映射 suite（每类错误 → 三句式输出）+ `jq empty Localizable.xcstrings` 门禁；
    新恢复按钮进入焦点序，合并前做一次手动焦点巡检，证据写进 PR。

## 过程决策

11. **PR 切分**：三个独立 PR 按 ①→②→③ 顺序合；视觉一致性批次（设置页语义色统一、rounded 补齐、
    hex 解析去重）另开议题，不阻塞本批。修复①是 ADR 0002 契约的兑现，不另记 ADR；修复③仅把
    既有类型化错误投影为本地化界面文案，不改变事实所有权或持久化语义，也不另记 ADR。

**未验证声明**：本节为计划定稿，未改实现代码、未运行构建或原生验收、未提交；原生核验项状态同上节。
