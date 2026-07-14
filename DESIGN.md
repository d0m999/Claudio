# Design System — Claudio

> 视觉设计系统（美学 / 字体 / 配色 / 间距 / 布局 / 动效 / 声音视觉语言 / App 图标）。
> 由 `/design-consultation` 生成 2026-07-06。工程 / 产品 spec 见 [ENGINEERING.md](./ENGINEERING.md)。
> 在线预览（暖色工具主义 v1）：https://claude.ai/code/artifact/18b03022-1d76-4b8c-ad47-4ce07e16f837

## Product Context（产品上下文）

- **是什么**：Claudio —— 一个 macOS 菜单栏 app，给 Claude Code 的每个事件播一个语义化的声音；主打开箱即用、版权干净（CC0）的策展声音包，可切换。
- **给谁**：Claude Code 重度用户 = 开发者（长在终端里、用 AI 编码 agent）。
- **v1 受众与安装摩擦（与 ENGINEERING T3 对齐）**：v1 **不签名、未公证**，面向能自绕 Gatekeeper 的技术用户 —— 定位是**技术用户低摩擦**，**不是「零摩擦安装」**。签名 + 公证是**面向非技术用户 / 广泛发布前**的硬门槛。因此 onboarding 视觉须诚实交代「未签名 + 绕过步骤」（见下方 State Components onboarding 卡与 ENGINEERING 用户旅程步骤 1），不作零摩擦承诺。
- **空间 / 同类**：macOS 菜单栏工具 · 开发者工具 · 音频类 app。参照：`claude-sounds`、`claudecodenotify`、Bartender、Ice、Rogue Amoeba SoundSource、Raycast、Linear、Warp、CleanShot、Notion Calendar、Amie。
- **项目类型**：原生 macOS SwiftUI 菜单栏 app + 落地页 / GitHub README。
- **记忆点（唯一）**：**不回头也知道状态** —— 光靠声音就知道 Claude 现在什么状态。所有设计决策服务于这一句。

## Aesthetic Direction（美学方向）

- **方向**：暖色工具主义（Warm Utilitarian）—— macOS 原生骨架（毛玻璃/近实心表面、SF Pro、系统设置式分组圆角卡片），Claude 暖色皮肤，波形母题给灵魂。
- **装饰程度**：intentional —— 主要靠排版 + 材质，一个招牌母题：**波形**（贯穿 App 图标 / 声音芯片 / 菜单栏视觉回放）。不靠视觉噪音。
- **基调**：像一台深夜用的、有触感的音频硬件 / 信号仪表，暖、克制、精确；个性来自**时序与声音**，不是花哨的图形。
- **核心张力（差异化）**：整个开发者工具圈都是冷蓝灰（Linear `#08090A` / Raycast `#07080A`）。Claudio 刻意往**暖**走，借 Claude 自己的调色板 —— 既天然对齐「Claude Code 伴侣」身份，又跳出同质化。（跨模型印证：Codex 独立方向亦收敛到同一暖色 + 四事件四色 + StopFailure 绝不用红。）
- **参考站点 / 产品**：Linear、Raycast、Warp、CleanShot X、SoundSource（Rogue Amoeba）、Bartender、Ice、Notion Calendar、Amie、Anthropic / Claude 品牌、Teenage Engineering。

## Typography（字体）

三个角色，各司其职。**承载个性的展示字是真选的字体；App 内用系统 SF Pro 是刻意的原生正确，不是「放弃排版」；数据一律等宽 = 开发者的母语视觉信号。**

- **展示 / 品牌（落地页 · wordmark · hero · 营销）**：**General Sans**（Fontshare / Indian Type Foundry）—— 温暖的人文无衬线，有个性但不喧哗，避开了 Inter / Space Grotesk 的收敛陷阱。
  - **加载策略**：**自托管** woff2（一次性下载放进落地页资源，不依赖 Fontshare 在线 CDN —— 该 CDN 在部分网络不可靠）。
  - **可靠替代**（若不想自托管）：Bricolage Grotesque 或 Hanken Grotesk（均 Google Fonts 托管、OFL）。**在线预览的展示字即用 Bricolage Grotesque 作替身**（因构建环境 Fontshare 不可达），最终以 General Sans 为准。
- **App 内 UI（面板控件 · 标签 · 快捷键提示 · 一切原生 chrome）**：**SF Pro（系统字，`-apple-system`）**。这是原生 macOS app，系统字才「像 macOS」；用 web 字体反而破坏原生感。**刻意选择，非默认放弃。**
- **数据 / 表格 / 代码（事件 id · 包 id · token 数 · 计时 · 波形刻度 · CLI · README 代码块）**：**JetBrains Mono**（OFL，需 `tabular-nums`）—— 开发者可信度信号，开源友好。App 内可用系统 **SF Mono** 等价替代。
- **衬线强调（risk）**：**Fraunces**（italic）—— 仅用于 hero 强调词与落地页大标题，跳出清一色无衬线、给「精心设计的作品」信号。Google Fonts / 自托管均可。

**字号阶梯（px）**
| 层级 | 字体 | 值 |
|---|---|---|
| Hero | General Sans 600 | clamp 44 – 86 / line-height .98 / letter-spacing -.03em |
| Section H2 | General Sans 600 | 26 – 32 / -.02em |
| 落地页标题 / hero 强调 | Fraunces italic 500 | 30 – 46 |
| 面板标题 | SF Pro semibold | 14 – 15 |
| 行标签 | SF Pro regular/medium | 13 |
| 次要 / 状态 | SF Pro | 11 |
| 数据 / 事件 id | JetBrains Mono | 10 – 12（tabular-nums） |

## Color（配色）

- **策略**：**restrained brand + functional semantic**。中性来自 Claude 暖调色板；品牌强调**只有一个**（黏土），克制使用；**四事件语义色是功能性的**（产品灵魂 = 听声辨状态，事件必须有可视身份）。
- **一个招牌绑定**：**Notification（要你确认）的事件色 = 品牌黏土** —— App 唯一一次「用 Claude 的颜色说话」，正是需要一个人的时候。
- **一个可读性约束**：**Stop 实心粗勾 vs SubagentStop 空心勾** = 同形状两权重 = 一眼分「大完成 / 小完成」。

**中性 + 品牌（暗色为主基调，亮色完整支持）**
| Token | Dark | Light |
|---|---|---|
| `bg` 底 | `#141413` | `#FAF9F5` |
| `surface` 表面 | `#1C1A17` | `#FFFFFF` |
| `surface-2` 抬升 | `#262320` | `#FFFDF7` |
| `panel` 面板 | `#1A1815` | `#FFFDF8` |
| `cream` 奶油（图标底） | `#F0EEE6` | `#F0EEE6` |
| `hairline` 描边 | `rgba(245,235,221,.10)` | `rgba(20,20,19,.10)` |
| `hairline-strong` | `rgba(245,235,221,.16)` | `rgba(20,20,19,.16)` |
| `text` 主文字 | `#F4EBDD` | `#201D19` |
| `text-2` 次要 | `#B0AEA5` | `#6F665B` |
| `text-muted` 弱 | `#6F665B` | `#938A7E` |
| **`clay` 品牌强调** | `#D97757` | `#C4633C` |
| `clay-hover` | `#E68A5C` | `#D97757` |
| `clay-soft` 底色 | `rgba(217,119,87,.15)` | `rgba(196,99,60,.12)` |

**四事件语义色**（固定语义 token，随模式微调对比度）
| 事件 | 含义 | Dark | Light | 字形 |
|---|---|---|---|---|
| ✅ `Stop` 干完了 | 完成、落定 | `#34C759` | `#288B43` | 实心粗勾 `checkmark.circle.fill` |
| ⏸ `StopFailure` 中断了 | 限流 / 欠费 / 过载 / 认证（**非代码 bug**） | `#FF9F0A` | `#AC6900` | 暂停 `pause.circle.fill` · **琥珀，绝不用红** |
| ✋ `Notification` 要你确认 | 等你确认 | `#D97757`（=clay） | `#C4633C` | 铃 / 举手 `bell.badge.fill` · **品牌黏土** |
| ◦ `SubagentStop` 子任务完成 | 从属完成 | `#5E5CE6` | `#5B59D6` | **空心**勾 `checkmark.circle` · 更暗 |

