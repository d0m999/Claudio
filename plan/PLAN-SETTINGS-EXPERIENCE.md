# PLAN — 统一设置体验完整实施计划

> 状态：**规格与 allowlisted 多 Provider SoT 已完成；统一设置迁移及多 Provider Swift 实施尚未开始**
>
> 日期：2026-08-26
>
> 范围：把当前分散的集成、事件、声音包与零散偏好收口到一个原生 macOS 统一设置窗口，
> 完整交付「通用、集成、事件与提示音、通知、显示、声音、用量、快捷键、关于」九个设置目的页。
> 完整九页产品验收由 GitHub #85 及其子 tickets 拥有；#103 只完成本文、ADR、执行计划与原型的
> allowlisted 多 Provider SoT 对齐，不授权 adapter、真实凭据、production UI 或 Provider smoke。
>
> 视觉原型 SoT：
> `mockups/ai-app-manager-native-macos.html?page=events&app=workbuddy&prototype=tts&profile=elevenlabs-global&stage=applied&credential=verified`
>
> AI 提示音的 Provider/profile、凭据、候选与采用领域合同由
> `plan/PLAN-CONSUMER-TTS-EXECUTION.md` 定义；本计划固定其统一设置投影并完成周边页面。

## 0. 目标与完成定义

用户从菜单栏面板进入设置后，只看到一个标准 macOS 窗口。左侧固定显示九个设置目的页，右侧在
同一窗口中切换真实、可操作的内容；面板、集成诊断、事件管理和声音映射的深链接都落到同一个
类型化路由。关闭窗口后，焦点只由这一个窗口 owner 归还，不再在三个 retained window 之间转移。

完成必须同时满足：

- 九个目的页全部存在且可通过键盘、VoiceOver 和鼠标到达；
- 不保留「后续接入」「原型占位」或只弹 Toast 的假动作；
- 每个可写控件都有真实事实源、持久化边界、失败呈现、回滚或重试语义；
- 现有集成、声音配置、声音包、AI 提示音和回执模型继续是唯一事实源，不复制写入路径；
- 默认窗口的信息架构、层级、间距、色彩重量和主要布局与批准原型一致；
- 原型与领域规则冲突时，`CONTEXT.md`、ADR 和真实模型决定语义，原型只决定视觉与交互层；
- 自动测试、原生手验、真实系统权限、真实 provider 与发布证据分层报告，不能互相冒充。

### 0.1 自动拍板决议

| 议题 | 决议 |
|---|---|
| 窗口形态 | 一个 app-lifetime retained `SettingsWindow`，九个目的页在同一侧栏切换 |
| 现有窗口 | 复用模型与视图能力；迁移完成后退役独立的 Integrations/EventSettings/SoundPacks 窗口 |
| 原型权威 | 原型负责导航、视觉层级和交互形态；领域文档与真实代码负责语义、安全和能力事实 |
| 完整度 | 九页都必须是真功能；占位、演示常量和无副作用按钮不算完成 |
| 实施方式 | 按依赖拆成可独立验收的纵向 tickets；全部通过后才声明统一设置完成 |
| 文档归属 | 本计划是总计划；TTS 计划只保留 AI 提示音子域，并与本计划互相引用 |
| 视觉验收 | 原生视觉合同，不逐像素复制 CSS；覆盖明暗模式、窗口断点、四档界面文字和 VoiceOver |

## 1. 当前事实与逐页差距

当前 `ClaudioGUIApp` 的 `Settings { EmptyView() }` 只为满足 SwiftUI `App` 协议存在，且合成的
`appSettings` 命令被移除。生产 UI 由 `MenuBarController` 分别持有
`IntegrationsWindowController`、`EventSettingsWindowController` 和
`SoundPacksWindowController`；因此当前截图中的「事件与提示音」只是独立窗口，不是完整设置页面。

| 设置目的页 | 原型承诺 | 当前可复用事实 | 主要缺口 |
|---|---|---|---|
| 通用 | 登录时打开、语言、窗口行为 | `ClaudioLanguageStore`、UserDefaults | 无统一页面；无系统语言模式；无登录项服务 |
| 集成 | 来源列表、状态、开关、检测、回执 | 完整 `IntegrationsWindowModel/View` 与 manager bridge | 独立窗口；视觉结构不同；原型错误地以 App 代替 Surface |
| 事件与提示音 | Surface、五事件、播放设置、BYOK AI 生成 | `EventSettingsWindowView`、`PanelConfigController`、AI cue 闭环 | 独立窗口；外壳、层级、行密度与原型差距大；路由仍跳声音包窗口 |
| 通知 | 提醒开关、专注/会议静默 | 逐事件开关；暂无系统静默策略 | 原型前三个开关重复事件配置；Focus/Calendar 无权限与跨进程模型 |
| 显示 | 面板宽度、菜单栏状态点 | 四档界面文字、固定/自适应面板宽度、模板图标 | 无页面；无用户宽度偏好与状态点开关 |
| 声音 | 包列表、导入、试听、使用 | 完整 Sound Packs window、共享 `SoundPackLibrary` | 独立窗口；原型只有演示两行，未覆盖真实编辑能力 |
| 用量 | 近期数字、诊断日志 | 每 Surface 20 条/30 天脱敏回执、滚动诊断日志 | 无页面；原型统计为假数据；`0 B 网络上传` 与 BYOK 事实冲突 |
| 快捷键 | 面板、试听、静音快捷键 | 无全局快捷键基础设施 | 原型明确是占位；试听/静音缺少稳定的全局目标语义 |
| 关于 | 产品信息 | Bundle 与本地许可/资产 | 原型明确是占位；无版本、许可、隐私与复制诊断信息界面 |

## 2. 对原型的必要修正

这些修正不削减九个目的页，而是删除无法诚实落地或与现有领域冲突的演示语义：

