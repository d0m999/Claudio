import Foundation

public struct PanelSoundScopeRowSurfaceAppearance: Hashable, Sendable {
    public let isSelected: Bool
    public let isInteractive: Bool
}

public struct PanelSoundScopeStatusIconAppearance: Hashable, Sendable {
    public let isInteractive: Bool
    public let isFocused: Bool
}

public enum PanelSoundScopeActionAppearance: Hashable, Sendable {
    case focused
    case hovered
    case selected
    case resting
}

public enum PanelSoundScopeStatusTextRole: Hashable, Sendable {
    case badge
    case integrationAction

    public func usesPrimaryText(for interactionState: PanelSoundScopeRowInteractionState) -> Bool {
        self == .integrationAction || interactionState.isInteractive
    }
}

/// 声音作用域菜单行的纯交互投影。
///
/// 这个接缝只组合视图瞬时状态，不拥有 selected scope、宿主状态或任何配置事实。作用域选择
/// 按钮和行内集成动作共享同一行状态，因此焦点、hover 和按压反馈不会在两个子按钮之间漂移。
public struct PanelSoundScopeRowInteractionState: Hashable, Sendable {
    public let isSelected: Bool
    public let isScopeHovered: Bool
    public let isActionHovered: Bool
    public let isScopeFocused: Bool
    public let isActionFocused: Bool
    public let isPressed: Bool

    public init(
        isSelected: Bool,
        isScopeHovered: Bool,
        isActionHovered: Bool,
        isScopeFocused: Bool,
        isActionFocused: Bool,
        isPressed: Bool
    ) {
        self.isSelected = isSelected
        self.isScopeHovered = isScopeHovered
        self.isActionHovered = isActionHovered
        self.isScopeFocused = isScopeFocused
        self.isActionFocused = isActionFocused
        self.isPressed = isPressed
    }

    public var isHovered: Bool {
        isScopeHovered || isActionHovered
    }

    public var isActionEngaged: Bool {
        isActionHovered
    }

    public var isFocused: Bool {
        isScopeFocused || isActionFocused
    }

    /// A row is visually engaged when either child is focused or the pointer is over the row/action.
    public var isInteractive: Bool {
        isHovered || isFocused
    }

    public var isChevronEngaged: Bool {
        isActionHovered || isActionFocused
    }

    public var rowSurfaceAppearance: PanelSoundScopeRowSurfaceAppearance {
        PanelSoundScopeRowSurfaceAppearance(
            isSelected: isSelected,
            isInteractive: isInteractive)
    }

    public var statusIconAppearance: PanelSoundScopeStatusIconAppearance {
        PanelSoundScopeStatusIconAppearance(
            isInteractive: isInteractive,
            isFocused: isFocused)
    }

    public var actionAppearance: PanelSoundScopeActionAppearance {
        if isActionFocused {
            .focused
        } else if isActionHovered {
            .hovered
        } else if isSelected {
            .selected
        } else {
            .resting
        }
    }

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

    public static func actionCompletionDelay(reduceMotion: Bool) -> Double {
        reduceMotion ? 0 : pressDuration
    }

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
