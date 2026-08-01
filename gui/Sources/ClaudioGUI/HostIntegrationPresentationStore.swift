import ClaudioCore
import ClaudioGUICore
import Combine
import Foundation

/// Main-actor presentation seam shared by the popover and the retained integrations window.
/// It accepts already-composed Core facts and never opens either host's configuration itself.
@MainActor
public final class HostIntegrationPresentationStore: ObservableObject {
    @Published private(set) var content: IntegrationsWindowContent

    private let configurationSources: [HostID: String]
    private var state: HostIntegrationPresentationState

    init(
        state: HostIntegrationPresentationState,
        configurationSources: [HostID: String]
    ) {
        self.state = state
        self.configurationSources = configurationSources
        content = integrationWindowContent(
            state: state,
            configurationSources: configurationSources)
    }

    @discardableResult
    func replace(state replacementState: HostIntegrationPresentationState)
        -> IntegrationsWindowContent
    {
        state = replacementState
        let replacement = integrationWindowContent(
            state: replacementState,
            configurationSources: configurationSources)
        content = replacement
        return replacement
    }

    func replace(content replacement: IntegrationsWindowContent) {
        content = replacement
    }
}

/// Async provider boundary for the non-observable manager bridge. Startup and ordinary refresh are
/// deliberately separate so app launch can bootstrap shared runtime without ever auto-connecting a
/// host; tests can inject two distinct operations and prove that separation.
struct HostIntegrationMatrixProvider: Sendable {
    private let refreshOperation:
        @Sendable () async throws -> HostIntegrationPresentationState
    private let bootstrapOperation:
        @Sendable () async throws -> HostIntegrationPresentationState

    init(
        refresh: @escaping @Sendable () async throws -> HostIntegrationPresentationState,
        bootstrap: @escaping @Sendable () async throws -> HostIntegrationPresentationState
    ) {
        refreshOperation = refresh
        bootstrapOperation = bootstrap
    }

    func callAsFunction() async throws -> HostIntegrationPresentationState {
        try await refreshOperation()
    }

    func bootstrapSharedRuntime() async throws -> HostIntegrationPresentationState {
        try await bootstrapOperation()
    }
}

/// Connect/repair/disconnect provider kept independent from the window model's content type. The
/// bridge returns Core presentation state; `MenuBarController` publishes it on MainActor into the
/// same store both UI surfaces observe.
struct HostIntegrationActionProvider: Sendable {
    private let operation:
        @Sendable (IntegrationsWindowInspectorAction) async throws
            -> HostIntegrationMutationOutcome

    init(
        _ operation: @escaping
            @Sendable (IntegrationsWindowInspectorAction) async throws
                -> HostIntegrationMutationOutcome
    ) {
        self.operation = operation
    }

    func callAsFunction(
        _ action: IntegrationsWindowInspectorAction
    ) async throws -> HostIntegrationMutationOutcome {
        try await operation(action)
    }
}

enum HostIntegrationPresentationError: LocalizedError {
    case storeUnavailable

    var errorDescription: String? {
        switch self {
        case .storeUnavailable:
            "声音来源状态暂时不可用，请重新检测。"
        }
    }
}

private func integrationWindowContent(
    state: HostIntegrationPresentationState,
    configurationSources: [HostID: String]
) -> IntegrationsWindowContent {
    let sourceRows = hostSourceRowPresentations(from: state.matrix)
    let snapshots = Dictionary(uniqueKeysWithValues: state.snapshots.map { ($0.host, $0) })
    let facts = Dictionary(
        uniqueKeysWithValues: sourceRows.map { row in
            (
                row.host,
                IntegrationsWindowHostInspectorFacts(
                    host: row.host,
                    configurationSource: configurationSources[row.host] ?? "由宿主集成管理器提供",
                    latestReceiptText: snapshots[row.host].flatMap(hostLatestReceiptText),
                    latestReceiptEvidence: snapshots[row.host].flatMap(hostLatestReceiptEvidence),
                    actions: integrationsInspectorActions(for: row))
            )
        })
    return IntegrationsWindowContent(
        sourceRows: sourceRows,
        matrix: hostCapabilityMatrixPresentation(from: state.matrix),
        inspectorFacts: facts)
}
