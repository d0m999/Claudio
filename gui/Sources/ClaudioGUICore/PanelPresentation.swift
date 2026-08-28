import ClaudioCore
import ClaudioLocalization
import Foundation

/// 菜单栏声音作用域的稳定身份。`global` 不是伪造的 Host；Surface 始终保留真实
/// `HostSurfaceID`，供配置写入、窗口路由和焦点恢复共同消费。
public enum PanelSoundScopeID: Sendable, Equatable, Hashable, Identifiable {
    case global
    case surface(HostSurfaceID)

    public var id: String { storedValue }

    public var storedValue: String {
        switch self {
        case .global: "global"
        case .surface(let surface): surface.rawValue
        }
    }

    public var surface: HostSurfaceID? {
        guard case .surface(let surface) = self else { return nil }
        return surface
    }
}

/// “事件与提示音”表面的显式入口。路由直接携带声音作用域与可选公共事件，避免把展示
/// 名称或 Host Product 重新解析成配置写入目标。
public struct EventSettingsWindowRoute: Sendable, Equatable, Hashable {
    public let scope: PanelSoundScopeID
    public let event: Event?

    public init(scope: PanelSoundScopeID, event: Event? = nil) {
        self.scope = scope
        self.event = event
    }

    public var surface: HostSurfaceID? { scope.surface }

    public func soundPacksRoute(packID: String, event: Event) -> SoundPacksWindowRoute {
        .editEvent(surface: surface, packID: packID, event: event)
    }
}

/// Resolves the file that both event surfaces may preview. Keeping the stale-coverage recheck in
/// one place prevents the panel and retained window from drifting on symlink or empty-file safety.
public func eventPreviewFileURL(
    row: EventRow,
    packID: String,
    environment: AudioImportEnvironment
) -> URL? {
    guard case .present(let fileName) = row.coverage,
        let packDirectory = resolvePackDirectory(
            id: packID,
            userPacksDirectory: environment.userPacksDirectory,
            bundledPacksDirectory: environment.bundledPacksDirectory),
        let file = safePackFileURL(fileName, in: packDirectory),
        nonEmptyRegularFileExists(at: file)
    else { return nil }
    return file
}

/// Stable focus identities for the retained Events & Sounds window. The first scope is always the
/// deterministic entry point; event controls follow the visible row order through SwiftUI's key
/// view loop.
public enum EventSettingsFocusTarget: Sendable, Equatable, Hashable {
    case scope(PanelSoundScopeID)
    case event(Event)
    case previewAll
    case masterVolume
    case packPicker
    case retryLibrary
    case manageSoundPacks
    case generateAICue(Event)
    case configure(Event)
    case preview(Event)
    case mute(Event)
}

public func eventSettingsFirstFocusTarget(
    scopes: [PanelSoundScopeID]
) -> EventSettingsFocusTarget? {
    scopes.first.map(EventSettingsFocusTarget.scope)
}

/// Repeated typed deep links must focus the same stable event identity. A stale scope never leaves
/// focus pointing at a row whose writes would target that stale Surface; it falls back to the first
/// visible scope and lets the caller present the route failure separately.
public func eventSettingsRouteFocusTarget(
    route: EventSettingsWindowRoute,
    scopes: [PanelSoundScopeID],
    events: Set<Event> = Set(Event.allCases)
) -> EventSettingsFocusTarget? {
    guard scopes.contains(route.scope) else {
        return eventSettingsFirstFocusTarget(scopes: scopes)
    }
    if let event = route.event, events.contains(event) {
        return .event(event)
    }
    return .scope(route.scope)
}

public enum EventSettingsInheritanceState: Sendable, Equatable {
    case globalDefault
    case inheritedGlobal
    case surfaceOverride
    case invalidSurfaceOverride
}

/// Pack inheritance is independent from per-event sparse overrides. An Event-only override must
/// not make the pack appear overridden, and a malformed Surface still fails closed.
public func eventSettingsPackInheritanceState(
    config: ClaudioConfig,
    scope: PanelSoundScopeID
) -> EventSettingsInheritanceState {
    guard let surface = scope.surface else { return .globalDefault }
    switch config.resolveSoundProfile(for: surface) {
    case .success(let profile):
        return profile.inheritedPack ? .inheritedGlobal : .surfaceOverride
    case .failure:
        return .invalidSurfaceOverride
    }
}

