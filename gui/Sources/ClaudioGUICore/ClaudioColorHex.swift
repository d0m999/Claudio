import Foundation

// MARK: - DESIGN.md「配色」表的单一真相源（hex 字面量在整个 gui/ 里只出现这一次）
//
// 为什么这个文件存在（/ship 评审「结构性无效断言」修复①）：
// 在这之前，DESIGN.md 的 hex 值在 gui/ 里存在**两份**互不相干的拷贝——
//   1. `ClaudioGUI/DesignTokens.swift` 里 `ClaudioColor` 的 `Color(hex: "…")` 字面量（视图真正渲染的那份）；
//   2. `Tests/ClaudioGUICoreTests/ContrastSuite.swift` 里一个私有 `enum DesignToken` 的手抄副本
//      （对比度断言真正测的那份）。
// 于是「把 DesignTokens 里的颜色改坏」这件事，对比度断言**照样全绿**——它在结构上不可能捕获它存在的
// 意义所对应的回归。T15 宣称「把对比度做成可执行的数学不变量」，实际并没有做到。
//
// 现在：hex 字面量只在本文件出现一次；`ClaudioColor`（SwiftUI 侧）从这批常量构建 `Color`，
// `ContrastSuite`（无依赖 harness 侧）直接对这批常量求对比度。改这里的任何一个颜色，视图和断言
// **同时**改变——对比度测试因此真的能变红。
//
// 本模块是纯 Foundation（不 import SwiftUI），所以无依赖测试 harness（`claudio-gui-tests`，本机
// 无 Xcode、无 XCTest/swift-testing）能直接引用它；这正是当初那份手抄副本存在的借口，现在不成立了。
//
// 每个值都逐字照抄自 DESIGN.md 的配色表；**不要在这里新增 DESIGN.md 里没有的颜色**
// （项目规则：「不经明确授权不得偏离 DESIGN.md」）。
public enum ClaudioColorHex {
    // MARK: 中性（DESIGN.md「中性 + 品牌」表）

    /// `text` 主文字。
    public static let textDark = "F4EBDD"
    public static let textLight = "2B2620"

    /// `text-2` 次要文字。DESIGN.md 里的次要文字色——也是「真红只做图标、文案改用 text-2」这条
    /// 决议（修复③）之后，pack 卡「文件丢失」/ onboarding 详情等报错**文案**的用色。
    public static let text2Dark = "B0AEA5"
    public static let text2Light = "75685A"

    /// `panel` 面板底——事件行、面板正文的真实底色。
    public static let panelDark = "1A1815"
    public static let panelLight = "FFFDFA"
    /// 糖果盘菜单栏面板渐变的最深端。对比度测试必须以这一端作为亮色最坏底。
    public static let panelDeepLight = "FBF7F1"

    /// 糖果盘行卡 / 表面。暗色不新增值，只提供语义别名。
    public static let surfaceDark = surface2Dark
    public static let surfaceLight = "FFFFFF"

    /// `surface-2` 抬升表面——pack 卡背景（T15 D3；卡内 2×2 事件字形网格**直接**画在它上面，没有 tile，
    /// 所以「事件字形 vs surface-2」仍是一对真实渲染的对比，`ContrastSuite` 继续钉它）。
    ///
    /// ⚠️ 它**不是**事件字形 tile 的底色。曾经有一版把 `EventRowView.glyphTile` 的底从「事件色自染 15%」
    /// 改成这个中性 token 来凑 ≥3:1——那是个退化，已推翻：亮色 `#FFFDF7` 对 `panel` `#FFFDF8` 只有
    /// **1.0006:1**，它俩就是同一个颜色，tile 在亮色下**整个消失**；「过了 ≥3:1」靠的是 tile 不存在、
    /// 字形直接落在面板上，而 DESIGN.md 的行结构明写 tile 是「事件色」。tile 现在（且必须）是事件色
    /// 自染 15%，见下面 `stopLight` / `stopFailureLight` 的注释。
    public static let surface2Dark = "262320"
    public static let surface2Light = "FFFDF7"

    /// `hairline-strong` 描边的**基色**。DESIGN.md 把它写成 `rgba(245,235,221,.16)` /
    /// `rgba(20,20,19,.16)`——透明度留在 `ClaudioColor.hairlineStrong(_:)`（那是 `Color` 层的事），
    /// 通道值放这里，这样 gui/ 里没有第二处颜色字面量。注意 `F5EBDD` **不是** `text` 的 `F4EBDD`
    /// （红通道差 1），是 DESIGN.md 自己的两个值，不要「顺手统一」。
    public static let hairlineBaseDark = "F5EBDD"
    public static let hairlineBaseLight = "3C2C20"

