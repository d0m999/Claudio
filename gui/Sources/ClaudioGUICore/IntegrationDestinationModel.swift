import ClaudioCore
import ClaudioLocalization
import Combine
import Foundation

public enum IntegrationDestinationConfirmation: Sendable, Equatable {
    case disconnect(HostID)
    case clearReceiptHistory(HostID)

    public var host: HostID {
        switch self {
        case .disconnect(let host), .clearReceiptHistory(let host): host
        }
    }
}

public struct IntegrationDestinationActionOutcome: Sendable, Equatable {
    public let content: IntegrationDestinationContent
    public let feedbackKind: IntegrationsFeedbackKind
    public let feedbackText: IntegrationsFeedbackText

    public var feedbackMessage: String { feedbackText.resolve(language: .zhHans) }

    public init(
        content: IntegrationDestinationContent,
        feedbackKind: IntegrationsFeedbackKind,
        feedbackMessage: String
    ) {
        self.content = content
        self.feedbackKind = feedbackKind
        feedbackText = .literal(feedbackMessage)
    }

    public init(
        content: IntegrationDestinationContent,
        feedbackKind: IntegrationsFeedbackKind,
        feedbackText: IntegrationsFeedbackText
    ) {
        self.content = content
        self.feedbackKind = feedbackKind
        self.feedbackText = feedbackText
    }
}

public struct IntegrationDestinationRefreshHandler: Sendable {
    private let operation:
        @MainActor @Sendable () async throws -> IntegrationDestinationActionOutcome

    public init(
        _ operation:
            @escaping @MainActor @Sendable () async throws -> IntegrationDestinationActionOutcome
    ) {
        self.operation = operation
    }

    @MainActor
    public func callAsFunction() async throws -> IntegrationDestinationActionOutcome {
        try await operation()
    }
}

public struct IntegrationDestinationActionHandler: Sendable {
    private let operation:
        @MainActor @Sendable (HostIntegrationUserAction) async throws
            -> IntegrationDestinationActionOutcome

    public init(
        _ operation:
            @escaping @MainActor @Sendable (HostIntegrationUserAction) async throws
            -> IntegrationDestinationActionOutcome
    ) {
        self.operation = operation
    }

    @MainActor
    public func callAsFunction(
        _ action: HostIntegrationUserAction
    ) async throws -> IntegrationDestinationActionOutcome {
        try await operation(action)
    }
}

/// AppKit is deliberately outside ClaudioGUICore. The GUI executable injects its NSPasteboard
/// adapter through this tiny Foundation-only seam.
public struct IntegrationDestinationClipboardWriter: Sendable {
    private let operation: @MainActor @Sendable (String) -> Bool

    public init(_ operation: @escaping @MainActor @Sendable (String) -> Bool) {
        self.operation = operation
    }

    @MainActor
    public func callAsFunction(_ text: String) -> Bool {
        operation(text)
    }
}

@MainActor
public final class IntegrationDestinationModel: ObservableObject {
    @Published public private(set) var content: IntegrationDestinationContent
    @Published public private(set) var feedback: IntegrationsFeedback?
    @Published public private(set) var inFlightOperation:
        IntegrationDestinationInFlightPresentation?
    @Published public private(set) var pendingConfirmation: IntegrationDestinationConfirmation?
    @Published public private(set) var isWindowVisible = false
    @Published public private(set) var isWindowKey = false
    @Published public private(set) var selectedHost: HostID?

    private let refreshHandler: IntegrationDestinationRefreshHandler
    private let actionHandler: IntegrationDestinationActionHandler
    private let preferences: ClaudioPreferences?
    private let clipboardWriter: IntegrationDestinationClipboardWriter?
    private let onContentChanged: @MainActor @Sendable (IntegrationDestinationContent) -> Void
    private var feedbackState = IntegrationsFeedbackModel()
    private var feedbackExpiryTask: Task<Void, Never>?

    public init(
        content: IntegrationDestinationContent,
        refreshHandler: IntegrationDestinationRefreshHandler,
        actionHandler: IntegrationDestinationActionHandler,
        preferences: ClaudioPreferences? = nil,
        clipboardWriter: IntegrationDestinationClipboardWriter? = nil,
        onContentChanged: @escaping @MainActor @Sendable (IntegrationDestinationContent) -> Void = {
            _ in
        }
    ) {
        self.content = content
        self.refreshHandler = refreshHandler
        self.actionHandler = actionHandler
        self.preferences = preferences
        self.clipboardWriter = clipboardWriter
        self.onContentChanged = onContentChanged
        inFlightOperation = nil
        feedback = nil
        pendingConfirmation = nil
        selectedHost = nil
        restorePreferredHost()
    }

    deinit {
        feedbackExpiryTask?.cancel()
    }

    public var isPerformingAction: Bool { inFlightOperation != nil }

    public var selectedHostFacts: IntegrationDestinationHostFacts? {
        selectedHost.flatMap(content.facts(for:))
    }

    public var connectionSection: IntegrationConnectionSectionPresentation? {
        selectedHost.flatMap(content.connectionSection(for:))
    }

