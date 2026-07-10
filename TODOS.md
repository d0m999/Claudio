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

## Completed
</content>