    /// `clay` 品牌强调——App 唯一的品牌色，同时是 `Notification` 的事件色（DESIGN.md「一个招牌绑定」）。
    /// `clay-soft`（drop-zone hover 底）就是这个色带透明度，不是另一个色，见 `ClaudioColor.claySoft(_:)`。
    public static let clayDark = "D97757"
    public static let clayLight = "C4633C"

    // MARK: UI 语义色（DESIGN.md「UI 语义色（提示 / 校验，独立于事件层）」表）

    /// `success`——已收到当前代次真实回执的宿主就绪状态。
    ///
    /// 和下面 `warning` vs `stopFailure` 完全同构的一次**刻意分叉**：UI 语义 `success` 仍是 DESIGN.md
    /// 原值 `#2FA24E`，而 `Stop` 的**事件**绿被调深到 `#288B43`（见 `stopLight`）。原因是两者画在
    /// 不同的底上——状态点画在面板上（亮色 3.23:1，过 ≥3:1 的非文本门槛），事件字形画在「自己颜色
    /// 15%」的复合底上（同一个 hex 在那儿只有 2.75:1，不及格）。它们过去恰好同值，那是巧合，不是
    /// 绑定（真正的绑定只有一处：
    /// `Notification` ≡ `clay`，那处是写成别名的）。
    public static let successDark = "34C759"
    public static let successLight = "2FA24E"

    /// `warning`——DESIGN.md 的 UI 语义 `warning`（校验提示），**与 `StopFailure` 的事件琥珀刻意分叉**：
    /// 事件字形的亮色琥珀被调深到 `#AC6900` 以过它那块自染复合底的 ≥3:1；UI `warning` 画在**面板**上，
    /// 是另一块底、另一个门槛，所以它有自己的值。分叉保留，理由不变。
    ///
    /// ## 亮色从 `#E08600` 调深到 `#B87000`（T17f，授权变更）
    ///
    /// 上一版这里写着「v1 还没有任何视图渲染它——将来第一个用它的视图是从这里取值」，并且留了一句
    /// 警告：「亮色 `#E08600` 对亮面板只有 2.73:1，**将来若把它当正文用**，必须先过对比度这关」。
    ///
    /// **那句警告漏了一半，而漏掉的那一半才是会绊倒人的那一半。** `#E08600` 不只过不了正文的
    /// ≥4.5:1——它连**图标**的 ≥3:1（WCAG 1.4.11）都过不了（对亮 panel 实测 2.73:1，对 surface-2
    /// 2.72:1）。于是「第一个用它的视图」（T17f 的 ⚠ 提示行，一个字形 + 一行 `text-2` 文案）在它
    /// 唯一能用的形态上**当场违约**。一个从没被渲染过的 token 也就从没被量过，这是它能带着一个
    /// 不及格的值在表里躺到今天的全部原因。
    ///
    /// 调深到 `#B87000`：对亮 panel **3.86:1**、对 surface-2 **3.85:1**，双双过 ≥3:1。只降明度、
    /// **不换色相**——仍是暖琥珀，绝不用红。与 `Stop`（`#2FA24E → #288B43`）、`StopFailure`
    /// （`#E08600 → #C87A00 → #AC6900`）是**同一条先例的第三次**：亮色 token 在真实底上量一遍，
    /// 不及格就降明度。暗色 `#FF9F0A` 对暗 panel 8.62:1，宽裕，不动。
    ///
    /// 刻意**不**复用 `stopFailureLight` (`#AC6900`)：那会把上面这条「UI 语义层与事件层刻意分叉」
    /// 当场合并成同一个 hex，而这条分叉正是写在这里防后人手抄的。
    ///
    /// 现在 `ContrastSuite` 给它开了四条 ≥3:1 断言（亮/暗 × panel/surface-2）——它不再是一个没人
    /// 量过的值。**仍然只做图标，不做正文**（同真红：3.86:1 过 ≥3:1，不过 ≥4.5:1），提示**文案**
    /// 一律 `text-2`。
    public static let warningDark = "FF9F0A"
    public static let warningLight = "B87000"

