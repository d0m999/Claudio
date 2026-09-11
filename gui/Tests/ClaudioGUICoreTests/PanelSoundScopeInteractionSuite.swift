import ClaudioGUICore
import Foundation

@MainActor
func runPanelSoundScopeInteractionSuites() {
    suite("声音作用域行：选择焦点与集成动作焦点共享整行状态") {
        let scopeFocused = PanelSoundScopeRowInteractionState(
            selected: false,
            hovered: false,
            scopeFocused: true,
            actionFocused: false,
            actionEngaged: false,
            pressed: false)
        let actionFocused = PanelSoundScopeRowInteractionState(
            selected: false,
            hovered: false,
            scopeFocused: false,
            actionFocused: true,
            actionEngaged: false,
            pressed: false)

        expect(scopeFocused.isFocused, "作用域选择按钮焦点必须提升整行焦点状态")
        expect(scopeFocused.isInteractive, "作用域选择按钮焦点必须提升整行交互状态")
        expect(actionFocused.isFocused, "集成动作焦点必须提升整行焦点状态")
        expect(actionFocused.isInteractive, "集成动作焦点必须提升整行交互状态")
    }

    suite("声音作用域行：普通 hover 不移动 chevron，集成动作 hover/focus 才移动") {
        let rowHovered = PanelSoundScopeRowInteractionState(
            selected: false,
            hovered: true,
            scopeFocused: false,
            actionFocused: false,
            actionEngaged: false,
            pressed: false)
        let actionHovered = PanelSoundScopeRowInteractionState(
            selected: false,
            hovered: true,
            scopeFocused: false,
            actionFocused: false,
            actionEngaged: true,
            pressed: false)
        let actionFocused = PanelSoundScopeRowInteractionState(
            selected: false,
            hovered: false,
            scopeFocused: false,
            actionFocused: true,
            actionEngaged: false,
            pressed: false)

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
            hovered: true,
            scopeFocused: false,
            actionFocused: false,
            actionEngaged: false,
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
            hovered: true,
            scopeFocused: true,
            actionFocused: false,
            actionEngaged: false,
            pressed: true)
        expect(
            pressed.rowScale(reduceMotion: false)
                == PanelSoundScopeRowInteractionState.rowPressedScale,
            "作用域按钮 pressed 必须把整行缩放到 0.985")

        let actionPressed = PanelSoundScopeRowInteractionState(
            selected: true,
            hovered: true,
            scopeFocused: false,
            actionFocused: true,
            actionEngaged: true,
            pressed: true)
        expect(
            actionPressed.rowScale(reduceMotion: false)
                == PanelSoundScopeRowInteractionState.rowPressedScale,
            "集成动作 pressed 必须与主体使用相同整行缩放")
    }

    suite("声音作用域行：Reduce Motion 保留静态焦点而取消几何变化") {
        let focused = PanelSoundScopeRowInteractionState(
            selected: true,
            hovered: true,
            scopeFocused: false,
            actionFocused: true,
            actionEngaged: true,
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
}
