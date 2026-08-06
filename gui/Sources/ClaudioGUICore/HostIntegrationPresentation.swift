import ClaudioCore
import Foundation

// MARK: - 声音来源行

/// 宿主行的语义状态。颜色只由视图把这些语义映射到 token；`ready` 不区分 5/5 与
/// Codex 的正常 4/5，因此不会把能力差异误画成故障警告。
public enum HostSourceRowStatus: Sendable, Equatable {
    case ready
    case awaitingActivation
    case legacy
    case notConnected
    case needsAttention
}

/// 菜单栏与 IntegrationsWindow 共用的一条声音来源呈现。
public struct HostSourceRowPresentation: Identifiable, Sendable, Equatable {
    public var id: HostID { host }
    public let host: HostID
    public let title: String
    public let readinessText: String
    public let detailText: String?
    public let status: HostSourceRowStatus

    public init(
        host: HostID,
        title: String,
        readinessText: String,
        detailText: String?,
        status: HostSourceRowStatus
    ) {
        self.host = host
        self.title = title
        self.readinessText = readinessText
        self.detailText = detailText
        self.status = status
    }

    /// 不依赖颜色或圆点：宿主、能力数、连接状态和必要限定语都进入同一句播报。
    public var accessibilityLabel: String {
        [title, readinessText, detailText].compactMap { $0 }.joined(separator: "，")
    }
}

/// 固定生成 Claude Code、Codex 两条等权来源行。宿主是否连接只改变行内状态，不改变行的存在。
public func hostSourceRowPresentations(
    from matrix: AudibilityMatrix
) -> [HostSourceRowPresentation] {
    HostID.allCases.map { host in
        let fallbackSupported = HostCapabilityCatalog.bindings(for: host)
            .filter(\.isAudibleCapability).count
        let summary = matrix.summary(for: host)
            ?? .notConnected(supported: fallbackSupported, total: Event.allCases.count)
        return hostSourceRowPresentation(host: host, summary: summary)
    }
}

private func hostSourceRowPresentation(
    host: HostID,
    summary: HostReadinessSummary
) -> HostSourceRowPresentation {
    let readinessText: String
    let detailText: String?
    let status: HostSourceRowStatus

    switch summary {
    case .ready(let supported, let total):
        readinessText = "\(supported)/\(total) 已就绪"
        detailText = host == .codex ? "执行中断暂无事件" : nil
        status = .ready

    case .awaitingActivation(let supported, let total):
        readinessText = "\(supported)/\(total) 已配置"
        detailText = host == .codex
            ? "在 Codex 输入 /hooks，确认后再提交一次提示词"
            : "请向 Claude Code 提交一次提示词以确认连接"
        status = .awaitingActivation

    case .legacy(let supported, let total):
        readinessText = "\(supported)/\(total) 旧版连接"
        detailText = host == .claudeCode
            ? "四个旧版事件可听；任务开始需升级"
            : "可听，但暂无真实回执"
        status = .legacy

    case .notConnected(let supported, let total):
        readinessText = "\(supported)/\(total) 未连接"
        detailText = nil
        status = .notConnected

    case .needsAttention(let supported, let total, let reason):
        readinessText = "\(supported)/\(total) 需要处理"
        detailText = reason
        status = .needsAttention
    }

    return HostSourceRowPresentation(
        host: host,
        title: host.displayName,
        readinessText: readinessText,
        detailText: detailText,
        status: status)
}

// MARK: - 5 × 2 可听能力矩阵

/// `.muted` 格仍需保留它由哪一条独立音量轴造成，否则恢复动作会把总音量为零
/// 误当成逐事件静音，并在没有改变可听事实时返回成功。
public enum HostCapabilityMuteReason: Sendable, Equatable, Hashable {
    case eventDisabled
    case masterVolumeZero
}

/// 一个矩阵格的可见与无障碍文案。所有内容均投影自 `AudibilityCell`，不在 GUI 重建能力映射。
public struct HostCapabilityCellPresentation: Identifiable, Sendable, Equatable {
    public var id: String { "\(host.rawValue):\(event.rawValue)" }
    public let host: HostID
    public let event: Event
    public let state: AudibilityCellState
    public let muteReason: HostCapabilityMuteReason?
    public let nativeEventText: String?
    public let qualificationText: String?
    public let statusText: String
    public let detailText: String?
    public let accessibilityLabel: String

