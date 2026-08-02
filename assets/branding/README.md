# claudi0 品牌资产

现行主方向为 **C / Signal**：未闭合的 `C` 是信号容器，中间脉冲代表声音，右侧圆点代表刚抵达的状态通知。产品名写作 `claudi0`，仍读作 “Claudio”。

- `claudi0-mark.svg`：亮色表面的黏土色主标志。
- `claudi0-app-icon.svg`：深色硬件感 macOS App 图标母版。
- `claudi0-app-icon.png`：1024×1024 预览与商店素材母版，由脚本生成。
- `claudi0.icns`：macOS bundle 图标，由脚本生成。

重新生成位图资产：

```sh
swift scripts/generate-brand-assets.swift
```

图形几何来自已选定的 branding 稿，生成脚本不得用近似 SF Symbol 替代。
