# PLAN — 退役事件页旧提示音采用路径（完成 ADR 0016 迁移）

基线：`HEAD = 60fa711`（`feat(gui): localize actionable panel errors`，18 文件 / +914−115）。
上一基线 `78fafac` 时的 Panel 在制品**已提交**（非丢失、非 stash）；本计划 §1 的锚点全部位于该提交
**未触及**的 AI 提示音路径（`git show --name-only 60fa711` 无任何 AI cue 文件），故行号不变。
依据：ADR 0016（采用目标 = `packID + Event`）、审查报告 v4（`sha256 0296a9c1…33eb329cf`）。
本文件只定义范围与次序，不改源码。

> ⚠️ 工作树现状：仅 `CONTEXT.md` 有 **8 行未暂存新增**（新增术语「写失败列表」「刷新失败提示」，
> 属 `60fa711` 那一版 Panel 改动**漏提交的领域词汇**，归 Panel 作者提交，本计划不得改动）；
> 其余为未跟踪文件（`.workbuddy/`、两份 `docs/frontend-ux-review-*`、本计划）。
> 施工时只碰本文件列出的文件，不得夹带。

## 1. 旧路径的事实边界（已逐条核实）

### 1.1 生产侧

| # | 位置 | 事实 |
|---|---|---|
| 1 | `SoundPacksEditorOwner.swift:2150-2159` | **唯一 permit 生产点**：`makeAdoptionPermit(target:candidateGenerationID:seed:)` 未传 `packScoped`（默认 `false`），target 来自旧资格 `model.aiCueAdoptionEligibility(for:)` |
| 2 | `SoundPacksEditorOwner.swift:425-594` | **唯一写入分支**：`finishAdoption` 中 `if binding.packScoped { performPackScopedAdoption } else { … }`；旧分支经 `:594` 以 `removePackAttribution: false` 写入（保留 `license`/`author`） |
| 3 | `SoundPacksEditorOwner.swift:441`、`:572`（旧分支内）、`:1232`（旧 target 校验函数内） | `model.captureAICueAdoptionTarget(for:)` 的**全部三个调用点**，均属旧分支 |
| 4 | `SoundPacksEditorOwner.swift:2137-2148` | `eventAccess.adoptionAvailability` 仍按旧资格 `model.aiCueAdoptionEligibility(for: row.event)` 计算 |
| 5 | `SoundPacksWindowModel.swift:1844`（`aiCueAdoptionEligibility(for:)` 包裹旧规则 `surface: managedSurface`）、`:1873`（`captureAICueAdoptionTarget`） | 仅服务旧分支；旧分支删除后二者均为**死代码，须一并删除** |
| 6 | `AICueAdoption.swift:30`（旧资格）、`:94`（`AICueAdoptionTarget(surface:event:packID:)`） | 旧规则与旧 target 构造，仅服务 #1 |
| 7 | `AICuePackScoped.swift:177` | 纯别名 `aiCuePackageAdoptionEligibility`（无调用方，deletion test 通过） |

### 1.2 视图与呈现侧

| # | 位置 | 事实 |
|---|---|---|
| 8 | `EventSettingsWindowView.swift:966-984` | 入口回退：`packageAICueRoute` 无结果且旧资格 eligible → `beginAISession` + `begin(scope:)` |
| 9 | `EventSettingsWindowView.swift:786`（`adoptionEnabled: eventsEditorPresentation?.adoptionPermit != nil`）、`:1040`（`adoptAICueCandidate` 取同一 permit） | 视图侧旧 permit 消费者 |
| 10 | `SoundPacksEditorPresentation.swift:132` | `EventsSoundPackPresentation.adoptionPermit` 字段本身 |
| 11 | `EventSettingsWindowSelection.swift`（`beginAISession`、`aiSessionState` ×5）、`SettingsPresentationState.swift`（`aiSessionState`） | 旧会话分流与状态投影 |
| 12 | `SettingsPresentationFixtures.swift:84-91` | `beginEventTransientActivity` **同时**驱动旧双会话（`beginAISession` + `begin(scope:)`），是测试侧旧会话入口 |

