# Release 体积预算

发布流程在 codesign 前执行 `scripts/check-release-size.sh`。门禁按 Mach-O 架构数线性放大：

- `claudi0-app`：每架构最多 `4,000,000 B`；
- `claudi0` helper：每架构最多 `2,500,000 B`；
- app 内其余正规文件合计预留 `1,000,000 B`；
- GUI 与 helper 必须包含相同架构；`Contents/Resources/bin/claudio` 必须是精确指向同目录 `claudi0` 的相对符号链接。

## 2026-08-06 基线

arm64 Release bundle 在剥离本地符号、移除重复 helper Mach-O 后：

| 项目 | 变更前 | 变更后 |
|---|---:|---:|
| 可执行 payload 合计 | `14,365,224 B` | `4,867,696 B` |
| 减少 | — | `66.1%` |
| GUI | — | `3,029,656 B` |
| helper | — | `1,838,040 B` |
| 非可执行资源 | — | `303,285 B` |
| app bundle 正规文件合计 | — | `5,170,981 B` |

同一流程生成的 arm64 + x86_64 universal bundle 为：GUI `6,142,616 B`、helper `3,771,352 B`、非可执行资源 `303,285 B`、bundle 正规文件合计 `10,217,253 B`，均在对应的双架构预算内。门禁逐架构检查 Mach-O slice，资源预算独立于可执行文件剩余额度；负向测试把资源预算压到 `1 B` 时会按预期拒绝。体积门禁只约束最终 app bundle，不把 developer-only benchmark product 计入分发物。
