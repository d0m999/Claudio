import ClaudioCore
import Foundation

public enum EventSettingsDestinationPreviewState: Sendable, Equatable {
    case idle
    case running(generation: UInt64)
}

public enum EventSettingsDestinationAISessionState: Sendable, Equatable {
    case idle
    case active(scope: PanelSoundScopeID, event: Event)
}

/// Foundation-only lifecycle seam for the retained Events & Sounds destination. It coordinates
/// route identity, focus commands, preview cancellation and AI-session invalidation without
/// reading disk, Keychain or network facts and without becoming a second domain-state owner.
public struct EventSettingsDestinationCoordinator: Sendable, Equatable {
    public private(set) var route: EventSettingsWindowRoute
    public private(set) var routeRequestRevision: UInt64 = 0
    public private(set) var focusRequestRevision: UInt64 = 0
    public private(set) var focusTarget: EventSettingsFocusTarget?
    public private(set) var previewState: EventSettingsDestinationPreviewState = .idle
    public private(set) var previewStopRequestRevision: UInt64 = 0
    public private(set) var aiSessionState: EventSettingsDestinationAISessionState = .idle
    public private(set) var aiSessionEndRequestRevision: UInt64 = 0

    private var previewGeneration: UInt64 = 0

    public init(route: EventSettingsWindowRoute = EventSettingsWindowRoute(scope: .global)) {
        self.route = route
    }

    public var currentScope: PanelSoundScopeID { route.scope }
    public var currentEvent: Event? { route.event }

    @discardableResult
    public mutating func select(_ newRoute: EventSettingsWindowRoute) -> Bool {
        guard route != newRoute else { return false }
        requestPreviewStop()
        requestAISessionEnd()
        route = newRoute
        routeRequestRevision &+= 1
        focusTarget = nil
        return true
    }

    @discardableResult
    public mutating func markCurrentScopeUnavailable() -> Bool {
        guard route.unavailableRequestedScopeStoredValue == nil else { return false }
        requestPreviewStop()
        requestAISessionEnd()
        route = EventSettingsWindowRoute(
            scope: route.scope,
            event: route.event,
            unavailableRequestedScopeStoredValue: route.scope.storedValue)
        routeRequestRevision &+= 1
        focusTarget = nil
        return true
    }

    @discardableResult
    public mutating func clearUnavailableScope() -> Bool {
        guard route.unavailableRequestedScopeStoredValue != nil else { return false }
        route = EventSettingsWindowRoute(scope: route.scope, event: route.event)
        routeRequestRevision &+= 1
        return true
    }

    public mutating func requestInitialFocus(
        scopes: [PanelSoundScopeID],
        events: Set<Event> = Set(Event.allCases)
    ) {
        if route.unavailableRequestedScopeStoredValue != nil {
            focusTarget = eventSettingsFirstFocusTarget(scopes: scopes)
        } else {
            focusTarget = eventSettingsRouteFocusTarget(
                route: route,
                scopes: scopes,
                events: events)
        }
        focusRequestRevision &+= 1
    }

    public mutating func beginPreviewSequence() -> UInt64 {
        previewGeneration &+= 1
        previewState = .running(generation: previewGeneration)
        return previewGeneration
    }

    @discardableResult
    public mutating func completePreviewSequence(generation: UInt64) -> Bool {
        guard previewState == .running(generation: generation) else { return false }
        previewState = .idle
        return true
    }

    public mutating func notePreviewStopped() {
        previewState = .idle
    }

    public mutating func requestPreviewStop() {
        previewState = .idle
        previewStopRequestRevision &+= 1
    }

    public mutating func beginAISession(scope: PanelSoundScopeID, event: Event) {
        aiSessionState = .active(scope: scope, event: event)
    }

    public mutating func noteAISessionEnded() {
        aiSessionState = .idle
    }

    public mutating func requestAISessionEnd() {
        aiSessionState = .idle
        aiSessionEndRequestRevision &+= 1
    }

    public mutating func leaveDestination() {
        requestPreviewStop()
        requestAISessionEnd()
    }
}