包级对照面：`SoundPacksEditorOwner.swift:2080-2119`（`makeSoundsAICueAdoptionPermit`，`packScoped: true`、
带 `draftID`）→ `SoundPacksEditorPresentation.swift:192`（`SoundPackEditorEventPresentation.aiCueAdoptionPermit`）。

## 2. 退役完成判据（符号级）

**应消失**：

- `EditorAdoptionBinding.packScoped` 标志（测试侧 0 引用；生产侧仅用于新旧分流）
- `makeAdoptionPermit` 的 `packScoped:` 参数
- `EventsSoundPackPresentation.adoptionPermit` 字段
- `aiCueAdoptionEligibility`（ADR 0007 规则）、`AICueAdoptionTarget(surface:…)`、别名 `aiCuePackageAdoptionEligibility`
- `SoundPacksWindowModel.aiCueAdoptionEligibility(for:)`、`captureAICueAdoptionTarget(for:)`（旧分支删完即死）
- `EventSettingsWindowSelection.beginAISession`、旧入口回退分支

**必须保留（易误删，逐条已核实）**：

| 符号 | 保留理由 |
|---|---|
| `makeAdoptionPermit` 的 `draftID:` 参数 / `EditorAdoptionBinding.draftID` | **包级草稿流在用**：`Owner:657-658`（草稿一致性）、`:1257-1258`（`packScopedAdoptionTargetIsCurrent`）、`:2096-2119`（`makeSoundsAICueAdoptionPermit` 生产）、`AICuePackScopedSuite` 草稿事务用例 |
| `AICueComposerSession(scope:event:)` 初始化器 | **预览侧仍在用**：`PreviewFixtures.swift:744`、`:803-805`。二选一：连预览一起迁到 pack 形态，或明确保留该初始化器**仅供预览**并在代码注释写明理由——不得无声删除 |
| `AICueAdoption.swift` 的 `AICueAdoptionEligibility` / `AICueAdoptionIneligibility` / `AICuePackConsumer` | 被包级流程共用（`SoundPacksWindowModel:1875`、`AICuePackScoped:68-85`、`SoundPacksEditorPresentation:149`） |
| `aiSessionState` 投影 | 状态语义仍需要，只改数据来源（去掉旧会话分流） |

## 3. ⚠️ 覆盖缺口与门禁口径

| 口径（grep 为准） | 计数 |
|---|---|
| 测试侧 `*.adoptionPermit` **接收者引用**（旧 Events permit） | **28** —— 门禁基准 |
| 其中 `SoundPacksEditorAnnouncementGapRedSuite.swift:437/441/451/458` | **排除**：`_ adoptionPermit: SoundPackAdoptionPermit` 是 swiftc 探针闭包的局部参数名，与本退役无关，删源码也删不掉 |
| 测试侧 `adoptionPermit` 原始提及 | 32（含上述 4 处排除项）——**不作为门禁数字** |
| 测试侧 `aiCueAdoptionPermit`（包级） | **1**（`AICuePackScopedSuite`） |

→ 直接退役会连同约 28 处行为保护网一起删掉。故 ① 内部必须**测试先行**；S3 对账表以
`grep -rhoE '[A-Za-z_][A-Za-z0-9_.]*\.adoptionPermit'` 的输出逐条映射，不使用手数总数。

## 4. 用例清单（按文件，L = 用例起始行）

### 4.1 直接退役

| 文件 | 用例 | 依赖 | 处置 |
|---|---|---|---|
| `AICueAdoptionSuite` | L7 采用资格：只允许明确 surface 的独立、可编辑、有效用户包 | `aiCueAdoptionEligibility` ×11、`sharedPack` ×4（全库唯一） | **规则退役**（surface 维度按 ADR 0016 本就不再需要），非行为迁移；等价性 = 剩余包规则由 `AICuePackScopedSuite:L118` 及后续用例覆盖，逐条比对后删除 |
| `SettingsPresentationLifecycleSuite` | L593 Events AI generation：emitted tuple 必须签发当前 c… | 旧 permit 签发 | 退役/改写为「事件页不再签发 permit」（① 验收「无旧 permit 可签发」的对应断言） |

