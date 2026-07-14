# 主音量滑块 —— 锁死的实现方案

> 产出自 `/plan-eng-review`（2026-07-11 第一轮；**2026-07-12 第二轮，本文件已按其结论重写**）。
> **第二轮**：10 路源码侦察 + 132 次对抗证伪 + Codex（gpt-5.5 high）+ **本机 key 窗口渲染探针**。
> **46 项决议**（D1–D19 第一轮，**D20–D36 第二轮**，**D37–D46 第三轮**）。第二轮推翻或修正了 **D4 / D5 / D8 / D10 / D11 / D12 / D13 / D15 / D17 / D19
> 与阶段 A 的文件清单** —— 其中 **D20 与 D21 各自足以让原方案「照做即坏」**。
> **第三轮（2026-07-12）**：交互式 mockup 展示板自证出 **10 项计划没收口的议题**，用户授权（原则：功能完整易用 · UI 好看 · 这版设计完可直接用）后已全部拍板为 **D37–D46**——
> 其中 **D44 撤销了第二轮的 D34①（假修正，D17 从头到尾是对的）**，**D45 修掉 `snap()` 的脏浮点**（21 档里 7 档会把 `0.35000000000000003` 写进用户的 config.json，模拟器实拖跑出来的）。
> ~~**实现尚未开始**（一份未测试的探索性 WIP 在分支 `feat/master-volume-slider` @ `cbc02f0`，勿直接信任 —— 处置见 D42）。~~
> ✅ **阶段 A′/B/C/D 已全部落地在 `main`**（2026-07-14）：`MasterVolume.swift`（helper，1c934a7）→
> `VolumeDragSession.swift`（a789fe3）→ `MasterVolumeController.swift`（47459a7）→ `MasterVolumeRow.swift`
> + `PanelConfigController.setMasterVolume(_:)` + 面板接线（8771946）。滑块在 `.operational` 面板上真的渲染。
> **那个 WIP 分支不要再碰**（D42 列了它的四处毒）：本行原先把下一个接手的人指向它，而 `main` 上早已是
> 已落地、已测、已评审的实现（`/codex review 8771946`）。

## 0. 问题

> ⚠️ **本节是历史**（问题陈述，写于 2026-07-11）。阶段 D 已经解决了它 —— 「`PanelView` 里零 Slider」
> 今天是假话（`MasterVolumeRow.swift` 就是那个 Slider）。保留原文是为了让后面的决议表有上下文，
> 不是因为它还成立。

ENGINEERING.md 面板线框（:204）画着 `│ 🔊 主音量  ●———————  │`，交互状态覆盖表（:224）写着
「拖动即时改 config，映射 `afplay -v`（含默认值）」「越界值 → 钳制到 0.0–1.0」。
**但 `PanelView` 里零 Slider。** 用户能逐事件静音，改不了整体音量，只能手改 `config.json`。

> 注：上面引的那两条 ENGINEERING.md 原文**本身**后来也被实现推翻了 —— 线框里的 🔊 喇叭字形被 D15
> 明令不画，「拖动即时改 config」被 D6/规则 1 改成「松手才写」。ENGINEERING.md 已按实现更正
> （2026-07-14）；这里引的是它**当时**的样子。

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
5. ~~**DESIGN.md 零滑块定义**~~ → **已补**（2026-07-12，DESIGN.md Layout「控件行（Control Row）」节 + Decisions Log）。
   原状属实：grep `滑块|slider|轨道|track|thumb|拨杆` 曾零命中，TODOS.md:179 所称「DESIGN.md 已定义其视觉」**是假话**。
   但缺的**不是**「滑块长什么样」—— 这套系统的既定立场本就是**原生**，且 `OnboardingView.swift:102-103` 的
   `.borderedProminent + .tint(clay)` 已是「原生外壳 + clay tint」的**既成先例**。新增节因此不发明控件解剖
   （轨道 / 拇指 / 焦点环 / 按下态一律交给 AppKit，**不是我们的决策面**），只把先例升格成规则 + 钉死 D15–D18 四个真会踩的坑。
6. **macOS `Slider` 默认填充 = 系统强调色** —— **已实证**（2026-07-12，本机 key 窗口 + `screencapture` 真实像素）：
   裸 `Slider` 的填充轨道渲染为 **`#3275F0`**（系统蓝）。
7. **`.tint(clay)` 在 macOS `Slider` 上确实生效** —— **已实证，推翻了本轮评审的头号怀疑**。
   证据链：① SwiftUI 的 macOS `Slider` 由 `NSSlider` 支撑（`AppKitPlatformViewHost<…SystemSlider>` → `CustomMarkedSlider`，`is NSSlider == true`）；
   ② `NSSlider.trackFillColor` 是**公开** API（`AppKit/NSSlider.h:30`，macOS 10.12.2+，本包 floor 是 macOS 12 → 可用）；
   ③ `.tint()` 把颜色原样转发到该属性；④ **key + active 窗口**下真实截屏，填充渲染为 **`#C7795B`**（请求 `#D97757`，差异是 Display P3 → sRGB 色彩管理，非丢色）。
   **重要方法学教训**：同一探针在**离屏 / 非 key 窗口**下渲染出的是**灰色**（macOS 对非活跃窗口的强调色做去饱和）——
   若只跑离屏截图会得出「`.tint` 无效」的**错误结论**。真实面板永远是 key + active（`MenuBarController.swift:144` 的
   `NSApp.activate(ignoringOtherApps:)` 就是为此），所以适用的是 key 窗口那一档。**任何后续控件的视觉验证都必须在 key 窗口下做。**
8. **`step:` 会画出刻度带** —— **已实证**：SwiftUI 在 macOS 上把 `Slider(…, step: 0.05)` 直译成
   `NSSlider.numberOfTickMarks = 21` + `allowsTickMarkValuesOnly = true`，轨道下方多出**一条 21 个灰点的刻度带**（截图逐像素证实）。
   不带 `step:` 则 `numberOfTickMarks = 0`。tint 与 step **不互斥**（`tint + step` 仍渲染 clay 填充 + 刻度点）。
9. **对比度**：clay 亮色 `#C4633C` 对 panel `#FFFDF8` = 3.97:1 → 过非文本 ≥3:1，不过正文 ≥4.5:1。
   滑块填充是非文本 → clay 合法（与已拍板的 drop-zone hover 同规则）。
   ⚠️ 但**这一对不是滑块真正的对比面**：clay 填充段的相邻色是 AppKit 的**未填充轨道灰**（截图实测 `#E0E0E0` 档），不是 panel。
   而未填充轨道灰是 AppKit 的、不在 `ClaudioColorHex` 里 → **纯 hex 数学的 `ContrastSuite` 结构上断不了它**（见 D25）。
10. ~~**面板的试听完全不理 master_volume**：`AudioPreviewPlayer.swift:28-32` 从不设 `sound.volume`
    （NSSound 默认 1.0）。今天无害（没 UI 能改音量）；滑块一上线即成为「拖了没反应」的直接原因。~~
    ✅ **已修（阶段 D，8771946）**：`AudioPreviewPlayer` 协议加了 volume 参数，`PanelView.playPreview`
    传 `panelModel.config.masterVolume`。走查 ⑦ 验的就是这条（拖到 ~20% → 试听明显变小）。
11. **面板的 SwiftUI 视图树与进程同寿**：`MenuBarController.swift:64` 的 `NSHostingController(rootView: panel)`
    **一辈子只建一次**，popover 只 show/close，视图树不重建 —— `PanelFocusCoordinator.swift:10-14` 已白纸黑字记下这一点
    （「`NSHostingController`'s SwiftUI-side state persists for the controller's whole lifetime」）。
    推论：**子视图的 `@State` 跨 popover 开关存活，且只在首次插入树时 seed 一次**。这条约束是 D8 / D10 / D12 三条决议共同的地基，
    而原方案没有一条意识到它（见 D21 / D22）。

## 3. 决议表

> **2026-07-12 第二轮 `/plan-eng-review`（10 路源码侦察 + 132 次对抗证伪 + Codex gpt-5.5 high + 本机 key 窗口渲染探针）**
> 推翻/修正了 D4 / D5 / D8 / D10 / D11 / D12 / D13 / D15 / D17 / D19 与阶段 A 的文件清单，新增 **D20–D36**。
> 被推翻的条目**原地划掉并指向替代决议**，不删除 —— 保留推翻的理由本身就是资产。

| # | 决议 | 来源 |
|---|---|---|
| **D1** | **松手才写**（`Slider(onEditingChanged:)`）。拖动中只改本地 draft。改 ENGINEERING.md:224「拖动即时改 config」→「松手即时落盘」+ 理由。 | 架构 Issue 1 |
| **D2** | **试听同批修**：`AudioPreviewPlaying.play(fileAt:volume:)` → `sound.volume = Float(AfplayVolume.clamped(v))`。 | 架构 Issue 2 |
| **D3** | **错误态统一成一个写失败列表**（不再每个写者一个 `@State` + 一个 `if`）。保住「多条可同时存在、不互相顶替」。下沉成 `ClaudioGUICore` 纯函数并单测（此性质今天零测试，只活在注释里）。 | 架构 Issue 3 · DRY |
| **D4** | **clay 填充 + 补登 DESIGN.md**：`.tint(ClaudioColor.clay(colorScheme))`。~~DESIGN.md 补滑块视觉一行 + 决策记录~~ → **已落地**（2026-07-12，「控件行（Control Row）」节 + Decisions Log；见 D15–D18）。ContrastSuite 加断言钉住「滑块填充 vs 面板 ≥3:1」（明暗双主题）。 | 质量 Issue 4 |
| ~~**D5**~~ | ~~**step 0.05（21 档）** 用 `Slider(…, step: 0.05)`~~ → **被 D24 取代**。`step:` 会在轨道下方画出 **21 个刻度点**（本机截图实证）。21 档的语义保留，但吸附改由 `VolumeDragSession` 负责。 | ~~质量 Issue 5~~ → **实证推翻** |
| **D6** | **`VolumeDragSession` 下沉成纯状态机**并单测 + 变异验证。视图只剩转发，无可漂移分支。 | 测试 Issue 6 |
| **D7** | **跨写者混合并发测试**（`concurrentPerform` 混跑三个写者）。顺带结掉 TODOS.md:233 那条 P4。 | 测试 Issue 7 |
| **D8** | **抽 `MasterVolumeRow` 子视图**，draft 就地持有 —— 拖动只使这一行失效，不重算 4 个事件行 + 画廊。 | 性能 Issue 8 |
| **D9** | **分离锁（根因修复）**：新增 `config.lock`（config 三写者）/ `settings.lock`（install/uninstall）；`play.lock` 退回只管 play 去抖。把 `Paths.swift:64-66` 早已为 `logLockFile` 写下的原则推到所有调用点。**⚠️ 阶段 A 的文件清单是错的 —— 见 D20。** | **Codex #4** |
| ~~**D10**~~ | ~~**dirty flush**：`onDisappear` + `willTerminateNotification` 冲刷~~ → **被 D22 取代**。D10 一边宣称「绝不把正确性押在 SwiftUI 的 popover 生命周期回调上」，一边把正确性押在了 `onDisappear` 上 —— 同一个 NSPopover 容器、同一类回调、同一个本仓库**已明文否定**的来源（`PanelFocusCoordinator.swift:10`）。 | ~~Codex #1/#2~~ → **自相矛盾** |
| **D11** | **不变不写**：只有 draft 真的偏离磁盘基线才落盘。~~且 `drag(to:)` 只在 `isDragging` 时接受，使 SwiftUI 的 render-time 网格吸附无法触发写~~ → **理由作废（但结论保留）**：D24 去掉了 `step:`，**根本不存在 render-time 网格**，所以「吸走 0.42」这个威胁自始就不会发生。`isDragging` 门控因此**不再需要**为它服务 —— 而它恰恰堵死了 VoiceOver / 键盘的写路径（§11 P0-a），故按 **D24 + D26** 改。手写的 `0.42` 仍然「不碰就永远活着」，靠的是「不变不写」这一条本身。 | **Codex #7** · 本轮修正 |
| **D12** | **失败即回滚**：写失败 → draft 弹回磁盘基线 + 错误行照常上报。UI 绝不显示磁盘上没有的值。**⚠️ 这条与 D8 在 SwiftUI 语义上直接互斥 —— 见 D21，那是本轮最严重的发现之一。** | **Codex #8** |
| ~~**D13**~~ | ~~`setMasterVolume` 的 `freshSelectedPack` 无默认值、强制调用方给~~ → **空转，被 D23 取代**。`ConfigMutation.swift:144` 实证：`freshSelectedPack` **只在 config.json 不存在的 else 分支被读**（:152-160）—— 而那**恰恰**是面板手里只有空串的那个分支。强制调用方传参，调用方传进来的还是 `""`。函数签名管不住调用方手里的坏数据。 | ~~Codex #5~~ → **实证空转** |
| **D14** | **NSSound 曲线如实注释**：`NSSound.volume` 与 `afplay -v` 同为 0…1 标量（`NSSound.h:65`），但**增益曲线等价未经证明**——注释写实话，记一条 TODO，不吹「完全一致」。 | **Codex #6** |
| **D15** | **主音量行 = 控件行，不是第五个事件行**：无事件色 tile、**无喇叭图标**、**无百分比读数**（跟 ENGINEERING:204 线框；读数交给 `accessibilityValue`，与 macOS 系统音量滑块同）。行 = `[「主音量」SF Pro 13] · Spacer · [Slider]`。**图标必须砍掉**：`speaker.wave.2` 已是试听键（`EventRowView.swift:290`）、`speaker.wave.2.fill`/`speaker.slash.fill` 已是静音钮两态（`:414`）——主音量再上喇叭就是同一个 312pt 面板里的**第三套**喇叭语义，紧贴在四行各带两枚喇叭的正下方 8pt 处，没人分得清哪个是"音量"。落 DESIGN.md 新增的「控件行」节。 | 设计缺口复核 |
| **D16** | **音量 0 = 全局静音，且不与逐事件静音联动**：0 是合法值（非"禁用"、非"错误"），语义 = 全部事件不出声。四行的静音钮**不跟着变**——它们表达的是正交维度（"这个事件配没配声音"），一个是总闸、一个是分路。**不换 `speaker.slash`**（那是第四次喇叭撞车）。ENGINEERING.md:224 状态表「主音量」行的三个 `—` 用这条填上。 | 设计缺口复核 |
| **D17** | **Dynamic Type 复用 `rowWrapsToTwoLines`**：「更大」及以上档 → 标签在上、Slider 整行在下，照抄 `EventRowView.swift:118-131` 的既有降级。**不给 `PanelLayoutAdaptation` 新立字段**（它今天只有 3 个字段，`PanelTypeSize.swift:31-43`）。这同时把第 5 节那条「Dynamic Type 最大档下滑块的布局」从"走查时现编"变成"走查时验收一个已知目标"。 | 设计缺口复核 |
| **D18** | **D12 的回滚是瞬跳，不加动画**；拖动跟手也不加动画。给滑块加任何动画 = 必须同批接上 reduced-motion 门控，代价远大于收益。<br>⚠️ **2026-07-14 更正（阶段 D 落地时发现）**：本条原本的理由是 ~~「`PanelView.swift:63-69` 明写『本视图树零 `.animation()`，**所以**不读 `accessibilityReduceMotion` —— 这条注释就是绊线』」~~ —— **这句话是假的，而且在写下它的那一刻就已经是假的**：那条绊线早被 T17c 踩响并改写（`0aab69a` 只修了 `.swift`，没修引用它的文档）。今天 `PanelView.swift:67-80` 说的是反话：树里有**两颗**已 gate 的 spinner（`PanelView.disconnectRow` + `OnboardingView.ctaButton`），`:80` 已声明 `@Environment(\.accessibilityReduceMotion)`。**规矩不变**（滑块行确实零动画；加动画必须同批 gate），作废的只是理由。 | 设计缺口复核 + **2026-07-14 更正** |
| ~~**D19**~~ | ~~**`selectedPack` 为空 → 滑块 `.disabled(true)`**~~ → **封错了门，被 D23 取代**。同一状态下真正会写出空包 config 的是**静音钮**（`EventRowView.swift:412` 的 `Button(action: onToggleMute)`，**无任何 `.disabled`**）—— 它**今天就能**造出 `selected_pack: ""`。禁用滑块 = 给一扇本来就不会开的门贴封条，同时让隔壁那扇一直敞着的门继续敞着。（滑块仍应禁用，但那是**表象处理**，不是修复；且与 D31 的焦点不变式撞车。） | ~~设计缺口复核~~ → **Codex #4 + 源码实证** |

