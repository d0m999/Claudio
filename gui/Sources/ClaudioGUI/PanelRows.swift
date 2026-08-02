import ClaudioGUICore
import ClaudioGUIComponents
import SwiftUI

// MARK: - 面板共享组件（2026-07-15 前端设计冗余审计 · A 类修复）
//
// 这个文件的存在理由，是本仓库反复交学费的那条教训的**唯一一种不会腐烂的解法**。
//
// 【它替换掉了什么】
// DESIGN.md 只定义了**一个**「拒绝行」组件（"真红 `circle-x` 字形 + `text-2` 说明"）。而在本文件
// 落地之前，代码里有**五份**各自独立的手抄实现，且三处 doc comment 白纸黑字替它们作伪证：
//
//   · `EventRowView.importErrorRow`  的注释：「reused **verbatim** from `AudioDropZoneView`…」
//   · `ActionFailureRow` 的注释：      「与 `PanelView` 的 `errorNotice` 和 … **完全一致**」
//   · `PanelView.errorNotice` 的注释： 「**identical to** `AudioDropZoneView`'s `rejectRow`…」
//
// **三句话，当时没有一句是真的**：`AudioDropZoneView.rejectRow` 的 ✗ 图标**根本没设字号**（继承默认
// body 字号，比其余四处的 11pt 大一圈），文字是 11.5pt 而不是 11pt。它们在被那三句注释宣布「完全一致」
// 的同时，已经漂移了三处。
//
// 【为什么修法是「抽组件」而不是「补一条断言」】
// 一条 `contains("...")` 式的文本绊线只是把一种脆弱换成另一种 —— `ViewWiringSuite` 自己的 doc comment
// 已经列了它那套机制的四条失效模式，其中两条是**实测**的（第一版 `contains("Bundle.main")` 被一句注释
// 假绿；把「全量 refresh」钉成 `contains("refresh()")`，而 `refresh()` 在那个文件里出现 37 次 ——
// 那个合取子恒真）。
//
// 而一个共享组件是**编译期结构**：五份变一份之后，「这五处一致」不再是一句需要被守的话，也不再需要
// 任何断言去守 —— 它成了一个**无法违反的事实**。这是唯一一种不会腐烂的绊线，所以优先找这一类。
// （TODOS.md「视图层的绊线以散文形式存在」条 · 修法 1）
//
// 【本文件的纪律】
// · 字号一律走 DESIGN.md「字号阶梯」的档位（次要 / 状态 = **11**）。2026-07-15 拍板：drop-zone 那两处
//   11.5pt 收敛到 11pt，图标补 11pt —— 字号阶梯从此零越界。
// · 真红 `error` **只上图标**，文案一律 `text-2`（DESIGN.md 2026-07-11 决议：亮色真红对面板 4.07:1，
//   过图标的 ≥3:1，**不过**正文的 ≥4.5:1）。往这个文件里加任何新的文字，都要先回答它是不是 `text-2`。
// · `@ScaledMetric` 在**每个组件自己**声明，不从调用点当 `CGFloat` 参数传进来 —— 参数传递正是
//   TODOS.md「`typeScale` 是一个被手工穿线的环境值」那条的病灶（`ActionFailureRow` / `ActionNoticeRow`
//   此前就是这么被穿线的，本轮一并拆掉）。

