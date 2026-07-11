# 主音量滑块 —— 锁死的实现方案

> 产出自 `/plan-eng-review`（2026-07-11）。四段评审 + Codex 外部声音（gpt-5.5 high）。
> 14 项决议，全部经用户拍板。**实现尚未开始**（一份未测试的探索性 WIP 在分支 `feat/master-volume-slider` @ `cbc02f0`，勿直接信任）。

## 0. 问题

ENGINEERING.md 面板线框（:204）画着 `│ 🔊 主音量  ●———————  │`，交互状态覆盖表（:224）写着
「拖动即时改 config，映射 `afplay -v`（含默认值）」「越界值 → 钳制到 0.0–1.0」。
**但 `PanelView` 里零 Slider。** 用户能逐事件静音，改不了整体音量，只能手改 `config.json`。

helper 侧的 `master_volume` → `afplay -v` 映射（T9，`Volume.swift`）早已完成，其 doc comment 甚至明写
它是为「the GUI's volume slider (T15/T16)」准备的。缺的只是 GUI 那一半 + 一个写者。

## 1. What already exists（约 90% 可直接复用）

| 已有 | 位置 | 复用还是重建 |
|---|---|---|
| 钳制规则（含 NaN/±inf → 0.8、`-0.0` 归一） | `Volume.swift:24` `AfplayVolume.clamped` | **复用**，绝不重写第二份 |
| `afplay -v` 渲染（locale 安全） | `Volume.swift:39` | 复用 |
| 默认值单一真相源 0.8 | `ClaudioConfig.defaultMasterVolume` | 复用 |
| 外科式读-改-写（未知键逐字保留、畸形 fail-closed） | `ConfigMutation.swift:137` `updateConfigJSON` | **复用**，做第三个调用方 |
| Double 安全落盘（非有限值拒写、最短往返渲染） | `JSONSafeWrite.swift` | 复用（自动获得） |
| @MainActor 写回外壳的形状 | `EventMuteController.swift`（47 行） | 镜像 |
| 焦点纯模型 | `PanelFocusOrder.swift` | 扩一个 case |
| 失败行 UI | `PanelView.errorNotice` | 复用（并统一，见 D3） |
| 播放端消费（每次 spawn 现读 config） | `Play.swift:198-205` | 无需改动 |
| GUI 已能读到 masterVolume | `PanelConfigSuite` 已有断言 | 复用 |

**没有一处需要重建。** 新增的只是：一个写者、一个状态机、一个外壳、一个视图、一个焦点 case。

## 2. 关键约束（评审实证，非假设）

1. **`play.lock` 被 5 个互不相干的写者共用**：`Play`（去抖+spawn，它唯一该保护的）、`EventEnabled`、
   `Use`、`SettingsInstaller`×2。而 `play` 拿不到锁时**静默不放声音**（`.skippedDebounce`，故意设计：
   hook 绝不能阻断 Claude Code）。=> **任何一次 config/settings 写都是一个会吞掉提示音的窗口。**
   这个 bug **今天就已经存在**，与滑块无关。
2. 分离安全的三点源码实证：`loadPlayConfig` 在锁**外**（`Play.swift:180`）；config 写是 `.atomic`
   rename（读者只见旧的完整版或新的完整版，绝不撕裂）；`play` **从不读** settings.json。
3. **该值没有实时消费者**：`claudio play` 每次 spawn 重读 config.json。拖动中间值无人可见。
4. **写路径是 @MainActor 同步阻塞 I/O**（open+flock+读+解析+序列化+原子 rename）。
5. **DESIGN.md 零滑块定义**（grep `滑块|slider|轨道|track|thumb|拨杆` 无命中）。
   TODOS.md:179 所称「DESIGN.md 已定义其视觉」**为假**。
6. **macOS `Slider` 默认填充 = 系统强调色**（用户在系统设置里选的），会把设计系统外的颜色带进面板。
7. **对比度**：clay 亮色 `#C4633C` 对 panel `#FFFDF8` = 3.97:1 → 过非文本 ≥3:1，不过正文 ≥4.5:1。
   滑块填充是非文本 → clay 合法（与已拍板的 drop-zone hover 同规则）。
8. **面板的试听完全不理 master_volume**：`AudioPreviewPlayer.swift:28-32` 从不设 `sound.volume`
   （NSSound 默认 1.0）。今天无害（没 UI 能改音量）；滑块一上线即成为「拖了没反应」的直接原因。

