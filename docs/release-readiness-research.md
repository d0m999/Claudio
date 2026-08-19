# Claudio 开源产品发布调研

> 调研日期：2026-08-15
>
> 目标：回答 Claudio 是否需要安装包、GitHub 中英文使用说明，以及在公开发布为 macOS 产品前还缺什么。

## 结论先行

需要，但不是从零开始重新做安装包：Claudio 已经有一条“tag → universal app → DMG → GitHub Release”的发布流水线。当前更准确的状态是：**技术预览分发链路已搭好，面向普通用户的产品发布还没有闭环**。

建议把发布拆成三层：

1. **开源层**：根目录 README、明确的软件许可证、贡献/行为/安全说明。
2. **可安装层**：可下载的 DMG、稳定版本号、Release Notes、校验和、安装/首次启动/卸载说明。
3. **产品层**：Developer ID 签名与 notarization、首次运行和宿主连接验收、升级/回滚策略、Homebrew 或自动更新入口。

`.pkg` 不是当前必需品。对于菜单栏 app，`.dmg` 中放置 `.app` 并拖入 `/Applications` 已经是成熟产品常用的首发形态；只有在需要系统级安装、特权 helper、driver 或复杂安装步骤时，才值得引入 `.pkg`。

## Claudio 当前状态

### 已经具备

- [`.github/workflows/release.yml`](../.github/workflows/release.yml) 已按 `vX.Y.Z` tag 构建 arm64 与 x86_64，再合并为 universal app 和 helper。
- 同一 workflow 已组装 `claudi0.app`、生成 `claudi0-<version>.dmg`、计算 DMG SHA-256，并创建 GitHub Release。
- [docs/distribution.md](distribution.md) 已覆盖手动 DMG 安装、Gatekeeper、Claude Code/Codex 连接、Terminal 备用路径。
- [packs/LICENSES.md](../packs/LICENSES.md) 已记录随 app 分发的内置音频包许可；这是第三方素材合规台账，但不等于项目代码许可证。

### 发布前的硬缺口