/// DESIGN.md「拒绝行」的**唯一**实现：真红 ✗ 字形 + `text-2` 说明。
///
/// 面板里每一种失败都长得像同一种东西 —— 而这句话现在是**结构事实**，不再是一句注释里的保证：
/// 全部四个失败渲染点（``PanelView`` 的写失败 / config 失败、``EventRowView`` 的导入·绑定失败、
/// ``AudioDropZoneView`` 的拖入拒绝、``ActionFailureRow`` 的 CTA 动作失败）都渲染这一个 `View`。
///
/// **刻意不收编的第五处**：``PackGalleryView`` 里 `PackCardView` 的 trailing-slot 状态行
/// （T4，2026-07-17 竖排整宽行 — `packRowTrailingSlot(for:) == .brokenStatus` 时渲染的那个
/// ✕ + 文案）。它**借用**了拒绝行的视觉语言（同样的 ✗ + `error` 色 + `text-2` 文案），但它不是
/// 一条面板级失败行 —— 它是**竖排整宽行内部、覆盖轨那个定高槽位**（`trailingSlotHeight`）里的一个
/// 状态占位，必须与轨道本身共享**完全相同的高度**（同一份滚动列表里，行不能因为相邻那个包是不是
/// broken 而上下跳）。`FailureRow` 允许多行折行（`fixedSize(horizontal: false, vertical: true)`）
/// + 一颗可选的披露箭头 —— "定高" 与 "允许折行" 是互相冲突的两条约束，硬塞进同一个组件只会让
/// `FailureRow` 长出一个只为这一处服务的定高参数，那不是收敛，是把差异换个地方藏。
/// （它与本组件共享的仍是 **token** 层：`ClaudioColor.error` / `.textSecondary` / 11pt。）
/// （T4 之前这里说的是「84pt 宽卡片、`spacing: 2` 被卡片宽度逼出来」——那份理由随卡片画廊一起
/// 消解了，本条随实现改写，结论没变：仍然不收编，只是理由换成了「定高 vs 允许折行」。）
/// 一条「Claudio 替你做了主」的**告知**行（T17f）—— ``FailureRow`` 的孪生兄弟，不是它的一个变体。
///
/// **名字不能改**：`ViewWiringSuite` 有两条真绊线数着 `PanelView.swift` 里的 `ActionNoticeRow(`
/// 字面量，其中一条是**顺序**断言（告知行必须排在 `PackGalleryView` **之前** —— 因为它的文案白纸黑字
/// 写着「你随时可以在**下面的**声音包里换成别的」）。改名会让那两条绊线静默失效。
///
/// ## 三处与失败行**刻意不同**，每一处都有理由（原样保留自 T17f）
///
/// ① **字形是 ⚠ 而非 ✗，颜色是暖琥珀 `warning` 而非真红 `error`**：setup **成功了**，磁盘上是一个能响
///    的安装。DESIGN.md「错误态用色（关键约束）」把真红**限定**给三种 app 自身错误 —— 把一次成功染成
///    真红就是在对用户撒谎。它也**不能**是中性灰：那正是 CLI 侧那行注释明令禁止的形状（「⚠ 而不是 ·：
///    搬走一个用户目录，是这次 setup 里代价最大的一个『我替你做主』」）。琥珀是唯一同时满足「不是错误」
///    与「不许被忽略」的答案。
/// ② **没有「查看原因」披露**：告知不是错误，没有底层 `Error.description` 可摊开 —— 话本身就是全部内容
///    （包名、新包名、搬到哪儿，全在那一句里）。于是它不长任何可聚焦控件，`panelFocusOrder` 一个字都不用改。
/// ③ **不参与 `isShowingDetail`**：同 ②。
///
/// 与失败行**相同**的那两条（不是巧合，是同一条纪律）：文案一律 `text-2`（琥珀同样只做图标 —— 亮色
/// `#B87000` 过 ≥3:1 的 WCAG 1.4.11，**不过** ≥4.5:1 的 1.4.3），以及 `.combine`。
///
/// 正因为 ①②③ 是三条**真实的**差异，它没有被折进 ``FailureRow`` 当一个 `style:` 参数 —— 那会让一个
/// 「它到底是不是错误」的产品决策退化成调用点的一个枚举值，而这正是 DESIGN.md 花了整整一节去钉死的东西。
struct ActionNoticeRow: View {
    let message: String

    @Environment(\.colorScheme) private var colorScheme
    @ScaledMetric(relativeTo: .body) private var typeScale: CGFloat = 1

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11 * typeScale))
                .foregroundColor(ClaudioColor.warning(colorScheme))
            Text(message)
                .font(.system(size: 11 * typeScale))
                .foregroundColor(ClaudioColor.textSecondary(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(minHeight: 24)
        .accessibilityElement(children: .combine)
    }
}

/// 一次 CTA **动作**失败的渲染：一条 ``FailureRow``，外加一颗可选的「查看原因」披露。
///
/// 有**两个**调用方：`OnboardingView`（接管 / 修复失败）与 `PanelView` 的运行态面板尾部（断开失败 ——
/// 那一刻 onboarding 卡根本不在屏幕上，因为 `.installed` 渲染的是 operational 面板）。所以它不能是
/// 任何一方的私有成员。
struct ActionFailureRow: View {
    let message: String
    let detail: String?
    let isShowingDetail: Bool
    /// 这条失败行自己该不该长出一颗「查看原因」—— 由纯函数
    /// ``onboardingShowsFailureDetailToggle(state:actionState:)`` 决定，**不是视图猜的**。
    /// `false` 的两种情形：没有 detail 可看；或这个 state 的次 CTA 本身就是「查看原因」。
    let showsDetailToggle: Bool
    let onToggleDetail: () -> Void
    let focusedTarget: FocusState<PanelFocusTarget?>.Binding

