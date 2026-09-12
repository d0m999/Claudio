# C 顶部事件来源提示条：开发规格与工程审查

日期：2026-09-12（Asia/Singapore）。审查基线：`main@d113ff335b7d5b35409b12adc78172d586c7566b`。
状态：工程计划已完成；生产实现、原生验收尚未开始。
授权：用户选择 C 顶部提示条，授权本次 `plan-eng-review` auto-select，要求完整 spec 与健壮实现。下列决策由该授权自动选择，不代表用户逐项回答过问题。
输入：本会话《Claudio 事件来源提示：三种交互原型》及已制作的 C 原型；原型位于本机 `.gstack/projects/Claudio/designs/event-source-prompts-20260912/index.html`。A/B 只保留为比较材料。

## 1. 目标与 spec 对照

让用户在事件到达时快速知道“哪个事件来源、哪个项目、哪个会话、发生了什么”，保持 C 的紧凑胶囊。原型证明交互方向，不能证明真实字段、原生不抢焦点或宿主跳转。

| ID | 必须兑现的需求 | 生产合同 / 验证入口 |
|---|---|---|
| S1 | C 顶部居中、约 440pt、低干扰 | 非激活顶部胶囊；固定单个容器；单个紧凑信息区域，不扩展成 A/B 大卡；G5/G8 |
| S2 | 沿用 DESIGN 字体、品牌和事件色 | SF Pro Rounded、Claudio 自有 clay、五事件现行语义；复用 token；G5 |
| S3 | 淡入、约 4 秒淡出 | 180ms 淡入后完整可读时间 4s，180ms 淡出；Reduce Motion 瞬时切换；G4/G5 |
| S4 | 悬停暂停、离开继续 | hover、键盘焦点、展开任一成立即暂停，全部结束才恢复剩余时间；G4 |
| S5 | 连续事件单容器、数量入口、阅读不被替换 | 当前条固定；后续事件入同一有界集合；显示“另 N 条”；展开共享近期列表；G3/G4 |
| S6 | 不同工具 / 同工具不同项目 / 同项目不同会话 | 用稳定 Surface 身份与独立项目、会话身份；不按显示名合并；G1/G3 |
| S7 | 长名称、无法识别会话、已知信息明确 | 源字段可选，逐字段降级；详情可读完整安全标签；不借上一条补字段；G1/G5 |
| S8 | 查看会话只模拟跳转结果 | 开发 gallery 保留模拟成功/失败；生产只对验证过的精确 route 显示“查看会话”，其余显示“查看来源”与可选“复制会话 ID”；G6 |
| S9 | 收起后菜单栏查看近期，不表示已处理 | 原菜单栏面板新增“近期提示”入口；共用同一模型；标签只表示展示状态；G3/G5 |
| S10 | 触发一条、连续三条、重播、明暗切换 | 保留浏览器比较页；原生 DEBUG gallery 通过同一模型注入 fixture；Release 无自动造假事件；G7/G8 |
| S11 | 动画、悬停、展开、键盘、长文本、明暗逐项验证 | 确定性 harness + 真实本地进程测试 + 原生截图/输入法/VoiceOver；G1–G8 |

S8 不授权凭空承诺各宿主精确会话跳转。未来若将“全部宿主一键精确跳转”升级为验收条件，必须先为每个宿主取得可验证接口，不能以打开应用、模拟 toast 或猜测 URL 交差。

## 2. Step 0 / What already exists

| 既有能力与源码锚点 | 本计划如何复用 |
|---|---|
| `helper/Sources/claudio/Subcommands.swift:15–25` 的 `Hook.run()` | 保留参数格式，增加有界 stdin 读取；不改宿主 hook command |
| `helper/Sources/ClaudioCore/HostHookRunner.swift:80–162` 的 `handleHostHook` | 同一语义映射、发生时间、installation 接受边界；增加独立 presentation sink |
| `helper/Sources/ClaudioCore/HostIntegrationModels.swift` 的 Host / Surface / Binding catalog | 身份、显示名、支持矩阵唯一来源，不新增平行宿主枚举 |
| `HostHookReceipt.swift:16–63` 和 `HostHookReceiptSuite.swift:56–63` | 最小回执 schema 原样保留，不加入项目/会话信息 |
| `LocalActivitySummaryStore` 与 ADR 0010 | 原活动事实独立累计，视觉关闭、静默、IPC 丢失均不回滚活动 |
| `gui/Sources/ClaudioGUICore/DynamicQuietPolicy.swift:231–385` | 复用已授权 Focus/Calendar 事实，不再请求权限或读取日历 |
| `ClaudioPreferences`、`SettingsRootView.notificationsSettings` | 单一视觉总开关与状态说明，沿用 retained Settings / typed route |
| `MenuBarController.swift:72–110`、`PanelFocusCoordinator` | app-lifetime 注入、近期入口、明确触发的焦点交接 |
| `ClaudioGUIComponents`、`ClaudioLocalization`、现行 DESIGN | 字体、颜色、控件尺寸、本地化都复用 |
| 两包 executable harness 与隔离 fixture 路径 | 新增测试注册到各包 `main.swift`，不用 `swift test` |

仓库内搜索未发现可直接复用的事件 IPC receiver 或项目/会话解析器。现有回执刷新是诊断事实投影，不能把最新一条回执轮询包装成连续事件流。

复杂度门：预计涉及 20–30 个源码/测试/本地化/文档路径，超过 8 文件阈值。D1 自动选择完整跨层方案；减少的是移动部件，不是需求。保留三个有生命周期的 owner：一个 receiver、一个提示 model、一个 native window controller；其余使用 value type / 函数及已有 owners。不引入常驻 helper daemon、数据库、通用消息总线、插件系统、新 SwiftPM target 或第三方依赖。把所有逻辑塞进 `MenuBarController` 虽然文件少，但会破坏测试边界。

