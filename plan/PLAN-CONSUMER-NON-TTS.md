# PLAN — 非 TTS 宿主提示音：状态与决策索引

> 状态：**pre-RC 自动化基线已收口；AX 技术 no-go；WorkBuddy 2/5 当前激活与持久连接窄验收通过**
>
> 更新：2026-08-31
>
> 本文件只维护跨宿主结论、状态、决策门和权威证据入口。每个新 Host Surface 或剩余事件
> 必须使用独立计划/Issue；不得在本索引里顺带授权实现、宿主写入或真实验收。

## 1. 当前决策

1. 正常产品 registry 只包含 Claude Code、Codex、WorkBuddy。ChatGPT Desktop AX 与
   Claude Desktop AX 保留为兼容解码和 `DEBUG` 诊断 identity，不再进入普通 UI、manager
   descriptor/capability registry 或可听能力矩阵。
2. Issue #16 只证明隔离 tracer、脱敏 fixture、隐私边界和生命周期契约；它没有证明真实
   ChatGPT 集成可用。
3. Issue #17 在当前 ChatGPT `26.818.31338` / `6892` 上无法形成稳定 surface identity，
   observer 启动次数为 0，结论是 fail-closed 技术 no-go。AX 不进入可用、发布或生产阶段。
4. WorkBuddy 在 `5.4.4` 上保持连接；`UserPromptSubmit → task_start`、`Stop → stop` 两条
   当前 binding 均有匹配当前 installation/scope 的 schema 2 回执，Current Activation 为
   `recorded`。本机持久连接与 2/5 当前激活已获用户正式批准；未执行 Disconnect。
5. WorkBuddy 剩余三个事件逐事件进入独立 evidence-first 计划/Issue；在真实宿主证据成立前，
   不实现、不接线，也不承诺 5/5。
6. Issues #64–#66 的自动化、状态模型与 wiring 基线已聚合验证；结论仅为 `pre_rc_only`。
   本次 2/5 持久连接窄验收不改变 Issues #18–#22 的 RC、双架构、视觉、VoiceOver 与发布状态；
   精确 commit 与计数只维护在唯一验收账本。

## 2. 五轴状态矩阵

| Host Surface | 宿主接口 | Claudio 实现 | 历史真实回执 | 带时间戳的当前激活 | 生产/正式验收 |
|---|---|---|---|---|---|
| Claude Code | 五个正式 hook 事件 | 5/5 native adapter | 本计划不重验，见发布验收账本 | 本计划未采集当前回执，不推断 | 未通过 |
| Codex | 4/5；无 `StopFailure`，`PermissionRequest` 仅部分覆盖 Notification | 4/5 native adapter | 本计划不重验，见发布验收账本 | 本计划未采集当前回执，不推断 | 未通过 |
| WorkBuddy | 五个事件已声明；Notification 为 partial | 2/5 native adapter | Issue #15 历史闭环；2026-08-31 当前 installation 再次取得两条真实回执 | `recorded`；保持连接 | 本机 2/5 持久连接窄验收通过；RC/生产未通过 |
| ChatGPT Desktop AX | Issue #17 当前版本无法形成稳定 surface identity | 仅有隔离 `DEBUG` tracer；无 adapter、权限 UX 或生产声音链 | 无真实生命周期回执；其余场景 `not_evaluated` | 不适用 | 技术 no-go |
| Claude Desktop AX | 本计划未验证任何可用接口 | 仅保留诊断 identity，无产品实现 | 无 | 无 | 未评估且不在路线图中 |

矩阵中的五列是独立事实。接口声明、代码存在、历史回执、当前激活、发布/正式验收之间不能互相替代。

## 3. What already exists

- `HostProductID`、`HostSurfaceID`、`HostID`、descriptor 和 `HostEventBindingID` 已提供稳定身份；
  AX token 继续可解码，以免删除历史偏好或诊断证据。
- `HostID.productVisibleCases` 是正常产品 registry 的唯一真相源；manager、Core 矩阵、GUI 默认值、
  preview 与回执反馈只消费这三个表面。
- WorkBuddy adapter 已外科式管理当前 installation 的两条 command hook，并复用配置锁、备份、CAS、
  symlink 与未知 JSON 保留契约。
