# 事件来源提示条（C）验收台账

日期：2026-09-12（Asia/Singapore）。范围：`edb7b7e feat(gui): add event source prompts` 及其 review 修复轮（plan/FIX-EVENT-NOTICE-REVIEW-20260912.md，K1–K11）。
原则：harness/源码检查不证明原生布局、焦点、VoiceOver、真实音频、真实宿主回调；未实测项一律标「未验证」。

## 自动化门禁

| 门禁 | 命令 | 结果 |
|---|---|---|
| helper harness | `swift run --package-path helper claudio-tests` | ✅ 2854 checks（修复轮复跑） |
| gui harness | `swift run --package-path gui claudio-gui-tests` | ✅ 8840 checks（修复轮复跑） |
| GUI debug 构建 | `swift build -c debug --package-path gui --product ClaudioGUI` | ✅（修复轮） |
| 本地化目录 | `jq empty gui/Sources/ClaudioLocalization/Resources/Localizable.xcstrings` | ✅（修复轮含 6 个新词条） |
| 补丁检查 | `git diff --check` | ✅ |
| 尺寸门禁 | `bash scripts/check-release-size.sh dist/claudi0.app` | ✅ 5,540,512 / 5,600,000（arm64） |

## 覆盖组状态（对照 plan/PLAN-EVENT-SOURCE-PROMPTS.md §6）

| 组 | 状态 | 证据 |
|---|---|---|
| G1 来源解析/输入边界 | ✅ harness | HostEventSourceSuite / HookInputReaderSuite |
| G2 hook 分流与失败隔离 | ✅ harness | HostHookRunnerSuite（含注入 `.dropped` 后的固定诊断码断言） |
| G3 transport | ✅ harness | EventNoticeTransportSuite（真 socket/双实例/epoch） |
| G4 模型状态图 | ✅ harness | EventNoticeModelSuite（含同刻到达确定排序回归） |
| G5 原生呈现 | ⚠️ 部分 | EventNoticePresentationSuite 覆盖布局夹取/刘海 inset/文本与 AX 同源；IME、FKA、VoiceOver、点外点击、多屏：**未验证**（需真机） |
| G6 路由能力 | ✅ harness + DEBUG gallery | SessionNavigationSuite；gallery「Route OK / Route Fail」为模拟，非真实宿主跳转 |
| G7 偏好/组合 | ✅ harness | SettingsPreferencesSuite / SettingsRootInteractionSuite / ViewWiringSuite |
| G8 端到端 | ⚠️ 部分 | 本台账即 G8 载体；真实 hook → 原生提示 → 近期 → 动作全链路：**未验证**（需真机逐宿主） |

## Review 修复轮决定记录

- FileLock 增加 `O_NOFOLLOW | O_CLOEXEC`：保留。与 spec L119「endpoint ownership/mode/no-follow 检查复用既有 bounded-file/lock 模式」同向；既有 AtomicWriteSuite 覆盖。
- Release 尺寸门禁 5,500,000 → 5,600,000：保留。原提交已给出实测归因（本节前述 2026-09-12 段：旧门禁下 5,519,464 B 失败关闭）；修复轮后复测 `5,540,512 B / 5,600,000 B`（arm64，dev-bundle，2026-09-12），仍在预算内，未再放宽。
- `panelFirstFocusTarget` 对 operational 保留「打开落声音作用域」特判：焦点顺序按 spec 前移近期入口后，为守住既有 a11y 合同（PanelFocusOrderSuite「打开必须落声音作用域」）而添加，超出 fix spec 字面范围，在此记录。
- `EventNoticeHealthStore` 增加 `.disabled` 态：表示偏好关闭/隐私挂起，属于诚实默认态；fix spec 只写了 ready/unavailable 两态。
- 修复轮复验追加：非面板路径打开提示时在 `openInteractive` 起点捕获 frontmost app，关闭焦点归还链不再为空兜底；未知 receiver 错误记 `unknown` 码而非猜测码。
- `plan/PLAN-EVENT-SOURCE-PROMPTS.md` 仍未跟踪：修复流程未获 commit 授权，待用户提交。

## 真机待验清单（未验证）

- 自动提示到达不激活 app、不提交/打断中文输入法组字
- 显式展开后 Tab/Shift-Tab/Enter/Space/Esc 与 VoiceOver 播报
- 刘海屏/菜单栏自动隐藏/多屏/全屏 Space 下的顶部位置
- 关闭后的焦点归还（面板入口 vs 原前台 app 两条路径）
- 设置窗口与顶部列表互斥的实际观感
- 连续三条真实 hook 事件不丢、不换当前条；明暗/对比度/Reduce Motion/Transparency 截图
