# Claudio 多分支整合覆盖台账（2026-09-07）

本台账是本地整合分支的审计记录。正式输入固定为已落地 PR #154 的
`origin/main@50bb124` 与 PR #138 的远端固定头 `8262432`；`50bb124` 的第二父提交为
PR #154 整合头 `bf7135e`，两者 tree 均为 `0dcfde5`。本地 stale 分支
`codex/architecture-deepening-20260902@b9f4bb7` 不作为输入。整合顺序为先 #154、后
#138，最终提交保持 Git merge commit 形态。PR #154 已由 GitHub merge commit `50bb124`
落地；没有执行 PR #138 push/merge、release 或 issue 状态变更。

## Issues #126–#137 覆盖

| Issue | 来源与最终 owner/path | compiled evidence | native / external evidence | 处置 |
|---|---|---|---|---|
| #126 umbrella | `8262432`; `SoundPacksEditorOwner`、`SettingsPresentationSession`、`SettingsRootView` | `SoundPacksEditorOwnerSuite`、`SettingsPresentationTargetSuite`、`SettingsPresentationLifecycleSuite` | 原生九页矩阵、真实宿主/provider 未验证 | `included` |
| #127 characterization | `agent/arch-127-sound-characterization@c46ce5e`; opaque editor actions/permits 与既有 low-level writers | `SoundPacksEditorInterfaceSuite`、`SoundPacksEditorMutationSuite`、`SoundPacksEditorAsyncOperationSuite`、`SoundPackLibraryMutationTransactionSuite` | 原生 Sounds/真实音频未验证 | `included` |
| #128 Settings characterization | `agent/arch-128-settings-characterization@bc37726`; typed routes、focus debt、mount recorder | `SettingsNavigationSuite`、`SettingsRootInteractionSuite`、`SettingsPresentationTargetSuite`、`SettingsPresentationLifecycleSuite` | 键盘/VoiceOver native matrix 未验证 | `included` |
| #129 deep editor interface | `agent/arch-129-editor-interface@a4184f3` 与 PR #138 owner chain；`SoundPacksEditorOwner.presentation/send/perform` | `SoundPacksEditorInterfaceSuite`、`SoundPacksEditorMutationSuite`、`SoundPacksEditorAsyncOperationSuite`、`SoundPacksEditorNativeTargetSuite`、`SoundPacksEditorAnnouncementGapRedSuite` | 原生 effect adapter 未做真实设备验收 | `included` |
| #130 native Sounds | `agent/arch-130-native-sounds@dbd7d70` 的语义由最终 owner/native adapter 重新落地；`SoundPacksEditorNativeEffects.swift`、`SoundPacksWindowView.swift` | `SoundPacksEditorNativeEffectsSuite`、`SoundPacksEditorViewSuite`、`SoundPacksWindowAccessibilitySuite`、`SoundPacksRefreshSuite` | 本地 `NSSound` 试听与 VoiceOver 未验证 | `ported` |
| #131 Events/AI | `8262432`；`EventSettingsWindowView`、`EventSettingsAICueView`、owner adoption interface | `SoundPacksEditorAsyncOperationSuite`、`PreviewFixturesSuite`、`SettingsPresentationLifecycleSuite` | 真实 provider、真实音频未验证 | `included` |
| #132 shell callers | `50bb124`（PR #154 head `bf7135e`）+ `8262432`；`MenuBarController`、`SettingsWindowController`、shared native effects dispatcher | `ViewWiringSuite`、`PanelPresentationSuite`、`SettingsPresentationLifecycleSuite`、`SoundPacksEditorAccessibilityPostingSuite` | AppKit handback 的完整人工旅程未验证 | `included` |
| #133 deletion gate | `8262432`；删除 raw editor seam、旧 Usage view/model 与重复 owner | `SourceScannerSuite`、`SettingsPresentationTargetSuite`、`SoundPacksEditorViewSuite`、全 GUI harness | release symbol/包体已在最终整合 gate 验证 | `included` |
| #134 Settings target | `8262432`；`ClaudioSettingsPresentation` target 与非 optional dependencies | `SettingsPresentationTargetSuite`、GUI target/product debug build | 双架构与签名未验证 | `included` |
| #135 nine-page tree | `8262432`；`SettingsRootView` 内部 exhaustive route switch，九页真实 mount | `SettingsPresentationTargetSuite`、`SettingsNavigationSuite`、`DisplayPreferencesSuite`、`ActivityDiagnosticsSuite` | 九页双语/双主题尺寸矩阵未验证 | `included` |
| #136 session/controller | `8262432`；`SettingsPresentationSession` 单一 route/lifecycle/focus/announcement owner，retained controller | `SettingsPresentationLifecycleSuite`、`SettingsRootInteractionSuite`、`SettingsPresentationTargetSuite` | 原生焦点归还与 VoiceOver 未验证 | `included` |
| #137 replacement/full gates | `50bb124`（PR #154 head `bf7135e`）+ `8262432`；删除同义 source scans，保留窄 composition/release checks | helper/gui executable harness、debug/release builds、catalog、benchmark、bundle/size checks | formal acceptance、production readiness 未验证 | `included` |