## 3. 十四项决议

| # | 决议 | 来源 |
|---|---|---|
| **D1** | **松手才写**（`Slider(onEditingChanged:)`）。拖动中只改本地 draft。改 ENGINEERING.md:224「拖动即时改 config」→「松手即时落盘」+ 理由。 | 架构 Issue 1 |
| **D2** | **试听同批修**：`AudioPreviewPlaying.play(fileAt:volume:)` → `sound.volume = Float(AfplayVolume.clamped(v))`。 | 架构 Issue 2 |
| **D3** | **错误态统一成一个写失败列表**（不再每个写者一个 `@State` + 一个 `if`）。保住「多条可同时存在、不互相顶替」。下沉成 `ClaudioGUICore` 纯函数并单测（此性质今天零测试，只活在注释里）。 | 架构 Issue 3 · DRY |
| **D4** | **clay 填充 + 补登 DESIGN.md**：`.tint(ClaudioColor.clay(colorScheme))`。DESIGN.md 补滑块视觉一行 + 决策记录。ContrastSuite 加断言钉住「滑块填充 vs 面板 ≥3:1」（明暗双主题）。 | 质量 Issue 4 |
| **D5** | **step 0.05（21 档）**。默认 0.8 恰在网格上（0.05×16）。 | 质量 Issue 5 |
| **D6** | **`VolumeDragSession` 下沉成纯状态机**并单测 + 变异验证。视图只剩转发，无可漂移分支。 | 测试 Issue 6 |
| **D7** | **跨写者混合并发测试**（`concurrentPerform` 混跑三个写者）。顺带结掉 TODOS.md:233 那条 P4。 | 测试 Issue 7 |
| **D8** | **抽 `MasterVolumeRow` 子视图**，draft 就地持有 —— 拖动只使这一行失效，不重算 4 个事件行 + 画廊。 | 性能 Issue 8 |
| **D9** | **分离锁（根因修复）**：新增 `config.lock`（config 三写者）/ `settings.lock`（install/uninstall）；`play.lock` 退回只管 play 去抖。把 `Paths.swift:64-66` 早已为 `logLockFile` 写下的原则推到所有调用点。 | **Codex #4** |
| **D10** | **dirty flush**：`onDisappear` + `NSApplication.willTerminateNotification` 都必须冲刷未提交的拖动。D6 原本的「只 dragged 无 ended = 0 commit」是**把数据丢失写成了规格**，已更正为「拖动**中**不写；脏会话**必须**被冲刷」。绝不把正确性押在 SwiftUI 会在 popover 消失时补发 `onEditingChanged(false)`。 | **Codex #1/#2** |
| **D11** | **不变不写**：只有 draft 真的偏离磁盘基线才落盘；且 `drag(to:)` 只在 `isDragging` 时接受（`onEditingChanged(true)` 才置位）——SwiftUI 的 render-time 网格吸附因此**无法**触发写。手写的 `master_volume: 0.42` 不碰就永远活着。 | **Codex #7** |
| **D12** | **失败即回滚**：写失败 → draft 弹回磁盘基线 + 错误行照常上报。UI 绝不显示磁盘上没有的值。 | **Codex #8** |
| **D13** | `setMasterVolume` 的 `freshSelectedPack` **无默认值、强制调用方给**——不像 `setEventEnabled` 那样传 `""`。面板永远知道当前包，让它说出来，而不是伪造一次谁也没做过的选择（`selected_pack: ""` 会让 play 读得到配置却解析不到包 → 一份看起来正常的静音配置）。 | **Codex #5** |
| **D14** | **NSSound 曲线如实注释**：`NSSound.volume` 与 `afplay -v` 同为 0…1 标量（`NSSound.h:65`），但**增益曲线等价未经证明**——注释写实话，记一条 TODO，不吹「完全一致」。 | **Codex #6** |

## 4. 实现（按此顺序，TDD）

### 阶段 A — 根因：锁分离（可独立落地、独立评审、独立 PR）
- `Paths.swift`：新增 `configLockFile` / `settingsLockFile`，并在 `lockFile` 上加「只许 play 拿」的 `- Important`。
- `Use.swift` / `EventEnabled.swift`：默认锁 → `configLockFile`。
- `SettingsInstaller.swift`（install / uninstall）：默认锁 → `settingsLockFile`。
- `Setup.swift`：`SetupEnvironment` 的 `lockFile` 拆成 `configLockFile` + `settingsLockFile`。
- 测试：**回归** —— 钉住「一个持有 `play.lock` 的进程存在时，`setEventEnabled` / `selectPack` /
  `installClaudioHooks` 仍然成功」（今天这条会 RED —— 那正是 bug）；以及「一个持有 `config.lock`
  的进程存在时，`playSoundEvent` 仍然正常发声」。变异验证：把锁改回共用，两条必须 RED。
