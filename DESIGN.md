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
| ✅ `Stop` 干完了 | 完成、落定 | `#34C759` | `#2FA24E` | 实心粗勾 `checkmark.circle.fill` |
| ⏸ `StopFailure` 中断了 | 限流 / 欠费 / 过载 / 认证（**非代码 bug**） | `#FF9F0A` | `#C87A00` | 暂停 `pause.circle.fill` · **琥珀，绝不用红** |
| ✋ `Notification` 要你确认 | 等你确认 | `#D97757`（=clay） | `#C4633C` | 铃 / 举手 `bell.badge.fill` · **品牌黏土** |
| ◦ `SubagentStop` 子任务完成 | 从属完成 | `#5E5CE6` | `#5B59D6` | **空心**勾 `checkmark.circle` · 更暗 |

> `StopFailure` 亮色由原 `#E08600`（对亮面板 ~2.73:1）调深为 `#C87A00`（≈3.31:1），以满足事件字形对表面 **≥3:1** 的非文本对比（WCAG 1.4.11）—— 仍为暖琥珀、绝不用红。UI 语义 `warning` token 是独立用途（校验提示，非事件字形），仍保留 `#E08600`，两者刻意分叉。`gui` 侧由 `ContrastSuite.swift` 逐对数学断言钉死。

**UI 语义色（提示 / 校验，独立于事件层）**
| 用途 | Dark | Light | 备注 |
|---|---|---|---|
| success | `#34C759` | `#2FA24E` | |
| warning | `#FF9F0A` | `#E08600` | |
| **error（真错误）** | `#FF453A` | `#E0453A` | **只**给 App 自身真错误（如写不进 settings.json）；**绝不**用于事件层 |
| info | `#0A84FF` | `#0A72D0` | |

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
- **声音包卡片 Pack Card**：2×2 四事件字形网格 + 等宽包名（+ CC0 标）；切包用**卡片画廊**（像 macOS 壁纸选择器），语义色固定、只换音色 / 质感。
- **事件字形**：优先用 SF Symbols（`checkmark.circle.fill` / `pause.circle.fill` / `bell.badge.fill` / `checkmark.circle`），保原生、自动亮暗。
- **包指纹（可选）**：一排 4 段波形签名 = 声音包的可视「条码」。
- **包卡片数据来源 / manifest 版本字段**：Pack Card 的包名、CC0 标、2×2 事件网格全部来自该包的 `manifest.json`（`id` / `name` / `license` / `events`）。manifest 顶层带一个**整数兼容标记字段 `schema`（v1 现值 `1`）** —— 它是「向前兼容读取」的格式版本锚点，字段名就是这一个整数键 `schema` 本身，manifest 里**并没有**另立一个带版本后缀的独立版本字段（2026-07-08 codex 复核已纠正此前的误命名）。当前 helper 端只读视图 `PackManifest` **尚未 decode 该字段**，靠 `Decodable` 忽略未知键保持前向兼容；install 校验 / GUI 共享 manifest（ENGINEERING T16）落地时再正式读取。视觉层不渲染 `schema`，仅在此登记为包格式演进的契约锚点。

## State Components（状态组件 · /plan-design-review 2026-07-07 补入）

> 操作态视觉参照：面板与状态线框 artifact — https://claude.ai/code/artifact/8442c301-c3f6-4f17-b470-18e1a483cc86
> 这些是 `/design-consultation` 首版未覆盖、由设计评审补入词汇表的组件。**全部由既有 token 派生，勿另立新色 / 新圆角。**

- **onboarding 卡 / 空态卡**：面板内居中列 —— 44px（radius 12）图标块（态色 15% 底 + 态色字形）→ 标题 SF Pro semibold 15 → 正文 `text-2` 12.5 → 主 CTA（黏土实心 pill radius 9 全宽）+ 次 CTA（ghost：透明 + `hairline-strong` 描边）。**空态三要素：温度 + 主行动 + 上下文。**
- **事件行三态 `CoverageState{present | unmapped | broken}`（与 ENGINEERING 决议① / T16、GUI 状态测 DoD 同源）**：每个事件行按 `CoverageState = present | unmapped | broken` 呈现 —— **GUI 从 manifest + 文件存在性算，helper 不改播放行为**。`present`（配了且文件在）= 上述完整行（名 + id + 文件名 + 波形 + 试听 ▶）；`unmapped`（manifest 没配此 event）= 行显「未配置」、试听 ▶ 禁用；`broken`（配了，但目标文件不存在 / 路径未通过包目录 containment）= 行显「文件丢失」并入 `doctor`、试听 ▶ 禁用。**`broken` 只判「文件缺失 / 路径无效」，不含「音频内容损坏」**：`doctor` 现只做 `fileExists` + containment，`play` 是 fire-and-forget（刻意不 `waitUntilExit()`，见 `Play.swift`），`afplay` 拒绝坏文件的信号回不到进程里。「文件在、但解不出声」要另立状态，须先给 doctor 或播放层加音频 lint —— v1 不做。`unmapped` 与 `broken` 两态都在**行尾提供逐事件导入绑定**（拖入 / 选文件 → 绑到该 event）去补。区分二者 = **真打包错误不被伪装成正常静默**。禁用观感用**显式禁用样式（控件置灰 + 图标降饱和），不整行降 opacity**（行内文字始终保 ≥ 4.5:1 对比度）。此三态与正交的**静音态**（`enabled=false`：控件区弱化 + 静音钮点亮）叠加，互不取代。
- **错误态用色（关键约束）**：app 自身错误（settings 不可写 / 解析失败 / helper 缺失）用 UI 语义 `error #FF453A`（真红）；**绝不用于四事件层**（StopFailure 永远琥珀）。非阻断提示（如 Claude Code 未装）用中性 `surface-2` + `text-2`，不上真红。
- **拖入 drop-zone**：虚线 1.5px `hairline-strong` + radius 10 + `text-2`；hover 命中 → 边框 / 文字转黏土 + `clay-soft` 底。
- **拒绝行**：真红 `circle-x` 字形 + `text-2` 说明，`原因`（真红）+「怎么修」一句；不道歉、不含糊。
- **内边距 / 圆角**：沿用面板 12–13pt、卡片 radius 10、控件 radius 6。
- ⚠️ **展柜 artifact 现状**：DESIGN.md 顶部链接的「设计系统预览」artifact 仍画着已移至 v2 的深夜降音量，且不在仓库 / CI 不可验。视觉真相源改为**仓库内 state gallery**（SwiftUI Preview 目录，与状态测试共用 fixtures，见 ENGINEERING T14）；外部展柜降为可选快照。

## App Icon（图标）

- **概念**：同心声波弧 / 放射波形，同时读作一个 **C**（Claudio）。奶油 `#F0EEE6` 底 + 黏土 `#D97757` 弧，暖而克制。
- **不碰** Anthropic 官方标 / 星芒 / wordmark（致敬式伴侣，**非官方**）。
- **两版**：全彩 Dock 图标；**单色模板菜单栏字形**（16×16pt，纯 alpha，自动亮/暗，可做「视觉回放」动画）。

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
