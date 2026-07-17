# PLAN — 声音包管理（Sound Pack Manager）

> 来源：`/plan-design-review` 2026-07-15（含 `/codex` 跨模型评审）。设计决议已写入 [DESIGN.md](../DESIGN.md)
> （「包行四态」/「4-slot 覆盖轨」/「行内文件名下拉」/「Sound Packs Window」四节 + Decisions Log）。
> 本文件是**工程计划**：写路径、契约、验收。视觉真相源是 DESIGN.md，不是这里。
>
> **2026-07-17 修订**（用户拍板，AskUserQuestion 四问）：面板包列表 = **竖排整宽行 + 覆盖轨恒显 +
> 星标显示集（最多 4 行）**。工程契约见 §2.6；T4 / T5 / T7 已按此改写，新增 T16 / T17。
> ⚠ 排期硬约束：**≤4 过滤的激活不得早于星标 UI（管理窗口）落地**（§2.6 末条）。
>
> **2026-07-17 二审**（`/plan-eng-review` 增量+接缝 + `/codex` outside voice）：§2.6 补读机制
> （`ClaudioConfig.starredPacks` —— 第一版自相矛盾）、写者落点（`setStarredPacks` 含默认星展开）、
> 窗口状态源（原始数组非显示集）、T17 真实激活点与刷新路径、T13 判据升级为逐字节、
> `.manageSounds` 诚实性、T14/T7 的既有测试反向拉力等 —— 全部折入正文，详见文末报告。

---

## 0. 为什么（三条实证发现，不是审美意见）

三条都是读代码读出来的，都可复现。

### ① 面板级 drop-zone 从不写 manifest —— 导入的文件是孤儿

`AudioDropZoneView`（面板底部「+ 拖入你自己的声音」）
→ `AudioImportViewModel.handleDrop(requests:)`
→ `importAudioFiles(_:packID:environment:)`
→ **把字节拷进 `~/.claudio/packs/<selectedPack>/<name>`，然后结束。**

它唯一的 `onImportSucceeded` 钩子（`AudioDropZoneView.swift:53`）只做一件事：播一次预览。
**`manifest.json` 一个字节都没写。** 文件躺在包目录里，没有任何 event key 指向它，
`claudio play` 永远不会碰它。而 drop-zone 亮起一个绿勾 —— 那个绿勾的意思是「字节落盘了」，
用户读到的是「我的声音装好了」。**一次以成功之名的静默失败。**

### ② 一个完整的包，GUI 里无法替换任何声音

`bindEventToManifest(event:fileName:packID:environment:)` 在**生产代码里只有一个调用者**：
`EventRowImportViewModel.swift:112`（事件行行尾的导入入口）。

而那个入口的渲染条件是（`EventRowView.swift:222-229`）：

```swift
switch row.coverage {
case .present:  presentTrailing(fileName:)      // ← 没有导入入口
case .unmapped: importAffordance(label: "未配置")
case .broken:   importAffordance(label: "文件丢失")
}
```

`minimal-chime` 四事件齐全 → 四行全 `.present` → **一个导入入口都不渲染**。

> **想把「干完了」换成别的声音，你必须先去 Finder 把 `stop.mp3` 删掉，
> 把那一行弄坏成 `.broken`，导入入口才会出现。**

「看」的界面很好（事件行 8/10）；**「改」的界面不存在**。

### ③ CC0 标会说谎

- `Setup.swift` 的 `copyBundledPacks` 把内置包拷进 `~/.claudio/packs/` → 它就是一个**普通的可写目录**。
- GUI 侧 `ClaudioGUIApp.swift:57` 构造 `AudioImportEnvironment(durationProbe:)`，
  `bundledPacksDirectory` 取默认 **`nil`**。
- `isBuiltinOnlyPackID` 第一行：`guard bundledPacksDirectory != nil else { return false }`
  → **`.overwritesBuiltin` 那道闸门在出厂的 GUI 里结构上跑不到。**

结果：**你可以往「极简铃音」里塞一个有版权的音频，而卡片照样显示 `CC0`。**
而「版权干净（CC0）」是 Product Context 第一行的卖点。

补一刀：`.overwritesBuiltin` 的文案是
「…先建一份属于你自己的包，再拖进来。」
—— **那个动作在 UI 里根本不存在**（`grep -riE 'createPack|forkPack|duplicatePack'` → 无）。
一块指向不存在的门的路牌，且这块路牌本身还是不可达的死代码。

---

## 1. 架构决议（用户已拍板）

| 决议 | 选择 | 被否掉的另一条 |
|---|---|---|
| 音频怎么存 | **包为中心**：音频只住在包目录，`manifest.json` 仍是唯一真相源，**helper 零改动** | 库为中心（`~/.claudio/library/`）—— ENGINEERING.md 早已明文拒绝：「v1 只走『复制进用户包』这一条路径，两套路径并存会制造第二个查找顺序，故意不做」 |
| 管理界面住哪 | **面板（轻）+ 独立管理窗口（重）** | 全塞进 312pt popover —— `.transient` popover 点一下别处就消失，不适合编辑任务 |
| 内置包 | **只读**；改 → 引导「复制为我的包」；另给「恢复出厂声音」 | 可写（现状）→ CC0 标说谎 |
| 行内编辑入口 | **文件名本身升格为原生 `Menu`**（`stop.mp3 ▾`） | 行尾加第三颗 `⋯`（312pt 的行已经挤）；右键菜单（不可发现 + 违反 WCAG 2.1.1） |
| 面板包列表形制（2026-07-17） | **竖排整宽行 + 覆盖轨恒显**（用户 mockup 全盘采纳） | 横向卡片画廊 +「complete 零图形」（2026-07-15 版 —— 已推翻存档，新旧理由并录于 DESIGN.md Decisions Log） |
| 面板显示哪些包（2026-07-17） | **星标唯一判据，最多 4 行**（§2.6）：当前包不特赦；出厂内置包默认星（缺键 = 默认 / 空数组 = 清空）；硬上限 4 | 当前包特赦恒显 / 切换自动加星 / 星数不限显示截断 / 零星回落前 4（四条均被否，判词见 DESIGN.md Decisions Log） |

**跨模型印证**：`/codex` 独立评审收敛到同一结论（删假 drop-zone > 一切；独立窗口是对的；
内置包默认只读）。它**否决**了本轮设计的第一版推荐方案（波形包指纹），判词见 DESIGN.md。

---

## 2. 新写路径（工程评审的重点 —— 这几条是「实现的人容易想当然」的地方）

> ### ⚠️ 先更正本文件自己的两条假话（`/plan-eng-review` + `/codex` 实证）
>
> 本节的第一版写着两句**我没读代码就照抄的断言**，两句都是假的：
>
> | 原话 | 实测 |
> |---|---|
> | 「必须走 `JSONSafeWrite` 的**文件锁** + 原子写」 | ❌ **`bindEventToManifest` 里一个锁都没有**（`grep -iE 'lock' ManifestBinding.swift:93-208` → 空）。`JSONSafeWrite` **只导出 `encodeJSONObjectForWriting`** —— 一个**纯编码**门面：不读、不锁、不写。 |
> | 「`Setup.copyBundledPacks` **已经是这段代码**，不是新机制，只是新入口」 | ❌ 它在 `if !alreadyInstalled` 里，且 `if isUsablePack(id, …) { continue }` —— **遇到已存在且可用的包会直接跳过**。「恢复出厂」要的正是「即使可用也替换」，**不能直接复用**。 |
>
> **为什么记在这里而不是删掉**：这与 DESIGN.md 同日写下的教训（「**登记 ≠ 验证**」、「一条错误的指控比没有指控更糟」）是**同一条**，而它在那条教训写完后的**下一个文件里立刻复发了两次**。
> 后果不是丢脸，是**具体的**：一个信了「锁已经有了」的实现者，会在一条**没有锁**的路径上再加两个写者。

### 2.1 `clearEventBinding(event:packID:environment:)` —— 今天**不存在**

`bindEventToManifest` 的**对偶**：从 manifest 的 `events` 里**删掉**一个 key。

**并发不变式（真实的那一条 —— 不是「有锁」）**：

manifest.json 的写者**今天只有一个**：`bindEventToManifest`。它安全**不是因为有锁**，而是因为
（`EventRowImportViewModel.swift:87-97` 的原话）：

> 「The raw manifest read-modify-write inside `bindEventToManifest` is safe against concurrent
> per-row binds **ONLY because that function is fully SYNCHRONOUS**, and every caller of it
> invokes it on the `@MainActor`.」

**本计划会给 manifest 加三个新写者**（`clearEventBinding` / `forkPack` / `restoreFactoryPack`）
**和一个新 UI 面**（管理窗口）。所以这条不变式必须被**明确地保住或明确地换掉**。

**拍板：保住它，不加锁。**

| 新写者 | 为什么不需要锁 |
|---|---|
| `clearEventBinding` | **全同步 + `@MainActor`**，与 `bind` 同一条串行化 |
| `forkPack` | **同步跑在 `@MainActor`**。fork 是**罕见的显式动作**（拷 manifest + ≤4 个音频，每个 ≤5 MB → 最坏约 20 MB，SSD 上几十毫秒）。为它引入一把锁，会把锁**同时压进 bind/clear 的热路径**（每次换声音都走）—— 拿一条真不变式换一次 UI 微卡顿，不划算 |
| `restoreFactoryPack` | 只作用于**内置包**，而内置包是**只读**的 → `bind`/`clear` **结构上**永远不会指向它。**只读闸门顺带买到了互斥**（§2.3） |
| 管理窗口 | 与面板**同一个 `@MainActor`**。窗口不得把 manifest 写操作丢到后台队列 |

⚠️ **一句注释保不住这条不变式** —— 这个仓库已经为「一条被跨过去还留在原地的绊线」交过学费
（`PanelView` 那条「本视图树零动画」）。所以：

> **T3 必须同批给 `SourceScannerSuite` 加一条源码绊线**：
> `ManifestBinding.swift` / `PackFork.swift` 里**任何**导出的 manifest 写函数带 `async` 或
> `Task` / `DispatchQueue` → **测试红**。
> 不变式从「一句话」变成**一条会响的东西**。

**统一的 read-modify-write 原语（Codex 评审 · 采纳）**：

`bindEventToManifest` 的 99–207 行里，**只有第 177 行**是真正的变更；前 78 行（解析目录 → 确认是
用户包 → 读 manifest → 解析 → **三道 fail-closed 校验**）和后 28 行（`encodeJSONObjectForWriting`
+ 原子写）是 `clear` **和 `fork` 都要逐字复用**的。

⚠️ **原语必须是顶层的，不能只管 `events`**：`forkPack` 要改**顶层** `id` / `name`、删 `license` /
`author`。一个只开放 `events` 的原语，会逼出**第二条顶层 JSON 手术路径** —— 正好绕回它想消灭的重复。

```swift
/// manifest.json 的**唯一**读-改-写原语。bind / clear / fork 全部经它。
/// 同步（不许 async —— SourceScannerSuite 有绊线钉着）。
func mutateManifestJSON(
    at packDirectory: URL,
    _ transform: (inout [String: Any]) -> Void
) -> Result<Void, ManifestBindError>
```

