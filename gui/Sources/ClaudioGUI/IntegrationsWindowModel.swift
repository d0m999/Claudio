import AppKit
import ClaudioCore
import ClaudioGUICore
import Combine
import Foundation

enum IntegrationsWindowSelection: Sendable, Hashable {
    case host(HostID)
    case capability(host: HostID, event: Event)

    var host: HostID {
        switch self {
        case .host(let host), .capability(let host, _): host
        }
    }
}

/// Host-level facts that are not matrix geometry. They are supplied by the shared integration
/// manager; this window never opens a host configuration or receipt file itself.
struct IntegrationsWindowHostInspectorFacts: Sendable, Equatable {
    let host: HostID
    let configurationSource: String
    let latestReceiptText: String?
    let latestReceiptEvidence: HostReceiptEvidence?
    let actions: [IntegrationsWindowInspectorAction]
}

struct IntegrationsWindowInspectorPresentation: Sendable, Equatable {
    let selection: IntegrationsWindowSelection
    let host: HostID
    let title: String
    let connectionText: String
    let configurationSource: String
    let nativeEventText: String?
    let latestReceiptText: String?
    let qualificationText: String?
    let accessibilityLabel: String
    let actions: [IntegrationsWindowInspectorAction]
}

/// One immutable refresh result. Both the two host cards and every matrix cell are already
/// projected by `ClaudioGUICore`; only inspector evidence remains host-scoped here.
struct IntegrationsWindowContent: Sendable, Equatable {
    let sourceRows: [HostSourceRowPresentation]
    let matrix: HostCapabilityMatrixPresentation
    let inspectorFacts: [HostID: IntegrationsWindowHostInspectorFacts]

    init(
        sourceRows: [HostSourceRowPresentation],
        matrix: HostCapabilityMatrixPresentation,
        inspectorFacts: [HostID: IntegrationsWindowHostInspectorFacts]
    ) {
        self.sourceRows = sourceRows
        self.matrix = matrix
        self.inspectorFacts = inspectorFacts
    }

    func contains(_ selection: IntegrationsWindowSelection) -> Bool {
        switch selection {
        case .host(let host):
            return sourceRows.contains(where: { $0.host == host })
        case .capability(let host, let event):
            return matrix.cell(host: host, event: event) != nil
        }
    }

    func inspector(for selection: IntegrationsWindowSelection)
        -> IntegrationsWindowInspectorPresentation?
    {
        let host = selection.host
        guard
            let row = sourceRows.first(where: { $0.host == host }),
            let facts = inspectorFacts[host]
        else { return nil }

        switch selection {
        case .host:
            let nativeEvents = matrix.rows.compactMap {
                matrix.cell(host: host, event: $0.event)?.nativeEventText
            }
            return IntegrationsWindowInspectorPresentation(
                selection: selection,
                host: host,
                title: host.displayName,
                connectionText: row.readinessText,
                configurationSource: facts.configurationSource,
                nativeEventText: nativeEvents.isEmpty
                    ? nil : nativeEvents.joined(separator: "、"),
                latestReceiptText: facts.latestReceiptText,
                qualificationText: row.detailText,
                accessibilityLabel: row.accessibilityLabel,
                actions: facts.actions)

        case .capability(_, let event):
            guard let cell = matrix.cell(host: host, event: event) else { return nil }
            return IntegrationsWindowInspectorPresentation(
                selection: selection,
                host: host,
                title: "\(event.displayName) · \(host.displayName)",
                connectionText: cell.statusText,
                configurationSource: facts.configurationSource,
                nativeEventText: cell.nativeEventText,
                latestReceiptText: facts.latestReceiptText,
                qualificationText: cell.qualificationText,
                accessibilityLabel: cell.accessibilityLabel,
                actions: facts.actions)
        }
    }
}

