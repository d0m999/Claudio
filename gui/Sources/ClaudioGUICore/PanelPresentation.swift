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

/// 全宽声音作用域菜单的一项。状态仍是语义枚举；图标与颜色只在 SwiftUI 层选择。
public struct PanelSoundScopePresentation: Sendable, Equatable, Identifiable {
    public var id: PanelSoundScopeID { scope }
    public let scope: PanelSoundScopeID
    public let host: HostID?
    public let name: String
    public let supportedCount: Int
    public let totalCount: Int
    public let status: HostSourceRowStatus
    public let statusText: String
    public let compactStatusText: String
    public let hasSparseOverride: Bool
    public let accessibilityLabel: String

    public init(
        scope: PanelSoundScopeID,
        host: HostID?,
        name: String,
        supportedCount: Int,
        totalCount: Int,
        status: HostSourceRowStatus,
        statusText: String,
        compactStatusText: String,
        hasSparseOverride: Bool,
        accessibilityLabel: String
    ) {
        self.scope = scope
        self.host = host
        self.name = name
        self.supportedCount = supportedCount
        self.totalCount = totalCount
        self.status = status
        self.statusText = statusText
        self.compactStatusText = compactStatusText
        self.hasSparseOverride = hasSparseOverride
        self.accessibilityLabel = accessibilityLabel
    }
}

/// Global 恒在；普通 Surface 只在“已配置或可用”时进入 popup。`.notConnected` 仍由
/// IntegrationsWindow 完整呈现，不会因为 popup 过滤而丢失诊断入口。
public func panelSoundScopePresentations(
    sourceRows: [HostSourceRowPresentation],
    config: ClaudioConfig,
    language: ClaudioAppLanguage
) -> [PanelSoundScopePresentation] {
    let l10n = ClaudioL10n(language: language)
    let separator = language == .english ? ", " : "，"
    let globalName = l10n.text(.panelGlobalName)
    let globalStatus = l10n.format(
        .panelGlobalStatus,
        Int64(Event.allCases.count),
        Int64(Event.allCases.count))
    let global = PanelSoundScopePresentation(
        scope: .global,
        host: nil,
        name: globalName,
        supportedCount: Event.allCases.count,
        totalCount: Event.allCases.count,
        status: .ready,
        statusText: globalStatus,
        compactStatusText: globalStatus,
        hasSparseOverride: false,
        accessibilityLabel: [globalName, globalStatus].joined(separator: separator))

    let byHost = Dictionary(uniqueKeysWithValues: sourceRows.map { ($0.host, $0) })
    let surfaces = hostSurfacePresentationOrder().compactMap {
        host -> PanelSoundScopePresentation? in
        guard let raw = byHost[host] else { return nil }
        guard raw.status != .notConnected else { return nil }
        let hasOverride =
            config.surfaceOverrides[host.surfaceID.rawValue] != nil
            || config.invalidSurfaceOverrideKeys.contains(host.surfaceID.rawValue)
        let row = localizedHostSourceRow(raw, language: language)
        let supported = row.supportedCount ?? 0
        let total = row.totalCount ?? Event.allCases.count
        let overrideText: String? = hasOverride ? l10n.text(.panelCustomSoundOverrides) : nil
        let accessibility = [row.title, row.readinessText, overrideText]
            .compactMap { $0 }
            .joined(separator: separator)
        return PanelSoundScopePresentation(
            scope: .surface(host.surfaceID),
            host: host,
            name: row.title,
            supportedCount: supported,
            totalCount: total,
            status: row.status,
            statusText: row.readinessText,
            compactStatusText: row.readinessText,
            hasSparseOverride: hasOverride,
            accessibilityLabel: accessibility)
    }
    return [global] + surfaces
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
        case .present(let fileName): soundFileText = fileName
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
