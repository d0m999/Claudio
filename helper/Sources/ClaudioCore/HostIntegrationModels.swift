import Foundation

/// Claudio 已知的宿主身份。raw value 同时是 CLI 与历史数据的稳定 token。
///
/// `allCases` 包含仅供兼容解码和隔离诊断使用的身份；正常产品 registry 必须使用
/// ``productVisibleCases``，不能把诊断身份当作可用集成表面。
public enum HostID: String, CaseIterable, Codable, Sendable, Hashable {
    case claudeCode = "claude-code"
    case codex = "codex"
    case workBuddy = "workbuddy"
    case chatGPTDesktopAX = "chatgpt-desktop-ax"
    case claudeDesktopAX = "claude-desktop-ax"

    /// 正常产品表面唯一真相源。AX identity 继续可解码，但不会进入 manager、矩阵或普通 UI。
    public static let productVisibleCases: [HostID] = [.claudeCode, .codex, .workBuddy]

    public var displayName: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        case .workBuddy: "WorkBuddy"
        case .chatGPTDesktopAX: "ChatGPT Desktop (AX Beta)"
        case .claudeDesktopAX: "Claude Desktop (AX Beta)"
        }
    }

    public var surfaceID: HostSurfaceID {
        HostSurfaceID(rawValue: rawValue)!
    }

    public var descriptor: HostIntegrationDescriptor {
        switch self {
        case .claudeCode:
            HostIntegrationDescriptor(
                host: self, product: .claude, surface: .claudeCode,
                mechanism: .nativeHooks, maturity: .stable, controlSurface: .shared)
        case .codex:
            HostIntegrationDescriptor(
                host: self, product: .chatGPT, surface: .codex,
                mechanism: .nativeHooks, maturity: .stable, controlSurface: .shared)
        case .workBuddy:
            HostIntegrationDescriptor(
                host: self, product: .workBuddy, surface: .workBuddy,
                mechanism: .nativeHooks, maturity: .stable, controlSurface: .shared)
        case .chatGPTDesktopAX:
            HostIntegrationDescriptor(
                host: self, product: .chatGPT, surface: .chatGPTDesktopAX,
                mechanism: .accessibilityBeta, maturity: .beta, controlSurface: .guiOnly)
        case .claudeDesktopAX:
            HostIntegrationDescriptor(
                host: self, product: .claude, surface: .claudeDesktopAX,
                mechanism: .accessibilityBeta, maturity: .beta, controlSurface: .guiOnly)
        }
    }
}

/// 用户识别的产品品牌。能力与偏好不直接绑定产品；它只负责把多个 surface 分组。
public enum HostProductID: String, CaseIterable, Codable, Sendable, Hashable {
    case chatGPT
    case claude
    case workBuddy = "workbuddy"

    public var displayName: String {
        switch self {
        case .chatGPT: "ChatGPT"
        case .claude: "Claude"
        case .workBuddy: "WorkBuddy"
        }
    }
}

/// 一条稳定、可持久化的事件来源。它比产品更细，声音覆盖和回执均以它为作用域。
public enum HostSurfaceID: String, CaseIterable, Codable, Sendable, Hashable {
    case claudeCode = "claude-code"
    case codex = "codex"
    case workBuddy = "workbuddy"
    case chatGPTDesktopAX = "chatgpt-desktop-ax"
    case claudeDesktopAX = "claude-desktop-ax"
}

public enum HostIntegrationMechanism: String, Codable, Sendable, Equatable {
    case nativeHooks = "native_hooks"
    case accessibilityBeta = "accessibility_beta"
}

public enum HostIntegrationMaturity: String, Codable, Sendable, Equatable {
    case stable
    case beta
}

public enum HostIntegrationControlSurface: String, Codable, Sendable, Equatable {
    case shared
    case guiOnly = "gui_only"
}

/// Core 只携带稳定 token；展示名由 localization 层决定。
public struct HostIntegrationDescriptor: Codable, Sendable, Equatable, Hashable {
    public let host: HostID
    public let product: HostProductID
    public let surface: HostSurfaceID
    public let mechanism: HostIntegrationMechanism
    public let maturity: HostIntegrationMaturity
    public let controlSurface: HostIntegrationControlSurface