### 本轮新增（2026-07-12 第二轮 eng review）

| # | 决议 | 来源 |
|---|---|---|
| **D20** | **锁分离必须改名，不能只改默认值 —— 否则 D9 对 GUI 完全无效（本轮最严重发现）。** 实证：`= ClaudioPaths.lockFile` 全仓 **10 个**默认值点，其中 **2 个在 `gui/`**（`PanelView.swift:96`、`EventMuteController.swift:26`）；而 GUI 是**显式传锁**的（`PanelView.swift:114` → `EventMuteController`、`:414` → `selectPack`、`EventMuteController.swift:38` → `setEventEnabled`）。**改 helper 侧函数的默认参数，对显式传参的调用方一点作用都没有。** 照阶段 A 的原清单实现完，用户点静音、切包**照样拿 `play.lock`**，照样吞提示音 —— 而 GUI 是本方案唯一的用户入口。<br>**修法：把 `ClaudioPaths.lockFile` 改名成 `playLockFile`。** 那 10 个点会**全部变成编译错误**，逼每一处做出显式选择。原计划写的是「在 `lockFile` 上加一条 `- Important` 文档注释」—— **那是在该放编译器的地方放了一条注释**，而本仓库刚刚才因为「注释拦不住任何人」吃过亏（`PanelFocusOrder.swift:132-138`）。 | **本轮 · Claude + Codex 独立同得** |
| **D21** | **D8 与 D12 在 SwiftUI 语义上直接互斥 —— 滑块会永久显示磁盘上没有的值。** 地基（约束 11）：`MenuBarController.swift:64` 的 `NSHostingController` 一辈子只建一次，`@State` 跨 popover 开关存活、**只 seed 一次**。D8 要求 draft「就地持有」= `MasterVolumeRow` 的 `@State`。于是 `PanelView.refresh()`（`:457` 重读 config）**推不进滑块**：用户手改 config 成 0.30 → 重开面板 → `config.masterVolume == 0.30`，而滑块仍显示 0.80。更狠的是 D11「不变不写」让它**不会自愈**（draft == 陈旧 baseline → 判定「没变」→ 不写盘），这个谎言一直挂到用户手动拖一下为止；而用户下一次微调是**基于幻影 baseline 提交的**（磁盘 0.30、滑块显 0.80、往下拨一格 → 落盘 0.75，音量被静默拉高）。这一字不差地违反 D12 自己写的「UI 绝不显示磁盘上没有的值」，且是 D8 的机制**亲手**造成的。<br>**修法**：`MasterVolumeRow` 显式接一条下行同步 —— `.onChange(of: diskVolume) { session.rebase(to: $0) }`。**`rebase(to:)` 在 WIP 里已经写好了**（`cbc02f0` 的 `VolumeDragSession.swift:150`，doc comment 甚至点名了三个触发场景），**但全仓零调用点** —— 一个写了没人调的函数就是漂移的定义。 | **本轮 · 两路侦察独立同得** |
| **D22** | **冲刷信号走 `popoverDidClose`，不是 `onDisappear`。** `MenuBarController` **已经是 `NSPopoverDelegate` 且已实现 `popoverDidClose`**（`:184`）；而 popover **显示**侧的可靠信号早已建成 —— `popoverDidShow`（`:159`）→ `focusCoordinator.requestFocus()` → `showCount` → `PanelView.onChange`（`:176`），且 `PanelFocusCoordinator.swift:10` 明写这套东西存在的**唯一理由**就是「SwiftUI 的 `.onAppear` 不是可靠信号」。全仓 `onDisappear` **零命中**。<br>**修法**：`popoverDidClose` → coordinator 上一个单调递增的隐藏计数器 → `.onChange(of: 它) { flush() }`，与既有的 show 路径**完全对称**。零新机制、零新假设、复用一条已在真机验证过的通路。<br>✅ **落地时比本条更彻底（8771946）**：那个计数器**不需要新加** —— T17d 早已建成 `PanelFocusCoordinator.hideCount` + `notePanelHidden()`，语义逐字相同，且它的 bump 已经在 `popoverDidClose` 的第一行（D37 要的排序保证是白送的）。所以实现直接复用 `hideCount`，**没有** `closeCount` 这个符号。本条原文写死了 `closeCount` 这个名字，与代码矛盾（`/codex review 8771946`）；「零新机制」这条原则本身是对的，实现只是把它贯彻得比计划更远。<br>`willTerminate` 那一半保留，但**降级为兜底**：app 无 Quit 入口，`willTerminate` 只覆盖 ⌘Q / 注销 / 关机，force quit 与 `killall` 完全不覆盖 —— §7 失败表把它写成「值照常落盘 ✅」是**假的**（见 D32）。 | **本轮 · Claude + Codex 独立同得** |
| **D23** | **`selected_pack: ""` 是今天就活着的 bug，必须在本轮修根因（原计划把它划到了 scope 外）。修法已定稿（三路独立设计 + 对抗证伪，见下）。**<br>**病灶链（全部逐字实证）**：`PanelConfig.swift:25` 的 `loadPanelConfig` 读不出 config 时回落 `ClaudioConfig(selectedPack: "")` → `OnboardingDetector` 判 `.installed` **只看 hooks、不看 config** → 面板停在运行态、顶着绿点、手里一个空包 → `EventRowView.swift:412` 的静音钮**无任何 `.disabled`** → 点它 → `EventEnabled.swift:88` 的 `updateConfigJSON(at:, freshSelectedPack: "")`（**硬编码空串，不是参数**）在 config 不存在时新建一份**有毒**的 config。<br>`EventEnabled.swift:47-52` 那句「In practice this branch is unreachable from the real panel（the mute button only renders once a pack is already selected）」是**假话** —— 静音钮的真实渲染门槛只有 `onboardingViewModel.state == .installed`（`PanelView.swift:144`），与「选过包」无关。它依赖的不变式**恰恰是 `loadPanelConfig` 亲手破坏的那一个**。<br>**⚠️ 严重性更正：不是「永久静音」（P0），是 P1。** `Setup.noPackHasEverBeenSelected` 会在下次 `claudio setup` 时自愈；画廊点一下也能救回。真实后果是**面板顶着绿点撒谎、声音悄悄死了、没有任何东西告诉用户**。 | **本轮 · Codex #4 + 侦察 S3** |
| **D23 定稿** | **三层修法。骨架取路线 A，helper 侧的刀取路线 C，判据是两条正交轴。**<br>**① helper —— 消灭毒源（一个文件，一个调用点）**：`setEventEnabled`（及新 `setMasterVolume`）在 config **缺失**时 **fail-closed 拒写**（新增 `.configMissing` 错误），不再新建。`EventEnabled.swift:88` 是磁盘上 `selected_pack: ""` 的**唯一产地**。该函数注释自己推理对了一半（「inventing one here would silently fabricate a selection **nothing actually chose**」——所以它拒绝**猜**包），却接着做了更糟的事：捏造了一个**有毒**的选择。**第三条路（什么都不写）从来没被考虑过。** → **D13 正式作废**（不再需要 `freshSelectedPack` 参数；该参数从此只剩 `selectPack` 一个用户）。<br>**② 判据是两问，不是一问（本轮最容易漏的一条）**：`loadClaudioConfig` 是**宽松**解码（`{"master_volume": "0.35"}` 读得动，静默换成 0.8），而 `updateConfigJSON` 的 `parseRewritableConfig` 是**严格**的（同一份文件 fail-closed 拒写）。于是存在一类「**读得动、写不动**」的 config → 只搬「读」判据会把它判成 `.usable` → 面板渲染全套活控件 → **每一次点击都必然失败**。这与 D23 是同一族的谎，而 `ConfigMutation.swift:46-49` **早就写下了这个警告**。<br>　· **读**：`packSelection(configFile:)` —— 把 `Setup.swift:71-75` 的 private 三态裁决升成 ClaudioCore 的 public（不存在 ∨ 空串 = 没人选过包；畸形 = 坏文件，不猜不重建）。<br>　· **写**：**复用已存在的 public `probeConfigRewritable`**（`ConfigMutation.swift:98-125`，四态 `.absent / .rewritable / .malformed(reason:) / .unwritable(reason:)`，**已经是 doctor 的单一真相源**）。**不要重造。**<br>　· 面板状态 = **两问的合成**。<br>**③ GUI —— 不再撒谎**：`loadPanelConfig` 去掉 `?? ClaudioConfig(selectedPack: "")`。`PanelConfig.swift:23` 的注释早就写对了：「Core 只回答『这份 config 能不能用』，『不能用时面板显示什么』是面板的事」。<br>**④ 面板 —— 路由到已经存在的自救路径（零新机制）**：<br>　· `.needsPack`（缺失 ∨ 空串）→ **画廊空态「先选包」**。`selectPack` 在 config 缺失时**会建出一份正确的 config**（`Use.swift:94`，`freshSelectedPack: packID` + 写前两道 pack 校验），而 `availablePacks` **不依赖 config** 列包 —— **自救路径本来就通，只是面板从来没走上去**。且这**已经是 ENGINEERING.md:224 的既有规格**（「空态卡『先选包』」）。<br>　· `.malformed` / `.unwritable` → 诚实失败态 + doctor 的可执行修复指令 + 「在访达中显示」（只读逃生口）。**不需要禁用所有控件** —— 写者本来就全部 fail-closed；要做的只是别再假装一切正常。<br>　· → **D19 作废**：不是禁用一个控件，是整个面板换一个诚实的态（空包态根本不渲染滑块）。<br>**为什么不是「让 OnboardingDetector 纳入 config.json」**：三路设计里这条被**两名反方一致判死、作者自己也 REJECT**。① 它会把用户**锁死** —— onboarding 的 CTA **今天根本没接线**（见 D35），点下去什么都不会发生；② 它混了两条正交的轴（「有没有接管 Claude Code」vs「Claudio 自己的状态健不健康」），`OnboardingEnvironment` 里**连 configFile 字段都没有**；③ 只把「损坏」送进 onboarding 的安全版**零修复**（D23 活着的那条路第一步是**缺失**，不是损坏）。<br>**为什么不自动自愈**（路线 C 的 `healPackSelection`）：它会**替用户选包**（字母序第一个 —— 用户装了 pikachu/psyduck/wobbuffet，config 一删就恢复成别的，原选择不可恢复），且开面板即写盘会撞 `play.lock`。这违反仓库自己的裁定：「**替他做主只会把一次诚实的报错换成一次静默的数据丢失**」。**让用户点那一下。** | **本轮定稿 · 三路设计 + 2×2 对抗证伪** |
| **D35** | **`.notInstalled` 的「接管 Claude Code」按钮今天是个死钮 —— 独立的活 bug，与主音量无关。** `OnboardingViewModel.onPrimaryAction` 在**整个生产代码里从未被赋值过一次**（`gui/Sources` + `helper/Sources` 里 `onPrimaryAction =` **零命中**；唯一赋值点在 `OnboardingViewModelSuite.swift:108/139` 的测试里）。完整行为：点击 → `onPrimaryAction?()` 求值为 `nil` → 什么都不做 → `refresh()` 重新检测 → **状态原样不变 → 永远出不去**。<br>而 `.notInstalled` 确实渲染着这个主 CTA（`OnboardingCopy.swift:79-85` `primaryActionTitle: "接管 Claude Code"` → `OnboardingView.swift:95-97`）。`OnboardingViewModel.swift:8-13` 自己承认这个洞：「Wiring a CTA tap to an actual side-effecting action is **the menu bar shell's job** (T8/T15) … future work hooks into」—— **菜单栏 shell（`MenuBarController.swift`）已经落地了，却没回来接线。**<br>**修法**：`MenuBarController` / `PanelView` 把 `onPrimaryAction` 接到真实副作用上。注意：`installClaudioHooks` **只写 settings.json**，对「config 缺失」是幂等无效的；能建 config + 拷包的是 `performFirstRunSetup`，而它从 GUI **完全不可达**（唯一调用方是 CLI `Subcommands.swift:113`）。<br>**登记为独立 P1，单独 PR，不进主音量。** | **本轮 · 事实核验副产品** |
| **D36** | **config 缺失 + `~/.claudio/packs/` 为空 → 零自救路径（登记，不在 D23 范围）。** 生产环境 `bundledPacksDirectory` 是 **`nil`**（`AudioImportEnvironment.swift:64` 默认 nil，`ClaudioGUIApp.swift:63-65` 没传），所以 `availablePacks` **只看用户包根**；它空了 → 画廊零卡 → **D23 的自救路径（点一张卡）也没了**，而面板仍顶着绿点、四行事件、静音钮全活。<br>`ClaudioGUIApp.swift:57-62` 的注释就是这条的自白：它明文**假设** setup 已经把内置包拷进用户包目录了。**假设成立时没事；假设不成立时无路可走。**<br>**修法（候选）**：`.needsPack` 态在画廊为空时，给出「重跑 `claudio setup`」的可执行指令（而不是一个空画廊）。**登记为 P2 TODO。** | **本轮 · 事实核验副产品** |
| **D24** | **不用 `Slider(step:)` —— 它会画出 21 个刻度点。** 本机 key 窗口截图实证（约束 8）：`step: 0.05` → `numberOfTickMarks = 21`，轨道下方多出一条 21 个灰点的刻度带。DESIGN.md 刚定的控件行「行高 ~28pt」装不下它，且这 21 个点**既不在设计系统里、也没人拍过板**，会出现在四行事件行正下方 8pt 处。<br>**修法**：视图侧用吸附型 `Binding` 转发，网格吸附放进 `VolumeDragSession`（D6 本来就说它是「唯一归宿」）：`Slider(value: Binding(get: { session.draft }, set: { session.drag(to: $0) }), in: 0...1, onEditingChanged: …)`，`drag(to:)` 内部吸附 ~~`snap(v) = (v / 0.05).rounded() * 0.05`~~ → **`(v / 0.05).rounded() / 20`（D45 —— `* 0.05` 会把 21 档里的 7 档写成脏浮点）**。`numberOfTickMarks` 恒为 0，21 档语义一点不丢。**副作用：D11 的「render-time 网格吸走 0.42」这个威胁自动消失** —— 没有 `step:` 就没有 render-time 网格。 | **本轮 · 渲染探针实证** |
| **D25** | **`ContrastSuite` 只补暗色一对；`.tint` 是否生效**只能靠真机截图，且**已经截过了**。 计划原本要加的「滑块填充 vs 面板 ≥3:1（明暗双主题）」里，**亮色那一半是已有断言的逐字重复**（`ContrastSuite.swift:211-214` 已有 `clayLight vs panelLight >= 3.0`；且 `nonTextPairs` 里的 `notificationDark` **就是 `clayDark` 的别名**，`ClaudioColorHex.swift:133`）—— 新断言的信息量为 0，它唯一能变红的情形是 clay 本身被改坏，而那时上面 6 条**先**红。<br>更要紧的是**它测不到会出事的那个东西**：`ContrastSuite` 是纯 hex 数学（`ClaudioGUICore` 不依赖 SwiftUI），它**结构上不可能知道** `MasterVolumeRow` 到底有没有写 `.tint(clay)`、有没有被人删掉退回系统蓝 —— 而那正是 D4 存在的全部理由。这与该文件 `header:9-15` 自我批判过的「手抄副本 → 结构上捕获不了它所针对的回归」是同一个病。<br>**修法（用户已拍板，2026-07-12）**：① 只加**暗色**一对（`clayDark vs panelDark`，今天确实没有，有价值）；② 「`.tint` 生效 / 未退回系统强调色」**接受为测不到的缺口，用真机走查兜底** —— 不投 `NSViewRepresentable` 做可测封装。落成 **§5.2 走查清单第 ⑨ 条**（把系统强调色改成红色再开面板），并附本轮实证色（clay `#C7795B` / 系统蓝 `#3275F0`）。**代价说清楚：这条规则的守门人是人，不是 CI —— 每次动到控件行都必须重跑第 ⑨ 条。** | **本轮 · 侦察 S5 + S8 · 用户拍板** |
| **D26** | **给 `VolumeDragSession` 加一条显式的非拖动提交路径（`adjust(to:)`），修 §11 P0-a。** VoiceOver 的 adjustable increment 与键盘方向键**不走** `onEditingChanged` → `isDragging` 永远 false → D11 的门控把它们的写**全部丢掉**。更糟：Slider 的 binding setter 被门掉后**显示值会弹回**，VO 用户体验到的不是「改了没存」，而是「控件根本推不动」（WCAG 2.1.1 可操作性失败，比持久化失败更严重）。而 §5 自己把「VoiceOver 上下箭头 5% 步进」列成了验收项 —— 按原设计**必挂**。<br>**修法**：`adjust(to:)` 走**非拖动路径、直接 commit**。⚠️ 关键约束：它**不能**简单地挂在 binding setter 的 `!isDragging` 分支上（那正是 render-time 写入的入口）—— 但 **D24 去掉 `step:` 后 render-time 网格吸附不复存在**，这个顾虑随之消失，setter 在 `!isDragging` 时路由到 `adjust(to:)` 变成安全的。**D24 是 D26 的前置条件。** | **本轮 · §11 P0-a 收口** |
| **D27** | **写成功后走 `refreshMasterVolume()`，镜像既有的 `refreshEnabledFlags()` —— 不发明新机制（修 §11 P0-b）。** 计划称「写成功后 `PanelView` 的 `@State config` 不重读」，作为对**既有写者**的描述**是错的**：静音写者 `toggleMute`（`:399-403`）成功后调 `refreshEnabledFlags()`（`:438-444`），而那个函数的注释白纸黑字写着「`config` 本身是**重读**而不是内存 patch，所以面板反映的是**真正落盘的字节** —— 这是 `refresh()` 同样遵循的 re-detect-don't-patch 纪律」。<br>所以 D12 的「baseline := 实际落盘值（内存 patch）」**与仓库既定纪律冲突**，且计划**漏看了现成的先例**。<br>**修法**：写成功 → 只重读 config（**不**扫包，轻量形状）→ `config.masterVolume` 变化 → 经 **D21** 的 `.onChange(of: diskVolume)` 下推到 session。**一举同时解决 P0-b 和 D21，且零新概念。**<br>✅ **落地（8771946）**：这条推理成立，但它引的两个函数名今天都不存在 —— `refreshEnabledFlags()` / `refreshMasterVolume()` 是 `PanelView` 的旧私有方法，9cccc9c 红队重构时随状态一起搬进 `PanelConfigController` 并合并成 **`reloadConfigOnly()`**。所以实现是 `setMasterVolume(_:)` 成功 → `.configOnly` → `reloadConfigOnly()`，与静音那一半**共用同一个函数**（比「镜像一个先例」更彻底：不是照着写第二份，是直接复用）。别照本条原文新建 `refreshMasterVolume()`，那只会重复它。 | **本轮 · 侦察 S2/S7** |
| **D28** | **D2 的另一半：`AudioDropZoneView` 拿不到 config，且 `onAppear` 会把音量定格。** 计划的阶段 D 写「`AudioPreviewPlayer.swift`：协议加 volume 参数；`AudioDropZoneView` **跟随**」—— 但「跟随」在源码里**无处可跟**：`AudioDropZoneView.init(viewModel:)` 自己 `new` player 且**没有 config 入口**；而它在 `.onAppear`（`:44`）里绑定回调 —— 传值快照进去会把音量**定格在开面板那一刻**。<br>**修法**：volume 用**闭包**传（`currentVolume: () -> Double`），不是值。取值时机 = 播放时，不是绑定时。 | **本轮 · Codex #5 + 侦察 S2** |
| **D29** | **「gui 预览 spy」这条测试在当前包结构下写不出来 —— §5 把它列进「可在本机自动测」是假的。** `AudioPreviewPlaying` 是 **internal 协议**，住在 `ClaudioGUI`（**executableTarget**，`gui/Package.swift`），而 `claudio-gui-tests` 的 dependencies **只有 `ClaudioGUICore`** —— harness 够不着它。<br>**修法**：把「音量解析」下沉成 `ClaudioGUICore` 的**纯函数**（`previewVolume(for config: ClaudioConfig) -> Double { AfplayVolume.clamped(config.masterVolume) }`）并单测；视图侧只做转发。可测的那一半进核心，够不着的那一半留在视图并**如实列进真机走查**。 | **本轮 · 侦察 S7/S8** |
| **D30** | **`ConfigLockSuite`（D9 的唯一守门人）按原写法必然假绿。** 现有**每一条**锁争用测试都**显式注入临时 lockFile**（`EventEnabledSuite.swift:127-131` 等），因此与默认参数**完全无关**。而 D9 只改默认值 → 「变异验证：把锁改回共用，两条必须 RED」**不会 RED**，测试是恒真的空测试。<br>**修法**：D20 的**改名**让这条测试有了牙 —— 真正该断言的是**接线**：`EventMuteController()` **默认构造**后其 `lockFile == ClaudioPaths.configLockFile`（而非 `playLockFile`），`PanelView` 的默认 `lockFile` 同理。这是唯一能捕获「有人把 GUI 的默认值改回 play.lock」的断言。 | **本轮 · 侦察 S8** |
| **D31** | **`PanelFocusTarget.masterVolume` 与 `.disabled(true)` 撞车。** 现有焦点模型有一条成文不变式：**禁用控件不得持有焦点身份**（`panelOpeningFocus` 专门过滤掉静音行的禁用试听键，`PanelView.swift:349-358` 的注释里「可操作 is load-bearing」）。空包时滑块 `.disabled` 但焦点模型仍把 `.masterVolume` 排进序列 → 不变式当场变成假话，而 §5 那条「`.masterVolume` 恒在最后 `.eventMute` 之后」的回归测试**测不到**它。<br>~~**修法**：`panelFocusOrder` / `panelOpeningFocus` 的入参加上「滑块是否可操作」，与既有的 `nonOperableActionEvents` 同形状。~~ → **修法被 D41 取代**：前提（「空包时滑块 `.disabled`」）已被 D23 定稿抽掉 —— 空包态**根本不渲染滑块**，`.operational` scope 里它恒可操作。给纯模型加一个永远只会传 `true` 的参数，正是 D21 批评过的「写了没人调」式漂移。 | **本轮 · 侦察 S9 + design-diff** |
| **D32** | **§7 失败模式表有三处假 ✅，必须改成实话。** ① 「拖动中 app 退出 → `willTerminate` 冲刷 → 值照常落盘 ✅」：冲刷走的仍是**非阻塞锁**（`EventEnabled.swift:63`，`case .skipped: return .failure(.lockBusy)`），锁被占 → 写失败；而此时 app 正在退出，**D12 的错误行没有观众** → **静默丢值**。② 「拖动中 popover 关闭 → `onDisappear` 冲刷 ✅」：`onDisappear` 不可信（D22）。③ 「config.json 不存在时首拖 → 不可能发生 ✅」：对滑块成立，但**同一张表描述的失败今天就能由静音钮触发**（D23）。<br>**修法**：三格改成实话；force quit / `killall` 明确列为**不覆盖**（可接受，但要写出来）。 | **本轮 · 侦察 S4/S9 + Codex** |
| **D33** | **主音量行必须进 `StateGalleryView` + `PreviewFixtures` —— 它现在绕过了仓库自己声明的「视觉真相源」。** DESIGN.md:161 明写「视觉真相源 = 仓库内 state gallery」，而 `StateGalleryView.swift`（353 行）今天 `Slider` / `主音量` **零命中**，计划的阶段 D 文件清单里**也没有它**。后果：D16（音量 = 0）与 D19/D23（空包禁用）这两个**最难手动复现**的态，落地前**零仓库内视觉验证**。<br>**修法**：阶段 D 补 `StateGalleryView` + `PreviewFixtures` 两个文件。 | **本轮 · 侦察 S9** |
| **D34** | **文档~~三~~两处硬错，一并改（① 已被 D44 撤销）。** ~~① **Dynamic Type 档位错一级**：`PanelTypeSize.swift:59-65` 实证 `.larger`（=「更大」）的 `rowWrapsToTwoLines` 是 **false**，true 从 `.largest` 才开始 —— 而 D17 **和刚写进 DESIGN.md 的「控件行」节**都写着「「更大」及以上档折行」。~~ → **① 是个假修正，被 D44 撤销**：`.larger` = 「**较大**」而不是「更大」（ENGINEERING.md:269 + `PanelTypeSize.swift:19-25` 逐字），「更大」== `.largest` == 正是折行那一档 —— **D17 一个字都没错**；真正的错是 D34① 自己塞进 DESIGN.md:132 的那句括注。② **D15 的引证是反的**：`ENGINEERING.md:204` 线框逐字是 `│  🔊 主音量  ●———————  │` —— **它有喇叭**。D15 的「同屏第三套喇叭」论证成立，但线框在图标上**反对**它；且阶段 E **没列「改线框」** → 实现完成之日就是新一轮 spec 漂移之时。③ **DESIGN.md:132 的「ContrastSuite 今天还没有这一对断言」是假的**（见 D25）。 | **本轮 · 源码逐字比对** |

