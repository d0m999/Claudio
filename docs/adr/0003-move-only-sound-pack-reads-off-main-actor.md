---
status: accepted
---

# 只把声音包读取移出 MainActor

本次性能重构只把目录枚举、受限 manifest 读取、JSON 解码、文件存在性与完整性检查移出 `@MainActor`；不改变 manifest、config、导入和恢复写入的现有执行模型。阻塞文件系统调用运行在专用串行 utility queue，不占用 Swift cooperative executor；库扫描与按需音频清单使用两条独立队列，慢清单不能阻塞库级刷新，尚未开始的已取消清单任务不得继续读盘。相关写入继续依赖同步 `@MainActor` 或既有锁与 CAS 维持顺序和原子性，写成功后仅递增 invalidation revision 并请求后台重读。禁止为了减少 UI 阻塞而直接给现有写函数套 `Task.detached`，因为这会把性能优化变成无锁 read-modify-write 竞争并可能造成丢更新。
