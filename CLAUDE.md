# Claudio

Claude Code 的语义化提示音 · 策展声音包（macOS 菜单栏 app）。核心记忆点：**不回头也知道状态**。

## 文件分工

- **[DESIGN.md](./DESIGN.md)** —— 视觉设计系统（美学 / 字体 / 配色 / 间距 / 布局 / 动效 / 声音视觉语言 / App 图标）。
- **[ENGINEERING.md](./ENGINEERING.md)** —— 产品 + 工程 spec（架构、helper-CLI 契约、settings.json 接管、声音包格式、实现任务、评审决议）。

## Design System

做任何视觉 / UI 决策前，**先读 [DESIGN.md](./DESIGN.md)**。字体、配色、间距、圆角、动效、四事件可视体系、美学方向都定义在那里。

- 不经明确授权不得偏离 DESIGN.md。
- QA 模式下，标出任何不符 DESIGN.md 的代码。
- App 内 UI 用系统 SF Pro；展示 / 品牌用 General Sans（自托管）；数据 / 代码用 JetBrains Mono。
- 品牌强调唯一 = 黏土 `#D97757`；四事件语义色（Stop 绿 / StopFailure 琥珀 / Notification 黏土 / SubagentStop 靛）；**StopFailure 绝不用红**；真红 `#FF453A` 只给 App 自身真错误。
- 面板用近实心暖表面 + 1px 描边（**不用**满毛玻璃），保事件色真色。
