# 默认组与工作区声音：实施及验证记录

本记录对应 ADR 0005 的 2026-09-24 合同。自动化、真实宿主目录回调、原生界面、实际听感分别记录，不互相替代。

## 真实宿主目录回调

在本机新建的临时 Git 仓库子目录中启动实际 CLI。没有改写用户已有 hooks；测试 hooks 通过临时项目设置或命令行参数注入。探针只保存宿主、事件、`cwd_present`、`cwd_matches` 四项，不保存 payload、目录、提示词、会话 ID 或凭据。比较在内存中对实际路径解析符号链接后进行。

| 宿主版本 | 实际事件 | 有 cwd | 与启动子目录一致 |
| --- | --- | --- | --- |
| codex-cli 0.156.1 | UserPromptSubmit | 是 | 是 |
| codex-cli 0.156.1 | Stop | 是 | 是 |
| codex-cli 0.156.1 | SubagentStop | 是 | 是 |
| codex-cli 0.156.1 | PermissionRequest | 是 | 是 |
| Claude Code 2.1.281 | UserPromptSubmit | 是 | 是 |
| Claude Code 2.1.281 | Stop | 是 | 是 |
| Claude Code 2.1.281 | SubagentStop | 是 | 是 |
| Claude Code 2.1.281 | Notification | 是 | 是 |
| Claude Code 2.1.281 | StopFailure | 是 | 是 |

触发方式：普通一轮提示得到提交/完成事件；要求宿主运行并等待一个只回复 OK 的子代理得到 SubagentStop；只读 sandbox 中请求运行无副作用的 `printf`，实际进入批准流程得到 Codex PermissionRequest / Claude Notification。仅批准这次测试命令。

Claude StopFailure 使用本机 loopback HTTP 服务返回固定 401 JSON，临时设置 `ANTHROPIC_BASE_URL`、两个凭据变量为明确的测试占位值，以及 `CLAUDE_CODE_MAX_RETRIES=0`。真实 CLI 终止请求并产生 StopFailure。此项证明受控 API 失败时宿主实际发出的目录回调，不是线上 Provider 成功验收。无真实凭据发送到测试服务；服务不记录请求头或正文。

Codex 项目 hooks 在本次 `exec` 的 trust/config layer 下未加载，成功证据来自显式 `-c hooks.<Event>=[...]` 注入及 `--dangerously-bypass-hook-trust` 的隔离测试。目录证据不等于用户集成已接入，也不等于 Claudio 收到有效安装代次回执。

因此 `WorkspaceSurfaceEligibility.verified` 开放 Codex CLI 和 Claude Code。WorkBuddy 仍不开放工作区规则。未来宿主版本改变 hook payload 时须重做此矩阵；当前证据不是对所有历史或未来版本的保证。

### WorkBuddy 5.6.2 目录回调补测（2026-09-25）

在 WorkBuddy Desktop 5.6.2（`com.tencent.workbuddy.mac`）界面中，分别选取两个新建的空临时目录 A、B 作为任务工作空间，提交只回复 OK 的任务，并明确要求调用 Agent 子代理完成无文件操作的计算。临时 Hook 观察器读取有界 stdin，观察记录只包含原生事件名、`cwd` 类型、是否为绝对路径，以及规范化后与 A 或 B 是否精确匹配；不含原始 payload、实际路径、提示词、会话 ID 或凭据。匹配用路径暂存于私有临时文件，测试后已清除。测试期间也有其他任务的回调，以下只统计匹配 A/B 的样本。

| WorkBuddy 原生事件 | A 精确匹配 | B 精确匹配 | 结论范围 |
| --- | ---: | ---: | --- |
| `UserPromptSubmit` | 3 | 2 | 当前已接入事件；两个目录均有真实匹配回调 |
| `Stop` | 3 | 2 | 当前已接入事件；两个目录均有真实匹配回调 |
| `SubagentStop` | 2 | 1 | 当前已接入事件；两个目录均有真实子代理结束回调 |
| `Notification` | 8 | 4 | 观察到目录字段；未记录 subtype，不能据此证明 Claudio 允许的通知类型 |
| `StopFailure` | 0 | 0 | 未触发，仍无目录证据 |

