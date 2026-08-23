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
