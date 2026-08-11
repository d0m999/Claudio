import ClaudioCore
import ClaudioLocalization
import Foundation

/// GUI 两个表面一次性消费的 manager 快照。宿主连接事实与可听矩阵同代返回，避免窗口与
/// popover 在一次异步刷新中各自看到半套状态。
public struct HostIntegrationPresentationState: Sendable, Equatable {
    public let snapshots: [HostIntegrationSnapshot]
    public let matrix: AudibilityMatrix
    public let masterVolumeIsZero: Bool

    public init(
        snapshots: [HostIntegrationSnapshot],
        matrix: AudibilityMatrix,
        masterVolumeIsZero: Bool = false
    ) {
        self.snapshots = snapshots
        self.matrix = matrix
        self.masterVolumeIsZero = masterVolumeIsZero
    }
}

/// 连接动作的领域结果。可见反馈与新状态一起跨 actor 返回，MainActor 只负责发布。
public struct HostIntegrationMutationOutcome: Sendable, Equatable {
    public let state: HostIntegrationPresentationState
    public let feedbackKind: IntegrationsFeedbackKind
    public let feedbackText: IntegrationsFeedbackText
    public var feedbackMessage: String { feedbackText.resolve(language: .zhHans) }

    public init(
        state: HostIntegrationPresentationState,
        feedbackKind: IntegrationsFeedbackKind,
        feedbackMessage: String
    ) {
        self.init(
            state: state,
            feedbackKind: feedbackKind,
            feedbackText: .literal(feedbackMessage))
    }

    public init(
        state: HostIntegrationPresentationState,
        feedbackKind: IntegrationsFeedbackKind,
        feedbackText: IntegrationsFeedbackText
    ) {
        self.state = state
        self.feedbackKind = feedbackKind
        self.feedbackText = feedbackText
    }
}

public enum HostIntegrationManagerBridgeError: LocalizedError, Sendable, Equatable {
    case action(HostIntegrationActionError)
    case unsupportedAction

    public var errorDescription: String? {
        switch self {
        case .action(let error): error.description
        case .unsupportedAction: "这个动作不应交给宿主连接管理器。"
        }
    }
}

