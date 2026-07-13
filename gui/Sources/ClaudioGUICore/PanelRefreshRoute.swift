import ClaudioCore
import Foundation

/// 一次静音写盘之后，面板必须做**哪一种**刷新。
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
/// `refresh()` 在 `PanelView.swift` 里出现 **37 次**（剥掉注释后仍有八处真实调用点：`playPreview`、
/// `switchPack`、`.onAppear`、导入回调……）。于是那个合取子**恒真**，整条断言实际只检查了前半个字符串
/// —— 而它失败消息里**亲口点名**的那个变异（把 `.configMissing` 分支的 `refresh()` 换成
/// `refreshEnabledFlags()`）会让它**照样绿**：那 36 处 `refresh()` 一个都没少。守卫读的是「整个文件」，
/// 它守的是「一个分支」。
///
/// 把断言收进 `toggleMute` 的**函数体切片**能杀掉那个变异 —— 但**杀不掉两个分支对调**
/// （成功 → `refresh()`、`.configMissing` → `refreshEnabledFlags()`）：切片里 `.configMissing` 和
/// `refresh()` 两个字符串都还在，绊线照样绿，而面板已经在一个被删掉的 config 上顶着四行活控件。
/// **文本绊线守不住「哪个结果走哪条路」，因为那是行为，不是存在性。**
///
/// 所以**这个判断**搬到这里：一个纯函数，不碰磁盘、不碰 `@State`，由 `PanelRefreshRouteSuite` 用
/// **行为断言**逐条钉死。对调、删分支、把 `.configMissing` 归进 `.noRefresh` —— 三种变异各自当场变红，
/// 且与 `refresh()` 这个名字在哪个文件里出现过多少次**完全无关**。
///
/// ## ⚠️ 它钉死的只是「判断」，不是「判断之后做的事」（红队 9cccc9c，worktree 实测 5 条存活）
///
/// 说清楚边界，别让这段文档也犯它自己在骂的那个错。搬到这里、被行为断言钉死的，是
/// **「哪种失败该走哪种刷新」这个判断**。判断**之后**的一切仍然住在 `PanelView`（`@main`
/// executableTarget，测试 import 不进来），红队逐一实测它们能被改坏而两套测试全绿：
///
///   - **执行**：`.full` 正确路由到 `refresh()`，但 `refresh()` 的函数体里删掉 `configState` 重载 ——
///     面板对磁盘上的删除永久失明。没有任何断言执行过 `refresh()`、或检查它的函数体。
///   - **可达性**：在 `toggleMute` 的 switch 前插一句 `if … == .enabledFlagsOnly { return }`，让那条 case
///     成死代码 —— 切片断言要的字符串一个不少（switch 一字未动），**存在 ≠ 可达**。
///   - **接线**：`EventRowView(onToggleMute: {})` 把按钮和 `toggleMute` 之间的线剪断 —— `toggleMute`
///     函数体完好，只是再没人调它。
///   - **翻转**：`setEnabled(event, enabled: !currentlyEnabled)` 去掉那个 `!` —— toggle 变死键，而切片
///     只查 switch 的四条路由，从不碰 switch 之上那行真正的翻转逻辑。
///
/// 这四条是**同一个洞的四个切面**：只要状态（`configState`/`eventRows`）和操作它们的方法还住在
/// `PanelView` 这个测不到的 View 里，`ViewWiringSuite` 就只能靠文本绊线守「代码在不在」，守不住
/// 「代码做什么 / 可不可达 / 接线对不对」。这是文本绊线的**强度天花板**，TODOS「文本绊线只挡得住
/// 整行被删」那条早已写明；红队这一轮是把它的确切形状实测出来了。根治 = 把这些方法和状态搬进一个
/// 可实例化的 view-model（同 `OnboardingViewModel`/`AudioImportViewModel`/`EventMuteController` 的
/// 既有做法），让测试能真的调 `toggleMute`、喂真磁盘、断言 `configState` 真的变了。见 TODOS 台账。
///
/// 拆出这个纯函数**仍然是真进展**：它把「判断」从那个测不到的面里救了出来，分支对调那一整类变异
/// 从此会红（变异台账 12/12）。但它**不是**、也**不可能仅靠 text-slice** 关闭上面那四条 —— 别把
/// 「判断可测了」读成「这段逻辑守住了」。
///
/// ## ⚠️⚠️ 12/12 的台账全绿，而规格本身是错的（`/codex review` 两条 [P1]，本轮修复）
///
/// 上面那份变异台账把**实现**钉死在**规格**上：对调分支、删分支、把 `.configMissing` 归进 `.noRefresh`
/// —— 三种变异全红，12/12 名副其实。**可是规格本身错了**，而错的规格白纸黑字写在这段文档的上一版里：
///
/// > 其他失败（`.lockBusy` / 读写失败 / 锁失败）：`config.json` 被原封不动地留在那里
/// > （`setEventEnabled` 从不半写），**读模型没有变陈**
///
/// 这句话把「**我们**没写」偷换成了「**文件**没变」。`setEventEnabled` 从不半写 —— 真的。但
/// `.configReadFailure` 的字面意思就是：**别人**在面板打开之后把那份文件改坏了（`master_volume` 变成
/// 字符串、JSON 被截断、同步工具覆盖）。文件**变了**，只是不是被我们变的。于是旧规格把它路由到
/// `.noRefresh`，`configState` 永远停在 `.operational`，面板在一份它刚刚亲口承认读不动的 config 上
/// 继续顶着四行活控件 —— 要等下一次 popover 重开才自愈。
///
/// 而这恰恰是 `.configMissing → .full` 存在的**全部理由**（下面那条 case 的文档自己写着「面板已经打开
/// 之后，`config.json` 被外部删掉了」）：设计**早就承认**「打开与点击之间会有外部改动」，它只接了
/// **删除**，漏了**改坏**和**变得写不动** —— 同一根轴上差两个 case。
///
/// **变异测试验的是「代码符合测试」，它永远告诉不了你「测试编码的规格是错的」。** 这一刀之后，本项目
/// 那条自复发规律（「措辞比覆盖范围大」）的落点要再记一格：它这次没落在测试里，落在了**给测试背书的
/// 那段散文**里，然后台账绿着放它过去了。
///
/// ## 极性：这是一张**围栏**，不是一张探针清单
///
/// 旧写法 `error == .configMissing ? .full : .noRefresh` 是**探针**：认出 `.configMissing` 就刷新，
/// **认不出的一律放绿**。认不出的东西默认安全 —— 这正是白名单式绊线一贯的死法。
///
/// 现在倒过来：`.noRefresh` 是一张**可证明磁盘没被碰过**的白名单（只有锁失败配得上：锁都没拿到，
/// `config.json` 一个字节没读没写），**其余一律 `.full`** —— 包括「失败了却没记下错误」这种本不该发生的
/// 情况。不知道 = 去读盘，安全侧。将来给 ``SetEventEnabledError`` 加第六个 case，它默认落进安全侧，
/// 而且**根本落不进来**：下面那个 switch 是**穷尽**的（`ClaudioCore` 与本模块同包编译，非 resilient），
/// 加一个 case 而不在这里归类 → **编译不过**。这道围栏由编译器守，不由某条断言守。
///
/// ## 这一刀**没有**做到什么（别让这段文档再犯它自己在骂的错）
///
/// 面板仍然只在**用户动手**（点静音 / 点包卡 / 重开 popover）时才会发现磁盘上的 config 坏了。**没有**
/// 文件监听，**没有**后台轮询：config 被改坏之后、用户下一次点击之前的那段窗口里，面板照旧显示
/// `.operational`。这一刀关掉的是「点击**已经**撞上了失败，面板却假装没事」，不是「面板实时知道磁盘」。
public enum PanelRefreshRoute: Equatable, Sendable {
    /// 写成功：`config.json` 里只有一个 bool 变了。它**不可能**因此改变任何包的 manifest、任何声音文件的
    /// 存在性、或磁盘上有哪些包 —— 全量 `refresh()`（重扫两个包根 + 读每个包的 manifest）在这条路上是
    /// 纯浪费：一次点静音钮就在主线程上扫一遍整个包库。只重算每行的 `enabled`。
    case enabledFlagsOnly

