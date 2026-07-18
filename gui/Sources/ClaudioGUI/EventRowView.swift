import AppKit
import ClaudioCore
import ClaudioGUICore
import SwiftUI
import UniformTypeIdentifiers

/// One event row (DESIGN.md "行结构（每事件行）" + "事件行三态" + "行内文件名下拉",
/// ENGINEERING.md T16 D4, PLAN-SOUND-MANAGER.md T2): renders purely off ``EventRow``
/// (`ClaudioGUICore`, computed by ``packCoverage(packID:config:environment:)``) — every
/// state DECISION (present/unmapped/broken, ``CoverageState/previewEnabled``, muted-vs-not)
/// already happened in `ClaudioGUICore` before this view ever renders. This view only lays
/// pixels out and wires the file-name ``Menu`` (``fileNameMenu``, T2) — a single native
/// control ALL THREE coverage states now share (选文件… / 清除绑定 / 在访达中显示; §2.6
/// 排期 keeps 阶段 1's menu to those three items — the pack's existing-audio list needs
/// T11's orphan enumeration, phase 2) — plus the always-present 试听/静音 pair. No
/// hardening/validation logic lives here, all of it is in `ClaudioGUICore`'s
/// `importAudioFile`/`bindEventToManifest`/`clearEventBinding`.
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

    /// Invoked after a menu-driven 「清除绑定」succeeds or fails (T2) — the SAME reason
    /// ``onImportCompleted`` exists: ``EventRowImportViewModel/clearBinding()`` writes
    /// `manifest.json` directly (via ``clearEventBinding(event:packID:environment:)``), but
    /// this row renders off ``row`` (``EventRow``), which only the caller's `refresh()`
    /// recomputes — without this hook a successful clear would leave the row showing its
    /// stale `.present`/`.broken` state until an unrelated action happened to refresh it.
    /// Fires unconditionally (success or failure), mirroring ``onImportCompleted``'s own
    /// "harmless on failure" reasoning: a failed clear just recomputes the unchanged state.
    public let onBindingCleared: () -> Void

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
        onImportCompleted: @escaping () -> Void = {},
        onBindingCleared: @escaping () -> Void = {}
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
        self.onBindingCleared = onBindingCleared
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
        // level swallowed `previewButtonBody`/`muteIndicator`/the file-name control (T2:
        // `fileNameMenu`, née `importAffordance`) — each already its own labeled control —
        // into ONE opaque VoiceOver element, so a VoiceOver/Switch Control user could never
        // reach or activate mute/preview/file-name independently, defeating the focus-order
        // model (``panelFocusOrder(_:)`` names them as THREE separate stops per row since T2).
        // `.contain` groups the row for navigation purposes without merging
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
    /// `.combine` there. Since T2, ``fileNameMenu`` is a REAL, reachable control with its OWN
    /// (deliberately differently-phrased) accessibility label — this node's summary and that
    /// control's label are two separate VoiceOver stops that describe two separate things
    /// ("what this row IS" vs "what activating that control DOES"), not a hidden duplicate of
    /// one string. §2.5 第 7 条's "don't repeat the exact same wording twice" contract is now a
    /// real, string-level unit test (``EventRowAccessibilitySuite``, `ClaudioGUICoreTests`) —
    /// both labels' actual DECISION logic moved to ``eventRowIdentityAccessibilityLabel(eventDisplayName:coverage:enabled:)``
    /// (`ClaudioGUICore`) precisely so a harness that cannot `import` this executableTarget can
    /// still assert on the returned strings themselves. A real-device VoiceOver walkthrough
    /// remains the only residual item (TODOS.md) — this machine has no way to query the live
    /// accessibility tree, only the strings these functions return.
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

    // MARK: - Trailing: fileNameMenu + always-present 试听/静音 pair

    @ViewBuilder
    private var trailing: some View {
        HStack(spacing: 6) {
            fileNameMenu
            // 波形占位（DESIGN.md「招牌母题：波形」）—— 只在 `.present` 画（`.unmapped`/`.broken`
            // 没有已知文件可以画波形），"较大" 及以上 Dynamic Type 档位隐藏（ENGINEERING.md T15 D5:
            // "较大 → 隐波形"）。
            if case .present = row.coverage, !adaptation.hidesWaveform {
                Image(systemName: "waveform")
                    .font(.system(size: 10 * typeScale))
                    .foregroundColor(ClaudioColor.textSecondary(colorScheme))
                    // Decorative only (a11y-architect FIX 1): `Image(systemName:)` would
                    // otherwise surface an SF-Symbol-derived accessibility label of its own
                    // (e.g. "waveform") as an unlabeled-feeling extra `.contain` stop.
                    .accessibilityHidden(true)
            }
            // DESIGN.md line 127 renders 试听 ▶ on EVERY row, just DISABLED on unmapped/broken
            // ("试听 ▶ 禁用" — a present-but-disabled button, not an absent one);
            // `previewButtonBody`'s own `enabled` already folds in `row.coverage.previewEnabled`,
            // so the disabled styling applies automatically.
            //
            // PLAN-SOUND-MANAGER.md §2.5: `.eventAction` is now UNCONDITIONALLY the preview
            // button in all three coverage states (the dedup `EventRow.previewClaimsActionFocus`
            // used to arbitrate between this button and the import affordance no longer applies —
            // that affordance moved into `fileNameMenu`'s own `.eventSound` focus identity, so
            // there is no second control left to race `.eventAction` for). One row → exactly one
            // `.focused(_:equals: .eventAction(_))` binding, always this button.
            previewButtonBody.focused(focusedTarget, equals: .eventAction(row.event))
            muteIndicator
        }
    }

    /// The 试听 ▶ preview button's styled body — always bound to ``PanelFocusTarget/eventAction(_:)``
    /// by ``trailing`` (see there for why the state that used to arbitrate this — the removed
    /// `EventRow.previewClaimsActionFocus` dedup — no longer needs to).
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

    // MARK: - File-name Menu (PLAN-SOUND-MANAGER.md §2.5/T2, DESIGN.md「行内文件名下拉」)

    /// The event row's file-name control: `stop.mp3 ▾` — a single native `Menu` ALL THREE
    /// ``CoverageState``s share. This replaces two things that used to be split across
    /// states: `.present`'s non-interactive filename `Text` (no edit entry at all — 决议②'s
    /// central bug, "一个完整的包在 GUI 里无法替换任何声音") and `.unmapped`/`.broken`'s
    /// drag/pick-only import affordance (``importAffordance(label:)``, now gone). Every row,
    /// in every state, now owns ONE control that can pick a new file, clear the binding, or
    /// (when a file really exists) reveal it in Finder.
    ///
    /// 阶段 1 scope only (PLAN-SOUND-MANAGER.md §2.6 排期): the menu does NOT list the pack's
    /// existing audio files ("包内已有音频，含孤儿") — that needs T11's orphan enumeration,
    /// phase 2. Only 选文件… / 清除绑定 / 在访达中显示, and which of the latter two appear
    /// depends on ``row``'s coverage (see the menu body below).
    ///
    /// Owns ``PanelFocusTarget/eventSound(_:)`` — a NEW, always-operable focus slot
    /// (PLAN-SOUND-MANAGER.md §2.5): picking a file is legal in every coverage state, so
    /// unlike the old `.eventAction` arbitration this control never has to yield its focus
    /// identity to anything else. This is also why an `.unmapped` row's opening focus now
    /// lands HERE rather than on the (still-disabled-until-bound) 试听 ▶ — exactly the
    /// control that can fix the row.
    ///
    /// Reuses ``EventRowImportViewModel/handleDrop(sourceURL:suggestedFileName:)`` /
    /// ``EventRowImportViewModel/clearBinding()`` / ``loadDropRequest(from:)`` — never a
    /// second, independent binding-mutation path. `.onDrop` (drag-to-bind) is preserved
    /// alongside the menu's click-driven 选文件… in every state, a superset of what the old
    /// `unmapped`/`broken`-only import affordance offered.
    private var fileNameMenu: some View {
        Menu {
            Button("选文件…", action: openImportPanel)
            switch row.coverage {
            case .present:
                Button("清除绑定", action: clearBinding)
                Button("在访达中显示", action: revealInFinder)
            case .broken:
                // 声明的文件已经不在磁盘上了 —— 没有什么可「在访达中显示」的。「清除绑定」仍然
                // 有意义：把这一行从「打包错误」（.broken）翻回「刻意静默」（.unmapped，
                // DESIGN.md「清除绑定」条：真打包错误不被伪装成正常静默，反向也成立）。
                Button("清除绑定", action: clearBinding)
            case .unmapped:
                // 本来就没有绑定 —— 「清除绑定」在这里只会是一次幂等的空操作，「在访达中显示」没有
                // 文件可显示。菜单只留「选文件…」，不为不做事的项目占用户的眼睛。
                EmptyView()
            }
        } label: {
            fileNameMenuLabel
        }
        .menuStyle(.borderlessButton)
        // 品牌强调只经 `.tint`（DESIGN.md「行内文件名下拉」："原生外壳，不自绘...品牌强调只经
        // `.tint(clay)`"）—— 菜单本身的系统外壳（焦点环、按下态）一个像素都不重画。
        .tint(ClaudioColor.clay(colorScheme))
        .onDrop(of: [UTType.fileURL], isTargeted: $isHoveringImportTarget, perform: handleDrop)
        .accessibilityLabel(fileNameMenuAccessibilityLabel)
        // a11y-architect FIX 4 的同一条纪律，套在这颗新槽位上：这是 `.eventSound` 唯一的 owner。
        .focused(focusedTarget, equals: .eventSound(row.event))
    }

    /// ``fileNameMenu``'s label content — the visible `stop.mp3 ▾` / `未配置 ▾` / `文件丢失 ▾`
    /// each ``CoverageState`` renders. `.present` stays PLAIN mono text (matches the row's old
    /// non-interactive filename exactly, just now inside a real control); `.unmapped` keeps the
    /// dashed-border pill the old `importAffordance` used (DESIGN.md: "未配置「（虚线边框）"）；
    /// `.broken` reuses the SAME pill shape (this row-level state had no distinct "broken" visual
    /// before T2 either — both `.unmapped`/`.broken` shared `importAffordance`), plus a small
    /// real-red glyph: DESIGN.md's dropdown note asks for "broken 显红名", but coloring the
    /// FILENAME TEXT itself real-red would repeat the exact ≥4.5:1 contrast failure already
    /// caught and fixed for `PackGalleryView`'s `.broken` card (真红 only ever passes the ≥3:1
    /// icon floor, never the ≥4.5:1 text floor) — so, mirroring that fix, 真红 lands on the
    /// icon only, the label text stays `text-2`.
    @ViewBuilder
    private var fileNameMenuLabel: some View {
        switch row.coverage {
        case .present(let fileName):
            HStack(spacing: 3) {
                Text(fileName)
                    .font(.system(size: 11 * typeScale, design: .monospaced))
                    // DESIGN.md 字体表：数据 / 事件 id = JetBrains Mono，**tabular-nums**。
                    .monospacedDigit()
                    // 长文件名截断到一行、留尾（ENGINEERING.md T15 D5）。
                    .lineLimit(1)
                    .truncationMode(.tail)
                chevronGlyph
            }
            .foregroundColor(ClaudioColor.textSecondary(colorScheme))
        case .unmapped:
            pillLabel(text: "未配置")
        case .broken:
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 10 * typeScale))
                    .foregroundColor(ClaudioColor.error(colorScheme))
                pillLabel(text: "文件丢失")
            }
        }
    }

    private var chevronGlyph: some View {
        Image(systemName: "chevron.down")
            .font(.system(size: 8 * typeScale))
    }

    /// The dashed-border pill both `.unmapped` and `.broken` render (identical visual
    /// treatment pre-T2, when both states shared `importAffordance` — T2 only changes the
    /// CONTROL underneath from a plain `Button` to a `Menu`, not this shape).
    private func pillLabel(text: String) -> some View {
        HStack(spacing: 4) {
            Text(text)
                .font(.system(size: 11 * typeScale))
                .foregroundColor(ClaudioColor.textSecondary(colorScheme))
            chevronGlyph
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

    /// `fileNameMenu`'s own accessibility label — a thin call-through to
    /// ``eventRowFileNameMenuAccessibilityLabel(eventDisplayName:coverage:)`` (`ClaudioGUICore`).
    /// The DECISION (what each coverage state's label says, and that it must not
    /// double-announce ``identity``'s summary — §2.5 第 7 条 ①) lives there now, where
    /// ``EventRowAccessibilitySuite`` can actually assert on the returned strings; this view
    /// only supplies the presentation-copy event name, exactly like
    /// ``PanelAnnouncementFacts/header`` supplies its half of a Core-decided sentence.
    private var fileNameMenuAccessibilityLabel: String {
        eventRowFileNameMenuAccessibilityLabel(
            eventDisplayName: eventDisplayName(row.event), coverage: row.coverage)
    }

    /// 「清除绑定」菜单项（present/broken 才渲染，见 ``fileNameMenu``）—— 经由
    /// ``EventRowImportViewModel/clearBinding()`` 落地到 ``clearEventBinding(event:packID:environment:)``
    /// （PLAN-SOUND-MANAGER.md §2.1/T3），从不绕开那条原语自己动手改 manifest。清除是**幂等**且
    /// **绝不删文件**的（该原语自己的文档），所以这里不需要任何确认对话框。
    private func clearBinding() {
        importViewModel.clearBinding()
        onBindingCleared()
    }

    /// 「在访达中显示」菜单项（仅 `.present` 渲染）。解析路径与 ``PanelView/playPreview(for:)``
    /// 同一套谓词（``resolvePackDirectory`` + ``safePackFileURL``），从不新写一条路径解析逻辑 ——
    /// `dropState` 就是 ``EventRowImportViewModel/importViewModel``（同一个 `AudioImportViewModel`
    /// 实例，见其doc comment），`packID`/`environment` 读的是它此刻真正指向的包。
    private func revealInFinder() {
        guard case .present(let fileName) = row.coverage,
            let packDirectory = resolvePackDirectory(
                id: dropState.packID, userPacksDirectory: dropState.environment.userPacksDirectory,
                bundledPacksDirectory: dropState.environment.bundledPacksDirectory),
            let resolvedFile = safePackFileURL(fileName, in: packDirectory)
        else { return }
        NSWorkspace.shared.activateFileViewerSelecting([resolvedFile])
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
        eventRowIdentityAccessibilityLabel(
            eventDisplayName: eventDisplayName(row.event), coverage: row.coverage,
            enabled: row.enabled)
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