`TODOS.md:793–837,950–971` 已记录原生键盘/VoiceOver 与 popover 激活限制；本功能必须验证新窗口，不能借用旧 TODO 免验。原菜单栏改 NSPanel 的重写不在本次范围。其余声音包、写盘基础设施、AI Cue 债无阻塞依赖。

分发：使用现有 macOS 12+ app/helper 和既有 arm64 / x86_64 Release pipeline；无新安装包类型、后台服务或独立发布渠道。开发构建需检查 helper 更新实际落到 shared runtime，否则新 GUI + 老 helper 会只显示未收到实时提示的状态。

## 3. Architecture review：4 项发现与自动决策

以下是“原型转生产”的设计缺口，不是对当前已出货代码的 bug 指控。严重度 P1 表示实现发布前必须解决。

### 1 / D2 来源与隐私边界

`[P1] (confidence: 10/10) HostHookReceipt.swift:4–5`：原文“项目/会话信息和音频路径在类型层就无处可放”。`Subcommands.swift:21` 直接调用 `handleHostHook`，其输入没有 stdin/source。S6 不能靠给回执加字段实现。

选择 **1A [Layer 1]**：hook adapter 严格提取最少来源字段，创建独立内存 `HostEventNotice`；近期仅在当前 GUI 生命周期保留。完整度 10/10；human ~1d / CC ~1–2h；有额外解析/传输测试成本，避免改变隐私与 activation 合同。
未选 **1B**：扩充 receipt/history 再轮询；实现初期较短，但永久改变隐私、会丢连续事件且混淆证据，不满足完整 spec（4/10）。

### 2 / D3 事件传输与故障隔离

`[P1] (confidence: 9/10) HostHookRunner.swift:78`：“任何失败都折叠进返回值，不 throw、不打印；CLI 无条件退出 0。”S5 要接收连续三条，原型没有跨进程失败模型。

选择 **2A [Layer 1]**：GUI 持有 Unix domain datagram socket，以 DispatchSourceRead 在专用串行队列接收；helper 非阻塞单次发送、无 ACK 等待、无重试落盘。类型化传输结果与播放结果正交。完整度 10/10（在明确的实时 best-effort 合同内）；human ~1–2d / CC ~2–3h；成本是 endpoint 生命周期与 syscall 测试。
未选 **2B**：新磁盘通知队列；能重启回放但扩大持久内容与清理/迁移事务，不是本 spec 要求。两者种类不同，不另给虚构覆盖分。

### 3 / D4 原生窗口与焦点

`[P1] (confidence: 10/10) MenuBarController.swift:546–547`：`NSApp.activate(ignoringOtherApps: true)`、`popover.contentViewController?.view.window?.makeKey()`。自动调用该路径会激活 Claudio。

选择 **3A [Layer 1]**：独立 retained `.nonactivatingPanel`，自动显示只 order-front、不 activate、不 make-key；显式展开后才启用键盘交互模式。现有菜单栏 popover 不迁移。完整度 10/10；human ~1d / CC ~1–2h + 真机走查；需验证 inactive app 的 AX 可达性、输入法和多屏。
未选 **3B**：复用现有 popover 自动弹出（4/10）；会继承已知激活路径，违背低干扰目标。不用系统通知中心承担 C 的可控居中位置与 4s 悬停时序。

### 4 / D5 “查看会话”的真实能力

`[P1] (confidence: 9/10) 原型 index.html:1301` 的 `showRouteToast` 是模拟结果；S8 明确“只模拟跳转结果”。不能把原型按钮当成生产接口证据。

选择 **4A [Layer 3]**：独立 `SessionNavigationCapability` value 与动作结果；展示文案由能力决定。当前没有已核实精确路由的 host 默认 `.unavailable`，提供来源详情/复制真实 session ID。模拟成功与失败只在 DEBUG fixture。对当前 S8 完整度 10/10；human ~4h / CC ~40min；需要接受真实宿主能力不齐。
未选 **4B**：猜测 URL 或打开任意同品牌终端（3/10），存在误跳与错误成功回执；不采用。未验证能力不是“不可能”，后续证据可以升级明确的 adapter。

## 4. 落地架构与合同

```text
Host command hook (existing command / installation UUID)
  |
  +--> bounded stdin --> host-specific allowlist --> optional source values
  |
  +--> existing handleHostHook / capability + current installation gate
        +--> activity fact                 (unchanged owner)
        +--> sound / debounce / receipt    (unchanged outcome semantics)
        +--> immutable HostEventNotice --> nonblocking sendto
                                              |
                       private local endpoint v
                    receiver queue: size/schema/generation checks
                                              |
                    bounded mailbox, one scheduled MainActor drain
                                              v
              EventNoticeModel (one current + recent records + timing)
                 |                     |                      |
              top capsule         recent list          Settings health
                 |                     |
                 +--> explicit navigation capability / local source details
```

**来源合同。** `HostEventNotice` 包含 schema、event UUID、当前 receiver epoch、HostSurfaceID、binding ID、installation UUID、发生时间、可选 project label/key、可选 session ID/label、source completeness。只支持 catalog 中已出货 surface/event；未知将来 schema 丢弃并记固定原因码。数据类型不携带 prompt、response、transcript 内容、任意 URL 或 shell command。

Claude Code 与 Codex 使用已核实的 `cwd` / `session_id`；项目只取目录末级标签，不扫描项目或执行 git。项目内部 key 可用原始 cwd 的内存摘要，不显示、不落盘，不能用于推断两个不同路径等同。session label 默认“会话 · <短 ID>”；不能从 prompt 首行或 transcript 生成标题。可读标题只有 adapter 的显式可信字段获得证据后才启用。Codex 子任务的 `session_id` 是父会话，UI 标注“父会话”，不把 `agent_id` 误当可导航主会话。

WorkBuddy：当前已支持其事件映射，但本次尚未核实项目/会话字段合同。解析器必须单列 adapter，以其版本固定的文档/安装包代码及合成 fixture 校准；未能核实的字段保持 unknown，事件仍正常出现。不得把 Claude 字段“兼容猜测”为 WorkBuddy 事实。G1 必须包含该降级，G8 单列真实宿主证据；不得宣称 WorkBuddy 来源全部已识别。