    public init(
        cell: AudibilityCell,
        muteReason: HostCapabilityMuteReason? = nil
    ) {
        let resolvedMuteReason = cell.state == .muted
            ? (muteReason ?? .eventDisabled)
            : nil
        host = cell.host
        event = cell.event
        state = cell.state
        self.muteReason = resolvedMuteReason
        nativeEventText = cell.binding.nativeEvent
        qualificationText = cell.binding.qualification
        statusText = hostCapabilityStatusText(cell.state, muteReason: resolvedMuteReason)
        detailText = cell.detail
        accessibilityLabel = resolvedMuteReason == .masterVolumeZero
            ? "\(cell.accessibilityLabel)，原因：主音量为零"
            : cell.accessibilityLabel
    }

    /// Preview/test initializer for presentation-only state galleries and pure recovery tests.
    /// Production still uses ``init(cell:)`` so adapter truth remains the only live source.
    public init(
        host: HostID,
        event: Event,
        state: AudibilityCellState,
        muteReason: HostCapabilityMuteReason? = nil,
        nativeEventText: String? = nil,
        qualificationText: String? = nil,
        statusText: String? = nil,
        detailText: String? = nil,
        accessibilityLabel: String? = nil
    ) {
        let resolvedMuteReason = state == .muted
            ? (muteReason ?? .eventDisabled)
            : nil
        self.host = host
        self.event = event
        self.state = state
        self.muteReason = resolvedMuteReason
        self.nativeEventText = nativeEventText
        self.qualificationText = qualificationText
        self.statusText = statusText
            ?? hostCapabilityStatusText(state, muteReason: resolvedMuteReason)
        self.detailText = detailText
        self.accessibilityLabel = accessibilityLabel
            ?? "\(host.displayName)，\(event.displayName)，"
                + "\(hostCapabilityStatusText(state, muteReason: resolvedMuteReason))"
    }
}

/// 同一个声音语义下的两条宿主子行。最大 Dynamic Type 直接把该值渲染成一张事件卡。
public struct HostCapabilityEventRowPresentation: Identifiable, Sendable, Equatable {
    public var id: Event { event }
    public let event: Event
    public let title: String
    public let cells: [HostCapabilityCellPresentation]

    public init(
        event: Event,
        title: String,
        cells: [HostCapabilityCellPresentation]
    ) {
        self.event = event
        self.title = title
        self.cells = cells
    }
}

/// 标准布局按 `hostColumns` 画两列；最大字号复用相同 `rows`，只把每行重排成事件卡。
public struct HostCapabilityMatrixPresentation: Sendable, Equatable {
    public let hostColumns: [HostID]
    public let rows: [HostCapabilityEventRowPresentation]

    public init(
        hostColumns: [HostID],
        rows: [HostCapabilityEventRowPresentation]
    ) {
        self.hostColumns = hostColumns
        self.rows = rows
    }

    public func cell(host: HostID, event: Event) -> HostCapabilityCellPresentation? {
        rows.first(where: { $0.event == event })?.cells.first(where: { $0.host == host })
    }
}

/// 只投影 Core 已组合好的格子。若 adapter 删除一个映射，Core 的 fail-closed 格会原样进入 UI；
/// 此处不会按宿主或事件补写任何原生事件名。
public func hostCapabilityMatrixPresentation(
    from matrix: AudibilityMatrix,
    mutedReason: HostCapabilityMuteReason = .eventDisabled
) -> HostCapabilityMatrixPresentation {
    HostCapabilityMatrixPresentation(
        hostColumns: HostID.allCases,
        rows: matrix.rows.map { row in
            HostCapabilityEventRowPresentation(
                event: row.event,
                title: row.event.displayName,
                cells: HostID.allCases.compactMap { host in
                    row.cells.first(where: { $0.host == host }).map { cell in
                        HostCapabilityCellPresentation(
                            cell: cell,
                            muteReason: cell.state == .muted ? mutedReason : nil)
                    }
                })
        })
}

