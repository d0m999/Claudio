import Foundation

/// 声音作用域菜单行的纯交互投影。
///
/// 这个接缝只组合视图瞬时状态，不拥有 selected scope、宿主状态或任何配置事实。作用域选择
/// 按钮和行内集成动作共享同一行状态，因此焦点、hover 和按压反馈不会在两个子按钮之间漂移。
public struct PanelSoundScopeRowInteractionState: Hashable, Sendable {
    public let isSelected: Bool
    public let isHovered: Bool
    public let isScopeFocused: Bool
    public let isActionFocused: Bool
    public let isActionEngaged: Bool
    public let isPressed: Bool

    public init(
        isSelected: Bool,
        isHovered: Bool,
        isScopeFocused: Bool,
        isActionFocused: Bool,
        isActionEngaged: Bool,
        isPressed: Bool
    ) {
        self.isSelected = isSelected
        self.isHovered = isHovered
        self.isScopeFocused = isScopeFocused
        self.isActionFocused = isActionFocused
        self.isActionEngaged = isActionEngaged
        self.isPressed = isPressed
    }

    /// Label names without the `is` prefix make fixture construction read like the product spec.
    public init(
        selected: Bool,
        hovered: Bool,
        scopeFocused: Bool,
        actionFocused: Bool,
        actionEngaged: Bool,
        pressed: Bool
    ) {
        self.init(
            isSelected: selected,
            isHovered: hovered,
            isScopeFocused: scopeFocused,
            isActionFocused: actionFocused,
            isActionEngaged: actionEngaged,
            isPressed: pressed)
    }

    public var isFocused: Bool {
        isScopeFocused || isActionFocused
    }

    /// A row is visually engaged when either child is focused or the pointer is over the row/action.
    /// `isActionEngaged` is kept separate so the chevron can respond only to the action itself.
    public var isInteractive: Bool {
        isHovered || isFocused || isActionEngaged
    }

    public var isChevronEngaged: Bool {
        isActionEngaged || isActionFocused
    }

    public var selected: Bool { isSelected }
    public var hovered: Bool { isHovered }
    public var scopeFocused: Bool { isScopeFocused }
    public var actionFocused: Bool { isActionFocused }
    public var actionEngaged: Bool { isActionEngaged }
    public var pressed: Bool { isPressed }

    // MARK: Motion contract

    public static let pressDuration: Double = 0.10
    public static let surfaceDuration: Double = 0.18
    public static let textDuration: Double = surfaceDuration
    public static let actionBorderDuration: Double = 0.10
    public static let chevronDuration: Double = 0.18
    public static let iconSpringStiffness: Double = 380
    public static let iconSpringDamping: Double = 30

    public static let rowPressedScale: Double = 0.985
    public static let activeIconOffset: Double = -1
    public static let activeIconScale: Double = 1.06
    public static let activeChevronOffset: Double = 2

    public func rowScale(reduceMotion: Bool) -> Double {
        isPressed && !reduceMotion ? Self.rowPressedScale : 1
    }

    public func iconOffset(reduceMotion: Bool) -> Double {
        isInteractive && !reduceMotion ? Self.activeIconOffset : 0
    }

    public func iconScale(reduceMotion: Bool) -> Double {
        isInteractive && !reduceMotion ? Self.activeIconScale : 1
    }

    public func labelOffset(reduceMotion: Bool) -> Double {
        iconOffset(reduceMotion: reduceMotion)
    }

    public func chevronOffset(reduceMotion: Bool) -> Double {
        isChevronEngaged && !reduceMotion ? Self.activeChevronOffset : 0
    }
}