> **`StopFailure` 亮色的两次调深（如实记录，因为第一次没达成目的）**：原 `#E08600` → `#C87A00` → 现 `#AC6900`。第一次调深（`#E08600 → #C87A00`）是**专为**过事件字形对表面的 **≥3:1**（WCAG 1.4.11 非文本对比）而授权的，但它**并没有达成目的**：当时 `ContrastSuite` 断的是「字形 vs 纯 `panel`」，而字形实际画在**事件色 @15% 自染**的 tile 上 —— **断言断错了那一对**。对纯 `panel` 它从 2.73:1 升到 3.31:1（看着过了），对**真实的自染 tile 底**却只从 2.36:1 升到 2.82:1，**依然不及格**。故本次进一步调深到 `#AC6900`（对真实 tile 底 **3.59:1**，见下注）。两次都只降明度、**不换色相** —— 仍为暖琥珀、绝不用红。UI 语义 `warning` token 是独立用途（校验提示，非事件字形），当时保留 `#E08600`（**已于 2026-07-12 · T17f 调深为 `#B87000`** —— 它当年之所以能带着一个连 ≥3:1 都不过的值留在表里，正是因为「没有任何视图渲染它」＝「没有任何人量过它」，见下方 T17f 记录）；同理 UI 语义 `success` 亮色仍为 `#2FA24E`，不随 `Stop` 调深 —— 事件层与 UI 语义层**刻意分叉**（这条分叉今天仍然成立：`warning` `#B87000` ≠ `StopFailure` `#AC6900`）。`gui` 侧由 `ContrastSuite.swift` 逐对数学断言钉死。

> **事件字形 tile 保持事件色自染（15%），改为调深两个亮色事件色 —— 对比度硬约束，不是审美选择**（2026-07-11 授权；**同日第二次修正**，第一次修法已被推翻）
> 事件行的 24pt 字形 tile（见「行结构」）是 `RoundedRectangle.fill(事件色.opacity(0.15))` —— **字形画在自己颜色的 15% 底上**。实测原色值下亮色字形对**真实**底色只有 `Stop` **2.75:1** / `StopFailure` **2.82:1**，双双不过 WCAG 1.4.11 对非文本图形的 **≥3:1**。（根因：旧 `ContrastSuite` 断的是「字形 vs 纯 `panel`」——**断错了那一对**，恰好是能过的那一对，所以一直假绿。）
>
> **同日的第一次修法（tile 底改中性 `surface-2`）已被独立评审推翻，不要再提。** 它的致命问题：亮色下 `surface-2` `#FFFDF7` 对 `panel` `#FFFDF8` = **1.0006:1** —— 它们**是同一个颜色**。所以 tile 在亮色下**整个消失了**：所谓「字形过了 ≥3:1」靠的是「tile 根本不存在、字形直接落在面板上」，而不是换了一块真的底。这与「行结构」白纸黑字的「事件字形 tile 24pt, **事件色**, 圆角6」直接冲突（tile 本该是事件色的），副作用还连带让试听键「已启用」的圆形底在亮色下一并消失，启用/禁用少一个视觉区分。**用对比度达标为名把一个设计元素变没，不是修复。**
>
> **决议（现行）**：**tile 保持事件色自染 15% 不变**；改为把**两个**亮色事件色调深 —— `Stop` `#2FA24E → #288B43`、`StopFailure` `#C87A00 → #AC6900`。`Notification` `#C4633C`（= clay 品牌招牌绑定）与 `SubagentStop` `#5B59D6` **不动**；**暗色四事件全部不动**（本来就宽裕）。**四事件语义一个不改：`StopFailure` 仍是琥珀，绝不用红** —— 调深的只是亮色明度，不是换色相。
>
> | 事件 | 亮色 hex | 字形 vs **真实 tile 底**（事件色 @15% 覆在 `panel` 上） | tile 对面板（可见性） |
> |---|---|---|---|
> | `Stop` | `#2FA24E` → **`#288B43`** | 2.75:1 ❌ → **3.53:1** ✅ | 1.20:1 看得见 |
> | `StopFailure` | `#C87A00` → **`#AC6900`** | 2.82:1 ❌ → **3.59:1** ✅ | 1.21:1 |
> | `Notification` | `#C4633C`（不变） | **3.32:1** ✅ | 1.20:1 |
> | `SubagentStop` | `#5B59D6`（不变） | **4.37:1** ✅ | 1.23:1 |
>
> 全局最差 **3.06:1**（暗色 `SubagentStop`，未改），过 ≥3:1。
>
> **断言方式同批改掉（这是本次最该记住的部分）**：`ContrastSuite.swift` 现在直接对**真实复合底**求值 —— `compositedHex(事件色, over: panel, alpha: 0.15)`，断的就是屏幕上真正渲染的那一对；并**额外**钉住「**tile 自身对面板必须可见**（≥1.10:1）」。加后面这条的理由正是上面那次翻车：**只断言字形对比度是不够的 —— tile 存不存在也得钉住**，否则「把 tile 变没」会被测试判为通过。

**UI 语义色（提示 / 校验，独立于事件层）**
| 用途 | Dark | Light | 备注 |
|---|---|---|---|
| success | `#34C759` | `#2FA24E` | |
| **warning（告知，非错误）** | `#FF9F0A` | `#B87000` | 「Claudio 替你做了主」那一类**告知**（搬走一个读不出的包 / 替你换掉一个已失效的选包）；**不是**错误，绝不上真红；**且只做图标、不做正文**（见下注） |
| **error（真错误）** | `#FF453A` | `#E0453A` | **只**给 App 自身真错误（如写不进 settings.json）；**绝不**用于事件层；**且只做图标、不做正文**（见下注） |
| info | `#0A84FF` | `#0A72D0` | ⚠️ 仓库里**尚未落地**（`ClaudioColorHex` 没搬它）——第一个要用它的视图，请先按 `warning` 的先例量一遍对比度再落值 |

> **`warning` 亮色 `#E08600 → #B87000`（2026-07-12 授权 · T17f）**
> 这是 `Stop`（`#2FA24E → #288B43`）、`StopFailure`（`#E08600 → #C87A00 → #AC6900`）之后**同一条先例的第三次**：一个亮色 token 在它**真实的底**上量一遍，不及格就降明度、不换色相。
> 触发它的是 `warning` 的**第一个使用者**（T17f 的 ⚠ 提示行）。此前这一格从没有任何视图渲染过，**于是也从没有人量过它** —— 这正是一个不及格的值能在表里躺到今天的全部原因。实测：`#E08600` 对亮 `panel` 只有 **2.73:1**、对 `surface-2` **2.72:1**，**连图标的 ≥3:1（WCAG 1.4.11）都不过**（旧注只警告了「当正文用要过 ≥4.5:1」，漏掉了图标这一半，而提示行恰恰只以图标形态使用它）。
> 新值 `#B87000`：对 `panel` **3.86:1**、对 `surface-2` **3.85:1**，双双过关。暗色 `#FF9F0A` 对暗 `panel` 8.62:1，宽裕，**不动**。
> **刻意不复用 `StopFailure` 的 `#AC6900`**：那会把「UI 语义层与事件层刻意分叉」当场合并成同一个 hex，而这条分叉本身就是写下来防手抄的。**四事件语义一个不改：`StopFailure` 仍是琥珀，绝不用红。**
> 现由 `ContrastSuite.swift` 四条 ≥3:1 断言（亮/暗 × `panel`/`surface-2`）钉死 —— 它不再是一个没人量过的值。

> **真红 `error` 只做图标，配套文案用 `text-2`**（2026-07-11 授权）
> 实测亮色真红 `#E0453A` 对 `panel` / `surface-2` = **4.07:1 / 4.06:1** —— 过非文本图形的 ≥3:1，**不过**正文的 **≥4.5:1**。而它此前被当**正文**用（包卡的「文件丢失」9pt、onboarding 详情）。
> **决议**：真红**只用于图标**（如 `xmark.circle.fill` / 拒绝行的 `circle-x` 字形），**配套的报错文案一律改用 `text-2`**（5.54:1，过 ≥4.5:1）。**品牌真红的色值不变**（它作为图标完全合格，问题只在用法）。`ContrastSuite.swift` 把这条钉成两句：真红只出现在 ≥3:1 那一组；同时正向断言「真红亮色 < 4.5:1」——哪天有人把真红调亮到够正文，这条会红并提醒回来重新决策。