    @Environment(\.colorScheme) private var colorScheme
    @ScaledMetric(relativeTo: .body) private var typeScale: CGFloat = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if showsDetailToggle {
                // 整条行就是那颗按钮 —— 一个控件、一个焦点身份。键盘 / VoiceOver 用户能够到它
                // （WCAG 2.1.1：一条本该键盘可完成的操作，不能退化成仅指针可用）。
                Button(action: onToggleDetail) {
                    FailureRow(
                        message: message,
                        disclosure: isShowingDetail ? .expanded : .collapsed)
                    // ≥24×24 命中区（a11y-architect FIX 6）—— 只有可点的那一态需要它。不可点的失败行
                    // （另外三个调用点）是纯文本，给它撑一个 24pt 命中区没有任何意义，只会白占垂直空间。
                    .frame(minHeight: 24)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(message)
                .accessibilityHint(isShowingDetail ? "收起原因" : "展开原因")
                .focused(focusedTarget, equals: .revealDetail)
            } else {
                FailureRow(message: message)
            }

            if isShowingDetail, let detail {
                Text(detail)
                    .font(.system(size: 11 * typeScale, design: .monospaced))
                    .monospacedDigit()
                    // `text-2`，**不是**真红：真红当正文亮色下只有 4.07:1，达不到 WCAG ≥4.5:1。
                    .foregroundColor(ClaudioColor.textSecondary(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// 面板顶部的「Claudio」标题行 —— **唯一**实现。
///
/// 【它替换掉了什么】此前 `PanelView.header` 与 `OnboardingView.header` 是两份几乎逐字相同的副本
/// （`HStack(spacing: 6)` + 15pt semibold 标题 + 8×8 `success` 绿点 + `Spacer`）。而两份副本对**同一颗
/// 绿点**的无障碍处理正好**相反**：
///
///   · `PanelView` 那份：`.accessibilityHidden(true)`（对的 —— header 整体已有一句 combine label）
///   · `OnboardingView` 那份：`.accessibilityLabel("已接管 Claude Code")`
///
/// 而后者**从来没有被任何人听到过**：绿点的条件是 ``OnboardingState/showsHeaderTakenOverDot``
/// （`== .installed`），而 `OnboardingView` **只在 `state != .installed` 时才上屏**（见
/// `PanelView.body` 的分支）。那颗绿点连同那句 label，在 shipping app 里一个像素都没有渲染过。
///
/// 【那个恒假的 `if` 现在怎么样了 —— 一处诚实的更正】
/// 审计当时写的是「抽成共享组件会自动暴露并消灭那个恒假的 `if`」。**那句话不准确，这里更正**：抽完
/// 之后 `if showsTakenOverDot` 仍然在（就在下面），而且**它就该在** —— `OnboardingView` 传进来的值恒为
/// `false` 并不是 bug，那是**正确的**恒假（onboarding 卡按定义就是「还没接管」）。`StateGalleryView`
/// 里那一帧 `.installed × OnboardingView` 仍会把绿点画出来，这也是对的：它展示的就是「这张卡在这个
/// state 下长什么样」，哪怕 app 里走不到那一帧（那是 TODOS.md 另一条的题目）。
///
/// **所以这次抽取真正消灭的东西是**：两份实现可能各自漂移（它们已经在 a11y 上漂了），以及那句永远
/// 听不到的 label。绿点的渲染判据从此只有一处 —— 它不可能再同时是 hidden 和有 label 的。
struct PanelHeader: View {
    /// 「已接管」的绿点。真相源是 ``OnboardingState/showsHeaderTakenOverDot``（`OnboardingStateSuite`
    /// 钉着它），两个调用点都读那个 property，**不写字面量 `true` / `false`** —— 把一个恒定值硬编在
    /// 调用点，等于把「为什么它恒定」这件事从代码里删掉。
    let showsTakenOverDot: Bool

    /// VoiceOver 落在这条 header 上时读的整句话。`.installed` 时是「Claudio 面板，当前声音包 X」
    /// （包名来自 `PanelConfigController.selectedPackMetadata`，独立于 packCards 显示集）；
    /// 其余状态或没有当前包名时一律是 ``baseLabel``。
    let accessibilityLabel: String

    /// 非 `.installed` 时那句 header —— 面板还没接管，没有「当前声音包」可报。
    /// 一个常量而不是两处字面量：`PanelView.headerAccessibilityLabel` 的 guard 分支与
    /// `OnboardingView` 的 header 读的是**同一个**它。
    static let baseLabel = "claudi0 面板"

    @Environment(\.colorScheme) private var colorScheme
    @ScaledMetric(relativeTo: .body) private var typeScale: CGFloat = 1

    var body: some View {
        HStack(spacing: 6) {
            Text("claudi0")
                // DESIGN.md 字号阶梯：面板标题 = SF Pro semibold 14–15。
                .font(.system(size: 15 * typeScale, weight: .semibold))
                .foregroundColor(ClaudioColor.text(colorScheme))
            if showsTakenOverDot {
                Circle()
                    .fill(ClaudioColor.success(colorScheme))
                    .frame(width: 8, height: 8)
                    // 绿点本身对 VoiceOver 无声 —— 它说的话已经折进整条 header 的 combine label 里了
                    // （见 `accessibilityLabel`）。给它单独配一句 label，只会多出一个冗余的光标停靠点。
                    .accessibilityHidden(true)
            }
            Spacer()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }
}