它保留今天 `bindEventToManifest` 里**全部**三道 fail-closed 校验（`events` 必须是 object /
values 全是 String / 顶层 `id` 必须是非空字符串），以及 `encodeJSONObjectForWriting`
（数字规范化 + 防 `-inf` 硬崩，两个洞都是**这个读-改-写形状本身**的洞）。
**未知顶层键原样保住** —— `schema` / `version` / 任何未来键。

`bindEventToManifest` 的**文件预检**（`safePackFileURL` + `regularFileExists`）留在它自己那一侧：
`clear` 不碰文件，`fork` 拷的是已经存在的文件。
错误枚举**共用 `ManifestBindError`，不改名**（改名要动 `EventRowImportViewModel.bindResult` +
1108 行的 `ManifestBindingSuite`，为一个名字不值）。加一句文档：`.unsafeFileName` / `.fileNotFound`
**只由 `bind` 的文件预检产生**，原语本身结构上不产生它们。

**语义（硬约束）**：
清除 → `CoverageState.unmapped`（**刻意静默**），**绝不是 `.broken`**。
决议① 的原话是「真打包错误不被伪装成正常静默」——**反向也成立**：
一次用户主动的清除，不得被伪装成打包错误。行显「未配置」，不是「文件丢失」。

⚠️ **文件本身不删。** 清除的是 manifest 的 key，不是磁盘上的音频。
被清掉的文件成为「未被使用的音频」，由管理窗口显式列出（T11）——
**不许在这一步顺手删文件**，那是一个不可逆动作藏在一个可逆动作里。

### 2.1b「四个事件全被清空」—— 三个子系统给三个答案（已知分歧，钉死不修）

用户可以把四个事件**全部**清除。那这个包还算包吗？**三个子系统今天各说各话**（Codex 实测）：

| 子系统 | 对 `events: {}` 的回答 | 判据 |
|---|---|---|
| `doctor` | **`.complete`** | 它问的是「你**声明**的文件在不在」。什么都没声明 → 没有缺失 |
| `play` | **全静默**（四个事件都 `.notReady`） | 它问的是「这个事件**要不要**出声」。`unmapped` = 刻意静默 |
| 面板包行（原「画廊卡片」，2026-07-17 改形制不改语义） | **`partial(0/4)`「缺 4 个」** | 它问的是「**覆盖**了几个事件」 |

**拍板：三者都不改，因为它们回答的是三个不同的问题。** 一个 `events: {}` 的包是**合法**的
（= 一个全静默的包）。

⚠️ **但必须写成验收断言把三者同时钉死** —— 否则下一个人会看到「doctor 说完整、包行说缺 4 个」
觉得是 bug，去「修好」其中一个，当场破坏另外两个。**这条分歧是被理解过的，不是被忽略的。**
（`doctor` 对空包的**措辞**可以更友好 —— 记 P3，不阻断。）

### 2.2 `forkPack` + 「恢复出厂声音」—— 目录级操作，不是文件级

**⚠️ 目录级原子性：`Data.write(.atomic)` 只保证单个文件。**
一个包 = manifest + N 个音频。**逐文件拷到位**的话，中途被 kill 就会留下**半个包**躺在
`~/.claudio/packs/<newid>/` —— 而 `availablePacks` **会照常把它枚举出来**，用户看到一张自己
没造过的残行（半个包照样被枚举成一个可切换的包）。

**基础设施已经在了**（`PackGallery.swift:118-119` 的注释就是为它写的）：

> 「excluding **dot-prefixed** entries (mirrors `Setup.swift`'s own filter: a killed import/setup
> can leave a `.<id>.tmp-<pid>` scratch directory behind, **which must never appear as a
> switchable pack**)」

> **拍板**：`forkPack` / `restoreFactoryPack` **一律**先写进 `.{id}.tmp-{pid}/`，
> 全部落盘后 **`rename(2)` 整个目录**进位。零新机制 —— `Setup.swift` 已经这么干，
> `packDirectoryIDs` 的 dot 过滤器就是为它存在的。

- **`forkPack(fromID:newID:environment:)`**
  - **新 `id`**：`<原id>-copy`，冲突则 `-copy-2`、`-copy-3`…。**必须过 `isSafePackID`**，
    **绝不静默覆盖**已存在的包。
  - **新 manifest 必须改写顶层 `id`**（Codex 评审逮到，本计划第一版**漏了**）。
    副本目录叫 `minimal-chime-copy` 而 manifest 里还写着 `"id": "minimal-chime"` =
    **包身份脏了**。而 `doctor` **不校验** manifest 的 `id` 是否等于目录名（`Doctor.swift:139`），
    所以系统会「继续正常工作」—— 一个不会报错的错误，最坏的那种。
  - **`license` 字段：整个删掉，不是改成别的值。**
    理由在 `PackCard.isCC0` 自己的 doc comment 里已经写好了：
    > 「`false` —— **not "unknown"** —— when `license` is absent or any other value;
    > this only ever drives a **positive** 'CC0' badge, never a negative claim.」

    删掉 `license` = 包行不再打 CC0 标 = **我们不再对这份副本的版权作任何声明**。
    诚实的语义：用户 fork 出来就是要改它，我们**不知道**它改完还是不是 CC0。
    **零新词汇** —— 不发明 `"mixed"` / `"LicenseRef-User-Custom"`，因为 `license` 是 helper
    也读的字段，往里塞新枚举值要跨模块拍板，而删除不需要。
  - `author` 同理删除。`name` → `「<原name> 的副本」`。`schema` / `events` 原样保留。
  - manifest 的改写走 **`mutateManifestJSON`**（§2.1 那个**顶层**原语 —— 这正是它不能只管
    `events` 的原因）。

- **`restoreFactoryPack(id:environment:)`**（内置包专属）
  - ⚠️ **不能直接复用 `Setup.copyBundledPacks`**（本计划第一版声称可以，**是假的**）：
    它在 `if !alreadyInstalled` 里，且 `if isUsablePack(id, …) { continue }` ——
    **遇到已存在且可用的包会直接跳过**。恢复出厂要的正是「**即使可用也替换**」。
    可复用的只有它的 **staging + rename 机械部分**，不是它的策略。
  - **来源**：`factoryPacksDirectory`（§2.3），**不是** `bundledPacksDirectory`。
  - ⚠️ **绝不静默替换**（本仓库铁律：绝不静默吞错）。目录里若有用户自己加的文件，
    须像 `setup` 的 `salvaged` 那样**搬走而不是删掉** + 明确告知。
    **一个不可逆动作不许藏在一个听起来温和的按钮后面。**
  - **它为什么不需要锁**：只作用于内置包，而内置包**只读** → `bind`/`clear` 结构上永远
    不会指向它（§2.1 的并发表格）。

### 2.2b 导入时的文件名冲突 —— **绝不覆盖**（Codex 评审逮到）

`importAudioFile` 今天对目标文件名**直接 `.atomic` 覆盖**（`AudioImport.swift:216-231`，
其 doc comment 明说这是「re-drop 到同一行 = 重新绑定」的预期流程）。

**但 T2 给每一行都装上「选文件…」之后，这个行为长出一条新的、静默的副作用**：
用户导入一个与包内已有文件**同名**、且**被另一个事件引用**的文件 →
**那个事件的声音被悄悄换掉了**，而它的行上什么都不会显示。

> **拍板：目标文件名已存在 → 生成唯一名（`stop-2.mp3`），不覆盖。**
> 代价：同一个文件导两次会留两份副本（阶段 2 的孤儿视图负责清理）。
> **换来的是：没有任何一次导入会静默改动另一个事件的声音。**
> 这条与「绝不静默吞错」是同一条铁律的两个面。

### 2.3 内置包只读的判据 —— **拍板：新增 `builtinPackIDs`，不复用 `bundledPacksDirectory`**

**先说被否掉的两条，以及为什么**：

| 候选 | 否决理由 |
|---|---|
| `manifest.author == "Claudio"` | ❌ **拿用户可写的数据当权限判据。** 任何人在自己的 manifest 里写 `"author": "Claudio"` 就能把自己的包变成只读。判据的真相源不能是被判据保护的那个文件。 |
| 硬编码 id 清单 `["minimal-chime"]` | ❌ 第二个内置包上线的那天就漂移。而且它复制了一个**磁盘上已经存在**的事实。 |
| **复用 `bundledPacksDirectory`（把 GUI 的 `nil` 改成真路径）** | ❌ **这是本节最重要的一条。** 那个字段**同时**喂给 `resolvePackDirectory`，它决定的是**包的查找顺序**。把它从 `nil` 改成真路径，会让「只存在于 bundle、还没被拷进用户根」的包**在面板包列表里可见**——而 helper 的 `play` 看不见它（`PlayEnvironment.bundledPacksDirectory` 恒 `nil`，ENGINEERING T17：「v1 只走『复制进用户包』这一条路径」）。<br>`Setup.swift:503-505` **已经踩过并写下了这个警告**：「若把 `Resources/packs/` 传进去，就会认可一个 **`play` 根本看不见**的包 —— 一次假阴性」。<br>**一个字段一个职责。`bundledPacksDirectory` 的职责是查找，它的 `nil` 是负重的。** |

**拍板 —— 新增一个字段：`factoryPacksDirectory`（一个「拷贝源」，不是一个「查找根」）**

> **本计划第一版提的是 `builtinPackIDs: Set<String>`，被 Codex 评审逮到不完整**：
> `forkPack`「从出厂包复制」和「恢复出厂」**都需要 `Contents/Resources/packs/<id>` 的真实 URL**，
> 而一个 id 集合给不出路径。补一个字段去凑 = 两个字段描述同一件事。

```swift
// AudioImportEnvironment
/// **出厂包的拷贝源** —— `Claudio.app/Contents/Resources/packs/`。
///
/// 它回答的是**一个**问题：「出厂包**从哪拷来**」。三个消费者：
///   ① `builtinPackIDs`（本字段下子目录名的派生）→ 「这个包是不是内置的 → 只读」
///   ② `forkPack(fromFactory:)` → 从出厂副本复制，而不是从可能已被改脏的用户副本
///   ③ `restoreFactoryPack` → 重新拷贝
///
/// ⚠️⚠️ **绝不传给 `resolvePackDirectory`。** 那个函数的 `bundledPacksDirectory` 参数
/// 决定的是**包的查找顺序**，GUI 侧恒 `nil` 是**负重的**：它让 GUI 眼中的「有哪些包」与
/// helper 的 `play` **逐字一致**。`Setup.swift:503-505` 已经踩过并写下了这个警告 ——
/// 「若把 `Resources/packs/` 传进去，就会认可一个 **`play` 根本看不见**的包 —— 一次假阴性」。
///
/// **两个字段名字像，职责正交：一个是「从哪拷」，一个是「去哪找」。**
/// `nil`（`swift run ClaudioGUI` 无 bundle、以及全部测试 fixture）= 没有任何包是内置的
/// = 没有任何包是只读的。与 `bundledHelperBinary(in: .main)` 在无 bundle 时回落 `nil` 的
/// 诚实降级同构。
public var factoryPacksDirectory: URL?

/// 派生，不是第二个真相源。
public var builtinPackIDs: Set<String> { /* factoryPacksDirectory 下的子目录名 */ }
```

- **来源**：`ClaudioGUIApp.swift`（app 里**唯一**碰 `Bundle.main` 的地方，T17 的既定结构）：
  `Bundle.main.resourceURL?.appendingPathComponent("packs")`。
