import ClaudioCore
import ClaudioLocalization
import Foundation

// MARK: - 声音来源行

/// 宿主行的语义状态。颜色只由视图把这些语义映射到 token；`ready` 不区分 5/5 与
/// Codex 的正常 4/5，因此不会把能力差异误画成故障警告。
public enum HostSourceRowStatus: Sendable, Equatable {
    case ready
    case awaitingActivation
    case legacy
    case notConnected
    case unavailable
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
    public let accessibilityLabel: String
    public let supportedCount: Int?
    public let totalCount: Int?

    public init(
        host: HostID,
        title: String,
        readinessText: String,
        detailText: String?,
        status: HostSourceRowStatus,
        accessibilityLabel: String? = nil,
        supportedCount: Int? = nil,
        totalCount: Int? = nil
    ) {
        self.host = host
        self.title = title
        self.readinessText = readinessText
        self.detailText = detailText
        self.status = status
        self.accessibilityLabel =
            accessibilityLabel
            ?? [title, readinessText, detailText].compactMap { $0 }.joined(separator: "，")
        self.supportedCount = supportedCount
        self.totalCount = totalCount
    }
}

/// IntegrationsWindow 的 Product → Surface 分组。产品只负责分组，选择、能力和回执仍以
/// `HostID` / `HostSurfaceID` 为粒度。
public struct HostSourceProductGroupPresentation: Identifiable, Sendable, Equatable {
    public var id: HostProductID { product }
    public let product: HostProductID
    public let title: String
    public let surfaces: [HostSourceRowPresentation]

    public init(
        product: HostProductID,
        title: String,
        surfaces: [HostSourceRowPresentation]
    ) {
        self.product = product
        self.title = title
        self.surfaces = surfaces
    }
}

/// Product → Surface 的唯一视觉顺序。正常产品 registry、产品分组、矩阵列、初始选择和
/// 键盘遍历都必须消费这里的呈现顺序，不能分别推导或把诊断 identity 混入普通 UI。
public func hostSurfacePresentationOrder(
    hosts: [HostID] = HostID.productVisibleCases
) -> [HostID] {
    HostProductID.allCases.flatMap { product in
        hosts.filter { $0.descriptor.product == product }
    }
}

public func hostSurfacePresentationOrder(
    from rows: [HostSourceRowPresentation]
) -> [HostID] {
    hostSurfacePresentationOrder(hosts: rows.map(\.host))
}

public func hostSourceProductGroups(
    from rows: [HostSourceRowPresentation]
) -> [HostSourceProductGroupPresentation] {
    HostProductID.allCases.compactMap { product in
        let surfaces: [HostSourceRowPresentation] = hostSurfacePresentationOrder(from: rows)
            .compactMap { host in
                guard host.descriptor.product == product else { return nil }
                return rows.first(where: { $0.host == host })
            }
        guard !surfaces.isEmpty else { return nil }
        return HostSourceProductGroupPresentation(
            product: product,
            title: product.displayName,
            surfaces: surfaces)
    }
}

/// 按产品可见 registry 生成所有已出货来源行。宿主是否连接只改变行内状态，不改变行的存在。
public func hostSourceRowPresentations(
    from matrix: AudibilityMatrix
) -> [HostSourceRowPresentation] {
    HostID.productVisibleCases.map { host in
        let fallbackSupported = HostCapabilityCatalog.bindings(for: host)
            .filter(\.isAudibleCapability).count
        let summary =
            matrix.summary(for: host)
            ?? .notConnected(supported: fallbackSupported, total: Event.allCases.count)
        return hostSourceRowPresentation(host: host, summary: summary)
    }
}