### 第三轮新增（2026-07-12 · mockup 展示板自证的 10 项议题 · 用户授权拍板）

> **来源**：交互式 mockup 展示板 https://claude.ai/code/artifact/5fc6437a-d209-4d0e-b75b-e1404850699f ——
> §10 曾拒绝「给原生 Slider 画 AI mockup」，该拒绝对滑块解剖（轨道/拇指/焦点环）**仍然成立**；展示板绕开它的方式是
> 三层诚实边界（HTML 可验 / AppKit 只能近似 / 只能真机），并把 `VolumeDragSession` 逐行镜像成可交互模拟器。
> 板子自证出 10 项计划正文没收口的议题（其中 D45 是**模拟器实拖跑出来的**，不是读代码读出来的）。
> **用户授权拍板（2026-07-12），裁决原则：功能完整易用 · UI 好看 · 这版设计完可直接用。**
> D44 / D46 属纯文档更正，**本轮已直接落纸**（DESIGN.md / DesignTokens.swift 注释），不等阶段 E。

| # | 裁决 | 议题 |
|---|---|---|
| **D37** | **隐藏计数器的 bump 必须是 `popoverDidClose` 的第一条语句（任何 early return 之上）。** 那句 `guard NSApp.isActive, let previous, … else { return }` 在「用户点了别的 app」——**关闭 popover 最常见的路径**——上恰好 `NSApp.isActive == false` 直接 return；冲刷挂在 guard 之后 = D22 白做而单测照绿（单测测的是状态机，测不到 AppKit 这一行的位置）。真机验证走 §5.2 ③④。<br>✅ **落地即满足（8771946）**：复用的 `notePanelHidden()` **本来就是** `popoverDidClose` 的第一行（T17d 出于同一个理由把它放在那儿），所以这条排序保证是继承来的，不是重新争取的。`ViewWiringSuite` 有一条**顺序**断言钉死它（不是 contains，是 `range(of:).lowerBound` 比较），且失败消息现在同时点名它守的两个 bug。原文写的 `closeCount` 符号不存在，见 D22。 | 板 ① |
| **D38** | **D33 的 gallery 范围 = `MasterVolumeState` 六帧（展示板 §2 即规格）；D23 的三个路由态不进 gallery，由 §5.2 ⑫⑬ 真机走查兜底。** `StateGalleryView` 的四个族全是子视图、从不渲染 PanelView —— 为三帧破例引入「整面板宿主」是一类全新机制，超出本方案。**整面板路由帧（`PanelRouteState` 族）登记为独立 P3 TODO**（TODOS.md），将来路由态再增多时投入。 | 板 ② |
| **D39** | **`.writeFailed` 错误行归 PanelView（D3 合并列表），`MasterVolumeRow` 零错误 UI。** `MasterVolumeController.lastError` 只是 D3 纯函数的第三个输入，生命周期逐字镜像 `EventMuteController.lastError`（`EventMuteController.swift:19-22`：首次为 nil，**下一次成功写清空**）。gallery 侧推论：写失败帧以「行 + 错误行」**组合帧**留在 `MasterVolumeState` 族里（展示板 §2 已这么画），不需要 PanelView 帧。 | 板 ③ |
| **D40** | **ENGINEERING.md:204 线框的拇指移到约 4/5 处**（默认 `defaultMasterVolume = 0.8`）：`│  主音量   ──────●──  │`。原线框画在最左（= 0%），与默认值矛盾且无一处解释。与 D34② 的「去 🔊」同批在阶段 E 改。 | 板 ④ |
| **D41** | **`PanelFocusOrder` 只加 `.masterVolume` case，不改 `panelFirstFocusTarget` 的签名（取代 D31 的修法半句）。** D23 定稿后滑块只存在于完全可运行的面板（`.needsPack` / `.malformed` / `.unwritable` 都不渲染它），`.operational` scope 里它**恒可操作** —— 过滤器 `PanelFocusOrder.swift:115-120` 那个 `return true` 默认分支从此对 `.masterVolume` **承重**，实现时在旁边加一行注释写明这个前提。测试改钉两条：位次恒定（最后一个 `.eventMute` 之后、`.dropZone` 之前）；四行全静音时首焦点是首行 `.eventMute`——**滑块永远轮不到抢首焦**。路由态的焦点 scope 归 A′ 定，唯一硬约束：**不含 `.masterVolume`**（不渲染即不进序 —— 结构保证，不是参数保证）。 | 板 ⑤ |
| **D42** | **WIP `cbc02f0` 按「代码形状可参考、注释必重写」处置，四处必改**：① 删 `VolumeDragSession.swift:65` 的假浮点断言（「`0.05 * 16 != 0.8` bit-for-bit」——**实测两者完全相等**，16 是 2 的幂，binary64 下按 2 的幂缩放是精确的；EPSILON 真正在挡的是 D45 那 7 档脏值，偏差约 5.6e-17）；② doc 里三条已死的决议全按 D22/D24/D26 重写（`:28` 的 `onDisappear`+`willTerminate`、`:57-58` 推荐 `step:`、`:45-52` 以 render-time 网格论证 `isDragging` 门控）；③ `quantized()` 按 D45 改；④ WIP 的 `MasterVolume.swift:84/105` 还带着 `freshSelectedPack` —— 阶段 B 已明令删除，**照抄会把毒源复制进新写者**。 | 板 ⑥ |
| **D43** | **`.configMissing` 不面向用户：无 GUI 文案、不进 D3 错误列表。** GUI 能收到它的唯一路径 = 面板开着时 config 被外部删掉（竞态窗口）。处置 = `commitFailed()` 回滚 + 触发**全量 `refresh()` 重检** → 面板路由到 `.needsPack` 空态、滑块随视图卸载 —— **面板换成诚实的态，本身就是给用户的解释**（这正是 `refreshEnabledFlags` 注释那条 re-detect-don't-patch 纪律的用法）。给一条实践上无人能看到的错误编一句面板文案 = 死文案，没人会 QA 它。helper 侧错误枚举的英文 reason 照 `SetEventEnabledError` 惯例写（给 CLI/doctor 看，不是面板文案）。 | 板 ⑦ |
| **D44** | **撤销 D34①（假修正）—— D17 从头到尾是对的。** 真相源 `ENGINEERING.md:269` 逐字「较大 → 隐波形；**更大 → 事件行转两行**；极大 → 加宽 popover」，`PanelTypeSize.swift:19-25` 照抄（`.larger`=「较大」、`.largest`=「更大」、`.maximum`=「极大」）——「更大」**就是**折行那一档。D34① 把「更大」误注成 `.larger`、指控 D17「错一级」，并把这句错误括注塞进了 DESIGN.md:132。**本轮已改**：DESIGN.md:132 括注更正 + 补中文档位对照表；§5.2 ⑪「挂了说明」栏、阶段 D 的「不是『更大』」措辞同步更正。**方法学教训：一条错误的指控比没有指控更糟** —— 展示板第一版照抄了 D34①、跟着指控 DESIGN.md，是 132 次对抗证伪把它自己纠正的。 | 板 ⑧ |
| **D45** | **`snap()` 改「先取档位再除」：`let k = (clamped(v) / 0.05).rounded(); return clamped(k / 20)`。** WIP 的 `k * 0.05` 在 binary64 下有 **7 档**（15/30/35/60/70/85/95%）偏一个 ULP，而 `JSONSafeWrite` 是最短往返渲染 → `0.35000000000000003` **原样写进用户的 config.json**（不会无限重写 —— EPSILON 的「不变不写」挡住了；所以不是数据损坏，是一个丑陋且用户看得见的文件）。`k / 20` 落在与源码字面量相同的 Double 上 → 21 档最短渲染全部干净（实测）。措辞纪律：**不许写「精确」**（0.35 在二进制下本就不可精确表示），只许写「与字面量同位、渲染干净」—— 本方案已经栽过一次假浮点事实的跟头（D42 ①）。测试见 §5。 | 板 ⑨ · **模拟器自证** |
| **D46** | **DESIGN.md 两处漂移 + 一处代码注释漂移，本轮顺手改掉（零行为变更）**：① Decisions Log :213 还标着「（待决 · 未改）」，而正文 :169 早已「✅ 已拍板（2026-07-11 /ship，解法 1）」—— 状态标记更正、保留存档；② `DesignTokens.swift:88-89` 的注释还在逐字引用被推翻的旧文案「边框 / 文字转黏土」（实现是对的，注释是错的）—— 改引现行文。又一例「注释拦不住任何人」。 | 板 ⑩ |

