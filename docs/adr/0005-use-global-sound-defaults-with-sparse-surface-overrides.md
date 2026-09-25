---
status: accepted
---

# 使用完整的默认组与工作区声音配置

2026-09-24 用户批准的新合同替代本 ADR 原来的 Global + sparse Surface 模型。
默认组和每个工作区各自拥有声音包、音量、五个事件开关；顶层 `master_volume` 仅是默认组音量的兼容存储名，不再乘以工作区音量。工作区不继承单项默认值。创建时必须选包、确认音量，五事件初始全开。

唯一解析入口在播放前根据有界 hook payload 的 `cwd` 和 Surface 选择整套配置。可信目录缺失或没有适用规则时使用默认组；命中规则的显式损坏或包损坏停止该规则播放。宿主能力、当前接入代次和动态静默仍先行约束自动播放；断开后迟到的回调不得播放。试听只检查音频可播放，不声明宿主事件已接入。

Git 目录使用 `rev-parse --show-toplevel` 定位所选 worktree 根，使用绝对 `--git-common-dir` 作为共同仓库身份，覆盖所有关联 worktree。普通目录按解析符号链接后的实际路径及子目录匹配。共同 Git 身份或普通实际路径重复时拒绝；适用 Git 规则优先于普通目录，普通规则选最长路径。Git 识别失败不得伪装为普通目录或掩盖已命中的损坏规则。目录仅留在本机配置和进程内存，不进入普通日志、回执或活动摘要。

升级立即忽略 `surface_overrides`（包括旧损坏覆盖），原始 JSON 与未知字段保留。首次新配置写入在既有 `config.lock`/CAS 边界中先制作私有可恢复备份，再记录模型版本；备份失败则拒写。旧来源声音写 API 明确拒绝，陈旧路由不得改写默认组。GUI 显示一次非阻塞迁移说明。

第一版的目录适用来源限 Codex CLI 与 Claude Code，并须以目标事件的实际版本目录回调证据开放；WorkBuddy 暂不开放。新规则只勾选创建时已具备证据的来源，新增来源不自动加入。目录证据、接入、能力与当前激活分别呈现。

WorkBuddy 开放须先取得五类真实 Desktop 回调的目录证据，其中 `Notification` 分别核对 `permission_prompt` 与 `idle_prompt`，`StopFailure` 须对应受控 API／基础设施异常结束。沿用协议兼容策略与完整安装代次 scope，不采用精确版本白名单。2026-09-25 的 Desktop 5.6.2 补测已在两个目录取得 `Notification` 两个目标 subtype 的真实回调；Security Center 审批界面本身不能代替该证据。有、无 matcher 的独立固定 401 测试均未捕获 `StopFailure`，因此本次仍不开放 WorkBuddy 工作区规则。详见 `docs/validation/workspace-sound-rules-2026-09-24.md`。

`Notification → notification` 可在工作区资格开放前独立实施：仅 `permission_prompt` 和 `idle_prompt`，两个 matcher 共用一个 binding 与 installation ID，使用默认组声音包、音量和事件开关。该阶段为四个已实现绑定、五条自有 hook、4/5 能力；`StopFailure` 仍未实现。入口、播放器启动前和安装锁内的回执写入均校验 installation ID 与完整 scope，三绑定旧 scope 在升级后失效。通知的当前回执不代表所有 subtype 已完成人工听音；subtype 证据单列脱敏验收矩阵。独立通知阶段不降低上述五类目录证据门槛。

设置详情与菜单栏共用写入 owner 和声音包库。设置提供默认组/工作区列表及同窗口详情；菜单栏只手动选组、换包、调该组音量、试听与逐事件静音，适用 Surface 只读并可定向进入详情。活动概览始终标为“所有来源”，不推算工作区统计。

参考：[Git rev-parse](https://git-scm.com/docs/git-rev-parse)、[Git worktree](https://git-scm.com/docs/git-worktree)、[Codex Hooks](https://developers.openai.com/de-DE/docs/hooks)、[Claude Code Hooks](https://code.claude.com/docs/en/hooks)。公开文档不代替发布前逐事件真实验证。
