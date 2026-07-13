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
/// 所以路由本身搬到这里：一个纯函数，不碰磁盘、不碰 `@State`，由 `PanelRefreshRouteSuite` 用**行为断言**
/// 逐条钉死。对调、删分支、把 `.configMissing` 归进 `.noRefresh` —— 三种变异各自当场变红，且与
/// `refresh()` 这个名字在哪个文件里出现过多少次**完全无关**。`PanelView` 那一侧只剩「三条路各接哪个
/// 方法」，那才是文本绊线**够得着**的东西（见 `ViewWiringSuite` 里那条按函数体切片的断言）。
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
