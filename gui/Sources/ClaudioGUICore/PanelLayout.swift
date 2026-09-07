import Foundation

/// 菜单栏面板的唯一生产宽度。显示页不再拥有字号或宽度偏好；此常量是 Panel、AppKit
/// popover 与 DEBUG 画廊共同使用的紧凑布局事实。
public let standardPanelWidth: Double = 312

/// 固定紧凑布局的纯值投影。保留行组件需要的几何字段，但不再由用户偏好驱动。
public struct PanelLayoutAdaptation: Sendable, Equatable {
    public let hidesWaveform: Bool
    public let rowWrapsToTwoLines: Bool
    public let eventActionsMoveBelow: Bool
    public let panelWidth: Double

    public init(
        hidesWaveform: Bool = false,
        rowWrapsToTwoLines: Bool = false,
        eventActionsMoveBelow: Bool = false,
        panelWidth: Double = standardPanelWidth
    ) {
        self.hidesWaveform = hidesWaveform
        self.rowWrapsToTwoLines = rowWrapsToTwoLines
        self.eventActionsMoveBelow = eventActionsMoveBelow
        self.panelWidth = panelWidth
    }
}

public func panelLayoutAdaptation() -> PanelLayoutAdaptation {
    PanelLayoutAdaptation()
}
