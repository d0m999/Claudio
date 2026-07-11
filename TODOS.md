# TODOS

## Ship / CI

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

### CoverageState / checkPackIntegrity / Play 的 `fileExists` 不辨目录（3 站点共用）

**What:** `coverageState`（T16 新增）、`checkPackIntegrity` 的 `missingFiles`、`Play` 的解析都用 `FileManager.fileExists(atPath:)` 判存在，不查 `isDirectory`。manifest 把某事件映射到一个**存在的同名目录**时，会报 `present`/`complete`，而 `afplay` 运行时静默失败。

**Why:** 现实里 manifest 值都是文件名、且 `safePackFileURL` 已挡路径逃逸；「存在的同名目录」需用户手动造。纯健壮性，非 T16 引入（继承既有 `doctor`/`play` 语义），但现在多了 `CoverageState` 第三个站点。

**Context:** T16 swift-reviewer（2026-07-11）。修法：三处统一改成「存在且是普通文件」判定，抽一个共享 helper 免第四次重犯。

**Effort:** S
**Priority:** P4
**Depends on:** None

### DesignTokens 规范化 / 生成式 token 模块归并延后（原划归 T14，越界故未做）

**What:** `gui/Sources/ClaudioGUI/DesignTokens.swift` 仍是跨 T7/T15/T16 手抄扩展的 DESIGN.md 调色子集（neutral/brand/surface-2/四事件色/glyph），非一个规范化（理想是从 DESIGN.md 生成）的 token 模块。

**Why:** ENGINEERING.md「T7 非阻断遗留②」原把这项归并划给 T14；T14 落地时刻意不做——越出「state gallery」范围，且会 churn 四个已上线视图换 token 引用、对 gallery 无收益。当前手抄方式功能正常、值与 DESIGN.md 逐一对齐，故为非阻断。

**Context:** T14 swift-reviewer（2026-07-11）+ 实现者自评。`DesignTokens.swift` 两处注释已更正为指向本条。修法：抽一个规范 token 模块（或从 DESIGN.md 生成），四视图改引用它。

**Effort:** M
**Priority:** P3
**Depends on:** None

### T15 真身面板的交互 a11y / 播放 / 接线需真机手验，多项收尾未接线

**What:** 本机只有 CommandLineTools（无 Xcode / 显示），T15 的 AppKit 层只编译验证，多项行为无法在此自动测：`NSStatusItem` 点击↔popover 开关、`.transient` 点外/Esc 关闭、开时首焦点落首个可操作项 + VoiceOver 播报面板标题/当前包、关后焦点回状态项、Tab/Shift+Tab 走 action→mute 序、VoiceOver 逐控件（行 `.contain` 后）导航、切包画廊滚动/点选、Dynamic Type 三级真实布局、reduce-transparency、真实 `NSSound` 试听、静音/切包后 SwiftUI refresh、`NSOpenPanel` 选择器端到端喂进导入管线。此外 onboarding CTA（接管/修复/断开）仍未端到端接线（no-op，属 T17 遗留：需先解决 GUI-bundled `claudio` 的 `executablePath` 语义），状态栏用占位 SF Symbol（`waveform.circle`）非最终定制单色字形。

**Why:** 面板核心逻辑（状态派生 / 写回 / 焦点顺序 / 对比度 / Dynamic Type 表）已下沉 `ClaudioGUICore` 并单测覆盖（helper 769 / gui 372），但交互真身只在真机成立。

**Context:** T15 tdd-guide + a11y-architect + swift-reviewer（2026-07-11）。修法：一台装 Xcode 的 Mac 上做一次 VoiceOver + 键盘走查，按上表逐项确认/修；补最终状态栏图标；T17 收口 onboarding CTA 接线。

**Effort:** M
**Priority:** P2
**Depends on:** 一台装 Xcode 的 Mac + T17

### T16/T15 GUI 小项：绑定失败留孤儿文件 + doc-comment 的 D 编号引用不存在

**What:** ① `EventRowImportViewModel`：导入成功但随后 `bindEventToManifest` 失败时，已复制进包目录的音频文件会留下、不被任何事件引用（孤儿文件）——已通过 `bindResult` 如实上报（非静默），非安全问题，纯整洁。② T15/T16 新文件里约 26 处 doc-comment 引用「ENGINEERING.md T15 D3/D4」等 D 编号，但 ENGINEERING.md 无此细分——溯源/可读性 nit，读者按 D 编号 grep 会落空。

**Why:** 均无功能风险；两项都是「诚实但可更整洁」，攒到某次 GUI 收尾 pass 一起清。