| 原型内容 | 生产决议 | 原因 |
|---|---|---|
| 侧栏底部「本地优先 · 无网络客户端」 | 改为「本地优先」；AI 页按 profile 披露 BYOK 直连 | allowlisted Provider 会按用户动作联网，不能继续声称无网络客户端 |
| 以 App/Agent 作为事件配置身份 | 按宿主产品分组，选择稳定事件来源 `HostSurfaceID` | 产品不直接拥有统一事件能力；Surface 才拥有协议、配置、授权和回执代次 |
| 「全屏时隐藏」 | 从生产规格删除 | 没有可靠公开 API 判断其他 app 的全屏状态；引入 AX/屏幕读取不符合该偏好的价值与隐私成本 |
| 「空闲时自动隐藏」状态项 | 从生产规格删除 | claudi0 是无 Dock 的菜单栏 app，隐藏唯一入口会让用户无法主动重新打开 |
| 通知页重复任务开始/响应结束/待响应开关 | 事件开关只留在「事件与提示音」；通知页负责动态静默策略 | 避免同一事件出现两个表面相同、优先级不明的开关 |
| 「会议期间静音」 | 精确改名为「日历忙碌时静音」 | 不读取标题猜测会议；只在授权后把当前非全天 busy 事件视为静默事实 |
| 用量页「0 B 网络上传」 | 改为隐私边界说明，不显示伪精确字节数 | 宿主内容不上报，但用户显式 AI 生成会与所选 Provider 交换描述和音频 |
| 声音页两个演示包 | 显示完整声音包库与唯一映射编辑器 | 原型行只是视觉样例，不能取代真实库状态、错误和安全写入 |
| 快捷键中的全局试听/静音 | v1 只提供目标明确的打开面板、打开设置、打开当前作用域事件页 | 全局试听没有稳定事件目标；全局静音曾被明确删除，不能借快捷键暗中复活 |
| 快捷键/关于占位页 | 补齐下述真实规格 | 导航骨架不构成功能完成 |

## 3. 目标架构

~~~text
Panel / menu action / destination action
                    │ SettingsRoute
                    ▼
          SettingsWindowController
          ├─ lifecycle + focus handback
          ├─ selected destination
          └─ typed deep-link routing
                    │
        SettingsShellView (fixed sidebar)
                    │
   ┌────────┬────────┬────────┬────────┐
 General  Integrations Events  Notifications ... About
   │          │         │          │
 typed UI  existing   existing   policy adapters
 prefs     manager    config/AI
   │          │         │          │
 UserDefaults / host manager / config lock / Keychain / expiring quiet snapshot
~~~

### 3.1 类型化设置路由

路由必须表达顶层目的页和可选的深链接上下文，不允许用显示名称、HTML query string 或多个独立
回调猜目标：

~~~swift
enum SettingsDestination: String, CaseIterable {
    case general, integrations, events, notifications, display, sounds, usage, shortcuts, about
}

enum SettingsRoute {
    case destination(SettingsDestination)
    case integrations(surface: HostSurfaceID?)
    case events(scope: PanelSoundScopeID, event: Event?)
    case sounds(SoundPacksWindowRoute)
}
~~~

具体类型名可以在实施时按模块边界调整，但必须保持以下不变量：

- 路由携带稳定 ID，不携带展示名称；
- generic「设置…」打开上次合法的顶层目的页；显式深链接永远覆盖上次选择；
- 持久化只保存顶层目的页 raw value，不保存可能陈旧的 pack、Surface 或 Event；
- 不存在、隐藏或损坏的深链接目标 fail closed 到对应目的页的可见错误，不静默改写别的目标；
- 页面内跳转复用同一个 router，禁止重新打开第二个标准窗口。

### 3.2 所有权边界

`SettingsWindowModel` 只拥有导航与窗口级状态，不能成为汇总所有领域数据的 God object。

| 事实 | 唯一 owner | 设置页职责 |
|---|---|---|
| 宿主安装、连接、能力、回执 | `HostIntegrationManager` / bridge | 订阅、投影、提交显式动作 |
| 全局与 Surface 声音配置 | 现有 config transaction/controller | 读取 effective profile，走现有外科式写入 |
| 声音包磁盘事实 | app-lifetime `SoundPackLibrary` | 订阅同一 snapshot，不重复扫描 |
| 声音包写入与映射 | `SoundPacksWindowModel` 既有写入 seams | 迁入「声音」目的页，不另造轻量 editor |
| AI 提示音 | credential manager、generation engine、adoption seam | 复用现有 view model；不接触 key 明文 |
| UI 偏好 | typed `SettingsPreferencesStore` | 读写有版本/默认值/非法值回退的 key |
| 登录项 | ServiceManagement adapter | 显示系统真实 status；不以 UserDefaults 冒充 |
| Focus/Calendar | GUI permission adapters | 发布最小动态静默快照；不进入 hook 回执 |
| 活动摘要 | `HostHookReceiptStore` 与现有 log reader | 有限投影，不创建云端 analytics |

### 3.3 持久化与信任边界

| 数据 | 存储 | 规则 |
|---|---|---|
| 语言、界面文字、面板宽度、状态点、通知偏好、快捷键、上次目的页 | UserDefaults | typed key；非法值回落；有迁移测试 |
| pack、事件、主音量、Surface 覆盖 | `~/.claudio/config.json` | 继续使用锁与外科式 JSON 更新，保留未知字段 |
| AI provider key | macOS Keychain | UI 只见状态，明文不进入页面状态或日志 |
| 动态静默 | 私有、带 schema/revision/expiry 的原子 snapshot | 只包含布尔原因和时间，不包含 Focus 名称、日历标题、参与人或位置 |
| 回执与日志 | 现有 0600 私有文件 | 不扩大字段；不保存提示词、响应、项目路径或音频绝对路径 |

## 4. 统一窗口与共享视觉合同

### 4.1 窗口与侧栏

- 默认内容尺寸以原型的 `1240 × 820` 为基准；最小尺寸 `960 × 640`，内容不足时目的页纵向滚动，
  不允许窗口外壳横向滚动。
- 使用真实 AppKit title bar、traffic lights、缩放和窗口恢复，不自绘网页窗口 chrome。
- 侧栏默认 252 pt；紧凑窗口收至 220 pt；最大文字档允许增宽并让长标签自然换行。
- 目的页顺序固定为原型九项；「高级」和「claudi0」分组保留，品牌写法使用 `claudi0`。
- 选中态使用中性底与彩色方形图标，不用事件色表达错误或连接状态。
- 右侧内容最大阅读宽度约 820 pt；设置组使用系统设置式圆角分组，不堆叠装饰卡片。
- 每个目的页只拥有一层主 ScrollView；嵌入的现有 view 必须移除重复外层滚动。

### 4.2 窗口生命周期与入口

- 一个 `SettingsWindowController` 由 composition root 创建并在 app 生命周期内保留；
  `isReleasedWhenClosed = false`，窗口内容和 app-lifetime models 不因关闭重复实例化。
