import Foundation

/// The panel's own four-tier reduction of macOS's eleven `DynamicTypeSize` cases
/// (ENGINEERING.md「无障碍规格」"Dynamic Type + 降级规则": "312pt 单行塞 名+id+文件+波形+
/// 试听+静音，大字号必挤；降级：较大 → 隐波形；更大 → 事件行转两行（名/id 上、文件/控件
/// 下）；极大 → 加宽 popover。不裁切、不溢出。") — kept as a small, ordered, Foundation-only
/// enum rather than depending on SwiftUI's own `DynamicTypeSize` directly, so this
/// degradation TABLE (the actual decision) is testable in this dependency-free harness; the
/// real `DynamicTypeSize` → ``PanelTypeSizeTier`` mapping is a one-line, untestable
/// SwiftUI-side lookup in `ClaudioGUI` (compile-only there).
///
/// Each case is CUMULATIVE with the ones before it (not mutually exclusive): `.larger`'s
/// adaptation carries into `.largest`/`.maximum`, `.largest`'s into `.maximum`, matching
/// ENGINEERING.md's own three additive rules exactly ("较大 →..." then "更大 →... [仍隐波形]"
/// then "极大 →... [仍两行+隐波形]").
public enum PanelTypeSizeTier: Sendable, Equatable, CaseIterable {
    /// Default legibility — the panel's normal single-line row layout, no adaptation.
    case standard
    /// "较大" — hide the waveform placeholder to reclaim horizontal room.
    case larger
    /// "更大" — additionally wrap each event row onto two lines (name/id on top,
    /// file/controls below).
    case largest
    /// "极大" — additionally widen the popover itself beyond the standard 312pt.
    case maximum
}

/// One concrete layout decision for a ``PanelTypeSizeTier`` — a plain, comparable value so
/// a test can assert the exact shape without SwiftUI's `DynamicTypeSize`/`Font` types at
/// all.
public struct PanelLayoutAdaptation: Sendable, Equatable {
    public let hidesWaveform: Bool
    public let rowWrapsToTwoLines: Bool
    /// The popover's width in points — DESIGN.md's 312pt standard width, widened only at
    /// ``PanelTypeSizeTier/maximum``.
    public let panelWidth: Double

    public init(hidesWaveform: Bool, rowWrapsToTwoLines: Bool, panelWidth: Double) {
        self.hidesWaveform = hidesWaveform
        self.rowWrapsToTwoLines = rowWrapsToTwoLines
        self.panelWidth = panelWidth
    }
}

/// DESIGN.md's standard panel width (`312pt`) — the width every tier below `.maximum`
/// keeps unchanged.
public let standardPanelWidth: Double = 312

/// The panel's own widened width at ``PanelTypeSizeTier/maximum`` — chosen as a round,
/// clearly-larger increment over ``standardPanelWidth``; ENGINEERING.md specifies THAT the
/// popover must widen at this tier, not by how much, so this exact value is this file's own
/// concrete choice, not lifted from DESIGN.md/ENGINEERING.md.
public let widenedPanelWidth: Double = 360

/// The degradation table itself — ENGINEERING.md's three rules, applied cumulatively.
public func panelLayoutAdaptation(for tier: PanelTypeSizeTier) -> PanelLayoutAdaptation {
    switch tier {
    case .standard:
        PanelLayoutAdaptation(hidesWaveform: false, rowWrapsToTwoLines: false, panelWidth: standardPanelWidth)
    case .larger:
        PanelLayoutAdaptation(hidesWaveform: true, rowWrapsToTwoLines: false, panelWidth: standardPanelWidth)
    case .largest:
        PanelLayoutAdaptation(hidesWaveform: true, rowWrapsToTwoLines: true, panelWidth: standardPanelWidth)
    case .maximum:
        PanelLayoutAdaptation(hidesWaveform: true, rowWrapsToTwoLines: true, panelWidth: widenedPanelWidth)
    }
}