## 4. 实现（按此顺序，TDD）

### 阶段 A — 根因：锁分离（可独立落地、独立评审、独立 PR）

> **⚠️ 本节按 D20 重写过。原清单只列 helper 五个文件 —— 照那个做，D9 对 GUI（唯一的用户入口）完全无效。**

**A1. 改名（这一步是全部效力的来源）**
- `Paths.swift`：`lockFile` → **`playLockFile`**（改名，不是加注释）；新增 `configLockFile`（`~/.claudio/config.lock`）
  与 `settingsLockFile`（`~/.claudio/settings.lock`）。
- 改名后 `= ClaudioPaths.lockFile` 的 **10 个**默认值点**全部编译不过**。逐个做出显式选择 —— 这正是目的。

**A2. helper 侧（5 处默认值）**
- `Play.swift:99` → `playLockFile`（唯一该拿它的人）。
- `Use.swift:61` / `EventEnabled.swift:61` → `configLockFile`。
- `SettingsInstaller.swift:119/138/189/203`（**4 个签名，不是 2 个** —— 原计划的「SettingsInstaller×2」少数了一半）→ `settingsLockFile`。
- `Setup.swift:37`：`SetupEnvironment` 的 `lockFile` 拆成 `configLockFile` + `settingsLockFile`
  （`setup` 今天把**同一把锁**喂给了两个不同文件的写者）。**source-breaking：5 个测试构造点必须同批改**
  （`SetupSuite.swift:36/88/210/278/379`）。

