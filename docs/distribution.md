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

## 首次安装后（v1 当前需要一步 Terminal 命令）

> **诚实说明**：Claudio 的菜单栏面板目前还是早期骨架，"接管 Claude Code"的按钮暂时**没有接上任何真实动作**（真身面板是 ENGINEERING.md T15，尚未完工）。所以 v1 打开 app 后，还需要手动跑一条 Terminal 命令才能真正听到声音——这不是操作失误，是当前版本的真实限制，下面这步就是修复它。

1. **打开 Terminal，跑一次自举命令**（只需跑一次）：
   ```bash
   /Applications/Claudio.app/Contents/Resources/bin/claudio setup
   ```
   这会一次性完成：把 helper 复制到 `~/.claudio/bin/claudio`、把内置声音包"极简铃音"复制到 `~/.claudio/packs/`、首次默认选中它、并把 hook 写进 `~/.claude/settings.json`
   - 不会覆盖你的其他 hook
   - 后续可随时卸载（`claudio uninstall`）
   - 自动备份原 settings.json 到 `settings.json.claudio.bak`
   - 命令是幂等的，重复运行不会重复安装或出错

2. **完成**  
   下次 Claude Code 的任务完成、中断或需要确认时，就会自动播放相应的声音了。以后想换别的内置包，用 `~/.claudio/bin/claudio use <pack-id>` 切换。

3. **T15 之后**：真身菜单栏面板落地后，"接管 Claude Code"按钮会直接触发这一整套逻辑，不再需要碰 Terminal——这份指引届时会更新。

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

1. 确认你已经跑过[「首次安装后」](#首次安装后v1-当前需要一步-terminal-命令)那条 `claudio setup` 命令——v1 光打开 app 本身不会自动接管，这是目前最常见的原因
2. 确认系统音量没有静音
3. 在 Claudio 面板里找到你选的声音包，点旁边的试听按钮 ▶ 测试一下

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
