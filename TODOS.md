# TODOS

## Ship / CI

### `play.lock` 被 config / settings 写者共用 —— 任何一次设置写都可能静默吞掉一声提示音

**What:** `ClaudioPaths.lockFile`（`play.lock`）今天被**五个互不相干的临界区**共用：`Play.swift:190`（去抖时间戳 + spawn afplay —— 它唯一该保护的东西）、`EventEnabled.swift:63`（写 config.json）、`Use.swift:72`（写 config.json）、`SettingsInstaller.swift:162/216`（写 **settings.json**）。而 `claudio play` 拿不到这把锁时的行为是 `.skippedDebounce` —— **静默不放声音**（这是故意的：hook 绝不能阻断 Claude Code）。

**Why:** 于是每一次「点静音 / 切包 / 跑 `claudio install`」都是一个**会吞掉提示音的窗口**：恰好落在窗口里的 Claude Code 事件，那声提示音直接消失，无任何错误、无任何日志。这打在产品的根上（「不回头也知道状态」）—— 用户在调设置的那几秒，恰好错过了他装这个 app 就是为了不错过的那声。

反方向的那一半**项目已经知道了**，只是把它当成了 UI 问题而不是锁设计问题 —— `PanelView.swift` 的注释原文：「`.lockBusy` 尤其是**真会发生**的，不是理论值：`setEventEnabled`/`selectPack` 与 `claudio play` 抢同一把 `play.lock`…点静音正好撞上」。修法是给它显示一句「请稍后重试」，而不是让它不再发生。

更讽刺的是**正确的原则早已写在仓库里**：`Paths.swift:64-66` 为 `logLockFile` 写着「Deliberately a **separate** lock from `lockFile`（`play.lock`）—— logging must never contend with, or be gated by, `play`'s own debounce lock.」闸门建了，只推开了日志那一格。这正是本仓库自己记下的 learning `gate-built-but-not-rolled-out`，同一形状第三次。

**Context:** 2026-07-11 `/plan-eng-review`（主音量滑块）期间，Codex 外部声音（gpt-5.5 high）指出，Claude 侧逐条源码复核确认。**分离是安全的，三点源码实证**：① `play` 读 config 在**锁外**（`Play.swift:180` 的 `loadPlayConfig` 在 `withNonBlockingLock` 之前）—— 它从来不需要排斥 config 写者；② config 写走 `Data.write(options: .atomic)`（`ConfigMutation.swift:176`）即 `rename(2)`，并发读者只会看到旧的完整文件或新的完整文件，绝不撕裂 —— 读侧本来就不需要锁；③ `play` **从不读** settings.json。

修法：新增 `ClaudioPaths.configLockFile`（`~/.claudio/config.lock`，串行三个 config 写者）与 `ClaudioPaths.settingsLockFile`（`~/.claudio/settings.lock`，串行 install/uninstall）；`play.lock` 退回只管 play 的去抖。回归测试钉住两条（**今天都会 RED，那正是 bug**）：持有 `play.lock` 时三个写者仍成功；持有 `config.lock` 时 `playSoundEvent` 仍发声。

一份**未测试的**探索性实现在分支 `feat/master-volume-slider` @ `cbc02f0`（helper 能编译，零测试，勿直接信任）。

**升级窗口注记**：旧二进制（拿 play.lock 写 config）与新二进制（拿 config.lock）并存时不互相串行。因为写是原子 rename，最坏是丢一次更新、绝不撕裂；且 GUI 是单进程、`claudio use` 是手动调用，实际不可达。

**Effort:** M
**Priority:** P1
**Depends on:** None（与主音量滑块无关，强烈建议**单独一个 PR**）

### Setup.swift 的包复制不是原子的，中断后无法自愈

**What:** `performFirstRunSetup` 的 dedupe guard（`guard !FileManager.default.fileExists(atPath: destination.path) else { continue }`）只看目标目录是否存在，不看它是否复制完整。`copyItem` 本身不是原子操作。

**Why:** 如果 `claudio setup` 在复制某个包的过程中被打断（Ctrl-C、磁盘满、SIGKILL、笔记本合盖休眠），目标目录会存在但内容不全。之后任何一次重跑都会因为"目录已存在"永久跳过重新复制——这份损坏永远无法通过文档里教的"重跑 claudio setup"自愈。

**Context:** 红队在 `/ship` pre-landing review（2026-07-10，commit 附近 f812af4）里挖出来的，跟同一轮已经修掉的"默认选包只看这次新复制的包"是同一类"中断态恢复不了"问题，但这一个改动更大（需要 staging 目录 + rename，或者校验完整性再决定是否跳过），这次先不做。v1 只有一个内置包（minimal-chime），复制失败的窗口很小，暂时接受这个风险。

**Effort:** M
**Priority:** P2
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

此外仍未接线：onboarding CTA（接管/修复/断开）**全是 no-op**（T17 遗留：需先解决 GUI-bundled `claudio` 的 `executablePath` 语义）—— 真机确认过：点「修复」后 `~/.claude/settings.json` 的 shasum 不变、`~/.claudio/bin` 仍不存在。状态栏仍用占位 SF Symbol（`waveform.circle`）非最终定制单色字形。

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

