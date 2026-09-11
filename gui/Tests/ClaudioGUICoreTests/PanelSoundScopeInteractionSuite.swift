import ClaudioGUIComponents
import ClaudioGUICore
import Foundation
import SwiftUI

extension PanelSoundScopeRowInteractionState {
    fileprivate init(
        selected: Bool,
        scopeHovered: Bool,
        actionHovered: Bool,
        scopeFocused: Bool,
        actionFocused: Bool,
        pressed: Bool
    ) {
        self.init(
            isSelected: selected,
            isScopeHovered: scopeHovered,
            isActionHovered: actionHovered,
            isScopeFocused: scopeFocused,
            isActionFocused: actionFocused,
            isPressed: pressed)
    }
}

private struct PanelSoundScopeControlsCompileFixture: View {
    @FocusState private var focusedTarget: PanelSoundScopePickerFocusTarget?
    @StateObject private var actionCoordinator = PanelSoundScopeActionCoordinator()

    var body: some View {
        PanelSoundScopeRowInteractionContainer(hasAction: true) { _, actionHovered in
            VStack {
                PanelSoundScopeButton(
                    action: {},
                    focusedTarget: $focusedTarget,
                    target: .scope(.global),
                    policy: .trigger,
                    onHover: { _ in }
                ) {
                    EmptyView()
                }
                PanelSoundScopeSuccessfulActionButton(
                    action: {},
                    actionCoordinator: actionCoordinator,
                    reduceMotion: false,
                    focusedTarget: $focusedTarget,
                    target: .scope(.global),
                    policy: .scopeAction,
                    onHover: { _ in }
                ) {
                    EmptyView()
                }
                PanelSoundScopeSuccessfulActionButton(
                    action: {},
                    actionCoordinator: actionCoordinator,
                    reduceMotion: false,
                    focusedTarget: $focusedTarget,
                    target: .integrationAction(.global),
                    policy: .integrationAction,
                    onHover: { actionHovered.wrappedValue = $0 }
                ) {
                    EmptyView()
                }
            }
        }
    }
}

