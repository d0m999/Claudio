# TODOS

> **台账清理（2026-08-22，基于当前工作树）**
>
> - 已删除标题带 `✅`、明确标为「已解决 / 已被替代 / 设计否决」以及 `Completed` 下的条目。
> - 未标记且没有明确关闭说明的条目继续视为开放项。
> - 「源码 / harness 已通过」不等于 native SwiftUI、VoiceOver、真实 release 下载路径或正式验收；人工验收项继续保留。
> - 本文件仅保留待执行项；人工和外部发布验收仍是独立状态。

## Ship / CI

### `loadPanelConfig` 每次调用把 config.json 独立读三遍 —— 文档写的「一次读 + 一次目录 stat」和实现对不上

**What:** D23 把面板的 config 判定拆成「写」「读」两条正交轴（`probeConfigRewritable` + `packSelection`），
再加上最后 `loadClaudioConfig` 解码一次 —— `loadPanelConfig` 在 happy path 上因此对同一个 `configFile` 各自
独立做了三次 `fileExists`/`open`/`read`/解析，而不是文档里 `PanelRefreshRoute.swift` 对 `.configOnly` 成本的
描述（「代价 = 一次文件读 + 一次目录 stat」）。三次读之间没有共享同一个字节缓冲区，也没有加锁（读端本来就
不占锁，这是既有约定），所以理论上一次外部并发写可能落在三次读之间，让三个判定基于不完全一致的磁盘内容
（红队复核：影响自限——下一次真正写盘会重新校验并诚实拒绝，不丢数据，只是这一次面板渲染可能对不上磁盘
当下状态）。

**Why:** `/ship` pre-landing review 的 performance specialist + red-team 两条独立路径都命中了同一处
（`gui/Sources/ClaudioGUICore/PanelConfig.swift:72`），confidence 都不低。不是这条分支要解决的问题（这条
分支的目标是「切包 + 路由」的行为正确性，已经用五轮红队 + 两次独立对抗验证钉死了），但发现的时候文档
与实现已经对不上号，值得单独一轮修，而不是为了赶这次 ship 临时改三个文件的函数签名。

**Context:** 2026-07-14 `/ship` pre-landing review（performance + red-team 双命中，parent 已用 `git diff`
逐行核实为真）。修法：给 `probeConfigRewritable`/`packSelection`/`loadClaudioConfig` 各配一个接受
预读 `Data` 的内部重载，`loadPanelConfig` 只在最外层读一次文件、把字节传给三个判定复用。

**Effort:** S
**Priority:** P2（性能影响可忽略，正确性影响自限且无数据丢失；但文档与实现的说法已经不一致）
**Depends on:** None

### 剩余的行为级缺口：`play` 与设置写之间的「互不阻塞」，仍然只有人工读码背书

**What:** 现有测试只证明「**每个写者拿的是递给它的那把锁**」（注入锁 + 持锁争用，够了）。它证明不了的是另一半：
**「持有 play.lock 时点静音仍然成功」** —— 也就是分锁要兑现的那个行为本身。

**Why:** 这一半要有牙，就必须锚定**生产默认值**（真实的 `~/.claudio/play.lock` 与 `~/.claudio/config.lock`）——
用两个临时路径去测它，断言从写下第一天起就恒真（两个不相干的路径本来就互不阻塞），正是 D30 判定「测不到东西」
的那类假绿。**这一条的前置条件是真的，上一条的不是**：区别在于前者断的是「两把锁之间的关系」（需要真锁），
后者断的是「这条代码路径用了哪把锁」（注入锁就够）。

**Context:** `ClaudioPaths.root` 锚在 `FileManager.default.homeDirectoryForCurrentUser`，**没有任何可覆盖的注入口**，
而 Darwin 上 `$HOME` 会被忽略 —— 这类测试会真实地碰到当前用户的 `~/.claudio/`。所以前置条件是**先给
`ClaudioPaths.root` 一个可覆盖锚点**，那是一次独立的基础设施改动。

今天仍靠人工读码确认（`play` 读 config 在锁外；config 写是原子 rename；`play` 从不读 settings.json），
**回归时没有灯会灭**。

**Effort:** M
**Priority:** P2
**Depends on:** `ClaudioPaths.root` 需要先获得可覆盖锚点（独立 PR，不要混进阶段 B 主音量滑块）

### 全仓还有十几处「一个字节都不写」，背书它们的仍然只是**字节比较** —— 而字节比较看不见「写了又擦回去」

**What:** `/codex review ee026db` 的 P2 指出：`fileBytes(after) == fileBytes(before)` 只证明**终态相同**，
而写着这句话的失败消息声称的是「**一个字节都没被碰过**」。一个「写完再回滚」的实现（写下去 → 撞上锁 →
把文件删/改回去）能让前后逐字相同，字节比较**全程绿**。

这一条已在 **settings.json 的四条持锁路径**上治好了：`FileWriteWatch`（`gui/Tests/…/TestSupport.swift`）
观测的是**事件**而不是状态差 —— 目录级 kqueue（`NOTE_WRITE|NOTE_DELETE|NOTE_RENAME`）逮住创建 / 原子替换 /
删除，`stat(2)` 的 **ctime** 逮住「非原子的原地重写」（ctime 是 userspace 唯一伪造不了的字段：`utimensat`
能把 mtime 按回过去，那一次调用自己却会把 ctime 顶到「现在」）。

**没治的是同一族的其余声称**，它们今天全靠字节比较：
`helper/Tests/ClaudioCoreTests/ConfigMutationSuite.swift`（`:126`、`:754`「fail closed 的含义是一个字节都不写」，
`:686` 只读探针）、`SetupSuite.swift`（`:564`、`:791`、`:1065` 失败路径必须逐字保住用户的 config / 文件）、
`gui/Tests/ClaudioGUICoreTests/ManifestBindingSuite.swift:302`（「一个字节都不写」）。

**Why:** 严重性**低于** settings.json 那一族，而且理由是具体的、不是感觉：settings.json 有**不遵守
claudio 任何锁的并发读者**（Claude Code 每个事件都读它），所以那里的「窗口期」真的会被别人看见；上面这些
路径上的 config.json / manifest 的并发读者是 claudio 自己，且都走原子 rename。**但这只是把风险降级，没有
消灭它**：一次「写了又回滚」的窗口里，一个并发的 `claudio play` 照样可能读到半途的 config.json。

真正的理由是：**这些断言的措辞，仍然比它们的覆盖范围大** —— 而这个仓库连着十一次栽在同一件事上。

**修复方式:** `FileWriteWatch` 是现成的，把它按「按包复制而非跨包共享」的约定抄一份进
`helper/Tests/ClaudioCoreTests/TestSupport.swift` 即可。⚠️ 两条硬约束，抄之前先读它文档里「它不兜什么」那节：
① 目录那一半会因**同目录里的其它写者**假阳（`~/.claudio/` 在接管期间一直在被写：二进制、声音包、两把锁文件），
所以它只能用在被观测文件是该目录唯一写者的时刻；② **每加一个用它的断言，都必须同时有一条正向对照**证明观测器
在那条路径上真的会响 —— 一个观测不到写的观测器，会把每一条「没被碰过」变成恒真，那正是它要杀的病升了一层。

**Effort:** M（每条断言都要配一次定向变异验证，不能批量替换了事）
**Priority:** P2
**Depends on:** None（工具已就绪）

### `FileWriteWatch` 自己有两处 fail-open —— 一个观测不到写的观测器，会把每一条「没被碰过」变回恒真

**What:** `/codex review 96ed71c` 的两条 P2，都打在 `FileWriteWatch`（`gui/Tests/…/TestSupport.swift`）身上 ——
即上一条 TODO 指望「抄一份进 helper」的那个工具。**抄之前必须先修，否则是把两个洞抄成四个。**

① **`kevent` 轮询失败被折叠成「没有目录事件」**：`sawDirectoryEvent = kevent(queue, nil, 0, &event, 1, &immediately) > 0`
—— 返回 `-1`（`EINTR`、fd 被意外关闭/复用）和返回 `0`（真的没事件）走进**同一个分支**。`isArmed` 只兜得住
**注册时**失败（7 处调用点都断言了），三条正向对照只兜得住**系统性**失明；谁都兜不住持锁 suite 真实跑的那一次
**观测时**的 syscall 错误。而对 `nil → 写入 → 删除 → nil` 这类**正是它存在理由**的回滚窗口，身份快照也相等 ——
于是断言静默变绿。零超时的 `kevent` 撞 `EINTR` 概率极低（不阻塞就没有可中断的睡眠），所以现实风险小；但这个
文件通篇的论点就是「观测器必须 fail closed」，而它唯一能失败的 syscall 恰恰 fail open。

② **dangling symlink 下两半同时瞎**：`settings.json` 是一条指向 dotfiles 的符号链接、而**目标不存在**时，
`identityBefore = FileIdentity(of: file)` 走 `stat` → `nil`；穿链接的写落在 `dotfiles/`，未解析的 `dot-claude/`
目录项一个都没动 → 目录 kqueue 全程安静。写 → 回滚删掉目标 → 终态又是 `nil`。**两半同时看不见。**
而这个形状不是臆想：`SettingsInstallerSuite.swift:1277` 明确把「dangling settings.json symlink = 普通全新
安装路径」钉成了**生产支持的行为**。新增的「写观测器③」用的是**目标已存在**的链接 —— 它钉的是 `stat` 的跟随
语义，钉不到「before 就是 `nil`」这一支。

**Why:** 今天**没有**任何断言因此假绿（四条持锁 suite 的 fixture 都是正规文件），所以不阻断 `96ed71c`。但工具
文档里那节「**它不兜什么**」**没写 ②** —— 措辞又一次比覆盖范围大，而这一次是在专门用来杀这个病的工具自己的
文档里。下一个人照着那节的承诺去用它，洞就跟着他走。

**可能的修法:** ① 把 poll 结果**三分**为 event / no-event / error：`> 0` → 有事件；`== 0` → 没事件；`< 0` →
`expect(false, ...)` 当场红（fail closed）。三行。② 在「它不兜什么」里写清 dangling symlink 这一支，并补一条
正向对照（dangling link + 穿链接写 + 回滚 → 必须被看见），修法大概是身份快照那一半改成「`stat` 目标 + `lstat`
链接本身」两个快照都拍。

**Effort:** ① S（三行 + 一次定向变异）/ ② M（新对照 + 两轮台账）
**Priority:** P2（不阻断本分支；**但阻断「把 FileWriteWatch 抄进 helper」那条 TODO** —— 别把洞抄一遍）
**Depends on:** None

### 一次性备份写在乐观闸门**之前** —— 一次 `.concurrentModification` 中止会留下一份 install 从没写过的永久备份

**What:** `installClaudioHooksLocked` 的顺序是 `backupOriginalIfNeeded`（`:317`）→ `atomicWrite`（`:322`，
里面才做 `expectedCurrentData` 的乐观并发重读）。于是：外部写者（Claude Code 自己 / 用户的编辑器）在读与写之间
改了 `settings.json` → `atomicWrite` 正确地中止并返回 `.concurrentModification`、**一个字节都没写** —— 而
`.claudio.bak` **已经落盘了**，且按「一次性备份」的纪律**永不刷新**。

于是 `SettingsInstaller` 类头那条不变式是**假的**：「the pre-claudio original is copied to
`settings.json.claudio.bak` **the first time `install` actually writes**」—— 它可以在 install **从没写过**的
情况下就存在。

**Why:** 行为影响比「备份非原子」那条小得多（已修：`options: .atomic`）：备份的**内容**仍然是 claudio 真实
读到的那份原件（`loadRoot` 的 `rawData`，不是重读的），所以它不是坏数据，只是**时机**不对 —— 它记录的是一次
被中止的 install 所看到的世界。真正要紧的是那句类头注释**在撒谎**，而这个仓库的规矩是：假注释就是 bug。

**可能的修法:** 把乐观闸门从 `atomicWrite` 里拆出来、提到 `backupOriginalIfNeeded` **之前**跑；或者退一步，
只把类头 `:26-27` 那条不变式改成实话（「the first time install **attempts** a write」）。前者是真修，后者是
止损 —— 但**别只做后者然后当成修好了**。

**Effort:** S（改注释）/ M（拆闸门）
**Priority:** P3
**Depends on:** None

### `updateConfigJSON` 的残余 TOCTOU：读完之后被外部删掉的 config，会被 `.atomic` 写**复活**（且报 `.success`）

**What:** `ConfigMutation.swift` 仍是 `fileExists` → `readConfigFileBounded` → `mutate` → `encode` → `data.write(.atomic)`。一个**不拿 `config.lock`** 的进程（用户手动 `rm`、清理工具、同步冲突）如果在**读成功之后、rename 之前**删掉 `config.json`，`.atomic` 的 temp+rename 会照常把文件**重新创建**出来 —— 内容是刚才读到的那份旧 config（加上本次的改动），并向调用方报 `.success`。用户以为自己删掉了 config，它却自己回来了。

**Why（先把措辞更正了）：** `573336d` 的提交信息写的是「判定与新建落在**同一次** `fileExists` 上，**那个窗口跟着一起没了**」。**这句话比它的覆盖范围大**（`/codex review 573336d` [P2] 独立指出，本人复核确认）。真正没掉的是**空串新建**那个窗口：调用方先探一次 `fileExists`、`updateConfigJSON` 内部再探第二次，两次之间的外部删除会让空串照常落盘。那一刀确实砍掉了（毒源在**类型层面**消失，`.failClosed` 的调用方递不出能落盘的 pack id）—— 但「TOCTOU 窗口关闭了」这个**广义**说法不成立：读→rename 之间那个窗口还在，它只是不再产毒了（复活的是旧内容，不是空串）。

危害比原来的小一个量级（没有毒源，只是一次不该发生的复活），但**措辞必须与覆盖范围对齐** —— 这个仓库栽在「headline 比覆盖范围大」上已经不止一次（见本文档「⚠️ 本条首版写的是…那是**假的**」几处）。

**Context:** 2026-07-13 `/codex review 573336d`。真修 = 与「GUI 写/读路径的同用户 symlink TOCTOU」那条的 config 侧加固**同一处**：写前解析 symlink + 乐观并发重读（读到的字节 vs 写之前重读的字节，不一致就 `.concurrentModification` 中止 —— `SettingsInstaller.swift:619` 对 `settings.json` 已经是这个形状，config 侧照抄即可）。三条并作一处改。

**Effort:** M
**Priority:** P3（需要一个不拿 config.lock 的外部写者，恰好落进读→rename 那几微秒；且后果是「旧 config 复活」，不是数据损坏）
**Depends on:** None

### T3 判定腿之二（并发黑名单）仍是**白名单探针** —— 跨文件调度这条逃逸是可编译的真代码

> **更新（2026-07-20 · `/codex review 48cbc07`）：下面的 ① 已修，② 未修，本条现在只讲 ②。**
> ① 的修法就是本条当年写下的那一条（「别继续扩正则打地鼠，反过来把『认不出』变成红」）：新增
> `allFuncDeclarationNames` 当标尺、`fileLocalFuncNames` 当白名单第二格，
> `unrecognizedFuncDeclarations` 按**计数**做差 —— `func` 声明总数 ≠ 两台识别器认出来的数之和，
> 差额就是漏网的，逐个变红。实测：`internal`（不写修饰符）/ `package` / `open` /
> `public extension` 里省略修饰符的成员，四种形态各一条 fixture 全部真的开火；真仓库
> `ManifestBinding.swift` 那个 `private func resolveUserPackDirectory` 不假红（白名单第二格接住）。
> 变异台账 5/5 被逮，且按断言原文归因确认红是这三条新正控打出来的（`✗ 3 of 2174`），不是连坐。
> **注意这只关掉了「修饰符形态」这一根轴。** 判定腿仍然只看**单个文件**，② 原封不动。

**What:** `SourceScannerSuite.auditManifestConcurrencyFence` 的**枚举**那一层是围栏（认不出 ⇒ 红：
symlink、读不到、属性判不出、子树枚举出错，全部 fail-closed，且各有自证），**@MainActor 腿**自
2026-07-20 起在「声明形态」这根轴上也是围栏了（见上面那条更新）。但**并发腿**仍不是：

1. ~~**@MainActor 腿只查「正则认得出的 `public func`」。**~~ ✅ 2026-07-20 已修（见上）。

2. **并发腿只扫「包含原语名的那一个文件」。** 纳入判据是单文件文本 `contains("mutateManifestJSON")`，
   黑名单随后只扫那一个文件。于是把 `Task` 挪进**另一个文件**就整条绕开：

   ```swift
   // BackgroundExecutor.swift —— 不含 mutateManifestJSON，压根不被纳入
   func launchManifestWork(_ op: @escaping @Sendable () async -> Void) { _ = Task.detached(operation: op) }
   ```
   ```swift
   // ManifestBinding.swift —— 没有 async / Task / DispatchQueue 任何一个黑名单 token
   @MainActor public func deferredWriter(at dir: URL) -> Result<Void, ManifestBindError> {
       launchManifestWork { _ = await mutateManifestJSON(at: dir) { _ in } }
       return .success(())
   }
   ```
   两个文件都编译进 app，真正的写被 detached task 调度。`await` **不在**黑名单里，所以两个文件都清白。

**Why:** `manifest.json` 今天零锁，并发安全**全靠**「全同步 + 全在 @MainActor」这一条不变式，而这条
源码绊线是它唯一的自动守卫。②「把耗时的写挪到后台去，别卡主线程」是重构时最自然的念头之一，
它会让读-改-写交错、丢更新，**且零运行时报错**。

**要害不在漏，在措辞。** 文件里 `bannedConcurrencyTokens` 头上那段 doc comment **早就诚实写着**
「两条腿都是探针，各自覆盖一组已知形态，合起来仍有缺口」。可 suite 名、commit headline、以及这几轮
review 的结论全都叫它「**内容围栏**」，而围栏的判据是「认不出 ⇒ 红」。**措辞比覆盖范围大** —— memory 里
`fence-polarity-and-self-recurrence` 记着的那条，这是第八次应验，而且照例复发在「自称已经把探针升成
围栏」的那一刀上。① 修掉之后这句话**依然成立**：@MainActor 腿在「声明形态」这根轴上是围栏了，
并发腿在**任何**轴上都还不是。别把「① 已修」读成「围栏补齐了」。

