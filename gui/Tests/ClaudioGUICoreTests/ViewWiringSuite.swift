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

@MainActor
func runViewWiringSuites() {
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
                + " .installed（点「修复」→ 撞上 play.lock → 失败，但二进制和 hooks 都在位），"
                + "那时 onboarding 卡根本不在屏幕上。上一版这里只认 branch: .disconnect，"
                + "于是那条失败一个像素都没有：绿点、静音、零诊断")
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
