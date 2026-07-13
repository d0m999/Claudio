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
@MainActor
private func codeOnly(_ relativePath: String) -> String? {
    guard let text = source(relativePath) else { return nil }
    return text.split(separator: "\n", omittingEmptySubsequences: false)
        .map { line -> String in
            guard let range = line.range(of: "//") else { return String(line) }
            return String(line[line.startIndex..<range.lowerBound])
        }
        .joined(separator: "\n")
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
@MainActor
private func guiSources() -> [(path: String, code: String)] {
    let relativeRoot = "gui/Sources/ClaudioGUI"
    let root = repoRoot().appendingPathComponent(relativeRoot)
    guard let walker = FileManager.default.enumerator(atPath: root.path) else { return [] }
    var found: [(path: String, code: String)] = []
    for case let name as String in walker where name.hasSuffix(".swift") {
        guard let code = codeOnly("\(relativeRoot)/\(name)") else { continue }
        found.append((path: name, code: code))
    }
    return found.sorted { $0.path < $1.path }
}

@MainActor
func runViewWiringSuites() {
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
        // config.json 还不存在，`loadPanelConfig` 回落成 `selectedPack: ""` —— 于是包名是**空的**。
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
                handlerBody.contains("refresh()"),
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

        if let rowsAt = panel.range(of: "ForEach(eventRows")?.lowerBound,
            let noticeAt = panel.range(of: "ActionNoticeRow(")?.lowerBound
        {
            expect(
                rowsAt < noticeAt,
                "四行事件覆盖度必须排在告知行**之前** —— 换包告知白纸黑字写着「事件行里会标出哪些还缺」。"
                    + "顶替上来的包只过了 isUsablePack（它一个字节的音频都不查，usablePackIDs.first 完全可能是"
                    + "一个只映了 1/4 事件的用户包），所以那几行是这句话之后唯一说真话的地方。把它们挪到告知"
                    + "下面，用户就得先读到「哪些还缺」、再往下找那个「哪些」")
        } else {
            expect(false, "PanelView 里必须同时有 ForEach(eventRows 与 ActionNoticeRow(")
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
        expect(
            panel.contains("EventMuteController(configFile: configFile, lockFile: lockFile)"),
            "PanelView 必须把它自己的 lockFile（= config.lock）转发给 EventMuteController —— "
                + "静音开关写的是 config.json")
        expect(
            panel.contains("settingsLockFile: ClaudioPaths.settingsLockFile"),
            "PanelView 构造 OnboardingActionEnvironment 时，settingsLockFile 必须是独立的 "
                + "settings.lock —— takeOver 路径同时写 settings.json（installClaudioHooks），"
                + "它绝不能与 config.json 的写者共用一把锁（那正是这次分锁要拆开的东西）")

        // 负向兜底：PanelView 在**任何位置**都不该出现 play 的去抖锁。它一个字节都不写
        // play.state，也不参与去抖。这一条能同时逮住上面四条各自的变异，且因为 `codeOnly`
        // 已剥掉注释，谈论 playLockFile 的**散文**不会把它假红（这正是本文件头部记着的那次翻车）。
        expect(
            !panel.contains("playLockFile"),
            "PanelView 里出现了 playLockFile —— 它不写 play.state、不参与去抖，"
                + "碰 play 的锁只会重新把提示音吞掉")
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

        // 普查一：全 target 只许有一个 `PanelView(` 构造点，且必须在 MenuBarController 里。
        var constructionSites: [String: Int] = [:]
        for file in sources {
            let count = file.code.components(separatedBy: "PanelView(").count - 1
            if count > 0 { constructionSites[file.path] = count }
        }
        expect(
            constructionSites == ["MenuBarController.swift": 1],
            "全 ClaudioGUI 只许有**一处** `PanelView(` 构造点，且只许在 MenuBarController.swift 里，"
                + "实得 \(constructionSites) —— 这条 suite 与它上面那条（PanelView 的 lockFile 默认值）"
                + "都建立在「全 target 唯一构造点、且走默认值」这个前提上。多出第二处，两条断言的"
                + "保护范围就都缩水了，必须重新想")

        // 普查二：除 PanelView 自己之外，全 target 的**代码**里不许出现 lockFile。
        // PanelView.swift 是唯一的例外，因为那个默认值与两条转发就住在它里面（上面那条 suite 钉的）。
        // `PackGalleryView` 的 doc comment 里提过 `selectPack(…lockFile:)`，`codeOnly` 已把它剥掉 ——
        // 这正是本文件头部记着的那次翻车（把谈论代码的文字当代码断）。
        var lockLeaks: [String: Int] = [:]
        for file in sources where !file.path.hasSuffix("PanelView.swift") {
            let count = file.code.components(separatedBy: "lockFile").count - 1
            if count > 0 { lockLeaks[file.path] = count }
        }
        expect(
            lockLeaks.isEmpty,
            "ClaudioGUI 里除 PanelView.swift 之外的文件出现了 lockFile：\(lockLeaks) —— "
                + "这会绕过 PanelView 那个唯一活着的默认值（= config.lock），把静音、切包、接管"
                + "三个 config.json 写者一起送回调用点指定的那把锁上。传 playLockFile = 阶段 A 的"
                + "分锁当场失效，而 PanelView.swift 一个字都不用改，整套 GUI 测试照样全绿。"
                + "GUI 的锁只有一个来源：PanelView 的默认值")
    }

    suite("MenuBarController：popover 关闭必须发出隐藏信号，而且必须在那句会提前 return 的 guard 之前（T17d）") {
        guard let controller = codeOnly("gui/Sources/ClaudioGUI/MenuBarController.swift") else {
            expect(false, "读不到 MenuBarController.swift")
            return
        }
        expect(
            controller.contains("focusCoordinator.notePanelHidden()"),
            "popoverDidClose 必须告诉 coordinator 面板不在屏幕上了 —— 这是 view-model 判断"
                + "「一条失败诞生时有没有人在看」的唯一依据")

        // 这不是普通的文本绊线，它钉的是**顺序**：`popoverDidClose` 里那句 `guard NSApp.isActive`
        // 在「用户切到别的 app 导致 popover 关闭」这条路径上会直接 return —— 而那**正是** T17d 修的
        // 那个 bug 的主路径。把 notePanelHidden() 挪到 guard 之后，编译绿、上面那条 contains 也绿，
        // 而 bug 原封不动地复活，且只在最常见的那条路径上复活。所以顺序本身必须是一条断言。
        guard let hidden = controller.range(of: "focusCoordinator.notePanelHidden()"),
            let guardIsActive = controller.range(of: "guard NSApp.isActive")
        else {
            expect(false, "在 MenuBarController 里找不到 notePanelHidden() 或 guard NSApp.isActive")
            return
        }
        expect(
            hidden.lowerBound < guardIsActive.lowerBound,
            "notePanelHidden() 必须出现在 `guard NSApp.isActive` **之前**。放在之后 = 切换 app 关闭"
                + "面板这条路径永远收不到隐藏信号（那句 guard 会提前 return），而那恰恰是「点完接管就"
                + "切走、安装在后台失败」的那条路径 —— 静默失败当场复活")
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
}
