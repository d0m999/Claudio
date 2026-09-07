---
status: accepted
---

# 使用本地活动摘要表示近期宿主活动

claudi0 为菜单栏面板和「活动与诊断」设置页建立一个 app-lifetime 共享的本地活动模型。模型读取
`LocalActivitySummaryStore` 发布的有限七日汇总，并通过同一个 `ActivityOverviewProjector` 投影
Global 与各个 `HostSurfaceID` 的今日、近七日和事件覆盖。Panel 与 Settings 不得各自从 receipt
history、播放结果或日志推算数字。

只有满足以下条件的宿主回调计入摘要：宿主身份匹配、原生事件可映射到现有公共 `Event`，并且回调
installation ID 与接受瞬间读取的当前 installation marker 一致。计数与播放、静音、动态静默、去抖、
音频缺失、播放失败和 receipt 写入并列；这些结果不能回滚已经接受的活动事实。未知事件、不支持事件、
旧 installation callback 和损坏安装标记不计数。

摘要仅保存 schema、更新时间、清除边界、七个本地 Gregorian 日期桶，以及
`HostID.rawValue × Event.cliName` 的饱和计数。它不保存 prompt、response、项目路径、provider、token、
网络字节或音频路径。日期桶按回调发生时的本地日历日期写入；近七日是今天和之前六个本地日期，时区变化
不会重写已经写入的日期键。

宿主 hook 使用专用非阻塞 activity lock。锁忙、汇总损坏或发布失败时，回调进入私有 `0600` pending
delta，下一次成功读取、刷新或清除在同一把锁下合并；发布成功前不得删除 delta。汇总和 delta 有硬大小
及目录数量上限，符号链接、非 regular file、超限和损坏输入 fail closed。未知未来 JSON 字段和未知
未来 host/event key 在正常更新时保留。

清除活动是在 activity lock 内发布带 `clearedAt` 和本地日期的空七日摘要的事务。清除前迟到的 delta
被忽略，清除后的 delta 继续计数；失败时保留旧摘要，不删除 activation marker、稳定 receipt、receipt
history、声音配置或诊断日志。今日范围在下一个本地午夜后恢复完整，七日范围在清除日期离开窗口后恢复
完整。诊断日志清除是独立事务。

读取失败且没有成功快照时 UI 显示 unavailable；已有成功快照时保留数字并标记 stale。清除后的不完整区间
显示 partial 和起始时间。Global 只汇总真实支持对应事件的 Surface，并显示覆盖比例；不支持事件始终为
`—`，而不是把磁盘中的零解释为支持。

这取代旧的「每个 Surface 最多 20 条、近 30 天 receipt history 投影用量」合同。保留 receipt、activation
和诊断日志各自的事实与清理边界，不把新摘要变成第二个声音库、连接 owner 或宿主内容读取器。