### 4.2 迁移（改会话/断言对象，保留行为）

| 文件 | 用例（L） | 迁移点 |
|---|---|---|
| `AICueDomainSuite` | L147 采用目标显式冻结 surface、Event 与 packID | 去 surface 维度，改为 pack 级 target 冻结 |
| `AICueGenerationViewModelSuite` | **14 处** `begin(scope:)`（:181–:638；覆盖 L174/206/237/293/326/351/377/412/435/493/528/563/603/627）+ **L724** 的旧 permit 引用（fixture 助手 `aiCueComposerAdoptionPermit(from:)` 读 `events.adoptionPermit`，带 `fatalError`） | 会话构造改包级 `begin(packID:event:)`（**已存在**，`ViewModel:174-179`，无需新设计 API）；L724 助手改为取包级 permit；行为断言原样保留：L174 生成中拒绝描述变动、L206 取消+迟到清理、L412 改描述作废旧候选、L435/493/528/563 采用成功/失败/orphan/迟到、L627 切 profile 取消 |
| `SenseAudioIsolationSuite` | L365 · L420 · L472 · L520 · L571 · L615 · L647 · L678 · L713 · **L752 · L854 · L914** | 前段联网/取消/凭据矩阵改会话构造；**L752/L854/L914 采用落盘、漂移零写、取消漂移优先迁移**（对应 ① 验收重点） |
| `AICueRuntimeSuite` | L586 VM 作废后丢弃迟到结果 | 会话构造 |
| `EventSettingsWindowSelectionSuite` | L9 route/focus/preview/AI 生命周期单点收敛；`aiSessionState` 断言 L16/28/41/79 | 去除旧 AI 会话分流（含 `SettingsPresentationFixtures.beginEventTransientActivity` 的双会话装配），保留 route/focus/preview 与 `aiSessionState` 语义 |
| `SettingsPresentationLifecycleSuite` | L464、L586 等 `aiSessionState` 断言 | 随 #12 的装配改造同步调整 |
| `SoundPacksEditorInterfaceSuite` | L8 投影语义资格与 opaque 试听 capacity、L590 broken Event mapping 仍签…、L616 non-fresh previous 只签 target | 断言对象由旧 permit 换为包级 |
| `SoundPacksEditorAsyncOperationSuite` | L88 stale permit 零写、L173 A→B→A、L498 AI adoption 绑定 generation、L581 经共享 coordinator 刷新、L661 in-flight cancel 保 adoption、L762/L819/L884/L963 generation 漂移、L1062 scope failure、L1142 identical activate、L1376 post-sample cancel、L1656 user pack 变 shared（`adoptionPermit` 15 处） | 逐条迁包级 |
| `SoundPacksEditorGapRedSuite` | L103 source I/O 前刷新 share、L194/L309 final bind epoch/最新 shared、L433 adoption manifest lock failure 保旧绑定、L518 writer 前 A→B→A | 逐条迁包级（① 保护网核心） |
| `SoundPacksEditorAnnouncementGapRedSuite` | 全部 | **不在范围内**（其 `adoptionPermit` 是探针局部参数名）；仅确认不因签名变化而编译失败 |

### 4.3 保留不动

- `AICuePackScopedSuite`（15 个，已走包级：L118 资格、L390 署名剥离、L338/L699 草稿事务）
- `AICueAdoptionSuite` L163/L205/L239（manifest 原子 RMW / 名称 / 损坏 `audio_names`）
- `AICueDomainSuite` L7/L26/L58/L103/L165
- `AICueGenerationViewModelSuite` L661、`AICueRuntimeSuite` L222-L518 中无旧会话者
- `SoundPacksEditorInterfaceSuite` 其余 presentation 用例

## 5. 迁移次序（每步带门槛）

0. **S0 基线**：在 `HEAD = 60fa711` 上跑一次 `swift run --package-path gui claudio-gui-tests` 与
   `swift run --package-path helper claudio-tests`，**记录已有失败**，作为后续「无新增失败」的对照。
   `CONTEXT.md` 的 8 行未暂存改动是文档、不进编译产物，不影响基线。
