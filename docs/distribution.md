# claudi0 安装指南

> 本文档描述 v1 发布后的安装流程；`.github/workflows/release.yml` 尚未真正跑过一次 tag release，
> 下方的 Homebrew tap / GitHub Releases 链接在首个版本发布前不会有实际内容。

**Supported:** macOS 12+，v1 为未签名 ad-hoc 构建

---

## 免责声明：当前未签名

claudi0 v1 分发的是**未签名 ad-hoc 构建**（开发者签名，非 Apple Developer 签名）。这意味着：
- 首次打开时，macOS 会拦截并要求你确认才能运行
- **这不是 bug，是苹果对未签名应用的安全审查**
- 我们即将上线 Apple Developer 签名 + 公证（预计接下来的版本），消除这个摩擦

**适用人群**：这个版本面向熟悉 macOS 系统的技术用户，能自行绕过 Gatekeeper。面向非技术用户的零摩擦版本将在签名公证完成后推出。

---

## 安装方式 1：Homebrew（推荐，若 tap 已配置）

```bash
brew tap d0m999/homebrew-tap
brew install --cask claudi0
```

首次打开时，按下方【在新系统上打开】或【在旧系统上打开】的指引操作。

---

## 安装方式 2：手动下载 DMG

1. **下载最新 DMG**  
   前往 [GitHub Releases](https://github.com/d0m999/Claudio/releases) 找到最新版本的 `claudi0-<version>.dmg`

2. **挂载 DMG**  
   下载完成后双击 `claudi0-<version>.dmg`，会在桌面出现一个虚拟磁盘

3. **拖入应用文件夹**  
   打开虚拟磁盘后，拖 `claudi0.app` 到 `/Applications` 文件夹（需要有写入权限）

4. **打开应用**  
   前往 `/Applications`，找到 `claudi0.app`，按下方指引操作

---

## macOS 第一次打开时：绕过 Gatekeeper

### 在新系统上打开（macOS Sequoia 15 及更新版本，含 26）

1. **打开 claudi0 时收到拦截**
   > `"claudi0" 无法打开，因为 Apple 无法检查是否包含恶意软件。`

2. **进入系统设置 > 隐私与安全性**

3. **下滑找到被拦的 claudi0**
   在"安全性"部分你会看到这条信息：
   ```
   "claudi0" 已被阻止，因为来自身份不明的开发者
   ```
   旁边会有一个按钮

4. **点击"仍要打开"**  
   系统会要求你输入密码确认，完成后 claudi0 就能正常打开

5. **后续打开直接运行**  
   第一次绕过后，下次直接双击 `claudi0.app` 打开，不会再拦截

### 在旧系统上打开（macOS Sonoma 14 及更早版本）

1. **右键点击 claudi0.app**

2. **选择"打开"**  
   （而非左键双击）

3. **在弹出的对话框中再点"打开"**  
   系统会要求确认身份

4. **后续打开直接运行**

> **注意**：这个方式（右键打开）只在 macOS Sonoma 14 及更早版本上有效。从 macOS Sequoia 15 起，苹果收紧了 Gatekeeper 检查，右键打开不再能绕过，必须走系统设置路径（苹果的版本号从 15 直接跳到了 26，中间没有 16–25）。

---

## 首次安装后：先准备声音，再分别连接宿主

1. **打开 claudi0**（菜单栏会出现 Orbit Zero 图标）。首次启动只准备共享 runtime：把 helper 与内置声音包放进 `~/.claudio/`、修复 quarantine，并在尚未选包时选择默认包。它**不会静默改写** Claude Code 或 Codex 配置。
2. 点菜单栏图标。面板始终显示两条等权声音来源：

   ```text
   Claude Code    5/5 …
   Codex          4/5 …
   ```

   Codex `4/5` 是正常能力，不是故障：当前没有与「执行中断」对应的 `StopFailure` 原生事件。
3. 点击任一来源行打开「声音来源」详情窗口，然后分别连接需要的宿主。

### 连接 Claude Code

点 Claude Code 卡片里的「连接」。claudi0 只向 `~/.claude/settings.json` 追加自己的 hook：

- 保留原有 hook、matcher 与数组顺序
- 首次写入前建立一次性备份
- 重复连接不会重复安装或制造双响
- 旧的 `claudio play` 连接继续有效，并显示为 legacy；需要真实回执时可在详情窗口点「升级连接」

### 连接 Codex

点 Codex 卡片里的「连接」。claudi0 只在 `~/.codex/hooks.json` 中管理自己的 `UserPromptSubmit`、`Stop`、`PermissionRequest` 与 `SubagentStop` command hook；不会接管单命令 `notify`，也不会读写私有 trust 数据或删除第三方 hook。

写入完成后会显示：

> **claudi0 已写好，等待 Codex 确认**

在 Codex 中运行 `/hooks` 并确认 claudi0 hooks，然后再提交一次提示词。详情窗口提供「复制 `/hooks`」和「重新检测」。只有当前 installation ID 的 `UserPromptSubmit` 回执才能证明新增的任务开始 hook 已激活并点亮绿色连接；仅仅写好 JSON，或只有旧的 Stop 等回执，都不算激活。其它当前代次回执仍会作为最新事件诊断显示。

Codex 的「需要你」只覆盖 `PermissionRequest`（**仅授权请求**）。`UserPromptSubmit` 是任务开始，不计入「需要你」；`Stop` 只写「本轮结束」，不承诺任务已经完成。

### 也可以走 Terminal

```bash
# 查看两个宿主
/Applications/claudi0.app/Contents/Resources/bin/claudi0 integrations status

# 分别连接
/Applications/claudi0.app/Contents/Resources/bin/claudi0 integrations connect claude-code
/Applications/claudi0.app/Contents/Resources/bin/claudi0 integrations connect codex
```

`claudi0 setup` 保留旧版兼容行为：它会准备 shared runtime 并连接 Claude Code，**不会替你激活 Codex**。`claudi0 install` / `uninstall` 也仍是 Claude Code 兼容别名。旧 hooks 继续调用 `~/.claudio/bin/claudio`，改名不会让现有连接失效。

> **关于 Gatekeeper 隔离（macOS 会给下载来的文件盖一个 `com.apple.quarantine` 章）**：
> 这个章如果留在 `~/.claudio/bin/claudio` 上，Claude Code 每次执行 hook 时都会被系统**直接杀掉**——
> 没有任何报错，你只会觉得"装好了但就是不响"。所以 shared bootstrap（以及兼容的 `setup`）在复制完成后会
> **自动解除隔离并回头验证一次**；万一没解掉，它会**报错并且不写任何 hook**，而不是留给你一个
> 看起来装好了、实际永远静音的安装。`claudi0 doctor` 也会把"被隔离的二进制"报成硬失败。

---

## 卸载

### 通过 Homebrew

先在「声音来源」详情窗口分别断开已连接的宿主，或运行：

```bash
~/.claudio/bin/claudi0 integrations disconnect claude-code
~/.claudio/bin/claudi0 integrations disconnect codex
```

然后卸载 app：

```bash
brew uninstall --cask claudi0
```

断开一个宿主只删除该宿主的 claudi0 条目；不会删除另一宿主、第三方 hooks、声音包或 `~/.claudio/` shared runtime。`claudi0 uninstall` 仍可作为断开 Claude Code 的兼容别名。

### 手动卸载

1. 在「声音来源」详情窗口分别断开已连接的宿主，或运行：
   ```bash
   ~/.claudio/bin/claudi0 integrations disconnect claude-code
   ~/.claudio/bin/claudi0 integrations disconnect codex
   ```
2. 拖 `claudi0.app` 到回收站（从 `/Applications` 删除）。

---

## 故障排除

### 我已经点过"仍要打开"，但 claudi0 还是打不开

1. 确认你是在**系统设置 > 隐私与安全性** 中点的，而不是在通知框里
2. 如果仍不行，尝试在终端里直接运行：
   ```bash
   open /Applications/claudi0.app
   ```
3. 看是否有其他错误信息

### claudi0 打开了但没发声

1. 在面板确认目标宿主已连接；也可以运行 `~/.claudio/bin/claudi0 integrations status`。未安装/未连接是提示，不是 shared runtime 故障。
2. 如果 Codex 显示「claudi0 已写好，等待 Codex 确认」，先运行 `/hooks` 完成确认，再提交一次提示词并点「重新检测」。`4/5` 本身不需要修复。
3. 确认系统音量以及 claudi0 的主音量/对应事件没有静音。
4. 在 claudi0 面板里找到当前声音包，点对应事件的试听按钮 ▶。试听会绕过宿主 hook，能帮助区分「播放链坏了」和「宿主还没激活」。
5. 运行 `~/.claudio/bin/claudi0 doctor`，分别查看 shared runtime、Claude Code 与 Codex。只有 shared runtime 不可用或已连接宿主损坏才会返回失败。

### 重跑一次 `setup` 可以修复 shared runtime 与 Claude Code 兼容连接（**从 app bundle 里跑**）

`setup` 是幂等兼容入口，会修复 helper、声音包、当前选包和 Claude Code 连接。Codex 始终通过 `integrations connect codex` / 详情窗口单独管理，并仍需要 `/hooks` 确认。

```bash
/Applications/claudi0.app/Contents/Resources/bin/claudi0 setup
```

> ⚠️ **一定要从 app bundle 里跑这条路径**，不要跑 `~/.claudio/bin/claudi0 setup`。
> 两者的区别只有一个，但很致命：**只有 app bundle 里的那份看得见内置声音包**（它们躺在
> `claudi0.app/Contents/Resources/packs/`）。从 `~/.claudio/bin/` 跑的那份没有内置包可复制 ——
> 如果你的问题恰恰是「声音包不见了」，它就修不好。

它会做这几件事（每一件都会在输出里如实说出来）：

- 二进制不在 / 被 macOS 隔离 → 重新复制、解除隔离，并**回头验证一次**（没解掉就报错，绝不写 hooks）
- 内置声音包不在 → 复制回来；严格 pristine 的 `minimal-chime 1.0.0` 会原子升级为含「任务开始」的 `1.1.0`，任何格式化、额外文件或音频变化都视为自定义并保持不变；若所在卷不支持原子目录交换，则安全保留 1.0.0 并继续启动
- 上一次安装被中断留下的**残缺包** → 原样搬到一个备份目录（`packs/.<id>.broken-…`，**一个文件都不删**），
  再装一份干净的；输出里会告诉你搬到哪儿了
- 你选中的那个包已经不在了 / 读不出来 → 替你换上一个能响的，并打印一行 ⚠ 告诉你换的是哪个
  （你随时可以在面板的声音包列表里换回去）
- Claude Code 的 claudi0 hooks 不在 → 补上（不会覆盖你自己的配置）

**它绝不会做的事**：在一台注定发不出声音的机器上写 Claude Code hooks 然后告诉你「装好了」。
只要这次安装注定是哑的（一个能用的声音包都没有、二进制被隔离、`config.json` 读不出来），
它会**大声失败并且不新增 Claude Code hook** —— 一个看起来装好了、实际永远静音的安装，比一次诚实的报错糟糕得多。

### 需要诊断日志

```bash
# 查看最近的错误日志
tail -20 ~/.claudio/claudio.log

# 或运行自检
~/.claudio/bin/claudi0 doctor

# 查看两宿主状态（机器可读时加 --json）
~/.claudio/bin/claudi0 integrations status
```

真实回执位于 `~/.claudio/integrations/receipts/<host>/<event>.json`，权限为 `0600`。它只含 installation ID、宿主/事件、时间和脱敏播放结果；不会保存提示词、响应内容、项目路径、会话内容或音频绝对路径。不要通过手改回执强行点亮连接——只有当前 installation 的真实 hook 回调才有效。

---

## 即将推出：签名版本

我们计划在近期上线 **Apple Developer 签名 + 公证** 的版本，这样新系统打开时就没有 Gatekeeper 拦截了。签名版本发布后，无需任何绕过步骤，就能像其他 App Store 应用一样直接打开。

---

## 更新到新版本

### 通过 Homebrew

```bash
brew upgrade claudi0
```

### 手动更新

1. 下载新的 `claudi0-<version>.dmg`
2. 挂载 DMG
3. 拖新的 `claudi0.app` 到 `/Applications`，覆盖旧版本
4. 完成

你之前配置的声音包、Claude Code / Codex 的 claudi0 条目与真实回执会保留。共享配置在 `~/.claudio/`，宿主条目仍分别位于各自配置文件中；更新后可用 `claudi0 integrations status` 重新检测。

---

## 相关链接

- **项目主页**：[GitHub](https://github.com/d0m999/Claudio)
- **问题报告**：[Issues](https://github.com/d0m999/Claudio/issues)
- **设计文档**：[DESIGN.md](../DESIGN.md)
- **工程规范**：[ENGINEERING.md](../ENGINEERING.md)
- **声音包标准**：[pack-standard.md](./pack-standard.md)