匹配样本的 `cwd` 均是顶层字符串绝对路径，解析符号链接后与界面所选目录精确一致。A、B 的交叉结果证明当前版本在这些测试任务中传的是各自目录。样本不证明未来版本、所有通知类型、失败事件、任务中途换目录或 worktree 场景。

本轮只补充目录证据，没有修改 `WorkspaceSurfaceEligibility`、声音配置或 Claudio 接入。测试前备份中的三条 Claudio 自有 WorkBuddy hook 分属两个 installation ID；恢复后只读 preflight 仍为 `configuration=conflict`、`activation=none`。因此这些回调不构成当前接入激活或按工作区实际播放的证据。临时观察器已移除，`~/.workbuddy/settings.json` 与测试前备份的 SHA-256 逐字节一致；私有临时备份、观察日志和空测试目录均已删除。

### WorkBuddy 5.6.2 通知 subtype 与失败语义补测（2026-09-25）

另建独立空目录 A、B，在 Desktop 中分别选为任务工作空间。临时观察器仅读取有界 stdin，记录原生事件、通知类型是否为 `permission_prompt`／`idle_prompt`、`cwd` 的字段类型和绝对路径布尔值，以及规范化后匹配 A/B 的结果。其他通知类型只记为 `other`，不保存原值；不保存原始 payload、目录、提示词、会话 ID、错误正文或凭据。

| 受控场景 | A | B | 结论 |
| --- | --- | --- | --- |
| `Notification` / `idle_prompt` | 1 次，顶层绝对路径 `cwd` 精确匹配 | 1 次，顶层绝对路径 `cwd` 精确匹配 | 两目录取得该 subtype 的真实目录回调 |
| `Notification` / `permission_prompt` | 0 次 | 0 次 | 本轮未进入授权请求流程，未取得该 subtype 的目录证据 |
| `StopFailure` / 自定义模型固定 401 | 0 次 | 0 次 | Desktop 两次均显示鉴权失败与任务未知错误，但观察器未捕获该回调 |

失败测试使用 Desktop 设置页新增的独立 OpenAI 兼容自定义模型，端点只监听 `127.0.0.1` 并固定返回 401 JSON；API Key 是测试占位值，没有使用或发送现有模型凭据。A/B 均在界面选择该测试模型并提交 `OK`，两次均看到 WorkBuddy 的 401 鉴权失败提示。本机端点的 401 响应已单独核对。`StopFailure` 观察组本轮使用 `matcher: "*"`，当时尚未单独验证该事件的 matcher 语义；后续无 matcher 复测见下文。零回调不能证明 Desktop 对所有异常都不发该事件。

探针还看到 A/B 匹配的其他 `Notification`，但其 subtype 不在本轮两种允许类型内，不能充作 `permission_prompt` 证据。测试期间 WorkBuddy 界面被用户主动切换，遂停止继续驱动宿主。临时 hook 已撤销，`~/.workbuddy/settings.json` 与本轮独立 0600 备份的 SHA-256 一致；测试模型已按名称和本机 URL 精确移除，loopback 服务已停止。私有探针、观察日志和备份已清除；A/B 空测试目录和 Desktop 测试任务暂留，未触碰其他模型或任务。

因此本计划的真实宿主门槛未通过：`permission_prompt` 和 `StopFailure` 缺失。WorkBuddy 仍不进入 `WorkspaceSurfaceEligibility.verified`，五类按工作区播放、六条 hook、5/5 能力、当前代次激活、实际听音和原生 UI 验收均未实施或验证。

### WorkBuddy 5.6.2 无 matcher 失败与权限请求复测（2026-09-25）

沿用独立临时目录 A/B，但重新建立本轮 0600 私有备份、临时 Hook 观察器和只监听 `127.0.0.1` 的固定 401 JSON 端点。`StopFailure` 观察组这次不设置 matcher；`Notification` 观察组仍观察所有 subtype，但只将 `permission_prompt`、`idle_prompt` 原样分类，其他归为 `other`。观察记录仅含配置事件、原生身份是否一致、输入是否为有界对象、`cwd` 字段类型、绝对路径布尔值和规范化后的 A/B 匹配结果，不保存原始 payload、路径、提示词、会话 ID、错误正文或凭据。

