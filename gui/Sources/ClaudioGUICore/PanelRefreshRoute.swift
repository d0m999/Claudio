import ClaudioCore
import Foundation

/// 一次 config 写盘（静音 / 切包）之后，面板必须做**哪一种**刷新。
///
/// ## 为什么这个判断值得从 `PanelView` 里拆出来（`/codex review 573336d` [P2]，两个变异均为实测）
///
/// 它原本是 `PanelView.toggleMute` 里的三行 `if / else if`，而唯一守着它的是 `ViewWiringSuite` 的一条
/// **文本绊线**：
///
/// ```swift
/// expect(panel.contains("muteController.lastError == .configMissing") && panel.contains("refresh()"), …)
/// ```
///
/// `refresh()` 在 `PanelView.swift` 里出现 **37 次**。于是那个合取子**恒真**，整条断言实际只检查了前半个
/// 字符串 —— 而它失败消息里**亲口点名**的那个变异（把 `.configMissing` 分支的 `refresh()` 换成
/// `refreshEnabledFlags()`）会让它**照样绿**：那 36 处 `refresh()` 一个都没少。守卫读的是「整个文件」，
/// 它守的是「一个分支」。**文本绊线守不住「哪个结果走哪条路」，因为那是行为，不是存在性。**
///
/// 所以判断搬到这里：纯函数，不碰磁盘、不碰 `@State`，由 `PanelRefreshRouteSuite` 用**行为断言**逐条钉死。
///
/// ## ⚠️ 台账 12/12 全绿，而它钉死的那份规格本身是错的（`/codex review` 两条 [P1]）
///
/// 上一版的失败一侧是 `error == .configMissing ? .full : .noRefresh`，给它背书的文档写着：
///
/// > 其他失败（`.lockBusy` / 读写失败 / 锁失败）：`config.json` 被原封不动地留在那里
/// > （`setEventEnabled` 从不半写），**读模型没有变陈**
///
/// 这句话把「**我们**没写」偷换成了「**文件**没变」。`setEventEnabled` 从不半写 —— 真的。但
/// `.configReadFailure` 的字面意思就是：**别人**在面板打开之后把那份文件改坏了。文件**变了**，只是不是
/// 被我们变的。于是面板在一份它刚刚亲口承认读不动的 config 上继续顶着四行活控件。
///
/// **变异台账验的是「实现符合规格」，它永远告诉不了你「规格本身是错的」。** 那一轮 12/12 一条也没逮到它，
/// 因为错的不在实现，在**给实现背书的那段散文**里。
///
/// ## ⚠️⚠️ 而修它的第一刀，把同一个偷换概念原样犯了一遍（红队打自己，实测）
///
/// 第一版修复（1c65215）把围栏内侧写成 `.lockBusy` / `.lockFailed`，理由是「锁都没拿到，`config.json`
/// 一个字节没读、没写」。这句话对 `config.json` 的**字节**成立 —— 但**读模型不只关于那些字节**：
/// ``PanelConfigState`` 是 ``probeConfigRewritable(configFile:)`` 的**两根轴**判定，第二根轴是**目录可写性**。
///
/// 实测（合法 config + 尚未建出 `config.lock` + 目录 `chmod 0500`，静音一次）：
///
/// ```text
/// muteError   = .lockFailed(errno: 13)   「无法获取文件锁，请稍后重试」← 而重试永远不会成功
/// configState = .operational(...)         ← 四行活控件原样留在屏幕上
/// 磁盘真相     = .unwritable("…目录不可写…请 chmod u+w …")  ← 此刻就算得出来的诚实答案
/// ```
///
/// 同一个 bug，换了个 case 复发。而 `.lockFailed` 根本**不是**「目录坏了」的证据 —— 它是一袋**未知**的
/// errno（`EACCES` 目录写不动、`EROFS` 只读卷、`EOPNOTSUPP` 网络/FUSE home 上 flock 不受支持、`EMFILE`
/// fd 耗尽……）。它什么也证明不了。
///
/// **而围栏要的从来不是「证明变了才刷新」，是「证明没变才敢不刷新」。** 证明不了 ⇒ 不许跳过。
///
/// ## 三条路由的极性
///
/// - ``noRefresh`` 是一张**可证明什么都没揭示**的白名单 —— 只有 `.lockBusy` 配得上（另一个写者持锁，
///   这是**高频常态**，不是异常）。
/// - ``configOnly`` 是「不知道 = 去读盘」的**安全侧**，而且**便宜**：只重读 `config.json` + 探一次目录，
///   **不扫包库、不 retarget**。实测它单独就足以把 `configState` 翻到 `.unwritable`（`afterFullReload`
///   零次）—— 所以「什么也证明不了」的失败付得起这个代价；付不起的是全库扫描。
/// - ``full`` 只留给**包库本身可能已经陈了**的那两格。
///
/// 两个 switch 都是**穷尽**的：给 ``SetEventEnabledError`` / ``UseError`` 加一个 case 而不在这里归类，
/// **编译不过**（实测：变异 M9/M10 各自在本文件报 `switch must be exhaustive`）。前提是 library evolution
/// **没有**开（SwiftPM 默认，本仓库也没开）——「同包编译」的说法是错的，`ClaudioCore` 由 `helper/` 这个
/// **另一个** package vend 出来。若哪天开了 library evolution，跨模块 enum 变成 resilient，穷尽 switch 会
/// 降级成**警告**而不是错误，这道围栏就会悄悄失效。
///
/// ## 这一刀**没有**做到什么（别让这段文档再犯它自己在骂的错）
///
/// - **没有**文件监听、**没有**轮询。config 被改坏之后、用户下一次动手（点静音 / 点包卡 / 重开 popover）
///   之前的那段窗口里，面板照旧显示 `.operational`。关掉的是「点击**已经**撞上了失败，面板却假装没事」。
/// - `.lockBusy` **仍然**跳过刷新。如果持锁的那个写者（并发的 `claudio use`）正在把 config 改成别的样子，
///   面板要到下一次全量 reload 才知道。这是**刻意**的取舍：锁竞争是高频常态，而它确实没**揭示**任何东西。
/// - `.malformed` / `.unwritable` 这两张诚实失败卡**本身**还有已知毛病（顶部视图切换会吃掉键盘焦点；
///   `errorNotice` 会把卡片里那句 reason 再印一遍）—— 那是这两个状态出厂就带的，任何一条路由到它们的路
///   （包括 popover 重开）都会撞上，不是这一刀引入的。见 TODOS 台账。
public enum PanelRefreshRoute: Equatable, Sendable {
    /// **只重读 config 读模型**：`loadPanelConfig` 重算 `configState` + `config`，再按新 config 重算每行的
    /// `enabled` 位。**不**重扫包根、**不**读任何 manifest、**不**调 `afterFullReload`（onboarding 重探 +
    /// import view-model retarget）。代价 = 一次文件读 + 一次目录 stat。
    ///
    /// 两种情况共用它，因为**要做的事一模一样**：重读 `config.json`，其余读模型不可能受影响。
    ///
    ///   - **写成功**：`config.json` 里只有一个 bool 变了。它**不可能**因此改变任何包的 manifest、任何声音
    ///     文件的存在性、或磁盘上有哪些包 —— 全量刷新在这条路上是纯浪费：点一次静音钮就在主线程上扫一遍
    ///     整个包库。
    ///   - **失败，但什么也证明不了**（`.lockFailed` / `.configReadFailure` / `.configWriteFailure` / `nil`）：
    ///     `config.json` 或它所在的目录**可能**已经不是面板打开时的样子了 —— 必须重读才知道，`configState`
    ///     据此落到 `.malformed` / `.unwritable`，渲染诚实失败卡。但**包库**没有任何理由变，所以不扫它；
    ///     也不该拿一份 `selectedPack` 为空的 config 去 retarget 那几个 import view-model（那会把 drop zone
    ///     污染成「什么都不敢收」，而画廊会丢掉选中卡的高亮）。
    ///
    /// 刻意**不**再叫 `.enabledFlagsOnly`：那个名字在**低报**它做的事 —— 它从第一天起就在重算 `configState`
    /// （见 ``PanelConfigController/reloadConfigOnly()``），只是没人注意到。
    case configOnly

