# TODOS

> **台账清理（2026-09-16，基于 `main` 9f363a4）**
>
> - 已对照当前生产 composition、源码、测试与提交历史，删除已解决、已被替代和只描述旧版非生产 UI 的条目。
> - 未标记且仍能在当前生产路径或待验收边界中复现的条目继续视为开放项。
> - 「源码 / harness 已通过」不等于 native SwiftUI、VoiceOver、真实 release 下载路径或正式验收；人工验收项继续保留。
> - 本文件保留原排期编号及逐项执行证据；已通过自动验收的项目与仍开放的人工、外部验收分开记录。

## 开发优先级（2026-09-16）

原排期共 **35 项：P1 6 项、P2 17 项、P3 12 项**。P1 六项的实现与仓库自动验收已完成；
P1-06 的真实焦点行为仍按 P2-10 做原生验收。P2 当前有 9 项完成仓库自动验收、8 项仍开放。
P1/P2/P3 是原执行优先级；
历史评审中的缺陷等级保留在原文，不与本轮排期混用。正文仍按领域归档，下面的索引是执行入口；
`TD-01` 至 `TD-35` 为本轮按原清单顺序分配的稳定引用编号，不随优先级变化重排。

| 优先级 | 数量 | 安排原则 |
|---|---:|---|
| P1 | 6 | 六项已实现并有自动回归；面板真实焦点行为继续由 P2-10 验收。 |
| P2 | 17 | P1 后推进：写盘与进程加固、核心回归缺口、原生及真实发布路径验收。 |
| P3 | 12 | 后续评估：潜伏形状、低收益整理、长期政策、新能力与条件触发的架构路线。 |

同级按表内顺序推进，硬依赖优先；没有依赖的任务可独立安排。条件尚未满足的验收项继续保留，
不阻塞其他可执行项。排期完成不代表代码修复或验收完成；每项开工先复现，再按对应合同验收。
P1 包含现有面板的 UI/交互修复；mixed 是 P3 新功能，NSPanel 是 P3 条件路线。

**P1 · 已实现与自动验收（6 项）**

