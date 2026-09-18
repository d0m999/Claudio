# Release 体积预算

发布流程在 codesign 前执行 `scripts/check-release-size.sh`。门禁按 Mach-O 架构数线性放大：

- `claudi0-app`：每架构最多 `6,500,000 B`；
- `claudi0` helper：每架构最多 `3,250,000 B`；
- macOS 12 内嵌 `claudi0-login-item`：每架构最多 `500,000 B`；
- app 内其余正规文件合计预留 `1,500,000 B`；
- GUI、helper 与 LoginItem 必须包含相同架构；`Contents/Resources/bin/claudio` 必须是精确指向同目录 `claudi0` 的相对符号链接。LoginItem 的固定 bundle identity、executable 和 macOS 12 floor 也会在签名前失败关闭。
- GUI 每个切片不得含产品定义的 external symbol；Xcode 16.4 即使在
  `-no_exported_symbols` 与完整 `strip` 后仍可能保留工具链拥有的
  `__mh_execute_header` Mach-O 主程序头哨兵，门禁只精确允许该哨兵。

## 2026-08-06 基线

arm64 Release bundle 在剥离本地符号、移除重复 helper Mach-O 后：

| 项目 | 变更前 | 变更后 |
|---|---:|---:|
| 可执行 payload 合计 | `14,365,224 B` | `4,867,696 B` |
| 减少 | — | `66.1%` |
| GUI | — | `3,029,656 B` |
| helper | — | `1,838,040 B` |
| 非可执行资源 | — | `303,285 B` |
| app bundle 正规文件合计 | — | `5,170,981 B` |

同一流程生成的 arm64 + x86_64 universal bundle 为：GUI `6,142,616 B`、helper `3,771,352 B`、非可执行资源 `303,285 B`、bundle 正规文件合计 `10,217,253 B`，均在对应的双架构预算内。门禁逐架构检查 Mach-O slice，资源预算独立于可执行文件剩余额度；负向测试把资源预算压到 `1 B` 时会按预期拒绝。体积门禁只约束最终 app bundle，不把 developer-only benchmark product 计入分发物。

## 2026-08-23 功能增长重基线

在保留 8 月 6 日基线之后新增的本地化、WorkBuddy 集成、激活回执与无障碍界面合同的前提下，
使用 `91eb5fd` 的 arm64 Release 产物重新测量。下列数字均来自 `strip -x` 之后、codesign 之前；
这与 CI 和 release workflow 执行体积门禁的时点相同。

| 项目 | arm64 实测 | 新预算 | 基线占预算 |
|---|---:|---:|---:|
| GUI | `4,223,128 B` | `5,500,000 B` | `76.8%` |
| helper | `2,466,184 B` | `3,250,000 B` | `75.9%` |
| 非可执行资源 | `435,818 B` | `1,000,000 B` | `43.6%` |
| 单架构 app bundle 正规文件合计 | `7,125,130 B` | `9,750,000 B` | `73.1%` |

同一源树和 Swift 6.3 工具链的交叉构建也通过了真实 universal 门禁：

| 项目 | arm64 slice | x86_64 slice | universal 文件 |
|---|---:|---:|---:|
| GUI | `4,223,128 B` | `4,348,424 B` | `8,581,272 B` |
| helper | `2,466,184 B` | `2,563,896 B` | `5,038,472 B` |

非可执行资源仍为 `435,818 B`，universal app bundle 正规文件合计为 `14,055,562 B`，低于
双架构总预算 `18,500,000 B`。

本次只重定默认预算，没有放宽逐切片、架构一致性、资源独立上限、legacy helper 符号链接或
bundle 总量门禁。GUI 与 helper 分别保留 `1,276,872 B` 和 `783,816 B` 余量；资源预算保持
不变。本地 Swift 6.3 交叉构建不能替代首次 GitHub Xcode 16.4 release 的真实回执；正式流程
仍会逐架构失败关闭。环境变量覆盖继续只用于受控测试和本地探针，默认 CI 路径不设置这些
覆盖值。

## 2026-09-04 内置声音资源重基线

加入真实乐器录音候选 `soft-mallet` 后，本机 arm64 `scripts/dev-bundle.sh` 在原
`1,000,000 B` 资源预算下以 `1,297,007 B` 失败关闭。新包采用 44.1kHz / 16-bit PCM WAV，
是为了保留自然衰减和可逐样本验证的全零尾部；没有改用低码率有损压缩绕过门禁。资源默认
预算据此重定为 `1,500,000 B`，仍与 Mach-O 预算和 bundle 总量预算独立。