private func hostSourceRowPresentation(
    host: HostID,
    summary: HostReadinessSummary
) -> HostSourceRowPresentation {
    if host.descriptor.mechanism == .accessibilityBeta {
        return HostSourceRowPresentation(
            host: host,
            title: host.displayName,
            readinessText: "0/\(Event.allCases.count) 暂不可用",
            detailText: "GUI-only Beta 候选；Accessibility 观察器与权限流程尚未实现",
            status: .unavailable,
            supportedCount: 0,
            totalCount: Event.allCases.count)
    }
    let readinessText: String
    let detailText: String?
    let status: HostSourceRowStatus
    var supportedCount: Int?
    var totalCount: Int?

    switch summary {
    case .ready(let supported, let total):
        supportedCount = supported
        totalCount = total
        readinessText = "\(supported)/\(total) 已就绪"
        switch host {
        case .claudeCode: detailText = nil
        case .codex: detailText = "执行中断暂无事件"
        case .workBuddy: detailText = "当前版本已实现 2/5；其余能力尚未启用"
        case .chatGPTDesktopAX, .claudeDesktopAX: detailText = nil
        }
        status = .ready

    case .awaitingActivation(let supported, let total):
        supportedCount = supported
        totalCount = total
        readinessText = "\(supported)/\(total) 已配置"
        switch host {
        case .claudeCode: detailText = "请向 Claude Code 提交一次提示词以确认连接"
        case .codex: detailText = "在 Codex 输入 /hooks，确认后再提交一次提示词"
        case .workBuddy: detailText = "请向 WorkBuddy 提交一次提示词以确认连接"
        case .chatGPTDesktopAX, .claudeDesktopAX: detailText = nil
        }
        status = .awaitingActivation

    case .legacy(let supported, let total):
        supportedCount = supported
        totalCount = total
        readinessText = "\(supported)/\(total) 旧版连接"
        switch host {
        case .claudeCode: detailText = "四个旧版事件可听；任务开始需升级"
        case .codex, .workBuddy: detailText = "可听，但暂无真实回执"
        case .chatGPTDesktopAX, .claudeDesktopAX: detailText = nil
        }
        status = .legacy

    case .notConnected(let supported, let total):
        supportedCount = supported
        totalCount = total
        readinessText = "\(supported)/\(total) 未连接"
        detailText = nil
        status = .notConnected

    case .needsAttention(let supported, let total, let reason):
        supportedCount = supported
        totalCount = total
        readinessText = "\(supported)/\(total) 需要处理"
        detailText = reason
        status = .needsAttention
    }

    return HostSourceRowPresentation(
        host: host,
        title: host.displayName,
        readinessText: readinessText,
        detailText: detailText,
        status: status,
        supportedCount: supportedCount,
        totalCount: totalCount)
}

// MARK: - 动态 5 × N 可听能力矩阵

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
        let resolvedMuteReason =
            cell.state == .muted
            ? (muteReason ?? .eventDisabled)
            : nil
        host = cell.host
        event = cell.event
        state = cell.state
        self.muteReason = resolvedMuteReason
        nativeEventText = cell.binding.nativeEvent
        qualificationText = cell.binding.qualification.map(defaultQualificationText)
        statusText = hostCapabilityStatusText(cell.state, muteReason: resolvedMuteReason)
        detailText = cell.detail
        let defaultLabel =
            cell.binding.qualification.map { qualification in
                cell.accessibilityLabel.replacingOccurrences(
                    of: qualification.rawValue,
                    with: defaultQualificationText(qualification))
            } ?? cell.accessibilityLabel
        accessibilityLabel =
            resolvedMuteReason == .masterVolumeZero
            ? "\(defaultLabel)，原因：主音量为零"
            : defaultLabel
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
        let resolvedMuteReason =
            state == .muted
            ? (muteReason ?? .eventDisabled)
            : nil
        self.host = host
        self.event = event
        self.state = state
        self.muteReason = resolvedMuteReason
        self.nativeEventText = nativeEventText
        self.qualificationText = qualificationText
        self.statusText =
            statusText
            ?? hostCapabilityStatusText(state, muteReason: resolvedMuteReason)
        self.detailText = detailText
        self.accessibilityLabel =
            accessibilityLabel
            ?? "\(host.displayName)，\(event.displayName)，"
            + "\(hostCapabilityStatusText(state, muteReason: resolvedMuteReason))"
    }
}