**Context:** T16 security-reviewer + T15/T14 swift-reviewer（2026-07-11）。修法：① 绑定失败时清掉刚复制的文件，或在 UI 上把孤儿文件也纳入下次 doctor/清理；② 把 D 编号软化为「T15/T16」或「(本任务 step D4)」。

**Effort:** S
**Priority:** P4
**Depends on:** None

### 事件行 `unmapped`/`broken` 态：禁用的 previewButton 与 importAffordance 共用同一 `.eventAction` 焦点身份

**What:** `EventRowView` 的 `unmapped`/`broken` 分支**同时**渲染 `importAffordance`（导入绑定按钮）与一个禁用态 `previewButton`（DESIGN.md line 127「试听 ▶ 禁用」），两者都 `.focused(focusedTarget, equals: .eventAction(row.event))`（`EventRowView.swift` 两处）。`panelFocusOrder` 的 doc-comment 却写「每行只渲染其一（never both）、单 `.eventAction` 槽」——不变式为假。

**Why:** 两个视图声明同一 `@FocusState` 身份，程序化设 `focusedTarget = .eventAction(event)` 时 SwiftUI 落到哪个未定义；且禁用的 previewButton 仍在 a11y 树里，VoiceOver 扫过 unmapped/broken 行会多念一个「试听 …（不可用）」冗余停靠。今天 `applyFirstFocus` 只设 `order.first`（永不是某行的 `.eventAction` 除非首事件、且首焦点问题属 T15 真机手验范畴），故无功能破坏，纯焦点模型一致性 + 一个冗余 VO 停靠。

**Context:** T14/T15/T16 pre-landing 多模型评审（2026-07-11，a11y-architect）。修法：给禁用占位的 previewButton 与 importAffordance 各自不同的 `PanelFocusTarget` case（或禁用态那个不绑 `.focused`），并修正 `PanelFocusOrder` 的 doc-comment。

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

### 补 GUI/helper 单测缺口（4 项 lake-not-ocean）

**What:** ① `setEventEnabled` 的 `.configWriteFailure` 路径（父目录被普通文件挡住）——`selectPack`(`UseSuite`) 有此 fixture 测、镜像它的 `setEventEnabled` 没有；② `contrastRatio` 的 `#` 前缀分支（doc-comment 承诺支持 `#RRGGBB`，`ContrastSuite`/`DesignToken` 全用裸 6 位）；③ `bindEventToManifest` 顶层是合法 JSON 但非对象（数组/标量）的 fail-closed 分支（现只测了非法 JSON 语法 + `events` 字段非对象，没测顶层非对象）；④ `setEventEnabled` 真并发写（`DispatchQueue.concurrentPerform`）——现仅有「一个持锁者 + 一个等待者」的 lock-busy 测，未证真并发下 read-modify-write 不撕裂。

**Why:** 四处都是「lake」：各自镜像已有 happy-path 测的结构、钉住一条当前未覆盖的分支。无功能风险，纯回归网加固。（T16 计数口径修复的混合态回归测已在本次落地补上，不在此列。）

**Context:** T14/T15/T16 pre-landing 评审（2026-07-11，pr-test-analyzer）。测试专家已给出每项的最小 `suite(...)/expect(...)` skeleton。

**Effort:** S
**Priority:** P4
**Depends on:** None

### popover 尺寸硬编码 312×400，最大 Dynamic Type 档下不跟随 PanelView 加宽

**What:** `MenuBarController.swift` init 里把 `popover.contentSize = NSSize(width: 312, height: 400)` 写死。注释只声明 height 由 `NSHostingController` 的 intrinsic content 在运行时驱动，width 没有。而 `PanelView.body` 在 `.accessibility2…5` 档会把自身 `.frame(width: layoutAdaptation.panelWidth)` 提到 360pt。

**Why:** 若 `NSHostingController` 没开 `.preferredContentSize` 之类的 sizing 传导，SwiftUI 想要的 360pt 宽不会反映到 popover 的 contentSize width，最大字号下"加宽 popover"落空、内容可能被裁。仅在最高 Dynamic Type 档触发，属边角，但确是未验证的假设。修法：把 `layoutAdaptation.panelWidth`（或实际内容尺寸）回传给 `MenuBarController` 更新 `contentSize`/`preferredContentSize`，不硬编码；或给 hostingController 开 intrinsic-size 传导后手动在真机上验一遍各档。

**Context:** codex review（2026-07-11，commits e4dd25f/6b9cb66）P2。Claude 侧核验：硬编码属实，是否裁切取决于 `NSHostingController` sizing 行为，需真机各档验证。AppKit/SwiftUI 尺寸传导本任务无法单测，留真机手验。

**Effort:** S
**Priority:** P3
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

## Completed