/// 菜单栏事件行中单枚宿主 Logo 的展示语义。颜色只是事实状态的冗余编码；鼠标帮助与事件编辑入口
/// 的 VoiceOver label 会同时给出完整文字状态。
public enum EventHostIndicatorState: Sendable, Equatable {
    case connected
    case legacy
    case awaitingActivation
    case notConnected
    case needsAttention
    case unsupported

    public var usesActiveColor: Bool {
        switch self {
        case .connected, .legacy: true
        case .awaitingActivation, .notConnected, .needsAttention, .unsupported: false
        }
    }

    public var statusText: String {
        switch self {
        case .connected: "已连接"
        case .legacy: "旧版连接"
        case .awaitingActivation: "待激活"
        case .notConnected: "未连接"
        case .needsAttention: "需处理"
        case .unsupported: "此事件不支持"
        }
    }
}

/// 一枚只读宿主 Logo 的完整呈现。`qualificationText` 仍来自 adapter，例如 Codex 的
/// “仅授权请求”；视图不推测或重建任何宿主能力。
public struct EventHostIndicatorPresentation: Identifiable, Sendable, Equatable {
    public var id: HostID { host }
    public let host: HostID
    public let state: EventHostIndicatorState
    public let qualificationText: String?

    public init(
        host: HostID,
        state: EventHostIndicatorState,
        qualificationText: String? = nil
    ) {
        self.host = host
        self.state = state
        self.qualificationText = qualificationText
    }

    public var helpText: String { state.statusText }

    public var accessibilityLabel: String {
        [host.displayName, state.statusText, qualificationText]
            .compactMap { $0 }
            .joined(separator: "，")
    }
}

/// 宿主标识资源名。穷举 `HostID` 且没有 `default`，新增 CLI 工具但未提供资源时会编译失败。
public func eventHostIndicatorAssetName(for host: HostID) -> String {
    switch host {
    case .claudeCode: "claude"
    case .codex: "codex"
    }
}

public struct EventHostIndicatorPalette: Sendable, Equatable {
    public let lightHex: String
    public let darkHex: String

    public init(lightHex: String, darkHex: String) {
        self.lightHex = lightHex
        self.darkHex = darkHex
    }
}

/// claudi0 的“已连接”状态色，不是宿主官方品牌色。与资源名映射一样穷举 `HostID`。
public func eventHostIndicatorPalette(for host: HostID) -> EventHostIndicatorPalette {
    switch host {
    case .claudeCode:
        EventHostIndicatorPalette(
            lightHex: ClaudioColorHex.claudeIndicatorLight,
            darkHex: ClaudioColorHex.claudeIndicatorDark)
    case .codex:
        EventHostIndicatorPalette(
            lightHex: ClaudioColorHex.codexIndicatorLight,
            darkHex: ClaudioColorHex.codexIndicatorDark)
    }
}

/// 从详情窗与菜单栏共用的矩阵投影一条事件行的只读 Logo。顺序唯一来自
/// `matrix.hostColumns`；缺失的行或格一律 fail closed 为“不支持”。
public func eventHostIndicatorPresentations(
    event: Event,
    matrix: HostCapabilityMatrixPresentation
) -> [EventHostIndicatorPresentation] {
    let row = matrix.rows.first(where: { $0.event == event })
    return matrix.hostColumns.map { host in
        guard let cell = row?.cells.first(where: { $0.host == host }) else {
            return EventHostIndicatorPresentation(host: host, state: .unsupported)
        }
        return EventHostIndicatorPresentation(
            host: host,
            state: eventHostIndicatorState(for: cell.state),
            qualificationText: cell.qualificationText)
    }
}

private func eventHostIndicatorState(
    for state: AudibilityCellState
) -> EventHostIndicatorState {
    switch state {
    case .audible, .muted, .missingSound: .connected
    case .legacy: .legacy
    case .notConnected: .notConnected
    case .awaitingActivation: .awaitingActivation
    case .unsupported: .unsupported
    case .degraded: .needsAttention
    }
}

/// 检查器的真实回执摘要。只投影快照中已经通过 installation ID 校验的 `.observed` 证据；
/// 不包含提示词、会话、路径、音频文件或 installation ID。
public func hostLatestReceiptText(
    snapshot: HostIntegrationSnapshot
) -> String? {
    guard let evidence = hostLatestReceiptEvidence(snapshot: snapshot) else { return nil }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let timestamp = formatter.string(from: evidence.timestamp)
    return "\(snapshot.host.displayName) · \(evidence.event.displayName) · \(timestamp) · "
        + hostHookPlaybackResultDisplayName(evidence.playbackResult)
}

