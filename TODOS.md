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

## Completed
</content>
