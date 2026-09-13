# claudi0 声音系统

claudi0 为多个宿主提供同一套语义化提示音，并让用户通过声音包管理这些声音。

## Language

**已安装声音包（Installed Sound Pack）**:
已经进入 claudi0 运行时可发现集合、可被选择和播放的声音包。随 app 提供但尚未复制进入该集合的出厂内容不算已安装声音包。
_Avoid_: Bundle Pack、出厂源

**声音包库（Sound Pack Library）**:
当前全部已安装声音包的集合，是管理窗口读取的完整集合；它不等于主面板上最多四项的显示集合。
_Avoid_: 面板包列表、星标包

**声音包库快照（Sound Pack Library Snapshot）**:
本次 app 运行期间最近一次成功读取声音包库所得的不可变事实集合。刷新期间它可以短暂陈旧，但不是独立于磁盘内容的第二个真相源；完整音频目录清单按选中包读取，不随全部包快照常驻内存。
_Avoid_: 持久缓存、声音包数据库

**声音包事实（Sound Pack Facts）**:
从声音包自身内容读取的身份、映射、文件可用性与出厂完整性，不包含当前选择、星标、静音或面板显示位置等用户配置。
_Avoid_: PackCard、面板状态

**面板显示集（Panel Display Set）**:
声音包库中被用户选为主面板快捷入口的子集，最多包含四个声音包。
_Avoid_: 声音包库

**出厂声音包（Factory Pack）**:
随 app 提供、用于首次复制和恢复的原始声音包；只有复制进入运行时可发现集合后，才同时成为已安装声音包。
_Avoid_: 已安装声音包、Bundled Lookup Pack

**宿主产品（Host Product）**:
向用户提供 AI 工作流的产品身份，例如 Claude、ChatGPT 或 WorkBuddy。产品不直接拥有统一事件能力；能力属于它的具体事件来源。
_Avoid_: 用产品名代替具体 surface

**事件来源（Host Surface）**:
一个具有独立原生事件协议、配置位置、授权状态和回执代次的宿主表面。每个来源由稳定 `HostSurfaceID` 标识，并可归属于一个宿主产品。
_Avoid_: App、来源行、把 Chat 与 Codex view 合并

**事件绑定（Host Event Binding）**:
一个来源的原生事件到 claudi0 公共 `Event` 的稳定、可版本化映射，由 `HostEventBindingID` 标识；接口声明、当前实现和真实激活是三个独立事实。
_Avoid_: 只用原生事件字符串作为身份

**当前激活（Current Activation）**:
当前 installation、surface、事件绑定和版本 scope 下，由真实宿主回调生成的脱敏回执。静态配置、接口文档、测试通过或旧代次回执都不构成当前激活。
_Avoid_: 已配置、已支持、已测试

**声音默认值（Global Sound Defaults）**:
顶层 `selected_pack`、事件开关和 `master_volume`。`master_volume` 始终为全局轴；具体 surface 只可稀疏覆盖 pack 与事件开关。
_Avoid_: 默认 surface、全局 profile 实例

**Surface 声音覆盖（Surface Sound Override）**:
`surface_overrides` 中按稳定 `HostSurfaceID` 保存的稀疏 pack/事件配置。缺键表示继承声音默认值；显式损坏必须 fail closed，不能静默继承。
_Avoid_: 完整复制的 per-app config、per-surface 主音量

**声音作用域（Sound Scope）**:
用户当前查看和修改声音偏好的目标，只能是声音默认值或一个事件来源。声音默认值不是伪造的事件来源；切换声音作用域不改变连接配置或当前激活。
_Avoid_: App、宿主产品、连接状态、默认 surface

**有效声音配置（Effective Sound Profile）**:
把声音默认值与一个可选的 Surface 声音覆盖逐字段解析后得到的 pack 与事件开关结果。它不单独持久化，主音量仍是独立的全局轴。
_Avoid_: 完整 surface config、持久化 profile、覆盖副本

**设置目的页（Settings Destination）**:
统一设置体验中一个用户可直接到达的顶层类别，例如「集成」或「声音」。目的页只组织相关能力，不因此成为新的事实所有者，也不等于一个独立窗口。
_Avoid_: 设置项目、独立管理窗口、把侧栏条目当成数据模型

**动态静默状态（Dynamic Quiet State）**:
由用户明确授权的系统状态临时派生出的自动提示音抑制，例如专注模式或日历忙碌。它不改写事件开关、声音作用域、声音包或主音量；过期或无法确认的状态不能继续制造静默。
_Avoid_: 全局静音配置、把主音量写成零、批量关闭事件

**事件来源提示（Event Source Notice）**:
由当前运行 GUI 临时接收并展示的不可变宿主事件投影，包含已验证的事件来源、绑定身份、
发生时间以及可选的安全项目/会话标签。它只在本次 GUI 生命周期的内存中存在，不属于回执、
本地活动摘要或宿主配置；自动展示不激活 Claudio，也不代表事件已经处理。
_Avoid_: 把来源写入 receipt、用提示历史冒充完整活动历史、从项目名称推断会话

