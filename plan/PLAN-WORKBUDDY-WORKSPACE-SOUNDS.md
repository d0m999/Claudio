# WorkBuddy Notification 独立接入与后续工作区声音

状态：**阶段 A 的 Notification 独立实现、自动回归与本地候选已落地；本机最终连接为 configured / awaiting_receipt，真实四格、听音和原生 UI 尚未完成。阶段 B 的 StopFailure 仍受真实 Desktop 证据门阻塞，未开放 WorkBuddy 工作区来源**。目录前提见 `docs/validation/workspace-sound-rules-2026-09-24.md`；本轮结果见 `docs/validation/workbuddy-notification-2026-09-25.md`。

## 阶段 A：Notification 独立接入（本轮）

本轮仅接入 `Notification → notification` 的 `permission_prompt` 与 `idle_prompt`。这两个 subtype 已取得 Desktop 5.6.2 的 A/B 真实目录回调，可独立开发；`StopFailure` 的缺证据不再阻塞本阶段，仍阻塞完整工作区开放。

- 四个已实现事件绑定、五条自有 hook 命令、能力 4/5。WorkBuddy 沿用默认组声音包、独立音量和五事件开关，不开放工作区资格。
- Core 共享通知 subtype 集合；安装两个独立 matcher，使用相同 binding 和 installation ID。完整性按事件加 matcher 核对；缺任一个为 incomplete，重复、错误 matcher、错位及混合代次为 conflict。保留第三方 hook、未知字段、备份和现有 Repair 路径。
- 启用 Notification 有界 JSON 校验：身份一致且 subtype 在集合内；重复身份/subtype 字段、非字符串类型、未知值、超限及畸形输入拒绝播放与回执。合法通知缺目录仍使用默认组。
- 入口、播放器启动前和现有安装锁内的回执写入重新核对 installation ID 与完整 scope，提供可注入 scope seam。四绑定升级使旧三绑定 scope 失效。任务开始 250 ms，其他事件共享 1.5 s 去抖。
- 展示从 catalog 派生 4/5；Notification 的待回执／当前回执逐 binding 显示。保留宿主 ready 判定，4/5 不等于四条当前回执。明确两个 subtype 与 StopFailure 尚未实现，English、zh-Hans 和 key registry 同步。

自动化覆盖四绑定/五命令、双 matcher 完整性、幂等、升级修复、断开与第三方保留；输入拒绝、默认组声音、事件静音/音量/动态静默、共享去抖；版本变化、断开重连竞争、迟到回执；GUI 能力与激活分离、限定文案与键盘/无障碍投影。运行两个 executable harness、GUI Debug/Release、本地化、改动 Swift 格式、diff 检查、本地候选打包及尺寸检查。默认工具链、替代 SDK 与既有失败分别记录；统一设置整套脚本仍要求干净 HEAD，不能清理共享树制造证据。

真实验收先为宿主配置、Claudio 状态、helper 和应用建立独立恢复点，私有文件 0600。现有 Repair 路径修复连接并核对第三方 hook；验证旧代次、旧 scope、断开拒绝后最终重连。在最终代次完成 A/B × 两种通知 subtype 四格，分别记录真实回调、目录匹配、当前回执与实际听音；权限通知采用已验证的原生 Read 授权路径。前三类各回归一次，并验证默认组通知开关、音量、静默、短时交错去抖、双语界面、键盘及 VoiceOver。恢复临时配置并移除探针，保留最终有效连接和恢复备份。

本阶段实现与验收状态见 `docs/validation/workbuddy-notification-2026-09-25.md`。四格回调、当前代次回执、实际听音及相关门禁全部齐全才标记完成；`played` 只证明播放器启动。subtype 证据留在脱敏矩阵，不扩展正式回执格式。提交、推送、发布另行授权。

## 阶段 B：完整工作区目标与边界（后续）

复用 ADR 0005 的 Default Group / Workspace resolver，让 WorkBuddy 根据真实回调的 `cwd` 选择完整声音配置：声音包、音量与五个事件开关。目标绑定为 `UserPromptSubmit → task_start`、`Stop → stop`、`SubagentStop → subagent_stop`、`Notification → notification`（仅 `permission_prompt` 和 `idle_prompt`）及 `StopFailure → stop_failure`。五类事件与两个通知 subtype 都通过真实验收才算完成；缺项须报告阻塞。

沿用协议兼容策略及安装代次校验，不增加精确版本白名单。保留宿主级去抖：任务开始 250 ms，其他事件共享 1.5 s。新建工作区默认勾选已验证来源；已有规则只在用户主动编辑后加入 WorkBuddy。合法事件缺可信目录、没有匹配规则或来源不适用时使用默认组；命中损坏规则或声音包时停止播放。

