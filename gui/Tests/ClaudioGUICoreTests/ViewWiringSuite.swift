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
private func collapsingWhitespace(_ text: String) -> String {
    text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
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
                + " .installed → body 切到 operationalPanel，而 config/eventRows/packCards 三个 @State"
                + "是 app **启动时**（= setup 之前）读的盘 —— 用户在接管成功的那一秒看到的是四行「未配置 /"
                + "文件丢失」+ 一个空的切包画廊，真实的包和 config 明明已经写好在磁盘上了。"
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
        // 它是三个 say() 调用点里唯一一个曾经**不** refresh 的。而 refresh() 写的正是 `config` /
        // `packCards` 两个 @State —— 面板句里包名的唯一来源。少了它：一次**无告知的成功接管**，若 SwiftUI
        // 先跑这个 handler（**未文档化**的顺序），它算 header 时 `onboardingViewModel.state` 已经是
        // `.installed`（引用类型，早更新了），而 packCards / config 还是 **app 启动时**那份 —— 那时
        // config.json 还不存在，`loadPanelConfig` 回落成 `.needsPack`（`config` 走 `resolvedConfig`
        // 的空包默认值）—— 于是包名是**空的**。
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
        // **1600/1600 全绿**。默认值写对、转发线接错，是一个测试一个字都不会红的洞，
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

        expect(
            panel.contains("settingsLockFile: ClaudioPaths.settingsLockFile"),
            "PanelView 构造 OnboardingActionEnvironment 时，settingsLockFile 必须是独立的 "
                + "settings.lock —— takeOver 路径同时写 settings.json（installClaudioHooks），"
                + "它绝不能与 config.json 的写者共用一把锁（那正是这次分锁要拆开的东西）")

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
        // 默认值声明没动、两条转发没动、`!contains("playLockFile")` 也没动 —— **1604 条全绿**。
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
        var lockLeaks: [String: Int] = [:]
        for file in sources where !file.path.hasSuffix("PanelView.swift") {
            let count = file.code.lowercased().components(separatedBy: "lockfile").count - 1
            if count > 0 { lockLeaks[file.path] = count }
        }
        expect(
            lockLeaks.isEmpty,
            "ClaudioGUI 里除 PanelView.swift 之外的文件出现了锁（lockFile / configLockFile / "
                + "settingsLockFile，大小写不敏感地数）：\(lockLeaks) —— 这会绕过 PanelView 那个唯一"
                + "活着的默认值（= config.lock），把静音、切包、接管三个 config.json 写者一起送回"
                + "调用点指定的那把锁上。传 playLockFile = 阶段 A 的分锁当场失效，而 PanelView.swift "
                + "一个字都不用改，整套 GUI 测试照样全绿。GUI 的锁只有一个来源：PanelView 的默认值")
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
        guard let actions = codeOnly("gui/Sources/ClaudioGUICore/OnboardingActions.swift") else {
            expect(false, "读不到 OnboardingActions.swift —— 这条 suite 唯一的价值就是读它")
            return
        }
        expect(
            actions.contains("packsLockFile: environment.packsLockFile"),
            "接管路径造 `SetupEnvironment` 时必须**逐字**转发 `packsLockFile: environment.packsLockFile`"
                + " —— 漏掉它，`SetupEnvironment` 会静默落回 `ClaudioPaths.packsLockFile` 那个真实路径："
                + "生产上碰巧仍然互斥（两边都用默认值），而**测试会去用户的 `~/.claudio` 上开一把真锁**，"
                + "并与他正在运行的 Claudio.app 抢锁。前两把锁（config / settings）已经各有一条断言，"
                + "这是第三条。")
        // 负向：不许绕过 environment 直接朝下游写死一把锁 —— 与前两把锁那两条负向兜底同形。
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
}