- **暗色模式策略**：暗色为主基调（「深夜音频硬件」）。非简单反相 —— 中性重新取暖色阶，事件色略降亮/升深保持在两底都可读；品牌黏土在亮底加深到 `#C4633C` 保对比。

## Spacing（间距）

- **基准单位**：4px。
- **密度**：comfortable-compact（菜单栏面板要紧凑但不挤）。菜单栏面板行高 ~28pt，面板内边距 12–13pt。
- **阶梯**：2 · 4 · 8 · 12 · 16 · 24 · 32 · 48。

## Layout（布局）

- **策略**：App = grid-disciplined（系统设置式分组圆角卡片、行=左标签右控件、可预期对齐）；营销 = hybrid（落地页可编辑化、真机构图）。
- **菜单栏面板**：宽 **312pt**；`NSPopover` 带尖角。
- **面板材质（关键决策）**：**近实心暖表面（`panel`）+ 1px `hairline-strong` 描边 + 柔和阴影**，**不用**满毛玻璃 vibrancy —— 因为 vibrancy 会被壁纸「染色」，而 Claudio 是颜色即语义的产品，事件色必须显示为真色（参照 Itsycal 的实心表面做法）。
- **圆角阶梯**：控件 / 芯片 6px · 卡片 / 行 10px · 面板 14–16px · 开关 / 声音芯片 pill(999)。
- **最大内容宽（营销）**：~1060px。
- **行结构（每事件行）**：`[事件字形 tile 24pt, 事件色, 圆角6] · [事件名 SF Pro 13 + 原始 id JetBrains Mono 10] · [声音文件名 mono] · [波形] · [圆形试听键 speaker.wave.2, 事件色]`。此为 `present` 态的完整结构；事件行共有三态 `CoverageState{present | unmapped | broken}`，`unmapped` / `broken` 收起文件名 / 波形、试听禁用、行尾出「导入绑定」入口（详见 State Components 的「事件行三态」条）。
- **控件行（Control Row）—— 面板里一切非事件的设置行**（主音量滑块 · 未来的开关 / 步进器 / 行内按钮）。**这一节管的是既成事实，不是新发明**：`OnboardingView` 主 CTA 早已是「原生外壳 + `.tint(clay)`」，此处只是把它升格成全 App 规则。
  - **原生外壳，不自绘**：`Slider` / `Button` / `Toggle` / `Stepper` 一律保留系统绘制的**轨道 · 拇指 · 焦点环 · 按下态 · hover**。品牌强调**只经 `.tint(ClaudioColor.clay(colorScheme))` 一个入口**施加。理由同「App 内 UI = 系统 SF Pro」：自绘控件会连带丢掉 macOS 的焦点环、按下反馈与辅助功能行为，为一点视觉自由付整套原生正确性的账。**先例**：`OnboardingView.swift:102-103` `.buttonStyle(.borderedProminent) + .tint(clay)`。故本设计系统**不定义**轨道高度 / 拇指直径 / 焦点环 —— 那不是我们的决策面。
  - **行解剖**：`[标签 SF Pro 13 · text] · Spacer · [原生控件]`。行高 ~28pt、内边距沿用面板 12–13pt、**无分隔线**（面板全局零 `Divider`，与事件行、drop-zone、画廊一致）。**关键：控件行没有事件色 tile** —— 这是它与事件行的唯一结构差别，也是它不会被误读成「第五个事件行」的全部依据。
  - **不加图标（默认）**：四个事件行已各自带**两枚**喇叭字形（试听键 `speaker.wave.2` + 静音钮 `speaker.wave.2.fill` / `speaker.slash.fill`）。控件行再上一枚喇叭 = 同一个 312pt 面板里的**第三套**喇叭语义，读者无从分辨哪个才是"音量"。**标签用文字**。确需图标时，须挑一个不与事件行撞的字形并登记在此。
  - **数值读数（默认不显示）**：交给 `accessibilityValue` 播报（对齐 macOS 系统音量滑块 —— 它也没有读数）。**一旦决定显示**：JetBrains Mono / SF Mono 10–12 + **`tabular-nums`（`.monospacedDigit()`）+ 定宽容纳最长值**（如 `100%`）。缺这两样，每跳一档数字宽度就变一次，会把控件横向顶得一伸一缩（GUI 里已有 8 处 `.monospacedDigit()` 正是为此）。
  - **禁用态**：`.disabled(true)`，用原生灰 —— 即 State Components「事件行三态」那条的同一口径「**控件置灰 + 图标降饱和，不整行降 opacity**」，行内文字始终 ≥4.5:1。
  - **Dynamic Type**：复用事件行既有的 `rowWrapsToTwoLines`（`PanelLayoutAdaptation`）—— **`.largest` 及以上档**（`xxxLarge` / `accessibility1+`）标签在上、控件整行在下。**不为控件行新立布局字段。**
    ⚠️ 档位以 `PanelTypeSize.swift:56-67` 的真值表为准。中文档位对照（真相源 ENGINEERING.md:269）：**「较大」= `.larger`**（只隐波形，**不**折行）·**「更大」= `.largest`**（**开始折行**，仍 312pt）·**「极大」= `.maximum`**（加宽 360pt）。（2026-07-12 更正：本行曾把「更大」误注成 `.larger` —— 那是 PLAN-MASTER-VOLUME D34① 的假修正，已被 D44 撤销；上一行正文写的 `.largest` 一直是对的。）
  - **对比度**：控件的品牌填充是**非文本图形**，判 **≥3:1**（亮色 `clay` `#C4633C` 对 `panel` = **3.97:1** ✅），与已拍板的 drop-zone hover 边框同规则。
    - **两个主题今天都断住了**（2026-07-14 补齐，PLAN-MASTER-VOLUME **D25 ①**）：亮色一对早已在 `ContrastSuite` 的 drop-zone 决议 suite 里（`clayLight` vs `panelLight` ≥3:1）；暗色的**专名**一对随第一个控件行（`MasterVolumeRow`）一并补上。**诚实标注它的射程**：`ClaudioColorHex` 里 `notificationDark` 是 `clayDark` 的**字面别名**，所以 `nonTextPairs` 那条 "Notification dark glyph vs panel" 算的本就是同两个 hex —— 新断言并不更早捕获「clay 被调坏」（两条会同时红）。它买到的是另外两样：① 暗色从此也有一个**以自己名字**存在的守卫，与亮色对称；② 万一将来有人把事件色 `notificationDark` 与品牌色 `clayDark` 解耦（本就是两个概念，只是今天同值），它就是**唯一**还钉着控件行填充色的断言。
    - ⚠️ **但纯 hex 数学的 `ContrastSuite` 结构上捕获不了这条规则真正的回归**：它看不见 `NSSlider` 实际填了什么色。**有人删掉 `.tint(clay)` → 填充退回系统强调色**（实测裸 `Slider` = `#3275F0` 系统蓝；用户可把系统强调色设成**红**，而真红只许给真错误）—— 这个回归只能靠**真机走查 + state gallery** 兜住，测试兜不住。写进走查清单，别假装测试覆盖了它。
  - **实证记录（2026-07-12，本机 key 窗口 + `screencapture` 真实像素）**：`.tint(clay)` 在 macOS `Slider` 上**确实生效** —— SwiftUI 的 macOS Slider 由 `NSSlider` 支撑，`.tint` 转发到公开属性 `NSSlider.trackFillColor`（`AppKit/NSSlider.h:30`，macOS 10.12.2+），渲染色 `#C7795B`（Display P3 → sRGB 偏移）。
    **方法学**：同一探针在**离屏 / 非 key 窗口**下渲染成**灰色**（macOS 对非活跃窗口的强调色去饱和），会得出「`.tint` 无效」的错误结论。**任何控件视觉验证必须在 key + active 窗口下做。**
    **同时实证**：`Slider(…, step:)` 会被直译成 `NSSlider.numberOfTickMarks`，在轨道下方画出一条刻度带（`step: 0.05` → **21 个点**），撑破本节的「行高 ~28pt」。**控件行不得使用 `step:`** —— 档位吸附交给状态机，视图侧只转发。
  - **动效：控件行不加 `.animation()`**。连续拖拽必须跟手无动画；值的吸附 / 回滚一律**瞬跳**。理由是**手感与诚实**：滑块是直接操纵控件，任何补间都会让拇指与填充段脱钩；而写盘失败后的回滚若被动画柔化，用户会以为值还在路上，而它其实已经没了。
    ⚠️ **（2026-07-14 更正）本条的理由曾被写错，别再照抄那句话**：此处一度写着「`PanelView.swift:63-69` 白纸黑字写着『本视图树零动画，所以不读 `accessibilityReduceMotion`，这条注释就是绊线』」。**那条绊线早已被踩响并改写**（T17c / `0aab69a` —— 但当时只改了 `.swift`，没回来改本文档）：这棵树今天**有**两颗动画（`PanelView.disconnectRow` 与 `OnboardingView.ctaButton` 的 in-flight spinner），两颗都已 gate 在 `reduceMotion` 之后，且 `PanelView` 已声明 `@Environment(\.accessibilityReduceMotion)`。所以「全树没人读 reduceMotion」**今天是假话**。**规矩本身不变**：往控件行（或这棵树的任何地方）加动画，必须在那一点同批 gate 住 `reduceMotion` —— 变的只是理由，不是规矩。