    /// `error`（真红）——**只**给 App 自身真错误（DESIGN.md「错误态用色（关键约束）」），
    /// 绝不用于四事件层（`StopFailure` 永远琥珀）。
    /// 且（修复③决议）：真红**只做图标**，不做正文——亮色 `#E0453A` 对面板只有 4.07:1，
    /// 不过正文 ≥4.5:1；报错**文案**一律用 `text-2`（5.54:1）。这条契约由 `ContrastSuite` 钉死。
    public static let errorDark = "FF453A"
    public static let errorLight = "E0453A"

    // MARK: 四事件语义色（DESIGN.md「四事件语义色」表）

    // ⚠️ 下面两个**亮色**事件色比 DESIGN.md 的原始值更深。这不是审美选择，是一条对比度硬约束
    // 推导出来的结果，改回去测试就会红——先读完这段再动它们：
    //
    // DESIGN.md 的行结构明写「事件字形 tile 24pt, **事件色**, 圆角6」，`EventRowView.glyphTile`
    // 因此把 tile 填成 `事件色.opacity(0.15)`，字形本身再用 100% 的同一个事件色画在上面。于是字形
    // 的**真实底色**不是 `panel`，而是「事件色 @15% 覆在 panel 上」的那个**复合色**——WCAG 1.4.11
    // 的 ≥3:1（非文本）必须对**那块复合底**成立。自染底把前景和背景往同一个色相上拉，是这套体系里
    // 最苛刻的一对，比对纯 panel 难得多（Stop 亮色：对 panel 4.25:1，对真实复合底只有 2.75:1）。
    //
    // 于是（2026-07-11 授权，DESIGN.md 配色表已同步）：
    //   · Stop        `#2FA24E` → `#288B43`   字形对真实 tile 底 2.75 → **3.53:1** ✅
    //   · StopFailure `#C87A00` → `#AC6900`   字形对真实 tile 底 2.82 → **3.59:1** ✅
    //   · Notification `#C4633C`（= clay，不动，招牌绑定）           3.32:1 ✅
    //   · SubagentStop `#5B59D6`（不动）                            4.37:1 ✅
    //   · 暗色四事件全部不动（本来就宽裕，全局最差是暗色 SubagentStop 的 3.06:1）
    //
    // 历史教训，两条都别再踩：
    //   1. 上一次的 `#E08600 → #C87A00` **没达成它的目的**。当时 `ContrastSuite` 断的是「字形 vs 纯
    //      `panel`」——断错了那一对（恰好是能过的那一对），所以 `#C87A00` 看着「达标」，真实复合底上
    //      其实只有 2.82:1。现在 suite 断的是 `compositedHex(事件色, over: panel, alpha: 0.15)`，
    //      即真身。
    //   2. 另一条走不通的路是「把 tile 底换成中性的 `surface-2`」：亮色下它对 `panel` 只有 1.0006:1，
    //      tile 会**整个消失**（详见 `surface2Light` 的注释）。tile 必须是事件色，所以只能调深事件色。

    /// ✅ `Stop` 本轮结束。亮色由 DESIGN.md 原 `#2FA24E` 调深为 `#288B43`——见上面那段：字形对
    /// 「Stop @15% 覆在 panel 上」的复合底旧值只有 2.75:1，新值 3.53:1。
    /// 注意它因此**不再**等于 UI 语义色 `success`（仍是 `#2FA24E`），那是刻意分叉，见 `successLight`。
    public static let stopDark = "34C759"
    public static let stopLight = "288B43"

    /// ⏸ `StopFailure` 中断了——琥珀，**绝不用红**。亮色从 DESIGN.md 原 `#E08600` 一路调深到
    /// `#AC6900`——见上面那段：字形对「StopFailure @15% 覆在 panel 上」的复合底，`#E08600` 是
    /// 2.36:1、上一版的 `#C87A00` 是 2.82:1（当时注释里写的「≈3.31:1」量的是**对纯 panel**，
    /// 断错了那一对，不是字形真实站着的底），`#AC6900` 才是 **3.59:1** ✅。
    /// 它因此也不再等于 UI 语义色 `warning`（T17f 起是 `#B87000`，此前是 `#E08600`），见 `warningLight`。
    /// **两者仍然刻意分叉** —— 只是今天两边都被量过了。
    public static let stopFailureDark = "FF9F0A"
    public static let stopFailureLight = "AC6900"

    /// ✋ `Notification` 需要你——**就是** `clay`（Claudio 自有品牌色与招牌绑定）。这里刻意
    /// 写成对 `clay` 的别名而不是复制一遍 hex：它们相等是设计意图，不是巧合，改 `clay` 就该
    /// 同时改它。
    public static let notificationDark = clayDark
    public static let notificationLight = clayLight

