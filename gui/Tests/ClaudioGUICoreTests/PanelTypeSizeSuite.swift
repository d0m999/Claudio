import ClaudioGUICore
import Foundation

// MARK: - panelLayoutAdaptation (ENGINEERING.md T15 D5: Dynamic Type 降级规则). Pins the
// three cumulative rules ENGINEERING.md's a11y spec defines: 较大→隐波形, 更大→两行,
// 极大→加宽 popover, plus the C event-row layout's maximum-only action placement.

@MainActor
func runPanelTypeSizeSuites() {
    suite("panelLayoutAdaptation: .standard has no adaptation at all") {
        let adaptation = panelLayoutAdaptation(for: .standard)
        expect(!adaptation.hidesWaveform, "standard must not hide the waveform")
        expect(!adaptation.rowWrapsToTwoLines, "standard must not wrap rows")
        expect(!adaptation.eventActionsMoveBelow, "standard must keep event actions overlaid")
        expect(adaptation.panelWidth == standardPanelWidth, "standard must keep the 312pt width")
    }

    suite("panelLayoutAdaptation: .larger hides the waveform only") {
        let adaptation = panelLayoutAdaptation(for: .larger)
        expect(adaptation.hidesWaveform, "larger must hide the waveform")
        expect(!adaptation.rowWrapsToTwoLines, "larger must NOT yet wrap rows")
        expect(!adaptation.eventActionsMoveBelow, "larger must keep event actions overlaid")
        expect(adaptation.panelWidth == standardPanelWidth, "larger must keep the standard width")
    }

    suite("panelLayoutAdaptation: .largest hides the waveform AND wraps rows (cumulative)") {
        let adaptation = panelLayoutAdaptation(for: .largest)
        expect(adaptation.hidesWaveform, "largest must still hide the waveform")
        expect(adaptation.rowWrapsToTwoLines, "largest must wrap rows to two lines")
        expect(!adaptation.eventActionsMoveBelow, "largest must keep event actions overlaid")
        expect(adaptation.panelWidth == standardPanelWidth, "largest must keep the standard width")
    }

    suite("panelLayoutAdaptation: .maximum carries every prior adaptation AND widens the popover") {
        let adaptation = panelLayoutAdaptation(for: .maximum)
        expect(adaptation.hidesWaveform, "maximum must still hide the waveform")
        expect(adaptation.rowWrapsToTwoLines, "maximum must still wrap rows")
        expect(adaptation.eventActionsMoveBelow, "maximum must move event actions below the chips")
        expect(adaptation.panelWidth == widenedPanelWidth, "maximum must widen beyond the standard 312pt")
        expect(adaptation.panelWidth > standardPanelWidth, "the widened width must be strictly larger")
    }

    suite("panelLayoutAdaptation: every tier is covered exactly once, no crashes") {
        for tier in PanelTypeSizeTier.allCases {
            _ = panelLayoutAdaptation(for: tier)
        }
        expect(PanelTypeSizeTier.allCases.count == 4, "expected exactly 4 tiers, got \(PanelTypeSizeTier.allCases.count)")
    }

    suite("panelTypeSizeTier: all four persisted interface sizes map explicitly") {
        let expectations: [(ClaudioInterfaceTextSize, PanelTypeSizeTier)] = [
            (.compact, .standard),
            (.standard, .standard),
            (.large, .largest),
            (.maximum, .maximum),
        ]
        for (interfaceTextSize, expectedTier) in expectations {
            expect(
                panelTypeSizeTier(for: interfaceTextSize) == expectedTier,
                "\(interfaceTextSize.rawValue) must map to \(expectedTier)")
        }
    }

    suite("panelLayoutAdaptation: only maximum moves event actions below") {
        let movingTiers = PanelTypeSizeTier.allCases.filter {
            panelLayoutAdaptation(for: $0).eventActionsMoveBelow
        }
        expect(
            movingTiers == [.maximum],
            "event actions must move below only at maximum, got \(movingTiers)")
    }
}