| 顺序 | 原条目 | 当前状态与证据 |
|---|---|---|
| P1-01 | [TD-20 · `currentExecutablePath` 裸命令路径解析](#todo-20) | `6617b5d` 改用真实进程映像路径；`SetupSuite` 覆盖裸命令、链接、长路径和查询失败。自动验收完成。 |
| P1-02 | [TD-05 · `FileWriteWatch` 两处 fail-open](#todo-05) | `6617b5d` 将轮询失败显式报告，并观测悬空链接的目标目录；`OnboardingActionsSuite` 有故障与写入正向对照。自动验收完成。 |
| P1-03 | [TD-02 · `loadPanelConfig` 三次独立读取](#todo-02) | `6617b5d` 统一为单次有界快照；`PanelConfigSuite` 断言一次刷新只读一次。自动验收完成。 |
| P1-04 | [TD-33 · config 缺失时遗漏父目录权限探测](#todo-33) | `6617b5d` 对缺失配置检查父目录链；`ConfigMutationSuite` 同时核对 doctor 与写路径。自动验收完成。 |
| P1-05 | [TD-30 · panel presentation 不能由 harness import](#todo-30) | `6617b5d` 提取 `ClaudioPanelPresentation` 并在 GUI harness 注册 compiled suites。自动验收完成；原生 owner 保留。 |
| P1-06 | [TD-34 · 面板 config 失败态、焦点与错误寿命](#todo-34) | `6617b5d` 加入失败去重、焦点协调与错误寿命回归。代码与自动验收完成；原生焦点和 VoiceOver 仍属 P2-10。 |

以上自动证据不等于原生键盘、焦点或 VoiceOver 验收；详细条目的问题描述保留为修复前背景。

P1 修复提交为 `6617b5d`。在当前 `470e585` 上复核：GUI harness 9985/9985 通过；
helper 首轮 3455/3456，唯一失败为 `HostIntegrationModelSuite.swift:68` 的 NVM shim 探测，
顺序复跑 3456/3456 通过。保留首轮失败记录，不把复跑通过写成首轮全绿。

**P2 · 随后加固与验收（17 项）**

| 顺序 | 原条目 | 排期理由 / 执行边界 |
|---|---|---|
| P2-01 | [TD-04 · 推广真正的“不写盘”事件观测](#todo-04) | 在 P1-02 完成后逐路径增加正向对照，补齐数据保护回归。 |
| P2-02 | [TD-25 · manifest / import / config 的 symlink 与 TOCTOU](#todo-25) | 先保护 config 读写同一目标，再处理目录级竞态；与下一项共用设计。 |
| P2-03 | [TD-07 · 外部删除的 config 被原子写复活](#todo-07) | 与 P2-02 同批处理 config 写入边界，单独验收删除竞争。 |
| P2-04 | [TD-06 · install 备份先于乐观并发检查](#todo-06) | 收紧备份时机；保留原件与失败语义，不能只改注释算完成。 |
| P2-05 | [TD-03 · `play` 与配置写互不阻塞的行为测试](#todo-03) | 先提供隔离的路径锚点，再验证生产默认锁之间的关系。 |
| P2-06 | [TD-19 · `selected_pack` 控制字符与 ANSI 输出](#todo-19) | 小范围提高 setup / doctor 输出可信度，统一转义与长度限制。 |
| P2-07 | [TD-22 · `SystemCommandRunner` 超时后子进程回收](#todo-22) | 增加有界等待和强制回收，真实验证忽略 SIGTERM 的进程。 |
| P2-08 | [TD-28 · `ManifestBindError` 缺少恢复指引](#todo-28) | 为损坏用户包提供可执行出路；恢复操作仍须保留用户资产。 |
| P2-09 | [TD-21 · 升级后 legacy 坏 hook 与新条目并存](#todo-21) | 有自愈路径，但迁移会改变幂等合同；独立设计并保护第三方 hooks。 |
| P2-10 | [TD-26 · 默认关闭 FKA 的键盘焦点复验](#todo-26) | P1 面板修复后做原生验收；失败再决定焦点实现。 |
| P2-11 | [TD-29 · 试听与真实播放的音量曲线验证](#todo-29) | 主音量已存在，可直接做真实音频 A/B；先验证再决定是否改实现。 |
| P2-12 | [TD-17 · T3 fixture 承重条件的可执行验证](#todo-17) | 先实跑存活变异，再加针对性断言，为后续扫描器调整保留判别力。 |
| P2-13 | [TD-08 · T3 跨文件调度绕过并发检查](#todo-08) | T3 核心加固：围住完整同步事务，避免只扩充 token 黑名单。 |
| P2-14 | [TD-10 · T3 非 func 写入点不可见](#todo-10) | 与 P2-13 统一设计声明归属和隔离模型，再落地实现。 |
| P2-15 | [TD-09 · T3 private 放行可经闭包导出](#todo-09) | 依赖 P2-14 的非 func 模型，同批修复并独立验证逃逸形状。 |
| P2-16 | [TD-12 · T3 裸 regex 未建模](#todo-12) | 共享词法模型的缺口；为后续嵌套形状识别提供前提。 |
| P2-17 | [TD-18 · 真实下载后嵌套 helper 的 quarantine 验收](#todo-18) | 外部验收项；有真实 tag 下载候选时执行，不因排期自行发版。 |

**P2 执行记录（2026-09-16）**

实现提交为 `f74ad9e`；此后的 P2-01 测试补充仍在工作树。基线 `6617b5d` 的复跑结果：helper 3299/3299、GUI 9912/9912；此前记录的 GUI
`AICueHTTPTransportSuite.swift:435` 失败本轮未复现。以下“代码完成”只表示本地实现及对应
自动断言通过，不代表原生交互、真实音频、下载路径或正式验收。

| 项目 | 本轮代码 / 自动证据 | 尚需验收或实现 |
|---|---|---|
| P2-01 / TD-04 | helper 复制修复后的 `FileWriteWatch`；多种畸形 config 的写入拒绝、只读探测、setup 拒写及 GUI manifest 拒写有 `.untouched` 事件断言与同路径正向对照。提交后又补齐三条 setup 的 settings/config 断言，隔离同目录合法产物；helper 3447/3447 通过。 | 仓库自动验收完成；三条补充测试随本轮提交。 |
| P2-02 / TD-25 | `AnchoredFileIO` 固定目录 fd、保留 config symlink，并供 config、manifest、导入使用；链接改指向、父目录换位及导入冲突有回归。 | 外部写者的任意时序 CAS 与原生操作未获完整证明。 |
| P2-03 / TD-07 | 已有 config 用 `RENAME_SWAP`，初建用排他发布；读后删除、首次创建竞争、交换后外部替换有回归。 | 这是目标身份和删除保护，不宣称完整外部写者 CAS。 |
| P2-04 / TD-06 | 首次并发重验移至备份前，发布前保留第二次重验；晚期删除及现有备份合同回归通过。 | 真实跨进程短窗口仍需外部压力验证。 |
| P2-05 / TD-03 | 隔离子进程走生产默认锁路径，覆盖异锁不阻塞与同锁争用。 | 原生播放声音未由锁测试证明。 |
| P2-06 / TD-19 | setup、doctor、CLI `use` 共用终端安全显示；控制符、双向控制符与长度边界有回归。 | 无。 |
| P2-07 / TD-22 | 单调时钟、TERM/KILL 有界回收及独立清理失败结果；忽略 TERM 的真实子进程回归通过。 | 系统级极端回收失败只经结果接口覆盖。 |
| P2-08 / TD-28 | 声音包编辑器给出原位置、Finder、保留原件的修复步骤和重试；动作捕获失败时的包身份，切包失效有 compiled 回归。 | 原生布局、键盘、VoiceOver 尚未验收。 |
| P2-09 / TD-21 | 精确旧 hook 迁移、同组去重、第三方及未知字段保留、再次 install 幂等有回归。疑似旧命令身份不明时拒绝混装、保留原文件，并在 install 错误中提示人工检查；只读状态不报告已安装。 | 真实 Claude Code 设置界面的错误呈现与旧配置迁移仍需外部验收。 |
| P2-10 / TD-26 | 只读确认本机 `AppleKeyboardUIMode=0`。 | 默认关闭 FKA 的完整原生焦点与 VoiceOver 路径未跑，保持开放。 |
| P2-11 / TD-29 | 记录本机输出条件。 | 缺同设备同音频三轮 A/B 录制，无法判定 ≤1 dB 或决定是否更换试听适配器。 |
| P2-12 / TD-17 | 补了路径、污染扫描与检查数见证。 | 九处原始削弱及对应变异尚未逐项实跑，保持开放。 |
| P2-13～P2-15 / TD-08、TD-10、TD-09 | 锁内同步事务保留；独立进程锁争用和成功返回即读回通过。有限调用图加入跨文件同步调用、非 `func` 原语调用拒绝、公开闭包导出私有写者拒绝及纯私有辅助函数正向对照。 | 模型尚未覆盖任意调用形状、间接文件 I/O 或完整声明归属；九处 fixture 变异也未逐项实跑，三项继续开放。 |
| P2-16 / TD-12 | 两包共享扫描区区分注释、除法、裸 regex；不确定形状进入 `unmodeledConstructs`，回归通过。 | 有限词法模型不构成任意 Swift 程序证明。 |
| P2-17 / TD-18 | 文档改为签名、公证 DMG 的四阶段下载验收步骤。 | 没有适用的已授权下载候选，quarantine、签名和执行的真实下载证据仍缺。 |

本轮自动门禁：helper 3435/3435，GUI 9959/9959；GUI Debug 与 Release 产品构建通过；
`scripts/dev-bundle.sh` 的本机 arm64 ad-hoc bundle 签名及体积门禁通过（正规文件总计
9,481,303 B / 11,250,000 B）；本地化 catalog 可解析，`git diff --check` 通过，
相对 `6617b5d` 的严格 swift-format 诊断没有新增。提交前，固定 `BASE_SHA` 的
`verify-settings-experience.sh` 因工作树非干净 HEAD 按脚本合同拒绝运行；组成门禁已逐项
运行，当时不能称为通过了官方集成 gate。上述自动证据均不代表原生/外部验收。

提交后的干净检出已运行 `bash scripts/verify-settings-experience.sh 6617b5d` 并通过：
helper 3435/3435、GUI 9959/9959、两种配置的 settings target / GUI product 构建、
本机 arm64 ad-hoc bundle 签名和体积门禁均通过；严格格式诊断没有新增。
此结果绑定 `f74ad9e`，不包含随后工作树中的 P2-01 测试补充；后者另由 helper 3447/3447 验证。

**P2 状态复核：**P2-01～P2-07、P2-09、P2-16 已完成各自的仓库自动验收（9 项）。
P2-08、P2-10～P2-15、P2-17 仍开放（8 项）：分别缺原生恢复体验、默认关闭 FKA 焦点、
真实音量 A/B、九处 fixture 变异，以及 T3 声明/引用与逃逸模型的剩余实现和独立验收、
正式下载候选的 quarantine 证据。`f74ad9e` 不能被称为 17 项全部闭合。

**P3 · 后续与条件触发（12 项）**

| 顺序 | 原条目 | 排期理由 / 执行边界 |
|---|---|---|
| P3-01 | [TD-11 · T3 自证的 root 差异](#todo-11) | 成本高的自证增强；核心围栏加固后再评估真实 checkout 变异 smoke。 |
| P3-02 | [TD-16 · T3 pathPrefix 与 subpath 联合差异](#todo-16) | 与 P3-01 同根因、同批评估，避免另建一套自证机制。 |
| P3-03 | [TD-13 · T3 运算符与 Unicode 函数名假红](#todo-13) | 当前台账记录为未使用形状；出现实际阻塞时提前。 |
| P3-04 | [TD-14 · T3 合法私有 / 嵌套形状假红](#todo-14) | 先完成 P2-16；引入相关形状时再扩展，不能以放宽检查制造假绿。 |
| P3-05 | [TD-15 · T3 形状表与诊断文本未同源](#todo-15) | 可维护性改进，可随同区域修改处理，不单独抢占核心修复。 |
| P3-06 | [TD-32 · AtomicWrite 围栏词汇表与 SwiftSyntax 路线](#todo-32) | 先比较依赖成本与可证明边界；不把引入 AST 等同于完整写入证明。 |
| P3-07 | [TD-31 · 断电持久化分级策略](#todo-31) | 先明确产品保证和成本；当前不能承诺完整掉电安全。 |
| P3-08 | [TD-23 · claude-version 超时与 env 路径常量](#todo-23) | 纯重复常量整理，随相关模块修改处理。 |
| P3-09 | [TD-24 · Setup 点前缀的 Unicode 判定粒度](#todo-24) | 下游已有拒绝保护，低收益一致性修正。 |
| P3-10 | [TD-35 · `forkPack` 副本名称措辞](#todo-35) | 纯产品文案决策，定稿后同步代码与断言。 |
| P3-11 | [TD-01 · SenseAudio mixed 新能力](#todo-01) | 独立产品里程碑；先确定合同与范围，再做单独授权的付费及听感验收。 |
| P3-12 | [TD-27 · NSPopover 改 NSPanel 的条件路线](#todo-27) | 有真实丢字反馈再启动，先做 AX 探针并确认窗口设计。 |

**依赖与批次约束**

- P1-02 → P2-01：先修 `FileWriteWatch`，再复制和推广；每个“不写盘”断言保留正向对照。
- P1-03 / P1-04 共享配置探测上下文；P1-05 提供面板 compiled 接缝后，完成 P1-06 的呈现回归。
  面板接缝只覆盖所需 presentation，不把整个 native app 抽离当作缺陷修复前置。
- P2-02 / P2-03 统一 config 写入设计，分别关闭 symlink、外部删除和目录竞争的验收项。
  config 的“读目标、写链接”不需要提权即可发生，不再把“未来提权”作为整条任务的启动条件。
- P2-12 至 P2-16 作为同一批 T3 工程设计，保留五项独立验收；先测现有变异与误报，再决定
  深化同步写接口或调整扫描模型。P3 的 SwiftSyntax 选型可一并评估，但不作为默认前置或已定方案。
- FKA、真实音量与 quarantine 分别记录原生/音频/发布证据；自动 harness 不替代这些验收。
  首个适用的真实 release 下载候选出现时执行 P2-17；当前只排期，不新建 tag 或发布。

**本轮校正的依赖事实**：`.github/workflows/ci.yml` 已配置 helper 与 GUI harness，T3 的 `root`
自证不再依赖一项已删除的“CI 不跑测试”任务；待补的是对应端到端变异验证。主音量已接入生产面板，
音量曲线任务剩余的是实际音频验证。以上来自当前源码/配置核对，不表示本轮运行过 CI 或人工验收。

## AI 提示音

<a id="todo-01"></a>

### SenseAudio `senseaudio-a1` mixed 生成路线留待独立设计与验收

**What:** 当前 `senseaudio-cn` 用 `sensenova-tts-2.0` 处理 `speech`，并用
`senseaudio-sfx-1.0-260626` 处理 `animal` / `soundEffect`；`.mixed` 在读取凭据或发网络前明确
fail closed。不要把一段同时含台词和背景声的描述拆成两次请求后本地拼接，也不要把 TTS 或 SFX
单路线伪装成 mixed。

**Why:** `senseaudio-a1` 可能提供更自然的混合音频路线，但它不属于当前三秒提示音合同，尚无固定
endpoint/model/输出格式、费用、留存、候选集合语义和真实听感证据。提前加入现有 profile 会扩大
数据与计费边界，并让无法由 fixture 证明的音频语义看起来已经受支持。

**修复方式:** 作为独立里程碑核对官方合同，固定不可由用户编辑的 route，补齐请求/响应/错误 fixture、
三秒和 5 MiB 本地校验、凭据与 retry 语义，并在单独授权的付费 smoke 和人工听感验收通过后再决定
是否加入 `senseaudio-cn`。不得用该路线绕过 ADR 0014 固定的 SenseAudio SFX 资源 policy，也不得自动
fallback。

**Effort:** L
**Priority:** P3（P3-11）
**Depends on:** `senseaudio-cn` TTS + SFX 完整合同、ADR 0014 固定资源 policy 与真实 Provider 验收

## Ship / CI

<a id="todo-02"></a>

### `loadPanelConfig` 每次调用把 config.json 独立读三遍 —— 文档写的「一次读 + 一次目录 stat」和实现对不上

**状态（2026-09-16）：**已由 `6617b5d` 修复并有单次快照的 compiled 回归；下文是修复前问题描述。

**What:** D23 把面板的 config 判定拆成「写」「读」两条正交轴（`probeConfigRewritable` + `packSelection`），
再加上最后 `loadClaudioConfig` 解码一次 —— `loadPanelConfig` 在 happy path 上因此对同一个 `configFile` 各自
独立做了三次 `fileExists`/`open`/`read`/解析，而不是文档里 `PanelRefreshRoute.swift` 对 `.configOnly` 成本的
描述（「代价 = 一次文件读 + 一次目录 stat」）。三次读之间没有共享同一个字节缓冲区，也没有加锁（读端本来就
不占锁，这是既有约定），所以理论上一次外部并发写可能落在三次读之间，让三个判定基于不完全一致的磁盘内容
（红队复核：影响自限——下一次真正写盘会重新校验并诚实拒绝，不丢数据，只是这一次面板渲染可能对不上磁盘
当下状态）。

**Why:** `/ship` pre-landing review 的 performance specialist + red-team 两条独立路径都命中了同一处
（`gui/Sources/ClaudioGUICore/PanelConfig.swift:72`），confidence 都不低。不是这条分支要解决的问题（这条
分支的目标是「切包 + 路由」的行为正确性，已经用五轮红队 + 两次独立对抗验证钉死了），但发现的时候文档
与实现已经对不上号，值得单独一轮修，而不是为了赶这次 ship 临时改三个文件的函数签名。

**Context:** 2026-07-14 `/ship` pre-landing review（performance + red-team 双命中，parent 已用 `git diff`
逐行核实为真）。修法：给 `probeConfigRewritable`/`packSelection`/`loadClaudioConfig` 各配一个接受
预读 `Data` 的内部重载，`loadPanelConfig` 只在最外层读一次文件、把字节传给三个判定复用。

**Effort:** S
**Priority:** P1（P1-03；性能影响可忽略，正确性影响自限且无数据丢失；但文档与实现的说法已经不一致）
**Depends on:** None

<a id="todo-03"></a>

### 剩余的行为级缺口：`play` 与设置写之间的「互不阻塞」，仍然只有人工读码背书

**What:** 现有测试只证明「**每个写者拿的是递给它的那把锁**」（注入锁 + 持锁争用，够了）。它证明不了的是另一半：
**「持有 play.lock 时点静音仍然成功」** —— 也就是分锁要兑现的那个行为本身。

**Why:** 这一半要有牙，就必须锚定**生产默认值**（真实的 `~/.claudio/play.lock` 与 `~/.claudio/config.lock`）——
用两个临时路径去测它，断言从写下第一天起就恒真（两个不相干的路径本来就互不阻塞），正是 D30 判定「测不到东西」
的那类假绿。**这一条的前置条件是真的，上一条的不是**：区别在于前者断的是「两把锁之间的关系」（需要真锁），
后者断的是「这条代码路径用了哪把锁」（注入锁就够）。

**Context:** `ClaudioPaths.root` 锚在 `FileManager.default.homeDirectoryForCurrentUser`，**没有任何可覆盖的注入口**，
而 Darwin 上 `$HOME` 会被忽略 —— 这类测试会真实地碰到当前用户的 `~/.claudio/`。所以前置条件是**先给
`ClaudioPaths.root` 一个可覆盖锚点**，那是一次独立的基础设施改动。

今天仍靠人工读码确认（`play` 读 config 在锁外；config 写是原子 rename；`play` 从不读 settings.json），
**回归时没有灯会灭**。

**Effort:** M
**Priority:** P2（P2-05）
**Depends on:** `ClaudioPaths.root` 需要先获得可覆盖锚点（独立 PR，不要混进阶段 B 主音量滑块）

<a id="todo-04"></a>

### 全仓还有十几处「一个字节都不写」，背书它们的仍然只是**字节比较** —— 而字节比较看不见「写了又擦回去」

**What:** `/codex review ee026db` 的 P2 指出：`fileBytes(after) == fileBytes(before)` 只证明**终态相同**，
而写着这句话的失败消息声称的是「**一个字节都没被碰过**」。一个「写完再回滚」的实现（写下去 → 撞上锁 →
把文件删/改回去）能让前后逐字相同，字节比较**全程绿**。

这一条已在 **settings.json 的四条持锁路径**上治好了：`FileWriteWatch`（`gui/Tests/…/TestSupport.swift`）
观测的是**事件**而不是状态差 —— 目录级 kqueue（`NOTE_WRITE|NOTE_DELETE|NOTE_RENAME`）逮住创建 / 原子替换 /
删除，`stat(2)` 的 **ctime** 逮住「非原子的原地重写」（ctime 是 userspace 唯一伪造不了的字段：`utimensat`
能把 mtime 按回过去，那一次调用自己却会把 ctime 顶到「现在」）。

**没治的是同一族的其余声称**，它们今天全靠字节比较：
`helper/Tests/ClaudioCoreTests/ConfigMutationSuite.swift`（`:126`、`:754`「fail closed 的含义是一个字节都不写」，
`:686` 只读探针）、`SetupSuite.swift`（`:564`、`:791`、`:1065` 失败路径必须逐字保住用户的 config / 文件）、
`gui/Tests/ClaudioGUICoreTests/ManifestBindingSuite.swift:302`（「一个字节都不写」）。

**Why:** 严重性**低于** settings.json 那一族，而且理由是具体的、不是感觉：settings.json 有**不遵守
claudio 任何锁的并发读者**（Claude Code 每个事件都读它），所以那里的「窗口期」真的会被别人看见；上面这些
路径上的 config.json / manifest 的并发读者是 claudio 自己，且都走原子 rename。**但这只是把风险降级，没有
消灭它**：一次「写了又回滚」的窗口里，一个并发的 `claudio play` 照样可能读到半途的 config.json。

真正的理由是：**这些断言的措辞，仍然比它们的覆盖范围大** —— 而这个仓库连着十一次栽在同一件事上。

**修复方式:** `FileWriteWatch` 是现成的，把它按「按包复制而非跨包共享」的约定抄一份进
`helper/Tests/ClaudioCoreTests/TestSupport.swift` 即可。⚠️ 两条硬约束，抄之前先读它文档里「它不兜什么」那节：
① 目录那一半会因**同目录里的其它写者**假阳（`~/.claudio/` 在接管期间一直在被写：二进制、声音包、两把锁文件），
所以它只能用在被观测文件是该目录唯一写者的时刻；② **每加一个用它的断言，都必须同时有一条正向对照**证明观测器
在那条路径上真的会响 —— 一个观测不到写的观测器，会把每一条「没被碰过」变成恒真，那正是它要杀的病升了一层。

**Effort:** M（每条断言都要配一次定向变异验证，不能批量替换了事）
**Priority:** P2（P2-01）
**Depends on:** [TD-05：`FileWriteWatch` fail-open 修复](#todo-05)；完成后才能复制进 helper 或推广断言

<a id="todo-05"></a>

### `FileWriteWatch` 自己有两处 fail-open —— 一个观测不到写的观测器，会把每一条「没被碰过」变回恒真

**状态（2026-09-16）：**已由 `6617b5d` 修复；轮询故障和悬空链接目标变化均有正向对照。

**What:** `/codex review 96ed71c` 的两条 P2，都打在 `FileWriteWatch`（`gui/Tests/…/TestSupport.swift`）身上 ——
即上一条 TODO 指望「抄一份进 helper」的那个工具。**抄之前必须先修，否则是把两个洞抄成四个。**

① **`kevent` 轮询失败被折叠成「没有目录事件」**：`sawDirectoryEvent = kevent(queue, nil, 0, &event, 1, &immediately) > 0`
—— 返回 `-1`（`EINTR`、fd 被意外关闭/复用）和返回 `0`（真的没事件）走进**同一个分支**。`isArmed` 只兜得住
**注册时**失败（7 处调用点都断言了），三条正向对照只兜得住**系统性**失明；谁都兜不住持锁 suite 真实跑的那一次
**观测时**的 syscall 错误。而对 `nil → 写入 → 删除 → nil` 这类**正是它存在理由**的回滚窗口，身份快照也相等 ——
于是断言静默变绿。零超时的 `kevent` 撞 `EINTR` 概率极低（不阻塞就没有可中断的睡眠），所以现实风险小；但这个
文件通篇的论点就是「观测器必须 fail closed」，而它唯一能失败的 syscall 恰恰 fail open。

② **dangling symlink 下两半同时瞎**：`settings.json` 是一条指向 dotfiles 的符号链接、而**目标不存在**时，
`identityBefore = FileIdentity(of: file)` 走 `stat` → `nil`；穿链接的写落在 `dotfiles/`，未解析的 `dot-claude/`
目录项一个都没动 → 目录 kqueue 全程安静。写 → 回滚删掉目标 → 终态又是 `nil`。**两半同时看不见。**
而这个形状不是臆想：`SettingsInstallerSuite.swift:1277` 明确把「dangling settings.json symlink = 普通全新
安装路径」钉成了**生产支持的行为**。新增的「写观测器③」用的是**目标已存在**的链接 —— 它钉的是 `stat` 的跟随
语义，钉不到「before 就是 `nil`」这一支。

**Why:** 今天**没有**任何断言因此假绿（四条持锁 suite 的 fixture 都是正规文件），所以不阻断 `96ed71c`。但工具
文档里那节「**它不兜什么**」**没写 ②** —— 措辞又一次比覆盖范围大，而这一次是在专门用来杀这个病的工具自己的
文档里。下一个人照着那节的承诺去用它，洞就跟着他走。

**可能的修法:** ① 把 poll 结果**三分**为 event / no-event / error：`> 0` → 有事件；`== 0` → 没事件；`< 0` →
`expect(false, ...)` 当场红（fail closed）。三行。② 在「它不兜什么」里写清 dangling symlink 这一支，并补一条
正向对照（dangling link + 穿链接写 + 回滚 → 必须被看见），修法大概是身份快照那一半改成「`stat` 目标 + `lstat`
链接本身」两个快照都拍。

**Effort:** ① S（三行 + 一次定向变异）/ ② M（新对照 + 两轮台账）
**Priority:** P1（P1-02；不阻断本分支；**但阻断「把 FileWriteWatch 抄进 helper」那条 TODO** —— 别把洞抄一遍）
**Depends on:** None

<a id="todo-06"></a>

### 一次性备份写在乐观闸门**之前** —— 一次 `.concurrentModification` 中止会留下一份 install 从没写过的永久备份

**What:** `installClaudioHooksLocked` 的顺序是 `backupOriginalIfNeeded`（`:317`）→ `atomicWrite`（`:322`，
里面才做 `expectedCurrentData` 的乐观并发重读）。于是：外部写者（Claude Code 自己 / 用户的编辑器）在读与写之间
改了 `settings.json` → `atomicWrite` 正确地中止并返回 `.concurrentModification`、**一个字节都没写** —— 而
`.claudio.bak` **已经落盘了**，且按「一次性备份」的纪律**永不刷新**。

于是 `SettingsInstaller` 类头那条不变式是**假的**：「the pre-claudio original is copied to
`settings.json.claudio.bak` **the first time `install` actually writes**」—— 它可以在 install **从没写过**的
情况下就存在。

**Why:** 行为影响比「备份非原子」那条小得多（已修：`options: .atomic`）：备份的**内容**仍然是 claudio 真实
读到的那份原件（`loadRoot` 的 `rawData`，不是重读的），所以它不是坏数据，只是**时机**不对 —— 它记录的是一次
被中止的 install 所看到的世界。真正要紧的是那句类头注释**在撒谎**，而这个仓库的规矩是：假注释就是 bug。

**可能的修法:** 把乐观闸门从 `atomicWrite` 里拆出来、提到 `backupOriginalIfNeeded` **之前**跑；或者退一步，
只把类头 `:26-27` 那条不变式改成实话（「the first time install **attempts** a write」）。前者是真修，后者是
止损 —— 但**别只做后者然后当成修好了**。

**Effort:** S（改注释）/ M（拆闸门）
**Priority:** P2（P2-04）
**Depends on:** None

<a id="todo-07"></a>

### `updateConfigJSON` 的残余 TOCTOU：读完之后被外部删掉的 config，会被 `.atomic` 写**复活**（且报 `.success`）

**What:** `ConfigMutation.swift` 仍是 `fileExists` → `readConfigFileBounded` → `mutate` → `encode` → `data.write(.atomic)`。一个**不拿 `config.lock`** 的进程（用户手动 `rm`、清理工具、同步冲突）如果在**读成功之后、rename 之前**删掉 `config.json`，`.atomic` 的 temp+rename 会照常把文件**重新创建**出来 —— 内容是刚才读到的那份旧 config（加上本次的改动），并向调用方报 `.success`。用户以为自己删掉了 config，它却自己回来了。

**Why（先把措辞更正了）：** `573336d` 的提交信息写的是「判定与新建落在**同一次** `fileExists` 上，**那个窗口跟着一起没了**」。**这句话比它的覆盖范围大**（`/codex review 573336d` [P2] 独立指出，本人复核确认）。真正没掉的是**空串新建**那个窗口：调用方先探一次 `fileExists`、`updateConfigJSON` 内部再探第二次，两次之间的外部删除会让空串照常落盘。那一刀确实砍掉了（毒源在**类型层面**消失，`.failClosed` 的调用方递不出能落盘的 pack id）—— 但「TOCTOU 窗口关闭了」这个**广义**说法不成立：读→rename 之间那个窗口还在，它只是不再产毒了（复活的是旧内容，不是空串）。

危害比原来的小一个量级（没有毒源，只是一次不该发生的复活），但**措辞必须与覆盖范围对齐** —— 这个仓库栽在「headline 比覆盖范围大」上已经不止一次（见本文档「⚠️ 本条首版写的是…那是**假的**」几处）。

**Context:** 2026-07-13 `/codex review 573336d`。真修 = 与「GUI 写/读路径的同用户 symlink TOCTOU」那条的 config 侧加固**同一处**：写前解析 symlink + 乐观并发重读（读到的字节 vs 写之前重读的字节，不一致就 `.concurrentModification` 中止 —— `SettingsInstaller.swift:619` 对 `settings.json` 已经是这个形状，config 侧照抄即可）。三条并作一处改。

**Effort:** M
**Priority:** P2（P2-03；需要一个不拿 config.lock 的外部写者，恰好落进读→rename 那几微秒；且后果是「旧 config 复活」，不是数据损坏）
**Depends on:** None

<a id="todo-08"></a>

### T3 判定腿之二（并发黑名单）仍是**白名单探针** —— 跨文件调度可绕过锁作用域检查

**What:** `SourceScannerSuite.auditManifestConcurrencyFence` 只把含 `mutateManifestJSON` 字样的文件纳入并发 token 检查。若以后把真正的异步调度或裸文件写移到另一个 helper 文件，原文件只保留一次看似同步的 helper 调用，那么原文件没有 `Task` / `await` / `DispatchQueue`，helper 文件又不含原语名，两边都能静默通过。

**Why:** 当前生产实现已有 `packs.lock`，并把 `performManifestMutation` 完整放在锁闭包内。剩余风险是一次重构把真实 I/O 安排到锁闭包返回之后，使锁只保护“安排任务”而不保护读改写。现有单文件白名单无法证明这件事没有发生。

**修复方式:** 将并发/写盘检查扩到整个 target，或把“锁闭包内执行完整同步事务”做成更深的不可异步接口并补行为级竞争测试。只往 token 清单里加 `await` 不能解决跨文件调度。

**Effort:** M
**Priority:** P2（P2-13）
**Depends on:** None

<a id="todo-09"></a>

### T3 修饰符白名单放行 `private`，靠的是一条**被实测证伪**的前提

**What:** `unrecognizedFuncDeclarations` 的白名单第二格放行 `private` / `fileprivate`。放行的理由
原本写的是「私有函数出不了这个文件，而这个文件里每一个出得去的声明都已被『导出写函数都得
@MainActor』钉住 ⇒ 私有函数只可能从已隔离的代码里被调到」。**那句推理是假的**，红队实测打穿：

```swift
public let escapeHatch: () -> Void = { privateFlush() }   // 公开闭包属性，把私有函数带出文件
private func privateFlush() { mutateManifestJSON() }      // 白名单放行，零 finding
```

闭包属性不是 `func`，不进任何一台识别器；它捕获的私有函数于是从**任意线程**都可达。实测该
fixture 产出 **0** 条 finding。

**Why:** 这一格**不能简单删掉** —— 真仓库 `ManifestBinding.swift` 里的
`private func resolveUserPackDirectory` 会当场假红，而本文件开头记着的病就是「假红的守卫会被
下一个人删掉」。所以现状是一个**权衡**，不是一条证明。已经把 doc comment 里那句假推理改掉了，
但缺口本身还在。

**Context:** 2026-07-20 `/codex review 48cbc07` 之后那轮红队（9 agent × 三视角）实测。
注意这条与「判定腿只数 `func`」是同一个根因的两个面：都是「非 `func` 的声明形态不进识别器」。

**可能的修法**（未定）：与「只数 `func`」那条一起修 —— 一旦识别器能看见闭包属性 / 计算属性这类
声明，`private` 那格就可以从「无条件放行」收紧成「放行且文件内没有把它导出去的闭包属性」。
单独修这一条不划算。

**Effort:** M（与「只数 `func`」合并修）
**Priority:** P2（P2-15）
**Depends on:** 「T3 判定腿只数 `func`」

<a id="todo-10"></a>

### T3 判定腿只数 `func` —— 计算属性 / subscript / init 里的写入点，四条腿一条都看不见

**What:** 2026-07-20 把 @MainActor 腿在「`func` 声明的修饰符形态」这根轴上升成了围栏（认不出 ⇒ 红）。
但那台标尺数的是 **`func` 声明**，于是**一切不是 `func` 的写入点全部隐身**。红队实测（临时探针，
跑完即删）：

```swift
// 一个被纳入的文件里：
@MainActor public func probeClean() { _ = 1 }
public var probeTrigger: Int { mutateManifestJSON(); return 1 }   // ← 计算属性 getter
```

这个文件产出的 finding 数是 **0**。逐条走一遍：`unmodeledConstructs` 空；并发 token 空；
`exported.isEmpty` 为假（`probeClean` 顶着）；`func` 声明总数 1 = 识别数 1，没有差额；
`missingMainActorIsolation` 只遍历枚举得到的名字。**四条腿一条都没响**，而那句读-改-写就在
`probeTrigger` 的 getter 里，任意后台线程读一次这个属性就同步触发它。

同一根轴上的同一个洞还有：`subscript`、`init` / `deinit`、`willSet` / `didSet`、属性的
`_read` / `_modify` 协程访问器。全部隐身。

**Why:** 「把写入点从函数挪进计算属性」不是刁钻构造 —— 它就是「让调用方写起来顺手一点」这个念头
的自然结果。而这条洞比修饰符那条更隐蔽：修饰符那条至少还是个 `func`，读代码的人扫一眼能认出「这是
个写者」；计算属性长得像一个**读**。

**要害仍然是措辞。** 本轮的 headline 若写成「围栏 fail-closed 补齐」，就是第九次应验
`fence-polarity-and-self-recurrence` 那条 memory —— 补齐的是**一根**轴，不是「补齐」。
`unrecognizedFuncDeclarations` 的 doc comment 里已经把这条逐字写下来了，这里登记的是同一件事。

**Context:** 2026-07-20 修 `/codex review 48cbc07` P1 之一时自查发现（Codex 没提这一条，是本轮
红队自己打自己那一刀打出来的）。

**可能的修法**（未定）：判据的**量纲要换** —— 从「数 `func` 声明」变成「找出所有能含语句的括号块，
每一个都得落在某个已知隔离的声明里」。那是重设计不是补一刀，而且假红面会大得多（每个计算属性都
要标注或豁免），需要先在真仓库上量一次代价。退一步的便宜档：把纳入判据从「文件含原语名」升级后
（见上一条 ②），顺带对**含原语的那几行**做一次「它落在哪个声明里」的定位，认不出归属 ⇒ 红。

**Effort:** L
**Priority:** P2（P2-14）
**Depends on:** None

<a id="todo-11"></a>

### T3 围栏的自证闭不上 `root` 这根轴 —— 一句按扫描根判真假的谓词能让生产静默失效而自证全绿

**What:** 围栏的两条自证 suite（消费边有牙、内容判定有牙）都必须把脏 fixture 写进一棵**临时树**，
而生产路径恒定喂**真仓库根**。于是任何「在临时根下为真、在生产根下为假」的谓词都能寄生：

```swift
// enforceManifestConcurrencyFence 里，消费循环加一个 where：
for finding in audit.findings where !root.path.hasPrefix("/Users/d0m999/Desktop/Claudio") { … }
```

自证喂的是 `/var/folders/…/T/…` ⇒ 照样全红；生产喂的是仓库根 ⇒ **一条 finding 都不消费**。
`git diff` 只显示函数体里多了个 `where`，调用点一个字符没动，所以「消费边接线自证」那条钉哨兵区块
逐字全等的 suite 也不会响。

**Why:** 这是 `fence-polarity-and-self-recurrence` 那条 memory 记的「同一个函数 ≠ 同一个实参向量」
的**第四层**：前三层（同一个 helper ≠ 同一条边、同一条边 ≠ 连消费一起、同一个函数 ≠ 同一个实参
向量）都已经收窄过，`pathPrefix` 那根轴现在两侧逐字相同。`root` 是**剩下的最后一根**，而它结构性
地闭不上：自证必须造脏输入，生产必须扫真代码，两者不可能喂同一个 `root`。

**Context:** 2026-07-20 `/codex review 48cbc07` 的 P1 之三。代码里 `绊线（T3）围栏消费边自证有牙`
那条 suite 头上的注释**已经逐字承认了这一条**（「仍然诚实的限度：`root` 这根轴闭不上 …… 收窄了，
没清零」）—— 这里登记的是同一件事，不是新发现。登记的理由是：它写在一段散文里，而散文不会变红。

**可能的修法**（未定，且都不便宜）：
- 把生产根也变成一个**注入点**，让自证能喂一棵「真仓库的只读快照 + 一个脏文件」的合成树 —— 那样
  两侧的 `root` 形状同构，`hasPrefix` 这类谓词失去分辨力。代价是围栏要多一层间接，而**多一层间接
  就是多一个可改的接缝**（这正是 `15ce131` → `36fce57` → `48cbc07` 三轮反复踩的那个坑）。
- 或者接受它，转而在**别处**兜底：一条 CI 侧的「把一个已知脏写者塞进真仓库、断言 suite 真的红」的
  端到端冒烟。当前 `.github/workflows/ci.yml` 已配置两套 harness；剩余工作是在隔离 checkout 中
  注入已知违规、确认生产入口确实报错，并清理注入。不能在共享工作树中污染真实源码。

**Effort:** L
**Priority:** P3（P3-01）
**Depends on:** 现有 CI harness 已配置；若走端到端路线，需为本条补隔离 checkout 的变异 smoke

<a id="todo-12"></a>

### T3 扫描器不建模**裸 regex 字面量** —— 它既不记账，又是唯一能把反引号贴到 `func` 左边的通道

**What:** `strippingComments` 建模 `#/…/#`，但**裸**的 `/…/`（Swift 5.7 regex 字面量）既不被建模、
也**不**记进 `unmodeledConstructs`（实测 `unmodeled=[]`）。后果有两面：

```swift
let probe = /`func mutate/       // swiftc -swift-version 6 -typecheck rc=0
```

- 它是**唯一**能让一个反引号紧贴 `func` 左边的合法通道，于是它成了「关键字计数与名字解析是不是
  同一份词素」的判别输入 —— 两台一旦漂移，它凑出的 ±1 会去**抵消**一个真实漏网声明的 ±1
  （实测：只给关键字那台加 lookbehind，一条现存的红当场变绿）。本轮靠 `funcKeywordLexeme`
  单源 + `LexemeSync.swift` fixture 把这条通道钉住了。
- 但**根因没修**：扫描器对裸 regex 字面量整体失明。今天真扫描根里零处（实测 `func ==` /
  `private extension` / `private import` / 反引号标识符**四类全为 0**），所以是潜伏项。

**Why:** 「认不出 ⇒ 记账」是这个扫描器其余部分一致遵守的极性，这里破了例 —— 而破例的地方恰好是
围栏两台计数器的**公共前提**。

**Context:** 2026-07-20 `/codex review abbf48e` 之后那轮红队。

**可能的修法：** 在 `strippingComments` 里把裸 `/…/` 记成 unmodeled。代价是要动 shared-scanner
区块（gui / helper 两包逐字节同步），且 `//` 注释与 `/regex/` 的消歧是真词法问题（除法也用 `/`）。
别顺手做。

**Effort:** M
**Priority:** P2（P2-16）

<a id="todo-13"></a>

### T3 判定腿对 `func ==` 与 Unicode 函数名是**恒假红**，而诊断给的补救对 `==` 物理上做不到

**What:** `allFuncDeclarationNames` 只认 `[A-Za-z_]` 打头的名字，于是运算符声明
`public static func == (l: K, r: K) -> Bool` 与 `public func 播放()` 都解析不出名字，被「标尺自查」
那条腿判成「连名字都认不出来」⇒ 红。两者 swiftc rc=0，是合法真代码。

方向是**安全侧**（红而不是绿），而且今天真扫描根里 `func ==` 为 0，所以不阻断。但诊断给的补救是
「把那个声明改成普通标识符命名的 `public func` 并标 `@MainActor`」—— 对 `==` 这是**做不到**的：
`Equatable` 要求的就是那个名字。一条无法遵循的红，就是下一个人删腿的理由（本文件反复在治的
「假红的守卫会被删掉」）。

**Context:** 2026-07-20 `/codex review abbf48e` 之后那轮红队，实测两者各 `diff=1`。

**可能的修法：** 给标尺补一格「运算符声明 / 非 ASCII 标识符」的识别器（认得出 ⇒ 交给隔离检查，
而不是判成认不出）。注意它必须与 `funcKeywordLexeme` 共用词素，否则就是本文件刚修掉的那个漂移。

**Effort:** M
**Priority:** P3（P3-03）

<a id="todo-14"></a>

### T3「认不出 ⇒ 红」对四类合法私有形状恒红 —— 这是**主动选择**的代价，不是没看见

**What:** 下面四类合法 Swift 今天一律变红（各有 fixture 钉着，见 `SourceScannerSuite` 的 ⑰）：

> ⚠️ 2026-07-20 更正：这句「各有 fixture 钉着」在 `ae494b1` 写下时**是假的** —— `enum` /
> `final class` / `actor` 三种当时一条 fixture 都没有，只有 `private struct` 有。`/codex review
> ae494b1` P2-2 打出来，同一提交补齐（⑰ 现为七行）。**这条 TODO 自己就是「措辞比覆盖范围大」
> 的又一次复发**：台账在替一份不存在的覆盖背书，而它正是用来记录覆盖边界的那份文件。

```swift
private extension Foo { func helper() { mutateManifestJSON() } }      // 及 fileprivate extension
private struct Batch  { func apply()  { mutateManifestJSON() } }      // 及 enum / final class / actor
@MainActor public func outer() { func inner() { mutateManifestJSON() } }   // 函数体内的局部 func
```

识别器是**词法**的，只看紧贴 `func` 前面那一段修饰符 run，跨不过外层的 `{`。

**Why 没把它们白名单化：** 提过一个方案（识别 `private extension` 块、把块内成员纳入白名单），
红队实测**否决**：那需要一台括号匹配器，而括号匹配会被一个裸 regex 字面量 `/^\s*\{/`（上一条：
不记 unmodeled、其自身括号配平）带偏而**过冲**，吞掉整块 `public extension` 里的非 `@MainActor`
写者 —— 放宽白名单却造出一条实测可达的 masking 路径，教条「放宽必须证明没有 masking 路径」
满足不了。且该方案只覆盖四类里的一类，达不到自己的立论。

所以本轮改为**保持红、把红修得可执行**：诊断逐字列出全部七种落点，并把补救从「标 `private` 收回
本文件」（对 private-extension 成员毫无意义 —— 它本来就是私有的）改成「把修饰符写在**成员自己
头上**」。

**⚠️ 顺带再破一次「私有一定安全」那条前提**（本文件 519 行那条已经记过一次）：
`@objc` 标注的 `private extension` 成员经 ObjC runtime（`perform(_:)` / target-action / `NSTimer`）
从**任意 run loop** 可达 —— 实测 swiftc rc=0。所以 `private` 那格白名单是**权衡**，不是证明。

**Context:** 2026-07-20 `/codex review abbf48e`（原报为 P2 假红）+ 之后那轮红队的否决。
今天真扫描根里这四类均为 0 处，是潜伏项。

**Effort:** L（要先给「括号嵌套」这根新读模型轴造正向对照 —— 现有 `unmodeledConstructs` 是**词法**
台账，守不住它）
**Priority:** P3（P3-04）
**Depends on:** 「T3 扫描器不建模裸 regex 字面量」

<a id="todo-15"></a>

### T3 形状表与诊断串**未同源** —— 覆盖锁只挡得住「删行」，挡不住「诊断长出新形状」

**What:** `SourceScannerSuite` 里三张形状表（⑦⑧⑧b 四行 / ⑩ 两行 / ⑰ 七行）各自镜像一条生产诊断串
里**逐字列出**的形状清单。2026-07-20 给三张表都加了 `expectShapeTableCovers` 覆盖锁，堵住了红队
实测的那条变异（删任意一行 → 修前全绿、修后每向量各红一次，实测 6/2261）。

**仍然开着的是反向**：诊断串长出第五种形状而没人加行，`mustCover` 与表两处一起停在旧清单，照样
全绿。而这**正是 `ae494b1` 栽的那一跤的形状** —— 当时诊断写着四种私有形状，表里只有 `private
struct` 一行，是 `/codex review ae494b1` P2-2 打出来的，不是绊线响的。

**⚠️ 别把覆盖锁读成「已同源」**：`mustCover` 与表是**两处字面量**，一起砍掉仍能全绿。它把「悄悄删
一行」抬成了「必须动两个地方」，是**抬高门槛，不是证明**。锁自己的 doc comment 里写了这句，别在
别处把它复述成更强的说法。

**修法方向:** 把诊断句子由表**生成**（表是唯一真源），而不是两边各写一份散文。难点是那几条诊断是
精心写的中文散文带 markdown 强调，生成式改写会牺牲可读性；折中方案是给每行加一个 `diagnosticToken`
字段，断言它是真 finding 文本的子串（把表钉到生产措辞上），反向仍需解析诊断串里的反引号 token。

**Context:** 2026-07-20 `/codex review ae494b1` 之后那轮红队 confirmed 的唯一一条。同一轮还改掉了
`fenceProofVectors` 的 `count == 2`（改为成员锁）—— 理由见下一条。

**Effort:** M
**Priority:** P3（P3-05）
**Depends on:** 无

<a id="todo-16"></a>

### T3 双向量自证收窄了 `pathPrefix` 那根轴，但**联合读取**那根还开着

**What:** 本轮把两条自证 suite 都做成了对 `("", fencePathPrefix)` 各跑一遍，并加了四条守卫
（常量形状 / 互异 / 生产值在清单里 / **执行**见证）与穿线见证。台账实测：
`where pathPrefix.isEmpty` 这类只读 `pathPrefix` 一个变量的寄生谓词，现在**当场红**（此前全绿）。

**仍然开着的**是「联合读取 `pathPrefix` **与** `subpath`」那一类。fixture 已从平铺迁进
`ClaudioGUICore/` 与 `ClaudioGUI/`（与生产树目录命名空间同形），所以
`where !display(relative).hasPrefix("gui/Sources/ClaudioGUICore")` 这条已经被逮住；但更窄的
`where !relative.contains("ManifestBinding")` 仍然逃得掉 —— **收窄了，没清零**。

**Why:** 与「闭不上 `root` 这根轴」同源：自证喂合成树、生产喂真仓库，只要谓词读得到「输入长什么
样」的任何一个侧面，就总有一条在两侧取值不同的谓词。

**Context:** 2026-07-20 `/codex review abbf48e` 的 P1（实测：加一行 `where pathPrefix.isEmpty`，
2179 条断言一条不红而围栏在真仓库上整条死掉）。这是「同一个函数 ≠ 同一个实参向量」的第十次复发，
且长在上一轮**为了修它而新加的那条腿**上。

**Effort:** L
**Priority:** P3（P3-02）
**Depends on:** 「T3 围栏的自证闭不上 `root` 这根轴」（同一根因，同一批修法）

<a id="todo-17"></a>

### T3 fixture 的**承重形状**普遍只由散文守着 —— ⑯ 已修，另有 8 处同形

**What:** 「这条 fixture 的某个表面形状（顺序 / 相邻 / 有没有某个修饰符 / 文件名前导点 / 语句在块里的
位置）是它全部分辨力的来源，但只写在注释里」是一整类病，不是一个点。⑯ `PrivateImport.swift` 那条
2026-07-20 已修成可执行（重建旧 run、要求它认领的恰好是漏网写者）。**同一形状红队扫出另外 8 处，
逐条经独立验证坐实**（每条都给出了「一次读起来更顺的无害编辑」+「随后存活的变异」）：

| # | 站点 | 承重形状 | 无害编辑 → 存活的变异 |
|---|---|---|---|
| 1 | ③ `DecoyString.swift` | decoy 串**不带 `public`** 且名字与真函数逐字同名 | 串里补 `public`（更像真声明）／把串里的名字改成 `mutateManifestJSON` → **M12**（`missingMainActorIsolation` 读 `code` 而非 `codeWithoutStringLiterals`）存活。全仓只有这一条 fixture 杀得掉 M12 |
| 2 | ⑪ `CommentGlue.swift` | `public/* MARK */func` 块注释**两侧零空白** | 加空格「更可读」（同文件 1189 行那条块注释 fixture 就是带空格的）→ 剥完粘不出 `publicfunc` |
| 3 | ⑭ `GluedBacktick.swift` | `func` 与反引号之间**无空格** | 加一个空格 —— 诱因现成：⑩ `Backtick.swift` 用的正是带空格写法，一次「统一写法」就够 |
| 4 | ⑮ `BacktickIdent.swift` | 毒源 `` let `func` = 0 `` 还在 | 改名成 `` `funcName` ``（或直接删，它是没人用的 `let`）→ 纳入见证由**干净写者**单独顶着仍成立、否定断言变恒真 → `funcKeywordLexeme` 丢掉 `(?<!`)` lookbehind 存活 |
| 5 | ⑥ `.DottedWriter.swift` | 文件名的**前导点**；且它是全文件唯一一条没有存在性见证的裸负控 | 「统一 fixture 命名」去掉点 → 断言查的是 `contains(".DottedWriter.swift")`，把承重属性编进了搜索串本身，改名后静默恒真。`writeFixture` 用 `try?` 吞写失败，一行 `fileExists` 就能补 |
| 6 | ② `TwoWriters.swift` | 「只有**第二个**缺 @MainActor」这个顺序 | 两行对调「先列不合规的」→ `exported.prefix(1)` 变异在②上存活。**但 suite 级没有活洞**：④ `Overload.swift` 顺序无关地兜住 `prefix(1)` 族，crosstalk 那根由 3126 的直接单测钉住。损失的是这条 fixture 自身的分辨力与那段散文的可信度 |
| 7 | 1850 圈的**生产树目录形状** | 两条嵌套 fixture 落在 `ClaudioGUICore/` / `ClaudioGUI/Deep/` | 改回 `Nested/` / `Deep/`（「跟另一条 suite 命名统一」）或删掉 DirtyTwo → 五条断言零响应 → 消费循环挂 `where !finding.contains("ClaudioGUICore/")` 存活。姊妹 suite 2405 已用逐字前缀见证钉过同款，照抄即可 |
| 8 | 1854 的「**三种**不同违规形态」 | 三条 Dirty fixture 产出跨两类 finding | 三条统一成同一种写法 → `count >= 3` 只数条数、对种类全瞎 → 消费循环按种类过滤（`where !finding.contains("没有 @MainActor 隔离")`）存活 |
| 9 | 1939 `executedVectors.append` | 它**必须是块的最后一行** | 「读起来更顺」挪到块首 → G4 自称唯一挡得住的「提前退出」当场清零：`if vectorPathPrefix.isEmpty { return }` 会让生产向量那圈跳过四条关键腿而全绿，把 suite 打回 `abbf48e` 修之前 |

**Why:** 与 ⑯ 同一根因。fixture 是**输入**，断言只看**输出**，于是「输入还是不是当初那个攻击形状」全靠
人读注释。而这类编辑的诱因往往是现成的（同文件里另一条 fixture 就是那个写法），「统一一下写法」是
最自然不过的一刀。

**修法方向:** ⑯ 那一版是模板，但**别照抄它的第一稿**：钉表面形状（行序 / 行数）是代理量，红队实测
`private import os.log` 能顺序不动地把分辨力清零。要钉的是**威胁本身** —— 就地重建被防的那个变异，
断言它在这条 fixture 上产出的东西恰好是预期的那一个。#7 #9 例外：那两条钉的是路径与执行事实，用逐字
前缀见证 / 检查数增量更直接。

**⚠️ 覆盖边界（别把这条读得比它大）:** #6 经验证在 suite 级**没有活洞**，只是局部分辨力衰减；其余
八条给出的「存活变异」均未实跑台账坐实，是读码推演。落地时每条都要先自己跑一遍第一格（打变异、
不加断言、确认全绿），别把推演当实测。

**Context:** 2026-07-20 修 ⑯（`/codex review 899302a` P1-2）时顺带扫出来的。⑯ 自己实测过：把干净
写者挪到中间，**2269 条断言一条不红**。这是「措辞比覆盖范围大」的第十二次复发。

**Effort:** M（九处各自独立，可逐条落；#1 #5 #7 最便宜）
**Priority:** P2（P2-12；#1 是全仓唯一杀得掉 M12 的 fixture，#9 能整条撤销 `abbf48e` 那一轮的修复）
**Depends on:** 无

<a id="todo-18"></a>

### 签名、公证 DMG 下载后的嵌套 helper quarantine —— 未在真实下载路径上验证

**What:** T17 本地实测确认 `FileManager.copyItem` 会传播 `com.apple.quarantine`，`setup` 有剥离及回验路径。**没验的是**：从正式签名、公证 DMG 下载、复制安装并首次启动后，app 与 `Contents/Resources/bin/claudio` 的 quarantine 状态，以及 `setup` 后嵌套 helper 的实际执行结果。

**Why:** 本地 ad-hoc bundle 不能代替真实下载与 Gatekeeper 的传递行为；需要用下载候选绑定 app SHA、DMG checksum、系统版本和架构，并逐阶段记录 xattr、签名和实际执行。

**Context:** 2026-07-12 T17b 历史场景使用未签名包与「仍要打开」；正式验收按当前签名、公证 DMG 合同，等待首个已授权的适用下载候选，不为此创建 tag、触发 RC workflow 或发布。具体步骤见 `docs/distribution.md`。

**Effort:** S
**Priority:** P2（P2-17）
**Depends on:** 首个已授权的签名、公证 DMG 下载候选

<a id="todo-19"></a>

### `selected_pack` 里的控制字符 / ANSI 转义会被原样打进终端

**What:** `printSetupSummary` 的 ⚠ 行、以及 `SetupError.selectedPackUnresolvable` / `doctor` 的四条 pack 消息，
都把 `config.json` 里的 `selected_pack` **原样**拼进输出。一个含 ANSI 转义序列 / C0 控制字符 / 超长字符串的 pack id
可以借此改写终端显示。

**Why:** 低危（用户得先自己往自己的 config 里塞这种东西，或者装一个恶意的第三方包并选中它），但输出的可信性是
`doctor` 这类诊断工具的立身之本 —— 一个能被内容改写的诊断，诊断的就不是那台机器。

**Context:** 2026-07-12 T17e 第二轮对抗评审（repair-semantics 镜头，P3）。既有问题（doctor 早就这么打了），
T17e 只是**新增了一个打印点**。

**可能的修法:** `ClaudioCore` 里加一个共享的 `displaySafe(_:)`（截断到 ~64 字符 ＋ 把非打印字符转义成 `\u{XX}`），
setup 与 doctor 的所有 packID 打印点统一走它。

**Effort:** S
**Priority:** P2（P2-06）
**Depends on:** None

<a id="todo-20"></a>

### currentExecutablePath 没有真正解析 PATH，裸命令名被当成当前目录的相对路径

**状态（2026-09-16）：**已由 `6617b5d` 改为读取进程映像路径，相关 `SetupSuite` 回归已注册。

**What:** `currentExecutablePath` 的 doc comment 曾经声称支持"裸命令名走 `PATH` 解析"，但实现只是把 `argv[0]` 当成 `currentDirectory` 的相对路径拼起来——如果用户把 `~/.claudio/bin` 加进自己的 `PATH`，然后在一个不相关的目录里跑裸 `claudio setup`，这里解析出来的路径跟 shell 实际通过 `PATH` 找到的二进制毫无关系。

**Why:** `docs/distribution.md` 教用户的命令一直是带完整路径的，不受影响；但这仍是一个货真价实的逻辑错误——doc comment 曾经承诺的行为和实现不一致，已经在这次改动里把 doc comment 改成实话（不再声称支持 PATH）。Codex 两轮独立审查（adversarial + structured review）都指出了同一处。

**Context:** 正确修法要改用 macOS 的 `_NSGetExecutablePath`（真正拿到 OS 层"这个进程实际怎么被启动的"路径，不用猜 `argv[0]`），但这个 API 没法像现在这样注入 `arguments`/`currentDirectory` 参数来写测试，需要重新设计一个可测试的封装（比如注入一个 `() -> String` 闭包，默认调 `_NSGetExecutablePath`）。这次先不做，只把文档改成实话，行为改动留到下一轮。

**Effort:** M
**Priority:** P1（P1-01）
**Depends on:** None

<a id="todo-21"></a>

### install 不清扫升级前留下的坏 hook 条目，异形 HOME 下会与新条目并存

**What:** `claudioHookCommand` 现在会给"会被 `/bin/sh -c` 破坏的路径"加单引号（T13 修正 ②，2026-07-10）。如果某用户的 HOME 含空格 / `$` / `{}` / `*`，他在升级前装的那条 hook 是**无引号**的旧字符串。升级后跑 `claudio install`：`groupContainsCommand` 拿新的带引号字符串做精确等值，认不出那条旧的，于是**追加**一条新的。结果 settings.json 里同一事件下并存两条——旧的那条 `/bin/sh` 每次都会报错（路径被切开 / brace 展开到不存在的路径），新的那条正常发声。

**Why:** 不是静默错误：`uninstall` 的结构化匹配器**两条都认得**（它同时接受带引号与旧的无引号带空格形态，有测试钉住），所以 `claudio uninstall && claudio install` 就能自愈。而且这类 HOME 在升级前 claudio 本来就是坏的（hook 从不触发，或 `*` 情况下执行了别的二进制），所以"并存"是从"完全不工作"变成"工作但有噪声"。真正的修法是让 `install` 也走结构化匹配去识别并替换 legacy 条目，但那会改动 `install` 现有的"append, never overwrite" + 精确等值幂等契约——那是一条被多处测试和 `detectHookInstallStatus` / gui onboarding 依赖的契约，不该跟一次 bugfix 混在一起改。

**Context:** 红队（5 finder × 3 怀疑者，2026-07-10）在 codex review 9913ae9 的修复补丁上提出，两个独立维度各自命中。glob 那一支的实测证据：同级存在 `a!b` 与 `a*b` 时，`sh -c '…/a*b/prog'` 执行的是 `…/a!b/prog`。

**Effort:** M
**Priority:** P2（P2-09）
**Depends on:** None

<a id="todo-22"></a>

### SystemCommandRunner 超时后只 terminate() 不强制回收，忽略 SIGTERM 的子进程仍可能失控

**What:** `SystemCommandRunner.run` 的超时路径仍只调用 `process.terminate()`（SIGTERM）并返回；它不做 bounded wait，也不在子进程拒绝退出时升级为 SIGKILL 并回收。`terminationHandler` 和 deadline-bounded stdout 排空已经补齐，但 `trap "" TERM` 的子进程仍能在 `.timedOut` 返回后继续运行。

**Why:** 当前生产调用者是一次性的 `claudio doctor`，风险低于常驻 GUI 进程，但 runner 的「超时后不会留下失控子进程」合同仍不成立。应在 SIGTERM 后限时等待，再按需 SIGKILL 并确认退出；同时增加一个真实忽略 SIGTERM 的 fixture。

**Effort:** M
**Priority:** P2（P2-07）
**Depends on:** None

<a id="todo-23"></a>

### claude-version 探测的 2s 超时与 `/usr/bin/env` 路径在三处各写一遍字面量

**What:** `checkClaudeCodeVersion`（`VersionCompatibility.swift:325`）、`claudeCodeVersionDoctorResult`（同文件 :384）、`DoctorEnvironment.claudeVersionTimeout`（`Doctor.swift:256`）各自把 `2.0` 秒超时以裸默认参数字面量写了一遍；`/usr/bin/env` 也在两处重复。

**Why:** 同一个文件把版本下限刻意收敛成 `VersionCompatibility` 枚举里的单一真相源常量，却把探测超时留成三份互不协调的拷贝——改其中一个会静默和另外两个分叉。纯一致性/可维护性，无行为风险。

**Context:** Maintainability 专家在 2026-07-11 `/ship` pre-landing review 提出（confidence 6）。修法：加命名常量（如 `VersionCompatibility.defaultClaudeVersionProbeTimeout` 与一个 `defaultEnvPath`），三处默认参数都引用它。

**Effort:** S
**Priority:** P3（P3-08）
**Depends on:** None

<a id="todo-24"></a>

### Setup.swift 的默认选包点前缀过滤用 Character 级而非 scalar 级

**What:** `performFirstRunSetup` 排除点前缀目录用 `!$0.hasPrefix(".")`（Character 级）。一个首字符 `.` 与紧随其后的组合符号融成一个 grapheme cluster 的目录名，整体不等于 `"."`，会溜过这道排除。

**Why:** 极其牵强——需要一次被打断的 `setup` 留下一个 id 以"组合符点"开头的临时包目录，而 `selectPack`/`isSafePackID` 下游本来也会拒掉它。实际不成立，纯一致性：本包其余部分（尤其 `HookCommandMatching`）都严格在 Unicode scalar 层做判定，唯独这一处停在 Character 层。

**Context:** Claude 对抗子代理（2026-07-11 `/ship`，finding #5）提出。修法：改成 scalar 级判定（如 `$0.unicodeScalars.first == "."`）与本包其余部分的粒度对齐。

**Effort:** S
**Priority:** P3（P3-09）
**Depends on:** None

<a id="todo-25"></a>

### GUI 写/读路径的同用户 symlink TOCTOU 未闭合（manifest bind + import + config，v2）

**What:** `bindEventToManifest` / `importAudioFile` 的最终 `Data.write(.atomic)` 与 `loadPackManifestData` 的读，都在 `resolvePackDirectory`/containment 校验之后隔若干 syscall 才操作路径。原子写的 `rename` 只保护**叶子**（`manifest.json`）——中间分量（`packID` 目录本身）被换成 symlink 会被内核跟随，把写重定向到包外。`config.json` 写路径（`selectPack`/`setEventEnabled`）则完全无 symlink 解析 / 乐观并发重读（不同于 `settings.json` 的 `atomicWrite`）。

**Why:** 同用户威胁模型——能并发换 symlink 者本已有该用户的写权限、不构成提权，与 ENGINEERING.md「pack 路径 containment 的 TOCTOU 加固」既定立场一致，故 v1 不做。现在 T16/T15 把这些写路径接进真实面板，站点增至：manifest bind、`importAudioFile` 持久化、`config.json` 两个写者（CLI `use` + GUI 面板）。

**Context:** T16 security-reviewer（2026-07-11）实证复现父目录 symlink 重定向（叶子 rename 语义只挡 `manifest.json` 自身被换，挡不住上层目录被换）；T15 swift-reviewer 指出 `config.json` 无 `settings.json` 那套加固。真修 = 校验后持有 `open(O_DIRECTORY|O_NOFOLLOW)` 目录 fd，后续全走 `openat`/`fstatat`/`renameat` 相对该 fd（`readRegularFileSource` 已对单文件这么做，缺的是**包目录级**）；config 侧补 symlink 解析 + 乐观并发重读。`ManifestBinding.swift` 的注释已修正为「原子写只保护叶子」。

**2026-07-13 `/codex review 573336d` 独立复现同一条（[P2]），行号已锁死**：`ConfigMutation.swift:205` 是裸 `try data.write(to: configFile, options: .atomic)` —— **没有** `resolvingSymlinksInPath()`；而同一个仓库的 `SettingsInstaller.swift:634` 就在写 `settings.json` 前先解析了，还配了一段注释专门讲这个坑（「`.atomic` 做的是 temp+rename **on the symlink**，把链接本身替换成普通文件，与 dotfiles 仓库静默分叉」）。更刺的是 `SafeFileRead.swift:110` **明确允许** `config.json` 是 symlink 并跟随读取 —— 于是 stow / chezmoi 用户的 config 是**读目标、写链接**：两边操作的根本不是同一个文件。D23 定稿①（`573336d`）改的正是 `ConfigMutation` 的这个写函数，**没有**顺手加上这一行；本条仍然开着。（真修与本条上面那半是同一处加固，仍建议合并处理。）

**Effort:** L
**Priority:** P2（P2-02）
**Depends on:** 与 [TD-07：config 外部删除竞争](#todo-07) 共用写入边界设计；config 读写目标一致性不依赖未来提权

<a id="todo-26"></a>

### 默认关闭 Full Keyboard Access 时，当前生产面板的 Tab 与首焦点仍未复验

**What:** 当前生产面板已换成 Settings、近期提示、Sound Scope、活动范围、事件试听/静音、主音量和退出等控件，但仍用 `@FocusState` 与系统 key-view loop，没有自建 Tab 分发。macOS 默认关闭「键盘导航」时，SwiftUI `Button` 是否进入 Tab 顺序、`focusedTarget` 的首次赋值是否真的落地，尚无当前版本的原生复验。

**Why:** `panelFocusOrder(_:)` 和 source-wiring 测试只证明预期顺序与接线，不能证明 AppKit 在默认系统设置下实际接受焦点。应在关闭 FKA 的真实会话中验证打开焦点、Tab/Shift+Tab、`Picker`、事件按钮和 `Slider`；若系统行为仍阻断，再决定是否引入自建键盘焦点层。

**Effort:** S（先复验；若需自建焦点层则 L）
**Priority:** P2（P2-10）
**Depends on:** None

<a id="todo-27"></a>

### 逃生路线：若真实用户反馈「点 Claudio 图标丢字」，唯一出路是丢掉 NSPopover 改 NSPanel

**What:** `MenuBarController.showPopover()` 里的 `NSApp.activate(ignoringOtherApps:)` 是无障碍的**必要代价**（无它 popover 的 window 永远不是 key，整节无障碍规格一条都不成立；替代 API 已按 AppKit 头文件逐条证伪 —— 见 ENGINEERING.md「T15 决议」）。但它有一笔**修不掉**的账：用户正用输入法**组字**时点图标 → 宿主 app 失活 → 组字缓冲被强制上屏或直接丢弃。这条**无法**靠 `popoverDidClose` 的「交还前台」兜底，它发生在**打开**的瞬间。

**Why:** 今天不动它 —— 中文用户在终端/编辑器里组字**同时**去点菜单栏图标，是个不常见的时序。但这是本 app 面向中文用户的一条真实体验裂缝，触发条件驱动：**有人报「点一下丢字」就启动。**

**Context:** T15 对抗评审（2026-07-11，ux-regression lens）。修法只有一条：丢掉 `NSPopover`，自建 `NSPanel` + `.nonactivatingPanel`（公开 API 里唯一「window 能拿 key 而 app 不激活」的机制）。代价：① 丢掉 popover 的尖角与自动锚定（DESIGN.md / T15 明写「NSPopover 带尖角」→ **属未授权设计偏离，须重新拍板**）；② `.transient` 的点外/切 app 自动关闭要用全局事件监视器自己重写；③ **「非激活 panel 在 inactive app 下会不会进 AX 树」在本机无法静态断言 —— 必须先用真机 AX 探针验证再决定**，否则可能原样复现「拿不到 key」的老问题，白改一场。

**Effort:** L
**Priority:** P3（P3-12；触发条件驱动，不主动做）
**Depends on:** 真机 AX 探针先验证 nonactivating panel 能进 AX 树

<a id="todo-28"></a>

### ManifestBindError 的 `manifestUnreadable` / `writeFailed` 仍没有可执行修复指引

**What:** 当前 Sound Packs Window 已把绑定失败本地化并持久呈现；导入后未绑定的文件也会进入 orphan 列表，可重新分配或显式删除。因此旧条目的「孤儿文件不可见、没有出路」部分已经关闭。剩余问题是 `manifestUnreadable` / `writeFailed` 仍只说明读写失败，没有提供修复或重建 `manifest.json` 的操作入口。

**Why:** fail closed 是正确的，但用户仍可能被永久卡在损坏的用户包上。需要给这两个状态补可执行恢复路径，例如显示 manifest 位置、提供安全重建/恢复建议，或由 doctor 给出同一套指引。

**Effort:** M
**Priority:** P2（P2-08）
**Depends on:** None

<a id="todo-29"></a>

### 试听（`NSSound.volume`）与真实播放（`afplay -v`）的增益曲线是否一致，未经证明

**What:** 主音量滑块已落地，当前面板的「试听 ▶」用 `NSSound.volume` 施加 `master_volume`，而真实 hook 播放走 `afplay -v`。两者**同为 0…1 标量**（`NSSound.h:65` 明确 `volume` 是单个 sound 的音量、范围 0…1、不影响系统音量；`afplay -h` 只说 `-v/--volume VOLUME set the volume`），但**没有任何文档说明二者的增益曲线（线性振幅 vs 感知/对数）相同**。

**Why:** 如果曲线不同，同一个 `master_volume` 值下「试听听到的响度」与「真实提示音的响度」会有落差 —— 用户按试听调好的音量，实际用起来偏大或偏小。今天两者都极可能是线性振幅乘子（这是这类 API 的常规），所以风险低；但它是一个**未验证的假设**，不该被当成已知。

**Context:** 2026-07-11 `/plan-eng-review` 的 Codex 外部声音提出（Claude 侧未想到）。修法两条，二选一：① 真机 A/B 实测两条路径在同一 `master_volume` 下的实际响度，一致则把结论写进 `Volume.swift` 的注释（把假设升级成事实）；② 若不一致，试听改走 `afplay -v` 本身（复用 `AfplayVolume.afplayArgument`，与真实播放路径逐字相同）—— 代价是引入进程 spawn 延迟与一个新失败模式（afplay 缺失），故不作为默认选项。

**Effort:** S
**Priority:** P2（P2-11）
**Depends on:** 主音量滑块已落地；需同一音频、相同系统输出与 `master_volume` 下的真机 A/B 证据

<a id="todo-30"></a>

### `ClaudioGUI` 的 panel 与 native composition 仍不能由 harness import

**状态（2026-09-16）：**`ClaudioPanelPresentation` 已由 `6617b5d` 提取并供 GUI harness import；原生 window owner 的行为仍需独立验收。

**What:** `ClaudioGUI` 是带 `@main` 的 **executableTarget**，其 `PanelView`、AppDelegate、
`MenuBarController` 与 native window adapter 不能由 harness 直接 import。Settings 这一半已经解决：
`claudio-gui-tests` 与 app 现在都直接依赖 `ClaudioSettingsPresentation`，compiled tests 会挂载同一个
`SettingsRootView(session:)` 并验证 route、lifecycle、focus、九页 destination 与 gallery。剩余缺口只限
panel/executable/native composition，不再是「整棵 SwiftUI 视图树零回归网」。

**Why:** T17 的 diff 评审曾对 panel 实测两次变异，**两次都全绿**：① 删掉
`PanelView` 里接管成功后的 refresh 接线；② 把 `actionRunner` 改回可选 + 静默 guard。两次都重建了
T17 要修的 bug，而编译与当时 652 项测试没有发现。Settings 的 importable target 不修复这些 panel
接线；它只说明这条 TODO 的原范围已经显著收窄。

**Context:** 2026-07-12 T17b diff 对抗评审；2026-09-04 随 Settings presentation target
收窄。当前只为无法 compiled 表达的 `@main`、controller mount、owner/native accessibility/resource wiring
保留窄 source audit。若要关闭剩余 panel 缺口，应把 panel presentation 移入可 import 的 library target；
不要把已经删除的 Settings 源码形状扫描重新扩回来。

**Effort:** M
**Priority:** P1（P1-05）
**Depends on:** None

## 写盘原子性：这一刀（`/codex review 3af8d5f` 的修复）**没**收进去的那几条

<a id="todo-31"></a>

### 配置事务已 fsync staging，但仍未定义断电持久化策略

**What:** `ConfigFileTransaction.secureAtomicPublish` 会在 rename 前 `fsync` staging fd，bootstrap report、host receipt、activity 和音频导入等路径也有同类处理。当前剩余边界是没有 `F_FULLFSYNC`，rename 后也没有同步父目录，因此不能把原子发布表述成完整的掉电持久化保证。

**Why:** 进程崩溃与突然断电是不同合同。当前代码已经覆盖前者并显著改善后者；是否要为一次性备份或其他低频关键文件支付 `F_FULLFSYNC` 与父目录同步成本，仍需先定分级政策。

**Effort:** M
**Priority:** P3（P3-07）
**Depends on:** None

<a id="todo-32"></a>

### 围栏的词汇表仍是一张枚举清单 —— 真要闭合，只能上 SwiftSyntax

**What:** `AtomicWriteSuite` 的极性已经翻过来了（认不出 ⇒ 红），但它认「写盘调用」靠的仍然是一张**词法**
词汇表（`byteWritingMembers` / `byteWritingFunctions` / `pathPublishing*` / `subprocess*`，故意过宽）。
一个它**没听说过**的写盘 API（某个第三方库的 `save(to:)`、一个 `@_silgen_name` 直连的 syscall）仍然能溜过去。

**Why:** 这是这条不变量今天**唯一**的假绿通道，而且文件头已经照字面写清了它（措辞不比覆盖范围大）。
它比上一版好在：漏一个词的代价从「那类写盘永久隐身」降到了「那**一个** API 隐身」，而且过宽的词汇表让
误伤的代价只是台账里多一行。

**可能的修法:** 用 SwiftSyntax 解析 AST，把「所有函数调用的被调用方名字」整个抽出来，与一张**允许出现在
生产码里的调用名**清单比对 —— 那样「我没听说过」就真的不可能是绿的了。代价：一个新依赖 + 测试包变重。

**Effort:** L
**Priority:** P3（P3-06）
**Depends on:** None

## 面板 config 路由（D23 / 阶段 A′）遗留

<a id="todo-33"></a>

### `probeConfigRewritable` 的 `.absent` 早退，不问父目录可不可写

**状态（2026-09-16）：**已由 `6617b5d` 修复；缺失 config 的父目录检查与 doctor 结论有 compiled 回归。

**What:** `probeConfigRewritable` 发现 `config.json` 不存在就直接返回 `.absent`，不会检查父目录能否创建文件；对已存在 config，它却会检查父目录写权限。于是「config 缺失且 `~/.claudio/` 不可写」仍被面板和 doctor 当作普通未配置状态，直到用户在 Settings 里选择声音包时才得到写入失败。

**Why:** 失败会如实上报，但本可在首次探测时直接说明权限问题。修复时应让 `.absent` 同样检查父目录的存在、目录类型与写/搜索权限，并同步更新 doctor 契约和测试。

**Effort:** S
**Priority:** P1（P1-04）
**Depends on:** None

<a id="todo-34"></a>

### 当前面板的 config 失败态仍有重复提示、焦点丢失与过期错误寿命

**状态（2026-09-16）：**`6617b5d` 已修复生产路径并补 compiled 回归；真实键盘焦点与 VoiceOver 继续按 P2-10 验收。

**What:** 三个残余仍能从当前生产路径成立：

1. 静音或主音量写入把 `configState` 重路由到 `.configFailure` 时，顶部失败卡与 `panelWriteFailures` 可能重复显示同一原因。
2. `.events` 切到 `.configFailure` / `.needsPack` 会摘掉当前事件按钮或滑块，但写入路径没有在顶层内容变化后重新应用合法焦点。
3. `muteError` / `masterVolumeError` 只在下一次同类成功时清除；普通 `reload()` 不裁定旧错误是否还成立，因此一次瞬时 `.lockBusy` 可跨多次 popover 重开继续显示。兼容保留的 `packSwitchError` 也采用同一寿命规则。

**Why:** 这些不是数据损坏，但会重复报错、让键盘/VoiceOver 光标消失，或长期显示已经失效的故障。应让失败呈现按 reason 去重，在 `topContent` 真正变化时恢复焦点，并为瞬时写入错误定义明确的刷新寿命。

**Effort:** M
**Priority:** P1（P1-06）
**Depends on:** None

## 声音包管理（PLAN-SOUND-MANAGER.md）落地债

<a id="todo-35"></a>

### `forkPack` 副本 `name` 字段的措辞未拍板——plan 原文的书名号是不是要求字面写入，没有定论

**What:** `plan/PLAN-SOUND-MANAGER.md` §2.2 给副本 `name` 的例子分别写成"《原name》的副本"与"「\<原name\>的副本」"两种引号包裹的写法，均可读成 prose 里的占位符标记，也可读成要求字面写入的字符。`PackFork.swift:187` 按最朴素的解读实现为 `"\(oldName) 的副本"`（不带任何书名号/引号包裹），`PackForkSuite.swift` 里对应的断言字符串也是这个不带书名号的版本。

**Why:** 这是一处产品文案判断，不是代码缺陷——但如果日后拍板要求带书名号（比如与 DESIGN.md 别处引用包名的规范对齐），需要同时改 `PackFork.swift` 的 `transform` 闭包与 `PackForkSuite.swift` 里对应的几处断言字符串，两处必须同步改，否则测试会继续钉着旧文案、把新文案挡在门外。

**Context:** T6 落地 workflow 的实现方（tdd-guide）在 HANDOFF 里主动标注的设计决策点；audit（silent-failure-hunter）与 review（swift-reviewer）两轮均判定为 minor、未要求返工。

**修复方式:** 找一次产品/设计决策（比如看一眼 DESIGN.md 里其它地方引用包名时用不用书名号，或直接由用户拍板），定了之后同步改 `PackFork.swift:187` 与 `PackForkSuite.swift` 里断言该字符串的几处。

**Effort:** XS
**Priority:** P3（P3-10；纯文案分歧，不影响功能正确性）
**Depends on:** None
