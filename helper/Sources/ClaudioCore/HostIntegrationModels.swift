import Foundation

/// Claudio 可以连接的宿主。raw value 同时是 CLI 稳定 token。
public enum HostID: String, CaseIterable, Codable, Sendable, Hashable {
    case claudeCode = "claude-code"
    case codex = "codex"

    public var displayName: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        }
    }
}

/// 宿主对一个 Claudio 声音语义的原生支持程度。
public enum HostCapabilitySupport: String, Codable, Sendable, Equatable {
    case supported
    case partial
    case unsupported
}

/// 一个宿主原生事件与声音包语义之间的唯一映射。
public struct HostCapabilityBinding: Codable, Sendable, Equatable, Hashable {
    public let host: HostID
    public let event: Event
    public let nativeEvent: String?
    public let support: HostCapabilitySupport
    public let qualification: String?

    public init(
        host: HostID,
        event: Event,
        nativeEvent: String?,
        support: HostCapabilitySupport,
        qualification: String? = nil
    ) {
        self.host = host
        self.event = event
        self.nativeEvent = nativeEvent
        self.support = support
        self.qualification = qualification
    }

    public var isAudibleCapability: Bool {
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
                    host: host, event: .stop, nativeEvent: "Stop", support: .supported),
                HostCapabilityBinding(
                    host: host, event: .stopFailure, nativeEvent: nil,
                    support: .unsupported, qualification: "Codex 暂无执行中断事件"),
                HostCapabilityBinding(
                    host: host, event: .notification, nativeEvent: "PermissionRequest",
                    support: .partial, qualification: "仅授权请求"),
                HostCapabilityBinding(
                    host: host, event: .subagentStop, nativeEvent: "SubagentStop",
                    support: .supported),
            ]
        }
    }

    public static func semanticEvent(host: HostID, nativeEvent: String) -> Event? {
        bindings(for: host).first {
            $0.nativeEvent == nativeEvent && $0.support != .unsupported
        }?.event
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

public struct HostReceiptEvidence: Codable, Sendable, Equatable {
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
    public let activation: HostActivationEvidence
    public let operation: HostOperationState
    public let installationID: UUID?

    public init(
        host: HostID,
        runtime: SharedRuntimeHealth,
        availability: HostAvailability,
        configuration: HostConfigurationState,
        writability: HostConfigWritability,
        activation: HostActivationEvidence,
        operation: HostOperationState = .idle,
        installationID: UUID? = nil
    ) {
        self.host = host
        self.runtime = runtime
        self.availability = availability
        self.configuration = configuration
        self.writability = writability
        self.activation = activation
        self.operation = operation
        self.installationID = installationID
    }

    public static func disconnected(host: HostID) -> HostIntegrationSnapshot {
        HostIntegrationSnapshot(
            host: host, runtime: .ready, availability: .available,
            configuration: .notConfigured, writability: .writable, activation: .none)
    }

    #if DEBUG
    public static func connectedForTesting(host: HostID) -> HostIntegrationSnapshot {
        let id = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
        let firstNativeEvent = HostCapabilityCatalog.bindings(for: host)
            .compactMap(\.nativeEvent).first ?? "Stop"
        let event = HostCapabilityCatalog.semanticEvent(host: host, nativeEvent: firstNativeEvent)
            ?? .stop
        return HostIntegrationSnapshot(
            host: host, runtime: .ready, availability: .available,
            configuration: .configured, writability: .writable,
            activation: .observed(
                HostReceiptEvidence(
                    installationID: id, nativeEvent: firstNativeEvent, event: event,
                    timestamp: Date(timeIntervalSince1970: 1), playbackResult: .played)),
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
        let nativeEvent = binding.nativeEvent.map { "原生事件 \($0)" } ?? "无原生事件"
        let support: String
        switch binding.support {
        case .supported:
            support = "完整支持"
        case .partial:
            support = "部分支持"
        case .unsupported:
            support = "不支持"
        }
        let qualifier = binding.qualification.map { "，\($0)" } ?? ""
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
        return "\(host.displayName)，\(event.displayName)，\(nativeEvent)\(qualifier)，\(support)，\(connection)，\(audibility)"
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
        let snapshotByHost = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.host, $0) })
        var summaries: [HostID: HostReadinessSummary] = [:]
        for host in HostID.allCases {
            let bindings = capabilities[host] ?? []
            let supported = bindings.filter(\.isAudibleCapability).count
            summaries[host] = readinessSummary(
                snapshot: snapshotByHost[host], supported: supported, total: Event.allCases.count)
        }

        let rows = Event.allCases.map { event in
            AudibilityEventRow(
                event: event,
                cells: HostID.allCases.map { host in
                    let binding = capabilities[host]?.first(where: { $0.event == event })
                        ?? HostCapabilityBinding(
                            host: host, event: event, nativeEvent: nil, support: .unsupported,
                            qualification: "此宿主未声明该能力")
                    return AudibilityCell(
                        host: host, event: event, binding: binding,
                        state: cellState(
                            binding: binding, snapshot: snapshotByHost[host],
                            hasSound: soundCoverage[event] ?? false,
                            enabled: enabledEvents[event] ?? true),
                        detail: nil)
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
            if !enabled { return .muted }
            return hasSound ? .legacy : .missingSound
        case .configured:
            guard case .observed = snapshot.activation else { return .awaitingActivation }
            if !enabled { return .muted }
            return hasSound ? .audible : .missingSound
        case .incomplete, .unreadable, .conflict:
            return .degraded
        }
    }
}
