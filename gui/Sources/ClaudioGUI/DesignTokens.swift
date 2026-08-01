import ClaudioCore
import ClaudioGUICore
import SwiftUI

// MARK: - DESIGN.md token values → SwiftUI `Color`
//
// 这个文件里**没有任何 hex 字面量**了（/ship 评审修复①）：每个颜色都从
// ``ClaudioColorHex``（`ClaudioGUICore`，纯 Foundation）的常量构建。那里是 DESIGN.md 配色表在
// gui/ 里的唯一真相源，`ContrastSuite.swift` 的对比度断言也直接对同一批常量求值——所以改一个
// 颜色，视图渲染和对比度不变量**同时**改变，对比度测试能真的因此变红。
//
// （在这之前，DESIGN.md 的 hex 在本文件和 `ContrastSuite.swift` 各存一份手抄副本，改这里对断言
// 毫无影响——一个在结构上不可能捕获它所针对的回归的断言。见 `ClaudioColorHex.swift` 的文件头。）
//
// 本文件负责的只剩「`Color` 层」的事：随 `ColorScheme` 选明/暗值，以及 DESIGN.md 用 `rgba(...)`
// 表达的那几个 token 的透明度（`hairline-strong` / `clay-soft`）。不要在这里新增
// DESIGN.md 里没有的颜色（项目规则：「不经明确授权不得偏离 DESIGN.md」）。

extension Color {
    /// A `Color` from a `"RRGGBB"` (or `"#RRGGBB"`) hex string, as used throughout
    /// DESIGN.md's token table.
    init(hex: String) {
        var hexString = hex
        if hexString.hasPrefix("#") { hexString.removeFirst() }
        var value: UInt64 = 0
        Scanner(string: hexString).scanHexInt64(&value)
        let red = Double((value & 0xFF0000) >> 16) / 255
        let green = Double((value & 0x00FF00) >> 8) / 255
        let blue = Double(value & 0x0000FF) / 255
        self.init(red: red, green: green, blue: blue)
    }
}

/// DESIGN.md's neutral + brand + UI-semantic tokens, resolved per `ColorScheme` since
/// this module deliberately avoids an `NSColor` dynamic-provider dependency for T7's
/// scope. Dark values are DESIGN.md's primary tone ("暗色为主基调"); light values are the
/// documented light-mode counterparts.
enum ClaudioColor {
    static func text(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(hex: ClaudioColorHex.textDark) : Color(hex: ClaudioColorHex.textLight)
    }

    /// `text-2` 次要文字。也是每一处**报错文案**的用色（/ship 评审修复③的决议：真红 `error`
    /// 只做图标、不做正文——亮色真红对面板只有 4.07:1，不过正文 ≥4.5:1；`text-2` 是 5.54:1）。
    static func textSecondary(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(hex: ClaudioColorHex.text2Dark) : Color(hex: ClaudioColorHex.text2Light)
    }

    static func panel(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(hex: ClaudioColorHex.panelDark) : Color(hex: ClaudioColorHex.panelLight)
    }

    /// `surface-2` 抬升表面 (T15). `PackGalleryView` 的 pack 卡背景 —— ⚠️ DESIGN.md 未定义 pack
    /// 卡背景色，这里用既有 token 派生（`surface-2` 是 DESIGN.md「配色」表里已有的「抬升」表面
    /// 语义，最贴近 macOS 壁纸选择器式卡片的既有选项），而非新造一个颜色。
    ///
    /// ⚠️ **不要**拿它当 `EventRowView.glyphTile` 的 tile 底 —— 这条路走过、并被推翻：亮色
    /// `surface-2` `#FFFDF7` 对 `panel` `#FFFDF8` 只有 **1.0006:1**，两者**是同一个颜色**，
    /// tile 会在亮色下**整个消失**（"通过"对比度靠的是字形直接落在面板上，而 DESIGN.md 行结构
    /// 要求 tile 是**事件色**）。tile 的 ≥3:1 现由**调深亮色事件色**满足（`#288B43` / `#AC6900`），
    /// tile 保持事件色自染 15%。`ContrastSuite.swift` 对此正反双向钉死：既断言字形对真实复合底
    /// ≥3:1，也断言 tile 底本身对 `panel` **可见**（≥1.10:1）—— 后者正是当初漏掉、导致 tile
    /// 消失也能"全绿"的那把尺子。
    static func surface2(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(hex: ClaudioColorHex.surface2Dark) : Color(hex: ClaudioColorHex.surface2Light)
    }