**输入边界。** stdin 只读一次，注入 fd/clock/reader；最大 64KiB、读取墙钟预算 20ms；跳过 TTY，不等无限 EOF，不派出悬挂后台 reader。用 poll/read 处理分片、EINTR、EAGAIN、EOF；超时、超限、错误 JSON、重复白名单键、字段类型不符都返回 typed source unavailable。整包失败不改变原 hook 退出/声音/计数。禁止跟随 `transcript_path`、访问宿主数据库、读取终端窗口标题或屏幕。量化预算是待实测目标，不能宣称严格调度上界。

helper 先检查有效 receiver descriptor，再决定是否读取来源 stdin；GUI 未运行或视觉开关关闭时跳过来源读取和解析，继续原 hook 链路。关闭与发送并发时依靠 epoch 拒收；receiver 已安排的批次及 MainActor 回调也必须重验 epoch/revision，不能在清空后重新填入旧来源。

**文本与身份。** 项目路径原值只存在解析局部内存，project label <=128 Unicode scalars，session ID <=256 bytes，所有展示标签总量 <=1KiB。拒绝带控制字符、NUL、ANSI、双向覆盖符的 ID；标签去控制字符、折叠换行为空格、按 grapheme 截断；必要时显示 unavailable。支持 CJK/emoji，不能切坏代理对/组合字符。显示 label 与匹配 key 分开；不按标题、basename、秒级时间去重；不同 cwd 同 basename 的记录仍不同，详情可显示会话内稳定的非语义区分编号。没有 session ID 时每条记录保持独立，不能并入上一次会话。

**IPC endpoint。** 生产路径由 `ClaudioPaths` 增加独立 `event-notices` runtime namespace；不移动旧路径。receiver descriptor 为小型 `0600` regular JSON，只含 schema、随机 epoch 和私有 socket 位置，不含来源内容；socket 位于 Darwin 用户临时目录内由 GUI 创建的 `0700` 短目录，显式检查 sockaddr_un 字节长度。采用系统临时目录 API，忽略外部不可信 TMPDIR 重定向。endpoint ownership、mode、no-follow 与 inode 检查复用既有 bounded-file/lock 模式。

一个 GUI receiver 持有 nonblocking owner lock；第二实例发现锁忙只显示健康状态，绝不 unlink 活跃 socket。创建/失败清理/退出仅回收本实例持有的目录项。崩溃恢复只在拿到锁后验证旧 descriptor，拒绝任意路径清理，不递归删除外部目录。helper 校验 descriptor 并创建 `O_NONBLOCK` socket，单个 envelope <=8KiB；sendto 的 ENOENT/ECONNREFUSED/EAGAIN/ENOBUFS/EMSGSIZE/权限错误均及时返回，最多一条固定脱敏原因码，绝不输出 payload。内核接受发送不等于 GUI 已展示。

receiver 校验 epoch、payload 上限、schema、Surface/Binding 对应和 installation。installation 在后台队列经已有 receipt store 的只读 seam 重验，不触发完整 integration refresh；显示与点击时再次对最新连接代次/模型 revision 校验。断开后已存在的近期记录可作为历史显示，但 route 失效；排队旧代次不得再次自动出现。消息只属于当前用户信任边界；0700 不等于抵御同用户恶意进程，不包装成“宿主身份密码学证明”。

**实时与保留。** GUI 未运行不自动启动、不创建内容 backlog，声音仍运行。近期集合最多 50 条、保留 30 分钟、只在 GUI 内存；文案“本次运行收到的近期提示”，不称完整历史。重复 event UUID 丢弃，异 UUID 不因字段相同合并。相同时间按 receiver 到达顺序稳定排序。流量超限淘汰最老非当前记录、保留当前阅读与选中详情；溢出以“仅保留最近 50 条”说明，无法知道的丢失数量不伪造。Quit 清空，sleep/锁屏立即隐藏并清空来源内存与 epoch，wake/unlock 重建 receiver，避免重新显示锁屏前私人信息。

30 分钟 TTL 使用本次接收的单调时间，优先于阅读暂停；到期立即清除模型、冻结列表快照和详情投影中的来源字段及导航目标。正在阅读的条目替换为无来源的“该来源信息已过期”占位，焦点留在关闭/近期入口，不自动选择另一事件。容量保护不能延长私人数据 TTL；只保留占位所需的非来源状态。过期调度使用最近一个到期截止，不增加逐秒轮询。

**视觉开关与静默。** `ClaudioPreferences` 新增 typed `showsEventSourcePrompts`（默认 true；非法值 fail closed 为 false 并显示 recovery issue）。通知页提供该总开关与短隐私说明；关闭立即清空来源、关闭 receiver 内容接收并收起 UI。事件声音开关仍只控制音频；主音量零、单事件静音、音频损坏/失败不吞视觉事实。顶部提示沿用用户已启用的 Focus/Calendar 静默事实，不新建权限 owner；有效静默时只保留内存近期记录、停止自动浮现，结束后不追补轰炸。通知页明确“专注/会议静默同时收起自动来源提示”；现有音频语义不变。系统事实失效按 ADR 0009 不延续过期静默。屏幕锁定与 sleep 是另一条隐私清空规则。

**原生呈现。** 自动条使用 `.borderless + .nonactivatingPanel`、`hidesOnDeactivate=false`；窗口 level 选择普通辅助浮层，不能使用屏保/锁屏级别。首条固定落在指针所在显示器，找不到时用主屏；当前 burst 固定该屏，不随鼠标漂移。顶部位置取可见安全区与刘海 safeAreaInsets 交集后向下 12pt，约 440pt 宽，两侧至少 16pt；屏幕移除重新夹取。菜单栏自动隐藏、缩放、负坐标屏幕和 full-screen Space 必须实测；不通过强制切换 Space/激活应用换取可见性。

