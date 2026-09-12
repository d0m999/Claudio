# 瞬时提示与「需要你」：实现与验收台账

基线：`a33d077`。日期：2026-09-12。环境：macOS 26.6.2、arm64、Apple Swift 6.3.3。
范围来自本次用户提供的 T1–T8 规格；本次是本地实现，不创建 GitHub issue，不提交、推送、发布或替换运行中的 app。
既有未跟踪计划、HTML 原型和报告未改写。

**总规格尚未正式验收。** 自动化、实际挂载视图、真实宿主回调与分发证据分开记录。
本文不把 synthetic、协议解码、构建成功或 ad-hoc 签名当成生产激活或正式验收。

## 已落地的合同

| 任务 | 实现 |
| --- | --- |
| T1 | ADR 0013 部分替代 ADR 0012；新增待接手提醒、提醒版本术语；schema 1 增加可选 `reason`、`observed_uptime`、`main_session_is_known`，不改 hook command、回执、活动摘要和配置 |
| T2 | 有界 stdin framing 后只解码一次宿主对象，来源和原因独立降级；Codex PermissionRequest 固定授权，Claude Notification 按已识别白名单分类；损坏/超长 ID 不截断复制，旧消息主会话身份未知 |
| T3 | 唯一 `EventNoticeModel` 持有最新和冻结版本，不可变来源载荷按版本共享，归并身份随版本擦除；完整主会话按 epoch、Surface、installation、projectKey、sessionID 归并；不透明 ID 按 UTF-8 字节区分；普通事件无历史/轮播；TTL 擦除每个旧版本来源与时间 |
| T4 | 动作捕获提醒 ID、版本、epoch、installation、能力代次；单在途、独立 3 秒截止、可取消 adapter；取消后回调失效；仅 exactReturnConfirmed 可作为导航移除依据；复制按实际结果反馈 |
| T5 | 独立横幅、五行列表、详情、空态；列表视口 270pt、行最小 54pt，全部 50 项可滚动；未知信息只在详情解释；过期/旧版本禁用动作，显式刷新切换内容；英中和 AX 投影同源 |
| T6 | 零项手动入口；保留统一 Settings 路由和既有焦点归还；动态静默不补播、不打断主动阅读；锁屏、睡眠、会话失活组成原因集合；禁用/退出使 epoch 和动作失效 |
| T7 | ingress 仍由 runtime 唯一持有，移入 Foundation-only GUICore 供真实队列测试；容量 128，每批 32 条或 4ms 后归还未消费消息；一次快照发布；徽标从首次变化起约 100ms 截止，显式移除立即更新；receiver I/O 每次最多 32 条并重验停止状态；原生 source timer 取消即解除闭包，token 释放自动取消 |
| T8 | 本台账与各包回归、实际挂载和资源测量；下面的真实宿主及人工门槛仍待验收 |

生产精确返回和按后续提交自动移除均保持关闭。验证过的测试替身可以启用提交清除，但它不是生产能力证明。
Stop、查看、复制和收起不移除提醒；移除原因区分用户操作、精确返回确认、后续提交、过期、容量和隐私清空。
容量保护当前阅读横幅、详情和在途动作；冻结内容不会因后续更新而延长自身 TTL。
最多保留 50 个最新版本、50 个冻结版本和 1 个瞬时版本；去重与顺序元数据各最多 256 条、最长 30 分钟。
聚焦占位只保留安全身份，来源及发生时间擦除；刷新后可移走占位。零项不代表宿主任务完成。

## 自动化及资源证据

以下执行均返回 exit 0：

| 检查 | 结果 | 本机日志 |
| --- | --- | --- |
| helper Debug executable harness | 3,259 checks，通过 | `/tmp/claudio-attention-delivery-helper.log` |
| helper Release executable harness | 3,222 checks，通过 | `/tmp/claudio-attention-helper-release-final.log` |
| GUI 完整 executable harness | 9,102 checks，通过 | `/tmp/claudio-attention-final-gui.log` |
| 最后一次 GUI 专项 | 291 checks，通过 | `/tmp/claudio-attention-source-free-view.log` |
| GUI Debug product | 通过 | `/tmp/claudio-attention-delivery-debug.log` |
| GUI/helper/LoginItem Release、组装及签名 | 通过，见下方产物表 | `/tmp/claudio-attention-delivery-bundle.log` |
| 修改范围 Swift 严格格式 | 28 个文件通过 | `swift format lint --strict --configuration .swift-format` |
| 本地化 JSON、占位符及注册 | JSON 检查与 GUI harness 通过 | `jq empty`、GUI 日志 |
| selector state、sound-pack candidates | 通过；Python 11 tests | 仓库原 Node/Python 脚本 |
| 工作区 diff 空白检查 | 通过 | `git diff --check` |