**Context:** 2026-07-20 `/codex review 36fce57` 的 P1 之二，`/codex review 48cbc07` 复核后仍在。
同一轮的 P1 之一（@MainActor 腿）已修，见上面那条更新。

**可能的修法**（未定）：纳入判据从「文件含原语名」升成**调用图**（谁调了原语、谁调了调原语的人），
或者退一步——把黑名单扫描范围从「含原语的文件」放宽到**整个 target**，代价是要先量一次假红。
`await` 无论如何该进黑名单（它今天不在，是个独立的小漏），但**单加 `await` 是创可贴**：它会让任何
含 `await` 的文件假红，而假红的守卫会被下一个人删掉。

**Effort:** M
**Priority:** P2
**Depends on:** None

### T3 修饰符白名单放行 `private`，靠的是一条**被实测证伪**的前提

**What:** `unrecognizedFuncDeclarations` 的白名单第二格放行 `private` / `fileprivate`。放行的理由
原本写的是「私有函数出不了这个文件，而这个文件里每一个出得去的声明都已被『导出写函数都得
@MainActor』钉住 ⇒ 私有函数只可能从已隔离的代码里被调到」。**那句推理是假的**，红队实测打穿：

```swift
public let escapeHatch: () -> Void = { privateFlush() }   // 公开闭包属性，把私有函数带出文件
private func privateFlush() { mutateManifestJSON() }      // 白名单放行，零 finding
```

闭包属性不是 `func`，不进任何一台识别器；它捕获的私有函数于是从**任意线程**都可达。实测该
fixture 产出 **0** 条 finding。

**Why:** 这一格**不能简单删掉** —— 真仓库 `ManifestBinding.swift` 里的
`private func resolveUserPackDirectory` 会当场假红，而本文件开头记着的病就是「假红的守卫会被
下一个人删掉」。所以现状是一个**权衡**，不是一条证明。已经把 doc comment 里那句假推理改掉了，
但缺口本身还在。

**Context:** 2026-07-20 `/codex review 48cbc07` 之后那轮红队（9 agent × 三视角）实测。
注意这条与「判定腿只数 `func`」是同一个根因的两个面：都是「非 `func` 的声明形态不进识别器」。

**可能的修法**（未定）：与「只数 `func`」那条一起修 —— 一旦识别器能看见闭包属性 / 计算属性这类
声明，`private` 那格就可以从「无条件放行」收紧成「放行且文件内没有把它导出去的闭包属性」。
单独修这一条不划算。

**Effort:** M（与「只数 `func`」合并修）
**Priority:** P2
**Depends on:** 「T3 判定腿只数 `func`」

### T3 判定腿只数 `func` —— 计算属性 / subscript / init 里的写入点，四条腿一条都看不见

**What:** 2026-07-20 把 @MainActor 腿在「`func` 声明的修饰符形态」这根轴上升成了围栏（认不出 ⇒ 红）。
但那台标尺数的是 **`func` 声明**，于是**一切不是 `func` 的写入点全部隐身**。红队实测（临时探针，
跑完即删）：

```swift
// 一个被纳入的文件里：
@MainActor public func probeClean() { _ = 1 }
public var probeTrigger: Int { mutateManifestJSON(); return 1 }   // ← 计算属性 getter
```

这个文件产出的 finding 数是 **0**。逐条走一遍：`unmodeledConstructs` 空；并发 token 空；
`exported.isEmpty` 为假（`probeClean` 顶着）；`func` 声明总数 1 = 识别数 1，没有差额；
`missingMainActorIsolation` 只遍历枚举得到的名字。**四条腿一条都没响**，而那句读-改-写就在
`probeTrigger` 的 getter 里，任意后台线程读一次这个属性就同步触发它。

同一根轴上的同一个洞还有：`subscript`、`init` / `deinit`、`willSet` / `didSet`、属性的
`_read` / `_modify` 协程访问器。全部隐身。

**Why:** 「把写入点从函数挪进计算属性」不是刁钻构造 —— 它就是「让调用方写起来顺手一点」这个念头
的自然结果。而这条洞比修饰符那条更隐蔽：修饰符那条至少还是个 `func`，读代码的人扫一眼能认出「这是
个写者」；计算属性长得像一个**读**。

**要害仍然是措辞。** 本轮的 headline 若写成「围栏 fail-closed 补齐」，就是第九次应验
`fence-polarity-and-self-recurrence` 那条 memory —— 补齐的是**一根**轴，不是「补齐」。
`unrecognizedFuncDeclarations` 的 doc comment 里已经把这条逐字写下来了，这里登记的是同一件事。

**Context:** 2026-07-20 修 `/codex review 48cbc07` P1 之一时自查发现（Codex 没提这一条，是本轮
红队自己打自己那一刀打出来的）。

**可能的修法**（未定）：判据的**量纲要换** —— 从「数 `func` 声明」变成「找出所有能含语句的括号块，
每一个都得落在某个已知隔离的声明里」。那是重设计不是补一刀，而且假红面会大得多（每个计算属性都
要标注或豁免），需要先在真仓库上量一次代价。退一步的便宜档：把纳入判据从「文件含原语名」升级后
（见上一条 ②），顺带对**含原语的那几行**做一次「它落在哪个声明里」的定位，认不出归属 ⇒ 红。

**Effort:** L
**Priority:** P2
**Depends on:** None

### T3 围栏的自证闭不上 `root` 这根轴 —— 一句按扫描根判真假的谓词能让生产静默失效而自证全绿

**What:** 围栏的两条自证 suite（消费边有牙、内容判定有牙）都必须把脏 fixture 写进一棵**临时树**，
而生产路径恒定喂**真仓库根**。于是任何「在临时根下为真、在生产根下为假」的谓词都能寄生：

```swift
// enforceManifestConcurrencyFence 里，消费循环加一个 where：
for finding in audit.findings where !root.path.hasPrefix("/Users/d0m999/Desktop/Claudio") { … }
```

自证喂的是 `/var/folders/…/T/…` ⇒ 照样全红；生产喂的是仓库根 ⇒ **一条 finding 都不消费**。
`git diff` 只显示函数体里多了个 `where`，调用点一个字符没动，所以「消费边接线自证」那条钉哨兵区块
逐字全等的 suite 也不会响。

**Why:** 这是 `fence-polarity-and-self-recurrence` 那条 memory 记的「同一个函数 ≠ 同一个实参向量」
的**第四层**：前三层（同一个 helper ≠ 同一条边、同一条边 ≠ 连消费一起、同一个函数 ≠ 同一个实参
向量）都已经收窄过，`pathPrefix` 那根轴现在两侧逐字相同。`root` 是**剩下的最后一根**，而它结构性
地闭不上：自证必须造脏输入，生产必须扫真代码，两者不可能喂同一个 `root`。

**Context:** 2026-07-20 `/codex review 48cbc07` 的 P1 之三。代码里 `绊线（T3）围栏消费边自证有牙`
那条 suite 头上的注释**已经逐字承认了这一条**（「仍然诚实的限度：`root` 这根轴闭不上 …… 收窄了，
没清零」）—— 这里登记的是同一件事，不是新发现。登记的理由是：它写在一段散文里，而散文不会变红。

**可能的修法**（未定，且都不便宜）：
- 把生产根也变成一个**注入点**，让自证能喂一棵「真仓库的只读快照 + 一个脏文件」的合成树 —— 那样
  两侧的 `root` 形状同构，`hasPrefix` 这类谓词失去分辨力。代价是围栏要多一层间接，而**多一层间接
  就是多一个可改的接缝**（这正是 `15ce131` → `36fce57` → `48cbc07` 三轮反复踩的那个坑）。
- 或者接受它，转而在**别处**兜底：一条 CI 侧的「把一个已知脏写者塞进真仓库、断言 suite 真的红」的
  端到端冒烟。这条不依赖任何注入，但需要 CI 真的跑测试 —— 而 CI 今天一次测试都不跑（见本文件
  「CI 一次测试都不跑」那条），所以它**依赖那条先修**。

**Effort:** L
**Priority:** P3
**Depends on:** 「CI 一次测试都不跑」（若走第二条修法）

### T3 扫描器不建模**裸 regex 字面量** —— 它既不记账，又是唯一能把反引号贴到 `func` 左边的通道

**What:** `strippingComments` 建模 `#/…/#`，但**裸**的 `/…/`（Swift 5.7 regex 字面量）既不被建模、
也**不**记进 `unmodeledConstructs`（实测 `unmodeled=[]`）。后果有两面：

```swift
let probe = /`func mutate/       // swiftc -swift-version 6 -typecheck rc=0
```

- 它是**唯一**能让一个反引号紧贴 `func` 左边的合法通道，于是它成了「关键字计数与名字解析是不是
  同一份词素」的判别输入 —— 两台一旦漂移，它凑出的 ±1 会去**抵消**一个真实漏网声明的 ±1
  （实测：只给关键字那台加 lookbehind，一条现存的红当场变绿）。本轮靠 `funcKeywordLexeme`
  单源 + `LexemeSync.swift` fixture 把这条通道钉住了。
- 但**根因没修**：扫描器对裸 regex 字面量整体失明。今天真扫描根里零处（实测 `func ==` /
  `private extension` / `private import` / 反引号标识符**四类全为 0**），所以是潜伏项。

**Why:** 「认不出 ⇒ 记账」是这个扫描器其余部分一致遵守的极性，这里破了例 —— 而破例的地方恰好是
围栏两台计数器的**公共前提**。

**Context:** 2026-07-20 `/codex review abbf48e` 之后那轮红队。

**可能的修法：** 在 `strippingComments` 里把裸 `/…/` 记成 unmodeled。代价是要动 shared-scanner
区块（gui / helper 两包逐字节同步），且 `//` 注释与 `/regex/` 的消歧是真词法问题（除法也用 `/`）。
别顺手做。

**Effort:** M
**Priority:** P3

### T3 判定腿对 `func ==` 与 Unicode 函数名是**恒假红**，而诊断给的补救对 `==` 物理上做不到

**What:** `allFuncDeclarationNames` 只认 `[A-Za-z_]` 打头的名字，于是运算符声明
`public static func == (l: K, r: K) -> Bool` 与 `public func 播放()` 都解析不出名字，被「标尺自查」
那条腿判成「连名字都认不出来」⇒ 红。两者 swiftc rc=0，是合法真代码。

方向是**安全侧**（红而不是绿），而且今天真扫描根里 `func ==` 为 0，所以不阻断。但诊断给的补救是
「把那个声明改成普通标识符命名的 `public func` 并标 `@MainActor`」—— 对 `==` 这是**做不到**的：
`Equatable` 要求的就是那个名字。一条无法遵循的红，就是下一个人删腿的理由（本文件反复在治的
「假红的守卫会被删掉」）。

**Context:** 2026-07-20 `/codex review abbf48e` 之后那轮红队，实测两者各 `diff=1`。

**可能的修法：** 给标尺补一格「运算符声明 / 非 ASCII 标识符」的识别器（认得出 ⇒ 交给隔离检查，
而不是判成认不出）。注意它必须与 `funcKeywordLexeme` 共用词素，否则就是本文件刚修掉的那个漂移。

**Effort:** M
**Priority:** P3

### T3「认不出 ⇒ 红」对四类合法私有形状恒红 —— 这是**主动选择**的代价，不是没看见

**What:** 下面四类合法 Swift 今天一律变红（各有 fixture 钉着，见 `SourceScannerSuite` 的 ⑰）：

> ⚠️ 2026-07-20 更正：这句「各有 fixture 钉着」在 `ae494b1` 写下时**是假的** —— `enum` /
> `final class` / `actor` 三种当时一条 fixture 都没有，只有 `private struct` 有。`/codex review
> ae494b1` P2-2 打出来，同一提交补齐（⑰ 现为七行）。**这条 TODO 自己就是「措辞比覆盖范围大」
> 的又一次复发**：台账在替一份不存在的覆盖背书，而它正是用来记录覆盖边界的那份文件。

```swift
private extension Foo { func helper() { mutateManifestJSON() } }      // 及 fileprivate extension
private struct Batch  { func apply()  { mutateManifestJSON() } }      // 及 enum / final class / actor
@MainActor public func outer() { func inner() { mutateManifestJSON() } }   // 函数体内的局部 func
```

识别器是**词法**的，只看紧贴 `func` 前面那一段修饰符 run，跨不过外层的 `{`。

**Why 没把它们白名单化：** 提过一个方案（识别 `private extension` 块、把块内成员纳入白名单），
红队实测**否决**：那需要一台括号匹配器，而括号匹配会被一个裸 regex 字面量 `/^\s*\{/`（上一条：
不记 unmodeled、其自身括号配平）带偏而**过冲**，吞掉整块 `public extension` 里的非 `@MainActor`
写者 —— 放宽白名单却造出一条实测可达的 masking 路径，教条「放宽必须证明没有 masking 路径」
满足不了。且该方案只覆盖四类里的一类，达不到自己的立论。

所以本轮改为**保持红、把红修得可执行**：诊断逐字列出全部七种落点，并把补救从「标 `private` 收回
本文件」（对 private-extension 成员毫无意义 —— 它本来就是私有的）改成「把修饰符写在**成员自己
头上**」。

**⚠️ 顺带再破一次「私有一定安全」那条前提**（本文件 519 行那条已经记过一次）：
`@objc` 标注的 `private extension` 成员经 ObjC runtime（`perform(_:)` / target-action / `NSTimer`）
从**任意 run loop** 可达 —— 实测 swiftc rc=0。所以 `private` 那格白名单是**权衡**，不是证明。

**Context:** 2026-07-20 `/codex review abbf48e`（原报为 P2 假红）+ 之后那轮红队的否决。
今天真扫描根里这四类均为 0 处，是潜伏项。

**Effort:** L（要先给「括号嵌套」这根新读模型轴造正向对照 —— 现有 `unmodeledConstructs` 是**词法**
台账，守不住它）
**Priority:** P3
**Depends on:** 「T3 扫描器不建模裸 regex 字面量」

### T3 形状表与诊断串**未同源** —— 覆盖锁只挡得住「删行」，挡不住「诊断长出新形状」

**What:** `SourceScannerSuite` 里三张形状表（⑦⑧⑧b 四行 / ⑩ 两行 / ⑰ 七行）各自镜像一条生产诊断串
里**逐字列出**的形状清单。2026-07-20 给三张表都加了 `expectShapeTableCovers` 覆盖锁，堵住了红队
实测的那条变异（删任意一行 → 修前全绿、修后每向量各红一次，实测 6/2261）。

**仍然开着的是反向**：诊断串长出第五种形状而没人加行，`mustCover` 与表两处一起停在旧清单，照样
全绿。而这**正是 `ae494b1` 栽的那一跤的形状** —— 当时诊断写着四种私有形状，表里只有 `private
struct` 一行，是 `/codex review ae494b1` P2-2 打出来的，不是绊线响的。

**⚠️ 别把覆盖锁读成「已同源」**：`mustCover` 与表是**两处字面量**，一起砍掉仍能全绿。它把「悄悄删
一行」抬成了「必须动两个地方」，是**抬高门槛，不是证明**。锁自己的 doc comment 里写了这句，别在
别处把它复述成更强的说法。

**修法方向:** 把诊断句子由表**生成**（表是唯一真源），而不是两边各写一份散文。难点是那几条诊断是
精心写的中文散文带 markdown 强调，生成式改写会牺牲可读性；折中方案是给每行加一个 `diagnosticToken`
字段，断言它是真 finding 文本的子串（把表钉到生产措辞上），反向仍需解析诊断串里的反引号 token。

**Context:** 2026-07-20 `/codex review ae494b1` 之后那轮红队 confirmed 的唯一一条。同一轮还改掉了
`fenceProofVectors` 的 `count == 2`（改为成员锁）—— 理由见下一条。

**Effort:** M
**Priority:** P3
**Depends on:** 无

### T3 双向量自证收窄了 `pathPrefix` 那根轴，但**联合读取**那根还开着

**What:** 本轮把两条自证 suite 都做成了对 `("", fencePathPrefix)` 各跑一遍，并加了四条守卫
（常量形状 / 互异 / 生产值在清单里 / **执行**见证）与穿线见证。台账实测：
`where pathPrefix.isEmpty` 这类只读 `pathPrefix` 一个变量的寄生谓词，现在**当场红**（此前全绿）。

**仍然开着的**是「联合读取 `pathPrefix` **与** `subpath`」那一类。fixture 已从平铺迁进
`ClaudioGUICore/` 与 `ClaudioGUI/`（与生产树目录命名空间同形），所以
`where !display(relative).hasPrefix("gui/Sources/ClaudioGUICore")` 这条已经被逮住；但更窄的
`where !relative.contains("ManifestBinding")` 仍然逃得掉 —— **收窄了，没清零**。

**Why:** 与「闭不上 `root` 这根轴」同源：自证喂合成树、生产喂真仓库，只要谓词读得到「输入长什么
样」的任何一个侧面，就总有一条在两侧取值不同的谓词。

**Context:** 2026-07-20 `/codex review abbf48e` 的 P1（实测：加一行 `where pathPrefix.isEmpty`，
2179 条断言一条不红而围栏在真仓库上整条死掉）。这是「同一个函数 ≠ 同一个实参向量」的第十次复发，
且长在上一轮**为了修它而新加的那条腿**上。

**Effort:** L
**Priority:** P3
**Depends on:** 「T3 围栏的自证闭不上 `root` 这根轴」（同一根因，同一批修法）

### T3 fixture 的**承重形状**普遍只由散文守着 —— ⑯ 已修，另有 8 处同形

**What:** 「这条 fixture 的某个表面形状（顺序 / 相邻 / 有没有某个修饰符 / 文件名前导点 / 语句在块里的
位置）是它全部分辨力的来源，但只写在注释里」是一整类病，不是一个点。⑯ `PrivateImport.swift` 那条
2026-07-20 已修成可执行（重建旧 run、要求它认领的恰好是漏网写者）。**同一形状红队扫出另外 8 处，
逐条经独立验证坐实**（每条都给出了「一次读起来更顺的无害编辑」+「随后存活的变异」）：