/// 与 ``hostLatestReceiptText(snapshot:)`` 同一条已校验、完整的结构化 evidence。
/// retained window 用它判断新旧回执，避免用可见摘要的秒级字符串代替事实身份。
public func hostLatestReceiptEvidence(
    snapshot: HostIntegrationSnapshot
) -> HostReceiptEvidence? {
    snapshot.latestReceipt
}

/// 保留事件投影 API；事件身份仍来自完整 evidence，不反向解析摘要。
public func hostLatestReceiptEvent(
    snapshot: HostIntegrationSnapshot
) -> Event? {
    hostLatestReceiptEvidence(snapshot: snapshot)?.event
}

/// 真实回执只暴露脱敏后的播放结果；这个 exhaustive switch 保证 Core 增加结果时
/// GUI 不会默默把新状态绘成成功或空白。
public func hostHookPlaybackResultDisplayName(
    _ result: HostHookPlaybackResult
) -> String {
    switch result {
    case .played: "已播放"
    case .muted: "已静音"
    case .debounced: "防抖跳过"
    case .notReady: "声音未就绪"
    case .unsupportedEvent: "事件不支持"
    case .playbackFailed: "播放失败"
    }
}

private func hostCapabilityStatusText(
    _ state: AudibilityCellState,
    muteReason: HostCapabilityMuteReason? = nil
) -> String {
    switch state {
    case .audible: "可听"
    case .muted: muteReason == .masterVolumeZero ? "主音量为零" : "已静音"
    case .missingSound: "声音缺失"
    case .notConnected: "未连接"
    case .awaitingActivation: "等待确认"
    case .legacy: "旧版连接"
    case .unsupported: "不支持"
    case .degraded: "需要处理"
    }
}

// MARK: - Dynamic Type 重排

/// IntegrationsWindow 只需要区分是否已进入必须重排的最大辅助字号区间；SwiftUI 层负责把系统
/// `DynamicTypeSize` 归一化成这里的两档。
public enum IntegrationsWindowTypeSizeTier: Sendable, Equatable, CaseIterable {
    case standard
    case maximum
}

public enum IntegrationsWindowLayoutMode: Sendable, Equatable {
    case capabilityMatrix(eventRowCount: Int, hostColumnCount: Int)
    case eventCards(cardCount: Int, hostRowsPerCard: Int)
}

public struct IntegrationsWindowLayoutAdaptation: Sendable, Equatable {
    public let mode: IntegrationsWindowLayoutMode
    public let allowsHorizontalScrolling: Bool

    public init(mode: IntegrationsWindowLayoutMode, allowsHorizontalScrolling: Bool) {
        self.mode = mode
        self.allowsHorizontalScrolling = allowsHorizontalScrolling
    }
}

/// 最大字号只改变几何：五行变五张卡，每张仍消费同一行的两个真实宿主格；两个布局都不把
/// 横向滚动当作文字放不下时的退路。
public func integrationsWindowLayoutAdaptation(
    for tier: IntegrationsWindowTypeSizeTier,
    eventCount: Int = Event.allCases.count,
    hostCount: Int = HostID.allCases.count
) -> IntegrationsWindowLayoutAdaptation {
    let mode: IntegrationsWindowLayoutMode
    switch tier {
    case .standard:
        mode = .capabilityMatrix(eventRowCount: eventCount, hostColumnCount: hostCount)
    case .maximum:
        mode = .eventCards(cardCount: eventCount, hostRowsPerCard: hostCount)
    }
    return IntegrationsWindowLayoutAdaptation(mode: mode, allowsHorizontalScrolling: false)
}

// MARK: - IntegrationsWindow 专用焦点序

public enum IntegrationsWindowInspectorAction: Sendable, Hashable {
    case copyHooksCommand
    case redetect
    case connect(HostID)
    case repair(HostID)
    case disconnect(HostID)

    fileprivate var isDestructive: Bool {
        if case .disconnect = self { return true }
        return false
    }
}