## Motion（动效）

- **策略**：intentional + **声音同步**（招牌）。个性来自时序，不是杂音。
- **缓动**：enter `ease-out`、exit `ease-in`、move `ease-in-out`；Spring 物理（起手快、落地软，stiffness ~380 / damping ~30）。
- **时长**：micro 100ms · short 180ms · medium 260ms · long 400ms。
- **招牌动效**：
  1. **动效跟随音高轮廓**：干完了=上扬两音→勾上跳；中断了=下沉且保持→暂停条淡入并停住；要你确认=双击→双弹；子任务=单 blip→空心勾静静填上。
  2. **视觉回放**：播声音时，菜单栏单色字形按事件色重放那段波形 —— 你能*看见*刚听到的声音。
  3. 试听 ▶ 触发 4–5 根 EQ 条弹跳。
- **无障碍**：尊重 `prefers-reduced-motion` / macOS「减弱动态效果」，降级为静态字形与瞬时状态切换。

## Sound Visual Language（声音视觉语言 · 产品独有）

- **声音芯片 Sound Chip**：事件字形 + 事件色 + 一段真实波形签名；hover / 试听时 EQ 条弹跳。
- **声音包卡片 Pack Card**（**2026-07-15 重设计 · 见下方「包卡片四态」**）：等宽包名 +（CC0 标）；切包用**卡片画廊**（像 macOS 壁纸选择器），语义色固定、只换音色 / 质感。
  > ⚠️ 本条原文是「**2×2 四事件字形网格** + 等宽包名（+ CC0 标）」。那个网格已于 2026-07-15 删除 —— 理由见 Decisions Log 与「包卡片四态」条：**完整的包不画任何覆盖图形**。
- **事件字形**：优先用 SF Symbols（`checkmark.circle.fill` / `pause.circle.fill` / `bell.badge.fill` / `checkmark.circle`），保原生、自动亮暗。
- ~~**包指纹（可选）**：一排 4 段波形签名 = 声音包的可视「条码」。~~ **（2026-07-15 否决 · 存档，不要再提）**
  > 它曾被当作 2×2 网格的替代方案画进视觉稿（每张卡 4 段波形、按事件色排、缺失事件画成灰虚线），**被跨模型评审（Codex）否决，判词成立**：一张 84–96pt 的卡片里，每段只分到约 17pt = 5 根 2pt 条 —— **那是彩色纹理，不是信息**。用户分辨不出「皮卡丘」与「可达鸭」的波形差异，只会看到一排细彩条。
  >
  > **致命的一条不是「不好看」，是它同时承载了缺失信号**：残包的「缺哪个」也压在这条不可读的纹理上，于是**失败信息被同一份不可读性一起弱化**。让装饰去扛负重信号 —— 这正是本文档反复交学费的那类错误（见 `warning` token「没人渲染过、于是没人量过」那条）。
  >
  > 波形母题**本身不作废**（事件行的 `waveform` 占位仍在，招牌动效「视觉回放」仍在菜单栏字形上）。作废的只是「**把波形塞进 84pt 卡片当身份标识**」这一个用法。
- **包卡片数据来源 / manifest 版本字段**：Pack Card 的包名、CC0 标、2×2 事件网格全部来自该包的 `manifest.json`（`id` / `name` / `license` / `events`）。manifest 顶层带一个**整数兼容标记字段 `schema`（v1 现值 `1`）** —— 它是「向前兼容读取」的格式版本锚点，字段名就是这一个整数键 `schema` 本身，manifest 里**并没有**另立一个带版本后缀的独立版本字段（2026-07-08 codex 复核已纠正此前的误命名）。当前 helper 端只读视图 `PackManifest` **尚未 decode 该字段**，靠 `Decodable` 忽略未知键保持前向兼容；install 校验 / GUI 共享 manifest（ENGINEERING T16）落地时再正式读取。视觉层不渲染 `schema`，仅在此登记为包格式演进的契约锚点。

## State Components（状态组件 · /plan-design-review 2026-07-07 补入）

> 操作态视觉参照：面板与状态线框 artifact — https://claude.ai/code/artifact/8442c301-c3f6-4f17-b470-18e1a483cc86
> 这些是 `/design-consultation` 首版未覆盖、由设计评审补入词汇表的组件。**全部由既有 token 派生，勿另立新色 / 新圆角。**

- **onboarding 卡 / 空态卡**：面板内居中列 —— 44px（radius 12）图标块（态色 15% 底 + 态色字形）→ 标题 SF Pro semibold 15 → 正文 `text-2` 12.5 → 主 CTA（黏土实心 pill radius 9 全宽）+ 次 CTA（ghost：透明 + `hairline-strong` 描边）。**空态三要素：温度 + 主行动 + 上下文。**
- **事件行三态 `CoverageState{present | unmapped | broken}`（与 ENGINEERING 决议① / T16、GUI 状态测 DoD 同源）**：每个事件行按 `CoverageState = present | unmapped | broken` 呈现 —— **GUI 从 manifest + 文件存在性算，helper 不改播放行为**。`present`（配了且文件在）= 上述完整行（名 + id + 文件名 + 波形 + 试听 ▶）；`unmapped`（manifest 没配此 event）= 行显「未配置」、试听 ▶ 禁用；`broken`（配了，但目标文件不存在 / 路径未通过包目录 containment）= 行显「文件丢失」并入 `doctor`、试听 ▶ 禁用。**`broken` 只判「文件缺失 / 路径无效」，不含「音频内容损坏」**：`doctor` 现只做**正规文件**存在性 + containment（`regularFileExists` = `stat` + `S_IFREG`；2026-07-11 `/ship` 收口前是 `fileExists`，会把一个名叫 `stop.mp3` 的**目录**判成 present），`play` 是 fire-and-forget（刻意不 `waitUntilExit()`，见 `Play.swift`），`afplay` 拒绝坏文件的信号回不到进程里。「文件在、确是正规文件、但解不出声」要另立状态，须先给 doctor 或播放层加音频 lint —— v1 不做。`unmapped` 与 `broken` 两态都在**行尾提供逐事件导入绑定**（拖入 / 选文件 → 绑到该 event）去补。区分二者 = **真打包错误不被伪装成正常静默**。禁用观感用**显式禁用样式（控件置灰 + 图标降饱和），不整行降 opacity**（行内文字始终保 ≥ 4.5:1 对比度）。此三态与正交的**静音态**（`enabled=false`：控件区弱化 + 静音钮点亮）叠加，互不取代。
- **错误态用色（关键约束）**：app 自身错误（settings 不可写 / 解析失败 / helper 缺失）用 UI 语义 `error #FF453A`（真红）；**绝不用于四事件层**（StopFailure 永远琥珀）。非阻断提示（如 Claude Code 未装）用中性 `surface-2` + `text-2`，不上真红。
- **拖入 drop-zone**：虚线 1.5px `hairline-strong` + radius 10 + `text-2`；hover 命中 → **边框** 转黏土 + `clay-soft` 底，**文案保持 `text-2` 不变**。
  - ✅ **已拍板（2026-07-11 `/ship`）—— hover 反馈由边框 + 底色承载，文字不转黏土**。此前本条写的是「边框 / **文字**转黏土」，与上面「事件行三态」条的「行内文字始终保 ≥ 4.5:1 对比度」自相矛盾：实测亮色 `clay` `#C4633C` 对 `panel` `#FFFDF8` = **3.97:1** —— 过图标 / 边框的 ≥3:1，**不过**正文的 ≥4.5:1。曾列的三个解法中取**解法 1**（本条原本自己标的推荐项）：
    1. ✅ **采纳**：hover 只让边框 + `clay-soft` 底转黏土，文案保持 `text-2`。零品牌成本，语义（「命中了」）由边框 + 底色照样说清。
    2. ❌ 调深亮色 `clay` 到 ≥4.5:1（约 `#A8502F`）—— 会改品牌色 **且**改 `Notification` 的视觉身份，为一个 hover 态动两处，不划算。
    3. ❌ 豁免 —— 不成立：hover 文案是 12.5pt 常规字重，够不上 WCAG 大字体豁免（≥18.66pt bold / ≥24pt）。
    落地：`AudioDropZoneView.promptLabel` 的 `foregroundColor` 恒为 `textSecondary`（不再有 `isHovering` 三元）；`isHovering` 仍然驱动边框与底色，hover 观感不变。`ContrastSuite.swift` 里那条被注释掉的「clay ≥4.5:1」known-gap 断言随之作废——正文文字集合里已经没有 clay 了。**「品牌强调唯一 = 黏土 `#D97757`」这条不为任何单一状态开色值的口子。**
