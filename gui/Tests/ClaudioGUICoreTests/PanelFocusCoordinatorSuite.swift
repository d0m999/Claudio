import ClaudioCore
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

    suite("PanelFocusCoordinator: retained window 恢复精确触发控件，普通打开会清掉旧请求") {
        let coordinator = PanelFocusCoordinator()
        expect(coordinator.requestedTarget == nil, "初始不得预设焦点")

        coordinator.requestFocus(target: .hostSource(.codex))
        expect(
            coordinator.showCount == 1
                && coordinator.requestedTarget == .hostSource(.codex),
            "Codex 宿主行恢复请求必须与本次 show 一起发布")

        coordinator.requestFocus(target: .manageIntegrations)
        expect(
            coordinator.showCount == 2
                && coordinator.requestedTarget == .manageIntegrations,
            "管理入口必须可作为独立精确恢复目标")

        coordinator.requestFocus()
        expect(
            coordinator.showCount == 3 && coordinator.requestedTarget == nil,
            "下一次普通菜单栏打开必须清掉旧窗口的恢复目标，不能重复偿还")
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