    /// `hairline-strong` — DESIGN.md 把它写成 `rgba(...)`：基色取自 ``ClaudioColorHex``，
    /// 透明度（`.16`）是本层（`Color` 层）的事。
    static func hairlineStrong(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(hex: ClaudioColorHex.hairlineBaseDark).opacity(0.16)
            : Color(hex: ClaudioColorHex.hairlineBaseLight).opacity(0.16)
    }

    /// `clay` — the sole brand accent.
    static func clay(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(hex: ClaudioColorHex.clayDark) : Color(hex: ClaudioColorHex.clayLight)
    }

    /// `clay-soft` — DESIGN.md 写作 `rgba(217,119,87,.15)` / `rgba(196,99,60,.12)`，即 `clay`
    /// 本身带透明度（通道值与 ``clay(_:)`` 逐位相同，不是另一个颜色），所以这里直接由 ``clay(_:)``
    /// 派生，而不是抄一份通道数字。仅用于 drop-zone 的 hover 底（T8; DESIGN.md「拖入 drop-zone」:
    /// "hover 命中 → **边框**转黏土 + `clay-soft` 底，**文案保持 `text-2` 不变**" —— 2026-07-11
    /// `/ship` 拍板解法 1 后的现行文；旧文「边框 / 文字转黏土」已被推翻，勿再引用，见
    /// PLAN-MASTER-VOLUME D46）。
    static func claySoft(_ scheme: ColorScheme) -> Color {
        clay(scheme).opacity(scheme == .dark ? 0.15 : 0.12)
    }

    /// UI-semantic `success` — current-installation receipt observed for a host source.
    static func success(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(hex: ClaudioColorHex.successDark) : Color(hex: ClaudioColorHex.successLight)
    }

    /// UI-semantic `warning`（暖琥珀）——「Claudio 替你做了主，你有权知道」那一类**告知**，
    /// 不是错误（T17f）。今天唯一的用处是 ``ActionNoticeRow`` 的 ⚠ 字形：一次 setup 把用户读不出来
    /// 的包**搬走了**，或把他选中的包**换掉了**。
    ///
    /// 为什么不是既有的三个 token 之一——三条都是 DESIGN.md 自己写下的规矩，不是口味：
    /// - **不是真红 ``error(_:)``**：DESIGN.md「错误态用色（关键约束）」把真红**限定**给三种 app
    ///   自身错误（settings 不可写 / 解析失败 / helper 缺失）。这里 setup **成功了**，磁盘上是一个
    ///   能响的安装。把它染成真红就是在对用户撒谎。
    /// - **不是中性 `text-2`**：那正是 CLI 侧那行注释明令禁止的形状——「⚠ 而不是 ·：搬走一个用户
    ///   目录，是这次 setup 里代价最大的一个『我替你做主』。绝不能让它混在几条 · 里悄悄过去——那个
    ///   目录里完全可能装着他自己导入的、磁盘上唯一一份音频。」
    /// - **不是黏土 ``clay(_:)``**：DESIGN.md「品牌强调唯一 = 黏土，这条不为任何单一状态开色值的
    ///   口子」，且 `clay ≡ Notification` 的事件色（写成别名的那一处真绑定）——拿它当警告色会让提示行
    ///   与「通知」事件同色。
    ///
    /// ⚠️ 与真红同一条纪律：**只做图标，不做正文**（亮色 `#B87000` 对面板 3.86:1，过 ≥3:1 的
    /// WCAG 1.4.11，**不过** ≥4.5:1 的 WCAG 1.4.3）。提示**文案**一律 ``textSecondary(_:)``。
    /// 这条契约由 `ContrastSuite` 的四条 ≥3:1 断言钉死。
    static func warning(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(hex: ClaudioColorHex.warningDark) : Color(hex: ClaudioColorHex.warningLight)
    }