**A3. GUI 侧（2 处默认值 + 3 处显式传参 —— 原计划完全没提）**
- `EventMuteController.swift:26` 默认值 → `configLockFile`；`:38` 的显式传参随之正确。
- `PanelView.swift:96` 默认值 → `configLockFile`；`:114`（→ `EventMuteController`）与 `:414`（→ `selectPack`）随之正确。
- **验收：`MenuBarController` 构造 `PanelView` 时不传 lock（`:45-63`），所以它吃的就是这个默认值 —— 这条链是整个 D9 的兑现点。**

**测试（按 D30 重写 —— 原写法必然假绿）**
- ❌ 原计划的「持有 `play.lock` 时三个写者仍成功」**测不到东西**：现有每条锁争用测试都**显式注入**临时 lockFile，
  与默认参数无关，把锁改回共用**也不会 RED**。
- ✅ 真正有牙的断言是**接线**：`EventMuteController()` **默认构造**后 `lockFile == ClaudioPaths.configLockFile`；
  `PanelView` 的默认 `lockFile` 同理；`PlayEnvironment` 的默认 `lockFile == ClaudioPaths.playLockFile`。
  这是唯一能捕获「有人把 GUI 的默认值改回 play.lock」的测试。
- ✅ 行为回归（仍然要，但它证明的是**锁本身**分离对了）：持有 `config.lock` 时 `playSoundEvent` 仍发声；
  持有 `play.lock` 时 `setEventEnabled(lockFile: configLockFile)` 仍成功。
- 变异验证：把 A3 的两个默认值改回 `playLockFile` → 接线断言必须 RED。

**升级窗口注记（按侦察 S4 + Codex #6 更正）**
- ~~「GUI 是单进程、CLI `use` 是手动，实际不可达」~~ —— **不成立**。这不是一个「窗口」，是一个**无限期常驻**的状态：
  helper 二进制只在 `performFirstRunSetup`（`Setup.swift:151/166`）时刷新，而 **GUI 从不调用它**（`gui/Sources/` 零命中）。
  用户升级 app 后，`~/.claudio/bin/claudio` 可以**长期停留在旧版**（拿 play.lock 写 config），与新 GUI（拿 config.lock）并存。
- 后果：两把不同的锁之间**原子 rename 只防撕裂、不防 lost update**。最坏是丢一次设置更新，且**报 `.success`**（静默）。
- 严重性 P3（需要用户在旧 CLI `claudio use` 与新 GUI 之间并发写），但**不能再写成「不可达」**。真修 = config 写路径加乐观并发重读（另开 TODO）。

### 阶段 A′ — 根因：`selected_pack: ""`（**独立 PR，与滑块无关，可与 A 并行**）

> **本节是 D23 定稿的落地清单。** 上一版的实现章节里**完全没有它** —— 决议拍完了没往下抄，
> 而 §5/§6 还留着已作废的 D13 写法。**这个 bug 今天就活着**（静音钮 → `EventEnabled.swift:88`），
> 与主音量无关，所以单独一个 PR。

**A′1. helper —— 消灭毒源（D23 定稿 ①）**
- `EventEnabled.swift`：`setEventEnabled` 在 config **缺失**时 **fail-closed**，新增 `.configMissing`，**不再新建**。
  删掉 `:88` 的 `freshSelectedPack: ""`（磁盘上 `selected_pack: ""` 的**唯一产地**）。
- 删掉 `:47-52` 那段「In practice this branch is unreachable from the real panel」的**假话注释**，
  换成一句实话：它可达，所以我们拒写。
- **`freshSelectedPack` 参数从此只剩 `selectPack` 一个用户**（`Use.swift:94`，它有写前两道 pack 校验）。
  → **D13 正式作废**，新写者**不得**再带这个参数。

**A′2. helper —— 判据是两条正交轴（D23 定稿 ②，本轮最容易漏的一条）**
- **读**：把 `Setup.swift:71-75` 的 private 三态裁决升成 ClaudioCore 的 **public `packSelection(configFile:)`**
  （不存在 ∨ 空串 = 没人选过包；畸形 = 坏文件，**不猜不重建**）。
- **写**：**复用已存在的 public `probeConfigRewritable`**（`ConfigMutation.swift:98-125`，四态，**已经是 doctor 的单一真相源**）。
  **不要重造。**
- 缺了「写」这一问 → 「读得动、写不动」的 config（`{"master_volume": "0.35"}`）会被判成 `.usable`
  → 面板渲染全套活控件 → **每一次点击都必然失败**。`ConfigMutation.swift:46-49` 早就写下了这个警告。

**A′3. GUI —— 不再撒谎（D23 定稿 ③）**
- `PanelConfig.swift:25`：`loadPanelConfig` 去掉 `?? ClaudioConfig(selectedPack: "")`。
  该文件 `:23` 的注释早就写对了：「Core 只回答『这份 config 能不能用』，『不能用时面板显示什么』是面板的事」。

**A′4. 面板 —— 路由到已经存在的自救路径（D23 定稿 ④，零新机制）**
- `.needsPack` → **画廊空态「先选包」**（`selectPack` 在 config 缺失时会建出一份**正确**的 config；
  `availablePacks` 不依赖 config —— **自救路径本来就通，只是面板从来没走上去**，且这已是 ENGINEERING.md:224 的既有规格）。
  空态卡文案（**2026-07-12 已拍板为工作稿**，随 D37–D46 同批）：标题「先选包」（ENGINEERING.md:219 规格文本）
  ＋副文案「**还没有选中任何声音包。点一张卡片，Claudio 会建好配置。**」（mockup 展示板提议 —— 符合 DESIGN.md
  空态三要素「温度 + 主行动 + 上下文」；此前全仓不存在这句）。
- `.malformed` / `.unwritable` → 诚实失败态 + doctor 的可执行修复指令 + 「在访达中显示」。
  **不禁用所有控件**（写者本来就全 fail-closed）—— 要做的只是别再假装一切正常。
- → **D19 作废**：不是禁用一个滑块，是整个面板换一个诚实的态（空包态**根本不渲染滑块**）。

**测试**
- helper `PackSelectionSuite`：三态（不存在 / 空串 / 畸形）× `probeConfigRewritable` 四态的**合成矩阵**；
  重点钉住「读得动、写不动」必须**不是** `.usable`。
- helper `EventEnabledSuite` 新增：config 缺失 → `.configMissing`，且**磁盘上不得出现新文件**
  （变异验证：把 `freshSelectedPack: ""` 加回去 → 必须 RED）。
- gui `PanelConfigSuite`：`loadPanelConfig` 对缺失 config **不再**吐出 `selectedPack: ""`。

### 阶段 B — helper 写者
- 新建 `helper/Sources/ClaudioCore/MasterVolume.swift`：
  `setMasterVolume(_:configFile:lockFile:) -> Result<SetMasterVolumeOutcome, SetMasterVolumeError>`
  - **没有 `freshSelectedPack` 参数**（D23 定稿 ① —— ~~D13~~ 已作废）。config **缺失 → `.configMissing` 拒写**，
    与 A′1 改造后的 `setEventEnabled` 同形状。**新写者绝不新建 config。**
  - **先钳制再写**（`AfplayVolume.clamped`）—— 越界值绝不落盘（spec:224），非有限值绝不到达编码器（防 abort）。
  - `updateConfigJSON` 只 set `master_volume`。
  - `.updated(volume:)` 带回**实际落盘的**（已钳制的）值，调用方据此吸附滑块，无需重读文件。
  - 错误枚举逐 case 镜像 `SetEventEnabledError`（含新增的 `.configMissing`）。
- **依赖 A′**（`.configMissing` 与 fail-closed 契约在那里定型）。

### 阶段 C — GUI 纯逻辑（全部可在本机单测）
- `VolumeDragSession.swift`：D6/D10/D11/D12 四条规则的唯一归宿。
- `MasterVolumeController.swift`：镜像 `EventMuteController`（@MainActor 壳，`@Published lastError`）。
- `PanelWriteFailures.swift`：D3 的纯函数（三写者的错误 → 有序去重列表）。
- `PanelFocusOrder.swift`：`PanelFocusTarget.masterVolume` 新 case，插在最后一个 `.eventMute` 之后、
  `.dropZone` 之前（对齐线框：滑块在事件行与拖入区之间）。**不改 `panelFirstFocusTarget` 的签名**（D41 ——
  D31 的加参修法作废：空包态根本不渲染滑块，`.operational` 里它恒可操作；过滤器的 `return true`
  默认分支对 `.masterVolume` 承重，加注释写明前提）。

### 阶段 D — GUI 视图（本机只能编译，行为需真机）

> **⚠️ 本节按 D21 / D22 / D24 / D26 / D27 / D28 / D31 / D33 重写过。**

- `MasterVolumeRow.swift`（新）：
  - Slider + `.tint(ClaudioColor.clay(colorScheme))`（**D4 已实证生效**）。
  - **不用 `step:`**（D24）—— 吸附型 `Binding` 转发，`snap()` 在 `VolumeDragSession` 里
    （公式按 **D45**：`(v / 0.05).rounded() / 20`，**不是** `* 0.05`）。
  - a11y：label / `accessibilityValue` / adjustable → 走 **`adjust(to:)` 非拖动提交路径**（D26），不是 `drag(to:)`。
  - **`.onChange(of: diskVolume) { session.rebase(to: $0) }`** ← **D21，原计划漏掉的一行；`rebase(to:)` 在 WIP 里已经写好了但零调用点。**
  - 冲刷：**`.onChange(of: focusCoordinator.hideCount) { flush() }`**（D22 —— 复用 T17d 既有的 `hideCount`，
    **不新增 `closeCount`**；原文写的 `closeCount` 从未存在过，见 D22/D37 的落地注）。
    冲刷的兜底是 `.onReceive(…willTerminateNotification) { flush() }`（D22-bis）。
    **两条的闭包体里都必须真的调 `flush()`** —— `ViewWiringSuite` 切开闭包体验这一点，不是验修饰符
    在不在（掏空闭包的变异体曾实测存活：拖完点面板外面，值静默丢失，测试全绿）。
  - **按 DESIGN.md「控件行」照做**：文字标签「主音量」+ Spacer + Slider，无 tile、无喇叭图标、无百分比读数（D15）。
  - Dynamic Type：`rowWrapsToTwoLines` 时标签在上、Slider 在下 —— **触发档是 `.largest`（=「更大」）及以上**；
    「较大」（`.larger`）只隐波形、**不**折行（D44 撤销了 D34① 的假更正 —— 原文这里的「不是『更大』」恰恰是错的）。
  - **全行零 `.animation()`**，回滚瞬跳（D18 —— **注意 D18 的理由已于 2026-07-14 更正**：`PanelView.swift` 那条「本视图树零动画」的绊线早就被 T17c 踩响并改写，别再照抄它；规矩仍在，理由换了）。
- `PanelView.swift`：插入 `MasterVolumeRow`；错误行改列表渲染（D3 —— **`.writeFailed` 归这里**，
  `MasterVolumeRow` 零错误 UI，D39）；`playPreview` 传 volume；
  写成功后重读 config（D27）；
  **`.configMissing` 不进错误列表** —— 回滚 + 全量重载重路由到 `.needsPack`（D43）。
  - ⚠️ **D27 的落地形状与本行原文不同（8771946）**：原文要求「新增 `refreshMasterVolume()`（镜像
    `refreshEnabledFlags()`）」。这两个函数**在今天的源码里都不存在** —— 它们是 `PanelView` 的旧私有
    方法，早在 9cccc9c 红队重构时就随状态一起搬进了 `PanelConfigController`，并合并成
    `reloadConfigOnly()`。D27 要的**行为**（写成功 → 只重读 config、不扫包 → `config.masterVolume` 变化
    → 经 D21 的 `.onChange(of: diskVolume)` 下推给 session）由 `setMasterVolume(_:)` → `.configOnly`
    → `reloadConfigOnly()` 逐字实现，且 `PanelConfigControllerSuite` 用真磁盘钉死。新增一个
    `refreshMasterVolume()` 只会**重复**它（`/codex review 8771946`）。
- `MenuBarController.swift`：**无需改动** —— `popoverDidClose` 里 bump 隐藏计数器（D22）这件事，
  T17d 已经做完了：它的第一条语句就是 `focusCoordinator.notePanelHidden()`，恰好在
  `guard NSApp.isActive` 之上（D37 要的排序保证）。原文以为要在这里加 `closeCount`。
- `PanelFocusCoordinator.swift`：**无需改动** —— `hideCount` + `notePanelHidden()` 早已存在（T17d），
  与既有 `showCount` 完全对称。原文要求「加 `closeCount`」；照做只会得到第二个语义相同、且需要
  同样小心放置的计数器。（唯一该动的是它的 doc comment：那句「hideCount 存在的**唯一**理由是
  OnboardingViewModel」在阶段 D 之后是假话，且是危险的假话 —— 已修，8771946 的 review 收口。）