    /// **全量**重读：config 读模型 + 重扫两个包根 + 读每个包的 manifest + `afterFullReload`
    /// （onboarding 重探 + 把 import view-model retarget 到新包）。
    ///
    /// 只发给**包库本身可能已经陈了**的那两格：
    ///
    ///   - ``SetEventEnabledError/configMissing``：`config.json` 被外部**删掉**了 → `configState` 重路由到
    ///     `.needsPack`。那张「先选包」的空态卡是自救路径的入口，而入口是**画廊** —— 用户下一步就要从里面
    ///     挑一张卡，所以它必须新鲜（删掉 config 的那个外部动作完全可能同时动过包目录）。这条错误**不**经
    ///     `errorNotice` 出，因为那张卡本身就是解释（D43）。
    ///   - ``UseError/packNotFound``：用户点的那张卡对应的包目录**不在磁盘上** —— 这是 `packCards` 已经陈了
    ///     的**直接证据**（画廊里挂着一张幽灵卡）。重扫包根会把它抹掉。
    case full

    /// 这次失败**可证明什么也没揭示**：`.lockBusy` —— 另一个写者持着锁，我们连 `config.json` 都没打开过，
    /// 读模型不比点击之前更陈。（切包侧的 `.invalidPackID` 同理：id 在碰盘之前就被校验拒了，而面板也递不出
    /// 这种 id。）
    ///
    /// 而重扫的代价是真的：一次全量刷新要重扫两个包根 + 读每个包的 manifest，把一次锁竞争（并发的
    /// `claudio use`、另一个面板）变成一次主线程上的全库扫描。解释由 `errorNotice` 出。
    ///
    /// **这张白名单只收「可证明」的。** 一袋未知 errno（`.lockFailed`）**不**在此列 —— 见类型文档里
    /// 「修它的第一刀把同一个偷换概念原样犯了一遍」那一节。
    ///
    /// 刻意**不**叫 `.none`：`PanelRefreshRoute?` 里的 `.none` 是 `Optional.none`，同名会让
    /// `case .none` 在可选上下文里静默地指向另一个东西。
    case noRefresh
}