- **判据**：`environment.builtinPackIDs.contains(packID)` → 只读。
  **与「用户根里有没有副本」无关** —— setup 之后每个内置包**都**有用户副本，
  所以旧的 `isBuiltinOnlyPackID`（「你还没有自己的副本」）语义本来就答不了我们的问题。
- ⚠️ **必须有一条测试断言 `resolvePackDirectory` 从来没被喂过 `factoryPacksDirectory`**
  —— 两个字段长得太像，这是一条**真会被"顺手合并"**的绊线（见验收）。

**连带的清理（不是可选项）**：
- **删掉 `isBuiltinOnlyPackID`**（`AudioImport.swift:376-389`）—— 它是一个名字会骗人的死函数：
  在出厂 GUI 里恒返回 `false`（`bundledPacksDirectory == nil`），一行都跑不到。
- **`.overwritesBuiltin(packID:)` → `.builtinReadOnly(packID:)`**，文案随之改成一句**做得到**的话：

  > 旧：「…先建一份属于你自己的包，再拖进来。」← **那个动作在 UI 里不存在**
  > 新：「「极简铃音」是内置声音包，不能直接改。先『复制为我的包』，再改副本。」← **T6 让这个动作存在**

  **一块路牌只有在门真的存在之后才能立。** 本轮之前，那句话指向虚空。

### 2.4 CC0 标必须由 bundle 背书 —— **只读闸门没有真正修掉 ③**（Codex 评审，最重的一条）

只读闸门只挡**未来**的写。它挡不住：

1. **已经被改脏的包**（现存用户机器上就有 —— 那个假 drop-zone 存在期间往里塞的任何东西）
2. 任何人用文本编辑器改 `manifest.json`
3. 旧版本 Claudio 造成的污染

而 `CC0` 标今天**读的是那个用户可写的 `license` 字段**（`PackGallery.swift:231`）。
所以：**一个被换掉了 `stop.mp3` 的「极简铃音」，`license` 字段还在，卡片照样打 `CC0`。**

**而本计划第一版的验收写着「原包仍有 CC0 标」—— 它假设了「原包是干净的」，
而那恰恰是唯一不能假设的东西。** 这是一条会自我背书的验收：它检查的是它自己的前提。

> **拍板 —— 新增 T13（P1）：`factoryIntegrity(packID:)`**
>
> 判据（这是**诚实信号**，不是安全边界）：
> - `manifest.json` **字节完全一致**（约 300 B，一次小读）
> - 每个**声明文件**与出厂副本**逐字节一致**（2026-07-17 Codex 逮到：第一版只比 `size`，而一次
>   **等长替换**照样挂 `CC0` —— 又一例「措辞比覆盖范围大」：headline 写着「③ 的真正修法」，判据却
>   放得过同 size 的污染）。成本论证：只对 `builtinPackIDs` 里的包算（今天一个），内置铃音都是小文件
>   （与导入上限 5 MB 无关 —— 那是用户文件的 cap）；若未来内置包变大，再按（size, mtime）memo 化，
>   **先诚实后省钱**。
>
> 与 `factoryPacksDirectory` 里的出厂副本比。只对 `builtinPackIDs` 里的包算
> （今天就一个），随 `packCards` 在 `reload()` 里算一次。
>
> **不一致 → 包行 meta 槽显示 `⚠ 已修改`，而不是 `CC0`**，并在管理窗口引导「恢复出厂」。
>
> **这才是 ③ 的真正修法**：让 CC0 标由 **bundle 背书**，而不是由**用户可写的字段**背书。
> 一个会说谎的 CC0 标，比没有标更坏 —— 而「版权干净（CC0）」是 Product Context 第一行的卖点。

---

## 2.5 面板焦点模型必须改 —— **计划第一版一个字都没提**（`/plan-eng-review` 逮到）

T2 把事件行的控件从**两个**（试听 ▶ / 静音）变成**三个**（`[文件名 ▾] [试听 ▶] [静音]`）。
而 `PanelFocusTarget.eventAction` 的文档白纸黑字（`PanelFocusOrder.swift:26-28`）：

> 「**A SINGLE slot per row** … the row always renders exactly one of them, so the tab STOP
> count per row **never changes** with coverage state.」

**这正是 `previewClaimsActionFocus` 那个纯函数当年被造出来解决的 bug**（两个控件绑同一个
focus 值 → SwiftUI 焦点解析未定义）。T2 会把它重新引爆。

**拍板**：

1. **新增 `PanelFocusTarget.eventSound(Event)`** —— 文件名下拉。
2. **每行焦点序按视觉序变成三个槽**：`eventSound → eventAction → eventMute`。
3. **`.eventAction` 从此恒等于试听 ▶**（三态统一）→
   **`EventRow.previewClaimsActionFocus` 整个作废，删掉** —— 它存在的唯一理由
   （两个控件抢一个槽）消失了。
4. **`EventRow.eventActionOperable` 语义改变**：从「`present` 时看 `enabled`，否则 `true`」
   变成 **`previewEnabled && enabled`**（试听在 `unmapped`/`broken` 上本来就是禁用的）。
   `unmapped` 行的首焦点于是落在 **`eventSound`**（那个下拉）—— **正是修好这一行的控件**。
5. ⚠️ **`.dropZone` 焦点目标必须删，而删它会开一个洞**：
   `panelFocusOrder` 里 `.dropZone` 是**无条件 append** 的（`:118`），而
   `panelFirstFocusTarget` 的文档正是**靠它**证明「operational scope 永不返回 nil」（`:163-166`）。
   删掉之后，在「**已安装 + 磁盘上零个包**」这一格（用户手删了 `~/.claudio/packs/*`），
   焦点序只剩 `[.disconnect]` ——
   > **面板一打开，键盘焦点就落在那颗卸载按钮上。按空格 = 卸载。**

   **修法**：T7 的「管理…」做成**真焦点目标 `.manageSounds`**，排在 packCards 之后、
   `.disconnect` 之前。空面板首焦点于是落在「管理…」—— 安全且有用。
   ⚠️ **`.manageSounds` 必须按 `.masterVolume` 的先例过一遍诚实性检查**（2026-07-17 二审补）：
   `PanelFocusOrder.swift:113-116` 记录过同型 P1 ——「无条件 append + 条件渲染 = 首焦点指向一个
   不存在的控件」。所以：① 管理钮在 `operationalPanel` 的**全部四个 configState**
   （`.operational`/`.needsPack`/`.malformed`/`.unwritable`）无条件渲染，unconditional append 才诚实；
   ② operability arm **恒 `true`，含 in-flight**（`ctaOperable == false` 时它照样可操作 ——
   访达 reveal 无写副作用），这也是「operational scope 永不返回 nil」这条保证在 `.dropZone` 死后
   **唯一**的继承者（`.disconnect` 是跟着 `ctaOperable` 走的，兜不住）；
   ③ `ViewWiringSuite` 双向钉（渲染无条件 + append 无条件，漂移任一半都红）。
   **并同批改写三段将随本改动失效的文档**：`panelFirstFocusTarget` 的非空论证（`:163-166`，靠
   `.dropZone`）、`panelFocusOrder` 的头注释（`:87-96`，逐字写着「then the drop zone, then every
   pack gallery card」）、`PanelFocusTarget.eventAction` 的「A SINGLE slot per row」doc（`:24-28`，
   被本节第 1-3 条直接作废）——
   这个仓库刚为「一句不再成立的断言留在原地」交过两次学费。
   （顺带：TODOS.md「`.dropZone` 是焦点位但没有任何视图绑定它」那条台账被本改动**整个消灭** ——
   落地时更新台账，不许留一条指向已删除符号的活条目。）

   > **2026-07-17 追记（P1#1 已提前落地，非 T7）**：cc59d52（T1）落地后 `/codex review` 逮到
   > `.dropZone` 焦点位在 `.needsPack`/`.malformed`/`.unwritable`（生产可达：首次启动没选包、config
   > 损坏）已是 `PanelView.applyFirstFocus` 的**开屏焦点目标**，即把焦点设到一个已删控件上（键盘/VO
   > 开屏焦点丢失）—— 这已不是「低危缺口」，是可达真回归。于是**这一刀在 T7 之前就单独落了**：
   > `PanelFocusTarget.dropZone`（枚举项 + `panelFocusOrder` 无条件 append + `panelFirstFocusTarget`
   > operable arm）**已整个删除**；上面点名的两段 doc（`panelFirstFocusTarget` 非空论证、`panelFocusOrder`
   > 头注释）与 TODOS 台账条目**已同批改写/删除**。删后诚实的过渡行为：`.needsPack` 有卡→首焦点是**首张
   > 包卡**（正好是「点一张卡片」主行动，净改善）；无卡→`.disconnect`（真控件，非幽灵；仅「零安装包」
   > 这个退化态才触发，内置包在场时不会）；in-flight 零形状→**首焦点诚实为 nil**（与 onboarding
   > in-flight 同型）。
   >
   > **所以 T7 不再是「删 `.dropZone` 并原子替换」，而是「新增 `.manageSounds`」**，第 ①②③ 条不变，但：
   > (a) 删除 `.dropZone` / 改那两段 doc / 消灭 TODOS 条目 —— **已完成，勿重做**；T7 名下只剩
   > `PanelFocusTarget.eventAction`「A SINGLE slot per row」那段 doc（本节第 1-3 条 `eventSound` 才作废它）；
   > (b) 测试的当前形状（`:329` 行号已移，按 suite 意图找）：无卡 `[.disconnect]` → `[.manageSounds, .disconnect]`
   > 且首焦点 `.disconnect` → `.manageSounds`；有卡的首张包卡断言不受影响（`.manageSounds` 插在 packCards
   > 之后、`.disconnect` 之前）；
   > (c) ⚠️ **`runPanelFocusInFlightSuites` 里新增了一条 `panelOpeningFocus(rows:[], packCardIDs:[],
   > ctaOperable:false) == nil` 的钉子**（T7 原指令清单没点名它）—— T7 的 `.manageSounds`（in-flight 恒
   > 可操作）落地后它必红，须**主动重写为 `== .manageSounds`**，别当意外红。

   > **2026-07-18 追记（P1#2：`.configReveal` 也提前落地，非 T7）**：紧接 26bba37 的 `/codex review`
   > 又逮到 —— 删掉 `.dropZone` 后，`.malformed`/`.unwritable` 的**诚实失败卡**上那颗
   > `PanelView.configFailureNotice` 的「在访达中显示 config.json」按钮（`PanelView.swift:624`）是一颗
   > 真控件，却没有焦点目标；开屏焦点于是越过这颗**视觉最顶端**的修复入口，落到包卡 / 断开连接 / nil。
   > 这一刀也在 T7 之前单独落了（26bba37 follow-up commit）：新增焦点目标 `PanelFocusTarget.configReveal`
   > + scope 字段 `hasConfigFailureNotice` + `panelOpeningFocus` 同名参；`panelFocusOrder` 在 operational
   > 序**最前**插入它（视觉最顶），operability arm 恒 `true`（访达 reveal 无写副作用，含 in-flight）；
   > `applyFirstFocus` 从 `configState` 的 `.malformed`/`.unwritable` 派生该 flag；`ViewWiringSuite` 按
   > `.masterVolume` 先例双向钉（call site 传派生值 + 派生自那两态 + 禁字面量）；`PanelFocusOrderSuite`
   > 拆掉把 `.malformed`/`.unwritable` 与 `.needsPack` 并成一个 fixture 的旧断言，新增 `.configReveal`
   > 首焦点 / 有卡 / in-flight 各一条；TODOS `:1160` 的过期「运行态恒含 `.dropZone`，永不返回 nil」已改写。
   >
   > **对 T7 的三条约束（`.configReveal` 与 `.manageSounds` 不冲突，但同改 `panelFocusOrder`，须协调 merge）**：
   > (i) `.configReveal` 是**条件性**顶部锚点（仅 `.malformed`/`.unwritable`），**不是** operational scope
   > 「永不返回 nil」的无条件担保者 —— 那把交椅仍归 `.manageSounds`；本改动没动 §2.5 ⚠②，别以为 never-nil
   > 已由它兜住。(ii) `.manageSounds` 落地时须排在 `.configReveal` **之后**（顶部 `.configReveal` → 事件 →
   > packCards → `.manageSounds` → `.disconnect`），否则失败卡首焦点会错落到管理钮。(iii) 上面 (c) 那条 in-flight
   > nil 钉子现在**只覆盖 `.needsPack` 一无所有**态（无失败卡）；`.malformed`/`.unwritable` 的 in-flight 已
   > 由新增的 `== .configReveal` 断言钉死为非 nil —— T7 把 (c) 重写成 `.manageSounds` 时别把这条一起动了。
   > （设计侧一条待拍板：post-T7 `.malformed`/`.unwritable` 面板上会有**两颗访达 reveal**——config.json 与
   > `~/.claudio/packs/`——功能不撞，但归 DESIGN.md 定夺失败态呈现。）