- `AudioPreviewPlayer.swift`：协议加 volume 参数。
- `AudioDropZoneView.swift`：volume 用**闭包**传（`currentVolume: () -> Double`），**不是值快照**（D28 —— 它在 `onAppear` 里绑回调，传值会定格）。
- `StateGalleryView.swift` + `PreviewFixtures.swift`：**补主音量行的各态**（D33 —— 否则新控件绕过了 DESIGN.md:161 声明的「视觉真相源」）。
  **范围按 D38**：只补 `MasterVolumeState` 族（展示板 §2 六帧即规格，含「行 + 错误行」组合帧）；
  D23 的三个路由态**不进 gallery**（走查 ⑫⑬ 兜底，`PanelRouteState` 族已登记 P3 TODO）。

### 阶段 E — 文档
- `ENGINEERING.md`：
  - **:204 线框去掉 `🔊`**（D34 —— 线框现在**有**喇叭，D15 说不要；不改它，实现完成之日就是新一轮 spec 漂移之时）。
  - :224 状态表「主音量」行**逐格**填（D32 —— 原计划说「三个 `—` 用 D16 填」，但那三格是**空/首次 · 加载 · 部分**，而 D16 是一条**「成功」**语义，填不进去）：
    - **空/首次** = config 无 `master_volume` 键 → 默认 0.8；**加载** = 无（本地读盘，瞬时）；
    - **错误** = 越界值 → 钳制 0.0–1.0 **＋ 写失败 → 滑块弹回磁盘值 + 错误行**（D12，原表漏了这一半）；
    - **成功** = **松手即时落盘**（D1，原为「拖动即时改 config」）；**部分** = 音量 0 = 全局静音，与逐事件静音**正交**（D16）。
  - 新增锁分离决议记录（D9 + D20）。
- ~~`DESIGN.md`：补滑块视觉 + 决策记录~~ ✅ **已完成**（2026-07-12）：Layout 新增「控件行（Control Row）」节
  （原生外壳 + `.tint(clay)` 升格为全 App 规则）+ Decisions Log 一条。D15–D18 即由它派生。
- `TODOS.md`：结掉主音量条 + :233 并发写条；**更正 :179 那句「DESIGN.md 已定义其视觉」的假话**
  （现在它**终于**为真了 —— 但要改成指向「控件行」节，而不是继续含糊其辞）。

## 5. 测试（诚实版 —— 不吹 100%）

**可在本机自动测（`swift run` 两包）：**
- helper `MasterVolumeSuite`：成功写 / 钳制（>1、<0、`-0.0`）/ `.lockBusy` / `.lockFailed` /
  损坏 config → `.configReadFailure` / 父目录不可写 → `.configWriteFailure` /
  ~~config 不存在 → 新建（断言 `selected_pack` 来自调用方，不是 `""` —— D13）~~
  **← 这条会把毒源原样复制进新写者。D23 定稿已判死：config 不存在 → `.configMissing` 拒写，
  且断言磁盘上不得出现新文件**（变异验证：让它新建 → 必须 RED）/ **保真**（未知顶层键、`events`、
  `selected_pack` 逐字保留）。
