import ClaudioGUICore
import Foundation

// MARK: - contrastRatio + DESIGN.md token pairs (ENGINEERING.md T15 D5「对比度」)
//
// 这些断言把 DESIGN.md 第 127 行（「行内文字 ≥ 4.5:1」）和 ENGINEERING.md「无障碍规格」
// （事件字形对表面 ≥ 3:1，WCAG 1.4.11 非文本）变成**可执行的数学不变量**。
//
// 它们过去并不是（/ship 评审修复①）：本文件顶部曾有一个私有 `enum DesignToken`，里面的 hex 是
// 从 `ClaudioGUI/DesignTokens.swift` **手抄的副本**——于是改 `DesignTokens.swift` 里的颜色，这
// 整套断言照样全绿。一个在结构上不可能捕获它所针对的回归的断言，不是不变量。
//
// 现在：**没有本地副本**。每一个 hex 都来自 ``ClaudioColorHex``（`ClaudioGUICore`，纯 Foundation，
// 所以这个无依赖 harness 直接能用），而 `ClaudioColor`（视图真正渲染的那层）也从同一批常量构建
// `Color`。改一个颜色 → 视图和断言同时改变 → 这套测试真的会红。
//
// 三条被这批断言钉死的用色契约（口头约定没用，写在这里才算数）：
//   1. **真红 `error` 只做图标，绝不做正文**：亮色 `#E0453A` 对 `panel` / `surface-2` 只有
//      4.07:1 / 4.06:1 —— 过非文本的 ≥3:1，**不过**正文的 ≥4.5:1。所以下面 `error` 只出现在
//      ≥3:1 那一组里；任何报错**文案**必须用 `text-2`（5.54:1，在 ≥4.5:1 那一组里）。
//   2. **半透明底必须先合成再量**：事件字形画在 `事件色.opacity(0.15)` 的 tile 上（DESIGN.md 行结构
//      要求 tile 是**事件色**），所以它真实站着的底是一个**复合色**，不是任何一个 token。
//      `runCompositedBackgroundSuites()` 用 ``compositedHex(_:over:alpha:)`` 把那块底算出来再量 ≥3:1
//      —— 断的是真身。本文件下面那组「字形 vs `surface-2`」量的是**另一个**真实表面（`PackGalleryView`
//      卡片里的 2×2 网格，字形直接画在卡底上、没有 tile），两组各有各的渲染现场，不是彼此的替身。
//   3. **tile 自己也得看得见**：字形对底达标还不够。曾经有一版为了凑 ≥3:1 把 tile 底从自染改成中性的
//      `surface-2` —— 亮色下 `#FFFDF7` 对 `panel` `#FFFDF8` 只有 **1.0006:1**，tile **整个消失**，
//      「达标」靠的是字形其实落在了面板上。`runCompositedBackgroundSuites()` 因此还有一条**可见性
//      护栏**（tile 底 vs 面板 ≥1.10:1）＋ 一条反向断言（`surface-2` 当 tile 底会掉到 1.0006）。