/// 同一个声音语义下的动态宿主子行。最大 Dynamic Type 直接把该值渲染成一张事件卡。
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

/// 标准布局按 `hostColumns` 画动态列；事件卡布局复用相同 `rows`，只改变几何。
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
    mutedReason: HostCapabilityMuteReason = .eventDisabled,
    hostOrder: [HostID]? = nil
) -> HostCapabilityMatrixPresentation {
    let orderedHosts = hostOrder ?? HostID.productVisibleCases
    return HostCapabilityMatrixPresentation(
        hostColumns: orderedHosts,
        rows: matrix.rows.map { row in
            HostCapabilityEventRowPresentation(
                event: row.event,
                title: row.event.displayName,
                cells: orderedHosts.compactMap { host in
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
    /// Short visual-only name for the event-row chip. Help and VoiceOver continue to resolve the
    /// full localized host name from ``host`` rather than exposing this compact label.
    public let compactDisplayName: String
    public let state: EventHostIndicatorState
    public let qualificationText: String?

    public init(
        host: HostID,
        state: EventHostIndicatorState,
        compactDisplayName: String? = nil,
        qualificationText: String? = nil
    ) {
        self.host = host
        self.compactDisplayName =
            compactDisplayName
            ?? eventHostIndicatorCompactDisplayName(for: host)
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

/// Compact names are a presentation projection, not host-capability logic. The exhaustive switch
/// ensures a newly supported host cannot silently inherit a misleading event-row label.
public func eventHostIndicatorCompactDisplayName(for host: HostID) -> String {
    switch host {
    case .claudeCode: "Claude"
    case .codex: "Codex"
    case .workBuddy: "Buddy"
    case .chatGPTDesktopAX: "ChatGPT"
    case .claudeDesktopAX: "Claude AX"
    }
}

/// 宿主标识资源名。穷举 `HostID` 且没有 `default`，新增 CLI 工具但未提供资源时会编译失败。
public func eventHostIndicatorAssetName(for host: HostID) -> String {
    switch host {
    case .claudeCode: "claude"
    case .codex: "codex"
    case .workBuddy: "workbuddy"
    case .chatGPTDesktopAX: "codex"
    case .claudeDesktopAX: "claude"
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
    case .workBuddy:
        EventHostIndicatorPalette(
            lightHex: ClaudioColorHex.workBuddyIndicatorLight,
            darkHex: ClaudioColorHex.workBuddyIndicatorDark)
    case .chatGPTDesktopAX:
        EventHostIndicatorPalette(
            lightHex: ClaudioColorHex.codexIndicatorLight,
            darkHex: ClaudioColorHex.codexIndicatorDark)
    case .claudeDesktopAX:
        EventHostIndicatorPalette(
            lightHex: ClaudioColorHex.claudeIndicatorLight,
            darkHex: ClaudioColorHex.claudeIndicatorDark)
    }
}

private func defaultQualificationText(_ qualification: HostCapabilityQualificationID) -> String {
    switch qualification {
    case .codexStopFailureUnavailable: "Codex 暂无执行中断事件"
    case .permissionRequestOnly: "仅授权请求"
    case .notificationMatchersOnly: "仅通知匹配器"
    case .interfaceSupportedNotImplemented: "接口支持，当前版本尚未实现"
    case .interfacePartiallySupportedNotImplemented: "接口部分支持，当前版本尚未实现"
    case .undeclaredCapability: "此宿主未声明该能力"
    case .accessibilityBetaUnavailable: "Accessibility Beta 候选尚未实现"
    }
}

/// 从详情窗与菜单栏共用的矩阵投影一条事件行的只读 Logo。顺序唯一来自
/// `matrix.hostColumns`；缺失的行或格一律 fail closed 为“不支持”。
public func eventHostIndicatorPresentations(
    event: Event,
    matrix: HostCapabilityMatrixPresentation
) -> [EventHostIndicatorPresentation] {
    let row = matrix.rows.first(where: { $0.event == event })
    return matrix.hostColumns.filter {
        $0.descriptor.mechanism == .nativeHooks
    }.map { host in
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

/// 矩阵的 118pt 事件列之外，每个 Host Surface 至少需要 156pt 才能同时容纳状态 glyph、
/// `UserPromptSubmit` 等原生事件和限定语。达不到时复用事件卡，不用横向滚动掩盖不可读列。
public let integrationsWindowEventColumnWidth = 118.0
public let integrationsWindowMinimumHostColumnWidth = 156.0

public func integrationsWindowLayoutAdaptation(
    for tier: IntegrationsWindowTypeSizeTier,
    availableWidth: Double,
    eventCount: Int = Event.allCases.count,
    hostCount: Int = HostID.productVisibleCases.count
) -> IntegrationsWindowLayoutAdaptation {
    let mode: IntegrationsWindowLayoutMode
    switch tier {
    case .standard:
        let requiredWidth =
            integrationsWindowEventColumnWidth
            + integrationsWindowMinimumHostColumnWidth * Double(hostCount)
        mode =
            availableWidth >= requiredWidth
            ? .capabilityMatrix(eventRowCount: eventCount, hostColumnCount: hostCount)
            : .eventCards(cardCount: eventCount, hostRowsPerCard: hostCount)
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
    case clearReceiptHistory(HostID)

    fileprivate var isDestructive: Bool {
        switch self {
        case .disconnect, .clearReceiptHistory: true
        default: false
        }
    }
}

/// 检查器动作完全由来源行状态投影。legacy 是“仍可听但没有当前代次真实回执”，因此不能与
/// ready 合并成只允许重探/断开；它必须提供显式升级，把旧 `claudio play` hooks 换成带回执连接。
public func integrationsInspectorActions(
    for row: HostSourceRowPresentation
) -> [IntegrationsWindowInspectorAction] {
    switch row.status {
    case .ready:
        return [.redetect, .clearReceiptHistory(row.host), .disconnect(row.host)]
    case .legacy:
        return [
            .repair(row.host), .redetect, .clearReceiptHistory(row.host), .disconnect(row.host),
        ]
    case .awaitingActivation:
        if row.host == .codex {
            return [
                .copyHooksCommand, .redetect, .clearReceiptHistory(row.host),
                .disconnect(row.host),
            ]
        }
        return [.redetect, .clearReceiptHistory(row.host), .disconnect(row.host)]
    case .notConnected:
        return [.connect(row.host), .clearReceiptHistory(row.host)]
    case .unavailable:
        return []
    case .needsAttention:
        return [
            .redetect, .repair(row.host), .clearReceiptHistory(row.host), .disconnect(row.host),
        ]
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
    case .clearReceiptHistory(let host): "清除 \(host.displayName) 回执历史"
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
    public let hostOrder: [HostID]
    public let inspectorActions: [IntegrationsWindowInspectorAction]
    public let recoveryAction: IntegrationsRecoveryAction
    public let configurationPathHost: HostID?
    public let feedbackRevision: UInt64?

    public init(
        matrix: HostCapabilityMatrixPresentation,
        hostOrder: [HostID]? = nil,
        inspectorActions: [IntegrationsWindowInspectorAction],
        recoveryAction: IntegrationsRecoveryAction = .none,
        configurationPathHost: HostID? = nil,
        feedbackRevision: UInt64? = nil
    ) {
        self.matrix = matrix
        self.hostOrder = hostOrder ?? matrix.hostColumns
        self.inspectorActions = inspectorActions
        self.recoveryAction = recoveryAction
        self.configurationPathHost = configurationPathHost
        self.feedbackRevision = feedbackRevision
    }
}

/// 从上到下按 Product → Surface 遍历来源摘要与矩阵，再进入检查器。即使调用者把断开动作
/// 夹在中间，函数也会把全部破坏性动作移到末尾；普通 Tab 流不能先撞上断开。
public func integrationsWindowFocusOrder(
    _ scope: IntegrationsWindowFocusScope
) -> [IntegrationsWindowFocusTarget] {
    let declaredHosts = scope.hostOrder.filter { scope.matrix.hostColumns.contains($0) }
    let remainingHosts = scope.matrix.hostColumns.filter { !declaredHosts.contains($0) }
    let orderedHosts = declaredHosts + remainingHosts
    var order = orderedHosts.map(IntegrationsWindowFocusTarget.hostCard)
    order.append(
        contentsOf: scope.matrix.rows.flatMap { row in
            orderedHosts.compactMap { host in
                row.cells.first(where: { $0.host == host }).map {
                    IntegrationsWindowFocusTarget.capabilityCell(host: $0.host, event: $0.event)
                }
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
    order.append(
        contentsOf: scope.inspectorActions.filter { !$0.isDestructive }.map {
            .inspectorAction($0)
        })
    order.append(
        contentsOf: scope.inspectorActions.filter(\.isDestructive).map {
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

/// Semantic copy for a short-lived banner. Keeping the key and arguments instead of a rendered
/// string lets retained windows re-project an already-visible feedback item when the interface
/// language changes; literal text is reserved for external/domain error data.
public indirect enum IntegrationsFeedbackText: Sendable, Equatable {
    case localized(key: ClaudioL10nKey, arguments: [String])
    case literal(String)
    case stateChange(
        message: IntegrationsFeedbackText,
        hostRow: HostSourceRowPresentation,
        capabilityCells: [HostCapabilityCellPresentation])

    public func resolve(language: ClaudioAppLanguage) -> String {
        switch self {
        case .localized(let key, let arguments):
            return ClaudioL10n(language: language).format(key, arguments: arguments)
        case .literal(let value):
            return value
        case .stateChange(let message, let hostRow, let capabilityCells):
            let localizedRow = localizedHostSourceRow(hostRow, language: language)
            let localizedCells = capabilityCells.map {
                localizedCapabilityCell($0, language: language)
            }
            return integrationsStateChangeAccessibilityLabel(
                message: message.resolve(language: language),
                hostRow: localizedRow,
                capabilityCells: localizedCells)
        }
    }
}

public struct IntegrationsFeedback: Identifiable, Sendable, Equatable {
    public var id: UInt64 { revision }
    public let revision: UInt64
    public let host: HostID
    public let kind: IntegrationsFeedbackKind
    public let text: IntegrationsFeedbackText
    public let accessibilityText: IntegrationsFeedbackText?
    public let expiresAt: Date

    public var isDismissible: Bool { true }
    public var message: String { text.resolve(language: .zhHans) }
    public func message(language: ClaudioAppLanguage) -> String {
        text.resolve(language: language)
    }
    public var accessibilityAnnouncement: String? {
        accessibilityText?.resolve(language: .zhHans)
    }
    public func localizedAccessibilityLabel(language: ClaudioAppLanguage) -> String {
        let message = text.resolve(language: language)
        let announcement = accessibilityText?.resolve(language: language)
        return announcement ?? "\(host.displayName)\(language == .english ? ", " : "，")\(message)"
    }
    public var accessibilityLabel: String {
        localizedAccessibilityLabel(language: .zhHans)
    }

    public init(
        revision: UInt64,
        host: HostID,
        kind: IntegrationsFeedbackKind,
        message: String,
        accessibilityAnnouncement: String? = nil,
        expiresAt: Date
    ) {
        self.init(
            revision: revision,
            host: host,
            kind: kind,
            text: .literal(message),
            accessibilityText: accessibilityAnnouncement.map(IntegrationsFeedbackText.literal),
            expiresAt: expiresAt)
    }

    public init(
        revision: UInt64,
        host: HostID,
        kind: IntegrationsFeedbackKind,
        text: IntegrationsFeedbackText,
        accessibilityText: IntegrationsFeedbackText? = nil,
        expiresAt: Date
    ) {
        self.revision = revision
        self.host = host
        self.kind = kind
        self.text = text
        self.accessibilityText = accessibilityText
        self.expiresAt = expiresAt
    }
}

/// 一次状态刷新可能同时产生多个独立宿主结果。请求先不分配 revision/过期时间；只有真正
/// 成为当前 banner 时才分配，确保排队中的 VoiceOver 句不会与上一条共用去重代次，也不会
/// 在尚未显示时提前过期。
public struct IntegrationsFeedbackRequest: Sendable, Equatable {
    public let host: HostID
    public let kind: IntegrationsFeedbackKind
    public let text: IntegrationsFeedbackText
    public let accessibilityText: IntegrationsFeedbackText?
    public var message: String { text.resolve(language: .zhHans) }
    public var accessibilityAnnouncement: String? {
        accessibilityText?.resolve(language: .zhHans)
    }

    public init(
        host: HostID,
        kind: IntegrationsFeedbackKind,
        message: String,
        accessibilityAnnouncement: String? = nil
    ) {
        self.init(
            host: host,
            kind: kind,
            text: .literal(message),
            accessibilityText: accessibilityAnnouncement.map(IntegrationsFeedbackText.literal))
    }

    public init(
        host: HostID,
        kind: IntegrationsFeedbackKind,
        text: IntegrationsFeedbackText,
        accessibilityText: IntegrationsFeedbackText? = nil
    ) {
        self.host = host
        self.kind = kind
        self.text = text
        self.accessibilityText = accessibilityText
    }

    public init(
        host: HostID,
        kind: IntegrationsFeedbackKind,
        text: IntegrationsFeedbackText,
        accessibilityAnnouncement: String?
    ) {
        self.init(
            host: host,
            kind: kind,
            text: text,
            accessibilityText: accessibilityAnnouncement.map(IntegrationsFeedbackText.literal))
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
        contentsOf:
            capabilityCells
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
            [
                IntegrationsFeedbackRequest(
                    host: host,
                    kind: kind,
                    message: message,
                    accessibilityAnnouncement: accessibilityAnnouncement)
            ],
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
            text: request.text,
            accessibilityText: request.accessibilityText,
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

    public mutating func consume(
        _ feedback: IntegrationsFeedback?,
        language: ClaudioAppLanguage
    ) -> String? {
        guard let feedback, feedback.revision != lastAnnouncedRevision else { return nil }
        lastAnnouncedRevision = feedback.revision
        return feedback.localizedAccessibilityLabel(language: language)
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
    /// Repairing a legacy installation is semantically an upgrade. Keep this fact typed so the
    /// localized view never infers it by comparing a Chinese status string.
    public let isUpgrade: Bool

    public init(
        action: IntegrationsWindowInspectorAction,
        host: HostID,
        statusText: String,
        accessibilityLabel: String,
        isUpgrade: Bool = false
    ) {
        self.action = action
        self.host = host
        self.statusText = statusText
        self.accessibilityLabel = accessibilityLabel
        self.isUpgrade = isUpgrade
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
    let isUpgrade: Bool
    switch action {
    case .copyHooksCommand:
        return nil
    case .redetect:
        host = selectedHost
        statusText = "重新检测中"
        isUpgrade = false
    case .connect(let target):
        host = target
        statusText = "连接中"
        isUpgrade = false
    case .repair(let target):
        host = target
        isUpgrade = hostStatus == .legacy
        statusText = isUpgrade ? "升级中" : "修复中"
    case .disconnect(let target):
        host = target
        statusText = "断开中"
        isUpgrade = false
    case .clearReceiptHistory(let target):
        host = target
        statusText = "清除回执历史中"
        isUpgrade = false
    }
    return IntegrationsInFlightPresentation(
        action: action,
        host: host,
        statusText: statusText,
        accessibilityLabel: "\(host.displayName)，\(statusText)",
        isUpgrade: isUpgrade)
}
