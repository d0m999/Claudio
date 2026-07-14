# PLAN — 声音包管理（Sound Pack Manager）

> 来源：`/plan-design-review` 2026-07-15（含 `/codex` 跨模型评审）。设计决议已写入 [DESIGN.md](./DESIGN.md)
> （「包卡片四态」/「4-slot 覆盖轨」/「行内文件名下拉」/「Sound Packs Window」四节 + 5 条 Decisions Log）。
> 本文件是**工程计划**：写路径、契约、验收。视觉真相源是 DESIGN.md，不是这里。

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
| 画廊卡片 | **`partial(0/4)`「缺 4 个」** | 它问的是「**覆盖**了几个事件」 |

**拍板：三者都不改，因为它们回答的是三个不同的问题。** 一个 `events: {}` 的包是**合法**的
（= 一个全静默的包）。

⚠️ **但必须写成验收断言把三者同时钉死** —— 否则下一个人会看到「doctor 说完整、画廊说缺 4 个」
觉得是 bug，去「修好」其中一个，当场破坏另外两个。**这条分歧是被理解过的，不是被忽略的。**
（`doctor` 对空包的**措辞**可以更友好 —— 记 P3，不阻断。）

### 2.2 `forkPack` + 「恢复出厂声音」—— 目录级操作，不是文件级

**⚠️ 目录级原子性：`Data.write(.atomic)` 只保证单个文件。**
一个包 = manifest + N 个音频。**逐文件拷到位**的话，中途被 kill 就会留下**半个包**躺在
`~/.claudio/packs/<newid>/` —— 而 `availablePacks` **会照常把它枚举出来**，用户看到一张自己
没造过的残卡。

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

    删掉 `license` = 卡片不再打 CC0 标 = **我们不再对这份副本的版权作任何声明**。
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
| **复用 `bundledPacksDirectory`（把 GUI 的 `nil` 改成真路径）** | ❌ **这是本节最重要的一条。** 那个字段**同时**喂给 `resolvePackDirectory`，它决定的是**包的查找顺序**。把它从 `nil` 改成真路径，会让「只存在于 bundle、还没被拷进用户根」的包**在 GUI 画廊里可见**——而 helper 的 `play` 看不见它（`PlayEnvironment.bundledPacksDirectory` 恒 `nil`，ENGINEERING T17：「v1 只走『复制进用户包』这一条路径」）。<br>`Setup.swift:503-505` **已经踩过并写下了这个警告**：「若把 `Resources/packs/` 传进去，就会认可一个 **`play` 根本看不见**的包 —— 一次假阴性」。<br>**一个字段一个职责。`bundledPacksDirectory` 的职责是查找，它的 `nil` 是负重的。** |

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
> 判据（便宜，不是密码学 —— 这是**诚实信号**，不是安全边界）：
> - `manifest.json` **字节完全一致**（约 300 B，一次小读）
> - 每个**声明文件**的 **size 一致**（`stat`，4 次）
>
> 与 `factoryPacksDirectory` 里的出厂副本比。只对 `builtinPackIDs` 里的包算
> （今天就一个），随 `packCards` 在 `reload()` 里算一次。
>
> **不一致 → 卡片显示 `⚠ 已修改`，而不是 `CC0`**，并在管理窗口引导「恢复出厂」。
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
   **并同批改写 `panelFirstFocusTarget` 那段已经失效的文档** ——
   这个仓库刚为「一句不再成立的断言留在原地」交过两次学费。

6. **测试要重写，不是删**（计划第一版没算这笔账）：
   `CoverageStateSuite` 有 **8 条**用例钉死 `previewClaimsActionFocus` / `eventActionOperable`
   的现语义；`PanelFocusOrderSuite:302` 那条「首焦点必须 ≠ `order.first`」的**前提**也变了
   （muted 行的首焦点从「跳过禁用的试听」变成「落在文件名下拉上」）。

---

## 3. 任务表