6. **测试要重写，不是删**（计划第一版没算这笔账）：
   `CoverageStateSuite` 有 **8 条**用例钉死 `previewClaimsActionFocus` / `eventActionOperable`
   的现语义；`PanelFocusOrderSuite:302` 那条「首焦点必须 ≠ `order.first`」的**前提**也变了
   （muted 行的首焦点从「跳过禁用的试听」变成「落在文件名下拉上」）；
   **`PanelFocusOrderSuite:329` 整条 suite 钉死「零行首焦点 = `.dropZone`」**（Codex 逮到 ——
   它连名字都写着 drop zone），T7 落地时它必红，重写为 `.manageSounds`，不许删。
   > **2026-07-17 追记**：这条已不再钉 `.dropZone`（见第 5 条追记，P1#1 提前落地）。现在它钉的是
   > 无卡→`.disconnect`、有卡→首张包卡、in-flight 零形状→`nil`。T7 要做的是把这些**当前**形状迁到
   > `.manageSounds`，而不是「重写一条写着 dropZone 的断言」。

7. **三态共用 `Menu` 的 VoiceOver 输出要成为契约，不只是焦点槽**（Codex 逮到，2026-07-17 补）：
   今天 present 行的文件名是**非控件** `Text`（`EventRowView.swift:254`，行级 a11y 合并播报），
   unmapped/broken 的绑定入口才是 `Button`（`:348`）。升格成 `Menu` 后要钉三件事：
   ① 行身份与菜单 label 不重复播报「声音 xxx」两遍；② 禁用的试听 ▶ 不抢播；③ unmapped 行的
   Menu label 必须让 VO 用户听得出「这里能修」（「未配置，选文件」级别的可操作性提示）。
   落进 `PanelAnnouncement` / 行 `accessibilityLabel` 的单测 + 一条真机 VO 走查（见 §4b 用户流）。

> **2026-07-17 追记（星标显示集连带）**：包列表行数从「有多少包画多少」变成 **≤4**（§2.6），
> `packCard(id:)` 焦点槽数量随之有了上界；而「包列表零行」从病态（用户手删 `~/.claudio/packs/*`）
> 升格为**日常合法态**（星标全取消）。第 5 条的 `.manageSounds` 首焦点从「边缘防御」变成
> **用户天天走得到的路** —— 那条验收（`panelOpeningFocus(rows: [], packCardIDs: [], …) != .disconnect`）
> 的分量随之变重。

---

## 2.6 星标显示集 `starred_packs` —— 面板最多 4 行（2026-07-17 用户拍板）

**四条产品决议**（AskUserQuestion 逐条拍板，判词与被否方案存档于 DESIGN.md Decisions Log）：

1. 面板包列表 = **竖排整宽行 + 覆盖轨恒显**（mockup 全盘采纳，推翻「横向画廊」+「complete 零图形」）；
2. **星标是唯一判据** —— 当前使用中的包未加星就**不显示**（当前包的保证可见读数 = 事件区标题
   「{包名} · 事件」，T7）；
3. 出厂默认**内置包带星**（示范，可取消，绝不复活）；
4. **硬上限 4**（管理窗口第 5 颗星显式禁用 + 原因；星标控件只住管理窗口，面板没有）。

### 键与语义

**`config.json` 顶层新键 `starred_packs: [String]`（pack id 数组）。**

**为什么住 config.json 而不是新文件**：外科式读-改-写原语 `updateConfigJSON`（`ConfigMutation.swift`）
+ `configLockFile` flock 纪律 + 未知键保真已经全在了（ENGINEERING「写入者有三个，但写路径只有一条」——
T17 落地后写入者变四个，写路径仍只有这一条）。第二份 GUI 偏好文件 = 第二条读写路径 + 第二把锁 + 第二个 doctor 盲区 ——
与「不引入第二个查找根」同一条本能。

**缺键 ≠ 空数组（防「默认复活」的那一刀）**：

| 磁盘状态 | 语义 | 显示集 |
|---|---|---|
| 键不存在 | 出厂默认 | `builtinPackIDs`（§2.3 的派生集合） |
| `starred_packs: []` | 用户清空 | 零行（合法日常态，§2.5 追记） |
| `starred_packs: ["a","b"]` | 用户选择 | 数组 ∩ 磁盘上存在的包 |

- **默认不靠 setup 写入** —— 没有写入者，就没有「取消默认星后每次启动重新种回来」的复活 bug。
  用户第一次动星标才物化这个键（那一笔写的是**显式全量数组**，从此与默认脱钩）。
- dev build（`swift run ClaudioGUI`，`factoryPacksDirectory == nil`）→ `builtinPackIDs` 为空 →
  缺键默认零行。与 §2.3 的诚实降级同构，**不为 dev 造第二条默认**。

### 写路径

- **唯一写者 = 管理窗口星标钮（T17，阶段 2）**。走 `updateConfigJSON`（`.failClosed` —— 星标写者与
  静音钮同款，凭空造不出 `selected_pack`）+ 同一把 `configLockFile`。
- ⚠️ **写者必须有自己的家（2026-07-17 `/plan-eng-review` 逮到，本节第一版没写落点）**：
  `updateConfigJSON` 是 **module-internal**（`ConfigMutation.swift:159`，无 `public`），GUI 够不着它；
  既有模式是**每个写者一个 public 包装文件，自带锁与错误枚举**（`Use.swift` / `EventEnabled.swift:78-93`
  / `MasterVolume.swift:123`）。所以 T16 落一个新文件 **`helper/Sources/ClaudioCore/StarredPacks.swift`**：
  `public func setStarredPacks(_ ids: [String], configFile:, lockFile: = ClaudioPaths.configLockFile,
  userPacksDirectory:, defaultStarredPackIDs: Set<String>) -> Result<...>`，`withNonBlockingLock` +
  `.failClosed` + 错误枚举 `description` 与 `SetEventEnabledError` 同款。**签名里必须有
  `userPacksDirectory`**（「>4 个指向磁盘上存在的包」这道判定需要枚举磁盘）**和
  `defaultStarredPackIDs`**（Codex 逮到：「缺键下加星 → 写盘显式全量含默认星」的**展开必须发生在
  写路径里**，GUI 传 `environment.builtinPackIDs` 进来 —— 展开若放 UI 层，它就不是写契约，
  「默认星静默消失」那条验收绊线也守不到真正的产地）。
- **写时归一化（全部住在写者里）**：去重（重复 id 折叠 —— shape 校验只保「数组 of 字符串」，挡不住
  `["a","a"]`）→ 剪陈旧 id → **按 distinct 有效 id 数**执行 ≤4 上限。UI 的禁用是 UX，写层的拒绝是绊线
  （手改 config 塞 5 个也进不来）。
- **陈旧 id（星标指向已不存在的包）：读时跳过、绝不写；只在下一次星标写入时顺手剪掉。**
  读路径写文件 = 打开面板就有副作用 —— 那是另一个 drop-zone 形状的坑。
- **同批三笔账（不是可选项）**：① `ConfigMutation.swift:7-8` 的 doc comment 写着「`selectPack` 与
  `setEventEnabled` 是它仅有的两个调用方」——**今天就是假的**（`MasterVolume.swift:123` 是第三个，
  2026-07-14 阶段 D），T16 加第四个时必须一并改成实话（本仓库规矩：假注释就是 bug）；
  ② ENGINEERING.md「写入者有三个，但写路径只有一条」→ 四个；
  ③ `ClaudioConfig.swift:7` 的「v1 fields only: `selected_pack` / `master_volume` / per-event
  `enabled`」——加 `starredPacks` 字段的同一笔改动里更新（Codex 逮到，否则又一条留在原地的假话）。

### `parseRewritableConfig` 加一条形状校验（⚠ 措辞要精确的地方）

`ConfigMutation.swift` 是 helper 与 GUI **共用**的模块 —— 所以本节不说「helper 零改动」，说精确的：
**`play` / `doctor` 的播放判定零改动**（`ClaudioConfig` 增加一个播放链**不消费**的宽松可选字段，
见「读模型」的读机制条 —— 本节第一版写的「宽松读**不 decode** `starred_packs`」与读模型**自相矛盾**：
面板读模型的唯一 config 输入就是 `PanelConfigState.operational(ClaudioConfig)`（`PanelConfig.swift:18`），
不进这个类型，读模型**结构上看不见**星标集。2026-07-17 `/plan-eng-review` 更正）；
config 写原语按 `events` 的既有先例**多认一个键**：

- `starred_packs` 存在但不是数组、或数组里有非字符串 → `.unreadable`，reason 必须**可执行**
  （哪个键 / 必须是什么 / 当前是什么 / 怎么修 + `configRebuildHint`），`probeConfigRewritable` 与
  真写路径**逐字同一句** —— 全部是既有契约照抄，`ConfigMutationSuite` 的断言形状现成。
- **兼容性注记（诚实说出去）**：一份昨天还被当未知键放行的畸形 `starred_packs`，加校验后会让**所有写**
  fail closed（读 / 播不受影响）—— 与当年给 `events` 加校验同形状。`doctor` 会把原因说成人话。
- id 的**内容**不校验（`isSafePackID` 不进 parse）：与 `selected_pack` 同款 —— 形状校验管
  「能不能安全重写」，存在性 / 合法性由读模型的 ∩ 磁盘过滤兜住。

### 读模型

**读机制（2026-07-17 `/plan-eng-review` 补，第一版整段缺失）**：`ClaudioConfig` 增加
`public var starredPacks: [String]?` —— `(try? container.decode([String].self, ...)) ?? nil` 的宽松形状，
**缺键 → `nil` / `[]` → `[]`**（缺键≠空数组的那把刀正是 `[String]?` 的 `nil` 位）。
- **不开第二条 config 读路径**：`loadPanelConfig` 的三次独立读已有记档 TODO（「文档写的一次读」），
  为星标再开第四读是往同一个坑里加深 —— 复用唯一那次 `loadClaudioConfig` 解码。
