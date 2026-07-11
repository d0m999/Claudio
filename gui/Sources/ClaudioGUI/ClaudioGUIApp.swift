import AppKit
import ClaudioCore
import ClaudioGUICore
import SwiftUI

/// The real menu-bar app entry point (ENGINEERING.md T15 D2) — replaces T7's temporary
/// `WindowGroup { OnboardingView(...) }` scaffolding, whose own doc comment already flagged
/// it as disposable ("expected to be replaced wholesale once the menu bar skeleton lands").
/// A `Scene`-less `App` (`Settings {}` is the smallest legal placeholder `Scene` SwiftUI's
/// `App` protocol requires — it never actually shows a window; the app's real UI is the
/// `NSStatusItem`/`NSPopover` ``MenuBarController`` owns, driven entirely by
/// ``ClaudioGUIAppDelegate``) — a menu-bar-only app has no document window at all.
///
/// ⚠️ COMPILE-ONLY here (see ``MenuBarController``'s doc comment): the actual menu-bar
/// icon, popover open/close, and focus behavior are manual-verify on a real Mac.
@main
struct ClaudioGUIApp: App {
    @NSApplicationDelegateAdaptor(ClaudioGUIAppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

/// Owns ``MenuBarController`` for the app's lifetime — an `NSApplicationDelegate`, not a
/// SwiftUI `Scene`, because the status item + popover are pure AppKit constructs with no
/// SwiftUI `Scene` counterpart (mirrors how every "menu bar only" SwiftUI app on macOS is
/// structured: `Scene` bodies model WINDOWS, and this app deliberately has none).
final class ClaudioGUIAppDelegate: NSObject, NSApplicationDelegate {
    private var menuBarController: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // `.accessory`: no Dock icon, no menu bar application menu — the correct activation
        // policy for a menu-bar-only utility (DESIGN.md「空间 / 同类」: menubar 工具类 app).
        NSApp.setActivationPolicy(.accessory)

        // Bundled packs default to `nil` here — matches ENGINEERING.md T17's own decision
        // for `PlayEnvironment.bundledPacksDirectory` ("v1 只走「复制进用户包」这一条路径，
        // 两套路径并存会制造第二个查找顺序，故意不做"): by the time the operational panel
        // can render at all (onboarding already reports `.installed`), `claudio
        // setup`/`performFirstRunSetup` has already copied every bundled pack into the user
        // pack root, so the panel's pack gallery only ever needs to look there.
        let audioEnvironment = AudioImportEnvironment(
            durationProbe: AVFoundationAudioDurationProbe())
        menuBarController = MenuBarController(audioEnvironment: audioEnvironment)
    }
}
