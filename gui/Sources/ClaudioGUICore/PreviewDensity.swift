#if DEBUG
import SwiftUI

/// DEBUG 画廊的固定密度标记。它不是偏好、不会读写 UserDefaults，也不进入 Release 组合根；
/// 仅用于让旧的预览组件以单一 `.standard` 形态编译，生产 UI 不再暴露字号档位。
public enum ClaudioCompactPreviewDensity: String, CaseIterable, Sendable, Identifiable {
    case standard

    public var id: String { rawValue }
    public var scale: Double { 1 }
    public var dynamicTypeSize: DynamicTypeSize { .large }
}

extension ClaudioPreferenceSnapshot {
    public var compactPreviewDensity: ClaudioCompactPreviewDensity { .standard }
}

extension ClaudioPreferences {
    public var compactPreviewDensity: ClaudioCompactPreviewDensity { .standard }
    public func setCompactPreviewDensity(_: ClaudioCompactPreviewDensity) {}
}
#endif