@MainActor
func runContrastSuites() {
    suite("contrastRatio: sanity — pure black on pure white is the known 21:1 maximum") {
        let ratio = contrastRatio("000000", "FFFFFF")
        expect(abs(ratio - 21.0) < 0.01, "expected ~21.0, got \(ratio)")
    }

    suite("contrastRatio: identical colors have a ratio of exactly 1.0 (no contrast)") {
        let ratio = contrastRatio(ClaudioColorHex.clayDark, ClaudioColorHex.clayDark)
        expect(abs(ratio - 1.0) < 0.0001, "expected 1.0, got \(ratio)")
    }

    suite("contrastRatio: is symmetric — argument order does not matter") {
        let a = contrastRatio(ClaudioColorHex.textDark, ClaudioColorHex.panelDark)
        let b = contrastRatio(ClaudioColorHex.panelDark, ClaudioColorHex.textDark)
        expect(a == b, "contrastRatio must be symmetric, got \(a) vs \(b)")
    }

    suite("contrastRatio: a malformed hex string fails closed to 1.0, never crashes") {
        let ratio = contrastRatio("not-a-hex-color", ClaudioColorHex.panelDark)
        expect(ratio == 1.0, "a malformed token must fail closed to the no-contrast floor, got \(ratio)")
    }

    suite("contrastRatio: a malformed SECOND argument also fails closed to 1.0 (both operands are guarded)") {
        // The first-argument case above alone would pass even if only `hexA` were validated —
        // this pins the other half of the same guard.
        let ratio = contrastRatio(ClaudioColorHex.panelDark, "#GGGGGG")
        expect(ratio == 1.0, "a malformed second token must fail closed too, got \(ratio)")
    }

    suite("contrastRatio: a `#`-prefixed hex parses identically to the bare form (documented behavior)") {
        // `relativeLuminance` explicitly strips a leading `#` ("optionally `#`-prefixed") — a
        // documented input shape with its own branch, and the form DESIGN.md's table itself
        // writes colors in, so a future token copied verbatim (with the `#`) must not silently
        // collapse to the 1.0 fail-closed floor.
        expect(
            abs(contrastRatio("#000000", "#FFFFFF") - 21.0) < 0.01,
            "a #-prefixed pair must measure the same 21:1 as the bare form, got \(contrastRatio("#000000", "#FFFFFF"))")
        expect(
            contrastRatio("#\(ClaudioColorHex.textDark)", ClaudioColorHex.panelDark)
                == contrastRatio(ClaudioColorHex.textDark, ClaudioColorHex.panelDark),
            "mixing a #-prefixed and a bare token must not change the measured ratio")
    }

    suite("contrastRatio: a too-short hex (3-digit shorthand) fails closed rather than mis-parsing") {
        // `#FFF` is legal CSS but NOT a shape this function claims to support — it must fail
        // closed to 1.0 rather than silently parse as some other color and let a would-be
        // contrast violation through the assertions below.
        expect(contrastRatio("FFF", "000000") == 1.0, "a 3-digit hex must fail closed, got \(contrastRatio("FFF", "000000"))")
    }

    // MARK: - DESIGN.md line 127: 行内文字 ≥ 4.5:1 (WCAG AA, normal text)

    let textPairs: [(name: String, ratio: Double)] = [
        ("text/panel dark", contrastRatio(ClaudioColorHex.textDark, ClaudioColorHex.panelDark)),
        ("text/panel light", contrastRatio(ClaudioColorHex.textLight, ClaudioColorHex.panelLight)),
        ("text/panel deepest light", contrastRatio(ClaudioColorHex.textLight, ClaudioColorHex.panelDeepLight)),
        // text-2/panel — 这一对现在钉住的东西比原来多：
        //   (a) T16 FIX B：muted 态的次要文字（行内文件名/id、「未配置」/「文件丢失」标签）永远
        //       是 `text-2`，`EventRowView` 从不降 opacity，所以钉住这一对就钉住了 muted 态的
        //       文字下限——不存在一个单独的「muted 灰」hex 可测；
        //   (b) /ship 评审修复③：**所有报错文案**（pack 卡「文件丢失」、onboarding 详情、拒绝行
        //       说明）也用 `text-2` —— 因为真红 `error` 亮色只有 4.07:1，做正文不合格。真红降级
        //       为「只做图标」，见下面 ≥3:1 那一组。
        ("text-2/panel dark (muted 次要文字 + 报错文案)", contrastRatio(ClaudioColorHex.text2Dark, ClaudioColorHex.panelDark)),
        ("text-2/panel light (muted 次要文字 + 报错文案)", contrastRatio(ClaudioColorHex.text2Light, ClaudioColorHex.panelLight)),
        ("text-2/panel deepest light", contrastRatio(ClaudioColorHex.text2Light, ClaudioColorHex.panelDeepLight)),
        // 糖果盘 pack row 的真实底是 `surface`（亮色纯白；暗色沿用旧抬升面）。
        ("text/surface dark (pack-row name)", contrastRatio(ClaudioColorHex.textDark, ClaudioColorHex.surfaceDark)),
        ("text/surface light (pack-row name)", contrastRatio(ClaudioColorHex.textLight, ClaudioColorHex.surfaceLight)),
        ("text-2/surface dark (pack-row status)", contrastRatio(ClaudioColorHex.text2Dark, ClaudioColorHex.surfaceDark)),
        ("text-2/surface light (pack-row status)", contrastRatio(ClaudioColorHex.text2Light, ClaudioColorHex.surfaceLight)),
    ]

    for pair in textPairs {
        suite("contrast: \(pair.name) is ≥ 4.5:1 (DESIGN.md line 127, WCAG AA normal text)") {
            expect(
                pair.ratio >= 4.5,
                "\(pair.name) must be ≥ 4.5:1, got \(pair.ratio) — DESIGN.md's in-panel text"
                    + " contrast floor has been violated")
        }
    }

    // MARK: - ENGINEERING.md「无障碍规格」: 非文本 ≥ 3:1 (WCAG 1.4.11)
    //
    // 覆盖两类非文本着色元素：
    //   (1) 五事件字形 × 明暗 × 它能画在的两种**不透明**底上：
    //         · `surface-2` —— `PackGalleryView` 卡片里的 2×2 事件网格：字形**直接**画在卡底上，
    //           没有 tile，所以这里的底就是这个 token 本身；以及
    //         · `panel` —— 面板上直接放字形、不带 tile 的地方（状态画廊 / 空态图标）。
    //       两种底都必须过；今天最差的一对是 SubagentStop 暗色对 surface-2（3.09:1）。
    //       ⚠️ 事件字形**第三个**、也是最苛刻的渲染现场是 `EventRowView.glyphTile` 的**自染复合底**
    //       （事件色 @15% 覆在 panel 上）——它不是一个 token，量它必须先合成，见
    //       `runCompositedBackgroundSuites()`。别把下面这两组当成它的替身：那正是上一版「断错了那一对」
    //       的错误。
    //   (2) 真红 `error` × 明暗 × 两种底 —— **只做图标**（DESIGN.md 拒绝行的 `circle-x` 字形、
    //       pack 卡的丢失图标）。它过去在这套断言里**一对都没有**（/ship 评审修复③），而它亮色
    //       只有 4.07:1：做图标合格，做正文不合格。这四条断言 = 「真红降级为图标色」这条决议的
    //       执行机制；配套的另一半是上面 text-2 的 ≥4.5:1 断言（报错文案的新用色）。
    struct NonTextPair {
        let name: String
        let hex: String
        let background: String
    }

    let nonTextPairs: [NonTextPair] = [
        // — 事件字形 vs surface-2：pack 卡 2×2 网格的卡底（无 tile）—
        NonTextPair(name: "TaskStart dark glyph vs surface-2", hex: ClaudioColorHex.taskStartDark, background: ClaudioColorHex.surface2Dark),
        NonTextPair(name: "TaskStart light glyph vs surface-2", hex: ClaudioColorHex.taskStartLight, background: ClaudioColorHex.surface2Light),
        NonTextPair(name: "Stop dark glyph vs surface-2 (pack 卡 2×2 网格底)", hex: ClaudioColorHex.stopDark, background: ClaudioColorHex.surface2Dark),
        NonTextPair(name: "Stop light glyph vs surface-2 (pack 卡 2×2 网格底)", hex: ClaudioColorHex.stopLight, background: ClaudioColorHex.surface2Light),
        NonTextPair(name: "StopFailure dark glyph vs surface-2 (pack 卡 2×2 网格底)", hex: ClaudioColorHex.stopFailureDark, background: ClaudioColorHex.surface2Dark),
        NonTextPair(name: "StopFailure light glyph vs surface-2 (pack 卡 2×2 网格底)", hex: ClaudioColorHex.stopFailureLight, background: ClaudioColorHex.surface2Light),
        NonTextPair(name: "Notification dark glyph vs surface-2 (pack 卡 2×2 网格底)", hex: ClaudioColorHex.notificationDark, background: ClaudioColorHex.surface2Dark),
        NonTextPair(name: "Notification light glyph vs surface-2 (pack 卡 2×2 网格底)", hex: ClaudioColorHex.notificationLight, background: ClaudioColorHex.surface2Light),
        NonTextPair(name: "SubagentStop dark glyph vs surface-2 (pack 卡 2×2 网格底)", hex: ClaudioColorHex.subagentStopDark, background: ClaudioColorHex.surface2Dark),
        NonTextPair(name: "SubagentStop light glyph vs surface-2 (pack 卡 2×2 网格底)", hex: ClaudioColorHex.subagentStopLight, background: ClaudioColorHex.surface2Light),
        // — 事件字形 vs panel：面板上不带 tile 直接放字形的地方 —
        NonTextPair(name: "TaskStart dark glyph vs panel", hex: ClaudioColorHex.taskStartDark, background: ClaudioColorHex.panelDark),
        NonTextPair(name: "TaskStart light glyph vs panel", hex: ClaudioColorHex.taskStartLight, background: ClaudioColorHex.panelLight),
        NonTextPair(name: "Stop dark glyph vs panel", hex: ClaudioColorHex.stopDark, background: ClaudioColorHex.panelDark),
        NonTextPair(name: "Stop light glyph vs panel", hex: ClaudioColorHex.stopLight, background: ClaudioColorHex.panelLight),
        NonTextPair(name: "StopFailure dark glyph vs panel", hex: ClaudioColorHex.stopFailureDark, background: ClaudioColorHex.panelDark),
        NonTextPair(name: "StopFailure light glyph vs panel", hex: ClaudioColorHex.stopFailureLight, background: ClaudioColorHex.panelLight),
        NonTextPair(name: "Notification dark glyph vs panel", hex: ClaudioColorHex.notificationDark, background: ClaudioColorHex.panelDark),
        NonTextPair(name: "Notification light glyph vs panel", hex: ClaudioColorHex.notificationLight, background: ClaudioColorHex.panelLight),
        NonTextPair(name: "SubagentStop dark glyph vs panel", hex: ClaudioColorHex.subagentStopDark, background: ClaudioColorHex.panelDark),
        NonTextPair(name: "SubagentStop light glyph vs panel", hex: ClaudioColorHex.subagentStopLight, background: ClaudioColorHex.panelLight),
        // — 真红 error，**只**做图标（修复③）—
        NonTextPair(name: "error 真红 dark ICON vs panel", hex: ClaudioColorHex.errorDark, background: ClaudioColorHex.panelDark),
        NonTextPair(name: "error 真红 light ICON vs panel", hex: ClaudioColorHex.errorLight, background: ClaudioColorHex.panelLight),
        NonTextPair(name: "error 真红 dark ICON vs surface-2", hex: ClaudioColorHex.errorDark, background: ClaudioColorHex.surface2Dark),
        NonTextPair(name: "error 真红 light ICON vs surface-2", hex: ClaudioColorHex.errorLight, background: ClaudioColorHex.surface2Light),
        // — UI 语义 warning（⚠ 告知行的字形），**只**做图标，同真红那条纪律（T17f）—
        //
        // 这四条是本次调深（`#E08600 → #B87000`）的**全部理由**：`warning` 在表里躺了很久，
        // 但从没有任何视图渲染它，**于是也从没有人量过它**。真去量，亮色只有 2.73:1 —— 连图标的
        // ≥3:1 都不过（旧注只警告了「当正文用要过 ≥4.5:1」，漏掉了图标这一半，而告知行恰恰只以
        // 图标形态用它）。一个没人量过的 token 就是一个没人验过的承诺。现在它被量了。
        NonTextPair(name: "warning 琥珀 dark ICON vs panel", hex: ClaudioColorHex.warningDark, background: ClaudioColorHex.panelDark),
        NonTextPair(name: "warning 琥珀 light ICON vs panel", hex: ClaudioColorHex.warningLight, background: ClaudioColorHex.panelLight),
        NonTextPair(name: "warning 琥珀 dark ICON vs surface-2", hex: ClaudioColorHex.warningDark, background: ClaudioColorHex.surface2Dark),
        NonTextPair(name: "warning 琥珀 light ICON vs surface-2", hex: ClaudioColorHex.warningLight, background: ClaudioColorHex.surface2Light),
    ]

    for pair in nonTextPairs {
        let ratio = contrastRatio(pair.hex, pair.background)
        suite("contrast: \(pair.name) is ≥ 3:1 (ENGINEERING.md 无障碍规格, WCAG 1.4.11 non-text)") {
            expect(
                ratio >= 3.0,
                "\(pair.name) must be ≥ 3:1, got \(ratio) — ENGINEERING.md's non-text"
                    + " contrast floor has been violated")
        }
    }

    // MARK: - 5-slot 覆盖轨：present / missing × 明 / 暗各一对（PLAN-SOUND-MANAGER T10）
    //
    // 这四条**刻意以覆盖轨自己的名字重断一次**，不是拿上面旧 2×2 网格的断言冒充新组件的覆盖：
    //
    // - `present` 是事件色实心胶囊；逐个事件里最弱的一对，亮色是 Notification、暗色是
    //   SubagentStop（DESIGN.md「5-slot 覆盖轨」实测 3.97 / 3.09）；
    // - `missing` 是 `text-2` 的 1px 空壳 + 斜杠；亮 / 暗分别是 5.54 / 7.03。
    //
    // 四对的真实底都是 PackCardView 的糖果盘 `surface`。`ClaudioGUI` 是不可 import 的 executable
    // target，所以这组保持纯 hex 数学；生产视图确实把这几个 token 接到 CoverageTrack 上的另一半，
    // 由 ViewWiringSuite 的 T10 绊线钉住。两半缺一不可：只有这里会漏掉「描边改回 muted」的接线回归，
    // 只有源码绊线又证明不了 token 本身真的过 ≥3:1。
    func assertCoverageTrackContrast(
        _ name: String,
        foreground: String,
        background: String
    ) {
        let ratio = contrastRatio(foreground, background)
        suite("contrast: 5-slot 覆盖轨 \(name) vs surface is ≥ 3:1 (DESIGN.md「5-slot 覆盖轨」)") {
            expect(
                ratio >= 3.0,
                "5-slot 覆盖轨 \(name) must be ≥ 3:1, got \(ratio) — missing 必须用 text-2，"
                    + "present 必须取该主题最弱事件色（WCAG 1.4.11 non-text）")
        }
    }

    assertCoverageTrackContrast(
        "present dark（最弱 SubagentStop）",
        foreground: ClaudioColorHex.subagentStopDark,
        background: ClaudioColorHex.surfaceDark)
    assertCoverageTrackContrast(
        "present light（最弱 Notification）",
        foreground: ClaudioColorHex.notificationLight,
        background: ClaudioColorHex.surfaceLight)
    assertCoverageTrackContrast(
        "missing dark（text-2 描边 + 斜杠）",
        foreground: ClaudioColorHex.text2Dark,
        background: ClaudioColorHex.surfaceDark)
    assertCoverageTrackContrast(
        "missing light（text-2 描边 + 斜杠）",
        foreground: ClaudioColorHex.text2Light,
        background: ClaudioColorHex.surfaceLight)

    // MARK: - 真红**不得**当正文用：这是上面那组断言在守的契约，这里把它写成可读的、会说话的一条
    //
    // 不是「期望它失败」的诡异断言——它断言的是一个事实：真红亮色**够不到**正文门槛。任何人想把
    // 报错文案改回真红，这条注释 + 这个数字就是拒绝的依据；而真正的执行机制是：真红只在 ≥3:1 那组
    // 出现，报错文案的 token（`text-2`）在 ≥4.5:1 那组出现。
    suite("contract: 真红 error 亮色够不到正文 ≥4.5:1 —— 所以它只做图标，文案一律 text-2") {
        let errorAsText = contrastRatio(ClaudioColorHex.errorLight, ClaudioColorHex.panelLight)
        expect(
            errorAsText < 4.5,
            "如果真红亮色已经 ≥4.5:1（实测 \(errorAsText)），说明 DESIGN.md 的真红被改过了 —— "
                + "「真红只做图标、文案用 text-2」这条决议的前提没了，请回来重新决策，不要让这条断言"
                + "自动失效")
        let text2AsText = contrastRatio(ClaudioColorHex.text2Light, ClaudioColorHex.panelLight)
        expect(
            text2AsText >= 4.5,
            "报错文案改用的 text-2 必须真的过正文门槛，got \(text2AsText)")
    }

    // MARK: - 决议（2026-07-11）：drop-zone hover 文案不转黏土，正文恒为 text-2
    //
    // DESIGN.md 第 131 行原本祝福了这个用法：「拖入 drop-zone ... hover 命中 → 边框 / **文字**转
    // 黏土 + `clay-soft` 底」——而 DESIGN.md 第 127 行同时要求「行内文字 ≥ 4.5:1」。亮色黏土
    // `#C4633C` 对 `panel` / `surface-2` 都是 3.97:1：过图标/边框的 ≥3:1，**不过**正文的 ≥4.5:1。
    // 这曾经是 DESIGN.md 的一处内部冲突（登记为 known gap、不擅自决定）。
    //
    // 现在冲突已经拍板：文字不动，hover 感交给边框 + `clay-soft` 底色——DESIGN.md 自己列出的
    // option 1，零品牌代价（黏土仍是 hover 唯一强调色，只是不落在文字上）。`AudioDropZoneView.
    // promptLabel` 已经照此改过：颜色恒为 `ClaudioColor.textSecondary`（对应这里的 `text2*`
    // token），hover 时也不变。
    //
    // 下面这条断言把决议钉成一个会红的不变量，而不是一句会被忽略的注释——它断的是「为什么」，不是
    // 「是否」：
    //   1. clay 亮色必须够不到正文 ≥4.5:1——这不再是「待决策的缺口」，而是「promptLabel 为什么
    //      不能用它」的事实依据。这个数字一旦变了（品牌色被调深），决议的前提就没了，需要回来重新
    //      决策，而不是让这条断言默默失效。
    //   2. text-2（promptLabel 真正使用的颜色）必须过 ≥4.5:1——上面 textPairs 那组已经钉住这一对
    //      本身，这里再点名一次，把「为什么选它」的理由和数字绑在一起。
    //   3. clay 至少仍要过非文本 ≥3:1——hover 的边框/`clay-soft` 底色仍然靠它。
    suite(
        "contract: clay 亮色够不到正文 ≥4.5:1，所以 drop-zone hover 文案改用 text-2（2026-07-11 决议，AudioDropZoneView.promptLabel 已落地，绝不回退到 clay）"
    ) {
        let clayLightRatio = contrastRatio(ClaudioColorHex.clayLight, ClaudioColorHex.panelLight)
        expect(
            clayLightRatio >= 3.0,
            "clay 亮色至少必须过非文本 ≥3:1（drop-zone 的边框/字形仍然用它），got \(clayLightRatio)")
        expect(
            clayLightRatio < 4.5,
            "如果 clay 亮色已经 ≥4.5:1（实测 \(clayLightRatio)），说明品牌色被调过了 —— 「clay 够不到"
                + "正文门槛，所以 promptLabel 改用 text-2」这条决议的前提没了，请回来重新决策，不要让"
                + "这条断言自动失效")
        let promptLabelRatio = contrastRatio(ClaudioColorHex.text2Light, ClaudioColorHex.panelLight)
        expect(
            promptLabelRatio >= 4.5,
            "AudioDropZoneView.promptLabel 恒用的 text-2 必须真的过正文 ≥4.5:1 门槛，got"
                + " \(promptLabelRatio) —— 这是决议能成立的另一半：不只是「clay 不行」，还得"
                + "「换上的颜色真的行」")
    }

    // MARK: - 控件行的品牌填充（DESIGN.md「控件行」·「对比度」/ PLAN-MASTER-VOLUME.md D4 + D25 ①）
    //
    // 亮色那一对上面已经有了（`clayLight` vs `panelLight`，但它是挂在 drop-zone 那条决议下的）；
    // 暗色一直缺一条**专名**断言 —— D25 ① 要补的就是这个不对称。第一个控件行（`MasterVolumeRow`
    // 的 `Slider.tint(clay)`）已落地，账在此清。
    //
    // **它今天能捕获什么，诚实说清楚（别把它当成比实际更强的护栏）**：
    //
    // - **不是**「clay 被改坏」的第一道防线。`ClaudioColorHex.swift` 里 `notificationDark = clayDark`
    //   是**字面别名**（同一个常量），所以 `nonTextPairs` 里那条 "Notification dark glyph vs panel"
    //   算的是**同两个 hex**：clay 一旦被调坏，那条与这条会同时红，这条并不更早、也不更灵。
    // - **是**两件别的事：① 补上暗色缺的那条专名断言，与亮色对称 —— 「滑块填充对面板 ≥3:1」这条
    //   规则从此在两个主题下各有一个**以自己的名字**存在的守卫；② 万一将来有人把 `notificationDark`
    //   与 `clayDark` 解耦（事件色与品牌色本就是两个概念，只是今天恰好同值），那条别名断言就不再
    //   覆盖 clay 了 —— 那一刻这条是**唯一**还钉着控件行填充色的断言。
    //
    // ☠️ **它捕获不了的那个真回归**：有人删掉 `.tint(clay)` → 填充退回系统强调色（用户可把强调色设成
    // 红，而真红只许给真错误）。本 suite 是纯 hex 数学，`ClaudioGUICore` 连 SwiftUI 都不 link，
    // **结构上看不见 NSSlider 实际填了什么色**。那条规则的守门人是**人**：DESIGN.md「控件行」与
    // PLAN-MASTER-VOLUME.md §5.2 走查清单第 ⑨ 条（把系统强调色改成红 → 开面板 → 看填充段），
    // **每次动控件行都必须重跑**。别让这条绿灯冒充那条覆盖。
    suite("contract: 控件行的 clay 填充对面板过非文本 ≥3:1 —— 暗色专名一对（D25 ①，亮色见上方 drop-zone 那条）") {
        let clayDarkRatio = contrastRatio(ClaudioColorHex.clayDark, ClaudioColorHex.panelDark)
        expect(
            clayDarkRatio >= 3.0,
            "clay 暗色填充（`MasterVolumeRow` 的 Slider `.tint`，以及一切未来控件行的品牌填充）必须过"
                + "非文本 ≥3:1，got \(clayDarkRatio) —— 它是图形不是文字，判 WCAG 1.4.11")
    }

    runCompositedBackgroundSuites()
}

// MARK: - 复合底色：半透明底必须先合成再量（/ship 评审修复②）
//
// `ContrastSuite` 过去断言的是「事件字形 vs 纯 `panel`」，可字形实际画在
// `RoundedRectangle.fill(事件色.opacity(0.15))` 的 tile 上——**它断的那一对恰好是能过的那一对**。
// 真实渲染的那一对（字形 vs「事件色 15% 覆在 panel 上」的复合色）亮色下 Stop = 2.75:1、
// StopFailure = 2.82:1，双双不过 ≥3:1。
//
// 中间走过一条错路，**已推翻**，教训写在这里免得再走一遍：当时的修法是把 tile 底从自染改成中性的
// `surface-2`。它让「字形 ≥3:1」全绿了——代价是 tile 在亮色下**根本不存在**：`surface-2` `#FFFDF7`
// 对 `panel` `#FFFDF8` = **1.0006:1**，同一个颜色。字形其实直接落在面板上，「过了」是因为 tile 没了，
// 而 DESIGN.md 的行结构明写「事件字形 tile 24pt, **事件色**, 圆角6」。
//
// 现在的决议（2026-07-11 授权）：tile **保持事件色 15% 自染**（忠于 DESIGN.md），改为**调深两个亮色
// 事件色**（Stop `#288B43`、StopFailure `#AC6900`，见 ``ClaudioColorHex``）来满足 ≥3:1。
//
// 这一节因此做四件事：
//   1. 把 ``compositedHex(_:over:alpha:)`` 本身钉死（它是所有半透明底的量尺；量尺错了，下面每一条
//      基于它的断言都会给出「合理而错误」的结论）；
//   2. 对**真实渲染的那一对**下 ≥3:1：`contrastRatio(事件色, compositedHex(事件色, over: panel, 0.15))`
//      —— 明暗 × 五事件 = 10 对；
//   3. **可见性护栏**：tile 底自己对面板必须 ≥1.10:1 —— 光看字形对比度达标是不够的，tile 还得**看得见**。
//      上一轮正是漏了这一点才把 tile 弄没了；
//   4. **反向断言**：`surface-2` 当 tile 底会掉到 1.0006:1，远低于那条 1.10 的下限 —— 把那条错路
//      钉成一个会红的事实，而不是一句注释。
@MainActor
private func runCompositedBackgroundSuites() {
    suite("compositedHex: alpha 0.5 的白覆在黑上 = 808080（gamma 空间逐通道混合，与 CoreGraphics 一致）") {
        expect(
            compositedHex("FFFFFF", over: "000000", alpha: 0.5) == "808080",
            "got \(String(describing: compositedHex("FFFFFF", over: "000000", alpha: 0.5)))")
    }

    suite("compositedHex: alpha 边界 —— 1.0 就是前景本身，0.0 就是背景本身") {
        expect(
            compositedHex("FF0000", over: "00FF00", alpha: 1.0) == "FF0000",
            "alpha 1.0 必须原样返回前景")
        expect(
            compositedHex("FF0000", over: "00FF00", alpha: 0.0) == "00FF00",
            "alpha 0.0 必须原样返回背景")
    }

    suite("compositedHex: 失败关闭 —— 畸形 hex / 越界 alpha 一律 nil，绝不返回一个「看着合理」的错误颜色") {
        expect(compositedHex("nope", over: "000000", alpha: 0.15) == nil, "畸形前景必须 nil")
        expect(compositedHex("FFFFFF", over: "#GGGGGG", alpha: 0.15) == nil, "畸形背景必须 nil")
        expect(compositedHex("FFF", over: "000000", alpha: 0.15) == nil, "3 位简写必须 nil")
        expect(compositedHex("FFFFFF", over: "000000", alpha: 1.5) == nil, "alpha > 1 必须 nil")
        expect(compositedHex("FFFFFF", over: "000000", alpha: -0.1) == nil, "alpha < 0 必须 nil")
    }

    suite("compositedHex: 符号前缀 token（\"+FFFFF\"）也必须失败关闭 —— 与 contrastRatio 同一套守卫") {
        // 和 `ContrastHexParsingSuite` 钉 `contrastRatio` 的是同一个变异体：`UInt32("+FFFFF", radix: 16)`
        // 解析成功（0x0FFFFF），会交回一个完全合理、也完全错误的颜色。`compositedHex` 有它自己的一份
        // 同形状守卫（文件所有权不允许把 `ContrastRatio.swift` 的那份提取出来复用），所以两份都得钉：
        // 谁松了都会红。
        expect(compositedHex("+FFFFF", over: "000000", alpha: 0.5) == nil, "前景的符号前缀必须失败关闭")
        expect(compositedHex("000000", over: "+FFFFF", alpha: 0.5) == nil, "背景的符号前缀必须失败关闭")
    }

    suite("compositedHex: 合法的 6 位 token 仍然正常合成（守卫不能把真颜色一起拒了）") {
        // 反方向：一个「一律返回 nil」的变异体会通过上面所有失败关闭用例——这条杀掉它。
        expect(
            compositedHex(ClaudioColorHex.stopLight, over: ClaudioColorHex.panelLight, alpha: 0.15) != nil,
            "真 token + 合法 alpha 必须合成出结果，不能被守卫误杀")
    }

    // MARK: 事件字形 tile —— `EventRowView.glyphTile` / `previewButtonBody` **真实渲染**的那一对
    //
    // tile 底 = `事件色.opacity(0.15)` 覆在 `panel` 上的复合色，字形 = 100% 的同一个事件色。
    // 自染底把前景和背景往同一个色相上拉，是这套体系里最苛刻的一对（比对纯 panel 难得多），
    // 所以两个亮色事件色为它专门调深过；见 ``ClaudioColorHex/stopLight``。
    //
    // 这 10 条断言取代了上一版那条「自染底**不满足** ≥3:1」的反向护栏——那条护栏当时是为了防止 tile
    // 改回自染，而自染现在才是正确实现（DESIGN.md 要求 tile 是事件色），前提整个反了过来。
    struct SelfTintedTilePair {
        let name: String
        let glyph: String
        let panel: String
    }

    let tilePairs: [SelfTintedTilePair] = [
        SelfTintedTilePair(name: "TaskStart dark", glyph: ClaudioColorHex.taskStartDark, panel: ClaudioColorHex.panelDark),
        SelfTintedTilePair(name: "TaskStart light · 糖果盘最深底", glyph: ClaudioColorHex.taskStartLight, panel: ClaudioColorHex.panelDeepLight),
        SelfTintedTilePair(name: "Stop dark", glyph: ClaudioColorHex.stopDark, panel: ClaudioColorHex.panelDark),
        SelfTintedTilePair(name: "Stop light · 糖果盘最深底", glyph: ClaudioColorHex.stopLight, panel: ClaudioColorHex.panelDeepLight),
        SelfTintedTilePair(name: "StopFailure dark", glyph: ClaudioColorHex.stopFailureDark, panel: ClaudioColorHex.panelDark),
        SelfTintedTilePair(name: "StopFailure light · 糖果盘最深底", glyph: ClaudioColorHex.stopFailureLight, panel: ClaudioColorHex.panelDeepLight),
        SelfTintedTilePair(name: "Notification dark", glyph: ClaudioColorHex.notificationDark, panel: ClaudioColorHex.panelDark),
        SelfTintedTilePair(name: "Notification light · 糖果盘最深底", glyph: ClaudioColorHex.notificationLight, panel: ClaudioColorHex.panelDeepLight),
        SelfTintedTilePair(name: "SubagentStop dark", glyph: ClaudioColorHex.subagentStopDark, panel: ClaudioColorHex.panelDark),
        SelfTintedTilePair(name: "SubagentStop light · 糖果盘最深底", glyph: ClaudioColorHex.subagentStopLight, panel: ClaudioColorHex.panelDeepLight),
    ]

    for pair in tilePairs {
        suite(
            "contrast: \(pair.name) 事件字形对「事件色 @15% 覆在 panel 上」的自染 tile 复合底 ≥ 3:1"
                + "（glyphTile / previewButtonBody 真实渲染的那一对，WCAG 1.4.11）"
        ) {
            guard let composited = compositedHex(pair.glyph, over: pair.panel, alpha: 0.15) else {
                expect(false, "\(pair.name): 复合底色算不出来，断言无从谈起")
                return
            }
            let ratio = contrastRatio(pair.glyph, composited)
            expect(
                ratio >= 3.0,
                "\(pair.name): 字形 \(pair.glyph) 对自染复合底 \(composited) 只有 \(ratio):1 —— "
                    + "这是 tile 上**真实**的那一对（不是对纯 panel 的那一对，别再断错了）。"
                    + "两条修法只有一条是对的：调深这个亮色事件色（历史修法，见 ClaudioColorHex）；"
                    + "把 tile 底换成中性色**不行**——tile 会在亮色下整个消失，见下面的可见性护栏")
        }
    }

    // MARK: 可见性护栏 —— tile 底自己必须对面板可见（上一轮退化的教训，钉死）
    //
    // 「字形对底 ≥3:1」达标 **不等于** tile 存在。上一轮把 tile 底改成 `surface-2` 就是靠 tile 在亮色下
    // 消失（`#FFFDF7` vs `#FFFDF8` = 1.0006:1，同一个颜色）来「达标」的：字形其实直接落在了面板上，
    // 一块 DESIGN.md 明确要求存在的 24pt 事件色 tile 被静悄悄地量没了，而所有断言全绿。
    //
    // 所以对比度这件事有**两个**方向，缺一不可：字形要从底上跳出来（≥3:1），底也要从面板上跳出来
    // （这条：≥1.10:1；五事件明暗实测均过门槛，亮色约 1.18–1.23）。1.10 是一条「肉眼能分辨出这里有块
    // 色板」的经验下限，不是 WCAG 的门槛（WCAG 根本不管装饰性表面），它的作用是：任何把 tile 底往面板
    // 色上拉平的改动，都必须先来改这条数字，而不是默默地让 tile 消失。
    for pair in tilePairs {
        suite("可见性护栏: \(pair.name) 的自染 tile 底对 panel ≥ 1.10:1 —— tile 必须真的看得见，不能被「量没了」") {
            guard let composited = compositedHex(pair.glyph, over: pair.panel, alpha: 0.15) else {
                expect(false, "\(pair.name): 复合底色算不出来，断言无从谈起")
                return
            }
            let ratio = contrastRatio(composited, pair.panel)
            expect(
                ratio >= 1.10,
                "\(pair.name): tile 底 \(composited) 对面板 \(pair.panel) 只有 \(ratio):1 —— tile 正在"
                    + "消失。DESIGN.md 行结构要求「事件字形 tile 24pt, 事件色, 圆角6」：一块看不见的"
                    + " tile 不是 tile。（若是把 opacity 从 0.15 调低导致的，请连同 EventRowView 一起改，"
                    + "并重新验证上面那组 ≥3:1）")
        }
    }

    // 反向断言：把那条**已被推翻**的错路钉成一个会红的事实，而不是一句会被忽略的注释。
    // 如果有人再次「用 surface-2 当 tile 底」，他会先撞上这一条：那个底连 1.10 都够不到。
    suite("反向护栏: surface-2 当 tile 底 = tile 消失 —— 亮色对 panel 仅 ~1.0006:1，远低于 1.10 的可见性下限") {
        let lightRatio = contrastRatio(ClaudioColorHex.surface2Light, ClaudioColorHex.panelLight)
        expect(
            lightRatio < 1.10,
            "surface-2 亮色对 panel 量到 \(lightRatio):1 —— 如果它现在 ≥1.10，说明这两个 token 之一被"
                + "改过了，「surface-2 当 tile 底会消失」这条历史结论的前提变了；请回来重新决策，不要"
                + "默默让这条护栏失效（tile 该不该是事件色，仍然是 DESIGN.md 说了算）")
        expect(
            lightRatio < 1.01,
            "记录当年那个具体的数字：surface-2 `#FFFDF7` 和 panel `#FFFDF8` **就是同一个颜色**"
                + "（实测 \(lightRatio):1，远不止「对比度偏低」，是压根没有对比度）")
    }
}