胶囊维持 C 紧凑骨架：Claudio 小图形 / 来源名与会话短标识、项目标签 / 事件字形与短标题 / 近期数量。原型实际含两条紧凑文字基线；不把“单行快速辨认”误写成强迫全部文字同一行。来源文字空间不足优先保留来源名、项目和事件，session 在详情完整呈现；不得压缩事件控件和至少 28pt 的命中区域。详情列表最大 6 条可见、其余滚动，source/session/发生时间完整可读；无外部标题推断。

只有用户点击数量/来源、通过菜单栏“近期提示”或按显式导航入口时，才进入 interactive 模式并 make-key。Tab/Shift-Tab/Enter/Space/Esc 在此窗口内处理，不能用全局键盘监听夺取宿主按键。原生列表/按钮 AX label 与 visible text 同源；自动到达不反复抢播 VoiceOver，近期入口可达。Esc 先关详情，再关列表/提示；点外关闭但不吞原点击。关闭只在当前 focus ownership 未被用户转移时归还原宿主/面板触发按钮，避免迟到 handback 激活错误应用。设置打开和顶部列表互斥显示，仍用现有 typed route 与 retained 设置窗口。

## 5. Code quality review：3 项发现与自动决策

### 5 / D6 计时、排队与阅读状态

`[P1] (confidence: 9/10) 原型 index.html:1226–1233`：`state.queue.push(item); updateCard(variant);` 说明原型将队列和重绘耦合；S4/S5 要求暂停/阅读稳定，生产不能用多个 View 定时器维护。

选择 **5A [Layer 1]**：Foundation-only `EventNoticeModel` 内统一 reducer、pause reason set、revision 和 clock/scheduler 注入（10/10；human ~1d / CC ~1h）。未选 **5B**：SwiftUI @State 分散 timer 与列表（6/10，少量编码但无法封住跨窗口取消）。符合 DRY、显式状态优先。

```text
hidden -- accepted event --> entering -- animation complete --> visible(4s)
  ^                             |                                 |
  |                         hover/focus                        timeout
  |                             v                                 v
  +-- fade complete <-------- exiting <------------------------ visible
                                |
               new arrival --> cancel old exit via revision

visible -- hover OR keyboardFocus OR expanded --> paused(remaining)
paused  -- remove one reason, others remain ----> paused(remaining)
paused  -- no reasons remain -------------------> visible(remaining)
any visible state -- next event --> same current + recent insert + pending count
explicit recent selection --> selected current, no new history record, fresh 4s after release
close / Esc --> hidden; display statuses only, never handled/resolved
disable / lock / sleep / quit --> cancel, invalidate epoch, clear source memory
```

完整计时：4s 从进入动画完成后算；进入期间 hover 已存在时完成后保持 paused。timer callback 带 presentation revision 和 current UUID，过期回调不能关新条。追加事件不延长当前 deadline、不自动播放队列；收起后下一次新事件开始新 burst。退出动画期间新事件取消旧退出、建立新 revision；旧 completion 无效。离开 hover 不得覆盖仍在列表内的 keyboard focus。展开期间新记录到达只更新 badge，冻结列表阅读快照；显示“有 N 条新提示”显式刷新，避免焦点索引漂移。记录状态为 displayed/queued/collapsed，仅用于展示，不加 handled/processed 字段。

### 6 / D7 身份、文案与错误边界

`[P1] (confidence: 9/10) 原型 index.html:1074–1076` 用数组序号绑定近期动作，并把各记录统一显示“已收起 / 未处理”。生产 S6/S9 需要稳定身份和不虚构处理状态。

选择 **6A [Layer 1]**：所有点击绑定 event UUID，展示投影统一生成 label/AX/action capability；无 session、非法文本、重复 basename、跨代次、路由失败都有独立结果（10/10；human ~5h / CC ~45min）。未选 **6B**：照搬数组 index 和散落字符串（5/10），插入新条可能点击到另一会话。新增英中 key 同批注册 `ClaudioL10nKey.allKnown`，用户名称不当格式串。

### 7 / D8 常驻生命周期与偏好

`[P2] (confidence: 9/10) SettingsPreferences.swift:24–30` 的 snapshot 目前只有语言、目的页、Surface、状态点和恢复问题；`MenuBarController.swift:89–93` 已有 app-lifetime tasks。S9 的近期历史不能寄存在随打开重建的 View。

选择 **7A [Layer 1]**：composition root 注入一个模型与 receiver；生命周期、偏好、语言改变只重投影；开关有持久化/失败回退；同一对象跨顶部条、面板入口、通知页（10/10；human ~5h / CC ~45min）。未选 **7B**：每个窗口自建实例（4/10），会重复通知或丢历史。现有动画注释与布局图同步更新，不能留下“面板零动画”的旧描述。

## 6. Test review：8 个覆盖缺口组

现有 `HostHookRunnerSuite` 已覆盖静音、失败、动态静默、严格事件映射和宿主间去抖；`HostHookReceiptSuite` 覆盖 schema 白名单和断开/重连；`SettingsPreferencesSuite` 与 `PanelFocusCoordinatorSuite` 覆盖已有偏好/焦点模型。这些测试在源码中存在，本次没有执行，不能报本轮 PASS，也不能当成新 IPC/UI 已覆盖。

新增功能目前 **0/8 覆盖组已实现**，以下 **8/8 已写入实施要求**；不是“覆盖率 100%”。每组含多个分支，不用主观星级替代代码覆盖计量。G1–G8 均为 `[P1] (confidence: 9/10)` 的计划缺口，以 S1–S11 原文和上述既有源码边界为依据，自动选择完整测试（D9–D16：A=10/10，B=只 happy path 6/10，均选 A）。

