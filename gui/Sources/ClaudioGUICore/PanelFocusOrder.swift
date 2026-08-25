import ClaudioCore
import Foundation

/// 面板内稳定可聚焦控件身份。旧来源卡、事件编辑按钮、包卡和“管理声音包”不再属于
/// 生产面板的焦点空间；保留的 legacy cases 只供已拆出的可复用旧组件/State Gallery 编译。
public enum PanelFocusTarget: Sendable, Hashable {
    case onboardingPrimaryAction
    case onboardingSecondaryAction
    case revealDetail
    case disconnect

    case soundScope
    case eventPreview(Event)
    case eventMute(Event)
    case masterVolume
    case openSoundSettings
    case resetSurface
    case configReveal
    case bootstrapReportRetry(id: String)
    case bootstrapReportDiagnostics(id: String)
    case bootstrapReportReveal(id: String)
    case bootstrapReportManageSounds(id: String)
    case bootstrapReportAcknowledge(id: String)
    case quitApplication

    // 非生产面板兼容身份。`PanelView` 与 `panelFocusOrder` 均不会生成它们。
    case hostSource(HostID)
    case eventSound(Event)
    case eventAction(Event)
    case packCard(id: String)
    case manageSounds
}

/// 作用域浮层存在期间的临时焦点空间。收起后仍只向生产面板暴露一个 `.soundScope`
/// 焦点目标，避免把当前可见来源数固化进主面板焦点模型。
public enum PanelSoundScopePickerFocusTarget: Sendable, Equatable, Hashable {
    case scope(PanelSoundScopeID)
    case integrations
}

public func panelSoundScopePickerFocusOrder(
    scopes: [PanelSoundScopeID]
) -> [PanelSoundScopePickerFocusTarget] {
    scopes.map(PanelSoundScopePickerFocusTarget.scope) + [.integrations]
}

public enum PanelFocusScope: Sendable, Equatable {
    case onboarding(
        hasPrimaryAction: Bool,
        hasSecondaryAction: Bool,
        hasDetailToggle: Bool = false)
    case operational(
        events: [PanelEventPresentation],
        hasMasterVolume: Bool,
        hasOpenSoundSettings: Bool,
        hasResetSurface: Bool,
        hasConfigFailureNotice: Bool = false,
        bootstrapReportActions: [PanelFocusTarget] = [])
}

/// 生产顺序与视觉顺序相同：作用域 → 启动/配置恢复 → 每行可用试听/静音 → 播放设置 →
/// 条件 reset → 固定退出 footer。禁用动作不制造幽灵 Tab stop。
public func panelFocusOrder(_ scope: PanelFocusScope) -> [PanelFocusTarget] {
    switch scope {
    case .onboarding(let hasPrimaryAction, let hasSecondaryAction, let hasDetailToggle):
        var order: [PanelFocusTarget] = []
        if hasDetailToggle { order.append(.revealDetail) }
        if hasPrimaryAction { order.append(.onboardingPrimaryAction) }
        if hasSecondaryAction { order.append(.onboardingSecondaryAction) }
        return order

    case .operational(
        let events,
        let hasMasterVolume,
        let hasOpenSoundSettings,
        let hasResetSurface,
        let hasConfigFailureNotice,
        let bootstrapReportActions):
        var order: [PanelFocusTarget] = [.soundScope]
        order.append(contentsOf: bootstrapReportActions)
        if hasConfigFailureNotice { order.append(.configReveal) }
        for event in events {
            if event.controls.previewEnabled { order.append(.eventPreview(event.event)) }
            if event.controls.muteEnabled { order.append(.eventMute(event.event)) }
        }
        if hasMasterVolume { order.append(.masterVolume) }
        if hasOpenSoundSettings { order.append(.openSoundSettings) }
        if hasResetSurface { order.append(.resetSurface) }
        order.append(.quitApplication)
        return order
    }
}

/// 面板打开时落在当前真实可操作顺序的第一项。operational 永远至少有声音作用域与退出。
public func panelFirstFocusTarget(
    _ scope: PanelFocusScope,
    nonOperableActionEvents _: Set<Event> = [],
    ctaOperable: Bool = true
) -> PanelFocusTarget? {
    panelFocusOrder(scope).first { target in
        switch target {
        case .onboardingPrimaryAction, .onboardingSecondaryAction, .disconnect, .revealDetail:
            return ctaOperable
        default:
            return true
        }
    }
}

public func panelOpeningFocus(
    events: [PanelEventPresentation],
    hasMasterVolume: Bool,
    hasOpenSoundSettings: Bool,
    hasResetSurface: Bool,
    hasConfigFailureNotice: Bool = false,
    bootstrapReportActions: [PanelFocusTarget] = []
) -> PanelFocusTarget? {
    panelFirstFocusTarget(
        .operational(
            events: events,
            hasMasterVolume: hasMasterVolume,
            hasOpenSoundSettings: hasOpenSoundSettings,
            hasResetSurface: hasResetSurface,
            hasConfigFailureNotice: hasConfigFailureNotice,
            bootstrapReportActions: bootstrapReportActions))
}