- **拒绝行**：真红 `circle-x` 字形 + `text-2` 说明，`原因`（真红）+「怎么修」一句；不道歉、不含糊。

- **包卡片四态 `PackCardState{complete | partial | broken}` × 正交的 `isSelected`（2026-07-15 重设计 · /plan-design-review）**
  卡片的**唯一工作是换包**。它由三个纵向槽位组成：`[状态槽 22pt] · [包名 mono 10] · [meta 行 mono 10]`。
  - **`complete`（四事件齐全）—— 状态槽空着，卡片上没有任何覆盖图形。** meta 行只在 `license == "CC0-1.0"` 时显示 `CC0`（`text-2`）。
    **为什么什么都不画**：这个产品的包之间的区别**在声音里，不在像素里**。旧的 2×2 网格之所以存在，是因为「卡片总得有张图」——而**声音没有图**，硬画一个只会撒谎：四张完整包的网格**长得一模一样**，承载的信息量是零，同时把「有四个事件」这件已经在上面四行里说过四遍的事又说了一遍。**正常时安静，出问题时才开口**（旧设计恰好相反：全绿时最吵，异常时最轻）。
  - **`partial`（缺 N 个）—— 状态槽出现 4-slot 覆盖轨**（见下条），meta 行 = `⚠`（`warning` 图标）+ `缺 N 个`（**`text-2`，不是琥珀**，见下方对比度注）。
  - **`broken`（目录/manifest 读不出）—— 状态槽出现真红 `xmark.circle.fill`**，meta 行 = `文件丢失`（`text-2`）。沿用「拒绝行」的既有语言（真红只上图标，文案走 `text-2`）。
  - **`isSelected` 与上述三态正交**：2px `clay` 描边环（未选中回落 1px `hairline-strong`）。与 `EventRow.enabled` 对 `CoverageState` 的正交关系同构。
  - **`CC0` 与「缺 N 个」必须分居两个槽位** —— 今天 `PackGalleryView.statusLine` 的 `switch` 让它们抢**同一行**，于是**一个 CC0 的残包会丢掉 CC0 标**。license 与完整度是两根**正交**的轴，一个格子塞不下两根轴。
  - **卡片上刻意没有试听 ▶**（2026-07-15 提出并当场砍掉，理由见 Decisions Log）：换包本来就是一次点击且可逆，事件行才是更好的试听面。

- **4-slot 覆盖轨（新组件 · 只在 `partial` / 未来的残包态出现）**
  一排 4 个 9×9pt、radius 2 的小方格，按 `Event.allCases` 固定顺序，间距 3pt。
  - **`present` 格 = 事件色实心方块**（不是 15% 自染 —— 这里是纯色块，不是字形 tile）。
  - **`missing` 格 = 空槽 + 1px `text-2` 描边 + 一道 `text-2` 斜杠**。
    **必须是另一种形状，不能是「同一个图标调灰」** —— 那正是旧网格失败的原因（40% opacity 的灰字形，缩到 12pt 后与在位字形几乎无法分辨）。
  - **双编码（形状 + 文案）**：轨道回答「**缺的是哪一个**」（缺「子任务完成」与缺「干完了」的严重性完全不同），meta 行的 `缺 N 个` 回答「**缺了几个**」。任何一个单独都不够。
  - **对比度（实测，非推理）**：
    | 配对 | 值 | 判据 |
    |---|---|---|
    | 暗 · `missing` 描边 `muted` `#6F665B` vs `surface-2` `#262320` | **2.77:1** ❌ | ≥3:1（1.4.11） |
    | 暗 · `missing` 描边 **`text-2` `#B0AEA5`** vs `surface-2` | **7.03:1** ✅ | 采纳 |
    | 亮 · `missing` 描边 **`text-2` `#6F665B`** vs `surface-2` `#FFFDF7` | **5.54:1** ✅ | 采纳 |
    | 亮 · `present` 最弱一格（`Notification` `#C4633C`）vs `surface-2` | **3.97:1** ✅ | ≥3:1 |
    | 暗 · `present` 最弱一格（`SubagentStop` `#5E5CE6`）vs `surface-2` | **3.09:1** ✅ | ≥3:1 |
    第一行就是**这套系统第四次**在同一个坑上翻车：一个没人渲染过的色值，也就没人量过。`ContrastSuite` 须同批钉死这四对。
  - ⚠️ **`缺 N 个` 的文案用 `text-2`，琥珀只上 `⚠` 图标** —— 这不是口味，是 DESIGN.md 第 101 行**自己已经写死的规矩**（`warning`「**且只做图标、不做正文**」）。实测亮色 `warning` `#B87000` 对 `surface-2` = **3.85:1**：过图标的 ≥3:1，**不过正文的 ≥4.5:1**。本次设计稿第一版把它当正文用了，被自己的规矩当场逮住 —— 与真红 `error`、`Stop`、`StopFailure`、`warning` 自己是**同一条先例的第五次**。

- **行内文件名下拉（事件行的编辑入口 · 新组件，2026-07-15）**
  事件行的**文件名本身**升格为一个原生 `Menu`（popup button）：`stop.mp3 ▾`。
  - **它替换掉了什么**：`unmapped` / `broken` 行尾原来的 `⤓ square.and.arrow.down` 导入键。三态从此**共用同一个控件**：`present` 显文件名、`unmapped` 显「未配置」（虚线边框）、`broken` 显红名。**旧结构是分裂的 —— 有声音的行没有编辑入口，只有没声音的行才有**，于是一个完整的包在 GUI 里无法替换任何声音（2026-07-15 实证）。
  - **菜单内容**：`[包目录里已有的音频，含「· 未被使用」的孤儿]` / `选文件…` / `清除绑定（这个事件将静默）` / `在访达中显示`。
  - **为什么是文件名而不是行尾加一颗 `⋯`**：312pt 的行里已有 `事件 tile + 名 + id + 文件名 + 波形 + 试听键 + 静音钮`，再加第三颗可点区就会挤（「控件行」一节早已警告过字形拥挤）。而**用户问「这是什么声音」时，眼睛本来就落在文件名上** —— 入口长在那儿，零新字形、零新宽度，且与管理窗口的选择器是**同一套词汇**。
  - **原生外壳，不自绘**（沿用「控件行」铁律）：用 SwiftUI `Menu` / `Picker`，保系统的焦点环、按下态与辅助功能行为。品牌强调只经 `.tint(clay)`。
  - **`清除绑定` → `CoverageState.unmapped`（刻意静默），绝不是 `broken`。** 决议①的原话：「真打包错误不被伪装成正常静默」—— 反向也成立，**一次用户主动的清除不得被伪装成打包错误**。行显「未配置」，不是「文件丢失」。

