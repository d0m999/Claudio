# WorkBuddy Notification 独立阶段：实施与验收记录

状态：**实现已落地，真实 Desktop 四格、实际听音与原生无障碍验收尚未完成；本阶段不标记完成。**

本轮从 `ab911289f7320097d50ecaf2ca62a5cac66755c7` 的共享工作树实施。原有 `CONTEXT.md` 和工作区目录证据记录的 diff 原样保留；现有 WorkBuddy 计划和 ADR 0005 增加独立通知阶段。未提交、推送或发布。

## 实现边界

- `Notification → notification` 仅允许 `permission_prompt`、`idle_prompt`。两个独立 matcher 共用一个 binding 和 installation ID；四绑定、五条自有命令，能力 4/5。
- 配置以事件＋matcher 检查完整性；任一缺失为 incomplete，重复、错位、错误 matcher 或混合代次为 conflict。幂等连接与 Repair 沿现有 adapter，断开精确移除五条自有命令；第三方与未知字段保留。
- CLI 启用有界 JSON 校验，拒绝身份错位、重复身份/subtype 字段（含转义键）、非字符串、未知 subtype、畸形和超限输入。合法通知缺目录仍使用默认组。未开放 WorkBuddy 工作区，StopFailure 仍未实现。
- 保留任务开始 250 ms、其他事件共享 1.5 s 的宿主级去抖。默认组声音包、音量、通知开关与动态静默继续沿现有播放器。
- WorkBuddy 在入口、播放授权检查及安装锁内回执写入核对 installation ID 和完整 scope。四绑定 scope 使三绑定旧安装失效。scope reader 可注入，正式回执不增加目录、subtype 或 scope 字段。
- 设置页从 catalog 派生覆盖数，在现有脱敏连接证据行内显示四条只读逐绑定状态；Notification 不从宿主 ready 推断当前回执。文案说明默认组、两个通知范围和未实现的执行中断；English/zh-Hans 与 key registry 同步。四行连接组和动作焦点顺序保留。

## 自动化证据

先添加旧 scope 回归并运行未修复代码：3566 项中仅新增的两条断言失败，复现相同 installation ID 的旧 scope 仍能播放及写回执。修复后 helper 全量 **3694 项通过**。

覆盖双 matcher 缺项/重复/错误类型/混代/错位、幂等与第三方保留、三绑定升级轮换、两种 subtype、非法输入零播放/零回执、默认组声音包与独立音量、通知静音、零音量、动态静默、共享去抖、入口及启动前失效、播放后断开/重连/同 ID scope 替换、安装锁内 scope 重读。GUI 覆盖 4/5 与逐绑定状态分离、双语限定和键盘/无障碍文本投影。

| 门禁 | 结果 |
| --- | --- |
| `swift run --package-path helper claudio-tests` | 3694 项通过 |
| `bash scripts/test-hook-cli-contract.sh` | 通过；真实 CLI 子进程的两种 subtype、非法输入、旧 scope、静默退出和 Debug-only root 合同 |
| 默认 GUI harness / Debug / Release | 失败：Command Line Tools 环境缺少可执行 `xcstringstool` |
| SDK 26.5 native GUI harness | 10458 项，1 项失败：既有资产下载 inactivity 取消断言；其余检查完成 |
| SDK 26.5 native GUI Debug / Release | 最终逐绑定展示候选均通过；Release 通过 dev-bundle 的 `-Osize` 构建复验 |
| 改动 Swift 的 `swift format lint --strict` | 32 个文件通过 |
| `jq empty`、`git diff --check` | 通过 |
| `verify-settings-experience.sh <BASE_SHA>` | 按脚本前置条件退出：共享树不是 clean HEAD；未清理或提交其他改动 |
| 默认 `dev-bundle.sh` | 失败于同一工具链限制；已从独立备份恢复原应用 |
| SDK 26.5 native 本地打包、尺寸、签名检查 | 全部通过；最终 arm64 app 正规文件合计 9,905,930 B / 11,750,000 B |

本机为 macOS 27.0、Apple Swift 6.4、arm64。替代构建显式使用 `/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk` 与 SwiftPM native backend，不修改仓库工具链。打包时仅在私有临时 PATH 中包装 `swift build/run` 添加上述参数，其余沿用原 `dev-bundle.sh`。这是当前架构、ad-hoc 签名的本地候选，不是双架构、Developer ID 或公证发布证据。

GUI 已有失败为 `AICueAssetFetchSuite.swift` 的 inactivity 后 URLProtocol 取消观察：`requests=1, stopped=0, late=0`。与现有工作区声音验收记录一致；本轮不改写该网络实现或削弱其断言，也不把全量 GUI 称为通过。

## 本机恢复点与连接

在 `~/.claudio/acceptance-backups/workbuddy-notification-20260925-183217/` 建立四份独立压缩备份：宿主 settings、Claudio 状态、已安装 helper、原本地 app。目录 0700，备份和 SHA-256 清单均为 0600。未将宿主配置、回执、日志或备份提交到仓库。