- 菜单栏增加明确的「设置…」入口；现有「连接与诊断」「打开设置」「管理声音包」分别提交
  `.integrations`、`.events`、`.sounds` 深链接。
- 继续移除 SwiftUI 合成的 process-wide `appSettings` 命令：popover 激活时 `⌘,` 仍可能抢走
  前台宿主的设置快捷键。快捷键页允许用户自行注册不冲突的 claudi0 全局入口。
- 首次打开捕获前台外部 app；关闭统一窗口只消费一次 handback。页面切换、sheet 和内部路由不交还焦点。
- 重复调用 show 只提到前台并路由，不创建窗口，也不重置不相关页面状态。

### 4.3 共享状态与无障碍

- 每页至少覆盖 loading、ready、empty、permission-required、write-failed 和 stale（如适用）；
  没有数据不伪装成错误，读取失败不伪装为空。
- 所有错误都从语义状态投影为可见文案与 VoiceOver 文案，禁止只打印日志或 Toast 后报成功。
- Sidebar → 页面标题 → 页面首个可操作项形成稳定焦点序；路由到 Surface/Event/pack 时聚焦目标或
  可见失败说明，不制造 phantom focus。
- 支持简体中文与 English、四档 `ClaudioInterfaceTextSize`、明暗模式、Reduce Motion、
  Increase Contrast 和默认关闭 Full Keyboard Access 的真实 macOS 行为。
- 新文案必须同时更新 `Localizable.xcstrings` 和 `ClaudioL10nKey.allKnown`；路径、事件 token、
  manifest ID 和版本号才使用等宽字体。

## 5. 九个目的页完整规格

### 5.1 通用

用户结果：配置登录启动和语言；不存在会让状态项永久消失的偏好。

内容与行为：

1. **登录时打开**
   - macOS 13+ 使用 `SMAppService.mainApp`，状态穷尽未注册、已启用、等待系统批准和不可用；
   - macOS 12 使用签名的内嵌 LoginItem helper 与 `SMLoginItemSetEnabled` 兼容层；
   - UI 读取 ServiceManagement 真实状态，不把上次点击值当成功；
   - 等待批准时提供打开系统登录项设置的明确动作；写失败保留旧状态。
2. **App 语言**
   - 选项为跟随系统、简体中文、English；
   - 将现有显式语言 raw value 无损迁移为 preference，resolved language 仍只有 zh-Hans/English；
   - 系统模式监听 locale 变化，即时重投影窗口标题、侧栏和当前页面，不重建领域模型。

Generic「设置…」默认回到上次合法的顶层目的页；没有记录或记录损坏时回到「通用」。这是窗口
导航行为，不额外暴露一项难以解释的用户偏好，也不保存陈旧深链接。

明确不做：全屏检测、隐藏状态项、启动时自动弹设置、静默申请系统权限。