struct IntegrationsWindowActionOutcome: Sendable, Equatable {
    let content: IntegrationsWindowContent
    let feedbackKind: IntegrationsFeedbackKind
    let feedbackMessage: String
}

struct IntegrationsWindowRefreshHandler: Sendable {
    private let operation:
        @MainActor @Sendable () async throws -> IntegrationsWindowActionOutcome

    init(
        _ operation: @escaping
            @MainActor @Sendable () async throws -> IntegrationsWindowActionOutcome
    ) {
        self.operation = operation
    }

    @MainActor
    func callAsFunction() async throws -> IntegrationsWindowActionOutcome {
        try await operation()
    }
}

struct IntegrationsWindowActionHandler: Sendable {
    private let operation:
        @MainActor @Sendable (IntegrationsWindowInspectorAction) async throws
            -> IntegrationsWindowActionOutcome

    init(
        _ operation: @escaping
            @MainActor @Sendable (IntegrationsWindowInspectorAction) async throws
                -> IntegrationsWindowActionOutcome
    ) {
        self.operation = operation
    }

    @MainActor
    func callAsFunction(
        _ action: IntegrationsWindowInspectorAction
    ) async throws -> IntegrationsWindowActionOutcome {
        try await operation(action)
    }
}

struct IntegrationsWindowRecoveryHandler: Sendable {
    private let operation:
        @MainActor @Sendable (IntegrationsRecoveryAction) async throws
            -> IntegrationsWindowActionOutcome

    init(
        _ operation: @escaping
            @MainActor @Sendable (IntegrationsRecoveryAction) async throws
                -> IntegrationsWindowActionOutcome
    ) {
        self.operation = operation
    }

    @MainActor
    func callAsFunction(
        _ action: IntegrationsRecoveryAction
    ) async throws -> IntegrationsWindowActionOutcome {
        try await operation(action)
    }
}

struct IntegrationsWindowClipboardWriter: Sendable {
    private let operation: @MainActor @Sendable (String) -> Bool

    init(_ operation: @escaping @MainActor @Sendable (String) -> Bool) {
        self.operation = operation
    }

    @MainActor
    func callAsFunction(_ text: String) -> Bool {
        operation(text)
    }

    static let system = IntegrationsWindowClipboardWriter { text in
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }
}

/// Monotonic hand-off from the retained AppKit controller to this window's own `FocusState`.
@MainActor
final class IntegrationsWindowFocusCoordinator: ObservableObject {
    @Published private(set) var requestRevision = 0

    func requestInitialFocus() {
        requestRevision += 1
    }
}

@MainActor
final class IntegrationsWindowModel: ObservableObject {
    @Published private(set) var content: IntegrationsWindowContent
    @Published private(set) var feedback: IntegrationsFeedback?
    @Published private(set) var inFlightOperation: IntegrationsInFlightPresentation?
    @Published private(set) var isPerformingRecovery = false
    @Published private(set) var isWindowVisible = false
    @Published private(set) var isWindowKey = false
    @Published var selection: IntegrationsWindowSelection

    private let refreshHandler: IntegrationsWindowRefreshHandler
    private let actionHandler: IntegrationsWindowActionHandler
    private let recoveryHandler: IntegrationsWindowRecoveryHandler?
    private let clipboardWriter: IntegrationsWindowClipboardWriter
    private let onContentChanged: @MainActor @Sendable (IntegrationsWindowContent) -> Void
    private var feedbackState = IntegrationsFeedbackModel()
    private var feedbackExpiryTask: Task<Void, Never>?

    init(
        content: IntegrationsWindowContent,
        refreshHandler: IntegrationsWindowRefreshHandler,
        actionHandler: IntegrationsWindowActionHandler,
        recoveryHandler: IntegrationsWindowRecoveryHandler? = nil,
        clipboardWriter: IntegrationsWindowClipboardWriter = .system,
        onContentChanged: @escaping @MainActor @Sendable
            (IntegrationsWindowContent) -> Void = { _ in }
    ) {
        self.content = content
        self.refreshHandler = refreshHandler
        self.actionHandler = actionHandler
        self.recoveryHandler = recoveryHandler
        self.clipboardWriter = clipboardWriter
        self.onContentChanged = onContentChanged
        inFlightOperation = nil
        selection = .host(content.sourceRows.first?.host ?? .claudeCode)
    }

