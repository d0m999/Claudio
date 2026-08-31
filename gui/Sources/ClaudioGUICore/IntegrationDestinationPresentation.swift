import ClaudioCore
import Foundation

/// The four rows in the connection section are a typed contract. Keeping the order here makes
/// the SwiftUI surface, deep-link focus, and presentation tests consume one declaration.
public enum IntegrationConnectionRowKind: String, CaseIterable, Codable, Sendable, Hashable,
    Identifiable
{
    case connectionStatus = "connection-status"
    case mechanism
    case eventsAndSounds = "events-and-sounds"
    case receiptHistory = "receipt-history"

    public var id: String { rawValue }
}

/// Actions that belong to a connection-section row. The row action is intentionally narrower
/// than ``HostIntegrationUserAction``: selecting an Agent and operating its Toggle remain separate
/// controls, while Events is routed by the Settings owner rather than the manager bridge.
public enum IntegrationConnectionRowAction: Sendable, Equatable, Hashable {
    case redetect
    case copyHooks
    case repair(HostID)
    case copyConfigurationSource(HostID)
    case manageEvents(HostID)
    case clearReceiptHistory(HostID)
}

public struct IntegrationConnectionRowPresentation: Identifiable, Sendable, Equatable {
    public var id: IntegrationConnectionRowKind { kind }
    public let kind: IntegrationConnectionRowKind
    public let title: String
    public let caption: String
    public let value: String?
    public let actions: [IntegrationConnectionRowAction]

    public init(
        kind: IntegrationConnectionRowKind,
        title: String,
        caption: String,
        value: String? = nil,
        actions: [IntegrationConnectionRowAction] = []
    ) {
        self.kind = kind
        self.title = title
        self.caption = caption
        self.value = value
        self.actions = actions
    }
}

/// One selected Host Surface's connection section. Its initializer normalizes rows to the
/// declared four-row order and never lets a caller introduce a fifth display row.
public struct IntegrationConnectionSectionPresentation: Sendable, Equatable {
    public let host: HostID
    public let rows: [IntegrationConnectionRowPresentation]
    public let infoText: String?

    public init(
        host: HostID,
        rows: [IntegrationConnectionRowPresentation],
        infoText: String? = nil
    ) {
        self.host = host
        self.rows = IntegrationConnectionRowKind.allCases.compactMap { kind in
            rows.first(where: { $0.kind == kind })
        }
        self.infoText = infoText
    }

    public func row(_ kind: IntegrationConnectionRowKind) -> IntegrationConnectionRowPresentation? {
        rows.first(where: { $0.kind == kind })
    }
}

/// Host facts not owned by the view: the manager-derived row state, optional manager-provided
/// configuration source, and current-installation redacted receipt evidence.
public struct IntegrationDestinationHostFacts: Identifiable, Sendable, Equatable {
    public var id: HostID { host }
    public let host: HostID
    public let row: HostSourceRowPresentation
    public let configurationSource: String?
    public let latestReceiptText: String?
    public let latestReceiptEvidence: HostReceiptEvidence?
    public let mechanism: HostIntegrationMechanism

    public init(
        host: HostID,
        row: HostSourceRowPresentation,
        configurationSource: String?,
        latestReceiptText: String?,
        latestReceiptEvidence: HostReceiptEvidence?,
        mechanism: HostIntegrationMechanism? = nil
    ) {
        self.host = host
        self.row = row
        self.configurationSource = configurationSource
        self.latestReceiptText = latestReceiptText
        self.latestReceiptEvidence = latestReceiptEvidence
        self.mechanism = mechanism ?? host.descriptor.mechanism
    }

    public var surfaceID: HostSurfaceID { host.surfaceID }
    public var status: HostSourceRowStatus { row.status }
    public var coverageText: String {
        guard let supportedCount = row.supportedCount, let totalCount = row.totalCount else {
            return row.readinessText
        }
        return "\(supportedCount)/\(totalCount)"
    }

    /// Connection diagnosis deliberately distinguishes configuration from current-installation
    /// activation. A receipt is the only fact that permits the activated wording.
    public var connectionDescription: String {
        if status == .ready, latestReceiptEvidence != nil {
            return "当前安装实例已取得真实宿主事件回执。"
        }
        let diagnosis: String
        switch status {
        case .notConnected:
            diagnosis = "当前安装实例尚未连接。"
        case .needsAttention:
            diagnosis = row.detailText ?? "当前安装实例需要处理。"
        case .ready, .awaitingActivation, .legacy:
            diagnosis = "当前安装实例已配置，等待真实宿主事件回执。"
        }
        if status != .needsAttention, let detail = row.detailText {
            return "\(diagnosis) \(detail)"
        }
        return diagnosis
    }

    public var connectionCaption: String {
        if let latestReceiptText {
            return "\(connectionDescription) 最近回执：\(latestReceiptText)"
        }
        return "\(connectionDescription) 暂无当前安装实例回执。"
    }
}

/// The Agent row is a pure projection of one host row and the current operation. `isOn` always
/// comes from the manager snapshot; an in-flight operation never flips it optimistically.
public struct IntegrationAgentConnectionControlPresentation: Identifiable, Sendable, Equatable {
    public var id: HostID { host }
    public let host: HostID
    public let title: String
    public let status: HostSourceRowStatus
    public let badgeText: String
    public let coverageText: String
    public let isOn: Bool
    public let isToggleEnabled: Bool
    public let isInFlight: Bool