- schema 2 current receipt、历史回执、installation/scope fingerprint 和 Disconnect 保留规则已经存在；
  历史证据不会重新点亮 Current Activation。
- Chat AX tracer 已被限制为 `DEBUG`、GUI-only、默认关闭，并有 fixture、privacy 与 lifecycle 测试；
  它继续作为诊断工具存在，不转化为产品 surface。

## 4. 产品路径与测试边界

```text
HostID.allCases（5 个兼容/诊断 identity）
├── productVisibleCases（3 个正常产品 surface）
│   ├── HostIntegrationManager descriptor/capability/snapshot registry
│   ├── AudibilityMatrix
│   └── Integrations UI / preview / receipt feedback
└── Desktop AX（2 个）
    ├── 历史 token 与偏好继续可解码
    └── DEBUG tracer 直接使用；不得进入普通产品路径

用户打开 Apps/集成窗口
└── 只看到 Claude Code / Codex / WorkBuddy
    ├── WorkBuddy 仍诚实显示 2/5
    └── 不出现 ChatGPT/Claude Desktop AX 占位或假连接动作
```

代码实施必须覆盖：产品 registry 唯一真相源、manager 与矩阵过滤、GUI 分组/布局/焦点、preview、
历史 AX token 解码、DEBUG tracer 隔离以及 Release 路径无 tracer 启动。

## 5. 后续决策门

### 5.1 新 ChatGPT 机制

任何 browser extension、Responses API/Codex、自有 consumer 或其他机制都必须创建新的
`HostSurfaceID`，并在独立计划/Issue 中依次取得：

1. 明确实现和外部写入授权；
2. 数据最小化、禁止持久化 prompt/response、生命周期与撤销契约；
3. 精确产品/版本/安装身份的只读 preflight；
4. 失败关闭的事件映射和进程边界；
5. fixture、负向测试、真实 callback、Current Activation、GUI/声音人工核对与 Disconnect 证明。

新机制不得继承 AX 的权限、fixture、Issue #16/#17 证据或 production 资格。调研结论只作为入口判断，
被 `.gitignore` 排除的本机调研文档不作为 tracked plan 的权威依赖。

### 5.2 WorkBuddy 剩余事件

`StopFailure`、`Notification`、`SubagentStop` 分别建立独立诊断/验收 Issue。每个 Issue 必须先证明：

- 当前 WorkBuddy 版本确实发出该原生事件，并记录可重复的最小触发步骤；
- callback payload 足以做确定性映射，同时不保存用户内容；
- 不触发、重复触发、宿主失败和过期 scope 都能 fail closed；
- 实现后产生匹配 binding/installation/scope 的真实回执，完成 GUI/声音核对并可逆 Disconnect。

三项不得合并成一个“5/5”任务。某一项通过不为另外两项提供证据。

## 6. 本地验证

```bash
bash scripts/local-pre-rc.sh
swift run --package-path helper claudio-tests
swift run --package-path gui claudio-gui-tests
swift build -c debug --package-path gui --product ClaudioGUI
jq empty gui/Sources/ClaudioLocalization/Resources/Localizable.xcstrings
git diff --check
```

2026-08-25 的聚合入口已在 clean checkout 上通过全部 gate。该结果只属于 automated / local
dev-bundle；精确 commit 与计数见唯一验收账本。2026-08-31 的 WorkBuddy 2/5 Current Activation
与本机持久连接窄验收已另行记录；原生 SwiftUI 完整矩阵、VoiceOver、键盘/焦点、
Intel/Apple Silicon RC 与发布批准仍属于独立证据。

### 6.1 正式验收 issue 链

| Issue | 当前状态 | 未验证事实 |
|---|---|---|
| #18 | `OPEN` | signed universal RC、Developer ID、notarization、stapling、Gatekeeper |
| #19 | `OPEN` | Apple Silicon 与 Intel 真机上的 WorkBuddy RC |
| #20 | `OPEN` | 原生 SwiftUI 视觉矩阵与截图证据 |
| #21 | `OPEN` | Full Keyboard Access、焦点归还与 VoiceOver 矩阵 |
| #22 | `OPEN` | 正式路线图验收与人工批准 |