```text
CODE PATHS / FILES                                    USER FLOWS
G1 [GAP] HostEventSource.swift + HookInputReader.swift
  parseSource(host,payload)                           same tool/different project
    +-- known host, valid cwd/session -> safe source  same project/different session
    +-- absent/invalid/oversize -> partial/unknown     long CJK/emoji/control characters
    +-- unsupported schema -> no guessed fields      WorkBuddy known-host/unknown-source
  readInput(fd,deadline,limit)
    +-- TTY/empty/closed -> unavailable
    +-- fragments/EINTR -> bounded continue
    +-- timeout/too big/bad JSON -> unavailable
G2 [GAP] HostHookRunner.swift + Subcommands.swift
  handleHostHook() -> existing mapping/install gate
    +-- unknown/unsupported -> existing no-op
    +-- stale/missing marker -> no live presentation
    +-- muted/failed/debounced -> unchanged audio/receipt/activity
    +-- parser/sink failure -> existing path still completes [CRITICAL ->E2E]
G3 [GAP] EventNoticeTransport.swift + EventNoticeModel.swift
  send/receive -> good -> validate -> bounded mailbox
    +-- bad mode/symlink/path too long -> typed unavailable
    +-- stale epoch/install/duplicate UUID -> reject
    +-- no GUI/socket full/restart/second instance -> bounded failure
    +-- queue full/TTL/counter boundary -> honest retained range [->E2E]
G4 [GAP] EventNoticeModel.swift
  receive/pause/resume/select/dismiss/expire
    +-- 3 events -> one container, current fixed, count=2
    +-- overlapping pause reasons -> remaining time stable
    +-- outdated timer/animation -> ignored
    +-- select by UUID/new arrivals -> correct item, no duplicate history
    +-- reduce-motion/disable/sleep/lock/quit -> cancel safely
G5 [GAP] EventNoticeView.swift + EventNoticeWindowController.swift
  render/place/show/interactive/close
    +-- long source/unknown/empty/recent list -> readable/accessible
    +-- auto-arrival -> no activation/no IME commit [->E2E native]
    +-- explicit expand -> Tab/Enter/Space/Esc/VO [->E2E native]
    +-- display removed/fullscreen/notch -> safe placement [->E2E native]
G6 [GAP] SessionNavigation.swift
  capability/action/result
    +-- verified route -> explicit open -> success/failure/timeout
    +-- unavailable/invalid target -> source details/copy valid ID
    +-- stale revision/double click -> single correct action
    +-- arbitrary payload URL/command -> never executed
G7 [GAP] Preferences / SettingsRootView / PanelView / App composition
  enable/disable/locale/quietPolicy/menu-recent
    +-- invalid defaults -> disabled + recovery
    +-- Focus/Calendar -> history only; no replay after recovery
    +-- sound muted/volume zero -> visual independent
    +-- multiple consumers -> one model; close/reopen retains only allowed memory
    +-- DEBUG fixture -> same model; Release -> no synthetic input
G8 [GAP ->E2E] built app + bundled/shared helper
  fresh real hook -> source projection -> native notice -> recent -> action
    +-- each supported host/event including unknown metadata
    +-- old/new helper pair -> explicit no-live-source state, audio unaffected
    +-- GUI restart/offline/overload -> no false delivery claims
    +-- light/dark/contrast/Reduce Motion/Transparency -> screenshots
```

| 组 | 实施测试文件与可检查断言 |
|---|---|
| G1 | 新 `helper/Tests/ClaudioCoreTests/HostEventSourceSuite.swift` / `HookInputReaderSuite.swift`：合成 JSON 字段白名单、父会话语义、错误字段与缺字段分别降级、禁止 transcript I/O；真实 pipe 分片/EOF 永不来/64KiB+1/20ms 截止；不打印 private sentinel |
| G2 | 扩展 `HostHookRunnerSuite.swift`：注入抛错/不可用 sink，不影响现有 play invocation、receipt keys、activity count、exit 0；旧 installation 不发视觉；测试 helper 真进程无 GUI 时及时退出。CRITICAL 回归保护，不是声称已有回归 |
| G3 | 新 `helper/Tests/ClaudioCoreTests/EventNoticeTransportSuite.swift`：临时 endpoint 真 sender/receiver、多进程三事件、故障 errno、epoch、长度、权限、抢占、重复、退出 FD 关闭；receiver 不对每条启动新 Task；验证真实发收而非全 mock |
| G4 | 新 `gui/Tests/ClaudioGUICoreTests/EventNoticeModelSuite.swift`：fake clock 跑状态图全部边、1/3/50/51/1000 条、过期/时钟回拨不影响剩余时间、同时 hover+focus+expand、进入/退出期间新事件、关窗后 stale completion；TTL 在暂停/冻结详情中仍清字段与 route，disable/lock 后旧 drain 不得回填 |
| G5 | 新 `EventNoticePresentationSuite.swift`：导入共享 view/投影，尺寸夹取、文本/AX/动作同源；纯模型不证明 AppKit。原生测试覆盖 IME、FKA 两态、VoiceOver、点外点击透传和多屏，结果写 acceptance ledger |
| G6 | 新 `SessionNavigationSuite.swift`：fake navigator 检查有效目标只派一次、异步失败可恢复、timeout 状态明确、离开后不激活窗口、不可用 route 不显示成功；不得打开拼接的 shell/任意 URL |
| G7 | 扩展 `SettingsPreferencesSuite.swift`、`SettingsRootInteractionSuite.swift`、`PanelFocusOrderSuite.swift`；最小 `ViewWiringSuite` 只守 executable composition 的不可编译边界，不能替代行为测试 |
| G8 | `docs/event-source-prompts-acceptance.md` 与原生 DEBUG gallery：记录源码 SHA、bundle/helper hash、OS/host version、主题、截图、操作步骤、真实 hook 是否观察到；同一 helper 配合隔离 marker/config 注入路径，不用修改 HOME 来伪装隔离 |

所有新 suite 公开 `run<Feature>Suites()`，各包 `main.swift` 注册；Swift 6 Sendable / MainActor 编译门禁。没有 LLM prompt/provider 改动，无需新增质量 eval。

## 7. Performance review：2 项发现与自动决策

### 8 / D17 短生命周期 hook 不得被增强链拖慢