    /// UI-semantic `error` (真红) — **只**给 App 自身真错误（DESIGN.md「错误态用色（关键约束）」），
    /// 绝不用于四事件层（`StopFailure` 永远琥珀，不在本 token 的射程内）。
    ///
    /// ⚠️ 且**只做图标**，不做正文（/ship 评审修复③）：亮色 `#E0453A` 对 `panel` / `surface-2`
    /// 只有 4.07:1 / 4.06:1 —— 过非文本的 ≥3:1（WCAG 1.4.11），但**不过**正文的 ≥4.5:1
    /// （WCAG 1.4.3）。报错**文案**一律用 ``textSecondary(_:)``。这条契约由 `ContrastSuite.swift`
    /// 钉死：真红只出现在 ≥3:1 那一组断言里。
    static func error(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(hex: ClaudioColorHex.errorDark) : Color(hex: ClaudioColorHex.errorLight)
    }
}

/// Maps an ``OnboardingAccent`` (from `ClaudioGUICore`, a Foundation-only semantic token
/// name) to its actual `Color`, per-`ColorScheme` — the one place `OnboardingAccent`
/// meets an actual pixel value, kept out of `ClaudioGUICore` so that module never needs
/// to import SwiftUI (see `gui/Package.swift`'s target-layout note).
func stateAccentColor(_ accent: OnboardingAccent, _ scheme: ColorScheme) -> Color {
    switch accent {
    case .neutral: ClaudioColor.textSecondary(scheme)
    case .error: ClaudioColor.error(scheme)
    case .brand: ClaudioColor.clay(scheme)
    case .success: ClaudioColor.success(scheme)
    }
}

// MARK: - T16: per-event color + glyph tokens
//
// 同上：值全部来自 ``ClaudioColorHex``（DESIGN.md「四事件语义色」表的唯一真相源），
// 这里只做「按 `ColorScheme` 选一个」这件事。不要在这里新增 DESIGN.md 里没有的色阶。
extension ClaudioColor {
    /// DESIGN.md's per-event accent color (dark / light), keyed by ``Event``.
    /// `Notification`'s value is deliberately the same `clay(_:)` the rest of this file
    /// already defines — DESIGN.md calls this out as "一个招牌绑定": the ONE place the
    /// brand color doubles as a semantic event color, not a coincidence to re-derive.
    /// （``ClaudioColorHex/notificationDark`` 同样是对 `clayDark` 的别名，不是复制一遍 hex。）
    static func event(_ event: Event, _ scheme: ColorScheme) -> Color {
        switch event {
        case .stop:
            scheme == .dark
                ? Color(hex: ClaudioColorHex.stopDark) : Color(hex: ClaudioColorHex.stopLight)
        case .stopFailure:
            // Amber — DESIGN.md: "限流 / 欠费 / 过载 / 认证（非代码 bug）...绝不用红".
            // 亮色从 DESIGN.md 原 #E08600 一路调深到 #AC6900（**不是** 中间那版 #C87A00——它量的是
            // 「字形 vs 纯 panel」，断错了那一对；对字形真实站着的复合底只有 2.82:1）。现值对
            // 「StopFailure @15% 覆在 panel 上」的真实底是 3.59:1，过 ≥3:1 非文本对比（WCAG 1.4.11）。
            // 仍是琥珀，绝不用红。全部数值与真相源见 ``ClaudioColorHex/stopFailureLight``。
            scheme == .dark
                ? Color(hex: ClaudioColorHex.stopFailureDark)
                : Color(hex: ClaudioColorHex.stopFailureLight)
        case .notification:
            clay(scheme)
        case .subagentStop:
            scheme == .dark
                ? Color(hex: ClaudioColorHex.subagentStopDark)
                : Color(hex: ClaudioColorHex.subagentStopLight)
        }
    }
}

/// SF Symbol per event (DESIGN.md「事件字形」table: `checkmark.circle.fill` /
/// `pause.circle.fill` / `bell.badge.fill` / `checkmark.circle`). `subagentStop` is
/// deliberately **hollow** (`checkmark.circle`, no `.fill`) — DESIGN.md's own note: "空心
/// 勾...更暗", a one-glance "smaller/lesser completion" distinct from `stop`'s solid
/// checkmark, not an inconsistency to "fix".
func eventGlyphName(_ event: Event) -> String {
    switch event {
    case .stop: "checkmark.circle.fill"
    case .stopFailure: "pause.circle.fill"
    case .notification: "bell.badge.fill"
    case .subagentStop: "checkmark.circle"
    }
}