## 先决宿主证据

以当前 WorkBuddy Desktop 为起点，在独立临时工作区 A/B 分别观察 `permission_prompt`、`idle_prompt` 和 `StopFailure` 的真实回调、原生事件身份、顶层 `cwd` 及语义。失败测试优先使用独立自定义模型、占位凭据与仅本机固定错误端点。观察器只记录事件、允许的通知类型、字段类型和目录匹配布尔值；宿主配置须做 0600 备份、并发检查和恢复。安装包函数、CLI 文档、手工 stdin 均不替代 Desktop 回调。

**停止条件：**不能隔离失败测试，目标事件未触发，语义不符或目录错误时，不接入未证明的事件，也不开放 WorkBuddy 工作区资格。两个目录的固定 401 在有、无 matcher 的独立观察中均未取得 `StopFailure` 回调。Security Center 的命令“询问”走沙箱审批路径，未产生目标 `Notification/permission_prompt`；修正 Desktop 输入方式后，原生 `Read` 工具授权已在 A/B 各取得 `Notification/permission_prompt` 与正确目录。Desktop 5.6.2 随包代码显示模型失败走 `Stop`，`StopFailure` 只从 `executeStopHooks` 的异常捕获派发；该静态发现不代替真实回调，但使目标失败语义在当前版本下存疑。因此 StopFailure 与完整工作区实施暂缓；阶段 A 可独立实施。

## 阶段 B 证据通过后的实现

1. 扩展能力目录与 WorkBuddy adapter，在阶段 A 基础上加入 `StopFailure` 的稳定 binding ID。Core 定义共享通知 subtype 集合，供 Hook 输入策略及配置转换器共用。通知装两个独立 matcher；目标为五个绑定、六条自有 hook 命令。配置检查以事件加 matcher 判定完整性、重复和混合代次，同时保留第三方 hook 及未知字段。五类事件统一校验有界 JSON 与原生事件身份；身份错误不播放且不写回执，合法事件目录缺失或非法则使用默认组。保留命令、公共事件 ID、配置路径及回执格式。
2. 在 `WorkspaceSurfaceEligibility` 开放 WorkBuddy，复用现有目录 resolver、配置写入 owner 与完整声音配置选择。保留 Git/worktree、普通目录最长路径及符号链接规则。先以回归复现旧 scope 可进入播放，再在入口、播放器启动前和回执接受边界同时检查 installation ID 与完整 scope；通过可注入 seam 测版本变化、断开及重接入竞争。目录不进入普通日志、回执或活动摘要。
3. 复用统一设置窗口及工作区详情。创建/编辑表单提供 WorkBuddy；创建与详情共用可测试来源状态投影，分别展示目录资格、规则适用性、接入及当前回执。覆盖数从 catalog 派生，5/5 不等于五类当前回执。更新通知范围和陈旧文案；新增文本同步 English、`zh-Hans` 与 `ClaudioL10nKey.allKnown`。菜单栏只手动切换默认组/工作区，最近回调不改变编辑目标。

## 阶段 B 验证与本机验收

自动化覆盖六条配置命令、两个 matcher、幂等连接、缺项/重复/混合代次及第三方保留；五类输入的身份、通知 subtype、重复字段、超限与畸形拒绝；A/B 选包、音量/开关、默认组回退、Git/worktree、子目录、符号链接与损坏规则；新旧 scope、断开重连、宿主去抖；GUI 的新建默认勾选、旧规则不自动加入、写失败保留原值和逐绑定激活。

从仓库根运行两个 executable harness、GUI Debug/Release、`jq empty`、改动 Swift 的格式检查及 `git diff --check`。本地候选包另做打包与尺寸检查；分别记录默认工具链与替代 SDK 的结果。设置整合脚本遵守干净 HEAD 前置条件，不清理共享工作树来制造通过结果。

本机验收先为宿主配置、Claudio 状态及现有 app 建立独立恢复点。经现有 Repair 路径处理 installation 冲突，核对第三方 hook，验证断开及旧代次拒绝后最终重接。随后完成 A/B × 六种触发场景的 12 格真实回调、目录匹配、当前代次回执与实际听音；正向听音避开去抖窗口，另测短时交错抑制。还须验证默认组回退、单工作区静音、独立音量、新建/编辑、同窗口跳转、键盘与 VoiceOver。撤销临时规则和探针，保留最终连接及恢复备份。

`played` 回执只证明播放器成功启动；实际听音另记。通知 subtype 的脱敏证据留在验收矩阵，不扩展正式回执字段。自动化、真实回调、当前激活、音频、原生 UI、签名/发布和正式验收分别报告。提交、推送及发布另行授权。