1. **当前仍是 ad-hoc 签名，无 Apple notarization。** workflow 明确使用 `codesign --sign -`，Release Notes 也要求用户手动绕过 Gatekeeper。Apple 对 App Store 外分发的建议是使用 Developer ID 签名并 notarize；notarization ticket 让 Gatekeeper 能验证软件来自开发者且未被篡改。[Apple：Distributing software on macOS](https://developer.apple.com/macos/distribution/)、[Apple：Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)。
2. **还没有真正跑过一次 tag Release。** 当前 workflow 的 build job 是存在的，但 Homebrew job 依赖尚未准备好的 `<owner>/homebrew-tap` 仓库和 `HOMEBREW_TAP_TOKEN`；仓库内的 [`Casks/claudi0.rb`](../Casks/claudi0.rb) 只是占位模板。
3. **根目录缺少产品入口文档。** 当前没有 `README.md`、`README.zh-CN.md`、`LICENSE`、`CHANGELOG.md`、`CONTRIBUTING.md`、`SECURITY.md` 或 `CODE_OF_CONDUCT.md`。
4. **缺少正式的项目许可证。** GitHub 明确说明：没有许可证时，默认版权法仍然适用，其他人不能合法复制、分发或制作衍生作品；公开仓库不自动等于 open source。[GitHub：Licensing a repository](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/licensing-a-repository)。
5. **Homebrew 安装命令需要修正。** 如果仓库名是 `d0m999/homebrew-tap`，Homebrew 的短命令应省略 `homebrew-` 前缀，即 `brew tap d0m999/tap`；也可以直接安装 `brew install --cask d0m999/tap/claudi0`。当前 [docs/distribution.md](distribution.md) 中的 `brew tap d0m999/homebrew-tap` 与 Homebrew 的 tap 命名规则不一致。[Homebrew：Taps](https://docs.brew.sh/Taps)、[Homebrew：How to Create and Maintain a Tap](https://docs.brew.sh/How-to-Create-and-Maintain-a-Tap)。

## 知名 macOS 开源产品对照

以下均以项目自己的 README、文档或官方仓库为准，而不是第三方安装教程。

| 产品 | 安装入口 | GitHub/文档内容 | 对 Claudio 的启发 |
|---|---|---|---|
| [Rectangle](https://github.com/rxhanson/Rectangle) | 官方 DMG / Releases + `brew install --cask rectangle` | README 先写系统要求，再写安装和核心使用方式；仓库同时有 `LICENSE`、`CONTRIBUTING.md`、`CODE_OF_CONDUCT.md`、`SECURITY.md` | 根 README 不需要百科全书，但必须让用户在几分钟内完成“我是谁、能否安装、怎么开始”。 |
| [Hammerspoon](https://github.com/Hammerspoon/hammerspoon) | Release 下载拖入 `/Applications` + `brew install hammerspoon --cask` | README 链接 Getting Started、API docs、FAQ、示例配置和贡献指南；Getting Started 明确写出首次运行要授予 Accessibility 权限 | Claudio 的宿主 hook、菜单栏 app、权限和回执也应有一个明确的首次运行路径，而不是让用户从源码或长文档猜。 |
| [Stats](https://github.com/exelban/stats) | `Stats.dmg` + Homebrew | README 同时说明手动安装、Homebrew、卸载脚本、系统要求、常见故障和对外请求/隐私边界 | “怎么卸载”“数据是否离开本机”“macOS 新版本下图标不见怎么办”应当和安装一样可见。 |
| [Maccy](https://github.com/p0deje/Maccy) | Releases + Homebrew | README 按 Features → Install → Usage → Advanced → FAQ → Translations → License 组织 | Claudio 可采用相同的信息架构，把一键安装、宿主连接、快捷操作、恢复/排障、隐私和许可证分层。 |

这些项目的官方入口基本都是英文 README；这是一个基于上述仓库页面的产品实践归纳，不是硬性规范。对 Claudio 最合适的做法是：**英文 `README.md` 作为公共入口，中文用 `README.zh-CN.md` 或 `docs/` 下的中文完整指南，并在两边互相链接**。不建议把所有段落中英逐行重复，否则功能和安装流程很容易漂移。

## 推荐的发布形态

### 首发安装包

推荐首发资产：

- `claudi0-0.1.0.dmg`：主安装入口，内含 universal `claudi0.app` 和 `/Applications` 快捷方式。
- `claudi0-0.1.0.zip`：可选，方便脚本、测试和高级用户；不是普通用户必需品。
- `SHA256SUMS.txt`：列出 DMG/ZIP 的 SHA-256。
- GitHub Release Notes：写清支持的 macOS、CPU 架构、已知限制、安装后的第一步和升级注意事项。

不建议首发就做 `.pkg`。当前 helper 主要落到用户目录 `~/.claudio/`，并由 app/CLI 管理宿主配置，不需要把系统级安装器作为用户入口。将来如果引入 privileged helper、系统扩展或必须由 Installer 执行的步骤，再单独评估 `.pkg`。

Apple 的分发文档列出了 ZIP、DMG 和 installer package 等容器，并建议直接分发时先完成分发签名，再对容器做 notarization。[Apple：Packaging Mac software for distribution](https://developer.apple.com/documentation/xcode/packaging-mac-software-for-distribution)。

### 签名与公证

面向“产品用户”的 P0 流程应是：

1. 为 app、嵌套 helper 和 CLI 配置 Developer ID Application 签名。
2. 启用 hardened runtime，并逐项确认 Claudio 所需 entitlement。
3. 组装 DMG 后提交 Apple notarization。
4. staple notarization ticket。
5. 在干净 macOS 环境验证 `codesign`、`spctl`、`xcrun stapler validate`，再发布 GitHub Release。

如果暂时没有 Apple Developer 账号，可以发布 `0.1.0-preview` 技术预览，但必须在 Release、README 和 DMG 安装页显著标注“未签名/无公证，仅面向技术用户”。这不应被包装成普通用户的无摩擦产品版本。

### Homebrew

Homebrew 不是首发硬依赖，但它是成熟 macOS 产品常见的第二入口。建议顺序：

1. 先让 GitHub Release + DMG 单独可用。
2. 创建 `d0m999/homebrew-tap`，把实际 cask 放在 `Casks/claudi0.rb`。
3. 让 cask 的 `version`、`url`、`sha256`、`homepage`、`depends_on macos` 和 `app` 与 Release 自动同步；Homebrew 的 Cask Cookbook 将这些列为标准字段，并强调尽可能使用 SHA-256。[Homebrew：Cask Cookbook](https://docs.brew.sh/Cask-Cookbook)。
4. 在签名/公证完成后移除用 `xattr` 强行清除 quarantine 的兼容 workaround，让 Gatekeeper 和 notarization 正常发挥作用。
5. 以后有稳定用户量，再考虑向官方 `homebrew/cask` 提交；自建 tap 足够支持首发。

非官方 tap 的 Ruby 定义可在用户权限下执行，Homebrew 因此有 tap trust 机制；README 中应优先给出 fully-qualified 安装命令，避免让用户无意中信任整个 tap。[Homebrew：Tap Trust](https://docs.brew.sh/Tap-Trust)。

## GitHub 说明应该包含什么

### 根目录 `README.md`

建议按以下顺序，控制在首次阅读几分钟内：

1. 一句话定位：Claudio 为 Claude Code 与 Codex 提供什么体验。
2. 截图或短 GIF：菜单栏面板、声音来源、连接状态。
3. Features：Claude Code、Codex、声音包、回执/诊断、语言、无障碍等。
4. Requirements：macOS 12+、Apple Silicon/Intel、宿主版本边界。
5. Quick start：下载 DMG → 拖入 Applications → 启动 → 分别连接 Claude Code/Codex → 用一次真实事件确认回执。
6. 两种安装方式：GitHub Release DMG、Homebrew；源码构建放到开发者章节。
7. Permissions and files：明确会读写哪些配置、备份放在哪里、哪些权限是可选的。
8. Troubleshooting：Gatekeeper、菜单栏图标、hook 未激活、旧配置恢复、声音不响。
9. Uninstall：app、`~/.claudio/`、hook 配置和备份分别如何处理；说明哪些用户数据不会被删除。
10. Privacy / Security：网络请求、遥测、日志、宿主配置和音频文件的边界，必须以代码实际行为为准。
11. Contributing、License、Security policy 和 Release 页面链接。

### 中文版本

推荐新增 `README.zh-CN.md`，而不是把中文藏在 README 最底部。顶部互链即可：

```text
English | 简体中文
```

中文页面可以比英文页面更详细，尤其写清 Gatekeeper、Claude Code/Codex 连接、hook 回执和卸载恢复；两份文档必须共享同一个版本/支持矩阵，Release Notes 也应至少有中英文摘要。

### 开源社区文件

GitHub 的社区 profile checklist 将 README、LICENSE、CODE_OF_CONDUCT、CONTRIBUTING 等视为公开项目的推荐健康文件。[GitHub：About community profiles for public repositories](https://docs.github.com/en/communities/setting-up-your-project-for-healthy-contributions/about-community-profiles-for-public-repositories)。Claudio 首发至少应补齐：

- `LICENSE`：代码许可证；需要单独决定 MIT、Apache-2.0 或 GPL 等，不应把音频的 CC0 台账当作代码许可证。
- `CONTRIBUTING.md`：本地构建、测试命令、Swift 版本、提交/PR 规则。
- `SECURITY.md`：漏洞报告渠道；不要要求公开 issue 贴敏感配置或日志。
- `CODE_OF_CONDUCT.md`：社区行为边界。
- `CHANGELOG.md`：版本变更、迁移和已知限制；每个 GitHub Release 复用其中条目。
- `.github/ISSUE_TEMPLATE/`：至少 bug report、宿主集成问题、功能建议。
- 可选 `SUPPORT.md`、`FUNDING.yml`、Discussions；首发不必一次做全。

## Claudio 的分级完成标准

### P0：可以称为“公开技术预览”

- [ ] 选择并提交 `LICENSE`。
- [ ] 新增英文 `README.md` 和中文 `README.zh-CN.md`。
- [ ] 用 `v0.1.0-preview.1` 或类似 tag 真跑一次 release workflow。
- [ ] GitHub Release 至少有 DMG、SHA-256、支持矩阵、已知限制和安装说明。
- [ ] 在一台 Apple Silicon 和一台 Intel Mac 做干净安装、启动、卸载 smoke test。
- [ ] 把 Homebrew job 设为可选或先创建 tap，不能让预期失败的 job 作为正式发布链路的一部分。

### P1：可以称为“面向普通用户的产品首发”

- [ ] Developer ID 签名 + hardened runtime + notarization + stapling。
- [ ] Gatekeeper 干净环境验证，不再依赖清除 quarantine 来完成首次运行。
- [ ] README/Release 提供一条三分钟 Quick start。
- [ ] Claude Code 与 Codex 各完成一次真实连接、真实事件和真实回执验收。
- [ ] 升级不覆盖用户 hook，回滚/备份路径可验证。
- [ ] `claudi0 --version`、app bundle 版本、tag、DMG 文件名一致；目前 helper 仍有硬编码开发版本，需要统一版本源。
- [ ] 提供卸载和恢复文档，并记录第三方素材/依赖许可证。

### P2：可以称为“可持续维护的产品”

- [ ] Homebrew tap 自动同步并在干净机器验证安装/升级。
- [ ] 有稳定的 release notes、issue triage、security response 和支持入口。
- [ ] 评估 Sparkle/其他更新机制，或明确“用户通过 GitHub/Homebrew 更新”的策略。
- [ ] 维护 macOS 新版本、Intel/Apple Silicon、VoiceOver/键盘、宿主版本变化的发布验收矩阵。

## 最终建议

Claudio 不需要先做一个复杂的 `.pkg` 才能发布；最短可行路径是：**补齐许可证与双语 README → 把现有 DMG workflow 真跑通 → 先以技术预览发布 → 完成 Developer ID/notarization 后再宣布普通用户产品首发**。Homebrew 是第二入口，不应成为第一版唯一安装方式。

### 资料来源

- [Apple — Distributing software on macOS](https://developer.apple.com/macos/distribution/)
- [Apple — Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
- [Apple — Packaging Mac software for distribution](https://developer.apple.com/documentation/xcode/packaging-mac-software-for-distribution)
- [GitHub — About releases](https://docs.github.com/en/repositories/releasing-projects-on-github/about-releases)
- [GitHub — Licensing a repository](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/licensing-a-repository)
- [GitHub — About community profiles for public repositories](https://docs.github.com/en/communities/setting-up-your-project-for-healthy-contributions/about-community-profiles-for-public-repositories)
- [Rectangle — official repository](https://github.com/rxhanson/Rectangle)
- [Hammerspoon — official repository](https://github.com/Hammerspoon/hammerspoon)
- [Hammerspoon — Getting Started](https://github.com/Hammerspoon/hammerspoon.github.io/blob/master/getting-started.md)
- [Stats — official repository](https://github.com/exelban/stats)
- [Maccy — official repository](https://github.com/p0deje/Maccy)
- [Homebrew — Taps](https://docs.brew.sh/Taps)
- [Homebrew — How to Create and Maintain a Tap](https://docs.brew.sh/How-to-Create-and-Maintain-a-Tap)
- [Homebrew — Cask Cookbook](https://docs.brew.sh/Cask-Cookbook)
- [Homebrew — Tap Trust](https://docs.brew.sh/Tap-Trust)
