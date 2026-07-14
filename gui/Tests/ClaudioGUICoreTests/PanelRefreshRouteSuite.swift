import ClaudioCore
import ClaudioGUICore
import Foundation

// MARK: - `panelRefreshRoute` / `packSwitchRefreshRoute` —— 一次 config 写盘的结果 → 面板做哪一种刷新
//
// ## 这个 suite 存在的理由（`/codex review 573336d` [P2]）
//
// 这条路由此前是 `PanelView.toggleMute` 里的三行 `if / else if`，而 `PanelView` 住在 `@main`
// executableTarget，测试 **import 不进来** —— 它唯一的守卫是 `ViewWiringSuite` 的一条文本绊线，而那条
// 绊线是坏的（`&& panel.contains("refresh()")` 恒真：`refresh()` 在那个文件里出现 37 次）。文本绊线守得住
// 「这行代码还在不在」，守不住「哪个结果走哪条路」。后者是行为，只有行为断言钉得死。
//
// ## 而行为断言也只能钉死「实现符合规格」—— 规格错了它一样全绿
//
// 上一版这里的失败一侧断言的是：`.configReadFailure` / `.configWriteFailure` → `.noRefresh`，理由写着
// 「config.json 逐字节未变（setEventEnabled 从不半写）」。**那条理由把「我们没写」偷换成了「文件没变」。**
// `.configReadFailure` 的字面意思就是：别人在面板打开之后把那份文件改坏了。变异台账 12/12 全绿，一条也
// 没逮到它 —— 因为台账验的是「实现符合规格」，而错的是**规格**。
//
// 第一刀（1c65215）倒了极性，却把 `.lockFailed` 留在了「跳过」那一侧，**同一个偷换概念原样复发**：
// 「锁都没拿到 ⇒ config.json 没被碰 ⇒ 读模型没变陈」—— 而读模型是**两根轴**（内容 + 目录可写性），
// `.lockFailed(EACCES)` 恰恰是第二根轴出事时会拿到的东西。实测：合法 config + 目录 chmod 0500 + 尚未建出
// config.lock，点一次静音 → muteError = .lockFailed(13)、configState 停在 .operational，而此刻磁盘真相
// 已经是 .unwritable。
//
// 极性最终定稿（三条路，见 `PanelRefreshRoute` 的类型文档）：
//
//   .noRefresh —— **可证明什么也没揭示**。只有 `.lockBusy`（+ 切包侧的 `.invalidPackID`）配得上。
//   .configOnly —— 「证明不了 ⇒ 去读盘」，但只读便宜的那一半（config.json + 目录探针，不扫包库）。
//   .full      —— 只给**包库本身可能已经陈了**的两格（`.configMissing` / `.packNotFound`）。
//
// 关键：`.lockFailed` 不是「目录坏了」的证据 —— 它是一袋**未知** errno。它什么也证明不了，而围栏要的从来
// 不是「证明变了才刷新」，是「**证明没变**才敢不刷新」。

