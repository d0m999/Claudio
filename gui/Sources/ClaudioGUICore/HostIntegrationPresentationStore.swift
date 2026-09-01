import ClaudioCore
import ClaudioLocalization
import Combine
import Foundation

/// Main-actor presentation seam shared by the menu-bar panel, Events, About, and the retained
/// Integrations destination. It accepts already-composed Core facts and never opens a host file.
@MainActor
public final class HostIntegrationPresentationStore: ObservableObject {
    @Published public private(set) var content: IntegrationDestinationContent
    @Published public private(set) var safeSurfaceFacts: [AboutSurfaceFact]

    private let configurationSources: [HostID: String]
    private var state: HostIntegrationPresentationState

    public init(
        state: HostIntegrationPresentationState,
        configurationSources: [HostID: String] = [:]
    ) {
        self.state = state
        self.configurationSources = configurationSources
        let initialContent = integrationDestinationContent(
            state: state,
            configurationSources: configurationSources)
        content = initialContent
        safeSurfaceFacts = aboutSurfaceFacts(from: initialContent.sourceRows)
    }

    @discardableResult
    public func replace(state replacementState: HostIntegrationPresentationState)
        -> IntegrationDestinationContent
    {
        state = replacementState
        let replacement = integrationDestinationContent(
            state: replacementState,
            configurationSources: configurationSources)
        content = replacement
        safeSurfaceFacts = aboutSurfaceFacts(from: replacement.sourceRows)
        return replacement
    }

    public func replace(content replacement: IntegrationDestinationContent) {
        content = replacement
        safeSurfaceFacts = aboutSurfaceFacts(from: replacement.sourceRows)
    }
}

/// Async provider boundary for the non-observable manager bridge. Startup and ordinary refresh are
/// deliberately separate so app launch can bootstrap shared runtime without ever auto-connecting a
/// host; tests can inject two distinct operations and prove that separation.
public struct HostIntegrationMatrixProvider: Sendable {
    private let refreshOperation: @Sendable () async throws -> HostIntegrationPresentationState
    private let bootstrapOperation: @Sendable () async throws -> HostIntegrationPresentationState

    public init(
        refresh: @escaping @Sendable () async throws -> HostIntegrationPresentationState,
        bootstrap: @escaping @Sendable () async throws -> HostIntegrationPresentationState
    ) {
        refreshOperation = refresh
        bootstrapOperation = bootstrap
    }

    public func callAsFunction() async throws -> HostIntegrationPresentationState {
        try await refreshOperation()
    }

    public func bootstrapSharedRuntime() async throws -> HostIntegrationPresentationState {
        try await bootstrapOperation()
    }
}

/// Connect/repair/disconnect provider kept independent from the destination model's content type.
public struct HostIntegrationActionProvider: Sendable {
    private let operation:
        @Sendable (HostIntegrationUserAction) async throws
            -> HostIntegrationMutationOutcome

    public init(
        _ operation:
            @escaping @Sendable (HostIntegrationUserAction) async throws
            -> HostIntegrationMutationOutcome
    ) {
        self.operation = operation
    }

    public func callAsFunction(
        _ action: HostIntegrationUserAction
    ) async throws -> HostIntegrationMutationOutcome {
        try await operation(action)
    }
}

public enum HostIntegrationPresentationError: LocalizedError, Sendable, Equatable {
    case storeUnavailable
    case recoveryFailed(String)

    public var errorDescription: String? {
        switch self {
        case .storeUnavailable:
            ClaudioL10n(language: .zhHans).text(.integrationsStoreUnavailable)
        case .recoveryFailed(let message):
            message
        }
    }
}

/// Compose the destination facts from one manager refresh. Production never supplies demo state;
/// tests and the State Gallery may inject a different manager snapshot through this same seam.
public func integrationDestinationContent(
    state: HostIntegrationPresentationState,
    configurationSources: [HostID: String] = [:]
) -> IntegrationDestinationContent {
    let sourceRows = hostSourceRowPresentations(from: state.matrix)
    let snapshots = Dictionary(uniqueKeysWithValues: state.snapshots.map { ($0.host, $0) })
    let facts = HostID.productVisibleCases.compactMap { host -> IntegrationDestinationHostFacts? in
        guard let row = sourceRows.first(where: { $0.host == host }) else { return nil }
        let snapshot = snapshots[host]
        return IntegrationDestinationHostFacts(
            host: host,
            row: row,
            configurationSource: configurationSources[host],
            latestReceiptText: snapshot.flatMap(hostLatestReceiptText),
            latestReceiptEvidence: snapshot.flatMap(hostLatestReceiptEvidence),
            mechanism: host.descriptor.mechanism)
    }
    return IntegrationDestinationContent(
        sourceRows: sourceRows,
        matrix: hostCapabilityMatrixPresentation(
            from: state.matrix,
            mutedReason: state.masterVolumeIsZero ? .masterVolumeZero : .eventDisabled,
            hostOrder: hostSurfacePresentationOrder(from: sourceRows)),
        hostFacts: facts)
}
