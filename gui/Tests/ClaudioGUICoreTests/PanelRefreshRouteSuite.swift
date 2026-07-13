import ClaudioCore
import ClaudioGUICore
import Foundation

// MARK: - `panelRefreshRoute` —— 静音写盘的结果 → 面板做哪一种刷新
//
// ## 这个 suite 存在的理由（`/codex review 573336d` [P2]）
//
// 这条路由此前是 `PanelView.toggleMute` 里的三行 `if / else if`，而 `PanelView` 住在 `@main`
// executableTarget，测试 **import 不进来** —— 于是它唯一的守卫是 `ViewWiringSuite` 的一条文本绊线。
// 那条绊线是坏的（`&& panel.contains("refresh()")` 恒真：`refresh()` 在那个文件里出现 37 次），而且
// **即使修好**（收进 `toggleMute` 的函数体切片）也守不住把两个分支**对调**：切片里 `.configMissing`
// 与 `refresh()` 一个字符都不少，绊线照绿，面板已经在一个被删掉的 config 上顶着四行活控件。
//
// 文本绊线守得住「这行代码还在不在」，守不住「哪个结果走哪条路」。后者是行为，只有行为断言钉得死。
// 所以判断搬进了 `ClaudioGUICore`（纯函数、不碰磁盘、不碰 `@State`），下面这些断言直接对着**返回值**打：
// 对调分支、删分支、把 `.configMissing` 归进 `.noRefresh` —— 三种变异各自当场变红，且与 `refresh()`
// 这个名字在任何文件里出现过多少次**完全无关**。
//
// `PanelView` 那一侧只剩「三条路各接哪个方法」，由 `ViewWiringSuite` 的切片绊线盯着 —— 那才是绊线
// 够得着的东西。两条测试各守一半，谁也不假装守到了对方那一半。