唯一分层状态与 commit 清单见
[0.1.0 验收账本](../docs/release-acceptance-0.1.0.md#pre-rc-自动化基线issues-6466)。

## Implementation Tasks

Synthesized from this review's findings. Each task derives from a specific finding above.

- [x] **T1 (P1, human: ~2h / CC: ~20min)** — ClaudioCore — 建立唯一产品可见 surface registry
  - Surfaced by: Architecture Review — `HostID.allCases` 同时承担兼容身份与产品 registry，导致 AX 泄漏。
  - Files: `helper/Sources/ClaudioCore/`、`helper/Tests/ClaudioCoreTests/`
  - Verify: helper harness 证明三项产品 registry 与两项 AX token 兼容解码。
- [x] **T2 (P1, human: ~3h / CC: ~30min)** — ClaudioGUICore — 统一过滤普通 UI 与矩阵
  - Surfaced by: Code Quality Review — manager、矩阵、GUI、preview 各自消费 `allCases`。
  - Files: `gui/Sources/`、`gui/Tests/ClaudioGUICoreTests/`
  - Verify: GUI harness 证明三个产品表面、无 AX 占位、动态布局与 tracer 隔离。
- [x] **T3 (P1, human: ~2h / CC: ~20min)** — Plans — 同步五轴状态和 WorkBuddy 实证
  - Surfaced by: Architecture Review — 旧计划混合路线图、实现细节和过期验收状态。
  - Files: `plan/`
  - Verify: tracked plan 不链接 ignored research，且明确历史回执不等于当前激活。
- [x] **T4 (P1, human: ~2h / CC: ~45min)** — Verification — 执行完整本地回归
  - Surfaced by: Test Review — 部分 UI 过滤会留下 manager/矩阵泄漏或破坏历史解码。
  - Files: `helper/Tests/`、`gui/Tests/`
  - Verify: helper、GUI、debug build、localization JSON 和 `git diff --check` 全部通过。

## NOT in scope

- 继续或放宽 AX observer、申请生产 Accessibility 权限：Issue #17 已触发停止条件。
- 删除 AX enum/token、历史偏好、fixture 或脱敏证据：它们仍承担兼容和诊断职责。
- 实现 WorkBuddy 剩余三个事件：尚无逐事件真实宿主证据。
- 创建 browser extension、Responses API consumer 或新的 ChatGPT surface：需要独立计划、授权和隐私契约。
- 修改真实宿主配置、重新 Connect、生成真实回执或自动试听：本次代码/文档任务不授权宿主写入。
- commit、push、release、签名、公证或正式验收：这些是独立动作和状态。

## 7. 权威证据入口

- [WorkBuddy 计划](PLAN-CONSUMER-WORKBUDDY.md)
- [AX spike 计划与停止条件](PLAN-CONSUMER-AX-SPIKE.md)
- [0.1.0 验收账本与 Issue #15 真实闭环](../docs/release-acceptance-0.1.0.md)
- [Issue #17 脱敏 no-go 结果](../docs/chat-ax-spike-issue-17.md)

## GSTACK REVIEW REPORT

| Review | Trigger | Why | Runs | Status | Findings |
|--------|---------|-----|------|--------|----------|
| CEO Review | `/plan-ceo-review` | Scope & strategy | 0 | — | 未运行 |
| Codex Review | `/codex review` | Independent 2nd opinion | 1 | CLEAR | 同会话反向检查；无方案冲突，补强兼容解码边界 |
| Eng Review | `/plan-eng-review` | Architecture & tests (required) | 1 | CLEAR | 8 issues，0 critical gaps，全部折叠并实现 |
| Design Review | `/plan-design-review` | UI/UX gaps | 2 | CLEAR | 最近评分 3/10 → 9/10，3 decisions |
| DX Review | `/plan-devex-review` | Developer experience gaps | 0 | — | 未运行 |

- **CODEX:** 当前会话已运行 free in-host challenge；确认隐藏产品入口时必须保留 AX token 与历史数据解码。
- **VERDICT:** CODEX + ENG + DESIGN CLEARED；本轮代码、计划与自动化验证已完成。

NO UNRESOLVED DECISIONS
