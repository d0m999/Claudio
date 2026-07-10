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

## Completed
</content>
