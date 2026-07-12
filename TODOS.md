# TODOS

## 静默失败

### 一条接管失败只活在内存里 —— app 一退出就没了，而磁盘上那半成品还在

**What:** `OnboardingActionState.failed` 是 `OnboardingViewModel` 的一个 `@Published` 属性，**不落盘**。T17d 保证了它活到「用户真的看过一次」为止，但那条命的上限是**进程的寿命**。用户点「接管」→ 切走 → 安装在后台失败 → **他直接 ⌘Q 退出了 Claudio**（或重启电脑）→ 下次启动 `actionState` 是 `.idle`，那条失败原因**永远消失**。

**Why:** 这不只是「少看一条错误」。`performFirstRunSetup` 的失败点大多在**中途**（二进制、内置包、`config.json` 可能都已经落盘了），而失败后 `refresh()` 会重新探测磁盘 —— 一台「二进制在位 + 四条 hook 都在，但选包那步失败了」的机器会被探测成 `.installed`：**下次启动，面板亮绿点说「已经接好了」，而用户听不到任何声音，也没有任何东西告诉他为什么。** 这正是 T17 存在的理由那句话（「装完后是哑的」）的第五个形状，只是隔了一次重启。

`MenuBarController.popoverDidClose` 在 ⌘Q 路径上也不保证被送达（`ClaudioGUIAppDelegate` 没有 `applicationWillTerminate`），所以连「隐藏」这一步都不一定发生 —— 但那不重要：`actionState` 本来就不过夜。

**Context:** 2026-07-12 T17d 对抗评审顺带发现（Codex 的两条 P1 之外）。当前的缓解是 `doctor`：它会如实报出隔离 / 二进制缺失。但 `doctor` 是一条**用户得先知道自己有问题**才会去跑的命令，而这个 bug 的全部要害就是他不知道。

**可能的修法**（未定，需要一次设计决策）：① 把最后一条失败写进 `~/.claudio/last-setup-error.json`，启动时读一次、渲染一次、读完即删；② 或者反过来 —— 别修失败的寿命，修**探测**：让 `detectOnboardingState` 也检查「有没有选中的包 + 那个包解析得出来」，于是一台哑机器根本不会被报成 `.installed`（这条更根治，而且顺带盖住「用户手动删了包目录」这类与 setup 无关的情形）。②看起来明显更对，但它会动 onboarding 状态机的定义，属于 T17 之外的范围。

**更新（2026-07-12 · T17e）：修法②的判据已经存在了，而且已经在用。** T17e 在 **setup 侧**立下了
「报成功时 `selected_pack` 一定指向一个 `play` 解析得出来的包」这条不变式，判据就是 `checkPackIntegrity`
＋ `isUsablePack`（与 `play` / `doctor` 逐字同源）。**探测侧仍然欠着**：`detectOnboardingState` 依旧只查
二进制 ＋ hooks，所以一台「用户自己把包目录删了」的机器，面板照样亮绿点说「已经接好了」。现在要做的只是把
同一个判据接进 `OnboardingDetector`（新增一个 state，或让 `.installed` 携带「包坏了」这一维），代价比当年小得多。

**更新（2026-07-12 · T17f）：这个洞现在**多吞一样东西** —— 「我替你做主」的告知。**
T17f 新增的 `OnboardingActionState.reported(notices:)` 与 `.failed` **同住一个 `@Published`，同样不落盘**，
于是它继承了一模一样的寿命上限。具体的丢失路径，比失败那条**更容易走到**，因为它走的是**成功**路径：

> 用户点「接管」→ 以为装完了，切走干别的（`.transient` popover 当场关闭）→ setup 在后台**成功**了，
> 但发现他选的包没了，替他换成了 minimal-chime、把他那个读不出的包搬到了某个隐藏路径 →
> 他**没有再打开过面板**就 ⌘Q 了 → 那条「我换了你的包 / 我搬走了你的目录」**永远消失**。
> 下次启动：面板亮绿点、声音是新包的、他自己导入的那个包不见了 —— **而没有任何东西告诉过他**。

注意这一条比失败那条更刺人：失败至少还有 `doctor` 兜底（它会如实报出隔离 / 二进制缺失）；而「包被换了」
这件事**`doctor` 根本不报**——从 `doctor` 的角度看，这台机器一切正常，它只是选了另一个包而已。
**磁盘上唯一还留着这条信息的地方，是那个被搬走的目录本身**，而用户不知道它在哪儿。

修法①（`~/.claudio/last-setup-error.json`，启动时读一次、渲染一次、读完即删）**天然同时盖住这两条** ——
只要把文件名改成中性的（`last-setup-report.json`）、内容改成「上一次 setup 有话要说」的通用形状
（既能装失败，也能装 `[SetupNotice]`）。这让①的性价比比 T17d 当时评估的更高：它现在一次买两个洞。
修法②（把包判据接进 `detectOnboardingState`）**盖不住这一条** —— 换包之后机器是**健康**的，探测器
永远不会觉得有什么不对。**两条修法现在不是二选一，是各修各的：② 治哑机器，① 治没说出口的话。**

**Effort:** M
**Priority:** P2
**Depends on:** None

## Ship / CI

### CI 一次测试都不跑 —— 全部绊线、变异钉子、穷尽性断言在 CI 上的执行次数是 0

**What:** `.github/workflows/` 里**只有** `release.yml`，只由 tag 触发，且只跑 `swift build`（arm64 / x86_64 各一次 + `--product ClaudioGUI`）。没有任何 job 跑 `swift run claudio-tests` 或 `claudio-gui-tests`。没有 `on: push` / `on: pull_request`。

**Why:** helper 971 项 + gui 809 项断言，在 CI 上从未被执行过一次。其中包括 `ReleaseLayoutSuite` —— 一条**专门为「有人改了 release.yml」而存在**的绊线。改 release.yml 的 PR，恰恰是最不会有人想起来在本机跑一遍 GUI 测试套件的那一类。这套仓库把大量心血投在「让回归会红」上，然后没有任何自动化的东西去看那盏灯。

`ReleaseLayoutSuite` 的注释里反复出现「CI 照样全绿」这句话 —— 它字面成立，而成立的原因是 CI 跑的测试数为零。

**Context:** 2026-07-12 T17c 对抗评审。修法：新增 `.github/workflows/ci.yml`（`on: [push, pull_request]`，`runs-on: macos-14`），跑 `swift run --package-path helper claudio-tests` + `swift run --package-path gui claudio-gui-tests` + `swift build -c release --product ClaudioGUI`（零告警），设为 required check。

**Effort:** S
**Priority:** P1
**Depends on:** None

### `ViewWiringSuite` 的文本绊线只挡得住「整行被删」，挡不住「body 被掏空」

**What:** `ViewWiringSuite` 断言的是 `panel.contains(".onChange(of: onboardingViewModel.state)")` —— 那行文本还在。它不断言那行**做了什么**。

**Why:** T17c 评审实测：把 `.onChange(of: onboardingViewModel.state) { _ in refresh(); applyFirstFocus(); announcePanel() }` 的**闭包体掏空**成 `{ _ in }` —— 这精确复现了 T17 要修的那个 bug（接管成功那一秒面板仍显示启动时读的陈旧 config：四行「未配置」+ 空画廊）—— **739/739 全绿**，绿灯纹丝不动。而「把三行搬进别的 modifier 时漏搬」比「整行删除」是更自然的重构事故。

