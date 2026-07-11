import ClaudioGUICore
import Foundation

// MARK: - PanelFocusCoordinator (a11y-architect FIX 4, T15): the explicit "popover just
// showed" signal PanelView's `@FocusState` reset observes.

@MainActor
func runPanelFocusCoordinatorSuites() {
    suite("PanelFocusCoordinator: starts at 0") {
        let coordinator = PanelFocusCoordinator()
        expect(coordinator.showCount == 0, "got \(coordinator.showCount)")
    }

    suite("PanelFocusCoordinator: requestFocus increments showCount") {
        let coordinator = PanelFocusCoordinator()
        coordinator.requestFocus()
        expect(coordinator.showCount == 1, "got \(coordinator.showCount)")
    }

    suite("PanelFocusCoordinator: each requestFocus call is a distinct, observable increment") {
        let coordinator = PanelFocusCoordinator()
        coordinator.requestFocus()
        coordinator.requestFocus()
        coordinator.requestFocus()
        expect(coordinator.showCount == 3, "got \(coordinator.showCount)")
    }
}