    /// ◦ `SubagentStop` 子任务结束——空心勾、更暗。
    public static let subagentStopDark = "5E5CE6"
    public static let subagentStopLight = "5B59D6"
}

/// 把 `foreground` 以 `alpha` 不透明度**合成**到不透明的 `background` 上，返回合成后那个不透明的
/// `"RRGGBB"` hex——即「一个半透明底真正渲染成什么颜色」。
///
/// 为什么需要它（/ship 评审修复②）：事件字形画在 `RoundedRectangle.fill(事件色.opacity(0.15))`
/// 的 tile 上，但 `ContrastSuite` 当初断言的却是「字形 vs 纯 `panel`」——**它断的那一对恰好是能过的
/// 那一对**，而真实渲染的那一对（字形 vs 事件色 15% 覆在 panel 上的复合色）亮色下只有 2.75:1 /
/// 2.82:1，不过 WCAG 1.4.11 的 ≥3:1。半透明底一旦出现，「底色 token」就不再等于「真实底色」，必须
/// 先合成再量。这个函数就是那把尺子：`ContrastSuite` 现在直接对
/// `compositedHex(事件色, over: panel, alpha: 0.15)` 下 ≥3:1 的断言，而不是对一个恰好过得去的替身；
/// tile 保持自染（DESIGN.md 要求它是事件色），达标靠的是**调深两个亮色事件色**（见 `stopLight` /
/// `stopFailureLight`）。将来任何人再引入半透明底，都用同一把尺子量。
///
/// 合成在 sRGB **gamma 空间**逐通道做（`out = fg·α + bg·(1−α)`）——这正是 CoreGraphics / SwiftUI
/// 对 `Color.opacity(_:)` 的实际行为，所以量出来的是屏幕上真实的那个像素，不是一个理论上「更正确」
/// 的线性光混合。
///
/// 失败关闭（fail-closed，和 ``contrastRatio(_:_:)`` 同一个契约）：任何一边不是恰好 6 位十六进制、
/// 或 `alpha` 不在 `0...1`，返回 `nil` —— 绝不返回一个「看起来很合理」的错误颜色，因为这个函数的
/// 输出会直接喂给对比度断言，一个悄悄算错的底色能让一个真实的对比度违规**通过**测试。
public func compositedHex(_ foreground: String, over background: String, alpha: Double) -> String? {
    guard alpha >= 0, alpha <= 1,
        let foregroundChannels = hexChannels(foreground),
        let backgroundChannels = hexChannels(background)
    else { return nil }

    let composited = zip(foregroundChannels, backgroundChannels).map { foreground, background in
        UInt8(
            (Double(foreground) * alpha + Double(background) * (1 - alpha))
                .rounded()
                .clamped(to: 0...255))
    }
    return composited.map { String(format: "%02X", $0) }.joined()
}

/// `"RRGGBB"`（可选 `#` 前缀）→ 三个 0–255 通道值；不合法的形状返回 `nil`。
///
/// 这里的守卫和 `ContrastRatio.swift` 里 `relativeLuminance(of:)` 的守卫**是同一套**：恰好 6 个字符、
/// 每个都是真的十六进制数字（`isHexDigit`），然后才敢信任 `UInt32(_:radix:)` 的解析结果——因为
/// `FixedWidthInteger(_:radix:)` 会接受一个前导符号，`"+FFFFF"` 正好 6 个字符、解析成 `0x0FFFFF`，
/// 会交回一个完全合理、也完全错误的颜色（见 `ContrastHexParsingSuite.swift`）。那份守卫是文件私有的，
/// 本次改动的文件所有权不允许去改它，所以这里是同一形状的第二份实现——`ContrastSuite` 因此对**这个**
/// 函数也钉了同样的符号前缀变异用例，两份守卫谁松了都会红。
private func hexChannels(_ hex: String) -> [UInt8]? {
    var hexString = hex
    if hexString.hasPrefix("#") { hexString.removeFirst() }
    guard hexString.count == 6, hexString.allSatisfy(\.isHexDigit),
        let value = UInt32(hexString, radix: 16)
    else { return nil }
    return [
        UInt8((value & 0xFF0000) >> 16),
        UInt8((value & 0x00FF00) >> 8),
        UInt8(value & 0x0000FF),
    ]
}

extension Double {
    /// 夹紧到闭区间——只为把浮点合成结果安全地收回 `UInt8` 的定义域（四舍五入后的 255.0000001
    /// 之类的边界，不能让它变成一次 trap）。
    fileprivate func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
