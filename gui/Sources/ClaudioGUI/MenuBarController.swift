import AppKit
import ClaudioCore
import ClaudioGUICore
import SwiftUI

/// The real menu-bar shell (ENGINEERING.md T15 D2): an `NSStatusItem` + `NSPopover` hosting
/// ``PanelView`` via `NSHostingController` — replaces T7's temporary `WindowGroup`
/// scaffolding (its own doc comment already said so: "expected to be replaced wholesale
/// once the menu bar skeleton lands").
///
/// ⚠️ **COMPILE-ONLY here** (CommandLineTools, no Xcode/simulator): this file compiles
/// cleanly, but its actual interactive behavior — click-to-toggle, popover open/close
/// animation, `.transient` dismiss-on-click-outside/Esc, first-responder/focus handoff —
/// is entirely `NSResponder`/AppKit runtime behavior that cannot be exercised by this
/// repo's headless dependency-free test harness. Every piece below is structured to be
/// CORRECT BY INSPECTION against ENGINEERING.md「无障碍规格」's focus-owner rule; a real Mac
/// manual walkthrough is required to confirm it actually behaves that way (see this task's
/// handoff `manual-verify-needed` list).
@MainActor
final class MenuBarController: NSObject, NSPopoverDelegate {
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private let hostingController: NSHostingController<PanelView>

    /// Owned here (not by `PanelView`) so it survives across every popover show/close cycle
    /// for the app's whole lifetime, and so `popoverDidShow` has something concrete to
    /// signal (a11y-architect FIX 4) — see ``PanelFocusCoordinator``'s doc comment.
    private let focusCoordinator = PanelFocusCoordinator()

    init(audioEnvironment: AudioImportEnvironment) {
        let panel = PanelView(audioEnvironment: audioEnvironment, focusCoordinator: focusCoordinator)
        hostingController = NSHostingController(rootView: panel)

        popover = NSPopover()
        popover.contentSize = NSSize(width: 312, height: 400)  // height is intrinsic-content-driven at runtime.
        popover.contentViewController = hostingController
        // `.transient`: AppKit itself closes the popover on a click outside it OR on Esc —
        // this is the built-in behavior ENGINEERING.md's "Esc 关闭" requirement rides on,
        // not custom key-handling this controller adds itself.
        popover.behavior = .transient

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        // Template image: SF Symbol renders as a single-color glyph, auto light/dark
        // (DESIGN.md「App Icon」: "单色模板菜单栏字形（16×16pt，纯 alpha，自动亮/暗）").
        let icon = NSImage(systemSymbolName: "waveform.circle", accessibilityDescription: "Claudio")
        icon?.isTemplate = true
        statusItem.button?.image = icon
        statusItem.button?.setAccessibilityLabel("Claudio")

        super.init()

        popover.delegate = self
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)
    }

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    // MARK: - NSPopoverDelegate — focus owner (ENGINEERING.md「无障碍规格」, a11y-architect
    // FIX 4)
    //
    // "打开焦点落首个可操作项...VoiceOver 进入先播报面板标题 + 当前包" — a TWO-step handoff:
    // (1) make the hosting view itself first responder — puts keyboard focus inside the
    // popover's view hierarchy at all, the prerequisite for Tab/SwiftUI focus to do
    // anything; (2) THEN tell `focusCoordinator` the popover just showed, which `PanelView`
    // observes to set its real `@FocusState` to `panelFocusOrder(_:)`'s current first item
    // (``PanelView/applyFirstFocus()``) — routing focus to the SPECIFIC first control, not
    // just the container. Order matters: step 2 only has an observable effect once step 1
    // has already put the hosting view into the responder chain.
    func popoverDidShow(_ notification: Notification) {
        popover.contentViewController?.view.window?.makeFirstResponder(
            popover.contentViewController?.view)
        focusCoordinator.requestFocus()
    }

    // "关闭后焦点回菜单栏 status item" — returns keyboard focus to the status item's own
    // button once the popover dismisses, so Tab/VoiceOver users aren't left with focus
    // pointing at a now-invisible view.
    func popoverDidClose(_ notification: Notification) {
        statusItem.button?.window?.makeFirstResponder(statusItem.button)
    }
}