/// 检查器动作完全由来源行状态投影。legacy 是“仍可听但没有当前代次真实回执”，因此不能与
/// ready 合并成只允许重探/断开；它必须提供显式升级，把旧 `claudio play` hooks 换成带回执连接。
public func integrationsInspectorActions(
    for row: HostSourceRowPresentation
) -> [IntegrationsWindowInspectorAction] {
    switch row.status {
    case .ready:
        return [.redetect, .disconnect(row.host)]
    case .legacy:
        return [.repair(row.host), .redetect, .disconnect(row.host)]
    case .awaitingActivation:
        if row.host == .codex {
            return [.copyHooksCommand, .redetect, .disconnect(row.host)]
        }
        return [.redetect, .disconnect(row.host)]
    case .notConnected:
        return [.connect(row.host)]
    case .needsAttention:
        return [.redetect, .repair(row.host), .disconnect(row.host)]
    }
}

/// 动作的稳定可见标题。`.repair` 在 legacy 上表达为产品动作“升级连接”，而真正损坏态仍叫
/// “修复”；两者继续复用同一个 manager connect seam。
public func integrationsInspectorActionTitle(
    _ action: IntegrationsWindowInspectorAction,
    hostStatus: HostSourceRowStatus?
) -> String {
    switch action {
    case .copyHooksCommand: "复制 /hooks"
    case .redetect: "重新检测"
    case .connect(let host): "连接 \(host.displayName)"
    case .repair(let host):
        hostStatus == .legacy ? "升级连接" : "修复 \(host.displayName) 连接"
    case .disconnect(let host): "断开 \(host.displayName)"
    }
}

public enum IntegrationsWindowFocusTarget: Sendable, Hashable {
    case hostCard(HostID)
    case capabilityCell(host: HostID, event: Event)
    case recoveryAction(IntegrationsRecoveryAction)
    case copyConfigurationPath(HostID)
    case dismissFeedback(revision: UInt64)
    case inspectorAction(IntegrationsWindowInspectorAction)
}

/// 详情窗当前真实渲染的矩阵、检查器动作与反馈关闭按钮。它与菜单栏面板的焦点模型分离，避免
/// retained window 的键盘环被 popover 的关闭/恢复规则污染。
public struct IntegrationsWindowFocusScope: Sendable, Equatable {
    public let matrix: HostCapabilityMatrixPresentation
    public let inspectorActions: [IntegrationsWindowInspectorAction]
    public let recoveryAction: IntegrationsRecoveryAction
    public let configurationPathHost: HostID?
    public let feedbackRevision: UInt64?

    public init(
        matrix: HostCapabilityMatrixPresentation,
        inspectorActions: [IntegrationsWindowInspectorAction],
        recoveryAction: IntegrationsRecoveryAction = .none,
        configurationPathHost: HostID? = nil,
        feedbackRevision: UInt64? = nil
    ) {
        self.matrix = matrix
        self.inspectorActions = inspectorActions
        self.recoveryAction = recoveryAction
        self.configurationPathHost = configurationPathHost
        self.feedbackRevision = feedbackRevision
    }
}

/// 从上到下遍历两张宿主摘要与矩阵，再进入检查器。即使调用者把断开动作夹在中间，函数也
/// 会把全部破坏性动作移到末尾；视图不能无意中让首焦点或普通 Tab 流先撞上断开。
public func integrationsWindowFocusOrder(
    _ scope: IntegrationsWindowFocusScope
) -> [IntegrationsWindowFocusTarget] {
    var order = HostID.allCases.map(IntegrationsWindowFocusTarget.hostCard)
    order.append(contentsOf: scope.matrix.rows.flatMap { row in
        row.cells.map {
            IntegrationsWindowFocusTarget.capabilityCell(host: $0.host, event: $0.event)
        }
    })
    if let host = scope.configurationPathHost {
        order.append(.copyConfigurationPath(host))
    }
    if let revision = scope.feedbackRevision {
        order.append(.dismissFeedback(revision: revision))
    }
    if scope.recoveryAction.title != nil {
        order.append(.recoveryAction(scope.recoveryAction))
    }
    order.append(contentsOf: scope.inspectorActions.filter { !$0.isDestructive }.map {
        .inspectorAction($0)
    })
    order.append(contentsOf: scope.inspectorActions.filter(\.isDestructive).map {
        .inspectorAction($0)
    })
    return order
}