- ⚠️ **诚实注记**：`try?` 会把「present 但畸形」也折叠成 `nil`（= 缺键默认）。这**只在 probe 已把
  畸形拦在 `.malformed`** 的面板路径上是安全的（`loadPanelConfig` 先问 `probeConfigRewritable`，
  畸形 config 根本到不了读模型）；`play`/`doctor` 不消费该字段，折叠对它们无意义。这句话要写进
  字段的 doc comment，不许省。
- **helper 回归绊线**：同一份带 5 星 / 畸形星的 config，`play` 的播放判定与加字段前**逐字一致**。

面板显示集 = 星标过滤**作用在 id 层**（`availablePacks` 枚举出的 `orderedIDs` ∩ 星标集，**在
`buildPackCard` 之前** —— 每张卡 = 一次目录解析 + manifest 读 + 解码，主线程 `reload()` 每次开面板
都跑，装 20 个包只显示 4 行时不许白读 16 份 manifest；管理窗口才需要全量卡片）→ 既有 `id` 排序 →
防御性 `prefix(4)`（写层已保 ≤4，读层不信任磁盘）。**零新排序机制。**
- **零写断言用类型背书，不用字节比较**：显示集过滤是一个**纯函数**（`[String]` 进、`[String]` 出，
  签名里没有 URL / FileManager）——「读路径绝不写盘」由类型层面成立。字节比较背书「没被碰过」是
  本仓库记档的已知弱断言（「写了又擦回去」全程绿），不再新增一处。
- 上限是一个具名常量 `maxStarredPacks = 4`，**住 `ClaudioCore`**（写者 `StarredPacks.swift` 旁），
  `PackGallery.swift` 经既有 `import ClaudioCore` 取同一个定义 —— 读写两侧**不许**各养一个 4。
  它与「四个事件」数值巧合，语义无关。

**管理窗口（T17）的星标状态源 = 原始 `starred_packs` ∩ 磁盘，不是 prefix(4) 后的显示集。**
否则手改 config 塞出的第 5 颗星在 app 内**不可见也不可解除**，且窗口下一次「显式全量」写会把它
**静默截掉** —— 违反绝不静默铁律。>4 时窗口如实显示 N 颗星 + 超上限提示（新星禁用），用户解除到
≤4 后恢复；面板侧照常 `prefix(4)`。

### ⚠ 排期硬约束（不是可选项）

**≤4 过滤的激活不得早于星标 UI（管理窗口）落地。**
出厂默认只星内置包 —— 若过滤先上而星标钮还没有，装了个人包（皮卡丘 / 可达鸭…）的用户会看到它们
从面板**消失且无处找回**（管理窗口是唯一的星标面，而它还不存在）。所以：

- **阶段 1 的 T4**：竖排行渲染**全部**包（照旧可滚动），不过滤；
- **T16（星标契约：parse 校验 + 读模型 + 写路径）**：纯逻辑 + 测试，可进阶段 1，**不激活过滤**；
- **T17（星标 UI + 过滤激活）**：钉死在阶段 2，与 T8 管理窗口同批。

---

## 3. 任务表

| # | P | 组件 | 做什么 | 文件 |
|---|---|---|---|---|
| **T0** | **P1** | 重构 | **先把 `loadDropRequest` 抽到 `AudioDropRequest.swift`。** 它 module-internal 住在 `AudioDropZoneView.swift` 里，且被 `EventRowView:439` 复用 —— **先删文件就是一个红编译** | 新 `AudioDropRequest.swift` |
| T1 | **P1** | drop-zone | **删除**面板级 `AudioDropZoneView`（假功能，孤儿制造机）。⚠️ **它是 `onImportSucceeded` 在生产代码里唯一的赋值点** —— 删了它就删掉了产品里唯一的「导入后自动试听」 | `PanelView.swift:574-580`, `AudioDropZoneView.swift` |
| T2 | **P1** | 事件行 | 文件名 → 原生 `Menu`（三态共用一个控件）。**阶段 1 的菜单只有**：`选文件… / 清除绑定 / 在访达中显示`。<br>⚠️ **必须把 `onImportSucceeded` 接到行的 previewPlayer 上**（补回 T1 删掉的自动试听）。<br>⚠️ **焦点模型见 §2.5** | `EventRowView.swift`, `PanelFocusOrder.swift`, `CoverageState.swift` |
| T3 | **P1** | 绑定 | `mutateManifestJSON` **顶层**原语 + `clearEventBinding`（§2.1）。<br>⚠️ **同批给 `SourceScannerSuite` 加并发绊线**：manifest 写函数带 `async`/`Task`/`DispatchQueue` → 测试红 | `ManifestBinding.swift`, `SourceScannerSuite.swift` |
| T4 | **P1** | 包行 | 卡片画廊 → **竖排整宽行**（2026-07-17 拍板）：行 = `[包名] [meta 槽] … [覆盖轨]`；缺失格 = **空槽+斜杠**；`broken` 行 = 真红 ✕ + `text-2` 文案、**以状态行替代轨（保留同一槽位高度，布局不跳）**。⚠ 「恒显」的精确含义 = **manifest 可读（`complete`/`partial`）的行必有轨** —— 第一版「覆盖轨恒显」与「broken 不渲染轨」在同一行互相打架（Codex 逮到），a11y 模型按此二分。⚠ 阶段 1 渲染**全部**包（可滚动），≤4 过滤在 T17（§2.6 排期硬约束）。模型 `PackCard` / 焦点槽 `packCard(id:)` 的**名字沿用**（改名要动 `PanelFocusOrder` + 全部测试，为一个名字不值 —— 与 `ManifestBindError` 不改名同款拍板） | `PackGalleryView.swift` |
| T5 | **P1** | 包行 | `CC0` 与「缺 N 个」拆到**两个槽位**（今天 `statusLine` 的 `switch` 让残包丢 CC0 标）。竖排行里 = **meta 槽**（含 T13 的 `⚠ 已修改`）与覆盖轨分居 —— mockup 没画 meta 标是**省略不是推翻**（DESIGN.md「包行四态」澄清条） | `PackGalleryView.swift` |
| T6 | **P1** | 内置包 | `factoryPacksDirectory`（§2.3）；**删死函数 `isBuiltinOnlyPackID`**；`.overwritesBuiltin` → `.builtinReadOnly` + 新文案；`forkPack`（§2.2，**temp-dir + rename**，**必须改写 manifest 的 `id`**）。**同批改写 `availablePacks` 的 doc**（`PackGallery.swift:82-108` 仍写着「枚举 user ∪ bundled 两个根」且实现真的读 `bundledPacksDirectory` —— GUI 侧恒 `nil` 后那是死枝，doc 必须说清 **factory 不是查找根**，否则下一次「顺手复用」有文档帮它背书，Codex 逮到） | `AudioImportEnvironment.swift`, `AudioImport.swift`, `DropZoneState.swift`, `ClaudioGUIApp.swift`, `PackGallery.swift`, 新 `PackFork.swift` |
| **T13** | **P1** | CC0 诚实 | `factoryIntegrity(packID:)`（§2.4）：manifest 字节 + 声明文件**逐字节**与 bundle 比对（2026-07-17 从 size 升级 —— 等长替换否则漏检）。不一致 → 包行 meta 槽显示 **`⚠ 已修改`** 而不是 `CC0` | `PackGallery.swift` |
| **T14** | **P1** | 导入 | **目标文件名冲突 → 生成唯一名，绝不覆盖**（§2.2b）。今天的覆盖行为会**静默改掉引用同名文件的其他事件的声音**。⚠️ **现有测试把旧行为钉成了断言**（2026-07-17 二审逮到，第一版测试账漏了）：`AudioImportSuite:519`「re-dropping onto the same filename … **replaces** it」与 `:553`「symlink 替换」—— T14 落地两条必红，须**重写语义而非删除**（唯一名路径根本不触碰既有目录项，symlink 那条守的「绝不写穿链接」性质要换一个成立的表述） | `AudioImport.swift:216-231`, `AudioImportSuite.swift` |
| T7 | **P1** | 面板节结构 | 「声音包」节标题 + 列表下方「**管理声音包…**」**全宽虚线 ghost**（2026-07-17 mockup 拍板 —— **推翻本行第一版「不得全宽 ghost」**：撞脸顾虑由**虚线 vs 实线**消解，全宽虚线自此专属「通往管理窗口」）+ 事件区标题「**{当前包名} · 事件**」（**负重**：当前包未加星不显示时，它是面板上唯一的当前包读数，§2.6 决议 2）。⚠️ **标题的包名来源必须独立于显示集**（Codex 逮到：`PanelView.swift:500` 今天从 `packCards.first(where: \.isSelected)?.name` 取名 —— 当前包被星标过滤出列表后 `packCards` 里没有它，只能退回裸 id，「{当前包名} · 事件」的验收会假绿或退化）：T7 落一个不依赖显示集的 `selectedPackMetadata`（对选中包的一次 manifest 读，走既有 `loadPackManifestData`；`headerAccessibilityLabel` 同源同修）。<br>⚠️ **`管理…` 必须是焦点目标 `.manageSounds`，排在 `.disconnect` 之前** —— 否则零行面板首焦点落在卸载键上（§2.5 第 5 条；星标时代零行是**日常态**）。<br>**阶段 1 中间态拍板（2026-07-17 修订时定，T8 未落地前）**：点击「管理声音包…」= **在访达中显示 `~/.claudio/packs/`**（既有词汇、真动作）。三个替代各撞一条本仓库铁律：做成禁用 → `panelFirstFocusTarget` 的 OPERABLE 过滤把零行首焦点滑到卸载键；先不渲染 → 违反零行首焦点验收；渲染但无动作 → 违反「绝不静默吞错」（`Use.swift` 的 never-silent-no-op）。T8 落地时改绑真窗口。<br>**同批改写 needsPack 空态卡文案与 `accessibilityLabel`**（「点一张**卡片**」→「点一个声音包」；零行时主行动指向「管理声音包…」—— DESIGN.md「面板显示集 · 星标」新条，`PanelView.swift:611-623`） | `PanelView.swift:601-623`, `PanelFocusOrder.swift` |
| T10 | **P1** | 对比度 | `ContrastSuite` 补 4 条断言：覆盖轨 `present`/`missing` × 亮/暗 vs `surface-2`（值见 DESIGN.md） | `ContrastSuite.swift` |
| T8 | P2 | 管理窗口 | 新 `SoundPacksWindow`。规范见 DESIGN.md「Sound Packs Window」。<br>⚠️ **时序/状态同步必须设计**：谁持 `NSWindow`、`管理…` 怎么开、窗口写完怎么刷 popover、popover 切包怎么刷窗口 | 新 target |
| T9 | P2 | a11y | 窗口的焦点序 / Dynamic Type / VoiceOver。**`PanelFocusTarget` / `PanelLayoutAdaptation` / `PanelAnnouncement` 全是面板专用，套不上** | 新文件 |
| T11 | P2 | 孤儿 | 包内音频枚举 + 「未被任何事件引用」判定；管理窗口列出 + 分配/删除。**事件行下拉的「复用包内已有音频」也在这一批**（阶段 1 刻意不做 —— 见下） | `PackGallery.swift` |
| T12 | P2 | 存量 | `restoreFactoryPack`（§2.2）—— **不是**复用 `copyBundledPacks`，只复用它的 staging+rename 机械部分 | 新 `PackRestore.swift` |
| **T16** | **P1** | 星标契约 | `starred_packs`（§2.6）：`parseRewritableConfig` 形状校验（数组 of 字符串，reason 可执行 + probe/写路径逐字同句）+ 读机制（`ClaudioConfig.starredPacks: [String]?` 宽松可选字段）+ 读模型（缺键=`builtinPackIDs` / `[]`=零行 / ∩磁盘 / id 层过滤 / `prefix(4)`）+ 写者 **`setStarredPacks`**（新 public 包装，`.failClosed`、锁同款、去重 + >4 distinct 拒绝、陈旧 id 只在写时剪）。**同批改假 doc**：`ConfigMutation.swift:7-8`「仅有的两个调用方」今天已假。**纯逻辑+测试，不激活过滤**；默认集依赖 T6 的 `builtinPackIDs` | `ConfigMutation.swift`, 新 `StarredPacks.swift`, `ClaudioConfig.swift`, `PackGallery.swift` |
| **T17** | P2 | 星标 UI | 管理窗口侧栏 **★/☆ 星标钮**（满 4 → 其余 `☆` 显式禁用 + 原因）+ **激活面板 ≤4 过滤**。⚠️ **窗口星标状态源 = 原始数组 ∩ 磁盘，不是 prefix(4) 显示集**（§2.6 读模型末条 —— 否则第 5 颗星不可见不可解除、下一次写静默截断）。⚠️ **过滤的真实激活点是 `PanelConfigController.reloadConfigReadModel` 的 `availablePacks` 调用（`:225-232`），不是 `PanelView`**（Codex 逮到 —— 视图层过滤 = 先读完全部 manifest 再丢弃，违背 §2.6「id 层过滤」）。⚠️ **刷新路径必须指定**：`reloadConfigOnly()` **不重算 `packCards`**（`:210-217` 实证）—— 星标写只改 config.json 却改变包列表，窗口写星后必须走会重算 `packCards` 的路由（全量 `reload()` 或新路由），走轻刷新 = 面板列表 stale。⚠️ §2.6 排期硬约束：不得早于 T8 管理窗口 —— 过滤先上 = 个人包从面板消失且无处找回 | `SoundPacksWindow`（新 target）, `PanelConfigController.swift`, `PackGallery.swift`, `PanelView.swift` |
| T15 | P3 | helper | `doctor` 对 `events: {}` 的空包措辞（今天报 `.complete`，与画廊的 `0/4` 读起来矛盾）。**语义不改**（§2.1b），只改措辞 | `Doctor.swift` |