| 项目 | arm64 实测 | 新预算 | 占用 |
|---|---:|---:|---:|
| GUI | `5,034,728 B` | `5,500,000 B` | `91.5%` |
| helper | `2,567,800 B` | `3,250,000 B` | `79.0%` |
| LoginItem | `54,368 B` | `500,000 B` | `10.9%` |
| 非可执行资源 | `1,297,007 B` | `1,500,000 B` | `86.5%` |
| 单架构 app bundle 正规文件合计 | `8,953,903 B` | `10,750,000 B` | `83.3%` |

这次重基线只覆盖本机 arm64、ad-hoc 签名前的同口径体积门禁。它不建立 universal 双架构、
Developer ID 签名、公证或正式 release 产物证据；CI 仍会对真实产物重新执行同一个失败关闭
门禁。

## 2026-09-09 Settings 与声音包编辑器深化归因

`44bc846` 在 GitHub `macos-15` / Xcode 16.4 的 CI 上把 arm64 GUI 推到 `5,632,280 B`，
超过既有 `5,500,000 B` 预算 `132,280 B`。同机 Swift 6.3.3、相同 `-Osize` 与完整 `strip`
口径下复测父提交和目标提交，确认这不是资源增长或陈旧构建产物：

| 项目 | arm64 GUI | 相对父提交 |
|---|---:|---:|
| 父提交 `592b74e` | `5,196,360 B` | — |
| `44bc846` 修复前 | `5,419,256 B` | `+222,896 B` |

链接图按 live symbol 归属统计，`ClaudioGUICore` 净增 `217,304 B`；其中深化后的
`SoundPacksEditorOwner.swift` 与新增 `SoundPacksEditorPresentation.swift` 合计净增约
`210,672 B`。移动进 `ClaudioSettingsPresentation` 的 Settings 视图与剩余 `ClaudioGUI`
合计反而减少约 `25,097 B`。这两项合计解释 `192,207 B` 净增，距离 GUI 总增量仍有
`30,689 B` 未按 source owner 归因；`210,672 B` 是 `ClaudioGUICore` 的子集，不能重复相加。
因此现有链接图只证明新增 target 不是主要代码段回归，不构成完整逐字节归因。

GitHub 与本机的额外差值尚未经过同一 commit、两套工具链的受控对照。Xcode 16.4 与本机
Swift 6.3.3 的产物差异是当前推测，不是已经隔离验证的原因；两边能共同证明的事实只有：最终
app 当时仍携带不供外部二进制调用的 Swift 导出链接元数据。

修复在 `ClaudioGUI` executable target 上仅为 Release 配置传入
`-Xlinker -no_exported_symbols`。它位于 `gui/Package.swift`，因此 CI、开发 bundle、双架构
release workflow 和直接 SwiftPM Release 构建在各自实际运行时消费同一合同。push / PR CI
已经声明 Release build、开发 bundle 组装与共享门禁；workflow 定义存在不等于某个尚未运行的
commit 已取得远程 CI 回执。修复没有提高预算，也没有禁用 Swift 反射。

签名前、完整 `strip` 后的同口径文件总量如下：

| arm64 GUI | 修复前 | 修复后 | 变化 |
|---|---:|---:|---:|
| 签名前文件总量 | `5,419,256 B` | `5,043,944 B` | `-375,312 B` |

修复后在现有预算下保留 `456,056 B` 余量。

另一组 ad-hoc 签名后的 Mach-O 段对照中，`__TEXT`（`4,472,832 B`）、`__text`
（`3,450,536 B`）、`__DATA_CONST`（`147,456 B`）和 `__DATA`（`360,448 B`）保持不变，
`__LINKEDIT` 从 `638,976 B` 降为 `278,528 B`，变化 `-360,448 B`。它与上表签名前文件总量
属于不同阶段，两个降幅相差的 `14,864 B` 不能直接归给导出元数据、签名或对齐；需要同一签名
阶段的完整段清单才能继续对账。现有证据支持「代码与数据段未变、导出链接负载减少」，不支持
「文件总量变化已逐字节完整归因」。

