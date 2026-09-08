# Release 体积预算

发布流程在 codesign 前执行 `scripts/check-release-size.sh`。门禁按 Mach-O 架构数线性放大：

- `claudi0-app`：每架构最多 `5,500,000 B`；
- `claudi0` helper：每架构最多 `3,250,000 B`；
- macOS 12 内嵌 `claudi0-login-item`：每架构最多 `500,000 B`；
- app 内其余正规文件合计预留 `1,500,000 B`；
- GUI、helper 与 LoginItem 必须包含相同架构；`Contents/Resources/bin/claudio` 必须是精确指向同目录 `claudi0` 的相对符号链接。LoginItem 的固定 bundle identity、executable 和 macOS 12 floor 也会在签名前失败关闭。

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