// MARK: - 短暂、可关闭反馈

/// 详情窗反馈的固定可见时间。计时由 retained window 的视图生命周期驱动，模型只决定边界。
public let integrationsFeedbackLifetime: TimeInterval = 5

public enum IntegrationsFeedbackKind: Sendable, Equatable {
    case success
    case information
    case failure
}

public struct IntegrationsFeedback: Identifiable, Sendable, Equatable {
    public var id: UInt64 { revision }
    public let revision: UInt64
    public let host: HostID
    public let kind: IntegrationsFeedbackKind
    public let message: String
    public let accessibilityAnnouncement: String?
    public let expiresAt: Date

    public var isDismissible: Bool { true }
    public var accessibilityLabel: String {
        accessibilityAnnouncement ?? "\(host.displayName)，\(message)"
    }

    public init(
        revision: UInt64,
        host: HostID,
        kind: IntegrationsFeedbackKind,
        message: String,
        accessibilityAnnouncement: String? = nil,
        expiresAt: Date
    ) {
        self.revision = revision
        self.host = host
        self.kind = kind
        self.message = message
        self.accessibilityAnnouncement = accessibilityAnnouncement
        self.expiresAt = expiresAt
    }
}

/// 一次状态刷新可能同时产生多个独立宿主结果。请求先不分配 revision/过期时间；只有真正
/// 成为当前 banner 时才分配，确保排队中的 VoiceOver 句不会与上一条共用去重代次，也不会
/// 在尚未显示时提前过期。
public struct IntegrationsFeedbackRequest: Sendable, Equatable {
    public let host: HostID
    public let kind: IntegrationsFeedbackKind
    public let message: String
    public let accessibilityAnnouncement: String?

    public init(
        host: HostID,
        kind: IntegrationsFeedbackKind,
        message: String,
        accessibilityAnnouncement: String? = nil
    ) {
        self.host = host
        self.kind = kind
        self.message = message
        self.accessibilityAnnouncement = accessibilityAnnouncement
    }
}

/// 短暂 banner 的可见文案保持简短，但主动 VoiceOver 播报必须携带足够上下文，避免
/// “已重新检测”或“收到回执”在脱离视觉位置后成为无主语、无事件的提示。宿主状态与事件限定
/// 只消费共享 presentation；特别是 Codex `PermissionRequest` 的“仅授权请求”由 matrix cell
/// 原样进入播报，不在窗口 model 另写一份宿主映射。
public func integrationsStateChangeAccessibilityLabel(
    message: String,
    hostRow: HostSourceRowPresentation,
    capabilityCells: [HostCapabilityCellPresentation]
) -> String {
    var clauses = [hostRow.accessibilityLabel]
    clauses.append(
        contentsOf: capabilityCells
            .filter { $0.host == hostRow.host }
            .map(\.accessibilityLabel))
    if !message.isEmpty { clauses.append(message) }
    return clauses.joined(separator: "。")
}

public enum IntegrationsFeedbackTransition: Sendable, Equatable {
    /// 普通模式只改变透明度，不造成布局位移。
    case opacity
    /// Reduce Motion 下立即更新，完全取消动画。
    case immediate
}

public func integrationsFeedbackTransition(
    reduceMotionEnabled: Bool
) -> IntegrationsFeedbackTransition {
    reduceMotionEnabled ? .immediate : .opacity
}

/// 显式时钟的纯状态机：测试与 UI 都不需要启动后台 timer；视图在自己的任务中按 `expiresAt`
/// 调用 `expire(at:)`。代次保护避免旧 banner 的延迟关闭事件误删后来出现的新结果。
public struct IntegrationsFeedbackModel: Sendable, Equatable {
    public private(set) var current: IntegrationsFeedback?
    private var nextRevision: UInt64
    private var pending: [IntegrationsFeedbackRequest]

    public init() {
        current = nil
        nextRevision = 1
        pending = []
    }

    @discardableResult
    public mutating func present(
        host: HostID,
        kind: IntegrationsFeedbackKind,
        message: String,
        accessibilityAnnouncement: String? = nil,
        now: Date
    ) -> UInt64 {
        presentSequence(
            [IntegrationsFeedbackRequest(
                host: host,
                kind: kind,
                message: message,
                accessibilityAnnouncement: accessibilityAnnouncement)],
            now: now)!
    }