/// `HostIntegrationManager` 到 GUI 的唯一桥。它不持有任何 SwiftUI/AppKit 类型；所有磁盘路径与
/// 音频环境均可注入，因此测试可以只在临时目录内运行。
public actor HostIntegrationManagerBridge {
    private let manager: HostIntegrationManager
    private let configFile: URL
    private let audioEnvironment: AudioImportEnvironment

    public init(
        manager: HostIntegrationManager,
        configFile: URL,
        audioEnvironment: AudioImportEnvironment
    ) {
        self.manager = manager
        self.configFile = configFile
        self.audioEnvironment = audioEnvironment
    }

    /// 首启只自举共享 runtime，再 inspect 两个宿主；绝不隐式调用任何 adapter 的 `connect`。
    public func bootstrapSharedRuntime() async -> HostIntegrationPresentationState {
        let snapshots = await manager.bootstrapSharedRuntime()
        return await presentationState(snapshots: snapshots)
    }

    public func refresh() async -> HostIntegrationPresentationState {
        let snapshots = await manager.refresh()
        return await presentationState(snapshots: snapshots)
    }

    public func perform(
        _ action: IntegrationsWindowInspectorAction
    ) async throws -> HostIntegrationMutationOutcome {
        let result: Result<HostIntegrationSnapshot, HostIntegrationActionError>

        switch action {
        case .connect(let requestedHost):
            result = await manager.connect(requestedHost)
        case .repair(let requestedHost):
            result = await manager.connect(requestedHost)
        case .disconnect(let requestedHost):
            result = await manager.disconnect(requestedHost)
        case .copyHooksCommand, .redetect:
            throw HostIntegrationManagerBridgeError.unsupportedAction
        }

        if case .failure(let error) = result {
            // Manager 已经把失败侧重新 inspect；再刷新两侧，把失败发生期间另一宿主的新回执也
            // 一并带回 MainActor。失败是可呈现 outcome，不是“保留旧 content”的异常捷径。
            let state = await refresh()
            return HostIntegrationMutationOutcome(
                state: state,
                feedbackKind: .failure,
                feedbackText: .localized(
                    key: .feedbackOperationFailed,
                    arguments: [error.description]))
        }

        // 动作只写一侧，但完成后刷新两侧，使另一宿主的新回执或外部配置变化不会被冻结。
        let state = await refresh()
        return HostIntegrationMutationOutcome(
            state: state,
            feedbackKind: action.isDisconnect ? .information : .success,
            feedbackText: mutationFeedbackText(action: action, state: state))
    }

    private func presentationState(
        snapshots: [HostIntegrationSnapshot]
    ) async -> HostIntegrationPresentationState {
        let capabilities = await manager.capabilities()
        let config = loadPanelConfig(from: configFile).resolvedConfig
        let eventRows = packCoverage(
            packID: config.selectedPack,
            config: config,
            environment: audioEnvironment)
        let coverage = Dictionary(uniqueKeysWithValues: eventRows.map { row in
            let hasSound: Bool
            if case .present = row.coverage {
                hasSound = true
            } else {
                hasSound = false
            }
            return (row.event, hasSound)
        })
        // `master_volume == 0` 表示总输出无声，与逐事件 enabled 正交；它不是另一颗“全局静音”
        // 控件。把两轴在进入唯一矩阵前合成；`AudibilityMatrix` 仍先判 unsupported，因此 Codex
        // StopFailure 不会被误画成 muted。
        let masterVolumeAllowsAudio = config.masterVolume > 0
        let enabled = Dictionary(
            uniqueKeysWithValues: eventRows.map {
                ($0.event, $0.enabled && masterVolumeAllowsAudio)
            })
        let matrix = AudibilityMatrix.make(
            snapshots: snapshots,
            capabilities: capabilities,
            soundCoverage: coverage,
            enabledEvents: enabled)
        return HostIntegrationPresentationState(
            snapshots: snapshots,
            matrix: matrix,
            masterVolumeIsZero: !masterVolumeAllowsAudio)
    }
}

/// 动作反馈必须描述刷新后的事实，不是连接按钮在点击前预设的路径。
/// 特别是 Codex：如果当前 installation 已经收到真实回执，不能还说“等待确认”。
private func mutationFeedbackText(
    action: IntegrationsWindowInspectorAction,
    state: HostIntegrationPresentationState
) -> IntegrationsFeedbackText {
    guard let host = action.host else {
        return .localized(key: .feedbackHostStateUpdated, arguments: [])
    }
    if action.isDisconnect {
        return .localized(key: .feedbackDisconnected, arguments: [host.displayName])
    }

    let snapshot = state.snapshots.first { $0.host == host }
    if host == .codex {
        if let snapshot, case .observed = snapshot.activation {
            return .localized(key: .feedbackConnectedReceipt, arguments: [host.displayName])
        }
        return .localized(key: .feedbackAwaitingConfirmation, arguments: [host.displayName])
    }

    if let snapshot, case .observed = snapshot.activation {
        return .localized(key: .feedbackConnectedReceipt, arguments: [host.displayName])
    }
    if case .repair = action {
        return .localized(key: .feedbackRepairedWaiting, arguments: [host.displayName])
    }
    return .localized(key: .feedbackConfiguredWaiting, arguments: [host.displayName])
}

private extension IntegrationsWindowInspectorAction {
    var host: HostID? {
        switch self {
        case .connect(let host), .repair(let host), .disconnect(let host): host
        case .copyHooksCommand, .redetect: nil
        }
    }

    var isDisconnect: Bool {
        if case .disconnect = self { return true }
        return false
    }
}
