# claudi0 品牌资产

现行主方向为 **Orbit Zero**：末尾 `0` 是持续工作的信号容器，倾斜轨道表达 AI coding 的运行方向，偏心圆点代表刚抵达的状态通知。产品名写作 `claudi0`，仍读作 “Claudio”。

- `claudi0-mark.svg`：亮色表面的黏土色 Orbit Zero 主标志。
- `claudi0-app-icon.svg`：深色硬件感 macOS App 图标母版。
- `claudi0-app-icon.png`：1024×1024 预览与商店素材母版，由脚本生成。
- `claudi0.icns`：macOS bundle 图标，由脚本生成。

App 内横向字标由 `gui/Sources/ClaudioGUIComponents/ClaudioBranding.swift` 直接绘制；
菜单栏使用同一几何的 16pt 减法版本，不嵌入位图。

重新生成位图资产：

```sh
swift scripts/generate-brand-assets.swift
```

图形几何来自已选定的 Orbit Zero branding 稿，生成脚本不得用近似 SF Symbol 替代。