    /// 用稳定输入顺序逐条呈现同一次刷新产生的反馈。第一条立即可见，其余条目只在前一条
    /// 关闭或到期后激活；每次激活都获得自己的 revision 与完整生命周期。
    @discardableResult
    public mutating func presentSequence(
        _ requests: [IntegrationsFeedbackRequest],
        now: Date
    ) -> UInt64? {
        guard let first = requests.first else { return nil }
        pending = Array(requests.dropFirst())
        return activate(first, now: now)
    }

    private mutating func activate(
        _ request: IntegrationsFeedbackRequest,
        now: Date
    ) -> UInt64 {
        let revision = nextRevision
        nextRevision &+= 1
        current = IntegrationsFeedback(
            revision: revision,
            host: request.host,
            kind: request.kind,
            message: request.message,
            accessibilityAnnouncement: request.accessibilityAnnouncement,
            expiresAt: now.addingTimeInterval(integrationsFeedbackLifetime))
        return revision
    }

    private mutating func advance(at now: Date) {
        guard !pending.isEmpty else {
            current = nil
            return
        }
        let next = pending.removeFirst()
        _ = activate(next, now: now)
    }

    public func activeFeedback(at now: Date) -> IntegrationsFeedback? {
        guard let current, now < current.expiresAt else { return nil }
        return current
    }

    public mutating func expire(at now: Date) {
        guard let current, now >= current.expiresAt else { return }
        advance(at: now)
    }

    public mutating func dismiss(revision: UInt64, now: Date = Date()) {
        guard current?.revision == revision else { return }
        advance(at: now)
    }
}

/// IntegrationsWindow 主动播报反馈的去重器。`nil`（关闭/到期）永远不产生播报，也不会重置
/// 已消费代次；只有一个从未播过的新 revision 才返回完整的宿主限定句。
public struct IntegrationsFeedbackAnnouncementModel: Sendable, Equatable {
    private var lastAnnouncedRevision: UInt64?

    public init() {
        lastAnnouncedRevision = nil
    }

    public mutating func consume(_ feedback: IntegrationsFeedback?) -> String? {
        guard let feedback, feedback.revision != lastAnnouncedRevision else { return nil }
        lastAnnouncedRevision = feedback.revision
        return feedback.accessibilityLabel
    }
}

// MARK: - 当前操作状态

/// 顶部宿主卡在一个真实异步动作进行中显示的状态。宿主与可见/无障碍文案同值返回，View 不再
/// 根据按钮标题猜“这是谁的哪个操作”。
public struct IntegrationsInFlightPresentation: Sendable, Equatable {
    public let action: IntegrationsWindowInspectorAction
    public let host: HostID
    public let statusText: String
    public let accessibilityLabel: String

    public init(
        action: IntegrationsWindowInspectorAction,
        host: HostID,
        statusText: String,
        accessibilityLabel: String
    ) {
        self.action = action
        self.host = host
        self.statusText = statusText
        self.accessibilityLabel = accessibilityLabel
    }
}

/// `copy /hooks` 是同步剪贴板动作，不进入 in-flight；其余动作都给目标宿主卡一个明确文字态。
/// legacy repair 使用“升级中”，普通 repair 使用“修复中”。
public func integrationsInFlightPresentation(
    action: IntegrationsWindowInspectorAction,
    selectedHost: HostID,
    hostStatus: HostSourceRowStatus?
) -> IntegrationsInFlightPresentation? {
    let host: HostID
    let statusText: String
    switch action {
    case .copyHooksCommand:
        return nil
    case .redetect:
        host = selectedHost
        statusText = "重新检测中"
    case .connect(let target):
        host = target
        statusText = "连接中"
    case .repair(let target):
        host = target
        statusText = hostStatus == .legacy ? "升级中" : "修复中"
    case .disconnect(let target):
        host = target
        statusText = "断开中"
    }
    return IntegrationsInFlightPresentation(
        action: action,
        host: host,
        statusText: statusText,
        accessibilityLabel: "\(host.displayName)，\(statusText)")
}