- **内边距 / 圆角**：沿用面板 12–13pt、卡片 radius 10、控件 radius 6。
- ⚠️ **展柜 artifact 现状**：DESIGN.md 顶部链接的「设计系统预览」artifact 仍画着已移至 v2 的深夜降音量，且不在仓库 / CI 不可验。视觉真相源改为**仓库内 state gallery**（SwiftUI Preview 目录，与状态测试共用 fixtures，见 ENGINEERING T14）；外部展柜降为可选快照。

## Sound Packs Window（管理窗口 · 2026-07-15 新增）

> **本文档在此之前是「零窗口规范」的** —— 从 Product Context 到 Layout 到 State Components，全部只谈那个 312pt 的 `NSPopover` 面板。这一节是第一次为一个**真窗口**立规矩，因此它明确划出面板与窗口的**职责边界**，而不是把面板的规矩复制一份。

- **为什么需要它**：面板的工作是「**不回头也知道状态**」—— 瞥一眼、按一下、关掉。而「包 × 事件 × 音频文件 × 孤儿文件 × 复制包」是一张**对象关系表**，塞进一个 `.transient` popover（用户点一下别处它就消失）会变成一个难用的小号文件管理器。**两个不同的使用时刻，不互相抄。**（跨模型印证：Codex 独立评审收敛到同一结论。）
- **尺寸 / 形制**：约 640×480，标准 macOS 窗口（**非** `.transient`，可移动、可缩放、可后台停留）。app 仍是 `LSUIElement`（无 Dock 图标）；窗口按需创建。
- **布局**：`[侧栏 176pt：包列表] | [主区：事件映射]`，底部 `[包级动作栏]`。
  - **侧栏**：每行 = `[微型覆盖轨] [包名] [右对齐 tag: CC0 / N/4 / ✓]`；底部 `+ 新建我的包`（虚线描边 ghost）。
  - **主区**：包名 + license 标 + `在访达中显示`；下面是**四条事件映射行**，每行 = `[事件名 + id] [文件名下拉 ▾] [试听 ▶]`。
    **映射行只有一个菜单** —— 那个 `▾` 下拉。**不得再在行尾加第二颗 `⋯`**：它与 `▾` 干的是同一件事，两个菜单一个职责，是纯冗余（2026-07-15 自评审逮到并删除）。
  - **孤儿音频行**：包目录里**没被任何事件引用**的音频，显式点名（`⚠` 图标 + `text-2` 文案 + `分配… / 删除`）。
    **这是「绝不静默吞错」在文件层的兑现**：一个躺在包里、永远不会响、也永远没人提的音频，是一次静默失败。它今天就大量存在（旧的面板级 drop-zone 制造的）。
  - **底部动作栏**：`+ 添加音频` · `复制为我的包` · （右）`用这个包`。
- **内置包只读（硬约束，2026-07-15 授权）**：内置包（`minimal-chime`）在窗口里**不可编辑**；试图改 → 不报错，**引导**「复制为我的包」。
  **理由是 license 正确性，不是洁癖**：`setup` 会把内置包拷进 `~/.claudio/packs/`（`Setup.swift`），于是它就是一个普通的可写目录；而 GUI 侧 `AudioImportEnvironment` 的 `bundledPacksDirectory` 取默认 `nil`（`ClaudioGUIApp.swift:57`），`isBuiltinOnlyPackID` 第一行 `guard bundledPacksDirectory != nil else { return false }` —— **`.overwritesBuiltin` 那道闸门在出厂的 GUI 里结构上跑不到**。结果：**你可以往「极简铃音」里塞一个有版权的音频，而卡片照样显示 `CC0`。** 一个会说谎的 license 标，比没有标更坏 —— 而「版权干净（CC0）」是这个产品 Product Context 第一行的卖点。
  - **配套：「恢复出厂声音」**（内置包专属动作）。只读只挡**未来**的写；**已经**被改脏的包不会自己变干净（现存用户机器上就有）。从 app bundle 重拷 + 重写 manifest —— `Setup.swift` 的 `copyBundledPacks` 已经是这段代码，**不是新机制，只是新入口**。
- **窗口的无障碍是一整个新面（不许复用面板的）**：`PanelFocusTarget` / `PanelLayoutAdaptation` / `PanelAnnouncement` 全部是**面板专用**的模型。窗口需要自己的焦点序、Dynamic Type 降级规则与 VoiceOver 播报策略。**别把面板那套硬套过来** —— 面板的规则（312pt、`rowWrapsToTwoLines`、`.maximum` 加宽到 360pt）是从「一个 popover」的约束里长出来的，窗口没有那个约束。

## App Icon（图标）

- **概念**：同心声波弧 / 放射波形，同时读作一个 **C**（Claudio）。奶油 `#F0EEE6` 底 + 黏土 `#D97757` 弧，暖而克制。
- **不碰** Anthropic 官方标 / 星芒 / wordmark（致敬式伴侣，**非官方**）。
- **两版**：全彩 Dock 图标；**单色模板菜单栏字形**（16×16pt，纯 alpha，自动亮/暗，可做「视觉回放」动画）。
- **已选定形状：方案 B「单线括弧 / Monoline Bracket」**——一圈粗括弧扛住全部视觉重量（外弧），内圈细弧只是半透明的回声点缀（内弧，`alpha 0.5`），缺口统一朝东（3 点钟方向）。选它是因为概念评审的真实 16px 压力测试里，B 是仅有的两个「缩到菜单栏尺寸依然看得出缺口方向」的方案之一，其余多环/高对比方案会糊成一坨。
- **菜单栏字形已落地**：`gui/Sources/ClaudioGUI/MenuBarIcon.swift`（`NSBezierPath` 直接画，非位图资源——`gui/` 是 SPM target，没有 `Assets.xcassets`），替换了原先占位的 SF Symbol `waveform.circle`；已用真实运行中的 app 截图核实菜单栏渲染效果（居中、清晰读作「C」）。**全彩 Dock 图标（`.icns`）尚未生成**，`Info.plist` 也还没有 `CFBundleIconFile`——v1 是 `LSUIElement`（无 Dock 图标），暂不阻断。

## macOS 平台注记

- 菜单栏 extra 工作区 22pt 上限；模板图标 16×16pt（纯 alpha）。
- macOS 26 (Tahoe) 菜单栏默认透明 + Liquid Glass；须测「减弱透明度」（强制不透明灰）两种状态。
- 面板虽近实心，仍可在其**背后**保留极轻材质感，但不能让事件色被壁纸染 —— 语义色优先。

## Decisions Log（决策记录）