    public init(
        host: HostID,
        product: HostProductID,
        surface: HostSurfaceID,
        mechanism: HostIntegrationMechanism,
        maturity: HostIntegrationMaturity,
        controlSurface: HostIntegrationControlSurface
    ) {
        self.host = host
        self.product = product
        self.surface = surface
        self.mechanism = mechanism
        self.maturity = maturity
        self.controlSurface = controlSurface
    }
}

/// 宿主对一个 Claudio 声音语义的原生支持程度。
public enum HostCapabilitySupport: String, Codable, Sendable, Equatable {
    case supported
    case partial
    case unsupported
}

/// 官方接口声明与 claudi0 当前实现是两条独立事实。
public enum HostCapabilityImplementation: String, Codable, Sendable, Equatable {
    case implemented
    case notImplemented = "not_implemented"
}

/// 限定语稳定 token；GUI 负责把它本地化为用户文案。
public enum HostCapabilityQualificationID: String, Codable, Sendable, Equatable, Hashable {
    case codexStopFailureUnavailable = "codex.stop_failure_unavailable"
    case permissionRequestOnly = "permission_request_only"
    case notificationMatchersOnly = "notification_matchers_only"
    case interfaceSupportedNotImplemented = "interface_supported_not_implemented"
    case interfacePartiallySupportedNotImplemented = "interface_partially_supported_not_implemented"
    case undeclaredCapability = "undeclared_capability"
    case accessibilityBetaUnavailable = "accessibility_beta_unavailable"
}

/// receipt 的稳定主键。schema revision 进入 raw value，binding 语义变化后旧证据自然失效。
public struct HostEventBindingID: RawRepresentable, Codable, Sendable, Equatable, Hashable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

/// 一个宿主原生事件与声音包语义之间的唯一映射。
public struct HostCapabilityBinding: Codable, Sendable, Equatable, Hashable {
    public let id: HostEventBindingID
    public let host: HostID
    public let event: Event
    public let nativeEvent: String?
    public let support: HostCapabilitySupport
    public let implementation: HostCapabilityImplementation
    public let qualification: HostCapabilityQualificationID?

    public init(
        host: HostID,
        event: Event,
        nativeEvent: String?,
        support: HostCapabilitySupport,
        implementation: HostCapabilityImplementation = .implemented,
        qualification: HostCapabilityQualificationID? = nil,
        schemaRevision: Int = 1
    ) {
        let nativeToken = nativeEvent ?? "none"
        let qualifierToken = qualification?.rawValue ?? "none"
        self.id = HostEventBindingID(
            rawValue:
                "\(host.rawValue):\(nativeToken):\(event.rawValue):\(qualifierToken):v\(schemaRevision)"
        )
        self.host = host
        self.event = event
        self.nativeEvent = nativeEvent
        self.support = support
        self.implementation = implementation
        self.qualification = qualification
    }

    public var isAudibleCapability: Bool {
        nativeEvent != nil && support != .unsupported && implementation == .implemented
    }

    public var isDeclaredCapability: Bool {
        nativeEvent != nil && support != .unsupported
    }
}