- helper `PackSelectionSuite` + `EventEnabledSuite` 新增（**A′**，D23 定稿）：见阶段 A′ 的测试清单。
- gui `PanelConfigSuite`（**A′**）：`loadPanelConfig` 对缺失 config 不再吐出 `selectedPack: ""`。
- helper `ConfigLockSuite`（**回归**，D9/**D30**）：~~持有 `play.lock` 时三个写者仍成功~~ **← 这条恒真，测不到东西**
  （现有每条锁争用测试都**显式注入**临时 lockFile，与默认参数无关）。**改断言「接线」**：
  `EventMuteController()` 默认构造后 `lockFile == configLockFile`；`PanelView` 默认同理；`PlayEnvironment` 默认 == `playLockFile`。
  行为回归照旧要：持有 `config.lock` 时 `playSoundEvent` 仍发声。变异验证：把 GUI 默认值改回 `playLockFile` → 接线断言必须 RED。
- helper `ConfigConcurrencySuite`（D7）：`concurrentPerform` 混跑三写者，落地 config 恒合法无损。
- gui `VolumeDragSessionSuite`（D6/D11/D12/**D21**/**D24**/**D26**）：
  1 began + N dragged + 1 ended = **恰好 1** commit；只 dragged 无 ended → `flushPending()` **必须**吐出 commit（**不是 0**）；
  未拖动 → 0 commit；baseline 0.42 未拖动 → 0 commit；`commitFailed` 后 draft == baseline；
  **`snap()`：0.42 → 0.40，0.8 恒等**（D24）；**21 档逐个断言最短字符串渲染 ≤ 4 字符**
  （`0.35` 落盘字节逐字是 `0.35`，不是 `0.35000000000000003` —— D45；变异验证：改回 `k * 0.05` → **7 档必须 RED**）；**`adjust(to:)` 在 `!isDragging` 时必须 commit**（D26 —— 对偶于「`drag` 被忽略」，
  原计划只写了后者，等于把 VoiceOver 写不进去**钉成了契约**）；
  **`rebase(to:)`：非拖动时采纳外部新值；拖动中不抢手**（D21）。
  **变异验证**：改回逐帧 commit 必须 RED；去掉 flush 必须 RED；**去掉 `rebase` 调用 → 「外部变更被采纳」必须 RED**。
- gui `MasterVolumeControllerSuite`：镜像 `EventMuteControllerSuite` 四条。
- gui `PanelWriteFailuresSuite`（D3）：多条同时存在时全部保留、顺序稳定、同因去重。
- gui `PanelFocusOrderSuite`（**回归**，**D31/D41**）：`.masterVolume` 在最后 `.eventMute` 之后、`.dropZone` 之前；
  ~~且滑块不可操作（空包）时不得进入焦点序~~ → **按 D41 改**（空包态 scope 根本不是 `.operational`，「不可操作的滑块」这个态不存在）：
  钉「四行全静音时首焦点是首行 `.eventMute`，永远不是 `.masterVolume`」＋「路由态的焦点序不含 `.masterVolume`」（后者随 A′ 的 scope 建模落地）。
- gui `ContrastSuite`（**D25**）：只加 **`clayDark` vs `panelDark`** ≥3:1。~~亮色那一对~~ **已存在**（`:211-214`），加了是逐字重复、信息量 0。
- ~~gui 预览 spy（**回归**）：`play(fileAt:volume:)` 收到的 volume == `clamped(config.masterVolume)`~~
  **← 在当前包结构下写不出来**（**D29**）：`AudioPreviewPlaying` 是 `ClaudioGUI`（**executableTarget**）里的 **internal** 协议，
  而 `claudio-gui-tests` 只依赖 `ClaudioGUICore`。**改**：把音量解析下沉成 `ClaudioGUICore` 的纯函数
  `previewVolume(for:) -> Double` 并单测；视图只转发，转发本身进真机走查。

---

## 5.2 真机走查指南（**照着做，不需要 Xcode**）

> **D25 已拍板（用户，2026-07-12）：接受「`.tint` 退回系统强调色」这个测不到的缺口，用真机走查兜底，
> 不投 `NSViewRepresentable` 做可测封装。** 代价是这条规则的守门人是**人**，不是 CI —— 所以下面第 ⑨ 条
> 是**每次动到控件行都必须重跑**的那一条，别跳。
>
> 「需要一台装 Xcode 的 Mac」这个前提**已被推翻**：CommandLineTools + 手工组 bundle 就够。
> **所以这些必须在实现的同一批里做完，不要挂账。**

### Part 0 —— 建一个能跑的 `Claudio.app`（本机，单架构，约 2 分钟）

`release.yml` 组的是双架构 universal bundle（`lipo`）。走查不需要那个 —— 下面是它的单架构等价物。
**存成 `scripts/dev-bundle.sh` 并 `chmod +x`**（仓库今天没有本地打包脚本，这是第一个）：

```bash
#!/usr/bin/env bash
# 本地走查用的 ad-hoc Claudio.app —— release.yml「Assemble Claudio.app」的单架构等价物。
# CI 那份用 lipo 合双架构；走查只需要本机这一个架构。
set -euo pipefail
cd "$(dirname "$0")/.."
APP="dist/Claudio.app"

# `--product ClaudioGUI` 不是可省的修饰：裸 `swift build -c release` 会连 claudio-gui-tests
# 一起建，而它引用 `#if DEBUG` 门控的 PreviewFixtures，Release 下编译不过（gui/Package.swift:18-23）。
swift build -c release --package-path gui --product ClaudioGUI
swift build -c release --package-path helper

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/bin" "$APP/Contents/Resources/packs"
cp "$(swift build -c release --package-path gui --product ClaudioGUI --show-bin-path)/ClaudioGUI" \
   "$APP/Contents/MacOS/Claudio"
cp "$(swift build -c release --package-path helper --show-bin-path)/claudio" \
   "$APP/Contents/Resources/bin/claudio"
cp -R packs/minimal-chime "$APP/Contents/Resources/packs/minimal-chime"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Claudio</string>
  <key>CFBundleDisplayName</key><string>Claudio</string>
  <key>CFBundleIdentifier</key><string>com.claudio.app</string>
  <key>CFBundleVersion</key><string>0.0.0-dev</string>
  <key>CFBundleShortVersionString</key><string>0.0.0-dev</string>
  <key>CFBundleExecutable</key><string>Claudio</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>12.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
printf 'APPL????' > "$APP/Contents/PkgInfo"

codesign --force --deep --sign - "$APP"
codesign --verify --verbose "$APP"
echo "✅ $APP —— 用 open dist/Claudio.app 启动（菜单栏出现波形图标，无 Dock 图标）"
```

**`LSUIElement` 是必需的**：没有它 app 会变成带 Dock 图标的普通 app，
而 `MenuBarController` 的 `NSApp.activate` / `popoverDidClose` 归还前台那套逻辑（`:144` / `:184`）
是**按 `.accessory` 设计的** —— 用错 policy 走查出来的行为不算数。

### Part 1 —— 进入运行态（**不做这步，下面全部走不了**）

面板默认停在 `.helperMissing`，**运行态根本进不去**（`~/.claudio/bin/` 不存在）。

```bash
open dist/Claudio.app                                  # 菜单栏出现波形图标
dist/Claudio.app/Contents/Resources/bin/claudio setup  # 真接管：拷 helper + 拷包 + 选默认包 + 写 hooks
dist/Claudio.app/Contents/Resources/bin/claudio doctor # 全绿才继续
```

点菜单栏图标 → 面板应显示 **header「Claudio」+ 绿点** + 四行事件 + **主音量行** + 拖入区 + 画廊。
**看不到绿点 = 你还在 onboarding，下面一条都别做。**

⚠️ **`claudio setup` 会真的改你的 `~/.claude/settings.json`。** 走查前备份，走查后可用
`claudio uninstall` 摘掉 hooks。

### Part 2 —— 走查清单

> 每条：**决议 → 怎么造状态 → 做什么 → 期望什么 → 挂了说明什么**。
> 「挂了说明什么」这一列是重点 —— 它把一次失败直接指到一条决议上，而不是让你回来猜。

| # | 决议 | 造状态 | 操作 | 期望 | 挂了说明 |
|---|---|---|---|---|---|
| **①** | **D9 + D20**<br>**（本方案最重要的一条）** | 无 | 在 Claude Code 里跑一个会连续出声的任务，**同时**用鼠标来回拖主音量滑块十几秒 | **一声提示音都不能少。** 拖动期间 Claude Code 的每个事件都照常发声 | **锁分离没到 GUI**（D20）。去查 `EventMuteController.swift` / `PanelView.swift` 的默认 `lockFile` 是不是还指着 `playLockFile` |
| **②** | **D21**<br>（滑块与磁盘脱钩） | 打开面板 → **关掉** → 终端 `jq '.master_volume = 0.30' ~/.claudio/config.json \| sponge ~/.claudio/config.json`（或手改） | **重新打开**面板 | 滑块显示 **30%** | **`rebase` 没接线**（D21）。`MasterVolumeRow` 缺 `.onChange(of: diskVolume) { session.rebase(to: $0) }`。这是本方案第二严重的洞，**必测** |
| **③** | **D22 + D37 + D45**<br>（关面板不丢值） | 无 | 把滑块拖到一个新值，**手指不松开就没法关面板** → 所以：拖到新值、松手前先移出 popover 区域再松手；以及「拖到新值 → 立刻点面板外面关掉」（**后者必测** —— 它正是 `NSApp.isActive == false` 那条路） | `~/.claudio/config.json` 里是**新值**，且拖到 35% 时文件里**逐字是 `0.35`**，不是 `0.35000000000000003`（D45） | **冲刷信号错了**（D22 —— 检查 `MasterVolumeRow` 那条 `.onChange(of: focusCoordinator.hideCount)` 的**闭包体**里真的调了 `flush()`，不只是修饰符在），或 `notePanelHidden()` 被挪到了 `guard NSApp.isActive` **之后**（D37 —— 「点别的 app 关面板」这条路上 guard 提前 return）。脏浮点 = `snap()` 还是 `k * 0.05`（D45） |
| **④** | **D22**<br>（退出 app 不丢值） | 无 | 拖到新值 → **⌘Q** 退出 | config 里是新值 | `willTerminate` 没接。**注意**：force quit / `killall Claudio` **不覆盖**（D32 已如实登记），别拿它测 |
| **⑤** | **D11 + D24**<br>（不碰就不写） | `jq '.master_volume = 0.42' ~/.claudio/config.json`（0.42 **不在** 0.05 网格上）→ 记下 `shasum ~/.claudio/config.json` | 开面板 → **看一眼滑块，什么都不碰** → 关面板 | `shasum` **一个字节不变**，仍是 0.42 | 有东西在写盘。若值变成 0.40 → **`step:` 还在**（D24 没做，render-time 网格把它吸走了） |
| **⑥** | **D24**<br>（**没有刻度点**） | 无 | 打开面板，**看滑块下方** | 轨道下面**干干净净**，没有一排小灰点；主音量行高与事件行观感一致 | **`step: 0.05` 还在**（D24）。已实证 `step:` → `numberOfTickMarks=21`，会画出一条 21 点的刻度带，撑破 28pt 行高 |
| **⑦** | **D2 + D27**<br>（试听跟随音量） | 无 | 把滑块拖到 **~20%** → **立刻**点任意一行的试听 ▶ | 声音**明显变小** | 若响度不变：要么 `AudioPreviewPlayer` 没接 volume（D2），要么写成功后 config 没重读（D27 —— 落地是 `setMasterVolume` 成功 → `.configOnly` → `reloadConfigOnly()`，**不是**一个叫 `refreshMasterVolume()` 的函数）。拖到 **0%** 再试 —— 应该**完全没声** |
| **⑧** | **D12**<br>（写失败 → 回滚 + 报错） | `chmod 500 ~/.claudio`（目录只读） | 拖动滑块 → 松手 | 滑块**瞬跳回**磁盘上的旧值（**无动画**，D18）+ 面板出现一行**错误行**（真红 ✗ 图标 + 人话） | 静默失败 = D12 没做。**滑块停在新位置而磁盘没变 = 面板在撒谎**（这正是 D12 存在的理由）。测完 `chmod 700 ~/.claudio` 改回来 |
| **⑨** | **D4 + D25**<br>**（每次动控件行都要重跑）** | 系统设置 → 外观 → **强调色**改成**红色** | 打开面板，看滑块**填充段的颜色** | 填充是**黏土色**（`#C7795B` 档，橙棕），**不是红色，也不是蓝色** | **`.tint(clay)` 被人删了 / 写错了。** 填充变成系统强调色 = 一个「真红只给真错误」的设计系统给出了一根红色主音量滑块。<br>**这条 `ContrastSuite` 结构上测不到**（纯 hex 数学，看不见 NSSlider）—— 它的守门人就是你。测完把强调色改回去 |
| **⑩** | **D26**<br>（VoiceOver 可操作） | ⌘F5 开 VoiceOver | VO 光标移到主音量 → 上/下箭头 | ① 播报「主音量，80%」；② 箭头**真的能推动**滑块；③ 推完的值**落盘**（`cat ~/.claudio/config.json` 确认） | ②挂 = `isDragging` 门控把 VO 堵死了（**WCAG 2.1.1 可操作性失败**，比丢值更严重）。③挂 = `adjust(to:)` 没接（D26） |
| **⑪** | **D17 + D44**<br>（Dynamic Type） | 系统设置 → 辅助功能 → 显示 → 文字大小，拉到**最大** | 打开面板 | 主音量行变成**两行**（标签在上、滑块整行在下），面板加宽到 360pt，**不裁切、不溢出** | 档位映射写错了。术语表（D44，真相源 ENGINEERING.md:269）：「较大」= `.larger`（**只隐波形，不折行**）·「更大」= `.largest`（**开始折行**，仍 312pt）·「极大」= `.maximum`（加宽 360pt）。顺便各退一档验：「更大」档折行但 **312pt**；「较大」档**不**折行 |
| **⑫** | **D23**<br>（空 config 不撒谎） | `mv ~/.claudio/config.json /tmp/` | 打开面板 | 面板**不再顶着绿点装正常** —— 显示「先选包」空态；**点一张包卡** → config 被重建（`cat` 确认 `selected_pack` 是**真包名，不是 `""`**） | D23 没做。**顺带验毒源**：若面板仍是运行态，**点一下静音钮**，然后 `cat ~/.claudio/config.json` —— 出现 `"selected_pack": ""` 就是 `EventEnabled.swift:88` 还在造毒（D23 ① 没做） |
| **⑬** | **D23**<br>（坏 config 诚实报错） | `echo '{"master_volume": "0.35"}' > ~/.claudio/config.json`（**读得动、写不动**的那一类） | 打开面板 | 显示**失败态** + doctor 的可执行修复指令。**不是**一个「点了必失败」的活面板 | 只做了「读」判据、没做「写」判据（D23 ②）。这份 config `loadClaudioConfig` **读得动**（静默把 `"0.35"` 换成 0.8），但 `updateConfigJSON` **拒写** → 面板会渲染全套活控件而每次点击必败 |
| **⑭** | **D14**<br>（如实记录，非验收） | 无 | 把音量设成 50% → 试听 ▶（走 `NSSound`）；再让 Claude Code 真发一次事件（走 `afplay -v`） | **只记录听感是否一致，不做通过/失败判定** | 两者增益曲线等价**未经证明**（D14）。听着差很多就在 TODOS 里补一条，别在注释里吹「完全一致」 |
| **⑮** | **D8**<br>（拖动不卡） | 无 | 快速来回拖滑块 | 跟手、不掉帧、四个事件行和画廊**不闪** | D8 的子视图隔离没生效 → 每帧重算全 panel。**本机无法实测帧率**，这一项只能靠眼睛，也正是 D8 confidence 只有 7/10 的原因 |

### Part 3 —— 收尾

```bash
chmod 700 ~/.claudio                     # 若跑过 ⑧
dist/Claudio.app/Contents/Resources/bin/claudio uninstall   # 摘掉 hooks
# 系统设置里把「强调色」和「文字大小」改回去（若跑过 ⑨ / ⑪）
```

### 关于 Tab 键 —— **别声称收益**

macOS 的「键盘导航 / FKA」**系统默认是关的**，关闭时 SwiftUI `Button` 不进 key view loop，
面板的 Tab 遍历今天本就是死的（TODOS.md 有独立的 P3 追踪它）。
`PanelFocusTarget.masterVolume` 该加还是要加 —— 纯模型必须与视图同构，否则又是一处漂移
（`.dropZone` 已经漂了一次）—— 但它**不会**让滑块变得键盘可达。
**VoiceOver 不受 FKA 影响**，所以 `accessibilityValue` / adjustable 那一半（⑩）是真实收益。
本方案不加剧、也不解决 FKA 那条。**走查时若发现 Tab 到不了滑块，那是既有缺口，不是本方案的回归。**

## 6. NOT in scope（明确不做）

| 不做 | 理由 |
|---|---|
| 逐事件音量 / 逐包音量 | v1 只有单一 `master_volume`（ENGINEERING.md）。加它要动 config schema + manifest schema。 |
| 音量 ducking（压低其它 app） | ENGINEERING.md:318 已裁定移出 v1：`afplay -v` 只能设自身音量，真做需弃 afplay 改 CoreAudio。 |
| 深夜降音量（`night_dim`） | T2 已移出 v1 → v2。 |
| 用 `afplay` 替代 `NSSound` 做试听 | 曲线完全一致的唯一保证，但引入进程 spawn 延迟 + 新失败模式。D14 先如实注释 + 记 TODO。 |
| 规范化 DesignTokens（从 DESIGN.md 生成） | TODOS.md:149 的既有 P3。本次只加 `.tint(clay)`，不新造颜色，不触发它。 |
| GUI 主线程全量扫包的异步化 | TODOS.md:269 的既有 P3。滑块不加剧它（松手才写，且不触发 `refresh()`）。 |
| ~~修 `setEventEnabled` 的 `freshSelectedPack: ""` 契约~~ | **← 本轮已拉回 scope 内（阶段 A′ / D23 定稿）。** 原理由「D13 只保证新写者不重蹈」是**空转**的：`freshSelectedPack` 只在 config 缺失的 else 分支被读，而那恰恰是面板手里只有空串的分支。~~改它要单独一轮~~ → 它**就是**单独一个 PR（A′），但在**本轮**做。 |
| `OnboardingViewModel.onPrimaryAction` 接线（**D35**） | 「接管 Claude Code」今天是个死钮，但那是 onboarding 的洞，与主音量正交。**独立 P1，单独 PR。** |
| config 缺失 **且** 用户包目录为空时的逃生口（**D36**） | A′ 的自救路径要求画廊里至少有一张卡。包目录空 → 零卡 → 无路可走。**登记为 P2 TODO**，不在 A′ 范围。 |

## 7. 失败模式表

| 新代码路径 | 一种真实的生产失败 | 有测试？ | 有错误处理？ | 用户看得见？ |
|---|---|---|---|---|
| `setMasterVolume` 拿锁 | 另一个 `claudio use` 正在写 → `.lockBusy` | ✅ | ✅ | ✅ 错误行「请稍后重试」+ 滑块弹回（D12） |
| `setMasterVolume` 写盘 | `~/.claudio` 只读 → `.configWriteFailure` | ✅ | ✅ | ✅ 错误行 + 滑块弹回 |
| `setMasterVolume` 读 config | 用户手改坏了 config → `.configReadFailure` | ✅ | ✅ | ✅ 错误行带可执行修复指令 |
| `setMasterVolume` 非有限值 | 调用方传 NaN → 进程 abort（exit 134） | ✅ | ✅ 先钳制 → 不可能到达编码器 | — 不可达 |
| 拖动中 popover 关闭 | `onEditingChanged(false)` 不补发 → **值丢失** | ✅ 纯单测 | ✅ **`popoverDidClose` 冲刷（D22）** —— ~~`onDisappear`~~ 不可信；**位置按 D37：`:185`，guard 之上**（放 guard 后面 = 最常见关闭路径上不执行，且单测测不到） | 值照常落盘 |
| 拖动中 app 退出（⌘Q / 注销 / 关机） | 同上 | ✅ 纯单测 | ⚠️ `willTerminate` 冲刷走**非阻塞锁**，`.lockBusy` → 写失败，而此时错误行**没有观众** → **静默丢值**（D32） | **可能丢一次拖动** |
| 拖动中 **force quit / `killall`** | 同上 | ❌ | ❌ **不覆盖**（D32 —— 可接受，但不再假装覆盖了） | **丢值，静默** |
| 开面板不碰滑块 | ~~SwiftUI 网格吸附把 0.42 改写成 0.40~~ | ✅ 纯单测 | ✅ **D24 去掉 `step:` → 根本不存在 render-time 网格**；「不变不写」（D11）独立成立 | 0.42 不动 |
| **重开面板 / 外部改了 config** | **`@State` 只 seed 一次 → 滑块显示磁盘上没有的值，且不自愈**（D8 × D12 互斥） | ✅ 纯单测 | ✅ **`.onChange(of: diskVolume) { rebase }`（D21）** —— **原计划漏掉了这条路径** | 滑块跟到磁盘值 |
| config.json 不存在时**点静音钮** | 造出 `selected_pack: ""` → 面板撒谎 + 恢复无指引 | ❌ **今天就能触发** | ❌ **今天无任何处理**（D23） | **面板顶着绿点声称一件假话** |
| config.json 不存在时首拖滑块 | 同上 | ✅ | ✅ 根因修在 `loadPanelConfig`（**D23**，~~D13 空转~~） | 不可能发生 |
| 写成功但 UI 不同步 | UI 显 30%、磁盘 80% | ✅ 纯单测 | ✅ **`reloadConfigOnly()` 重读磁盘**（D27 —— 与静音那一半共用同一个函数；`refreshMasterVolume()` / `refreshEnabledFlags()` 都不存在，见 D27 落地注） | — |
| 滑块被人删掉 `.tint` | 填充退回**系统强调色**（可能是红 —— DESIGN.md 明令真红只给真错误） | ❌ **`ContrastSuite` 结构上测不到**（纯 hex 数学，看不见 NSSlider） | — | ⚠️ **只能靠真机走查兜住**（D25） |

**critical gap（无测试 + 无错误处理 + 静默）：~~0 条~~ → 1 条。**
`selected_pack: ""` 经**静音钮**（`EventRowView.swift:412`，无 `.disabled`）→ `EventEnabled.swift:83`（config 缺失时用空串新建）。
**今天就活着，与滑块无关，且原计划把它划到了 scope 外。** 见 **D23** —— 本轮把它拉回 scope 内。

## 8. 并行化

| 阶段 | 触及模块 | 依赖 |
|---|---|---|
| A 锁分离 | `helper/Sources/ClaudioCore/`（Paths/Play/Use/EventEnabled/SettingsInstaller/Setup）**＋ `gui/`（PanelView / EventMuteController）** ← **D20** | — |
| **A′ 空包根因** | `helper/`（EventEnabled / Setup→packSelection）**＋ `gui/`（PanelConfig / PanelView 状态路由）** ← **D23 定稿** | — |
| B helper 写者 | `helper/Sources/ClaudioCore/` | A（要 `configLockFile`）**＋ A′（要 `.configMissing` 契约）** |
| C GUI 纯逻辑 | `gui/Sources/ClaudioGUICore/` | B（`MasterVolumeController` 调 `setMasterVolume`） |
| D GUI 视图 | `gui/Sources/ClaudioGUI/` | C**＋A′**（空包态不渲染滑块 → 焦点序，D31） |
| E 文档 | `*.md` | — |

- **Lane 1**：A → B → C → D（严格串行，同模块 + 真依赖）
- **Lane 2**：**A′**（独立 PR，与 A 无交集；A 改锁、A′ 改契约，`EventEnabled.swift` 两边都碰 → **A 先合，A′ rebase**）
- **Lane 3**：E（独立，可并行）

`VolumeDragSession` / `PanelWriteFailures` / `PanelFocusOrder` 三者互不依赖，C 内部可三路并行。

**A 与 A′ 各自单独一个 PR** —— 两者都是**今天就活着**的 bug 修复（A 在吞提示音，A′ 在让面板顶着绿点撒谎），
与滑块无关。混进来会让「加个滑块」的 PR 里藏着一个并发契约变更 + 一个状态机重构。
**唯一的排序约束**：两者都改 `EventEnabled.swift`（A 改它的锁，A′ 改它的 fail-closed 契约）→ **A 先落，A′ 在其上 rebase**。

## 9. 绿灯

- `swift run --package-path helper claudio-tests` 退出 0
- `swift run --package-path gui claudio-gui-tests` 退出 0
- 两包 `swift build` 零 warning
- **五条变异验证全部 RED**（否则对应的测试是恒真的空测试）：
  ① GUI 默认锁改回 `playLockFile` → 接线断言 RED（D30）；
  ② 去掉 `rebase(to:)` 调用 → 「外部变更被采纳」RED（D21）；
  ③ `setEventEnabled` 把 `freshSelectedPack: ""` 加回去 → 「不得新建 config」RED（D23）；
  ④ 改回逐帧 commit / 去掉 flush → `VolumeDragSessionSuite` RED（D6/D22）；
  ⑤ `snap()` 改回 `k * 0.05` → 21 档渲染断言 **7 档 RED**（D45）。
- 真机走查按 **§5.2** 的 15 条清单走完（ad-hoc 签名 app bundle，不需要 Xcode）

## 10. 评审来源

- **四段评审**（架构 / 代码质量 / 测试 / 性能）：9 个发现，0 个 critical gap。
- **外部声音**：Codex（gpt-5.5, high reasoning）—— 9 条，全部成立，其中 3 条推翻了 Claude 侧的结论：
  ① 「松手才写解决了吞声音」→ 只是缩小窗口，根因是锁的共用（D9）；
  ② 「只拖不松手 = 0 次写」当特性 → 那是把数据丢失写成规格（D10）；
  ③ 「100% 覆盖」→ 假的，最危险的行为恰恰不可自动测（第 5 节已改成诚实版）。
  另有三个 Claude 完全漏掉的洞：`selected_pack: ""`（D13）、`0.42` 被吸走（D11）、写失败后 UI 状态未定义（D12）。
- **一份未测试的探索性实现**在分支 `feat/master-volume-slider` @ `cbc02f0`（helper 能编译，零测试，**勿直接信任**）。
  实现阶段应按本文件 TDD 重来，或以它为起点补齐测试。
- **设计缺口复核（2026-07-12）**：评估过要不要跑 `/plan-design-review`，**判定不跑**。四路侦察 + 一轮证伪的结论是：
  所谓「必须新造轨道 / 拇指 / 焦点环 / pressed 态」全是**假缺口** —— 原生控件的这些部件由 AppKit 绘制，
  且 `OnboardingView.swift:102-103` 已是「原生外壳 + `.tint(clay)`」的既成先例；「百分比数字的字体 / 对齐 / 定宽」
  是**假前提**（线框 ENGINEERING:204 本就没有数字）。真缺口只有 5 条，已收成 D15–D19，并补进 DESIGN.md
  「控件行（Control Row）」节。**代价 8–10 行文档，而不是一轮 12 步、带 mockup 对比板的交互式评审**
  （后者还会给一个原生 macOS Slider 画 AI mockup —— 逆着 DESIGN.md:161「视觉真相源 = 仓库内 state gallery」）。
- **第三轮 · 交互式 mockup 展示板（2026-07-12，用户发起）**：
  https://claude.ai/code/artifact/5fc6437a-d209-4d0e-b75b-e1404850699f ——
  上一条对「给原生 Slider 画 mockup」的拒绝**对滑块解剖仍然成立**；展示板的边界是三层诚实声明
  （HTML 可验 / AppKit 只能近似、附实证对照色 / 只能真机，单列一节共 10 行「本页验不了」）。
  面板各态、文案、错误行、路由、焦点序、Dynamic Type 四档、`VolumeDragSession` 全逐行可验（色值 1:1 取自
  `ClaudioColorHex.swift`，`/browse` QA 过计算色与几何）。它自证出 **10 项议题**（板内 §7），
  经 132 条断言的对抗证伪（其中 17 条被推翻并修正，含板子第一版照抄 D34① 的错误指控）后，
  用户授权拍板为 **D37–D46** —— 其中 D45 是**模拟器实拖跑出来的**，任何静态评审都没抓到。

## 11. 第 11 节的三个洞 —— **已收口**（2026-07-12 第二轮 eng review）

| 原编号 | 收口去向 | 结论变化 |
|---|---|---|
| **P0-a**（`isDragging` 门控堵死 VoiceOver / 键盘） | → **D26**（`adjust(to:)` 非拖动提交路径） | 成立，且**比原描述更严重**：不是「改了没存」，是「控件根本推不动」（binding setter 被门掉 → 显示值弹回）—— WCAG 2.1.1 可操作性失败。修法有一个**前置条件**原文没写：必须先有 **D24**（去掉 `step:`），否则把 setter 的 `!isDragging` 分支路由到 `adjust(to:)` 会重新打开 render-time 写入。 |
| **P0-b**（写成功后 `@State config` 不重读） | → **D27** | **结论对，证据错**。「既有写者也不重读」是**假的** —— 静音写者成功后会重读 config，其注释明写 re-detect-don't-patch 纪律。所以主音量该做的是**复用那条既有路径**，而不是发明新机制；同时 D12 的「内存 patch baseline」与该纪律冲突，应改为重读。<br>（本行原引 `refreshEnabledFlags()` / `PanelView.swift:438-444`，两者今天都不存在：那个方法早在 9cccc9c 就搬进 `PanelConfigController` 并合并成 `reloadConfigOnly()`。结论不变，符号名以 D27 落地注为准。） |
| **P0-c**（`selected_pack: ""` 可达） | → **D23**（根因修 `loadPanelConfig`） | **严重性被低估了**。它不是「滑块上线后可能坏」，而是**今天就活着**：静音钮（`EventRowView.swift:412`，无 `.disabled`）→ `EventEnabled.swift:83`（config 缺失时用空串新建）。D13（强制传 pack）是**空转** —— `ConfigMutation.swift:144` 实证 `freshSelectedPack` 只在 config 缺失的 else 分支被读，而那恰恰是面板手里只有空串的分支。原计划把「修 `setEventEnabled`」划到 scope 外，本轮**拉回 scope 内**。 |

**新增的、上一轮完全没看见的洞**：D20（锁分离漏了 GUI）、D21（D8 × D12 在 SwiftUI 语义上互斥）、
D22（D10 押在本仓库已否定的回调上）、D24（`step:` 会画 21 个刻度点）、D29（预览 spy 测试写不出来）、
D30（`ConfigLockSuite` 恒真）。**其中 D20 与 D21 各自足以让本方案「照做即坏」。**

## GSTACK REVIEW REPORT

| Review | Trigger | Why | Runs | Status | Findings |
|--------|---------|-----|------|--------|----------|
| CEO Review | `/plan-ceo-review` | Scope & strategy | 0 | — | — |
| Codex Review | `/codex review` | Independent 2nd opinion | 1 | issues_found | 6 findings, 6 absorbed (D20/D22/D23/D28/D32 + 升级窗口) |
| Eng Review | `/plan-eng-review` | Architecture & tests (required) | 2 | issues_found | 17 issues (3 P0), 1 critical gap, 17 new decisions (D20–D36) |
| Design Review | `/plan-design-review` | UI/UX gaps | 0 | skipped-by-decision | 视觉缺口经 D15–D19 + DESIGN.md「控件行」收口；本轮又在其上发现 D24/D33/D34 |
| DX Review | `/plan-devex-review` | Developer experience gaps | 0 | — | — |

**CODEX:** gpt-5.5 high，6 条全部成立，其中 2 条与 Claude 侧独立同得（阶段 A 漏 GUI；`onDisappear` 不可信），
1 条把 P0-c 从「潜在」升级为「今天就活着的 bug」（`EventEnabled.swift:83` 静音钮可造出空包 config），
1 条推翻了「升级窗口实际不可达」。

**CROSS-MODEL:** 无实质分歧。Claude（10 路源码侦察 + 132 次对抗证伪）与 Codex 在四条 P0 上完全重合。
唯一的模型内分歧发生在 **Claude 内部**：一路侦察用离屏渲染探针得出「`.tint(clay)` 生效」，
而 main loop 用 **key + active 窗口 + `screencapture` 真实像素**复测，先得出「不生效」（clay 像素数 0，容差判据错），
再看图确认**确实生效**（渲染色 `#C7795B`，Display P3 → sRGB 偏移）。
**方法学产出：离屏 / 非 key 窗口会把 macOS 强调色去饱和成灰 —— 任何控件视觉验证必须在 key 窗口下做。**
这条实证同时否掉了本轮最初的头号怀疑（「`.tint` 在 NSSlider 上是 no-op」），并附带抓出 D24（`step:` 会画 21 个刻度点）。

**VERDICT:** ENG NOT CLEARED — 3 条 P0 + 1 条 P1 未落地实现（D20 / D21 / D22 为 P0；D23 经复核降为 P1）。
计划本身已按本轮结论修订完毕，**可以开始实现**；但在 D20–D23 落地并通过测试前，不得视为 ready to ship。
建议 **阶段 A（锁分离，含 GUI）与阶段 A′（`selected_pack: ""` 根因）各自单独一个 PR** —— 两者都是与滑块无关的既存 bug 修复；
两者都改 `EventEnabled.swift`，**A 先落，A′ rebase**。

**下游传播补记（2026-07-12，收尾自查）**：D23 定稿当时**只落进了决议表，没有往实现章节抄** ——
阶段 B 的签名还带着已作废的 `freshSelectedPack`，§5 测试表还写着「config 不存在 → **新建**」
（**照那条测试实现，等于把毒源原样复制进新写者**），§6 还把 `setEventEnabled` 的修复列在 scope 外，
而 D23 定稿的四层修法在 §4 里**没有任何阶段承接**。已补：**新增阶段 A′**（四层逐条 + 测试 + 变异验证）、
阶段 B 去掉 `freshSelectedPack` 并改为 `.configMissing` fail-closed、§5/§6/§8/§9 同步。
**教训：一条推翻既有决议的裁决，落表之后必须再走一遍全文 —— 决议表和实现清单脱节，比没做这个决议更危险。**

**已知且已接受的缺口（用户拍板，2026-07-12）**：`.tint(clay)` 被删 / 写错 → 滑块填充退回系统强调色，
`ContrastSuite`（纯 hex 数学，看不见 NSSlider）**结构上捕获不了**。决定**接受**，用 **§5.2 走查清单第 ⑨ 条**兜底，
不投 `NSViewRepresentable`。**守门人是人，不是 CI —— 每次动控件行必须重跑第 ⑨ 条。**

**第三轮补记（2026-07-12，mockup 展示板 + 用户授权拍板）**：展示板自证出 10 项未收口议题，
一度使下面那行「NO UNRESOLVED DECISIONS」**变假**。用户授权（裁决原则：功能完整易用 · UI 好看 ·
这版设计完可直接用）后以 **D37–D46** 全部收口：D44 **撤销了第二轮的 D34①**（假修正 —— 上一轮的
「源码逐字比对」自己把「较大/更大」的中文档位对错了位；**逐字比对也会比错行，结论必须回真相源二验**），
D45 修掉 `snap()` 的脏浮点（**模拟器实拖发现，静态评审零命中**），D44/D46 的文档更正已当场落纸。
实现顺序不变：A → A′ rebase → B/C/D，E 随时。该行重新为真：

NO UNRESOLVED DECISIONS
