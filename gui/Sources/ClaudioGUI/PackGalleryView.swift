import ClaudioCore
import ClaudioGUICore
import SwiftUI

/// The pack switching gallery (ENGINEERING.md T15 D3; DESIGN.md「声音包卡片 Pack Card」:
/// "2×2 四事件字形网格 + 等宽包名（+ CC0 标）；切包用卡片画廊（像 macOS 壁纸选择器）"). Renders
/// purely off ``PackCard`` (`ClaudioGUICore`, ``availablePacks(config:environment:)``) — every
/// state DECISION (complete/partial/broken, which events are present, selection) already
/// happened before this view ever renders; switching itself reuses
/// ``selectPack(_:configFile:userPacksDirectory:bundledPacksDirectory:lockFile:)`` via
/// `onSelect`, never a second write path.
///
/// COMPILE-ONLY here (CommandLineTools, no Xcode/simulator/`#Preview`): visual layout is
/// manual-verify on a real Mac.
public struct PackGalleryView: View {
    public let cards: [PackCard]
    public let onSelect: (PackCard) -> Void

    /// The SHARED focus-state binding every card reports into (a11y-architect FIX 4):
    /// `PanelView` owns the actual `@FocusState` and passes its projected binding down here
    /// — mirrors ``EventRowView``'s own `focusedTarget` parameter exactly. Required (no
    /// default) since `PanelView` is this view's only real call site.
    private let focusedTarget: FocusState<PanelFocusTarget?>.Binding

    public init(
        cards: [PackCard],
        focusedTarget: FocusState<PanelFocusTarget?>.Binding,
        onSelect: @escaping (PackCard) -> Void = { _ in }
    ) {
        self.cards = cards
        self.focusedTarget = focusedTarget
        self.onSelect = onSelect
    }

    public var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(cards, id: \.id) { card in
                    PackCardView(card: card, focusedTarget: focusedTarget, onSelect: { onSelect(card) })
                }
            }
            .padding(.vertical, 2)
        }
        // `.contain`, not `.combine`: unlike `EventRowView`'s single-announcement row
        // (ENGINEERING.md「无障碍规格」spells out one combined string per row), the gallery's
        // whole point is per-CARD navigation/selection — VoiceOver must be able to move
        // between cards individually, not hear the entire gallery as one blob.
        .accessibilityElement(children: .contain)
    }
}

/// One pack card. DESIGN.md defines the 2×2 event grid + mono name + CC0 badge; it does
/// **not** define selected/broken/partial visuals (T15's own ⚠️ design-gap note, per the
/// orchestrator's instructions) — every derivation below is called out inline, reuses
/// EXISTING tokens only, and does not invent a new color.
private struct PackCardView: View {
    let card: PackCard
    let focusedTarget: FocusState<PanelFocusTarget?>.Binding
    let onSelect: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    /// Dynamic-Type scale factor for this card's fixed `.system(size:)` text (a11y fix) — see
    /// ``EventRowView``'s `typeScale` for the full rationale (fixed sizes don't scale on their
    /// own, so the panel's Dynamic-Type layout adaptation fired with no actual text growth).
    @ScaledMetric(relativeTo: .body) private var typeScale: CGFloat = 1

    /// The 2×2 grid's column widths — an INSTANCE property scaled by `typeScale`, not the `static
    /// let` of fixed 20pt columns this was (`/ship` 评审 · Dynamic Type): the glyphs inside grow
    /// with `12 * typeScale` (~28pt at the largest accessibility size), so fixed 20pt columns —
    /// and the fixed 84pt card below — would CLIP them, which is exactly the 「不裁切、不溢出」
    /// T15 D5's degradation rules exist to prevent. The gallery scrolls horizontally, so a wider
    /// card costs scroll distance, never truncation.
    private var gridColumns: [GridItem] {
        [GridItem(.fixed(20 * typeScale)), GridItem(.fixed(20 * typeScale))]
    }

