# PLAN — 普通用户 AI 终端兼容（非 TTS）执行计划

> 状态：**方案已拍板，尚未实施**
>
> 日期：2026-08-22
>
> 范围：WorkBuddy 正式集成、ChatGPT / Claude Desktop 普通对话面的 AX Beta、宿主能力矩阵、
> 真实事件回执、事件播放和集成窗口。
>
> 描述式 TTS 接口、本地模拟器和声音候选导入，见
> plan/PLAN-CONSUMER-TTS-EXECUTION.md。
>
> 本计划不授权 commit、push、发布、真实宿主配置修改、外部服务部署或付费探测。

## 0. 目标与完成定义

本计划解决普通用户不只在 Claude Code / Codex 里获得提示音的问题，同时保持对宿主能力的诚实标注：

1. WorkBuddy Desktop 通过官方 command hooks 支持可验证的 task_start 与 stop，其他事件按
   当前 Desktop/runtime 版本和真实回执逐项启用。
2. ChatGPT / Claude 的普通 Chat surface 可以由用户显式启用 AX Beta；版本或 UI 结构不匹配时
   fail closed，不误报为已支持。
3. 集成窗口从固定两个宿主的矩阵改为产品 → surface → 五事件的动态模型。
4. 配置、系统授权和真实 activation 是三个独立事实；静态 runtime/schema、既有用户配置或测试
   不能代替当前 installation 的真实事件回执。

完成后的用户结果：

- WorkBuddy 的正式支持与实际激活状态分别展示；
- ChatGPT Desktop 的 Codex view 不会被错误投影到普通 Chat/Work；
- AX 只在菜单栏应用存活、版本签名通过且用户显式启用后监听；
- 不读取或日志化 prompt/response 正文，不创建全局键盘监听；
- 第三方 hook、未知 JSON 字段、用户信任数据和项目配置保持不变；
- unsupported、partial、awaiting receipt、permission required 和 signature mismatch 的语义不混淆。

### 0.1 已拍板决议

| 议题 | 决议 |
|---|---|
| 普通 Chat/Work 的兼容方式 | **官方结构化接口 + 用户显式启用的 macOS Accessibility Beta** |
| AX Beta 首版事件 | 只做**提交开始 + 生成结束**；错误、授权请求、subagent 全部不猜 |
| WorkBuddy | 使用官方 command hooks，首版映射 UserPromptSubmit 与 Stop；按 Desktop/runtime 版本探测其余事件 |
| 现有公共事件 | 保持五个 Event 语义，不为缺失映射伪造 session、tool 或 UI 事件 |
| 回执门槛 | 只有当前 installation 的真实事件 receipt 才能点亮 activation |
| 配置所有权 | WorkBuddy 只改用户级 ~/.workbuddy/settings.json 中明确属于当前 claudi0 installation 的条目 |
| AX 控制面 | AX 监听只由长驻 GUI 启停；CLI 只能报告状态和应用内操作路径 |

## 1. 事实基线与能力边界

### 1.1 现有 claudi0 语义保持不变

现有五个声音语义继续是唯一公共事件集：

| Event | 稳定 token | 含义 |
|---|---|---|
| .taskStart | task_start | 用户提交了一个新的任务或 prompt |
| .stop | stop | 宿主停止本轮响应；**不等价于业务成功** |
| .stopFailure | stop_failure | 宿主明确报告执行失败 |
| .notification | notification | 宿主明确发出通知；部分宿主只覆盖授权请求 |
| .subagentStop | subagent_stop | 子代理结束 |

不得为了让矩阵更好看而把 session、tool、按钮消失或普通 UI 文案伪装成其余事件。

### 1.2 官方接口确认的覆盖

按当前最新版官方接口处理，同一 app 不再按文档代际拆行。这里记录的是接口覆盖结果；
当前 WorkBuddy Desktop 是否已经激活，仍由当前安装的真实 hook receipt 单独决定。

