import ClaudioGUICore

@MainActor
func runPanelTypeSizeSuites() {
    suite("固定紧凑布局：Panel geometry 不再由字号或宽度偏好分支") {
        let adaptation = panelLayoutAdaptation()
        expect(adaptation.panelWidth == 312, "Panel 宽度必须固定为 312pt")
        expect(!adaptation.hidesWaveform, "紧凑布局保留事件行的既有内容")
        expect(!adaptation.rowWrapsToTwoLines, "紧凑布局不引入字号驱动的布局矩阵")
        expect(!adaptation.eventActionsMoveBelow, "紧凑布局保留事件操作位置")
        expect(
            standardPanelWidth == adaptation.panelWidth,
            "AppKit popover 与 SwiftUI Panel 必须消费同一宽度事实")
    }
}
