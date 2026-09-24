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