/// 原生事件名只存在于这里；``Event`` 只保留声音语义和文件键。
public enum HostCapabilityCatalog {
    public static func bindings(for host: HostID) -> [HostCapabilityBinding] {
        switch host {
        case .claudeCode:
            return [
                HostCapabilityBinding(
                    host: host, event: .taskStart, nativeEvent: "UserPromptSubmit",
                    support: .supported),
                HostCapabilityBinding(
                    host: host, event: .stop, nativeEvent: "Stop", support: .supported),
                HostCapabilityBinding(
                    host: host, event: .stopFailure, nativeEvent: "StopFailure",
                    support: .supported),
                HostCapabilityBinding(
                    host: host, event: .notification, nativeEvent: "Notification",
                    support: .supported),
                HostCapabilityBinding(
                    host: host, event: .subagentStop, nativeEvent: "SubagentStop",
                    support: .supported),
            ]
        case .codex:
            return [
                HostCapabilityBinding(
                    host: host, event: .taskStart, nativeEvent: "UserPromptSubmit",
                    support: .supported),
                HostCapabilityBinding(
                    host: host, event: .stop, nativeEvent: "Stop", support: .supported),
                HostCapabilityBinding(
                    host: host, event: .stopFailure, nativeEvent: nil,
                    support: .unsupported, qualification: .codexStopFailureUnavailable),
                HostCapabilityBinding(
                    host: host, event: .notification, nativeEvent: "PermissionRequest",
                    support: .partial, qualification: .permissionRequestOnly),
                HostCapabilityBinding(
                    host: host, event: .subagentStop, nativeEvent: "SubagentStop",
                    support: .supported),
            ]
        case .workBuddy:
            return [
                HostCapabilityBinding(
                    host: host, event: .taskStart, nativeEvent: "UserPromptSubmit",
                    support: .supported),
                HostCapabilityBinding(
                    host: host, event: .stop, nativeEvent: "Stop", support: .supported),
                HostCapabilityBinding(
                    host: host, event: .stopFailure, nativeEvent: "StopFailure",
                    support: .supported, implementation: .notImplemented,
                    qualification: .interfaceSupportedNotImplemented),
                HostCapabilityBinding(
                    host: host, event: .notification, nativeEvent: "Notification",
                    support: .partial, implementation: .notImplemented,
                    qualification: .interfacePartiallySupportedNotImplemented),
                HostCapabilityBinding(
                    host: host, event: .subagentStop, nativeEvent: "SubagentStop",
                    support: .supported, implementation: .notImplemented,
                    qualification: .interfaceSupportedNotImplemented),
            ]
        case .chatGPTDesktopAX, .claudeDesktopAX:
            return Event.allCases.map { event in
                HostCapabilityBinding(
                    host: host,
                    event: event,
                    nativeEvent: nil,
                    support: .unsupported,
                    implementation: .notImplemented,
                    qualification: .accessibilityBetaUnavailable)
            }
        }
    }

    public static func semanticEvent(host: HostID, nativeEvent: String) -> Event? {
        bindings(for: host).first {
            $0.nativeEvent == nativeEvent && $0.isAudibleCapability
        }?.event
    }

    public static func binding(host: HostID, nativeEvent: String) -> HostCapabilityBinding? {
        bindings(for: host).first {
            $0.nativeEvent == nativeEvent && $0.isAudibleCapability
        }
    }

    public static func binding(host: HostID, event: Event) -> HostCapabilityBinding? {
        bindings(for: host).first { $0.event == event }
    }
}

public enum SharedRuntimeHealth: Codable, Sendable, Equatable {
    case ready
    case unavailable(reason: String)
    case damaged(reason: String)
}

public enum HostAvailability: Codable, Sendable, Equatable {
    case available
    case unavailable(reason: String)
}

public enum HostConfigurationState: Codable, Sendable, Equatable {
    case notConfigured
    case legacyConnected
    case configured
    case incomplete(missingNativeEvents: [String])
    case unreadable(reason: String)
    case conflict(reason: String)
}

public enum HostConfigWritability: Codable, Sendable, Equatable {
    case writable
    case notWritable(reason: String)
    case unknown
}

public enum HostAuthorizationState: Codable, Sendable, Equatable {
    case notRequired
    case permissionRequired
    case denied
    case granted
}

public struct HostReceiptEvidence: Codable, Sendable, Equatable {
    public let bindingID: HostEventBindingID
    public let installationID: UUID
    public let nativeEvent: String
    public let event: Event
    public let timestamp: Date
    public let playbackResult: HostHookPlaybackResult

    public init(
        installationID: UUID,
        nativeEvent: String,
        event: Event,
        timestamp: Date,
        playbackResult: HostHookPlaybackResult
    ) {
        self.bindingID = HostEventBindingID(rawValue: "legacy:\(nativeEvent):\(event.rawValue)")
        self.installationID = installationID
        self.nativeEvent = nativeEvent
        self.event = event
        self.timestamp = timestamp
        self.playbackResult = playbackResult
    }