| # | P | 组件 | 做什么 | 文件 |
|---|---|---|---|---|
| **T0** | **P1** | 重构 | **先把 `loadDropRequest` 抽到 `AudioDropRequest.swift`。** 它 module-internal 住在 `AudioDropZoneView.swift` 里，且被 `EventRowView:439` 复用 —— **先删文件就是一个红编译** | 新 `AudioDropRequest.swift` |
| T1 | **P1** | drop-zone | **删除**面板级 `AudioDropZoneView`（假功能，孤儿制造机）。⚠️ **它是 `onImportSucceeded` 在生产代码里唯一的赋值点** —— 删了它就删掉了产品里唯一的「导入后自动试听」 | `PanelView.swift:574-580`, `AudioDropZoneView.swift` |
| T2 | **P1** | 事件行 | 文件名 → 原生 `Menu`（三态共用一个控件）。**阶段 1 的菜单只有**：`选文件… / 清除绑定 / 在访达中显示`。<br>⚠️ **必须把 `onImportSucceeded` 接到行的 previewPlayer 上**（补回 T1 删掉的自动试听）。<br>⚠️ **焦点模型见 §2.5** | `EventRowView.swift`, `PanelFocusOrder.swift`, `CoverageState.swift` |
| T3 | **P1** | 绑定 | `mutateManifestJSON` **顶层**原语 + `clearEventBinding`（§2.1）。<br>⚠️ **同批给 `SourceScannerSuite` 加并发绊线**：manifest 写函数带 `async`/`Task`/`DispatchQueue` → 测试红 | `ManifestBinding.swift`, `SourceScannerSuite.swift` |
| T4 | **P1** | 包卡片 | 删 2×2 网格；`complete` **零图形**；`partial` 出 4-slot 覆盖轨（缺失格 = **空槽+斜杠**，另一种形状）+ `⚠` 图标 + `text-2` 文案；`broken` 出真红 ✕ | `PackGalleryView.swift:116-185` |
| T5 | **P1** | 包卡片 | `CC0` 与「缺 N 个」拆到**两个槽位**（今天 `statusLine` 的 `switch` 让残包丢 CC0 标） | `PackGalleryView.swift:141-185` |
| T6 | **P1** | 内置包 | `factoryPacksDirectory`（§2.3）；**删死函数 `isBuiltinOnlyPackID`**；`.overwritesBuiltin` → `.builtinReadOnly` + 新文案；`forkPack`（§2.2，**temp-dir + rename**，**必须改写 manifest 的 `id`**） | `AudioImportEnvironment.swift`, `AudioImport.swift`, `DropZoneState.swift`, `ClaudioGUIApp.swift`, 新 `PackFork.swift` |
| **T13** | **P1** | CC0 诚实 | `factoryIntegrity(packID:)`（§2.4）：manifest 字节 + 声明文件 size 与 bundle 比对。不一致 → 卡片显示 **`⚠ 已修改`** 而不是 `CC0` | `PackGallery.swift` |
| **T14** | **P1** | 导入 | **目标文件名冲突 → 生成唯一名，绝不覆盖**（§2.2b）。今天的覆盖行为会**静默改掉引用同名文件的其他事件的声音** | `AudioImport.swift:216-231` |
| T7 | **P1** | 画廊 | 「声音包 ⋯ 管理…」标题行。<br>⚠️ **`管理…` 必须是焦点目标 `.manageSounds`，排在 `.disconnect` 之前** —— 否则空面板首焦点落在卸载键上（§2.5 第 5 条）。且**不得**做成全宽 ghost（会与「断开连接」撞脸） | `PanelView.swift:601-603`, `PanelFocusOrder.swift` |
| T10 | **P1** | 对比度 | `ContrastSuite` 补 4 条断言：覆盖轨 `present`/`missing` × 亮/暗 vs `surface-2`（值见 DESIGN.md） | `ContrastSuite.swift` |
| T8 | P2 | 管理窗口 | 新 `SoundPacksWindow`。规范见 DESIGN.md「Sound Packs Window」。<br>⚠️ **时序/状态同步必须设计**：谁持 `NSWindow`、`管理…` 怎么开、窗口写完怎么刷 popover、popover 切包怎么刷窗口 | 新 target |
| T9 | P2 | a11y | 窗口的焦点序 / Dynamic Type / VoiceOver。**`PanelFocusTarget` / `PanelLayoutAdaptation` / `PanelAnnouncement` 全是面板专用，套不上** | 新文件 |
| T11 | P2 | 孤儿 | 包内音频枚举 + 「未被任何事件引用」判定；管理窗口列出 + 分配/删除。**事件行下拉的「复用包内已有音频」也在这一批**（阶段 1 刻意不做 —— 见下） | `PackGallery.swift` |
| T12 | P2 | 存量 | `restoreFactoryPack`（§2.2）—— **不是**复用 `copyBundledPacks`，只复用它的 staging+rename 机械部分 | 新 `PackRestore.swift` |
| T15 | P3 | helper | `doctor` 对 `events: {}` 的空包措辞（今天报 `.complete`，与画廊的 `0/4` 读起来矛盾）。**语义不改**（§2.1b），只改措辞 | `Doctor.swift` |

### 分阶段（Codex 建议「阶段 1 过重」—— 部分采纳）

