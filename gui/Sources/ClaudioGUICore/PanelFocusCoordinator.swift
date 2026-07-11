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

    public init() {}

    /// Records one more "the popover just showed" event.
    public func requestFocus() {
        showCount += 1
    }
}
