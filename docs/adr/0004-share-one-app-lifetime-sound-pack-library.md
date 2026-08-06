---
status: accepted
---

# 全 app 共享一个 SoundPackLibrary actor

app composition root 创建一个 app-lifetime `SoundPackLibrary` actor，并把它注入主面板与 retained 声音包管理窗口。该 actor 是声音包扫描、metadata fingerprint、会话快照、刷新合并、按需音频清单和 revision 的唯一所有者，两个消费者不得各自维护磁盘缓存或重复扫描。它只发布声音包磁盘事实，不拥有 config、当前选择、星标、静音、主音量、写操作、`NSWindow` 或 SwiftUI 状态；这些职责继续留在现有界面与写入 module 中，并在消费快照时使用最新 config 投影。

actor 的读取 interface 是一个向每位新订阅者重放当前值的 `AsyncStream<SoundPackLibraryState>`；状态穷尽表达 `unloaded`、`loading(previous:)`、`ready(snapshot)` 与 `failed(previous:error)`。`loadIfNeeded(trigger:)` 只负责首次 hydration，不把新消费者附着到已有 ready 快照误变成扫描；`requestRefresh(trigger:)` 表达展示、激活、bootstrap 或重试观察；同步 `nonisolated invalidate(packIDs:)` 在写边界先推进 mailbox revision；`audioInventory(packID:)` 只在消费者检查具体包时加载浅目录清单。主面板和管理窗口订阅同一状态流，不得再各自实现 current/refresh 缓存状态机。

每个声音包的 fingerprint 绑定目录、manifest 与当前事件声明音频文件的 device、inode、mode、size、纳秒级 mtime/ctime；一次 facts 读取必须被前后相同 fingerprint 包围，原子替换落在读取区间内时最多重试三次，不能把旧 bytes 绑定到新 inode。常规刷新不对全部音频做内容哈希，出厂完整性仍沿用既有逐字节验证。manifest 只接受当前事件名，单个音频相对路径最多 1024 bytes，未知未来事件不能放大 fingerprint 或完整性 I/O。

完整音频目录 inventory 不进入 100 包主快照：正常 facts 标记为 `deferred`，选中/检查时才在独立队列读取；成功结果按 pack fingerprint 进入最多四项的会话 LRU，失败不做负缓存，快照 fingerprint 改变后自动淘汰。配置了 factory root 时该根缺失是库级失败；可首次创建的 user/bundled root 缺失视为空集合，其他 errno、非目录和不可读错误不得伪装成空库。

刷新期间到达的多个观察请求合并成恰好一次 follow-up；新的 invalidation 同样使旧 ready/failed 结果不得发布，并让下一次扫描覆盖最新 revision。mailbox 的锁内 publication check 与同步写边界线性化，既防止 actor 尚未收到失效消息时发布旧结果，也不允许失败扫描确认掉未处理的 invalidation。一次 app 内写只有写入方发起扫描，另一界面仅重投影共享状态，避免把同一写产生的双消费者通知误排成无意义 follow-up。
