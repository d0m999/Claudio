import Combine

/// Monotonic hand-off from a retained AppKit owner or typed Settings route to the Integrations
/// surface's own `FocusState`. A nil target means the surface should choose its first legal item.
@MainActor
public final class IntegrationsWindowFocusCoordinator: ObservableObject {
    @Published public private(set) var requestRevision = 0
    @Published public private(set) var requestedTarget: IntegrationsWindowFocusTarget?
    private var latestIssuedRevision = 0
    private var consumedThroughRevision = 0

    public init() {}

    public func requestInitialFocus() {
        requestFocus(nil)
    }

    public func requestFocus(_ target: IntegrationsWindowFocusTarget?) {
        requestedTarget = target
        latestIssuedRevision = requestRevision + 1
        requestRevision = latestIssuedRevision
    }

    /// Claims the current request exactly once. A request issued while the destination is absent
    /// stays pending for the next mounted view; a previously handled deep link cannot replay when
    /// the user later returns through the generic sidebar destination.
    @discardableResult
    public func consumeRequest(_ revision: Int) -> Bool {
        guard revision == latestIssuedRevision, revision > consumedThroughRevision else {
            return false
        }
        consumedThroughRevision = revision
        return true
    }

    /// Cancels an unconsumed deep-link request without publishing a new focus event. The Settings
    /// shell can therefore focus its title for a generic destination without the embedded view
    /// competing for focus.
    public func cancelPendingRequest() {
        consumedThroughRevision = latestIssuedRevision
        requestedTarget = nil
    }
}