/// The unified Settings projection shares the app-lifetime AI model with the legacy window but
/// must never own or end that window's composer session.
public func eventSettingsShouldCloseAICueComposer(
    includesAICueComposer: Bool,
    targetSurface: HostSurfaceID?,
    selectedSurface: HostSurfaceID?
) -> Bool {
    includesAICueComposer && targetSurface != selectedSurface
}

/// The legacy composer belongs to one exact Surface/Event tuple. A route projection from another
/// retained window must never make that session appear under a different Surface.
public func eventSettingsAICueComposerMatches(
    targetSurface: HostSurfaceID?,
    targetEvent: Event?,
    selectedSurface: HostSurfaceID?,
    event: Event
) -> Bool {
    guard let targetSurface, let targetEvent, let selectedSurface else { return false }
    return targetSurface == selectedSurface && targetEvent == event
}

/// VoiceOver receives the same inheritance fact rendered beside an Event. Keeping the join in
/// GUICore makes both the no-override and bilingual projections executable without mounting UI.
public func eventSettingsIdentityAccessibilityLabel(
    presentationLabel: String,
    inheritanceText: String?,
    language: ClaudioAppLanguage
) -> String {
    guard let inheritanceText, !inheritanceText.isEmpty else { return presentationLabel }
    let separator = language == .english ? ", " : "，"
    return [presentationLabel, inheritanceText].joined(separator: separator)
}

/// Per-event sparse-override projection for the unified Events page. It consumes the same
/// `resolveSoundProfile` fail-closed boundary as writes and never infers inheritance from only the
/// pack field.
public func eventSettingsInheritanceState(
    config: ClaudioConfig,
    scope: PanelSoundScopeID,
    event: Event
) -> EventSettingsInheritanceState {
    guard let surface = scope.surface else { return .globalDefault }
    switch config.resolveSoundProfile(for: surface) {
    case .success(let profile):
        return profile.inheritedEvents.contains(event) ? .inheritedGlobal : .surfaceOverride
    case .failure:
        return .invalidSurfaceOverride
    }
}

/// A standard window has its own width-driven degradation rules. Unlike
/// ``PanelLayoutAdaptation``, this value never carries the menu-bar popover's fixed width or
/// waveform decisions into a resizable window.
public struct EventSettingsWindowLayout: Sendable, Equatable {
    public let metadataStacks: Bool
    public let actionsMoveBelow: Bool

    public init(metadataStacks: Bool, actionsMoveBelow: Bool) {
        self.metadataStacks = metadataStacks
        self.actionsMoveBelow = actionsMoveBelow
    }
}

public func eventSettingsWindowLayout(
    availableWidth: Double,
    typeScale: Double
) -> EventSettingsWindowLayout {
    let safeWidth = availableWidth.isFinite && availableWidth > 0 ? availableWidth : 0
    let safeScale = typeScale.isFinite && typeScale > 0 ? typeScale : 1
    let normalizedWidth = safeWidth / safeScale
    return EventSettingsWindowLayout(
        metadataStacks: normalizedWidth < 560,
        actionsMoveBelow: normalizedWidth < 500)
}

/// 全宽声音作用域菜单的一项。状态仍是语义枚举；图标与颜色只在 SwiftUI 层选择。
public struct PanelSoundScopePresentation: Sendable, Equatable, Identifiable {
    public var id: PanelSoundScopeID { scope }
    public let scope: PanelSoundScopeID
    public let host: HostID?
    public let name: String
    public let supportedCount: Int
    public let totalCount: Int
    public let status: HostSourceRowStatus
    public let coverageText: String
    public let stateText: String
    public let summaryText: String
    public let hasSparseOverride: Bool
    public let accessibilityLabel: String