**Context:** 2026-07-11 `/ship` plan-completion 审计发现；同日 `/plan-eng-review`（四段 + Codex 外部声音）产出锁死方案，**并推翻了本条原有的两句修法**：

- ~~「DESIGN.md 已定义其视觉」~~ —— **假的**。DESIGN.md 全文 grep `滑块|slider|轨道|track|thumb|拨杆` **零命中**，滑块长什么样从来没人定过。而 macOS 原生 `Slider` 的填充色默认跟**系统强调色**（用户在系统设置里选的），会把一个设计系统外、且 claudio 控制不了的颜色带进面板 —— 直接违反 DESIGN.md「品牌强调只有一个（黏土）」与 `DesignTokens.swift:17`「不得新增 DESIGN.md 里没有的颜色」。
- ~~「第三个写者照抄即可」~~ —— **照抄就是 bug**。`setEventEnabled` 拿的是 `play.lock`（见本文件第一条 P1），逐帧写盘会把「吞掉提示音的窗口」开成一片。

**锁死的方案（14 项决议，全文见 `/plan-eng-review` 产出）要点：**
- **松手才写**（`Slider(onEditingChanged:)`）—— 该值没有实时消费者（`claudio play` 每次 spawn 重读 config），拖动中间值无人可见，逐帧写盘是纯成本。ENGINEERING.md 交互状态覆盖表的「拖动即时改 config」需改为「松手即时落盘」并记理由。
- **但「拖动不写」不能变成「丢数据」**：popover 中途关闭 / app 退出时 `onEditingChanged(false)` 未必补发 —— 必须有 `onDisappear` + `willTerminate` 的 dirty flush。绝不把正确性押在 SwiftUI 会补发回调上。
- **不变不写**：`drag(to:)` 只在 `isDragging` 时接受（`onEditingChanged(true)` 才置位），使 SwiftUI 的 render-time 网格吸附**无法**触发写 —— 用户手改的 `master_volume: 0.42`（读路径合法、面板照常显示、但不在 0.05 网格上）不碰就永远活着。
- **失败即回滚**：写失败 → 滑块弹回磁盘值 + 错误行。UI 绝不显示磁盘上没有的值。
- **先钳制再写**：越界值绝不落盘（spec 要求）；非有限值绝不到达 `JSONSerialization`（否则 ObjC 异常穿透 Swift `do/catch`，进程 abort，exit 134）。
- **`freshSelectedPack` 强制调用方给**，不像 `setEventEnabled` 那样传 `""` —— 一份 `selected_pack: ""` 的 config 会让 play 读得到却解析不到包，即一份看起来正常的**静音**配置。
- **step 0.05**（21 档，默认 0.8 恰在网格上）；`.tint(ClaudioColor.clay(colorScheme))`（clay 亮色 3.97:1 过非文本 ≥3:1，合法）+ DESIGN.md 补登滑块视觉。
- **把「一次拖动写几次盘」下沉成 `VolumeDragSession` 纯状态机**并单测 + 变异验证 —— 否则这条 P1 决策只活在注释里，而注释拦不住任何人（`PanelFocusOrder.swift:132-138` 记着本项目在同一形状上吃过的亏）。
- 试听（`AudioPreviewPlayer`）**必须同批修**：它今天完全不理 `master_volume`（`NSSound` 默认满音量），滑块一上线就会「拖了没反应」。

**Depends on:** 本文件第一条 P1（`play.lock` 分离）—— 不先修它，即使松手才写也仍留一个会吞提示音的窗口。

**Effort:** M
**Priority:** P2

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

### 试听（`NSSound.volume`）与真实播放（`afplay -v`）的增益曲线是否一致，未经证明

**What:** 主音量滑块落地后，面板的「试听 ▶」会用 `NSSound.volume` 施加 `master_volume`，而真实 hook 播放走 `afplay -v`。两者**同为 0…1 标量**（`NSSound.h:65` 明确 `volume` 是单个 sound 的音量、范围 0…1、不影响系统音量；`afplay -h` 只说 `-v/--volume VOLUME set the volume`），但**没有任何文档说明二者的增益曲线（线性振幅 vs 感知/对数）相同**。

**Why:** 如果曲线不同，同一个 `master_volume` 值下「试听听到的响度」与「真实提示音的响度」会有落差 —— 用户按试听调好的音量，实际用起来偏大或偏小。今天两者都极可能是线性振幅乘子（这是这类 API 的常规），所以风险低；但它是一个**未验证的假设**，不该被当成已知。

**Context:** 2026-07-11 `/plan-eng-review` 的 Codex 外部声音提出（Claude 侧未想到）。修法两条，二选一：① 真机 A/B 实测两条路径在同一 `master_volume` 下的实际响度，一致则把结论写进 `Volume.swift` 的注释（把假设升级成事实）；② 若不一致，试听改走 `afplay -v` 本身（复用 `AfplayVolume.afplayArgument`，与真实播放路径逐字相同）—— 代价是引入进程 spawn 延迟与一个新失败模式（afplay 缺失），故不作为默认选项。

**Effort:** S
**Priority:** P3
**Depends on:** 主音量滑块落地（在那之前这条不可观察）

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
