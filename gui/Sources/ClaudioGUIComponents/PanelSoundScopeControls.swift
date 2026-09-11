import ClaudioGUICore
import Combine
import Foundation
import SwiftUI

/// Sound Scope 三类按钮共享的焦点与 pressed 策略。
public enum PanelSoundScopeButtonPolicy: Hashable, Sendable {
    case trigger
    case scopeAction
    case integrationAction

    public var isExplicitlyFocusable: Bool {
        self == .integrationAction
    }

    public var reportsPressed: Bool {
        self != .trigger
    }
}

/// 单个可见行在本地生命周期内产生的瞬时交互事实。
public struct PanelSoundScopeRowTransientState: Hashable, Sendable {
    public let scopeHovered: Bool
    public let actionHovered: Bool
    public let isPressed: Bool
}

/// 行级瞬时状态 owner：菜单卸载时这些状态随行一起销毁。
public struct PanelSoundScopeRowInteractionContainer<Content: View>: View {
    private let hasAction: Bool
    private let content: (PanelSoundScopeRowTransientState, Binding<Bool>) -> Content

    @State private var scopeHovered = false
    @State private var actionHovered = false
    @State private var isPressed = false

    public init(
        hasAction: Bool,
        @ViewBuilder content:
            @escaping (PanelSoundScopeRowTransientState, Binding<Bool>) -> Content
    ) {
        self.hasAction = hasAction
        self.content = content
    }

    public var body: some View {
        content(
            PanelSoundScopeRowTransientState(
                scopeHovered: scopeHovered,
                actionHovered: hasAction && actionHovered,
                isPressed: isPressed),
            $actionHovered
        )
        // 整行 hover 包含选择按钮、按钮间距与胶囊。
        .onHover { scopeHovered = $0 }
        .onPreferenceChange(PanelSoundScopeRowPressedPreferenceKey.self) { isPressed = $0 }
        .onChange(of: hasAction) { _ in
            actionHovered = false
        }
    }
}

/// 触发卡和两类行内动作共用的 native Button 策略。
public struct PanelSoundScopeButton<FocusValue: Hashable, Label: View>: View {
    private let action: @MainActor () -> Void
    private let focusedTarget: FocusState<FocusValue?>.Binding
    private let target: FocusValue
    private let policy: PanelSoundScopeButtonPolicy
    private let onHover: (Bool) -> Void
    private let label: Label

    public init(
        action: @escaping @MainActor () -> Void,
        focusedTarget: FocusState<FocusValue?>.Binding,
        target: FocusValue,
        policy: PanelSoundScopeButtonPolicy,
        onHover: @escaping (Bool) -> Void,
        @ViewBuilder label: () -> Label
    ) {
        self.action = action
        self.focusedTarget = focusedTarget
        self.target = target
        self.policy = policy
        self.onHover = onHover
        self.label = label()
    }

    public var body: some View {
        focusableButton
            .focused(focusedTarget, equals: target)
            .panelSoundScopeFocusEffectDisabled()
            .onHover(perform: onHover)
    }

    @ViewBuilder
    private var focusableButton: some View {
        if policy.isExplicitlyFocusable {
            button.focusable()
        } else {
            button
        }
    }

    private var button: some View {
        Button(action: action) {
            label
        }
        .buttonStyle(PanelSoundScopeChildButtonStyle(reportsPressed: policy.reportsPressed))
    }
}

/// 菜单级的单一成功动作 owner：同时持有重复激活 gate 和回弹调度策略。
@MainActor
public final class PanelSoundScopeActionCoordinator: ObservableObject {
    public typealias Scheduler =
        @MainActor (
            _ delay: Double,
            _ completion: @escaping @MainActor () -> Void
        ) -> Void

    @Published public private(set) var isPending = false
    private let schedule: Scheduler

    public init() {
        self.schedule = Self.liveSchedule
    }

    public init(schedule: @escaping Scheduler) {
        self.schedule = schedule
    }

    @discardableResult
    public func submit(
        reduceMotion: Bool,
        action: @escaping @MainActor () -> Void
    ) -> Bool {
        guard !isPending else { return false }
        isPending = true
        let completion = { @MainActor [weak self] in
            action()
            self?.isPending = false
        }
        let delay = PanelSoundScopeRowInteractionState.actionCompletionDelay(
            reduceMotion: reduceMotion)
        guard delay > 0 else {
            completion()
            return true
        }
        schedule(delay, completion)
        return true
    }

    public func reset() {
        isPending = false
    }

    private static func liveSchedule(
        _ delay: Double,
        _ completion: @escaping @MainActor () -> Void
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            completion()
        }
    }
}

/// 作用域选择与 Integrations 动作的唯一成功提交路径。
///
/// 它先获取菜单级 gate，再等待可见的 pressed 回弹完成；Reduce Motion
/// 下延迟为零。两类动作无法各自引入第二条调度路径。
public struct PanelSoundScopeSuccessfulActionButton<FocusValue: Hashable, Label: View>: View {
    private let action: @MainActor () -> Void
    @ObservedObject private var actionCoordinator: PanelSoundScopeActionCoordinator
    private let reduceMotion: Bool
    private let focusedTarget: FocusState<FocusValue?>.Binding
    private let target: FocusValue
    private let policy: PanelSoundScopeButtonPolicy
    private let onHover: (Bool) -> Void
    private let label: Label

    public init(
        action: @escaping @MainActor () -> Void,
        actionCoordinator: PanelSoundScopeActionCoordinator,
        reduceMotion: Bool,
        focusedTarget: FocusState<FocusValue?>.Binding,
        target: FocusValue,
        policy: PanelSoundScopeButtonPolicy,
        onHover: @escaping (Bool) -> Void,
        @ViewBuilder label: () -> Label
    ) {
        self.action = action
        self.actionCoordinator = actionCoordinator
        self.reduceMotion = reduceMotion
        self.focusedTarget = focusedTarget
        self.target = target
        self.policy = policy
        self.onHover = onHover
        self.label = label()
    }

    public var body: some View {
        PanelSoundScopeButton(
            action: completeAfterPressRelease,
            focusedTarget: focusedTarget,
            target: target,
            policy: policy,
            onHover: onHover
        ) {
            label
        }
    }

    private func completeAfterPressRelease() {
        actionCoordinator.submit(reduceMotion: reduceMotion, action: action)
    }
}

private struct PanelSoundScopeRowPressedPreferenceKey: PreferenceKey {
    static let defaultValue = false

    static func reduce(
        value: inout Bool,
        nextValue: () -> Bool
    ) {
        value = value || nextValue()
    }
}

private struct PanelSoundScopeChildButtonStyle: ButtonStyle {
    let reportsPressed: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .preference(
                key: PanelSoundScopeRowPressedPreferenceKey.self,
                value: reportsPressed && configuration.isPressed)
    }
}

extension View {
    /// macOS 14 可关闭系统 focus effect，因为选择器会画出自有行级状态。
    /// macOS 12–13 保留原生焦点环；同一自有状态在所有版本均可见。
    @ViewBuilder
    fileprivate func panelSoundScopeFocusEffectDisabled() -> some View {
        if #available(macOS 14.0, *) {
            focusEffectDisabled()
        } else {
            self
        }
    }
}