    public init(
        scope: PanelSoundScopeID,
        host: HostID?,
        name: String,
        supportedCount: Int,
        totalCount: Int,
        status: HostSourceRowStatus,
        coverageText: String,
        stateText: String,
        summaryText: String,
        hasSparseOverride: Bool,
        accessibilityLabel: String
    ) {
        self.scope = scope
        self.host = host
        self.name = name
        self.supportedCount = supportedCount
        self.totalCount = totalCount
        self.status = status
        self.coverageText = coverageText
        self.stateText = stateText
        self.summaryText = summaryText
        self.hasSparseOverride = hasSparseOverride
        self.accessibilityLabel = accessibilityLabel
    }
}

/// 声音作用域浮层在当前滚动视口内的尺寸决策。诊断入口与浮层 chrome 固定保留，只有
/// 作用域选项区随剩余高度收缩并在 SwiftUI 层滚动。
public struct PanelSoundScopeMenuLayout: Sendable, Equatable {
    public let optionHeight: Double
    public let optionsContentHeight: Double
    public let optionsHeight: Double
    public let diagnosticsHeight: Double
    public let totalHeight: Double
}

public func panelSoundScopeMenuLayout(
    scopeCount: Int,
    typeScale: Double,
    availableHeight: Double
) -> PanelSoundScopeMenuLayout {
    let count = max(0, scopeCount)
    let scale = max(1, typeScale)
    let optionHeight = max(46, 46 * typeScale)
    let diagnosticsHeight = max(34, 34 * typeScale)
    let chromeHeight: Double = 21
    let designHeightLimit = 250 * scale
    let effectiveAvailableHeight =
        availableHeight.isFinite && availableHeight > 0
        ? availableHeight : designHeightLimit
    let optionsContentHeight =
        Double(count) * optionHeight + Double(max(0, count - 1)) * 3
    let designOptionsLimit = max(0, designHeightLimit - diagnosticsHeight - chromeHeight)
    let viewportOptionsLimit = max(
        0,
        effectiveAvailableHeight - diagnosticsHeight - chromeHeight)
    let optionsHeight = min(optionsContentHeight, designOptionsLimit, viewportOptionsLimit)
    return PanelSoundScopeMenuLayout(
        optionHeight: optionHeight,
        optionsContentHeight: optionsContentHeight,
        optionsHeight: optionsHeight,
        diagnosticsHeight: diagnosticsHeight,
        totalHeight: min(
            effectiveAvailableHeight,
            optionsHeight + diagnosticsHeight + chromeHeight))
}

/// Global 恒在；普通 Surface 只在“已配置或可用”时进入 popup。`.notConnected` 仍由
/// IntegrationsWindow 完整呈现，不会因为 popup 过滤而丢失诊断入口。
public func panelSoundScopePresentations(
    sourceRows: [HostSourceRowPresentation],
    config: ClaudioConfig,
    language: ClaudioAppLanguage,
    includesDisconnected: Bool = false
) -> [PanelSoundScopePresentation] {
    let l10n = ClaudioL10n(language: language)
    let separator = language == .english ? ", " : "，"
    let globalName = l10n.text(.panelGlobalDefaults)
    let globalCoverage = l10n.format(
        .panelSoundScopeGlobalCoverage,
        Int64(Event.allCases.count))
    let globalState = l10n.text(.panelSoundScopeStatusDefault)
    let globalSummary = [globalCoverage, globalState].joined(separator: " · ")
    let global = PanelSoundScopePresentation(
        scope: .global,
        host: nil,
        name: globalName,
        supportedCount: Event.allCases.count,
        totalCount: Event.allCases.count,
        status: .ready,
        coverageText: globalCoverage,
        stateText: globalState,
        summaryText: globalSummary,
        hasSparseOverride: false,
        accessibilityLabel: [globalName, globalSummary].joined(separator: separator))

    let byHost = Dictionary(uniqueKeysWithValues: sourceRows.map { ($0.host, $0) })
    let surfaces = hostSurfacePresentationOrder().compactMap {
        host -> PanelSoundScopePresentation? in
        guard let raw = byHost[host] else { return nil }
        guard includesDisconnected || raw.status != .notConnected else { return nil }
        let hasOverride =
            config.surfaceOverrides[host.surfaceID.rawValue] != nil
            || config.invalidSurfaceOverrideKeys.contains(host.surfaceID.rawValue)
        let row = localizedHostSourceRow(raw, language: language)
        let supported = row.supportedCount ?? 0
        let total = row.totalCount ?? Event.allCases.count
        let coverage = "\(supported)/\(total)"
        let state = panelSoundScopeStateText(row.status, l10n: l10n)
        let summary = [coverage, state].joined(separator: " · ")
        let overrideText: String? = hasOverride ? l10n.text(.panelCustomSoundOverrides) : nil
        let accessibility = [row.title, summary, overrideText]
            .compactMap { $0 }
            .joined(separator: separator)
        return PanelSoundScopePresentation(
            scope: .surface(host.surfaceID),
            host: host,
            name: row.title,
            supportedCount: supported,
            totalCount: total,
            status: row.status,
            coverageText: coverage,
            stateText: state,
            summaryText: summary,
            hasSparseOverride: hasOverride,
            accessibilityLabel: accessibility)
    }
    return [global] + surfaces
}