- **升级窗口注记**：旧二进制（拿 play.lock 写 config）与新二进制（拿 config.lock）并存时不互相串行。
  写是原子 rename，最坏情况是丢一次更新，不会撕裂。GUI 是单进程、CLI `use` 是手动，实际不可达。

### 阶段 B — helper 写者
- 新建 `helper/Sources/ClaudioCore/MasterVolume.swift`：
  `setMasterVolume(_:freshSelectedPack:configFile:lockFile:) -> Result<SetMasterVolumeOutcome, SetMasterVolumeError>`
  - **先钳制再写**（`AfplayVolume.clamped`）—— 越界值绝不落盘（spec:224），非有限值绝不到达编码器（防 abort）。
  - `updateConfigJSON` 只 set `master_volume`。
  - `.updated(volume:)` 带回**实际落盘的**（已钳制的）值，调用方据此吸附滑块，无需重读文件。
  - 错误枚举逐 case 镜像 `SetEventEnabledError`。

### 阶段 C — GUI 纯逻辑（全部可在本机单测）
- `VolumeDragSession.swift`：D6/D10/D11/D12 四条规则的唯一归宿。
- `MasterVolumeController.swift`：镜像 `EventMuteController`（@MainActor 壳，`@Published lastError`）。
- `PanelWriteFailures.swift`：D3 的纯函数（三写者的错误 → 有序去重列表）。
- `PanelFocusOrder.swift`：`PanelFocusTarget.masterVolume` 新 case，插在最后一个 `.eventMute` 之后、
  `.dropZone` 之前（对齐线框：滑块在事件行与拖入区之间）。

### 阶段 D — GUI 视图（本机只能编译，行为需真机）
- `MasterVolumeRow.swift`（新）：Slider + `.tint(clay)` + `step: 0.05` + a11y（label / value / adjustable）
  + `onDisappear` 冲刷 + `willTerminate` 冲刷。
- `PanelView.swift`：插入 `MasterVolumeRow`；错误行改列表渲染；`playPreview` 传 volume。
- `AudioPreviewPlayer.swift`：协议加 volume 参数；`AudioDropZoneView` 跟随。

### 阶段 E — 文档
- `ENGINEERING.md`：:224 改「松手即时落盘」+ 理由；新增锁分离决议记录。
- `DESIGN.md`：补滑块视觉 + 决策记录。
- `TODOS.md`：结掉主音量条 + :233 并发写条；**更正 :179 那句「DESIGN.md 已定义其视觉」的假话**。

## 5. 测试（诚实版 —— 不吹 100%）

**可在本机自动测（`swift run` 两包）：**
- helper `MasterVolumeSuite`：成功写 / 钳制（>1、<0、`-0.0`）/ `.lockBusy` / `.lockFailed` /
  损坏 config → `.configReadFailure` / 父目录不可写 → `.configWriteFailure` / config 不存在 → 新建
  （**断言 `selected_pack` 来自调用方，不是 `""`** —— D13）/ **保真**（未知顶层键、`events`、
  `selected_pack` 逐字保留）。
- helper `ConfigLockSuite`（**回归**，D9）：持有 `play.lock` 时三个写者仍成功；持有 `config.lock` 时
  `playSoundEvent` 仍发声。变异验证必须 RED。
- helper `ConfigConcurrencySuite`（D7）：`concurrentPerform` 混跑三写者，落地 config 恒合法无损。
- gui `VolumeDragSessionSuite`（D6/D10/D11/D12）：1 began + N dragged + 1 ended = **恰好 1** commit；
  只 dragged 无 ended → `flushPending()` **必须**吐出 commit（**不是 0**）；未拖动 → 0 commit；
  baseline 0.42 未拖动 → 0 commit；`drag` 在 `!isDragging` 时被忽略；`commitFailed` 后 draft == baseline。
  **变异验证**：改回逐帧 commit 必须 RED；去掉 flush 必须 RED。
