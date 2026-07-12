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

    /// Whoever was frontmost when the popover opened. `showPopover()` takes the foreground
    /// away from them (it has to — see there); `popoverDidClose` gives it back. Nil whenever
    /// no handback is owed.
    private var previousApp: NSRunningApplication?

    /// `bundledHelperBinary` is the helper CLI inside this app bundle
    /// (`Claudio.app/Contents/Resources/bin/claudio`) — what the 接管 CTA copies to
    /// `~/.claudio/bin/claudio`. It is a PARAMETER, resolved by ``bundledHelperBinary(in:)``
    /// (`ClaudioGUICore`), not a `Bundle.main` lookup performed here.
    ///
    /// That is deliberate and it is the whole point of T17: the lookup is the ONE line that can
    /// hand `performFirstRunSetup` the wrong binary — swap it for `Bundle.main.executableURL` and
    /// it resolves to `Contents/MacOS/Claudio`, the SwiftUI app itself, which then gets copied
    /// over the helper so every Claude Code event execs a GUI app, and the bundled-pack directory
    /// (derived by dropping two components off that path) resolves to a `Contents/packs` that does
    /// not exist. Left in this AppKit-only file, that line is unreachable by the test harness, and
    /// the mutation above keeps the ENTIRE suite green. Sunk into `ClaudioGUICore`, it is pinned
    /// by a real fixture bundle (`OnboardingActionsSuite`).
    init(audioEnvironment: AudioImportEnvironment, bundledHelperBinary: URL?) {
        // Built BEFORE the panel so the panel's width callback can capture it (the callback can't
        // capture `self` — we're still pre-`super.init()` here).
        let popover = NSPopover()
        // `standardPanelWidth` (`ClaudioGUICore`), never a second hardcoded `312`: DESIGN.md's
        // 312pt panel width already exists as a constant, and `PanelLayoutAdaptation/panelWidth`
        // — the value the SwiftUI side actually sizes itself to — is derived from it.
        // Height is intrinsic-content-driven at runtime.
        popover.contentSize = NSSize(width: standardPanelWidth, height: 400)

        let panel = PanelView(
            audioEnvironment: audioEnvironment,
            bundledHelperBinary: bundledHelperBinary,
            focusCoordinator: focusCoordinator,
            // T15 D5「极大 → 加宽 popover」, now actually in effect (TODOS.md:257): `PanelView`
            // widens ITSELF to `widenedPanelWidth` (360pt) at the `.maximum` Dynamic Type tier,
            // but this AppKit popover around it kept its hardcoded 312pt `contentSize` — so the
            // widened panel was being rendered inside a container that never grew, which is
            // exactly the 「不裁切、不溢出」 the degradation rule exists to prevent. `PanelView`
            // reports its real width here (on appear and on every tier change) and the popover
            // follows. Captures `popover` (a class), never `self`.
            // `[weak popover]`：强捕获会成环——`popover → contentViewController → rootView(PanelView)
            // → 这个闭包 → popover`，于是 popover 与它整棵 SwiftUI 视图树永不释放（本轮 /ship 评审：
            // Claude 对抗子代理）。今天菜单栏 app 的 popover 与进程同生共死，所以泄漏不可见；一旦将来
            // 有人重建 popover（换皮肤、换尺寸策略、多状态栏图标），它就会变成一个真实的、每次重建都
            // 涨一份的泄漏。捕获 popover 而不是 self 本来就是对的，只是漏了 weak。
            onPanelWidthChange: { [weak popover] width in
                popover?.contentSize.width = CGFloat(width)
            }
        )
        hostingController = NSHostingController(rootView: panel)

        popover.contentViewController = hostingController
        self.popover = popover
        // `.transient`: AppKit closes the popover on a click outside it, on an app switch,
        // and — ONLY once the popover's window is key — on Esc. That last clause is the whole
        // catch: `.transient` alone does NOT buy "Esc 关闭", because a status-item popover in
        // an `.accessory` app is never key until someone activates the app. See `showPopover()`
        // for the measurement and the fix; this line used to claim Esc came for free here.
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

        // Remember who we're about to take the foreground from, so `popoverDidClose` can give
        // it back (AppKit will not: see there). Guarded on a real closed→open transition —
        // a redundant `show` while already shown would otherwise overwrite this with Claudio.
        if !popover.isShown {
            let front = NSWorkspace.shared.frontmostApplication
            if front?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                previousApp = front
            }
        }

        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)

        // Everything T15 promises — first focus lands on the first operable control, Tab /
        // Shift+Tab traversal, Space/Enter activation, Esc closes, VoiceOver announces the
        // panel — rides on the popover's window being KEY. It never is, on its own: the app
        // is `.accessory` (no Dock icon) and clicking a status item does NOT activate it, so
        // `NSApp` stays inactive and the popover's window never becomes key.
        //
        // Measured on a real Mac (2026-07-11), popover visibly open on screen:
        //     windows=0   frontmost=false   topLevelUIElements=2   (just the two menu bars)
        // Zero AX windows means VoiceOver cannot reach a single control in the panel, and an
        // inactive app means Esc/Tab/Space/Enter are delivered to whatever app IS frontmost.
        // `popoverDidShow`'s `makeFirstResponder` is a no-op against a non-key window, and
        // `.transient` only ever gave us click-outside dismissal — never Esc.
        //
        // Activating is what makes the window key, which puts it in the AX tree and in the
        // key-event path. `.transient` still closes the popover when the user clicks away or
        // switches apps (an app that deactivates dismisses its transient popover), so this
        // does not trade Esc for a popover that will not go away.
        //
        // There is no way to have the key window without the activation, and it was checked
        // one API at a time against the AppKit headers (ENGINEERING.md T15 决议): `NSPopover`
        // exposes no non-activating switch; `.nonactivatingPanel` is documented as "only
        // applicable for NSPanel"; `becomesKeyOnlyIfNeeded` points the other way; and a
        // `makeKey()` without activation is the no-op that produced the windows=0 above (an
        // inactive app has no key window at all). Escaping it means dropping NSPopover for a
        // hand-built `NSPanel` — see TODOS.md, and don't start down that road casually.
        //
        // So opening the panel costs one app switch, every time, and one part of that bill
        // cannot be refunded by `popoverDidClose`'s handback: if the user is mid-composition
        // in an IME (Chinese/Japanese/Korean, characters not yet committed), deactivating
        // their app forces the marked text to commit or drops it. That is the price of a
        // keyboard/VoiceOver-operable panel on this architecture.
        NSApp.activate(ignoringOtherApps: true)
        popover.contentViewController?.view.window?.makeKey()
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

    // The other half of `showPopover()`'s `NSApp.activate` — the two are a pair, and shipping
    // the activate without this is a regression, not a partial fix.
    //
    // AppKit does not deactivate an app just because its last window went away. So without a
    // handback: Esc closes the panel and leaves an `.accessory` app frontmost with ZERO
    // windows. The menu bar on screen still belongs to the app the user is looking at, so
    // nothing tells them the foreground moved — they keep typing and every keystroke is
    // swallowed, and ⌘Q quits Claudio instead of their editor. That failure lands squarely on
    // the keyboard/VoiceOver users the Esc path exists for.
    //
    // This replaces `makeFirstResponder(statusItem.button)`, which had been standing in for
    // 「关闭后焦点回菜单栏 status item」 while doing nothing at all: `statusItem.button` lives in
    // the system-owned `NSStatusBarWindow`, whose `canBecomeKeyWindow` is false, and AppKit
    // delivers key events only to the KEY window's first responder — setting one on a window
    // that can never be key changes nothing. (It isn't in the app's AX window tree either; it
    // hangs off `AXExtrasMenuBar`, so the VoiceOver cursor doesn't follow a first responder
    // there.) The contract cannot be met literally, and what it is actually for — "the panel
    // closed, someone give the keyboard back" — is met by returning it to the only party that
    // can hold it: the app the user came from. ENGINEERING.md's wording was corrected to say so.
    func popoverDidClose(_ notification: Notification) {
        // T17d —— **必须是这个方法的第一行。** 下面那句 `guard NSApp.isActive` 会在「用户切到别的
        // app 导致 popover 关闭」这条路径上直接 return，而那正是本信号存在的理由：用户点完「接管」
        // 就切走，写盘的 `Task` 继续跑并失败，`OnboardingViewModel` 必须知道那一刻面板已经不在屏幕上
        // 了，否则它会把这条从没被渲染过的失败当成「用户看过了」清掉（见
        // ``PanelFocusCoordinator/notePanelHidden()``）。把这一行挪到 guard 之后 = 复活那个 bug，
        // 而且只在最常见的那条路径上复活。
        focusCoordinator.notePanelHidden()

        let previous = previousApp
        previousApp = nil

        // Not active ⇒ the popover closed BECAUSE the user went elsewhere (clicked another
        // app, ⌘-Tabbed away). That app owns the foreground now, and it is not necessarily
        // `previous` — pulling it back would be us overriding the user's own choice.
        guard NSApp.isActive,
            let previous,
            !previous.isTerminated,
            previous.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else { return }

        if #available(macOS 14.0, *) {
            // Cooperative activation (macOS 14+): consent to `previous` taking the foreground
            // so its `activate()` isn't denied. Yielding resigns ours — no `deactivate()`
            // needed, and adding one races the handoff.
            NSApp.yieldActivation(to: previous)
            previous.activate()
        } else {
            previous.activate(options: [])
            NSApp.deactivate()
        }
    }
}