验收：ServiceManagement 四态、macOS 12/13+ adapter、语言迁移/非法值/系统变化、窗口标题即时更新
都有自动 seam；真实登录重启必须用签名 app 单独手验，ad-hoc `dev-bundle` 不构成证据。
macOS 13+ 的主 app 登录项入口见 Apple 的
[SMAppService.mainApp](https://developer.apple.com/documentation/servicemanagement/smappservice/mainapp)。

### 5.2 集成

用户结果：在统一设置里查看和管理每个**事件来源**的连接、事件能力与当前代次回执；任何动作只影响
明确选择的 Surface。

内容与行为：

- 按宿主产品分组显示全部已发布 Surface，不把 Claude、Codex view 或 WorkBuddy 合并成一个 App；
- 每行显示连接状态、当前激活、`supported/total`、in-flight 状态和真实错误；
- 右侧/下方检查器复用当前 capability matrix、配置来源、原生事件、最新回执、诊断与恢复动作；
- 启用/停用调用 manager 的 connect/disconnect，不把 toggle 本地翻转冒充成功；
- 「重新检测」刷新当前事实；「管理事件」内部路由到同 Surface 的事件页；
- 清除脱敏回执历史必须确认，只清历史，不改连接、当前稳定回执或声音偏好；
- 显式支持、当前实现和当前激活继续是三条独立事实。

验收：迁移前后 manager action、receipt transition、错误恢复和 accessibility label 保持等价；
Codex `4/5` 与 WorkBuddy `2/5` 是诚实正常能力，不得为了填满原型显示假支持。

### 5.3 事件与提示音

用户结果：在原型批准的层级内切换 Global/Surface，管理五个语义事件、试听、自动播放开关、
主音量、effective pack，并在合格目标上完成 AI 提示音闭环。

布局与行为：

- 页面顶部显示标题、说明、页面级 AI 声音生成服务卡和「试听全部」；
- 内层左栏标题使用「声音作用域」，先显示 Global，再按宿主产品显示 Surface；
- 右侧显示当前 scope、连接/覆盖状态、五个事件行和播放设置组；
- Global 显示 claudi0 event token，不伪造宿主原生事件；Surface 显示真实 native event、接口支持和实现状态；
- 行内动作固定为开关、当前声音/文件、试听；不支持、缺声、损坏、主音量零分别显示真实原因；
- 「管理声音」不再打开第二窗口，路由到 `.sounds(surface, packID, event)`；
- 主音量保持唯一全局轴；Surface 只写稀疏 pack/event 覆盖；损坏覆盖 fail closed；
- AI 入口只对明确 Surface、已实现事件和独立可编辑用户包开放；Global、内置/共享/陈旧包显示原因。

AI 可见流程固定为：

~~~text
选择 Provider/profile -> 描述 -> 显式生成 -> 3 个候选和命名 -> 显式采用
~~~

1. 页面级选择 allowlisted profile，并配置、替换或删除当前 profile 的 BYOK；
2. 第一阶段只输入声音描述，不输入名称；保存或替换 API Key 后不自动生成；
3. 本地隐藏的 `AICueSoundPlan` 按当前 profile 的固定 route 编译，顺序请求三个候选；
4. 候选完整通过校验后一起显示，不自动播放；
5. 候选阶段建议并允许修改一个最终名称；
6. 用户明确采用后才进入现有 `AudioImport` + manifest bind；失败保留旧声音。

选择 profile、scope、Event 或离开页面会取消并清理未采用候选，已采用声音不受影响。保存凭据后返回
原表单并保留描述与 profile；用户必须再次显式点击生成。

#### 5.3.1 首批 Provider/profile 目录

用户只能选择以下四个注册 profile；默认 `elevenlabs-global`。UI 不提供任意 endpoint、model、voice
或 region 输入，不自动 fallback、跨区或跨 Provider 重试。`routes.keys` 是 capability 的唯一真相；
界面能力标签和本地阻止逻辑都从它投影。

| Profile | 固定 origin/path | Auth / credential slot | 固定 model、voice、输出 | `routes.keys` / locale | Validation |
|---|---|---|---|---|---|
| `elevenlabs-global` | `https://api.elevenlabs.io`；probe `GET /v1/models`；speech/mixed `POST /v1/text-to-speech/JBFqnCBsd6RMkjVDRZzb`；animal/soundEffect `POST /v1/sound-generation` | `xi-api-key`；旧 account `elevenlabs` | `eleven_v3` + `JBFqnCBsd6RMkjVDRZzb`；`eleven_text_to_sound_v2`；直接 MP3 | `speech`、`mixed`、`animal`、`soundEffect`；`zh` / `zh-Hans` / `en` | `readOnlyProbe` |
| `minimax-global` | `https://api.minimax.io`；probe `POST /v1/get_voice`；生成 `POST /v1/t2a_v2` | Bearer；`minimax-global` | `speech-2.8-hd` + `Chinese (Mandarin)_Reliable_Executive`；32 kHz / 128 kbps / mono MP3；JSON hex | 仅 `speech`；`zh` / `zh-Hans` | `readOnlyProbe` |
| `qwen-singapore` | `https://dashscope-intl.aliyuncs.com`；生成 `POST /api/v1/services/aigc/multimodal-generation/generation`；`X-DashScope-SSE: enable` | Bearer；`qwen-singapore` | `qwen3-tts-instruct-flash` + `Cherry`；SSE Base64 PCM，24 kHz / 16-bit / mono / little-endian，封装 WAV | 仅 `speech`；`zh* -> Chinese`、`en* -> English` | `deferredUntilExplicitGeneration` |
| `qwen-beijing` | `https://dashscope.aliyuncs.com`；path/header 同 Singapore | Bearer；`qwen-beijing` | 与 Singapore 相同 | 仅 `speech`；与 Singapore 相同 | `deferredUntilExplicitGeneration` |

MiniMax/Qwen 不显示 animal、soundEffect 或 mixed 为可生成；不支持 modality/locale 时保留描述，在读取
credential 或发网络前显示可修正错误。Qwen Singapore/Beijing 是两个独立 region profile 和 Keychain
slot，不能交叉读取 key。

#### 5.3.2 逐 profile 凭据状态与动作

页面级服务卡同时投影 profile 选择与当前 profile 状态；不显示 key 内容。每个 profile 独立拥有：

- `missing`；
- `stored(verified | deferred | rejected)`；
- `unavailable`；
- activity：`probing`、`saving`、`pendingReplacement`、`deleting`。

“Keychain 可读”“已保存”和“在线验证成功”是不同事实：

| Policy | 首次保存 / 替换 | 成功文案 | 失败与旧 key |
|---|---|---|---|
| ElevenLabs/MiniMax `readOnlyProbe` | “验证并保存”/“验证并替换”；先调用只读 probe，再原子写 Keychain | “已验证并保存” | probe 或写入失败保留旧 active key，显示失败原因 |
| Qwen `deferredUntilExplicitGeneration` | “保存 API Key”；首次保存写 stored-unverified active，已有 active 时替换才写 pending；均不发模型请求 | “已保存，待首次生成验证”；显式生成成功后首次 active 标记 verified 或 pending 提升为 active | pending replacement 可取消并恢复原 active 的验证状态；仅 pending 的明确 401 丢弃 pending 并保留旧 active，权限、额度、429/5xx、网络或取消不能伪装成 key 无效，也不自动用旧 key 重试 |

未配置当前 profile 时点击生成，保留描述与 profile 选择并打开凭据界面；保存后返回原表单，用户必须
再次点击生成。删除前二次确认，只删除当前 profile 的 active/pending credential；其他 profile 和已采用
声音保持不变。ElevenLabs 继续直接使用 legacy account `elevenlabs`，没有迁移 UI。

#### 5.3.3 逐 profile 披露

首次配置每个 profile 前分别显示：

| Profile | 本机直连、地区与数据 | 费用/配额与验证语义 |
|---|---|---|
| `elevenlabs-global` | 本机直连 ElevenLabs global origin；发送描述、隐藏规范化结果与生成元数据；供应商留存和模型改进规则适用 | 生成可能消耗 ElevenLabs 配额；list-models probe 不生成音频，成功只证明该 key 通过此次只读检查 |
| `minimax-global` | 本机直连 MiniMax global origin；首批 Mandarin speech；供应商数据处理规则独立适用 | T2A 可能消耗 MiniMax 配额；get-voice probe 不生成音频，不能用 ElevenLabs 状态代替 |
| `qwen-singapore` | 本机直连新加坡 DashScope origin；只使用此 region 的独立 key；供应商新加坡地区处理规则适用 | 保存 key 不发模型请求、生成费用为零；下一次显式生成才验证并可能计费 |
| `qwen-beijing` | 本机直连北京 DashScope origin；不复用 Singapore key；供应商北京地区处理规则适用 | 与 Singapore 相同的 deferred 语义，但两地配额、权限和 smoke 证据互不替代 |

Claudio 不承诺任何供应商 zero retention，不展示统一账单或推算费用。API Key 只存 macOS Keychain；
不得进入设置、日志、receipt、manifest、截图或仓库。描述、隐藏声音计划、provider 响应和候选音频也
遵循 `PLAN-CONSUMER-TTS-EXECUTION.md` 的最小化与临时清理边界。

#### 5.3.4 原型状态与证据分层

多 Provider Events 原型路径为：

`mockups/ai-app-manager-native-macos.html?page=events&app=workbuddy&prototype=tts`

原型同时显示四个 profile，并允许用 `profile`、`credential` 和 `scenario` query 演示：

- `profile=elevenlabs-global&credential=verified`
- `profile=minimax-global&credential=missing`
- `profile=qwen-singapore&credential=deferred`
- `profile=qwen-beijing&credential=unavailable`
- `credential=rejected|pending` 用于拒绝和 pending replacement 状态。
- `profile=minimax-global&scenario=unsupported-modality|unsupported-locale` 用于能力/语言本地阻止状态。
- 旧 `credential=ready` 只在缺省、显式或未知 `profile` 最终回落到 `elevenlabs-global` 时兼容为
  `verified`；对 MiniMax/Qwen 忽略该旧别名并保留各自固定 fixture 状态。

选择 MiniMax/Qwen 后用非 speech 描述可见地展示 unsupported modality；MiniMax 使用 English 台词时
展示 unsupported locale。原型只模拟状态，不联网、不持久化，也不得接收真实 key。旧的单 Provider
页面或截图只能作为 ElevenLabs 核心闭环历史参考，不是多 Provider UI SoT。

验收必须覆盖 prompt、interpreting、generating、candidates、playing、adopting、applied、逐 profile
credential missing/unavailable/rejected/pending、unsupported modality/locale、provider failure、validation
failure、target drift 和 adoption rollback。文档与原型中的四个 profile 必须保持 exact origin/path、
auth、model/voice、输出、locale、routes、credential slot 与 validation policy 一致；MiniMax/Qwen 只有
`speech`，ElevenLabs 保留四类 route，所有 UI capability 从 `routes.keys` 派生。

自动 fixture、静态原型和本地 bundle 只能证明相应合同与投影。真实 key、真实/付费 Provider smoke、
真实音频质量、native macOS UI、键盘/焦点、VoiceOver、双架构、签名、公证和发布都需要分别授权和
记录；一个 Provider 或地区的结果不能替代另一个。

详细 AI 领域、transport 和音频安全合同见 `plan/PLAN-CONSUMER-TTS-EXECUTION.md`；决策摘要见
`docs/adr/0006-use-elevenlabs-byok-with-fixed-modality-routing.md`。

### 5.4 通知

用户结果：控制**自动提示音何时临时静默**，而不是在第二个页面重复逐事件开关。手工试听永远不受
动态静默影响，仍受主音量、文件安全和格式检查约束。

内容与行为：

1. **专注模式中静音**
   - 默认关闭；用户打开时才通过 `INFocusStatusCenter` 请求授权；
   - 显示未请求、已授权、被拒绝、系统限制和当前是否正在抑制；
   - 不记录 Focus 名称或模式细节。
2. **日历忙碌时静音**
   - 默认关闭；用户打开时才通过 EventKit 请求读取事件所需权限：macOS 14+ 使用
     `requestFullAccessToEvents`，macOS 12–13 使用已废弃但在该系统线仍正确的
     `requestAccess(to: .event)` 兼容 adapter；
   - 只判断当前非全天、availability 为 busy 的事件，不保存标题、位置、URL、参与人或正文；
   - 权限被拒时开关不伪装成功，提供打开隐私设置动作。
3. **当前静默状态**
   - 可见显示未静默、Focus、日历忙碌、组合原因、状态过期或 observer 失败；
   - 提供「管理事件提示音」内部路由，不复制五个事件开关。

GUI 把授权后的最小事实发布成 ADR 0009 定义的动态静默快照。helper 只接受 schema 正确、revision
不倒退且尚未过期的 regular file；损坏/过期快照不继续静音，并写入不含私人信息的诊断结果。

官方平台边界：Focus 访问使用
[INFocusStatusCenter](https://developer.apple.com/documentation/intents/infocusstatuscenter)，日历读取必须
由用户授权，详见 Apple 的
[EventKit event store](https://developer.apple.com/documentation/eventkit/accessing-the-event-store)。

### 5.5 显示

用户结果：从一个页面调整界面文字、面板宽度和菜单栏状态点；主面板现有 `Aa` 快速入口继续镜像
同一份偏好，不产生第二套状态。

内容与行为：

- **界面文字**：紧凑、标准、较大、最大四档，复用现有 `ClaudioInterfaceTextSize`；
- **面板宽度**：自动、紧凑、宽松。自动使用当前内容/文字档决策；显式选择仍要被最小安全宽度 clamp，
  最大文字档不得因用户选紧凑而裁切；
- **菜单栏显示状态点**：只控制 Orbit Zero 的状态点/活动变体，不隐藏状态项、不改变事件语义；
- 变化即时作用于当前窗口/面板，持久化失败或非法 raw value 回落到安全默认并可测试。

验收：三种宽度 × 四档文字 × 中英文 × 明暗模式没有横向裁切；状态点关闭后 VoiceOver 仍播报
完整 app/活动状态，不能把唯一状态信息只藏在像素中。

### 5.6 声音

用户结果：在统一设置中完成全部声音包浏览、导入、复制、使用、映射、恢复、删除、试听与 Finder 动作；
这里是唯一完整映射编辑器。

内容与行为：

- 迁入现有 `SoundPacksWindowView/Model` 能力，复用 app-lifetime `SoundPackLibrary` 和 refresh coordinator；
- 左侧/顶部 scope 明确显示正在管理 Global 或具体 Surface；
- 包列表显示 built-in/user、license、完整/partial/broken、当前选择、只读/可编辑和刷新状态；
- 支持导入声音包、复制内置包、使用此包、逐事件选文件/清除绑定/试听/在 Finder 显示、恢复出厂、删除用户包；
- AI 采用继续调用同一个 headless adoption seam，不要求先切到声音页；成功后同一 library revision 更新两页；
- 首次加载、SWR 旧快照、刷新失败、库失败、单包损坏、写入中、锁冲突和恢复 salvage 全部可见；
- 100 包性能 ADR、浅 inventory、包锁、安全路径和未知字段保留规则不变。

迁移完成后删除独立 `SoundPacksWindowController` 的 window ownership，但保留/重构其 model owner、
adoption 和 route resolution；不得同时保留可写的 standalone 与 embedded 两个 editor。

### 5.7 用量

用户结果：查看本机当前保留范围内的脱敏活动与诊断入口，准确理解这不是完整历史、云端遥测或
任一 Provider 的账单。

内容与行为：

- 摘要卡显示「已保留回执」「其中已播放」「静音/去抖/失败」，从全部 Surface 的现有历史投影；
- 明确标注范围：最近 30 天、每 Surface 最多 20 条，因此不称「本周总事件」或完整用量；
- 按 Surface 与公共 `Event` 展示有限分组，不显示提示词、响应、项目、会话、日历或声音路径；
- 诊断区显示滚动日志是否存在、大小、最近失败数量；提供在 Finder 显示与复制路径；
- 清除历史/日志是显式破坏动作，分别确认、分别加锁，不能影响连接 marker、当前回执或声音配置；
- 隐私说明区分：宿主内容不上传；用户点击 AI 生成时描述和音频与所选 Provider 交换；供应商费用和
  配额必须去对应 Provider 查看，claudi0 不伪造成本。

本页不新增完整 analytics ledger，不扩大回执保留量，也不从诊断日志反推成功事件。

### 5.8 快捷键

用户结果：可选地注册目标明确的全局入口，不要求 Accessibility/Input Monitoring，也不监听所有按键。

首版动作固定为：

- 显示/隐藏 Claudio 面板；
- 打开统一设置；
- 打开当前合法声音作用域的「事件与提示音」。

实现契约：

- 使用 `RegisterEventHotKey`/`UnregisterEventHotKey` 封装的 `GlobalShortcutRegistrar`；不得使用
  `NSEvent.addGlobalMonitorForEvents` 观察系统所有按键，因为 Apple 明确指出 key monitor 需要
  Accessibility trust；
- 录制只在聚焦的本地控件内读取一次组合，不保存字符流；组合至少含 Command 或 Control，拒绝裸键、
  仅 Shift/Option、系统保留和同 app 重复组合；
- 替换采用 unregister old → register new → persist 的事务；新注册失败时重新注册旧值并显示冲突；
- shortcut ID、key code 和 modifiers 版本化持久化；未知/损坏值禁用该项，不猜测别的按键；
- 关闭设置窗口不注销快捷键；app 退出由系统和 registrar 清理。

Apple 对全局 `NSEvent` key monitor 的权限说明见
[addGlobalMonitorForEvents](https://developer.apple.com/documentation/appkit/nsevent/addglobalmonitorforevents%28matching%3Ahandler:%29)。

明确不做：全局试听、全局静音、宏、连续键序列、按键记录、导入第三方快捷键配置。

### 5.9 关于

用户结果：在统一设置中确认当前 app 身份、版本、运行架构、兼容下限、许可和隐私边界，并复制安全的
诊断摘要。

内容与行为：

- 显示 Orbit Zero 图标、`claudi0`、`CFBundleShortVersionString`、build、当前架构和最低 macOS；
- 提供复制版本信息、打开开源许可/声音包 attribution、打开隐私说明；
- 「复制诊断摘要」只包含版本、架构、macOS、已发布 Surface 的语义状态和路径是否存在，不包含路径值、
  receipt 内容、API key、prompt、response、Calendar 或个人声音包名称；
- Bundle 字段缺失时显示未知并让测试捕获，不崩溃、不写假版本；
- 没有 updater 前不显示「检查更新」假按钮，没有确定 URL 前不放空官网/反馈链接。

## 6. 页面间一致性与刷新

- `SettingsWindowController` 在窗口显示与 app 重新激活时请求各 owner 的适当观察，不把一个页面的刷新
  复制成九次磁盘扫描。
- Sound library 仍只有一个 refresh owner；其他页面订阅 revision 并使用最新 config 重投影。
- Integrations action 成功后更新共享 store，Events/Notifications 只消费新事实；失败保留旧事实和 action error。
- Display/General 的 UserDefaults 变化通过 typed store 发布，不依赖每个 view 自己的 `@AppStorage` 字符串。
- AI session 在离开 Events 或关闭窗口时清理未采用候选；切到同页其他 Event 也按现有契约失效。
- 任何目的页 write 成功后只刷新受影响 owner；write 失败不得发布假 revision 或清空旧成功状态。

## 7. 实施任务与依赖图

下面每项可独立成为 ticket。每个 ticket 都必须同时包含 Foundation seam、SwiftUI wiring、双语文案、
回归测试和失败态；不得把测试/无障碍统一推迟到最后补。S1–S13 可以在开发分支内逐步完成，但
旧生产入口保持不变；只有 S14 在九页均达到等价门槛后执行一次性 cutover，避免用户看到半成品侧栏。

~~~text
S0 文档与契约锁定
 └─ S1 路由/窗口生命周期
     ├─ S2 typed 偏好与迁移
     │   ├─ S4 通用
     │   ├─ S8 通知策略 core ─ S9 通知页
     │   ├─ S10 显示
     │   └─ S12 快捷键
     ├─ S3 统一窗口视觉壳
     │   ├─ S5 集成迁入
     │   ├─ S6 声音迁入 ─ S7 事件/AI 迁入
     │   ├─ S11 用量
     │   └─ S13 关于
     └──────────────────────────┐
                                ▼
                 S14 深链接与旧窗口退役
                                ▼
                 S15 全状态/AX/视觉收口
                                ▼
                 S16 完整构建与真机验收
~~~

| Ticket | 直接依赖 | 可独立验收的交付物 |
|---|---|---|
| S0 | — | 领域词汇、ADR、原型修正与总规格一致 |
| S1 | S0 | 类型化路由、唯一 window owner 与生命周期 reducer 可在测试中独立运行 |
| S2 | S1 | typed preferences、旧值迁移、非法值回退与 observation 全绿 |
| S3 | S1 | 统一 shell 在 DEBUG gallery 中覆盖九个 route slot；尚不替换生产入口 |
| S4 | S2、S3 | 通用页、macOS 12/13+ 登录项 adapter 与语言模式完整 |
| S5 | S3 | 集成页迁入且 manager 行为、回执、恢复与 AX 等价 |
| S6 | S3 | 声音页迁入且完整包编辑、单 owner 与 100 包回归等价 |
| S7 | S3、S6、既有 TTS 子域 | 事件/AI 页迁入且 profile、scope、候选、命名、采用与回滚等价 |
| S8 | S2 | 权限 reducer、动态静默快照与 helper 播放策略独立全绿 |
| S9 | S3、S8 | 通知页及常驻 observer 完整，不复制事件开关 |
| S10 | S2、S3 | 显示页和 panel 共同消费文字、宽度、状态点偏好 |
| S11 | S3 | 用量页只投影既有有限数据并可安全清理 |
| S12 | S1、S2、S3 | 三项 Carbon 快捷键注册、冲突回滚与窗口外常驻完整 |
| S13 | S3 | 关于页真实 Bundle/许可/隐私/脱敏诊断完整 |
| S14 | S4–S7、S9–S13 | 所有入口原子切到统一窗口，三套旧 window wiring 退役 |
| S15 | S14 | 九页视觉、状态、AX、本地化和 state gallery 收口 |
| S16 | S15 | 自动门禁、签名真机矩阵与分层证据完成 |

### S0 — 规格与领域合同

- 接受本计划、ADR 0006/0008/0009 和新增 glossary；
- 把原型修正表作为实现约束，不在代码中照抄演示常量；
- 验收：文档无冲突，`git diff --check` 通过。

### S1 — 统一设置路由与 retained window 生命周期

- 新增 typed destination/route、route reducer、window selection 和 app-lifetime controller；
- 建立 generic/deep-link 打开、单窗口复用、focus handback、非法路由 fail-closed；
- 先在测试/DEBUG gallery 注入 route fixtures；S14 前不替换现有生产入口，也不暴露空目的页；
- 测试重复 show、路由覆盖、陈旧 ID、关闭一次 handback、窗口已打开再路由。

### S2 — Typed 设置偏好与迁移

- 建立 `SettingsPreferencesStore`，集中 key、默认值、非法值回退和发布；
- 迁移现有语言/文字 raw value，新增面板宽度、状态点、通知策略偏好、快捷键与上次目的页；
- 不把 helper 无需读取的 UI 偏好塞进 `config.json`；
- 测试旧值、新值、未知值、并发观察和 suite 隔离。

### S3 — 原型一致的统一窗口壳

- 完成 1240×820 默认/960×640 最小布局、侧栏、图标、分组、内容阅读宽度与明暗模式；
- 建立单层滚动、sidebar focus、选中态、窗口标题和状态 footer；
- DEBUG state gallery 覆盖九页注册、双语、四文字档和两窗口断点；
- gallery 可使用确定性 fixtures；production composition 不得包含 placeholder destination 或演示常量。

### S4 — 通用页与登录项

- 完成 ServiceManagement adapter、macOS 12 login helper bundle、系统语言模式和 generic reopen/fallback 行为；
- 更新 dev/release bundle、签名、双架构与 size 检查以包含 login helper；
- 真实登录重启与等待系统批准状态列为人工门禁。

### S5 — 集成页迁入

- 从 `IntegrationsWindowView` 提取 destination content，保留 model/action/receipt seams；
- 改成 prototype hierarchy，同时使用 Host Product → Surface 的领域身份；
- 所有去 Events/Sounds 的动作改用内部 router；
- 保持 capability、诊断、恢复、clear history、AX 和刷新测试。

### S6 — 声音页迁入

- 把 `SoundPacksWindowView/Model` 迁为唯一 Sounds destination；
- 解耦 window-owned focus/announcement 与领域 model，保留单一 library/adoption owner；
- 支持 `.sounds(route)` 精确选择 scope/pack/event；
- 覆盖完整库状态、写入、恢复、删除、导入和 100 包性能回归。

### S7 — 事件与 AI 提示音页迁入

- 把 `EventSettingsWindowView` 重构为 prototype hierarchy；嵌入页面级 BYOK card 和行内 composer；
- manage sound 使用内部 Sounds route，采用继续走同一个 request；
- 对齐 Provider/profile 选择、逐 profile 凭据策略、所有 AI 阶段、命名位置、候选、失败与清理；
- 视觉基准覆盖四个 allowlisted profile、verified/missing/deferred/unavailable/rejected/pending、
  unsupported modality/locale 以及 generating/candidates/applied/error。

### S8 — 动态静默领域与跨进程快照

- 建立 Focus/Calendar permission adapters（含 EventKit 12–13/14+ 分层）、纯 reducer、
  snapshot schema/revision/expiry 和原子 publication；
- helper 播放策略读取最小 snapshot，区分 automatic playback 与 manual preview；
- 过期、损坏、symlink、oversize、revision 倒退和 writer failure 都有测试；
- 不把日历/Focus 私密字段写入 snapshot、receipt 或 log。

### S9 — 通知页

- 完成 Focus 与「日历忙碌」开关、权限状态、当前静默原因、系统设置恢复动作；
- 关闭权限/偏好时停止 observer 并清理或过期 snapshot；
- 页面离开不撤销已启用策略；窗口关闭后常驻 owner 继续维护状态。

### S10 — 显示页

- 完成文字档、面板宽度和状态点；把 panel `Aa` 入口接到同一 store；
- 菜单栏和 popover 对偏好变化即时响应，宽度始终满足内容安全下限；
- 覆盖明暗、四文字档、三宽度和 VoiceOver 不依赖状态点。

### S11 — 用量页

- 从现有 history/log reader 建立只读 activity summary projector；
- 完成范围披露、Surface/Event 分组、Finder/复制路径、分别清除与错误恢复；
- 证明没有新增 prompt/response/provider billing/网络字节持久化。

### S12 — 快捷键页

- 建立 Carbon hot-key registrar、录制状态机、冲突/回滚和三项固定 action；
- router/action owner 与页面 model 分离，窗口关闭后保持注册；
- 测试 key normalization、重复、系统错误、旧值恢复和清除。

### S13 — 关于页

- 完成 Bundle facts projector、安全诊断摘要、许可/隐私资源与复制动作；
- 缺失 Bundle key、资源缺失和粘贴板失败有可见状态；
- 不引入 updater、网络探测或未确定外链。

### S14 — 深链接迁移与旧窗口退役

- MenuBarController 只拥有统一 settings controller；移除三套 pending window presentation 状态；
- 原 panel focus target 精确映射到 settings route，关闭后一次归还；
- 删除 standalone window wiring、autosave name 和重复 title/update subscriptions；
- 静态测试证明生产 composition root 只创建一个标准设置窗口和一个声音写入 owner。

### S15 — 全状态、视觉、无障碍与本地化收口

- 九页逐一建立 state gallery，不允许 gallery-only 逻辑与生产 mount point 漂移；
- 审查标题、说明、分组、行高、按钮层级、空/错/权限态、焦点和 announcement；
- 更新 `DESIGN.md`、README、手工验收清单和截图；
- `ClaudioL10nKey.allKnown` 与 xcstrings 双语完整。

### S16 — 完整验证与交付门禁

- 运行 helper/gui 全 harness、GUI debug build、xcstrings JSON、bundle、size、format baseline 和 diff check；
- 真机完成九页视觉/键盘/VoiceOver/四文字档/明暗/Reduce Motion；
- 单独验证签名 login item、Focus、Calendar、global hot key 和各 Provider/region 的真实 smoke；
- 双架构、签名、公证、发布仍按 release 流程另行授权，不由本地 ad-hoc 证明。

## 8. 自动测试合同

### 8.1 Foundation 与 helper

- destination/route 合法化、深链接和 last-destination reducer；
- typed preference migration、默认值、非法值与 observation；
- ServiceManagement status projector（系统调用注入）；
- quiet snapshot encode/decode、expiry、revision、文件安全与 automatic/manual policy；
- activity summary 的 20 条/30 天边界、损坏历史与 log 解析；
- shortcut normalization、注册事务、冲突回滚；
- about diagnostic redaction；
- helper 读取动态静默但不改变现有 config/receipt 语义。

### 8.2 GUI wiring

- 九个 destination 恰好一次、固定顺序、固定 accessibility identifier；
- 生产 root 挂载 `SettingsShellView`，不存在 `EmptyView`/placeholder copy/Toast-only action；
- Integrations/Events/Sounds 消费共享 owner，不创建幽灵 model；
- 所有跨页动作提交 typed route；
- 语言、文字、宽度变化不重建磁盘/host owners；
- AI credential sheet、candidate playback 和 adoption session 生命周期保持原契约。

### 8.3 必跑命令

~~~bash
swift run --package-path helper claudio-tests
swift run --package-path gui claudio-gui-tests
swift build -c debug --package-path gui --product ClaudioGUI
jq empty gui/Sources/ClaudioLocalization/Resources/Localizable.xcstrings
bash scripts/dev-bundle.sh
bash scripts/check-release-size.sh dist/claudi0.app
git diff --check
~~~

`swift format lint --strict` 需要与实施基线比较；既有诊断不能冒充本轮回归，本轮不得新增诊断。

## 9. 原生人工验收矩阵

每个目的页至少走查：

| 维度 | 必测 |
|---|---|
| 外观 | light、dark、Increase Contrast、Reduce Transparency |
| 尺寸 | 1240×820、960×640、手动放大；无水平裁切 |
| 文字 | 中文/英文 × 紧凑/标准/较大/最大 |
| 输入 | 鼠标、Tab/Shift-Tab、方向键、Return/Space、Escape、VoiceOver |
| 生命周期 | panel → deep link → settings、页间路由、关闭 handback、重复打开 |
| 失败 | 权限拒绝、config/pack/receipt/log 不可读、锁忙、磁盘写失败、陈旧 route |

额外真实门禁：

- 登录项：签名 app 注册、等待批准、注销、重启登录、移动 app 后状态；
- Focus：首次授权、拒绝、系统撤销、Focus 开关、observer failure；
- Calendar：首次授权、拒绝、busy/全天/free、事件变更、无标题数据泄漏；
- 快捷键：冲突、键盘布局变化、app 前后台、睡眠唤醒、注销；
- 声音：真实 `NSSound` 试听、主音量、动态静默只抑制 automatic；
- AI：真实 key/provider/潜在费用需要独立显式授权。

## 10. 关键失败模式

| 失败 | 防线 | 用户可见结果 |
|---|---|---|
| 统一窗口又包三层旧窗口 | views 与 window ownership 解耦；composition wiring test | 始终只有一个设置窗口 |
| 页面切换复制 model/磁盘扫描 | app-lifetime owners 注入；单一 library actor | 共享 snapshot/revision |
| App 被当成 Surface | typed `HostSurfaceID` route；按产品只做分组 | 能力与配置不串来源 |
| 通知页改写事件/音量 | expiring quiet snapshot | 原设置不变，静默结束自动恢复 |
| 陈旧静默永久无声 | expiry + revision + stale ignore | 页面提示监控失效，automatic 恢复 |
| 登录项按钮假成功 | 读取 SM status，不信本地 toggle | 显示等待批准或失败 |
| 用量数字冒充完整统计 | 只投影现有 retention，并明确范围 | 不显示「本周总量」 |
| BYOK 页面仍写「0 B 上传」 | 隐私边界分层文案 | 区分宿主内容与 provider 流量 |
| 快捷键变按键记录器 | Carbon registration；本地一次录制 | 不申请 AX/Input Monitoring |
| AI 迁页后候选泄漏 | destination/session lifecycle 清理 | 未采用候选失效，旧声音保留 |
| 旧窗口仍可写 | S14 删除 production wiring | 唯一编辑面与写入 owner |

## 11. 明确不做

- 不在本计划新增宿主事件、伪造 WorkBuddy/Codex 支持或修改真实宿主配置。
- 不重新引入全局静音、不把主音量写零模拟静音、不批量覆写逐事件选择。
- 不使用 Accessibility、Screen Recording 或全局 key monitor 实现全屏、空闲或快捷键功能。
- 不新增云端 telemetry、账号、完整 analytics ledger、供应商账单或网络字节计量。
- 不把 Calendar 标题、参与人、位置、URL 或 Focus 名称写入 snapshot、日志、回执或 UI 历史。
- 不把 API key、prompt、response、provider 原始响应、个人声音包或绝对路径放入诊断摘要。
- 不在统一设置完成前删除既有模型/测试；只在 route 和行为等价后退役 window wiring。
- 不把本地构建、HTML 原型或 fixture 升格为真机、签名、公证、真实 provider 或发布证据。

## 12. 绿灯

统一设置体验只有在以下条件全部成立时才算完成：

- 九个目的页在同一 retained window 中完整可用，生产导航无占位；
- 原型视觉层级在默认窗口明显对齐，并在小窗口、四文字档、双语和明暗模式下原生适配；
- Integrations、Events、Sounds 复用原 owner，独立旧窗口不再进入 production composition；
- General、Notifications、Display、Usage、Shortcuts、About 的真实模型、权限、失败和持久化均落地；
- AI 提示音维持描述 → 三候选与命名 → 显式采用，内部声音方案隐藏，BYOK 边界不退化；
- 所有自动命令全绿，`git diff --check` 通过且无新增 format diagnostics；
- 真机视觉、键盘、VoiceOver、登录项、Focus、Calendar、快捷键和音频分别有证据；
- 真实 Provider/key/付费请求、双架构、签名、公证、发布和正式验收继续单独报告与授权。

文档类型：统一设置体验的工程执行 spec、任务依赖图、测试 reference 与验收 explanation。本文件不授权
自动实施、commit、push、创建/关闭 issue、真实权限请求、真实 provider 调用或发布。
