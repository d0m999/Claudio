import ClaudioCore
import ClaudioGUICore
import SwiftUI

/// The pack switching gallery (ENGINEERING.md T15 D3; DESIGN.md「声音包行 Pack Row」/「包行四态」:
/// 2026-07-17 用户拍板全盘采纳竖排 mockup —— 横向 84pt 卡片画廊 → **竖排整宽行**
/// `[包名][meta 槽]……[覆盖轨]`). Renders purely off ``PackCard`` (`ClaudioGUICore`,
/// ``availablePacks(config:environment:)``) — every state DECISION (complete/partial/broken,
/// which events are present, selection, and now which of the two trailing-slot shapes a row
/// gets — ``packRowTrailingSlot(for:)``) already happened before this view ever renders;
/// switching itself reuses
/// ``selectPack(_:configFile:userPacksDirectory:bundledPacksDirectory:lockFile:)`` via
/// `onSelect`, never a second write path.
///
/// 阶段 1（PLAN-SOUND-MANAGER.md §2.6 排期硬约束）: renders EVERY card, unfiltered — the ≤4
/// starred-only filter is T17, gated on the management window landing first (starring becomes
/// the only way back once filtering activates, so filtering can't ship before it). Still
/// scrollable (now vertically, was horizontally): the panel's `NSPopover` has a fixed
/// `contentSize` (`MenuBarController.swift`), so this view's `ScrollView` simply absorbs
/// whatever vertical space the fixed-height siblings around it (event rows, notices,
/// disconnect row) leave over, and scrolls internally rather than growing the popover.
///
/// COMPILE-ONLY here (CommandLineTools, no Xcode/simulator/`#Preview`): visual layout is
/// manual-verify on a real Mac. The one piece of this file's behavior that IS unit-tested is
/// ``packRowTrailingSlot(for:)`` (`ClaudioGUICore`, ``PackGallerySuite``) — this view only
/// switches on that already-decided value, it makes no state decisions of its own.
public struct PackGalleryView: View {
    public let cards: [PackCard]
    public let onSelect: (PackCard) -> Void

    /// The SHARED focus-state binding every row reports into (a11y-architect FIX 4):
    /// `PanelView` owns the actual `@FocusState` and passes its projected binding down here
    /// — mirrors ``EventRowView``'s own `focusedTarget` parameter exactly. Required (no
    /// default) since `PanelView` is this view's only real call site.
    private let focusedTarget: FocusState<PanelFocusTarget?>.Binding

    /// The Dynamic Type degradation these rows currently render under (ENGINEERING.md T15 D5
    /// 「无障碍规格 · Dynamic Type + 降级规则」) — mirrors ``EventRowView``/``MasterVolumeRow``'s
    /// own `adaptation` parameter exactly (/codex review 6c40fbc P1: this rewrite had wired
    /// EVERY other row to `PanelView`'s `layoutAdaptation` except this gallery, so pack rows
    /// alone never wrapped to two lines at `.largest`/`.maximum`, squeezing/truncating the
    /// pack name against the trailing slot). Defaults to ``PanelTypeSizeTier/standard`` so
    /// every existing call site (`StateGalleryView`'s single-card preview, `PackGallerySuite`)
    /// keeps today's single-line layout unless a caller explicitly opts into a larger tier.
    private let adaptation: PanelLayoutAdaptation

    public init(
        cards: [PackCard],
        focusedTarget: FocusState<PanelFocusTarget?>.Binding,
        adaptation: PanelLayoutAdaptation = panelLayoutAdaptation(for: .standard),
        onSelect: @escaping (PackCard) -> Void = { _ in }
    ) {
        self.cards = cards
        self.focusedTarget = focusedTarget
        self.adaptation = adaptation
        self.onSelect = onSelect
    }

    public var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 8) {
                ForEach(cards, id: \.id) { card in
                    PackCardView(
                        card: card, focusedTarget: focusedTarget, adaptation: adaptation,
                        onSelect: { onSelect(card) })
                }
            }
            .padding(.vertical, 2)
        }
        // `.contain`, not `.combine`: unlike `EventRowView`'s single-announcement row
        // (ENGINEERING.md「无障碍规格」spells out one combined string per row), the gallery's
        // whole point is per-ROW navigation/selection — VoiceOver must be able to move
        // between rows individually, not hear the entire gallery as one blob.
        .accessibilityElement(children: .contain)
    }
}