    public func agent(for host: HostID) -> IntegrationAgentConnectionControlPresentation? {
        agentControls.first(where: { $0.host == host })
    }

    /// The in-flight projection changes only action affordances, never the manager-derived `isOn`
    /// bit. Selection remains available while an operation is running.
    public var agentControls: [IntegrationAgentConnectionControlPresentation] {
        content.hostFacts.compactMap { facts in
            IntegrationAgentConnectionControlPresentation(
                row: facts.row,
                isToggleEnabled: !isPerformingAction,
                isInFlight: inFlightOperation?.host == facts.host)
        }
    }

    @discardableResult
    public func selectHost(_ host: HostID) -> Bool {
        guard HostID.productVisibleCases.contains(host), content.facts(for: host) != nil else {
            return false
        }
        selectedHost = host
        preferences?.setLastIntegrationSurface(host.surfaceID)
        return true
    }

    /// Generic Integrations entry restores the last legal Surface. If an external refresh has
    /// removed it, product-visible order supplies the reconciliation target and persists it.
    @discardableResult
    public func restorePreferredHost() -> HostID? {
        let preferredSurface = preferences?.lastIntegrationSurface
        let preferredHost = preferredSurface.flatMap { surface in
            HostID.productVisibleCases.first(where: { $0.surfaceID == surface })
        }
        let host =
            preferredHost.flatMap { content.facts(for: $0) != nil ? $0 : nil }
            ?? integrationAgentHostOrder().first(where: { content.facts(for: $0) != nil })
        selectedHost = host
        if let host, preferredHost != host {
            preferences?.setLastIntegrationSurface(host.surfaceID)
        }
        return host
    }

    /// The Settings owner supplies the actual AppKit lifecycle facts. A retained hosting view can
    /// outlive the window, so view existence alone is never treated as visibility or key state.
    public func noteWindowVisibility(_ visible: Bool) {
        isWindowVisible = visible
        if !visible { isWindowKey = false }
    }

    public func noteWindowKeyState(_ key: Bool) {
        isWindowKey = key && isWindowVisible
    }

    public func replaceExternalContent(_ replacement: IntegrationDestinationContent) {
        let receiptTransitions = integrationReceiptTransitions(from: content, to: replacement)
        replaceContent(replacement)
        if isWindowVisible, !receiptTransitions.isEmpty {
            presentFeedbackSequence(
                receiptTransitions.map { transition in
                    IntegrationsFeedbackRequest(
                        host: transition.host,
                        kind: .information,
                        text: .localized(
                            key: .feedbackReceipt,
                            arguments: [transition.receipt]),
                        accessibilityText: stateChangeAccessibilityText(
                            in: replacement,
                            host: transition.host,
                            message: .localized(
                                key: .feedbackReceipt,
                                arguments: [transition.receipt])))
                })
        }
    }

    /// The Toggle is a real connection control. Turning off always opens confirmation; canceling
    /// only clears the typed pending action and cannot call the manager.
    public func requestToggle(for host: HostID) {
        guard !isPerformingAction, let facts = content.facts(for: host) else { return }
        if facts.status == .notConnected {
            Task { @MainActor [weak self] in
                await self?.perform(.connect(host))
            }
        } else {
            pendingConfirmation = .disconnect(host)
        }
    }

    public func toggleHost(_ host: HostID) async {
        guard !isPerformingAction, let facts = content.facts(for: host) else { return }
        if facts.status == .notConnected {
            await perform(.connect(host))
        } else {
            pendingConfirmation = .disconnect(host)
        }
    }

    public func requestClearReceiptHistory(for host: HostID) {
        guard !isPerformingAction, content.facts(for: host) != nil else { return }
        pendingConfirmation = .clearReceiptHistory(host)
    }

    public func cancelPendingAction() {
        pendingConfirmation = nil
    }

    public func confirmPendingAction() async {
        guard !isPerformingAction, let confirmation = pendingConfirmation else { return }
        pendingConfirmation = nil
        switch confirmation {
        case .disconnect(let host): await perform(.disconnect(host))
        case .clearReceiptHistory(let host): await perform(.clearReceiptHistory(host))
        }
    }

    @discardableResult
    public func copyConfigurationSource(for host: HostID) -> Bool {
        guard !isPerformingAction,
            let source = content.facts(for: host)?.configurationSource,
            let clipboardWriter
        else { return false }
        let didCopy = clipboardWriter(source)
        presentFeedback(
            host: host,
            kind: didCopy ? .information : .failure,
            text: .localized(
                key: didCopy
                    ? .feedbackCopyConfigurationPathSucceeded
                    : .feedbackCopyConfigurationPathFailed,
                arguments: []))
        return didCopy
    }

