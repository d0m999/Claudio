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
public enum PanelRefreshRoute: Equatable, Sendable {
    /// 写成功：`config.json` 里只有一个 bool 变了。它**不可能**因此改变任何包的 manifest、任何声音文件的
    /// 存在性、或磁盘上有哪些包 —— 全量 `refresh()`（重扫两个包根 + 读每个包的 manifest）在这条路上是
    /// 纯浪费：一次点静音钮就在主线程上扫一遍整个包库。只重算每行的 `enabled`。
    case enabledFlagsOnly

    /// ``SetEventEnabledError/configMissing``：面板**已经打开之后**，`config.json` 被外部删掉了。
    /// `configState` / `eventRows` 此刻全是陈的（仍是 `.operational`，仍在一个不存在的文件上画着四行
    /// 活控件）。必须**全量** `refresh()`，让 `configState` 重路由到 `.needsPack` —— 那张「先选包」的
    /// 空态卡本身就是解释，所以这条错误**不**经 `errorNotice` 出（D43）。
    case full

    /// 其他失败（`.lockBusy` / 读写失败 / 锁失败）：`config.json` 被原封不动地留在那里
    /// （`setEventEnabled` 从不半写），读模型没有变陈 —— 重扫一遍磁盘什么也改不了。
    /// 解释由 `errorNotice` 出。
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
public func panelRefreshRoute(muteSucceeded: Bool, error: SetEventEnabledError?) -> PanelRefreshRoute {
    if muteSucceeded { return .enabledFlagsOnly }
    return error == .configMissing ? .full : .noRefresh
}
