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
    /// The exact control that should receive focus for the latest show request. Ordinary menu-bar
    /// opens leave this `nil` and use the panel's computed first target; a retained integrations
    /// window supplies the trigger that opened it so closing the window restores that control.
    @Published public private(set) var requestedTarget: PanelFocusTarget?

    /// 「popover 刚刚不在屏幕上了」信号。它是 `MasterVolumeRow`
    /// （PLAN-MASTER-VOLUME.md 阶段 D，D22/D37，8771946）的**冲刷**信号：
    ///    拖动本身一个字节都不写（`VolumeDragSession` 规则 1），所以「popover 关掉了」就是那次拖动
    ///    唯一的落盘时机。D22 选它而不是新造一个 `closeCount`，正是因为这个计数器已经在
    ///    `MenuBarController.popoverDidClose` 的**第一行**被 bump（见 ``notePanelHidden()``），
    ///    那条排序保证是白送的；新造一个只会得到第二个需要同样小心放置的调用点。
    ///
    /// 双宿主改造已移除 Panel 的 Claude-only onboarding 消费者，但不能顺手删这个信号：
    /// 否则用户拖完滑块点面板外面，值就没了（`/codex review 8771946`）。`ViewWiringSuite` 现在
    /// 盯着 `MasterVolumeRow` 那条 `.onChange(of: focusCoordinator.hideCount)` 的**闭包体**。
    ///
    /// 与 ``showCount`` 同样是单调递增的计数器，同样的理由：`onChange(of:)` 得在每一次隐藏上都
    /// 触发，哪怕两次隐藏看起来一模一样。
    @Published public private(set) var hideCount = 0

    public init() {}

    /// Records one more "the popover just showed" event.
    public func requestFocus(target: PanelFocusTarget? = nil) {
        requestedTarget = target
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