    /// 这次失败**揭示了读模型已经陈了** —— 面板打开那一刻的 `config.json` 和磁盘上此刻的那份，已经不是
    /// 同一份了：
    ///
    ///   - ``SetEventEnabledError/configMissing``：被外部**删掉**了。`configState` 必须重路由到
    ///     `.needsPack` —— 那张「先选包」的空态卡本身就是解释，所以这条错误**不**经 `errorNotice` 出（D43）。
    ///   - ``SetEventEnabledError/configReadFailure``：被外部**改坏**了（`master_volume` 变成字符串、
    ///     JSON 被截断……）。`configState` 必须重路由到 `.malformed(reason:)`，渲染诚实失败卡。
    ///   - ``SetEventEnabledError/configWriteFailure``：内容还好，但它所在的目录**写不动**了。
    ///     `configState` 必须重路由到 `.unwritable(reason:)` —— 那是另一个问题、另一个修法（chmod 目录，
    ///     而不是改文件）。
    ///   - `nil`（失败了却没记下错误，`EventMuteController` 的契约不该允许）：**不知道 = 去读盘**。
    ///
    /// 不全量刷新的后果不是「少刷一次」，是**面板顶着四行活控件、在一份它刚刚亲口承认读不动的 config 上
    /// 继续撒谎**，直到用户重开 popover 才自愈。
    ///
    /// 全量 `refresh()` 在这条路上不算浪费：这几种失败都是**罕见**的（config 被外部改坏），不是
    /// `.lockBusy` 那种每次并发写都会撞上的常态。
    case full