同一源树的本机交叉构建得到 `5,184,000 B` 的 x86_64 slice；按 release workflow 顺序先合成
再 strip 的 universal GUI 为 `10,237,672 B`，重新拆出的 arm64 与 x86_64 slice 分别仍是
`5,043,944 B` 和 `5,184,000 B`。共享 release bundle gate 会对 strip 后的每个 GUI slice
执行 defined external symbol 检查：任何非空结果或检查工具失败都失败关闭。该门禁把 manifest
配置与最终产物事实分开验证，但这些数据和自动化仍不等同于 GUI 原生启动、Intel 真机运行、
Developer ID 签名、公证或正式 release；本次没有执行 Release GUI 启动 smoke，相关运行时证据
保持未验证。

## 2026-09-12 顶部事件来源提示重基线

加入 C 方向顶部事件来源提示、私有 datagram receiver、近期记录模型和设置接线后，本机
arm64 的 `scripts/dev-bundle.sh` 在原 `5,500,000 B` GUI 门禁下以 `5,519,464 B` 失败关闭。
按相同 `-Osize`、完整 `strip`、签名前口径将 GUI 默认预算重定为 `5,600,000 B`；没有改变
helper、LoginItem、资源、架构一致性或无导出符号门禁。

| 项目 | arm64 实测 | 当前预算 | 余量 |
|---|---:|---:|---:|
| GUI | `5,519,464 B` | `5,600,000 B` | `80,536 B` |
| helper | `2,857,144 B` | `3,250,000 B` | `392,856 B` |
| LoginItem | `54,368 B` | `500,000 B` | `445,632 B` |
| 非可执行资源 | `594,542 B` | `1,500,000 B` | `905,458 B` |
| 单架构 app bundle 正规文件合计 | `9,025,518 B` | `10,850,000 B` | `1,824,482 B` |

这是本机 arm64、ad-hoc 签名前的本地走查证据，不等同于 universal 双架构、Developer ID
签名、公证或真实宿主/原生 UI 验收；CI 仍会对最终 release 产物重新执行同一失败关闭门禁。

## 2026-09-13 Xcode 16.4 CI 产物重基线

`fe3ce99` 在固定的 GitHub `macos-15` / Xcode 16.4 CI 上，以 Release `-Osize`、完整
`strip`、签名前的共享 `scripts/check-release-size.sh` 口径生成 `5,820,216 B` 的 arm64 GUI，
超过 `5,600,000 B` 旧预算 `220,216 B`。同一生产源码此前在本机工具链下得到
`5,575,552 B`；两者相差 `244,664 B`。这组证据确认旧预算不能容纳固定发布工具链的真实
产物，但没有用同一构建机隔离工具链以外的变量，因此不把差值进一步归因给编译器或链接器。

GUI 每架构默认预算据此重定为 `6,000,000 B`，为 Xcode 16.4 实测保留 `179,784 B`
（约 `3.0%`）余量。helper、LoginItem、非可执行资源预算，以及逐切片、架构一致性、GUI
无产品导出符号和 bundle 总量门禁均保持不变；CI 和 release workflow 也不设置环境变量绕过默认值。
该远端 arm64 CI 回执不等同于 universal 双架构、Developer ID 签名、公证或正式 release 验收。

同一固定工具链随后在 `c164aea` 的 `dev-bundle.sh` 组装阶段报告唯一 defined external 为
`__mh_execute_header`，而本机较新工具链的同口径产物没有报告该符号。门禁现按语义区分
工具链主程序头哨兵与 Claudio 产品导出：只允许精确的 `__mh_execute_header`，并继续对任何
额外 Swift/业务符号或 `nm` 检查失败关闭。这是工具链兼容性修复，不取消
`-no_exported_symbols`，也不把未知导出加入允许列表。

## 2026-09-18 GUI 体积重基线（B2，本地实施）

