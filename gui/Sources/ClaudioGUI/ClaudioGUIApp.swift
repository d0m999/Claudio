import ClaudioGUICore
import SwiftUI

/// Minimal app shell for T7 — just enough to host ``OnboardingView`` for manual
/// verification. **Not** the real menu bar app: no `NSStatusItem`/`NSPopover` yet (that's
/// T8/T15, per ENGINEERING.md's task list and the orchestrator's T7 scope note). A plain
/// `WindowGroup` is deliberately temporary scaffolding, expected to be replaced wholesale
/// once the menu bar skeleton lands — nothing here should be treated as a design
/// decision about the final app's window chrome.
@main
struct ClaudioGUIApp: App {
    @StateObject private var onboardingViewModel = OnboardingViewModel()

    var body: some Scene {
        WindowGroup("Claudio") {
            OnboardingView(viewModel: onboardingViewModel)
                .frame(width: 320)
        }
    }
}