private func panelSoundScopeStateText(
    _ status: HostSourceRowStatus,
    l10n: ClaudioL10n
) -> String {
    switch status {
    case .ready: l10n.text(.panelSoundScopeStatusActive)
    case .awaitingActivation: l10n.text(.panelSoundScopeStatusAwaitingReceipt)
    case .legacy: l10n.text(.panelSoundScopeStatusLegacy)
    case .notConnected: l10n.text(.panelSoundScopeStatusNotConnected)
    case .needsAttention: l10n.text(.panelSoundScopeStatusNeedsAttention)
    }
}

/// 持久化选择的恢复规则：显式 `global` 永远保留；合法历史 Surface 原样恢复；从未选择或
/// 失效值优先首个可用 Surface，没有 Surface 才回退 Global。
public func resolvedPanelSoundScopeSelection(
    storedValue: String?,
    scopes: [PanelSoundScopePresentation]
) -> PanelSoundScopeID {
    if storedValue == PanelSoundScopeID.global.storedValue { return .global }
    if let storedValue,
        let exact = scopes.first(where: { $0.scope.storedValue == storedValue })
    {
        return exact.scope
    }
    return scopes.first(where: { $0.scope.surface != nil })?.scope ?? .global
}

/// Keeps the retained Events & Sounds route on a currently visible sound scope. A Surface may
/// disappear while the window remains open; resolving through the same rule as the panel prevents
/// a fallback label from continuing to write to the stale Surface.
public func resolvedEventSettingsScope(
    route: EventSettingsWindowRoute,
    scopes: [PanelSoundScopePresentation]
) -> PanelSoundScopeID {
    resolvedPanelSoundScopeSelection(storedValue: route.scope.storedValue, scopes: scopes)
}

/// `unselected` / missing means the first host refresh has not yet established whether a Surface
/// is available. Global remains a safe transient presentation, but only a real Surface arrival or
/// an explicit user choice may turn that pending marker into a persisted selection.
public func panelSoundScopeStoredValueToPersist(
    storedValue: String?,
    resolvedSelection: PanelSoundScopeID
) -> String? {
    let isPendingFirstSelection = storedValue == nil || storedValue == "unselected"
    if isPendingFirstSelection, resolvedSelection == .global { return nil }
    return resolvedSelection.storedValue
}

/// 事件行两个写/试听动作的唯一可用性投影。视图与焦点顺序必须消费同一实例。
public struct PanelEventControlAvailability: Sendable, Equatable {
    public let previewEnabled: Bool
    public let muteEnabled: Bool
    public let previewAvailability: EventPreviewAvailability

    public init(
        previewEnabled: Bool,
        muteEnabled: Bool,
        previewAvailability: EventPreviewAvailability
    ) {
        self.previewEnabled = previewEnabled
        self.muteEnabled = muteEnabled
        self.previewAvailability = previewAvailability
    }
}

