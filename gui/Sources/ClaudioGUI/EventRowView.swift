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

    /// The row's UNDERLYING drop-zone mechanics (``EventRowImportViewModel/importViewModel``),
    /// observed SEPARATELY (`/ship` 评审 · 静默吞错修复): `@ObservedObject` on the outer
    /// ``EventRowImportViewModel`` only republishes ITS OWN `@Published` members (`bindResult`) —
    /// a nested `ObservableObject`'s changes do NOT propagate through its parent. So the
    /// IMPORT-side failure surface (``AudioImportViewModel/state`` == `.reject`, i.e. 超大 /
    /// 格式不对 / 时长超限) would never invalidate this view if we only observed the outer one,
    /// and ``importErrorMessage`` below reads BOTH surfaces. Same instance either way — this is
    /// an extra observation of the object the row was already handed, never a second view-model.
    @ObservedObject private var dropState: AudioImportViewModel

    @Environment(\.colorScheme) private var colorScheme
    @State private var isHoveringImportTarget = false

    /// Dynamic-Type scale factor for this row's text (a11y fix): every `Text`/glyph below uses
    /// a fixed `.system(size:)` point size, which does NOT scale with the user's Content Size
    /// Category on its own — so before this, `PanelView`'s `dynamicTypeSize`-driven layout
    /// degradation (hide waveform / wrap rows / widen popover) fired while the text itself stayed
    /// literally 10–13pt, delivering the layout cost with zero legibility gain. Multiplying each
    /// fixed size by this `@ScaledMetric(relativeTo: .body)` value (1.0 at the default size, larger
    /// at accessibility sizes) makes the text actually grow, preserving each base size exactly at
    /// the default setting. `.lineLimit(1)`/`.truncationMode(.tail)` (already present) keep scaled
    /// text from overflowing; the layout tiers reclaim room. Real-Mac walkthrough of the scaled
    /// layout at each tier remains a manual-verify item (TODOS.md).
    @ScaledMetric(relativeTo: .body) private var typeScale: CGFloat = 1

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

    /// Invoked after a row-end import attempt (drag OR pick) finishes — success or failure
    /// (T16 fix: bind→refresh). ``EventRowImportViewModel/handleDrop(sourceURL:suggestedFileName:)``
    /// only mutates its own `@Published bindResult`; the row itself renders purely off the
    /// ``EventRow`` value ``PanelView`` passes down, which nothing recomputes on a bind. So a
    /// successful bind wrote `manifest.json` but the row kept showing "未配置/文件丢失" until
    /// an unrelated action (mute/switch-pack/reopen) happened to call ``PanelView``'s
    /// `refresh()`. This seam lets the caller (``PanelView``) recompute ``EventRow``/``PackCard``
    /// from disk the instant a bind lands, exactly like ``onToggleMute``'s tap→write→refresh
    /// split. Fires on failure too (harmless: `refresh()` just recomputes the unchanged state).
    public let onImportCompleted: () -> Void

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
        onToggleMute: @escaping () -> Void = {},
        onImportCompleted: @escaping () -> Void = {}
    ) {
        self.row = row
        self.importViewModel = importViewModel
        // The SAME object `importViewModel` already owns — observed a second time so this view
        // also re-renders on the IMPORT-side `.reject` surface (see `dropState`'s doc comment).
        _dropState = ObservedObject(wrappedValue: importViewModel.importViewModel)
        self.focusedTarget = focusedTarget
        self.adaptation = adaptation
        self.onPreview = onPreview
        self.onToggleMute = onToggleMute
        self.onImportCompleted = onImportCompleted
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
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

            // 绝不静默吞错（项目规则原文: "never a silent no-op reported as success"）—— 一次被拒的
            // 导入（超大 / 格式不对 / 时长超限）或一次失败的 manifest 绑定，此前在行上**什么都不显示**：
            // 字节可能已经落进包里成了孤儿，`onImportCompleted()` 照常触发 `refresh()`，行原地闪一下
            // 又回到「未配置」，用户只看到「拖进去没反应」。见 ``importErrorMessage``。
            if let message = importErrorMessage {
                FailureRow(message: message)
            }
        }
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
            // 事件色自己的 15% 淡底 —— DESIGN.md 行结构「事件字形 tile 24pt, **事件色**, 圆角6」。
            // 字形对这块**复合底色**（事件色 @15% 覆在 panel 上）必须过 WCAG 1.4.11 的 ≥3:1。
            // `/ship` 评审实证：旧的亮色 Stop `#2FA24E` / StopFailure `#C87A00` 在这块真实底上
            // 只有 2.75:1 / 2.82:1，**不及格**——而当时 `ContrastSuite` 断的是「字形 vs 纯 panel」，
            // 断错了那一对，所以一直假绿。修法是**调深亮色事件色**（`#288B43` / `#AC6900`，
            // 2026-07-11 授权，DESIGN.md 配色表已同步），而不是把 tile 改成中性色：
            // `surface-2` 亮色 `#FFFDF7` 对 panel `#FFFDF8` 只有 1.0006:1 —— tile 会**整个消失**。
            // 现在字形对真实 tile 底亮色 3.53/3.59/3.32/4.37、tile 对面板 1.20:1（看得见）。
            // 这一对由 `ContrastSuite` 用 `compositedHex(事件色, over: panel, alpha: 0.15)` 钉死。
            .fill(color.opacity(0.15))
            .frame(width: 24, height: 24)
            .overlay(
                Image(systemName: eventGlyphName(row.event))
                    .font(.system(size: 12 * typeScale))
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
                .font(.system(size: 13 * typeScale))
                .foregroundColor(ClaudioColor.text(colorScheme))
            Text(row.event.cliName)
                .font(.system(size: 10 * typeScale, design: .monospaced))
                // DESIGN.md 字体表：数据 / 事件 id = JetBrains Mono，**tabular-nums**。
                .monospacedDigit()
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
                importAffordance(label: "未配置")
            case .broken:
                importAffordance(label: "文件丢失")
            }
            // DESIGN.md line 127 renders 试听 ▶ on EVERY row, just DISABLED on unmapped/broken
            // ("试听 ▶ 禁用" — a present-but-disabled button, not an absent one);
            // `previewButtonBody`'s own `enabled` already folds in `row.coverage.previewEnabled`,
            // so the disabled styling applies automatically. Hence ONE call site, outside the
            // switch.
            //
            // `claimsActionFocus` comes from ``EventRow/previewClaimsActionFocus`` (`ClaudioGUICore`,
            // unit-tested) — NOT from three hand-written `true`/`false` literals inside the switch
            // above, which is what this was (T16 review 修复⑥ sank the decision into a pure
            // function precisely because nothing constrained those literals: flipping one broke no
            // test, while it silently decides whether opening focus lands on a dead preview button
            // or the operable import affordance).
            previewButton(claimsActionFocus: row.previewClaimsActionFocus)
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
                .font(.system(size: 11 * typeScale, design: .monospaced))
                // DESIGN.md 字体表：数据 / 事件 id = JetBrains Mono，**tabular-nums**（等宽数字）。
                .monospacedDigit()
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
                    .font(.system(size: 10 * typeScale))
                    .foregroundColor(ClaudioColor.textSecondary(colorScheme))
                    // Decorative only (a11y-architect FIX 1): `Image(systemName:)` would
                    // otherwise surface an SF-Symbol-derived accessibility label of its own
                    // (e.g. "waveform") as an unlabeled-feeling extra `.contain` stop.
                    .accessibilityHidden(true)
            }
            // 试听 ▶ 由 `trailing` 统一渲染（每行恰好一次，见那里的注释）—— 这里不再各自铺一份。
        }
    }

    /// The 试听 ▶ preview button's styled body, WITHOUT the `.eventAction` focus binding — the
    /// binding is applied conditionally by ``previewButton(claimsActionFocus:)`` so that exactly
    /// one control per row ever owns that focus identity (see there).
    private var previewButtonBody: some View {
        let enabled = row.coverage.previewEnabled && row.enabled
        return Button(action: onPreview) {
            Image(systemName: "speaker.wave.2")
                .font(.system(size: 12 * typeScale))
        }
        .buttonStyle(.plain)
        // ≥24×24 hit target (a11y-architect FIX 6, WCAG 2.5.8) — the 22×22 background circle
        // stays the same VISUAL size below; `minWidth`/`minHeight` only grows the tappable
        // area, glyph point size is untouched.
        .frame(minWidth: 24, minHeight: 24)
        .background(
            Circle()
                // 事件色 15% 自染底 —— 与 ``glyphTile`` 同一块复合底、同一条 ≥3:1 约束，
                // 由调深后的亮色事件色（`#288B43` / `#AC6900`）满足；见 ``glyphTile`` 的注释。
                // DESIGN.md「圆形试听键 speaker.wave.2, 事件色」不变。
                .fill(enabled ? ClaudioColor.event(row.event, colorScheme).opacity(0.15) : Color.clear)
                .frame(width: 22, height: 22)
        )
        // 显式禁用样式（DESIGN.md 硬约束）：图标置灰 + 降饱和，绝不靠整行 opacity 传达禁用。
        .foregroundColor(enabled ? ClaudioColor.event(row.event, colorScheme) : ClaudioColor.textSecondary(colorScheme))
        .saturation(enabled ? 1 : 0)
        .disabled(!enabled)
        .contentShape(Rectangle())
        .accessibilityLabel("试听 \(eventDisplayName(row.event)) 的声音")
    }

    /// The 试听 ▶ preview button. `claimsActionFocus` decides whether THIS control owns the
    /// row's ``PanelFocusTarget/eventAction(_:)`` focus identity:
    ///
    /// - `.present` rows pass `true`: the preview button is the row's SOLE action control, so it
    ///   owns `.eventAction` (`panelFocusOrder(_:)`'s SAME identity, never a second one).
    /// - `.unmapped`/`.broken` rows pass `false`: DESIGN.md line 127 still renders a disabled
    ///   "试听 ▶ 禁用" here, but the row's OPERABLE action is the always-enabled
    ///   ``importAffordance(label:)``, which owns `.eventAction`. This disabled button must NOT
    ///   also bind `.eventAction` — two simultaneously-rendered `.focused(_:equals:)` on one
    ///   value make SwiftUI's focus resolution undefined (a11y-architect FIX 4 dedup), and in
    ///   particular would let ``PanelView/applyFirstFocus()`` land opening focus on this dead
    ///   preview instead of the operable import affordance. One row → exactly one `.eventAction`
    ///   owner, honoring ``PanelFocusTarget/eventAction(_:)``'s "a SINGLE slot per row" contract.
    @ViewBuilder
    private func previewButton(claimsActionFocus: Bool) -> some View {
        if claimsActionFocus {
            previewButtonBody.focused(focusedTarget, equals: .eventAction(row.event))
        } else {
            previewButtonBody
        }
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
                    .font(.system(size: 11 * typeScale))
                    .foregroundColor(ClaudioColor.textSecondary(colorScheme))
                Image(systemName: "square.and.arrow.down")
                    .font(.system(size: 11 * typeScale))
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
        // a11y-architect FIX 4: this is the row's `.eventAction` focus OWNER when coverage is
        // `.unmapped`/`.broken` — the SAME identity `previewButton(claimsActionFocus:)` uses for
        // `.present`. DESIGN.md still renders a disabled "试听 ▶ 禁用" alongside this on
        // unmapped/broken rows, but that button passes `claimsActionFocus: false` so it does NOT
        // also bind `.eventAction`: exactly one operable owner per row, never a disabled one
        // racing this affordance for the same `@FocusState` value (which would make first focus
        // land on the dead preview — the whole reason for the dedup).
        .focused(focusedTarget, equals: .eventAction(row.event))
    }

    /// Opens the shared audio picker (``runAudioOpenPanel(allowsMultipleSelection:)``,
    /// single-select — a row binds to exactly one event), feeding the chosen file into the
    /// SAME hardened import pipeline `.onDrop` already uses. The panel's `allowedContentTypes`
    /// is a picker-UX nicety only, never the actual security boundary — a mislabeled file still
    /// gets content-sniffed and can still be rejected by `importAudioFile`'s real magic-byte
    /// check (``sniffAudioFormat(_:)``) exactly as a drag-and-drop would be, and that rejection
    /// now actually SHOWS on the row (``importErrorMessage``). AppKit — compile-only here,
    /// manual-verify on a real Mac.
    private func openImportPanel() {
        guard let url = runAudioOpenPanel(allowsMultipleSelection: false).first else { return }
        let suggestedFileName = url.lastPathComponent
        Task { @MainActor in
            await importViewModel.handleDrop(sourceURL: url, suggestedFileName: suggestedFileName)
            onImportCompleted()
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
                .font(.system(size: 11 * typeScale))
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
            onImportCompleted()
        }
        return true
    }

    // MARK: - 导入 / 绑定失败的如实上报（绝不静默吞错）

    /// The row's CURRENT import/bind failure, as one human Chinese sentence — or `nil` when the
    /// last attempt (if any) went through cleanly.
    ///
    /// Reads BOTH failure surfaces ``EventRowImportViewModel`` deliberately keeps apart (its own
    /// doc comment: "two different failure surfaces with two different causes, never folded into
    /// one"), and reports whichever one the MOST RECENT attempt actually hit:
    ///
    /// 1. ``AudioImportViewModel/state`` == `.reject` — the import itself was refused (超大 /
    ///    非白名单格式 / 时长超限 / 路径不安全 / 顶替内置包 / 拷贝失败). Checked FIRST because a
    ///    rejected import never reaches the bind step at all, so `bindResult` is left holding
    ///    whatever an EARLIER attempt put there — a stale value that must not outrank the
    ///    rejection the user just triggered.
    /// 2. ``EventRowImportViewModel/bindResult`` == `.failure` — the file WAS copied in, but
    ///    writing it into `manifest.json` failed (manifest 不可读 / 写入失败 / …). This is the
    ///    nastiest case and the reason this whole property exists: the bytes are already on disk
    ///    (an orphan file inside the pack), yet the row would render 「未配置」 forever with no
    ///    explanation anywhere.
    ///
    /// (`.success` on either surface yields `nil` — the row's own ``EventRow/coverage``, freshly
    /// recomputed by `PanelView.refresh()` via `onImportCompleted`, IS the success feedback.)
    private var importErrorMessage: String? {
        if case .reject(let reason) = dropState.state { return reason.message }
        if case .failure(let error) = importViewModel.bindResult { return bindErrorMessage(error) }
        return nil
    }

    // `importErrorRow(_:)` 已删（2026-07-15 冗余审计 · A 类修复）—— 它是 DESIGN.md「拒绝行」的六份
    // 手抄副本之一。它的 doc comment 当时写着「reused **verbatim** from `AudioDropZoneView`'s own
    // `rejectRow(_:)` … because they ARE the same thing」——**那句话是假的**：`rejectRow` 的 ✗ 图标根本
    // 没设字号，文字是 11.5pt 而不是 11pt。两份「同一个东西」在被那句话宣布相同的同时已经漂了。
    // 现在它们真的是同一个东西：都渲染 ``FailureRow``（`PanelRows.swift`）。

    /// One human Chinese sentence per ``ManifestBindError`` case — presentation copy, so it lives
    /// HERE rather than in `ClaudioGUICore` (exactly like ``eventDisplayName(_:)`` below, and
    /// unlike `DropRejectionReason.message`, which `ClaudioGUICore` already owns). Exhaustive, no
    /// `default:` — a new bind-error case fails this file to compile until it, too, gets told to
    /// the user instead of being swallowed.
    private func bindErrorMessage(_ error: ManifestBindError) -> String {
        switch error {
        case .packNotFound(let packID):
            "声音已经存进来了，但「\(packID)」这个包现在找不到，没法把它绑到这个事件上——重开面板再试一次。"
        case .unsafeFileName:
            "这个文件名 Claudio 不敢写进声音包清单，换个正常一点的名字再拖一次。"
        case .fileNotFound(let fileName):
            "「\(fileName)」没能留在声音包里，绑定已中止（清单一个字节都没改），再拖一次试试。"
        case .manifestUnreadable(let reason):
            "这个声音包的 manifest.json 读不动，绑定已中止（没有改坏它）：\(reason)"
        case .writeFailed(let reason):
            "声音存进去了，但写不进声音包清单：\(reason)"
        }
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