`[P1] (confidence: 9/10) Subcommands.swift:6–7`：“这里也静默返回成功，绝不把宿主工作流卡在声音工具上。”无界 stdin read、GUI ACK、每条全量 integration refresh 都违背该约束。

选择 **8A [Layer 1]**：20ms 有界输入、一次非阻塞发送、专用 I/O 队列、单批 MainActor drain；receiver 不扫目录/项目/声音库（10/10；human ~5h / CC ~45min）。未选 **8B**：轮询最新回执或同步等待 GUI（5/10），同时丢突发事件/增加 hook 延迟。

目标（待基准测试）：本机 Release、无故障 100 次序列增量延迟 p95 <=30ms；accepted envelope 到已准备显示的模型 p95 <=100ms；原生首次显示目标 <=250ms。慢 stdin 故障不能超出读取预算后继续等待 EOF；OS 调度造成的超时与代码主动等待分开报告。与同基线未接 sink 的 hook 对比，不把构建/进程冷启动算成 source 解析时间。

### 9 / D18 高频事件、内存与空闲成本

`[P2] (confidence: 9/10) 原型 index.html:1232`：`state.queue.push(item)` 未设上限，`1074` 仅通过 `slice(0,5)` 限制渲染，不能作为生产保留策略。

选择 **9A [Layer 1]**：应用队列/近期/去重表均有界，receiver mailbox <=128、单次处理 <=32 条或 4ms、同一时刻最多一个待处理 MainActor drain；展示以 100ms 合并 badge 更新但不合并事件身份。当前显示期间仅一个截止 timer，空闲无轮询/逐秒刷新（10/10；human ~4h / CC ~40min）。未选 **9B**：只截断 UI 不截断数据（6/10），长时间工作会累积对象。

压力试验：1000 条/10s，内存集合始终在常量上限、当前/选中条不被换掉、UI 不排队执行 1000 个 task，结束后计时/observer/FD 数归基线。禁用时没有 receiver 内容读取。无数据库，无 N+1 SQL；不引入配置/声音库第二缓存。允许仅保存枚举健康码和聚合丢弃计数，不保存来源到性能日志。

## 8. Failure modes 与可见恢复

这里的“覆盖”指计划中的必要测试，全部尚待执行。无处理且无测试的静默关键缺口：0；已识别风险都有具体处理与验证，不能把这个数字读作已验证安全。

| 新路径 | 现实失败 | 处理 / 用户看见什么 | 覆盖 |
|---|---|---|---|
| G1 输入 | 宿主不关 stdin、私密大 payload、字段变化 | 截止并显示已知 host/event + 来源未识别，原声音不受影响 | pipe + parser |
| G2 分流 | source sink 失败或 installation 迟到 | 无伪提示/伪激活；已有音频/回执/活动分别完成；固定诊断码 | runner + process |
| G3 transport | GUI 未运行/崩溃/第二实例/socket 满 | best-effort 丢弃；不补历史；通知页可显示当前 receiver unavailable；可知错误记脱敏码，未知丢失不编数量 | real socket / restart |
| G3 retention | 超过 50 条、30min、重复 UUID | 明确保留范围，当前阅读固定，过期清理不标处理 | bound / fake time |
| G4 timing | 已取消 timer 又返回、新事件撞退出动画 | revision/UUID 不匹配即忽略，当前条完整可读 | deterministic scheduler |
| G5 native | 输入法组字被激活打断、多屏移除、VO 不可达 | 自动路径无 activate；显式入口可键盘查看；新窗口原生门禁未通过不得报完整实现 | native IME / AX / screen |
| G6 route | session 失效、宿主未装、打开失败、重复点击 | 不猜替代会话；来源详情保留、复制 ID 可恢复、错误明确 | fake effect + verified-host manual |
| G7 policy | 偏好损坏、quiet 快照过期、锁屏 | 偏好失败关闭；过期 quiet 不无限压制；锁屏立即隐藏并清内存；健康状态可见 | prefs / lifecycle |
| G8 composition | shared helper 仍是旧版、Release 带 fixture | hash/版本核对；无实时来源单独说明，现有连接激活不能作为 IPC 健康；DEBUG seam 不进入 Release | bundle/process + release build |

## 9. NOT in scope / TODO 决策

- A/B 生产模式与样式切换：用户已经选择 C，保留比较页即可。
- 任意宿主精确会话跳转、自动操控终端/AppleScript、读取会话数据库：原 spec 只要求模拟；当前不具备跨宿主接口证据。
- 跨重启历史、磁盘 inbox、云同步、完整活动历史：超出近期提示目的，且扩大私人来源保留范围。
- 以 UI 提示替代/改造音频、活动摘要、receipt/activation，或新增宿主事件能力：属于别的领域变更。
- 全量替换主菜单栏 NSPopover：已有显式交互合同，C 不需要重写该入口。
- 新分发渠道、上架、签名、公证、push/PR/发布：本轮是规划，沿用现有分发方案。

潜在 TODO 单项审查 D19：**精确宿主会话导航能力调查**。What：按 host/version 固定可导航接口。Why：从辨认来源进一步减少手工找会话。Pros：精确返回工作现场；Cons：各宿主协议不齐、误跳风险及维护成本。Context：当前只有 session ID 和模拟原型，需从 adapter 而非 UI 猜 URL 开始；Depends on：官方接口及真机对照。自动选择 **B 跳过新增 TODOS.md**，将其保留为本计划明确非目标；不以本次功能制造一个没有证据的实现承诺。将来用户要求该能力时再立独立完整规格。

其余所有发现本轮实施任务内解决，不延期计时、来源降级、失败隔离、原生/无障碍验收。`TODOS.md` 不修改。

## 10. Implementation Tasks

所有任务来自上面发现，未执行。时间为预算估计（仓库 AGENTS 无 AI 压缩表），人工验收时间不可用 AI 编码倍率折算掉。

