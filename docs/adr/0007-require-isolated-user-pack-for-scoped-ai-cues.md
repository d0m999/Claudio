---
status: accepted
---

# 为来源级 AI 提示音要求独立用户声音包

声音包 manifest 的事件到音频映射是包级事实，不是 per-surface 配置。`surface_overrides` 只稀疏
选择整个声音包和事件开关；若两个声音作用域解析到同一个包，直接修改该包的事件映射会同时影响
两个来源。因此首版 AI 提示音只允许从明确的非全局 `HostSurfaceID` 进入，并要求目标为可编辑、
已安装且只被该来源有效选择的用户声音包。全局作用域、内置包、陈旧选择或被其他作用域共享的包
全部 fail closed，UI 引导用户先复制或切换到独立用户包。

采用请求必须显式捕获 `HostSurfaceID + Event + packID`，并在任何文件写入前重新解析配置和声音包
快照。只有目标仍属于同一来源、仍可编辑且仍未共享时，候选才进入既有 `AudioImport` 与 manifest
bind。这样保留 ADR 0005 的稀疏 surface 覆盖和 pack 作为声音映射真相源，也让“只影响此来源”
成为可验证的不变量，而不是 UI 文案承诺。

代价是首版不能在全局声音默认值中生成，也不能直接编辑多个来源共用的用户包。未来若要支持共享
包中的来源级差异，应另行设计明确的 overlay 或复制语义，并迁移配置；不能把 per-surface 映射
暗中塞进现有 manifest 或 `surface_overrides`。