/// 一次 ``EventMuteController/setEnabled(_:enabled:)`` 的结果 → 面板该做哪一种刷新。
///
/// `muteSucceeded` 优先于 `error`：``EventMuteController`` 在成功时会把 `lastError` 清成 `nil`，但这个
/// 函数不**依赖**它那么做 —— 一次成功的写盘意味着 `config.json` 就在那里、且只有一个 bool 变了，上一次
/// 失败留下的陈旧 `error` 不该把它路由到别处去。
///
/// 失败一侧的极性见 ``PanelRefreshRoute``：`.noRefresh` 只发给**可证明什么也没揭示**的 `.lockBusy`，其余
/// 一律去读盘。这个 switch 是穷尽的 —— 加一个 ``SetEventEnabledError`` case 而不在这里归类，编译不过。
public func panelRefreshRoute(muteSucceeded: Bool, error: SetEventEnabledError?) -> PanelRefreshRoute {
    if muteSucceeded { return .configOnly }
    switch error {
    case .lockBusy?:
        // 另一个写者持锁 —— 我们连 config.json 都没打开过。可证明：什么也没揭示。高频常态，不许全库扫描。
        return .noRefresh
    case .configMissing?:
        // config.json 被删了 → .needsPack，而自救的入口是画廊 → 它必须新鲜。
        return .full
    case .lockFailed?, .configReadFailure?, .configWriteFailure?, nil:
        // config.json / 它的目录**可能**变了，但包库没理由变。.lockFailed 是一袋未知 errno、nil 是本不该
        // 出现的空失败 —— 两者都「证明不了没变」。不知道 = 去读盘，但只读便宜的那一半。
        return .configOnly
    }
}

/// 一次 ``MasterVolumeController/setVolume(_:)``（PLAN-MASTER-VOLUME.md 阶段 D，D27/D43）的结果 →
/// 面板该做哪一种刷新。逐 case 镜像 ``panelRefreshRoute(muteSucceeded:error:)``：`SetMasterVolumeError`
/// 与 `SetEventEnabledError` 本就是同一份文件、同一把锁、同一套 missing-config 策略的两张面孔
/// （见 `MasterVolume.swift` 的类型文档「Mirrors SetEventEnabledError case-for-case」），极性没有理由不同。
///
/// - 写成功（D27）：只翻了 `config.json` 里的一个 `Double` —— `.configOnly`，不扫包库。
/// - `.configMissing`（D43）：`config.json` 被外部删掉 → `.full`，重路由到 `.needsPack`（自救入口是画廊，
///   必须新鲜）。
/// - `.lockBusy`：可证明什么也没揭示（另一个写者持锁，我们连文件都没打开过）—— `.noRefresh`。
/// - 其余（`.lockFailed` / `.configReadFailure` / `.configWriteFailure` / `nil`）：证明不了「没变」——
///   `.configOnly`（去读盘，但只读便宜的那一半）。
///
/// 穷尽 switch：给 `SetMasterVolumeError` 加一个 case 而不在这里归类，编译不过。
public func masterVolumeRefreshRoute(succeeded: Bool, error: SetMasterVolumeError?) -> PanelRefreshRoute {
    if succeeded { return .configOnly }
    switch error {
    case .lockBusy?:
        return .noRefresh
    case .configMissing?:
        return .full
    case .lockFailed?, .configReadFailure?, .configWriteFailure?, nil:
        return .configOnly
    }
}

/// 一次**失败**的 ``selectPack(_:configFile:userPacksDirectory:bundledPacksDirectory:lockFile:)`` 之后，
/// 面板该做哪一种刷新。
///
/// 与 ``panelRefreshRoute(muteSucceeded:error:)`` 是**同一个问题的另一半**，同一种极性 —— 静音和切包是面板
/// 仅有的两条 config 写路径，它们撞上同一份被外部改坏的 `config.json` 时必须给出同一个答案。上一版切包的
/// 失败分支**只记 error、从不刷新**（`/codex review` 第二条 [P1]）。
///
/// 问的仍然是那一个问题：**这次失败之后，我还能不能证明读模型没变陈？**
///
///   - `.lockBusy` / `.invalidPackID`：能证明（锁没拿到 / id 在碰盘之前就被拒）—— 什么也没揭示。
///   - `.lockFailed` / `.configReadFailure` / `.configWriteFailure`：**不能** —— 去重读 config 那一半。
///   - `.packNotFound`：不但不能，而且直接**证明了 `packCards` 已经陈**（画廊里挂着一张幽灵卡）—— 只有
///     这一格值得重扫整个包库。
///
/// 这个 switch 同样是穷尽的：加一个 ``UseError`` case 而不在这里归类，编译不过。
public func packSwitchRefreshRoute(after error: UseError) -> PanelRefreshRoute {
    switch error {
    case .lockBusy, .invalidPackID:
        return .noRefresh
    case .lockFailed, .configReadFailure, .configWriteFailure:
        return .configOnly
    case .packNotFound:
        return .full
    }
}