- gui `MasterVolumeControllerSuite`：镜像 `EventMuteControllerSuite` 四条。
- gui `PanelWriteFailuresSuite`（D3）：多条同时存在时全部保留、顺序稳定、同因去重。
- gui `PanelFocusOrderSuite`（**回归**）：`.masterVolume` 恒在最后 `.eventMute` 之后、`.dropZone` 之前。
- gui `ContrastSuite`：滑块填充 vs 面板 ≥3:1（明暗双主题）。
- gui 预览 spy（**回归**）：`play(fileAt:volume:)` 收到的 volume == `clamped(config.masterVolume)`。

**单测覆盖不了、必须真机走查 —— 但这不是被阻塞项：**

「需要一台装 Xcode 的 Mac」这个前提**已被推翻**（TODOS.md「T15 真身面板」条）：本机
（CommandLineTools）用 `swift build -c release` + 手工组一个 ad-hoc 签名的 `Claudio.app`
（`LSUIElement` Info.plist + `Resources/bin/claudio` + `Resources/packs/` + `codesign --sign -`）
就能跑完整真机走查。**所以下面这些应该在实现的同一批里做完，不要挂账。**
前置：先让 state 进 `.installed`（跑一次 `claudio setup` 真接管），否则面板停在 `.helperMissing`，
运行态根本进不去。

- `onEditingChanged(false)` 在 popover dismiss 时到底补不补发 —— **D10 的兜底正是为了不依赖它**，
  所以这一项无论结论如何都不改变实现，只是让我们知道真相；
- 拖动手感 / step 吸附 / 帧率（D8 是否真的解决了重算 —— 本机无法实测帧率，这是它 confidence 只有 7/10 的原因）；
- 拖到一半关面板 / 退出 app → 值仍落盘（D10 的验收）；
- 手改的 `0.42` 开面板不碰它 → 一个字节不变（D11 的验收）；
- 把 `~/.claudio` 改只读 → 滑块弹回 + 错误行（D12 的验收）；
- 拖完立刻试听 → 响度当场跟随（D2 的验收，也是滑块可信度的验收点）；
- **拖滑块的同时让 Claude Code 发事件 → 提示音不得消失**（D9 的验收，本方案最重要的一条）；
- VoiceOver 播报「主音量，80%」+ 上下箭头 5% 步进；
- Dynamic Type 最大档下滑块在 360pt 面板里的布局；
- 真实 `NSSound.volume` 与 `afplay -v` 的听感是否一致（D14 —— 未证明，见 TODOS）。

**关于 Tab 键，别声称收益**：macOS 的「键盘导航 / FKA」**系统默认是关的**，关闭时 SwiftUI `Button`
不进 key view loop，面板的 Tab 遍历今天本就是死的（TODOS.md 有独立的 P3 追踪它）。
`PanelFocusTarget.masterVolume` 该加还是要加 —— 纯模型必须与视图同构，否则又是一处漂移
（`.dropZone` 已经漂了一次）—— 但它**不会**让滑块变得键盘可达。
VoiceOver 不受 FKA 影响，所以 `accessibilityValue` / adjustable 那一半是真实收益。
本方案不加剧、也不解决 FKA 那条。

## 6. NOT in scope（明确不做）

| 不做 | 理由 |
|---|---|
| 逐事件音量 / 逐包音量 | v1 只有单一 `master_volume`（ENGINEERING.md）。加它要动 config schema + manifest schema。 |
| 音量 ducking（压低其它 app） | ENGINEERING.md:318 已裁定移出 v1：`afplay -v` 只能设自身音量，真做需弃 afplay 改 CoreAudio。 |
| 深夜降音量（`night_dim`） | T2 已移出 v1 → v2。 |
| 用 `afplay` 替代 `NSSound` 做试听 | 曲线完全一致的唯一保证，但引入进程 spawn 延迟 + 新失败模式。D14 先如实注释 + 记 TODO。 |
| 规范化 DesignTokens（从 DESIGN.md 生成） | TODOS.md:149 的既有 P3。本次只加 `.tint(clay)`，不新造颜色，不触发它。 |
| GUI 主线程全量扫包的异步化 | TODOS.md:269 的既有 P3。滑块不加剧它（松手才写，且不触发 `refresh()`）。 |
| 修 `setEventEnabled` 的 `freshSelectedPack: ""` 契约 | 它是另一个写者的既有契约；D13 只保证**新**写者不重蹈。改它要单独一轮。 |

