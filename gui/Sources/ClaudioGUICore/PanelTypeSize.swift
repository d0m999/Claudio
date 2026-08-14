import Foundation

/// The panel's own four-tier reduction of macOS's eleven `DynamicTypeSize` cases
/// (ENGINEERING.md「无障碍规格」"Dynamic Type + 降级规则": "312pt 单行塞 名+id+文件+波形+
/// 试听+静音，大字号必挤；降级：较大 → 隐波形；更大 → 事件行转两行（名/id 上、文件/控件
/// 下）；极大 → 加宽 popover。不裁切、不溢出。") — kept as a small, ordered, Foundation-only
/// enum rather than depending on SwiftUI's own `DynamicTypeSize` directly, so this
/// degradation TABLE (the actual decision) is testable in this dependency-free harness. The
/// persisted four-level preference → ``PanelTypeSizeTier`` projection also lives here; only its
/// final conversion to SwiftUI's `DynamicTypeSize` remains in `ClaudioGUI`.
///
/// Each case is CUMULATIVE with the ones before it (not mutually exclusive): `.larger`'s
/// adaptation carries into `.largest`/`.maximum`, `.largest`'s into `.maximum`, matching
/// ENGINEERING.md's own three additive rules exactly ("较大 →..." then "更大 →... [仍隐波形]"
/// then "极大 →... [仍两行+隐波形]").
public enum PanelTypeSizeTier: Sendable, Equatable, CaseIterable {
    /// Default legibility — the panel's normal layout, no legacy row adaptation.
    case standard
    /// "较大" — hide the waveform placeholder to reclaim horizontal room.
    case larger
    /// "更大" — additionally enable the older two-line adaptation consumed by pack and
    /// master-volume rows. Event titles already admit two lines at every tier.
    case largest
    /// "极大" — additionally widen the popover beyond 312pt and move event actions below.
    case maximum
}

/// One concrete layout decision for a ``PanelTypeSizeTier`` — a plain, comparable value so
/// a test can assert the exact shape without SwiftUI's `DynamicTypeSize`/`Font` types at
/// all.
public struct PanelLayoutAdaptation: Sendable, Equatable {
    public let hidesWaveform: Bool
    /// Cumulative two-line fallback retained for pack and master-volume rows.
    public let rowWrapsToTwoLines: Bool
    /// Event rows keep preview/mute overlaid at the upper trailing edge for every ordinary
    /// interface-text tier. Only the maximum tier moves those actions below the identity chips.
    /// This is intentionally separate from ``rowWrapsToTwoLines``: that older adaptation still
    /// drives pack and master-volume rows from `.largest` onward.
    public let eventActionsMoveBelow: Bool
    /// The popover's width in points — DESIGN.md's 312pt standard width, widened only at
    /// ``PanelTypeSizeTier/maximum``.
    public let panelWidth: Double

    public init(
        hidesWaveform: Bool,
        rowWrapsToTwoLines: Bool,
        eventActionsMoveBelow: Bool = false,
        panelWidth: Double
    ) {
        self.hidesWaveform = hidesWaveform
        self.rowWrapsToTwoLines = rowWrapsToTwoLines
        self.eventActionsMoveBelow = eventActionsMoveBelow
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

/// The persisted four-level interface preference and the panel's older cumulative adaptation
/// tiers are deliberately different vocabularies. Keeping this projection in the Foundation-only
/// core makes all four mappings testable and prevents Panel/State Gallery drift.
public func panelTypeSizeTier(
    for interfaceTextSize: ClaudioInterfaceTextSize
) -> PanelTypeSizeTier {
    switch interfaceTextSize {
    case .compact, .standard: .standard
    case .large: .largest
    case .maximum: .maximum
    }
}

/// The degradation table itself — ENGINEERING.md's three legacy rules applied cumulatively,
/// plus the C event-row layout's maximum-only action placement.
public func panelLayoutAdaptation(for tier: PanelTypeSizeTier) -> PanelLayoutAdaptation {
    switch tier {
    case .standard:
        PanelLayoutAdaptation(
            hidesWaveform: false,
            rowWrapsToTwoLines: false,
            panelWidth: standardPanelWidth)
    case .larger:
        PanelLayoutAdaptation(
            hidesWaveform: true,
            rowWrapsToTwoLines: false,
            panelWidth: standardPanelWidth)
    case .largest:
        PanelLayoutAdaptation(
            hidesWaveform: true,
            rowWrapsToTwoLines: true,
            panelWidth: standardPanelWidth)
    case .maximum:
        PanelLayoutAdaptation(
            hidesWaveform: true,
            rowWrapsToTwoLines: true,
            eventActionsMoveBelow: true,
            panelWidth: widenedPanelWidth)
    }
}