    public init(
        bindingID: HostEventBindingID,
        installationID: UUID,
        nativeEvent: String,
        event: Event,
        timestamp: Date,
        playbackResult: HostHookPlaybackResult
    ) {
        self.bindingID = bindingID
        self.installationID = installationID
        self.nativeEvent = nativeEvent
        self.event = event
        self.timestamp = timestamp
        self.playbackResult = playbackResult
    }
}

public enum HostActivationEvidence: Codable, Sendable, Equatable {
    case none
    case awaitingReceipt(installationID: UUID)
    case observed(HostReceiptEvidence)
}

public enum HostOperationState: Codable, Sendable, Equatable {
    case idle
    case connecting
    case disconnecting
    case failed(reason: String)
}

/// UI、CLI 与 doctor 共用的宿主事实快照。
public struct HostIntegrationSnapshot: Codable, Sendable, Equatable {
    public let host: HostID
    public let runtime: SharedRuntimeHealth
    public let availability: HostAvailability
    public let configuration: HostConfigurationState
    public let writability: HostConfigWritability
    public let authorization: HostAuthorizationState
    public let activation: HostActivationEvidence
    public let bindingActivations: [HostEventBindingID: HostActivationEvidence]
    /// 当前 installation 全部受支持事件里时间最新的脱敏回执。它只负责诊断展示；
    /// 宿主激活门槛由 ``activation`` 独立表达，旧 lifecycle 回执不能点亮任务开始能力。
    public let latestReceipt: HostReceiptEvidence?
    public let operation: HostOperationState
    public let installationID: UUID?

    public init(
        host: HostID,
        runtime: SharedRuntimeHealth,
        availability: HostAvailability,
        configuration: HostConfigurationState,
        writability: HostConfigWritability,
        authorization: HostAuthorizationState = .notRequired,
        activation: HostActivationEvidence,
        bindingActivations: [HostEventBindingID: HostActivationEvidence] = [:],
        latestReceipt: HostReceiptEvidence? = nil,
        operation: HostOperationState = .idle,
        installationID: UUID? = nil
    ) {
        self.host = host
        self.runtime = runtime
        self.availability = availability
        self.configuration = configuration
        self.writability = writability
        self.authorization = authorization
        self.activation = activation
        self.bindingActivations = bindingActivations
        self.latestReceipt = latestReceipt
        self.operation = operation
        self.installationID = installationID
    }

    public var descriptor: HostIntegrationDescriptor { host.descriptor }

    public func activation(for binding: HostCapabilityBinding) -> HostActivationEvidence {
        bindingActivations[binding.id] ?? activation
    }

    public static func disconnected(host: HostID) -> HostIntegrationSnapshot {
        HostIntegrationSnapshot(
            host: host, runtime: .ready, availability: .available,
            configuration: .notConfigured, writability: .writable, activation: .none)
    }

    #if DEBUG
    public static func connectedForTesting(host: HostID) -> HostIntegrationSnapshot {
        let id = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
        let firstNativeEvent = "UserPromptSubmit"
        let event = Event.taskStart
        let evidence = HostReceiptEvidence(
            installationID: id, nativeEvent: firstNativeEvent, event: event,
            timestamp: Date(timeIntervalSince1970: 1), playbackResult: .played)
        return HostIntegrationSnapshot(
            host: host, runtime: .ready, availability: .available,
            configuration: .configured, writability: .writable,
            activation: .observed(evidence),
            latestReceipt: evidence,
            installationID: id)
    }
    #endif
}

public enum HostReadinessSummary: Codable, Sendable, Equatable {
    case ready(supported: Int, total: Int)
    case awaitingActivation(supported: Int, total: Int)
    case legacy(supported: Int, total: Int)
    case notConnected(supported: Int, total: Int)
    case needsAttention(supported: Int, total: Int, reason: String)
}

public enum AudibilityCellState: String, Codable, Sendable, Equatable {
    case audible
    case muted
    case missingSound
    case notConnected
    case awaitingActivation
    case legacy
    case unsupported
    case degraded
}

public struct AudibilityCell: Identifiable, Codable, Sendable, Equatable {
    public var id: String { "\(host.rawValue):\(event.rawValue)" }
    public let host: HostID
    public let event: Event
    public let binding: HostCapabilityBinding
    public let state: AudibilityCellState
    public let detail: String?