- [ ] **T1 (P1, human: ~4h / CC: ~45min)** — 规格与领域边界 — 固定来源隐私/生命周期与 C 展示例外。
  - Surfaced by: Architecture 1/3、Code Quality 7。
  - Files: `CONTEXT.md`, `DESIGN.md`, 新 `docs/adr/0012-use-ephemeral-event-source-notices.md`, 本计划。
  - Verify: 新 ADR 保留 0008/0009/0010 owners；明确顶部条为辅助短暂窗口，更新 DESIGN 当前“两顶层 surface”边界和通知静默说明；不动历史段。
- [ ] **T2 (P1, human: ~1d / CC: ~1–2h)** — ClaudioCore 输入 — 实现有界来源提取与兼容 hook 分流。
  - Surfaced by: Architecture 1、Performance 8、G1/G2。
  - Files: 新 `helper/Sources/ClaudioCore/HostEventSource.swift`, `HookInputReader.swift`; `HostHookRunner.swift`; `helper/Sources/claudio/Subcommands.swift`; 新 `HostEventSourceSuite.swift`, `HookInputReaderSuite.swift`; 既有 `HostHookRunnerSuite.swift` 和 helper test main。
  - Verify: G1/G2；命令格式/receipt schema 完全不变；来源失败不影响原链路。
- [ ] **T3 (P1, human: ~1–2d / CC: ~2–3h)** — ClaudioCore transport — 建立私有有界实时通道。
  - Surfaced by: Architecture 2、Performance 8/9、G3。
  - Files: 新 `helper/Sources/ClaudioCore/EventNoticeTransport.swift`, `Paths.swift`, 新 `EventNoticeTransportSuite.swift`, helper test main。
  - Verify: G3 真实 socket、故障、双实例、跨进程；若产生新磁盘 metadata writer，更新 `AtomicWriteSuite` 的写面台账，不写任何 source payload。
- [ ] **T4 (P1, human: ~1d / CC: ~1–2h)** — ClaudioGUICore — 实现单一提示状态模型与动作投影。
  - Surfaced by: Code Quality 5/6、Performance 9、G4/G6。
  - Files: 新 `gui/Sources/ClaudioGUICore/EventNoticeModel.swift`, `SessionNavigation.swift`; 新 `EventNoticeModelSuite.swift`, `SessionNavigationSuite.swift`; gui test main。
  - Verify: G4/G6 全状态图；所有副作用注入；源码内保留上面 timer/pause/epoch ASCII 图。
- [ ] **T5 (P1, human: ~1–2d / CC: ~2h + manual)** — 原生 C — 实现顶部条、展开列表与显式焦点交互。
  - Surfaced by: Architecture 3/4、Code Quality 6、G5。
  - Files: 新 `gui/Sources/ClaudioGUIComponents/EventNoticeView.swift`, `gui/Sources/ClaudioGUI/EventNoticeWindowController.swift`, 新 `EventNoticePresentationSuite.swift`; gui test main。
  - Verify: macOS 12 编译；G5 原生 gate；不在 view 做 I/O，不在自动显示激活 app，保留 C 布局和主题 token。
- [ ] **T6 (P1, human: ~1d / CC: ~1–2h)** — composition 与设置 — 接入唯一 owner、近期入口与偏好。
  - Surfaced by: Code Quality 7、Architecture 2/3、G7。
  - Files: `gui/Sources/ClaudioGUI/MenuBarController.swift`, `PanelView.swift`, `ClaudioGUIApp.swift`; `gui/Sources/ClaudioGUICore/SettingsPreferences.swift`, `PanelFocusOrder.swift`; `gui/Sources/ClaudioSettingsPresentation/SettingsRootView.swift`, 需要的 session 注入；`gui/Sources/ClaudioLocalization/ClaudioLocalization.swift`, `Resources/Localizable.xcstrings`；既有相关 suite。
  - Verify: G7；新的近期入口排在 Settings 与 Sound Scope 之间，并同步 focus order/handback；按钮可发现且不挤压原设置动作；sleep/lock/disable 清空，quiet 不补播。
- [ ] **T7 (P1, human: ~1d / CC: ~1h + manual)** — 验收与运行时 — 完成宿主、进程、视觉与分发回归。
  - Surfaced by: G1–G8、Architecture 4、Performance 8/9。
  - Files: 新 `docs/event-source-prompts-acceptance.md`; 新 DEBUG `gui/Sources/ClaudioGUI/EventNoticeGallery.swift`；必要的 `ViewWiringSuite.swift` composition 绊线；分发说明如需更新。
  - Verify: 以下完整门禁与逐 host native ledger；记录不支持/未知/未验证，不用 screenshot 或 harness 互相替代。

不新增没有发现来源的任务。所有 P1 在本功能完成前闭环；没有隐藏 P3 功能捷径。

## 11. Worktree parallelization strategy

| Step | Modules touched | Depends on |
|---|---|---|
| T1 | docs/, root design/context | — |
| T2 → T3 | helper/Sources/, helper/Tests/ | T1 固定 envelope 与隐私合同 |
| T4 | gui/Sources/ClaudioGUICore/, gui/Tests/ | T1 固定 envelope/public test seam |
| T5 → T6 | gui/Sources/, gui/Tests/ | T4；T6 还需要 T3 |
| T7 | docs/, gui/, helper/ tests | T2–T6 |

Lane A：T2 → T3（共享 helper，串行）；Lane B：T4 → T5（共享 GUI/tests，串行）。T1 完成后 A/B 可在独立 worktree 并行，T1 先提供可编译的最小 DTO 合同或两 lane 共同依赖的底层提交；不得各自造同名 DTO。合并 A/B 后 T6 → T7 顺序集成。两 lane 不同时改同一 test main；任何实际重叠路径归一个 owner。当前工作树已有 `.reports/`、`.workbuddy/` 未跟踪内容，保持原样。

## 12. 验证、实施顺序与证据门槛

1. 原生技术验证先于大规模 UI：在 DEBUG gallery 验证自动非激活、显式 key/AX 和 IME；验证 socket 的三事件收发、无 GUI 有界退出。这是 T3/T5 的第一小步，失败则修实现，不能用浏览器效果代签。
2. T2–T6 同步写 focused tests，先跑受影响 suite，再跑两包完整 harness；不得只做字符串 wiring 测试。
3. 完成功能后执行：