| 集成 app/surface | 当前采用的官方接口 | taskStart | stop | stopFailure | notification | subagentStop |
|---|---|---:|---:|---:|---:|---:|
| WorkBuddy Desktop 5.3.14 · bundled CodeBuddy 2.115.0 | 最新版 CodeBuddy Code Hooks API v1.16+ | ✅ | ✅ | ✅ | ◐ 仅官方通知子集 | ✅ |
| ChatGPT Desktop · Codex | 当前 OpenAI Codex Hooks（11 个事件） | ✅ | ✅ | — | ◐ 仅授权请求 | ✅ |
| ChatGPT · Chat/Work AX Beta | 官方 AX surface；非原生 hooks | ◐ | ◐ | — | — | — |
| Claude Desktop · Claude Code | 官方 Claude Code hooks | ✅ | ✅ | ✅ | ✅ | ✅ |
| Claude Desktop · Chat AX Beta | 官方 AX surface；非原生 hooks | ◐ | ◐ | — | — | — |

符号：✅ = 当前官方接口明确声明了结构化事件及其触发语义；◐ = 官方接口只覆盖该语义的子集；
— = 当前 surface 没有可用映射。接口覆盖不等于本机激活：WorkBuddy 当前安装仍需逐事件取得
receipt，ChatGPT Desktop 的 Codex view 也仍需当前安装的真实 receipt；不能仅凭 bundled
runtime/schema 或既有用户级配置点亮 claudi0 的 activation。

因此，当前 WorkBuddy 的官方接口结果为
UserPromptSubmit、Stop、StopFailure、SubagentStop，并对 Notification 提供有限的
通知场景；按完整五语义计为 **4 个明确事件 + 1 个部分事件**。首版实现目标仍只先接入
UserPromptSubmit → task_start 和 Stop → stop，其余事件必须在本机取得 receipt 后再启用。

当前 ChatGPT Desktop 的 Codex 官方接口结果为 UserPromptSubmit、Stop、SubagentStop 三个
明确事件，PermissionRequest 只能作为授权通知子集；官方 Hooks 清单没有 StopFailure 或
Notification。这套接口只属于 ChatGPT Desktop 的 Codex view；普通 Chat/Work 仍没有可继承的
原生 Codex hook 映射，且本机尚未取得 ChatGPT Desktop 专用 receipt。

来源与结论：