### 分阶段（Codex 建议「阶段 1 过重」—— 部分采纳）

**阶段 1 = T0–T7, T10, T13, T14, T16**（把面板修活 + 让 CC0 不说谎；T16 只落契约与测试，**不激活过滤**）。
**阶段 2 = T8, T9, T11, T12, T17**（管理窗口 + 孤儿 + 恢复出厂 + 星标 UI 与 ≤4 过滤激活 —— §2.6 排期硬约束）。

**采纳 Codex 的一半**：事件行下拉在**阶段 1 只有 `选文件…/清除/访达`**，
**没有**「包内已有音频列表」。理由是它逼出了一条**隐藏依赖**：
那个列表需要「包内音频枚举 + 未被引用判定」= **T11 的全部数据**，而 T11 在阶段 2。
砍掉它，阶段 1 **不需要新增任何「包内音频枚举」**（readdir 包**内容** = T11 的数据；
`availablePacks` 对包**根**的既有枚举、覆盖轨读的 `packCoverage` 不算 —— 它们今天就在跑。
性能发现 P1 随之消失），而 ①② 两条致命 bug 照样全修。
（措辞于 2026-07-17 收窄：原句「一次 readdir 都不需要」比覆盖范围大 —— 本仓库记档的老病。）

**驳回 Codex 的另一半**：**T6 / T13 不能延期。**
Codex 说阶段 1 不必包含内置包只读。**但 T2 会让 ③ 变得更糟**：
给每一行装上「选文件…」之后，往「极简铃音」里塞一个有版权音频的路径**从难用变好用**。
**先做 T2 不做 T6 = 亲手把 CC0 谎言的入口拓宽。** 两者必须同批。

---

## 4. 验收

### 核心回归（三条实证发现的直接绊线）

- [ ] 一个**四事件齐全**的包（`minimal-chime` fork 出来的副本），能在面板里**替换任一事件的声音**，
      不需要先弄坏它。（今天不可能 —— ①② 的直接回归测试）
- [ ] 导入一个音频之后，它**要么被绑定、要么被拒绝并给出原因**。
      **不存在「拷进去了但什么都没发生」的第三种结局。**（今天这是**唯一**的结局）
- [ ] **导入成功后自动试听仍然响**（T1 删掉了它唯一的实现，T2 必须补回来）。
      ⚠️ 这条**今天是绿的**（drop-zone 有），**改完之后很容易变红而没人发现** —— 它不是新功能，
      是一条**会被顺手删掉的现有行为**。

### 内置包 / CC0 诚实（③ 的真正修法）

- [ ] 内置包 `minimal-chime` **无法被写入**；试图编辑 → 引导「复制为我的包」。
- [ ] **`forkPack` 出来的副本没有 CC0 标**（`license` 被删 = 不作任何声明），
      且它的 **manifest `id` 等于新目录名**（不是 `minimal-chime`）。
- [ ] **一个被改脏的内置包，包行显示 `⚠ 已修改`，不是 `CC0`**（T13）。
      **构造方式**：直接往 fixture 的 `minimal-chime/stop.mp3` 写几个字节 → `factoryIntegrity` 必须失败；
      **另一条：等长替换**（同 size、不同字节）→ 也必须失败 —— 判据是逐字节，不是 `stat`
      （这条钉住的是「headline 说 bundle 背书、判据却放过同 size 污染」那半个洞）。
      ⚠️ **这条替换了计划第一版那条会自我背书的验收**（「原包仍有 CC0 标」——
      它假设了原包是干净的，而那正是不能假设的东西）。
- [ ] 「恢复出厂」之后，`factoryIntegrity` 重新通过，包行回到 `CC0`；
      **且用户自己加进去的文件被搬走而不是删掉**，并有明确告知。

### 状态机 / 语义

- [ ] `清除绑定` → 行显「未配置」（`unmapped`），**不是**「文件丢失」（`broken`）；
      `doctor` **不**把它报成缺陷；**磁盘上的文件还在**。
- [ ] **「四个事件全清空」的三方回答同时钉死**（§2.1b，已知分歧、被理解过）：
      `doctor` → `.complete`；`play` → 四个全静默；面板包行 → `partial(0/4)`「缺 4 个」。
      ⚠️ **三条必须写在同一个测试里** —— 否则下一个人会觉得是 bug，去「修好」一个，破坏另外两个。
- [ ] 一个 `CC0-1.0` 的**残包**（缺 1 个事件），包行上 **`CC0` 标与「⚠ 缺 1 个」同时可见**。
      （今天残包会丢掉 CC0 标）
- [ ] **导入同名文件不覆盖**（T14）：包里已有 `a.mp3` 且被「中断了」引用 →
      给「干完了」导入另一个也叫 `a.mp3` 的文件 → 生成 `a-2.mp3`，
      **「中断了」的声音一个字节都没变**。

### 星标显示集（§2.6 · 2026-07-17）

- [ ] **缺键与空数组是两个不同结局**：无 `starred_packs` 键 → 显示集 = `builtinPackIDs`；
      `starred_packs: []` → 零行。⚠️ 这条是「取消默认星后复活」的直接绊线 —— 两个 fixture 必须分开断言。
- [ ] 取消内置包的星（写盘为不含它的显式数组）→ 重启 / `reload()` 后**不复活**。
- [ ] 当前包未加星 → 不在包列表里；事件区标题仍显「{当前包名} · 事件」（决议 2 的两半在同一个测试里）。
- [ ] 手改 config 塞 5 个有效星 → 星标**写路径**拒绝；**读路径** `prefix(4)` 防御性生效（两层分开测）。
- [ ] （T17）同一份 5 星 config：**窗口显示 5 颗可解除的星** + 超上限提示（新星禁用），面板只显示前 4；
      用户解除 1 颗后写盘成功 —— **任何路径都不静默截断**（窗口状态源 = 原始数组，非显示集）。
- [ ] `starred_packs: ["a","a","b"]`（重复 id）：显示集 = {a,b}（成员判定天然去重）；
      下一次星标写入落盘为**去重后的显式数组**；cap 判定按 distinct 数。
- [ ] 陈旧星标 id：读时跳过不渲染、**config.json 一个字节不动**（读路径零写断言）；下一次星标写入时被剪。
- [ ] `starred_packs: "abc"`（非数组）→ `probeConfigRewritable` = `.malformed`，reason 可执行且与真写路径
      **逐字相同**；同一份 config 下 `play` / `doctor` 的播放判定**不受影响**（宽松读不认识它）。
- [ ] **helper 回归**：带合法 `starred_packs` 的 config，`claudio use` / 静音 / 主音量写后该键**键值幸存**
      （未知键保真契约的新键专项 —— 它从「未知键」变成「被校验的键」后这条不许变松）。
- [ ] 零行包列表首焦点 = `.manageSounds`（与 §2.5 第 5 条同一条断言 —— 星标时代它守的是日常路径）。
- [ ] **加星侧的物化断言**（防「默认星静默消失」—— 与「取消不复活」互不覆盖，两条都要）：
      缺键状态下经写路径给一个**非内置**包加星 → 写盘数组 = **显式全量**（内置包 id 仍在 + 新包 id），
      reload 后两者都显示。只写 `["新包"]` 而丢掉默认星 = 一个不会报错的错误，这条必须逮住它。
- [ ] **needsPack × 零行同屏**（两根正交轴）：config 缺失且零星标 → 空态卡主行动指向「管理声音包…」；
      **无**「 · 事件」半截标题被渲染。
- [ ] （T17）星标写失败（config malformed / lock busy / >4 拒绝）→ **窗口内可见错误行**
      （`FailureRow` 组件与 token 层复用，DESIGN.md「窗口的失败呈现」）+ VoiceOver 播报；
      reason 与 `probeConfigRewritable` **逐字同句**。

### 结构性绊线（防止「顺手改坏」）

- [ ] **`factoryPacksDirectory` 从来没被喂给 `resolvePackDirectory`。**
      断言 GUI 的 `availablePacks(...)` 列出的包集合，与 helper 的 `play` 能解析到的包集合
      **逐字相同**。
      （§2.3 的「假阴性」陷阱 —— 两个字段名字太像，这是一条**真会被顺手合并**的绊线。
      谁哪天把它传进去，这条必须红。）
- [ ] **并发不变式的源码绊线**（T3）：`ManifestBinding.swift` / `PackFork.swift` 里任何导出的
      manifest 写函数带 `async` / `Task` / `DispatchQueue` → **`SourceScannerSuite` 红**。
      ⚠️ 不变式今天靠的是「**全同步 + 全在 MainActor**」，**不是靠锁**（本文件 §2.1 的更正）。
      一句注释保不住它 —— 这个仓库已经为「一条被跨过去还留在原地的绊线」交过学费。