@MainActor
func runPanelSoundScopeInteractionSuites() {
    suite("声音作用域控件：生产组件接缝可编译且三类策略唯一") {
        _ = PanelSoundScopeControlsCompileFixture()
        expect(
            !PanelSoundScopeButtonPolicy.trigger.isExplicitlyFocusable
                && !PanelSoundScopeButtonPolicy.trigger.reportsPressed,
            "触发卡不得额外进入 Tab 序或上报行级 pressed")
        expect(
            !PanelSoundScopeButtonPolicy.scopeAction.isExplicitlyFocusable
                && PanelSoundScopeButtonPolicy.scopeAction.reportsPressed,
            "作用域选择必须上报 pressed，但不改变现有焦点序")
        expect(
            PanelSoundScopeButtonPolicy.integrationAction.isExplicitlyFocusable
                && PanelSoundScopeButtonPolicy.integrationAction.reportsPressed,
            "集成动作必须显式可聚焦并上报 pressed")
    }

    suite("声音作用域行：选择焦点与集成动作焦点共享整行状态") {
        let scopeFocused = PanelSoundScopeRowInteractionState(
            selected: false,
            scopeHovered: false,
            actionHovered: false,
            scopeFocused: true,
            actionFocused: false,
            pressed: false)
        let actionFocused = PanelSoundScopeRowInteractionState(
            selected: false,
            scopeHovered: false,
            actionHovered: false,
            scopeFocused: false,
            actionFocused: true,
            pressed: false)

        expect(scopeFocused.isFocused, "作用域选择按钮焦点必须提升整行焦点状态")
        expect(scopeFocused.isInteractive, "作用域选择按钮焦点必须提升整行交互状态")
        expect(actionFocused.isFocused, "集成动作焦点必须提升整行焦点状态")
        expect(actionFocused.isInteractive, "集成动作焦点必须提升整行交互状态")
    }

    suite("声音作用域行：普通 hover 不移动 chevron，集成动作 hover/focus 才移动") {
        let rowHovered = PanelSoundScopeRowInteractionState(
            selected: false,
            scopeHovered: true,
            actionHovered: false,
            scopeFocused: false,
            actionFocused: false,
            pressed: false)
        let actionHovered = PanelSoundScopeRowInteractionState(
            selected: false,
            scopeHovered: false,
            actionHovered: true,
            scopeFocused: false,
            actionFocused: false,
            pressed: false)
        let actionFocused = PanelSoundScopeRowInteractionState(
            selected: false,
            scopeHovered: false,
            actionHovered: false,
            scopeFocused: false,
            actionFocused: true,
            pressed: false)

        expect(actionHovered.isHovered, "集成动作 hover 必须由原始事实派生整行 hover")
        expect(actionHovered.isInteractive, "集成动作 hover 必须提升整行交互状态")
        expect(actionHovered.isActionEngaged, "集成动作 hover 必须派生动作 engaged 状态")
        expect(
            rowHovered.chevronOffset(reduceMotion: false) == 0,
            "普通行 hover 不得错误驱动集成动作 chevron")
        expect(
            actionHovered.chevronOffset(reduceMotion: false)
                == PanelSoundScopeRowInteractionState.activeChevronOffset,
            "直接 hover 集成动作时 chevron 必须移动 2pt")
        expect(
            actionFocused.chevronOffset(reduceMotion: false)
                == PanelSoundScopeRowInteractionState.activeChevronOffset,
            "聚焦集成动作时 chevron 必须移动 2pt")
    }

    suite("声音作用域行：selected 与 hover/focus 可并存且不覆盖选中身份") {
        let selectedInteractive = PanelSoundScopeRowInteractionState(
            selected: true,
            scopeHovered: true,
            actionHovered: false,
            scopeFocused: false,
            actionFocused: false,
            pressed: false)
        expect(selectedInteractive.isSelected, "选中态必须持续存在")
        expect(selectedInteractive.isInteractive, "选中行 hover 必须提升交互态")
        expect(
            selectedInteractive.iconOffset(reduceMotion: false)
                == PanelSoundScopeRowInteractionState.activeIconOffset,
            "选中行 hover 仍须驱动状态图标回应")
        expect(
            selectedInteractive.rowScale(reduceMotion: false) == 1,
            "未按压的选中行不得误触发按压缩放")
    }

    suite("声音作用域行：任一子按钮 pressed 都驱动统一的 0.985 回弹") {
        let pressed = PanelSoundScopeRowInteractionState(
            selected: false,
            scopeHovered: true,
            actionHovered: false,
            scopeFocused: true,
            actionFocused: false,
            pressed: true)
        expect(
            pressed.rowScale(reduceMotion: false)
                == PanelSoundScopeRowInteractionState.rowPressedScale,
            "作用域按钮 pressed 必须把整行缩放到 0.985")

        let actionPressed = PanelSoundScopeRowInteractionState(
            selected: true,
            scopeHovered: false,
            actionHovered: true,
            scopeFocused: false,
            actionFocused: true,
            pressed: true)
        expect(
            actionPressed.rowScale(reduceMotion: false)
                == PanelSoundScopeRowInteractionState.rowPressedScale,
            "集成动作 pressed 必须与主体使用相同整行缩放")
    }

    suite("声音作用域行：Reduce Motion 保留静态焦点而取消几何变化") {
        let focused = PanelSoundScopeRowInteractionState(
            selected: true,
            scopeHovered: false,
            actionHovered: true,
            scopeFocused: false,
            actionFocused: true,
            pressed: true)
        expect(focused.isFocused, "Reduce Motion 下仍必须保留动作焦点语义")
        expect(focused.isInteractive, "Reduce Motion 下仍必须保留整行静态交互表面")
        expect(focused.rowScale(reduceMotion: true) == 1, "Reduce Motion 下不得缩放整行")
        expect(focused.iconOffset(reduceMotion: true) == 0, "Reduce Motion 下不得移动状态图标")
        expect(focused.iconScale(reduceMotion: true) == 1, "Reduce Motion 下不得放大状态图标")
        expect(focused.chevronOffset(reduceMotion: true) == 0, "Reduce Motion 下不得移动 chevron")
    }

    suite("声音作用域行：动效时长与 spring 参数保持合同") {
        expect(
            PanelSoundScopeRowInteractionState.pressDuration == 0.10
                && PanelSoundScopeRowInteractionState.actionBorderDuration == 0.10,
            "按压与动作胶囊边框必须使用 100ms")
        expect(
            PanelSoundScopeRowInteractionState.surfaceDuration == 0.18
                && PanelSoundScopeRowInteractionState.textDuration == 0.18
                && PanelSoundScopeRowInteractionState.chevronDuration == 0.18,
            "行表面、文字与 chevron 必须使用 180ms")
        expect(
            PanelSoundScopeRowInteractionState.iconSpringStiffness == 380
                && PanelSoundScopeRowInteractionState.iconSpringDamping == 30,
            "状态图标 spring 必须使用 stiffness 380 / damping 30")
        expect(
            PanelSoundScopeRowInteractionState.activeIconOffset == -1
                && PanelSoundScopeRowInteractionState.activeIconScale == 1.06
                && PanelSoundScopeRowInteractionState.activeChevronOffset == 2,
            "图标与 chevron 的几何变化必须保持规格值")
    }

    suite("声音作用域行：成功动作等回弹完成，Reduce Motion 下不引入延迟") {
        expect(
            PanelSoundScopeRowInteractionState.actionCompletionDelay(reduceMotion: false)
                == PanelSoundScopeRowInteractionState.pressDuration,
            "正常动效下必须等完整 100ms 回弹后再执行成功动作")
        expect(
            PanelSoundScopeRowInteractionState.actionCompletionDelay(reduceMotion: true) == 0,
            "Reduce Motion 下成功动作不得等待不可见的回弹")
    }

    suite("声音作用域菜单：不同控件连续激活只接受第一次") {
        var scheduledDelay: Double?
        var scheduledCompletion: (@MainActor () -> Void)?
        let coordinator = PanelSoundScopeActionCoordinator { delay, completion in
            scheduledDelay = delay
            scheduledCompletion = completion
        }
        var activationCount = 0

        let acceptedScope = coordinator.submit(reduceMotion: false) {
            activationCount += 1
        }
        let acceptedIntegration = coordinator.submit(reduceMotion: false) {
            activationCount += 1
        }

        expect(acceptedScope && !acceptedIntegration, "菜单级 gate 必须拒绝跨行、跨控件重复激活")
        expect(coordinator.isPending, "首个成功动作必须在回弹窗口内持有菜单级 gate")
        expect(activationCount == 0, "正常动效下回调不得在回弹前同步执行")
        expect(
            scheduledDelay == PanelSoundScopeRowInteractionState.pressDuration,
            "成功动作必须等待完整 pressed 回弹时长")

        scheduledCompletion?()
        expect(activationCount == 1, "调度完成时必须只执行第一个动作")
        expect(!coordinator.isPending, "动作完成后 gate 必须为下次展开重置")
    }

    suite("声音作用域菜单：Reduce Motion 成功动作同步完成") {
        var didSchedule = false
        var activationCount = 0
        let coordinator = PanelSoundScopeActionCoordinator { _, _ in
            didSchedule = true
        }

        let accepted = coordinator.submit(reduceMotion: true) {
            activationCount += 1
        }

        expect(accepted && activationCount == 1, "Reduce Motion 下必须立即执行成功动作")
        expect(!didSchedule, "Reduce Motion 下不得创建不可见的延迟任务")
        expect(!coordinator.isPending, "Reduce Motion 同步完成后不得遗留 pending gate")
    }

    suite("声音作用域行：动画键只投影各自实际渲染事实") {
        let resting = PanelSoundScopeRowInteractionState(
            selected: false,
            scopeHovered: false,
            actionHovered: false,
            scopeFocused: false,
            actionFocused: false,
            pressed: false)
        let pressedOnly = PanelSoundScopeRowInteractionState(
            selected: false,
            scopeHovered: false,
            actionHovered: false,
            scopeFocused: false,
            actionFocused: false,
            pressed: true)
        let scopeHovered = PanelSoundScopeRowInteractionState(
            selected: false,
            scopeHovered: true,
            actionHovered: false,
            scopeFocused: false,
            actionFocused: false,
            pressed: false)
        let actionHovered = PanelSoundScopeRowInteractionState(
            selected: false,
            scopeHovered: false,
            actionHovered: true,
            scopeFocused: false,
            actionFocused: false,
            pressed: false)
        let actionFocused = PanelSoundScopeRowInteractionState(
            selected: true,
            scopeHovered: false,
            actionHovered: false,
            scopeFocused: false,
            actionFocused: true,
            pressed: false)

        expect(
            resting.rowSurfaceAppearance == pressedOnly.rowSurfaceAppearance,
            "pressed 不得额外触发行表面动画")
        expect(
            resting.statusIconAppearance == pressedOnly.statusIconAppearance,
            "pressed 不得额外触发状态图标动画")
        expect(
            resting.actionAppearance == scopeHovered.actionAppearance,
            "普通行 hover 不得额外触发动作胶囊动画")
        expect(
            actionHovered.actionAppearance == .hovered,
            "动作 hover 必须投影为胶囊 hovered 外观")
        expect(
            actionFocused.actionAppearance == .focused,
            "动作 focus 必须优先投影为胶囊 focused 外观")
        expect(
            resting.rowSurfaceAppearance != scopeHovered.rowSurfaceAppearance
                && resting.statusIconAppearance != scopeHovered.statusIconAppearance,
            "行 hover 仍必须驱动行表面与状态图标的各自动画键")
    }

    suite("声音作用域行：集成动作文字静止时仍使用主文字强调") {
        let resting = PanelSoundScopeRowInteractionState(
            selected: false,
            scopeHovered: false,
            actionHovered: false,
            scopeFocused: false,
            actionFocused: false,
            pressed: false)
        let hovered = PanelSoundScopeRowInteractionState(
            selected: false,
            scopeHovered: true,
            actionHovered: false,
            scopeFocused: false,
            actionFocused: false,
            pressed: false)

        expect(
            PanelSoundScopeStatusTextRole.integrationAction.usesPrimaryText(for: resting),
            "集成动作的静止文字不得降级为 secondaryText")
        expect(
            !PanelSoundScopeStatusTextRole.badge.usesPrimaryText(for: resting),
            "只读徽标静止时应保留次要文字层级")
        expect(
            PanelSoundScopeStatusTextRole.badge.usesPrimaryText(for: hovered),
            "只读徽标在行交互时应提升为主文字")
    }
}