    public var accessibilityLabel: String {
        let support: String
        switch binding.support {
        case .supported:
            support = "完整支持"
        case .partial:
            support = "部分支持"
        case .unsupported:
            support = "不支持"
        }
        let qualifier = binding.qualification.map { "，\($0.rawValue)" } ?? ""
        let connection: String
        let audibility: String
        switch state {
        case .audible:
            connection = "已连接"
            audibility = "可听"
        case .muted:
            connection = "已连接"
            audibility = "已静音"
        case .missingSound:
            connection = "已连接"
            audibility = "声音文件缺失"
        case .notConnected:
            connection = "未连接"
            audibility = "不可听"
        case .awaitingActivation:
            connection = "等待确认"
            audibility = "尚不可听"
        case .legacy:
            connection = "旧版连接"
            audibility = "可听，无真实回执"
        case .unsupported:
            connection = "不支持"
            audibility = "不可听"
        case .degraded:
            connection = "需要处理"
            audibility = "不可听"
        }
        let summary =
            "\(host.displayName)，\(event.displayName)\(qualifier)，\(support)，\(connection)，\(audibility)"
        return detail.map { "\(summary)，\($0)" } ?? summary
    }
}

public struct AudibilityEventRow: Identifiable, Codable, Sendable, Equatable {
    public var id: Event { event }
    public let event: Event
    public let cells: [AudibilityCell]
}

/// 把 adapter 能力、连接事实、声音包覆盖与静音状态组合成唯一可听事实源。
public struct AudibilityMatrix: Codable, Sendable, Equatable {
    public let rows: [AudibilityEventRow]
    private let summaries: [HostID: HostReadinessSummary]

    private init(rows: [AudibilityEventRow], summaries: [HostID: HostReadinessSummary]) {
        self.rows = rows
        self.summaries = summaries
    }

    public static func make(
        snapshots: [HostIntegrationSnapshot],
        capabilities: [HostID: [HostCapabilityBinding]],
        soundCoverage: [Event: Bool],
        enabledEvents: [Event: Bool]
    ) -> AudibilityMatrix {
        make(
            snapshots: snapshots,
            capabilities: capabilities,
            soundCoverageByHost: Dictionary(
                uniqueKeysWithValues: HostID.productVisibleCases.map { ($0, soundCoverage) }),
            enabledEventsByHost: Dictionary(
                uniqueKeysWithValues: HostID.productVisibleCases.map { ($0, enabledEvents) }))
    }

