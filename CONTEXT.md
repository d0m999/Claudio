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

**提示音采用目标（Cue Adoption Target）**:
一次采用操作捕获的 `HostSurfaceID`、公共 `Event` 和用户声音包 ID。三者在导入和绑定前必须重新验证，避免生成期间 UI 选择变化导致写入错误来源或声音包。
_Avoid_: 只传 Event、当前 UI 隐式选择、全局目标

**用户声音包（User Sound Pack）**:
可编辑且已安装的普通声音包，由用户拥有其 manifest 与音频。AI 提示音采用后只成为其中一个常规资产；「我的提示音」是可变的展示名称，不是独立数据库或特殊持久化层。
_Avoid_: AI 资产库、虚拟声音包、临时候选目录