| # | 站点 | 承重形状 | 无害编辑 → 存活的变异 |
|---|---|---|---|
| 1 | ③ `DecoyString.swift` | decoy 串**不带 `public`** 且名字与真函数逐字同名 | 串里补 `public`（更像真声明）／把串里的名字改成 `mutateManifestJSON` → **M12**（`missingMainActorIsolation` 读 `code` 而非 `codeWithoutStringLiterals`）存活。全仓只有这一条 fixture 杀得掉 M12 |
| 2 | ⑪ `CommentGlue.swift` | `public/* MARK */func` 块注释**两侧零空白** | 加空格「更可读」（同文件 1189 行那条块注释 fixture 就是带空格的）→ 剥完粘不出 `publicfunc` |
| 3 | ⑭ `GluedBacktick.swift` | `func` 与反引号之间**无空格** | 加一个空格 —— 诱因现成：⑩ `Backtick.swift` 用的正是带空格写法，一次「统一写法」就够 |
| 4 | ⑮ `BacktickIdent.swift` | 毒源 `` let `func` = 0 `` 还在 | 改名成 `` `funcName` ``（或直接删，它是没人用的 `let`）→ 纳入见证由**干净写者**单独顶着仍成立、否定断言变恒真 → `funcKeywordLexeme` 丢掉 `(?<!`)` lookbehind 存活 |
| 5 | ⑥ `.DottedWriter.swift` | 文件名的**前导点**；且它是全文件唯一一条没有存在性见证的裸负控 | 「统一 fixture 命名」去掉点 → 断言查的是 `contains(".DottedWriter.swift")`，把承重属性编进了搜索串本身，改名后静默恒真。`writeFixture` 用 `try?` 吞写失败，一行 `fileExists` 就能补 |
| 6 | ② `TwoWriters.swift` | 「只有**第二个**缺 @MainActor」这个顺序 | 两行对调「先列不合规的」→ `exported.prefix(1)` 变异在②上存活。**但 suite 级没有活洞**：④ `Overload.swift` 顺序无关地兜住 `prefix(1)` 族，crosstalk 那根由 3126 的直接单测钉住。损失的是这条 fixture 自身的分辨力与那段散文的可信度 |
| 7 | 1850 圈的**生产树目录形状** | 两条嵌套 fixture 落在 `ClaudioGUICore/` / `ClaudioGUI/Deep/` | 改回 `Nested/` / `Deep/`（「跟另一条 suite 命名统一」）或删掉 DirtyTwo → 五条断言零响应 → 消费循环挂 `where !finding.contains("ClaudioGUICore/")` 存活。姊妹 suite 2405 已用逐字前缀见证钉过同款，照抄即可 |
| 8 | 1854 的「**三种**不同违规形态」 | 三条 Dirty fixture 产出跨两类 finding | 三条统一成同一种写法 → `count >= 3` 只数条数、对种类全瞎 → 消费循环按种类过滤（`where !finding.contains("没有 @MainActor 隔离")`）存活 |
| 9 | 1939 `executedVectors.append` | 它**必须是块的最后一行** | 「读起来更顺」挪到块首 → G4 自称唯一挡得住的「提前退出」当场清零：`if vectorPathPrefix.isEmpty { return }` 会让生产向量那圈跳过四条关键腿而全绿，把 suite 打回 `abbf48e` 修之前 |

**Why:** 与 ⑯ 同一根因。fixture 是**输入**，断言只看**输出**，于是「输入还是不是当初那个攻击形状」全靠
人读注释。而这类编辑的诱因往往是现成的（同文件里另一条 fixture 就是那个写法），「统一一下写法」是
最自然不过的一刀。

**修法方向:** ⑯ 那一版是模板，但**别照抄它的第一稿**：钉表面形状（行序 / 行数）是代理量，红队实测
`private import os.log` 能顺序不动地把分辨力清零。要钉的是**威胁本身** —— 就地重建被防的那个变异，
断言它在这条 fixture 上产出的东西恰好是预期的那一个。#7 #9 例外：那两条钉的是路径与执行事实，用逐字
前缀见证 / 检查数增量更直接。

**⚠️ 覆盖边界（别把这条读得比它大）:** #6 经验证在 suite 级**没有活洞**，只是局部分辨力衰减；其余
八条给出的「存活变异」均未实跑台账坐实，是读码推演。落地时每条都要先自己跑一遍第一格（打变异、
不加断言、确认全绿），别把推演当实测。

**Context:** 2026-07-20 修 ⑯（`/codex review 899302a` P1-2）时顺带扫出来的。⑯ 自己实测过：把干净
写者挪到中间，**2269 条断言一条不红**。这是「措辞比覆盖范围大」的第十二次复发。

**Effort:** M（九处各自独立，可逐条落；#1 #5 #7 最便宜）
**Priority:** P2（#1 是全仓唯一杀得掉 M12 的 fixture，#9 能整条撤销 `abbf48e` 那一轮的修复）
**Depends on:** 无

### 穷尽性断言丢了 `action` 这一维 —— 「断开失败」这一视觉态从没被任何一帧渲染过

**What:** `PreviewFixtures.onboardingActionStateCoverage` 对 `.failed` 的分类是 `case .failed(_, _, let detail)` —— **`action` 被 `_` 丢掉了**，只按 detail 是否为 nil 分成 `failed.noDetail` / `failed.withDetail`。而 `onboardingActionStates` 里两条 `.failed` fixture **都是 `.takeOver`**。于是 `.failed(action: .disconnect, …)` 在整个 state gallery 里**一帧都没有**，而 `assertExhaustive()` 照样全绿 —— 因为两个标签都已被 takeOver 的 fixture 满足。

**Why:** 这与 `PreviewFixtures.swift` 自己的注释声称在防的那件事（「否则 T17 引入的两个新视觉态**从来不会被任何一帧渲染**，而 `assertExhaustive()` 仍然全绿」，即 `/ship` 收口记录 ③ 那次翻车）是**同一类错，在声称修好它的那个函数里**。

**Context:** 2026-07-12 T17c。修法：`case .failed(let action, _, let detail): "failed.\(onboardingDiskActionCoverage(action)).\(detail == nil ? "noDetail" : "withDetail")"`，同步扩 `PreviewFixturesSuite` 的 expected 名册、补两条 `.failed(action: .disconnect, …)` fixture。**注意依赖**：补了 fixture 也没用，除非画廊能渲染真正画那颗按钮的视图 —— 见下一条。

**Effort:** S
**Priority:** P2
**Depends on:** 「state gallery 给「断开连接」画的是一帧 app 里不存在的画面」

### 「仍要打开」之后，bundle 里的嵌套 helper 还带不带 quarantine —— 未在真实下载路径上验证

**What:** T17 实测确认了三件事：`FileManager.copyItem` 会传播 `com.apple.quarantine`；一个带章的二进制经 `/bin/sh -c` 执行会被 Gatekeeper SIGKILL（`exit=137`，零 stderr）；`setup` 现在会剥离 + 回头验证。**没验的是**：用户在「系统设置 > 隐私与安全性 > 仍要打开」里批准这个 app 之后，`Contents/Resources/bin/claudio` 上的章**是不是也跟着被清掉了**。

**Why:** 如果是，那么 `setup` 的剥离在真实下载路径上是一次 no-op（无害）；如果不是，它就是唯一挡在「装完永远静音」前面的东西。**两种情况下修法都不变**（剥 + 验），所以这不阻断发布 —— 但它决定了这道闸门到底是保险丝还是主保险。真机复现需要一次真实的未签名 DMG 下载 + Gatekeeper 批准流程，本地 ad-hoc `.app` 造不出来（本地编译的二进制根本不带章）。

**Context:** 2026-07-12 T17b。验法：打一个真 tag → 从 GitHub Releases 下载 DMG → 拖进 /Applications → 走「仍要打开」→ `xattr -lr /Applications/Claudio.app | grep quarantine`。

**Effort:** S
**Priority:** P3
**Depends on:** 首个真实 tag release

### `claudio use` / `claudio install` 没有 T17e 那条不变式 —— 一条命令就能重新造出 setup 刚拒绝创造的那台哑机器

**What:** T17e 让 `performFirstRunSetup` 立下了「报成功时 `selected_pack` 一定指向一个 `play` 解析得出来的包」
这条不变式。但它**只是 `performFirstRunSetup` 这一个函数的不变式，不是系统的**：
- `selectPack`（`claudio use <id>`，Use.swift:63）只校验 `resolvePackDirectory`，**不读 manifest** —— 于是
  `claudio use <一个只有目录、没有 manifest 的残骸>` 会返回 `.success` 并打印「✓ 已切换到声音包」，而 `play`
  从此每次都 `.notReady`。
- `claudio install`（Subcommands.swift）直接调 `installClaudioHooks()`，**零校验**，成功就打印 ✓。用户被 setup
  的失败拦下之后，最自然的下一条命令就是它。

**Why:** 「注定是哑的安装不许报成功」这条纪律，只要有一扇门没装上，它就不是一条纪律，只是一个函数的局部性质。

**Context:** 2026-07-12 T17e 对抗评审（bypass 镜头 + 完备性批评者独立命中）。本次刻意不做：`use` 加校验要新增
`UseError` case（波及 UseSuite ＋ GUI 画廊），`install` 加校验会改动一条**文档里的一等命令**的契约（ENGINEERING.md
契约表：「把 hook 写进 settings.json（幂等）」）—— 两者都该单独评审，不该混进一次 bugfix。
GUI 侧的切包画廊只列**解析得出来**的包，所以主动线暂时安全；这个洞主要长在 Terminal 上。

**可能的修法:** `selectPack` 在 `resolvePackDirectory` 之后追加一次 `loadPackManifest`（与 T17e 的
`isUsablePack` 同源），失败返回新的 `UseError.manifestUnreadable`；`installClaudioHooks` 的入口加同一道判据
（或至少让 `Install.run()` 先跑一次 `checkPackIntegrity`，坏管道时拒绝并给出与 setup 一字不差的那句话）。

**Effort:** S（use）/ M（install，要动契约）
**Priority:** P2
**Depends on:** None

### install **失败**时，CLI 与 GUI 都没有完整报告，而副作用已经落盘，且重试**永远不会**补发

**What:** install 失败路径更糟，而且是**结构性**的：

`SetupError`（`Setup.swift:221-275`）的每一个 case 只带 `reason: String` 或子错误 —— **没有任何字段能承载
`[SalvagedPack]` / `PackSelectionOutcome`**。而 `performFirstRunSetup` 的副作用顺序是：复制二进制 → **搬走坏包**
（`:403-431`，`moveItem` 到 `packs/.<id>.broken-<pid>` + `salvagedPacks.append`）→ 复制干净的内置包 → **写 config**
（选包）→ **写 hooks**（`:551`，`installClaudioHooks`）。

也就是说：**做主的那两个副作用，发生在可能失败的那一步之前。** 一旦最后一步失败（`.lockBusy` / `.notWritable` /
`.malformedHooksSection` / `.concurrentModification` —— 后三个每次重跑都一字不差地失败），`:562` 就
`return .failure(.installFailure(error))`，`salvagedPacks` 就地丢弃。CLI 只 `print("✗ \(error.description)")`
（`Subcommands.swift:117`，那句带绝对路径的 ⚠ 只在 `printSetupSummary` 的成功分支）；GUI 只
`actionState = .failed(...)`（`OnboardingViewModel.swift:344-346`）。

**而且补不回来**：用户按提示「再点一次」，这一次 `isUsablePack(minimal-chime)` 已经为真（上一轮刚盖了一份干净的）
→ `:392` 直接 `continue` → `salvagedPacks` 恒空 → **就算这次成功，告知也永远不会再生成**。

净结果：用户的包目录（里面可能有他自己导入的音频）被搬进了一个**每一个界面都过滤掉**的点开头目录
（`availablePackIDs` 与 `PackGallery` 都显式过滤 `.` 开头），而唯一一条载着 `movedTo` 绝对路径的消息被丢弃了。
`SalvagedPack` 自己的文档（`Setup.swift:186-190`）写的是：「**现在它是 outcome 的一等公民**」——
它只是**成功** outcome 的一等公民。

**Why:** 缓解是真的：`moveItem` 一个文件都没删，`AudioImport` 也只复制不移动源文件，所以用户拖进来的原件通常
还在 Desktop / Downloads。**但这只是把「丢数据」降级成「藏数据」**：菜单栏 app 的用户，Finder 默认不显示点目录，
app 内每一个界面又都过滤它 —— 我们替他做了主，然后在唯一一次该开口的时候闭嘴了。

⚠️ **这条不是锁分离引入的**：`.malformedHooksSection` / `.notWritable` / `.concurrentModification` 在 `main` 上
就走得出同一条路。锁分离只是给它新增了一条 `.lockBusy` 触发方式。**别让一条 147 行的锁分离分支扛它。**

**可能的修法:** 让 `SetupError` 带得动部分结果 —— `case installFailure(SettingsUpdateError, salvaged: [SalvagedPack],
packSelection: PackSelectionOutcome)`；`OnboardingActionFailure` 跟着带上 notices；GUI 的 `.failed` 分支与 CLI 的
`print("✗ …")` 都把那行 ⚠ + 绝对路径打出来。修复时需同时覆盖 CLI、GUI 以及跨重启可见性，不能只补一条即时提示。

**Context:** 2026-07-13 生产代码 diff 的六路对抗 review（lock-semantics / assume-broken 两个镜头独立命中）。
上一条 TODO 只覆盖了成功路径的 GUI 侧，失败路径**两边都没有** —— 而失败路径才是副作用真的会留在磁盘上的那条。

**Effort:** M
**Priority:** P1（用户损害面：可能藏掉他磁盘上唯一一份自导入音频，且不可补发）
**Depends on:** None

### `claudio` 可执行 target 的输出从来没有被测过一行 —— T17e 那两句 ⚠ 是产品语义，却住在测试够不到的地方

**What:** `printSetupSummary` / `hooksOutcomeMessage` 住在 `helper/Sources/claudio/Subcommands.swift`（可执行
target），而 `claudio-tests` 只依赖 `ClaudioCore`。于是 T17e 新增的两句 ⚠（「已替你选中 X」「已把你的包原样搬到 Y」）
—— 也就是「替用户做主必须说出来」这条规矩的**唯一载体** —— **零测试覆盖**：把它们整段删掉，1025 checks 照样全绿。

**Why:** 这与 `ViewWiringSuite` 头部自陈的那个结构问题同源（`ClaudioGUI` 是 executableTarget，harness 一行都跑不到）。
一条产品承诺，如果没有任何断言钉着它，它离被顺手删掉只有一次重构的距离。

**可能的修法:** 把 `printSetupSummary` 的**纯字符串部分**下沉进 `ClaudioCore`（例如
`setupSummaryLines(_ outcome: SetupOutcome) -> [String]`），`Subcommands` 只负责 `print`。然后表驱动地钉住每一种
outcome 该出现哪几行（尤其是那两个 ⚠ 必须出现、且必须带绝对路径）。

**Effort:** S
**Priority:** P2
**Depends on:** None

### `doctor` 会把两类「一声都发不出来」的包报成 ✓ 完整

**What:** 两个各自独立的假阳性：
① **manifest 的事件键全拼错**（第三方包写了 `"on_stop"` 而不是 `"stop"`）→ `checkPackIntegrity` 的 `missingFiles`
   为空 → `.complete` → doctor 打印「✓ 声音包完整」，而四个 v1 事件一个都没映射上，**每个事件都静默无声**。
② **0 字节 / 根本不是音频的文件**（见上一条「0 字节」）。

**Why:** doctor 是「静默失败必须有诊断轨迹」（决议 6）的唯一出口。它自己失明的地方，就是用户永远查不到的地方。

**Context:** 2026-07-12 T17e 第二轮对抗评审（bypass 镜头）。T17e 的判据只走到「manifest 读得出来」，够不到这一层。

**可能的修法:** `checkPackIntegrity` 只认 `Event.allCases.map(\.manifestKey)` 这四个键；四个都没映射上时返回一个新的
`.noMappedEvents(packID:)`，doctor 渲染成 ⚠（**仍是 warning，不硬失败** —— 包内容的缺口不该阻断安装，见 T17e
「管道 vs 内容」那条线）。

**Effort:** S
**Priority:** P2
**Depends on:** None

### `selected_pack` 里的控制字符 / ANSI 转义会被原样打进终端

**What:** `printSetupSummary` 的 ⚠ 行、以及 `SetupError.selectedPackUnresolvable` / `doctor` 的四条 pack 消息，
都把 `config.json` 里的 `selected_pack` **原样**拼进输出。一个含 ANSI 转义序列 / C0 控制字符 / 超长字符串的 pack id
可以借此改写终端显示。

**Why:** 低危（用户得先自己往自己的 config 里塞这种东西，或者装一个恶意的第三方包并选中它），但输出的可信性是
`doctor` 这类诊断工具的立身之本 —— 一个能被内容改写的诊断，诊断的就不是那台机器。

**Context:** 2026-07-12 T17e 第二轮对抗评审（repair-semantics 镜头，P3）。既有问题（doctor 早就这么打了），
T17e 只是**新增了一个打印点**。

**可能的修法:** `ClaudioCore` 里加一个共享的 `displaySafe(_:)`（截断到 ~64 字符 ＋ 把非打印字符转义成 `\u{XX}`），
setup 与 doctor 的所有 packID 打印点统一走它。

**Effort:** S
**Priority:** P3
**Depends on:** None

### 一个 0 字节 / 根本不是音频的文件，会被判成「这个事件有声音」

**What:** `doctor` / `play` / GUI 覆盖度三边共用的判据是 `regularFileExists`（`stat` 判 `S_IFREG`）——它只问「是不是
一个正规文件」，不问「里面有没有东西」。一个 0 字节的 `stop.mp3`（下载中断、Git-LFS 指针、`touch` 出来的占位）
会让 `doctor` 打印「✓ 声音包完整」、面板把这一行画成 `.present`（甚至给出试听按钮）、`play` 兴高采烈地 spawn
`afplay` —— 然后**什么声音都没有**。afplay 的失败退出码没人接（fire-and-forget），`claudio.log` 一个字都不会写。

**Why:** 这是「装完是哑的」这一族里**最后一个零信号的形状**：四个界面（setup ✓、doctor ✓、面板 present、日志空）
全部说「好着呢」。T17e 的判据只走到「manifest 读得出来」，够不到这一层。

**Context:** 2026-07-12 T17e 对抗评审（bypass 镜头）。本次不做：修法要**同时**改三处同源判据
（`Doctor.swift` 的 missingFiles、`Play.swift` 的 `resolveAudioFile`、`gui/CoverageState.swift` 的 `coverageState`），
少改一处就会制造出这三个文件的注释里反复警告过的「两套判据」。

**可能的修法:** 在 `SafeFileRead.swift` 加一个 `playableFileExists(at:) = regularFileExists && st_size > 0`，三处
逐字替换。（更彻底的做法是校验音频头，但那需要引入解码依赖，不值得。）

**Effort:** S
**Priority:** P2
**Depends on:** None

### AudioImportViewModel 并发 handleDrop() 的完成顺序竞态（生产路径已有 revision 保护，通用语义仍待收口）

**Status（2026-08-19）：** 部分完成。Sound Packs Window 的生产导入路径已经用 `audioImportActionRevision` 保护新旧操作顺序；通用 `AudioImportViewModel.handleDrop()` 仍需决定是删除/归档，还是补齐「最新操作获胜、旧完成不能覆盖新状态」的契约与测试。以下 What / Why 保留为原始发现。

**What:** `handleDrop(sourceURL:...)` / `handleDrop(requests:)` 都把耗时工作丢进 `Task.detached`，只有 `@Published state` 的写回在主 actor。如果同一个 view-model 实例上两次 drop 重叠触发（比如探测时长慢的文件 vs. 快的文件），两个 detached task 完成顺序不保证跟触发顺序一致，`state` 最终可能反映的是较早那次 drop 的结果，不是最近一次。

**Why:** 目前 `AudioDropZoneView` 还没接进真正跑起来的 app（T15 留白），这条代码路径没有任何真实用户能触发，风险为零。但 T16（逐事件导入绑定）真正接线后，多个事件行各自的 drop-zone 一旦允许用户快速连续拖拽，这个顺序竞态就会变成真实、可观察的 bug。

**Context:** Testing 专家在 `/ship` pre-landing review（2026-07-10）里发现的。修法方向：要么显式定义"最后完成的赢"是不是就是想要的语义（如果是，加个回归测试钉住它），要么给每个 view-model 实例加一个"正在处理"的 in-flight task 引用，新的 handleDrop 调用先取消/等待前一个。留给 T16 真正接线那批工作一起处理，不单独抽出来。

**Effort:** M
**Priority:** P3
**Depends on:** T16（逐事件导入绑定）

### currentExecutablePath 没有真正解析 PATH，裸命令名被当成当前目录的相对路径

**What:** `currentExecutablePath` 的 doc comment 曾经声称支持"裸命令名走 `PATH` 解析"，但实现只是把 `argv[0]` 当成 `currentDirectory` 的相对路径拼起来——如果用户把 `~/.claudio/bin` 加进自己的 `PATH`，然后在一个不相关的目录里跑裸 `claudio setup`，这里解析出来的路径跟 shell 实际通过 `PATH` 找到的二进制毫无关系。

**Why:** `docs/distribution.md` 教用户的命令一直是带完整路径的，不受影响；但这仍是一个货真价实的逻辑错误——doc comment 曾经承诺的行为和实现不一致，已经在这次改动里把 doc comment 改成实话（不再声称支持 PATH）。Codex 两轮独立审查（adversarial + structured review）都指出了同一处。

**Context:** 正确修法要改用 macOS 的 `_NSGetExecutablePath`（真正拿到 OS 层"这个进程实际怎么被启动的"路径，不用猜 `argv[0]`），但这个 API 没法像现在这样注入 `arguments`/`currentDirectory` 参数来写测试，需要重新设计一个可测试的封装（比如注入一个 `() -> String` 闭包，默认调 `_NSGetExecutablePath`）。这次先不做，只把文档改成实话，行为改动留到下一轮。

**Effort:** M
**Priority:** P2
**Depends on:** None

### install 不清扫升级前留下的坏 hook 条目，异形 HOME 下会与新条目并存

**What:** `claudioHookCommand` 现在会给"会被 `/bin/sh -c` 破坏的路径"加单引号（T13 修正 ②，2026-07-10）。如果某用户的 HOME 含空格 / `$` / `{}` / `*`，他在升级前装的那条 hook 是**无引号**的旧字符串。升级后跑 `claudio install`：`groupContainsCommand` 拿新的带引号字符串做精确等值，认不出那条旧的，于是**追加**一条新的。结果 settings.json 里同一事件下并存两条——旧的那条 `/bin/sh` 每次都会报错（路径被切开 / brace 展开到不存在的路径），新的那条正常发声。

**Why:** 不是静默错误：`uninstall` 的结构化匹配器**两条都认得**（它同时接受带引号与旧的无引号带空格形态，有测试钉住），所以 `claudio uninstall && claudio install` 就能自愈。而且这类 HOME 在升级前 claudio 本来就是坏的（hook 从不触发，或 `*` 情况下执行了别的二进制），所以"并存"是从"完全不工作"变成"工作但有噪声"。真正的修法是让 `install` 也走结构化匹配去识别并替换 legacy 条目，但那会改动 `install` 现有的"append, never overwrite" + 精确等值幂等契约——那是一条被多处测试和 `detectHookInstallStatus` / gui onboarding 依赖的契约，不该跟一次 bugfix 混在一起改。

**Context:** 红队（5 finder × 3 怀疑者，2026-07-10）在 codex review 9913ae9 的修复补丁上提出，两个独立维度各自命中。glob 那一支的实测证据：同级存在 `a!b` 与 `a*b` 时，`sh -c '…/a*b/prog'` 执行的是 `…/a!b/prog`。

**Effort:** M
**Priority:** P3
**Depends on:** None

### 菜单栏 app 以 GUI 方式启动时 PATH 极简，doctor 的 Claude Code 版本检查会恒报 warning

**What:** `checkClaudeCodeVersion` 走 `/usr/bin/env claude --version` 做 PATH 查找。终端里没问题（实测 `claude` 在 `~/.local/bin/claude`，0.05s 返回 `2.1.206 (Claude Code)`）。但 Finder/launchd 启动的 GUI 进程拿到的是极简 PATH：实测 `env -i PATH=/usr/bin:/bin /usr/bin/env claude --version` → `env: claude: No such file or directory`（退出码 127）。

**Why:** 眼下无害——`doctor` 是 CLI，永远在终端里跑，拿得到用户的 PATH。但 `VersionCompatibility.swift` 的 doc comment 明确写着菜单栏 app 计划 in-process 复用这套 API；那一刻这个检查会对**每个**用户恒定报一条"⚠ 无法核实 Claude Code 版本"，而它其实装得好好的。修法：GUI 侧探测时补上常见安装位置（`~/.local/bin`、`~/.claude/local`、Homebrew 前缀），或者干脆读用户的 login shell PATH，而不是依赖继承来的那个。

**Context:** 2026-07-10 codex review 9913ae9 期间自查发现（codex 未报此条）。同一轮里另一条推测——"`claude --version` 是 Node CLI，2s 超时可能不够"——**实测证伪**，它是原生二进制，0.05s 返回，2s 绰绰有余，故不列为 TODO。

**Effort:** S
**Priority:** P3
**Depends on:** T7 / 菜单栏 app 真正复用 CommandRunning

### SystemCommandRunner 超时后只 terminate() 不强制回收，忽略 SIGTERM 的子进程仍可能失控

**Status（2026-08-19）：** 部分完成。`SystemCommandRunner` 已加入 `terminationHandler` 和 deadline-bounded 的输出排空；但超时后仍没有 bounded wait，必要时也没有升级到 `SIGKILL` 并完成回收。以下 What / Why 是原始发现，当前只保留剩余硬化项（相关修复：`72d0765`）。

**What:** `SystemCommandRunner.run` 的超时路径只调用 `process.terminate()`（发 SIGTERM）就返回，不 `waitpid`、也不在子进程赖着不退时升级为 SIGKILL。一个 `trap "" TERM` 或需要时间清理的子进程会被报成 `.timedOut`，但真实进程仍在后台继续跑。另一处相关：`drainToEOF` 之后的 `exited.wait`（`VersionCompatibility.swift:210-214`）——若排空 stdout 几乎耗尽 deadline，即使已 `sawEOF`、子进程只差微秒就退出，`exited.wait` 拿到约 0 的剩余时间也可能返回 `.timedOut`，于是 doctor 显示"无法核实版本"而非那个（可能低于下限的）真实版本。

**Why:** 眼下无害：生产里唯一的命令是 `/usr/bin/env claude --version`——它不 trap SIGTERM、会乖乖被杀，且是原生二进制 0.05s 返回，远快于 2s 上限，EOF-后误报那一支实际不可达；runner 目前也只被一次性的 `doctor` CLI 进程调用，进程随后就退出。但 `VersionCompatibility.swift` 的 doc comment 反复写明菜单栏 app 计划 in-process 复用这套 API；那一刻，面对刻意忽略 SIGTERM 的子进程，失控子进程会累积。

**Context:** Codex 结构化评审（2026-07-11 `/ship`，[P2]）与 Claude 对抗子代理（finding #3）各自独立命中同一区域，一个说"terminate 不 reap"、一个说"EOF 后仍可能误报超时"，均 LOW/latent、生产不可达。修法：`terminate()` 后做一次 bounded 等待，仍在跑就 `SIGKILL` 并回收；`drainToEOF` 返回后若 `sawEOF && !process.isRunning` 直接 `.completed(exitCode, stdout)`，不再进那个可能拿到约 0 剩余时间的 `exited.wait`。已有超时测试用 `sleep`（会被 SIGTERM 杀），没覆盖 trap-TERM 的子进程——补测需要一个真的忽略 SIGTERM 的子进程 fixture。

**Effort:** M
**Priority:** P3
**Depends on:** T7 / 菜单栏 app 真正 in-process 复用 CommandRunning

### claude-version 探测的 2s 超时与 `/usr/bin/env` 路径在三处各写一遍字面量

**What:** `checkClaudeCodeVersion`（`VersionCompatibility.swift:325`）、`claudeCodeVersionDoctorResult`（同文件 :384）、`DoctorEnvironment.claudeVersionTimeout`（`Doctor.swift:256`）各自把 `2.0` 秒超时以裸默认参数字面量写了一遍；`/usr/bin/env` 也在两处重复。

**Why:** 同一个文件把版本下限刻意收敛成 `VersionCompatibility` 枚举里的单一真相源常量，却把探测超时留成三份互不协调的拷贝——改其中一个会静默和另外两个分叉。纯一致性/可维护性，无行为风险。

**Context:** Maintainability 专家在 2026-07-11 `/ship` pre-landing review 提出（confidence 6）。修法：加命名常量（如 `VersionCompatibility.defaultClaudeVersionProbeTimeout` 与一个 `defaultEnvPath`），三处默认参数都引用它。

**Effort:** S
**Priority:** P4
**Depends on:** None

### Setup.swift 的默认选包点前缀过滤用 Character 级而非 scalar 级

**What:** `performFirstRunSetup` 排除点前缀目录用 `!$0.hasPrefix(".")`（Character 级）。一个首字符 `.` 与紧随其后的组合符号融成一个 grapheme cluster 的目录名，整体不等于 `"."`，会溜过这道排除。

**Why:** 极其牵强——需要一次被打断的 `setup` 留下一个 id 以"组合符点"开头的临时包目录，而 `selectPack`/`isSafePackID` 下游本来也会拒掉它。实际不成立，纯一致性：本包其余部分（尤其 `HookCommandMatching`）都严格在 Unicode scalar 层做判定，唯独这一处停在 Character 层。

**Context:** Claude 对抗子代理（2026-07-11 `/ship`，finding #5）提出。修法：改成 scalar 级判定（如 `$0.unicodeScalars.first == "."`）与本包其余部分的粒度对齐。

**Effort:** S
**Priority:** P4
**Depends on:** None

### GUI 写/读路径的同用户 symlink TOCTOU 未闭合（manifest bind + import + config，v2）

**What:** `bindEventToManifest` / `importAudioFile` 的最终 `Data.write(.atomic)` 与 `loadPackManifestData` 的读，都在 `resolvePackDirectory`/containment 校验之后隔若干 syscall 才操作路径。原子写的 `rename` 只保护**叶子**（`manifest.json`）——中间分量（`packID` 目录本身）被换成 symlink 会被内核跟随，把写重定向到包外。`config.json` 写路径（`selectPack`/`setEventEnabled`）则完全无 symlink 解析 / 乐观并发重读（不同于 `settings.json` 的 `atomicWrite`）。

**Why:** 同用户威胁模型——能并发换 symlink 者本已有该用户的写权限、不构成提权，与 ENGINEERING.md「pack 路径 containment 的 TOCTOU 加固」既定立场一致，故 v1 不做。现在 T16/T15 把这些写路径接进真实面板，站点增至：manifest bind、`importAudioFile` 持久化、`config.json` 两个写者（CLI `use` + GUI 面板）。

**Context:** T16 security-reviewer（2026-07-11）实证复现父目录 symlink 重定向（叶子 rename 语义只挡 `manifest.json` 自身被换，挡不住上层目录被换）；T15 swift-reviewer 指出 `config.json` 无 `settings.json` 那套加固。真修 = 校验后持有 `open(O_DIRECTORY|O_NOFOLLOW)` 目录 fd，后续全走 `openat`/`fstatat`/`renameat` 相对该 fd（`readRegularFileSource` 已对单文件这么做，缺的是**包目录级**）；config 侧补 symlink 解析 + 乐观并发重读。`ManifestBinding.swift` 的注释已修正为「原子写只保护叶子」。

**2026-07-13 `/codex review 573336d` 独立复现同一条（[P2]），行号已锁死**：`ConfigMutation.swift:205` 是裸 `try data.write(to: configFile, options: .atomic)` —— **没有** `resolvingSymlinksInPath()`；而同一个仓库的 `SettingsInstaller.swift:634` 就在写 `settings.json` 前先解析了，还配了一段注释专门讲这个坑（「`.atomic` 做的是 temp+rename **on the symlink**，把链接本身替换成普通文件，与 dotfiles 仓库静默分叉」）。更刺的是 `SafeFileRead.swift:110` **明确允许** `config.json` 是 symlink 并跟随读取 —— 于是 stow / chezmoi 用户的 config 是**读目标、写链接**：两边操作的根本不是同一个文件。D23 定稿①（`573336d`）改的正是 `ConfigMutation` 的这个写函数，**没有**顺手加上这一行；本条仍然开着。（真修与本条上面那半是同一处加固，仍建议合并处理。）

**Effort:** L
**Priority:** P3
**Depends on:** helper 未来提权运行 / 处理不可信可写目录时才升级

### DesignTokens 规范化 / 生成式 token 模块归并延后（原划归 T14，越界故未做）

**What:** `gui/Sources/ClaudioGUI/DesignTokens.swift` 仍是跨 T7/T15/T16 手抄扩展的 DESIGN.md 调色子集（neutral/brand/surface-2/四事件色/glyph），非一个规范化（理想是从 DESIGN.md 生成）的 token 模块。

**Why:** ENGINEERING.md「T7 非阻断遗留②」原把这项归并划给 T14；T14 落地时刻意不做——越出「state gallery」范围，且会 churn 四个已上线视图换 token 引用、对 gallery 无收益。当前手抄方式功能正常、值与 DESIGN.md 逐一对齐，故为非阻断。

**Context:** T14 swift-reviewer（2026-07-11）+ 实现者自评。`DesignTokens.swift` 两处注释已更正为指向本条。修法：抽一个规范 token 模块（或从 DESIGN.md 生成），四视图改引用它。

**Effort:** M
**Priority:** P3
**Depends on:** None

### T15 真身面板的交互 a11y / 播放 / 接线仍需真机走查（**「需要一台装 Xcode 的 Mac」这个前提是错的，已推翻**）

**What:** 原条目说这些只能在「一台装 Xcode 的 Mac」上验 —— **不对**。2026-07-11 在本机（CommandLineTools，无 Xcode）用 `swift build -c release` 出来的二进制手工组了一个 ad-hoc 签名的 `Claudio.app`（跟 release.yml 一模一样的做法：`LSUIElement` Info.plist + `Resources/bin/claudio` + `Resources/packs/` + `codesign --sign -`），双击就跑起来了，菜单栏图标、面板、真机 AX 探针全都能用。**没有 Xcode 也能做完整真机走查**，此前所有「等一台有 Xcode 的 Mac」的等待都是自缚。

已由那次走查验掉的：`NSStatusItem` 点击 ↔ popover 开关 ✅；`.transient` Esc 关闭 ✅（**并非白来的** —— 见下方 `NSApp.activate` 那笔账）；面板渲染 ✅。

**仍未验、且必须在 state 到 `.installed` 之后才够得着的**（本机当前 `~/.claudio/bin/` 不存在、settings.json 无 claudio hooks，所以第一屏永远是 `.helperMissing`，运行态面板根本进不去）：Tab/Shift+Tab 走 action→mute 序（**注意：默认系统设置下这条根本不成立，见下一条 TODO**）、切包画廊滚动/点选、reduce-transparency、静音/切包后 SwiftUI refresh、`NSOpenPanel` 端到端喂进导入管线。

> **2026-07-14 更新（PLAN-MASTER-VOLUME.md §9 真机走查，聚焦主音量行）**：VoiceOver 逐控件导航 + 进入播报 **✅ 已验**——开 VoiceOver、焦点移到主音量滑块，VO 字幕面板截图实测依次显示「42% 主音量, slider」→按↑箭头→「45%」，`config.json` 同步落盘，播报/推动/落盘三条断言全部拿到证据。真实 `NSSound` 试听 **✅ 已验**（拖到 ~20% 明显变小、拖到 0% 完全无声）。**Dynamic Type 三级真实布局 ❌ 验出真失败**——系统「文字大小」拉到最大档（`defaults read com.apple.universalaccess FontSizeCategory` 确认 `global=AX5`）、完全重启 app 后，主音量行没有任何变化（不折行、面板不加宽）。见新条目「主音量行的 Dynamic Type 三级布局在真机上完全不生效」。

~~此外仍未接线：onboarding CTA（接管/修复/断开）**全是 no-op**~~ → **2026-07-12 已接线并真机验证通过（T17b）**：CTA 现在真的会复制二进制 + 内置包、选默认包、写 hooks，失败会当场说出来；「断开连接」在运行态面板底部有了真入口。仍未做：状态栏图标仍是占位 SF Symbol（`waveform.circle`），非最终定制单色字形。

**Why:** 面板核心逻辑（状态派生 / 写回 / 焦点顺序 / 对比度 / Dynamic Type 表）已下沉 `ClaudioGUICore` 并单测覆盖（helper 945 / gui 543），但交互真身只在真机成立 —— 而真机走查现在**随时可做**，不再有硬前提。

**Context:** T15 tdd-guide + a11y-architect + swift-reviewer（2026-07-11）；同日真机走查推翻了「需要 Xcode」的前提。修法：把剩余项在真机走完 —— 但先得让 state 进 `.installed`（要么跑 `claudio setup` 真接管，要么接完 T17 的 CTA）。

**Effort:** M
**Priority:** P2
**Depends on:** state 到 `.installed`（`claudio setup` 或 T17）

### 面板的 Tab 遍历 / 首焦点在**默认系统设置**下是死的（macOS「键盘导航」默认关闭）

**What:** 面板里的可聚焦控件**绝大多数**是 SwiftUI `Button`（`EventRowView` 试听/导入/静音、`PackGalleryView` 卡片、`OnboardingView` CTA），全 `gui/Sources/` 里 `.focusable()` 出现 **0 次**。而 macOS 的「键盘导航 / Full Keyboard Access」**系统默认是关的**，关闭时 Button 不进 key view loop —— `applyFirstFocus()` 那次 `@FocusState` 赋值直接落空，Tab 在面板里也无处可去。

> ⚠️ **本条的措辞原为「所有可聚焦控件都是 Button」，阶段 D 之后不再成立**：`MasterVolumeRow` 的 `Slider` 是个例外，且它在 FKA 关闭时的行为**没人验过**（Button 的那套理由不适用于 value-adjust 控件）。**别拿这条台账的判据给整个面板的 Tab 结案** —— 它只覆盖 Button。见下方独立条目「主音量滑块在 FKA 关闭时到底能不能 Tab 到」。

**Why:** ENGINEERING.md 的无障碍规格已按实际行为改写（分成「无条件成立」和「仅 FKA 开启时成立」两档），所以**文档不再撒谎**；但产品缺口还在：一个没开 FKA 的纯键盘用户（非 VoiceOver）操作不了这个面板。VoiceOver 用户不受影响（VO 光标独立于 FKA），Esc 与鼠标也不受影响。

**Context:** T15 a11y 对抗评审（2026-07-11）。Apple WWDC23 “The SwiftUI cookbook for focus” 原文：「macOS and iPadOS don't give focus to buttons when you tap them, and the only way to reach them with the Tab key is to turn on keyboard navigation system-wide.」**别指望 `.focusable()`**：它的默认 interactions 就是 `.activate`，纯 no-op；`.focusable(interactions:)` 还是 macOS 14+ API，超出本包 macOS 12 floor。真要在不开 FKA 时也能纯键盘操作，唯一出路是**自建焦点系统**：`focusedTarget` 从 `@FocusState` 换成普通 `@State` + 自绘焦点环（DESIGN.md 需补 focus-ring token），并在 `MenuBarController` 里挂 `NSEvent.addLocalMonitorForEvents(matching: .keyDown)` 拦 Tab/Shift+Tab/空格/回车，用已有的纯模型函数 `panelFocusOrder(_:)` / `panelOpeningFocus(rows:packCardIDs:)` 推进焦点并派发 action（这些函数已有单测，自建路径照样可测）。

**Effort:** L
**Priority:** P3
**Depends on:** None

### 逃生路线：若真实用户反馈「点 Claudio 图标丢字」，唯一出路是丢掉 NSPopover 改 NSPanel

**What:** `MenuBarController.showPopover()` 里的 `NSApp.activate(ignoringOtherApps:)` 是无障碍的**必要代价**（无它 popover 的 window 永远不是 key，整节无障碍规格一条都不成立；替代 API 已按 AppKit 头文件逐条证伪 —— 见 ENGINEERING.md「T15 决议」）。但它有一笔**修不掉**的账：用户正用输入法**组字**时点图标 → 宿主 app 失活 → 组字缓冲被强制上屏或直接丢弃。这条**无法**靠 `popoverDidClose` 的「交还前台」兜底，它发生在**打开**的瞬间。

**Why:** 今天不动它 —— 中文用户在终端/编辑器里组字**同时**去点菜单栏图标，是个不常见的时序。但这是本 app 面向中文用户的一条真实体验裂缝，触发条件驱动：**有人报「点一下丢字」就启动。**

**Context:** T15 对抗评审（2026-07-11，ux-regression lens）。修法只有一条：丢掉 `NSPopover`，自建 `NSPanel` + `.nonactivatingPanel`（公开 API 里唯一「window 能拿 key 而 app 不激活」的机制）。代价：① 丢掉 popover 的尖角与自动锚定（DESIGN.md / T15 明写「NSPopover 带尖角」→ **属未授权设计偏离，须重新拍板**）；② `.transient` 的点外/切 app 自动关闭要用全局事件监视器自己重写；③ **「非激活 panel 在 inactive app 下会不会进 AX 树」在本机无法静态断言 —— 必须先用真机 AX 探针验证再决定**，否则可能原样复现「拿不到 key」的老问题，白改一场。

**Effort:** L
**Priority:** P4（触发条件驱动，不主动做）
**Depends on:** 真机 AX 探针先验证 nonactivating panel 能进 AX 树

### 主音量滑块在 FKA 关闭时到底能不能 Tab 到 —— 面板第一个非 Button 可聚焦控件，没人验过

**What:** `MasterVolumeRow` 的 `Slider` 是面板里**唯一**的非 Button 可聚焦控件（阶段 D 新增），已被排进焦点序（`PanelFocusOrder` 的 `.masterVolume`）并绑了 `.focused(...)`。而上一条台账（「Tab 遍历在默认系统设置下是死的」）的**整段论证**建立在「面板里所有可聚焦控件都是 SwiftUI `Button`」这个前提上 —— 那个前提今天有了例外。

**Why:** Button 不进 key view loop 的理由（`.activate` interactions、`.focusable()` 是 no-op）是 **Button 专属**的，根本不描述一个由 `NSSlider` 支撑的 **value-adjust** 控件 —— AppKit 里 NSSlider 在 FKA **关闭**时是否进 key view loop，与 Button 不是同一个答案。**我们没验过。** 风险不在「滑块能不能 Tab 到」本身，而在：将来有人按上一条台账去评估「Tab 修好了没有」，会拿一个只覆盖 Button 的判据，给一个已经含 Slider 的面板结案。

**Context:** `/codex review 8771946` 完备性批评（2026-07-14）。ENGINEERING.md 的无障碍规格已就此**明确不作承诺**（在验之前）。验法：系统设置里**关掉**「键盘导航」，开面板，按 Tab —— 看焦点会不会落到滑块上（以及 ←/→ 能不能调值）。VoiceOver 那一档不受影响（VO 光标独立于 FKA，滑块的 label/value 已落地并有守卫）。

**Effort:** S（一次真机走查即可定性；若结论是「能」，上一条台账的措辞要跟着收窄）
**Priority:** P3
**Depends on:** None

### T16/T15 GUI 小项：用户可见绑定错误已并入 ManifestBindError 主条目，孤儿文件回滚与 doc-comment D 编号仍待处理

**Status（2026-08-19）：** 部分完成。绑定失败的用户可见错误已由下方 `ManifestBindError` 条目统一跟踪；当前仍开放的是失败后的孤儿文件清理/回滚，以及过期的 doc-comment D 编号引用。

**What:** ① `EventRowImportViewModel`：导入成功但随后 `bindEventToManifest` 失败时，已复制进包目录的音频文件会留下、不被任何事件引用（孤儿文件）——**文件本身仍未清理**，非安全问题，纯整洁。② T15/T16 新文件里约 26 处 doc-comment 引用「ENGINEERING.md T15 D3/D4」等 D 编号，但 ENGINEERING.md 无此细分——溯源/可读性 nit，读者按 D 编号 grep 会落空。

**Why:** 均无功能风险；两项都是「诚实但可更整洁」，攒到某次 GUI 收尾 pass 一起清。

**Context:** T16 security-reviewer + T15/T14 swift-reviewer（2026-07-11）。**本条此前记载不实，已更正**：原文写孤儿文件「已通过 `bindResult` 如实上报（非静默）」——事实是 `bindResult` 从未被任何视图读过（三个独立评审各自 grep 确认），它一直是静默的。**2026-07-11 `/ship` 这一批才真正接上上报**：`EventRowView` 现在会渲染 `bindResult` 的绑定失败与导入被拒（过程中发现内层 `AudioImportViewModel` 的 `@Published` 不会穿过外层 `EventRowImportViewModel` 自动传播，必须额外挂一个 `@ObservedObject` 才收得到）。所以「用户看不见失败」已解决，**留下的遗留只剩孤儿文件本身没被清掉**。修法：① 绑定失败时清掉刚复制进包的那个文件，或把孤儿文件纳入下次 doctor/清理；② 把 D 编号软化为「T15/T16」或「(本任务 step D4)」。

**Effort:** S
**Priority:** P4
**Depends on:** None

### Dynamic Type 三级布局在真机上疑似完全不生效——代码路径已替换，四档人工复验待做（2026-08-02）

**2026-08-02 更新：** 不再把 macOS SwiftUI `dynamicTypeSize` 误作会跟随系统设置的能力。三个界面现统一读取 `ClaudioInterfaceTextSize` 的四档 `UserDefaults` 偏好，并显式注入 `dynamicTypeSize`；入口位于主面板「Claudio 选项」。原根因已绕开，但真实四档布局与 VoiceOver 仍需在 AppKit 会话复验后才能关闭本条。

**What:** PLAN-MASTER-VOLUME.md §9 真机走查第 ⑪ 条（2026-07-14）：系统设置 → 辅助功能 → 显示 → 文字大小拉到最大档（`defaults read com.apple.universalaccess FontSizeCategory` 确认 `global=AX5`，即最高档），**完全退出重启** `Claudio.app` 后重新打开面板——D17/D44 描述的「主音量行变两行、面板加宽到 360pt」**完全没有发生**，面板与默认档位下逐像素一致。测试过程：先误增到系统设置里另一条无关滑块（显示对比度），发现后已改回原值，不影响本条结论；随后精确定位到「文字大小」这一控件（description 为「首选阅读字体大小」，range 0–14）并推到顶（14/14，预览文案确认变为「示例 42 点」），关闭面板重开、乃至 `⌘Q` 全新进程重启后复测，结果不变。**这次真机走查只覆盖了主音量行**（PLAN-MASTER-VOLUME.md §9 的走查范围本就是主音量行），`EventRowView`/`PackGalleryView` 从未被单独这样复测过。

**Why:** 这不是「测试没测对地方」——`defaults` 确认系统偏好确实写到了最高档，且给了 app 一次全新进程生命周期去读取它。真正的怀疑落在上面那条邻近 TODO（`DynamicTypeSize → PanelTypeSizeTier` 映射）默认成立的前提上：`PanelView.swift` 的 `typeSizeTier` 读的是 SwiftUI 的 `@Environment(\.dynamicTypeSize)`，而 macOS 上这个环境值**是否真的跟随「辅助功能 → 显示 → 文字大小」这个系统偏好**，本仓库从未验证过——两者可能根本不是同一件事（iOS 上 `dynamicTypeSize` 直接映射系统文字大小；macOS 的等价桥接历来更弱，`@Environment(\.dynamicTypeSize)` 在纯 AppKit 宿主的 SwiftUI 视图里默认恒为 `.large` 也是已知的平台坑）。如果确实如此，那么 `typeSizeTier` 后面接的那张三档映射表（`.larger`/`.largest`/`.maximum`，ENGINEERING.md:269 术语表）**永远读不到非默认值**，D17/D44 的验收标准在真机上不可能通过——不管 `switch` 里 `default:` 写不写 `@unknown` 都无关紧要（上面那条 TODO 因此可能是在打磨一段永远执行不到非默认分支的代码）。

关键一点：`typeSizeTier`/`layoutAdaptation` 是 `PanelView.swift` 里的**同一个**计算属性（`private var layoutAdaptation: PanelLayoutAdaptation { panelLayoutAdaptation(for: typeSizeTier) }`），`EventRowView`（T15 起接线）、`MasterVolumeRow`（本条实测对象）、`PackGalleryView`（2026-07-24 补线，见下方追加）三个调用点读的是**同一份**上游值，没有第二条独立的 `@Environment` 读取路径。所以这条根因怀疑一旦坐实，**波及范围不是「主音量行」这一处，而是全部三个消费者**——只是目前只有主音量行被真机走查实际验证过失效，另外两个是根因层面的合理推断，尚未逐一复测。

> **2026-07-24 追加**：`PackGalleryView`（T4 竖排整宽行重写，commit 6c40fbc）当时完全没有接 `adaptation: PanelLayoutAdaptation`——独立的 `/codex review 6c40fbc` 揪出这处遗漏（P1：最大字号下会挤裁切包名），已修复（同日），现在也读上面那同一个 `layoutAdaptation`。这次修复本身经 `swift build`（0 error）、`swift run claudio-gui-tests`（2484/2484）与一次独立 swift-reviewer 对抗审查确认代码层面无误——但它继承的正是本条尚未解决的疑点：如果 `typeSizeTier` 在真机上真的读不到非默认值，`PackGalleryView` 的两行布局分支和 `MasterVolumeRow`/`EventRowView` 一样，可能同样永远触发不到。下一次真机排查（见下方「下一步排查建议」）只需验一次 `typeSizeTier` 本身，三个消费者不必分别走查——反之，根因一旦修好，三处会同时恢复。

**Context:** PLAN-MASTER-VOLUME.md §9 走查第 ⑪ 条实测（2026-07-14，本机 macOS 26.5.1，`swift build -c release` 出的 ad-hoc `Claudio.app`）。按 Acceptance 要求本轮**未修改任何 Swift 代码**，只如实记录现象。下一步排查建议：① 确认 `PanelView.swift` 的 `typeSizeTier` 具体读的是哪个 SwiftUI/AppKit API；② 若确认是 `@Environment(\.dynamicTypeSize)`，查它在纯 `LSUIElement` + `NSPopover` 宿主下是否真的桥接系统「文字大小」偏好（可能需要显式监听 `NSApplication` 的辅助功能通知或改读 `NSApplication.shared.effectiveAppearance`/`NSFont` 的等价系统 API）；③ 有其它 macOS 系统 app（如 Finder/Notes）在同一台机器同一个系统偏好下是否表现出字体变化，作为「这是 macOS 平台限制」还是「只有 Claudio 没接对」的判据；④ 根因修好后，`EventRowView`/`PackGalleryView` 也各自需要一次真机复测，不能只验主音量行就假定另外两个也好了。

**Effort:** M
**Priority:** P1（D17/D44 是已拍板的验收决议，真机验证不通过意味着「阶段 D 已交付」这句话目前不成立；范围已从「主音量行」扩到全部三个 Dynamic Type 降级消费者，优先级不降）
**Depends on:** 先查清 `typeSizeTier` 读的具体 API 再定修法；可能与上一条「`DynamicTypeSize → PanelTypeSizeTier` 映射用裸 `default:`」共用一次修复窗口；修好后 `EventRowView`/`PackGalleryView` 需要各自的真机复测（目前只有主音量行被验证过失效）

### PackCardView 的 CC0 徽标标签已修，但子槽图标与 native VoiceOver 仍待验证

**Status（2026-08-19）：** 部分完成。CC0 徽标的 VoiceOver 标签已在 `d6dafe8` 后修复；子槽图标的可访问性归属以及真实 macOS VoiceOver 行为没有装机实测，不能按源码或 harness 结果关闭。

**What（原文，2026-07-11 pre-T4/T5 组件形态）：** `PackCardView` 的 `eventGrid` 每个字形都 `.accessibilityHidden(true)`（已由卡片自身 `accessibilityLabel` 汇总），但 `statusLine` 的 `xmark.circle.fill` +「文件丢失」、`CC0` 徽标、`N/4` 计数都**未**隐藏，可能作为冗余/自动生成 label 的 VoiceOver 停靠泄漏；且 `CC0` 根本没进 `accessibilityLabel`，VoiceOver 用户完全听不到「这是 CC0 包」。

**现状（2026-07-24）：** `eventGrid`/`statusLine` 是 T4/T5（竖排整宽行）之前的旧组件形态，今天的 `PackCardView`（`PackGalleryView.swift`）已经是 `metaSlot`/`trailingSlot`/`brokenStatusRow` 三槽结构，原文点名的两个属性名已不存在，需要按今天的形状重新判断：

- **CC0 未播报半 —— 已修。** `d6dafe8` T5 引入的 `slots.license`（CC0 / `.none`）此前只喂 `metaSlot`（视觉），没喂 `accessibilityLabel`（听觉）——`/codex review d6dafe8` [P2] 抓到同一个洞。修法：把 `metaSlot`/`accessibilityLabel` 收口到同一个 `private var metaSlots: PackRowMetaSlots` 计算属性上（单一来源，两个读者），`accessibilityLabel` 追加「，CC0 授权」后缀（`card.isSelected` 与 `.broken` 分支同样生效，`.broken` 因 `packRowMetaSlots` 本身对 `.broken` 恒返回 `.none` 而正确地不播报）。`swift run --package-path gui claudio-gui-tests` 2494 项全绿（无回归，`metaSlots` 只是既有 `packRowMetaSlots` 纯函数的一层薄读取，纯函数本身已被 `PackGallerySuite` 覆盖）。
- **子槽图标未 `accessibilityHidden` 半 —— 结构已变，很可能不再是问题，但未验证。** 原文的担忧是「图标会作为冗余/未标注的 VoiceOver 停靠泄漏」——这在 `EventRowView` 是真实风险，因为那一行是 `.accessibilityElement(children: .contain)`（同一行里 fileNameMenu/试听/静音三个**各自独立可达**的控件，`.contain` 故意不合并，所以每个纯装饰 `Image` 都得手动 `.accessibilityHidden(true)` 才不会冒出来）。而今天的 `PackCardView` 整行是**一个** `Button(action: onSelect)`，直接在 Button 本身挂 `.accessibilityLabel(accessibilityLabel)`——SwiftUI 对 `Button` 的默认无障碍行为就是把它折叠成单一元素（不像 `.contain` 那样让子视图各自可达），所以 `metaSlot`/`trailingSlot` 里的 `Image`/`Text` 大概率本来就不会被 VoiceOver 单独枚举到。但这是框架默认行为的推理，不是设备实测——本机没有 Xcode/VoiceOver 可验（同「T15 真身面板」那条的天花板）。如果之后哪次真机走查发现确实冗余播报，再补 `.accessibilityHidden(true)`。

**Why:** 均无功能风险，纯 VoiceOver 体验。CC0 半已随 `d6dafe8` 后续修复补齐；子槽图标半保留观察，不阻塞。

**Context:** T14/T15/T16 pre-landing 评审（2026-07-11，a11y-architect，confidence 5）原文；`/codex review d6dafe8`（2026-07-24）独立命中同一个 CC0 缺口并已修。

**Effort:** ~~S（CC0 半）~~ 已完成 / XS（子槽图标半，若日后需要）
**Priority:** ~~P4（CC0 半）~~ 已关闭 / P4（子槽图标半，观察）
**Depends on:** None

### 当前包目录被删时画廊不生成 broken 当前包卡片，selected 卡片直接消失

**What:** `PackGallery.swift`（`availablePacks`/`packCards`）只枚举磁盘上真实存在的包目录。若 `config.selectedPack` 指向一个已被删除的包，当前包不在 `availablePacks` 里，于是 `packCards` 里没有 `isSelected` 卡片；用户看到的是全 unmapped 事件行 + 一个没有"当前项"的画廊，而不是一个可理解的"当前包坏了"状态。

**Why:** 静默丢失当前包卡片，与 DESIGN.md"真打包错误不被伪装成正常静默"的取向不符——用户无法从 UI 看出"你选的包不见了"。修法：把安全化后的 `config.selectedPack` 并入候选 ID 集合，即使目录不存在也走 `buildPackCard` 生成一张 `.broken(reason: "声音包目录未找到")` 的 selected 卡片。

**Context:** codex review（2026-07-11，commits e4dd25f/6b9cb66）P2。需同时想清楚：broken 当前包的事件行该显示什么（当前 `packCoverage` 对无法解析的包已回落全 `.unmapped`，见 `CoverageState.swift` 注释），卡片层与行层对"当前包缺失"的表达要一致。

**Effort:** S
**Priority:** P3
**Depends on:** None

### ManifestBindError 的两个失败态没有「怎么修」的出路，且绑定失败会留下孤儿文件

**What:** `config.json` 的每一条 fail-closed 原因都带 `configRebuildHint`（「手工改这个键，或删掉文件让 claudio 重建」），而 `ManifestBindError.manifestUnreadable` / `.writeFailed` 的文案只说了「读不动 / 写不进」，没有任何下一步；代码里也没有任何路径能重建 / 修复一个用户包的 manifest.json。叠加已知的「绑定失败留孤儿文件」（音频已拷进去、manifest 没更新），用户在那个包上就被永久卡住，而且一旦那条 toast 消失，磁盘上再没有任何证据。

**Why:** 与 config 侧「fail closed 必须给出路」是同一条原则，只是 manifest 侧没跟上。

**Context:** 2026-07-11 `/ship` 九路评审（红队）。修法：给这两个 case 补可执行 hint（对齐 `configRebuildHint` 的形状），并让 doctor 或面板能提示「这个包的 manifest 坏了，重装 / 重建它」；孤儿文件在 `.writeFailed` 时回滚删除。（原「绑定失败留孤儿文件」P4 条目并入本条。）

**Effort:** M
**Priority:** P3
**Depends on:** None

### 试听（`NSSound.volume`）与真实播放（`afplay -v`）的增益曲线是否一致，未经证明

**What:** 主音量滑块落地后，面板的「试听 ▶」会用 `NSSound.volume` 施加 `master_volume`，而真实 hook 播放走 `afplay -v`。两者**同为 0…1 标量**（`NSSound.h:65` 明确 `volume` 是单个 sound 的音量、范围 0…1、不影响系统音量；`afplay -h` 只说 `-v/--volume VOLUME set the volume`），但**没有任何文档说明二者的增益曲线（线性振幅 vs 感知/对数）相同**。

**Why:** 如果曲线不同，同一个 `master_volume` 值下「试听听到的响度」与「真实提示音的响度」会有落差 —— 用户按试听调好的音量，实际用起来偏大或偏小。今天两者都极可能是线性振幅乘子（这是这类 API 的常规），所以风险低；但它是一个**未验证的假设**，不该被当成已知。

**Context:** 2026-07-11 `/plan-eng-review` 的 Codex 外部声音提出（Claude 侧未想到）。修法两条，二选一：① 真机 A/B 实测两条路径在同一 `master_volume` 下的实际响度，一致则把结论写进 `Volume.swift` 的注释（把假设升级成事实）；② 若不一致，试听改走 `afplay -v` 本身（复用 `AfplayVolume.afplayArgument`，与真实播放路径逐字相同）—— 代价是引入进程 spawn 延迟与一个新失败模式（afplay 缺失），故不作为默认选项。

**Effort:** S
**Priority:** P3
**Depends on:** 主音量滑块落地（在那之前这条不可观察）

### StateGalleryView 没有整面板（PanelView）帧，路由态零仓库内视觉验证

**What:** `StateGalleryView` 的四个族全是子视图帧，从不渲染 PanelView。于是 D23 定稿引入的三个面板级路由态（`.needsPack` 空态「先选包」/ `.malformed` / `.unwritable` 诚实失败态）落地后在仓库内没有任何视觉真相源 —— 而 DESIGN.md:161 声明「视觉真相源 = 仓库内 state gallery」。

**Why:** 这三个态恰恰是最难手动复现的（要删 / 改坏 `~/.claudio/config.json`）。目前由 PLAN-MASTER-VOLUME §5.2 走查 ⑫⑬ 真机兜底，可接受但依赖人肉。

**Context:** 2026-07-12 mockup 展示板议题 ②，用户授权拍板为 **D38**：主音量的 `MasterVolumeState` 族照常进 gallery（展示板 §2 即规格）；整面板 `PanelRouteState` 族因需要给 gallery 引入一类全新宿主（渲染整个 PanelView + 假 config 环境）而**不随主音量方案做**，登记于此。展示板 §4 的三帧可作将来实现时的参照。

**Effort:** M
**Priority:** P3
**Depends on:** 阶段 A′（路由态本身落地之后才有东西可画）

### `ClaudioGUI` 整个 target 在 harness 里一行都跑不到（视图层接线零回归网）

**What:** `claudio-gui-tests` 只依赖 `ClaudioGUICore` + `ClaudioCore`。`ClaudioGUI` 是带 `@main` 的 **executableTarget**，Swift 里 import 不了。于是整棵 SwiftUI 视图树上的每一行接线，对这套测试都是不可见的。

**Why:** T17 的 diff 评审实测了两次变异，**两次都全绿**：① 删掉 `PanelView` 里那句 `.onChange(of: onboardingViewModel.state) { refresh(); … }` —— 也就是让「接管成功」真正兑现的那一行（没有它，用户在成功的那一秒看到的是四行「未配置」+ 空画廊）—— 652 项测试全绿、release 构建零告警；② 把 `actionRunner` 改回可选 + 静默 guard（= 逐字重建 T17 之前那个死 CTA）—— 652 项全绿，唯一信号是一条无关的 unused-variable 警告。**两次变异都重新制造了 T17 要修的那个 bug，绿灯一次都没灭。**

**Context:** 2026-07-12 T17b diff 对抗评审。当前的缓解是 `ViewWiringSuite`（读源码文本的绊线）—— 它挡得住「顺手删掉 / 重构漏掉」，但**证明不了那行代码做对了，只能证明它还在**。真正的修法：把 `ClaudioGUI` 的视图拆进一个可被 import 的 library target（`ClaudioGUIViews`），executable 只剩 `@main` + AppDelegate；或引入 ViewInspector。前者不需要新依赖，且与本仓库「视图里不留判定逻辑」的既有纪律同向。

**Effort:** M
**Priority:** P2
**Depends on:** None

### state gallery 的旧 `.running(.disconnect)` 记录已由集成目的页替代

**Status（2026-08-31）：** 已关闭。集成连接动作已迁入统一 Settings 的
`IntegrationsSettingsDestinationView`；生产状态由 `HostIntegrationUserAction.disconnect` 和
`IntegrationDestinationModel` 投影，gallery 新增固定的 `workbuddy.disconnect-in-flight` production
frame。旧 `OnboardingActionState` 的 `.running(.disconnect)` 仍保留在明确标注为 Legacy 的历史归档中，
不再声称它是当前生产画面。

**Boundary:** 本次保留 onboarding/Panel 的历史 fixture 与其穷举测试，不把已退役的 action enum 重新接回
生产连接路径；新 frame 覆盖的是当前真实集成目的页的断开中状态。

**Effort:** S
**Priority:** P3
**Depends on:** None

### in-flight 期间 onboarding 的键盘焦点无处可去（当前是「诚实的空」，不是想清楚的答案）

**What:** 一个 `.takeOver` / `.disconnect` 跑到一半时，两颗 CTA 都 `.disabled`。`applyFirstFocus()` 于是拿 `ctaOperable: false` 去算焦点序，而 onboarding scope 里除了这两颗按钮**没有别的候选**（失败行此刻不存在 —— `runDiskAction` 一开跑就把 actionState 换成 `.running`）→ `panelFirstFocusTarget` 返回 `nil` → `focusedTarget = nil` → SwiftUI 的 `@FocusState` 置 nil 会 resign first responder，光标整个消失。

**Why:** `PanelView` 那段 `.onChange(of: actionState)` 的注释白纸黑字说这次改动就是为了「没人把焦点接走的话，键盘用户按完空格就无处可去了」—— 而实现出来的结果正是「无处可去」。测试也把这个行为钉成了断言（`panelFirstFocusTarget(scope, ctaOperable: false) == nil`），而那条断言的失败文案写着「caret 必须有人接管，而不是悬在那儿」。

**但这不是一个纯 bug**：in-flight 期间那张卡上**确实没有任何可操作的东西**，把光标指向一颗禁用的按钮同样是撒谎。这是一个真实的产品取舍（① 保持焦点不动，让它停在那颗已禁用但仍在屏幕上的按钮上，AppKit 的 key loop 会自己跳过 disabled view；② 让正在跑的那颗按钮保持可聚焦但不可激活，配 `.accessibilityValue("正在接管…")`；③ 把焦点交给面板容器）。需要拍板，不该由评审代劳。**运行态面板**已由 T7 的 `.manageSounds` 接过无条件锚点：它在四种 configState 恒渲染且 in-flight 恒可操作，零行零卡的 `.needsPack` 也返回 `.manageSounds`；`.malformed`/`.unwritable` 则仍由视觉更靠前的 `.configReveal` 领焦点。运行态因此重新保证非 nil，本条只讨论 onboarding 卡，二者独立。

**Context:** 2026-07-12 T17c（Swift 专项 + 设计专项独立指出）。T17c 已修掉相邻的注释腐烂（`panelFirstFocusTarget` 的 doc 此前写着「Returns nil only for a genuinely empty order」，那句话在 `ctaOperable` 落地那一刻就是假的）。

**Effort:** S
**Priority:** P3
**Depends on:** None（需要先拍板取哪种行为）

### `DiskOnboardingActionRunner` 用 `Task.detached` 在 Swift 协作线程池上跑阻塞式磁盘 I/O

**What:** `await Task.detached(priority: .userInitiated) { performOnboardingDiskAction(...) }.value` —— 闭包体是纯同步阻塞 I/O（复制一个 universal 二进制 + 整个声音包目录 + flock + 原子写 settings.json）。

**Why:** 协作池的线程数按核数固定，Swift Concurrency 的前向进度假设是「线程永不阻塞」。菜单栏 app 的 Task 并发度低、`flock` 是 `LOCK_NB`（不会长时间等锁），所以今天不致命 —— 但这是教科书级反模式，一旦将来有后台探测 / 定时刷新 / 更多并发动作，它会真的咬人。

**Context:** 2026-07-12 T17c（Swift 专项 + 红队独立指出）。修法：换成 GCD 逃生舱 —— `await withCheckedContinuation { c in DispatchQueue.global(qos: .userInitiated).async { c.resume(returning: performOnboardingDiskAction(action, environment: environment)) } }`。行为一字不变，阻塞的是一条可增长的 GCD 线程而不是协作线程。

**Effort:** S
**Priority:** P3
**Depends on:** None

### 「下面的声音包」与告知行的位置断言，在 onboarding 卡上都是假的

**What:** `SetupNotice.repairedDeadSelection` 的文案里有一句**关于布局的断言**：「你随时可以在**下面的**声音包里换成别的」。它由 `PanelView.operationalPanel` 的排布兑现（提示行排在 `PackGalleryView` 之前），并由 `ViewWiringSuite` 的顺序断言钉死。**但 `OnboardingView` 那张卡也渲染 `ActionNoticeRow`（`OnboardingView.swift:125`），而那张卡既没有声音包画廊、也没有四行事件覆盖度** —— 那句「下面的声音包」在它上面指向的是空气。

**Why:** 今天不会伤到人，但理由是「这条路径不可达」：一次成功的 `takeOver` 必然把 state 推成 `.installed`，于是每一条告知都诞生在运行态面板那一侧，onboarding 卡接不住它。**而「我推理出这个格子不可达」正是这个仓库交过两次学费的那句话**（T17d 的「重开 = 看过了」、T17e 的「零包不会写 hooks」）—— 而且这张卡**之所以**渲染告知行，恰恰是因为 T17f 拒绝对不可达性做推理（「两个渲染点都无条件画」是它的结构不变式）。两条理由自己打架：要么承认它可达、给它一句站得住的文案，要么承认它不可达、别渲染。

**Context:** 2026-07-12 T17g（`/codex review 0d789dd` 自评审顺带发现）。同一轮里刻意**没有**往文案里再加一句「上面四行会告诉你哪些还缺」，就是不想在这个洞里再多埋一条位置断言。修法二选一：① 把告知行做成一个自带上下文的组件（不假设自己上下有什么），文案去掉方位词；② 让 `onboardingVisibleNotices` 在 onboarding 卡上恒为空，并用一条测试把「告知只可能诞生在 `.installed`」钉死 —— 那等于正式承认这条不可达，就得配一条会变红的断言，而不是一句注释。

**Effort:** S
**Priority:** P3
**Depends on:** None

## 前端设计冗余（2026-07-15 视图层通读审计）

> 一次针对 `gui/Sources/ClaudioGUI/` 全部 14 个视图文件（3598 行）的冗余专项。判据是 DESIGN.md：
> **凡是 DESIGN.md 定义了「一个」组件 / 一档 token，而代码里存在两份及以上互不相认的实现，即记一条。**
> 下面仍保留的三条具体开放项按「同一个东西被写了几遍」排序，不按修复代价。
> 已有的同族条目「DesignTokens 规范化 / 生成式 token 模块归并延后」（P3）不在此重开。

### `typeScale` 是一个被手工穿线的环境值 —— 6 个视图各声明一份，40 处手写乘法，漏一处就静默不跟随 Dynamic Type

**What:** `gui/Sources/ClaudioGUI/` 里**每一个**渲染文字的视图都各自声明了同一行：

```swift
@ScaledMetric(relativeTo: .body) private var typeScale: CGFloat = 1
```

`PanelView` / `EventRowView` / `OnboardingView` / `AudioDropZoneView` / `PackGalleryView` / `MasterVolumeRow` —— 六份。然后每一处字号都手写成 `.font(.system(size: 11 * typeScale))`，全树 **40 处**这样的乘法。

更糟的是 `ActionFailureRow` / `ActionNoticeRow`：它们是独立的 `struct`，拿不到父视图的 `@ScaledMetric`，于是 `typeScale: CGFloat` 被做成了**构造参数**，由 `PanelView` / `OnboardingView` 在 4 个调用点手工传下去（`typeScale: typeScale`）。一个本该是环境值的东西，正在被当参数搬运。

**Why:** 这是一条**只会静默失败**的约束。新加一个视图、忘了声明 `typeScale`，或者新加一行 `Text` 忘了乘 —— 编译过、测试全绿、真机上那行字**就是不跟随系统「文字大小」**。而这个失败模式**已经真的发生过一次**：TODOS.md 上面那条「主音量行的 Dynamic Type 三级布局在真机上完全不生效」（2026-07-14 走查 ⑪ 实测失败）就是同一个病根的另一半 —— 那条是**布局**没跟随，这条是**字号**没跟随，两者共享同一个根因：**Dynamic Type 在这棵树里靠人手工接线，没有任何结构强制它。**

`ContrastSuite` 也守不住这一条：它是纯 hex 数学，看不见 `.font()`。

**Context:** 2026-07-15 视图层通读审计。修法：一个 `.claudioFont(.rowLabel)` 式的 `ViewModifier` + 一个字号 token 枚举（见下一条：那个枚举**同时**是收敛字号阶梯的载体），`@ScaledMetric` 只在 modifier 内部声明一次，视图侧再也写不出「忘了乘」这种代码。这与上面那条「DesignTokens 规范化 / 生成式 token 模块归并延后」（P3）是**同一次重构**的两半 —— 那条管颜色 token，这条管字号 token（而字号 token 今天**根本不存在**）。合并考虑。

**Effort:** M
**Priority:** P2
**Depends on:** None（与「DesignTokens 规范化」合做最划算）

### 字号阶梯：原「代码在用 8 档」描述已过期，但固定字面量与 DESIGN.md 矛盾仍待收口

**Status（2026-08-19）：** 部分完成。当前持久化接口字号已收敛为四档；但字号实现仍有 `9` / `11.5` / `12.5` 等固定字面量，且 `DESIGN.md` 仍有两处阶梯定义冲突。以下 What / Why 按当前残余问题理解，不再把旧的「8 档」计数当作事实。

**What:** DESIGN.md「字号阶梯」表里，App 内只有四档：**面板标题 14–15 · 行标签 13 · 次要/状态 11 · 数据/事件 id 10–12**。

代码实际在用：**9 · 10 · 11 · 11.5 · 12 · 12.5 · 13 · 15** —— 八档。越界的三个：

- **`11.5`** —— `AudioDropZoneView` 的 `rejectRow` + `successRow`。不在任何一档上。
- **`12.5`** —— `AudioDropZoneView.promptLabel` + `OnboardingView` 卡正文。**但这一个不是代码的错**：DESIGN.md「State Components · onboarding 卡」白纸黑字写着「正文 `text-2` **12.5**」—— 也就是说 **DESIGN.md 的字号阶梯表与它自己的 State Components 节对不上**。要么阶梯表漏了一档，要么 State Components 越了界，得拍板一个。
- **`9`** —— `ActionFailureRow.messageRow` 的 chevron，低于阶梯最小档。而 `PackCardView.statusLine` 里有一句现成的注释：「此前这三行都用 9pt，**低于阶梯的最小档**」，并已修掉 —— **同一个 9pt 在另一个文件里活得好好的，那次修复没走到底。**

**Why:** 不是审美洁癖。字号阶梯是 DESIGN.md 唯一一处对「文字层级」的规定，而八档意味着「次要文字」这一个层级今天有 11 / 11.5 / 12.5 三种大小同屏 —— 用户看到的是三种「同等重要」的文字长得不一样大。且这三个越界值全都**没有任何测试或断言守着**（`ContrastSuite` 只管颜色对比度，不看字号）。

**Context:** 2026-07-15 视图层通读审计。修法与上一条（字号 token 枚举）是**同一刀**：枚举的 case 就是 DESIGN.md 的档位，越界的字号在写枚举的那一刻就没有 case 可用。**但必须先拍板两件事**（不该由实现者代劳）：① `12.5` 进不进阶梯表（= DESIGN.md 自身冲突的收口）；② `11.5` 与 `9` 分别收敛到哪一档。

**Effort:** S（收敛本身很小；拍板是前置）
**Priority:** P3
**Depends on:** 需先拍板 ①②

### 「拖一个音频文件到这儿」的旧虚线规格条目已过期，当前 drop targets 需按 Sound Packs Window + EventRowView 重写

**Status（2026-08-19）：** 需重写。原文依赖已移除的 `AudioDropZoneView`；当前仍可讨论 `SoundPacksWindow` 与 `EventRowView.importAffordance` 的统一规范，但不能直接按原文执行。

**What:** 面板里有两个 drop 目标，视觉语言是两套：

| | 圆角 | 线宽 | dash | hover |
|---|---|---|---|---|
| `AudioDropZoneView`（面板底部大区） | 10 | **1.5** | **[4, 3]** | 边框转 clay + `clay-soft` 底 |
| `EventRowView.importAffordance`（行尾「未配置 / 文件丢失」） | 6 | **1** | **[3, 2]** | 边框转 clay + `clay-soft` 底 |

DESIGN.md 只定义了**前者**（「拖入 drop-zone：虚线 **1.5px** `hairline-strong` + radius 10」）。后者的 1px / `[3,2]` / radius 6 **没有任何 DESIGN.md 背书** —— 它是第二套虚线语言，凭空长出来的。

**Why:** 两者是**同一个语义**（「往这儿拖一个音频文件」），hover 反馈也已经是同一套（边框转黏土 + `clay-soft` 底 —— 这一半是对的，说明当初确实有意对齐）。虚线规格却各写各的。危害有限（不影响可用性，也不违反任何对比度约束），但它是「同一个东西两份实现」这条主线上最便宜的一条：一个 `dashedBorder(radius:)` modifier 就收掉了。

⚠️ 注意 radius 6 vs 10 **可能是对的** —— DESIGN.md 圆角阶梯里「控件 / 芯片 = 6，卡片 / 行 = 10」，行尾那个小按钮确实更像「控件」而非「卡片」。所以要收的是**线宽与 dash pattern**（两者没有任何理由不同），圆角保留两档、但要在 DESIGN.md 里把「行内小 drop 目标 = 控件档 radius 6」这句话补上，让它从「凭空」变成「有据」。

**Context:** 2026-07-15 视图层通读审计。

**Effort:** XS
**Priority:** P3
**Depends on:** None

### 视图层的绊线以**散文**形式存在 —— 本轮实测腐烂 3 处，而它此前已经踩响过至少 4 次

**What:** `gui/Sources/ClaudioGUI/` 的注释占比：`PanelView.swift` **56%**（894 行里 508 行注释 / 348 行代码）、`MasterVolumeRow.swift` **53%**、`EventRowView.swift` 44%。整个视图层的 SwiftUI 代码只有约 1200 行，被约 1100 行散文包着。

**这一条不是在说「注释太多」。** 那些散文里装的是这个项目最贵的资产——「为什么**不能**那样做」的负空间知识（tile 底为什么不能用 `surface-2`、`.tint` 为什么不能自绘、告知行为什么必须排在画廊之前、`say()` 为什么不能从 `switchPack` 再调一次）。删掉它们是自杀。

这一条说的是：**那些散文里混着三种载体完全不同的东西，而今天它们长得一模一样，于是没有人能分辨哪一句还活着。**

| 类别 | 它是什么 | 正确的载体 | 今天的载体 |
|---|---|---|---|
| **A** | 「这五处必须一致」「这棵树里没有动画」 | **编译期结构**（一个共享组件 → 「一致」不再需要被断言，它成为无法违反的事实） | doc comment |
| **B** | 「告知行必须排在画廊之前」「`.idle` 那一格必须先 `reload()`」 | **行为断言**（真磁盘 / 真状态机） | doc comment（+ 部分 `ViewWiringSuite` 的文本 `contains()`） |
| **C** | 「走查 ⑨ 每次动控件行都必须重跑」 | **会过期的 checklist**（结构上测不到——`ContrastSuite` 是纯 hex 数学，`ClaudioGUICore` 连 SwiftUI 都不 link，看不见 `NSSlider` 填了什么色） | doc comment |

**Why —— 腐烂不是风险，是已经发生的事实，而且反复发生：**

*本轮实测新发现的 3 处（全部是 A 类，全部在说同一件事）：*
1. `EventRowView.importErrorRow` 的注释：「reused **verbatim** from `AudioDropZoneView`'s own `rejectRow(_:)`」
2. `ActionFailureRow` 的注释：「与 `PanelView` 的 `errorNotice(_:)` 和 `AudioDropZoneView` 的 `rejectRow(_:)` **完全一致**」
3. `PanelView.errorNotice` 的注释：「**identical to** `AudioDropZoneView`'s `rejectRow(_:)` and `EventRowView`'s `importErrorRow(_:)`」

三句话都是假的（图标字号、文字字号、spacing 三处已漂移——详见本节第一条）。

*而在此之前，同一种腐烂已经踩响过至少 4 次，每一次都被如实记在案：*
- `PanelView.swift:62-75` ——「本视图树零动画，所以不读 `accessibilityReduceMotion`，**这条注释就是绊线**」。T17c 往树里加了两颗 spinner，**跨过了它**，既没 gate 也没回来改。注释自己写着：「一条自己被跨过去还留在原地的绊线，比没有绊线更坏。」
- `DESIGN.md:147` + `DESIGN.md` Decisions Log 2026-07-12 那一行 —— **两处**都在引用上面那条**已被推翻**的绊线原话，作为「控件行不得加动画」的理由。2026-07-14 才更正。
- `MasterVolumeRow.swift:195-198` + `DESIGN.md` Decisions Log —— **两处**都写着走查 ⑨「That run is still owed / 本轮重新欠账」，而那一跑**已经跑完了**。注释自己写着：「话写在跑之前，跑完没人回来改……它对一条**真**纪律喊了狼来了。」
- `PanelView.swift:603-604` —— 「`runSetupNoticeSuites` 钉住了『文案里有下面的声音包』这一半；另一半——**它真的在下面**——只有这条注释和你的眼睛守着。」这是一条 B 类不变式，主动声明自己没有断言背书。

**而已经存在的那次「把绊线变成测试」的尝试，本身也在同一个坑里。** `ViewWiringSuite` 是读 `.swift` 源码文本做 `contains(字面量)`——它的 doc comment 自己列了四条失效模式，其中两条是**实测**的：

- 第一版 `contains("Bundle.main")` **被一句注释假绿**（注释里的字面量与真调用同形）
- 「把『全量 refresh』钉成 `contains("refresh()")`，而 `refresh()` 在那个文件里出现 **37 次**，那个合取子**恒真**」
- 「那种断言能证明**修饰符在**，证明不了**闭包体做了什么**」
- 同类呈现级接线问题仍受文本绊线的覆盖边界限制。

所以修法**不是**「把散文改写成 `contains()` 断言」——那只是把一种脆弱换成另一种（探针，不是围栏：认不出的东西一律绿）。

**Context:** 2026-07-15 视图层通读审计（本条是元层条目：它是本节前三条具体开放项的**共同成因**，不是第六个并列现象）。根因是 `ClaudioGUI` 是 `@main` executableTarget，harness **一行都 import 不到**——所以视图层的每一条不变式，要么下沉进 `ClaudioGUICore`（已做过多次：`PanelConfigController` / `panelAnnouncement` / `panelFocusOrder` / `previewClaimsActionFocus`，每一次都是被一次真实的翻车逼出来的），要么就只能是一句话。

**修法（按顺序，不是三选一）：**
1. ✅ **已执行（2026-07-15）—— A 类优先，因为它最便宜也最彻底**：共享 `FailureRow` 与 `PanelHeader` 已落地。那三句「完全一致」的注释**不再需要存在**——七份变一份，「一致」从一句需要被守的话变成了一个**编译期事实**。**这是唯一一种不会腐烂的绊线。**

   **实践中学到的两件事，都不在原计划里：**
   - **A 类修复会顺手带走它没瞄准的 bug。** `StateGalleryView` 那份副本的字号是裸 `size: 11`、没乘 `typeScale`（展柜里那行字从不跟随 Dynamic Type）。没有人发现过它，也没有人修过它——它是被合并**免费**带走的（组件自带 `@ScaledMetric`）。这是 A 类相对 B 类（补断言）的额外红利：**断言只能证明你想到的那条，组件把你没想到的那条也一起收了。**
   - **而 A 类修复自己也会犯同一种病。** 抽组件前我 grep 的是**函数名**（`rejectRow` / `errorNotice` / `importErrorRow`）——一张白名单——于是漏了两份（一份没有独立函数名、一份名字不一样）。**能找全它们的判据是视觉特征本身（`xmark.circle.fill`），不是名字。** 围栏按「它长什么样」围，不按「它可能叫什么」猜。
2. **B 类下沉**，沿用仓库已经走了五次的那条路（搬进 `ClaudioGUICore` + 真行为断言），而不是加更多 `contains()`。
3. **C 类必须换载体**：真机走查那几条（⑨ `.tint` 是不是黏土、⑪ Dynamic Type）结构上测不到，它们**只能**靠人。但它们今天散落在三个文件的 doc comment 里，且已经被证明会写成过去时。给它们一个**单一的、带时间戳的走查清单**（`docs/` 里一份，每次 `/ship` 前跑，跑完记 commit sha）——ENGINEERING.md §9 已经有 15 条真机走查的雏形，把注释里的纪律**收编进去**，别让它们继续住在代码旁边。

**Effort:** M（普查 + 分类是 M；A 类的两次抽组件已完成；C 类收编是 S）
**Priority:** P2
**Depends on:** None

## 写盘原子性：这一刀（`/codex review 3af8d5f` 的修复）**没**收进去的那几条

### `.atomic` 不是掉电安全 —— 全仓没有一处 `fsync` / `F_FULLFSYNC`

**What:** `Data.write(options: .atomic)` = 同目录临时文件 + `rename(2)`。`rename` 对**目录项**是原子的，
所以**进程被 kill** 之后终态只有「没有」和「完整」两种 —— 这一半是真的。但 POSIX **不**保证掉电时临时文件的
**数据块**先于那条目录项落盘：APFS 实践上大多会排序，规范上不保证。于是掉电之后，一个**目录项已经改好、
内容却是零长度 / 半截**的 `.claudio.bak` 在原理上是可能的 —— 而那正是「一次性备份 + `fileExists` 闸门」
最怕的东西（它认不出残缺）。

**Why:** 行为风险低（要真正撞上得掉电撞在那个毫秒窗口里），但**措辞风险是满的**：commit `3af8d5f` 的正文与
它写进生产注释的那段散文，都白纸黑字声称了「掉电」。那是这个仓库栽了十五次的同一个病（措辞比覆盖范围大）。
注释已经改成实话（只声称 kill），但**能力**本身还没补。

**可能的修法:** 写完临时文件后 `fcntl(fd, F_FULLFSYNC)`，`rename` 之后再 fsync 一次父目录 —— 这要绕开
`Data.write(options:)`，自己拿 fd 写。代价：`.claudio.bak` 那一处（一次性、路径短）值得；`config.json` /
`play.state` 那种高频写不值得（F_FULLFSYNC 在 macOS 上是真的慢）。所以它**不是**一条全仓不变量，
而是一条「哪些文件配得上掉电安全」的分级政策 —— 那需要先想清楚，不该混在一次 bugfix 里。

**Effort:** M（自己拿 fd 写 + 一条分级政策 + 台账）
**Priority:** P3（不阻断发布：注释已经不再撒谎，而真实风险窗口极窄）
**Depends on:** None

### 一份 0600 的 `settings.json`，备份成了一份 0644 的 `.claudio.bak`

**What:** 本机实测（Darwin 25.5, umask 022）：`Data.write(options: .atomic)` 写到一个**已存在**的目标会保留
它原来的 mode（所以 `settings.json` 那一处 `:618` 没问题），但写一个**新**文件时 mode 走 umask → 0644。
而 `.claudio.bak` **永远是新文件**（`!fileExists` 闸门保证了这一点）。于是一个把 `~/.claude/settings.json`
chmod 到 0600 的用户（它可以装着 API key —— hook 命令、`env` 段），拿到的备份是**全世界可读**的。

**Why:** 这不是这一刀引入的（上一版的非原子 `write(to:)` 同样走 umask），但它是**这一刀的邻居**，而且是
一次真实的权限放宽。修法本身很短：备份写完之后按源文件的 mode `setAttributes` 一次。

**Effort:** S（三行 + 一条断言）
**Priority:** P2（安全相关，但需要用户自己先 chmod 过 —— 不是默认路径）
**Depends on:** None

### `~/.claudio/bin` 用 `createDirectory` 无显式 mode 建成 —— 松 umask 下组/世界可写，而里面的二进制每个事件都被 exec

**What:** 本机实测（Darwin 25.5）：`copySelfToFixedLocation` 里 `createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)`（`Setup.swift:677`）**不传 `attributes:`**，于是新建的 `~/.claudio/bin`（及 `~/.claudio`）的 mode 走 umask：umask 022 → 0755（安全），umask 002 → **0775（组可写）**，umask 000 → 0777。而 `~/.claudio/bin/claudio` 正是 `settings.json` 四条 hook 每个 Claude Code 事件都 exec 的那个二进制。目录若组/世界可写，同组或本地另一个用户就能替换它（或抢先占用可预测的 `.claudio.tmp-<pid>` 暂存名）→ 下一个事件即以受害者身份**执行任意代码**。本分支的原子发布只加固了「崩溃/kill 时的完整性」，没有约束它发布进去的那个目录的**权限**。

**Why:** 默认 macOS umask 是 022 → 0755，所以**默认单用户 Mac 打不到**；触发需要「非默认松 umask（MDM / 某些 dotfiles 会设 002）+ 多用户机 + 同组敌手」。但代价是代码执行，量级高于它的孪生项。修法很短：`~/.claudio` 与 `~/.claudio/bin` 显式建成 `0700`（`createDirectory(attributes: [.posixPermissions: 0o700])`，并对存量目录 `setAttributes` 兜底），无论用户 umask 是什么，被 exec 的二进制都不可能落在一个组/世界可写的目录里。与上一条（`.claudio.bak` 的 0644）是**同一形状的孪生**：都是「新建 filesystem 对象不传显式 mode → 继承 umask → 在一个安全敏感的位置放宽了权限」，建议一并修。

**Context:** 2026-07-13 `/review feat/lock-separation` 的 security specialist（Claude 侧，opus）实测命中，Codex 对抗评审未报。台账此前只有文件侧（`.claudio.bak` 0644），漏了目录侧这条 exec 劫持路径。

**Effort:** S（一行 `attributes:` + 一次存量 `setAttributes` 兜底 + 一条断言）
**Priority:** P2（安全相关，但默认 umask 022 已使其不可达 —— 需用户/MDM 先设松 umask + 多用户机）
**Depends on:** None

### `claudio install` 在一台从没有过 `settings.json` 的机器上，照样说「备份见 settings.json.claudio.bak」

**What:** `hooksOutcomeMessage(.installed)`（`Subcommands.swift:167`）**无条件**印出那句备份提示。而
`backupOriginalIfNeeded` 在 `originalData == nil` 时**直接 `.success(())` 返回、什么都不写**（`:572`）——
那正是「用户装了 Claude Code 但从没有过 `settings.json`」的常见全新态。于是 CLI 指着一个**不存在的文件**
说「你的备份在这儿」。

**Why:** 「假注释就是 bug」这条规矩对**印给用户看的字**只会更严。它不会弄坏任何东西，但它是一句假话，
而这个产品的整个信任叙事（onboarding 的「会搞坏我现有配置吗？」→「自动备份」）就压在这句话上。

**Effort:** S（把 outcome 带上「有没有真的写过备份」这一位）
**Priority:** P2
**Depends on:** None

### 围栏的词汇表仍是一张枚举清单 —— 真要闭合，只能上 SwiftSyntax

**What:** `AtomicWriteSuite` 的极性已经翻过来了（认不出 ⇒ 红），但它认「写盘调用」靠的仍然是一张**词法**
词汇表（`byteWritingMembers` / `byteWritingFunctions` / `pathPublishing*` / `subprocess*`，故意过宽）。
一个它**没听说过**的写盘 API（某个第三方库的 `save(to:)`、一个 `@_silgen_name` 直连的 syscall）仍然能溜过去。

**Why:** 这是这条不变量今天**唯一**的假绿通道，而且文件头已经照字面写清了它（措辞不比覆盖范围大）。
它比上一版好在：漏一个词的代价从「那类写盘永久隐身」降到了「那**一个** API 隐身」，而且过宽的词汇表让
误伤的代价只是台账里多一行。

**可能的修法:** 用 SwiftSyntax 解析 AST，把「所有函数调用的被调用方名字」整个抽出来，与一张**允许出现在
生产码里的调用名**清单比对 —— 那样「我没听说过」就真的不可能是绿的了。代价：一个新依赖 + 测试包变重。

**Effort:** L
**Priority:** P3
**Depends on:** None

## 面板 config 路由（D23 / 阶段 A′）落地后剩下的三条

### `probeConfigRewritable` 的 `.absent` 早退，不问父目录可不可写

**What:** `ConfigMutation.swift` 的 `probeConfigRewritable` 一发现 `config.json` 不存在就 `return .absent`
（「全新安装的正常状态」），**在那之前不问一句父目录让不让写**——而这一问它对**存在**的 config 是问了的
（`.unwritable` 那一支）。于是「config 缺失 **且** `~/.claudio/` 不可写」这一格会被两轴合成判成 `.needsPack`，
面板渲染「先选包」空态，用户点一张包卡 → `selectPack` 在写盘那一步才失败。

**Why:** 失败**是**如实上报的（`packSwitchError` → `errorNotice`），所以这不是静默失败，也不是撒谎——
但它把一句本可以在面板一打开就说清的话（「你的目录不让写，chmod 一下」）推迟成了一次注定失败的点击。
与 `probeSettingsWritable` 那条（本文件上一节）是**同一个形状**：探测的粒度比真正要写的东西细一级。

**Effort:** S（`.absent` 那一支 return 前补一次 `isWritableFile(父目录)`，与 `.unwritable` 复用同一句 reason）
**Priority:** P3
**Depends on:** 会改到 `doctor` 的既有输出（`Doctor.swift:379` 是它今天的另一个调用方），要同批改 DoctorSuite。

### `.malformed` / `.unwritable` 都丢掉了仍然读得出来的 `selected_pack` —— 拖拽拒绝理由、画廊高亮、VoiceOver 播报全部遭殃

**What:** `PanelConfigState.malformed(reason:)` 和 `.unwritable(reason:)` 都不带 packID，`resolvedConfig`
一律回落成 `ClaudioConfig(selectedPack: "")`。但两者都常常只坏在**别的**地方——`.malformed`：
`{"selected_pack": "lofi", "master_volume": "0.35"}`，`selected_pack` 好好的，只是 `master_volume`
是字符串；`.unwritable`：内容**必然**合法（`loadPanelConfig` 走到 `.unwritable` 分支之前，
`probeConfigRewritable` 已经跑完 `parseRewritableConfig`——顶层对象、`selected_pack` 合法字符串、
`master_volume` 数字、`events` 全布尔全部通过），坏的只是**父目录写不进去**。两种情况下
`selected_pack` 其实都读得出来，却被那句硬编码的空默认值一起扔掉。

**验证过的具体后果**（`.unwritable` 这一半，2026-07-14 `/ship` Step 11 adversarial review，Claude
子代理逐行核对源码而非只看 diff hunk 确认）：
- `AudioDropZoneView` 不像事件行那样受 `configState` 顶层路由收纳，是**无条件渲染**的。用户在
  `~/.claudio` 目录突然变只读（MDM chmod、磁盘写满、同步工具占锁——都不是内容坏）时拖一个音频进去，
  `importAudioFile` 第一道闸门 `isSafePackID("")` 判假，报的是 **「这个文件名 Claudio 不敢直接用，换个
  正常一点的名字再拖一次」**——把一个目录权限问题说成文件名问题。
- `PackGalleryView` 的选中高亮（`config.selectedPack` 比对）整卡熄灭，即便磁盘上明明有一张选中的卡。
- `headerAccessibilityLabel` 对 VoiceOver 播报空包名，而不是真实、合法的那个。

`.malformed` 那一半仍是原始 finding（拖拽拒绝理由报 `.pathTraversal`，文不对题）。`.unwritable`
这一半是**更干净的修法**：`loadClaudioConfig(from:)` 在这个分支下保证解码成功（构造上不存在
「解不出来」的可能），不需要 `.malformed` 那种「解不解得出来看情况」的判断。

**Why:** 不是静默失败（拒绝 / 空高亮都会显式渲染），是**措辞与真实原因对不上，且发生在完全非对抗性的
生产场景下**（目录权限变化，不需要任何人手动改坏 config 内容）——这个仓库反复栽在同一件事上。

**Context:** 2026-07-14 `/ship` Step 11 adversarial review（Claude adversarial subagent + Codex adversarial
两路独立命中 `.unwritable` 这一半的不同侧面，均已用实际源码核实，非猜测）。顺带发现一条更窄、优先级更低、
与本条同一处的相关缺口，先记在这里而非单开一条：`PanelConfigController.reloadConfigOnly()`（mute 成功 /
`.configOnly` 失败两条路共用）重读 `configState`/`config` 之后，`eventRows` 只重算 `enabled` 位，
`coverage` 原样带过来自旧值——如果外部一个不受锁约束的写者（`claudio use`）恰好在同一个窗口把
`selected_pack` 换掉，`config`/header 会正确显示新包，但 `eventRows.coverage` 会继续显示旧包的文件
存在性，直到下一次全量 reload。**这条不是本分支引入的回归**——`git show origin/main:.../PanelView.swift`
确认 pre-branch 的 `refreshEnabledFlags()` 就是同一个模式（`eventRows.map` 只翻 `enabled`），本分支
只是重命名+挪了地方，行为字面未变。窗口窄（需要外部 CLI 恰好在这个时间点写）、后果自限（下一次任何
一次全量刷新——重开 popover、切包成功——就会纠正），不足以单开一条，但修上面这条 packID 携带问题时
顺手看一眼这条是否也该在「新旧 selectedPack 不一致」时升级成全量刷新。

**Effort:** M（给 `.malformed` / `.unwritable` 都加一个可选 packID 字段；`.unwritable` 那一半可以直接调
`loadClaudioConfig` 拿到手，`.malformed` 那一半仍要处理「解不解得出来看情况」；牵动 PanelConfigSuite
的合成矩阵）
**Priority:** P2（从 P3 上调——`.unwritable` 这一半三处真实 UI 表面都受影响，且触发条件是完全非对抗性的
目录权限变化，比原始 `.malformed` finding 的影响面更广）
**Depends on:** None

### 单源化到「决策级」之后，`operationalPanel` 的 case→子视图 render 映射仍是手写 switch，只文本探针背书 —— 要 ViewInspector 才根治

**What:** f54d335 P1#1 把 `configState` 单源化到**决策级**：render 路径（`operationalPanel` 顶部
`switch panelModel.configState.topContent`，PanelView.swift:514）与开局焦点派生（`applyFirstFocus` 读
`content.showsEventContent` / `content.hasConfigFailureNotice`，:826/:830）现在读**同一个** `PanelTopContent`
分类 + 同两颗 `PanelConfigSuite` 单测钉过返回值的纯投影。**决策级漂移**（两条路各 key 一个不同的
state→content 映射）确实由类型堵死。但那个 `switch` 里 **case→画哪个子视图** 仍是**手写**的：没有任何
import 单测把「`.events` 分支真的画了滑块 + 四行事件」「`.configFailure` 分支真的画了带 Reveal 钮的失败卡」
钉到实际在屏幕上的控件。把 `EventRows` 误塞进 `.needsPack` 分支、或把滑块从 `.events` 分支删掉——两颗
投影仍全绿、`PanelConfigSuite` 也全绿，而 render 与 focus 已经对不上。

**Why:** 这是 `/codex review 457bff9`（2026-07-18）P2#2 的落点，也是本仓库反复自陈的那道天花板：
`ViewWiringSuite` 只能 `codeOnly()` + `contains(修饰符字面量)` 文本探针——它证明得了「那一行还在」，
证明不了「它接在对的 case / 对的子视图上」（ViewWiringSuite.swift:916-918 已如实自陈同一件事；本文件
「视图层的绊线以散文形式存在」那条同族）。**源码注释此前写「在类型层一致，不可能漂移」，比真实覆盖范围大**；
本轮已把 PanelConfig.swift 与 PanelView.swift（顶部 switch + `applyFirstFocus`）三处注释软化成「决策级封、
呈现级 render 映射仅文本探针封」，与测试注释既有的「决策层」措辞对齐。真正堵住呈现级洞只有一条路：
ViewInspector / XCTest（本机 CommandLineTools 没有，见本文件「CI 一次测试都不跑」与「`ClaudioGUI` 整个
target 在 harness 里一行都跑不到」两条）。

**Effort:** L（要么引 ViewInspector 把 `operationalPanel` 各分支渲染出的可见控件结构化断言；要么把
「每个 topContent → 该出现的控件集 + 焦点输入」抽成一个可 import 单测的展示描述符，让视图只照它渲染）
**Priority:** P3（非阻断：决策级已封，剩下的是「手写 switch 塞错子视图」这类**改错**才触发，非生产路径
自然发生；与「`ClaudioGUI` target 零回归网」「ViewWiringSuite 文本绊线只挡整行删」同族，本质是无
ViewInspector 的固有天花板）
**Depends on:** 与「`ClaudioGUI` 整个 target 在 harness 里一行都跑不到」「`ViewWiringSuite` 的文本绊线只挡得住
「整行被删」」同根，宜一并处理

---

### 诚实失败态（`.malformed` / `.unwritable` / `.needsPack`）本身的三处毛病 —— 红队 1c65215 实测，非本轮引入

**Context:** 2026-07-14。`/codex review` 两条 [P1] 修完后，对修复本身发动多视角红队（14 条 finding，8 条挺过双反驳者）。其中三条与**路由**无关 —— 它们是这三个状态**出厂就带的**，任何一条抵达它们的路（包括最老的 `.configMissing` 和 popover 重开）都会撞上。修完路由之后它们更容易被看见了，所以入册。

**1. `errorNotice` 的滤网没跟着极性一起扩 —— 同一句 reason 被印两遍**

D43 把 `.configMissing` 从 `errorNotice` 里滤掉，理由是「那张空态卡本身就是解释，再画一遍它的 description 就是重复」。滤网是硬编码的 `error != .configMissing`（PanelView.swift:559），而 `packSwitchError` 那条**零滤网**（:562）。现在 `.configReadFailure` / `.configWriteFailure` / `.lockFailed` 也会重路由到一张**自带解释**的诚实失败卡 —— 于是同一份约 90 字的修复指令，会在同一屏、两个真红 circle-x 图标下渲染两遍。D43 的判据（「卡片本身就是解释」）现在适用于三条错误，滤网却只认得一条 —— 一元白名单探针。

**Effort:** S（滤网改成「这条 error 是否已经被 configState 重路由并自带解释」的判断，而不是逐个 case 点名）
**Priority:** P2

**2. 顶部视图切换会吃掉键盘焦点 —— 而两条写路径上一处 `applyFirstFocus()` 都没有**

`configState` 从 `.operational` 翻到 `.malformed` / `.unwritable` / `.needsPack` 会把四行事件行（或用户刚按下的那张包卡）整个从视图树里摘掉，SwiftUI 随即把 `@FocusState` 置 nil。键盘 / VoiceOver 用户按完空格，光标凭空消失。`applyFirstFocus()` 只挂在 `onAppear` / `showCount` / onboarding state / actionState 四处 —— `toggleMute` 和 `switchPack` 一处也没有。**不是本轮引入**：`.configMissing → .full → .needsPack` 这条路从 D43 起就能触发同样的摘除，本轮只是把触发点从一个扩到四个。

**Effort:** M（写路径上在 configState 真的换了顶层视图时补一次 applyFirstFocus；要小心别在每次成功静音后都抢焦点）
**Priority:** P2

**3. `muteError` / `packSwitchError` 没有寿命 —— 一条过期红字能穿过每一次 popover 重开**

两条 error 都只有「下一次**成功**的同类操作」才会清（`muteError` 在 `setEnabled` 成功时清，`packSwitchError` 在 `switchPack` 成功时清）。而**刷新从不清它们** —— `reload()` / `reloadConfigOnly()` 都不碰。popover 重开做的唯一一件事是 `panelModel.reload()`（PanelView.swift:246），而 `PanelView` 由 `MenuBarController.init` 构造**一次**、活满整个进程，`panelModel` 这个 `@StateObject` 从不重建。于是：一次 `.lockBusy`（并发的 `claudio use`，早就跑完了）留下的红字，会一直挂在面板上，直到用户碰巧成功静音一次。

（`packSwitchError` 的 `init` 值已有断言守着，红队 round5；缺的是**寿命**，不是初值。）

**Effort:** S（刷新时按新的 configState 重新裁定：错误还成立吗？或给 error 打时间戳/序号）
**Priority:** P2

**⚠️ 本轮**已经**关掉的，别重复记账：** 失败路径改走 `.configOnly`（不调 `afterFullReload`）之后，「拿一份 `selectedPack` 为空的 config 去 retarget，污染 drop zone / 抹掉画廊选中卡高亮」在 `.configReadFailure` / `.configWriteFailure` / `.lockFailed` 三条路上**不再发生**。但 `.configMissing → .full` 那条路**仍然**会（它必须重扫画廊，`afterFullReload` 躲不掉）—— 那一格的 drop zone 污染是真的、仍然开着，只是它比这三条老得多。

## 声音包管理（PLAN-SOUND-MANAGER.md）落地债

### T2 文件名 Menu 已迁入 Sound Packs Window；新三界面 VoiceOver 真机走查仍未做（2026-08-02）

**Status（2026-08-19）：** 部分完成。迁移本身已完成；Sound Packs Window、EventRowView、PackCardView 三个当前生产 surface 的 native VoiceOver 走查仍待执行。

**2026-08-02 更新：** 主面板不再渲染文件名 `Menu`；事件身份按钮只负责显式路由。完整文件菜单、清除绑定和拖放都在 Sound Packs Window。原字符串级测试保留历史契约，新人工验收应覆盖三个生产界面的唯一名称、Hint、Selected trait、稳定 identifier 与焦点返回。

**What:** T2（事件行文件名升格为原生 `Menu`，三态共用）落地后，PLAN-SOUND-MANAGER.md §2.5 第 7 条要求的三件事——① 行身份与菜单 label 不重复播报；② 禁用的试听 ▶ 不抢播；③ unmapped 行的 Menu label 让 VO 用户听得出"这里能修"——**现在①③有真正的字符串级单测，②有结构级断言，但没有一条是真机 VoiceOver 走查**。`fileNameMenuAccessibilityLabel`/`accessibilityLabel` 的实际 DECISION 逻辑已从 `EventRowView`（住在不可 `import` 的 `ClaudioGUI` executableTarget）拆成 `ClaudioGUICore` 的纯函数 `eventRowIdentityAccessibilityLabel`/`eventRowFileNameMenuAccessibilityLabel`（`EventRowAccessibility.swift`），`EventRowAccessibilitySuite` 直接断言这两个函数的**返回字符串本身**（三态各断一次「不逐字重复」+ unmapped 的可操作动词「选择」）——这条修复过程中当场抓到一个真 bug：`.broken` 的旧菜单措辞把 identity 的「声音文件丢失」原样复述了一遍，两个 VoiceOver 停靠点背靠背念同一句话，现已改写为只说"能做什么"。②（禁用试听 ▶ 不被 `.combine` 合并抢播）是控件树**形状**问题、不是字符串问题，走的是 `ViewWiringSuite` 的源码结构断言（`.disabled(!enabled)` 结构性存在 + 行级 `.contain`、非 `.combine` + `identity` 节点内无 Button 混入）。WCAG 2.1.1 的 Tab 顺序（三槽焦点模型下 Menu 是否会被跳过）已由 `PanelFocusOrderSuite` 的既有断言覆盖（`.eventSound` 恒排每行首位、恒可操作，从未被 T2 之后的任何 fixture 跳过）。**但这一切仍然是本机能做到的上限**——`EventRowView.swift` 所在的 `ClaudioGUI` 执行体 target 不可 `import`（本机 CommandLineTools 无 ViewInspector/XCTest），没有任何测试能真正驱动一次运行期的 VoiceOver 会话，字符串对不对、结构对不对，都不等于"VoiceOver 实际念出来是什么"。

**Why:** 这正是本仓库反复记录的"呈现级洞"天花板——不是偷懒没写,是这台机器结构上够不到 SwiftUI 运行期的无障碍树。如实标注比谎称"类型层已覆盖"更重要（DESIGN.md/ENGINEERING.md 反复踩过"断言存在 ≠ 断言为真"这同一个坑）；这次的教训又添了一条：**字符串级单测能抓到真 bug**（`.broken` 的重复播报），但它抓不到的是"两个 VoiceOver 停靠点之间的实际停顿/语速/是否被系统截断"这类只有真机才回答得了的问题。

**Context:** PLAN-SOUND-MANAGER.md §2.5 第 7 条原文即预告了这条走查项："落进 PanelAnnouncement / 行 accessibilityLabel 的单测 + 一条真机 VO 走查"——本条把后半句正式记账，避免它只活在计划文档的散文里、落地后被遗忘。2026-07-18 a11y-architect 一轮补齐了前半句（单测）与结构断言，后半句依旧原样成立。

**修复方式:** 在一台真 Mac 上开启 VoiceOver，对 `.present`/`.unmapped`/`.broken` 三态各走一遍：确认识别到的是两条不同措辞的公告（行身份 + 菜单控件），确认禁用的试听 ▶ 被 VO 跳过（Tab/VO-Right 移上去不触发播放），确认 unmapped 行的菜单公告让人听得出"可以选文件修好它"。

**Effort:** S（人工走查，非代码改动；若发现真的措辞问题则另计）
**Priority:** P3（不阻断发布——字符串级单测 + 结构断言已经把重复播报的概率降到接近零，真机走查是锦上添花的确认，不是已知缺陷）
**Depends on:** None

### `forkPack` 副本 `name` 字段的措辞未拍板——plan 原文的书名号是不是要求字面写入，没有定论

**What:** `plan/PLAN-SOUND-MANAGER.md` §2.2 给副本 `name` 的例子分别写成"《原name》的副本"与"「\<原name\>的副本」"两种引号包裹的写法，均可读成 prose 里的占位符标记，也可读成要求字面写入的字符。`PackFork.swift:187` 按最朴素的解读实现为 `"\(oldName) 的副本"`（不带任何书名号/引号包裹），`PackForkSuite.swift` 里对应的断言字符串也是这个不带书名号的版本。

**Why:** 这是一处产品文案判断，不是代码缺陷——但如果日后拍板要求带书名号（比如与 DESIGN.md 别处引用包名的规范对齐），需要同时改 `PackFork.swift` 的 `transform` 闭包与 `PackForkSuite.swift` 里对应的几处断言字符串，两处必须同步改，否则测试会继续钉着旧文案、把新文案挡在门外。

**Context:** T6 落地 workflow 的实现方（tdd-guide）在 HANDOFF 里主动标注的设计决策点；audit（silent-failure-hunter）与 review（swift-reviewer）两轮均判定为 minor、未要求返工。

**修复方式:** 找一次产品/设计决策（比如看一眼 DESIGN.md 里其它地方引用包名时用不用书名号，或直接由用户拍板），定了之后同步改 `PackFork.swift:187` 与 `PackForkSuite.swift` 里断言该字符串的几处。

**Effort:** XS
**Priority:** P4（纯文案分歧，不影响功能正确性）
**Depends on:** None
