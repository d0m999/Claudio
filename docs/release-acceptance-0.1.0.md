# claudi0 0.1.0 首发验收记录

状态：**未通过**。本记录是 `0.1.0` 的唯一人工验收账本；本地测试、RC 构建成功或单个截图均不能替代未完成项。

## 产物绑定

| 字段 | 结果 |
|---|---|
| Commit SHA | 待填 |
| GitHub Actions run URL / ID | 待填 |
| Actions artifact 名称 | `claudi0-rc-<commit-sha>`（待下载核对） |
| DMG 文件名 | `claudi0-0.1.0.dmg`（待核对） |
| DMG SHA-256 | 待填 |
| Apple Silicon 硬件 / macOS | 待填 |
| Intel 硬件 / macOS 12 | 待填 |
| Claude Code 版本 | 待填 |
| Codex 版本 | 待填 |
| 截图目录或附件 | 待填 |
| 脱敏 receipt 目录或附件 | 待填 |

## 自动化与分发门禁

- [ ] `workflow_dispatch(version=0.1.0)` 从 `main` 完成，且只产生 SHA 绑定的 Actions artifact。
- [ ] helper / GUI harness、CLI 子进程 contracts、universal build、签名、公证、staple、checksum 全部通过。
- [ ] workflow 从最终挂载 DMG 复验 app/helper 架构、版本、资源、symlink、`codesign`、`spctl`、`stapler` 和 SHA-256。
- [ ] 从 Actions 下载的 DMG 与记录中的 SHA-256 一致。
- [ ] Apple Silicon 当前系统完成安装、启动、基础播放。
- [ ] Intel / macOS 12 完成安装、启动、基础播放。
- [ ] 隔离测试账户连接真实 Claude Code 与 Codex；Claude 为 5/5、Codex 为 4/5。
- [ ] 真实事件产生脱敏 `played`、`muted`、`not_ready` receipt，installation / host / event 绑定正确。

## 视觉矩阵（48 帧）

每格必须链接到独立截图或写明附件文件名；`maximum` 不得裁切。表面：菜单栏面板、声音包窗口、连接与诊断窗口。

| 表面 / 文字档 | 浅色中文 | 浅色英文 | 深色中文 | 深色英文 |
|---|---|---|---|---|
| 面板 / compact | 待验 | 待验 | 待验 | 待验 |
| 面板 / standard | 待验 | 待验 | 待验 | 待验 |
| 面板 / large | 待验 | 待验 | 待验 | 待验 |
| 面板 / maximum | 待验 | 待验 | 待验 | 待验 |
| 声音包 / compact | 待验 | 待验 | 待验 | 待验 |
| 声音包 / standard | 待验 | 待验 | 待验 | 待验 |
| 声音包 / large | 待验 | 待验 | 待验 | 待验 |
| 声音包 / maximum | 待验 | 待验 | 待验 | 待验 |
| 连接与诊断 / compact | 待验 | 待验 | 待验 | 待验 |
| 连接与诊断 / standard | 待验 | 待验 | 待验 | 待验 |
| 连接与诊断 / large | 待验 | 待验 | 待验 | 待验 |
| 连接与诊断 / maximum | 待验 | 待验 | 待验 | 待验 |

附加 spot check：

- [ ] 三个表面 × 增加对比度。
- [ ] 三个表面 × 降低透明度。

## 键盘矩阵（24 条流程）

每格执行：初始焦点、完整 `Tab` / `Shift-Tab`、`Esc`、retained-window 关闭后的焦点归还。

| 表面 / 文字档 | 中文 FKA 关 | 中文 FKA 开 | 英文 FKA 关 | 英文 FKA 开 |
|---|---|---|---|---|
| 面板 / standard | 待验 | 待验 | 待验 | 待验 |
| 面板 / maximum | 待验 | 待验 | 待验 | 待验 |
| 声音包 / standard | 待验 | 待验 | 待验 | 待验 |
| 声音包 / maximum | 待验 | 待验 | 待验 | 待验 |
| 连接与诊断 / standard | 待验 | 待验 | 待验 | 待验 |
| 连接与诊断 / maximum | 待验 | 待验 | 待验 | 待验 |

## VoiceOver 矩阵（12 条流程）

每格核对 label、hint、value、selected；禁用试听必须跳过，装饰图标不得重复，bootstrap 报告首次可见时只完整播报一次。

| 表面 / 文字档 | 中文 | 英文 |
|---|---|---|
| 面板 / standard | 待验 | 待验 |
| 面板 / maximum | 待验 | 待验 |
| 声音包 / standard | 待验 | 待验 |
| 声音包 / maximum | 待验 | 待验 |
| 连接与诊断 / standard | 待验 | 待验 |
| 连接与诊断 / maximum | 待验 | 待验 |

## 正式发布后终验

只有上面全部通过后才允许另行授权创建并推送 `v0.1.0`。tag workflow 创建正式 Release 后：

- [ ] 重新下载 Release 中的 DMG 与 `SHA256SUMS.txt` 并校验。
- [ ] 重新执行 Gatekeeper、安装、覆盖升级、卸载和真实宿主 smoke。
- [ ] Release notes、支持矩阵、已知限制与安装说明完整。
- [ ] 若启用 Homebrew，cask SHA 与正式 DMG 一致，并在干净环境完成安装/升级。

任何 Intel、VoiceOver、Apple 凭据或真实回执缺失均保持本记录“未通过”；不得用本地绿色或自报结果改成通过。
