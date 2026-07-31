import ClaudioGUICore
import Foundation

// MARK: - `ClaudioGUI` 这个 target，harness 一行都跑不到（T17 实测）
//
// `claudio-gui-tests` 只依赖 `ClaudioGUICore` + `ClaudioCore`。`ClaudioGUI` 是一个带 `@main` 的
// **executableTarget**，Swift 里没法 `import` 它。所以整棵 SwiftUI 视图树上的每一行接线，对这套
// 测试都是**不可见的**。评审实测了两次变异，两次都全绿：
//
//   ① 删掉 `PanelView` 里那句 `.onChange(of: onboardingViewModel.state) { refresh(); … }`
//      —— 也就是让「接管成功」真正兑现的那一行 —— `✓ all 652 checks passed`，release 构建零告警。
//   ② 把 `actionRunner` 改回可选 + 默认 nil + 静默 `guard let … else { refresh(); return }`，
//      并删掉 `PanelView` 那边的接线（= 逐字重建 T17 之前那个死 CTA）—— `✓ all 652 checks passed`。
//
// **两次变异都重新制造了这次提交要修的那个 bug，而绿灯一次都没灭。**
//
// 真正的结构修法是把视图层拆成一个可被 import 的 library target（或引入 ViewInspector）—— 那是一次
// 独立的重构，不该跟一次 bugfix 混在一起（已记入 TODOS）。在那之前，这个 suite 是**唯一存在的护栏**：
// 它读源码文本。
//
// ⚠️ **诚实标注：这是文本绊线，不是行为测试。** 它证明不了那行代码**做对了**，只能证明它**还在**。
// 一个把 `.onChange` 改成 `.onChange(of: config)` 的改动照样能骗过它。它挡的是「顺手删掉 / 重构时
// 漏掉」这一类，而那恰恰是上面两次变异的形状。`ReleaseLayoutSuite` 已经为 release.yml 立下了同样的
// 先例：一个可执行的 harness 读得了文件，那就用它读。

/// 仓库根 —— 从 `#filePath` 推（编译期常量，不依赖 cwd）。
private func repoRoot(file: StaticString = #filePath) -> URL {
    URL(fileURLWithPath: "\(file)")
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
}

@MainActor
private func source(_ relativePath: String) -> String? {
    guard let data = try? Data(contentsOf: repoRoot().appendingPathComponent(relativePath)) else {
        return nil
    }
    return String(data: data, encoding: .utf8)
}

/// 同一个文件，被 ``strippingComments(_:)`` 扫过之后的样子（代码 + 「扫描器不认识的构造」清单）。
@MainActor
private func scan(_ relativePath: String) -> StrippedSwiftSource? {
    guard let text = source(relativePath) else { return nil }
    return strippingComments(text)
}

/// 同一个文件，**剥掉注释**之后的样子。
///
/// 这不是洁癖：本 suite 的第一版直接对整份源码做 `contains("Bundle.main")`，然后**被
/// `MenuBarController` 自己那段解释「为什么这里不该有 Bundle.main」的注释**判红了。
/// 这与它上游的 `ReleaseLayoutSuite` 第一版翻的是**同一次车**（release.yml 的散文让 grep 命中，
/// 于是那条断言永远不会红）。一次文本断言若不区分「代码」与「谈论代码的文字」，它断的就不是代码。
/// T17c：也剥**行尾**注释，不只是整行注释。上一版只判断 `hasPrefix("//")`，于是一行
/// `foo()  // 见 .onChange(of: onboardingViewModel.state)` 能同时活过过滤器**又**让 `contains()`
/// 命中 —— 真代码被删掉了，绊线照样绿。这正是本 suite 头部自陈翻过的那次车的**残留一半**：
/// 它修好了整行注释，没修行尾注释。（反向断言 `!contains("Bundle.main")` 则会被行尾注释假红。）
///
/// **同一个病的第三半**（`/codex review be332ff` 的 P3）：它此前在**每行第一个 `//`** 处无条件截断，
/// 而它不认识字符串字面量。于是一行 `let url = "https://…"; …("play.lock")` 会被剪掉后半截，
/// `play.lock` 对下面那条 `ClaudioGUICore` 普查**隐身**。helper 那边给自己配了一条守卫（还是恒真的），
/// GUI 这半边**连那条都没有**。现在剥注释的活儿交给 `TestSupport.strippingComments` —— 一个位置感知的
/// 状态机，两个包共用，字符串字面量里的 `//` 不再是注释起点；它自己的行为由 `SourceScannerSuite`
/// 喂合成输入钉死。剩下那点它不认识的（raw string），由本文件第一条 suite 盯着。
@MainActor
private func codeOnly(_ relativePath: String) -> String? {
    scan(relativePath)?.code
}

/// 同一个文件，剥掉注释**且清空字符串内容**之后的样子（界定符与插值里的代码保留）。
///
/// 需要看**代码结构**（数括号、切函数体）而不是「字符串里写了什么」的断言，必须读这一路 ——
/// `code` 里一句写着 `refresh()` 的错误消息，在 `contains("refresh()")` 眼里与一次真的调用完全同形。
/// 见 ``StrippedSwiftSource/codeWithoutStringLiterals``。
@MainActor
private func codeWithoutStrings(_ relativePath: String) -> String? {
    scan(relativePath)?.codeWithoutStringLiterals
}

/// 把连续空白（含换行、缩进）压成单个空格 —— 让文本断言对**排版**免疫。
///
/// `.swift-format` 的 `respectsExistingLineBreaks: true` 意味着 `case .full: refresh()` 既可能写成一行、
/// 也可能被人拆成两行。一条断言若要求其中一种，它守的就是排版而不是接线：下一个人换了行，它假红，
/// 然后被删掉。
///
/// ⚠️ **不是 `private`**：`SourceScannerSuite` 的锁转发腿（T3 内容围栏第四条腿）要拿同一份实现去
/// 归一化 `lockFile:` 实参。两份拷贝会漂移（一份收窄、另一份没有 ⇒ 同一段源码在两处得出不同结论），
/// 而这两个文件在同一个 target 里，去掉 `private` 就够了 —— 别为了「每个文件自带一份」再抄一遍。
func collapsingWhitespace(_ text: String) -> String {
    text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
}

/// `marker` 在 `source` 里出现几次，对空白排版（任意长度的空格、换行、块注释被剥完后补的那个
/// 空格）免疫 —— 先 ``collapsingWhitespace(_:)`` 再数子串。
///
/// ⚠️ 生产扫描与它的合成正/负控**必须**共用这一个函数，不能各自重新拼一遍「collapse 再数」——
/// 两处各写一份看起来一样的表达式，正/负控测的就只是「这个表达式抽象上对不对」，测不出「生产那
/// 一行有没有真的在调它」：把生产那行悄悄改回不 collapse 的旧版，两份各自独立的表达式各判各的，
/// 正/负控一个字都不会变，围栏本体的回归却没有任何东西喊。（`gui/Tests/ClaudioGUICoreTests`
/// `extension` 普查那一刀第一版就是这么栽的：实测把生产那行改回
/// `source.code.components(separatedBy: marker)`，2472 条检查照样全绿。）
func whitespaceTolerantHitCount(of marker: String, in source: String) -> Int {
    collapsingWhitespace(source).components(separatedBy: marker).count - 1
}

/// `marker` 之后紧跟的那个 `{ … }` 的**闭包体**（按花括号配对切出来），`nil` = 找不到 marker 或它后面
/// 没有配平的闭包。
///
/// ## 它修的那个洞（`/codex review 8771946` P1 + 变异实测）
///
/// 本 suite 的绊线全是 `contains(修饰符字面量)`。那种断言能证明**修饰符在**，证明不了**闭包体做了
/// 什么** —— 而「做了什么」恰恰是这些修饰符存在的全部理由。实测变异体：
///
/// ```swift
/// .onChange(of: focusCoordinator.hideCount) { _ in
///     // flush() 被删掉，闭包留空
/// }
/// ```
///
/// 用户拖完滑块点面板外面关掉 popover，音量**静默丢失** —— 正是守着这一行的那条断言在失败消息里
/// 亲口写下的那个 bug —— 而 1973 checks **全绿**。绊线的措辞（「必须观察 hideCount 的变化**并冲刷
/// pending 的拖动**」）比它的覆盖范围（「`.onChange(of:` 这串字符在文件里」）大了一整个闭包体。
///
/// 这是本仓库反复复发的同一种病，已有两处判例记在案：`PanelRefreshRoute.swift:17`（把「静音失败必须
/// 全量 refresh」钉成 `contains("refresh()")`，而 `refresh()` 在那个文件里出现 37 次，那个合取子恒真）
/// 与本文件 ``sourcesUnder(_:)`` 的 T17h（措辞说「全 GUI」，范围只有一个文件）。所以这个 helper 是
/// **围栏**不是探针：切不出闭包体就返回 `nil`，调用方一律判红 —— 「我看不懂这段代码」绝不等于「这段
/// 代码是对的」。
///
/// 必须喂 ``codeWithoutStrings(_:)`` 的输出，不能喂 ``codeOnly(_:)``：后者保留字符串**内容**，一句写着
/// `flush()` 的错误消息在 `contains("flush()")` 眼里与一次真的调用完全同形。
private func closureBody(after marker: String, in source: String) -> String? {
    guard let markerRange = source.range(of: marker) else { return nil }
    var depth = 0
    var body = ""
    for ch in source[markerRange.upperBound...] {
        if ch == "{" {
            depth += 1
            if depth == 1 { continue }  // 最外层的开括号本身不算体
        }
        if ch == "}" {
            depth -= 1
            if depth == 0 { return body }  // 配平：闭包体到此为止
        }
        if depth >= 1 { body.append(ch) }
    }
    return nil  // 没配平（marker 后面根本没有闭包，或文件被截断）—— 围栏判红，不判绿
}

/// `marker` 所在位置的花括号嵌套深度。输入必须是 ``codeWithoutStrings(_:)`` 的结果。
///
/// T7 的 `.manageSounds` 双向诚实性不能只靠「出现一次 + 相对顺序」：把
/// `manageSoundsRow` 包进 `if !packCards.isEmpty { … }`，或把 `order.append(.manageSounds)`
/// 包进同型条件，字面量与先后顺序一个都没变，却会让零行面板再次出现幽灵焦点。层级与所在
/// `switch`/`case` 相同，才证明它没有被一个额外的 `if`/`switch`/`ForEach` 花括号条件化。
private func braceDepth(of marker: String, in source: String) -> Int? {
    guard let markerRange = source.range(of: marker) else { return nil }
    var depth = 0
    for ch in source[..<markerRange.lowerBound] {
        switch ch {
        case "{":
            depth += 1
        case "}":
            depth -= 1
            if depth < 0 { return nil }
        default:
            break
        }
    }
    return depth
}

/// `ClaudioGUI` target 下**每一个** Swift 源文件，剥掉注释之后的样子 —— `(文件名, 代码)`。
///
/// ## 它修的那个洞（T17h —— `/codex review a3c2d08` 独立评审逮到）
///
/// 上一版那条断言的**措辞**是「全 GUI 只许有一处 `NSAccessibility.post`」，它守的**范围**却是
/// `PanelView.swift` **一个文件**：
///
/// ```swift
/// expect(panel.components(separatedBy: "NSAccessibility.post").count - 1 == 1, "全 GUI 只许有一处…")
/// //     ^^^^^ 只有 PanelView.swift
/// ```
///
/// 于是在 `MenuBarController.swift` / `PackGalleryView.swift` / `OnboardingView.swift` 里加第二处
/// post —— 换完包顺手补一句「已切换到 X」，正是 ``PanelView/say(_:)`` 的文档亲口点名**最诱人**的那条路
/// —— 测试全绿，而那条 post 会截断用户还没听完的那句「你的包被换掉了」。T17g 的提交信息把这条断言
/// 写成「全 GUI 只剩一处 NSAccessibility.post，**由 ViewWiringSuite 数着**」：后半句当时是虚的。
///
/// 目录读不到 / 一个文件都数不到，必须**变红**，而不是安静地数出 0 —— 一个数不到任何文件的计数器
/// 永远等不到 1，它会一直绿下去。这与本文件头部那条「一次文本断言若不区分代码与谈论代码的文字，
/// 它断的就不是代码」是同一种病：一条永远不会红的断言，不是护栏。
/// 一个被扫过的源文件：路径、剥掉注释的代码、以及扫描器**自己不认识**的那些构造。
///
/// `unmodeled` 不是装饰：它非空 = `code` 不可信，而本文件的兜底全是负向断言（不可信的文本只会
/// 让它们更绿）。第一条 suite 就盯着它。
private typealias ScannedSource = (path: String, code: String, unmodeled: [String])

@MainActor
private func sourcesUnder(_ relativeRoot: String) -> [ScannedSource] {
    let root = repoRoot().appendingPathComponent(relativeRoot)
    guard let walker = FileManager.default.enumerator(atPath: root.path) else { return [] }
    var found: [ScannedSource] = []
    for case let name as String in walker where name.hasSuffix(".swift") {
        guard let scanned = scan("\(relativeRoot)/\(name)") else { continue }
        found.append((path: name, code: scanned.code, unmodeled: scanned.unmodeledConstructs))
    }
    return found.sorted { $0.path < $1.path }
}

@MainActor
private func guiSources() -> [ScannedSource] {
    sourcesUnder("gui/Sources/ClaudioGUI")
}

/// 从 `lockLeaks` 普查里豁免的文件（**文件级单源**）。
///
/// ⚠️ 提到文件级不是为了复用，是为了让「每个豁免项都换来一条更严的锚定绊线」这句散文有一条
/// **可执行**版本：下面那条 suite 会断言这张表减去 `PanelView.swift` 之后，**逐项等于**
/// `expectedProductionLocks` 的文件集。上一版两张清单各自硬编码、互不绑定 —— 往这里加第四项
/// 而对价一条不写，普查静默少查一个文件、全绿、没有人会喊（`/review d7084be` 红队 P2 坐实）。
///
/// `PanelView.swift` 的豁免理由与另外两项不同（它是三把锁**唯一**允许的来源，由本文件那条
/// 「PanelView 构造 OnboardingActionEnvironment 的三把锁逐个按调用点绑」守着），所以它在
/// 那条相等判定里被单独减掉 —— 减的是**它一个**，不是「随便谁都能豁免」。
private let lockCensusExemptedFiles = [
    "PanelView.swift", "ClaudioGUIApp.swift", "StateGalleryView.swift",
]

/// 上一条里被单独减掉的那一个 —— 提成常量，免得相等判定里出现一个没人解释的字面量。
private let lockCensusSelfGuardedFile = "PanelView.swift"

/// 生产侧**每一处** `AudioImportEnvironment(…)` 构造点，连同它那把包锁应有的实参（**文件级单源**）。
///
/// ⚠️ 提到文件级的理由与 ``lockCensusExemptedFiles`` 逐字相同，只是又晚了一轮：这张表现在同时喂
/// **三**条断言 —— 豁免绑定（集合相等）、逐调用点的实参锚定、以及下面那条**构造点普查**。
/// `/codex review 51aebae,7caf6dc,e278736` 的 P1-B 坐实：它上一版是 suite 内部的局部 `let`，
/// 于是「生产侧两个构造点」这句话在整个仓库里**没有任何东西在数**——往 `ClaudioGUICore` 放一个
/// 就地算锁的第三个构造点（`packsLockFile: packDirectory.appendingPathComponent("packs.lock")`），
/// 编译通过、**2456 条检查全绿**、一条都不红（隔离 worktree 实测，不是推理）。
/// 再写第四张各自硬编码的清单就是同一个病第三次复发，所以从这里开始只有这一份。
///
/// `file` 是 **basename**；普查那条把它拼成 `ClaudioGUI/<file>` 去与实得的键比。那个前缀是硬编码的，
/// 而这正是要的极性：某天 `ClaudioGUICore` 里合法长出一个构造点，实得的键会是
/// `ClaudioGUICore/<file>`、与期望集合不等 ⇒ **红** ⇒ 有人必须来想清楚「lockLeaks 只扫
/// `ClaudioGUI`，那个新文件由谁守」。fail-closed，不是遗漏。
private let expectedProductionLocks: [(file: String, value: String, literal: String?, why: String)] = [
    (
        "ClaudioGUIApp.swift", "ClaudioPaths.packsLockFile", nil,
        "组装根是全 app 唯一该说出真实路径的地方。它若变成别的，两个 manifest.json 写者"
            + "（接管发布内置包走 helper 的 `performFirstRunSetup`、绑定/解绑走 "
            + "`mutateManifestJSON`）就不再是同一把 `flock`，跨进程互斥当场断开"
    ),
    (
        "StateGalleryView.swift", "URL(fileURLWithPath: \"\")",
        "/dev/null/claudio-preview-packs.lock",
        "preview 用一条**永不解析**的占位路径（`/dev/null/…`，字符串内容由下面那条单独钉）。"
            + "它若变成 `ClaudioPaths.packsLockFile`，一个 SwiftUI preview 就有了去碰用户 home "
            + "上那把锁的能力 —— 而 preview 是 `#if DEBUG` 里的代码，没有任何行为测试跑它"
    ),
]

/// `ClaudioGUICore` target 下每一个源文件 —— 上面那个 `guiSources()` **看不见**的那一半 GUI。
///
/// 它存在的理由（`/review e7c38ea` 的 P1，变异实测）：接管路径的锁要过四手，而**中间那一手**
/// （`OnboardingActions.swift:589-596`，把 `OnboardingActionEnvironment` 的两把锁灌进
/// `SetupEnvironment`）住在 `ClaudioGUICore` 里 —— `guiSources()` 只扫 `gui/Sources/ClaudioGUI`，
/// `LockSeparationSuite` 只 `codeOnly("helper/…")`，于是这个 target **两套绊线都看不到**。
///
/// 把 `OnboardingActions.swift:595` 的 `configLockFile: environment.configLockFile` 改成
/// `configLockFile: ClaudioPaths.playLockFile` —— 用户点下「接管」之后那几秒，config.json 的写占住
/// `play` 的去抖锁，他的每一声提示音被静默吞掉 —— **1064 + 1607 全绿，零红**。
///
/// ⚠️ 这里只立**负向**兜底（不许出现 play 的去抖锁）。真正把「谁守谁」钉死的是
/// `OnboardingActionsSuite` 那四条**持锁行为断言** —— 它们绑的是真实锁文件路径，成对交换、
/// 值级假名、三元表达式、大小写差一个字母，在它们面前全部当场变红。这一条只是**便宜的第二道**：
/// 行为断言够不到的地方（比如将来 `ClaudioGUICore` 里长出第三个写者、而没人给它写行为测试），
/// 至少 play.lock 这条最要命的路是堵死的。
@MainActor
private func guiCoreSources() -> [ScannedSource] {
    sourcesUnder("gui/Sources/ClaudioGUICore")
}