- [当前 CodeBuddy Code Hooks 参考](https://www.codebuddy.cn/docs/cli/hooks) 面向 v1.16.0+
  的 runtime 明确声明 27+ 个事件；[插件参考](https://www.codebuddy.cn/docs/cli/plugins-reference)
  进一步列出 StopFailure（轮次因 API 错误结束）、Notification、SubagentStop、TaskCompleted
  等事件及其触发时机。官方指南同时把 Notification 限定为权限请求或 60 秒无输入提醒等
  通知场景。WorkBuddy 行按这套当前接口维护唯一结果；Desktop 是否激活仍按当前安装的 receipt
  验收，不把接口声明当作运行时回执。
- [OpenAI Hooks](https://learn.chatgpt.com/docs/hooks) 是 Codex 的扩展机制；
  [Plugin capabilities can be surface-specific](https://developers.openai.com/plugins/concepts/plugins)，
  当前文档明确列出 PreToolUse、PermissionRequest、PostToolUse、PreCompact、PostCompact、
  UserPromptSubmit、SubagentStop、Stop、SessionStart、SubagentStart、SessionEnd；
  所以 Chat/Work 的普通对话不能继承 Codex 的 3+1/5 覆盖声明。
- [Claude Code Hooks](https://code.claude.com/docs/en/hooks) 提供当前 claudi0 所需的五种事件。
- [Cowork Monitoring](https://claude.com/docs/cowork/monitoring) 是企业管理/遥测路线，不是普通用户
  Chat 生命周期回调，本期明确排除。

### 1.3 本机验收基线

- 当前本机存在并已启动 /Applications/ChatGPT.app，版本 26.818.31338，bundle ID
  com.openai.codex；其 Codex Framework 为 151.0.7922.170，bundled CLI 为
  codex-cli 0.149.0-alpha.4。当前进程使用 ~/Library/Application Support/Codex；版本和
  数据目录是本机快照，不能外推到未来版本。
- OpenAI 官方 Hooks 的用户级配置入口是 ~/.codex/hooks.json / ~/.codex/config.toml，项目级入口
  是 <repo>/.codex/hooks.json / <repo>/.codex/config.toml。当前本机 ~/.codex/hooks.json
  静态配置了 PermissionRequest、PostCompact、PostToolUse、PreCompact、SessionEnd、
  SessionStart、Stop、SubagentStart、SubagentStop、UserPromptSubmit；没有
  StopFailure 或 Notification。现有 config.toml 的 notify 是独立的 Codex notifier，
  不能冒充额外 hook，也不得覆盖。
- 上述 ~/.codex 配置只证明用户级配置存在；本次没有写入配置或执行唯一 sentinel hook，不能把
  静态配置、bundled strings 或既有 Codex 日志升级为当前 ChatGPT Desktop 的真实 receipt。
- 当前本机已安装并启动 /Applications/WorkBuddy.app：bundle ID com.workbuddy.workbuddy，
  Desktop 版本 5.3.14，Apple Silicon arm64；bundled CodeBuddy CLI 为 2.115.0，启动时
  使用 CODEBUDDY_HOST=workbuddy-desktop。
- WorkBuddy Desktop 的实际用户配置根目录为 /Users/d0m999/.workbuddy，而不是
  ~/.codebuddy；当前 sidecar 使用 --setting-sources user。/Users/d0m999/.workbuddy/settings.json
  当前没有全局 hooks 键，但已启用的内置插件包包含 SessionStart、UserPromptSubmit、
  SubagentStop、PreToolUse 等 command-hook schema。静态出现 StopFailure、Notification 等
  标识不等于这些事件已经取得真实回执。
- 当前本机仍没有发现 Claude Desktop。没有某个明确版本的真实宿主回执前，不得宣称该 surface
  已通过原生验收。
- 当前分支基线中的既有修改不属于本计划，实施时必须排除：
  - helper/Sources/ClaudioCore/BootstrapReport.swift
  - helper/Sources/ClaudioCore/FileLock.swift
  - helper/Tests/ClaudioCoreTests/BootstrapReportSuite.swift

## 2. 总体架构

现有深模块边界继续成立：adapter 拥有外部宿主协议，共享 core 拥有事件语义、状态事实、事务、
回执和播放；UI、CLI、doctor 不直接解析宿主配置。

~~~text
                         ┌─────────────────────────────┐
                         │ HostCapabilityCatalog       │
                         │ Event / support / qualifier │
                         └──────────────┬──────────────┘
                                        │
                ┌───────────────────────┴───────────────────────┐
                │                                               │
      ┌─────────▼─────────┐                           ┌─────────▼─────────┐
      │ Native hook       │                           │ Accessibility Beta │
      │ adapters          │                           │ adapters (GUI only)│
      │ Claude/Codex/WB   │                           │ ChatGPT/Claude Chat│
      └─────────┬─────────┘                           └─────────┬─────────┘
                └───────────────────────┬───────────────────────┘
                                        ▼
                         HostIntegrationManager / receipts
                                        │
                                        ▼
                              shared Event playback
~~~

### 2.1 宿主身份与展示分组

保留现有 HostID raw value，不迁移旧回执或 CLI token：

~~~swift
case claudeCode = "claude-code"
case codex = "codex"
~~~

新增三种**事件来源**，而不是把整个品牌当成一个能力相同的宿主：

~~~swift
case workBuddy = "workbuddy"
case chatGPTDesktopAX = "chatgpt-desktop-ax"
case claudeDesktopAX = "claude-desktop-ax"
~~~

新增共享描述类型：

~~~swift
enum HostProductID: String, Codable, Sendable {
    case chatGPT
    case claude
    case workBuddy
}

enum HostIntegrationMechanism: String, Codable, Sendable {
    case nativeHooks
    case accessibilityBeta
}

enum HostIntegrationMaturity: String, Codable, Sendable {
    case stable
    case beta
}

enum HostIntegrationControlSurface: String, Codable, Sendable {
    case shared
    case guiOnly
}

struct HostIntegrationDescriptor: Codable, Sendable, Equatable {
    let host: HostID
    let product: HostProductID
    let surfaceName: String
    let mechanism: HostIntegrationMechanism
    let maturity: HostIntegrationMaturity
    let controlSurface: HostIntegrationControlSurface
}
~~~

HostIntegrationControlSurface 至少区分 .shared 与 .guiOnly：WorkBuddy/Claude Code/Codex 可由
现有 GUI/CLI 管理；AX 监听只能在长驻 GUI 中启停。CLI 对 AX 只报告状态和“请在应用内启用”，不能假装
已经申请或获得 Accessibility 权限。

HostIntegrationSnapshot 新增独立授权轴：

~~~swift
enum HostAuthorizationState: Codable, Sendable, Equatable {
    case notRequired
    case permissionRequired
    case denied
    case granted
}
~~~

不要把 Accessibility 授权塞进 HostConfigurationState。原生配置是否完整、系统权限是否允许、
真实事件是否已经产生回执，是三个不同事实。

### 2.2 管理器与矩阵

- HostIntegrationAdapter 继续保持 inspect/connect/disconnect 这一窄接口，并增加 descriptor。
- WorkBuddy adapter 位于 ClaudioCore，拥有 settings schema 和事务。
- AX adapter 的状态/协议放共享 Foundation 层，AXUIElement/AXObserver 实现放 GUI 专用 target；
  helper 不能因此依赖 AppKit。
- HostIntegrationManager 从 registry 注入 adapter，不再假设固定两个宿主；缺少 GUI-only adapter 时
  返回明确的 .unavailable(reason:)，不是崩溃或漏行。
- HostCapabilityCatalog 是 native event → Event 的唯一映射源。
- 当前固定 5×2 的矩阵、preview fixture、文案 switch、图标 registry 和测试全部改为 descriptor 驱动。
- UI 先按 HostProductID 分组，再显示各 surface；不能把 Codex 的 3+1/5 涂到 ChatGPT Chat 上，
  也不能把 Claude Code 的 5/5 涂到 Claude Chat 上。

## 3. WorkBuddy 正式集成

### 3.1 配置所有权

- WorkBuddy Desktop 只管理用户级 ~/.workbuddy/settings.json；路径必须由 WorkBuddy Desktop
  descriptor 提供，不能把 standalone CodeBuddy CLI 的 ~/.codebuddy/settings.json 路径硬编码
  到 Desktop adapter。
- 不修改 <workspace>/.workbuddy/settings.json 或 <workspace>/.codebuddy/settings.json，避免
  打开项目时产生隐式仓库改动；当前 Desktop sidecar 明确只加载 user settings。
- adapter 只增删能够被 matchedCurrentHostHookCommand 证明属于当前 claudi0 installation 的 command。
- 未知顶层键、第三方 hook、matcher、排序和用户信任数据必须保留。
- 读、改、写、rollback、CAS 和锁纪律复用 ConfigFileTransaction；不复制一套 WorkBuddy 专用写盘。

### 3.2 能力绑定

~~~text
UserPromptSubmit  -> Event.taskStart     supported; real receipt required
Stop              -> Event.stop          supported; manual interrupt may not emit it
StopFailure       -> Event.stopFailure   candidate; API-error receipt required
Notification      -> Event.notification  partial; matcher-specific receipt required
SubagentStop      -> Event.subagentStop   supported by command schema; real receipt required
~~~

Notification 只按明确的 matcher 映射，例如 permission_prompt、idle_prompt 或
auth_success；不能把所有桌面通知泛化为 notification。PostToolUseFailure 是工具失败，
不能伪装成主轮次的 stop_failure；TaskCompleted 是显式任务状态，也不能替代主响应结束。
SessionStart 与 SessionEnd 仍保持 session 语义，不加入现有五个公共 Event。

Stop 的 UI 文案使用“响应结束”，不能写“任务成功完成”。

### 3.3 激活证据

- connect 成功只表示 .configured + .awaitingReceipt(installationID:)。
- 只有当前 installation ID 的真实 UserPromptSubmit 回执能点亮 activation。
- 当前 WorkBuddy Desktop 的全局 settings.json 没有 claudi0 hook；已启用内置插件中的 hook
  只能证明 schema/command 执行路径存在，不能替代 claudi0 自有 installation receipt。
- 回执继续只保存 installation ID、host、native/semantic event、timestamp、播放结果；不保存 prompt、
  response、workspace、路径或 session 内容。
- disconnect 只删除 claudi0 自有条目；第三方和项目级配置不动。

## 4. ChatGPT / Claude Desktop AX Beta

### 4.1 产品边界

AX Beta 是普通 Chat surface 的补充，不是官方 hook 的替代：

- Codex surface 继续走 .codex 原生 adapter。
- Claude Code surface 继续走 .claudeCode 原生 adapter。
- WorkBuddy 已有官方 hooks，不再加一条 AX 路径制造重复声音。
- ChatGPT Chat/Work 与 Claude Chat 才进入 AX Beta。

### 4.2 权限与隐私

- 首次启动不弹 Accessibility 权限；用户点击“启用 Beta”时才调用系统授权流程。
- 不创建 global event tap，不记录键盘，不扫描其他进程。
- observer 只附着到 allowlist 中已验证签名、bundle ID 和版本范围的目标进程。
- detector 只读取已知控制的 role、identifier、enabled/busy 状态和 allowlisted 静态 label；
  不遍历消息列表，不读取或日志化 prompt/response value。
- 所有诊断字段必须可枚举且脱敏：app 版本、detector schema 版本、状态转移、失败代码、时间和播放结果。

### 4.3 版本签名与 fail-closed

每个 app/surface 有独立 AXSurfaceSignature：

~~~swift
struct AXSurfaceSignature: Sendable, Equatable {
    let bundleID: String
    let teamID: String
    let supportedVersionRange: ClosedRange<SemanticVersion>
    let schemaRevision: Int
    let requiredControlSignatures: [AXControlSignature]
}
~~~

连接前必须同时满足：

1. bundle ID 与 code-signing Team ID 命中 allowlist；
2. app 版本落在已人工验收范围；
3. composer、send/stop control、assistant region 的结构签名完整；
4. Accessibility 权限已授予。

任一条件失败时状态是 .unsupportedVersion、.signatureMismatch 或 .permissionRequired；observer
不得启动，矩阵不得显示已连接。app 升级后默认重新验证，不沿用旧版本的绿色状态。

### 4.4 状态机

每个 pid + windowIdentifier 独立维护：

~~~text
disabled / unsupported / permissionRequired
                    │ enable + verified
                    ▼
                  idle
                    │ composer submit confirmed
                    │ AND generating/stop control appears
                    ▼
               generating  ──────────────┐
                    │                     │ app exits / window lost /
                    │ stop control gone   │ ambiguous structure
                    │ AND assistant area  │
                    │ stable for 500 ms   ▼
                    ▼                  reset silently
                  idle
~~~

事件规则：

- 只有“提交动作已确认 + 同窗生成控件出现”才产生 taskStart。
- 只有先观察到该窗口的 taskStart，随后生成控件消失且 assistant region 稳定 500ms，才产生 stop。
- 快速响应仍须形成完整 start → stop 顺序；同一状态转移去重。
- app 退出、窗口销毁、进程重启、超时、结构模糊或 detector 热切换，只清状态，不补发 stop。
- 首版不解析错误 banner。因此 AX stop 是“生成停止”，无法保证成功，能力必须为 partial。
- AX native token 使用稳定内部名称，例如 AXGenerationStarted / AXGenerationEnded，只通过
  HostCapabilityCatalog 映射，不能由 SwiftUI view 直接调用 play。

### 4.5 生命周期与播放

- AX adapter 只有在 claudi0 菜单栏应用存活时工作；UI 必须明确说明这一点。
- detector 输出进入共享播放 facade，继续服从 master volume、事件静音、声音包缺失和播放错误语义。
- 成功或静音结果写入现有最小回执；observer 自己不维护第二套“已连接”事实。
- 切换语言、打开/关闭管理窗口不得重建 observer；GUI app lifetime 持有一个 source manager。

## 5. 集成窗口改造

集成窗口从“两个宿主的固定矩阵”改成“产品 → surface → 五事件”的动态模型。

每个 surface 必须显示：

- 正式 hooks 或 Accessibility Beta；
- stable / beta badge；
- app/CLI availability；
- configuration、authorization、activation 三条独立状态；
- 五事件覆盖及 qualification；
- 最近一条最小回执；
- 与 control surface 相符的操作。

操作规则：

- WorkBuddy/Claude Code/Codex：连接、修复、升级、重检、断开。
- AX：启用 Beta、打开系统设置、重新检测当前版本、停用。
- CLI 遇到 .guiOnly 只给出应用内路径，不尝试调系统授权。
- unsupported 是正常能力边界，不渲染成 degraded；signature mismatch 才是需要处理的 Beta 状态。

可访问性：

- 视觉分组顺序与键盘/VoiceOver 顺序一致。
- Beta、部分支持、权限缺失和未知版本必须进入 accessible name/value，不能只靠颜色或图标。
- 状态变化使用现有 revision 去重播报机制；刷新轮询不能反复朗读同一句。
- 任何 surface 都不得自动播放测试声；试听必须由用户操作触发。

## 6. 实施顺序

| Task | 内容 | 主要依赖 | 完成门槛 |
|---|---|---|---|
| NT-0 | 扩展 host descriptor、mechanism、maturity、authorization 和动态 registry | — | 旧 raw token/receipt 可读；现有 Claude/Codex 测试全绿 |
| NT-1 | WorkBuddy catalog、transform、adapter、CLI/doctor 投影 | NT-0 | Desktop/runtime 版本矩阵和第三方配置保真；真实回执前不点亮 |
| NT-2 | 集成窗口按产品/surface 动态分组，删除固定 5×2 假设 | NT-0 | preview、文案、图标、操作和 a11y 全由 descriptor 驱动 |
| NT-3 | AX 共享状态机、签名 registry、权限/隐私模型和 fixture detector | NT-0 | 合成 tree 覆盖全部状态转移；未知结构 fail closed |
| NT-4 | ChatGPT Chat/Work detector 与本机版本真机走查 | NT-3 | 当前已安装版本 start/stop、权限、窗口和退出场景通过 |
| NT-5 | Claude Chat detector | NT-3 | 取得真实 app fixture 后实现；未验收前保持 unavailable |
| NT-6 | 文档、隐私声明和分层验收 | NT-1–NT-5 | 自动、build、真实宿主、AX 和未完成项分开报告 |

依赖关系：

~~~text
Lane A: NT-0 → NT-1 → NT-2                 WorkBuddy 与动态矩阵
              └→ NT-3 → NT-4 → NT-5         AX Beta；NT-5 等真实 fixture
Final:  NT-6 等所有计划内已实施 task；未具备真机的 surface 保持 unavailable
~~~

NT-0 可与 TTS 计划的 TTS-0 并行，但都可能触及 GUI tests 与 localization，合并时必须顺序处理这些
共享文件。NT-3/NT-4/NT-5 不能并行改同一 AX registry。NT-2 应在 descriptor 和状态事实稳定后完成。

## 7. 自动测试与回归命令

### 7.1 Host 与 WorkBuddy

- HostID 新旧 Codable token round-trip；旧 receipt fixture 不迁移。
- registry 缺 adapter、GUI-only adapter、未知 host 的确定性投影。
- WorkBuddy ~/.workbuddy 空配置、完整配置、缺事件、legacy/重复 claudi0 条目、第三方 hooks、
  未知键、只读文件、symlink、CAS 漂移、rollback 和 disconnect 保真；确认不会写入 ~/.codebuddy。
- WorkBuddy UserPromptSubmit 激活；只有 Stop 回执不能点亮 task-start activation。
- WorkBuddy StopFailure、Notification matcher、SubagentStop 的 native receipt 与语义投影；
  PostToolUseFailure/TaskCompleted 不得误映射到五个公共事件。
- host-aware debounce 保证 WorkBuddy 不抑制 Claude/Codex。

### 7.2 AX

- 权限未请求、拒绝、授予、撤销。
- bundle/team/version/signature 任一不匹配即不启动 observer。
- submit without generating control 不发 start；orphan completion 不发 stop。
- 快速响应、重复通知、500ms 稳定窗、多个窗口、多个 app、进程重启和 app 退出。
- 生成中切换 conversation/window 不串状态。
- 所有 log/receipt fixture 扫描不得含 prompt、response 或 AXValue。
- detector mutation test：删除 start 前置、删除同窗约束、把 mismatch 改为继续运行时，测试必须变红。

### 7.3 回归命令

~~~bash
swift run --package-path helper claudio-tests
swift run --package-path gui claudio-gui-tests
swift build --package-path helper -c release --arch arm64 --product claudio
swift build --package-path gui -c release --arch arm64 --product ClaudioGUI
git diff --check
~~~

不得用裸 swift build -c release 代替显式 product build。

## 8. 真机验收

自动测试和合成 AX tree 不能证明真实桌面应用接受了配置或维持相同 accessibility structure。

### 8.1 WorkBuddy

1. 在隔离测试账户安装并记录当前 WorkBuddy Desktop 版本、bundle、bundled CodeBuddy runtime
   和实际 user config root；当前本机基线为 Desktop 5.3.14 / CLI 2.115.0 / ~/.workbuddy。
2. 备份并记录用户级 settings bytes；连接 claudi0。
3. 确认静态配置只新增 claudi0 自有条目，仍显示 awaiting receipt；项目级 .workbuddy/.codebuddy
   和 standalone CLI 配置均未被修改。
4. 提交真实 prompt，确认 task_start 声音与当前 installation receipt。
5. 等待真实响应结束，确认 stop 声音；不要把它报告为成功完成；另行验证手动中断是否不触发。
6. 在可控 fixture 中验证 StopFailure、Notification 的目标 matcher 和 SubagentStop；没有回执
   就保持 partial/unavailable。
7. 断开，逐字验证第三方内容与未知键保留。

### 8.2 ChatGPT Desktop · Codex 原生 hooks

1. 记录当前 ChatGPT Desktop 版本、bundle、Codex Framework/bundled CLI 和
   ~/Library/Application Support/Codex；当前本机基线为 26.818.31338 / com.openai.codex /
   codex-cli 0.149.0-alpha.4。
2. 只读检查 ~/.codex/hooks.json、~/.codex/config.toml 和项目级 .codex 层；保留现有
   notify notifier，不把它当成额外 hook，不写入项目级配置。
3. 在 Codex view 提交真实 prompt，确认 UserPromptSubmit → task_start 的当前安装 receipt；
   等待响应结束，确认 Stop → stop receipt；在可控 subagent 场景确认 SubagentStop。
4. 明确记录 StopFailure、Notification 不在官方当前 Codex Hooks 清单中；
   PermissionRequest 只能作为授权通知子集，不得扩展成普通桌面 notification。
5. 在普通 Chat 与 Work view 各执行一次对照检查；没有原生 Codex hook receipt 时保持 AX Beta
   或 unavailable，不把 Codex view 结果投影到 Chat/Work。
6. 没有唯一 installation ID 的真实 receipt 时，状态保持 .configured + .awaitingReceipt，
   不点亮 activation。

### 8.3 ChatGPT / Claude AX

逐 app/version 执行：

- 未授权、拒绝授权、授权后启用；
- 新会话、现有会话、快速响应、长响应、手动停止、错误响应、多窗口；
- 生成中关闭窗口、退出 app、重启 app、升级版本；
- 菜单栏 app 退出时不再监听；重启后按保存的 enabled preference 和当前授权重新 inspect；
- VoiceOver 同时运行时不抢焦点、不朗读消息正文、不造成事件重复；
- 检查本地 log 与 receipt，确认只有脱敏元数据。

只有某个明确版本完成全部走查，才能把它加入 supported version range。没有对应真机或真实回执时，
相应状态保持 unavailable/partial，不能用 ChatGPT 的结果代替。

## 9. 失败模式

| 路径 | 失败 | 防线 | 用户可见结果 |
|---|---|---|---|
| WorkBuddy transform | 覆盖第三方 hook/未知键 | ConfigFileTransaction + 精确 ownership matcher + byte fixtures | fail closed；原配置保留 |
| WorkBuddy activation | 静态配置被误报为已连接 | 当前 installation 的 task-start receipt | 显示“等待首次真实事件” |
| AX app 升级 | 控件树变化导致误报 | version/signature 双门 + 默认重新验收 | 显示“当前版本尚未验证” |
| AX completion | 错误页被当成功 | 能力标记 partial；文案只写“响应结束” | 不承诺成功；模糊时静默 reset |
| AX 隐私 | detector 遍历并记录消息 | 目标控件 allowlist + source/log 扫描 | 无正文进入日志或回执 |
| duplicate path | 官方 hooks 与 AX 同时发声 | 按 surface 选择唯一 adapter；WorkBuddy 不启用 AX | 每个事件最多一次播放 |
| stale receipt | app/installation 已变化 | installation ID、版本签名和默认重检 | 回到 awaiting/unavailable，不保留绿色状态 |

## 10. 明确不做

- 不新增或改名现有五个 Event。
- 不把 SessionStart、SessionEnd、tool event、按钮消失或 OTel api_error 伪装成缺失语义。
- 不在 AX 首版识别失败、授权请求、普通通知或 subagent。
- 不使用全局键盘监听、屏幕录制、OCR 或读取消息正文。
- 不为 WorkBuddy 修改项目级 .workbuddy/settings.json 或 .codebuddy/settings.json。
- 不实现 Cowork 企业 OTel collector。
- 不把 WorkBuddy standalone CodeBuddy CLI 配置路径写死到 Desktop adapter。
- 不把静态配置、bundled strings、fixture、日志或 hash 升格为真实宿主/正式发布验收。
- 描述式 TTS、真实 provider、Hosted server、BYOK credential 和费用流程属于另一份计划，本计划不实现。
- 不改变当前 macOS 12 最低版本，不为新 UI 强行采用只在更高系统可用的 observation API。

## 11. 绿灯

只有以下条件同时成立，非 TTS 计划内相应能力才算完成：

- WorkBuddy 配置变换、manager、CLI/doctor、版本矩阵和回执测试全绿，并在明确的真实 Desktop
  版本完成 start/stop 走查；其余事件只有拿到对应回执才可从 partial 升格。
- ChatGPT/Claude AX 各自有真实 bundle/team/version/signature fixture；未知版本 fail closed；权限和隐私走查通过。
- 集成窗口不存在固定两宿主假设，且正式/部分/不支持/损坏四类状态语义不混淆。
- 宿主事件均进入共享 playback facade，回执最小化且不含正文。
- helper/GUI test harness、两个显式 release product build 和 git diff --check 全绿。
- 自动证据、真实宿主证据、AppKit/VoiceOver 证据、外部发布状态分别报告。
- 实施 diff 不包含本计划开始前的三个已有修改文件；commit/push 仍需用户另行明确授权。

## 12. 计划来源与复用边界

本计划复用现有：

- HostIntegrationAdapter / HostIntegrationManager / HostCapabilityCatalog；
- ConfigFileTransaction 与精确 command ownership matcher；
- installation-scoped 最小回执；
- 共享 Event playback facade、master volume、静音和播放错误语义；
- SoundPacksWindow 的宿主集成状态展示、retained window 与 accessibility presentation。

本计划新增的是 WorkBuddy/AX adapter、host descriptor、授权轴、状态和动态矩阵接缝，不在 UI、CLI、
doctor 或 adapter 中复制宿主配置事务、回执或事件映射基础设施。

文档类型：工程执行计划，兼具内部接口 reference 与架构 explanation。实现后再为最终用户补
tutorial/how-to；在真实宿主验收完成前，不提前写会让用户误以为功能已上线的使用教程。
