---
status: accepted
---

# 使用全局声音默认值与稀疏 surface 覆盖

claudi0 的顶层 `selected_pack`、事件开关和 `master_volume` 继续是声音默认值。具体
`HostSurfaceID` 只在 `surface_overrides` 下保存用户明确改过的 `selected_pack` 或单个事件开关；
缺失字段逐项继承顶层默认值。`master_volume` 保持唯一全局轴，不提供 per-surface 副本。

读取必须通过一个 effective profile 解析入口合成默认值与覆盖。某个 surface 的显式覆盖损坏时，
该 surface fail closed 并停止播放，不能回退到全局配置掩盖损坏；其他 surface 和全局播放不受影响。
写入使用既有 `config.lock` 和外科式 JSON 更新，保留未知顶层字段、未知其他 surface 与未来字段。
reset 按字段或整 surface 删除覆盖；空 object 必须从配置中移除，使继承重新成为显式语义。

连接与声音偏好是正交事实。首次连接不创建覆盖、不播放试听；断开只撤销当前 activation，不删除
surface 偏好或脱敏历史。popup 只显示当前已配置/可用来源的 effective profile，管理窗口继续展示
全部已发布 adapter 的连接、版本、绑定和回执事实。显式引用不存在或损坏声音包的覆盖不得使用
全局包兜底，因为那会把错误配置伪装成成功。
