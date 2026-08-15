# Claudio

[English](README.md) | [简体中文](README.zh-CN.md)

Claudio 是面向 Claude Code 与 Codex 的本地优先 macOS 声音中心。它把宿主生命周期事件转换成彼此可辨、可试听、可单独静音的提示音，同时让宿主连接、声音包、诊断结果和真实激活回执都保持可见。

![Claudio 菜单栏面板预览，显示 Claude Code、Codex 状态和五种语义事件](docs/images/claudi0-overview.png)

_界面预览；原生 app 会跟随 Claudio 内选择的语言和 macOS 外观。_

## 核心功能

- 一个菜单栏 app 同时管理 Claude Code 与 Codex，两边可独立连接或断开。
- 五种声音语义：任务开始、本轮结束、执行中断、待响应、子任务完成。
- 每事件静音、主音量、试听、声音包切换、星标和本地音频导入。
- 只追加/摘除 Claudio 自己的 hook，保留第三方条目、未知字段和数组顺序。
- 写配置前创建一次性备份；写入后仍需真实宿主事件产生回执，才显示为已激活。
- UI 诊断与 `claudi0 doctor` 自检。
- 中英文界面、键盘操作、随文字大小重排及 VoiceOver 语义。

## 系统与宿主要求

- macOS 12 Monterey 或更高版本。
- Apple Silicon（`arm64`）与 Intel（`x86_64`）；Release DMG 内为 universal 二进制。
- Claude Code 与 Codex 均为可选，可只连接其中一个。
- Claude Code 已验证兼容下限为 2.1.201。更旧版本可能不产生 `StopFailure`，Claudio 会给出警告，但不会阻断其它事件。
- Codex 需要支持 `~/.codex/hooks.json` 的可组合 hooks；写入后还要通过 `/hooks` 确认。

## 安装

### GitHub Release DMG（主安装方式）