@MainActor
func runViewWiringSuites() {
    suite("扫描器的前提：ClaudioGUI / ClaudioGUICore 里没有一处它自己不认识的构造") {
        // ## GUI 这一半此前**一条守卫都没有**（`/codex review be332ff` 的 P3）
        //
        // 本文件下面的兜底全是**负向**断言（除 PanelView 外不许出现锁、ClaudioGUICore 里不许出现
        // `play.lock`、全 target 只许一处 `NSAccessibility.post`）。它们共享同一个失效模式：
        // **分析文本里少一段代码，它们只会更绿。**
        //
        // 上一版 `codeOnly` 在每行第一个 `//` 处无条件截断，不认识字符串字面量。于是
        //
        // ```swift
        // let url = "https://claudio.dev/locks"; let lock = ClaudioPaths.root.appendingPathComponent("play.lock")
        // ```
        //
        // 会被剪掉后半截 —— `play.lock` 对新增的 `ClaudioGUICore` 普查**隐身**。helper 那边给自己配了
        // 一条守卫（`be332ff`），可惜那条守卫检查的是**截断之后**的文本，`://` 自带 `//`，它**恒真**；
        // 而 GUI 这半边连那条恒真的都没有。两半的洞现在一起堵：剥注释交给两个包共用的
        // `TestSupport.strippingComments`（位置感知，字符串里的 `//` 不再是注释起点，行为由
        // `SourceScannerSuite` 喂合成输入钉死），剩下它不建模的 raw string 由这条盯着。
        //
        // 位置感知是必须的：`ClaudioColorHex.swift:206` / `ContrastRatio.swift:27` 里的
        // `hasPrefix("#")` 逐字包含 `#"` —— 一条纯文本的 `#"` 守卫会在它们身上当场假红，然后被
        // 下一个人删掉，洞原样回来。
        let scanned = guiSources() + guiCoreSources()
        expect(
            scanned.count >= 10,
            "两个 target 加起来一个 Swift 文件都没数到（实得 \(scanned.count)）—— 这条是**普查**，"
                + "普查不到任何文件就永远等不到红，只会安静地绿下去")
        var unmodeled: [String: [String]] = [:]
        for file in scanned where !file.unmodeled.isEmpty {
            unmodeled[file.path] = file.unmodeled
        }
        expect(
            unmodeled.isEmpty,
            "这些文件里出现了扫描器不建模的词法构造：\(unmodeled) —— 它剥出来的「代码」从此不可信，"
                + "而本文件的兜底全是负向断言：一段被误判成字符串 / 注释而消失的代码只会让它们**更绿**，"
                + "一句藏在里面的 `ClaudioPaths.playLockFile` 或 `\"play.lock\"` 会对整套锁普查"
                + "**永久隐身**。要么把这个构造挪走，要么先教 `strippingComments` 认识它")
    }

    suite("T17h 播报出口全 target 只此一个 —— 数的是整个 ClaudioGUI，不是一个文件") {
        let sources = guiSources()
        expect(
            sources.count >= 5,
            "在 gui/Sources/ClaudioGUI 下一个 Swift 文件都没数到（实得 \(sources.count)）。"
                + "这条断言存在的全部意义就是去数那些文件 —— 数不到，它就永远等不到 1，安静地绿下去")
        expect(
            sources.contains { $0.path.hasSuffix("PanelView.swift") },
            "PanelView.swift 必须在名册里 —— 唯一那处 post 就住在它的 say(_:) 里")

        var posts: [String: Int] = [:]
        var consumes: [String: Int] = [:]
        for file in sources {
            let postCount = file.code.components(separatedBy: "NSAccessibility.post").count - 1
            let consumeCount = file.code.components(separatedBy: "announcer.consume(").count - 1
            if postCount > 0 { posts[file.path] = postCount }
            if consumeCount > 0 { consumes[file.path] = consumeCount }
        }

        expect(
            posts == ["PanelView.swift": 1],
            "全 GUI 只许有**一处** NSAccessibility.post（PanelView 的 say(_:) 里）。第二处 post = 第二条"
                + "抢「一次一句」通道的话 —— 它会当场截断用户可能还没听完的那条告知。上一版这条断言只数"
                + " PanelView 一个文件，措辞却写着「全 GUI」：在 MenuBarController / PackGalleryView 里"
                + "加一处，它绿得毫无察觉。实得 \(posts)")
        expect(
            consumes == ["PanelView.swift": 1],
            "去重器也只许有一个调用点，理由一字不差 —— 绕过它 = 把「同一趟里 post 两条」放回来。"
                + "实得 \(consumes)")
    }

    suite("PanelView 仍然在 state 变化时重跑 refresh()（否则「接管成功」的那一秒面板是骗人的）") {
        guard let panel = codeOnly("gui/Sources/ClaudioGUI/PanelView.swift") else {
            expect(false, "读不到 PanelView.swift —— 这个 suite 唯一的价值就是读它")
            return
        }
        expect(
            panel.contains(".onChange(of: onboardingViewModel.state)"),
            "PanelView 必须在 onboarding state 变化时重跑自己的 refresh()。没有它：CTA 成功 → state 翻到"
                + " .installed → body 切到 operationalPanel，而 panelModel 的 config/eventRows/packCards/"
                + "selectedPackMetadata 仍是 app **启动时**（= setup 之前）读的盘 —— 用户在接管成功的"
                + "那一秒看到的是四行「未配置 / 文件丢失」+ 空画廊/空包名，真实的包和 config 明明已经"
                + "写好在磁盘上了。"
                + "评审实测：删掉这一行，652 项测试全绿。")
        expect(
            panel.contains("bundledHelperBinary: bundledHelperBinary"),
            "PanelView 必须把 bundle 里的 helper 路径传进 OnboardingActionEnvironment")
        expect(
            panel.contains("DiskOnboardingActionRunner(environment:"),
            "PanelView 必须真的把生产 runner 接给 view-model —— 这是整个 T17 的接线点")

        // T17c：两个渲染点都必须**无条件**画「此刻有没有失败」。
        expect(
            panel.contains("onboardingVisibleFailure(actionState:"),
            "运行态面板必须渲染任何失败，不只是断开的 —— 一次接管失败完全可能在 refresh() 之后落在"
                + " .installed（点「修复」→ 撞上 config.lock / settings.lock → 失败，但二进制和 hooks 都在位），"
                + "那时 onboarding 卡根本不在屏幕上。上一版这里只认 branch: .disconnect，"
                + "于是那条失败一个像素都没有：绿点、静音、零诊断")

        // T17f：**这条比上面那条更要命。** 告知只从一次成功的接管而来，而成功必然把 state 推成
        // `.installed` —— 也就是说**每一条告知都诞生在这个面板上**，onboarding 卡那一侧永远接不住。
        // 这一行没了，就等于回到修复前：用户的包被换掉、目录被搬走，面板一声不吭。
        expect(
            panel.contains("onboardingVisibleNotices(actionState:"),
            "运行态面板必须渲染「我替你做主」的告知 —— 一次成功的接管必然落在 .installed，所以这里"
                + "是告知**唯一**的家。上一版这里一行都没有，于是 T17e 立下的『替他换上，并如实说"
                + "出来』只对开终端的人成立，而命中这条路径的恰恰是点面板「接管 / 修复」的那个用户")
        expect(
            panel.contains("ActionNoticeRow("),
            "光调纯函数不够 —— 面板得真的把它画成一行（⚠ 暖琥珀，不是真红：setup 成功了）")

        // T17f 自评审：**文案里那句「下面的声音包」是一句关于布局的断言，这里把它兑现。**
        //
        // 第一版把提示行放进了 `disconnectRow`，而 `disconnectRow` 排在 `PackGalleryView` **之后** ——
        // 于是那句话下面唯一的东西是「断开连接」那颗破坏性按钮：我们把一个刚被替换了选包、正想换回去
        // 的用户，一句话指向了卸载键。没有任何测试为此变红（一句指错方向的话，编译器不管，
        // `onboardingVisibleNotices` 也照样返回非空）。
        //
        // 这条断言是**顺序**断言：ActionNoticeRow 必须出现在 PackGalleryView **之前**。
        // 把提示行挪到画廊下方 = 把文案变成谎话 = 这里变红。
        if let noticeAt = panel.range(of: "ActionNoticeRow(")?.lowerBound,
            let galleryAt = panel.range(of: "PackGalleryView(")?.lowerBound
        {
            expect(
                noticeAt < galleryAt,
                "告知行必须排在声音包画廊**之前** —— 文案白纸黑字写着「你随时可以在**下面的**声音包里"
                    + "换成别的」。挪到画廊之后，那句话下面就只剩「断开连接」了：一个想换回自己包的用户，"
                    + "会被这句话指向卸载键。要改位置，先改文案")
        } else {
            expect(false, "PanelView 里必须同时有 ActionNoticeRow 与 PackGalleryView")
        }
        expect(
            !panel.contains("onboardingFailureBelongsHere"),
            "按 action 分派失败的那个函数已经删了（T17c）—— 它默认「哪个动作失败」与「失败之后 state"
                + "落在哪」是同一件事，而 runDiskAction 在失败后无条件重新探测磁盘")
        // T17d：面板的可见 / 隐藏**两个**信号都必须接进 view-model。
        expect(
            panel.contains("onboardingViewModel.panelDidBecomeVisible()"),
            "面板可见时必须通知 view-model —— 一条**已经被看过**的失败在这里被忘掉（T17c 那条"
                + "「陈旧失败不该永久挂在一张已经装好的面板上」的顾虑仍然成立）")
        expect(
            panel.contains(".onChange(of: focusCoordinator.hideCount)")
                && panel.contains("onboardingViewModel.panelDidHide()"),
            "面板**隐藏**也必须通知 view-model。没有这一半，view-model 只能去假定「下一次打开 ="
                + "上一条失败已经被看过」—— 而用户点完「接管」就切走时（.transient popover 当场关闭，"
                + "写盘的 Task 却不随视图销毁而取消、继续跑、失败），那条失败从头到尾一个像素都没有过，"
                + "下一次打开却会把它当成「看过了」清掉。T17d 第四轮对抗评审（Codex）实测确认。")
        expect(
            !panel.contains("clearConsumedFailure"),
            "`clearConsumedFailure()` 已经删了（T17d）—— 它无条件在面板重开时清掉当前失败，"
                + "而「重开 = 看过了」是一个**假定**，在「失败诞生于面板关闭之后」这条路径上是假的")

        // ── T17g：结果不但要画得出来，还要说得出口 ────────────────────────────────────────
        expect(
            panel.contains("let moment = onboardingViewModel.panelDidBecomeVisible()")
                && panel.contains("say(moment)"),
            "打开面板必须把 panelDidBecomeVisible() 的返回值**说出去** —— 它是「这条结果第一次露面」的"
                + "唯一真相源（outcomeHasBeenSeen 就在那个函数里被消费掉了）。T17d/T17f 把结果画出来了，"
                + "却从没说出来：VO 用户在 ActionFailureRow / ActionNoticeRow 真正出现的那一次打开里，"
                + "听到的只有一句平静的「Claudio 面板，当前声音包 X」")
        expect(
            panel.contains("say(.stateChanged)") && panel.contains("say(.actionStateChanged)"),
            "另外两个播报时刻也必须接上 —— 政策在 panelAnnouncement(_:)，视图只负责报时刻")
        expect(
            panel.contains("viewModel.announcement(")
                && panel.contains("let viewModel = onboardingViewModel"),
            "播报政策必须从 ClaudioGUICore 拿，不许在视图里再判一次 —— 它上一次住在这个文件里的时候，"
                + "「谁抢到那条一次一句的通道」押在 SwiftUI 未文档化的 onChange 顺序上，零测试守护。"
                + "（T17h：那次调用挪进了 DispatchQueue 的闭包，view-model 先取成一个局部量。**这不是因为"
                + "「闭包捕不到 self」** —— 那句话曾经写在这里，它是假的：`View` 是 @MainActor 的，PanelView "
                + "隐式 Sendable，捕得到 self，实测编得过。取局部量只是不必绕道视图去拿一个引用类型。）")
        expect(
            !panel.contains("announcePanel") && !panel.contains("announceActionState"),
            "这两个函数体里的 switch 就是播报政策，已整体下沉到 panelAnnouncement(_:)。"
                + "把任何一个放回来 = 把那场竞争放回来")

        // ── T17h：闸门与去重必须在 `DispatchQueue.main.async` 的**里面** ──────────────────────
        //
        // 「全 GUI 只许有一处 post」那两条计数断言已经搬去上面那个 suite（它数的是整个 target，
        // 而不是这一个文件 —— 那正是它上一版守不住的东西）。这里守的是**另一件事**：那一处 post
        // 与它的闸门之间，不许再隔着一趟 main queue。
        if let asyncAt = panel.range(of: "DispatchQueue.main.async")?.lowerBound,
            let announceAt = panel.range(of: "viewModel.announcement(")?.lowerBound,
            let consumeAt = panel.range(of: "announcer.consume(")?.lowerBound
        {
            expect(
                asyncAt < announceAt && asyncAt < consumeAt,
                "「该不该说」与「刚才说过没」必须在 async 闭包**里面**问。放回外面 = 那道「面板关着就一个字"
                + "都不说」的闸门问的是**上一趟**的世界，而 post 发生在下一趟：两趟之间 .transient popover "
                + "完全可能已经被一次 app 切换关掉（那正是这整条 bug 家族的主路径），而 post 的 element 是"
                    + " NSApp —— 整个 app，不是那个已经消失的 popover。用户人在 Finder 里，Claudio 朝着他"
                    + "正在用的窗口念了一句话。窗口只有一次 main queue drain 那么宽，谁都没实测到过 —— 而"
                    + "「我推理出这个格子不可达」正是这个仓库反复交学费的那句话")
        } else {
            expect(
                false,
                "PanelView 里必须同时有 DispatchQueue.main.async、viewModel.announcement( 与 "
                    + "announcer.consume( —— 三者缺一，上面那条顺序断言就无从判起")
        }
        expect(
            panel.contains("MainActor.assumeIsolated"),
            "async 闭包里那两行是 @MainActor 的（consume / announcement），得把「这个 block 跑在主线程上」"
                + "这个运行期事实交给编译器。**不许换成 Task { @MainActor in … }** —— 但**不是**因为"
                + "「那是另一条队列」（这句话曾经写在这里，它是假的：Darwin 上 MainActor 的默认 executor "
                + "正是把 job enqueue 进 main dispatch queue，并没有换队列）。真正的理由是**保证的强度**："
                + "串行队列按入队顺序 FIFO 是 libdispatch 的**文档保证**，而 Swift 并发 job 相对 dispatch "
                + "block 的入队顺序只是**实现细节** —— 「第二条必然是第一条的后缀」这条去重不变式，不该"
                + "压在实现细节上")
        expect(
            panel.contains(".onChange(of: onboardingViewModel.actionState) { _ in"),
            "必须读 view-model 的**当前值**，不许用 onChange 的 newValue —— 「同一趟里只有一个开口，"
                + "或两个说同一句」这条不变式建立在两边看到同一份快照上")

        // ── T17h′：actionState 那个 handler 必须在 say() **之前** refresh() ──────────────────────
        //
        // 它是三个 say() 调用点里唯一一个曾经**不** refresh 的。而 refresh() 写新的
        // `panelModel.selectedPackMetadata` —— 面板句里包名的唯一来源。少了它：一次**无告知的成功接管**，若 SwiftUI
        // 先跑这个 handler（**未文档化**的顺序），它算 header 时 `onboardingViewModel.state` 已经是
        // `.installed`（引用类型，早更新了），而 selectedPackMetadata / config 还是 **app 启动时**
        // 那份 —— 那时 config.json 还不存在，`loadPanelConfig` 回落成 `.needsPack`，metadata 的 id
        // 为空 —— 于是包名是**空的**。
        // 随后 state 那个 handler（先 refresh）说出带包名的那一句：**两句不同 → 后缀吞不掉 → 同一趟
        // post 两条**，正是 T17f/T17g 整台机器存在的唯一理由。
        //
        // 「没害处」（陈旧那句必然先 post，被后一条截断，幸存者总是对的）是一句**推理**，它押的是
        // 「被截断的那条一个字都不会出声」—— 一个没人实测过的 VoiceOver 语义。用户完全可能听到一句卡半截
        // 的「Claudio 面板，当前声音包…」，就在这个产品唯一一次庆祝时刻上。
        //
        // 这条只能长在这里：`header` 是视图**唯一**供给的那个事实，而 `PanelAnnouncementSuite` 给每个
        // 时刻喂的都是同一个 `H` —— 政策的 harness 结构上**看不见**两个 handler 各自算出不同 header 这件事。
        if let actionHandlerAt = panel.range(
            of: ".onChange(of: onboardingViewModel.actionState) { _ in")?.upperBound,
            let sayActionAt = panel.range(of: "say(.actionStateChanged)")?.lowerBound,
            actionHandlerAt < sayActionAt
        {
            let handlerBody = panel[actionHandlerAt..<sayActionAt]
            expect(
                handlerBody.contains("panelModel.reload()"),
                "`.onChange(of: actionState)` 必须在 `say(.actionStateChanged)` **之前** refresh() —— 见上。"
                    + "少了这一行，一次成功的接管会在同一趟里 post 两条内容不同的播报，而用户在这个产品"
                    + "唯一一次庆祝时刻上，听到的是一句卡半截的「Claudio 面板，当前声音包…」")
            expect(
                handlerBody.contains("if case .idle = onboardingViewModel.actionState"),
                "而且**只在 `.idle` 那一格** refresh：面板句只在那一格才被说出来（别的动作态说的是 "
                    + "actionClause，一个字的 header 都不用）。无条件 refresh 会在 `.running` 时去扫一块"
                    + "**动作正在写**的磁盘 —— 那是拿一个真 bug 换一个假 bug")
        } else {
            expect(
                false,
                "PanelView 里必须有 `.onChange(of: onboardingViewModel.actionState) { _ in`，且 "
                    + "`say(.actionStateChanged)` 排在它**之后** —— 否则上面那条顺序断言无从判起")
        }

        if let appearAt = panel.range(of: ".onAppear {")?.lowerBound,
            let showAt = panel.range(of: ".onChange(of: focusCoordinator.showCount)")?.lowerBound
        {
            expect(
                !panel[appearAt..<showAt].contains("say("),
                ".onAppear 不许播报 —— 它与 .onChange(showCount) 在同一次打开里**都会**跑（本文件为 refresh() "
                    + "实测过这一点：首开会扫盘两遍），两条 post 会抢同一条一次一句的通道，而谁先谁后取决于"
                    + " onAppear 与 popoverDidShow 的 AppKit 时序 —— 一个没实测过的语义。播报只挂 showCount")
        } else {
            expect(false, "PanelView 里必须同时有 .onAppear 与 .onChange(of: focusCoordinator.showCount)")
        }

        if let rowsAt = panel.range(of: "ForEach(panelModel.eventRows")?.lowerBound,
            let noticeAt = panel.range(of: "ActionNoticeRow(")?.lowerBound
        {
            expect(
                rowsAt < noticeAt,
                "四行事件覆盖度必须排在告知行**之前** —— 换包告知白纸黑字写着「事件行里会标出哪些还缺」。"
                    + "顶替上来的包只过了 isUsablePack（它一个字节的音频都不查，usablePackIDs.first 完全可能是"
                    + "一个只映了 1/4 事件的用户包），所以那几行是这句话之后唯一说真话的地方。把它们挪到告知"
                    + "下面，用户就得先读到「哪些还缺」、再往下找那个「哪些」")
        } else {
            expect(false, "PanelView 里必须同时有 ForEach(panelModel.eventRows 与 ActionNoticeRow(")
        }
    }

    suite("PanelView 的 lockFile 默认值必须是 configLockFile（锁分离 D9 的兑现点）") {
        // MenuBarController.swift 是全仓唯一的 `PanelView(` 构造点，且不传 `lockFile`（见下面那条
        // suite「MenuBarController 里没有 Bundle.main」旁边同一个文件）—— 所以这个默认值是 GUI 生产
        // 路径上**唯一活着**的锁值。`ClaudioGUI` 是 executableTarget，`claudio-gui-tests` import 不了
        // 它，`PanelView.lockFile` 又是 `private let`（编译期也够不到），所以只能走源码文本绊线 ——
        // 与本文件其余每一条断言同一个理由（见文件头部）。
        guard let panel = codeOnly("gui/Sources/ClaudioGUI/PanelView.swift") else {
            expect(false, "读不到 PanelView.swift —— 这个 suite 唯一的价值就是读它")
            return
        }
        expect(
            panel.contains("lockFile: URL = ClaudioPaths.configLockFile"),
            "PanelView 的 lockFile 默认值必须是 ClaudioPaths.configLockFile，不是 playLockFile —— "
                + "它同时喂给 EventMuteController 与 selectPack，两者都在写 config.json，绝不能被 "
                + "play 的 debounce 锁挡住（这正是这次分锁要修的那个『吞提示音』的 bug）")

        // 上面那条只钉住**默认值声明那一行**。它钉不住「这个值真的被转发下去」——
        // 实测（swift-reviewer 的变异验证）：把 `configLockFile: lockFile` 改成
        // `configLockFile: ClaudioPaths.playLockFile`，默认值声明原样不动，整个 gui 套件
        // **整套 gui 测试全绿**（不写条数：那个数每加一条断言就腐烂一次，本文件为它翻过车）。
        // 默认值写对、转发线接错，是一个测试一个字都不会红的洞，
        // 而它的用户可见后果与默认值写错**一模一样**（点静音又吞一次提示音）。
        // 所以下面三条把整条链钉死：默认值 → 两个下游写者 → 那把不该被 config 锁冒名顶替的 settings 锁。
        expect(
            panel.contains("configLockFile: lockFile"),
            "PanelView 必须把它自己的 lockFile（= config.lock）转发给 OnboardingActionEnvironment "
                + "的 configLockFile —— takeOver 路径要写 config.json（selectPack）")
        // 第二个消费者 EventMuteController 的锁转发断言，下移到 `controllerSource` 读入之后 —— 因为
        // 它现在由 `PanelConfigController` **独占构造**（红队 b86ec0a：注入会开「幽灵实例」的口，面板读
        // 一个实例、controller 写另一个，静默吞错）。见下面 `controllerSource` 段。

        // 第三个消费者：切包（`switchPack` → `selectPack`）。它**搬进了**
        // `ClaudioGUICore.PanelConfigController`（红队 9cccc9c 兑现台账那条 P2），所以这条锁转发链现在
        // 有两段，两段都要钉：
        //   ① PanelView.init 把自己的 lockFile（= config.lock）**灌进** PanelConfigController；
        //   ② PanelConfigController.switchPack 把那把锁**转发给** selectPack。
        // 任何一段接错（比如②里换成 settingsLockFile），切包写 config.json 却守着别的锁，与并发的
        // `claudio use`（守 config.lock）之间互斥当场消失，两个读-改-写交错、丢更新。
        //
        // ② 这一段现在住在**可 import** 的 `ClaudioGUICore` 里（不像困在 executableTarget 的 PanelView）——
        // 本可以行为级测锁竞争，但那要模拟持锁，太重；这里仍走源码文本，与①同一种绊线。
        expect(
            collapsingWhitespace(panel).contains(
                "PanelConfigController( configFile: configFile, lockFile: lockFile,"),
            "① PanelView.init 必须把自己的 lockFile（= config.lock）灌进 PanelConfigController —— 切包 /"
                + "静音的写路径都在那个 controller 里，它拿错锁 = 整条 config.json 写路径拿错锁")
        guard let controllerSource = codeOnly("gui/Sources/ClaudioGUICore/PanelConfigController.swift")
        else {
            expect(false, "读不到 PanelConfigController.swift —— 切包的锁转发第②段住在那里")
            return
        }
        expect(
            controllerSource.contains(
                "bundledPacksDirectory: environment.bundledPacksDirectory, lockFile: lockFile)"),
            "② PanelConfigController.switchPack 必须把它自己的 lockFile 转发给 selectPack —— 它是全仓"
                + "第三个 config.lock 消费者（另两个：EventMuteController、OnboardingActionEnvironment），"
                + "也是用户每次在画廊里换包都会走的那一条。换成 settingsLockFile 之类，与并发 `claudio use`"
                + "的互斥就没了")

        // 第二个消费者 EventMuteController：现在由 PanelConfigController 独占构造（红队 b86ec0a 的「幽灵
        // 实例」结构性修复），所以它也拿 controller 的 lockFile（= config.lock）。锁转发断言读 controller 源码。
        expect(
            controllerSource.contains("EventMuteController(configFile: configFile, lockFile: lockFile)"),
            "PanelConfigController 必须用它自己的 lockFile（= config.lock）构造 EventMuteController —— "
                + "静音开关写的是 config.json，绝不能被 play 的 debounce 锁挡住。换成 playLockFile 之类，"
                + "点静音又会吞一次提示音（这正是分锁 D9 要修的 bug）")

        // `OnboardingActionEnvironment(…)` 那三把锁（config / settings / packs）的转发断言**不在
        // 这里** —— 它们搬进了下面那条按调用点绑的 suite。这里曾经有一条
        // `panel.contains("settingsLockFile: ClaudioPaths.settingsLockFile")`，删掉不是放弃覆盖：
        // 那是一条读 `codeOnly`（**保留**字符串内容）的全文件 `contains`，`/codex review 48b6730`
        // 与 `37745f2` 两轮各证过它可以被一句见证值（字符串字面量 / 元组标签）喂饱，而真实实参
        // 换成别的。新那条严格更强：调用点两头锚死 + 实参**相等**判定 + 读清空字符串的那一路，
        // 三把锁一起。这里没有它的独占靶子（构造点认不出来时，那边的 `count == 1` 先红）。

        // 负向兜底：PanelView 在**任何位置**都不该碰 play 的去抖锁。它一个字节都不写 play.state，
        // 也不参与去抖。因为 `codeOnly` 已剥掉注释，谈论 playLockFile 的**散文**不会把它假红
        // （这正是本文件头部记着的那次翻车）。
        //
        // ⚠️ 连**值级假名**一起拦（`/review e7c38ea` 的 P1-4）：只禁标识符 `playLockFile` 是不够的 ——
        //
        // ```swift
        // lockFile: ClaudioPaths.root.appendingPathComponent("play.lock")
        // ```
        //
        // —— 拿到的是**同一把**去抖锁，而标识符 `playLockFile` 一次都没出现。禁掉字面量 `play.lock`
        // 把这条路一起堵上。这不是洁癖：这个文件是 GUI 三个 config 写者的**唯一**锁来源，它是
        // `claudio-gui-tests` **import 不到**的 target（`ClaudioGUI` 带 `@main`），所以源码绊线是
        // 这里**唯一**能立的防线 —— 而绊线只挡得住它逐字写下的那几个形状。
        expect(
            !panel.contains("playLockFile") && !panel.contains("play.lock"),
            "PanelView 的**代码**里出现了 playLockFile 或字面量 `play.lock` —— 它不写 play.state、"
                + "不参与去抖，碰 play 的锁只会重新把提示音吞掉。两个都禁：`ClaudioPaths.root"
                + ".appendingPathComponent(\"play.lock\")` 拿到的是同一把锁，却一次都不提那个标识符")
    }

    suite("PanelView 构造 OnboardingActionEnvironment 的**三把锁**逐个按调用点绑（不是全文件 contains）") {
        // ## 这一手为什么此前是全链上唯一没有守卫的
        //
        // 包锁从 GUI 灌到 `Setup.swift` 要过四手。前三手各有守卫（`OnboardingActions.swift` 的
        // 构造点实参由本文件那条相等循环钉、`init` 的存储赋值由 `OnboardingActionsSuite` 的持锁
        // 行为测试钉），而**第一手 —— `PanelView` 构造 `OnboardingActionEnvironment` 时转发不转发
        // —— 一条断言都没有**。实际状态（不是假想变异体）：它**根本没传**，于是
        // `packsLockFile` 的默认实参静默生效，落回 `ClaudioPaths.packsLockFile`。
        //
        // 它躲过了本文件已有的每一张网，三层原因叠在一起：
        //  · 上面那条 `lockLeaks` 普查**按文件名豁免了 PanelView.swift**
        //    （`where !file.path.hasSuffix("PanelView.swift")`）—— 那条普查的立论是「GUI 的锁只有
        //    一个来源：PanelView 的默认值」，于是唯一允许写锁的文件也是唯一没人数它写了什么的文件；
        //  · 那条相等循环读的是 `OnboardingActions.swift`，够不到 `PanelView.swift`；
        //  · `ClaudioGUI` 带 `@main`、`claudio-gui-tests` **不依赖**它 ⇒ 没有任何行为测试到得了
        //    这一手。**在测试进程里，源码绊线是这里唯一可能的守卫**，而三把锁里只有它没有。
        //
        // ⚠️ 「唯一」限定在**测试进程内**，别把它写大：`OnboardingActionEnvironment.init` 的
        // `packsLockFile` 已经没有默认值，所以**漏传**这一种在 `swift build` 下是编译错误。但
        // 本仓库文档化的绿灯信号 `swift run --package-path gui claudio-gui-tests` 压根不编译
        // `PanelView.swift`（依赖表里没有 `ClaudioGUI`）—— 实测：删掉那行实参，`swift build` 报
        // `missing argument`，而 `swift run claudio-gui-tests` **编译通过、整套跑完**，红的是下面
        // 这条断言。所以：编译器守 `swift build` 与 release CI，本条守测试进程，**两者不互相代偿**。
        // 而「传了但传错」（写成 `ClaudioPaths.…`）编译器**永远**看不见，只有下面两条看得见。
        //
        // ## 为什么读 `codeWithoutStrings` 而不是 `codeOnly`
        //
        // `codeOnly` 剥注释但**保留字符串内容**。`/codex review 48b6730,9f347fc` 的 P1 逐字证过
        // 那是可伪造的：往文件里加一句 `let witness = "packsLockFile: audioEnvironment.packsLockFile"`，
        // 正向断言被这句字面量喂饱，而真实实参可以换成别的。`codeWithoutStrings` 把字符串**内容**
        // 清空，字面量再也喂不动它。
        //
        // ## 而清空字符串**不够** —— 见证值可以是**代码**（`/codex review 37745f2` 的 P1）
        //
        // 上一版这条断的是 `panel.contains("packsLockFile: audioEnvironment.packsLockFile")`，并且
        // 在注释里管它叫「**逐字全等的整行实参**，不是 `contains("packsLockFile:")` 那种前缀式」。
        // 那句话是假的：它就是 `contains`，只是 needle 更长。Codex 给的见证值一个字符串都没用 ——
        //
        // ```swift
        // let witness = (packsLockFile: audioEnvironment.packsLockFile)   // 元组标签，纯代码
        // …
        // packsLockFile: fallback                                        // 真实实参，fallback = ClaudioPaths.packsLockFile
        // ```
        //
        // —— 元组标签是**代码位置**，`codeWithoutStrings` 一个字都不会碰它；正向断言被它喂饱，
        // 负向断言（`!contains("packsLockFile: ClaudioPaths.")`）碰不到值级假名 `fallback`。
        // 上一刀只关掉了**字符串字面量**那一个见证子类，却把措辞写成整类已封 —— 这个仓库第 N 次
        // 栽在「措辞比覆盖范围大」上，而且又一次栽在自称修好它的那一刀里。
        //
        // 这一版换掉的是**判据的种类**，不是 needle 的长度：先把调用点两头锚死
        // （``callArguments(of:in:)``：头是类型名、尾是配平右括号），再对切出来的实参做**相等**
        // 判定。见证值无论写成字符串还是元组还是别的什么，都不在那对括号里，喂不动它。
        guard let panel = codeWithoutStrings("gui/Sources/ClaudioGUI/PanelView.swift") else {
            expect(false, "读不到 PanelView.swift —— 这条 suite 唯一的价值就是读它")
            return
        }

        // ## 围栏那一半：认不出的构造形状 ⇒ 当场红
        //
        // `callArguments` 是白名单，而白名单永远不完整。少认一处 = 那一处静默退出审查 = 真实构造
        // 可以随便写而没有人会喊。`unmodeledConstructionShapes` 把「我认不出哪些」从 doc comment
        // 里搬进返回值 —— 被写进注释的洞不会因为被写进注释而变成有人看守它。
        let unmodeledShapes = unmodeledConstructionShapes(
            of: "OnboardingActionEnvironment", in: panel)
        expect(
            unmodeledShapes.isEmpty,
            "`PanelView.swift` 里出现了 `callArguments` 认不出的构造形状：\(unmodeledShapes) —— "
                + "下面那条「每一处构造点都必须转发对」的循环会**漏掉**它，而漏掉不会有任何人喊。"
                + "要么把这个构造挪走，要么先把扫描器教会这个形状再放行")
        // ## 精确计数，不是 `!isEmpty`
        //
        // `!isEmpty` 只要求「≥1 处且那一处转发对」，于是一个写得完全合规的**死代码诱饵**就能替
        // 真实构造背书（`/codex review 37745f2` P1 的第一步正是这个）。`PanelView` 里实测只有
        // **一处** `OnboardingActionEnvironment(…)`，就断死这个数：多出来一处 ⇒ 红 ⇒ 有人来看
        // 那是诱饵还是一次真实的重构。helper 那边两条锁绊线（`count == 2` / `count == 1`）
        // 早就是这么写的，这里之前是全链上唯一还在用 `!isEmpty` 的。
        let environmentCalls = callArguments(of: "OnboardingActionEnvironment", in: panel)
        expect(
            environmentCalls.count == 1,
            "`PanelView.swift` 里必须正好有 1 处 `OnboardingActionEnvironment(…)` 构造点，实得 "
                + "\(environmentCalls.count) 处 —— 0 处 = 接管路径不再经由它（下面那三条转发断言就是"
                + "在守一段不存在的代码），>1 处 = 多出来的那个可能是喂饱断言的死代码诱饵，也可能是"
                + "一次真实重构，两种都必须有人看一眼再放行")

        // 三把锁一个循环断完。它们是**同一个构造点**上的三个实参，分开写成三条全文件 `contains`
        // 是上一版的形状 —— 而那正是见证值攻击的入口（needle 在文件里任何位置出现都算数）。
        //
        // ⚠️ 这三条**互不代偿**，一条都不能省：三个实参各自绑不同的锁，任意一条传错都是一条真实
        // 的锁串线，而另外两条照样绿。
        let expectedLocks: [(label: String, value: String, why: String)] = [
            (
                "configLockFile", "lockFile",
                "写的是 config.json，必须守着 PanelView 自己那把 config.lock（本 init 的 `lockFile` "
                    + "参数）。传成别的 ⇒ 接管写 config.json 时与并发的 `claudio use`（守 config.lock）"
                    + "互斥当场消失，两个读-改-写交错、丢更新"
            ),
            (
                "settingsLockFile", "ClaudioPaths.settingsLockFile",
                "takeOver 路径同时写 settings.json（installClaudioHooks），它必须守着**独立**的 "
                    + "settings.lock —— 与 config.json 的写者共用一把锁，正是这次分锁要拆开的东西"
            ),
            (
                "packsLockFile", "audioEnvironment.packsLockFile",
                "manifest.json 有两个写者（接管发布内置包、`ManifestBinding` 绑定/解绑），"
                    + "`userPacksDirectory` 那一行已经把它们指向同一个包目录，这一行是把它们的**互斥**"
                    + "焊在同一个源上的唯一结构链接。漏掉它 ⇒ 默认实参静默生效、编译器一声不吭；"
                    + "写成 `ClaudioPaths.packsLockFile` ⇒ 今天碰巧仍相等，但那是「两个独立默认值恰好"
                    + "收敛」而不是「同一个源」，改动 audioEnvironment 那一侧（它是 `var`）两个写者当场分家"
            ),
        ]
        for (ordinal, arguments) in environmentCalls.enumerated() {
            for expected in expectedLocks {
                let forwarded = argumentValue(expected.label, in: arguments)
                expect(
                    forwarded == expected.value,
                    "第 \(ordinal + 1) 处 `OnboardingActionEnvironment(…)` 的 `\(expected.label):` 实参"
                        + "必须**正好是** `\(expected.value)`，实际是 `\(forwarded ?? "<没有这个实参>")` —— "
                        + expected.why
                        + "。**相等**，不是 `contains`：`\(expected.value).deletingLastPathComponent()"
                        + ".appendingPathComponent(…)` 逐字包含前者，拿到的却是别的路径")
            }
        }

        // 负向兜底：不许绕过 audioEnvironment 直接取真实路径。
        //
        // ⚠️ 如实标注它现在还剩多少分辨力：上面那条相等判定**已经覆盖了这个构造点上的这一种**
        // （实参写成 `ClaudioPaths.packsLockFile` ⇒ 相等判定当场红）。它没有被完全吞掉 —— 只有它
        // 逮得到的是：本文件里**另起一个非 `OnboardingActionEnvironment(` 的构造点**并写死真实路径
        // （上面那个循环根本不看它）。所以留着；但别把它当「第二道独立防线」宣传：在最要害的那个
        // 调用点上，它与上面那条是**重叠**的。
        //
        // ⚠️ 如实标注极性代价：读 `codeWithoutStrings` 对**负向**断言是 fail-**open**（被清空的字符串
        // 里若正好有 needle 会静默变绿）。仍然接受，因为 needle `packsLockFile: ClaudioPaths.` 是一段
        // **代码形状**而不是字符串内容，且同一次读取要喂上面那条承重的相等循环 —— 一个绑定喂两类
        // 极性相反的断言时，承重的那一类说了算。代价写在这里，不藏。
        //
        // ⚠️ 它也**挡不住值级假名**（`let p = ClaudioPaths.packsLockFile` 再传 `packsLockFile: p`）——
        // 与本文件 play 锁那条负向兜底同一个已知天花板，那里靠加禁字面量 `play.lock` 补了一半。
        // 这里**没有**对应的字面量可禁（`"packs.lock"` 在 PanelView 里本就不该出现，但禁它挡不住
        // `ClaudioPaths.packsLockFile` 这个不含该字面量的假名）。不声称封死，只声称封住直写那一种。
        expect(
            !panel.contains("packsLockFile: ClaudioPaths."),
            "PanelView 把 packsLockFile 直接写成了 `ClaudioPaths.…` —— 那就绕过了 audioEnvironment "
                + "这个唯一的源，两个 manifest.json 写者从「同一个源」退化成「两个碰巧相等的默认值」。"
                + "锁只有一个来源：audioEnvironment")
    }

    suite("MenuBarController 构造 PanelView 时不许传 lockFile —— 上面那个默认值的唯一活路") {
        // 上面那条 suite 的头部注释里写着一句话：「MenuBarController.swift 是全仓唯一的
        // `PanelView(` 构造点，且不传 `lockFile`」。**那是一个被写进注释的事实，而这个仓库
        // 自己的规矩是：该断言的地方不许放注释**（`/codex review 803c639,b74b7f3` 的完整性
        // 复查逮到的就是这一条）。
        //
        // 它为什么必须是断言：`PanelView.lockFile` 是 `public` 的 init 参数，它存在的**唯一**
        // 理由就是注入。任何一次「把锁/环境从 AppKit 外壳往下穿」的重构（主音量那一行、第二个
        // popover、一个测试接缝）都会**自然而然**开始传它。而一旦这里传进 `ClaudioPaths.playLockFile`：
        //
        //   PanelView.lockFile → EventMuteController（静音写 config.json）
        //                      → selectPack（切包写 config.json）
        //                      → OnboardingActionEnvironment.configLockFile（接管写 config.json）
        //
        // 三个 GUI config 写者**同时**回到 play.lock 上。而上面那条 suite 只读 `PanelView.swift`：
        // 默认值声明没动、两条转发没动、`!contains("playLockFile")` 也没动 —— **整套全绿**。
        // 用户可见后果与默认值写错一模一样：点静音又吞一次提示音。
        //
        // 这是 D20 那条教训（「GUI 是显式向下传参的，改默认值挡不住调用点」）在**上一层**的复发：
        // 阶段 A 给 PanelView 的默认值上了绊线，却把**调用点**的行为记成了一句散文。
        //
        // ## 为什么数的是整个 target，而不是 MenuBarController 一个文件（`/codex review d5ec97e,8f9cfa2`）
        //
        // 这条断言的**上一版**只读 `MenuBarController.swift`，措辞却写着「全仓唯一构造点」——
        // 与 T17h 那次（见 `guiSources()` 的文档）**逐字同一个病**：断言的措辞比它守的范围大。
        // 于是在 `ClaudioGUIApp.swift` 或任何一个新文件里写第二处
        //
        // ```swift
        // PanelView(configFile: …, lockFile: ClaudioPaths.playLockFile)
        // ```
        //
        // —— MenuBarController 里那个计数仍是 1、`!contains("lockFile")` 仍成立 —— **全绿**，
        // 而 GUI 的三个 config 写者已经回到 play.lock 上了。同一个洞在同一个 suite 里被修过一次，
        // 又在它旁边重开了一次；这次连措辞一起钉死。
        let sources = guiSources()
        expect(
            sources.count >= 5,
            "在 gui/Sources/ClaudioGUI 下一个 Swift 文件都没数到（实得 \(sources.count)）—— "
                + "下面两条都是**普查**，普查不到任何文件就永远等不到红，只会安静地绿下去")

        // 普查一：全 target 只许有一个 PanelView 构造点，且必须在 MenuBarController 里。
        //
        // 两种写法都数（`/codex review 840ea37` 的 P2）：`PanelView.init(` **不**包含 `PanelView(`，
        // 上一版只数后者，措辞却写着「唯一构造点」—— 又一次措辞比正则宽。真正守住锁的是下面的
        // 普查二（任何显式传锁的构造点，不论写成哪种，都会漏出 `lockFile`）；普查一守的是上面那条
        // 默认值断言的**前提**（「只有一个构造点、且走默认值」）。前提得连写法一起数，才配叫普查。
        var constructionSites: [String: Int] = [:]
        for file in sources {
            let bare = file.code.components(separatedBy: "PanelView(").count - 1
            let explicitInit = file.code.components(separatedBy: "PanelView.init(").count - 1
            let count = bare + explicitInit
            if count > 0 { constructionSites[file.path] = count }
        }
        expect(
            constructionSites == ["MenuBarController.swift": 1],
            "全 ClaudioGUI 只许有**一处** PanelView 构造点（`PanelView(` 与 `PanelView.init(` 一起数），"
                + "且只许在 MenuBarController.swift 里，实得 \(constructionSites) —— 这条 suite 与它上面"
                + "那条（PanelView 的 lockFile 默认值）都建立在「全 target 唯一构造点、且走默认值」这个"
                + "前提上。多出第二处，两条断言的保护范围就都缩水了，必须重新想")

        // 普查二：除 PanelView 自己之外，全 target 的**代码**里不许出现任何锁。
        // PanelView.swift 是唯一的例外，因为那个默认值与三条转发就住在它里面（上面那条 suite 钉的）。
        // `PackGalleryView` 的 doc comment 里提过 `selectPack(…lockFile:)`，`codeOnly` 已把它剥掉 ——
        // 这正是本文件头部记着的那次翻车（把谈论代码的文字当代码断）。
        //
        // ⚠️ **大小写不敏感**（`/review e7c38ea` 的 P1-2）：上一版数的是子串 `lockFile`，而
        // `configLockFile` / `settingsLockFile` 里那个 `L` 是**大写**的 —— 子串匹配大小写敏感，
        // 于是在任何一个 ClaudioGUI 文件里写
        //
        // ```swift
        // OnboardingActionEnvironment(…, configLockFile: ClaudioPaths.playLockFile, …)
        // ```
        //
        // —— 这条普查**一次都数不到**。措辞（「不许出现 lockFile」）比正则（「小写 l 那一种写法」）大，
        // 又一次。`lowercased()` 一行就把 `lockFile` / `configLockFile` / `settingsLockFile` 全收进来。
        // ## 豁免名单从一项变成三项，而净极性**没有**下降
        //
        // 拆掉 `AudioImportEnvironment.packsLockFile` 的默认值之后（`/codex review 95d16a5,b89a0ee,
        // 37745f2` 的 P1-A），生产侧两个构造点必须**显式**写出包锁 —— 于是这两个文件里出现了
        // `lockfile` 这个 token，而本普查的机制（数任何 `lockfile`）比它的目的（**config / settings**
        // 这两把锁只有一个来源）宽。
        //
        // ⚠️ 处理办法**不是**收窄 needle。本普查是**负向**的（出现 ⇒ 红），收窄 needle = 少数几处 =
        // 少红几次 = fail-**open**，与直觉相反。也不是白给两个文件开豁免 —— 那是同一个方向。
        //
        // 办法是：豁免它们，**同时**各给一条更严的锚定绊线（下面那条 suite）。那条绊线按调用点绑
        // 实参、做相等判定，并且用实参**自己的文本**算出该文件应有的命中数 —— 多出一个 token 就是
        // 第三处锁，当场红。所以每个被豁免的文件换来的是一条比本普查**更强**的守卫，不是一个洞。
        //
        // PanelView.swift 的豁免理由与它们不同（它是三把锁**唯一**允许的来源），由本文件那条
        // 「PanelView 构造 OnboardingActionEnvironment 的三把锁逐个按调用点绑」守着。
        //
        // ⚠️ 这里**直接读**文件级的 ``lockCensusExemptedFiles``，不许再套一层 suite 局部别名
        //   （`let lockCensusExemptions = lockCensusExemptedFiles`）。上一版套了，而那一层就是洞：
        //   下面那条绑定断言绑的是**常量**，普查消费的是**别名** —— 两者之间没有任何断言。往别名上
        //   写 `lockCensusExemptedFiles + ["MenuBarController.swift"]`，绑定断言逐字全绿
        //   （它读的常量一个字没变），而 MenuBarController.swift 从此静默退出本普查，对价一条没付；
        //   接着在它里面写 `PanelView(configFile: …, lockFile: ClaudioPaths.playLockFile)`，
        //   三个 GUI config 写者一起回到 play.lock 上 —— 整套仍然全绿。
        //   把常量提到文件级的**全部目的**就是让豁免集成为一个被绑住的值，再局部化一层等于原地
        //   把它解绑（memory 第九次那条「抽取一层接缝就往外挪一层」）。而且当时修复**自己的散文**
        //   与失败消息都指着 `lockCensusExemptions` 这个没被绑的名字，照着那句话去加第四项的人，
        //   落笔正好落在洞上。删掉那一层，编辑点就不存在了，代价为零。
        //   （`/codex review 51aebae,7caf6dc,e278736` 的红队对抗轮实测坐实。）
        //
        // ⚠️ **如实标注这一刀的性质：它消除的是编辑点，不是新增了一条守卫。**
        //   台账实测：把那层别名写回来、并在它上面加第四项（`lockCensusExemptedFiles +
        //   ["MenuBarController.swift"]`），**2468 条全绿**，没有任何断言会喊 —— 下面那条绑定
        //   断言读的是常量，常量一个字没变。也就是说这条路今天靠的是「源码里没有那个编辑点」，
        //   而不是「有人守着它」。要真正守住，得有一条断言去读本普查**实际消费的那个值**，
        //   而那需要一台能读自己源码又不自我污染的机器；不在本刀范围内，不声称封死。
        var lockLeaks: [String: Int] = [:]
        // ⚠️ 豁免按**文件名全等**判，不是 `hasSuffix` —— 极性在这里是反的，看清楚再改
        //   （`/review d7084be` 补，与 `/codex review d7084be` 那条 `hasPrefix(root.path)` 是同一个病
        //   的孪生体，只是坐在**豁免**这一侧）。`file.path` 是 `sourcesUnder` 交出来的**相对子路径**，
        //   于是裸 `hasSuffix("PanelView.swift")` 会连带命中**任何**以它收尾的文件名
        //   （`<任意前缀>PanelView.swift`）—— 它们会**自动**退出这条普查，而换来对价的那条锚定绊线
        //   按**精确文件名**读 `expectedProductionLocks`，够不到它们。
        //   实测（本轮，隔离 worktree）：往 `gui/Sources/ClaudioGUI/` 放一个含 `lockFile` token 的
        //   `SoundManagerPanelView.swift`，`lastPathComponent` 全等判据下**当场红** —— 这一刀有牙。
        //
        //   ⚠️ 另一个直觉上的泄漏形状 `Sub/PanelView.swift`（子目录下同名）**结构上不可达**，
        //   不要为它加判据：`sourcesUnder` 用的 `enumerator(atPath:)` 确实递归、确实会交出
        //   `Sub/PanelView.swift` 这种相对子路径，但同一个 SwiftPM target 里**不允许两个同名
        //   basename** —— 实测直接构建失败（`couldn't build …/PanelView.swift.o because of
        //   multiple producers`）。也就是说 SwiftPM 自己就是那一侧的围栏，源文件根本进不来。
        //   少豁免一个 = 多查一个文件 = 有人喊（fail-closed）；多豁免一个 = 一个文件静默退出审查 =
        //   **没有人会喊**（fail-open）。所以这里必须是最窄的那个判据。
        //
        //   ⚠️ 这里**不**举具体的未来文件名当论据。上一版写的是「plan/ 里已经写着
        //   `SoundManagerPanelView.swift`，这不是假想输入」—— 实测证伪：`plan/` 下确有
        //   `PLAN-SOUND-MANAGER.md`（规划了面板 + 独立管理窗口，点名的新 View 是 `AudioDropZoneView`
        //   与 `EventRowView`），但字符串 `SoundManagerPanelView` 全仓**只出现在那句声称它存在的注释
        //   自己身上**。那是一次凭空背书，与本分支 7caf6dc 修的是同一个病 —— 而这次它长在给修复
        //   背书的散文里。收窄判据的理由是**极性**（上一段），它自己站得住，不需要引用任何文件名。
        for file in sources
        where !lockCensusExemptedFiles.contains((file.path as NSString).lastPathComponent) {
            let count = file.code.lowercased().components(separatedBy: "lockfile").count - 1
            if count > 0 { lockLeaks[file.path] = count }
        }
        expect(
            lockLeaks.isEmpty,
            "ClaudioGUI 里除 PanelView.swift 之外的文件出现了锁（lockFile / configLockFile / "
                + "settingsLockFile，大小写不敏感地数）：\(lockLeaks) —— 这会绕过 PanelView 那个唯一"
                + "活着的默认值（= config.lock），把静音、切包、接管三个 config.json 写者一起送回"
                + "调用点指定的那把锁上。传 playLockFile = 阶段 A 的分锁当场失效，而 PanelView.swift "
                + "一个字都不用改，整套 GUI 测试照样全绿。**config / settings 这两把**锁只有一个"
                + "来源：PanelView 的默认值（包锁不在此列 —— 它由 PanelView 从 audioEnvironment "
                + "**转发**，见那条独立的转发绊线）。豁免名单：\(lockCensusExemptedFiles) —— 每一项都换来"
                + "一条比本普查更严的锚定绊线，不是一个洞")
    }

    suite("`AudioImportEnvironment.packsLockFile` 不许有默认值 —— 编译器执行「必须传」的那一半") {
        // 拆掉默认值那一刀（`/codex review 95d16a5,b89a0ee,37745f2` 的 P1-A）的守卫。
        //
        // ## 为什么编译器不能给它自己背书
        //
        // 把默认值加回去是一次**纯放宽**：现存调用点全都显式传着值，加完 `swift build` 零诊断。
        // 编译器强制的是默认值的*后果*，从不是它的*不存在* —— 本仓库为同一句话立过两个判例
        // （`@MainActor` 与「同步无挂起点」，都记在 `ManifestBinding.swift` 的 doc 里）。
        //
        // ## 它守的东西有多值钱：实测的那次实锤
        //
        // 默认值还在的时候，往 `gui/Tests` 里加一个漏传它、又走 `clearEventBinding` 的 fixture：
        // 编译通过、**2421 条断言全绿**；把用户真实的 `~/.claudio/packs.lock` 挪开再跑，那个文件被
        // **重新创建**出来（0 字节、`0600`，`FileLock` 的 `open(O_CREAT, 0o600)` 签名）。判据是
        // 「把它挪开再看它长不长回来」，不是退出码 —— 那个 0 字节文件在 `stat` 前后是同形的。
        guard let environment = codeWithoutStrings(
            "gui/Sources/ClaudioGUICore/AudioImportEnvironment.swift")
        else {
            expect(false, "读不到 AudioImportEnvironment.swift —— 这条 suite 唯一的价值就是读它")
            return
        }
        // ⚠️ 这个文件里有**两个** `public init`（`AudioImportEnvironment` 与 `AudioImportLimits`）——
        // 第一版按 `public init` 锚，实得 2 处当场红。所以锚的是「**带 `packsLockFile:` 形参**的那个
        // init」：0 处 ⇒ 形参没了（下面那条判定就是在守一段不存在的代码，对空集恒真绿），
        // >1 处 ⇒ 两个 init 都带这个形参，下面那条只看得住它逐个遍历到的，歧义必须有人来定。
        //
        // ## ⚠️ 那个 `.filter` 曾经**就是**这条 suite 的洞（`/codex review 51aebae,7caf6dc,e278736`
        //    的 P1-A，隔离 worktree 实测坐实）
        //
        // 它把「**不带** `packsLockFile:` 形参的 init」整个丢掉 —— 而那正是逃逸体本身。给这个
        // struct 加一个便利 init：
        //
        // ```swift
        // public init(
        //     userPacksDirectory: URL = ClaudioPaths.packsDirectory,
        //     bundledPacksDirectory: URL? = nil,
        //     durationProbe: any AudioDurationProbing,
        //     limits: AudioImportLimits = AudioImportLimits()
        // ) {
        //     self.init(…, packsLockFile: ClaudioPaths.packsLockFile)   // 静默回到用户真实 home
        // }
        // ```
        //
        // —— 12 行，`swift build` 零诊断，随后让任意 fixture 漏传那把锁：**2456 条检查全绿**，
        // 与基线逐字同数。「漏传 = 编译错误」这个性质当场没了，而这条 suite 一声不吭：它守的是
        // **一种语法形态**（形参上挂没挂默认值），不是它声称的那个**后果**（漏传能不能编过）。
        // 白名单式识别（认不出 ⇒ 静默放行）伪装成围栏 —— 本仓库反复立案的那一条，这次长在
        // 为「把绊线升成围栏」而写的这一刀自己身上。
        //
        // 下面三条把它补成围栏：**总数**锚定 + 非包锁 init 的形参表**逐字全等** + `extension` 普查。
        // 三条缺一不可：只锚总数，删掉 `AudioImportLimits` 的 init 再加便利 init 就绕过去了
        // （总数仍是 2）；只钉签名，加第三个 init 时它一眼都不看。
        let allPublicInits = callArguments(of: "public init", in: environment)
        expect(
            allPublicInits.count == 2,
            "`AudioImportEnvironment.swift` 里的 `public init(…)` 不是恰好 2 处（实得 "
                + "\(allPublicInits.count) 处）—— 这个文件按设计只住着两个类型的构造器："
                + "`AudioImportEnvironment` 一个（`packsLockFile:` 必填）与 `AudioImportLimits` 一个。"
                + "多出来的第三个最可能是一个**便利 init**：它不带 `packsLockFile:` 形参、内部转发一个"
                + "硬编码的 `ClaudioPaths.packsLockFile`，于是「漏传 = 编译错误」当场失效，而下面那条"
                + "按形参锚定的判定**结构上看不见它**（它先被 `.filter` 丢掉了）。"
                + "少一个 = 某个构造器没了，下面两条各自在守一段不存在的代码")
        // 非包锁的那一个 **必须**是 `AudioImportLimits` 的那个已知签名，逐字全等。
        //
        // ⚠️ 这一条与上面那条**不是**同一个靶子，别把任何一条当成锦上添花：
        //
        // * 上面那条（总数 == 2）逮的是「**多**一个 init」——便利 init 直接加进来那一种；
        // * 这一条逮的是「总数没变、但那个非包锁 init **换了个人**」。
        //
        // ⚠️ 那么「删掉 `AudioImportLimits.init` 腾出名额、再补一个便利 init」这条组合路呢？
        //    **实测走不通**（不是推理）：删掉它之后 Swift 合成的 memberwise init **不带默认值**，
        //    同一个文件里 `limits: AudioImportLimits = AudioImportLimits()` 那句空参调用当场编译
        //    失败 —— `error: missing arguments for parameters 'maxFileSizeBytes',`
        //    `'maxDurationSeconds' in call`。台账里那个变异因此是**三态里的第三态**（既不是红也不是
        //    绿，是编译不过），如实记在这里，免得下一个人以为它验过了。
        //    所以这两条合起来对「本文件里冒出第二个能不传包锁就造出环境的入口」是完备的。
        //
        // **相等**判定，不是 `contains`：`maxFileSizeBytes: Int = …` 逐字包含任何它的前缀。
        let audioImportLimitsInitSignature =
            "maxFileSizeBytes: Int = 5 * 1024 * 1024, maxDurationSeconds: Double = 3.0"
        let nonLockInits = allPublicInits
            .filter { argumentValue("packsLockFile", in: $0) == nil }
            .map(collapsingWhitespace)
        expect(
            nonLockInits == [audioImportLimitsInitSignature],
            "`AudioImportEnvironment.swift` 里**不带** `packsLockFile:` 形参的 `public init(…)` 的形参表"
                + "必须正好是 `AudioImportLimits` 那一个（`\(audioImportLimitsInitSignature)`），"
                + "实得 \(nonLockInits) —— 对不上就意味着这个文件里多了一个**可以不传包锁就构造出"
                + "环境**的入口（便利 init / 第二个 memberwise 风格入口）。那种入口让「漏传 = 编译"
                + "错误」退回成「漏传 = 静默去用户 home 上开锁」，而测试照样全绿：实测 2456 条一条不红")
        let initializerArguments = allPublicInits
            .filter { argumentValue("packsLockFile", in: $0) != nil }
        expect(
            initializerArguments.count == 1,
            "`AudioImportEnvironment.swift` 里带 `packsLockFile:` 形参的 `public init(…)` 不是恰好 1 处"
                + "（实得 \(initializerArguments.count) 处）—— 0 处 = 形参整个没了，下面那条判定在守一段"
                + "不存在的代码（对空集恒真绿）；>1 处 = 有第二个入口，而包锁只该有一个必填入口")
        for arguments in initializerArguments {
            expect(
                argumentValue("packsLockFile", in: arguments) == "URL",
                "`AudioImportEnvironment.init` 的 `packsLockFile:` 形参不是**没有默认值的** `URL`，"
                    + "实际是 `\(argumentValue("packsLockFile", in: arguments) ?? "<没有这个形参>")` —— "
                    + "带上默认值，漏传这把锁就从编译错误变回**静默**落回那个值。而这一把与它的兄弟"
                    + "`userPacksDirectory` 的失败模式不一样：忘了后者会当场断言失败（真实 packs 里"
                    + "没有 fixture），忘了这一把只会安静地去用户机器上开一把真锁 —— 测试照样全绿，"
                    + "只是与正在运行的 Claudio.app 抢锁、并在 `~/.claudio/` 里落一个文件。静默那一类"
                    + "不能靠纪律，只能靠编译器。**相等**判定，不是 `hasPrefix`：`URL = ClaudioPaths.…` "
                    + "逐字以 `URL` 开头")
        }

        // ## 第三条：`extension` 普查 —— 上面两条**唯一**够不到的那条路
        //
        // 上面两条都只读 `AudioImportEnvironment.swift` 这**一个文件**。而 Swift 允许在同一个
        // 模块的**任何**文件里给这个 struct 加构造器：
        //
        // ```swift
        // // 随便哪个新文件，甚至就在测试包里
        // extension AudioImportEnvironment {
        //     public init(userPacksDirectory: URL, durationProbe: any AudioDurationProbing) {
        //         self.init(…, packsLockFile: ClaudioPaths.packsLockFile)
        //     }
        // }
        // ```
        //
        // 效果与那个便利 init 逐字相同（漏传重新变得能编过、静默落到用户真实 home），而上面两条
        // 一个字都读不到它 —— 又是「新调用点最可能的落点是**新文件**」那条老规律。
        //
        // 扫三个目录：两个生产 target **加测试包**。测试包必须一起扫，因为那里才是漏传真正会发生
        // 的地方（b89a0ee 那个潜伏洞：四个 fixture 漏传，八十余个调用点在用户真实 home 上开锁，
        // 全程 2421 条全绿）。
        //
        // ⚠️ needle **分段拼**，源码里永远不出现连续的那个串：本普查扫的目录**包含本文件**，
        // 把它逐字写进来 = 命中的第一处就是我自己的判据 = 这条断言永久假红。本仓库为这个形状翻过车
        // （`SourceScannerSuite` 的自纠⑤，以及本文件那条 `injected` + `-locks`）。失败消息里的那一份
        // 也是运行时插值，不是源码文本。
        let environmentExtensionMarker = "extension " + "AudioImportEnvironment"
        var environmentExtensions: [String: Int] = [:]
        for root in [
            "gui/Sources/ClaudioGUI", "gui/Sources/ClaudioGUICore",
            "gui/Tests/ClaudioGUICoreTests",
        ] {
            let scanned = sourcesUnder(root)
            expect(
                scanned.count >= 5,
                "在 \(root) 下只数到 \(scanned.count) 个 Swift 文件 —— 这条是**普查**，普查不到文件"
                    + "就永远等不到红，只会安静地绿下去")
            for source in scanned {
                // 读 `code`（剥注释、保留字符串内容）：注释里谈论这个形状的散文**不该**被数到
                // （本 suite 上面就有两段），而一段被误判成字符串的代码同样数不到 —— 后者由本文件
                // 第一条 suite（词法 `unmodeled` 普查）兜着。
                //
                // ⚠️ 喂 `whitespaceTolerantHitCount`（先 collapse 再数），不是直接数 `source.code`
                // 里的固定单空格子串（`/codex review d9f099a,b4091d7,14ec6b1` P1 坐实）：那种判据
                // 只逮得住原样敲一个空格的那一种，`extension  AudioImportEnvironment`（两个空格）、
                // 换行分隔、或块注释隔开（剥完注释后补的那个空格，见 `strippingComments` 的
                // `blockComment` 分支）都是合法 Swift、`swift-format` 不会去改它们，原判据一个字
                // 都读不到。
                let hits = whitespaceTolerantHitCount(of: environmentExtensionMarker, in: source.code)
                if hits > 0 { environmentExtensions["\(root)/\(source.path)"] = hits }
            }
        }
        expect(
            environmentExtensions.isEmpty,
            "有文件给 `AudioImportEnvironment` 开了 `\(environmentExtensionMarker)`："
                + "\(environmentExtensions) —— 本 suite 上面那两条只读 "
                + "`AudioImportEnvironment.swift` 一个文件，一个开在别处的扩展构造器让「漏传包锁 = "
                + "编译错误」当场失效，而它们结构上看不见。这不是「扩展一律不许」的教条：包锁的"
                + "**必填性**是这个类型今天唯一靠编译器执行的不变量，而扩展是绕开它最短的一条路。"
                + "真要加扩展，先把上面那两条改成能读到扩展里的构造器，再来放行这一条")

        // 上面那条 `whitespaceTolerantHitCount` 的**正/负控**：合成输入直接喂**同一个函数**（定义
        // 见 91 行附近，紧跟 `collapsingWhitespace` 之后），不各自重新拼一遍「collapse 再数」——
        // 那样正/负控测的只是「这段逻辑抽象上对不对」，测不出「生产那行有没有真的在调它」（该函数
        // 的 doc comment 里记着这条教训第一版是怎么栽的：生产那行独立改回旧版，正/负控一个字不变，
        // 2472 条检查照样全绿）。现在两边共用同一个函数体，回退生产那一行就是回退这四条正/负控在
        // 测的同一段代码，才会真的红。
        //
        // 真实仓库里从来没人写过两个空格的 `extension`，所以「以前逮不住、现在逮得住」这件事没有
        // 真实文件能验证，只能靠合成输入。
        //
        // ⚠️ 下面四个变体的 needle **分段拼**，与 `environmentExtensionMarker` 自己那行同一个理由：
        // 本条 suite 扫的目录**包含本文件**，若哪个变体在源码里连续写出 `extension AudioImportEnvironment`
        // （哪怕中间隔的是两个空格、一个 `\n`），`source.code` 保留字符串字面量内容，扫到自己这行
        // 就会算作一次命中 —— 上面那条围栏当场对着自己的正/负控假红。第一版就是这么栽的（实测：
        // `swift run` 直接报 `ViewWiringSuite.swift: 2` 次命中）。
        let extensionKeyword = "extension"
        let typeName = "AudioImportEnvironment"
        expect(
            whitespaceTolerantHitCount(
                of: environmentExtensionMarker, in: extensionKeyword + " " + typeName + " {"
            ) == 1,
            "正控基线都读不到 —— 单空格这个最平常的写法本该必中，`whitespaceTolerantHitCount` 本身就是坏的"
        )
        expect(
            whitespaceTolerantHitCount(  // 两个空格
                of: environmentExtensionMarker, in: extensionKeyword + "  " + typeName + " {"
            ) == 1,
            "两个空格的 `extension` 声明没被逮到 —— collapse 没生效，固定单空格子串那个洞原样还在")
        expect(
            whitespaceTolerantHitCount(  // 换行分隔
                of: environmentExtensionMarker, in: extensionKeyword + "\n" + typeName + " {"
            ) == 1,
            "`extension` 和类型名之间换行的声明没被逮到 —— 同一个洞的换行变体")
        expect(
            whitespaceTolerantHitCount(
                of: environmentExtensionMarker, in: extensionKeyword + " " + "SomeUnrelatedType { }"
            ) == 0,
            "负控假红了 —— collapse 之后不该无差别命中任何 `extension` 声明，只该命中"
                + "`AudioImportEnvironment` 那一个")
    }

    suite("生产侧两处显式包锁各自锚到调用点 —— 它们换来了 lockLeaks 普查的两个豁免") {
        // 这条 suite 是上面那条普查两个新豁免项的**对价**。普查按文件名放行它们，这里按**调用点**
        // 逐个绑回来：实参做相等判定，再用实参自己的文本算出该文件应有的 `lockfile` 命中数 ——
        // 多出一个 token 就是第三处锁，当场红。所以豁免换来的是更严，不是更松。
        // `literal` = 该文件里必须**逐字**出现的字符串**内容**。上面读的是清空字符串之后的文本，
        // 字面量在那里一律是空串，于是「占位路径有没有偷偷变成真实路径」在那一路上完全不可判。
        // 这一列补上那一半，而且它**跟着表走** —— 上一版把这半条检查写死在循环外、只覆盖
        // `StateGalleryView.swift` 一个文件，表里再加第三项时那一半会静默不存在；同时循环里
        // `let raw = codeOnly(…)` 绑了却一次没用，Swift 为它报 `immutable value 'raw' was never used`。
        // 那条警告在这台机器上**一直看不见**：每次 build 都是增量的（零条 Compiling），
        // 而 e278736 / 51aebae 的 commit message 写的是「两个包 Build complete 零警告」——
        // `/review d7084be` 用 `--scratch-path` 全新编译一次才把它照出来（8 条，全是这一条）。
        // 这张表现在住在文件级（见 ``expectedProductionLocks`` 的 doc）—— 它同时喂三条断言，
        // 其中一条是下面那条**构造点普查**，而普查按定义不能读一张 suite 私有的表。
        // ⚠️ [10] 「每个豁免项都换来一条更严的锚定绊线」的**可执行**版本（`/review d7084be` 红队 P2）。
        //    上一版这句话只是散文：两张硬编码清单互不绑定，往 `lockCensusExemptedFiles` 加第四项而这里
        //    一条不写 —— 那个文件从此静默退出普查，编译通过、全绿、没有人会喊（豁免侧放宽 = fail-open）。
        //    判据是**集合相等**不是 `count`：数目对得上而成员错位同样是一个没人守的文件。
        expect(
            Set(lockCensusExemptedFiles).subtracting([lockCensusSelfGuardedFile])
                == Set(expectedProductionLocks.map(\.file)),
            "`lockCensusExemptedFiles` 减掉 `\(lockCensusSelfGuardedFile)`（它由本文件另一条 suite 按调用点"
                + "守着）之后，必须**逐项等于** `expectedProductionLocks` 的文件集 —— 否则「豁免换来的是"
                + "更严，不是更松」这句话就有一项没兑现。豁免侧="
                + "\(Set(lockCensusExemptedFiles).subtracting([lockCensusSelfGuardedFile]).sorted())，"
                + "对价侧=\(Set(expectedProductionLocks.map(\.file)).sorted())")

        for expected in expectedProductionLocks {
            // ⚠️ [9] `literal` 是 `String?`，而 `if let` 意味着「没填 ⇒ 不查」—— 那正是这一刀声称要
            //    修掉的 fail-open，只是从「第三项」挪到了「literal 填 nil 的那一项」。
            //    这条把「哪一行**必须**填」从散文变成断言：`value` 里出现被清空的字符串字面量（`""`）
            //    就说明这一处的真实实参含字面量内容，而相等判定对内容恒不可判 ⇒ 必须有 `literal` 那一半。
            expect(
                !expected.value.contains("\"\"") || expected.literal != nil,
                "`expectedProductionLocks` 里 `\(expected.file)` 那一行的 `value` 是 "
                    + "`\(expected.value)` —— 它含一个被清空的字符串字面量，说明真实实参里有字面量内容，"
                    + "而相等判定读的是清空之后的文本、对内容完全不可判。这一行**必须**填 `literal`，"
                    + "否则那半条检查静默不存在（漏填 = 不查 = fail-open）")

            guard let code = codeWithoutStrings("gui/Sources/ClaudioGUI/\(expected.file)"),
                let raw = codeOnly("gui/Sources/ClaudioGUI/\(expected.file)")
            else {
                expect(false, "读不到 \(expected.file) —— 这条 suite 唯一的价值就是读它")
                continue
            }
            let calls = callArguments(of: "AudioImportEnvironment", in: code)
            expect(
                calls.count == 1,
                "\(expected.file) 里必须正好有 1 处 `AudioImportEnvironment(…)` 构造点，实得 "
                    + "\(calls.count) 处 —— 0 处 = 下面两条在守一段不存在的代码，>1 处 = 多出来的那个"
                    + "可能是喂饱断言的死代码诱饵，也可能是一次真实重构，两种都必须有人看一眼再放行")
            for arguments in calls {
                expect(
                    argumentValue("packsLockFile", in: arguments) == expected.value,
                    "\(expected.file) 的 `AudioImportEnvironment(…)` 的 `packsLockFile:` 实参必须**正好"
                        + "是** `\(expected.value)`，实际是 "
                        + "`\(argumentValue("packsLockFile", in: arguments) ?? "<没有这个实参>")` —— "
                        + expected.why
                        + "。（读的是清空字符串内容之后的文本，所以字面量在这里一律是空串 —— 内容"
                        + "由下面那条单独钉。）")
            }
            // 用实参**自己的文本**算出该文件应有的命中数，不写死一个数字：写死的数字与实参一起
            // 漂移时不会有人喊，而这里两者是同一个来源。多出来的每一个 token 都是第三处锁。
            let accounted =
                calls
                .compactMap { argumentValue("packsLockFile", in: $0) }
                .map { "packsLockFile: \($0)".lowercased().components(separatedBy: "lockfile").count - 1 }
                .reduce(0, +)
            let actual = code.lowercased().components(separatedBy: "lockfile").count - 1
            expect(
                actual == accounted,
                "\(expected.file) 里 `lockfile` 命中 \(actual) 次，而上面那个被锚定的包锁实参只解释得了"
                    + " \(accounted) 次 —— 多出来的 \(actual - accounted) 处是**没有人在断言**的第三处锁。"
                    + "这个文件之所以能从 `lockLeaks` 普查里豁免，全部理由就是「它里面的锁都被这条 suite "
                    + "按调用点绑住了」。多一处没绑的，那句话就不成立了")

            // 字面量那一半，**跟着表走**（上一版写死在循环外、只覆盖 StateGalleryView 一个文件）。
            // 上面读的是清空字符串内容之后的文本，字面量在那里一律是空串，于是「占位路径有没有偷偷
            // 变成真实路径」在上面完全不可判 —— 这一条是那一半，读的是 `raw`（保留字符串内容）。
            // 字面量那一半 —— **绑回调用点**，不是全文件 `contains`（`/review d7084be` 红队 P1）。
            //
            // ⚠️ 上一版写的是 `raw.contains(literal)`：全文件、无锚点。于是把真实实参换成
            //    `URL(fileURLWithPath: "/Users/<me>/.claudio/packs.lock")`、同时在文件里任意位置
            //    留一句死代码 `private let note = "/dev/null/claudio-preview-packs.lock"`，三条断言
            //    逐条通过 —— 相等判定读的是清空字符串的文本（两种写法都被清成 `URL(fileURLWithPath: "")`），
            //    而 `contains` 被那句诱饵喂饱。**这与本文件上面亲口判过死刑的见证值形状逐字同构**，
            //    只是换了个位置重开一次。
            //
            //    修法是换**判据种类**（不是换读模型）：从 `raw` 里按同一个调用点切出实参，
            //    在**那一段**里找字面量。同文件别处的诱饵从此够不着。
            if let literal = expected.literal {
                let rawCalls = callArguments(of: "AudioImportEnvironment", in: raw)
                let rawValue = rawCalls.compactMap { argumentValue("packsLockFile", in: $0) }.first
                // 切不出来一律判红（围栏，不是探针）——`raw` 保留字符串内容，一句带 `(` 的字面量
                // 会把配平括号的扫描带偏，那时我们**不知道**自己在看什么，不能默认它是对的。
                expect(
                    rawValue != nil,
                    "从 \(expected.file) 的**原始文本**（保留字符串内容）里切不出 "
                        + "`AudioImportEnvironment(…)` 的 `packsLockFile:` 实参 —— 切不出来就无从判定"
                        + "字面量内容，而「无从判定」必须落在红那一侧。实得 \(rawCalls.count) 处调用")
                expect(
                    rawValue?.contains(literal) == true,
                    "\(expected.file) 的 `packsLockFile:` **实参本身**里必须逐字出现 `\(literal)`，"
                        + "实得 `\(rawValue ?? "<切不出来>")` —— 上面那条相等判定读的是清空字符串内容"
                        + "之后的文本（`\(expected.value)`），对「字面量换成了什么」完全不可判；这一条是"
                        + "那一半。判据绑在**调用点**上而不是全文件：同文件别处留一句提到该串的死代码"
                        + "喂不饱它。preview 是 `#if DEBUG` 里的代码，没有任何行为测试跑它，一条指向"
                        + "真实 home 的占位路径不会有别的东西喊")
            }
        }
    }

    suite("注入包锁的构造点全测试包只此一处 ——「唯一来源」这句散文的可执行版本") {
        // ## 它治的病
        //
        // `AudioImportFixtures.swift` 的 doc 把 ``injectedPacksLock(under:)`` 称作「**全包唯一来源**」。
        // 那句话在 `/codex review 95d16a5,b89a0ee,37745f2` 之前是**假的**：`OnboardingActionsSuite` 的
        // `FixtureTargets.init` 里另有一段**同形而不同源**的内联构造。代价不是理论上的 —— d7084be
        // 那一刀为了同一个病要改**两处**，而只改一处不会有任何断言变红。
        //
        // 两处已经合并。这条普查是那句话的**可执行版本**：散文说「唯一」，就得有人数着。
        //
        // ## ⚠️ 判据不能是会被自己污染的那次 grep
        //
        // 这条普查扫的是 `gui/Tests/ClaudioGUICoreTests` —— **包含本文件**。把目录名逐字写进本文件，
        // grep 当场多命中一处，命中的还是我自己的判据。本仓库为这个形状翻过车（`SourceScannerSuite`
        // 里那条自纠⑤：「`packsLockBusy` 在整个 `gui/` 目录零命中」—— 写下这句话本身就把这个词写进了
        // `gui/`）。所以 needle **分段拼**，源码里永远不出现连续的那个串；失败消息里的那一份是运行时
        // 插值，不是源码文本。
        //
        // 读 `code`（剥注释、**保留字符串内容**）而不是 `codeWithoutStrings`：要数的东西
        // （`"injected-locks-\(nonce)"`）本身就是一个字符串字面量，清空内容会把靶子一起清掉。
        // 代价如实标注：注释里谈论这个目录名的散文不会被数到（那是**想要**的，本文件下面就有几段），
        // 但一段被误判成字符串的代码同样数不到 —— 后者由本文件第一条 suite（`unmodeled` 普查）兜。
        //
        // ## ⚠️ 它的天花板，别把措辞写大
        //
        // 它按**这一种形状的目录名**认人。一个换了名字的第二处构造（`fixture-locks-<nonce>/…`）它
        // 认不出来。所以它守的是「**同一个病原样复发**」（这正是实际发生过的那一种），**不是**
        // 「所有可能的第二来源」。真正管住「值必须来自被注入的那把锁」的是持锁行为测试。
        let lockDirectoryMarker = "injected" + "-locks"
        let testSources = sourcesUnder("gui/Tests/ClaudioGUICoreTests")
        expect(
            testSources.count >= 20,
            "在 gui/Tests/ClaudioGUICoreTests 下只数到 \(testSources.count) 个 Swift 文件 —— 这条是"
                + "**普查**，普查不到文件就永远等不到红，只会安静地绿下去（实测该目录下有三十余个）")
        let constructionSites = testSources
            .filter { $0.code.contains(lockDirectoryMarker) }
            .map(\.path)
        expect(
            constructionSites == ["AudioImportFixtures.swift"],
            "注入包锁的构造点不是恰好一处（实得 \(constructionSites)）—— 期望只有 "
                + "`AudioImportFixtures.swift` 里的 `injectedPacksLock(under:)`。"
                + "多出来一处 = 又一份**同形而不同源**的拷贝：它今天可能写得一模一样，但下次给这个"
                + "形状打补丁（比如把固定名字换成运行时随机成分，d7084be 干的正是这件事）只改一处"
                + "不会有任何断言变红，另一处静默留在可派生的老位置上，而那正是「就地算一把锁」的"
                + "变异体求值出来会撞上的地方 —— 持锁行为测试于是全绿，保护力归零。"
                + "少了那一处 = 要么文件改名了（把这条断言的期望值一起更新），要么唯一来源没了"
                + "（那 `AudioImportFixtures.swift` 的 doc 里「全包唯一来源」那句话又变回散文）")
    }

    suite("生产侧 `AudioImportEnvironment(…)` 构造点**普查** ——「两个构造点」那句散文的可执行版本") {
        // ## 它治的病（`/codex review 51aebae,7caf6dc,e278736` 的 P1-B，隔离 worktree 实测坐实）
        //
        // `AudioImportEnvironment.swift` 的 doc 逐字写着「生产侧两个构造点显式写出真实路径，
        // **各自有绊线看着**」。那个「两个」此前是一句**没有任何东西在数**的散文：上面那条
        // 「生产侧两处显式包锁各自锚到调用点」按 ``expectedProductionLocks`` 里**硬编码的两个
        // 文件名**逐一去读，它不枚举任何目录 —— 措辞比覆盖范围大，本仓库第 N 次，而这一次长在
        // 「把绊线从硬编码文件升成围栏」那一刀**自己**身上。
        //
        // 实测的第三构造点（往 `gui/Sources/ClaudioGUICore/` 放一个文件）：
        //
        // ```swift
        // public func makeAudioImportEnvironmentForPack(
        //     at d: URL, durationProbe: any AudioDurationProbing
        // ) -> AudioImportEnvironment {
        //     AudioImportEnvironment(
        //         userPacksDirectory: d, durationProbe: durationProbe,
        //         packsLockFile: d.appendingPathComponent("packs.lock"))   // 就地算一把锁
        // }
        // ```
        //
        // —— `swift build` 零诊断、**2456 条检查全绿**、一条都不红。三张网一张都罩不到它：
        // `lockLeaks` 只扫 `gui/Sources/ClaudioGUI`（`guiSources()`）；`guiCoreSources()` 那条只禁
        // `playLockFile` 与字面量 `play.lock`；`SourceScannerSuite` 的 T3 四条腿只纳入**代码里出现
        // `mutateManifestJSON` 的文件**，而一个环境**工厂**一个字节的 manifest 都不写。
        //
        // 它一旦被任何一个 manifest 写者用上，那个写者转发的**文本**依旧逐字是
        // `environment.packsLockFile`（第四条腿全绿 —— 它守的是转发，不是被转发的那把锁自己
        // 从哪来），求值出来却是包目录里的另一把锁：与 helper `performFirstRunSetup` 在
        // `~/.claudio/packs.lock` 上取的那把**永不冲突** ⇒ 跨进程互斥断开 ⇒ 用户刚绑好的音效被
        // 包发布循环整目录 `moveItem` 吞掉，而那次写照旧返回 `.success`。
        //
        // ## 为什么挂在这里而不是给上面那条再补一个文件名
        //
        // 与第四条腿搬家时逐字同一个理由：新构造点最可能的落点是**新文件**（`gui/Package.swift`
        // 没有 `sources:` 白名单，默认目录下任意 `.swift` 直接进 target），而一张文件名清单
        // 结构上读不到它。所以这里数的是**目录**，期望值从 ``expectedProductionLocks``（文件级
        // 单源）派生 —— 不是第三张互不绑定的硬编码清单。
        let productionRoots = [
            (root: "gui/Sources/ClaudioGUI", target: "ClaudioGUI"),
            (root: "gui/Sources/ClaudioGUICore", target: "ClaudioGUICore"),
        ]
        var constructionCensus: [String: Int] = [:]
        var scannedFileCount = 0
        var unreadable: [String] = []
        var hiddenShapes: [String: [String]] = [:]
        for entry in productionRoots {
            for source in sourcesUnder(entry.root) {
                scannedFileCount += 1
                let key = "\(entry.target)/\(source.path)"
                // 喂 `codeWithoutStringLiterals`，**不是** `code`：后者保留字符串内容，一句
                // `"pack (1.json"` 里的 `(` 会被计进深度、括号从此永不配平（`callArguments` 的
                // doc 里立着这条判例）。`sourcesUnder` 只交 `code`，所以这里按相对路径再要一次。
                guard let code = codeWithoutStrings("\(entry.root)/\(source.path)") else {
                    unreadable.append(key)
                    continue
                }
                let count = callArguments(of: "AudioImportEnvironment", in: code).count
                if count > 0 { constructionCensus[key] = count }

                // 围栏那一半：`callArguments` 是白名单（`head(` / `head (` / `head.init(` /
                // `head .init (` 四种），而白名单永远不完整。凡是**结构上认不出**的构造形状都必须
                // 变成红 —— 「我读不到它怎么构造的」绝不等于「它没事」。
                //
                // ⚠️ 只对**提到这个类型名的文件**跑，理由不是省事，是极性：跨文件别名
                // （`typealias AIE = AudioImportEnvironment` 在 A、`AIE(…)` 在 B）的**声明那一行**
                // 必然含类型名 ⇒ A 会被纳入 ⇒ 红。所以这个收窄对别名那一类是 fail-closed。
                //
                // ⚠️ 过滤掉「条件编译」那一类，而这**有论证**、不是随手收窄：`unmodeledConstruction`
                // `Shapes` 记 `#if` 的理由是「非活跃分支的构造点会替真实构造喂饱『≥1 处 / 正好 N 处』
                // 那类断言」。本条的判据是**集合相等**（文件 → 计数），`#if` 只会让计数**偏多**、
                // 让键**变多**，两种都是红 —— 它在这条判据上不构成隐身路径。不过滤则
                // `StateGalleryView.swift`（整份 `#if DEBUG`）永久假红，然后被下一个人删掉。
                //
                // ⚠️ 如实标注够不到什么：一个**完全不提**这个类型名的文件里、**实参位置**的
                // 上下文推断构造（`someCall(environment: .init(…))`）——本条既数不到它，也不会
                // 对它记账。要够到那一类，得把这条围栏扩到两个 target 的**每一个**文件，而那需要
                // 先给 `= .init(` 这种在 SwiftUI 代码里合法且常见的写法定一个策，不在本刀范围内。
                if code.contains("AudioImportEnvironment") {
                    let shapes = unmodeledConstructionShapes(
                        of: "AudioImportEnvironment", in: code
                    ).filter { !$0.contains("条件编译") }
                    if !shapes.isEmpty { hiddenShapes[key] = shapes }
                }
            }
        }
        expect(
            scannedFileCount >= 10,
            "两个生产 target 加起来一个 Swift 文件都没数到（实得 \(scannedFileCount)）—— 这条是"
                + "**普查**，普查不到文件就永远等不到红，只会安静地绿下去")
        expect(
            unreadable.isEmpty,
            "这些生产源文件读不出来：\(unreadable) —— 读不到 ⇒ 那个文件里的构造点对本普查**隐身**，"
                + "而隐身在这条判据上是静默放行。认不出 ⇒ 红，不许静默跳过")
        expect(
            hiddenShapes.isEmpty,
            "这些文件里出现了 `callArguments` **结构上认不出**的 `AudioImportEnvironment` 构造形状："
                + "\(hiddenShapes) —— 那一处会静默退出本普查，而普查是「就地算一把锁的第三个构造点」"
                + "唯一的守卫。要么把它改成扫描器认得的直接构造，要么先把 `callArguments` 教会这个"
                + "形状再放行")

        var expectedCensus: [String: Int] = [:]
        for expected in expectedProductionLocks {
            expectedCensus["ClaudioGUI/\(expected.file)"] = 1
        }
        expect(
            constructionCensus == expectedCensus,
            "生产侧 `AudioImportEnvironment(…)` 的构造点集合必须**逐项等于** "
                + "\(expectedCensus.keys.sorted())，实得 \(constructionCensus) —— "
                + "多出来的那一处就是一个**没有任何断言在看**的包锁来源：上面那条按调用点锚定的 "
                + "suite 只读 ``expectedProductionLocks`` 里点名的文件，它对一个新文件结构上是瞎的。"
                + "它若就地算一把锁（`packDirectory` 的兄弟位、每包一把的 `<id>.lock`），这个环境喂给"
                + "任何 manifest 写者之后，那个写者与 helper 的 `performFirstRunSetup` 就用上**两把"
                + "不同路径**的 `flock` ⇒ 跨进程互斥当场断开 ⇒ 用户刚绑好的音效被包发布循环整目录 "
                + "`moveItem` 吞掉，而那次写照旧返回 `.success`。"
                + "少了一处 = 要么文件改名/构造点搬家（把 ``expectedProductionLocks`` 一起更新），"
                + "要么它被换成了本普查认不出的形状（上面那条围栏该先红）。"
                + "**不许**靠往 ``expectedProductionLocks`` 里加一行让新构造点变绿：那张表同时是"
                + "`lockLeaks` 豁免名单的对价侧，加一行会让豁免绑定那条集合相等**当场红** —— "
                + "两条断言咬合在一起，正是要的那次停顿")
    }

    suite("ClaudioGUIApp.swift 的 AudioImportEnvironment(…) 必须显式传 factoryPacksDirectory —— 否则 builtinPackIDs 生产环境恒为空集") {
        // ## 它治的病（swift-reviewer 终审 blocker，PLAN-SOUND-MANAGER.md T6 验收表实测未过）
        //
        // `factoryPacksDirectory` 有默认值 `nil`（大多数测试 fixture 不需要它，见其 doc）。但生产侧
        // **唯一**那一处构造点如果沿用默认值，`environment.builtinPackIDs` 就恒为空集
        // （``AudioImportEnvironment/builtinPackIDs`` 的实现：`factoryPacksDirectory == nil` ⇒ `[]`），
        // T6「内置包只读」唯一的判据 `environment.builtinPackIDs.contains(packID)` 对任何包永远是
        // `false` —— 用户依旧能直接拖文件覆盖『极简铃音』，这正是 T6 想根治的那个 bug 以完全相同的
        // 方式原地复发。而 `swift run claudio-gui-tests` 全绿掩盖了这一点：全部测试都走显式注入
        // `factoryPacksDirectory` 的 fixture（`AudioImportFixtures.swift`），唯独这一个生产构造点
        // 不受任何 fixture 覆盖 —— 上面那条「生产侧 `AudioImportEnvironment(…)` 构造点普查」按
        // ``expectedProductionLocks`` 逐调用点锚的是 `packsLockFile:` 一个实参，从未看过
        // `factoryPacksDirectory:`。这条补的就是那半条缺口。
        //
        // ## 为什么不塞进 ``expectedProductionLocks`` 那张表
        //
        // 那张表是**文件级单源**，同时喂三条断言（豁免绑定的集合相等 / 逐调用点包锁实参锚定 /
        // 构造点普查的期望计数）——它的字段（`value` / `literal`）与「跟着表走」的相等判定全部是
        // 为 `packsLockFile:` 一个实参设计的。硬塞第二个实参会让那三条断言的语义变得含糊（豁免的
        // 对价到底是「这把锁被钉住」还是「这两个实参都被钉住」？）。这里单开一条自成一体的 suite，
        // 只读 `ClaudioGUIApp.swift` 这一个已知的、唯一合法的构造点，不重新发明普查。
        guard let code = codeWithoutStrings("gui/Sources/ClaudioGUI/ClaudioGUIApp.swift"),
            let raw = codeOnly("gui/Sources/ClaudioGUI/ClaudioGUIApp.swift")
        else {
            expect(false, "读不到 ClaudioGUIApp.swift —— 这条 suite 唯一的价值就是读它")
            return
        }
        let calls = callArguments(of: "AudioImportEnvironment", in: code)
        expect(
            calls.count == 1,
            "ClaudioGUIApp.swift 里必须正好有 1 处 AudioImportEnvironment(…) 构造点，实得 "
                + "\(calls.count) 处 —— 0 处 = 下面的断言在守一段不存在的代码，>1 处 = 多出来的那个"
                + "需要有人看一眼再放行")
        guard let arguments = calls.first else { return }

        let expectedValue = "Bundle.main.resourceURL?.appendingPathComponent(\"\")"
        let actualValue = argumentValue("factoryPacksDirectory", in: arguments)
        let actualDescription =
            actualValue
            ?? "<没有这个实参 —— 默认值 nil 会静默生效，builtinPackIDs 在真实出货的 app 里恒为空集>"
        expect(
            actualValue == expectedValue,
            "ClaudioGUIApp.swift 的 AudioImportEnvironment(…) 的 factoryPacksDirectory: 实参必须**正好"
                + "是** `\(expectedValue)`（字符串内容被清空之后的文本），实际是 `\(actualDescription)` "
                + "—— release.yml 把 minimal-chime 打进 Contents/Resources/packs/，这一处实参是唯一"
                + "把它接进 T6 只读判据的线，PLAN-SOUND-MANAGER.md §2.3/T6 点名的来源就是 "
                + "`Bundle.main.resourceURL` + `packs`")

        // 字面量那一半：上面读的是清空字符串内容之后的文本，"packs" 这个目录名在那里已经不可判。
        // 判据绑在**这一处调用点**上（`raw` 里同一个调用的实参文本），不是全文件 contains —— 同一
        // 病同一修法，见上面「生产侧两处显式包锁各自锚到调用点」那条 suite 的 doc。
        let rawCalls = callArguments(of: "AudioImportEnvironment", in: raw)
        let rawValue = rawCalls.compactMap { argumentValue("factoryPacksDirectory", in: $0) }.first
        expect(
            rawValue != nil,
            "从 ClaudioGUIApp.swift 的**原始文本**（保留字符串内容）里切不出 "
                + "AudioImportEnvironment(…) 的 factoryPacksDirectory: 实参 —— 切不出来就无从判定"
                + "字面量内容，而「无从判定」必须落在红那一侧。实得 \(rawCalls.count) 处调用")
        expect(
            rawValue?.contains("\"packs\"") == true,
            "ClaudioGUIApp.swift 的 factoryPacksDirectory: **实参本身**里必须逐字出现 `\"packs\"`，"
                + "实得 `\(rawValue ?? "<切不出来>")` —— 判据绑在这一处调用点上，同文件别处提到"
                + "「packs」的死代码喂不饱它")
    }

    suite("锁转发的**编译期前提**：`mutateManifestJSON` 的 `lockFile:` 不许有默认值") {
        // ## 这条 suite 取代了什么
        //
        // 这里原本是一条「`ManifestBinding.swift` 的每一处 `lockFile:` 都必须是转发来的那把」的绊线。
        // 它的**措辞**（suite 标题与失败消息都逐字写着「每一处」「一个新增的、没人测的调用点」）比它
        // 的**覆盖范围**大了整整一个目录树：它读的是**一个硬编码文件**
        // （`codeWithoutStrings("gui/Sources/ClaudioGUICore/ManifestBinding.swift")`），而新调用点最
        // 可能的落点恰恰是**新文件** —— `gui/Package.swift` 没有 `sources:` 白名单，默认目录下任意
        // `.swift` 直接进 target，连 manifest 都不用改。实测（`/codex review 95d16a5,b89a0ee,37745f2`
        // 的 P1-B）：往 `ClaudioGUICore` 里塞一个就地算锁的第三写者，两个包 Build complete 零警告，
        // 整套 2411 条断言**一条都不红**。
        //
        // 那条判定现在住在 `SourceScannerSuite` 的 T3 内容围栏里，作为**第四条腿** —— 那台机器递归
        // 枚举 `gui/Sources`（两个 target）、按内容纳入、点开头/`UF_HIDDEN`/symlink/属性读不到全部
        // 已建模，而且是全仓唯一一条有合格递归自证的枚举。它的三个独占靶子（就地派生 / 硬编码真实
        // 路径 / 子目录）与两条极性腿（认不出的用法 / 条件编译）各配了常驻正/负控，跑遍两个
        // `pathPrefix` 向量。删这条之前逐条确认过靶子都已搬走 —— 除了下面这一个。
        //
        // ## 唯一没搬走的那个靶子，就是这条 suite
        //
        // 老绊线有一条 `!sites.isEmpty` 兜底：「一处 `lockFile:` 都找不到 ⇒ 红」。它**不能**原样搬进
        // 第四条腿 —— 那条腿的宿主 suite 里有几十个 `mutateManifestJSON()` 无实参形状的合成 fixture
        // （它们是另外三条腿的正/负控），一条 `isEmpty ⇒ 红` 会让它们集体假红，而最省事的修补
        // （「文件里已出现 `lockFile:` 才检查」）恰好把极性改回 fail-open。红队实测过这条路。
        //
        // 所以把它换成**更硬**的那一种：钉住形参**没有默认值**。这样「漏传锁」在生产上是一次
        // **编译错误**，根本到不了第四条腿；第四条腿因此可以对「取不到 `lockFile:` 标签」的调用点
        // 安心沉默，而那份沉默由这条 suite 背书 —— 两条合起来才是完整的极性，单独任何一条都不是。
        //
        // ⚠️ 为什么编译器强制**不能**给它自己背书：给形参加回一个默认值是一次**放宽**，现存调用方
        // 全都显式传着值，加完 `swift build` 零诊断（本文件与 `ManifestBinding.swift` 各记着同一句话
        // 的两个判例：`@MainActor` 与 `async`）。编译器强制的是默认值的*后果*，从不是它的*不存在*。
        guard let manifest = codeWithoutStrings("gui/Sources/ClaudioGUICore/ManifestBinding.swift")
        else {
            expect(false, "读不到 ManifestBinding.swift —— 这条 suite 唯一的价值就是读它")
            return
        }
        // 正向：形参在。它若整个消失（原语改从别处取锁），第四条腿会对每一处调用点取不到标签而
        // **静默**，整条锁转发判定退化成对空集的恒真绿 —— 那正是老绊线 `!sites.isEmpty` 守的东西。
        expect(
            collapsingWhitespace(manifest).contains("lockFile: URL"),
            "`mutateManifestJSON` 的形参表里找不到 `lockFile: URL` —— 要么读-改-写原语不再按锁参数"
                + "取锁（那 `SourceScannerSuite` 第四条腿就是在守一段不存在的代码：它逐处取 "
                + "`lockFile:` 标签，取不到就沉默，整条判定对空集恒真绿），要么扫描器读串了。"
                + "两种都必须有人看一眼再放行")
        // 负向：不许有默认值。`lockFile: URL = ClaudioPaths.packsLockFile` 会让**漏传**从编译错误
        // 变成静默生效，而 `claudio-gui-tests` 压根不编译 `ClaudioGUI`，那一手在测试进程里无人看守。
        expect(
            !collapsingWhitespace(manifest).contains("lockFile: URL ="),
            "`mutateManifestJSON` 的 `lockFile:` 形参被加上了**默认值** —— 漏传这把锁从此不再是编译"
                + "错误，而是静默落回那个默认值。包锁只有一个来源：调用方转发进来的那把；一个默认值"
                + "就是第二个来源，两个 manifest.json 写者从「同一个源」退化成「两个碰巧相等的常量」，"
                + "而 `SourceScannerSuite` 第四条腿对「没有 `lockFile:` 标签」的调用点是**沉默**的"
                + "（那份沉默正是靠这一条背书）。要加默认值，先把那条腿的极性一起改了")
    }

    suite("ClaudioGUICore 的代码里一个字都不许出现 play 的去抖锁（两套绊线中间那条缝）") {
        // 见 `guiCoreSources()` 的文档：这个 target 是 `guiSources()`（只扫 ClaudioGUI）与
        // `LockSeparationSuite`（只读 helper/）双方的盲区，而接管路径把两把锁灌进 `SetupEnvironment`
        // 的那个构造点（`OnboardingActions.swift:589-596`）就住在这里。
        let sources = guiCoreSources()
        expect(
            sources.count >= 5,
            "在 gui/Sources/ClaudioGUICore 下一个 Swift 文件都没数到（实得 \(sources.count)）—— "
                + "下面那条是**普查**，普查不到任何文件就永远等不到红，只会安静地绿下去")

        // 与 PanelView 那条同样连**值级假名**一起拦：`ClaudioPaths.root.appendingPathComponent`
        // `("play.lock")` 拿到的是同一把去抖锁，而标识符 `playLockFile` 一次都不出现。
        var debounceLockLeaks: [String: Int] = [:]
        for file in sources {
            let byIdentifier = file.code.components(separatedBy: "playLockFile").count - 1
            let byLiteral = file.code.components(separatedBy: "play.lock").count - 1
            let count = byIdentifier + byLiteral
            if count > 0 { debounceLockLeaks[file.path] = count }
        }
        expect(
            debounceLockLeaks.isEmpty,
            "ClaudioGUICore 的**代码**里出现了 playLockFile 或字面量 `play.lock`：\(debounceLockLeaks) —— "
                + "这个 target 里的每一个写者写的都是 config.json（静音、切包）或 settings.json"
                + "（接管、断开），**一个字节都不写 play.state**。让它们中的任何一个去占去抖锁，"
                + "就是在用户点下按钮之后的那几秒里，把他的每一声提示音静默吞掉 —— 而那正是他"
                + "最需要听见反馈的一刻。谁守哪把锁由 `OnboardingActionsSuite` 的四条持锁行为断言钉死；"
                + "这一条只是把最要命的那把锁从整个 target 里赶出去")
    }

    suite("接管路径必须把**包锁**也灌进 SetupEnvironment（第三把锁，与前两把同一个洞）") {
        // `OnboardingActions.swift` 造 `SetupEnvironment` 时逐个转发 `configLockFile` /
        // `settingsLockFile`。本轮给 setup 加了**第三把**锁（`packsLockFile`），而它一开始
        // **没有**被转发 —— `SetupEnvironment.packsLockFile` 于是落回 `ClaudioPaths` 那个指向
        // **真实** `~/.claudio/packs.lock` 的默认值。
        //
        // 生产上这碰巧是对的（GUI 侧 bind 用的也是那个默认值，两边仍然互斥）。**测试里不是**：
        // 接管测试给其它每一样东西都注入了临时路径，唯独这把锁会去用户的 home 上开一把真锁。
        // 实测症状：跑完测试之后 `~/.claudio/packs.lock` 真的躺在那里（0 字节、0600，正是
        // `FileLock` 的 `open(O_CREAT, 0o600)` 留下的）。
        //
        // 这就是 memory 里记着的「接管路径的锁要过四手，而中间那一手住在 ClaudioGUICore」——
        // 加第三把锁的那一刀（也就是我自己这一刀）原样重犯了一次。
        //
        // 读 `codeWithoutStrings`（剥注释**且清空字符串内容**）而不是 `codeOnly`。`/codex review
        // 48b6730` 的 P1 给了逐字变异体 —— 在 `OnboardingActions.swift` 里加一句
        // `let witness = "packsLockFile: environment.packsLockFile"`，再把真实实参换成局部别名
        // （`let fallback = ClaudioPaths.packsLockFile` → `packsLockFile: fallback`）。台账实测
        // （M1-old / M1-fixed 一对）：`codeOnly` 下两条断言**全绿**，`codeWithoutStrings` 下**红**。
        //
        // ⚠️ 但「两条全绿」的成因**不同**，这一刀也只救回来一条 —— 说清楚，别把功劳记大了：
        //  · **正向**那条（下面 `contains(…environment.packsLockFile)`）是被那句 `witness` 字面量
        //    喂饱的**假绿**。这一换关掉的就是这条轴 —— 只是这条轴，不是这条断言（它还有别的洞，
        //    见下面第四段）。
        //  · **负向**那条（`!contains("packsLockFile: ClaudioPaths.")`）绿跟字符串**无关**：它是被
        //    别名躲开的 —— 变异体写的是 `packsLockFile: forgeryFallback`，那个 needle 一次都没出现。
        //    换读取函数对它一点忙都帮不上，它今天仍然拦不住「换个局部别名」这一手。
        //
        // 而且对**纯负向**断言，这一换在极性上是**放宽**不是收紧：`codeOnly` 保留字符串内容 ⇒ 更容易
        // 命中 ⇒ 更容易红（fail-closed，代价是假红）；`codeWithoutStrings` 清空 ⇒ 更容易绿
        // （fail-open，代价是假绿）。这里仍然换，是因为两条断言共用一次读取，而**正向**那半是承重的
        // （台账坐实），负向那半本就不靠字符串这条轴。
        //
        // MasterVolumeRow 那条 suite 做的是同一个动作（也为正向那半统一换了读取路），但它的行内注释
        // 把负向那半的 `codeOnly` 成本只记成「**假红**」。fail-open 这一面 `TestSupport.swift` 早就写过
        // 两遍（文件头 L14-15、``StrippedSwiftSource`` 的 doc L80-81），还称它为「两套源码绊线唯一的、
        // 共同的致命失效模式」—— 这里只是把它落到这条 suite 上。
        //
        // ⚠️⚠️ 这一换关掉的是**四条已实测通道里的一条**。台账第二轮（`/codex review 48b6730` 之后
        // 那轮红队逼出来的，三条全部在本机 `swift run claudio-gui-tests` 上跑过，不是纸上推理）：
        //
        //  R1 **第二手无守卫**（红队 F1，最要命的一条）：把 `OnboardingActionEnvironment.init` 里的
        //     存储赋值改成 `self.packsLockFile = ClaudioPaths.packsLockFile`，**调用点一字不动** ——
        //     下面两条断言读的是调用点那行文本，照常命中 ⇒ **整套 gui 测试全绿**，而注入的临时路径在赋值
        //     那一手就被丢掉了，接管测试**真的**在用户 `~/.claudio/packs.lock` 上开了锁（台账跑完
        //     那个 0 字节 0600 的文件真的躺在那儿）。这条**任何**文本绊线都够不着：调用点的实参
        //     字面就是 `environment.packsLockFile`，完全合规，错的是它求值出来的**值**。
        //  R2 **尾部未锚**：`packsLockFile: environment.packsLockFile.deletingLastPathComponent()`
        //     `.appendingPathComponent("packs2.lock")` 逐字包含 needle ⇒ 全绿，而这把锁已经不是 GUI
        //     侧那把，互斥归零。与 `LockSeparationSuite` 的 ``argumentValue`` doc 里记的判例同形。
        //  R3 **死代码供养**：真实实参换成局部别名，另起一个永不被调用的函数供养 needle ⇒ 全绿，
        //     真实 home 上的锁同样被创建。字符串插值 `\(…)` 里的同名调用同理（插值里的代码是
        //     `codeWithoutStringLiterals` **按设计**保留的），`#if` 非活跃分支同理。
        //
        // 所以真正的收紧分两层，缺一不可：
        //  · R2/R3 这一层用「按调用点绑实参」封（`LockSeparationSuite` 的 ``callArguments`` /
        //    ``argumentValue`` 那一路 —— 锚到 `SetupEnvironment(` 调用点、对实参做**相等**判定而非
        //    `contains`）。正向、负向两条都要换。
        //    （**这里原本还写着「再加一条『本文件恰好一处构造点』的计数」——那一句是假的**：下面的
        //    实现**刻意没有**写 `calls.count == 1`，理由逐字写在它自己那段注释里。同一段注释隔
        //    五十行自己打自己，`/codex review ceae86e` 的 P2 逮到。留着这条自纠当判例：一段专门
        //    为「措辞比覆盖范围大」而写的注释，连它自己开的方子都会与实现漂移。）
        //  · **R1 这一层只有行为测试封得住** —— 持住**被注入的那把** `packsLockFile` 跑一次接管、
        //    断言它停在 `.packsLockBusy`。
        //
        //    判据不写「grep 零命中」那种会被本注释自己污染的说法（第一稿就是这么写的，写完当场
        //    自我证伪）。曾经写的是数 `FileLock(path: targets.<X>LockFile.path)` 的出现次数
        //    「config 2、settings 2、packs **0**」—— 那个 0 是**行为兜底还不存在**时的快照，
        //    行为测试落地当天它就变成了 1，而这段散文没跟着改，于是「可执行判别式」自己成了谎话
        //    （同一条 P2 的另一半）。**计数式引用天然会腐烂**，本仓库为它翻过不止一次车。
        //
        //    所以不再在散文里记数字：要知道行为兜底还在不在，读
        //    `OnboardingActionsSuite` 里那条「持住 packs.lock → 必须停在包发布上」的 suite 本身。
        //    它在不在，是一条 suite 的存废，不是一个会漂移的计数。
        //
        // 这条规矩本文件早就写着：逐字版在 ``closureBody(after:in:)`` 的 doc 里，MasterVolumeRow 那条
        // suite 的行内注释重复过一遍。加第三把锁的这一刀照样没照着做 —— 「写下警告不等于守住它」
        // 这句话，上一个提交刚在自己的 commit message 里写过。
        //
        // 附自纠，全是这段注释**自己**在成稿过程中犯的，留着当判例 —— 它们比上面任何一条结论都
        // 更能说明这个病的复发力：一段专门为「措辞比覆盖范围大」而写的注释，每一稿都在犯它。
        // （不写「共几条」：计数正是这段注释翻过车的东西之一，见 ③。）
        //  ① 第一稿把出处写成「``codeWithoutStrings(_:)`` 的 doc、T17i 那条」—— 前者挂错（那个 doc
        //     讲的是「看代码结构的断言」，不是「负向断言」这条），后者**是我凭空造的编号，本文件里
        //     根本没有 T17i**。
        //  ② 第一稿写「下面两条断言都能被一句字符串字面量伪造」—— 对着变异体核，只有正向那条是。
        //  ③ 第二稿（也就是①的自纠本身）把出处改写成「MasterVolumeRow 与 **EventRowView** 那几条
        //     suite 各自重复过一遍」—— 实测 EventRowView 三处读取里只有「三槽焦点身份各自恰好一个
        //     owner」那条重复了；「禁用的试听 ▶ 不会被无障碍合并抢播」那条只字未提；而「文件名 Menu
        //     的『清除绑定』菜单项」那条写的是**反面** —— 它逐字论证为什么那里该用 `codeOnly`（要断的
        //     是字面量标签本身）。自纠自己又挂错了一次出处。现在也不写计数。
        //     （按 suite 名指，不写行号：这三处的行号在本段注释写下之后就被本段自己推移了
        //     1192/1234/1303 → 1211/1253/1322。行号是会腐烂的引用，本仓库为它翻过车。）
        //  ④ 第三稿写「fail-open 这一面本仓库此前没写下来过，这里是第一次」—— `TestSupport.swift`
        //     的文件头与 ``StrippedSwiftSource`` 的 doc 已经各写过一遍，还称它为「两套源码绊线唯一
        //     的、共同的致命失效模式」。声称首创之前先 grep。
        //  ⑤ 又一稿写「`packsLockBusy` 在整个 `gui/` 目录零命中」—— 写下这句话本身就把这个词写进了
        //     `gui/`，grep 当场命中三处，全是我自己的散文。**判据不能是「会被自己污染的那次 grep」**
        //     （memory 里那条「守卫不能读它自己守的输出」的同一形状）。改成数
        //     `FileLock(path: targets.…LockFile.path)` 的出现次数 —— 那个串只会长在代码里。
        //
        // ③④ 是 `/codex review 48b6730` 之后那轮红队逮到的（F3-eventrowview-attribution-wrong /
        // F4-fail-open-novelty-claim）—— 值得记一笔：这两条在红队自己的三人证伪投票里被判成
        // 「已证伪」，实测却都成立。多数投票在这种「核对散文出处」的 finding 上不可靠。
        guard let actions = codeWithoutStrings("gui/Sources/ClaudioGUICore/OnboardingActions.swift")
        else {
            expect(false, "读不到 OnboardingActions.swift —— 这条 suite 唯一的价值就是读它")
            return
        }
        // 按**调用点绑实参**，不是全文件 `contains`（`LockSeparationSuite` 为同一个病立过判例，
        // 那两个 helper 现在住在跨包哨兵区块里，两包共用同一份实现）。三条已实测的伪造通道
        // （R2 尾部未锚 / R3 死代码供养 needle / 插值里的同名调用）全靠这一换关掉：
        //  · 头由 `SetupEnvironment(` 锚、尾由配平右括号锚 ⇒ 只看真正的构造点，死代码里那个也是
        //    构造点、于是**也要**被查，而不是替真调用点背书；
        //    ⚠️ 上面这半句**曾经是假的**（`/codex review ceae86e` 的 P1）：它成立的前提是扫描器
        //    看得见**真实**构造点，而上一版只认裸 `SetupEnvironment(` 这一种形式。实测：把真实构造
        //    改写成 `let x: SetupEnvironment = .init(…)`（连同另外四种形式，全部编译得过），扫描器
        //    识别出 **0** 处；再加一个 `DecoySetupEnvironment(…)` 死代码诱饵（逐字包含 needle、写得
        //    完全合规）喂饱 `!isEmpty`，**整套 gui 测试全绿**，而真实构造已经彻底退出审查。
        //    现在三头一起堵：``callArguments(of:in:)`` 的**左词边界**杀诱饵替身那一路、它多认的
        //    `.init(` 与**空格**形式收掉两种写法、上面那条 `count == 1` 让诱饵本身当场红。
        //    ⚠️ 而「白名单永远不完整」这句话仍然成立，所以**别再把剩下的写进注释了事**：
        //    上一版正是那么做的（把空格形式与 `typealias` 别名如实记进 `callArguments` 的 doc，
        //    再声称「兜住这一整类的是行为测试」），而 `/codex review 37745f2` 的 P1 证明那句话是
        //    假的 —— 诱饵 + 别名 + 从注入值派生的实参，文本与行为**双双全绿**。认不出的形状现在
        //    由 ``unmodeledConstructionShapes(of:in:)`` 记账、由上面那条围栏断言变成红。
        //  · 实参做**相等**判定 ⇒ `environment.packsLockFile.deletingLastPathComponent()…` 这种
        //    「以 needle 开头、后面接着把它改掉」的写法当场红。
        //
        // ## ⚠️ 上一版这里刻意**不**写 `calls.count == 1`，那个论证已被证伪（`/codex review 37745f2`）
        //
        // 它当时写的是：「那种『不许变多』的锁对 fail-open 方向零贡献（多一个构造点若也转发对了，
        // 本就没问题）」。**前半句是错的**，而且错在关键处：多出来的那个构造点如果是**死代码诱饵**，
        // 它「转发对了」恰恰是伪装的一部分 —— 诱饵满足 `!calls.isEmpty` 与那条相等循环，真实构造
        // 同时改走扫描器认不出的形式（`typealias` 别名）隐身而去。这不是「本就没问题」，这正是
        // Codex 那条 P1 的第一步。
        //
        // 所以现在写 `count == 1`。当时怕的「合法新增一处构造点时诊断是假的」仍然成立，处理办法是
        // 把它写进失败消息本身（「>1 处 = 可能是诱饵，也可能是一次真实重构，两种都必须有人看一眼
        // 再放行」）—— 让读消息的人知道该怎么办，而不是为了不误报就把这一维覆盖整个放掉。
        //
        // ## 归因表（七个变异体 × 五条断言，干净树基线做减法，按**断言原文**归因，不看退出码）
        //
        // 只看「红了」是假背书 —— 非零退出可能来自任何一条断言。这张表证明的是：**五条里有四条
        // 各自都有只有它逮得到的变异体** —— 围栏 R3 / 计数 R7 / 持锁行为 R1 / 负向 R6。
        //
        // ⚠️ **第五条「实参相等」在本表里没有独占，所以本表并不背书它非冗余**。而且不是「只是还没
        // 测到」这么轻：它逮到的 R2/R4/R5 三行**在「持锁行为」列也全是 ✓**，即按本表它的命中集合是
        // 持锁行为的**真子集**（持锁行为还多逮一个 R1）。它非冗余的理由是另一条，按覆盖**类别**走而
        // 不按独占变异体走 —— 见下面 R1 那段：行为测试只跑得到**被测试执行到的那一个**构造点，而
        // 「测试根本执行不到的构造点」只有文本绊线管得住。要让它在本表意义上也有独占，得补一个
        // 「未锚实参写在行为测试执行不到的构造点上」的变异体**并实测**，那还没做 —— 在做之前这一
        // 列的措辞就停在这里，不许替它补一个没跑过的 ✓。
        //
        // ⚠️ **R3/R7 两行曾经各多标过两个 ✓，与同行的「独占」字面矛盾**（「独占」按上一段的定义是
        // 「只有它逮得到」，同一行另一列若也是 ✓ 就已经不是「只有」）。2026-07-23 用真实变异体重新
        // 跑过一遍（`OnboardingActions.swift` 里手工植入这两种形状，跑 `claudio-gui-tests`，读退出码
        // 之外还读了具体是哪条断言的原文变红），R3 实测只有围栏那一条变红、R7 实测只有计数那一条——
        // 表已按实测结果改过来，不是按推理改的。
        //
        // | 变异体                                          | 围栏 | 计数 | 实参相等 | 持锁行为 | 负向 |
        // |-------------------------------------------------|:----:|:----:|:--------:|:--------:|:----:|
        // | R1 `init` 存储赋值换成 `ClaudioPaths.…`         |  —   |  —   |    —     | **独占** |  —   |
        // | R2 实参尾部未锚（`.deleting…append…`）          |  —   |  —   |    ✓     |    ✓     |  —   |
        // | R3 死代码诱饵供养断言 + 真实构造走 `typealias`  |**独占**|  —  |    —     |    —     |  —   |
        // | R4 实参直接写死 `ClaudioPaths.…`                |  —   |  —   |    ✓     |    ✓     |  ✓   |
        // | R5 实参从别处**推导**出同一个路径               |  —   |  —   |    ✓     |    ✓     |  —   |
        // | R6 另起一个**非** `SetupEnvironment` 构造点写死 |  —   |  —   |    —     |    —     |**独占**|
        // | R7 只加死代码诱饵（真实构造不动）               |  —   |**独占**|  —     |    —     |  —   |
        //
        // ⚠️ **R3 那一行是这一刀新加的，而它此前是全表唯一没有任何一条断言看得见的变异体**：诱饵喂饱
        // 计数与相等循环，真实构造走别名隐身，实参再从注入值派生出来 ⇒ 文本与行为**双双全绿**。
        // 现在围栏（`unmodeledConstructionShapes`）独占它 —— `typealias` 一出现就红，不管它后面写什么。
        //
        // ⚠️ **R5 那一行曾经写的是「本条独占 / 行为 —」，两次都不是了**，而两次变的都不是断言，是 fixture。
        // 最早那版把包锁放在 `claudioRoot/packs.lock`（与 config / settings 同父同名规则），于是
        // `environment.configLockFile.deletingLastPathComponent().appendingPathComponent("packs.lock")`
        // 求值出来恰好等于注入值 ⇒ 行为测试全绿。上一版挪到固定的 `injected-locks/gui-packs-lock`，
        // 并声称「任何兄弟派生都算不出它」—— Codex 证伪：向上**两级**再拼死那两个名字即可。现在
        // fixture 的包锁带一段运行时 `UUID`，**不存在**能算出它的路径表达式 ⇒ R5 的任何写法都让行为
        // 测试当场红。
        //
        // 这条 fixture 性质是**承重**的，它自己由「FixtureTargets 自证」那条 suite 钉着 —— 少了它，
        // 上面这段推理就寄生在一段没人断言的构造上。
        //
        // R1 反过来：调用点一个字符没动 ⇒ 文本三条全绿，只有行为测试看得见。
        // **文本绊线与行为测试互不代偿，两类都得有** —— 分工：文本独占「测试根本执行不到的那些构造点」
        // 与「诱饵/隐身」这类结构伪造，行为独占「实参求值出来的**值**」。
        // ## 围栏那一半：`callArguments` 认不出的构造形状 ⇒ 当场红
        //
        // 上一版这里只钉了 `#if` 一种（扫描器不建模条件编译，非活跃分支里的构造点与活跃的同形，
        // 一个 `#if false` 里的诱饵就能替真实构造喂饱下面两条断言）。`/codex review 37745f2` 的
        // P1 证明那还不够：`typealias SE = SetupEnvironment; SE(…)` 与上下文推断的 `.init(` 是
        // 另外两条同样宽的隐身路，而它们当时只被写在 `callArguments` 的 doc comment 里 ——
        // **被写进注释的洞不会因为被写进注释而变成有人看守它**。
        //
        // 三类现在由 ``unmodeledConstructionShapes(of:in:)`` 统一记账，一条断言收口。合并不降低
        // 覆盖（同样的输入 ⇒ 同样红），但把「新增一种认不出的形状」从「三处分散的 grep 各改一遍」
        // 变成「改一个函数」。本文件今天三类各零命中（实测），所以它现在就绿 —— 它不是装饰：
        // 一旦有人引入其中任何一种，下面那整套「按调用点绑实参」的推理就不再成立，必须当场停下来
        // 重新想，而不是让诱饵悄悄替真实构造背书。
        let unmodeledShapes = unmodeledConstructionShapes(of: "SetupEnvironment", in: actions)
        expect(
            unmodeledShapes.isEmpty,
            "`OnboardingActions.swift` 里出现了 `callArguments` 认不出的构造形状：\(unmodeledShapes) "
                + "—— 下面那条「每一处构造点都必须转发对」的循环会**漏掉**它（或者被一个非活跃分支里的"
                + "诱饵喂饱），而漏掉不会有任何人喊。要么把这个构造挪走，要么先把扫描器教会它再放行")

        // 精确计数，不是 `!isEmpty`：后者只要求「≥1 处且那一处转发对」，一个写得完全合规的死代码
        // 诱饵就能替真实构造背书（`/codex review 37745f2` P1 的第一步）。本文件实测正好 1 处。
        let setupEnvironmentCalls = callArguments(of: "SetupEnvironment", in: actions)
        expect(
            setupEnvironmentCalls.count == 1,
            "`OnboardingActions.swift` 里必须正好有 1 处 `SetupEnvironment(…)` 构造点，实得 "
                + "\(setupEnvironmentCalls.count) 处 —— 0 处 = 接管路径不再经由它（那下面这条转发断言"
                + "就是在守一段不存在的代码，整条 suite 失去意义）或 `callArguments` 的切法读串了；"
                + ">1 处 = 多出来的那个可能是喂饱断言的死代码诱饵。认不出 / 数不对 ⇒ 红，不许静默放行")
        for (ordinal, arguments) in setupEnvironmentCalls.enumerated() {
            let forwarded = argumentValue("packsLockFile", in: arguments)
            expect(
                forwarded == "environment.packsLockFile",
                "第 \(ordinal + 1) 处 `SetupEnvironment(…)` 的 `packsLockFile:` 实参必须**正好是** "
                    + "`environment.packsLockFile`，实际是 `\(forwarded ?? "<没有这个实参>")` —— 漏掉或"
                    + "传别的，`SetupEnvironment` 会静默落回 `ClaudioPaths.packsLockFile` 那个真实路径："
                    + "生产上碰巧仍然互斥（两边都用默认值），而**测试会去用户的 `~/.claudio` 上开一把"
                    + "真锁**，并与他正在运行的 Claudio.app 抢锁。"
                    + "⚠️ 这一条挡的是**这一手**（构造点的实参文本）。它挡不住上游 "
                    + "`OnboardingActionEnvironment.init` 里那一手存储赋值被换掉 —— 那条实测全绿、"
                    + "且真的会在用户 home 上开锁。封住它的是 `OnboardingActionsSuite` 里那条"
                    + "**持锁行为**断言")
        }
        // 负向兜底：不许绕过 environment 直接写死一把锁 —— 与前两把锁那两条负向兜底同形。
        //
        // ⚠️ 如实标注它现在还剩多少分辨力：上面那条相等判定**已经覆盖了 `SetupEnvironment(` 构造点上
        // 的这一种**（实参写成 `ClaudioPaths.packsLockFile` ⇒ 相等判定当场红，归因表 R4 那行三条一起响）。
        // 它没有被完全吞掉 —— 归因表 R6 是**只有它**逮得到的那一个：本文件里另起一个**非**
        // `SetupEnvironment(` 的构造点并写死真实路径
        // （`OnboardingActionEnvironment(…, packsLockFile: ClaudioPaths.packsLockFile)`），上面那个
        // 循环根本不看它，实测只有这一条开火。所以留着；但也别把它当「第二道独立防线」宣传：在最
        // 要害的那个调用点上，它与上面那条是**重叠**的。
        //
        // （不写「两根独立的轴」这种话。上一刀我在 `LockSeparationSuite` 的预算断言上正好写反过一次：
        // 改完算式之后 budget 那条其实**严格蕴含**了兄弟两条，我却写成「各自独立成立」。）
        //
        // 读的是 `codeWithoutStrings`：对这条负向断言而言那是 fail-**open**（清空的字符串里正好有
        // needle 就静默变绿）。之所以仍然接受，是因为 needle `packsLockFile: ClaudioPaths.` 是一段
        // **代码形状**、不是字符串内容，而同一次读取要喂上面那条承重的 `callArguments`。极性代价
        // 写在这里，不藏。
        expect(
            !actions.contains("packsLockFile: ClaudioPaths."),
            "接管路径把 `packsLockFile` 直接写成了 `ClaudioPaths.…` —— 那就绕过了注入点，"
                + "测试再怎么注入也拦不住它去碰真实 `~/.claudio`。锁只有一个来源：`environment`。")
    }

    suite("MenuBarController：popover 关闭必须发出隐藏信号，而且必须在那句会提前 return 的 guard 之前（T17d）") {
        guard let controller = codeOnly("gui/Sources/ClaudioGUI/MenuBarController.swift") else {
            expect(false, "读不到 MenuBarController.swift")
            return
        }
        expect(
            controller.contains("focusCoordinator.notePanelHidden()"),
            "popoverDidClose 必须告诉 coordinator 面板不在屏幕上了 —— 这一个信号今天驮着**两件**事："
                + "① OnboardingViewModel 判断「一条失败诞生时有没有人在看」；② MasterVolumeRow 的冲刷"
                + "（阶段 D / D22：拖动本身不写盘，popover 关闭就是那次拖动唯一的落盘时机）")

        // 这不是普通的文本绊线，它钉的是**顺序**：`popoverDidClose` 里那句 `guard NSApp.isActive`
        // 在「用户切到别的 app 导致 popover 关闭」这条路径上会直接 return —— 而那**正是** T17d 修的
        // 那个 bug 的主路径。把 notePanelHidden() 挪到 guard 之后，编译绿、上面那条 contains 也绿，
        // 而 bug 原封不动地复活，且只在最常见的那条路径上复活。所以顺序本身必须是一条断言。
        //
        // 阶段 D（8771946）之后这条顺序守的是**两个** bug，不是一个：主音量的冲刷（D22/D37）明确
        // 依赖同一条 `notePanelHidden()` 的位置来继承这条排序保证（MasterVolumeRow.swift 的
        // `focusCoordinator` doc 逐字写着这一点）。下面那条失败消息以前只报 onboarding 那一半 ——
        // 绊线响的时候，失败消息是唯一会被读的那段文字，它漏掉的后果等于不存在（`/codex review 8771946`）。
        guard let hidden = controller.range(of: "focusCoordinator.notePanelHidden()"),
            let guardIsActive = controller.range(of: "guard NSApp.isActive")
        else {
            expect(false, "在 MenuBarController 里找不到 notePanelHidden() 或 guard NSApp.isActive")
            return
        }
        expect(
            hidden.lowerBound < guardIsActive.lowerBound,
            "notePanelHidden() 必须出现在 `guard NSApp.isActive` **之前**。放在之后 = 切换 app 关闭"
                + "面板这条路径永远收不到隐藏信号（那句 guard 会提前 return），而「点了别的 app」正是"
                + "关闭 popover 最常见的一条路径。两个 bug 会当场一起复活：①「点完接管就切走、安装在"
                + "后台失败」的静默失败（T17d）；②「拖到新值后点别的 app 关掉面板」时那次拖动静默"
                + "丢失（阶段 D / D22/D37 —— 主音量拖动本身一个字节都不写）")
    }

    suite("OnboardingView 渲染任何失败，而不是只渲染接管的失败（T17c）") {
        guard let view = codeOnly("gui/Sources/ClaudioGUI/OnboardingView.swift") else {
            expect(false, "读不到 OnboardingView.swift")
            return
        }
        expect(
            view.contains("onboardingVisibleFailure(actionState:"),
            "onboarding 卡必须渲染任何失败 —— 一次**断开**失败之后 state 可能不再是 .installed"
                + "（比如 settings.json 同时被外部改坏），那时运行态面板不在屏幕上，只有这张卡在")

        // T17f：这张卡**几乎**看不到告知（告知来自成功的接管 → state 变 .installed → 画的是运行态
        // 面板）。它仍然必须无条件画，理由与 T17c 一字不差：「我推理出这个格子不可达，所以不画它」
        // 这句话，正是 T17c 里造出两个无人认领格子的那句话。两边都画，「不可达」就不需要任何人去证明。
        expect(
            view.contains("onboardingVisibleNotices(actionState:"),
            "onboarding 卡也必须无条件渲染告知 —— 结构不变式两边都得成立，否则它就不是不变式，"
                + "而是一条需要人去维护的分派规则（T17c 已经为这个区别交过学费）")
        expect(
            !view.contains("onboardingFailureBelongsHere"),
            "按 action 分派失败的那个函数已经删了（T17c）")
    }

    suite("OnboardingViewModel 的 actionRunner 仍然是必填的（可选 = T17 那个 bug 换层皮）") {
        guard let viewModel = codeOnly("gui/Sources/ClaudioGUICore/OnboardingViewModel.swift") else {
            expect(false, "读不到 OnboardingViewModel.swift")
            return
        }
        expect(
            viewModel.contains("actionRunner: any OnboardingActionRunning\n"),
            "init 的 actionRunner 必须**没有默认值** —— 一旦给它一个默认值（尤其 nil），"
                + "「忘了接线」就从编译错误退化成一次全绿的测试。评审实测：把它改回可选 + 静默 guard，"
                + "652 项测试全绿，唯一的信号是一条无关的 unused-variable 警告。")
        expect(
            viewModel.contains("private let actionRunner: any OnboardingActionRunning"),
            "actionRunner 必须是 `let`、非可选 —— 见上")
    }

    suite("MenuBarController 里没有 Bundle.main —— 那次查找必须留在可测的核心里") {
        guard let controller = codeOnly("gui/Sources/ClaudioGUI/MenuBarController.swift"),
            let app = codeOnly("gui/Sources/ClaudioGUI/ClaudioGUIApp.swift")
        else {
            expect(false, "读不到 MenuBarController.swift / ClaudioGUIApp.swift")
            return
        }
        expect(
            !controller.contains("Bundle.main"),
            "MenuBarController 里不该有 Bundle.main —— T17 的整个 bug 就住在那一行：把它写成"
                + " `Bundle.main.executableURL` 会解析到 Contents/MacOS/Claudio（SwiftUI app 自己），"
                + "而留在 AppKit 层的话整套测试抓不到。它必须走 `bundledHelperBinary(in:)`。")
        expect(
            app.contains("bundledHelperBinary(in: .main)"),
            "ClaudioGUIApp 必须用 ClaudioGUICore 的 bundledHelperBinary(in:) 解析 helper —— 剩下的只有"
                + "一个无分支的 `.main`，没有任何决定可以做错")
    }

    // ── D23 定稿④：面板路由的渲染层接线（红队 9cccc9c 之后，行为那半已经搬走了）─────────────
    //
    // ## 这条 suite 缩了一圈，因为它守的东西一半**不在这里了**
    //
    // 曾经这里有一整套 `functionBody("toggleMute")` 切片装置，逐条钉 `toggleMute` 函数体里的三条路由
    // （`panelRefreshRoute(` / `case .full: refresh()` / …）。那套装置存在的**全部理由**，是 `toggleMute`
    // 连同它操作的 `configState` / `eventRows` 困在 `PanelView`（`@main` executableTarget，测试 import 不
    // 进来）—— 逻辑测不到，只能退而用文本切片守「代码长什么样」。而红队 9cccc9c 实测证明：文本切片守不住
    // 「执行 / 可达性 / 翻转」（refresh 不重载 configState、某条 case 早退成死代码、静音去掉取反，三条各自
    // 改坏行为而两套测试全绿）。
    //
    // 所以 `toggleMute` / `switchPack` / `reload` / `reloadEnabledFlags` **整体搬进了**
    // `ClaudioGUICore.PanelConfigController`（一个可实例化的 `@MainActor` 类），由 `PanelConfigControllerSuite`
    // **new 它、喂真磁盘、调真方法、断言 configState/eventRows 真的变**。那三条变异现在各有一条行为断言当场
    // 逮住 —— 切片装置连同 `functionBody` 一起删了，它是为一个已经不存在的问题写的脚手架。
    //
    // 剩在 `PanelView` 里、这条 suite 还在守的，只有**渲染层接线**：顶部按 `configState` 路由、两张替换
    // 视图被引用到、按钮接到 `panelModel.toggleMute`、`.configMissing` 被滤掉、焦点只收可见行。它们是
    // `@main` View 的 body 接线，纯逻辑测试**本质上**到不了（只有 UI / 快照测试够得着，本机 CommandLineTools
    // 无 XCTest）——所以这里仍是**存在性**级文本绊线，且**如实**标注成存在性级：它证明「body 里写着这根线」，
    // 不证明「这根线运行期真的接通、接对了地方」。别把这条 suite 全绿读成「面板行为被守住了」——行为那半
    // 由 `PanelConfigControllerSuite` + `PanelRefreshRouteSuite` 守，这半只守「渲染层的线还在不在」。
    suite("PanelView：config 不可用时必须换态（渲染层接线的存在性；行为那半在 PanelConfigControllerSuite）") {
        guard let panel = codeWithoutStrings("gui/Sources/ClaudioGUI/PanelView.swift") else {
            expect(false, "读不到 PanelView.swift")
            return
        }
        expect(
            panel.contains("switch panelModel.configState"),
            "operationalPanel 必须按 configState 路由 —— 没有这个 switch，`{\"master_volume\": \"0.35\"}`"
                + " 这种「读得动、写不动」的 config 会照常渲染四行带静音钮 / 试听钮的活控件，而写路径"
                + "早已 fail closed：用户点下去的每一次都必然失败（这正是判据要两条正交轴的理由）")
        // ⚠️ 检查的是 **case → view 的映射**，不是裸标识符（红队 b86ec0a）。上一版写的是
        // `panel.contains("needsPackNotice")` —— 而这个标识符在它**自己的定义行**
        // `private var needsPackNotice: some View {` 里就出现了，于是把 `.needsPack` 分支体改成
        // `EmptyView()`（空态卡连同它唯一的 VoiceOver 播报被删）时，contains 仍恒真、测试全绿。
        // 收紧成 collapsed 后的 `case .needsPack: needsPackNotice` —— 它区分「定义存在」与「case 真的
        // 渲染它」。仍是 SwiftUI body 接线的存在性级（运行期接没接通到不了），但不再被自身定义满足。
        let panelCollapsed = collapsingWhitespace(panel)
        expect(
            panelCollapsed.contains("case .needsPack: needsPackNotice"),
            "`.needsPack` 分支体必须渲染「先选包」空态卡 `needsPackNotice`（不是 EmptyView 之类）—— 那是"
                + "从没选过包时顶部唯一的引导 + VoiceOver 口头指引，删了它 = 顶部一片空白、无障碍指引消失。"
                + "得到的 switch 附近：\(String(panelCollapsed.prefix(0)))（见 PanelView operationalPanel）")
        expect(
            panelCollapsed.contains(
                "case .configFailure(let reason): configFailureNotice(reason: reason)"),
            "`.configFailure`（= `.malformed`/`.unwritable`，见 `PanelConfigState.topContent`）分支体必须渲染"
                + "诚实失败态 `configFailureNotice(reason:)` —— 它带可执行修复指令；换成别的（或空）= 写不动的"
                + " config 上顶着四行必败活控件却不说实话")

        // 按钮 → handler 的那根线：静音的**行为**（翻转 + 路由 + 刷新）现在住在可测的 `PanelConfigController`
        // 里、由 `PanelConfigControllerSuite` 用真磁盘钉死。这里只剩守**最外层这根接线**：EventRowView 的
        // 静音钮真的接到 `panelModel.toggleMute`。红队 9cccc9c 实测把它剪成 `onToggleMute: {}`，四行静音钮
        // 点了毫无反应（连失败都没有）。
        //
        // ⚠️ 存在性级：证明「body 里写着这根线」，证明不了它运行期真的接通（SwiftUI body 接线，只有 UI /
        // 快照测试够得着）。挡「线被剪断」，不挡「运行期没接通」。
        expect(
            collapsingWhitespace(panel).contains("onToggleMute: { panelModel.toggleMute(row.event) }"),
            "operationalPanel 的 EventRowView 必须把 onToggleMute 接到 `panelModel.toggleMute(row.event)`"
                + " —— 剪成 `onToggleMute: {}` 之类，四行事件的静音钮就变成点了没反应的死键")

        // D43 的 `.configMissing` 过滤（PLAN-MASTER-VOLUME.md 阶段 D）：过滤逻辑已经搬进纯函数
        // `panelWriteFailures(muteError:packSwitchError:masterVolumeError:)`（`PanelWriteFailuresSuite`
        // 逐条钉死「.configMissing 被排除」），不再是 PanelView.swift 里裸露的 `error != .configMissing`
        // 字面量——这里改守**接线本身**：三个写者的错误必须全部喂给这一个合并函数，一个都不许漏
        // （漏掉 masterVolumeError，主音量的写失败就会从错误列表里悄悄消失，且这条断言此前测不到它）。
        expect(
            collapsingWhitespace(panel).contains(
                "panelWriteFailures( muteError: panelModel.muteError, packSwitchError:"
                    + " panelModel.packSwitchError, masterVolumeError: panelModel.masterVolumeError"),
            "operationalPanel 必须把三个写者的错误全部喂给 panelWriteFailures(muteError:packSwitchError:"
                + "masterVolumeError:)（D3 合并列表）—— 少喂一个，那个写者的失败就从错误列表里静默消失。"
                + ".configMissing 的排除逻辑本身已经下沉进这个纯函数，由 PanelWriteFailuresSuite 钉死")
        expect(
            panel.contains("let visibleRows"),
            "applyFirstFocus 必须只把**真的被渲染出来**的行送进焦点序 —— 非 .operational 态下"
                + " eventRows 仍会算出四行（走 resolvedConfig 的空包默认值），但它们一个像素都没上屏；"
                + "把它们送进开局焦点 = 焦点落在一个不存在的控件上")

        // 现状（PLAN-MASTER-VOLUME.md 阶段 D 已落地）：`MasterVolumeRow` 真的渲染在 `operationalPanel`
        // 的 `.events`（= `.operational`）分支里。`hasMasterVolume` 现在转发的是 `content.showsEventContent`
        // —— `PanelTopContent` 上一颗**单测钉过返回值**的投影（`= .events`，`PanelConfigSuite` 钉死），
        // 而不是视图里一颗未测的 `content == .events` 闭包（f54d335 P1#1 follow-up：对抗复核逮到，值级单源
        // 不够，视图里重解释的布尔翻个返回值就能让渲染 / 焦点分叉还全绿）。渲染判据与焦点判据从此在**决策层**
        // 一致：投影返回值由单测钉，视图只转发，本断言钉住这句转发原样还在。
        //
        // 历史，别再当现状读（这段注释本身在阶段 D 落地时说过一次反话，被 /codex review 逮到过 ——
        // 1fcd96f 就是修同一个病的）：341d9b7 修掉的是「`.masterVolume` 在三个边缘态
        // （`.needsPack`/`.malformed`/`.unwritable`）里指向一个不存在的滑块」；紧接着那一轮 /codex review
        // 的 P2 指出，在阶段 D 落地**之前**，从 `configState` 派生这个布尔只是把同一个 bug 从边缘态搬到最
        // 常见的 `.operational` 态，于是它一度被钉死成字面量 fail-closed 值。阶段 D 落地就是那颗钉子自己
        // 写明的退出条件。下面两条断言：正向要求转发 `content.showsEventContent`，反向禁止钉回字面量。
        expect(
            panelCollapsed.contains(
                "hasDetailToggle: hasDetailToggle, hasMasterVolume: content.showsEventContent"),
            "hasMasterVolume 现在必须转发 `content.showsEventContent`（`PanelTopContent` 上单测钉过返回值的投影，"
                + " = `.events`）—— 钉死字面量 false 会让 .masterVolume 在滑块真的在屏幕上时也永远抢不到焦点，"
                + "键盘 / VoiceOver 用户走 Tab 会跳过一个明明可操作的控件；换成别的投影名 = render/focus 分叉")
        expect(
            !panelCollapsed.contains("hasMasterVolume: false"),
            "hasMasterVolume 不许再钉死字面量 false —— 那是 MasterVolumeRow 落地前的占位值（341d9b7 之后"
                + "那一轮 /codex review 的临时状态），见上一条断言")

        // /codex review f54d335 P1#1（单源化 + 决策级钉法，取代 26bba37 那轮的双 switch 设计）：诚实失败卡上的
        //「在访达中显示 config.json」是一颗真控件（焦点目标 `.configReveal`），`.malformed`/`.unwritable` 开局
        // 焦点该落在它上面而不是越过它。此前**渲染判据**（operationalPanel 的 switch 分支渲染 configFailureNotice）
        // 与**焦点判据**（applyFirstFocus 派生 hasConfigFailureNotice）是**两段**独立 `switch panelModel.configState`，
        // 只靠本 suite 的文本绊线防漂移。现在链条是：configState →（`PanelConfigState.topContent` 映射）→
        // topContent →（`PanelTopContent.hasConfigFailureNotice` 投影）→ Bool，**两级都由 `PanelConfigSuite` 真行为
        // 单测钉返回值**；render 在 `.topContent` 上 switch，focus **原样转发** `content.hasConfigFailureNotice`。
        //（对抗复核实测的教训：只让两边读同一个 topContent **值**不够——视图里若再用一颗未测闭包把值重解释成
        // Bool，翻个返回值就能让失败卡照画、焦点跳过 Reveal 钮还全绿。把投影上提到单测属性、视图只转发，才把
        // 漂移堵在决策层。）所以本块只钉视图层无法被 import 单测的那几件**转发 / 接线**事实：① render switch 在
        // `.topContent`；② focus 的 `content` 绑的就是这个单源；③ focus 原样转发 `content.hasConfigFailureNotice`
        //（不是本地重解释、不是钉字面量）；④ 视图接线半：Reveal 按钮带 `.focused(... .configReveal)`。
        expect(
            panelCollapsed.contains("switch panelModel.configState.topContent"),
            "operationalPanel 顶部必须 switch 在 `panelModel.configState.topContent` 上 —— 直接 switch 裸 configState "
                + "会复活「渲染判据 / 焦点判据两段独立 switch」的漂移隐患（/codex review f54d335 P1#1 抽掉的正是它）")
        expect(
            panelCollapsed.contains("let content = panelModel.configState.topContent"),
            "applyFirstFocus 必须把 `content` 绑到单源 `panelModel.configState.topContent` 上 —— 焦点判据从此和"
                + "渲染判据同源，不是各自 switch 一遍 configState")
        expect(
            panelCollapsed.contains("hasConfigFailureNotice: content.hasConfigFailureNotice"),
            "applyFirstFocus 必须**原样转发** `content.hasConfigFailureNotice`（`PanelTopContent` 上单测钉过返回值的"
                + "投影）进 panelOpeningFocus —— 换成视图里本地重解释（`if case .configFailure = content { … }`）那颗"
                + "闭包的返回值没测过，翻成 false 就让失败卡照画、`.configReveal` 被踢出焦点序还全绿（f54d335 P1#1 "
                + "follow-up 对抗复核逮到的洞）；钉死字面量 / 换投影名同样让 render/focus 分叉")
        expect(
            !panelCollapsed.contains("hasConfigFailureNotice: false"),
            "hasConfigFailureNotice 不许钉死字面量 false —— 那会让失败卡上的真控件永远抢不到开局焦点")
        // 视图接线半（此前完全没人钉，/codex review f54d335 P1#2 逮到）：把 `focusedTarget = .configReveal`
        // 真正接到那颗控件的，是 configFailureNotice 里 Reveal 按钮上的 `.focused($focusedTarget, equals:
        // .configReveal)`。删掉那一行，上面几条 + 纯 `PanelFocusOrderSuite` 仍会全绿，而 `.configReveal` 又变回
        // 一个没有视图认领的悬空焦点位（`panelFocusOrder` 仍把它排进焦点序，PanelFocusOrder.swift:146）——
        // 正是 cc59d52 删 `.dropZone`、26bba37 → 本分支要根除的那个形状。
        // ⚠️ 存在性级绊线（同本文件头部自陈 + 下面 `.disconnect` 同款）：它只证明那一行**还在**，证不了它接在
        // **对的**视图上（把这个修饰符原样挪到隐藏 / 别的兄弟视图照样绿——那只有 ViewInspector / XCTest 挡得住，
        // 本机 CommandLineTools 没有）。它切实挡的是「顺手删掉 / 注释掉 / 改错 case」这一类，恰是本 bug 的复发形状。
        expect(
            panelCollapsed.contains(".focused($focusedTarget, equals: .configReveal)"),
            "configFailureNotice 的「在访达中显示 config.json」按钮必须带 `.focused($focusedTarget, equals: "
                + ".configReveal)` 把开局焦点接到自己身上 —— 删掉它，`.malformed`/`.unwritable` 开局焦点落到一个"
                + "没有视图认领的 .configReveal（panelFocusOrder 仍排它进序），Reveal 钮永远抢不到键盘 / VoiceOver 焦点")

        // T7 `.manageSounds` 的诚实性双向钉（与 `.masterVolume` 的 P1 先例同型）：
        // 视图侧必须在 configState 的三分支 switch 之外无条件渲染管理钮；模型侧必须无条件 append。
        // 任一半条件化都会让另一半变成幽灵焦点或让真控件从 Tab 序消失。
        let unconditionalShape =
            "VStack { switch content { case .events: rows } manageSoundsRow }"
        let conditionalShape =
            "VStack { switch content { case .events: rows } if hasCards { manageSoundsRow } }"
        expect(
            braceDepth(of: "manageSoundsRow", in: unconditionalShape)
                == braceDepth(of: "switch content", in: unconditionalShape),
            "braceDepth 正向对照：switch 外的同级管理钮必须被识别为无条件")
        expect(
            braceDepth(of: "manageSoundsRow", in: conditionalShape)
                != braceDepth(of: "switch content", in: conditionalShape),
            "braceDepth 负向对照：把管理钮包进 if 后必须被识别为条件渲染；否则双向钉没有牙")
        guard
            let focusModel = codeWithoutStrings(
                "gui/Sources/ClaudioGUICore/PanelFocusOrder.swift"),
            let operationalBody = closureBody(
                after: "private var operationalPanel: some View", in: panelCollapsed)
        else {
            expect(false, "读不到 operationalPanel 或 PanelFocusOrder.swift，无法核验 .manageSounds 双向接线")
            return
        }
        let manageRenderCount =
            operationalBody.components(separatedBy: "manageSoundsRow").count - 1
        expect(
            manageRenderCount == 1,
            "operationalPanel 必须恰好无条件渲染一次 manageSoundsRow；它放在 configState switch "
                + "之外，才能覆盖 operational/needsPack/malformed/unwritable 四态。得到 \(manageRenderCount) 次")
        expect(
            braceDepth(of: "manageSoundsRow", in: operationalBody)
                == braceDepth(of: "switch panelModel.configState.topContent", in: operationalBody),
            "manageSoundsRow 必须与 configState switch 处于同一花括号层级，证明它在 switch 之外无条件"
                + "渲染；包进 if/switch 后即使字面量与顺序不变也必须红")
        guard
            let galleryAt = operationalBody.range(of: "PackGalleryView(")?.lowerBound,
            let manageAt = operationalBody.range(of: "manageSoundsRow")?.lowerBound,
            let disconnectAt = operationalBody.range(of: "disconnectRow")?.lowerBound
        else {
            expect(false, "operationalPanel 必须同时有 PackGalleryView → manageSoundsRow → disconnectRow")
            return
        }
        expect(
            galleryAt < manageAt && manageAt < disconnectAt,
            "manageSoundsRow 必须在包列表之后、断开连接之前无条件渲染；这是视觉序与焦点序的共同真相")

        let focusCollapsed = collapsingWhitespace(focusModel)
        let appendNeedle = "order.append(.manageSounds)"
        guard
            let focusOrderBody = closureBody(
                after: "public func panelFocusOrder(_ scope: PanelFocusScope)", in: focusCollapsed)
        else {
            expect(false, "读不到 panelFocusOrder 函数体，无法核验 .manageSounds 无条件 append")
            return
        }
        expect(
            focusOrderBody.components(separatedBy: appendNeedle).count - 1 == 1,
            "panelFocusOrder operational 分支必须恰好无条件 append 一次 .manageSounds；条件 append "
                + "会与四态恒渲染的真控件漂移")
        expect(
            braceDepth(of: appendNeedle, in: focusOrderBody)
                == braceDepth(of: "case .operational(", in: focusOrderBody),
            "order.append(.manageSounds) 必须与 operational case 处于同一花括号层级，证明它不受任何"
                + "额外 if/switch 条件控制；只数 occurrence 无法守住无条件 append")
        guard
            let cardsAppendAt = focusOrderBody.range(
                of: "order.append(contentsOf: packCardIDs.map { .packCard(id: $0) })")?.lowerBound,
            let manageAppendAt = focusOrderBody.range(of: appendNeedle)?.lowerBound,
            let disconnectAppendAt = focusOrderBody.range(of: "order.append(.disconnect)")?.lowerBound
        else {
            expect(false, "焦点模型必须同时有 packCards → .manageSounds → .disconnect 三段")
            return
        }
        expect(
            cardsAppendAt < manageAppendAt && manageAppendAt < disconnectAppendAt,
            ".manageSounds 必须无条件排在全部 packCards 之后、.disconnect 之前")
        guard let panelRaw = source("gui/Sources/ClaudioGUI/PanelView.swift") else {
            expect(false, "读不到 PanelView.swift 原文，无法核验 T7 的用户可见文案")
            return
        }
        let rawCollapsed = collapsingWhitespace(panelRaw)

        // 当前包名不能再从显示集反推：header 与事件区标题必须共用 selectedPackMetadata 的同一投影。
        expect(
            panelCollapsed.contains(
                "private var selectedPackDisplayName: String { panelModel.selectedPackMetadata.displayName }"),
            "selectedPackDisplayName 必须直接读独立的 selectedPackMetadata，不得从 packCards 显示集反推")
        expect(
            !panelCollapsed.contains("packCards.first(where:"),
            "PanelView 不得再从 packCards.first(where:) 取当前包名；当前包未加星时它不在显示集")
        expect(
            rawCollapsed.contains(
                "let packName = selectedPackDisplayName guard !packName.isEmpty else { return PanelHeader.baseLabel } "
                    + "return \"\\(PanelHeader.baseLabel)，当前声音包 \\(packName)\""),
            "headerAccessibilityLabel 必须消费 selectedPackDisplayName，与事件标题同源")
        expect(
            rawCollapsed.contains("case .events: Text(\"\\(selectedPackDisplayName) · 事件\")"),
            "「{当前包名} · 事件」必须只从 `.events` 分支开始渲染，并消费同一个 selectedPackDisplayName；"
                + "needsPack/失败态不得出现「 · 事件」半截")

        // 节结构 + T8 真窗口动作 + 专属虚线形制。
        guard
            let soundTitleAt = rawCollapsed.range(of: "Text(\"声音包\")")?.lowerBound,
            let rawGalleryAt = rawCollapsed.range(of: "PackGalleryView(")?.lowerBound,
            let manageBody = closureBody(
                after: "private var manageSoundsRow: some View", in: panelCollapsed),
            let rawManageBody = closureBody(
                after: "private var manageSoundsRow: some View", in: rawCollapsed)
        else {
            expect(false, "必须能定位「声音包」节标题、PackGalleryView 与 manageSoundsRow")
            return
        }
        expect(
            soundTitleAt < rawGalleryAt,
            "「声音包」节标题必须渲染在包列表上方")
        expect(
            manageBody.contains("onManageSounds()")
                && !manageBody.contains("activateFileViewerSelecting"),
            "T8 管理钮必须调用注入的真窗口入口，并替换掉阶段 1 的 Finder 中间态；不能退回空 closure")
        expect(
            manageBody.contains(".frame(maxWidth: .infinity)"),
            "管理声音包必须是列表下方全宽 ghost")
        expect(
            manageBody.contains("StrokeStyle(lineWidth: 1.5, dash: [4, 3])"),
            "管理声音包必须使用虚线描边，与实线「断开连接」区分")
        expect(
            manageBody.contains(".focused($focusedTarget, equals: .manageSounds)"),
            "管理声音包按钮本体必须认领 .manageSounds 焦点身份，否则纯模型会再次指向一个无 owner 的幽灵目标")
        expect(
            rawManageBody.contains(".accessibilityLabel(\"管理声音包\")"),
            ".manageSounds 的 VoiceOver 名称必须是「管理声音包」；零行首焦点不得播报成断开连接或卸载")
        expect(
            rawManageBody.contains(".accessibilityHint(\"打开声音包管理窗口\")"),
            "T8 的 VoiceOver hint 必须如实说明点击后打开管理窗口，不得继续声称会去访达")
        expect(
            !rawManageBody.contains("断开连接") && !rawManageBody.contains("卸载"),
            ".manageSounds 控件自己的可访问语义不得混入相邻破坏性动作的名称")

        // needsPack 两根正交轴：文案值由 PanelAccessibilitySuite 逐字断言；这里钉视图确实把
        // 同一份 copy 同时送给可见 Text 与 accessibilityLabel，不能在 SwiftUI 里另写一套。
        expect(
            panelCollapsed.contains(
                "let copy = needsPackNoticeCopy(hasVisiblePackChoices: !panelModel.packCards.isEmpty)"),
            "needsPack 的有包/零行选择必须交给可单测的 needsPackNoticeCopy，且轴来自真实显示集是否为空")
        expect(
            panelCollapsed.contains("Text(copy.message)"),
            "needsPack 可见副文案必须直接消费 copy.message")
        expect(
            panelCollapsed.contains(".accessibilityLabel(copy.accessibilityLabel)"),
            "needsPack VoiceOver label 必须直接消费同一份 copy，不得与可见文案各写一套")
    }

    // ── PLAN-MASTER-VOLUME.md 阶段 D：MasterVolumeRow 的三个硬约束 + 三条接线绊线 ──────────────
    //
    // `MasterVolumeRow.swift` 是 SwiftUI body 接线，纯逻辑测试到不了（本机 CommandLineTools 无
    // XCTest）—— 与本文件其余每一条同一个理由（见文件头部）。「全 GUI 只许一处 NSAccessibility.post /
    // announcer.consume(」已经由上面「T17h 播报出口」那条 suite 覆盖（它数的是整个 `guiSources()`，
    // MasterVolumeRow.swift 自然落进普查范围），这里不重复；这里守的是这个文件**自己**独有的三个
    // 已实证的坑（D5/D10 已作废、D18）+ 三条本步新增的接线（D21 的 rebase、D22/D37 的 popover 冲刷、
    // D22-bis 的 willTerminate 冲刷）。
    suite("MasterVolumeRow：三个已作废/已实证的坑不许出现（step: / onDisappear / 任何动画入口）") {
        // 读 codeWithoutStrings：负向断言（「不许出现 X」）若读保留字符串内容的 codeOnly，任何一句
        // 恰好把 X 写进错误消息的代码都会让它**假红**；更要命的是正向那半（下面 closureBody 那几条）
        // 会被同一份字符串**假绿**。统一读这一路。
        guard let row = codeWithoutStrings("gui/Sources/ClaudioGUI/MasterVolumeRow.swift") else {
            expect(false, "读不到 MasterVolumeRow.swift —— 这个 suite 唯一的价值就是读它")
            return
        }
        expect(
            !row.contains("step:"),
            "MasterVolumeRow 不许使用 Slider(…, step:)（D24）—— 本机 key 窗口截图实证：`step: 0.05` 会被"
                + "直译成 NSSlider.numberOfTickMarks = 21，在轨道下方画出一条 21 个灰点的刻度带，撑破"
                + "DESIGN.md「控件行」的 ~28pt 行高。档位吸附交给 VolumeDragSession.snap()，视图侧只转发")
        expect(
            !row.contains("onDisappear"),
            "MasterVolumeRow 不许用 onDisappear 冲刷（D10 已作废，全仓零命中且本仓库已明文否定该回调—— "
                + "PanelFocusCoordinator.swift 的文档：popover 不保证在每次 show/close 之间重建视图层级）。"
                + "冲刷信号走 focusCoordinator.hideCount")
        // 动画有**两个**入口，这条绊线上一版只堵了一个。
        //
        // `.animation(` 是修饰符那一路；`withAnimation { … }` 是命令式那一路，它照样能给这一行接上
        // 隐式动画，而 `!contains(".animation(")` 对它完全看不见。实测变异体
        // `.opacity(withAnimation(.easeInOut) { 1.0 })` 注入 MasterVolumeRow —— 1973 checks 全绿
        // （`/codex review 8771946`）。措辞（「全行零动画」）比覆盖范围（「零 `.animation(`」）大了
        // 一整个入口，与本文件 `sourcesUnder(_:)` 的 T17h 是同一种病。
        //
        // 围栏，不是白名单：认不出的动画入口只会更多（`.transaction {}`、`Animation` 值本身），所以
        // 判据是「这两个入口一个都不许在」，任何一个命中即红。
        for entry in [".animation(", "withAnimation"] {
            expect(
                !row.contains(entry),
                "MasterVolumeRow 全行零动画（D18）—— 命中了 `\(entry)`。拖动跟手不加动画、失败回滚一律"
                    + "瞬跳；给控件行加动画 = 必须同批接上 accessibilityReduceMotion 门控，代价远大于收益"
                    + "（PanelView.swift 顶部那条「本视图树的动画绊线」记录着同一条纪律）")
        }
    }

    // ══ 下面三条守的是 MasterVolumeRow 的三个 SwiftUI 修饰符，它们各自的**闭包体**才是本体 ══════
    //
    // 三条都经 `closureBody(after:in:)` 切出闭包体再断言，而不是 `row.contains(修饰符字面量)`。
    // 理由是实测出来的，不是设计洁癖（`/codex review 8771946` P1）：变异体「把
    // `.onChange(of: focusCoordinator.hideCount)` 的闭包体掏空、修饰符原样留着」—— 用户拖完滑块点
    // 面板外面关掉 popover，音量**静默丢失**，正是下面那条断言的失败消息亲口写的那个 bug —— 而
    // 1973 checks **全绿**。`contains(修饰符)` 守得住「这行代码在不在」，守不住「它做不做事」，
    // 而「做不做事」是这些修饰符存在的全部理由。
    //
    // 喂的是 `codeWithoutStrings`（剥注释 + 清空字符串内容）而不是 `codeOnly`：后者保留字符串内容，
    // 一句写着 `flush()` 的错误消息在 `contains("flush()")` 眼里与一次真的调用完全同形。

    suite("MasterVolumeRow：diskVolume 变化必须下行同步进 session（D21，否则滑块永久显示磁盘上没有的值）") {
        guard let row = codeWithoutStrings("gui/Sources/ClaudioGUI/MasterVolumeRow.swift") else {
            expect(false, "读不到 MasterVolumeRow.swift")
            return
        }
        let flat = collapsingWhitespace(row)
        guard let body = closureBody(after: ".onChange(of: diskVolume)", in: flat) else {
            expect(
                false,
                "MasterVolumeRow 必须有 .onChange(of: diskVolume) { … } —— 切不出它的闭包体（修饰符不在，"
                    + "或后面没有配平的闭包）。围栏认不出就判红：看不懂 ≠ 是对的")
            return
        }
        expect(
            body.contains("session.rebase(to:"),
            "`.onChange(of: diskVolume)` 的闭包体里必须真的调 session.rebase(to:) —— 上一版把这两样分成"
                + "两个独立的 contains 用 && 连起来，于是把 rebase 挪进**别的**修饰符闭包里（或留在任何"
                + "一句死代码里）都照样绿。没有这次下推：用户手改 config.json 成 0.30、重开面板，"
                + "`config.masterVolume == 0.30` 而滑块仍显示旧值；D11「不变不写」还会让它不自愈，"
                + "下一次微调基于幻影 baseline 提交（D21）。闭包体实际是：\(body)")
    }

    suite("MasterVolumeRow：popover 隐藏必须冲刷（D22/D37，复用既有 hideCount 信号，不新增 closeCount）") {
        guard let row = codeWithoutStrings("gui/Sources/ClaudioGUI/MasterVolumeRow.swift") else {
            expect(false, "读不到 MasterVolumeRow.swift")
            return
        }
        let flat = collapsingWhitespace(row)
        expect(
            !flat.contains("closeCount"),
            "不许新增 closeCount —— PanelFocusCoordinator 今天已经有 hideCount 且 "
                + "MenuBarController.popoverDidClose 的第一条语句已经是 notePanelHidden()（T17d），语义"
                + "与这里要的冲刷信号完全一致，复用它")
        guard let body = closureBody(after: ".onChange(of: focusCoordinator.hideCount)", in: flat) else {
            expect(
                false,
                "MasterVolumeRow 必须有 .onChange(of: focusCoordinator.hideCount) { … } —— 切不出它的闭包体。"
                    + "没有它，用户拖到新值后点面板外面关闭 popover，值会静默丢失（D22：popover 关闭是 "
                    + "NSPopover 的可靠信号，`.onDisappear` 不是）")
            return
        }
        expect(
            body.contains("flush()"),
            "`.onChange(of: focusCoordinator.hideCount)` 的闭包体里必须真的调 flush() —— 空闭包 = 修饰符"
                + "在、冲刷没了，用户拖完点面板外面关 popover，那次拖动**静默丢失**。这正是本条断言上一版"
                + "（只查修饰符字面量在不在）放过去的那个变异体，实测存活、1973 checks 全绿。"
                + "闭包体实际是：\(body)")
    }

    suite("MasterVolumeRow：VoiceOver 是读数的唯一交付通道，删掉它 = 盲用户彻底听不到音量（D15）") {
        // D15 把百分比读数从**屏幕上**拿掉了（无「80%」文字，照抄 macOS 系统音量滑块），代价是
        // `.accessibilityValue` 成了这个值**唯一**的交付通道 —— 对 VoiceOver 用户，删掉那一行不是
        // 「少一点 a11y 修饰」，是这一整个控件从此不报数。
        //
        // 而本 suite 对 MasterVolumeRow 原有的 8 条断言里，**没有一条**读 accessibilityLabel/Value
        // （`/codex review 8771946` 完备性批评）：删掉 `.accessibilityValue`，1976 checks 全绿。
        // 一个「屏幕上没有、VO 里也没有」的值，就是压根不存在的值。
        guard let row = codeWithoutStrings("gui/Sources/ClaudioGUI/MasterVolumeRow.swift") else {
            expect(false, "读不到 MasterVolumeRow.swift")
            return
        }
        let flat = collapsingWhitespace(row)
        expect(
            flat.contains(".accessibilityLabel("),
            "MasterVolumeRow 必须给 Slider 一个 accessibilityLabel —— 没有它，VO 停在这个控件上只会"
                + "念一句「滑块」，用户不知道自己在调什么")
        expect(
            flat.contains(".accessibilityValue("),
            "MasterVolumeRow 必须给 Slider 一个 accessibilityValue —— D15 把百分比读数从屏幕上拿掉了，"
                + "这是那个数字**唯一**的交付通道。删掉它，VO 用户听不到任何音量值，而屏幕上也没有 ——"
                + "这个值对他们从此不存在")
        // 读数必须来自**会话草稿**（拖动中的实时值），不是磁盘值：拖动期间一个字节都不写盘
        // （VolumeDragSession 规则 1），若 VO 念的是 diskVolume，用户拖动时听到的是拖动**之前**的
        // 那个数，全程不动 —— 一个永远滞后的读数比没有读数更糟。
        expect(
            flat.contains("session.draft"),
            "accessibilityValue 必须读 session.draft（拖动中的草稿值），不是 diskVolume —— 拖动期间不"
                + "写盘，念磁盘值 = VO 用户拖着滑块却始终听到旧数字")
        // Text("主音量") 必须对 VO 隐藏：它与 accessibilityLabel 同字，不隐藏 VO 会在这一行停两次
        // （一次念 Text、一次念 Slider 的 label）。
        expect(
            flat.contains(".accessibilityHidden(true)"),
            "MasterVolumeRow 的可视标签 Text(\"主音量\") 必须 .accessibilityHidden(true) —— 它与 Slider 的"
                + " accessibilityLabel 同字，不隐藏 VO 会在这一行停两次、把同一个词念两遍")
    }

    suite("MasterVolumeRow：willTerminate 必须同步冲刷（D22-bis，且不得复用 hideCount 那套计数器机制）") {
        guard let row = codeWithoutStrings("gui/Sources/ClaudioGUI/MasterVolumeRow.swift") else {
            expect(false, "读不到 MasterVolumeRow.swift")
            return
        }
        let flat = collapsingWhitespace(row)
        expect(
            flat.contains(".onReceive("),
            "willTerminate 的冲刷必须走 .onReceive(NotificationCenter.default.publisher(for:))，不是 "
                + ".onChange —— app 正在终止时 SwiftUI 的 update pass 不保证再跑一次，bump 一个 @Published "
                + "计数器等于什么都没做；.onReceive 是一条独立的 Combine 订阅，NotificationCenter 会在通知"
                + "post 的同一线程上同步调用它，不依赖任何一次视图重渲染")
        guard let body = closureBody(after: "NSApplication.willTerminateNotification", in: flat) else {
            expect(
                false,
                "MasterVolumeRow 必须监听 NSApplication.willTerminateNotification 并同步冲刷 —— 切不出它后面"
                    + "的闭包体。这是 D22 冲刷的兜底：popover 关闭那条信号覆盖不了 ⌘Q 时 popover 从未被关闭"
                    + "过（用户直接退出）的路径")
            return
        }
        expect(
            body.contains("flush()"),
            "willTerminate 的闭包体里必须真的调 flush() —— 订阅建了但闭包是空的，等于没订阅：⌘Q 时那次"
                + "没提交的拖动照样丢。闭包体实际是：\(body)")
    }

    // MARK: - PLAN-SOUND-MANAGER.md T2：自动试听回归 + 「清除绑定」菜单项接线（存在性级，理由同本文件
    // 头部——EventRowView/PanelView 都住在不可 import 的 `ClaudioGUI` executableTarget）

    suite("PanelView：每行的 onImportSucceeded 必须接到 previewPlayer.play(...) —— T1 删掉假 drop-zone 时带走了它唯一的实现，T2 必须补回自动试听") {
        guard let panel = codeWithoutStrings("gui/Sources/ClaudioGUI/PanelView.swift") else {
            expect(false, "读不到 PanelView.swift")
            return
        }
        let flat = collapsingWhitespace(panel)
        guard let body = closureBody(after: "importViewModel.onImportSucceeded =", in: flat) else {
            expect(
                false,
                "PanelView 的 init 必须给每行的 AudioImportViewModel 接一句 onImportSucceeded —— 切不出它"
                    + "后面的闭包体。没有它，导入成功后（菜单选文件 / 拖拽）行内不会自动试听，用户导入了"
                    + "什么声音只能凭猜测")
            return
        }
        expect(
            body.contains("previewPlayer.play("),
            "onImportSucceeded 的闭包体必须真的调 previewPlayer.play(...) —— 接了钩子却是空闭包，等于"
                + "没接。闭包体实际是：\(body)")
        expect(
            body.contains("previewVolume(for: panelModel.config)"),
            "自动试听必须读 panelModel.config（PLAY 时刻的最新音量），而不是 init 时捕获的一个冻结值 ——"
                + "否则用户开着面板调过一次主音量之后，自动试听仍然放着调整前的音量。闭包体实际是：\(body)")
    }

    suite("EventRowView：文件名 Menu 的「清除绑定」菜单项必须接到 clearBinding()，而 clearBinding() 必须经由 importViewModel.clearBinding() 落地 —— 不许绕开 T3 的 clearEventBinding 原语另起一套清除逻辑") {
        // `codeOnly`（剥注释、**保留**字符串内容），不是 `codeWithoutStrings`：这条要断的是菜单项的
        // 字面量标签「清除绑定」本身也在——`codeWithoutStrings` 会把它清空成 `""`，让下面第一条
        // 断言恒假。
        guard let row = codeOnly("gui/Sources/ClaudioGUI/EventRowView.swift") else {
            expect(false, "读不到 EventRowView.swift")
            return
        }
        let flat = collapsingWhitespace(row)
        expect(
            flat.contains(#"Button("清除绑定", action: clearBinding)"#),
            "present/broken 两态的菜单必须把「清除绑定」接到 clearBinding —— 少了它，菜单项要么不存在"
                + "要么是个死按钮")
        guard let body = closureBody(after: "private func clearBinding()", in: flat) else {
            expect(false, "切不出 clearBinding() 的函数体")
            return
        }
        expect(
            body.contains("importViewModel.clearBinding()"),
            "clearBinding() 必须调用 importViewModel.clearBinding()（EventRowImportViewModel 那一层，"
                + "它经由 ManifestBindingSuite 钉死的 clearEventBinding 落地）—— 绕开它另写一套会制造"
                + "第二条清除路径。函数体实际是：\(body)")
        expect(
            body.contains("onBindingCleared()"),
            "clearBinding() 必须调用 onBindingCleared() —— 少了它，清除成功后行仍显示清除前的旧状态，"
                + "直到一次不相关的操作恰好触发 refresh()。函数体实际是：\(body)")
    }

    suite("PanelView：EventRowView 的 onBindingCleared 必须接到 panelModel.reload() —— 否则「清除绑定」写完 manifest.json 之后行不会重算") {
        guard let panel = codeWithoutStrings("gui/Sources/ClaudioGUI/PanelView.swift") else {
            expect(false, "读不到 PanelView.swift")
            return
        }
        expect(
            collapsingWhitespace(panel).contains("onBindingCleared: { panelModel.reload() }"),
            "operationalPanel 的 EventRowView 必须把 onBindingCleared 接到 panelModel.reload() —— 与"
                + " onImportCompleted 同一条理由：菜单驱动的清除直接写 manifest.json，行只在 reload()"
                + " 之后才会显示新状态")
    }

    suite("T11：面板事件行菜单列出包内音频（孤儿带标记），并经 EventRowImportViewModel.bindExistingFile 绑定") {
        guard
            let row = codeOnly("gui/Sources/ClaudioGUI/EventRowView.swift"),
            let panel = codeWithoutStrings("gui/Sources/ClaudioGUI/PanelView.swift")
        else {
            expect(false, "读不到 EventRowView.swift 或 PanelView.swift")
            return
        }
        let flatRow = collapsingWhitespace(row)
        let flatPanel = collapsingWhitespace(panel)
        expect(
            flatRow.contains("ForEach(existingAudioFiles)")
                && flatRow.contains(#""\(file.fileName) · 未被使用""#),
            "文件名 Menu 必须消费共享 inventory，且孤儿逐字显示「· 未被使用」")
        guard let bindBody = closureBody(
            after: "private func bindExistingFile(_ fileName: String)", in: flatRow)
        else {
            expect(false, "切不出 EventRowView.bindExistingFile")
            return
        }
        expect(
            bindBody.contains("importViewModel.bindExistingFile(fileName)")
                && bindBody.contains("guard case .success? = importViewModel.bindResult")
                && bindBody.contains("onExistingAudioBound()")
                && bindBody.contains("onPackAudioChanged(changedPackID)"),
            "复用必须走 EventRowImportViewModel 的 T3 bind 包装；只有真成功才刷新两侧，实得 \(bindBody)")
        expect(
            flatPanel.contains("existingAudioFiles: panelModel.selectedPackAudioFiles")
                && flatPanel.contains("onExistingAudioBound: { panelModel.reload() }")
                && flatPanel.contains(
                    "soundPacksRefreshCoordinator.completePanelPackAudioChange(.changed)"),
            "PanelView 必须把共享 inventory 传给四行，并把真实包音频变化同时通知保留窗口")
    }

    suite("T11：管理窗口孤儿行的删除是显式永久确认，分配与删除都接到窗口 model") {
        guard let view = codeOnly(
            "gui/Sources/SoundPacksWindow/SoundPacksWindowView.swift")
        else {
            expect(false, "读不到 SoundPacksWindowView.swift")
            return
        }
        let flat = collapsingWhitespace(view)
        expect(
            flat.contains("model.selectedAudioFiles.filter(\\.isOrphan)")
                && flat.contains(#"Text("\(file.fileName) · 未被使用")"#),
            "窗口必须只把未引用项列进孤儿区，并逐字点名文件")
        expect(
            flat.contains("model.assignSelectedAudioFile(file.fileName, to: event)"),
            "孤儿分配菜单必须接到窗口 model 的 T3 bind 路由")
        expect(
            flat.contains(
                ".accessibilityElement(children: canEditSelectedPack ? .contain : .ignore)"),
            "可编辑事件行必须保留 Menu 的 VoiceOver 子节点；只有内置只读行可继续折叠为静态状态")
        expect(
            flat.contains(".confirmationDialog(")
                && flat.contains(#"Button("永久删除", role: .destructive)"#)
                && flat.contains("此操作无法撤销"),
            "删除必须是 destructive confirmation，并明确告知不可撤销")
        expect(
            flat.contains("deleteSelectedOrphanAudioFileAfterConfirmation(")
                && flat.contains("expectedPackID: request.packID"),
            "只有确认对话框的 destructive action 才能触发永久删除")
        guard
            let detailBody = closureBody(
                after: "private var detail: some View",
                in: collapsingWhitespace(
                    codeWithoutStrings(
                        "gui/Sources/SoundPacksWindow/SoundPacksWindowView.swift") ?? "")),
            let selectedCardAt = detailBody.range(of: "if let card = selectedCard")?.lowerBound,
            let audioErrorAt = detailBody.range(of: "model.audioActionError")?.lowerBound
        else {
            expect(false, "必须能切出详情体中的窗口级音频错误与 selected-card 分支")
            return
        }
        expect(
            audioErrorAt < selectedCardAt,
            "音频操作错误必须位于 selected-card 分支之外：确认期间唯一包被外部移走时，"
                + "packNotFound 会把窗口重读为空态，若错误仍留在包详情里就会静默消失")
    }

    suite("T10：CoverageTrack 的 present 接事件色、missing 接 text-2，且真实行底仍是 surface-2") {
        // ContrastSuite 的四对数学断言只能证明「这些 hex 配在一起能过 ≥3:1」，看不见不可 import 的
        // ClaudioGUI 视图到底用了哪一个 token。少了这半，把 present 改成 hairline-strong，或把
        // missing 改回 muted `#6F665B`（暗色对 surface-2 只有 2.77:1）时，那四条都会继续全绿
        // ——断言措辞就比覆盖范围大。
        guard
            let source = codeWithoutStrings("gui/Sources/ClaudioGUI/PackGalleryView.swift"),
            let packCardBody = closureBody(after: "private struct PackCardView: View", in: source),
            let coverageTrackBody = closureBody(
                after: "private struct CoverageTrack: View", in: source),
            let coverageBody = closureBody(after: "var body: some View", in: coverageTrackBody),
            let slotBody = closureBody(
                after: "private func slot(isPresent: Bool, color: Color) -> some View",
                in: coverageTrackBody),
            let presentBody = closureBody(after: "if isPresent", in: slotBody)
        else {
            expect(
                false,
                "读不到 PackGalleryView.swift，或切不出 PackCardView / CoverageTrack.body / "
                    + "CoverageTrack.slot 的 present 分支 —— "
                    + "T10 接线无从判起")
            return
        }
        let flatCoverage = collapsingWhitespace(coverageBody)
        let flatSlot = collapsingWhitespace(slotBody)
        let flatPresent = collapsingWhitespace(presentBody)
        expect(
            whitespaceTolerantHitCount(
                of: "slot(isPresent: presentEvents.contains(event), "
                    + "color: ClaudioColor.event(event, colorScheme))",
                in: coverageBody) == 1,
            "CoverageTrack.body 必须把每个 event 的 ClaudioColor.event(...) 作为 color 参数传给"
                + " slot；否则 ContrastSuite 量到的事件色没有进入真实胶囊。body 实际是："
                + "\(flatCoverage)")
        expect(
            whitespaceTolerantHitCount(of: ".fill(color)", in: presentBody) == 1,
            "CoverageTrack present 分支必须用传入的事件色 .fill(color)；改成 hairline-strong 等"
                + "其它 token 会让静态对比度断言继续假绿。present 分支实际是：\(flatPresent)")
        expect(
            whitespaceTolerantHitCount(
                of: ".strokeBorder(ClaudioColor.textSecondary(colorScheme), lineWidth: 1)",
                in: slotBody) == 1,
            "CoverageTrack missing 的空槽描边必须接 text-2；改回 muted 会让暗色掉到 2.77:1。"
                + "slot 实际是：\(flatSlot)")
        expect(
            whitespaceTolerantHitCount(
                of: ".stroke(ClaudioColor.textSecondary(colorScheme), lineWidth: 1)",
                in: slotBody) == 1,
            "CoverageTrack missing 的斜杠必须与空槽同接 text-2；只修描边、不修斜杠仍是半个违规。"
                + "slot 实际是：\(flatSlot)")
        expect(
            whitespaceTolerantHitCount(
                of: ".fill(ClaudioColor.surface2(colorScheme))",
                in: packCardBody) == 1,
            "ContrastSuite 量的是覆盖轨对 surface-2；PackCardView 的真实行底若换了 token，必须同步"
                + "重做四对数学断言，不能让旧底的绿灯冒充真实渲染路径")
    }

    suite("EventRowView：禁用的试听 ▶ 不会被无障碍合并抢播 —— PLAN-SOUND-MANAGER.md §2.5 第 7 条 ②") {
        // structural check，理由同本文件头部：EventRowView 住在不可 import 的 ClaudioGUI
        // executableTarget，够不着行为级测试，只能读它的源码结构。字符串级契约（① / ③）已经
        // 拆成纯函数进了 `EventRowAccessibility.swift`，走真正的单测（`EventRowAccessibilitySuite`）——
        // 这一条独立存在，是因为「禁用样式是不是结构性的、有没有被某种 .combine 悄悄合并」是一个
        // **控件树形状**问题，不是字符串问题，两者用不了同一套断言。
        guard let row = codeWithoutStrings("gui/Sources/ClaudioGUI/EventRowView.swift") else {
            expect(false, "读不到 EventRowView.swift —— 这个 suite 唯一的价值就是读它")
            return
        }
        let flat = collapsingWhitespace(row)

        guard
            let previewBody = closureBody(
                after: "private var previewButtonBody: some View", in: flat)
        else {
            expect(false, "切不出 previewButtonBody 的属性体 —— 下面那条断言无从判起")
            return
        }
        expect(
            previewBody.contains(".disabled(!enabled)"),
            "previewButtonBody 必须显式 .disabled(!enabled) —— 结构性禁用，VoiceOver 才会把它播报成"
                + "「变灰」，而不是当成一个可正常触发的控件。属性体实际是：\(previewBody)")

        guard let trailingBody = closureBody(after: "private var trailing: some View", in: flat)
        else {
            expect(
                false,
                "切不出 trailing 的属性体 —— previewButtonBody 就渲染在它里面，下面那条兜底无从判起")
            return
        }
        expect(
            !trailingBody.contains(".combine"),
            "trailing（fileNameMenu + 试听 ▶ + 静音钮所在的那一段）不许出现"
                + " .accessibilityElement(children: .combine) —— 一旦出现，会把三个本该各自独立的"
                + "控件合并成一整块摘要，禁用的试听 ▶ 就被吞进那一整块播报里，VoiceOver 用户再也"
                + "无法把焦点单独移到它上面区分「这一颗是灰的」。属性体实际是：\(trailingBody)")

        guard let identityBody = closureBody(after: "private var identity: some View", in: flat)
        else {
            expect(false, "切不出 identity 的属性体 —— 下面那条兜底无从判起")
            return
        }
        expect(
            !identityBody.contains("Button"),
            "identity 节点只能包 Text（DESIGN.md 的行摘要），不许混进任何 Button —— 它自己那句"
                + " .accessibilityElement(children: .combine) 只该合并纯文字，一旦某个 Button 混"
                + "进来，它自己的独立 accessibilityLabel 会被 combine 进这一整句摘要，无法再单独"
                + "触达。属性体实际是：\(identityBody)")

        // 行级分组必须是 .contain（a11y-architect FIX 1 既有纪律，EventRowView 头部 doc comment
        // 早有记录）—— 这是「试听 ▶ / fileNameMenu / 静音钮三者各自独立可达」的结构性前提：没有它，
        // 上面三条即使各自成立，行级 .combine 照样会把它们重新合并成一整块。
        expect(
            row.contains(".accessibilityElement(children: .contain)"),
            "EventRowView 的行级分组必须是 .contain，不是 .combine —— 否则 previewButtonBody /"
                + " fileNameMenu / muteIndicator 三个独立控件会被合并成一个 VoiceOver 停靠点，"
                + "禁用的试听 ▶ 会被合并进行摘要而不是单独播报「变灰」")
    }

    suite(
        "EventRowView：三槽焦点身份各自恰好一个 owner、owner 正确、且源码顺序 = 文件名 Menu → 试听 ▶ → 静音钮（PLAN-SOUND-MANAGER.md §2.5 三槽焦点 / /codex review dcab3de,7e97bc4 P2）"
    ) {
        // structural check（理由同本文件头部）：EventRowView 住在不可 import 的 ClaudioGUI
        // executableTarget，够不着行为级测试，三槽焦点接线只能读源码结构。`PanelFocusOrderSuite` 钉的
        // 是 `panelFocusOrder(_:)` 这个纯**模型**（eventSound→eventAction→eventMute），此前**没有任何
        // 东西**钉住模型在视图侧的兑现：删掉或对调 EventRowView 里那三条 `.focused` 修饰符，纯模型测试
        // 照样全绿，而真实的 Tab / 初始焦点会退化。这条补的就是那半。
        //
        // 它同时是 `CoverageStateSuite` 那条恒真 suite（「previewClaimsActionFocus 已删」）的**真替代**：
        // 那条只重复断言 `eventActionOperable`、对「`.eventAction` 到底接在谁身上」零分辨力。真正要钉的
        // 替代不变量是「`.eventAction` 恰好一个 owner，且永远是试听 ▶」——落在这里的第 ① / ② 条。
        //
        // 读 `codeWithoutStrings`（清空字符串内容）而不是 `codeOnly`：这条断的是控件树**结构**，一句
        // 写着 `.focused(...)` 的错误消息不该被算成一处真接线（本文件头部 `codeWithoutStrings` doc）。
        guard let rowSource = codeWithoutStrings("gui/Sources/ClaudioGUI/EventRowView.swift") else {
            expect(false, "读不到 EventRowView.swift —— 这个 suite 唯一的价值就是读它")
            return
        }
        let flat = collapsingWhitespace(rowSource)

        // ① 每个焦点身份**恰好**一个 `.focused(... equals:)` 绑定 —— 直接兑现「一行 → 一个 owner」。
        //    0 个 = 这一槽在这一行 Tab 不到；≥2 个 = 两个控件抢同一个焦点身份，SwiftUI 的焦点仲裁
        //    行为未定义（正是 T2 把导入入口搬进 `.eventSound` 之前 `.eventAction` 要靠 dedup 仲裁的病）。
        func focusOwnerCount(_ target: String) -> Int {
            flat.components(separatedBy: ".focused(focusedTarget, equals: \(target))").count - 1
        }
        for target in [".eventSound(row.event)", ".eventAction(row.event)", ".eventMute(row.event)"] {
            let count = focusOwnerCount(target)
            expect(
                count == 1,
                "焦点身份 \(target) 必须恰好被一个 `.focused(focusedTarget, equals:)` 绑定占用 —— "
                    + "0 个 = 这一槽在这一行不可达（Tab 到不了、初始焦点也落不上）；≥2 个 = 两个控件抢"
                    + "同一个焦点身份，仲裁未定义。得到 \(count) 个。")
        }

        // ② owner 正确：eventSound 归 fileNameMenu，eventMute 归 muteIndicator，eventAction 归
        //    previewButtonBody（且这三条绑定就挂在各自那颗控件上，不是飘在别处）。
        guard let menuBody = closureBody(after: "private var fileNameMenu: some View", in: flat)
        else {
            expect(false, "切不出 fileNameMenu 的属性体 —— 下面那条 owner 断言无从判起")
            return
        }
        expect(
            menuBody.contains(".focused(focusedTarget, equals: .eventSound(row.event))"),
            "文件名 Menu（fileNameMenu）必须是 `.eventSound` 的 owner —— 它是三态下都可操作的那一槽，"
                + "所以一行的初始焦点落在它上，而不是还禁着的试听 ▶。fileNameMenu 属性体实际是：\(menuBody)")

        guard let muteBody = closureBody(after: "private var muteIndicator: some View", in: flat)
        else {
            expect(false, "切不出 muteIndicator 的属性体 —— 下面那条 owner 断言无从判起")
            return
        }
        expect(
            muteBody.contains(".focused(focusedTarget, equals: .eventMute(row.event))"),
            "静音钮（muteIndicator）必须是 `.eventMute` 的 owner。muteIndicator 属性体实际是：\(muteBody)")

        guard let trailingBody = closureBody(after: "private var trailing: some View", in: flat)
        else {
            expect(false, "切不出 trailing 的属性体 —— 下面 eventAction owner + 三槽顺序都无从判起")
            return
        }
        expect(
            trailingBody.contains(
                "previewButtonBody.focused(focusedTarget, equals: .eventAction(row.event))"),
            "试听 ▶（previewButtonBody）必须是 `.eventAction` 的 owner，且这条绑定就挂在 trailing 里那颗"
                + " previewButtonBody 上 —— 这是 `CoverageStateSuite` 删掉的 previewClaimsActionFocus 仲裁"
                + "的真替代：三态下 `.eventAction` 只剩这一个候选。trailing 属性体实际是：\(trailingBody)")

        // ③ 三槽源码顺序 = 文件名 Menu → 试听 ▶ → 静音钮（`panelFocusOrder` 的 eventSound → eventAction
        //    → eventMute 在视图侧的兑现点）。顺序错了，Tab 键顺序与视觉从左到右就对不上。
        guard let menuAt = trailingBody.range(of: "fileNameMenu")?.lowerBound,
            let previewAt = trailingBody.range(of: "previewButtonBody")?.lowerBound,
            let muteAt = trailingBody.range(of: "muteIndicator")?.lowerBound
        else {
            expect(
                false,
                "trailing 里必须同时出现 fileNameMenu / previewButtonBody / muteIndicator 三颗控件 —— "
                    + "少一颗，这一行就缺一个焦点槽。trailing 属性体实际是：\(trailingBody)")
            return
        }
        expect(
            menuAt < previewAt && previewAt < muteAt,
            "trailing 的三槽源码顺序必须是 文件名 Menu → 试听 ▶ → 静音钮（与 `panelFocusOrder` 的 "
                + "eventSound → eventAction → eventMute 一致）—— 顺序对调，Tab 键顺序与视觉从左到右就"
                + "对不上。实际位置：menu=\(menuAt) preview=\(previewAt) mute=\(muteAt)")
        }

    suite("T12：管理窗口恢复出厂是内置包专属的显式替换确认，成功/失败告知都在窗口内可见") {
        guard let view = codeOnly(
            "gui/Sources/SoundPacksWindow/SoundPacksWindowView.swift")
        else {
            expect(false, "读不到 SoundPacksWindowView.swift")
            return
        }
        let flat = collapsingWhitespace(view)
        expect(
            flat.contains("if model.selectedPackIsBuiltinReadOnly")
                && flat.contains(#"Button("恢复出厂声音…")"#),
            "恢复入口必须只在内置包详情中出现，并用带省略号的明确动作标签预告后续确认")
        expect(
            flat.contains(".confirmationDialog(")
                && flat.contains(#"Button("替换并恢复出厂声音", role: .destructive)"#)
                && flat.contains("一个文件都不会删除")
                && flat.contains("完成后会显示实际路径"),
            "替换必须有 destructive confirmation，并在执行前说清旧目录会搬走、零删除和路径告知")
        expect(
            flat.contains("restoreSelectedFactoryPackAfterConfirmation(")
                && flat.contains("expectedPackID: request.packID"),
            "只有确认对话框的 destructive action 才能触发 restore，且必须带确认时的包 id 防陈旧选择")
        expect(
            flat.contains(#"Button("重试恢复「\(displayName)」…")"#)
                && flat.contains("retryFailedFactoryPackRestoreAfterConfirmation(")
                && flat.contains(".focused($focusedTarget, equals: .retryFactoryRestore)"),
            "publish 失败移除原包后，窗口级失败行必须保留经过确认的重试入口并接入真实焦点序")
        expect(
            flat.contains("factoryPackRestoreNoticeMessage(")
                && flat.contains("model.factoryRestoreActionError"),
            "成功 salvage 路径告知与失败原因都必须在窗口内渲染，不能只留在 model")
        guard
            let detailBody = closureBody(
                after: "private var detail: some View",
                in: collapsingWhitespace(
                    codeWithoutStrings(
                        "gui/Sources/SoundPacksWindow/SoundPacksWindowView.swift") ?? "")),
            let selectedCardAt = detailBody.range(of: "if let card = selectedCard")?.lowerBound,
            let restoreErrorAt =
                detailBody.range(of: "model.factoryRestoreActionError")?.lowerBound
        else {
            expect(false, "必须能切出详情体中的窗口级恢复状态与 selected-card 分支")
            return
        }
        expect(
            restoreErrorAt < selectedCardAt,
            "恢复失败提示必须位于 selected-card 分支之外：publish 在 salvage 后失败会让原包从列表消失，"
                + "若把失败行留在包详情里，零 fallback 时整条错误不可见，有 fallback 时又会错挂到别的包")
        expect(
            flat.contains(".focused($focusedTarget, equals: .restoreFactoryPack)"),
            "恢复出厂按钮必须接进窗口专用焦点模型")
    }
}