**阶段 1 = T0–T7, T10, T13, T14**（把面板修活 + 让 CC0 不说谎）。
**阶段 2 = T8, T9, T11, T12**（管理窗口 + 孤儿 + 恢复出厂）。

**采纳 Codex 的一半**：事件行下拉在**阶段 1 只有 `选文件…/清除/访达`**，
**没有**「包内已有音频列表」。理由是它逼出了一条**隐藏依赖**：
那个列表需要「包内音频枚举 + 未被引用判定」= **T11 的全部数据**，而 T11 在阶段 2。
砍掉它，阶段 1 **一次 readdir 都不需要**（性能发现 P1 随之消失），
而 ①② 两条致命 bug 照样全修。

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
- [ ] **一个被改脏的内置包，卡片显示 `⚠ 已修改`，不是 `CC0`**（T13）。
      **构造方式**：直接往 fixture 的 `minimal-chime/stop.mp3` 写几个字节 → `factoryIntegrity` 必须失败。
      ⚠️ **这条替换了计划第一版那条会自我背书的验收**（「原包仍有 CC0 标」——
      它假设了原包是干净的，而那正是不能假设的东西）。
- [ ] 「恢复出厂」之后，`factoryIntegrity` 重新通过，卡片回到 `CC0`；
      **且用户自己加进去的文件被搬走而不是删掉**，并有明确告知。

### 状态机 / 语义

- [ ] `清除绑定` → 行显「未配置」（`unmapped`），**不是**「文件丢失」（`broken`）；
      `doctor` **不**把它报成缺陷；**磁盘上的文件还在**。
- [ ] **「四个事件全清空」的三方回答同时钉死**（§2.1b，已知分歧、被理解过）：
      `doctor` → `.complete`；`play` → 四个全静默；画廊卡片 → `partial(0/4)`「缺 4 个」。
      ⚠️ **三条必须写在同一个测试里** —— 否则下一个人会觉得是 bug，去「修好」一个，破坏另外两个。
- [ ] 一个 `CC0-1.0` 的**残包**（缺 1 个事件），卡片上 **`CC0` 标与「⚠ 缺 1 个」同时可见**。
      （今天残包会丢掉 CC0 标）
- [ ] **导入同名文件不覆盖**（T14）：包里已有 `a.mp3` 且被「中断了」引用 →
      给「干完了」导入另一个也叫 `a.mp3` 的文件 → 生成 `a-2.mp3`，
      **「中断了」的声音一个字节都没变**。

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
      └── [GAP] 四个全清空 → doctor .complete / play 全静默 / 卡片 0/4  ← 三方同一测试

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
      ├── [GAP] 干净的内置包 → 通过 → 卡片显示 CC0
      ├── [GAP] stop.mp3 被改了几个字节 → 失败 → 卡片显示 ⚠ 已修改   ← ③ 的真修法
      ├── [GAP] manifest 被改 → 失败
      └── [GAP] 非内置包 → 不参与判定（不显示 ⚠）

[+] AudioImport.swift
  └── importAudioFile()                   【改 · T14】
      └── [GAP] 目标名冲突 → 生成 a-2.mp3，**引用 a.mp3 的其他事件一个字节没变**

[+] PanelFocusOrder.swift / CoverageState.swift   【改 · §2.5】
  ├── [REWRITE] CoverageStateSuite 的 8 条（previewClaimsActionFocus 作废 / eventActionOperable 语义变）
  ├── [GAP] 每行三个焦点槽：eventSound → eventAction → eventMute
  ├── [GAP] unmapped 行首焦点落在 eventSound（那个能修好它的控件）
  └── [GAP] 空面板（零包）首焦点 ≠ .disconnect                ← 防「开面板即卸载」

[+] SourceScannerSuite.swift              【新绊线 · T3】
  └── [GAP] manifest 写函数带 async/Task/DispatchQueue → 红

用户流
  ├── [GAP] [→真机] 换掉「干完了」的声音（不先弄坏包）—— ①② 的端到端
  ├── [GAP] [→真机] 导入后自动试听仍然响 —— **一条会被顺手删掉的现有行为**
  ├── [GAP] [→真机] 试图改内置包 → 引导「复制为我的包」→ 副本可改
  └── [GAP] [→真机] .tint(clay) 在 Menu 上生效（正向对照先自证）

COVERAGE: 现有 0/31 新路径有测试  |  回归基线：ManifestBindingSuite 1108 行必须仍全绿
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
| T4 + T5 + T10（卡片 + 对比度） | `ClaudioGUI/PackGalleryView`, `Tests/` | — |
| T1 + T2 + T7（面板 + 焦点） | `ClaudioGUI/`, `ClaudioGUICore/PanelFocusOrder` | T0, T3 |

