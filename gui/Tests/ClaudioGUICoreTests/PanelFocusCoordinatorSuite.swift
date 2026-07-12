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

    // T17d —— 「面板已隐藏」这一半。它存在的唯一理由是让 `OnboardingViewModel` 能知道一条失败
    // 诞生的那一刻面板究竟开着还是关着（见 `runOnboardingFailureLifecycleSuites`）。

    suite("PanelFocusCoordinator: hideCount 从 0 开始") {
        let coordinator = PanelFocusCoordinator()
        expect(coordinator.hideCount == 0, "got \(coordinator.hideCount)")
    }

    suite("PanelFocusCoordinator: notePanelHidden 每次都是一次独立可观察的递增") {
        let coordinator = PanelFocusCoordinator()
        coordinator.notePanelHidden()
        coordinator.notePanelHidden()
        expect(coordinator.hideCount == 2, "got \(coordinator.hideCount)")
    }

    suite("PanelFocusCoordinator: 显示与隐藏是两个独立的计数器，互不干扰") {
        let coordinator = PanelFocusCoordinator()
        coordinator.requestFocus()
        coordinator.notePanelHidden()
        coordinator.requestFocus()
        expect(
            coordinator.showCount == 2 && coordinator.hideCount == 1,
            "开-关-开：showCount 该是 2、hideCount 该是 1，得到 \(coordinator.showCount)/\(coordinator.hideCount)"
        )
    }
}