**触发与回执**。`c19bddf` 在 GitHub `macos-15` / Xcode 16.4（Swift 6.1.2）CI 上，以
Release `-Osize`、完整 `strip`、签名前的共享 `scripts/check-release-size.sh` 口径实测
arm64 GUI **`6,273,016 B`**，超过 `6,000,000 B` 预算 **`273,016 B`（`+4.55%`）**。回执
来自 [run 35358455808](https://github.com/d0m999/Claudio/actions/runs/35358455808)（PR #199 临时分支 `rc/size-receipt-c19bddf`，探针分支已按流程
关闭并删除）；该分支树与 `c19bddf` 的产品部分（`gui/Sources`、helper、manifest、资源、
脚本）零差异，唯一差别是 `SettingsSoundsLayoutSuite.swift` 的测试探针加固（测试 target
不进入货运二进制），因此回执记名 `c19bddf`。harness 全绿后失败在 "Assemble local
release-layout app" 的共享门禁；GUI 先于 helper 检查，helper、LoginItem 与非可执行资源
未到达该步（本机同源树实测参考：helper `2,970,368 B` / `3,250,000 B`、LoginItem
`72,192 B` / `500,000 B`、非可执行资源 `680,832 B` / `1,500,000 B`，均在预算内）。

**三组受控 CI↔本机锚点**（回应 2026-09-09 节的开放问题）：

| 锚点提交 | CI 实测（Xcode 16.4） | 本机实测（CLT Swift 6.3.3 / SDK 26.5） | 差值 |
|---|---:|---:|---:|
| `6617b5d`（09-16，门禁最后绿回执） | `5,923,048 B` | `5,692,752 B` | `+230,296 B`（`+4.05%`） |
| `bb7bafa1`（09-17，门禁首红） | `6,206,664 B` | `5,992,864 B` | `+213,800 B`（`+3.57%`） |
| `c19bddf`（09-18 HEAD） | `6,273,016 B` | `6,059,216 B` / `6,059,224 B`（两次独立测量） | `+213,792 ~ +213,800 B`（约 `+3.53%`） |

`bb7bafa1 → c19bddf` 的批增量在两套工具链上逐字节一致：CI `66,352 B`，本机
`66,352 ~ 66,360 B`（两次独立测量，±8 B）。源码增量与工具链差值可分离，下述主题归因
（本机刻度）可平移到 CI 刻度。仍非单机隔离：两侧工具链与 SDK 同时变化，因此与
2026-09-09 节保持同一克制口径——不把差值进一步归因给编译器或链接器，只确立
「CI 刻度比本机系统性大 `+3.5% ~ +4.1%`，预算必须画在 CI 刻度上」。

**归因**（本机刻度主题阶梯，`923491e` → `c19bddf` 端到端累积 `+469,280 B`；另一独立
测量链得 `+469,272 B`，±8 B 属测量噪声，各主题 Δ 在该噪声下稳健）：

| 主题 | 提交 | 本机 Δ | 占累积 |
|---|---|---:|---:|
| SenseAudio 集成簇 | `2dbb645` + `8330a3c` + `9f363a4` | `+52,768 B` | `11%` |
| 事件来源提示 config 恢复 | `6617b5d` | `+50,040 B` | `11%` |
| 文件事务加固 ×2 | `f74ad9e` + `470e585` | `+116,616 B` | `25%` |
| 包级 AI cue 落子 | `470e585 → 5ae5bc0`（4 提交，主体为 `5ae5bc0`） | `+150,352 B` | `32%` |
| AI cue 采纳加固 | `7571521` | `+33,144 B` | `7%` |
| Sounds 设置布局对齐 | `ae40823` | `+24 B` | ~0 |
| 面板 UX 修复批（PR①–③ 及收尾） | `5eacc5e..c19bddf` | `+66,336 B` | `14%` |

AI cue 主题合计 `+183,496 B`（`39%`），文件事务与配置恢复簇合计 `+166,656 B`
（`36%`），两者占累积增长的 `75%`。全部为已评审功能交付（ADR 0006/0007/0011/0014/0015
链、文件事务加固、面板 UX 修复批），非膨胀性回归；`-no_exported_symbols` 与完整
`strip` 已生效（`__LINKEDIT` 仅 `294,912 B`，正常水位），无工具性余量可回收。门禁首红
（`bb7bafa1`，09-17）发生在 UX 修复批开始之前；UX 批净增仅 `+66,336 B`（PR② 的读回
清除逻辑为零字节成本），不是本次超限的原因。

**新预算**：GUI 每架构默认预算重定为 **`6,500,000 B`**。计算依据：CI 实测
`6,273,016 B` × 1.03 ≈ `6,461,206 B`（09-13 先例余量率 3.09% 与 3% 相差不足 0.1 个
百分点，圆整后同值），按仓库既有 `0.1M` 粒度惯例圆整（`5,500,000` / `5,600,000` /
`6,000,000` 同款），余量 `226,984 B`（`3.62%`）。helper、LoginItem、非可执行资源预算
不变；app bundle 总量上限为派生值（`check-release-size.sh:136` = 三可执行预算之和 ×
架构数 + 资源预算），自动跟随为单架构 `11,750,000 B`，无需独立修改。

**配套修改清单**（本地第二笔提交；与 `c88c02a`「align Swift toolchain and
size budgets」的预算部分同款实践，4 个文件 6 处）：

| 位置 | 现值 | 改为 |
|---|---|---|
| `scripts/check-release-size.sh:15` | `6000000` | `6500000` |
| `docs/ENV.md:13` | ``default `6000000` `` | ``default `6500000` `` |
| `docs/performance/release-size-budget.md:5` | `6,000,000 B` | `6,500,000 B` |
| `gui/Tests/ClaudioGUICoreTests/ReleaseLayoutSuite.swift:1188` | `6000000` 字面量 | `6500000` |
| `ReleaseLayoutSuite.swift:1196` | ``default `6000000` `` | ``default `6500000` `` |
| `ReleaseLayoutSuite.swift:1202` | `` `6,000,000 B` `` | `` `6,500,000 B` `` |

本文件历史节中的 `6,000,000 B` 为当时的预算与实测记录，不随本次重基线修改。`swift run --package-path gui claudio-gui-tests`
验证脚本、环境说明与断言的一致性。

**明确排除的做法**：

- 把 GUI 代码挪入 `Contents/Frameworks/*.dylib` 使 GUI slice 缩小、payload 落入非可执行
  资源预算（现用 `680,832 B` / `1,500,000 B`）——只挪预算名目、不减分发体积，属规避门禁。
- 按本机刻度画线（如 `6,100,000 B`）——CI 刻度系统性大 `+3.5% ~ +4.1%`，本机尺画线
  在上述 CI 锚点上仍会失败；上表三组锚点即教训记录。
- 以「拆 AI cue 两个设置视图的重复」作为转绿手段——本机尺度可回收约 `60,000 B`，回收后
  CI 仍超约 `213,000 B`。该重构是真实的代码卫生债，定位为预算落地后的独立还债项（带
  回归测试），不阻塞本次预算重基线、也不被本次重基线豁免。

**CI 布局探针修复**：`c19bddf` 的 GUI harness 在 `SettingsSoundsLayoutSuite` 上失败。
run 时间线证据：树与 `c19bddf` 相同的空提交 `9d30b21` 失败于 "Run GUI harness"——
无头 runner 的虚拟屏幕高度不足 820pt 时，AppKit 按可见区压缩探针窗口，破坏
1240×820 布局合同的前提；加固 1（`706da76`，初始化后 enforce 请求尺寸）单独不够，
加固 2（`c92fe6b`，`UnconstrainedProbeWindow` 重载 `constrainFrameRect` 拒绝屏幕适配）
补全后该探针分支的 harness 才绿。本工作分支第一笔提交合并两项测试探针修复，保留
1240×820 断言，不带入空提交 `9d30b21`，不改产品源码。它与预算提交供同一个 PR 审查；
该分支的新 CI 结果须在获得推送授权后重新取得，不能借用旧探针分支的通过回执。

**注记（工具链）**：`.github/workflows/ci.yml` 的 Helper 与 GUI job 均通过
`DEVELOPER_DIR: /Applications/Xcode_16.4.app/Contents/Developer` 选择 Xcode 16.4，
并检查 Swift 6；本次三组 CI 锚点使用同一 `Swift 6.1.2`。若将来主动变更 CI
工具链或 runner 不再提供该 Xcode 路径，须重新测量并锚定预算。

**证据边界**：PR #199 的既有回执为远端 arm64 单架构、签名前共享门禁口径，只作为
本次重基线依据。本地提交的新分支 CI 尚未验证；原生界面验收、universal 双架构、
Developer ID 签名、公证与正式 release 验收各需独立证据。

**本地实施验证（仅 arm64）**：本分支使用 CLT Swift 6.3.3 / SDK 26.5，
helper executable harness `3488/3488`、GUI executable harness `10339/10339` 通过；
GUI Debug 与 Release 构建、`jq empty` 和 `git diff --check` 通过。无预算环境变量覆盖的
`bash scripts/dev-bundle.sh` 在签名前通过共享体积门：GUI `6,059,208 / 6,500,000 B`，
helper `2,969,496 / 3,250,000 B`，LoginItem `54,368 / 500,000 B`，非可执行资源
`700,939 / 1,500,000 B`，bundle 合计 `9,784,011 / 11,750,000 B`。
签名后再次运行 `bash scripts/check-release-size.sh dist/claudi0.app` 通过，GUI 为
`6,042,112 / 6,500,000 B`；`codesign --verify --deep --strict` 与
`scripts/verify-dev-bundle-signature.sh` 均通过。该本地 ad-hoc app 只提供单架构检验，
新分支的 Xcode 16.4 CI 和正式分发验收仍需独立回执。