```
Lane A: T3 → T6+T13+T14        （共用 mutateManifestJSON，顺序）
Lane B: T4 + T5 + T10          （只碰 PackGalleryView + ContrastSuite，独立）
Lane C: T0 → T1 + T2 + T7      （面板 + 焦点，依赖 T0 与 T3 的原语）

并行：A 与 B 可同时开工。C 等 T3 落地。
⚠️ 冲突旗标：Lane A 与 Lane C 都碰 `ClaudioGUICore/` —— A 改 ManifestBinding，
   C 改 PanelFocusOrder/CoverageState，文件不重叠，但同一 target，合并时留意。
```

## 5. 明确不做

- **不引入 `~/.claudio/library/`**（第二个查找根）。ENGINEERING.md 早已拒绝那个形状；
  `helper` 的 `play` / `doctor` 解析链**零改动**是本方案的核心资产。
  代价：同一个音频想给两个包用 → 拷两份。接受。
- **不做音频编辑 / 裁剪 / 音量归一。** 那是另一个产品。
- **不在管理窗口里重做面板。** 面板管「不回头也知道状态」，窗口管「坐下来把它配好」。
  两个不同的使用时刻，不互相抄。
- **卡片上不加试听 ▶。** 换包本已是一次点击且可逆，事件行是更好的试听面。
  为省一次点击要付：每卡两个控件 → 撞破 `PanelFocusTarget.packCard(id:)` 的单焦点槽契约
  + 序列播放器 + 中断语义 + reduce-motion 门控。（评审中提出、当场砍掉，理由存档于 DESIGN.md）
- **波形「包指纹」不做。** 被 `/codex` 跨模型评审否决，判词成立：17pt 段 = 纹理不是信息，
  且缺失信号压在同一条不可读纹理上。（存档于 DESIGN.md，不要再提）
- **manifest.json 不加锁。** 保住「全同步 + 全在 `@MainActor`」这条**结构性**不变式（§2.1）。
  加锁会把它压进 bind/clear 的热路径 —— 拿一条真不变式换一次 UI 微卡顿，不划算。
  守卫是 T3 的**源码绊线**，不是一句注释。
- **阶段 1 的文件名下拉不列「包内已有音频」。** 那需要孤儿计算（T11），随管理窗口进阶段 2。
  砍掉它，阶段 1 **一次 readdir 都不需要**，而 ①② 照样全修。
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
| Codex Review | `/codex review` | Independent 2nd opinion | 1 | issues_found | 13 findings, 10 folded / 2 partial / 1 rejected |
| Eng Review | `/plan-eng-review` | Architecture & tests (required) | 1 | issues_open | 19 issues, 1 critical gap |
| Design Review | `/plan-design-review` | UI/UX gaps | 1 | issues_open | score: 3/10 → 9/10, 6 decisions |
| DX Review | `/plan-devex-review` | Developer experience gaps | 0 | — | — |

- **CODEX:** 逮到 9 条本轮评审漏掉的问题，其中 **2 条推翻了本计划自己的事实断言**：`bindEventToManifest` **零锁**（`JSONSafeWrite` 只是编码门面），`Setup.copyBundledPacks` **不能直接复用**（它 skip 已可用的包）。两条均已实证并写进 §2 的更正框。另外 7 条（顶层原语 / fork 漏写 `id` / `factoryPacksDirectory` 需要源路径 / 空包三方语义 / CC0 未真正修复 / T2 隐含依赖 T11 / 同名覆盖的跨事件副作用）全部折进计划。**驳回 1 条**：Codex 主张 T6（内置包只读）可延期 —— 但 T2 会把 CC0 谎言的入口从难用变好用，两者必须同批。
- **CROSS-MODEL:** 两个模型**独立收敛**到同一条最重的结论：**删掉假 drop-zone 优先于一切**。分歧在阶段切分（Codex 认为阶段 1 过重），**部分采纳**：砍掉下拉的「包内音频列表」（消除 T11 隐藏依赖 + 性能问题），但保留 T6/T13。
- **VERDICT:** DESIGN + ENG CLEARED — 计划可实施。1 个 critical gap 已知且已有守卫（T3 源码绊线）。

**UNRESOLVED DECISIONS:**
- 无 —— 本轮 19 条发现全部已折进计划并拍板（auto-select 授权）。唯一的 critical gap（manifest 并发不变式无运行时防护）是**已知且被接受**的结构性约束，守卫为 T3 的源码绊线，不是未决项。