/// One pack row (2026-07-17 竖排整宽行 mockup 拍板; DESIGN.md「包行四态」). Anatomy at
/// ``PanelTypeSizeTier/standard``/``PanelTypeSizeTier/larger``:
/// `[包名][meta 槽] Spacer [覆盖轨 / broken 状态行]`（一行）；从 ``PanelTypeSizeTier/largest``
/// 起（`adaptation.rowWrapsToTwoLines`）改两行：`[包名][meta 槽]` 上、`[覆盖轨 / broken 状态行]`
/// 下 —— 与 ``EventRowView``同一条降级规则 (ENGINEERING.md「无障碍规格 · Dynamic Type + 降级规则」)。
/// DESIGN.md now defines the selected/broken/partial visual language (「包行四态」); where a
/// pixel choice still isn't pinned there — the mockup itself omits meta labels entirely, a
/// documented OMISSION not a reversal (DESIGN.md's own "省略不是推翻" note) — every derivation
/// below is called out inline.
///
/// The name stays `PackCardView` (private to this file, never referenced by symbol name from
/// any test) even though it now renders a row, not a card — PLAN-SOUND-MANAGER.md T4's explicit
/// instruction is to keep ``PackCard``/``PanelFocusTarget/packCard(id:)`` unchanged (renaming
/// either touches `PanelFocusOrder.swift` + every test that names it, for zero behavior change);
/// renaming this PRIVATE view type isn't forbidden by that instruction, but doing so for no
/// reason beyond cosmetics isn't worth touching unrelated files' doc comments that name it.
private struct PackCardView: View {
    let card: PackCard
    let focusedTarget: FocusState<PanelFocusTarget?>.Binding
    /// See ``PackGalleryView``'s own `adaptation` doc comment — this is that same value,
    /// threaded straight through, never re-derived here.
    let adaptation: PanelLayoutAdaptation
    let onSelect: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    /// Dynamic-Type scale factor for this row's fixed `.system(size:)` text (a11y fix) — see
    /// ``EventRowView``'s `typeScale` for the full rationale.
    @ScaledMetric(relativeTo: .body) private var typeScale: CGFloat = 1

    /// The 覆盖轨/broken 状态行 shared reserved height (T4, the Codex-catch half of the fix):
    /// ``packRowTrailingSlot(for:)`` decides WHICH of the two renders, but both must share this
    /// ONE height, or a row visibly grows/shrinks depending on whether the pack next to it is
    /// broken — exactly the "布局不跳" the T4 acceptance criterion names. Sized to fit the
    /// TALLER of the two contents (the ✕ + "文件丢失" status row, ~11pt glyph/text) rather than
    /// the track's own 10pt, so the track ends up vertically centered inside a slightly taller
    /// box instead of the status row ever needing to shrink.
    private var trailingSlotHeight: CGFloat { 16 * typeScale }