完整 GUI harness 通过后，最后的视图观察键收窄以 291 项专项复核；观察键只保留身份和有效性，
不为变化检测额外保留完整来源快照。最终 Debug/Release 产物均使用收窄后的源码。
构建仍有仓库已有的弃用 API / 测试捕获等警告，未将其表述为零警告。
早先与编译并行的一次 GUI 全量执行出现 SoundPacksEditorMutationSuite 两项收敛超时；
未改动该无关实现，之后串行全量通过，不据此宣称长期运行稳定性已验收。

可重复执行：

```bash
swift run --package-path helper claudio-tests
swift run --package-path gui claudio-gui-tests
swift run --package-path gui claudio-gui-tests --event-attention
swift build -c debug --package-path gui --product ClaudioGUI
swift build -c release --package-path gui --product ClaudioGUI
jq empty gui/Sources/ClaudioLocalization/Resources/Localizable.xcstrings
git diff --check
```

专项回归包括：

- 0/1/5/6/50/51 项，完整身份及不完整/parent/旧消息身份，跨项目/安装与 Unicode ID。
- 暂停交叠、完整冻结版本、旧内容独立 TTL、重复 UUID、乱序观察、元数据淘汰及容量阅读保护。
- Stop 不清除，提交清除默认关闭，缺失/相等/倒序/异常/parent 观察不清除。
- 双击、失败、永不完成后超时、取消/隐私/能力代次/版本变化后完成，以及仅确认精确返回才移除。
- 复制成功、失败和陈旧版本拒绝，隐私清空不覆盖用户主动导出。
- 实际调度器中取消或释放 token 后，30 分钟定时闭包捕获对象立即释放；没有被旧 asyncAfter 截止时间挂住。
- 真正挂载 `EventNoticeView` 到 NSPanel：英中、浅深主题 0/1/5/7/50 项、末行滚动、300×180pt 详情、256 字符无断点 ID、滚动后的实际按钮点击与失败反馈；HostingView 固有尺寸不能反向撑高受控窗口。
- 真实 ingress 的 1000 条/10 秒 synthetic 压力；真实 pipe/socket 新旧 wire、半包 stdin、声音失败独立性及 receiver FD 启停。

本轮实测：

| 测量 | 结果与范围 |
| --- | --- |
| 来源启用相对禁用的 helper 增量 | Release 100 对真实 pipe/socket，配对增量 p95 **0.88ms**，门槛 ≤30ms；启用 p95 3.37ms、禁用 p95 3.45ms。配对差值分位数不等于两个分位数之差 |
| stub hook 返回 | Release 100 次 p95 3.26ms；不代表真实播放器和真实宿主 |
| 半包 stdin 不关闭 | 配置 20ms；故障墙钟 21.05ms，含 poll 取整和 OS 调度 |
| 生产 ingress → model | 最后专项 synthetic 1000 条/9.996 秒，p95 **1.534ms**，门槛 ≤100ms |
| 首次徽标 | 最后专项实测 **102.259ms**；100ms 截止另由手动时钟断言，不被持续到达重置 |
| 常驻状态与 timer | 50/50/1 版本、256/256 元数据、128 ingress、至多 3 个模型 timer；隐私清空后计数归零；取消/释放 token 的实际捕获对象释放回归通过 |
| receiver FD | 100 次创建、发送、停止，FD 0..<1024 探测为 **3 → 3 → 3**；持续发送期间停止不迟到交付 |

实际调度延迟另行测量，不把 OS 调度等同于主动延长截止。
原有门槛不变：Release 来源链增量 p95 ≤30ms，accepted envelope 到模型 p95 ≤100ms，原生首次展示目标 ≤250ms。
20ms 是 stdin 的配置读取预算；poll 毫秒取整和 OS 调度可能产生墙钟超出，单独记录而不改预算。

## 独立 Release 产物

