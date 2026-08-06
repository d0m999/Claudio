# 声音包库性能基准

本基准守住 [ADR 0001](../adr/0001-design-sound-pack-library-for-100-packs.md) 的两个 Release 性能预算：100 个已安装包的首次会话读取 `p95 ≤ 500 ms`，已有会话快照的展示 `p95 ≤ 100 ms`。运行：

```bash
scripts/benchmark-sound-pack-library.sh
```

脚本先构建 Release benchmark product，再直接计时已链接的可执行文件，SwiftPM 编译时间不计入样本。fixture 含 100 个完整包，每包一个 manifest 和五个音频目录项：

- cold：每个样本新建 `SoundPackLibrary`，不复用任何 app-session snapshot；3 次预热后取 30 次样本。
- cached：使用 production initializer 从同一个 ready library 构造 retained `SoundPacksWindowModel`，等待 `AsyncStream` 重放 snapshot 并完成 100 包 UI 投影；取 100 次样本。
- incremental：已有 snapshot 时执行未失效的 activation refresh，校验 100 个 metadata fingerprint；取 30 次样本。该项记录趋势，当前不设发布阈值。

## 2026-08-06 基线

环境：`MacBookPro17,1`、Apple M1、arm64、APFS、Release。

| 场景 | p95 | 预算 | 结果 |
|---|---:|---:|---|
| cold，100 包 | 173.893 ms | 500 ms | 通过 |
| cached presentation，100 包 | 0.282 ms | 100 ms | 通过 |
| incremental refresh，100 包 | 49.787 ms | 仅记录 | 通过 |

独立 benchmark 进程的 `maximum resident set size` 为 `22,085,632 B`（约 21.1 MiB），`peak memory footprint` 为 `14,943,424 B`（约 14.3 MiB）。这些数字覆盖 Foundation 扫描、actor、100 包 fixture、production window model 和 benchmark 自身，不等同于包含完整 AppKit/SwiftUI 界面的应用常驻内存。

benchmark 在 cold 或 cached 的 p95 超预算、扫描失败、包数量错误时以非零状态退出，并在预算失败路径删除 fixture。可用 `CLAUDIO_BENCHMARK_PACKS`、`CLAUDIO_BENCHMARK_COLD_SAMPLES`、`CLAUDIO_BENCHMARK_CACHED_SAMPLES`、`CLAUDIO_BENCHMARK_INCREMENTAL_SAMPLES`、`CLAUDIO_BENCHMARK_COLD_LIMIT_MS` 和 `CLAUDIO_BENCHMARK_CACHED_LIMIT_MS` 临时调整样本或做负向门禁测试，但正式验收使用默认值。