其他合法绕过路径：重命名 `onboardingViewModel` 属性、改用 `.onReceive`、把 onChange 移进子视图 / ViewModifier 扩展的另一个文件。

（T17c 已修掉相邻的一个更弱项：`codeOnly()` 此前只剥整行注释、不剥行尾注释，于是一行 `foo() // .onChange(of: onboardingViewModel.state)` 能让断言假绿。）

**Context:** 2026-07-12 T17c。短期修法：把断言收紧到包含 body 首行（`contains("of: onboardingViewModel.state) { _ in\n            refresh()")`）。根治仍是下面那条 P2（把视图拆进可 import 的 library target），文本绊线的强度天花板就在这里。

**Effort:** S
**Priority:** P2
**Depends on:** None

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

### ~~Setup.swift 的包复制不是原子的，中断后无法自愈~~ ✅ 2026-07-12 T17e 已修

复制现在走 `packs/.<id>.tmp-<pid>` ＋ rename（同卷 rename 原子），且跳过判据从「目标目录存在」收紧成
「目标是一个**能用的包**（manifest 读得出来）」；是残骸就挪到 `.<id>.broken-<pid>`（不删——里面可能有用户的
东西）再重新复制。台账里当年那句「暂时接受这个风险」在 T17e 的对抗评审里被实测证伪：加上新的选包判据之后，
这个残骸不再只是「少一个包」，它会让**每一次重跑都一字不差地失败**（永久死锁）。见 ENGINEERING.md T17e。

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

### GUI 从不告诉用户「我替你换了声音包」「我搬走了你的包目录」—— 那两句 ⚠ 只有 CLI 有

**What:** T17e 会在两种情形下**替用户做主**，并把这两件事都结构化地带在 `SetupOutcome` 里
（`.repairedDeadSelection(removed:selected:)` 和 `salvaged: [SalvagedPack]`），`printSetupSummary` 各印一行 ⚠。
但 GUI 的 `OnboardingActionOutcome.tookOver(SetupOutcome)` **只是把 outcome 接住就扔了**：
`runDiskAction` 的成功分支是 `case .success: actionState = .idle`，payload 从头到尾没有任何视图、任何 `@Published`、
任何无障碍标签消费它（grep 全 `gui/Sources` 可证）。

**Why:** 面板才是产品的主动线（Terminal 只是 v1 的过渡）。也就是说，在最主要的那条路上：
① 我们悄悄改掉了用户的声音包选择；② 我们把他一个可能装着**自己导入的、磁盘上唯一一份音频**的目录搬到了
`packs/.<id>.broken-…`（而 `PackGallery` 显式过滤点开头目录 → 它在任何界面里都不存在）。**两件事他都永远不会
被告知。** 这是 T17e 自身最大的诚实性缺口 —— 它亲手立的规矩就是「替用户做的决定必须说出来」。

**Context:** 2026-07-12 T17e 第二轮对抗评审（repair-semantics ＋ data-loss 两个镜头独立命中）。之所以没在本次做：
面板上多一条提示条需要一次设计决策（放哪、何时消失、要不要给一颗「换回去」/「打开那个目录」的按钮），
属于 DESIGN.md 的范围。缓解：画廊此刻**是可达的**（`.installed`），用户随时能换回去 —— 这正是 T17e 硬失败版本
翻车的那条路径；而被搬走的目录一个文件都没删。

**可能的修法:** `OnboardingViewModel` 加一个与 `actionState` 同族的 `@Published packRepairNotice`（进
`PreviewFixtures` / `assertExhaustive`），`runDiskAction` 的成功分支填它；`PanelView.operationalPanel` 里复用已有的
`errorNotice(...)` 排版画一条琥珀色提示（**不用真红**——这不是 app 的错误），位置就在 `PackGalleryView` 上方，
用户抬眼就是画廊、一步可改。清除时机沿用 `failureHasBeenSeen` 那条纪律（下一次打开面板时清），别在 `refresh()` 里清。

**Effort:** S（一条提示条）/ M（带「换回去」＋「打开备份目录」）
**Priority:** P2
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

### `Casks/claudio.rb` 没有 `zap` —— 「重新安装 Claudio」修不好任何一种中毒态

**What:** cask 里没有 `zap` stanza，`postflight` 只跑 `xattr -dr`。于是 `brew uninstall --cask claudio` /
`brew reinstall` **一个字节都不碰 `~/.claudio/`**（config.json、packs/、残骸全在），也不碰 `settings.json` 里的 hooks。

**Why:** 而所有「装完是哑的」的中毒态**全都活在 `~/.claudio/` 里**。所以「重新安装 Claudio」这句用户最容易想到、
我们此前也在错误信息里印过的建议，对它被印出来的每一种情形都是**确定无效**的。（T17e 已经把 setup 的失败文案
改成了真正有效的那条：从 app bundle 跑一次 `setup`。但 cask 的 `caveats` 仍然只教用户「打开 Claudio，点接管」。）

**Context:** 2026-07-12 T17e 对抗评审（完备性批评者）。

**可能的修法:** 给 cask 加 `zap trash: ["~/.claudio"]`（以及 `uninstall` 里提示摘 hooks）。注意 `zap` 只在
`brew uninstall --zap` 时生效，所以文档也要跟着说清楚。

**Effort:** S
**Priority:** P3
**Depends on:** None

### release.yml 多处 `${{ }}` 表达式直接拼进 shell 脚本，存在脚本注入模式

**What:** `.github/workflows/release.yml` 的 build job（约 58/127-128/160/177-180 行）和 update-cask job（约 205-206/240 行）把 `steps.ver.outputs.version` 等从 git tag 派生的值直接用 `${{ }}` 模板展开进多行 `run:` 脚本体，而不是走 `env:` 再引用 shell 变量。