    deinit {
        feedbackExpiryTask?.cancel()
    }

    var inspector: IntegrationsWindowInspectorPresentation? {
        content.inspector(for: selection)
    }

    var isPerformingAction: Bool { inFlightOperation != nil || isPerformingRecovery }

    var recoveryAction: IntegrationsRecoveryAction {
        guard
            case .capability(let host, let event) = selection,
            let cell = content.matrix.cell(host: host, event: event),
            let status = content.sourceRows.first(where: { $0.host == host })?.status
        else { return .none }
        return integrationsRecoveryAction(for: cell, hostStatus: status)
    }

    /// Codex's trust step is a product invariant rather than optional caller decoration. Even if
    /// a stale manager result omitted actions, an awaiting Codex row still exposes exactly the
    /// two safe recovery controls promised by the UI copy.
    var inspectorActions: [IntegrationsWindowInspectorAction] {
        guard let inspector else { return [] }
        var actions = inspector.actions
        if
            inspector.host == .codex,
            let row = content.sourceRows.first(where: { $0.host == .codex }),
            row.status == .awaitingActivation
        {
            if !actions.contains(.copyHooksCommand) {
                actions.insert(.copyHooksCommand, at: 0)
            }
            if !actions.contains(.redetect) {
                let insertionIndex = actions.first == .copyHooksCommand ? 1 : 0
                actions.insert(.redetect, at: insertionIndex)
            }
        }
        return actions
    }

    func select(_ selection: IntegrationsWindowSelection) {
        guard content.contains(selection) else { return }
        self.selection = selection
    }

    /// 面板打开、声音包/静音变化或真实回执到达时，MenuBarController
    /// 会把同一份 manager 投影同步给保留窗口。窗口不因关闭而释放，
    /// 因此不能只在自己的按钮动作后更新，否则重开会显示旧快照。
    func replaceExternalContent(_ replacement: IntegrationsWindowContent) {
        let receiptTransitions = integrationsReceiptTransitions(from: content, to: replacement)
        replaceContent(replacement)
        if isWindowVisible, !receiptTransitions.isEmpty {
            presentFeedbackSequence(receiptTransitions.map { receiptTransition in
                IntegrationsFeedbackRequest(
                    host: receiptTransition.host,
                    kind: .information,
                    message: receiptTransition.message,
                    accessibilityAnnouncement: stateChangeAccessibilityAnnouncement(
                        in: replacement,
                        host: receiptTransition.host,
                        event: receiptTransition.event,
                        message: receiptTransition.message))
            })
        }
    }

    /// AppKit 窗口生命周期的唯一入口。retained hosting view 在 close 后仍存活，
    /// 因此 SwiftUI 不能拿“view 还在”推断它可见或拥有键盘/VoiceOver 焦点。
    func noteWindowVisibility(_ visible: Bool) {
        isWindowVisible = visible
        if !visible { isWindowKey = false }
    }

    func noteWindowKeyState(_ key: Bool) {
        isWindowKey = key && isWindowVisible
    }

