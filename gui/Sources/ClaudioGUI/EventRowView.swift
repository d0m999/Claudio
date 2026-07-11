import AppKit
import ClaudioCore
import ClaudioGUICore
import SwiftUI
import UniformTypeIdentifiers

/// One event row (DESIGN.md "行结构（每事件行）" + "事件行三态", ENGINEERING.md T16 D4):
/// renders purely off ``EventRow`` (`ClaudioGUICore`, computed by
/// ``packCoverage(packID:config:environment:)``) — every state DECISION
/// (present/unmapped/broken, ``CoverageState/previewEnabled``, muted-vs-not) already
/// happened in `ClaudioGUICore` before this view ever renders. This view only lays pixels
/// out and wires the row-end drag-to-bind affordance (``EventRowImportViewModel``, T16 D3)
/// for the `unmapped`/`broken` states — no hardening/validation logic lives here, all of
/// it is in `ClaudioGUICore`'s `importAudioFile`/`bindEventToManifest`.
///
/// Row height ~28pt, per DESIGN.md「间距」("菜单栏面板行高 ~28pt").
public struct EventRowView: View {
    public let row: EventRow
    @ObservedObject private var importViewModel: EventRowImportViewModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHoveringImportTarget = false

    /// Invoked when the 试听 (preview) button is tapped — only ever reachable while
    /// ``CoverageState/previewEnabled`` is `true`. This view never resolves the sound
    /// file's absolute path or plays it itself (`CoverageState.present` only carries a
    /// bare filename, by design — see its doc comment); the caller, which already has the
    /// pack directory in hand from computing ``EventRow``, owns turning this into an actual
    /// playback call. Mirrors `AudioImportViewModel/onImportSucceeded`'s hook-based shape.
    public let onPreview: () -> Void

    /// Invoked when the 静音钮 (mute toggle) is tapped (ENGINEERING.md 决议③, T15 D4) — the
    /// write-back seam ``EventMuteController/setEnabled(_:enabled:)`` wires into. This view
    /// never calls into `ClaudioCore` itself and never re-derives the NEXT `enabled` value —
    /// the caller (which already knows ``EventRow/enabled``, the CURRENT value) owns
    /// deciding what "toggled" means and performing the actual write, exactly like
    /// ``onPreview``'s split between "this view says a tap happened" and "the caller decides
    /// what that means."
    public let onToggleMute: () -> Void

    /// The Dynamic Type degradation this row currently renders under (ENGINEERING.md
    /// T15 D5「无障碍规格 · Dynamic Type + 降级规则」, ``panelLayoutAdaptation(for:)``) —
    /// defaults to ``PanelTypeSizeTier/standard`` (today's single-line layout), so every
    /// existing call site (and this file's own doc-comment "Row height ~28pt" claim) stays
    /// correct unless a caller explicitly opts into a larger tier. `PanelView` (T15 D1)
    /// computes the real tier from `@Environment(\.dynamicTypeSize)` and passes it down —
    /// that environment read is SwiftUI-only and stays out of `ClaudioGUICore`, mirroring
    /// how `AudioDurationProbing` keeps AVFoundation out of the same module.
    public let adaptation: PanelLayoutAdaptation

    /// The SHARED focus-state binding this row's two controls report into (a11y-architect
    /// FIX 4): ``PanelView`` owns the actual `@FocusState` and passes its projected binding
    /// down here — this row never owns focus state itself, it only tells the shared binding
    /// "focus me" via ``PanelFocusTarget/eventAction(_:)``/``PanelFocusTarget/eventMute(_:)``
    /// (``panelFocusOrder(_:)``'s own per-row identities, `ClaudioGUICore`, so the SwiftUI
    /// binding and the pure focus-ORDER model key off the exact same values). Required (no
    /// default) since `PanelView` is this view's only real call site — see `PanelView`'s own
    /// doc comment.
    private let focusedTarget: FocusState<PanelFocusTarget?>.Binding

    public init(
        row: EventRow,
        importViewModel: EventRowImportViewModel,
        focusedTarget: FocusState<PanelFocusTarget?>.Binding,
        adaptation: PanelLayoutAdaptation = panelLayoutAdaptation(for: .standard),
        onPreview: @escaping () -> Void = {},
        onToggleMute: @escaping () -> Void = {}
    ) {
        self.row = row
        self.importViewModel = importViewModel
        self.focusedTarget = focusedTarget
        self.adaptation = adaptation
        self.onPreview = onPreview
        self.onToggleMute = onToggleMute
    }