    var body: some View {
        Button(action: onSelect) {
            VStack(spacing: 6) {
                eventGrid
                Text(card.name ?? card.id)
                    .font(.system(size: 10 * typeScale, design: .monospaced))
                    // DESIGN.md 字体表：数据 = JetBrains Mono，**tabular-nums**（包名常带版本号/数字，
                    // 非等宽数字会让相邻卡片的宽度互相抖动）。
                    .monospacedDigit()
                    .foregroundColor(ClaudioColor.text(colorScheme))
                    .lineLimit(1)
                    .truncationMode(.tail)
                statusLine
            }
            .padding(8)
            .frame(width: 84 * typeScale)
            .background(
                // ⚠️ DESIGN.md 未定义 pack 卡背景 — 用既有 `surface-2`（「抬升」表面语义）
                // 派生，贴近 macOS 壁纸选择器的卡片底色，不新造颜色。
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
        // a11y-architect FIX 4: this card's `.packCard(id:)` slot — `panelFocusOrder(_:)`'s
        // SAME identity, never a second one.
        .focused(focusedTarget, equals: .packCard(id: card.id))
    }

    /// The 2×2 event glyph grid — present events in their event color (reused verbatim from
    /// `EventRowView`'s ``ClaudioColor/event(_:_:)``/``eventGlyphName(_:)``, never a second
    /// color/glyph mapping), missing events greyed via `textSecondary` + reduced opacity.
    /// Distinguished by GLYPH SHAPE too, not color alone (ENGINEERING.md「无障碍规格」"不靠
    /// 颜色单独区分") — the four SF Symbols already differ in shape regardless of tint.
    private var eventGrid: some View {
        LazyVGrid(columns: gridColumns, spacing: 4) {
            ForEach(Event.allCases, id: \.self) { event in
                let isPresent = card.presentEvents.contains(event)
                Image(systemName: eventGlyphName(event))
                    .font(.system(size: 12 * typeScale))
                    .foregroundColor(
                        isPresent
                            ? ClaudioColor.event(event, colorScheme) : ClaudioColor.textSecondary(colorScheme)
                    )
                    // 显式禁用样式的镜像应用（DESIGN.md 硬约束原文用于事件行禁用控件）：置灰 +
                    // 降饱和/不透明度传达"缺失"，而不是给整张卡片降 opacity。
                    .saturation(isPresent ? 1 : 0)
                    .opacity(isPresent ? 1 : 0.4)
                    .accessibilityHidden(true)  // summarized by the card's own accessibilityLabel below.
            }
        }
    }

    // 字号阶梯（DESIGN.md「字号阶梯」）：此前这三行都用 9pt，低于阶梯的最小档。
    // CC0 与 N/4 是**数据** → JetBrains Mono 10–12（取 10）；「文件丢失」是**状态** → SF Pro 11。
    @ViewBuilder
    private var statusLine: some View {
        switch card.state {
        case .complete:
            if card.isCC0 {
                Text("CC0")
                    .font(.system(size: 10 * typeScale, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundColor(ClaudioColor.textSecondary(colorScheme))
            }
        case .partial(let present, let total):
            // ⚠️ DESIGN.md 未定义 partial(部分可用) 视觉 — 用既有 `text-2` 呈现 "N/4"
            // 计数（既有 token，无新色），按 T15 D3 指令的推荐做法。
            Text("\(present)/\(total)")
                .font(.system(size: 10 * typeScale, design: .monospaced))
                // tabular-nums（DESIGN.md 字体表要求）：没有它，"1/4" 与 "3/4" 的字宽不同，
                // 相邻卡片之间的计数会左右抖动。
                .monospacedDigit()
                .foregroundColor(ClaudioColor.textSecondary(colorScheme))
        case .broken:
            // ⚠️ DESIGN.md 未定义 broken(损坏) 卡片视觉 — 借用「拒绝行」既有的视觉语言（DESIGN.md
            // 「拒绝行」原文："真红 `circle-x` 字形 + `text-2` 说明"），是 DESIGN.md 里唯一已定义的
            // "文件缺失/错误"语言，不新造态色。
            //
            // 真红**只**上图标（非文本，门槛 ≥3:1，实测 4.06 通过），文案走 `text-2`（5.54:1，过
            // ≥4.5:1）—— 此前整个 HStack 都染真红，把 4.07:1 的真红当正文用，不达标（`/ship` 评审
            // 实证）。DESIGN.md 的「拒绝行」本来就是这么写的：真红给字形，`text-2` 给说明。
            HStack(spacing: 2) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 11 * typeScale))
                    .foregroundColor(ClaudioColor.error(colorScheme))
                Text("文件丢失")
                    .font(.system(size: 11 * typeScale))
                    .foregroundColor(ClaudioColor.textSecondary(colorScheme))
            }
        }
    }

    /// DESIGN.md「无障碍规格」defines a "切包 pill" label template ("当前声音包 {包名}，点按
    /// 切换") for a single current-pack summary control; T15's actual switching UI is this
    /// per-card gallery instead (no separate pill), so the template is adapted per-card: the
    /// SELECTED card reads as "当前声音包"（a readout, no need to say "点按切换" — you're
    /// already looking at it), every other card reads as "…，点按切换" (an actionable
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