    /// surface-aware 入口。每个宿主格消费自己的 effective pack/事件开关；调用方不得先把
    /// 多个 surface 压成一份全局配置，否则矩阵会与真实播放链分叉。
    public static func make(
        snapshots: [HostIntegrationSnapshot],
        capabilities: [HostID: [HostCapabilityBinding]],
        soundCoverageByHost: [HostID: [Event: Bool]],
        enabledEventsByHost: [HostID: [Event: Bool]]
    ) -> AudibilityMatrix {
        let snapshotByHost = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.host, $0) })
        var summaries: [HostID: HostReadinessSummary] = [:]
        for host in HostID.productVisibleCases {
            let bindings = capabilities[host] ?? []
            let configuredSupported = bindings.filter(\.isAudibleCapability).count
            let legacySupported = bindings.filter {
                $0.isAudibleCapability && Event.legacyLifecycleCases.contains($0.event)
            }.count
            let supported =
                snapshotByHost[host]?.configuration == .legacyConnected
                ? legacySupported
                : configuredSupported
            summaries[host] = readinessSummary(
                snapshot: snapshotByHost[host], supported: supported, total: Event.allCases.count)
        }

        let rows = Event.allCases.map { event in
            AudibilityEventRow(
                event: event,
                cells: HostID.productVisibleCases.map { host in
                    let binding =
                        capabilities[host]?.first(where: { $0.event == event })
                        ?? HostCapabilityBinding(
                            host: host, event: event, nativeEvent: nil, support: .unsupported,
                            qualification: .undeclaredCapability)
                    let state = cellState(
                        binding: binding, snapshot: snapshotByHost[host],
                        hasSound: soundCoverageByHost[host]?[event] ?? false,
                        enabled: enabledEventsByHost[host]?[event] ?? true)
                    let detail =
                        state == .degraded
                            && snapshotByHost[host]?.configuration == .legacyConnected
                            && !Event.legacyLifecycleCases.contains(event)
                        ? "旧版连接未安装此事件，请升级连接"
                        : nil
                    return AudibilityCell(
                        host: host, event: event, binding: binding,
                        state: state,
                        detail: detail)
                })
        }
        return AudibilityMatrix(rows: rows, summaries: summaries)
    }

    public func cell(host: HostID, event: Event) -> AudibilityCell? {
        rows.first(where: { $0.event == event })?.cells.first(where: { $0.host == host })
    }

    public func summary(for host: HostID) -> HostReadinessSummary? {
        summaries[host]
    }

    private static func readinessSummary(
        snapshot: HostIntegrationSnapshot?, supported: Int, total: Int
    ) -> HostReadinessSummary {
        guard let snapshot else { return .notConnected(supported: supported, total: total) }
        if case .unavailable(let reason) = snapshot.runtime {
            return .needsAttention(supported: supported, total: total, reason: reason)
        }
        if case .damaged(let reason) = snapshot.runtime {
            return .needsAttention(supported: supported, total: total, reason: reason)
        }
        // 宿主尚未安装且用户也从未连接，是正常空态而不是 Claudio 故障。先按配置事实
        // 识别这一格，避免 availability 的“未检测到目录”把来源行染成 error。
        if case .notConfigured = snapshot.configuration,
            case .unavailable = snapshot.availability
        {
            return .notConnected(supported: supported, total: total)
        }
        if case .unavailable(let reason) = snapshot.availability {
            return .needsAttention(supported: supported, total: total, reason: reason)
        }
        if case .notWritable(let reason) = snapshot.writability {
            return .needsAttention(supported: supported, total: total, reason: reason)
        }
        switch snapshot.configuration {
        case .notConfigured:
            return .notConnected(supported: supported, total: total)
        case .legacyConnected:
            return .legacy(supported: supported, total: total)
        case .incomplete(let missing):
            return .needsAttention(
                supported: supported, total: total,
                reason: "缺少 hook：\(missing.joined(separator: ", "))")
        case .unreadable(let reason), .conflict(let reason):
            return .needsAttention(supported: supported, total: total, reason: reason)
        case .configured:
            switch snapshot.activation {
            case .observed:
                return .ready(supported: supported, total: total)
            case .none, .awaitingReceipt:
                return .awaitingActivation(supported: supported, total: total)
            }
        }
    }

    private static func cellState(
        binding: HostCapabilityBinding,
        snapshot: HostIntegrationSnapshot?,
        hasSound: Bool,
        enabled: Bool
    ) -> AudibilityCellState {
        guard binding.isAudibleCapability else { return .unsupported }
        guard let snapshot else { return .notConnected }
        guard snapshot.runtime == .ready else {
            return .degraded
        }
        // 与来源汇总同一顺序：不存在的宿主目录 + 没有配置只表示“未连接”。若已有
        // Claudio 配置却宿主不可用，才是需要处理的 degraded 状态。
        if case .notConfigured = snapshot.configuration,
            case .unavailable = snapshot.availability
        {
            return .notConnected
        }
        guard snapshot.availability == .available else { return .degraded }
        switch snapshot.configuration {
        case .notConfigured:
            return .notConnected
        case .legacyConnected:
            // 旧安装器只写 Event.legacyLifecycleCases。通用能力目录里的 taskStart 是现代
            // UserPromptSubmit 能力，不能因宿主总体是 legacyConnected 就被误报为可听/缺音。
            guard Event.legacyLifecycleCases.contains(binding.event) else {
                return .degraded
            }
            if !enabled { return .muted }
            return hasSound ? .legacy : .missingSound
        case .configured:
            guard case .observed = snapshot.activation(for: binding) else {
                return .awaitingActivation
            }
            if !enabled { return .muted }
            return hasSound ? .audible : .missingSound
        case .incomplete, .unreadable, .conflict:
            return .degraded
        }
    }
}
