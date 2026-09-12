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

## 四项 review 修复验证（2026-09-12）

本节为本轮证据，前文保留为上一修复轮的历史记录。范围：[spec #171](https://github.com/d0m999/Claudio/issues/171)
及 tickets #172–#175；基线 `09628dbe9120ba1590343a28130a5ae375c6fbcf` 到未提交工作区。
环境：macOS 26.6.2、arm64；未 commit、push、部署、发布或关闭 issue。

| Finding | 最小修复与回归证据 |
|---|---|
| #172 Settings → 提示焦点债务丢失 | 在 Settings close 前转交完整延迟恢复动作，保留最新外部 app 与原面板目标；提示仅首次交互时捕获，关闭按 key ownership 消费，隐私隐藏释放。数量入口也接入同一交互路径。tracker 行为回归与 executable 跨文件接线检查通过；真实宿主焦点归还仍未验证。 |
| #173 过期占位显示发生时间 | 模型从唯一 notice 派生时间，TTL 擦除 notice 时同步失去时间；过期投影返回 nil。当前项、冻结选中占位及英中投影回归从 5 个失败变为通过。 |
| #174 180pt 详情被裁切 | 展开内容共用一个滚动区域。实际 NSHostingView/NSPanel 挂载回归中，旧视图需要 251pt、列表视口为零且 session ID 在滚动区外；修复后 root 不超过 180pt，256-byte session ID 可滚动到达，底部来源按钮及数量入口的合成原生点击通过。fixture 同时包含待刷新提示与容量溢出。此证据不等于物理键盘或 VoiceOver 验收。 |
| #175 机器本地链接 | 本机原型、任务和 QA 引用改为仓库内等效章节；目标计划的机器路径扫描无命中，章节锚点已核对。 |

| 门禁 | 本轮结果 |
|---|---|
| `swift run --package-path helper claudio-tests` | 2854 checks passed |
| `swift run --package-path gui claudio-gui-tests` | 最终 8864 checks passed |
| 定向回归与导航重复验证 | 77 条 handback/model/presentation 检查通过；追加 100 次导航测试后共 877 checks passed |
| GUI Debug / Release 构建 | 两者通过；本地 bundle 同时重建 Release helper 与 LoginItem |
| `jq empty gui/Sources/ClaudioLocalization/Resources/Localizable.xcstrings` | 通过，无新增本地化词条 |
| selector state / candidates 脚本 | Node state seam 通过；Python 11 tests 通过 |
| 严格格式检查 | 修改的 Swift 文件全部通过；相对固定基线无新增诊断（全仓既有诊断 1322 → 1315） |
| `bash scripts/test-settings-format-diagnostics.sh` | 通过 |
| `bash scripts/dev-bundle.sh` | arm64 本地 ad-hoc bundle 构建与签名检查通过；未启动替换正在运行的 app |
| `bash scripts/check-release-size.sh dist/claudi0.app` | GUI 5,540,528 / 5,600,000 B，零导出；bundle 正规文件总计 9,154,012 / 10,850,000 B，通过 |
| `git diff --check` | 通过 |
| `bash scripts/verify-settings-experience.sh 09628dbe9120ba1590343a28130a5ae375c6fbcf` | 因工作区非 clean HEAD 按设计退出；组件测试、构建、bundle、格式诊断比较已分别执行。未为绕过该限制提交或删除用户内容。 |

测试同步修正：前两次完整 GUI 运行在既有 `SessionNavigationSuite` 的固定 1ms 等待断言失败。
定向诊断表明原生 SwiftUI 测试后，导航已收到正确 target，但测试先于导航内部的 `Task.yield()` 完成而恢复；
稍后仍返回 succeeded。该测试改为在 1 秒上限内观察完成状态，原成功与 target 断言保留；
未改导航生产逻辑。此后定向 100 次重复与完整 harness 均通过。

仍未验证：真实 Settings → 提示 → 宿主/面板的键盘焦点、IME、FKA、VoiceOver、真实宿主回调、
多屏/full-screen、真实音频、Intel 架构、Developer ID 签名、公证和正式验收。