    func perform(_ action: IntegrationsWindowInspectorAction) async {
        guard !isPerformingAction else { return }
        let host = action.host ?? selection.host

        if action == .copyHooksCommand {
            let didCopy = clipboardWriter("/hooks")
            presentFeedback(
                host: host,
                kind: didCopy ? .information : .failure,
                message: didCopy ? "已复制 /hooks" : "无法复制 /hooks")
            return
        }

        let hostStatus = content.sourceRows.first(where: { $0.host == host })?.status
        inFlightOperation = integrationsInFlightPresentation(
            action: action,
            selectedHost: host,
            hostStatus: hostStatus)
        defer { inFlightOperation = nil }
        do {
            let outcome: IntegrationsWindowActionOutcome
            if action == .redetect {
                outcome = try await refreshHandler()
            } else {
                outcome = try await actionHandler(action)
            }
            let receiptTransitions = action == .redetect
                ? integrationsReceiptTransitions(from: content, to: outcome.content)
                : []
            replaceContent(outcome.content)
            if !receiptTransitions.isEmpty {
                presentFeedbackSequence(receiptTransitions.map { receiptTransition in
                    IntegrationsFeedbackRequest(
                        host: receiptTransition.host,
                        kind: .information,
                        message: receiptTransition.message,
                        accessibilityAnnouncement: stateChangeAccessibilityAnnouncement(
                            in: outcome.content,
                            host: receiptTransition.host,
                            event: receiptTransition.event,
                            message: receiptTransition.message))
                })
            } else {
                presentFeedback(
                    host: host,
                    kind: outcome.feedbackKind,
                    message: outcome.feedbackMessage,
                    accessibilityAnnouncement: stateChangeAccessibilityAnnouncement(
                        in: outcome.content,
                        host: host,
                        event: selectedCapabilityEvent(for: host),
                        message: outcome.feedbackMessage))
            }
        } catch {
            let message = "操作失败：\(error.localizedDescription)"
            presentFeedback(
                host: host,
                kind: .failure,
                message: message,
                accessibilityAnnouncement: stateChangeAccessibilityAnnouncement(
                    in: content,
                    host: host,
                    event: selectedCapabilityEvent(for: host),
                    message: message))
        }
    }

    func performRecovery(_ action: IntegrationsRecoveryAction) async {
        switch action {
        case .connect(let host):
            await perform(.connect(host))
            return
        case .upgrade(let host), .repair(let host):
            await perform(.repair(host))
            return
        case .redetect:
            await perform(.redetect)
            return
        case .explainUnsupported, .none:
            return
        case .unmute(let host, let event), .configureSound(let host, let event):
            guard !isPerformingAction, let recoveryHandler else { return }
            isPerformingRecovery = true
            defer { isPerformingRecovery = false }
            do {
                let outcome = try await recoveryHandler(action)
                replaceContent(outcome.content)
                presentFeedback(
                    host: host,
                    kind: outcome.feedbackKind,
                    message: outcome.feedbackMessage,
                    accessibilityAnnouncement: stateChangeAccessibilityAnnouncement(
                        in: outcome.content,
                        host: host,
                        event: event,
                        message: outcome.feedbackMessage))
            } catch {
                let message = "操作失败：\(error.localizedDescription)"
                presentFeedback(
                    host: host,
                    kind: .failure,
                    message: message,
                    accessibilityAnnouncement: stateChangeAccessibilityAnnouncement(
                        in: content,
                        host: host,
                        event: event,
                        message: message))
            }
        }
    }

    func copyConfigurationPath() {
        guard let inspector else { return }
        let didCopy = clipboardWriter(inspector.configurationSource)
        presentFeedback(
            host: inspector.host,
            kind: didCopy ? .information : .failure,
            message: didCopy ? "已复制配置路径" : "无法复制配置路径")
    }

    func dismissFeedback(revision: UInt64) {
        guard feedbackState.current?.revision == revision else { return }
        feedbackExpiryTask?.cancel()
        feedbackExpiryTask = nil
        feedbackState.dismiss(revision: revision, now: Date())
        feedback = feedbackState.current
        scheduleFeedbackExpiryIfNeeded()
    }

    private func replaceContent(_ replacement: IntegrationsWindowContent) {
        content = replacement
        onContentChanged(replacement)
        if !replacement.contains(selection) {
            selection = .host(replacement.sourceRows.first?.host ?? .claudeCode)
        }
    }

