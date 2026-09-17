# PLAN — 包作用域 AI 提示音生成与应用

> 设计状态：**已接受（ADR 0016）**。本轮仅定稿文档与可交互原型；Swift 生产实现、原生验收与发布状态独立。
>
> 更新：2026-09-17。原型：`mockups/pack-scoped-ai-cues.html`。

## 1. 背景与决定

原有 `aiCueAdoptionEligibility` 按 ADR 0007 要求非 Global、独占的用户包。2026-09-16 的
`pikachu` 案例中，Global、Codex、Claude Code 与 WorkBuddy 有效选择同一个健康包，
`sharedPack` 门拒绝采纳。包 manifest 的映射本来就是包级事实；按来源独占证明与用户
希望共同编辑一个包的目标冲突。[ADR 0016](../docs/adr/0016-adopt-ai-cues-into-user-packs.md)
现已取代 ADR 0007 的这一限制。

**生成和采纳面向用户声音包；选用面向 Global 或 Surface。**「提示音组」只是普通用户包的
界面称呼，没有单独资产库、完成状态或 per-surface manifest。`packID + Event` 是采用目标，
声音作用域继续按 ADR 0005 解析完整包和稀疏覆盖。配置写入、包映射写入和 Provider 凭据
各有原 owner。

## 2. 三条进入路径

| 路径 | 进入、发布与取消 | 应用作用域 |
|---|---|---|
| 已有健康用户包 | 直接选择事件、生成、命名并采纳；成功才改 manifest | 不自动改 Global/Surface 选包；包的所有有效使用者立即听到更新 |
| 新建空提示音组 | 保持未发布草稿；自动建议名称，可改名；取消、关闭或首音失败不入库；首个音完整采纳成功才发布为普通用户包 | 发布后显示在选包列表，用户显式选择应用 |
| 复制任意健康包 | 完整复制成功即发布并查看可编辑副本；失败不产生成功态 | 普通「复制」只创建副本，不切换选包 |

只读内置包不能直接采纳。来自「事件与提示音」的缺声深链先捕获目标 Global 或明确
`HostSurfaceID`、原包和 `Event`，显示「复制并用于全局默认」或「复制并用于此来源」。
复制成功后才向该目标应用副本，随后定位事件；**应用失败时保留可找回的副本**并显示
「复制成功，应用失败」，不跳到隐式 Global 或另一个 Surface。普通复制不具有这一步。
用户包深链直接定位原包及事件，无需 fork。健康检查在复制和采纳时重新执行。

## 3. 门控与事务

| 门 | 范围 | 失败呈现 |
|---|---|---|
| G1 · 可写 | 采纳目标须为可编辑用户包；内置包引导新建或复制 | 原包不变 |
| G2 · 健康 | 包须已安装、未损坏且身份未漂移；复制源也须健康 | 修复或重选，不能假刷新 |
| G3 · 凭证 | 所选固定 profile 发起**新的联网生成**之前检查 | 保留描述，提供该 profile 配置入口；保存后须再次显式点击生成 |

进入 `AudioImport` 和 manifest bind 前还须验证公共 `Event`、`packID` 和候选的 generation、
profile、route、唯一身份与完整校验状态。候选在生成时有效，后来删除凭据不撤销采纳资格；
切 profile、改描述、重新生成、取消或关闭则按现有 session 规则使未采纳候选失效。
采纳成功才发布新映射；任何失败保留旧绑定，部分磁盘结果按实际状态报告。新建空组必须
以首音采纳的成功作为发布门，不允许先入声音包库再等待生成。

使用者范围按 effective selection 计算：Global 明示选择、每个显式选包的 Surface，及
继承 Global 的 Surface 均应列出。共用包被修改后立即影响这些有效使用者，在采纳按钮旁
直接说明，不加确认弹窗。显式损坏的覆盖不能回退 Global；配置损坏导致范围无法完整求出时
标明「使用范围不完整」，仍允许健康用户包采纳。`master_volume` 仍只有全局一轴。

复制副本或向带整包声明的用户包采纳 AI 音频时，从**修改后的包**移除整包 `license` /
`author` 声明。界面在动作旁提前说明；无额外确认弹窗。原包、独立 attribution 文件、
第三方许可材料和未知 manifest 字段不因此删除。元数据变更与包安全写入失败时不得声称成功。

## 4. 覆盖度、宿主与生成服务

侧栏和包详情固定显示公共五事件的 `n/5`。缺失 event key 是合法静默，不要求 5/5 才
可选用。「声音」页不默认选中事件，事件名称是普通标签。点击「描述生成」或从缺声深链进入时，
定位对应事件，在行下方显示生成表单；只读包显示复制引导。生成时保留目标包与事件、服务与
凭据状态、采纳后受影响的有效使用者。宿主事件能力仍由现有 `HostCapabilityBinding` 持有，
在「事件与提示音」按当前来源显示原生事件、支持和实现状态；当前激活另按真实回执判断。
不支持或未实现的事件不提供缺声生成入口，但来源能力不限制「声音」中的包级生成。

「声音」顶部独立服务区块只列出已注册的五个固定 profile：`elevenlabs-global`、
`minimax-global`、`qwen-singapore`、`qwen-beijing`、`senseaudio-cn`。选择仅改变生成
profile 与其独立凭据状态；不提供自由 endpoint、model、voice、region 或虚构的
SenseAudio 国际 API。`routes.keys` 决定声音类型，route-owned policy 决定候选身份与
数量：ElevenLabs/Qwen 为 3 styled，MiniMax/SenseAudio speech 为 3 numbered，
仅 SenseAudio SFX 可为 1–2/3 partial。演示原型不请求真实服务或保存真实凭据。

## 5. 生产实施影响面与证据边界

- `AICueAdoption.swift` 的来源独占资格与 permit 需要换成包目标；`AICueAdoptionSuite`
  须覆盖共享、继承、配置损坏、凭据变化及候选身份重校验。
- `EventSettingsWindowView.swift` 保留缺声深链；「声音」目的页承担服务/profile、
  包级生成、复制、草稿首音发布、使用范围与失败态。复用 app-lifetime `SoundPackLibrary`、
  现有 pack fork 与安全写入，不增加第二个包事实 owner。
- 新原生文案需 en 与 `zh-Hans` 同步且占位符一致，注册于 `ClaudioL10nKey.allKnown`。
  行为回归 suite 遵循 `<Feature>Suite.swift` + `run<Feature>Suites()` 注册。
- 原型走查覆盖五个事件默认无能力对照、描述生成与缺声深链准确定位、只读包复制引导、
  键盘操作与表单焦点；「事件与提示音」在当前来源如实显示 Codex「执行中断」和「待响应」、
  WorkBuddy 未实现事件，且不为不支持或未实现的事件提供缺声入口。来源状态不禁用包级生成。
  同时覆盖共用与继承、用户包原地采纳、Global/Surface 内置包深链、任意包复制、
  空组取消和首音发布、配置损坏、凭据变化、候选身份与失败态。
  自动 harness、HTML 预览、原生交互、真实 Provider 和发布各是不同证据层。

本计划只定稿设计，**不表示 Swift 已迁移**。原始 ADR 0007、执行计划与设置计划中的
历史任务和验收记录保留，并明确标成历史；现行实现合同以 ADR 0016 和本文为准。