```bash
swift run --package-path helper claudio-tests
swift run --package-path gui claudio-gui-tests
swift build -c debug --package-path gui --product ClaudioGUI
swift build -c release --package-path helper --product claudio
swift build -c release --package-path gui --product ClaudioGUI
jq empty gui/Sources/ClaudioLocalization/Resources/Localizable.xcstrings
git diff --check
bash scripts/dev-bundle.sh
bash scripts/check-release-size.sh dist/claudi0.app
```

对意图修改的 Swift 文件按 `.swift-format` lint，并检查新 API macOS 12 availability；clock 使用可注入单调时间，默认用支持 macOS 12 的 `DispatchTime.uptimeNanoseconds` + 可取消 scheduler，不直接无条件引入更高系统版本 Clock API。sleep 隐藏/清空，wall clock 仅用于显示发生时间，不驱动 4s 剩余量。

设置整体验证脚本 `bash scripts/verify-settings-experience.sh d113ff335b7d5b35409b12adc78172d586c7566b` 要求 clean HEAD；实施时先运行各组件门禁，获独立 commit 授权并形成 clean HEAD 后再运行固定基线脚本，不能为了过门禁擅自提交或清理用户文件。双 CPU 构建、真实宿主 callback、音频、FKA/VO、Focus/Calendar 权限、真实多屏/full-screen、签名/公证分别标状态。

验收通过的最低实证：连续三条不同来源不丢/不换当前；hover+focus 交叠暂停；正在中文输入法组字时自动提示不提交/丢字；菜单栏近期可重看；未知会话诚实显示；关闭视觉提示不损声音/统计/回执；真实 helper 与 GUI 版本匹配。原型示例标题不冒充真实采集结果。实现结束时仍无法完成的原生 gate 必须保留“未验证”，不能称全量验收完成。

## 13. 研究依据、回顾与审查记录

平台研究使用官方资料。Aside 本机未安装，已使用可用 web 工具回退；未安装浏览器扩展。原生策略依据 [Apple NSPanel.becomesKeyOnlyIfNeeded](https://developer.apple.com/documentation/appkit/nspanel/becomeskeyonlyifneeded)，非激活创建时固定 style，不能运行中随意切换以规避焦点问题。I/O 复用 [Apple DispatchSourceRead](https://developer.apple.com/documentation/dispatch/dispatchsource/makereadsource%28filedescriptor%3Aqueue%3A%29) 和 [send(2)](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/send.2.html)；非阻塞不等于无丢失保证。

来源字段依据 [Claude Code hooks](https://code.claude.com/docs/en/hooks) 和 [Codex hooks](https://developers.openai.com/codex/hooks)，只采用共同明确字段；Codex 文档强调 transcript 格式不是稳定 hook 接口，因此不将它当标题/导航数据库。WorkBuddy 的此次字段研究无可用官方页面，保持未知并设专门 adapter 校准任务。没有据此宣称宿主不可能支持字段。

近期 Git log 显示 `ec71250` 延迟作用域选择重验、`ec4fe1f` 交互加固和 `de4b4e6` 焦点/动画统一，故本计划将 delayed callback revision、稳定 ID 和焦点移交列为一级验收。Prior learning applied：`sound-scope-delayed-selection-revalidation`（10/10，2026-09-11）、`settings-gate-needs-clean-head`（10/10，2026-09-11）。

Outside voice：按已读取 skill section 的 `CODEX_MODE=under_codex` 分支跳过 nested Codex；没有独立第二模型结论，不将本次自检标作跨模型共识。设计链决策 D20：本次以 C 已选原型进入工程实现准备，原生视觉设计复查纳入 T5/T7；不自动启动新一轮 CEO/产品方向讨论。

Suppressed findings：关于 WorkBuddy 精确 title/URL、inactive NSPanel 的实际 VoiceOver、所有系统版本 full-screen 行为，仅有待验证假设；不以高置信度“已支持/不可能”列为缺陷。验证任务保留。

机器可读交付：[七项实施任务](/Users/d0m999/.gstack/projects/Claudio/tasks-eng-review-20260911-183046.jsonl)；QA 入口：[测试清单](/Users/d0m999/.gstack/projects/Claudio/d0m999-main-eng-review-test-plan-20260911-183046.md)。本轮只校验计划映射、文件路径、JSONL schema 和 whitespace；未运行生产构建/harness，未改生产实现。

Completion summary：Step 0 完整范围保留、移动部件收敛；Architecture 4 项；Code Quality 3 项；Test 8 缺口组和 ASCII 图；Performance 2 项；What already exists / NOT in scope 已写；TODO 1 项已按 auto-select 决定不新增；未分配处理/测试的 critical gap=0；Outside voice skipped；2 条可并行 lane + 集成顺序段；Lake Score 17/17 完整建议进入计划，均尚待实现。无未决产品选择，仍有明确实施证据门禁。

## GSTACK REVIEW REPORT

| Review | Trigger | Why | Runs | Status | Findings |
|---|---|---|---|---|---|
| CEO Review | `/plan-ceo-review` | 产品范围 | 0 | 未运行（本功能） | 沿用 C 与原 spec |
| Codex Review | outside voice | 独立第二意见 | 0 | SKIPPED under_codex | 不声称跨模型审查 |
| Eng Review | `/plan-eng-review` | 架构、质量、测试、性能 | 1 | CLEAR (PLAN) | 17 项计划发现已纳入；0 未决选择 |
| Design Review | `/plan-design-review` | 原生视觉与交互 | 0 | 原生检查待 T5/T7 | C 原型已由用户选择 |
| DX Review | `/plan-devex-review` | 开发体验 | 0 | 未运行 | 沿用现有两包 harness |

**VERDICT:** ENG CLEARED，工程计划可执行；不是实现完成、真实宿主跳转可用或原生验收通过的证明。

NO UNRESOLVED DECISIONS