- [ ] **`forkPack` 被中途 kill，不留下可见的残包**：
      `.{id}.tmp-{pid}/` 不出现在 `availablePacks` 里（`packDirectoryIDs` 的 dot 过滤器）。
- [ ] `ContrastSuite` 四条新断言绿；**且变异实测**：把覆盖轨 `missing` 的描边改回 `muted`，
      断言必须**红**。（「措辞比覆盖范围大」—— 这个仓库的老病）
- [ ] **空面板（零个包）的首焦点不落在「断开连接」上**（§2.5 第 5 条）。
      断言 `panelOpeningFocus(rows: [], packCardIDs: [], …) != .disconnect`。
- [ ] **`.manageSounds` 的诚实性双向钉**（§2.5 第 5 条 ⚠ 补条）：管理钮在 `operationalPanel`
      全部四个 configState 渲染 + `panelFocusOrder` 无条件 append（`ViewWiringSuite`，漂移任一半都红）；
      且 in-flight（`ctaOperable == false`）下 operational scope 首焦点**仍非 nil**（它是 `.dropZone`
      死后「永不返回 nil」这条文档保证唯一的继承者）。

### 真机走查（测试结构上兜不住的）

- [ ] **`.tint(clay)` 在新的 `Menu` 上是否真的生效？**
      `ContrastSuite` 是纯 hex 数学，`ClaudioGUICore` 连 SwiftUI 都不 link，**结构上测不到**。
      守门人是人：系统强调色设成红 → 开面板 → 看下拉的强调色是黏土不是红。
      **正向对照先自证**：同条件下**裸** `Menu` 必须渲染成红 —— 否则这个探针什么也没证明
      （2026-07-14 走查 ⑨ 的同一条方法学）。
- [ ] **key + active 窗口下做**。离屏 / 非 key 窗口会让 macOS 把强调色去饱和成灰，
      得出「`.tint` 无效」的错误结论（DESIGN.md 已实证记录）。

---

## 4b. 测试覆盖图（`/plan-eng-review`）

```
代码路径                                              用户流 / 失败模式
[+] ManifestBinding.swift
  ├── mutateManifestJSON(at:_:)          【新原语】
  │   ├── [GAP] 目录解析失败 → .packNotFound
  │   ├── [GAP] 解析到的是 bundled 根（非用户包）→ .packNotFound
  │   ├── [GAP] manifest 读不出 → .manifestUnreadable
  │   ├── [GAP] 顶层不是 object → .manifestUnreadable      ← 三道 fail-closed
  │   ├── [GAP] events 不是 object → .manifestUnreadable      必须逐条继承，
  │   ├── [GAP] events 有非字符串值 → .manifestUnreadable      不能在重构里蒸发
  │   ├── [GAP] 顶层 id 缺失/空 → .manifestUnreadable
  │   ├── [GAP] encodeJSONObjectForWriting 拒绝（-inf）→ .writeFailed
  │   └── [GAP] 未知顶层键原样保住（schema/version/未来键）
  ├── bindEventToManifest()              【改：委托给原语】
  │   └── [★★★ 已测] ManifestBindingSuite (1108 行) —— 回归基线，必须仍全绿
  └── clearEventBinding()                【新】
      ├── [GAP] 清除已绑定的 event → unmapped，**文件仍在磁盘上**
      ├── [GAP] 清除一个本来就 unmapped 的 event → 幂等，不报错
      ├── [GAP] 清除后 doctor 不报缺陷（对比 broken）
      └── [GAP] 四个全清空 → doctor .complete / play 全静默 / 包行 0/4  ← 三方同一测试

[+] PackFork.swift                        【新文件】
  ├── forkPack(fromID:newID:)
  │   ├── [GAP] 新 id 冲突 → -copy-2，**绝不覆盖**
  │   ├── [GAP] 新 manifest 的 id == 新目录名（不是原 id）   ← Codex 逮到的漏项
  │   ├── [GAP] license / author 被删；schema / events 保留
  │   ├── [GAP] 中途失败 → .{id}.tmp-{pid}/ 不出现在 availablePacks 里
  │   └── [GAP] 从 factoryPacksDirectory fork（而非从可能已脏的用户副本）
  └── restoreFactoryPack(id:)
      ├── [GAP] 已存在且可用的包**也会被替换**（≠ copyBundledPacks 的 skip 行为）
      ├── [GAP] 用户自加的文件被**搬走而非删掉** + 明确告知
      └── [GAP] 恢复后 factoryIntegrity 重新通过

[+] PackGallery.swift
  └── factoryIntegrity(packID:)           【新 · T13】
      ├── [GAP] 干净的内置包 → 通过 → 包行显示 CC0
      ├── [GAP] stop.mp3 被改了几个字节 → 失败 → 包行显示 ⚠ 已修改   ← ③ 的真修法
      ├── [GAP] manifest 被改 → 失败
      └── [GAP] 非内置包 → 不参与判定（不显示 ⚠）

[+] AudioImport.swift
  └── importAudioFile()                   【改 · T14】
      ├── [GAP] 目标名冲突 → 生成 a-2.mp3，**引用 a.mp3 的其他事件一个字节没变**
      ├── [REWRITE] AudioImportSuite:519「re-drop 同名 = 替换」—— T14 刻意推翻的旧契约，必红，重写不删
      └── [REWRITE] AudioImportSuite:553「symlink 替换」—— 唯一名路径不再触碰既有目录项，性质要换表述

[+] PanelFocusOrder.swift / CoverageState.swift   【改 · §2.5】
  ├── [REWRITE] CoverageStateSuite 的 8 条（previewClaimsActionFocus 作废 / eventActionOperable 语义变）
  ├── [REWRITE] PanelFocusOrderSuite:329「零行首焦点 = .dropZone」整条 suite —— T7 必红，改钉 .manageSounds
  ├── [GAP] 每行三个焦点槽：eventSound → eventAction → eventMute
  ├── [GAP] unmapped 行首焦点落在 eventSound（那个能修好它的控件）
  ├── [GAP] 空面板（零包）首焦点 ≠ .disconnect                ← 防「开面板即卸载」
  └── [GAP] .manageSounds 诚实性：四个 configState 全渲染（ViewWiring 双向钉）
      + in-flight（ctaOperable=false）下 operational 首焦点仍非 nil    ← .dropZone 非空保证的继承者

[+] SourceScannerSuite.swift              【新绊线 · T3】
  └── [GAP] manifest 写函数带 async/Task/DispatchQueue → 红

[+] ConfigMutation.swift / StarredPacks.swift / ClaudioConfig.swift / PackGallery.swift   【新 · T16 星标契约】
  ├── [GAP] 缺键 → builtinPackIDs；[] → 零行（两个不同结局，防复活）
  ├── [GAP] ClaudioConfig.starredPacks 宽松三态：缺键→nil / []→[] / 合法数组→值
  │        （畸形折叠成 nil 的语境安全性：probe 已把畸形拦在 .malformed，读模型到不了）
  ├── [GAP] 缺键下加星非内置包 → 写盘显式全量（默认星不静默消失）
  ├── [GAP] starred_packs 非数组 / 含非字符串 → .unreadable（probe 与写路径逐字同句）
  ├── [GAP] >4 distinct 有效星 → 写拒绝；读 prefix(4)（两层分开）
  ├── [GAP] 重复 id：["a","a","b"] 显示集 = {a,b}；写时折叠成去重显式数组
  ├── [GAP] 陈旧 id：读跳过 + 零写（纯函数签名背书，非字节比较）；写时剪
  ├── [GAP] （T17）5 星 fixture → 窗口模型显示 5 颗可解除的星；面板 prefix(4)（两面分开断言）
  └── [GAP] use/静音/主音量写后 starred_packs 键值幸存；play 判定与加字段前逐字一致

用户流
  ├── [GAP] [→真机] 换掉「干完了」的声音（不先弄坏包）—— ①② 的端到端
  ├── [GAP] [→真机] 加星第 4 颗后第 5 颗禁用且给原因；取消一颗后恢复可用（T17）
  ├── [GAP] [→真机] 导入后自动试听仍然响 —— **一条会被顺手删掉的现有行为**
  ├── [GAP] [→真机] 试图改内置包 → 引导「复制为我的包」→ 副本可改
  ├── [GAP] [→真机] 三态 Menu 的 VoiceOver 输出（行身份/菜单 label 不重复播报、禁用试听不抢播、
  │        unmapped 行听得出「这里能修」—— §2.5 第 7 条）
  └── [GAP] [→真机] .tint(clay) 在 Menu 上生效（正向对照先自证）

COVERAGE: 现有 0/44 新路径有测试（口径 = [GAP] 46 条 − [→真机] 6 条 + [REWRITE] 4 条；
真机项不计入自动测试路径数 —— 2026-07-17 二审后口径，同日一审为 0/37、更早为「0/31」，同口径）
回归基线：ManifestBindingSuite 1108 行必须仍全绿；ConfigMutationSuite 必须仍全绿；
AudioImportSuite 的 re-drop 两条（:519/:553）是【被 T14 刻意推翻】的基线 —— 必须重写语义，不许照抄保绿
```

## 4c. 失败模式（每条新路径一个真实的生产故障）

| 新路径 | 一个真实的失败 | 有测试？ | 有错误处理？ | 用户看得见？ |
|---|---|---|---|---|
| `clearEventBinding` | 清除时 manifest 被外部改成非法 JSON → 写回覆盖用户的手改 | 待建 | ✅ fail-closed（原语的三道 guard） | ✅ `FailureRow` |
| `forkPack` | 拷到一半磁盘满 → 半个包 | 待建 | ✅ temp-dir + rename（残骸不可见） | ✅ 拒绝行 |
| `restoreFactoryPack` | 用户自加的文件被**删掉**而不是搬走 | 待建 | ⚠️ **必须实现 salvage** | ✅ 必须告知 |
| `factoryIntegrity` | bundle 里没有 packs（dev build）→ 判定不出来 | 待建 | ✅ `factoryPacksDirectory == nil` → 不参与判定，**不显示 ⚠**（诚实降级） | — |
| `importAudioFile` 唯一名 | `a.mp3` / `a-2.mp3` / … 无限增长 | 待建 | ⚠️ 需要上限或复用检测 → **P3** | 阶段 2 孤儿视图 |
| 文件名 `Menu` | 包目录被外部删空 → 菜单为空 | 待建 | ✅ 只剩「选文件…」 | ✅ |
| `starred_packs` 形状校验（T16） | 存量 config 带畸形 `starred_packs`（旧版当未知键放行）→ 加校验后 use / 静音 / 主音量**全部** fail closed | 待建 | ✅ `.unreadable` → probe `.malformed`，reason 可执行 + `configRebuildHint`（§2.6 兼容性注记） | ✅ `doctor` 说成人话；面板 `FailureRow` |
| 星标写路径（T17） | config malformed / lock busy / >4 拒绝 → 星标钮写失败 | 待建 | ✅ fail closed，reason 与 probe 逐字同句 | ✅ 窗口内 `FailureRow`（DESIGN「窗口的失败呈现」）+ VO 播报 |
| **并发不变式** | **有人把 `forkPack` 改成 `async` 去避免 UI 卡顿 → 无锁 RMW 竞争，manifest 丢更新** | **T3 的源码绊线** | ❌ **结构上没有锁** | ❌ **静默丢失** ← **唯一的 critical gap** |

