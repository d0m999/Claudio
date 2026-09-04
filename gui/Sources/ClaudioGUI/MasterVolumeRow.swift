import ClaudioCore
import ClaudioGUIComponents
import ClaudioGUICore
import ClaudioLocalization
import SwiftUI

/// The panel's master-volume control row (PLAN-MASTER-VOLUME.md 阶段 D; DESIGN.md「控件行
/// （Control Row）」节): `[「主音量」SF Pro 13] · Spacer · [Slider]` — no event-color tile, no
/// speaker glyph. Agent 面板重构后百分比同时可见并继续作为 ``accessibilityValue``；拖动提交、
/// 回滚与关闭前 flush 的既有语义不变。
///
/// Every DECISION this row would otherwise have to make itself already happened elsewhere and
/// is independently unit-tested:
///
/// - **"How many disk writes does one drag produce"** is ``VolumeDragSession``'s entire reason
///   to exist (阶段 C1) — this view holds one as private ``@State`` (D8: a drag only invalidates
///   THIS row, never the five event rows + gallery) and only forwards callbacks.
/// - **"What actually gets written, and did it land"** is
///   ``PanelConfigController/setMasterVolume(_:)`` (阶段 D, D27/D39/D43) — this view never talks
///   to `ClaudioCore` directly, it calls ``onCommit`` and reacts to whether that returned a
///   landed value or `nil`.
///
/// so the only thing left for this file to get wrong is composition — exactly the shape
/// `EventRowView`/`AudioDropZoneView` already established.
public struct MasterVolumeRow: View {
    /// The `master_volume` currently on disk (``PanelConfigController/config``'s value) — NOT
    /// this row's own `@State`. Rule 5 (D21): this row must react when it changes out from under
    /// an open panel (another write landed, the popover reopened after an external edit), via
    /// ``VolumeDragSession/rebase(to:)`` — see ``body``'s `.onChange(of:)` below. Without it, a
    /// hand-edited `config.json` would leave the slider showing a value the disk no longer has,
    /// forever (D11's "unchanged means unwritten" means it would never self-heal on its own).
    public let diskVolume: Double
    /// `.needsPack` 等恢复态仍显示这行上下文，但禁止写入并从焦点顺序移除。
    public let isEnabled: Bool
    /// Writes `volume` through ``PanelConfigController/setMasterVolume(_:)`` and returns the
    /// **landed** (clamped) value on success, `nil` on failure — this view never calls
    /// `ClaudioCore` itself, it only resolves ``VolumeDragSession/commitSucceeded(_:)``/
    /// ``VolumeDragSession/commitFailed()`` off whichever this returns.
    public let onCommit: (Double) -> Double?
    /// Owned by `MenuBarController` for the app's whole lifetime, shared with `PanelView` — NOT
    /// constructed here. `.hideCount` is this row's flush signal (D22/D37): `PanelFocusCoordinator`
    /// already has it (T17d), and `MenuBarController.popoverDidClose`'s FIRST statement is already
    /// `notePanelHidden()`, ahead of the `guard NSApp.isActive` that would otherwise skip the most
    /// common close path ("clicked another app"). Reusing it means this row's flush automatically
    /// inherits that ordering guarantee — no second counter, no second AppKit callback to place
    /// correctly.
    @ObservedObject public var focusCoordinator: PanelFocusCoordinator
    /// The SHARED `@FocusState` binding `PanelView` owns (a11y-architect FIX 4) — mirrors
    /// `EventRowView`'s own `focusedTarget` parameter exactly.
    private let focusedTarget: FocusState<PanelFocusTarget?>.Binding
    public let adaptation: PanelLayoutAdaptation
    public let language: ClaudioAppLanguage

    @Environment(\.colorScheme) private var colorScheme
    /// Dynamic-Type scale factor for this row's fixed `.system(size:)` text (a11y fix) — see
    /// `EventRowView`'s `typeScale` for the full rationale.
    @ScaledMetric(relativeTo: .body) private var typeScale: CGFloat = 1

    public init(
        diskVolume: Double,
        isEnabled: Bool = true,
        onCommit: @escaping (Double) -> Double?,
        focusCoordinator: PanelFocusCoordinator,
        focusedTarget: FocusState<PanelFocusTarget?>.Binding,
        adaptation: PanelLayoutAdaptation = panelLayoutAdaptation(for: .standard),
        language: ClaudioAppLanguage = .zhHans
    ) {
        self.diskVolume = diskVolume
        self.isEnabled = isEnabled
        self.onCommit = onCommit
        self.focusCoordinator = focusCoordinator
        self.focusedTarget = focusedTarget
        self.adaptation = adaptation
        self.language = language
    }

    public var body: some View {
        Group {
            if adaptation.rowWrapsToTwoLines {
                // "更大" tier (D17/D44 — the term is `.largest`, NOT `.larger`): label on top,
                // the slider spanning the full row below. Master-volume and pack rows continue
                // to share `rowWrapsToTwoLines`; EventRow's separate maximum-only action placement
                // does not change this control-row contract (DESIGN.md「控件行」).
                VStack(alignment: .leading, spacing: 2) {
                    label
                    slider
                }
            } else {
                HStack(spacing: 8) {
                    label
                    Spacer(minLength: 8)
                    slider
                }
            }
        }
        .frame(minHeight: adaptation.rowWrapsToTwoLines ? 44 : 28)
        .disabled(!isEnabled)
    }

    private var label: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(ClaudioL10n(language: language).text(.panelMasterVolume))
                .font(.system(size: 12.5 * typeScale, weight: .medium, design: .rounded))
                .foregroundColor(ClaudioColor.text(colorScheme))
            Text(ClaudioL10n(language: language).text(.panelMasterVolumeDescription))
                .font(.system(size: 9.5 * typeScale, design: .rounded))
                .foregroundColor(ClaudioColor.textSecondary(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityHidden(true)
    }

    private var slider: some View {
        SharedMasterVolumeSlider(
            diskVolume: diskVolume,
            isEnabled: isEnabled,
            language: language,
            accessibilityIdentifier: "panel.master-volume",
            percentageWidth: 38,
            flushRevision: focusCoordinator.hideCount,
            onCommit: onCommit
        )
        .focused(focusedTarget, equals: .masterVolume)
    }
}