使用与最终生产源码哈希一致的独立快照运行原 `scripts/dev-bundle.sh`（GUI `Release -Osize`、
helper/LoginItem Release）。未启动该 app，未写工作区的 `dist/`。体积预算和脚本未修改。

签名后再次执行原 `check-release-size.sh`，全部通过：

| 项目 | 实测 | 原门槛 |
| --- | ---: | ---: |
| GUI arm64 | 5,575,536 B | 5,600,000 B |
| helper arm64 | 2,862,896 B | 3,250,000 B |
| LoginItem arm64 | 72,192 B | 500,000 B |
| 非可执行资源 | 686,919 B | 1,500,000 B |
| bundle 正规文件合计 | 9,197,543 B | 10,850,000 B |

GUI 无导出符号；原 `verify-dev-bundle-signature.sh` 通过。签名前 strip 门槛也通过
（GUI 5,589,912 B）；签名过程会改变 Mach-O 与资源封装大小，因此以上表格采用签名后的复检值。
版本为 `0.0.0-dev`，不是发布版本。

本机证据目录：`/tmp/claudio-attention-validation-5z2tnqov`；源码快照清单为
`validation-source-sha256.json`，构建日志为 `/tmp/claudio-attention-delivery-bundle.log`。
这些临时产物未纳入 Git，可能随系统临时目录清理消失。

- GUI SHA-256：`75069feaa891be8c33674e4371286b3675c31e70ce70b4442517bca34b54eb23`
- helper SHA-256：`b7cffe7e8496f2cb67795f37b6a436dc4c422da00d1e0e32c0d3bb3c71f41d02`

## 尚未验证的人工或外部门槛

| 门槛 | 状态与所需证据 |
| --- | --- |
| 当前已实现 binding 的真实宿主回调 | 未验证；须逐一记录宿主版本、installation、binding 和真实脱敏回执；不能用本文 synthetic 输入代替 |
| 实际旧 GUI / 新 helper、旧 helper / 新 GUI 二进制配对 | 未验证；当前已有 frozen 旧 schema decoder 与旧 wire→新 receiver 的真实 socket 验证 |
| IME、FKA、VoiceOver | 未验证；中文组字不提交/不丢键，FKA 开关下 Tab/Shift-Tab/Enter/Space/Esc，VoiceOver 动作与反馈逐项验收 |
| 原生窗口和焦点 | 部分：挂载布局/鼠标动作已自动验证；运行 app 的 Settings 互斥、外部点击、精确 handback、多屏/小屏/全屏 Space/刘海和辅助显示设置未人工验收 |
| 锁屏/睡眠/失活交叠 | 模型回归与接线编译已验证，真实系统交叠未验证；只恢复一个原因不得重启 receiver |
| 真实音频 | 未验证；自动化只验证视觉与声音结果独立，不能代替扬声器/真实宿主声音验收 |
| 原生首次显示 ≤250ms、长期 RSS | 未测；队列到模型延迟、集合/计时器上限、receiver FD 循环不能代替这两个门槛 |
| Intel、最低 macOS 12 | 未验证；当前只有 arm64/macOS 26.6.2 环境 |
| Developer ID、universal、notarization、分发与正式验收 | 未验证；独立临时目录的 ad-hoc bundle 不建立这些结论 |

独立的 `verify-settings-experience.sh` 要求 clean HEAD，本次保留未提交工作，未将该脚本记为通过。
Settings 路由和窗口所有权的既有回归随 GUI 全量 harness 执行；正式提交后的集成台账需另行收集。

## 协议及系统依据

Claude 原因名单与主/子会话字段来自官方 [Notification](https://code.claude.com/docs/en/hooks#notification)
及 [common input fields](https://code.claude.com/docs/en/hooks#common-input-fields)；Codex 子会话结构参考
[官方 hooks 源码](https://github.com/openai/codex/blob/main/codex-rs/hooks/src/events/common.rs)。这些是协议依据，不是当前激活证据。

Apple 将 [sessionDidResignActiveNotification](https://developer.apple.com/documentation/appkit/nsworkspace/sessiondidresignactivenotification)
定义为用户会话切出。因此它与锁屏原因分开处理。当前本机 loginwindow 二进制包含
`com.apple.screenIsLocked` / `com.apple.screenIsUnlocked`，接线使用相应分布式通知；这仅是本机静态核对，
不能替代真实锁屏测试，也不构成 Apple 对这两个通知名的公开兼容保证。