    public func perform(_ action: HostIntegrationUserAction) async {
        guard !isPerformingAction else { return }
        let host = action.host ?? selectedHost ?? .claudeCode

        if action == .copyHooksCommand {
            let didCopy = clipboardWriter?("/hooks") ?? false
            presentFeedback(
                host: host,
                kind: didCopy ? .information : .failure,
                text: .localized(
                    key: didCopy ? .feedbackCopyHooksSucceeded : .feedbackCopyHooksFailed,
                    arguments: []))
            return
        }

        let hostStatus = content.facts(for: host)?.status
        inFlightOperation = integrationDestinationInFlightPresentation(
            action: action,
            selectedHost: host,
            hostStatus: hostStatus)
        defer { inFlightOperation = nil }

        do {
            let outcome =
                try await
                (action == .redetect
                ? refreshHandler()
                : actionHandler(action))
            let receiptTransitions =
                action == .redetect
                ? integrationReceiptTransitions(from: content, to: outcome.content)
                : []
            replaceContent(outcome.content)
            if receiptTransitions.isEmpty {
                presentFeedback(
                    host: host,
                    kind: outcome.feedbackKind,
                    text: outcome.feedbackText,
                    accessibilityText: stateChangeAccessibilityText(
                        in: outcome.content,
                        host: host,
                        message: outcome.feedbackText))
            } else {
                presentFeedbackSequence(
                    receiptTransitions.map { transition in
                        IntegrationsFeedbackRequest(
                            host: transition.host,
                            kind: .information,
                            text: .localized(
                                key: .feedbackReceipt,
                                arguments: [transition.receipt]),
                            accessibilityText: stateChangeAccessibilityText(
                                in: outcome.content,
                                host: transition.host,
                                message: .localized(
                                    key: .feedbackReceipt,
                                    arguments: [transition.receipt])))
                    })
            }
        } catch {
            let failureText = localizedFailureFeedbackText(for: error)
            presentFeedback(
                host: host,
                kind: .failure,
                text: failureText,
                accessibilityText: stateChangeAccessibilityText(
                    in: content,
                    host: host,
                    message: failureText))
        }
    }

    public func dismissFeedback(revision: UInt64) {
        guard feedbackState.current?.revision == revision else { return }
        feedbackExpiryTask?.cancel()
        feedbackExpiryTask = nil
        feedbackState.dismiss(revision: revision, now: Date())
        feedback = feedbackState.current
        scheduleFeedbackExpiryIfNeeded()
    }

    #if DEBUG
    /// Pins a deterministic in-flight frame for the DEBUG State Gallery. It never calls a
    /// manager or changes the content snapshot; production actions still enter this state only
    /// through ``perform(_:)``.
    public func pinPreviewInFlight(_ action: HostIntegrationUserAction) {
        let host = action.host ?? selectedHost ?? .claudeCode
        inFlightOperation = integrationDestinationInFlightPresentation(
            action: action,
            selectedHost: host,
            hostStatus: content.facts(for: host)?.status)
    }
    #endif

    private func replaceContent(_ replacement: IntegrationDestinationContent) {
        content = replacement
        onContentChanged(replacement)
        if selectedHost.flatMap(replacement.facts(for:)) == nil {
            _ = restorePreferredHost()
        }
    }

    private func presentFeedback(
        host: HostID,
        kind: IntegrationsFeedbackKind,
        text: IntegrationsFeedbackText,
        accessibilityText: IntegrationsFeedbackText? = nil
    ) {
        presentFeedbackSequence([
            IntegrationsFeedbackRequest(
                host: host,
                kind: kind,
                text: text,
                accessibilityText: accessibilityText)
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
        let remainingLifetime = max(0, current.expiresAt.timeIntervalSinceNow)
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

    private func stateChangeAccessibilityText(
        in content: IntegrationDestinationContent,
        host: HostID,
        message: IntegrationsFeedbackText
    ) -> IntegrationsFeedbackText? {
        guard let hostRow = content.sourceRows.first(where: { $0.host == host }) else {
            return nil
        }
        let capabilityCells = content.matrix.rows.compactMap {
            $0.cells.first(where: { $0.host == host })
        }
        return .stateChange(
            message: message,
            hostRow: hostRow,
            capabilityCells: capabilityCells)
    }

    private func localizedFailureFeedbackText(for error: Error) -> IntegrationsFeedbackText {
        if let presentationError = error as? HostIntegrationPresentationError {
            switch presentationError {
            case .storeUnavailable:
                return .localized(key: .integrationsStoreUnavailable, arguments: [])
            case .recoveryFailed(let reason):
                return .localized(key: .feedbackOperationFailed, arguments: [reason])
            }
        }
        return .localized(
            key: .feedbackOperationFailed,
            arguments: [error.localizedDescription])
    }
}

private struct IntegrationReceiptTransition {
    let host: HostID
    let receipt: String
}

private func integrationReceiptTransitions(
    from previous: IntegrationDestinationContent,
    to current: IntegrationDestinationContent
) -> [IntegrationReceiptTransition] {
    HostID.productVisibleCases.compactMap { host in
        let oldEvidence = previous.facts(for: host)?.latestReceiptEvidence
        guard let currentFacts = current.facts(for: host),
            let newEvidence = currentFacts.latestReceiptEvidence,
            let newReceipt = currentFacts.latestReceiptText,
            newEvidence != oldEvidence
        else { return nil }
        return IntegrationReceiptTransition(host: host, receipt: newReceipt)
    }
}