开发前只读 preflight：WorkBuddy Desktop 5.6.2，三条原有 Claudio hook 的安装代次冲突，`configuration=conflict`、`activation=none`；另有九条第三方 hook。使用本轮候选 helper 经现有 manager/adapter 的连接修复路径更新共享 runtime，先修复冲突，再断开、重连。最终 `configuration=configured`、`activation=awaiting_receipt`，四个已实现 binding、五条自有命令，Notification 的两个 matcher 正确。最终已安装 helper 与候选 bundle 的 helper SHA-256 相同。

在本机实际状态上分别调用候选 CLI，验证：相同 installation ID 的旧 scope、修复前旧代次、断开后代次、重连前代次均退出 0 且零输出，WorkBuddy 回执及两条去抖状态文件逐字节不变。这些是本机安装防护的合成输入检查，**不是 Desktop 真实回调或实际听音**。断开撤销 marker，最终重连生成新 ID。移除自有 hook 后的配置结构与操作前相同，九条第三方 hook 及未知字段保留；默认组 config 的 SHA-256 不变。保留最终连接，不写入合成“当前激活”回执。

候选源码文件摘要、两个 binary 的 SHA-256、前后只读 preflight 与安装防护结果已作为 0600 文件留在上述恢复目录。本轮没有安装宿主探针或更改权限规则；不存在需恢复的临时声音/目录配置。

## 真实验收矩阵与阻塞

本轮 UI 工具识别到 `com.tencent.workbuddy.mac` 正在运行，但分别通过名称和 bundle ID 读取窗口均返回 `cgWindowNotFound`；当前工具也没有可调用的 macOS `launch_app`。新 Claudio bundle 启动后两次 UI 读取均返回 `timeoutReached`；已核对有进程运行最终候选的可执行路径，这只证明启动，不是布局或交互验收。已请求用户显示 Desktop 主窗口并配合实际听音。不能用手工 stdin 或 harness 替代 Desktop 回调。

| 最终代次场景 | Desktop 回调 | 目录 A/B 匹配 | 当前回执 | 实际听音 |
| --- | --- | --- | --- | --- |
| A / permission_prompt | 未验证 | 未验证 | 未验证 | 未验证 |
| A / idle_prompt | 未验证 | 未验证 | 未验证 | 未验证 |
| B / permission_prompt | 未验证 | 未验证 | 未验证 | 未验证 |
| B / idle_prompt | 未验证 | 未验证 | 未验证 | 未验证 |

此前 5.6.2 的两 subtype A/B 目录证据仍见 `workspace-sound-rules-2026-09-24.md`，只作为开发前提，不提升为本轮最终代次激活或听音。UserPromptSubmit、Stop、SubagentStop 的最终代次 Desktop 回归，以及通知开关、音量、静默、交错去抖的真实声音测试均待补。

原生双语布局、键盘完整路径及 VoiceOver 未验证；harness 文本/焦点投影、NSHostingView 挂载和构建不替代它们。`played` 仅表示播放器启动。只有本表与相关人工门禁齐全后，才可标记独立通知阶段完成；StopFailure 的缺证据继续阻塞后续工作区资格。

## 后续验收尝试（2026-09-25）

用户要求按“先验收”继续。本次重新核对共享树，没有提交或推送。电脑操作接口仍识别 WorkBuddy 进程，但获取 Desktop 窗口返回 `cgWindowNotFound`；获取本地候选 Claudio 窗口返回 `timeoutReached`，另一个已运行应用也返回 `cgWindowNotFound`。用户确认当前暂时无法打开 WorkBuddy 主窗口或参与听音。因此没有驱动新的 Desktop 任务，也没有生成任何合成的正向回执；上表四格、前三类真实回归、音量／静默和原生无障碍验收状态均不变。

只读 `acceptance workbuddy-preflight --json` 已保存为私有恢复目录下的 `preflight-followup.json`（0600）。与本阶段最终连接记录相比，installation ID 与完整 scope 均未变化；`configuration=configured`、`activation=awaiting_receipt`，四个已实现 binding 逐项仍为 `awaiting_receipt`。已安装 helper 与候选 bundle 的 helper 字节摘要相同。此复核只证明连接仍处于待真实回执状态，不构成真实回调或声音验收。

## 解锁后的继续尝试（2026-09-25）

用户表示电脑已解锁，可以开始验收。电脑操作接口对 WorkBuddy 和本地候选 Claudio 均返回 `Computer Use was not approved to use ...`，因此本轮不能代用户操作两个原生界面；没有通过其他 UI 自动化路径绕过该拒绝。

同一安装 ID 与完整 scope 的只读 preflight 显示 `configuration=configured`，但本轮受限运行环境将宿主配置报告为 `not_writable`，故未尝试 Repair 或改写宿主配置。`UserPromptSubmit` 与 `Stop` 在上次记录之后出现 `current_activation` 回执，时间分别为本地 20:12:59 与 20:13:24，结果都是 `played`；`Notification` 与 `SubagentStop` 仍为 `awaiting_receipt`。这两条回执属于当前安装代次，但本轮没有受控 Desktop 任务及听音记录可对应，不能充作计划要求的真实回归或实际听音。四格通知矩阵仍未开始。