    var body: some View {
        Button(action: onSelect) {
            Group {
                if adaptation.rowWrapsToTwoLines {
                    // "更大" 及以上 tier：包名/meta 上、trailing slot 下 —— 与 ``EventRowView``
                    // 同一条两行降级 (ENGINEERING.md「无障碍规格 · Dynamic Type + 降级规则」)；否则
                    // 最大字号下覆盖轨/broken 状态行会先把包名挤裁切或溢出，违背"不裁切、不溢出"。
                    VStack(alignment: .leading, spacing: 4) {
                        nameAndMeta
                        trailingSlot
                            .frame(height: trailingSlotHeight, alignment: .center)
                    }
                } else {
                    HStack(spacing: 8) {
                        nameAndMeta
                        trailingSlot
                            .frame(height: trailingSlotHeight, alignment: .center)
                    }
                }
            }
            .frame(minHeight: adaptation.rowWrapsToTwoLines ? 44 : 28)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                // ⚠️ DESIGN.md 未定义 pack 行背景的确切 token（「现行视觉皮肤：糖果盘」把它改成白色
                // `surface` + radius 13，但方向 D 尚未落地到任何一处 SwiftUI 代码——TODOS.md「方向
                // D 全量采纳的落地债」——所以这里跟随代码库现状，沿用 v1 的既有 `surface-2` + radius
                // 10，不单独抢跑糖果盘皮肤）。
                RoundedRectangle(cornerRadius: 10)
                    .fill(ClaudioColor.surface2(colorScheme))
            )
            .overlay(
                // ⚠️ DESIGN.md 未定义 selected 视觉 — 用既有 `clay`（品牌强调，语义固定为
                // "选中/该你了"）描边环表达选中，非选中态回落到既有 `hairline-strong`。
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(
                        card.isSelected ? ClaudioColor.clay(colorScheme) : ClaudioColor.hairlineStrong(colorScheme),
                        lineWidth: card.isSelected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(card.isSelected ? [.isButton, .isSelected] : .isButton)
        // a11y-architect FIX 4: this row's `.packCard(id:)` slot — `panelFocusOrder(_:)`'s
        // SAME identity, never a second one.
        .focused(focusedTarget, equals: .packCard(id: card.id))
    }

    /// 包名 + meta 槽 + `Spacer` 这一簇 —— 单行/两行两种布局（``body`` 的 `Group`）都直接引用
    /// 这同一份内容，从不各自重复抄写一遍（mirrors ``EventRowView``'s own `identity`/`glyphTile`
    /// extraction: 每个「行的一段」只有一份定义，两种布局只是重新摆放同样的几个子视图）。
    private var nameAndMeta: some View {
        HStack(spacing: 8) {
            Text(card.name ?? card.id)
                .font(.system(size: 13 * typeScale))
                .foregroundColor(ClaudioColor.text(colorScheme))
                .lineLimit(1)
                .truncationMode(.tail)
            metaSlot
            Spacer(minLength: 8)
        }
    }

    /// DESIGN.md「包行四态」meta 槽 content — `complete`/`partial` only (T5 will later split
    /// this ONE slot into a license sub-slot + a completeness sub-slot; T4 keeps it a single
    /// undivided slot, so a CC0 `.partial` pack still loses its CC0 badge here exactly like the
    /// pre-T4 card did — a known, already-scheduled-for-T5 gap, not a T4 regression).
    ///
    /// `.broken` renders nothing here (`EmptyView`): its ONE visible indicator lives in
    /// ``trailingSlot`` instead (see that property's doc comment for why — the T4 PLAN task's
    /// literal wording, "以状态行替代轨", places the broken indicator AT the track's position,
    /// not the meta slot's; showing "✕ 文件丢失" in BOTH places would just be the same badge
    /// twice in one row).
    @ViewBuilder
    private var metaSlot: some View {
        switch card.state {
        case .complete:
            if card.isCC0 {
                Text("CC0")
                    .font(.system(size: 10 * typeScale, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundColor(ClaudioColor.textSecondary(colorScheme))
            }
        case .partial(let present, let total):
            // DESIGN.md「包行四态」: meta 槽 = `⚠`（`warning` 图标）+ `缺 N 个`（**`text-2`，不是
            // 琥珀**）—— 与 `ActionNoticeRow` 同一个图标/配色契约（琥珀只做图标，文案走 text-2）。
            HStack(spacing: 3) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10 * typeScale))
                    .foregroundColor(ClaudioColor.warning(colorScheme))
                Text("缺 \(total - present) 个")
                    .font(.system(size: 11 * typeScale))
                    .foregroundColor(ClaudioColor.textSecondary(colorScheme))
            }
        case .broken:
            EmptyView()
        }
    }

    /// The row's trailing position: the real 4-slot ``CoverageTrack`` for a manifest-readable
    /// row, or a height-matched status row for `.broken` — ``packRowTrailingSlot(for:)``
    /// (`ClaudioGUICore`, unit-tested by ``PackGallerySuite``) is the ONLY thing deciding which;
    /// this view merely switches on that already-made decision, never re-derives it from
    /// `card.state` itself.
    @ViewBuilder
    private var trailingSlot: some View {
        switch packRowTrailingSlot(for: card.state) {
        case .track:
            CoverageTrack(presentEvents: card.presentEvents)
        case .brokenStatus:
            brokenStatusRow
        }
    }

    /// The `.broken` row's ONE status indicator (see ``metaSlot``'s doc comment for why it isn't
    /// duplicated there too) — borrows 拒绝行's visual language (✗ + `error` 色 + `text-2`
    /// 文案) exactly like the pre-T4 84pt card's `.broken` branch did, still deliberately NOT
    /// folded into ``FailureRow`` (see that type's own doc comment, updated for T4's shape: this
    /// is a fixed-height inline slot inside a full-width row's Button, not a standalone
    /// multi-line-capable panel alert).
    private var brokenStatusRow: some View {
        HStack(spacing: 4) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 11 * typeScale))
                .foregroundColor(ClaudioColor.error(colorScheme))
            Text("文件丢失")
                .font(.system(size: 11 * typeScale))
                .foregroundColor(ClaudioColor.textSecondary(colorScheme))
        }
    }

    /// DESIGN.md「无障碍规格」defines a "切包 pill" label template ("当前声音包 {包名}，点按
    /// 切换") for a single current-pack summary control; the actual switching UI is this
    /// per-row list instead (no separate pill), so the template is adapted per-row: the
    /// SELECTED row reads as "当前声音包"（a readout, no need to say "点按切换" — you're
    /// already looking at it), every other row reads as "…，点按切换" (an actionable
    /// switch target), each with its completeness state appended.
    private var accessibilityLabel: String {
        let name = card.name ?? card.id
        let stateSuffix: String
        switch card.state {
        case .complete: stateSuffix = ""
        case .partial(let present, let total): stateSuffix = "，\(present)/\(total) 可用，缺少：\(missingEventNames)"
        case .broken: stateSuffix = "，文件丢失"
        }
        return card.isSelected
            ? "当前声音包 \(name)\(stateSuffix)"
            : "声音包 \(name)，点按切换\(stateSuffix)"
    }

    /// Chinese display names (``eventDisplayName(_:)``, `EventRowView.swift`) of every
    /// ``Event`` NOT in ``PackCard/presentEvents``, in ``Event/allCases`` order — a11y-
    /// architect FIX 7 (LOW): "N/4 可用" alone told VoiceOver a COUNT but never WHICH of
    /// the four events that count refers to. Only ever read from the `.partial` branch of
    /// ``accessibilityLabel`` above.
    private var missingEventNames: String {
        Event.allCases
            .filter { !card.presentEvents.contains($0) }
            .map(eventDisplayName)
            .joined(separator: "、")
    }
}

