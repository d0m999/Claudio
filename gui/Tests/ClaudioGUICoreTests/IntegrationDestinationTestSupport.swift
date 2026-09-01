import ClaudioCore
import ClaudioGUICore
import Foundation

enum IntegrationDestinationTestStatus: CaseIterable {
    case ready
    case awaitingActivation
    case legacy
    case notConnected
    case needsAttention

    var rowStatus: HostSourceRowStatus {
        switch self {
        case .ready: .ready
        case .awaitingActivation: .awaitingActivation
        case .legacy: .legacy
        case .notConnected: .notConnected
        case .needsAttention: .needsAttention
        }
    }
}

private let integrationDestinationTestInstallationID = UUID(
    uuidString: "00000000-0000-4000-8000-00000000D001")!

func integrationDestinationTestSnapshot(
    host: HostID,
    status: IntegrationDestinationTestStatus
) -> HostIntegrationSnapshot {
    guard
        let binding = HostCapabilityCatalog.bindings(for: host).first(where: \.isAudibleCapability)
    else {
        return HostIntegrationSnapshot(
            host: host,
            runtime: .ready,
            availability: .unavailable(reason: "fixture unavailable"),
            configuration: .notConfigured,
            writability: .unknown,
            activation: .none)
    }

    let evidence = HostReceiptEvidence(
        installationID: integrationDestinationTestInstallationID,
        nativeEvent: binding.nativeEvent!,
        event: binding.event,
        timestamp: Date(timeIntervalSince1970: 1_722_000_000),
        playbackResult: .played)
    switch status {
    case .ready:
        return HostIntegrationSnapshot(
            host: host,
            runtime: .ready,
            availability: .available,
            configuration: .configured,
            writability: .writable,
            activation: .observed(evidence),
            latestReceipt: evidence,
            installationID: integrationDestinationTestInstallationID)
    case .awaitingActivation:
        return HostIntegrationSnapshot(
            host: host,
            runtime: .ready,
            availability: .available,
            configuration: .configured,
            writability: .writable,
            activation: .awaitingReceipt(
                installationID: integrationDestinationTestInstallationID),
            installationID: integrationDestinationTestInstallationID)
    case .legacy:
        return HostIntegrationSnapshot(
            host: host,
            runtime: .ready,
            availability: .available,
            configuration: .legacyConnected,
            writability: .writable,
            activation: .none,
            installationID: integrationDestinationTestInstallationID)
    case .notConnected:
        return .disconnected(host: host)
    case .needsAttention:
        return HostIntegrationSnapshot(
            host: host,
            runtime: .ready,
            availability: .available,
            configuration: .conflict(reason: "fixture connection conflict"),
            writability: .writable,
            activation: .none,
            operation: .failed(reason: "fixture connection conflict"),
            installationID: integrationDestinationTestInstallationID)
    }
}

func integrationDestinationTestState(
    statuses: [HostID: IntegrationDestinationTestStatus] = [:],
    masterVolumeIsZero: Bool = false
) -> HostIntegrationPresentationState {
    let snapshots = HostID.productVisibleCases.map { host in
        integrationDestinationTestSnapshot(
            host: host,
            status: statuses[host] ?? .ready)
    }
    let capabilities = Dictionary(
        uniqueKeysWithValues: HostID.productVisibleCases.map {
            ($0, HostCapabilityCatalog.bindings(for: $0))
        })
    let enabledEvents = Dictionary(
        uniqueKeysWithValues: Event.allCases.map { ($0, !masterVolumeIsZero) })
    let matrix = AudibilityMatrix.make(
        snapshots: snapshots,
        capabilities: capabilities,
        soundCoverage: Dictionary(uniqueKeysWithValues: Event.allCases.map { ($0, true) }),
        enabledEvents: enabledEvents)
    return HostIntegrationPresentationState(
        snapshots: snapshots,
        matrix: matrix,
        masterVolumeIsZero: masterVolumeIsZero)
}

func integrationDestinationTestContent(
    statuses: [HostID: IntegrationDestinationTestStatus] = [:],
    configurationSources: [HostID: String] = [
        .claudeCode: "~/.claude/settings.json",
        .codex: "~/.codex/hooks.json",
        .workBuddy: "~/.workbuddy/settings.json",
    ],
    masterVolumeIsZero: Bool = false
) -> IntegrationDestinationContent {
    let state = integrationDestinationTestState(
        statuses: statuses,
        masterVolumeIsZero: masterVolumeIsZero)
    return integrationDestinationContent(
        state: state,
        configurationSources: configurationSources)
}

func integrationDestinationTestOutcome(
    content: IntegrationDestinationContent,
    kind: IntegrationsFeedbackKind = .success,
    message: String = "fixture complete"
) -> IntegrationDestinationActionOutcome {
    IntegrationDestinationActionOutcome(
        content: content,
        feedbackKind: kind,
        feedbackMessage: message)
}

actor IntegrationDestinationTestGate {
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func open() {
        continuation?.resume()
        continuation = nil
    }
}

actor IntegrationDestinationTestRecorder<Value: Sendable> {
    private var values: [Value] = []

    func append(_ value: Value) { values.append(value) }

    func all() -> [Value] { values }
}
