import Combine
import Foundation

/// The explicit "the popover just became visible — recompute and re-apply first focus now"
/// signal (a11y-architect FIX 4, T15): `ClaudioGUI`'s `MenuBarController` owns one instance
/// and calls ``requestFocus()`` from `NSPopoverDelegate.popoverDidShow`; `PanelView` observes
/// ``showCount`` and, on every change, resets its `@FocusState` to
/// ``panelFocusOrder(_:)``'s current first item.
///
/// This exists because SwiftUI's `.onAppear` is NOT a reliable enough signal on its own:
/// `NSHostingController`'s SwiftUI-side state (`@StateObject`s, `@FocusState`) persists for
/// the controller's whole lifetime, and `NSPopover` does not necessarily tear down and
/// recreate its content view's hierarchy between every show/close cycle the way a fresh
/// window would — so "the popover opened again" needs its own explicit signal, not an
/// inferred one. A plain incrementing counter (not a `Bool`/`Void` signal) so `PanelView`'s
/// `onChange(of:)` fires on every request even if two requests happen to look identical.
///
/// Foundation-only (no AppKit/SwiftUI import) so this stays testable in the dependency-free
/// harness — only `ObservableObject` conformance (from `Combine`, already a dependency of
/// every other `ObservableObject` in this module) is needed.
@MainActor
public final class PanelFocusCoordinator: ObservableObject {
    @Published public private(set) var showCount = 0

    /// 「popover 刚刚不在屏幕上了」—— ``showCount`` 的另一半（T17d）。
    ///
    /// ## 消费者有**两个**，删任何一个消费者都不构成删这个信号的理由
    ///
    /// 1. **``OnboardingViewModel``**（T17d，本信号的出生理由）：它必须知道一条失败诞生的那一刻，
    ///    面板究竟开着还是关着。没有这个信号，它只能靠「下一次打开 = 上一条失败已经被看过」去
    ///    **假定** —— 而那个假定在最要命的那条路径上是假的：用户点完「接管」就切走（`.transient`
    ///    popover 当场关闭），写盘的 `Task` 不随视图销毁而取消、继续跑、失败，此时屏幕上没有任何
    ///    像素属于它；下一次打开却会把它当成「看过了」清掉。**静默失败的第四种形状**
    ///    （T17 对抗评审 · Codex）。
    /// 2. **`MasterVolumeRow`**（PLAN-MASTER-VOLUME.md 阶段 D，D22/D37，8771946）：它的**冲刷**信号。
    ///    拖动本身一个字节都不写（`VolumeDragSession` 规则 1），所以「popover 关掉了」就是那次拖动
    ///    唯一的落盘时机。D22 选它而不是新造一个 `closeCount`，正是因为这个计数器已经在
    ///    `MenuBarController.popoverDidClose` 的**第一行**被 bump（见 ``notePanelHidden()``），
    ///    那条排序保证是白送的；新造一个只会得到第二个需要同样小心放置的调用点。
    ///
    /// 这一段以前写的是「它存在的**唯一**理由是 OnboardingViewModel」。阶段 D 落地后那是假话，
    /// 而且是**危险**的假话：谁重构掉 onboarding 那套、顺手删掉这个信号，主音量的冲刷会跟着静默
    /// 消失，用户拖完滑块点面板外面，值就没了（`/codex review 8771946`）。`ViewWiringSuite` 现在
    /// 盯着 `MasterVolumeRow` 那条 `.onChange(of: focusCoordinator.hideCount)` 的**闭包体**。
    ///
    /// 与 ``showCount`` 同样是单调递增的计数器，同样的理由：`onChange(of:)` 得在每一次隐藏上都
    /// 触发，哪怕两次隐藏看起来一模一样。
    @Published public private(set) var hideCount = 0

    public init() {}

    /// Records one more "the popover just showed" event.
    public func requestFocus() {
        showCount += 1
    }

    /// Records one more "the popover just went away" event。
    ///
    /// ⚠️ 调用点在 `MenuBarController.popoverDidClose` 的**第一行**，必须在那句
    /// `guard NSApp.isActive` **之前** —— 那句 guard 在「用户切到别的 app 导致 popover 关闭」
    /// 这条路径上会提前 return，而那恰恰是本信号最需要覆盖的一条路径。
    public func notePanelHidden() {
        hideCount += 1
    }
}
