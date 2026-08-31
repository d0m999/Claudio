import ClaudioCore
import Combine

/// Focus targets for the prototype-aligned Integrations destination. The destination has one
/// vertical reading order; selection and Toggle remain separate focusable controls.
public enum IntegrationDestinationFocusTarget: Sendable, Hashable {
    case title
    case agent(HostID)
    case toggle(HostID)
    case connectionRow(IntegrationConnectionRowKind)
    case copyConfigurationSource(HostID)
    case dismissFeedback(revision: UInt64)
}

/// Monotonic hand-off from the retained Settings owner to the destination's FocusState.
@MainActor
public final class IntegrationDestinationFocusCoordinator: ObservableObject {
    @Published public private(set) var requestRevision = 0
    @Published public private(set) var requestedTarget: IntegrationDestinationFocusTarget?
    private var latestIssuedRevision = 0
    private var consumedThroughRevision = 0

    public init() {}

    public func requestInitialFocus() {
        requestFocus(nil)
    }

    public func requestFocus(_ target: IntegrationDestinationFocusTarget?) {
        requestedTarget = target
        latestIssuedRevision = requestRevision + 1
        requestRevision = latestIssuedRevision
    }

    @discardableResult
    public func consumeRequest(_ revision: Int) -> Bool {
        guard revision == latestIssuedRevision, revision > consumedThroughRevision else {
            return false
        }
        consumedThroughRevision = revision
        return true
    }

    public func cancelPendingRequest() {
        consumedThroughRevision = latestIssuedRevision
        requestedTarget = nil
    }
}