1. **S1 骨架**：建立「从包级呈现取 permit」的 fixture 取用方式（`aiCueAdoptionPermit`），跑通 1 条。
2. **S2 行为断言迁移**：先 GapRed → AsyncOperation（stale / 漂移 / shared / 零写），再 Interface → Selection → ViewModel。
   每条迁完做 **kill-test：断开包级签发（或使包级 permit 失效），确认新断言变红**——不断旧产出点（旧的反正要删），
   否则无法证明新断言真的守住了行为。
3. **S3 覆盖对账**：`*.adoptionPermit` 接收者引用 28 → 0 之前，包级引用须 ≥ 等量，逐条映射（排除
   `SoundPacksEditorAnnouncementGapRedSuite`）。
4. **S4 源码退役**：删 §1.1 的 #1–#7 与 §1.2 的 #8–#12，连带 §2「应消失」符号。
   移除 `packScoped` 标志与旧分支，**保留 `draftID`**（§2 表）。
5. **S5 门禁**：见 §8 的「S5 门禁最终形态」——两套 harness + Debug build + 本地化 JSON + `git diff --check`
   + `verify-settings-experience.sh 60fa711` + 两条能力断言（事件页无入口／声音页包级仍可用；前置固定
   `EventSettingsWindowView:730-735` 的「选中包已安装且非损坏」）+ **无新增失败**（相对 S0 基线）
   + 按 `docs/settings-experience-acceptance.md` 记录人工证据（原生/键盘/VoiceOver）。
   Panel 改动已提交，若仍有失败须按基线逐条归因，**不默认归给「在制品」**。

## 6. 本计划不做（防范围蔓延）

- ② ViewWiring 接缝迁移、③ 编排抽取、④ `Result` 返回：均在 ① 落地后按实测证据决定。
- 不动 `SoundPackLibrary` actor（ADR 0004，单一事实所有者）、`AICueGenerationDeadline`（ADR 0011，预算冻结）、
  `AICueAssetOrigin/Policy`、`AICueCredentialManager` 双槽。

## 7. 复核记录（2026-09-18，外部逐条复核后修正）

| 项 | 原表述 | 修正 |
|---|---|---|
| S3 门禁口径 | 「旧引用 32 → 0」 | 改为**接收者引用 28 → 0**，显式排除 `SoundPacksEditorAnnouncementGapRedSuite`（4 处探针参数名）；映射表以 grep 为准 |
| S4 范围 | 只列 5 点 | 补 `SoundPacksWindowModel:1844/1873` 死代码、`Owner:2137-2148` 旧资格投影、视图侧 `:786/:1040`、`SettingsPresentationFixtures:84-91` 与 `aiSessionState` 断言网 |
| `draftID` | 「与 `packScoped` 一并消失」 | **错**——`draftID` 是包级草稿流在用（`Owner:657/1257/2096-2119`），保留 |
| `AICueComposerSession(scope:)` | 「应消失」 | **预览侧仍在用**（`PreviewFixtures:744/803-805`）：迁移预览或明确保留并写理由 |
| ViewModelSuite 数量 | 15 处 | **14 处**（:181–:638）+ L724 旧 permit 引用 |
| S5 门禁 | 「全绿」 | 脏树不可判定：改为 **S0 基线 + 无新增失败** |
| kill-test 方向 | （未写明） | **断包级签发、看新断言变红**，不是断旧产出点 |
| `AICueAdoptionSuite:L7` 性质 | （隐含） | 明写为**规则退役**（非行为迁移），等价性 = 包规则由 `PackScopedSuite:L118+` 覆盖 |
| 基线漂移 | `HEAD = 78fafac` | 上一轮的在制品已提交为 **`60fa711`**（非丢失、非 stash）；基线 bump，§1 锚点不受影响（该提交未触及 AI 提示音路径） |
| 工作树状态 | 「Panel 在制品未提交」 | 已提交；残留仅为 `CONTEXT.md` 8 行文档改动（属 60fa711 漏提交的领域词汇，归 Panel 作者） |