> **唯一的 critical gap**：并发不变式**没有运行时防护**（无锁），只有「全同步 + 全在 MainActor」
> 这条**结构性**约束。一个善意的 `async` 重构会静默破坏它，而**没有任何运行时会报错**。
> 这正是 T3 那条源码绊线**必须存在**的理由 —— 它是这个洞**唯一**的守卫。

## 4d. 并行化

| 步骤 | 触碰的模块 | 依赖 |
|---|---|---|
| T0（抽 `loadDropRequest`） | `ClaudioGUI/` | — |
| T3（原语 + clear + 绊线） | `ClaudioGUICore/`, `Tests/` | — |
| T6 + T13 + T14（内置包 / 诚实 / 唯一名） | `ClaudioGUICore/`, `ClaudioGUI/` | T3（共用原语） |
| T4 + T5 + T10（包行 + 对比度） | `ClaudioGUI/PackGalleryView`, `Tests/` | — |
| T16（星标契约） | `helper/ClaudioCore/ConfigMutation`, `ClaudioGUICore/PackGallery`, `Tests/` | T6（`builtinPackIDs`） |
| T1 + T2 + T7（面板 + 焦点） | `ClaudioGUI/`, `ClaudioGUICore/PanelFocusOrder` | T0, T3 |

```
Lane A: T3 → T6+T13+T14 → T16  （共用 mutateManifestJSON；T16 的默认集依赖 T6 的 builtinPackIDs）
Lane B: T4 + T5 + T10          （只碰 PackGalleryView + ContrastSuite，独立）
Lane C: T0 → T1 + T2 + T7      （面板 + 焦点，依赖 T0 与 T3 的原语）

并行：A 与 B 可同时开工。C 等 T3 落地。T16 挂 Lane A 尾部 —— 必须等 T6。
⚠️ 冲突旗标：Lane A 与 Lane C 都碰 `ClaudioGUICore/` —— A 改 ManifestBinding，
   C 改 PanelFocusOrder/CoverageState，文件不重叠，但同一 target，合并时留意。
⚠️ 冲突旗标 2（2026-07-17）：T13 与 T16 都改 `PackGallery.swift` —— **同文件**，
   须顺序进行（同在 Lane A 尾部即天然顺序，不得拆去并行）。T16 另碰 helper 侧
   `ConfigMutation.swift`，与 Lane A 其余任务的 `ManifestBinding.swift` 同 target 不同文件。
```

## 5. 明确不做

- **不引入 `~/.claudio/library/`**（第二个查找根）。ENGINEERING.md 早已拒绝那个形状；
  `helper` 的 `play` / `doctor` 解析链**零改动**是本方案的核心资产。
  代价：同一个音频想给两个包用 → 拷两份。接受。
- **不做音频编辑 / 裁剪 / 音量归一。** 那是另一个产品。
- **不在管理窗口里重做面板。** 面板管「不回头也知道状态」，窗口管「坐下来把它配好」。
  两个不同的使用时刻，不互相抄。
- **面板上不放星标控件。** 策展（加星 / 取消）住管理窗口 ——「两个不同的使用时刻，不互相抄」。
- **星标显示集的四个被否方案不做**（2026-07-17 拍板，判词存档 DESIGN.md Decisions Log）：
  当前包特赦恒显（星标不再是唯一判据）／切换自动加星（切包动作隐式改写星标集）／
  星数不限、显示截断（「加了但不显示」暧昧态）／零星回落前 4（回落集随装包漂移）。
- **读路径绝不剪陈旧星标**（打开面板就写盘 = 又一个带副作用的「只读」面，drop-zone 的老坑）。
- **星标不存 UserDefaults / 独立 plist**（2026-07-17 二审 Search check【Layer 1】）。macOS 惯例的
  UI 偏好存储对这里是错的：config.json 已有锁纪律、probe 契约、未知键保真与 doctor 可见性；
  第二个存储 = 第二条读写路径 + doctor 盲区 —— 与「不引入第二个查找根」同一条本能。
- **包行上不加试听 ▶。** 换包本已是一次点击且可逆，事件行是更好的试听面。
  为省一次点击要付：每行两个控件 → 撞破 `PanelFocusTarget.packCard(id:)` 的单焦点槽契约
  + 序列播放器 + 中断语义 + reduce-motion 门控。（评审中提出、当场砍掉，理由存档于 DESIGN.md）
- **波形「包指纹」不做。** 被 `/codex` 跨模型评审否决，判词成立：17pt 段 = 纹理不是信息，
  且缺失信号压在同一条不可读纹理上。（存档于 DESIGN.md，不要再提）
- **manifest.json 不加锁。** 保住「全同步 + 全在 `@MainActor`」这条**结构性**不变式（§2.1）。
  加锁会把它压进 bind/clear 的热路径 —— 拿一条真不变式换一次 UI 微卡顿，不划算。
  守卫是 T3 的**源码绊线**，不是一句注释。
- **阶段 1 的文件名下拉不列「包内已有音频」。** 那需要孤儿计算（T11），随管理窗口进阶段 2。
  砍掉它，阶段 1 **不需要新增任何「包内音频枚举」**（包根的既有枚举不算），而 ①② 照样全修。
- **`doctor` 对空包（`events: {}`）的语义不改**（只在 P3 改措辞）。三个子系统回答三个不同的问题，
  这条分歧是**被理解过的**，并由验收断言同时钉死（§2.1b）。

## 6. 已存在、被复用的东西（不重造）

| 已有 | 计划怎么用 |
|---|---|
| `encodeJSONObjectForWriting`（`JSONSafeWrite.swift`） | 新原语 `mutateManifestJSON` 直接用 —— 数字规范化 + 防 `-inf` 硬崩，两个洞都是**这个读-改-写形状本身**的洞 |
| `safePackFileURL` / `regularFileExists` / `resolvePackDirectory` | 一行不重写。`bind` 的文件预检、`coverage`、`doctor`、`play` **共用同一个谓词** |
| `packDirectoryIDs` 的 **dot 前缀过滤器** | `forkPack` / `restore` 的 `.{id}.tmp-{pid}` staging **直接靠它**不可见。零新机制 |
| `Setup` 的 staging + rename **机械部分** | `restoreFactoryPack` 复用它的**机械**，**不复用它的策略**（它会 skip 已可用的包） |
| `SourceScannerSuite`（567 行） | T3 的并发绊线挂在它上面 —— 这个仓库已经有「文本绊线」这套设施 |
| `ManifestBindingSuite`（1108 行） | **回归基线**：重构成原语之后必须**仍然全绿**，一条都不许改 |
| `previewClaimsActionFocus` | **删掉** —— 它存在的唯一理由（两控件抢一槽）被 §2.5 消灭了 |

---

## GSTACK REVIEW REPORT

| Review | Trigger | Why | Runs | Status | Findings |
|--------|---------|-----|------|--------|----------|
| CEO Review | `/plan-ceo-review` | Scope & strategy | 0 | — | — |
| Codex Review | `/codex review` | Independent 2nd opinion | 2 | issues_found | 07-15：13 findings, 10 folded / 2 partial / 1 rejected；07-17（outside voice）：10 findings, 9 folded / 1 partial |
| Eng Review | `/plan-eng-review` | Architecture & tests (required) | 2 | clean | 07-14：19 issues 全折入；07-17 二审（增量+接缝）：13 issues 全折入，含 1 条今天就存在的假注释 |
| Design Review | `/plan-design-review` | UI/UX gaps | 1 | issues_open | score: 3/10 → 9/10, 6 decisions |
| DX Review | `/plan-devex-review` | Developer experience gaps | 0 | — | — |

**07-14 一审存档**：19 条发现全折入；Codex（07-15）13 条中 2 条推翻本计划自己的事实断言（`bindEventToManifest` 零锁 / `copyBundledPacks` 不能直接复用），驳回 1 条（T6 延期 —— T2 会把 CC0 谎言入口从难用变好用，必须同批）。两模型独立收敛：删假 drop-zone 优先于一切。

**07-17 二审（本轮，范围 = §2.6/T16/T17 增量 + 改写的 T4/T5/T7 + 接缝，基座抽查；auto-select 授权）**：

- **Eng 二审 13 条（全部实证后折入）**，最重的三条：① §2.6 读机制**整段缺失且自相矛盾**——「宽松读不 decode `starred_packs`」与读模型打架（面板唯一 config 输入是 `PanelConfigState.operational(ClaudioConfig)`），修法 = `ClaudioConfig.starredPacks: [String]?` 宽松可选字段（缺键→`nil`/`[]`→`[]`，恰好是防复活那把刀的形状）；② **T16 写者没有落点**——`updateConfigJSON` 是 module-internal，按「每写者一个 public 包装」既有模式落 `StarredPacks.swift`（去重 + >4 distinct 拒绝 + 剪陈旧 id 全住写者）；③ **两条既有测试把 T14 要推翻的旧行为钉成了断言**（`AudioImportSuite:519/:553`）——测试账补 [REWRITE]。另有：`ConfigMutation.swift:7-8` doc **今天就是假的**（三个写者、注释说两个）；`.manageSounds` 要按 `.masterVolume` 先例过诚实性检查（无条件渲染 + append + in-flight 仍非 nil）；星标过滤在 id 层（省 manifest IO）；`maxStarredPacks` 常量住 ClaudioCore；零写断言用纯函数签名背书而非字节比较；不用 UserDefaults【Layer 1】。基座抽查（约 15 处行号/引文/行为断言）**全部与源码逐字吻合**——07-14 修订后的基座没有再犯「登记≠验证」。
- **CODEX（outside voice）10 条，9 折入 / 1 部分**：`setStarredPacks` 签名缺默认星展开（加 `defaultStarredPackIDs`）；T17 真实激活点在 `PanelConfigController.reloadConfigReadModel`（非 PanelView）；`reloadConfigOnly()` 不重算 `packCards` → 星标写后刷新路径必须指定；事件区标题包名来源必须独立于显示集（`PanelView.swift:500` 今天从 packCards 取名）；`PanelFocusOrderSuite:329` 整条钉死 dropZone 首焦点，必红须重写；三态 Menu 的 VoiceOver 输出要成为契约（§2.5 第 7 条）；T4「恒显」与「broken 不渲染轨」措辞打架（已收窄）；`ClaudioConfig:7`「v1 fields only」doc 会变假（入同批账）；`availablePacks` 的 user∪bundled doc 须随 T6 改写。**部分采纳**：T13 判据从 size 升级为**逐字节**（等长替换否则漏检 ——「措辞比覆盖范围大」第 N 次），但 Codex 的成本论证（「≤5MB×4」）不准确——只对内置包算、内置铃音本来就小，若未来变大再 memo 化。
- **CROSS-MODEL:** 两模型在「§2.6 是本轮唯一未审暴面、其风险集中在与既有读模型/焦点模型的接缝」上独立收敛；Codex 补的是 GUI 装配层（controller/刷新路由/标题来源）——恰好是 Claude 侧四段走查里最薄的一层。无未消解张力。
- **VERDICT:** ENG（二审）+ CODEX CLEARED — 计划可实施。唯一 critical gap（manifest 并发不变式无运行时防护）维持已知且被接受，守卫为 T3 源码绊线；Step 0 复杂度检查数值触发（16 任务 / ~18 文件），按 07-14 已裁定的两阶段切分维持原判（auto-select 授权），不再缩。

NO UNRESOLVED DECISIONS