**提示来源接收器（Event Notice Receiver）**:
由 GUI app-lifetime owner 持有的私有 Unix datagram 接收器。它只接受当前 epoch、当前
安装代次和已知 Surface/Binding 的有界消息；发送失败是 best-effort，不改变既有 hook
播放、回执、活动或 CLI 退出语义。
_Avoid_: 常驻 helper daemon、磁盘内容队列、ACK 重试总线

**待接手提醒（Attention Reminder）**:
Claudio 已观察到的授权、明确输入请求、执行中断或原因不明关注信号，供用户稍后接手。它是有期限的提示投影，移除或空列表都不表示宿主任务已完成。
_Avoid_: 待办任务、已解决任务、全事件历史

**提醒版本（Attention Revision）**:
同一待接手提醒在一次新信号到达后的不可变内容身份；用户阅读和操作对应这一版本。完整主会话身份相同的重复提醒可以更新版本，身份不完整的信号分别保留。
_Avoid_: 自动绑定最新内容、按项目名合并

**会话导航能力（Session Navigation Capability）**:
由宿主 adapter 证据决定的来源动作能力。未知或未经验证的精确 route 不能显示伪造的
“查看会话”成功；默认提供安全来源详情和复制有效会话 ID。
_Avoid_: 猜 URL、执行任意命令、把打开宿主 app 当作已进入会话

**本地活动摘要（Local Activity Summary）**:
由 `LocalActivitySummaryStore` 唯一持有的本地七日事实：只记录已确认 installation 的、能够映射到
公共 `Event` 的宿主回调，按发生时的本地 Gregorian 日期入桶，并以 `HostID × Event` 饱和计数保存。
Panel 与「活动与诊断」共享同一个 app-lifetime `ActivityDiagnosticsModel` 和
`ActivityOverviewProjector`；不得从最多 20 条 receipt history、播放结果或日志重新推算活动。摘要不保存
prompt、response、项目路径、provider、token、网络字节或音频路径，也不是完整用量、分析遥测或供应商账单。
摘要损坏、超限或锁忙时 fail closed；已有成功快照显示 stale，没有快照显示 unavailable。清除在专用锁内
原子发布空摘要并记录清除边界，迟到的清除前 delta 不会重新出现，且不触碰 activation marker、receipt、
receipt history、声音配置或诊断日志。近七日固定为今天和之前六个本地日期；切换时区不改写旧日期键。
_Avoid_: 用量分析、云端遥测、完整历史、以回执结果冒充活动、ElevenLabs 账单

**AI 提示音（AI Cue）**:
用户以自然语言描述、由外部生成服务创建并在明确采用后进入普通用户声音包的短音频。它可以是语音、动物叫声、纯音效或混合声音；`TTS` 只保留在历史文件名和原型路由中。
_Avoid_: 只称 TTS、AI 声音包、自动绑定

**声音描述（Sound Description）**:
用户对期望提示音的自然语言输入，是生成阶段唯一必填的创作输入。名称、事件 token、声音作用域和声音包身份都不属于声音描述，也不发送给生成服务。
_Avoid_: 提示词配方、提示音名称、事件文案

**内部声音方案（Internal Sound Plan）**:
Claudio 在本地从声音描述规范化出的、带版本的生成意图，包含声音类型、可选台词、风格和目标时长。它是 provider 路由与请求编译模块，不是用户必须确认的独立表单。
_Avoid_: 第二步表单、用户配置、持久化 prompt

**提示音候选（Cue Candidate）**:
同一次显式生成得到、尚未导入声音包的私有临时音频。候选必须完整通过大小、格式和时长检查；修改描述、重新生成、取消或关闭窗口会使未采用候选失效。
_Avoid_: 已安装声音、声音包文件、三个永久提示音

**候选身份（Cue Candidate Identity）**:
用户在一次生成中区分候选的稳定身份。身份可以表达真实参与生成的风格，也可以只表达服务返回顺序；编号候选不得伪装成未实际发送给服务的风格。
_Avoid_: 最终提示音名称、为编号候选虚构风格

**候选集合政策（Cue Candidate Set Policy）**:
某条 Provider 路线对候选身份语义、请求数量和最少可接受数量的统一约定。该政策属于路线；界面、生成引擎或 adapter 不得维护另一份候选规则。
_Avoid_: 全局三候选假设、界面临时放宽

**生成完整度（Generation Completion）**:
一次可展示候选集合的完整程度。`complete` 恰好包含三个有效候选；`partial` 只包含一至两个有效候选，且仅在所选路线的候选集合政策明确允许时成立。
_Avoid_: 导入部分成功、manifest 部分写入、任意残缺响应

**提示音采用目标（Cue Adoption Target）**:
一次采用操作捕获的 `HostSurfaceID`、公共 `Event` 和用户声音包 ID。三者在导入和绑定前必须重新验证，避免生成期间 UI 选择变化导致写入错误来源或声音包。
_Avoid_: 只传 Event、当前 UI 隐式选择、全局目标

**用户声音包（User Sound Pack）**:
可编辑且已安装的普通声音包，由用户拥有其 manifest 与音频。AI 提示音采用后只成为其中一个常规资产；「我的提示音」是可变的展示名称，不是独立数据库或特殊持久化层。
_Avoid_: AI 资产库、虚拟声音包、临时候选目录