@MainActor
func runPanelRefreshRouteSuites() {
    suite("panelRefreshRoute：写成功 → 只重读 config（.configOnly），不扫包库") {
        expect(
            panelRefreshRoute(muteSucceeded: true, error: nil) == .configOnly,
            "一次成功的静音写盘只翻了 config.json 里的一个 bool —— 它不可能改变任何包的 manifest、任何声音"
                + "文件的存在性、或磁盘上有哪些包。走 .full = 点一次静音钮就在主线程上扫一遍整个包库。"
                + "得到：\(panelRefreshRoute(muteSucceeded: true, error: nil))")
    }

    suite("panelRefreshRoute：成功压过陈旧的 error —— 不许被上一次失败的残留改道") {
        // EventMuteController 成功时会把 lastError 清成 nil，但这个纯函数**不依赖**它那么做：一次成功的
        // 写盘意味着 config.json 就在那里。如果这里写成「先看 error 再看 succeeded」，一条「失败 → 用户
        // 修好 → 再点静音成功」的正常序列会在成功那一格被陈旧 error 拐去 .full（全库扫描）或 .noRefresh
        // （读模型不更新）。
        expect(
            panelRefreshRoute(muteSucceeded: true, error: .configMissing) == .configOnly,
            "succeeded 必须压过 error —— 写成功了就是写成功了，config.json 此刻就在磁盘上。得到："
                + "\(panelRefreshRoute(muteSucceeded: true, error: .configMissing))")
        expect(
            panelRefreshRoute(muteSucceeded: true, error: .lockBusy) == .configOnly,
            "同上：陈旧的 .lockBusy 不该把一次成功的写盘路由到别处去")
    }

    // ── 围栏内侧：**可证明什么也没揭示**的，只有 .lockBusy 一条 ──────────────────────────────────
    //
    // 这一组逮的变异是「失败一律去读盘」（把 .lockBusy 也并进 .configOnly / .full）。它在其余每一格上
    // 给的答案都对，只有这一格错 —— 而错的代价是真的：锁竞争是**高频常态**（并发的 `claudio use`、另一个
    // 面板），每一次都去读一遍盘，读出来的东西与读之前逐字节相同。
    suite("panelRefreshRoute：.lockBusy → 什么都不做（.noRefresh）—— 我们连 config.json 都没打开过") {
        expect(
            panelRefreshRoute(muteSucceeded: false, error: .lockBusy) == .noRefresh,
            "另一个写者持着锁 —— 我们连 config.json 都没打开过，读模型不比点击之前更陈。这是唯一**可证明**"
                + "什么也没揭示的失败，也是唯一的高频常态。解释由 errorNotice 出。得到："
                + "\(panelRefreshRoute(muteSucceeded: false, error: .lockBusy))")
    }

    // ── 围栏外侧之一：证明不了 ⇒ 去读盘，但只读便宜的那一半 ─────────────────────────────────────
    //
    // 这一组是本轮两刀的正面钉子。它逮两类变异：
    //   (a) 把任何一条退回 .noRefresh —— 那正是修复前的代码（第一刀退 .configReadFailure/.configWriteFailure，
    //       第二刀退 .lockFailed）。面板会在一份它刚刚亲口承认读不动的 config 上继续顶着四行活控件。
    //   (b) 把任何一条升到 .full —— 那会白扫一遍包库（config 坏了跟包库有没有变没有半点关系），并且拿一份
    //       selectedPack 为空的 config 去 retarget，污染 drop zone、抹掉画廊的选中卡高亮。
    //
    // ⚠️ errno 用的是**真实可达**的值：EACCES(13) / EPERM(1) / EROFS(30)。**不许**再用 35 —— Darwin 上
    // 35 = EAGAIN = EWOULDBLOCK，而 FileLock 恰恰把 EWOULDBLOCK 映射成 `.busy`，`.lockFailed` 永远不可能
    // 带这个 errno（红队实测点名：上一版这里的 fixture 验的是一个**不可能出现的值**）。
    suite("panelRefreshRoute：证明不了「没变」 → 重读 config（.configOnly），但不扫包库") {
        let cannotProveUnchanged: [(name: String, error: SetEventEnabledError?, why: String)] = [
            (
                "lockFailed(EACCES 13)", .lockFailed(errno: 13),
                "锁文件建不出来 —— 目录写不动。configState 必须落到 .unwritable（本轮第二刀：第一版把它留在"
                    + "了跳过那一侧，同一个偷换概念原样复发）"
            ),
            (
                "lockFailed(EROFS 30)", .lockFailed(errno: 30),
                "只读卷 —— 连已存在的锁文件都 open 不动。同上"
            ),
            (
                "lockFailed(EPERM 1)", .lockFailed(errno: 1),
                "一袋未知 errno 里的又一个。围栏不该认识 errno —— 认不出就去读盘，读盘便宜"
            ),
            (
                "configReadFailure", .configReadFailure(reason: "master_volume is a string"),
                "config.json 被外部改坏了 → configState 必须落到 .malformed（本轮第一刀）"
            ),
            (
                "configWriteFailure", .configWriteFailure(reason: "directory not writable"),
                "config.json 的目录写不动了 → configState 必须落到 .unwritable（本轮第一刀）"
            ),
            (
                "nil（失败却没记下错误）", nil,
                "EventMuteController 的契约不该允许这一格出现。缺省必须落在安全侧：不知道 = 去读盘"
            ),
        ]
        for failure in cannotProveUnchanged {
            let route = panelRefreshRoute(muteSucceeded: false, error: failure.error)
            expect(
                route == .configOnly,
                "`.\(failure.name)`：\(failure.why)。判成 .noRefresh = 面板顶着四行活控件、在一份它刚刚"
                    + "亲口承认动不了的 config 上继续撒谎；判成 .full = 白扫一遍包库 + 拿空包 id 去 retarget。"
                    + "得到：\(route)")
        }
    }

    // ── 围栏外侧之二：只有这一格值得重扫整个包库 ────────────────────────────────────────────────
    suite("panelRefreshRoute：.configMissing → 全量（.full）—— 自救的入口是画廊，它必须新鲜") {
        expect(
            panelRefreshRoute(muteSucceeded: false, error: .configMissing) == .full,
            "config.json 在面板**已经打开之后**被外部删掉 → configState 重路由到 .needsPack。那张「先选包」"
                + "空态卡是自救入口，而入口是**画廊** —— 用户下一步就要从里面挑一张卡，所以包库必须重扫"
                + "（删 config 的那个外部动作完全可能同时动过包目录）。判成 .configOnly = 用户对着一份可能"
                + "已经陈了的画廊做唯一的自救动作。得到：\(panelRefreshRoute(muteSucceeded: false, error: .configMissing))")
    }

    // ⚠️ 上面几张表是**手抄**的（`SetEventEnabledError` 有关联值，不是 `CaseIterable`）。守住「将来加了
    // 第六个 case 却忘了归类」的**不是**这些表 —— 是 `panelRefreshRoute` 里那个**穷尽 switch**：加一个 case
    // 而不在那里归类，**编译不过**（变异 M9 实测）。这道围栏由编译器守，不由断言守。
    //
    // 所以这里**不再**写一条「唯一能路由到 X 的只许是 Y」的负向兜底 —— 那种兜底恰恰是前两版把极性写反的
    // 地方：它把白名单钉死成了「我认得的那几个」。

    // ── 切包那一半：同一个问题、同一种极性 ─────────────────────────────────────────────────────
    suite("packSwitchRefreshRoute：可证明什么也没揭示的（.lockBusy / .invalidPackID）→ .noRefresh") {
        let provesNothingChanged: [(name: String, error: UseError)] = [
            ("lockBusy", .lockBusy),
            ("invalidPackID", .invalidPackID("../etc")),
        ]
        for failure in provesNothingChanged {
            let route = packSwitchRefreshRoute(after: failure.error)
            expect(
                route == .noRefresh,
                "`.\(failure.name)`：锁没拿到 / id 在碰盘之前就被校验拒了 —— 什么也没揭示，读盘是纯浪费。"
                    + "得到：\(route)")
        }
    }

    suite("packSwitchRefreshRoute：证明不了「没变」 → 重读 config（.configOnly）") {
        let cannotProveUnchanged: [(name: String, error: UseError)] = [
            ("lockFailed(EACCES 13)", .lockFailed(errno: 13)),
            ("lockFailed(EROFS 30)", .lockFailed(errno: 30)),
            ("configReadFailure", .configReadFailure(reason: "master_volume is a string")),
            ("configWriteFailure", .configWriteFailure(reason: "directory not writable")),
        ]
        for failure in cannotProveUnchanged {
            let route = packSwitchRefreshRoute(after: failure.error)
            expect(
                route == .configOnly,
                "`.\(failure.name)`：config.json 或它的目录**可能**已经变了（`.lockFailed` 更是一袋未知"
                    + " errno）—— configState 必须重算，诚实失败卡才出得来。但包库没理由变，不扫。得到：\(route)")
        }
    }

    suite("packSwitchRefreshRoute：.packNotFound → 全量（.full）—— 画廊里挂着一张幽灵卡") {
        let route = packSwitchRefreshRoute(after: .packNotFound("ghost"))
        expect(
            route == .full,
            "用户点的那张卡对应的包目录**不在磁盘上** —— 这是 packCards 已经陈了的**直接证据**（画廊里挂着"
                + "一张幽灵卡）。这是切包侧唯一值得重扫整个包库的一格：不重扫，那张点不动的卡就一直挂在那儿。"
                + "得到：\(route)")
    }

    // ── 整条链：磁盘 → setEventEnabled → EventMuteController → 路由 ────────────────────────────
    //
    // 上面那些是对纯函数打的（喂的是**手写**的 error）。这一条把它接回**真实磁盘状态**：一个真的不存在的
    // config.json，走真的 `setEventEnabled`，拿真的 `lastError`，再问路由。它守的是**接缝**：万一哪天
    // `setEventEnabled` 对缺失的 config 不再返回 `.configMissing`（比如又改回「静默新建」），上面那些纯函数
    // 断言会全绿 —— 它们喂的不是磁盘真的吐出来的那个 error。
    suite("整条链：config.json 不存在 → EventMuteController 记下 .configMissing → 路由必须是 .full") {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let controller = EventMuteController(
                configFile: configFile, lockFile: root.appendingPathComponent("config.lock"))

            let succeeded = controller.setEnabled(.stop, enabled: false)
            expect(!succeeded, "缺失的 config.json 必须让这次调用失败，而不是静默新建一份（D23 定稿①）")
            expect(
                panelRefreshRoute(muteSucceeded: succeeded, error: controller.lastError) == .full,
                "磁盘上真的没有 config.json 时，整条链必须把面板送去 .full —— 这是「面板打开着，文件被外部"
                    + "删了」在真实磁盘上的样子。得到："
                    + "\(panelRefreshRoute(muteSucceeded: succeeded, error: controller.lastError))")
        }
    }
}