## 7. 失败模式表

| 新代码路径 | 一种真实的生产失败 | 有测试？ | 有错误处理？ | 用户看得见？ |
|---|---|---|---|---|
| `setMasterVolume` 拿锁 | 另一个 `claudio use` 正在写 → `.lockBusy` | ✅ | ✅ | ✅ 错误行「请稍后重试」+ 滑块弹回（D12） |
| `setMasterVolume` 写盘 | `~/.claudio` 只读 → `.configWriteFailure` | ✅ | ✅ | ✅ 错误行 + 滑块弹回 |
| `setMasterVolume` 读 config | 用户手改坏了 config → `.configReadFailure` | ✅ | ✅ | ✅ 错误行带可执行修复指令 |
| `setMasterVolume` 非有限值 | 调用方传 NaN → 进程 abort（exit 134） | ✅ | ✅ 先钳制 → 不可能到达编码器 | — 不可达 |
| 拖动中 popover 关闭 | `onEditingChanged(false)` 不补发 → **值丢失** | ✅ 纯单测 | ✅ `onDisappear` 冲刷（D10） | 值照常落盘 |
| 拖动中 app 退出 | 同上 | ✅ 纯单测 | ✅ `willTerminate` 冲刷（D10） | 值照常落盘 |
| 开面板不碰滑块 | SwiftUI 网格吸附把 0.42 改写成 0.40 | ✅ 纯单测 | ✅ `drag` 门控在 `isDragging`（D11） | 0.42 不动 |
| config.json 不存在时首拖 | 造出 `selected_pack: ""` → **永久静音** | ✅ | ✅ 强制调用方给 pack（D13） | 不可能发生 |
| 写成功但 UI 不同步 | UI 显 30%、磁盘 80% | ✅ 纯单测 | ✅ baseline := 实际落盘值 | — |

**critical gap（无测试 + 无错误处理 + 静默）：0 条。**

## 8. 并行化

| 阶段 | 触及模块 | 依赖 |
|---|---|---|
| A 锁分离 | `helper/Sources/ClaudioCore/`（Paths/Use/EventEnabled/SettingsInstaller/Setup） | — |
| B helper 写者 | `helper/Sources/ClaudioCore/` | A（要 `configLockFile`） |
| C GUI 纯逻辑 | `gui/Sources/ClaudioGUICore/` | B（`MasterVolumeController` 调 `setMasterVolume`） |
| D GUI 视图 | `gui/Sources/ClaudioGUI/` | C |
| E 文档 | `*.md` | — |

- **Lane 1**：A → B → C → D（严格串行，同模块 + 真依赖）
- **Lane 2**：E（独立，可并行）

`VolumeDragSession` / `PanelWriteFailures` / `PanelFocusOrder` 三者互不依赖，C 内部可三路并行。
**A 强烈建议单独一个 PR** —— 它是一个独立成立的 bug 修复（今天就在吞声音），与滑块无关，
混在一起会让「加个滑块」的 PR 里藏着一个改了五个文件的并发契约变更。

## 9. 绿灯

- `swift run --package-path helper claudio-tests` 退出 0
- `swift run --package-path gui claudio-gui-tests` 退出 0
- 两包 `swift build` 零 warning
- 真机走查按第 5 节的清单走完（ad-hoc 签名 app bundle，不需要 Xcode）

## 10. 评审来源

- **四段评审**（架构 / 代码质量 / 测试 / 性能）：9 个发现，0 个 critical gap。
- **外部声音**：Codex（gpt-5.5, high reasoning）—— 9 条，全部成立，其中 3 条推翻了 Claude 侧的结论：
  ① 「松手才写解决了吞声音」→ 只是缩小窗口，根因是锁的共用（D9）；
  ② 「只拖不松手 = 0 次写」当特性 → 那是把数据丢失写成规格（D10）；
  ③ 「100% 覆盖」→ 假的，最危险的行为恰恰不可自动测（第 5 节已改成诚实版）。
  另有三个 Claude 完全漏掉的洞：`selected_pack: ""`（D13）、`0.42` 被吸走（D11）、写失败后 UI 状态未定义（D12）。
- **一份未测试的探索性实现**在分支 `feat/master-volume-slider` @ `cbc02f0`（helper 能编译，零测试，**勿直接信任**）。
  实现阶段应按本文件 TDD 重来，或以它为起点补齐测试。