| 受控场景 | A | B | 结论 |
| --- | --- | --- | --- |
| `Notification` / `idle_prompt` | 2 次，顶层绝对路径 `cwd` 精确匹配 | 1 次，顶层绝对路径 `cwd` 精确匹配 | 再次取得两个目录的真实回调 |
| `Notification` / `permission_prompt` | 0 次，默认权限下尝试命令 | 0 次，未主动触发权限请求 | A 的命令没有进入询问流程；两目录仍无该 subtype 的目录证据 |
| `StopFailure` / 无 matcher、固定 401 | 0 次 | 0 次 | 两个 Desktop 任务均显示鉴权失败及未知错误；此错误场景没有观察到回调 |

通知观察组另记录 A 匹配 `other` 10 次、B 匹配 2 次，以及不匹配 A/B 的 `other` 14 次；这些都不能代替目标 subtype。A/B 的三条 `idle_prompt` 均为有界对象、原生身份正确、顶层字符串绝对路径 `cwd`。本轮 29 条观察中没有 `StopFailure` 调用，说明此前的零结果不只是 `matcher: "*"` 的写法造成；仍不能外推到其他异常类型。

只读核对 Desktop 5.6.2 随包的 `cli/bin/codebuddy`、`codebuddy-lite-wb.mjs` 和 `codebuddy-headless.js`：后两者的 `executeStopFailureHooks` 均只在 `executeStopHooks` 的异常捕获路径调用，而模型失败以 `stopReason: "failed"` 进入 `Stop`。当前 Desktop 子进程分别使用过 lite 和 headless 路径，两份文件在这一点上相同。这一静态实现与本轮 401 的零回调一致，但不能代替真实回调，也不证明所有错误路径。它与[官方 CLI 插件文档](https://www.codebuddy.ai/docs/cli/plugins-reference)所述 API 错误结束语义存在版本内的可观察差异；继续把 503/429 模型错误当作 `StopFailure` 触发法缺乏依据。

为进入真实授权流程，在 A 的“默认权限”下分别尝试了工作区内无副作用命令、工作区外临时标记、一次性临时目录清理，以及本机 loopback 请求；这些任务均直接完成，没有出现权限询问。随后在 Security Center 临时添加仅匹配 `printf CLAUDIO_PERMISSION_PROBE` 的“询问”规则。准备提交匹配命令时，Desktop 输入框内容与填入内容不一致；该任务未发送，规则没有经过触发验证，不能算 `permission_prompt` 的反例。为避免干扰其他 Desktop 操作，立即撤销该规则并停止 UI 驱动。

临时 hook、测试模型和安全规则均已精确撤销；`~/.workbuddy/settings.json` 与 `~/.workbuddy/models.json` 均与本轮独立备份的 SHA-256 逐字节一致，本机 401 服务已停止。本轮私有探针、观察日志和备份在核对后已清除；A/B 空测试目录和 Desktop 测试任务暂留。本轮未修改 Claudio 源码、工作区资格或正式接入；没有当前代次回执、按工作区声音或实际听音的新证据。下一次真实宿主验收仍需在可控的 Desktop 会话中触发 A/B 各自的 `permission_prompt`，并找到符合目标语义且实际发出 `StopFailure` 的异常结束场景；当前版本尚无可重复的后者触发法。

### WorkBuddy 5.6.2 独占界面的权限路径补测（2026-09-25）

用户确认本轮可独占 Desktop 后，为原有 A/B 临时工作空间建立新的 0600 设置备份，并安装只记录事件身份、允许的通知 subtype、有界输入状态、`cwd` 类型及 A/B 匹配结果的观察器。本轮没有保存原始 hook payload、目录、任务正文或凭据。

在 A 的“默认权限”下，Security Center 新增只匹配测试用 `printf` 命令的临时“询问”规则。Desktop 确实显示该命令命中规则的审批界面；批准单次执行后，命令以退出码 0 完成。观察器没有收到 `Notification/permission_prompt`。本轮八条 `Notification` 观察均为 `other`：A 匹配 2 条，B 匹配 2 条，另有不匹配 A/B 的 4 条；匹配样本的原生身份正确、输入有界、`cwd` 是顶层字符串绝对路径。`PermissionRequest` 探针在 A 审批后才安装，不能据其零记录判断 A 的该事件。

只读核对随包 `codebuddy-headless.js`／`codebuddy-lite-wb.mjs` 后发现，Security Center 的命令“询问”经沙箱审批队列处理；该路径没有调用 `Notification/permission_prompt` 或普通 `PermissionRequest` hook。它说明真实审批界面不等于目标通知回调。两份随包代码还显示沙箱开启时 Bash 跳过顶层工具权限检查，因此继续给 Bash 添加 `permissions.ask` 也不能验证普通授权路径。[官方权限规则文档](https://www.codebuddy.ai/docs/cli/permissions)定义了 `permissions.ask` 的 `Read` 规则，但 Desktop 实际触发仍须以回调为准。

为验证普通工具授权，曾在 A/B 各创建一个仅含测试标记的小文件，并临时加入 `permissions.ask: ["Read"]`。B 的新任务在发送前界面显示了“只用原生 Read 读取测试文件”，实际提交后却显示前一条未发送的 `printf` 任务；此前 A 的任务也出现过发送前显示文本与最终提交文本不一致。两次提交的实际命令均只输出测试标记，没有读写文件或访问网络。由于 B 未调用 `Read`，本轮未取得普通工具授权弹窗、`PermissionRequest` 或 `Notification/permission_prompt` 的有效测试。停止继续驱动 Desktop；不能把这次未执行的 Read 场景算作事件不存在的证据。

临时 Security Center 规则、顶层 `permissions.ask` 规则及两个观察器已撤销；A/B 测试文件已精确删除。`~/.workbuddy/settings.json` 与本轮独立备份逐字节一致，私有观察数据清理后不留正式回执。A/B 临时目录和 Desktop 测试任务暂留。WorkBuddy 仍不开放工作区资格；五类事件、两个通知 subtype 的真实验收及实际声音验收均未完成。

### WorkBuddy 5.6.2 原生 Read 授权回调补测（2026-09-25）

独占 Desktop 的后续输入同步探针表明：全新任务中直接键盘输入、等待文字完整，再点击已启用的发送按钮，实际提交内容与界面一致；先前的错位发生在使用 `setValue` 清空输入后。本轮因此不再用 `setValue`。重新建立独立 0600 设置备份，在 A/B 临时工作空间各放置仅含测试标记的一行小文件，临时设置 `permissions.ask: ["Read"]`，并同时观察 `Notification` 与 `PermissionRequest`。B、A 各自的新任务只要求原生 `Read` 读取该文件，提交后实际消息与预检一致；Desktop 均显示读取成功，没有其他工具调用。[官方权限规则文档](https://www.codebuddy.ai/docs/cli/permissions)提供 `Read` 工具 ask 规则语法；本表以 Desktop 回调为证据。

| 原生事件／通知 subtype | A 精确匹配 | B 精确匹配 | 证据范围 |
| --- | ---: | ---: | --- |
| `Notification` / `permission_prompt` | 1 | 1 | 两目录均为真实 Desktop 回调，原生身份正确、输入有界、顶层 `cwd` 为字符串绝对路径 |
| `PermissionRequest` | 1 | 1 | 同次原生 Read 工具请求的额外观察，不扩展本计划的五类公共事件绑定 |
| `Notification` / `other` | 2 | 2 | 不代替目标 subtype；另有 2 条不匹配 A/B |

本轮全部 10 条观察的原生身份、有界输入及顶层字符串绝对路径 `cwd` 检查均通过。`permission_prompt` 在 A/B 分别与对应工作空间规范化后精确匹配；加上此前两目录的 `idle_prompt`，目标 `Notification` 两个 subtype 的目录证据现已齐全。本轮没有可复核的审批按钮人工操作记录，也没有 Claudio 当前代次回执或实际听音证据；工具读取成功与 hook 回调各自只证明其对应事实。

临时 `permissions.ask`、两个 hook 观察器和 A/B 测试文件已撤销；`~/.workbuddy/settings.json` 与本轮独立备份逐字节一致。私有探针及观察数据在核对后清除，A/B 临时目录与 Desktop 测试任务暂留。五类目标中仍缺符合语义的真实 `StopFailure` 回调，因此不开放 WorkBuddy 工作区资格，不实施五类配置或 5/5 展示，也不宣称正式验收完成。

公开协议依据：[Git rev-parse](https://git-scm.com/docs/git-rev-parse)、[Git worktree](https://git-scm.com/docs/git-worktree)、[Codex hooks](https://developers.openai.com/de-DE/docs/hooks)、[Claude Code hooks](https://code.claude.com/docs/en/hooks)。

## 自动化覆盖

- Core 的真实临时文件系统 fixture 覆盖两个仓库、同仓库两个 worktree、子目录、符号链接、普通目录嵌套、Git 优先、重复冲突、缺少可信 cwd、不适用来源、损坏命中规则/包、五个开关、独立音量。
- 首次迁移备份逐字节验证；旧覆盖（含损坏原始字段）和未知字段保留；旧写 API、失效 UUID 拒绝修改默认组。
- GUI 编译 seam 覆盖选择/路由、工作区写失败原值、切换后的延迟音量提交、使用中声音包删除保护和五项试听与宿主能力分离。
- 配置增长超过 64 KiB 时拒绝发布并逐字节保留原文件；发布后的并发冲突沿既有 CAS 边界报告、重读当前状态，不宣称原值未变。

### 本机命令结果

- `swift run --package-path helper claudio-tests`：3540 项通过。
- GUI executable harness：最终全量为 10385 项、1 失败（退出码 1，失败详见下文）；最新工作区集中回归 `claudio-gui-tests --workspace-sounds` 为 2235 项、0 失败。此前曾完成一轮 10381 项通过，仅保留为阶段证据。
- GUI Debug / Release：SDK 26.5 + SwiftPM native backend 构建通过。
- `node scripts/test-sound-pack-selector-state.js`：通过。
- `python3 scripts/test-sound-pack-candidates.py`：11 项通过。
- `jq empty`、改动 Swift 文件的 `swift format lint --strict`、`git diff --check`：通过。

本机为 macOS 27 / Command Line Tools。规定的默认 GUI Debug build 实际运行失败于缺少 `xcstringstool`；native backend 使用默认 SDK 27 又缺少 `SwiftUIMacros.StateMacro` 插件。没有改仓库工具链。可重复的替代命令为：

```bash
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk swift run --build-system native --sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk --package-path gui claudio-gui-tests
swift build -c debug --build-system native --sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk --package-path gui --product ClaudioGUI
swift build -c release --build-system native --sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk --package-path gui --product ClaudioGUI
```

`SDKROOT` 同时使 harness 内的 `swiftc` 可见性正/负探针使用相同 SDK。几次全量重跑（含无并行构建的复跑）停在已有 `AICueAssetFetchSuite` 的 `connection/inactivity/absolute deadline` 用例。该用例包含 20 ms 时限和两处无上限测试回调等待。本次仅把这两处测试等待改为 2 秒 watchdog，保留原有结果断言，并给失败消息补充计数；没有修改产品网络实现。

隔离入口 `claudio-gui-tests --ai-cue-assets` 跑完 192 项，1 项失败：inactivity 后期待 URLProtocol 已取消且迟到 chunk 被丢弃，实得 `requests=1, stopped=0, late=0`。最终全量 10385 项也仅此断言失败，其余检查运行完成，包括原生视图挂载。因此 GUI 全量未通过；此前 10381 项通过的一轮不能覆盖这项后续失败。现有证据只能定位到测试未观察到取消回调，尚未确定是运行环境、测试时序还是产品网络行为导致。

未运行要求干净 HEAD 的整套 `verify-settings-experience.sh`：本任务没有提交授权，且工作区原有三份未跟踪原型仍被保留。脚本中的相关独立检查如上执行。没有用旧 `dist/claudi0.app` 充当新构建或新界面证据，也未覆盖该现有产物。

## 原生及外部验收边界

真实宿主目录证据已验证。原生 UI 自动化入口两次连接超时，未完成菜单栏键盘/VoiceOver、实际听感、升级提示和同窗口详情的人工走查。harness 的 NSHostingView 挂载检查不能替代这些验收。未执行发布、推送、签名公证或跨 CPU 架构验收。