    private func presentFeedback(
        host: HostID,
        kind: IntegrationsFeedbackKind,
        message: String,
        accessibilityAnnouncement: String? = nil
    ) {
        presentFeedbackSequence([
            IntegrationsFeedbackRequest(
                host: host,
                kind: kind,
                message: message,
                accessibilityAnnouncement: accessibilityAnnouncement)
        ])
    }

    private func presentFeedbackSequence(_ requests: [IntegrationsFeedbackRequest]) {
        guard !requests.isEmpty else { return }
        feedbackExpiryTask?.cancel()
        let now = Date()
        _ = feedbackState.presentSequence(requests, now: now)
        feedback = feedbackState.activeFeedback(at: now)
        scheduleFeedbackExpiryIfNeeded()
    }

    private func scheduleFeedbackExpiryIfNeeded() {
        guard let current = feedbackState.current else {
            feedbackExpiryTask = nil
            return
        }
        let now = Date()
        let remainingLifetime = max(0, current.expiresAt.timeIntervalSince(now))
        let revision = current.revision
        feedbackExpiryTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(
                    nanoseconds: UInt64(remainingLifetime * 1_000_000_000))
            } catch {
                return
            }
            guard let self, self.feedback?.revision == revision else { return }
            self.feedbackState.expire(at: Date())
            self.feedback = self.feedbackState.current
            self.feedbackExpiryTask = nil
            self.scheduleFeedbackExpiryIfNeeded()
        }
    }

    /// `event == nil` 表示宿主卡级 refresh：把该宿主的四个共享矩阵格都播出；矩阵格选择或
    /// 真实回执则只播相关事件。两条路径都先带宿主来源行的能力/连接摘要。
    private func stateChangeAccessibilityAnnouncement(
        in content: IntegrationsWindowContent,
        host: HostID,
        event: Event?,
        message: String
    ) -> String? {
        guard let hostRow = content.sourceRows.first(where: { $0.host == host }) else {
            return nil
        }
        let capabilityCells: [HostCapabilityCellPresentation]
        if let event, let cell = content.matrix.cell(host: host, event: event) {
            capabilityCells = [cell]
        } else {
            capabilityCells = content.matrix.rows.compactMap {
                $0.cells.first(where: { $0.host == host })
            }
        }
        return integrationsStateChangeAccessibilityLabel(
            message: message,
            hostRow: hostRow,
            capabilityCells: capabilityCells)
    }

    private func selectedCapabilityEvent(for host: HostID) -> Event? {
        guard case .capability(let selectedHost, let event) = selection,
            selectedHost == host
        else { return nil }
        return event
    }

}

private struct IntegrationsReceiptTransition {
    let host: HostID
    let event: Event
    let message: String
}

/// 只把已经通过 current installation 校验、并且相对上一帧新增/变化的真实回执
/// 提升为短暂反馈。变化判定比较完整 evidence，不依赖可见摘要的格式或时间精度。
private func integrationsReceiptTransitions(
    from previous: IntegrationsWindowContent,
    to current: IntegrationsWindowContent
) -> [IntegrationsReceiptTransition] {
    HostID.allCases.compactMap { host in
        let oldEvidence = previous.inspectorFacts[host]?.latestReceiptEvidence
        guard let currentFacts = current.inspectorFacts[host],
            let newEvidence = currentFacts.latestReceiptEvidence,
            let newReceipt = currentFacts.latestReceiptText,
            newEvidence != oldEvidence
        else { return nil }
        return IntegrationsReceiptTransition(
            host: host,
            event: newEvidence.event,
            message: "收到当前代次真实回执：\(newReceipt)")
    }
}

private extension IntegrationsWindowInspectorAction {
    var host: HostID? {
        switch self {
        case .connect(let host), .repair(let host), .disconnect(let host): host
        case .copyHooksCommand, .redetect: nil
        }
    }
}
