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

    // ── 失败一侧的**极性**（`/codex review` [P1]，本轮修复）────────────────────────────────────
    //
    // 上一版这里只有一条 suite：「其他失败 → .noRefresh」，把 `.configReadFailure` / `.configWriteFailure`
    // 一并断言成「不重扫」，理由写的是「config.json 逐字节未变（setEventEnabled 从不半写）」。
    //
    // **那条理由把「我们没写」偷换成了「文件没变」。** `.configReadFailure` 的字面意思就是：**别人**在
    // 面板打开之后把那份文件改坏了。文件变了，只是不是被我们变的 —— 读模型**已经陈了**，而旧规格让它
    // 停在 `.operational`，面板于是在一份它刚刚亲口承认读不动的 config 上继续顶着四行活控件。
    //
    // 变异台账 12/12 全绿，一条也没逮到它 —— 因为台账验的是「实现符合规格」，而**错的是规格**。这就是
    // 变异测试的天花板：它永远告诉不了你，你钉死的那份规格本身是错的。
    //
    // 极性因此倒过来：`.noRefresh` 是一张「**可证明**磁盘没被碰过」的**围栏**白名单（只有锁失败配得上），
    // 其余一律 `.full`。下面两条 suite 分守围栏的两侧。

    // 围栏**内**侧：只有这两条配得上 .noRefresh。
    //
    // 这一组逮的变异是：**任何失败都判 .full**（`if muteSucceeded { .enabledFlagsOnly }; return .full`）。
    // 它在「成功」「.configMissing」「.configReadFailure」那些格上给的答案全对，只有这两格是错的 ——
    // 而错的代价是真的：每一次锁竞争（并发的 `claudio use` 持着 config.lock）都会在主线程上扫一遍整个
    // 包库，扫出来的东西与扫之前逐字节相同。「失败了就重扫，反正更安全」不是保守，是把一次锁竞争变成
    // 一次全库磁盘扫描。
    suite("panelRefreshRoute：锁失败 → 不重扫（.noRefresh）—— 锁都没拿到，磁盘一个字节没碰") {
        let provablyUntouched: [(name: String, error: SetEventEnabledError)] = [
            ("lockBusy", .lockBusy),
            ("lockFailed", .lockFailed(errno: 35)),
        ]
        for failure in provablyUntouched {
            expect(
                panelRefreshRoute(muteSucceeded: false, error: failure.error) == .noRefresh,
                "`.\(failure.name)`：锁根本没拿到 → config.json 没读、没写，读模型不比点击之前更陈。"
                    + "重扫扫不出任何新东西，只会把一次锁竞争变成一次主线程全库扫描。得到："
                    + "\(panelRefreshRoute(muteSucceeded: false, error: failure.error))")
        }
    }

    // 围栏**外**侧：其余每一条都必须 .full —— 这一组是本轮 [P1] 的正面钉子。
    //
    // 逮的变异正是**修复之前的那行代码**：`error == .configMissing ? .full : .noRefresh`。它对
    // `.configMissing` 那一格答对，对下面另外三格全答错。这三条断言里任何一条被删，那行旧代码就能原样
    // 复活而测试全绿 —— 所以三条都必须在，不许合并成一条「至少有一个是 .full」。
    suite("panelRefreshRoute：config 已被外部改动 / 原因不明 → 必须全量重读（.full）") {
        let revealsStaleReadModel: [(name: String, error: SetEventEnabledError?, becomes: String)] = [
            ("configMissing", .configMissing, "configState 必须重路由到 .needsPack"),
            (
                "configReadFailure", .configReadFailure(reason: "master_volume is a string"),
                "configState 必须重路由到 .malformed —— 这是本轮 [P1] 的第一条"
            ),
            (
                "configWriteFailure", .configWriteFailure(reason: "directory not writable"),
                "configState 必须重路由到 .unwritable —— 这是本轮 [P1] 的第一条"
            ),
            (
                "nil（失败却没记下错误）", nil,
                "不知道 = 去读盘。EventMuteController 的契约不该允许这一格出现，但缺省必须落在安全侧"
            ),
        ]
        for failure in revealsStaleReadModel {
            expect(
                panelRefreshRoute(muteSucceeded: false, error: failure.error) == .full,
                "`.\(failure.name)` 证明磁盘上那份 config 已经不是面板打开时的那份了（或我们压根不知道）"
                    + " —— \(failure.becomes)。判成 .noRefresh = 面板顶着四行活控件、在一份它刚刚亲口"
                    + "承认读不动的 config 上继续撒谎，直到用户重开 popover 才自愈。得到："
                    + "\(panelRefreshRoute(muteSucceeded: false, error: failure.error))")
        }
    }

    // ⚠️ 上面两张表是**手抄**的（`SetEventEnabledError` 有关联值，不是 `CaseIterable`）。守住「将来加了
    // 第六个 case 却忘了归类」的**不是**这两张表 —— 是 `panelRefreshRoute` 里那个**穷尽 switch**：
    // `ClaudioCore` 与 `ClaudioGUICore` 同包编译（非 resilient），加一个 case 而不在那个 switch 里归类，
    // **编译不过**。这道围栏由编译器守，不由断言守 —— 所以这里不再写一条「唯一能路由到 .full 的只许是
    // X」的负向兜底：那种兜底恰恰是上一版把极性写反的地方（它把白名单钉死成了「我认得的那一个」）。

    // ── 切包那一半（`/codex review` 第二条 [P1]）────────────────────────────────────────────────
    //
    // 静音和切包是面板仅有的两条 config 写路径。它们撞上同一份被外部改坏的 config.json 时必须给出同一个
    // 答案 —— 上一版切包的失败分支**只记 error、从不 reload**，于是同一个 [P1] 在这条路上原封不动地
    // 复发了一遍。同一种极性，同样穷尽的 switch。
    suite("packSwitchNeedsFullReload：只有「可证明磁盘没被碰过」的失败才跳过重读") {
        let skipsReload: [(name: String, error: UseError)] = [
            ("lockBusy", .lockBusy),
            ("lockFailed", .lockFailed(errno: 35)),
            ("invalidPackID", .invalidPackID("../etc")),
        ]
        for failure in skipsReload {
            expect(
                !packSwitchNeedsFullReload(after: failure.error),
                "`.\(failure.name)`：碰盘之前就被拒了（或锁没拿到）—— 什么也没揭示，重扫是纯浪费。"
                    + "得到 needsFullReload=\(packSwitchNeedsFullReload(after: failure.error))")
        }

        let revealsStale: [(name: String, error: UseError, why: String)] = [
            (
                "packNotFound", .packNotFound("ghost"),
                "用户点的那张卡对应的包目录不在磁盘上 → packCards 已经陈了（画廊挂着一张幽灵卡）"
            ),
            (
                "configReadFailure", .configReadFailure(reason: "master_volume is a string"),
                "config.json 被外部改坏了 → configState 必须落到 .malformed"
            ),
            (
                "configWriteFailure", .configWriteFailure(reason: "directory not writable"),
                "config.json 的目录写不动了 → configState 必须落到 .unwritable"
            ),
        ]
        for failure in revealsStale {
            expect(
                packSwitchNeedsFullReload(after: failure.error),
                "`.\(failure.name)`：\(failure.why) —— 不 reload = 面板红字说切包失败，四行活控件却原样"
                    + "留在屏幕上。得到 needsFullReload=\(packSwitchNeedsFullReload(after: failure.error))")
        }
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