## 8. 开工前置与验收义务（CONTRIBUTING 派生，2026-09-18 补齐）

以下 6 项在 S1 之前确认，其中 3–5 项属 S4/S5 的**完成定义**，漏了就交付不合规。

| # | 项 | 依据 | 动作 |
|---|---|---|---|
| 1 | 固定基线集成门 | `CONTRIBUTING.md:41-45`「影响统一设置体验的改动」 | S5 增加 `bash scripts/verify-settings-experience.sh 60fa711` |
| 2 | 设置验收清单 | `CONTRIBUTING.md:47-48`、`docs/settings-experience-acceptance.md` | ① 是**用户可见行为变更**（事件页不再自带生成入口，改为深链「声音」页）→ 需原生/键盘焦点/VoiceOver 人工证据，并按该清单区分「已验/未验」；`CONTRIBUTING.md:71` 明确 CI 不构成原生验收 |
| 3 | l10n 收尾 | `CONTRIBUTING.md:57` | `.aiCueEligibilityGlobal` 退役后成孤儿 key：改 4 处——`ClaudioLocalization.swift:405`（static let）、`:1286`（`allKnown`）、`Localizable.xcstrings` 的 en 与 zh-Hans |
| 4 | 死因子处置（**待拍板**） | 见 §9 | `.surfaceRequired`、`.sharedPack` 在包级资格下不可达，但 `SettingsSoundsAICueView.swift:478` 仍覆盖 `.sharedPack`（穷尽性要求） |
| 5 | CHANGELOG | `CHANGELOG.md` 为 Keep a Changelog，`0.1.0 - Unreleased` 当前仅有 `### Added` | 新增 `### Changed` / `### Removed` 条目（入口退役 + 署名语义统一） |
| 6 | kill-test 机制 | 本计划 §5 S2 未写明「怎么断」 | 优先用**合法状态变更**制造失效（如 `cancelAICuePackDraft()` 让已签 permit 失效、stale 场景），不改源码；确需改源码时走「本地临时改 → 跑目标套件 → `git restore` 还原 → `git status` + sha256 双证据」，并在 PR 记录 |
| 7 | 不回溯改写既有包 | `CONTRIBUTING.md:52`（除非 issue 明确定义迁移） | 经旧路径采纳过、manifest 仍带 `license`/`author` 的既有用户包**保持原样**，只对之后的采纳生效新语义 |

**S5 门禁最终形态**：两套 harness（helper + gui）+ Debug build + `jq empty …xcstrings` + `git diff --check`
+ `verify-settings-experience.sh 60fa711` + 两条能力断言 + **无新增失败**（相对 S0 基线）+ 人工证据记录。
`node scripts/test-sound-pack-selector-state.js` 与 `python3 scripts/test-sound-pack-candidates.py` 属声音包工具链，
本计划不触及，可不跑（若 CI 强制则照跑）。

## 9. 待拍板的两个决策点

1. **`.surfaceRequired` / `.sharedPack` 死因子：保留还是移除？**
   - 移除：S4 影响面从 §1 的 12 点扩到 14 点（多 `SettingsSoundsAICueView.swift:478` 与 l10n 两处），
     但有 ADR 0016 依据——它用「告知受影响的有效使用者」（`aiCuePackUsage`）取代了旧规则的「禁止共享包」；
     且消除不可达分支。
   - 保留：改动更小，代价是永久留下二个不可达 reason 与一条孤儿文案。
   - 倾向：**移除**（与 §2「易误删表」并列，需同时确认 `AICuePackConsumer` 仍被 `aiCuePackUsage` 使用而**不移除类型**）。
2. **分支策略**：直接在 `main` 施工，还是开 `refactor/retire-legacy-ai-cue-path` 主题分支？
   按 `CONTRIBUTING.md:61-71` 的 PR 流程与 `AGENTS.md`「实现/提交不等于授权推送」，**建议开分支**，
   且提交/推送需另行授权。