PR #154 的现行 UI 行为以已落地主干 merge `50bb124`（第二父提交 `bf7135e`）为准：Panel 使用 shared
`ActivityDiagnosticsModel`，固定 compact Display，Activity 的 failure/clear/recovery 状态由
`ActivityDiagnosticsView` 继续渲染。#138 冲突处理保留 typed Settings/session/editor ownership，
没有恢复字号或 Panel 宽度写路径。

## 架构分支去重与处置

| 分支 tip | ancestry / patch 审计 | 处置理由 |
|---|---|---|
| `agent/arch-127-sound-characterization@c46ce5e` | `8262432` ancestor | `included`；其 characterization 已进入最终 owner/compiled suites |
| `agent/arch-128-settings-characterization@bc37726` | `8262432` ancestor | `included`；其 Settings seam 已进入最终 target/session suites |
| `agent/arch-129-editor-interface@a4184f3` | `8262432` ancestor | `included`；最终 PR #138 已包含该接口深化链 |
| `agent/arch-129-async-red@2affaf5` | patch-equivalent | `patch-equivalent`；red-only async identity 断言由当前 `SoundPacksEditorAsyncOperationSuite` 覆盖 |
| `agent/arch-129-gap-red@3bf972c` | patch-equivalent | `patch-equivalent`；semantic announcement/gap red 合同已在当前 suites 中保留 |
| `agent/arch-129-impact-red@8bbb480` | patch-equivalent | `patch-equivalent`；mutation impact 的 owner/refresh 合同已由当前 mutation suites 覆盖 |
| `agent/arch-129-native-target-red@a06a7f9` | patch-equivalent | `patch-equivalent`；native target facts 已由当前 native-target suite 覆盖 |
| `agent/arch-129-presentation-red@c295434` | patch-equivalent | `patch-equivalent`；presentation red 合同已由当前 interface/presentation tests 覆盖 |
| `agent/arch-129-sync-red2@c439ac3` | semantic-equivalent | `da06585` 的额外 mutation-only red 深化没有单独合入；其行为由当前 `SoundPacksEditorMutationSuite` 的 coherent receipt/lifecycle checks 覆盖 |
| `agent/arch-130-announcement@389bc04` | semantic diff | `ported`；semantic announcement、priority、native adapter 与 retained controller 由 PR #138 的最终接口重新表达 |
| `agent/arch-130-interface-gaps@70148a8` | semantic diff | `semantic-equivalent`；empty-library recovery、durable status、signed preview 与 announcement priority 已存在于最终 owner/presentation |
| `agent/arch-130-native-sounds@dbd7d70` | semantic diff | `semantic-equivalent`；该分支是旧树上的整段 native view 变体，最终树保留 owner-only view、native dispatcher 与 compiled adapter tests |
| `agent/issue129-transaction-matrix-review@f65d135` | patch-equivalent | `patch-equivalent`；transaction matrix 已由当前 `SoundPackLibraryMutationTransactionSuite` 覆盖 |

因此没有 `unclassified` 或 `requires-port` 项；red-only 分支没有新增 production write path，
没有单独 merge。归档的未提交 native-sounds 草稿仅保存为本地 commit
`350f01f`（`archive/arch-130-native-sounds-20260907-74cc6208`），不属于整合输入，也不 push。

## 当前验证状态

已通过：helper harness `2801/2801`、GUI harness `8394/8394`、ClaudioSettingsPresentation 与
ClaudioGUI 的 Debug/Release product/target builds、localization JSON、`git diff --check`、
100-pack sound-pack benchmark（cold p95 `238.658ms`、cached p95 `0.600ms`、incremental p95
`57.200ms`，`MacBookPro17,1` / Apple M1 / arm64 / APFS）。`verify-settings-experience.sh`
已在 clean final integration HEAD 通过，包含
required suite registration、四项构建、dev bundle/signature、release size 与 strict format
baseline（baseline `1519`、HEAD `1328`）。

尚未由自动化冒充的证据：九页双语×双主题 native layout、Full Keyboard Access、VoiceOver、
Increase Contrast、Reduce Transparency、Reduce Motion、真实 `NSSound` 试听、真实 Provider/host
callback、Intel、Developer ID、公证、production/release acceptance。