1. 从 [GitHub Releases](https://github.com/d0m999/Claudio/releases) 下载同一版本的 `claudi0-<version>.dmg` 与 `SHA256SUMS.txt`。
2. 把两个文件放在同一目录并校验下载：

   ```bash
   shasum -a 256 -c SHA256SUMS.txt
   ```

3. 打开 DMG，把 `claudi0.app` 拖到 `/Applications`。
4. 从“应用程序”启动 `claudi0`。它是纯菜单栏 app，不出现 Dock 主窗口是正常行为。

正式 Release 必须经过 Developer ID 签名、hardened runtime 和 Apple notarization；缺少任一签名/公证凭据时 workflow 会直接失败，不会降级发布 ad-hoc 构建。

### Homebrew（可选渠道）

某个 Release 启用 Homebrew tap 后，安装命令为：

```bash
brew install --cask d0m999/tap/claudi0
```

GitHub Release DMG 始终是主安装包。Homebrew job 默认可跳过；`brew uninstall` 也不会自动删除 `~/.claudio/`。

## 第一次连接

首次打开 Claudio 只会在 `~/.claudio/` 准备 shared runtime、内置声音包和默认选择；它不会静默改写 Claude Code 或 Codex 配置。

### 连接 Claude Code

1. 点菜单栏里的 Claudio 图标。
2. 打开 Claude Code 声音来源详情，点“连接”。
3. 回到 Claude Code，提交一条真实提示词。
4. 必要时在 Claudio 中点“重新检测”。只有当前连接代次收到真实 hook 回调后，才会显示 `5/5 已就绪`。

Claudio 只在 `~/.claude/settings.json` 中添加自己拥有的 command hook。原有 hook、matcher、数组顺序及未知字段都会保留；首次写入已有文件前会生成 `~/.claude/settings.json.claudio.bak`。

### 连接 Codex

1. 打开 Codex 声音来源详情，点“连接”。
2. 在 Codex 中运行 `/hooks`，确认 Claudio hooks。
3. 再提交一条真实提示词，并回到 Claudio 重新检测。
4. `4/5 已就绪` 是正常健康状态：Codex 当前没有与 Claudio“执行中断”（`StopFailure`）对应的原生事件。

Claudio 只管理 `~/.codex/hooks.json` 中自己的 command 条目；不会接管单命令 `notify`，不会读写私有 trust 数据，也不会删除第三方 hook。首次写入已有文件前会生成 `~/.codex/hooks.json.claudio.bak`。

也可以从 Terminal 完成同样的操作：

```bash
# 只读查看 shared runtime 与两个宿主
~/.claudio/bin/claudi0 integrations status

# 分别连接
~/.claudio/bin/claudi0 integrations connect claude-code
~/.claudio/bin/claudi0 integrations connect codex
```

`claudi0 setup`、`install`、`uninstall` 是为旧版 Claude Code 流程保留的兼容命令，不会替你激活 Codex。

## 配置、备份、用户数据与隐私

| 路径 | 内容与边界 |
|---|---|
| `~/.claudio/config.json` | 当前声音包、主音量、逐事件开关、星标 |
| `~/.claudio/packs/` | 内置包的用户副本和自行导入的声音包 |
| `~/.claudio/bin/` | 宿主 hook 调用的 shared helper |
| `~/.claudio/claudio.log` | 小型滚动诊断日志 |
| `~/.claudio/integrations/receipts/` | 权限为 `0600` 的真实 hook 回执 |
| `~/.claude/settings.json` | Claude Code 配置；只外科式修改 Claudio 自有条目 |
| `~/.claude/settings.json.claudio.bak` | 首次写入前的一次性原始快照（源文件原本存在时） |
| `~/.codex/hooks.json` | Codex 可组合 hooks；只外科式修改 Claudio 自有条目 |
| `~/.codex/hooks.json.claudio.bak` | 首次写入前的一次性原始快照（源文件原本存在时） |

Claudio runtime 没有网络客户端、遥测、分析或云端上传路径。声音、配置、回执与日志都留在本机。回执只包含 installation ID、宿主/事件标识、时间和脱敏播放结果；不会保存提示词、响应正文、项目路径、会话内容或音频绝对路径。

随 app 分发的声音素材使用独立许可，完整来源与哈希见 [packs/LICENSES.md](packs/LICENSES.md)。

## 排障

### Gatekeeper 阻止打开

官方 Release 正常情况下不需要“仍要打开”，也不需要任何 quarantine 清除命令。如果 Gatekeeper 拒绝：

1. 删除可疑 DMG，只从项目 Releases 页面重新下载 DMG 与校验和。
2. 重新运行 `shasum -a 256 -c SHA256SUMS.txt`。
3. 验证下载容器与安装后的 app：

   ```bash
   spctl --assess --type open --context context:primary-signature -vv claudi0-<version>.dmg
   codesign --verify --deep --strict --verbose=2 /Applications/claudi0.app
   ```

不要用 `xattr` 绕过 Gatekeeper。正式包验证失败属于 Release 完整性问题，应通过 issue 报告，而不是安装步骤。

### 找不到菜单栏图标

Claudio 没有常驻 Dock 窗口。先检查菜单栏折叠/溢出区域，再运行：

```bash
open /Applications/claudi0.app
```

### hook 已写入但还没激活

- Claude Code：连接后必须新提交一次提示词；仅写好配置不等于收到真实回执。
- Codex：先执行 `/hooks` 并确认 Claudio hooks，再提交提示词，最后重新检测。
- 用只读命令核对两边：

  ```bash
  ~/.claudio/bin/claudi0 integrations status
  ```

不要通过手改 `receipts/` 强行点亮状态：只有当前 installation ID 的真实回调才有效。

### 没有声音

1. 在 Claudio 中试听当前事件。试听正常说明播放链基本可用，应继续排查宿主激活。
2. 检查 macOS 输出音量、Claudio 主音量和该事件是否静音。
3. 运行只读自检并查看最近日志：

   ```bash
   ~/.claudio/bin/claudi0 doctor
   tail -20 ~/.claudio/claudio.log
   ```

4. 如果 helper 或内置声音包缺失，从 app bundle 修复：

   ```bash
   /Applications/claudi0.app/Contents/Resources/bin/claudi0 setup
   ```

这条修复必须从 app bundle 运行；`~/.claudio/bin/` 中的 helper 看不到 app 内的 factory packs，无法补回缺失声音包。`setup` 是幂等兼容入口：它不会覆盖同名用户自定义包；检测到残缺包时会先原样搬到备份目录，再发布干净副本。

更完整的分发排障见 [docs/distribution.md](docs/distribution.md)。

## 更新、断开、卸载与恢复

更新 app 不会覆盖 `~/.claudio/`、宿主配置、真实回执或一次性备份。Homebrew 用户可以运行：

```bash
brew upgrade --cask claudi0
```

卸载前先分别断开宿主，让 Claudio 精准摘除自己的条目：

```bash
~/.claudio/bin/claudi0 integrations disconnect claude-code
~/.claudio/bin/claudi0 integrations disconnect codex
```

然后二选一：

```bash
brew uninstall --cask claudi0
```

或把 `/Applications/claudi0.app` 移到废纸篓。

上述操作都不会删除 `~/.claudio/`、声音包、日志、回执和 `.claudio.bak`。如果需要彻底清理：

1. 先复制想保留的声音包。
2. 在 Finder 中打开并手动移到废纸篓：

   ```bash
   open ~/.claudio
   ```

3. 如需清除 app 的界面偏好，可自行运行 `defaults delete com.claudio.app`。

备份是 Claudio 首次写入前的快照，不是持续同步副本。宿主或其它工具后来可能增加了新配置，因此不要直接覆盖当前文件。先比较：

```bash
diff -u ~/.claude/settings.json.claudio.bak ~/.claude/settings.json
diff -u ~/.codex/hooks.json.claudio.bak ~/.codex/hooks.json
```

只有在明确愿意放弃首次连接之后的改动时，才应先另存当前文件、退出对应宿主，再用备份恢复。

## 本地构建与测试

安装 Xcode Command Line Tools 和 Swift 6 后，在仓库根目录运行：

```bash
# 两套依赖自由的测试 harness
swift run --package-path helper claudio-tests
swift run --package-path gui claudio-gui-tests

# GUI 产品构建
swift build -c debug --package-path gui --product ClaudioGUI
swift build -c release --package-path gui --product ClaudioGUI

# 静态检查与本机 app 组装
jq empty gui/Sources/ClaudioLocalization/Resources/Localizable.xcstrings
bash scripts/dev-bundle.sh
bash scripts/check-release-size.sh dist/claudi0.app
git diff --check
```

本地 CLI/app 版本固定显示 `0.0.0-dev`。Release workflow 只接受严格的 `vMAJOR.MINOR.PATCH` tag，并把同一个无 `v` 版本注入 CLI、app `Info.plist`、DMG 文件名、`SHA256SUMS.txt`、Release 标题和可选 cask。

提交 PR 前请阅读 [CONTRIBUTING.md](CONTRIBUTING.md)。CI 全绿仍不能替代原生 macOS、VoiceOver、键盘/焦点、Apple Silicon/Intel 以及 Claude Code/Codex 真实回执验收。

## 安全、社区与许可证

安全问题请按 [SECURITY.md](SECURITY.md) 私下报告，不要在公开 issue 中粘贴宿主配置、回执或日志。社区参与遵循 [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md)。

Claudio 源代码采用 [MIT License](LICENSE)，Copyright © 2026 d0m999。内置声音素材沿用 [packs/LICENSES.md](packs/LICENSES.md) 中分别列明的许可。