/// 菜单栏单一来源的五行事件呈现。Global 行使用 claudi0 事件 ID；Surface 行使用能力
/// catalog 的原生事件名、接口支持和实现事实。
public struct PanelEventPresentation: Sendable, Equatable, Identifiable {
    public var id: Event { event }
    public let event: Event
    public let title: String
    public let nativeEventText: String
    public let capabilityText: String
    public let soundFileText: String
    public let enabled: Bool
    public let support: HostCapabilitySupport?
    public let implementation: HostCapabilityImplementation?
    public let controls: PanelEventControlAvailability
    public let accessibilityLabel: String
}

public func panelEventPresentations(
    rows: [EventRow],
    scope: PanelSoundScopeID,
    masterVolume: Double,
    language: ClaudioAppLanguage,
    configWritesAllowed: Bool = true
) -> [PanelEventPresentation] {
    let l10n = ClaudioL10n(language: language)
    let separator = language == .english ? ", " : "，"
    let rowsByEvent = Dictionary(uniqueKeysWithValues: rows.map { ($0.event, $0) })
    return Event.allCases.map { event in
        let row = rowsByEvent[event] ?? EventRow(event: event, coverage: .unmapped, enabled: false)
        let binding: HostCapabilityBinding?
        switch scope {
        case .global:
            binding = nil
        case .surface(let surface):
            binding = HostID.productVisibleCases
                .first(where: { $0.surfaceID == surface })
                .flatMap { HostCapabilityCatalog.binding(host: $0, event: event) }
        }
        let implemented: Bool
        switch scope {
        case .global:
            implemented = true
        case .surface:
            implemented =
                binding.map {
                    $0.implementation != .notImplemented && $0.support != .unsupported
                } ?? false
        }
        let previewAvailability = eventPreviewAvailability(
            coverage: row.coverage,
            masterVolume: masterVolume)
        let controls = PanelEventControlAvailability(
            previewEnabled: implemented && previewAvailability.isAvailable,
            muteEnabled: implemented && configWritesAllowed,
            previewAvailability: previewAvailability)
        let nativeEventText: String
        if let binding {
            nativeEventText = binding.nativeEvent ?? l10n.text(.panelNoNativeEvent)
        } else {
            nativeEventText = event.cliName
        }
        let capabilityText: String
        if let binding {
            capabilityText = panelCapabilityText(binding, language: language)
        } else {
            capabilityText = l10n.text(.panelGlobalDefaults)
        }
        let soundFileText: String
        switch row.coverage {
        case .present(let fileName): soundFileText = row.audioDisplayName ?? fileName
        case .unmapped: soundFileText = l10n.text(.panelNoSoundAssigned)
        case .broken(let fileName):
            soundFileText = l10n.format(.panelMissingSound, fileName)
        }
        let enabledText =
            row.enabled
            ? l10n.text(.eventEnabled)
            : l10n.text(.eventMuted)
        let clauses = [
            localizedEventName(event, language: language), nativeEventText, capabilityText,
            soundFileText, enabledText,
        ]
        return PanelEventPresentation(
            event: event,
            title: localizedEventName(event, language: language),
            nativeEventText: nativeEventText,
            capabilityText: capabilityText,
            soundFileText: soundFileText,
            enabled: row.enabled,
            support: binding?.support,
            implementation: binding?.implementation,
            controls: controls,
            accessibilityLabel: clauses.joined(separator: separator))
    }
}

private func panelCapabilityText(
    _ binding: HostCapabilityBinding,
    language: ClaudioAppLanguage
) -> String {
    let l10n = ClaudioL10n(language: language)
    if binding.implementation == .notImplemented {
        switch binding.support {
        case .supported:
            return l10n.text(.panelCapabilitySupportedNotImplemented)
        case .partial:
            return l10n.text(.panelCapabilityPartialNotImplemented)
        case .unsupported:
            return l10n.text(.panelCapabilityUnsupportedNotImplemented)
        }
    }
    switch binding.support {
    case .supported: return l10n.text(.panelCapabilitySupported)
    case .partial: return l10n.text(.panelCapabilityPartial)
    case .unsupported: return l10n.text(.panelCapabilityUnsupported)
    }
}