    /// 这次失败**什么也没揭示**：锁根本没拿到，`config.json` 一个字节没读、没写 —— 读模型不比点击之前更陈，
    /// 重扫一遍磁盘扫不出任何新东西。而重扫的代价是真的：一次全量 `refresh()` 要重扫两个包根 + 读每个包的
    /// manifest，把一次锁竞争（并发的 `claudio use`、另一个面板）变成一次主线程上的全库扫描。解释由
    /// `errorNotice` 出。
    ///
    /// **只有锁失败配得上这一格**（`.lockBusy` / `.lockFailed`）。这是一张「**可证明**磁盘没被碰过」的
    /// 围栏白名单，不是一张「我认得的坏事」清单 —— 见 ``panelRefreshRoute(muteSucceeded:error:)`` 的极性
    /// 说明。
    ///
    /// 刻意**不**叫 `.none`：`PanelRefreshRoute?` 里的 `.none` 是 `Optional.none`，同名会让
    /// `case .none` 在可选上下文里静默地指向另一个东西。
    case noRefresh
}

/// 一次 ``EventMuteController/setEnabled(_:enabled:)`` 的结果 → 面板该做哪一种刷新。
///
/// 纯函数：这正是它能被行为断言钉死、而 `toggleMute` 里原来那三行不能的全部原因（见 ``PanelRefreshRoute``）。
///
/// `muteSucceeded` 优先于 `error`：``EventMuteController`` 在成功时会把 `lastError` 清成 `nil`，但这个
/// 函数不**依赖**它那么做 —— 一次成功的写盘意味着 `config.json` 就在那里、且只有一个 bool 变了，
/// 上一次失败留下的陈旧 `error` 不该把它路由到别处去。
///
/// 失败一侧的极性是**围栏**：`.noRefresh` 只发给可证明磁盘没被碰过的那两条锁失败，**其余一律 `.full`**。
/// 这个 switch 是穷尽的 —— 给 ``SetEventEnabledError`` 加一个 case 而不在这里归类，**编译不过**。
public func panelRefreshRoute(muteSucceeded: Bool, error: SetEventEnabledError?) -> PanelRefreshRoute {
    if muteSucceeded { return .enabledFlagsOnly }
    switch error {
    case .lockBusy?, .lockFailed?:
        // 锁都没拿到 → config.json 一个字节没读、没写。读模型不比刚才更陈，重扫是纯浪费。
        return .noRefresh
    case .configMissing?, .configReadFailure?, .configWriteFailure?, nil:
        // 每一条都证明「磁盘上那份 config 已经不是面板打开时的那份了」（或者我们压根不知道）→ 去读盘。
        return .full
    }
}

/// 一次**失败**的 ``selectPack(_:configFile:userPacksDirectory:bundledPacksDirectory:lockFile:)`` 之后，
/// 面板要不要全量 `reload()`。
///
/// 与 ``panelRefreshRoute(muteSucceeded:error:)`` 是**同一个问题的另一半**，也是同一种极性 —— 静音和切包
/// 是面板仅有的两条 config 写路径，它们撞上同一份被外部改坏的 `config.json` 时必须给出同一个答案。上一版
/// 只有静音那一半有路由，切包的失败分支**只记 error、从不 reload**（`/codex review` 第二条 [P1]）：
/// 「打开有效面板 → 外部把 `master_volume` 改成字符串 → 点一张包卡」，`selectPack` 如实返回
/// `.configReadFailure`，而 `configState` 纹丝不动地停在 `.operational`。
///
/// 问的仍然是那一个问题：**这次失败，揭示了面板的读模型已经陈了吗？**
///
///   - `.lockBusy` / `.lockFailed`：锁没拿到，磁盘没碰过 —— 什么也没揭示。
///   - `.invalidPackID`：id 在**碰盘之前**就被校验拒了（面板递不出这种 id，这一格实际不可达）—— 同样
///     什么也没揭示。
///   - `.packNotFound`：用户点的那张卡对应的包目录**不在磁盘上** —— 这直接证明 `packCards` 已经陈了
///     （画廊里挂着一张幽灵卡）。重扫包根会把它抹掉。
///   - `.configReadFailure` / `.configWriteFailure`：`config.json` 被改坏了 / 它的目录写不动了 ——
///     `configState` 必须落到 `.malformed` / `.unwritable`。
///
/// 这个 switch 同样是穷尽的：给 ``UseError`` 加一个 case 而不在这里归类，**编译不过**。
public func packSwitchNeedsFullReload(after error: UseError) -> Bool {
    switch error {
    case .lockBusy, .lockFailed, .invalidPackID:
        return false
    case .packNotFound, .configReadFailure, .configWriteFailure:
        return true
    }
}
