# 事件来源提示条 对账轮 Review 修复：规格与 Ticket 拆分

日期：2026-09-13（Asia/Singapore）。基线：`4160baf`（review 对象即 `4160baf...HEAD` 的三个提交
`e41587d`、`2987fea`、`3143048` 及其后的未提交工作树修改）。
来源：本会话最近一次 code review（`code-review` 双轴：Standards 0 hard + 2 judgement calls，
Spec 3 findings）。Review 发现由用户在会话中提供、未在 GitHub 跟踪，与上轮
（`plan/FIX-EVENT-NOTICE-REVIEW-20260912.md`）同一处置。

## 确认结果与最小修复

### F1「resignKey 断言丢失分支极性，台账 line 86 过度声明」（Spec #3 + Standards judgement #1）— 确认

- **根因**：对账轮为避免等价重构假红，把断言从语句形态（`if isInteractive { close() }`）
  放宽为内容存在性（`close()` + `isInteractive` + `model.setKeyboardFocused(false)` 三个 token
  在闭包体内出现即可）。内容存在性看不到**极性取反**：把闭包体改成
  `if !isInteractive { close() } else { model.setKeyboardFocused(false) }`，断言照样全绿，
  而「交互面板失焦后收起」的语义已经被翻转（自动横幅被关、交互面板残留）。
- **最小修复**（T1）：在既有 expect 上折入一条极性腿 `!normalized.contains("!isInteractive")`
  —— 对 if/guard 形态都免疫（等价 `guard isInteractive else { …; return }` 不含该 token，
  保持绿），而取反写法（`if !isInteractive` / `guard !isInteractive`）直接判红。不新增 expect，
  检查计数不变。断言消息同步改为「存在性+极性断言，不证明分支内归属；等价 guard 改写不得假红」。
  已知残余：else-first 翻转（`if isInteractive { setKeyboardFocused } else { close() }`）仍不可见 ——
  文本绊线能力边界，如实披露，不在本刀范围。
- **测试 seam**：`gui/Tests/ClaudioGUICoreTests/ViewWiringSuite.swift` 第一个 suite
  （`codeWithoutStrings` + `closureBody(after: "func windowDidResignKey")`，AGENTS 允许的
  executable 跨文件接线护栏）。
- **变异验证（T2 执行，结果回填台账）**：
  1. 极性取反变异（`if !isInteractive`）→ 必须红（新能力，F1 的本体）。
  2. 等价 guard 改写 → 必须绿（对上轮承诺的回归）。
  3. 删除 `window.delegate = self` → 必须红（对上轮承诺的回归）。
- **台账对齐（T3）**：line 86 的「保证交互面板失去 key window 后沿关闭路径收起」按断言真实
  能力改写（文本层存在性+极性+接线，不宣称分支内归属）。

### F2「台账头部范围列表未纳入本轮三个提交」（Spec #1）— 确认

- **根因**：`docs/event-attention-acceptance.md` line 3 的「最终源码范围」沿用
  `4160baf` 当轮的写法，对账轮三个提交（`e41587d`、`2987fea`、`3143048`）未列入。
- **最小修复（T3）**：line 3 补入三个对账轮提交；line 5 补一句本轮（review 修复）为
  未提交工作树修改，沿用「本地实现，不提交」约定。

### F3「证据表与 follow-up 段矛盾」（Spec #2）— 确认

- **根因**：表中 GUI 完整 harness 行仍是上轮的「9,152 checks，通过」与旧 mSKtCQ 日志，而
  follow-up 段已声明本轮 9,151 checks、5 项本机环境既有失败 —— 一轮通过的 9,152 与一轮
  有 5 项失败的 9,151 在同一台账内无 reconciliation；line 35「以下执行均返回 exit 0」被
  follow-up 段的失败声明直接矛盾。
- **最小修复（T2 执行 + T3 回填）**：2026-09-13 重跑完整 GUI harness，表行更新为实测
  计数与日志路径；line 35 加限定「除注明项外」；follow-up 段补本轮（review 修复轮）段落，
  逐条记录真实结果。不回填 helper 行（本轮未触碰 helper 源码）。

### 不处理项（记录在案，超出范围）

- **Standards judgement #2**：`EventNoticeView.swift:185,288` 的 `record.kind != .transient`
  残余否定式 —— 上轮已记录为有意的收敛残余（`isAttention` 留 public 供后续收敛），
  本轮不动视图排版代码。

## Ticket 拆分

- **T1 极性腿**（依赖：无；验收：`ViewWiringSuite` 首个 suite 在改动后的完整 harness 中绿）。
- **T2 验证执行**（依赖：T1；验收：完整 GUI harness、专项、Debug 构建、严格格式、
  `jq empty`、`git diff --check`，全部如实记录计数与日志路径；三条变异逐一判定）。
- **T3 台账对齐**（依赖：T2 的真实结果；验收：台账头部、line 35、证据表行、line 86、
  follow-up 段相互一致且与实际验证结果一致，`git diff --check` 通过）。

## 验收命令

```bash
swift run --package-path gui claudio-gui-tests
swift run --package-path gui claudio-gui-tests --event-attention
swift build -c debug --package-path gui --product ClaudioGUI
swift format lint --strict --configuration .swift-format gui/Tests/ClaudioGUICoreTests/ViewWiringSuite.swift
jq empty gui/Sources/ClaudioLocalization/Resources/Localizable.xcstrings
git diff --check
```

本机 sandbox 内 SwiftPM 需 `--disable-sandbox`（见台账 follow-up 段）。
不 commit、push、deploy、release 或关闭 issue。