| Date | Decision | Rationale |
|------|----------|-----------|
| 2026-07-06 | 初版设计系统创建 | 由 `/design-consultation` 基于产品上下文 + 3 路并行研究（menubar 设计语言 / 开发者工具美学 / 声音视觉身份）+ Codex 跨模型独立方向合成 |
| 2026-07-06 | 美学 = 暖色工具主义（暖背离冷开发灰） | 借 Claude 品牌暖色对齐「伴侣」身份 + 跳出 Linear/Raycast 同质化；Codex 独立收敛到同一暖色，跨模型一致 |
| 2026-07-06 | 展示字 = General Sans（自托管） | 温暖人文无衬线、避收敛陷阱；自托管以绕开 Fontshare CDN 可靠性；预览临时用 Bricolage 替身 |
| 2026-07-06 | App 内 UI = 系统 SF Pro | 原生 macOS app 的正确选择；承载个性的是展示字 General Sans，非系统字 |
| 2026-07-06 | 数据 / 代码 = JetBrains Mono | 开发者母语视觉信号 + 开源友好 |
| 2026-07-06 | Notification 事件色 = 品牌黏土 | 品牌色==「该你了」，把品牌与最有人味的信号诗意统一（Codex 曾主张用蓝，已择黏土） |
| 2026-07-06 | StopFailure = 琥珀，绝不用红 | 诚实约束：它是「被限流/欠费/过载中断」，不是「代码有 bug」 |
| 2026-07-06 | Stop 实心勾 / SubagentStop 空心勾（靛） | 同形状两权重 = 一眼分大/小完成（Codex 曾主张橄榄，已择靛以求清晰分离） |
| 2026-07-06 | 面板近实心表面 + 1px 描边，不用满毛玻璃 | 颜色即语义的产品，vibrancy 会被壁纸染色，事件色须真色（参照 Itsycal） |
| 2026-07-06 | 动效声音同步（跟随音高轮廓 + 视觉回放）为招牌 | 把音频灵魂变可见；个性来自时序而非视觉噪音 |
| 2026-07-06 | 落地页 / hero 用 Fraunces 斜体衬线（risk） | 跳出清一色无衬线，给「精心设计的作品」信号 |
| 2026-07-09 | 事件行改为三态 `CoverageState{present\|unmapped\|broken}` | 对齐 ENGINEERING 决议① / T16 与 GUI 状态测 DoD；`unmapped`（静默正常）vs `broken`（打包错误）须可分，不把真错误伪装成正常静默（T10） |
| 2026-07-09 | 去「零摩擦安装」措辞 → 「技术用户低摩擦」 | 对齐 ENGINEERING T3：v1 不签名、未公证，面向能自绕 Gatekeeper 的技术用户；签名 + 公证是面向非技术用户 / 广泛发布前的硬门槛（T10） |
| 2026-07-09 | manifest 版本字段用现有整数 `schema`（现值 1），而非另立独立版本号字段 | 2026-07-08 codex 复核纠正字段名；`PackManifest` 尚未 decode，靠 `Decodable` 忽略未知键前向兼容（T10） |
| 2026-07-09 | 确认 night_dim 在 DESIGN.md 只作 v2、无 v1 特性叙述 | 深夜降音量已由 ENGINEERING T2 移出 v1；DESIGN.md 仅余展柜漂移诚实注记与「深夜音频硬件」美学隐喻，均非 v1 特性（T10） |
| 2026-07-09 | `broken` 收窄为「文件缺失 / 路径无效」，剔除「音频内容损坏」 | `/codex review 78e19c2`：doctor 只 `fileExists` + containment，`play` fire-and-forget 不 `waitUntilExit()`，坏文件的播放失败信号结构上拿不到。设计真相源不得承诺代码无从判定的状态 |
| 2026-07-11 | 事件字形 tile **保持事件色自染 15%**；改为调深两个亮色事件色：`Stop` `#2FA24E→#288B43`、`StopFailure` `#C87A00→#AC6900`（`Notification`/`SubagentStop`/全部暗色不动） | 对比度硬约束，非审美：自染底让亮色 `Stop` 2.75:1 / `StopFailure` 2.82:1 不过 WCAG 1.4.11 的 ≥3:1（旧 `ContrastSuite` 断的是「字形 vs 纯 panel」，断错了那一对，故一直假绿——也使上次 `#E08600→#C87A00` 的调色没达成目的）。调深后对真实复合底 3.53 / 3.59 / 3.32 / 4.37，全局最差 3.06:1（暗色 SubagentStop，未改）。`ContrastSuite` 改对 `compositedHex(事件色, over: panel, alpha: 0.15)` 断言，并**额外**钉住 tile 对面板可见性 ≥1.10:1 |
| 2026-07-11 | **（同日第一次修法，已推翻 · 存档）** 事件字形 tile 底 = 中性 `surface-2` | 推翻理由：亮色 `surface-2` `#FFFDF7` 对 `panel` `#FFFDF8` = **1.0006:1**，是同一个颜色 —— tile 在亮色下**整个消失**，「过了 ≥3:1」靠的是字形直接落在面板上，等于用「删掉 tile」通过对比度；与「行结构」的「事件字形 tile 24pt, **事件色**」冲突，并连带让试听键「已启用」的圆形底在亮色下消失。教训：**只断言字形对比度不够，tile 存不存在也得钉住** → 新增 tile 可见性断言 |
| 2026-07-11 | 真红 `error` **只做图标**，配套文案改用 `text-2`；真红色值不变 | 亮色 `#E0453A` 对 `panel`/`surface-2` = 4.07:1/4.06:1：过非文本 ≥3:1、**不过**正文 ≥4.5:1，而它此前被当正文用（包卡「文件丢失」、onboarding 详情）。`text-2` 5.54:1 过 AA |
| 2026-07-11 | **（登记时待决 → 同日 `/ship` 已拍板解法 1 · 存档）** drop-zone hover「文字转黏土」与「行内文字 ≥4.5:1」冲突登记为 known gap | 亮色 `clay` `#C4633C` = 3.97:1（过 ≥3:1、不过 ≥4.5:1）。clay 同时是品牌唯一强调 + `Notification` 事件色，改动牵连品牌与事件身份，须用户拍板；已在 drop-zone 条列出三个候选解法，`ContrastSuite` 放 known-gap 断言（≥3:1 启用、≥4.5:1 注释 + 自毁提醒），`TODOS.md` P3。→ **收口见上方「拖入 drop-zone」条 ✅**（hover 只转边框 + 底色，文案恒 `text-2`）；本行原「待决 · 未改」的状态标记与正文漂移了一天，2026-07-12 更正（PLAN D46） |
| 2026-07-12 | 新增 Layout「**控件行（Control Row）**」一节：原生控件保留系统外壳（轨道 / 拇指 / 焦点环 / 按下态不自绘），品牌只经 `.tint(clay)` 施加；行 = 标签 + Spacer + 控件、**无事件色 tile**、无图标、无数值读数、瞬跳无动画 | 主音量滑块（`PLAN-MASTER-VOLUME.md`）暴露出 DESIGN.md 对**交互控件**零规范。但缺的不是「滑块长什么样」——**这套系统的既定立场本就是原生**（「App 内 UI = 系统 SF Pro」/「事件字形优先 SF Symbols，保原生」），且 `OnboardingView` 主 CTA 已经是「原生外壳 + clay tint」的**既成先例**。故本节不发明控件解剖，只把先例升格成规则，并钉死四个**真会踩的**坑：① 喇叭字形已被试听键 + 静音钮用掉两枚，控件行再上就是同屏第三套；② 数值读数不做 `tabular-nums` + 定宽会横向抖动；③ Dynamic Type 复用 `rowWrapsToTwoLines`，不新立字段；④ 加动画必须同批接上 reduced-motion 门控（**2026-07-14 更正**：本条原写作「会引爆 `PanelView.swift:63-69` 的**零动画**绊线」—— 那条绊线在本行落笔时**早已被 T17c 踩响并改写**，树里已有两颗 gate 过的 spinner，「全树零动画」是假话；门控要求不变，失效的只是这个理由）。一并替代 `/plan-design-review`（评估后判定不跑：真视觉缺口仅 4–5 条且均已被既有先例逼到唯一解） |
| 2026-07-12 | 更正「控件行 · Dynamic Type」的档位括注（「更大」= `.largest` 而非 `.larger`）；Decisions Log 上一日 drop-zone 行的「待决 · 未改」状态标记同步更正为「已拍板 · 存档」 | PLAN-MASTER-VOLUME **D44/D46**（用户授权拍板）：D34① 是假修正 —— 真相源 ENGINEERING.md:269「较大 → 隐波形；**更大 → 事件行转两行**；极大 → 加宽」与 `PanelTypeSize.swift` 一致，原 D17 与本文档正文的 `.largest` 从头到尾是对的，错的是 D34① 塞进来的那句括注。教训：**一条错误的指控比没有指控更糟；「源码逐字比对」也会比错行，结论必须回真相源二验** |
| 2026-07-14 | 第一个控件行落地（`MasterVolumeRow`，PLAN-MASTER-VOLUME 阶段 D）。同批清三笔账：① 更正「控件行 · 动效」正文与上一行 Decisions Log ④ 里那句**已被推翻的绊线原话**；② 补齐「控件行 · 对比度」缺的**暗色专名断言**（`clayDark` vs `panelDark` ≥3:1，PLAN **D25 ①**）；③ **走查 ⑨ 已实跑，实测值存档**（见右栏 ③） | ① 两处都在引用 `PanelView.swift` 那条「本视图树零动画，所以不读 `accessibilityReduceMotion`」的绊线 —— 而它**早已被 T17c 踩响并改写**（`0aab69a` 只修了 `.swift`，没回来修本文档），树里今天有两颗已 gate 的 spinner。**这正是本文档上一行那条教训（「一条错误的指控比没有指控更糟」）在文档自己身上的复发**：一句不再成立的断言留在原地，比没有断言更坏，因为下一个人会信它。规矩（加动画必须同批 gate `reduceMotion`）不变，作废的只是理由。② D25 ① 早就写明「第一个控件行落地时补」，今天到期。③ **`.tint(clay)` 是否真的生效，CI 结构上测不到**（`ContrastSuite` 是纯 hex 数学，`ClaudioGUICore` 连 SwiftUI 都不 link，看不见 `NSSlider` 填了什么色）—— 守门人是**人**：走查 ⑨（系统强调色改红 → 开面板 → 看填充段是黏土不是红），**每次动控件行都必须重跑**。<br>✅ **本轮已实跑**（2026-07-14，`8771946`，系统强调色设为红）：滑块填充 `#AE6E41`（G−B = **45**，橙棕），与**同面板** clay 字形 `#B5754A` 同族（两者走同一条渲染/截图管线 —— 这才是有效比较，而不是拿它去等于原始 `#D97757`）；系统红强调色实测 `#D55A53`（G−B = **7**）。**正向对照先自证**：同条件下**裸** `Slider` 渲染成红，证明红强调色确已生效 —— 没有这一步，哪怕强调色压根没施加，一个黏土色填充也会「通过」（探针必须先证明自己有效，才能证明别的）。同一跑的走查 ⑥：轨道下方无刻度带，未踩 D24 的 `step:` 坑。<br>⚠️ 本条原写作「**本轮重新欠账**」，而同一个 commit 的 `MasterVolumeRow.swift` 注释也写着「That run is still owed」—— **两处都是假的**：话写在跑之前，跑完没人回来改。这比普通的文档腐烂更险：它对一条**真**纪律喊了狼来了，教会下一个读者去打折「走查 ⑨ 欠账」这句话——而总有一天它是真的（`/codex review 8771946`） |
| 2026-07-15 | **声音包管理重设计（`/plan-design-review`）—— 三条实证发现**：① 面板级 drop-zone「+ 拖入你自己的声音」**从不写 manifest**：`AudioImportViewModel.handleDrop` → `importAudioFiles` 只把字节拷进包目录、播一次预览、亮一个绿勾，文件成为**孤儿**（磁盘上有、永不发声、无人引用）。② `bindEventToManifest` 在生产代码里**只有一个调用者**（`EventRowImportViewModel.swift:112`，即事件行的导入入口），而该入口**只在 `unmapped`/`broken` 时渲染** —— 于是**一个完整的包，在整个 GUI 里没有任何路径能替换它的任何一个声音**（想换「干完了」，你得先去 Finder 把 `stop.mp3` 删掉、把那一行弄坏）。③ `.overwritesBuiltin` 的拒绝文案叫用户「先建一份属于你自己的包」，而**那个动作在 UI 里根本不存在**（grep 无 `createPack`/`forkPack` 任何形态），且该分支在出厂 GUI 里**结构上不可达**（`bundledPacksDirectory = nil`）—— 一块指向不存在的门的路牌 | 用户原话：「上传自己的音频，这个功能完全没有用」—— **不是夸张，是对代码的精确描述**。<br>**决议**（用户拍板）：**包为中心**（manifest 仍是唯一真相源，**helper 零改动**；明确**不**引入 `~/.claudio/library/` 第二查找根 —— ENGINEERING.md 早已拒绝过那个形状）+ **面板 + 独立管理窗口**。落地：删面板 drop-zone；事件行**文件名升格为原生下拉**（三态共用一个控件）；新增 `clearEventBinding`（`bindEventToManifest` 的**对偶，今天不存在** —— 不写清楚，实现者会绕过 `JSONSafeWrite` 的锁去手改 JSON）；内置包只读 + 「复制为我的包」+「恢复出厂声音」 |
| 2026-07-15 | **包卡片：删掉 2×2 事件字形网格，完整的包不画任何覆盖图形**；图形只在 `partial`（4-slot 覆盖轨，缺失格 = **空槽 + 斜杠**，另一种形状）/ `broken`（真红 ✕）时出现。`CC0` 与「缺 N 个」拆到两个槽位 | 用户原话：「图标冗余，也不能体现出是否有提示音缺失」—— **两句话是同一个病的两面**：旧网格**正常时最吵**（四张完整包的网格一模一样，信息量为零），**异常时最轻**（一个 40% opacity 的灰字形 + 一个与 `CC0` 抢位的 10pt「3/4」，于是一个 CC0 的残包**会丢掉 CC0 标**）。<br>**根因**：网格之所以存在，是因为「卡片总得有张图」——而**声音没有图**。硬画一个只会撒谎。**正确的做法不是换一种图形，而是让它在正常时消失。**<br>缺失格必须是**另一种形状**（不是同一图标调灰）+ **文案双编码**：轨道答「缺哪个」（缺「子任务完成」与缺「干完了」严重性完全不同），meta 行答「缺几个」 |
| 2026-07-15 | **（提出并当场否决 · 存档，不要再提）** 用「4 段波形包指纹」替代 2×2 网格 | `/codex` 跨模型评审否决，**判词成立**：84–96pt 的卡片里每段只分到约 **17pt = 5 根 2pt 条** —— **是彩色纹理，不是信息**。<br>**致命的一条不是「不好看」，是它同时承载了缺失信号**：残包「缺哪个」也压在这条不可读的纹理上，于是**失败信息被同一份不可读性一起弱化**。让装饰去扛负重信号，是本文档反复交学费的那类错误。<br>它当初的理由是「DESIGN.md 自己登记过『包指纹（可选）』」—— 而**「文档里登记过」不是「它在 17pt 下可读」的证据**。这条教训与「`warning` 那个不及格的值能躺到今天，正因为没有任何视图渲染它＝没有任何人量过它」是**同一条**：**登记 ≠ 验证** |
| 2026-07-15 | **（提出并当场砍掉 · 存档）** 包卡片加 hover ▶ 试听（不切包就能听） | 用户一句话砍掉，理由成立：**换包本来就是一次点击且可逆**，事件行才是更好的试听面（按事件分、带事件色）。为省**一次点击**，要付：每张卡从一个控件变两个 → **撞破 `PanelFocusTarget.packCard(id:)` 的「每卡恰好一个焦点槽」契约**（正是 `EventRowView.previewClaimsActionFocus` 存在的那条契约）+ 一个四段序列播放器 + 中断语义 + 多卡连点的叠音处理 + reduce-motion 门控。**砍掉它，`/plan-design-review` Pass 6 记下的那条结构性发现直接消失** |
| 2026-07-15 | 新增「4-slot 覆盖轨」的四对对比度断言；`缺 N 个` 文案用 `text-2`，琥珀只上 `⚠` 图标 | **同一条先例的第五次**（前四次：`Stop` / `StopFailure` / `warning` / 真红 `error`）。实测：暗色缺失格若用 `muted` `#6F665B` 对 `surface-2` = **2.77:1 ❌**（不过 ≥3:1）；`缺 N 个` 若用琥珀当正文 = 亮色 **3.85:1 ❌**（不过 ≥4.5:1 —— 而第 101 行**自己早写着** `warning`「只做图标、不做正文」）。**设计稿第一版两条都踩了，被这个文档自己的规矩当场逮住。** 两条均改用 `text-2`（5.54 / 7.03 ✅），**零新颜色** |
| 2026-07-15 | App Icon 拍板方案 B「单线括弧」，菜单栏字形落地 | 概念评审阶段出过 A–E 五版同心弧 + I 系终端声窗延伸 + 像素风延伸，用户从真实 16px 菜单栏压力测试里选定 B——多环/高对比方案在该尺寸下会糊成一坨，B（外粗弧 + 内半透明回声弧）是仅存的两个方向之一。落地范围明确收窄到「先换菜单栏字形」（用户拍板，Dock `.icns` 全套暂缓）：新增 `MenuBarIcon.swift` 用 `NSBezierPath` 直接画（`gui/` 是 SPM target 无 `Assets.xcassets`，画比建资源管线便宜），替换 `MenuBarController.swift` 里原来的占位 SF Symbol `waveform.circle`。走查方式：`scripts/dev-bundle.sh` 打包真实 app、`open` 启动、`screencapture` 截真实菜单栏，量出图标 bounding box 与相邻系统图标（电池/Wi-Fi）几乎同高同位，证明不是「代码编译过但没人看过渲染结果」 |