/// The 4-slot coverage track (DESIGN.md「4-slot 覆盖轨」): ``Event/allCases``' fixed order, one
/// slot each. `present` = 事件色实心胶囊；`missing` = 空槽描边 + 斜杠— **必须是另一种形状**, not
/// the same glyph dimmed (DESIGN.md's own words: "必须是另一种形状，不能是「同一个图标调灰」" —
/// the exact failure mode the pre-2026-07-15 2×2 event grid died of). Only ever constructed for
/// ``PackRowTrailingSlot/track`` (``PackCardView/trailingSlot``) — a `.broken` row never
/// reaches this view at all, matching "画不出没读出来的覆盖度" (DESIGN.md「包行四态」).
///
/// 双编码（DESIGN.md「4-slot 覆盖轨」）：轨道本身只答「缺的是哪一个」，`.accessibilityHidden(true)`
/// — 「缺了几个」和「具体缺哪几个」由行的 `accessibilityLabel`（``PackCardView``）统一读出,
/// exactly like the pre-T4 2×2 grid's own per-glyph hiding.
private struct CoverageTrack: View {
    let presentEvents: Set<Event>
    @Environment(\.colorScheme) private var colorScheme
    @ScaledMetric(relativeTo: .body) private var typeScale: CGFloat = 1

    /// v1 几何（DESIGN.md「4-slot 覆盖轨」"面板行档 ≈ 18×10pt...间距 4pt"）— the candy-skin
    /// mockup's 14×7 geometry is a DESIGN value that hasn't landed in any SwiftUI code yet
    /// (TODOS.md「方向 D 全量采纳的落地债」: `ContrastSuite` is still pinned to the v1 surface).
    /// This component follows the rest of the codebase and stays on v1 numbers rather than
    /// jumping the queue on its own.
    private var slotSize: CGSize { CGSize(width: 18 * typeScale, height: 10 * typeScale) }

    var body: some View {
        HStack(spacing: 4 * typeScale) {
            ForEach(Event.allCases, id: \.self) { event in
                slot(isPresent: presentEvents.contains(event), color: ClaudioColor.event(event, colorScheme))
            }
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func slot(isPresent: Bool, color: Color) -> some View {
        if isPresent {
            RoundedRectangle(cornerRadius: slotSize.height / 2)
                .fill(color)
                .frame(width: slotSize.width, height: slotSize.height)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: slotSize.height / 2)
                    .strokeBorder(ClaudioColor.textSecondary(colorScheme), lineWidth: 1)
                CoverageTrackSlash()
                    .stroke(ClaudioColor.textSecondary(colorScheme), lineWidth: 1)
            }
            .frame(width: slotSize.width, height: slotSize.height)
        }
    }
}

/// The diagonal line inside a `missing` coverage-track slot — a distinct SHAPE from the
/// `present` slot's solid fill, never a color/opacity variation of the same shape (DESIGN.md's
/// explicit rule, see ``CoverageTrack``'s doc comment).
private struct CoverageTrackSlash: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + 2, y: rect.maxY - 2))
        path.addLine(to: CGPoint(x: rect.maxX - 2, y: rect.minY + 2))
        return path
    }
}