    public init(
        row: HostSourceRowPresentation,
        isToggleEnabled: Bool = true,
        isInFlight: Bool = false
    ) {
        host = row.host
        title = row.title
        status = row.status
        badgeText = hostIntegrationStatusBadgeText(row.status)
        if let supportedCount = row.supportedCount, let totalCount = row.totalCount {
            coverageText = "\(supportedCount)/\(totalCount)"
        } else {
            coverageText = row.readinessText
        }
        isOn = row.status != .notConnected
        self.isToggleEnabled = isToggleEnabled
        self.isInFlight = isInFlight
    }
}

public struct IntegrationDestinationContent: Sendable, Equatable {
    /// Shared rows/matrix remain available to Panel and Events consumers. The Integrations page
    /// itself renders only `agents`, `hostFacts`, and the selected connection section.
    public let sourceRows: [HostSourceRowPresentation]
    public let matrix: HostCapabilityMatrixPresentation
    public let hostFacts: [IntegrationDestinationHostFacts]
    public let agents: [IntegrationAgentConnectionControlPresentation]
    public let unavailableReason: String?

    public init(
        sourceRows: [HostSourceRowPresentation],
        matrix: HostCapabilityMatrixPresentation,
        hostFacts: [IntegrationDestinationHostFacts],
        unavailableReason: String? = nil
    ) {
        self.sourceRows = sourceRows
        self.matrix = matrix
        let orderedHostFacts = HostID.productVisibleCases.compactMap { host in
            hostFacts.first(where: { $0.host == host })
        }
        self.hostFacts = orderedHostFacts
        self.agents = orderedHostFacts.map {
            IntegrationAgentConnectionControlPresentation(row: $0.row)
        }
        self.unavailableReason = unavailableReason
    }

    public var isUnavailable: Bool { hostFacts.isEmpty || unavailableReason != nil }

    public func facts(for host: HostID) -> IntegrationDestinationHostFacts? {
        hostFacts.first(where: { $0.host == host })
    }

    public func agent(for host: HostID) -> IntegrationAgentConnectionControlPresentation? {
        agents.first(where: { $0.host == host })
    }

    public func connectionSection(for host: HostID) -> IntegrationConnectionSectionPresentation? {
        guard let facts = facts(for: host) else { return nil }
        return integrationConnectionSectionPresentation(for: facts)
    }
}

public func hostIntegrationStatusBadgeText(_ status: HostSourceRowStatus) -> String {
    switch status {
    case .ready: "已激活"
    case .awaitingActivation: "待回执"
    case .legacy: "旧版连接"
    case .notConnected: "未连接"
    case .needsAttention: "需要处理"
    }
}

public func hostIntegrationMechanismDisplayName(_ mechanism: HostIntegrationMechanism) -> String {
    switch mechanism {
    case .nativeHooks: "原生 hooks"
    case .accessibilityBeta: "Accessibility Beta"
    }
}

/// Exactly the Agent order promised by the destination contract. Do not replace this with
/// `HostID.allCases` or Product grouping; those include diagnostic AX identities and have a
/// different historical order.
public func integrationAgentHostOrder() -> [HostID] {
    HostID.productVisibleCases
}

/// Pure five-state action projection for the connection-status row.
public func integrationConnectionStatusActions(
    for facts: IntegrationDestinationHostFacts
) -> [IntegrationConnectionRowAction] {
    integrationConnectionStatusActions(for: facts.row).compactMap { action in
        switch action {
        case .copyHooksCommand: .copyHooks
        case .redetect: .redetect
        case .repair(let host): .repair(host)
        case .connect, .disconnect, .clearReceiptHistory: nil
        }
    }
}

public func integrationConnectionSectionPresentation(
    for facts: IntegrationDestinationHostFacts
) -> IntegrationConnectionSectionPresentation {
    let sourceCaption: String
    if let source = facts.configurationSource {
        sourceCaption = "\(hostIntegrationMechanismDisplayName(facts.mechanism)) · 配置来源：\(abbreviatedConfigurationPath(source))"
    } else {
        sourceCaption = "\(hostIntegrationMechanismDisplayName(facts.mechanism)) · 配置来源暂不可用"
    }
    let statusActions = integrationConnectionStatusActions(for: facts)
    return IntegrationConnectionSectionPresentation(
        host: facts.host,
        rows: [
            IntegrationConnectionRowPresentation(
                kind: .connectionStatus,
                title: "连接状态",
                caption: facts.connectionCaption,
                actions: statusActions),
            IntegrationConnectionRowPresentation(
                kind: .mechanism,
                title: "接入方式",
                caption: sourceCaption,
                value: facts.coverageText,
                actions: facts.configurationSource == nil
                    ? [] : [.copyConfigurationSource(facts.host)]),
            IntegrationConnectionRowPresentation(
                kind: .eventsAndSounds,
                title: "事件与提示音",
                caption: "只修改 \(facts.host.displayName)；其他 app 的事件开关和声音保持不变",
                actions: [.manageEvents(facts.host)]),
            IntegrationConnectionRowPresentation(
                kind: .receiptHistory,
                title: "脱敏回执历史",
                caption: "每个来源最多保留 20 条、30 天；清除不影响当前连接或声音偏好",
                actions: [.clearReceiptHistory(facts.host)]),
        ],
        infoText:
            "“已配置”不等于“已激活”：只有当前安装实例产生真实 receipt，状态才会变为已激活。普通 Chat 不继承 Codex view 的 hooks。")
}