@MainActor
func runPanelRefreshRouteSuites() {
    suite("panelRefreshRoute：写成功 → 只重算 enabled 位（.enabledFlagsOnly）") {
        expect(
            panelRefreshRoute(muteSucceeded: true, error: nil) == .enabledFlagsOnly,
            "一次成功的静音写盘只翻了 config.json 里的一个 bool —— 它不可能改变任何包的 manifest、"
                + "任何声音文件的存在性、或磁盘上有哪些包。走全量 refresh() = 点一次静音钮就在主线程上"
                + "扫一遍整个包库。得到：\(panelRefreshRoute(muteSucceeded: true, error: nil))")
    }

    suite("panelRefreshRoute：.configMissing → **全量** refresh()（.full）—— 这条是 D43 的要害") {
        expect(
            panelRefreshRoute(muteSucceeded: false, error: .configMissing) == .full,
            "config.json 在面板**已经打开之后**被外部删掉：configState / eventRows 此刻全是陈的（仍是"
                + " .operational，仍在一个不存在的文件上画四行活控件）。只有全量 refresh() 会让"
                + " configState 重路由到 .needsPack。判成 .enabledFlagsOnly（只重算 enabled 位）= 四行"
                + "活控件原样留在屏幕上，用户每点一次都必然失败 —— 正是「面板顶着绿点撒谎」。"
                + "得到：\(panelRefreshRoute(muteSucceeded: false, error: .configMissing))")
    }

    // 这一组单独逮一个变异：**任何失败都判 .full**（`if muteSucceeded { .enabledFlagsOnly }; return .full`）。
    // 上面两条 suite 对它**全绿** —— 它们只问了「成功」和「.configMissing」，而这个变异在这两格上给的
    // 答案都对。它错的是**剩下那些格**：每一次锁竞争（另一个 config.json 写者持锁，比如并发的
    // `claudio use`）都会在主线程上扫一遍整个包库，而 config.json 根本没变（setEventEnabled 从不半写），
    // 扫出来的东西与扫之前逐字节相同。「失败了就重扫一遍，反正更安全」不是保守，是把一次锁竞争变成一次
    // 全库磁盘扫描。
    suite("panelRefreshRoute：其他失败 → 不重扫（.noRefresh）—— config.json 原封未动，扫了也白扫") {
        let untouchedFailures: [(name: String, error: SetEventEnabledError)] = [
            ("lockBusy", .lockBusy),
            ("lockFailed", .lockFailed(errno: 35)),
            ("configReadFailure", .configReadFailure(reason: "unreadable")),
            ("configWriteFailure", .configWriteFailure(reason: "disk full")),
        ]
        for failure in untouchedFailures {
            expect(
                panelRefreshRoute(muteSucceeded: false, error: failure.error) == .noRefresh,
                "`.\(failure.name)` 之后 config.json 逐字节未变（setEventEnabled 从不半写）—— 读模型"
                    + "没有变陈，重扫磁盘扫不出任何新东西。解释由 errorNotice 出，不由一次全库扫描出。"
                    + "得到：\(panelRefreshRoute(muteSucceeded: false, error: failure.error))")
        }
        // ⚠️ `SetEventEnabledError` 有关联值，不是 `CaseIterable` —— 这张表是**手抄**的。将来给它加了
        // 第五个 case 而忘了抄进来，这条 suite 不会红（它只遍历它认得的四个）。下面那条负向断言是这张
        // 手抄表的兜底：**唯一**能路由到 .full 的错误只许是 .configMissing。
        expect(
            panelRefreshRoute(muteSucceeded: false, error: nil) == .noRefresh,
            "失败但没记下错误（不该发生：EventMuteController 在返回 false 的同一格里必写 lastError）——"
                + "缺省也必须是「什么都不做」，不能是 .full：一条没有原因的失败不该触发全库重扫")
    }

    suite("panelRefreshRoute：成功压过陈旧的 error —— 不许被上一次失败的残留改道") {
        // EventMuteController 成功时会把 lastError 清成 nil，但这个纯函数**不依赖**它那么做：
        // 一次成功的写盘意味着 config.json 就在那里、且只有一个 bool 变了。如果这里写成
        // 「先看 error 再看 succeeded」，一次「.configMissing 失败 → 用户选了包 → 再点静音成功」
        // 的正常序列会在成功那一格触发一次没必要的全库扫描（如果 lastError 恰好没被清）。
        expect(
            panelRefreshRoute(muteSucceeded: true, error: .configMissing) == .enabledFlagsOnly,
            "succeeded 必须压过 error —— 写成功了就是写成功了，config.json 此刻就在磁盘上。"
                + "得到：\(panelRefreshRoute(muteSucceeded: true, error: .configMissing))")
        expect(
            panelRefreshRoute(muteSucceeded: true, error: .lockBusy) == .enabledFlagsOnly,
            "同上：陈旧的 .lockBusy 不该把一次成功的写盘路由到别处去")
    }

    // ── 整条链：磁盘 → setEventEnabled → EventMuteController → 路由 ────────────────────────────
    //
    // 上面那些是对纯函数打的。这一条把它接回**真实磁盘状态**：一个真的不存在的 config.json，走真的
    // `setEventEnabled`，拿真的 `lastError`，再问路由。它守的是**接缝**：万一哪天 `setEventEnabled`
    // 对缺失的 config 不再返回 `.configMissing`（比如又改回「静默新建」），上面那些纯函数断言会全绿
    // ——它们喂的是手写的 `.configMissing`，不是磁盘真的吐出来的那个。
    //
    // 这条链上唯一还没被任何测试覆盖的一格，是 `PanelView` 把 `.full` 接到 `refresh()` 的那一行
    // （executableTarget，import 不进来）—— 那一格由 ViewWiringSuite 的切片绊线盯着。整条链到此闭合。
    suite("整条链：config.json 不存在 → EventMuteController 记下 .configMissing → 路由必须是 .full") {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let controller = EventMuteController(
                configFile: configFile, lockFile: root.appendingPathComponent("config.lock"))

            let succeeded = controller.setEnabled(.stop, enabled: false)
            expect(!succeeded, "缺失的 config.json 必须让这次调用失败，而不是静默新建一份（D23 定稿①）")
            expect(
                panelRefreshRoute(muteSucceeded: succeeded, error: controller.lastError) == .full,
                "磁盘上真的没有 config.json 时，整条链必须把面板送去 .full —— 这是「面板打开着，"
                    + "文件被外部删了」在真实磁盘上的样子。得到："
                    + "\(panelRefreshRoute(muteSucceeded: succeeded, error: controller.lastError))")
        }
    }
}
