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

    private static let gridColumns = [GridItem(.fixed(20)), GridItem(.fixed(20))]

    var body: some View {
        Button(action: onSelect) {
            VStack(spacing: 6) {
                eventGrid
                Text(card.name ?? card.id)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(ClaudioColor.text(colorScheme))
                    .lineLimit(1)
                    .truncationMode(.tail)
                statusLine
            }
            .padding(8)
            .frame(width: 84)
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
        LazyVGrid(columns: Self.gridColumns, spacing: 4) {
            ForEach(Event.allCases, id: \.self) { event in
                let isPresent = card.presentEvents.contains(event)
                Image(systemName: eventGlyphName(event))
                    .font(.system(size: 12))
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

    @ViewBuilder
    private var statusLine: some View {
        switch card.state {
        case .complete:
            if card.isCC0 {
                Text("CC0")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundColor(ClaudioColor.textSecondary(colorScheme))
            }
        case .partial(let present, let total):
            // ⚠️ DESIGN.md 未定义 partial(部分可用) 视觉 — 用既有 `text-2` 呈现 "N/4"
            // 计数（既有 token，无新色），按 T15 D3 指令的推荐做法。
            Text("\(present)/\(total)")
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(ClaudioColor.textSecondary(colorScheme))
        case .broken:
            // ⚠️ DESIGN.md 未定义 broken(损坏) 卡片视觉 — 借用「拒绝行」既有的 error 语义色
            // + `xmark.circle.fill` 字形（DESIGN.md「拒绝行」："真红 circle-x 字形"），是
            // DESIGN.md 里唯一已定义的"文件缺失/错误"视觉语言，不新造态色。
            HStack(spacing: 2) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 9))
                Text("文件丢失")
                    .font(.system(size: 9))
            }
            .foregroundColor(ClaudioColor.error(colorScheme))
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