**Why:** git tag 名理论上可以包含 shell 特殊字符（`$`、`` ` ``、`;`、`|` 等），且触发条件（`v*.*.*`）只检查了非空，没有字符白名单。这是 GitHub Actions 官方文档点名的经典脚本注入反模式——理论上一个精心构造的 tag 名能在 CI 里拿到 `HOMEBREW_TAP_TOKEN` / `GITHUB_TOKEN` 执行任意命令。

**Context:** 红队在 `/ship` pre-landing review（2026-07-10）里发现的。利用门槛是"有权限往这个仓库推 git tag"——这个仓库是私人项目（solo repo），能推 tag 的只有仓库主人自己，所以眼下实际攻击面基本为零；但这个模式一旦被复制到未来权限更松的 workflow 里就会变成真问题，值得单独一个 commit 清理，不跟功能改动混在一起。修法：把用到的 `${{ }}` 值都改成 `env:` 声明，脚本体里用带引号的 shell 变量（`"$VERSION"`）引用。

**Effort:** S
**Priority:** P3
**Depends on:** None

### release.yml 打包 Resources/packs 时硬编码了包名，加新包容易漏

**What:** "Assemble Claudio.app" 步骤用 `cp -R packs/minimal-chime "$APP/Contents/Resources/packs/minimal-chime"` 硬编码单个包名，没有遍历仓库 `packs/` 下所有包目录，也没有校验 app bundle 里的包集合跟仓库里的包集合一致。

**Why:** v1 只有一个内置包，暂时不会触发。等以后加第二个内置包（比如节日限定包）时，如果忘了同步改这一行，CI 会全绿、DMG 照常签发，但新包会悄悄漏在 bundle 外——`claudio setup` 自然也复制不出一个不存在的包，且没有任何 job 会失败或报警。

**Context:** 红队在 `/ship` pre-landing review（2026-07-10）里发现的，INFORMATIONAL 级别（v1 单包场景下不构成真实问题）。修法：改成遍历 `packs/*/`（按有没有 `manifest.json` 过滤），再加一步校验 bundle 内的包 id 集合跟仓库里的包 id 集合完全一致，不一致就让 job 失败。

**Effort:** S
**Priority:** P4
**Depends on:** 加第二个内置包之前应该处理掉

### AudioImportViewModel 并发 handleDrop() 的完成顺序竞态

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

### SystemCommandRunner 超时后只 terminate() 不强制回收，忽略 SIGTERM 的子进程会失控

**What:** `SystemCommandRunner.run` 的超时路径只调用 `process.terminate()`（发 SIGTERM）就返回，不 `waitpid`、也不在子进程赖着不退时升级为 SIGKILL。一个 `trap "" TERM` 或需要时间清理的子进程会被报成 `.timedOut`，但真实进程仍在后台继续跑。另一处相关：`drainToEOF` 之后的 `exited.wait`（`VersionCompatibility.swift:210-214`）——若排空 stdout 几乎耗尽 deadline，即使已 `sawEOF`、子进程只差微秒就退出，`exited.wait` 拿到约 0 的剩余时间也可能返回 `.timedOut`，于是 doctor 显示"无法核实版本"而非那个（可能低于下限的）真实版本。

**Why:** 眼下无害：生产里唯一的命令是 `/usr/bin/env claude --version`——它不 trap SIGTERM、会乖乖被杀，且是原生二进制 0.05s 返回，远快于 2s 上限，EOF-后误报那一支实际不可达；runner 目前也只被一次性的 `doctor` CLI 进程调用，进程随后就退出。但 `VersionCompatibility.swift` 的 doc comment 反复写明菜单栏 app 计划 in-process 复用这套 API；那一刻，面对刻意忽略 SIGTERM 的子进程，失控子进程会累积。

**Context:** Codex 结构化评审（2026-07-11 `/ship`，[P2]）与 Claude 对抗子代理（finding #3）各自独立命中同一区域，一个说"terminate 不 reap"、一个说"EOF 后仍可能误报超时"，均 LOW/latent、生产不可达。修法：`terminate()` 后做一次 bounded 等待，仍在跑就 `SIGKILL` 并回收；`drainToEOF` 返回后若 `sawEOF && !process.isRunning` 直接 `.completed(exitCode, stdout)`，不再进那个可能拿到约 0 剩余时间的 `exited.wait`。已有超时测试用 `sleep`（会被 SIGTERM 杀），没覆盖 trap-TERM 的子进程——补测需要一个真的忽略 SIGTERM 的子进程 fixture。

**Effort:** M
**Priority:** P3
**Depends on:** T7 / 菜单栏 app 真正 in-process 复用 CommandRunning

### install 对完全不在 `.claudio` 命名空间的二进制路径不设 unsweepable 守卫

**What:** `binaryPathContradictsItsNamespace` 只拦"在命名空间内但形状会让 uninstall 认不出"的路径（`..`、相对路径、below-root 元字符）。一个**根本不含 `.claudio` 分量**的路径（如 `/usr/local/bin/claudio`）返回 `false`——install 照装，但 `claudioNamespaceRoot` 对它推不出 root，uninstall fail-closed（nil root → `.notInstalled`），永远清不掉这条 hook。

**Why:** 生产不可达：setup 恒用 `~/.claudio/bin/claudio`，一定含 `.claudio`；而且这是**有意的** carve-out——`detectHookInstallStatus` 的 stale-namespace 覆盖就是靠这条分支装 `.claudio-OLD` 条目的（见 `binaryPathContradictsItsNamespace` 的 doc comment）。但它是一处不对称：将来某次重定位把二进制挪到命名空间外，会静默留下一条无人能清的 hook。

**Context:** Claude 对抗子代理（2026-07-11 `/ship`，finding #2）提出。是否在 install 侧对 nil-root 情形也加守卫，是个需权衡的产品决定：加了会和上面那条 carve-out 打架，得先想清楚"命名空间外的 claudio 二进制"该拒装还是容忍。

**Effort:** S
**Priority:** P4
**Depends on:** None

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

**仍未验、且必须在 state 到 `.installed` 之后才够得着的**（本机当前 `~/.claudio/bin/` 不存在、settings.json 无 claudio hooks，所以第一屏永远是 `.helperMissing`，运行态面板根本进不去）：Tab/Shift+Tab 走 action→mute 序（**注意：默认系统设置下这条根本不成立，见下一条 TODO**）、VoiceOver 逐控件导航 + 进入播报、切包画廊滚动/点选、Dynamic Type 三级真实布局、reduce-transparency、真实 `NSSound` 试听、静音/切包后 SwiftUI refresh、`NSOpenPanel` 端到端喂进导入管线。

~~此外仍未接线：onboarding CTA（接管/修复/断开）**全是 no-op**~~ → **2026-07-12 已接线并真机验证通过（T17b）**：CTA 现在真的会复制二进制 + 内置包、选默认包、写 hooks，失败会当场说出来；「断开连接」在运行态面板底部有了真入口。仍未做：状态栏图标仍是占位 SF Symbol（`waveform.circle`），非最终定制单色字形。

**Why:** 面板核心逻辑（状态派生 / 写回 / 焦点顺序 / 对比度 / Dynamic Type 表）已下沉 `ClaudioGUICore` 并单测覆盖（helper 945 / gui 543），但交互真身只在真机成立 —— 而真机走查现在**随时可做**，不再有硬前提。

**Context:** T15 tdd-guide + a11y-architect + swift-reviewer（2026-07-11）；同日真机走查推翻了「需要 Xcode」的前提。修法：把剩余项在真机走完 —— 但先得让 state 进 `.installed`（要么跑 `claudio setup` 真接管，要么接完 T17 的 CTA）。

**Effort:** M
**Priority:** P2
**Depends on:** state 到 `.installed`（`claudio setup` 或 T17）

### 面板的 Tab 遍历 / 首焦点在**默认系统设置**下是死的（macOS「键盘导航」默认关闭）

**What:** 面板里所有可聚焦控件都是 SwiftUI `Button`（`EventRowView` 试听/导入/静音、`PackGalleryView` 卡片、`OnboardingView` CTA），全 `gui/Sources/` 里 `.focusable()` 出现 **0 次**。而 macOS 的「键盘导航 / Full Keyboard Access」**系统默认是关的**，关闭时 Button 不进 key view loop —— `applyFirstFocus()` 那次 `@FocusState` 赋值直接落空，Tab 在面板里也无处可去。

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

### 主音量滑块 spec 写了、代码里根本没有（面板 UI 唯一的静默漂移）

**What:** ENGINEERING.md 的面板 UI 线框和「交互状态覆盖表」都明确列着「🔊 主音量 ●———————」一行（拖动即时改 `config.json` / 越界钳制），但 `PanelView` 里**零 Slider**——`grep` 全仓库无 `masterVolume` / `Slider` 命中。helper 侧的 `volume` → `afplay -v` 映射早在 T9 就做完了（`Volume.swift`），缺的只是面板里的 Slider 控件 + 写回 config。

**Why:** 这是本次 `/ship` plan-completion 审计发现的**唯一一处「spec 写了、代码没有、台账也没记」的静默漂移**——它此前既没有 TODOS 条目、也没有任何 T 编号认领，等于所有人都以为它做了。后果：用户能逐事件静音，但改不了整体音量，只能手改 `config.json`。（好消息：本次已把 `config.json` 改成保真读-改-写，所以用户手改的 `master_volume` **至少不会再被下一次点静音静默吃掉**——这正是本轮修复前的真实行为。）

**Context:** 2026-07-11 `/ship` plan-completion 审计。修法：`PanelView` 加一个 Slider（DESIGN.md 已定义其视觉），值绑到 config 的 `master_volume`，拖动经 `ConfigMutation` 的外科式写回落盘（`setEventEnabled` / `selectPack` 已共用它，第三个写者照抄即可），越界钳制走 `Volume.swift` 现成的规则。

**Effort:** M
**Priority:** P2
**Depends on:** None

### T16/T15 GUI 小项：绑定失败留孤儿文件 + doc-comment 的 D 编号引用不存在

**What:** ① `EventRowImportViewModel`：导入成功但随后 `bindEventToManifest` 失败时，已复制进包目录的音频文件会留下、不被任何事件引用（孤儿文件）——**文件本身仍未清理**，非安全问题，纯整洁。② T15/T16 新文件里约 26 处 doc-comment 引用「ENGINEERING.md T15 D3/D4」等 D 编号，但 ENGINEERING.md 无此细分——溯源/可读性 nit，读者按 D 编号 grep 会落空。

**Why:** 均无功能风险；两项都是「诚实但可更整洁」，攒到某次 GUI 收尾 pass 一起清。

**Context:** T16 security-reviewer + T15/T14 swift-reviewer（2026-07-11）。**本条此前记载不实，已更正**：原文写孤儿文件「已通过 `bindResult` 如实上报（非静默）」——事实是 `bindResult` 从未被任何视图读过（三个独立评审各自 grep 确认），它一直是静默的。**2026-07-11 `/ship` 这一批才真正接上上报**：`EventRowView` 现在会渲染 `bindResult` 的绑定失败与导入被拒（过程中发现内层 `AudioImportViewModel` 的 `@Published` 不会穿过外层 `EventRowImportViewModel` 自动传播，必须额外挂一个 `@ObservedObject` 才收得到）。所以「用户看不见失败」已解决，**留下的遗留只剩孤儿文件本身没被清掉**。修法：① 绑定失败时清掉刚复制进包的那个文件，或把孤儿文件纳入下次 doctor/清理；② 把 D 编号软化为「T15/T16」或「(本任务 step D4)」。

**Effort:** S
**Priority:** P4
**Depends on:** None

### `.dropZone` 是 `panelFocusOrder` 的焦点位，但没有任何视图绑定它

**What:** `PanelFocusTarget.dropZone` 出现在 `panelFocusOrder(...)`（`PanelFocusOrder.swift:76`），但没有任何视图 `.focused(_, equals: .dropZone)`——`AudioDropZoneView(viewModel:)` 不收 `focusedTarget` 参数。`PanelFocusOrder` 的 doc-comment 声称纯模型与实时 `@FocusState`「共享一个身份空间，绝不各自漂移」，对 `.dropZone` 而言恰恰漂了。

**Why:** 今天低危：拖入区的 prompt 现在是真 `Button`（a11y FIX 2），仍能靠 SwiftUI 视图树顺序被 Tab / VoiceOver 到达；`.dropZone` 也永不是首焦点目标。缺口只是「程序化把焦点设到拖入区」是 no-op、且模型与接线不一致——将来若某次改动让 `.dropZone` 成为首焦点或引入基于 `panelFocusOrder` 的 Tab-key 处理，就会静默失效。

**Context:** T14/T15/T16 pre-landing 评审（2026-07-11，我 + a11y-architect 各自命中）。修法：给 `AudioDropZoneView` 加 `focusedTarget: FocusState<PanelFocusTarget?>.Binding`，把 `promptLabel` 的 Button `.focused(focusedTarget, equals: .dropZone)`，`PanelView` 传 `$focusedTarget`。

**Effort:** S
**Priority:** P4
**Depends on:** None

### `DynamicTypeSize → PanelTypeSizeTier` 映射用裸 `default:` 而非 `@unknown default:`

**What:** `PanelView.swift` 的 `typeSizeTier` 用 `switch dynamicTypeSize { … default: .maximum }`。`DynamicTypeSize` 是非 frozen 的 SwiftUI 枚举，裸 `default:` 会把未来 SDK 新增的档位静默并进 `.maximum`，无编译期提示——与本仓库处处刻意穷尽 `switch`（`StateGalleryView`/`PreviewFixtures` 明确不写 `default:`）的自律不符。

**Why:** 今天的回落（`.maximum`，最大/最安全档）本身合理，但是个未标注的假设而非被验证的选择。纯健壮性/一致性，无行为风险。

**Context:** T14/T15/T16 pre-landing 评审（2026-07-11，swift-reviewer）。**注意修法非一 token**：直接改 `@unknown default:` 会因 `.accessibility2…5` 是已知未列举 case 报 warning、破坏零 warning 线——正确修法要先显式列出 `.accessibility2, .accessibility3, .accessibility4, .accessibility5`（映射 `.maximum`），再补 `@unknown default: .maximum`。

**Effort:** S
**Priority:** P4
**Depends on:** None

### PackCardView 的 statusLine 图标/文字未 `accessibilityHidden`，且 CC0 徽标 VoiceOver 听不到

**What:** `PackCardView` 的 `eventGrid` 每个字形都 `.accessibilityHidden(true)`（已由卡片自身 `accessibilityLabel` 汇总），但 `statusLine` 的 `xmark.circle.fill` +「文件丢失」、`CC0` 徽标、`N/4` 计数都**未**隐藏，可能作为冗余/自动生成 label 的 VoiceOver 停靠泄漏；且 `CC0` 根本没进 `accessibilityLabel`，VoiceOver 用户完全听不到「这是 CC0 包」。

**Why:** 均无功能风险，纯 VoiceOver 体验：要么冗余停靠、要么信息缺失（CC0）。

**Context:** T14/T15/T16 pre-landing 评审（2026-07-11，a11y-architect，confidence 5）。修法：给 `statusLine` 的图标/文字节点补 `.accessibilityHidden(true)`（镜像 `eventGrid` 的既有处理），并把 `CC0` 折进 `.complete` 分支的 `accessibilityLabel` 若需播报。

**Effort:** S
**Priority:** P4
**Depends on:** None

### 补 helper 单测缺口：`setEventEnabled` 的真并发写未证不撕裂（原 4 项 lake-not-ocean，只剩这 1 项）

**What:** `setEventEnabled` 真并发写（`DispatchQueue.concurrentPerform` 多线程同时切同一/不同事件）——现仅有「一个持锁者 + 一个等待者」的 lock-busy 测（`EventEnabledSuite`「shares play.lock with selectPack」），未证真并发下 read-modify-write 不撕裂。`LogSuite` / `PlaySuite` 已有 `concurrentPerform` 的先例可照抄。

**Why:** 「lake」型补测：镜像已有 happy-path 结构、钉住一条当前未覆盖的分支。无功能风险，纯回归网加固。

**Context:** T14/T15/T16 pre-landing 评审（2026-07-11，pr-test-analyzer）原列 4 项，2026-07-11 `/ship` 修复批已补掉其中 3 项，故本条收窄到只剩并发写：① `setEventEnabled` 的 `.configWriteFailure` 路径 → 已补（`EventEnabledSuite`，父目录被普通文件挡住的 fixture）；② `contrastRatio` 的 `#` 前缀分支 → 已补（`ContrastSuite`「a `#`-prefixed hex parses identically to the bare form」+ 新 `ContrastHexParsingSuite` 连带钉住 `#+FFFF` 的 fail-closed）；③ `bindEventToManifest` 顶层合法 JSON 但非对象 → 已补（`ManifestBindingSuite`「a VALID-JSON but non-object top level (a JSON array) fails closed」）。**并发写这一项没做，别当成做了。**

**Effort:** S
**Priority:** P4
**Depends on:** None

### 导入区（AudioDropZoneView）成功/拒绝后不再可键盘/VoiceOver 触发，只剩拖拽

**What:** `AudioDropZoneView` 新增的"点按打开 `NSOpenPanel`"只挂在 `promptLabel`（初始 `.idle`/prompt 态）。`AudioImportViewModel` 一次成功或拒绝后停在 `.success`/`.reject`，内容切到非按钮行，键盘/VoiceOver 用户无法再次点按导入区重试或继续加声音，只有鼠标拖拽还能用。

**Why:** WCAG 2.1.1（键盘可达）：一条本应键盘可完成的操作在成功/失败后退化为仅指针可用。功能不崩，但可访问性回归——恰与 T15 这一轮"给导入路径补键盘/VoiceOver 激活"的目标相反。修法：把整个 drop zone 在所有状态下都保持为可激活控件；或在 `.success`/`.reject` 行提供同样的"点按添加/重试"按钮，接进同一 `handleDrop` 导入路径（别开第二条）。

**Context:** codex review（2026-07-11，commits e4dd25f/6b9cb66）P2。同类问题曾在 EventRowView 的 importAffordance 上由 a11y-architect FIX 2 修过（drag→drag OR tap），这条是 drop-zone 自身状态机的遗漏。

**Effort:** S
**Priority:** P3
**Depends on:** None

### 当前包目录被删时画廊不生成 broken 当前包卡片，selected 卡片直接消失

**What:** `PackGallery.swift`（`availablePacks`/`packCards`）只枚举磁盘上真实存在的包目录。若 `config.selectedPack` 指向一个已被删除的包，当前包不在 `availablePacks` 里，于是 `packCards` 里没有 `isSelected` 卡片；用户看到的是全 unmapped 事件行 + 一个没有"当前项"的画廊，而不是一个可理解的"当前包坏了"状态。

**Why:** 静默丢失当前包卡片，与 DESIGN.md"真打包错误不被伪装成正常静默"的取向不符——用户无法从 UI 看出"你选的包不见了"。修法：把安全化后的 `config.selectedPack` 并入候选 ID 集合，即使目录不存在也走 `buildPackCard` 生成一张 `.broken(reason: "声音包目录未找到")` 的 selected 卡片。

**Context:** codex review（2026-07-11，commits e4dd25f/6b9cb66）P2。需同时想清楚：broken 当前包的事件行该显示什么（当前 `packCoverage` 对无法解析的包已回落全 `.unmapped`，见 `CoverageState.swift` 注释），卡片层与行层对"当前包缺失"的表达要一致。

**Effort:** S
**Priority:** P3
**Depends on:** None

### GUI 主线程一次性全量扫包（装几十个包后开面板会卡）

**What:** 每开一次面板，`availablePacks` 在主线程上把两个包根目录全量枚举一遍，对**每个**包解析目录 + 有界读 manifest + 解 JSON + 算 coverage，无缓存、无异步、无分页。

**Why:** 1 MiB 的单份 manifest 上限挡不住「包很多」这一维：几十个包就开始线性变卡，几千个包能把菜单栏 app 冻住。今天用户手里通常只有 1–3 个包，所以是真实但尚未触发的问题。

**Context:** 2026-07-11 `/ship` 九路评审（Codex 对抗 [P2] + Claude 对抗独立命中）。修法：把画廊加载移出主 actor + 缓存结果（按目录 mtime 失效），必要时分页。

**Effort:** M
**Priority:** P3
**Depends on:** None

### ManifestBindError 的两个失败态没有「怎么修」的出路，且绑定失败会留下孤儿文件

**What:** `config.json` 的每一条 fail-closed 原因都带 `configRebuildHint`（「手工改这个键，或删掉文件让 claudio 重建」），而 `ManifestBindError.manifestUnreadable` / `.writeFailed` 的文案只说了「读不动 / 写不进」，没有任何下一步；代码里也没有任何路径能重建 / 修复一个用户包的 manifest.json。叠加已知的「绑定失败留孤儿文件」（音频已拷进去、manifest 没更新），用户在那个包上就被永久卡住，而且一旦那条 toast 消失，磁盘上再没有任何证据。

**Why:** 与 config 侧「fail closed 必须给出路」是同一条原则，只是 manifest 侧没跟上。

**Context:** 2026-07-11 `/ship` 九路评审（红队）。修法：给这两个 case 补可执行 hint（对齐 `configRebuildHint` 的形状），并让 doctor 或面板能提示「这个包的 manifest 坏了，重装 / 重建它」；孤儿文件在 `.writeFailed` 时回滚删除。（原「绑定失败留孤儿文件」P4 条目并入本条。）

**Effort:** M
**Priority:** P3
**Depends on:** None

## Completed

### clay 当正文用够不到 4.5:1 —— DESIGN.md 自身冲突

**What:** DESIGN.md 一边祝福「drop-zone hover 命中 → 边框 / **文字**转黏土」，一边要求「行内文字 ≥ 4.5:1」。实测亮色 clay `#C4633C` 对 panel `#FFFDF8` = **3.97:1**——过图标 / 边框的 ≥3:1，**不过正文的 ≥4.5:1**。两行规范互相矛盾，代码只能二选一。

**Why:** 不是实现 bug，是规范内部冲突，且两条出路都动 DESIGN.md，而 clay 是品牌唯一强调色，实现者不该代为改动——所以挂账等用户拍板。

**Context:** T14/T15/T16 pre-landing 评审（2026-07-11 `/ship`，对比度审计）登记；同日 `/ship` 九路评审复现并量到同一个 3.97:1。

**修复方式:** 用户拍板取 DESIGN.md 自己标的**解法 1**：hover 反馈只由**边框 + `clay-soft` 底**承载，**文案恒为 `text-2`**。`AudioDropZoneView.promptLabel` 的 `foregroundColor` 去掉 `isHovering` 三元（`isHovering` 仍驱动边框与底色，hover 观感不变）；DESIGN.md 的 known-gap 注记改成已拍板记录。零品牌成本——clay 的色值一个字没动，`Notification` 的视觉身份也没动。

**Effort:** S
**Priority:** P3
**Depends on:** None
**Completed:** 2026-07-11（`/ship` 九路评审修复批，分支 `feat/t16-t15-t14-state-gallery`）

### 补 helper 单测缺口：`setEventEnabled` 的真并发写未证不撕裂

**What:** `setEventEnabled` 的 config 读-改-写在本分支里**新**被纳入 `play.lock`（此前无锁），但只测了锁竞争（1 持有者 + 1 等待者），没有任何 `DispatchQueue.concurrentPerform` 测试证明这条 RMW 在真并发写下不撕裂。

**Why:** 「被本分支改掉行为、却没有覆盖变更后路径」的定义就是回归缺口——覆盖率审计把它列为整个 diff 里唯一的 REGRESSION GAP，优先级最高。`PlaySuite.swift` 里已有现成的同形状测试（真并发证明「恰好一个播放」）可以 1:1 照抄。

**Context:** 2026-07-11 `/ship` 覆盖率审计（91%，唯一 REGRESSION GAP）。

**修复方式:** 照 `PlaySuite` 的 `concurrentPerform` 形状补真并发写测试：N 个并发 `setEventEnabled` 打同一份 config，断言落地文件仍是合法 JSON、三个 v1 键都在、未知顶层键一个没丢、且每次调用要么成功要么 `.lockBusy`——绝无静默损坏。

**Effort:** S
**Priority:** P4
**Depends on:** None
**Completed:** 2026-07-11（`/ship` 九路评审修复批，分支 `feat/t16-t15-t14-state-gallery`）

### CoverageState / checkPackIntegrity / Play 的 `fileExists` 不辨目录（3 站点共用）

**What:** `coverageState`（T16 新增）、`checkPackIntegrity` 的 `missingFiles`、`Play` 的解析都用 `FileManager.fileExists(atPath:)` 判存在，不查 `isDirectory`。manifest 把某事件映射到一个**存在的同名目录**时，会报 `present`/`complete`，而 `afplay` 运行时静默失败。

**Why:** 现实里 manifest 值都是文件名、且 `safePackFileURL` 已挡路径逃逸；「存在的同名目录」需用户手动造。纯健壮性，非 T16 引入（继承既有 `doctor`/`play` 语义），但现在多了 `CoverageState` 第三个站点。

**Context:** T16 swift-reviewer（2026-07-11）。修法：三处统一改成「存在且是普通文件」判定，抽一个共享 helper 免第四次重犯。

**修复方式:** 新增 `helper/Sources/ClaudioCore/SafeFileRead.swift` 的 `regularFileExists`（`stat` + `S_IFREG` 门），三个站点统一改用它，不再各自 `fileExists`。变异测试实证了旧代码的完整失败链：一个**名为 `stop.mp3` 的目录**会被判为 `present`、`doctor` 报通过、`play` 报「已播放」——却什么声音都没有。

**Effort:** S
**Priority:** P4
**Depends on:** None
**Completed:** 2026-07-11（`/ship` pre-landing 修复批，分支 `feat/t16-t15-t14-state-gallery`）

### popover 尺寸硬编码 312×400，最大 Dynamic Type 档下不跟随 PanelView 加宽

**What:** `MenuBarController.swift` init 里把 `popover.contentSize = NSSize(width: 312, height: 400)` 写死。注释只声明 height 由 `NSHostingController` 的 intrinsic content 在运行时驱动，width 没有。而 `PanelView.body` 在 `.accessibility2…5` 档会把自身 `.frame(width: layoutAdaptation.panelWidth)` 提到 360pt。

**Why:** 若 `NSHostingController` 没开 `.preferredContentSize` 之类的 sizing 传导，SwiftUI 想要的 360pt 宽不会反映到 popover 的 contentSize width，最大字号下"加宽 popover"落空、内容可能被裁。仅在最高 Dynamic Type 档触发，属边角，但确是未验证的假设。

**Context:** codex review（2026-07-11，commits e4dd25f/6b9cb66）P2。Claude 侧核验：硬编码属实，是否裁切取决于 `NSHostingController` sizing 行为。

**修复方式:** 不再硬编码 312：popover 初始宽改用 `standardPanelWidth` 常量，并新增 `onPanelWidthChange` 回调，由 `PanelView` 把 `layoutAdaptation.panelWidth` 回传给 `MenuBarController` 更新 `contentSize`。`.maximum` Dynamic Type 档下 popover 真的加宽到 360，不再指望 `NSHostingController` 的隐式 sizing 传导。

**Effort:** S
**Priority:** P3
**Depends on:** None
**Completed:** 2026-07-11（`/ship` pre-landing 修复批，分支 `feat/t16-t15-t14-state-gallery`）

### 焦点契约修复（52f8913）只有纯逻辑测试，视图接线无回归护栏

**What:** commit `52f8913` 修了两处视图层 bug：① `PanelView.applyFirstFocus()` 首焦点跳过 muted-present preview（改用 `nonOperableActionEvents`，不再 `panelFocusOrder(...).first`）；② `.unmapped`/`.broken` 行的禁用 preview 不再持有 `.eventAction` 焦点身份。但新增的 `CoverageStateSuite`（+33）/`PanelFocusOrderSuite`（+96）只覆盖 `panelFirstFocusTarget` 与 `EventRow.eventActionOperable` 两个**纯函数**——证明「函数算得对」，没有一根测试盯住「视图真的调用了它们」。谁把 `applyFirstFocus` 改回 `panelFocusOrder(...).first`、或把 `.focused(... .eventAction)` 加回 disabled 的 `previewButtonBody`，现有测试大概率仍绿，原 bug 悄悄回归。

**Why:** 回归护栏缺口，非当前正确性缺陷——Codex 独立审查已确认 diff 本身逻辑自洽，故记账而非阻断。

**Context:** codex review `52f8913`（2026-07-11，[P2]，无 P1）。原计划是引入 ViewInspector 或并入真机走查。

**修复方式:** **比原计划更好，且不需要 ViewInspector、不需要真机。** 把判定从视图**下沉**进 `ClaudioGUICore`，成为两个纯函数——`EventRow.previewClaimsActionFocus` 与 `panelOpeningFocus(rows:packCardIDs:)`——视图侧只剩一次调用、没有可漂移的分支。护栏因此变成普通单测：变异验证把视图改回旧写法，两组断言分别 **5 红 / 3 红**（含「首焦点必须 ≠ `order.first`」那条关键断言）。原来「测试证明函数算得对，却没人盯住视图是否调用它」的缺口，通过消灭「视图里的判定逻辑」这个东西本身而关闭。

**Effort:** S
**Priority:** P3
**Depends on:** 线 173 的 T15 真机手验同批（若引入 ViewInspector 则可本机）
**Completed:** 2026-07-11（`/ship` pre-landing 修复批，分支 `feat/t16-t15-t14-state-gallery`）

### `ClaudioGUI` 整个 target 在 harness 里一行都跑不到（视图层接线零回归网）

**What:** `claudio-gui-tests` 只依赖 `ClaudioGUICore` + `ClaudioCore`。`ClaudioGUI` 是带 `@main` 的 **executableTarget**，Swift 里 import 不了。于是整棵 SwiftUI 视图树上的每一行接线，对这套测试都是不可见的。

**Why:** T17 的 diff 评审实测了两次变异，**两次都全绿**：① 删掉 `PanelView` 里那句 `.onChange(of: onboardingViewModel.state) { refresh(); … }` —— 也就是让「接管成功」真正兑现的那一行（没有它，用户在成功的那一秒看到的是四行「未配置」+ 空画廊）—— 652 项测试全绿、release 构建零告警；② 把 `actionRunner` 改回可选 + 静默 guard（= 逐字重建 T17 之前那个死 CTA）—— 652 项全绿，唯一信号是一条无关的 unused-variable 警告。**两次变异都重新制造了 T17 要修的那个 bug，绿灯一次都没灭。**

**Context:** 2026-07-12 T17b diff 对抗评审。当前的缓解是 `ViewWiringSuite`（读源码文本的绊线）—— 它挡得住「顺手删掉 / 重构漏掉」，但**证明不了那行代码做对了，只能证明它还在**。真正的修法：把 `ClaudioGUI` 的视图拆进一个可被 import 的 library target（`ClaudioGUIViews`），executable 只剩 `@main` + AppDelegate；或引入 ViewInspector。前者不需要新依赖，且与本仓库「视图里不留判定逻辑」的既有纪律同向。

**Effort:** M
**Priority:** P2
**Depends on:** None

### state gallery 给「断开连接」画的是一帧 app 里不存在的画面

**What:** `.running(.disconnect)` 那一帧用 `.installed` 承载，渲染的是 `OnboardingView`。但真实 app 在 `.installed` 时渲染的是 `operationalPanel`（`OnboardingView` 根本不出现）——真正 ship 的那颗「断开连接」按钮（在 `PanelView.disconnectRow` 里）**一帧都没有**。

**Why:** T14 的意义是「仓库内 gallery = 视觉真相源」。这条不是新引入的（`.installed` 的 onboarding fixture 本来就渲染一个 app 里不出现的界面），但 T17 把一个**真的会 ship** 的控件加进了 operational 面板，于是这个缺口第一次有了实际代价：没有人看过那颗按钮长什么样，明暗两主题都没有。

**Context:** 2026-07-12 T17b diff 评审。修法：给 gallery 加一个能 pin 状态的 `PanelView` 帧（需要 `PanelView` 支持 `#if DEBUG` 的 preview init），或把 `disconnectRow` 抽成一个独立的可预览小组件。

**Effort:** S
**Priority:** P3
**Depends on:** None

### `hasQuarantineAttribute` 是 fail-open：任何 errno 都被折叠成「没被隔离」

**What:** `getxattr(url.path, name, nil, 0, 0, XATTR_NOFOLLOW) >= 0` —— `ENOATTR` / `ENOENT` / `EPERM` / `EACCES` / `EIO` **全部**返回 -1，函数一律报 `false`（干净）。实测确认（Darwin 25.5）：穿一个 0000 权限的目录去读一个确实带章的文件 → `rc=-1 errno=13 (EACCES)` → 函数说「没被隔离」。

**Why:** 三个调用点里，`Setup.swift:250` 是**唯一 load-bearing** 的那个 —— 它是「剥完回验、验不过就一条 hook 都不写」这道主保险的判据，而它唯一的失败方向是**放行**：读不出来 = 当作干净 = 照写 hooks。后果正是 T17 要杀死的那个 bug 原样复活（装完、绿点、doctor 全绿、每个事件被 Gatekeeper 静默杀掉）。`OnboardingDetector` / `Doctor` 那两处只是少报一次 `.helperMissing` / 少报一条硬失败。

**在当前威胁模型下不可利用**（目标是用户自己家目录里、自己创建的文件；EACCES/EPERM 需要用户亲手 chmod 000 才构造得出来；`ENOTSUP`（无 xattr 的文件系统）下报 false 反而是正确答案）。这是**健壮性 / 断言诚实性**问题，不是安全漏洞 —— 所以不阻断发布。

**Context:** 2026-07-12 T17c 对抗评审（Codex + Claude 安全专项 + 红队三方独立指出，安全专项实测了 errno）。修法：改成三态而不是布尔 —— `rc >= 0` → `.present`；`errno ∈ {ENOATTR, ENOENT, ENOTSUP}` → `.absent`；其余 errno → `.unknown(errno)`。`Setup.swift` 的闸门**只在 `.absent` 时放行**（`.unknown` 视为仍被隔离，走 `binaryQuarantined` 并把 errno 写进 reason）；Detector / Doctor 可以继续把 `.unknown` 当 `.absent`（保持宽松），但 doctor 至少要把 errno 打出来。顺带：`stripQuarantineAttribute` 现在完全丢弃 `removexattr` 的返回值，`binaryQuarantined` 的 reason 因此无法区分「剥不动」和「回验读不到」—— 一起收进来。

**Effort:** S
**Priority:** P2
**Depends on:** None

### in-flight 期间 onboarding 的键盘焦点无处可去（当前是「诚实的空」，不是想清楚的答案）

**What:** 一个 `.takeOver` / `.disconnect` 跑到一半时，两颗 CTA 都 `.disabled`。`applyFirstFocus()` 于是拿 `ctaOperable: false` 去算焦点序，而 onboarding scope 里除了这两颗按钮**没有别的候选**（失败行此刻不存在 —— `runDiskAction` 一开跑就把 actionState 换成 `.running`）→ `panelFirstFocusTarget` 返回 `nil` → `focusedTarget = nil` → SwiftUI 的 `@FocusState` 置 nil 会 resign first responder，光标整个消失。

**Why:** `PanelView` 那段 `.onChange(of: actionState)` 的注释白纸黑字说这次改动就是为了「没人把焦点接走的话，键盘用户按完空格就无处可去了」—— 而实现出来的结果正是「无处可去」。测试也把这个行为钉成了断言（`panelFirstFocusTarget(scope, ctaOperable: false) == nil`），而那条断言的失败文案写着「caret 必须有人接管，而不是悬在那儿」。

**但这不是一个纯 bug**：in-flight 期间那张卡上**确实没有任何可操作的东西**，把光标指向一颗禁用的按钮同样是撒谎。这是一个真实的产品取舍（① 保持焦点不动，让它停在那颗已禁用但仍在屏幕上的按钮上，AppKit 的 key loop 会自己跳过 disabled view；② 让正在跑的那颗按钮保持可聚焦但不可激活，配 `.accessibilityValue("正在接管…")`；③ 把焦点交给面板容器）。需要拍板，不该由评审代劳。运行态面板不受影响（它恒含 `.dropZone`，永不返回 nil）。

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

### 「断开连接」ghost 按钮偏离 DESIGN.md，且「次 CTA」这一个角色现在有两套渲染

**What:** 四条，都在 `PanelView.disconnectRow`：① 圆角 `cornerRadius: 8` 不在 DESIGN.md 的圆角阶梯上（控件 6 / 卡片·行 10 / onboarding 图标块 12 / 面板 15 —— 全 app 其余 `RoundedRectangle` 无一例外落在 token 上）；② 字号 `11` 是「次要 / 状态」那一档（面板里 `errorNotice` / `ActionFailureRow` 的说明文字正是 11），而控件标签最接近的档是「行标签 13」—— 这颗按钮的标签比面板里任何一颗别的按钮都小，跟它旁边的失败说明一样大；③ `.buttonStyle(.plain)` 剥掉了 AppKit 的全部反馈，只补了一层**静态**描边 —— 一颗全宽的、不可撤销的破坏性按钮，鼠标压下去屏幕上没有任何变化（本仓库对同类命中区已有成熟的 token 化 hover：`AudioDropZoneView` 的「边框转 clay + `clay-soft` 底」）；④ 同一个「次 CTA」语义角色，`OnboardingView` 里仍是 `.buttonStyle(.bordered)`（macOS 系统灰底按钮），而 DESIGN.md 写的是「次 CTA（ghost：透明 + `hairline-strong` 描边）」。

**Why:** ①②④ 都需要拍板取值（6 还是 9？13 还是保持 11？把 `.bordered` 一起换成 ghost 会改动**已经真机验证过**的 onboarding 卡），不该由评审代劳。③ 是纯增补。

**Context:** 2026-07-12 T17c 设计专项。修法：抽一个共享的 `GhostButtonStyle`（透明底 + `hairline-strong` 描边 + hover/pressed 态 + token 化圆角），`OnboardingView` 的次 CTA 与 `disconnectRow` 同时用它 —— 一个角色一套渲染。

**Effort:** S
**Priority:** P3
**Depends on:** None（需要先拍板 ①②④ 的取值）

### 「断开连接」是全 app 唯一一条会与正在发声的 `claudio play` 抢 `play.lock` 的写路径

**What:** `disconnectRow` 只在 `.installed` 渲染 —— 而 `.installed` 的定义就是「四条 hook 都在」，也就是**每一个 Claude Code 事件都会 spawn 一次 `claudio play`**，而 `play` 与 `uninstallClaudioHooks` 共用同一把 `play.lock`（`SettingsInstaller.swift:216` → `.skipped` → `.lockBusy`）。

**Why:** 用户越是在正常用 Claude Code，点「断开」就越容易吃到一条 `.disconnectFailed(.lockBusy)` **假失败**。对照之下「接管」不受影响：takeOver 只从 `.notInstalled` / `.helperMissing` 出发，那时要么没有 hooks、要么 helper 跑不起来，`play` 拿不到锁。所以 T17 把 setup 搬进 GUI **没有**加剧 play.lock（与直觉相反），但它新造的**断开**按钮，第一次把 TODOS 里那条 P1 推到了 UI 表层。

**Context:** 2026-07-12 T17c 红队。短期修法：`.lockBusy` 单独出一条更准的文案（「Claude Code 正在响，稍等一两秒再点一次」），别与真正的写失败混为一谈；或在 lockBusy 时自动重试 2–3 次（指数退避 100/300/700ms —— 这是一把非阻塞锁，重试安全且几乎必然成功）。根治仍是那条 P1：把 `play.lock` 拆成 play 专用锁与 config/settings 写锁。

**Effort:** S
**Priority:** P2
**Depends on:** 「`play.lock` 被 config / settings 写者共用」（那条 P1 的根治会顺带消灭这一条）

### 「下面的声音包」与告知行的位置断言，在 onboarding 卡上都是假的

**What:** `SetupNotice.repairedDeadSelection` 的文案里有一句**关于布局的断言**：「你随时可以在**下面的**声音包里换成别的」。它由 `PanelView.operationalPanel` 的排布兑现（提示行排在 `PackGalleryView` 之前），并由 `ViewWiringSuite` 的顺序断言钉死。**但 `OnboardingView` 那张卡也渲染 `ActionNoticeRow`（`OnboardingView.swift:125`），而那张卡既没有声音包画廊、也没有四行事件覆盖度** —— 那句「下面的声音包」在它上面指向的是空气。

**Why:** 今天不会伤到人，但理由是「这条路径不可达」：一次成功的 `takeOver` 必然把 state 推成 `.installed`，于是每一条告知都诞生在运行态面板那一侧，onboarding 卡接不住它。**而「我推理出这个格子不可达」正是这个仓库交过两次学费的那句话**（T17d 的「重开 = 看过了」、T17e 的「零包不会写 hooks」）—— 而且这张卡**之所以**渲染告知行，恰恰是因为 T17f 拒绝对不可达性做推理（「两个渲染点都无条件画」是它的结构不变式）。两条理由自己打架：要么承认它可达、给它一句站得住的文案，要么承认它不可达、别渲染。

**Context:** 2026-07-12 T17g（`/codex review 0d789dd` 自评审顺带发现）。同一轮里刻意**没有**往文案里再加一句「上面四行会告诉你哪些还缺」，就是不想在这个洞里再多埋一条位置断言。修法二选一：① 把告知行做成一个自带上下文的组件（不假设自己上下有什么），文案去掉方位词；② 让 `onboardingVisibleNotices` 在 onboarding 卡上恒为空，并用一条测试把「告知只可能诞生在 `.installed`」钉死 —— 那等于正式承认这条不可达，就得配一条会变红的断言，而不是一句注释。

**Effort:** S
**Priority:** P3
**Depends on:** None

### 面板句里的 `header` 是视图算的，harness 一行都测不到 —— 而它里面藏着第二个「这是哪一屏」的 oracle

**What:** `PanelAnnouncementFacts` 的文档白纸黑字写着：`state` 由 view-model 供给，**视图不碰**，「也就不会有第二个会漂移的答案」。但 `header` 仍是视图算的，而 `PanelView.headerAccessibilityLabel` 自己**又分了一次 `state == .installed`**：

```swift
private var headerAccessibilityLabel: String {
    guard onboardingViewModel.state == .installed else { return "Claudio 面板" }   // ← 第二个 oracle
    let packName = packCards.first(where: \.isSelected)?.name ?? config.selectedPack  // ← 滞后的 @State
    return "Claudio 面板，当前声音包 \(packName)"
}
```

于是「这是哪一屏」有**两个**答案：模型侧的 `state`（`panelSentence` 用它），和视图侧这一支（over `packCards` / `config` 两个只在 `refresh()` 时才追上的 `@State`）。

**Why:** 今天两者**一致** —— T17h′ 补上了 `.onChange(of: actionState)` 里那句 `refresh()`，于是三个会用到 header 的 `say()` 调用点全都排在 `refresh()` 之后（`ViewWiringSuite` 有顺序断言钉着）。但这条一致性靠的是**一条文本绊线**，不是类型。`ClaudioGUI` 是 `@main` executableTarget，harness **一行都 import 不到**，所以 `headerAccessibilityLabel` 这个函数本身**从来没有被任何一个 check 执行过** —— 包括「首次运行时 `config.selectedPack` 回落成 `""`，包名会念成一片空白」这一格。而 `PanelAnnouncementSuite` 给每个时刻喂的都是同一个常量 `H`，所以政策的全矩阵结构上**看不见** header 这一维的任何毛病。

**Context:** 2026-07-12 T17h（`/codex review a3c2d08` 修复期间，本地 + 一次 34-agent 对抗验证双双指出）。修法：**把 `config` / `packCards` 从视图 `@State` 搬进一个 `@MainActor` view-model**。三件事一次到位：① header 变成一个**模型事实**，第二个 oracle 消失（`panelSentence` 独占那次分支）；② harness 第一次能测它（包括空包名那一格）；③ `say(_:)` 可以在 post 的那一趟**重算** header 而不是捕获它 —— 今天做不到，因为 `DispatchQueue.main.async` 的闭包是 `@Sendable` 的、捕不到 `self`（`PanelView` 带着 `@State`，不是 `Sendable`），而一个 `@MainActor` class 是 `Sendable` 的，捕得到。这与 `ViewWiringSuite` 头部那条「真正的结构修法是把视图层拆成可被 import 的 library target」是同一个方向，代价也在同一个量级。

**Effort:** M
**Priority:** P3
**Depends on:** None（与「把视图层拆成可被 import 的 library target」一起做最划算）
