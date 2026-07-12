# Claudio 安装指南

> 本文档描述 v1 发布后的安装流程；`.github/workflows/release.yml` 尚未真正跑过一次 tag release，
> 下方的 Homebrew tap / GitHub Releases 链接在首个版本发布前不会有实际内容。

**Supported:** macOS 12+，v1 为未签名 ad-hoc 构建

---

## 免责声明：当前未签名

Claudio v1 分发的是**未签名 ad-hoc 构建**（开发者签名，非 Apple Developer 签名）。这意味着：
- 首次打开时，macOS 会拦截并要求你确认才能运行
- **这不是 bug，是苹果对未签名应用的安全审查**
- 我们即将上线 Apple Developer 签名 + 公证（预计接下来的版本），消除这个摩擦

**适用人群**：这个版本面向熟悉 macOS 系统的技术用户，能自行绕过 Gatekeeper。面向非技术用户的零摩擦版本将在签名公证完成后推出。

---

## 安装方式 1：Homebrew（推荐，若 tap 已配置）

```bash
brew tap d0m999/homebrew-tap
brew install --cask claudio
```

首次打开时，按下方【在新系统上打开】或【在旧系统上打开】的指引操作。

---

## 安装方式 2：手动下载 DMG

1. **下载最新 DMG**  
   前往 [GitHub Releases](https://github.com/d0m999/Claudio/releases) 找到最新版本的 `Claudio.dmg`

2. **挂载 DMG**  
   下载完成后双击 `Claudio.dmg`，会在桌面出现一个虚拟磁盘

3. **拖入应用文件夹**  
   打开虚拟磁盘后，拖 `Claudio.app` 到 `/Applications` 文件夹（需要有写入权限）

4. **打开应用**  
   前往 `/Applications`，找到 `Claudio.app`，按下方指引操作

---

## macOS 第一次打开时：绕过 Gatekeeper

### 在新系统上打开（macOS Sequoia 15 及更新版本，含 26）

1. **打开 Claudio 时收到拦截**  
   > `"Claudio" 无法打开，因为 Apple 无法检查是否包含恶意软件。`

2. **进入系统设置 > 隐私与安全性**

3. **下滑找到被拦的 Claudio**  
   在"安全性"部分你会看到这条信息：
   ```
   "Claudio" 已被阻止，因为来自身份不明的开发者
   ```
   旁边会有一个按钮

4. **点击"仍要打开"**  
   系统会要求你输入密码确认，完成后 Claudio 就能正常打开

5. **后续打开直接运行**  
   第一次绕过后，下次直接双击 `Claudio.app` 打开，不会再拦截

### 在旧系统上打开（macOS Sonoma 14 及更早版本）

1. **右键点击 Claudio.app**

2. **选择"打开"**  
   （而非左键双击）

3. **在弹出的对话框中再点"打开"**  
   系统会要求确认身份

4. **后续打开直接运行**

> **注意**：这个方式（右键打开）只在 macOS Sonoma 14 及更早版本上有效。从 macOS Sequoia 15 起，苹果收紧了 Gatekeeper 检查，右键打开不再能绕过，必须走系统设置路径（苹果的版本号从 15 直接跳到了 26，中间没有 16–25）。

---

## 首次安装后（点面板里的按钮就行）

1. **打开 Claudio**（菜单栏会出现一个波形图标），点它 → 面板打开。
2. **点「接管 Claude Code」**（如果小助手还没装上，这颗按钮会显示为「修复」）。

   一次点击会完成全部四件事：把 helper 复制到 `~/.claudio/bin/claudio`、把内置声音包"极简铃音"复制到 `~/.claudio/packs/`、首次默认选中它、并把 hook 追加进 `~/.claude/settings.json`。
   - **追加，不覆盖**你的其他 hook
   - 自动备份原 settings.json 到 `settings.json.claudio.bak`
   - 幂等：重复点不会重复安装、也不会响两声
   - 失败会**当场说出来**（面板上一句人话 + 可展开的原因），绝不会假装成功
   - 面板底部的「断开连接」随时可以一键撤销

3. **完成**  
   下次 Claude Code 的任务完成、中断或需要确认时，就会自动播放相应的声音了。换包直接点面板里的切包画廊。

### 也可以走 Terminal（与上面完全等价）

```bash
/Applications/Claudio.app/Contents/Resources/bin/claudio setup
```

面板上那颗按钮调用的就是这条命令背后的同一个函数（`performFirstRunSetup`），两条路径没有任何行为差异。

> **关于 Gatekeeper 隔离（macOS 会给下载来的文件盖一个 `com.apple.quarantine` 章）**：
> 这个章如果留在 `~/.claudio/bin/claudio` 上，Claude Code 每次执行 hook 时都会被系统**直接杀掉**——
> 没有任何报错，你只会觉得"装好了但就是不响"。所以 `setup`（以及面板上那颗按钮）在复制完成后会
> **自动解除隔离并回头验证一次**；万一没解掉，它会**报错并且不写任何 hook**，而不是留给你一个
> 看起来装好了、实际永远静音的安装。`claudio doctor` 也会把"被隔离的二进制"报成硬失败。

---

## 卸载

### 通过 Homebrew

```bash
brew uninstall --cask claudio
```

然后手动卸载 Claude Code hook：

```bash
~/.claudio/bin/claudio uninstall
```

### 手动卸载

1. 拖 `Claudio.app` 到回收站（从 `/Applications` 删除）
2. 运行卸载命令：
   ```bash
   ~/.claudio/bin/claudio uninstall
   ```

---

## 故障排除

### 我已经点过"仍要打开"，但 Claudio 还是打不开

1. 确认你是在**系统设置 > 隐私与安全性** 中点的，而不是在通知框里
2. 如果仍不行，尝试在终端里直接运行：
   ```bash
   open /Applications/Claudio.app
   ```
3. 看是否有其他错误信息

### Claudio 打开了但没发声

1. 确认你已经点过面板里的「接管 Claude Code」（或跑过 `claudio setup`）——见[「首次安装后」](#首次安装后点面板里的按钮就行)
2. 确认系统音量没有静音
3. 在 Claudio 面板里找到你选的声音包，点旁边的试听按钮 ▶ 测试一下

### 重跑一次 `setup` 就能治好一台坏掉的安装（**从 app bundle 里跑**）

这是 Claudio 的一条承诺，也是 `setup` 之所以可以放心重复运行的原因：它是幂等的，而且**它会把它能修的都修好**。

```bash
/Applications/Claudio.app/Contents/Resources/bin/claudio setup
```

> ⚠️ **一定要从 app bundle 里跑这条路径**，不要跑 `~/.claudio/bin/claudio setup`。
> 两者的区别只有一个，但很致命：**只有 app bundle 里的那份看得见内置声音包**（它们躺在
> `Claudio.app/Contents/Resources/packs/`）。从 `~/.claudio/bin/` 跑的那份没有内置包可复制 ——
> 如果你的问题恰恰是「声音包不见了」，它就修不好。

它会做这几件事（每一件都会在输出里如实说出来）：

- 二进制不在 / 被 macOS 隔离 → 重新复制、解除隔离，并**回头验证一次**（没解掉就报错，绝不写 hooks）
- 内置声音包不在 → 复制回来
- 上一次安装被中断留下的**残缺包** → 原样搬到一个备份目录（`packs/.<id>.broken-…`，**一个文件都不删**），
  再装一份干净的；输出里会告诉你搬到哪儿了
- 你选中的那个包已经不在了 / 读不出来 → 替你换上一个能响的，并打印一行 ⚠ 告诉你换的是哪个
  （你随时可以在面板的切包画廊里换回去）
- Claude Code 的 hooks 不在 → 补上（不会覆盖你自己的配置）

**它绝不会做的事**：在一台注定发不出声音的机器上写 hooks 然后告诉你「装好了」。
只要这次安装注定是哑的（一个能用的声音包都没有、二进制被隔离、`config.json` 读不出来），
它会**大声失败并且一条 hook 都不写** —— 一个看起来装好了、实际永远静音的安装，比一次诚实的报错糟糕得多。

### 需要诊断日志

```bash
# 查看最近的错误日志
tail -20 ~/.claudio/claudio.log

# 或运行自检
~/.claudio/bin/claudio doctor
```

---

## 即将推出：签名版本

我们计划在近期上线 **Apple Developer 签名 + 公证** 的版本，这样新系统打开时就没有 Gatekeeper 拦截了。签名版本发布后，无需任何绕过步骤，就能像其他 App Store 应用一样直接打开。

---

## 更新到新版本

### 通过 Homebrew

```bash
brew upgrade claudio
```

### 手动更新

1. 下载新的 `Claudio.dmg`
2. 挂载 DMG
3. 拖新的 `Claudio.app` 到 `/Applications`，覆盖旧版本
4. 完成

你之前配置的声音包和 Claude Code 接管会保留（配置存在 `~/.claudio/` 目录）。

---

## 相关链接

- **项目主页**：[GitHub](https://github.com/d0m999/Claudio)
- **问题报告**：[Issues](https://github.com/d0m999/Claudio/issues)
- **设计文档**：[DESIGN.md](../DESIGN.md)
- **工程规范**：[ENGINEERING.md](../ENGINEERING.md)
- **声音包标准**：[pack-standard.md](./pack-standard.md)