    public var body: some View {
        Group {
            if adaptation.rowWrapsToTwoLines {
                // "更大" tier: 名/id 上、文件/控件下 — ENGINEERING.md's literal two-line
                // degradation, applied here rather than letting the single HStack truncate
                // or overflow at large Dynamic Type sizes.
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        glyphTile
                        identity
                        Spacer(minLength: 8)
                    }
                    HStack(spacing: 8) {
                        trailing
                    }
                }
            } else {
                HStack(spacing: 8) {
                    glyphTile
                    identity
                    Spacer(minLength: 8)
                    trailing
                }
            }
        }
        .frame(minHeight: adaptation.rowWrapsToTwoLines ? 44 : 28)
        // LOAD-BEARING (DESIGN.md, verbatim): "禁用观感用显式禁用样式（控件置灰 + 图标降饱和），
        // 不整行降 opacity（行内文字始终保 ≥ 4.5:1 对比度）" — the row itself NEVER has its
        // opacity reduced, in ANY state (present/unmapped/broken, enabled/muted). Disabled
        // controls below carry their own explicit greyed styling instead.
        //
        // `.contain`, NOT `.combine` (a11y-architect FIX 1, CRITICAL): `.combine` at the ROW
        // level swallowed `previewButton`/`muteIndicator`/`importAffordance` — each already
        // its own labeled `Button` — into ONE opaque VoiceOver element, so a VoiceOver/Switch
        // Control user could never reach or activate mute/preview independently, defeating
        // T15's own focus-order model (``panelFocusOrder(_:)`` names them as two SEPARATE
        // stops per row). `.contain` groups the row for navigation purposes without merging
        // its interactive children — the combined descriptive summary (name + sound +
        // enabled/muted) now lives on the NON-interactive ``identity`` node instead (below),
        // so VoiceOver still gets that summary when landing on the row's identity, while
        // Tab/VO-Right can still step onto each Button individually.
        .accessibilityElement(children: .contain)
    }

    // MARK: - Glyph tile

    private var glyphTile: some View {
        let color = ClaudioColor.event(row.event, colorScheme)
        return RoundedRectangle(cornerRadius: 6)
            .fill(color.opacity(0.15))
            .frame(width: 24, height: 24)
            .overlay(
                Image(systemName: eventGlyphName(row.event))
                    .font(.system(size: 12))
                    .foregroundColor(color)
            )
            .accessibilityHidden(true)
    }

    // MARK: - Event name + raw id

    /// The row's NON-interactive summary node (a11y-architect FIX 1): carries the combined
    /// descriptive announcement (DESIGN.md「无障碍规格」: "事件行→「{事件名}，声音 {文件名}，
    /// {已启用/已静音}」") that used to live on the whole row before `.contain` replaced
    /// `.combine` there. `presentTrailing`'s standalone `fileName` `Text` is hidden from
    /// accessibility (below) precisely because its content is already folded into THIS
    /// node's ``accessibilityLabel`` — so `.contain` at the row level doesn't spawn a
    /// second, redundant, unlabeled-ish stop for the same information.
    private var identity: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(eventDisplayName(row.event))
                .font(.system(size: 13))
                .foregroundColor(ClaudioColor.text(colorScheme))
            Text(row.event.cliName)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(ClaudioColor.textSecondary(colorScheme))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    // MARK: - Trailing (state-dependent) + orthogonal mute indicator

    @ViewBuilder
    private var trailing: some View {
        HStack(spacing: 6) {
            switch row.coverage {
            case .present(let fileName):
                presentTrailing(fileName: fileName)
            case .unmapped:
                // DESIGN.md line 127 specifies unmapped/broken rows as "试听 ▶ 禁用" — a
                // PRESENT-but-disabled preview button, not an absent one; render it here
                // too, not just for `.present`. `previewButton`'s own `enabled` already
                // folds in `row.coverage.previewEnabled` (false for `.unmapped`), so it
                // renders with its existing disabled styling automatically.
                importAffordance(label: "未配置")
                previewButton
            case .broken:
                importAffordance(label: "文件丢失")
                previewButton
            }
            muteIndicator
        }
    }

    private func presentTrailing(fileName: String) -> some View {
        HStack(spacing: 6) {
            // Full `textSecondary` in EVERY state (present, regardless of `row.enabled`) —
            // DESIGN.md's ≥4.5:1 in-row-text floor (line 127) applies here; the muted look
            // is carried, compliantly, by `muteIndicator` (lit clay when muted) and
            // `previewButton` (greyed + desaturated when muted, since its `enabled` already
            // folds in `row.enabled`) — never by dimming this text's opacity.
            Text(fileName)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(ClaudioColor.textSecondary(colorScheme))
                // 长文件名截断到一行、留尾（ENGINEERING.md T15 D5: "长文件名截断带尾"；"不裁切、
                // 不溢出" 指布局层面不裁掉整个控件，文本本身仍需截断以不撑爆行）。
                .lineLimit(1)
                .truncationMode(.tail)
                // Purely visual (a11y-architect FIX 1): its content is already folded into
                // `identity`'s combined ``accessibilityLabel`` ("声音 \(fileName)") — hiding
                // it here stops `.contain` (row-level) from spawning a second, redundant
                // stop for the same filename.
                .accessibilityHidden(true)
            // 波形占位（DESIGN.md「招牌母题：波形」）— T16 只画占位字形，真实波形渲染不在本任务范围。
            // "较大" 及以上 Dynamic Type 档位隐藏（ENGINEERING.md T15 D5: "较大 → 隐波形"）。
            if !adaptation.hidesWaveform {
                Image(systemName: "waveform")
                    .font(.system(size: 10))
                    .foregroundColor(ClaudioColor.textSecondary(colorScheme))
                    // Decorative only (a11y-architect FIX 1): `Image(systemName:)` would
                    // otherwise surface an SF-Symbol-derived accessibility label of its own
                    // (e.g. "waveform") as an unlabeled-feeling extra `.contain` stop.
                    .accessibilityHidden(true)
            }
            previewButton
        }
    }

    private var previewButton: some View {
        let enabled = row.coverage.previewEnabled && row.enabled
        return Button(action: onPreview) {
            Image(systemName: "speaker.wave.2")
                .font(.system(size: 12))
        }
        .buttonStyle(.plain)
        // ≥24×24 hit target (a11y-architect FIX 6, WCAG 2.5.8) — the 22×22 background circle
        // stays the same VISUAL size below; `minWidth`/`minHeight` only grows the tappable
        // area, glyph point size is untouched.
        .frame(minWidth: 24, minHeight: 24)
        .background(
            Circle()
                .fill(enabled ? ClaudioColor.event(row.event, colorScheme).opacity(0.15) : Color.clear)
                .frame(width: 22, height: 22)
        )
        // 显式禁用样式（DESIGN.md 硬约束）：图标置灰 + 降饱和，绝不靠整行 opacity 传达禁用。
        .foregroundColor(enabled ? ClaudioColor.event(row.event, colorScheme) : ClaudioColor.textSecondary(colorScheme))
        .saturation(enabled ? 1 : 0)
        .disabled(!enabled)
        .contentShape(Rectangle())
        .accessibilityLabel("试听 \(eventDisplayName(row.event)) 的声音")
        // a11y-architect FIX 4: this is the row's `.eventAction` slot when coverage is
        // `.present` — `panelFocusOrder(_:)`'s SAME identity, never a second one.
        .focused(focusedTarget, equals: .eventAction(row.event))
    }

    /// The row-end drag-to-bind affordance for `unmapped`/`broken` rows (DESIGN.md: "行尾
    /// 提供逐事件导入绑定"). Reuses ``EventRowImportViewModel/handleDrop(sourceURL:suggestedFileName:)``
    /// (T16 D3 — import via the existing hardened pipeline, then bind) and
    /// ``loadDropRequest(from:)`` (the exact same `NSItemProvider` extraction
    /// `AudioDropZoneView` already uses), never a second drop-handling implementation.
    ///
    /// A real `Button` (a11y-architect FIX 2, CRITICAL — WCAG 2.1.1): this control's own
    /// accessibility label has always promised "拖入或点按" (drag OR TAP), but until this fix
    /// it only ever handled `.onDrop` — a keyboard/VoiceOver/Switch Control user had no way
    /// to activate it at all. Tapping/activating now opens ``openImportPanel()`` (an
    /// `NSOpenPanel`), feeding the chosen file into the exact same
    /// `importViewModel.handleDrop(sourceURL:suggestedFileName:)` pipeline a drop already
    /// used — never a second import path. `.onDrop` is preserved unchanged alongside it.
    private func importAffordance(label: String) -> some View {
        Button(action: openImportPanel) {
            HStack(spacing: 4) {
                Text(label)
                    .font(.system(size: 11))
                    .foregroundColor(ClaudioColor.textSecondary(colorScheme))
                Image(systemName: "square.and.arrow.down")
                    .font(.system(size: 11))
                    .foregroundColor(
                        isHoveringImportTarget
                            ? ClaudioColor.clay(colorScheme) : ClaudioColor.textSecondary(colorScheme))
            }
            .padding(.vertical, 3)
            .padding(.horizontal, 6)
            // ≥24×24 hit target (a11y-architect FIX 6, WCAG 2.5.8).
            .frame(minHeight: 24)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHoveringImportTarget ? ClaudioColor.claySoft(colorScheme) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(
                        isHoveringImportTarget
                            ? ClaudioColor.clay(colorScheme) : ClaudioColor.hairlineStrong(colorScheme),
                        style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onDrop(of: [UTType.fileURL], isTargeted: $isHoveringImportTarget, perform: handleDrop)
        .accessibilityLabel("拖入或点按，绑定声音到 \(eventDisplayName(row.event))")
        // a11y-architect FIX 4: this is the row's `.eventAction` slot when coverage is
        // `.unmapped`/`.broken` — the SAME identity `previewButton` uses for `.present`,
        // since a row only ever renders ONE of the two at a time (never both).
        .focused(focusedTarget, equals: .eventAction(row.event))
    }

    /// Opens an `NSOpenPanel` scoped to the same wav/mp3/aiff/m4a whitelist
    /// ``AudioFormat`` documents (ENGINEERING.md 决议 "拖入自带音频"), feeding the chosen
    /// file into the SAME hardened import pipeline `.onDrop` already uses. The panel's
    /// `allowedContentTypes` is a picker-UX nicety only, never the actual security
    /// boundary — a mislabeled file still gets content-sniffed and can still be rejected by
    /// `importAudioFile`'s real magic-byte check (``sniffAudioFormat(_:)``) exactly as a
    /// drag-and-drop would be. AppKit — compile-only here, manual-verify on a real Mac.
    private func openImportPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = audioOpenPanelContentTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let suggestedFileName = url.lastPathComponent
        Task { @MainActor in
            await importViewModel.handleDrop(sourceURL: url, suggestedFileName: suggestedFileName)
        }
    }

    /// The orthogonal 静音态 (enabled=false) toggle (决议③, DESIGN.md: "静音钮点亮") —
    /// present on every row regardless of ``CoverageState``, since muting overlays coverage
    /// rather than replacing it. T16 left this presentation-only; T15 D4 wires it to
    /// ``onToggleMute`` — a real `Button`, not a bare `Image`, per DESIGN.md「无障碍规格」:
    /// "静音钮→切换按钮「{事件名} 声音」+ on/off" (a *button*, not a static glyph).
    private var muteIndicator: some View {
        Button(action: onToggleMute) {
            Image(systemName: row.enabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                .font(.system(size: 11))
        }
        .buttonStyle(.plain)
        // ≥24×24 hit target (a11y-architect FIX 6, WCAG 2.5.8) — previously unsized, so it
        // shrank to the 11pt glyph's own tiny intrinsic bounds.
        .frame(minWidth: 24, minHeight: 24)
        .contentShape(Rectangle())
        .foregroundColor(
            row.enabled ? ClaudioColor.textSecondary(colorScheme) : ClaudioColor.clay(colorScheme))
        .accessibilityLabel("\(eventDisplayName(row.event)) 声音")
        .accessibilityValue(row.enabled ? "已启用" : "已静音")
        .accessibilityAddTraits(.isButton)
        // a11y-architect FIX 4: this row's `.eventMute` slot — `panelFocusOrder(_:)`'s SAME
        // identity, never a second one.
        .focused(focusedTarget, equals: .eventMute(row.event))
    }

    // MARK: - Drop handling (mirrors AudioDropZoneView.handleDrop(_:) exactly, scoped to a
    // single file — a row binds to exactly one event, so unlike the drop-zone's own
    // multi-file batch there is no ambiguity to resolve here)

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        Task { @MainActor in
            guard let request = await loadDropRequest(from: provider) else { return }
            await importViewModel.handleDrop(
                sourceURL: request.sourceURL, suggestedFileName: request.suggestedFileName)
        }
        return true
    }

    // MARK: - Accessibility (DESIGN.md「无障碍规格」: "事件行→「{事件名}，声音 {文件名}，
    // {已启用/已静音}」")

    private var accessibilityLabel: String {
        let soundDescription: String
        switch row.coverage {
        case .present(let fileName): soundDescription = "声音 \(fileName)"
        case .unmapped: soundDescription = "未配置声音"
        case .broken: soundDescription = "声音文件丢失"
        }
        let muteDescription = row.enabled ? "已启用" : "已静音"
        return "\(eventDisplayName(row.event))，\(soundDescription)，\(muteDescription)"
    }
}

/// The product-language Chinese display name for each event (ASCII 线框: "干完了 (Stop)" /
/// "中断了 (StopFailure)" / "要你确认 (Notification)" / "子任务完成 (SubagentStop)") — kept
/// here (not in `ClaudioGUICore`) since it is static, deterministic presentation copy with
/// no state decision behind it, mirroring how `OnboardingView.iconName(for:)` stays local to
/// its own view file rather than round-tripping through the Foundation-only core module.
func eventDisplayName(_ event: Event) -> String {
    switch event {
    case .stop: "干完了"
    case .stopFailure: "中断了"
    case .notification: "要你确认"
    case .subagentStop: "子任务完成"
    }
}
