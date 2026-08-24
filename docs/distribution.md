# claudi0 分发、安装与恢复指南

**支持范围：** macOS 12+，Apple Silicon 与 Intel。正式 Release 为 universal、Developer ID 签名并经过 Apple notarization 的 DMG。

产品概览与快速开始见 [中文 README](../README.zh-CN.md)；本文聚焦安装、宿主配置边界、修复和卸载。

## 安装方式一：GitHub Release DMG（主渠道）

1. 从 [GitHub Releases](https://github.com/d0m999/Claudio/releases) 下载同一版本的 `claudi0-<version>.dmg` 和 `SHA256SUMS.txt`。
2. 在下载目录验证：

   ```bash
   shasum -a 256 -c SHA256SUMS.txt
   ```

3. 双击挂载 DMG，把 `claudi0.app` 拖入 `/Applications`。
4. 从“应用程序”启动。Claudio 是菜单栏 app，不显示 Dock 主窗口。

Release workflow 有两条严格分离的路径：从 `main` 手动运行 RC `workflow_dispatch` 只生成带
commit SHA 的签名、公证 artifact，不创建 tag、GitHub Release 或更新 tap；只有严格的
`vMAJOR.MINOR.PATCH` tag 才进入 publish job。RC dispatch 必须同时提供 `version=0.1.0`、获批的
40 位 `target_commit` 和 `release_authorized=true`；最后一项只是“已另行取得运行授权”的记录，
不能自行替代授权。workflow 会把目标 SHA 与触发 SHA、checkout HEAD 同时核对，任一漂移即失败。

两条路径都把同一版本注入 CLI、app `Info.plist` 和 DMG 名称。helper 与 app 分别核对 Developer ID
team、secure timestamp 和 hardened runtime；app 先独立 notarize/staple，再进入另行签名、
notarize/staple 的 DMG。workflow 从最终只读挂载 DMG 重新核对 app 字节、架构、helper/Info.plist
版本、资源、symlink、签名、Gatekeeper、公证票据、体积和校验和。RC artifact 额外包含
`RC_MANIFEST.json`，用于把 run、artifact、commit、版本、DMG 文件名和 SHA-256 绑定起来；下载后用
`scripts/verify-release-candidate.sh` 从唯一验收账本读取期望 identity，对照 GitHub 当前 main run、
精确 release workflow ID/path、artifact 元数据、官方 artifact archive SHA-256 digest 和本地解压
字节复验。调用者不能用独立参数覆盖账本中的 run、commit 或 artifact：

```bash
bash scripts/verify-release-candidate.sh \
  --artifact-dir <downloaded-artifact-directory> \
  --ledger docs/release-acceptance-0.1.0.md
```

复验器在下载前拒绝 GitHub API 声明超过 25 MiB 的 artifact，并在解析或哈希前限制
ledger/manifest、checksum 与 DMG 的大小；这些边界为当前 release size budget 保留了余量。

缺少任一 Apple 凭据（包括 `APPLE_DEVELOPER_TEAM_ID`）时直接失败，不回退为 ad-hoc 发布。

`0.1.0` 的人工与真机门禁记录在 [`release-acceptance-0.1.0.md`](release-acceptance-0.1.0.md)。RC workflow 通过不等于首发验收通过；Intel/macOS 12、VoiceOver、真实宿主和真实回执缺一项都不得创建首发 tag。

## 本机 pre-RC 基线

在已经提交且没有 tracked/untracked 改动的 clean checkout 上运行：

```bash
bash scripts/local-pre-rc.sh
jq . dist/local-pre-rc-report.json
```

入口会在每个 gate 前后复验同一个 40 位 `HEAD`，并记录当前 macOS、CPU 架构、dev bundle
架构和 ad-hoc 签名。它依次运行 patch whitespace、双 harness、Debug GUI build、localization、
`dev-bundle` 与 release-size gate；任何失败、HEAD 漂移或非 clean checkout 都不会留下旧的成功报告。

报告固定标记为 `pre_rc_only`：单架构结果不满足 universal，ad-hoc 签名不满足 Developer ID；
notarization、stapling、Gatekeeper、DMG checksum 与 Intel 真机均为 `not_evaluated`。该入口不运行
GitHub release workflow、不读取 Apple/GitHub secrets，也不能替代签名 universal RC、#18/#19
账本或正式人工验收。

## 安装方式二：Homebrew（可选渠道）

只有在对应 Release 启用了外部 tap 时才使用：

```bash
brew install --cask d0m999/tap/claudi0
```

Homebrew tap 不是 GitHub Release 的前置条件。tap job 未启用或被跳过时，不影响已经完成的签名、公证和 GitHub Release。cask 不包含 `zap`，卸载时不会自动删除 `~/.claudio/`。

## 首次启动与宿主连接

首次启动只准备 shared runtime：

- 把 helper 与内置声音包安全发布到 `~/.claudio/`；
- 尚未选择声音包时选择一个可用的默认包；
- 检查 helper 是否为可执行正规文件；
- 不自动连接 Claude Code 或 Codex。

面板始终把两个宿主作为等权声音来源。Codex `4/5` 是正常能力，不是故障：当前缺少与 `StopFailure` 对应的原生事件。

### Claude Code

在 Claude Code 详情中点“连接”。Claudio 会向 `~/.claude/settings.json` 外科式追加自己的 hook：

- 保留已有 hook、matcher、数组顺序及未知字段；
- 首次修改已有文件前创建 `settings.json.claudio.bak`；
- 重复连接不会制造重复条目或双响；
- 旧的 `claudio play` 连接会显示为 legacy，需要显式升级才获得真实回执。

连接后在 Claude Code 提交一条真实提示词。只有当前 installation ID 的回调产生回执后，状态才是已激活；写好 JSON 本身不是激活证据。

### Codex

在 Codex 详情中点“连接”。Claudio 只在 `~/.codex/hooks.json` 中管理 `UserPromptSubmit`、`Stop`、`PermissionRequest` 和 `SubagentStop` command hook；不会接管 `notify`，不会写私有 trust 数据，也不会删除第三方 hook。

写入后：

1. 在 Codex 运行 `/hooks`；
2. 确认 Claudio hooks；
3. 提交一条真实提示词；
4. 在 Claudio 点“重新检测”。

只有当前 installation ID 的 `UserPromptSubmit` 回执才能证明新增任务开始 hook 已激活。其它当前代次回执仍用于最近事件诊断，但不能代替首次确认。

### Terminal 等价命令

```bash
# 查看 shared runtime 与两个宿主
/Applications/claudi0.app/Contents/Resources/bin/claudi0 integrations status

# 分别连接
/Applications/claudi0.app/Contents/Resources/bin/claudi0 integrations connect claude-code
/Applications/claudi0.app/Contents/Resources/bin/claudi0 integrations connect codex
```

`claudi0 setup` 只保留旧版兼容语义：准备 shared runtime 并连接 Claude Code legacy hooks，不会替用户激活 Codex。旧 hooks 继续调用 `~/.claudio/bin/claudio`，品牌入口 `~/.claudio/bin/claudi0` 与它并存。

## 用户文件与真实回执

- Claudio 自有状态：`~/.claudio/`。
- Claude Code 配置：`~/.claude/settings.json`；一次性备份为相邻的 `.claudio.bak`。
- Codex hooks：`~/.codex/hooks.json`；一次性备份为相邻的 `.claudio.bak`。
- 回执：`~/.claudio/integrations/receipts/<host>/<event>.json`，权限 `0600`。

回执只包含 installation ID、宿主/事件、时间和脱敏播放结果；不包含提示词、响应内容、项目路径、会话内容或音频绝对路径。不要手改回执伪造激活状态。

## Gatekeeper 与完整性排障

正式 Release 已签名和公证，正常安装不需要“仍要打开”，也不依赖 `xattr` 清除 quarantine。如果 macOS 拒绝打开：

```bash
spctl --assess --type open --context context:primary-signature -vv claudi0-<version>.dmg
codesign --verify --deep --strict --verbose=2 /Applications/claudi0.app
```

同时重新核对 `SHA256SUMS.txt`。任何失败都应视为下载损坏、非官方构建或 Release 完整性问题；删除该文件，从官方 Release 重新下载，并在仍可复现时提交 issue。不要把关闭 Gatekeeper 或清除 quarantine 当作安装步骤。

本地运行 `scripts/dev-bundle.sh` 得到的是 ad-hoc 开发包，只用于当前机器走查；它不具备正式 Release 的身份、公证和跨架构保证。

## 声音不响或 hook 未激活

1. 用面板的试听按钮检查播放链。试听绕过宿主 hook。
2. 运行：

   ```bash
   ~/.claudio/bin/claudi0 integrations status
   ~/.claudio/bin/claudi0 doctor
   tail -20 ~/.claudio/claudio.log
   ```

3. Claude Code 连接后必须提交一条新提示词。
4. Codex 必须先通过 `/hooks` 确认，再提交提示词；`4/5` 无需修复。
5. 检查系统输出音量、Claudio 主音量和逐事件静音。

只有 shared runtime 不可用或已连接宿主损坏才会让新版 `doctor` 返回失败；未安装或未连接的宿主是提示状态。

## 从 app bundle 修复 shared runtime

helper 或内置声音包缺失时，运行：

```bash
/Applications/claudi0.app/Contents/Resources/bin/claudi0 setup
```

一定要使用 app bundle 内的路径。`~/.claudio/bin/claudi0 setup` 看不到 `Contents/Resources/packs/`，无法补回缺失的 factory pack。

`setup` 会：

- 原子更新 helper，并校验它可执行；
- 复制缺失的内置包，不覆盖同名用户自定义包；
- 把残缺包原样搬到 `packs/.<id>.broken-…` 后再装干净副本；
- 在当前选择已失效时换到一个确实可解析的包并明确报告；
- 幂等补齐 Claude Code legacy hooks。

如果没有任何可用包、helper 不可执行或 `config.json` 无法安全解析，`setup` 会在新增 hook 前失败关闭，不留下“看似连接但永远静音”的状态。

## 更新

Homebrew：

```bash
brew upgrade --cask claudi0
```

DMG：下载新版本并把新的 `claudi0.app` 拖入 `/Applications` 覆盖旧 app。

更新不会覆盖 `~/.claudio/`、用户声音包、宿主配置、回执或备份。更新后可用 `claudi0 integrations status` 重新检测。

## 断开与卸载

先分别断开宿主：

```bash
~/.claudio/bin/claudi0 integrations disconnect claude-code
~/.claudio/bin/claudi0 integrations disconnect codex
```

断开一个宿主只删除该宿主中 Claudio 自己的条目；不会删除另一宿主、第三方 hooks、声音包或 shared runtime。`claudi0 uninstall` 仍只是断开 Claude Code legacy hooks 的兼容别名。

然后卸载 app：

```bash
brew uninstall --cask claudi0
```

或把 `/Applications/claudi0.app` 移到废纸篓。

两种方式都保留 `~/.claudio/`。要彻底清理，先备份需要的声音包，再运行 `open ~/.claudio` 并在 Finder 中手动移到废纸篓。界面偏好可用 `defaults delete com.claudio.app` 单独清除。

## 从一次性备份恢复宿主配置

`.claudio.bak` 是首次写入前的原始快照，不会吸收之后由宿主、用户或第三方工具写入的变化。先断开 Claudio，再比较：

```bash
diff -u ~/.claude/settings.json.claudio.bak ~/.claude/settings.json
diff -u ~/.codex/hooks.json.claudio.bak ~/.codex/hooks.json
```

不要无条件覆盖当前配置。只有在明确接受丢弃首次连接之后的修改时，才应退出对应宿主、另存当前文件并手动恢复备份。

## 相关文档

- [README](../README.md)
- [中文 README](../README.zh-CN.md)
- [贡献指南](../CONTRIBUTING.md)
- [安全策略](../SECURITY.md)
- [工程规范](../ENGINEERING.md)
- [声音包标准](pack-standard.md)
- [Apple：Packaging Mac software for distribution](https://developer.apple.com/documentation/xcode/packaging-mac-software-for-distribution)
- [Apple：Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
- [GitHub：Licensing a repository](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/licensing-a-repository)
