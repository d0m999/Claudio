import ClaudioCore
import ClaudioGUICore
import Combine

/// App-lifetime typed selection shared by the unified Events & Sounds destination and its routes.
@MainActor
final class EventSettingsWindowSelection: ObservableObject {
    @Published private(set) var route: EventSettingsWindowRoute
    @Published private(set) var routeRequestRevision: UInt64
    @Published private(set) var focusRequestRevision: UInt64
    @Published private(set) var focusTarget: EventSettingsFocusTarget?
    @Published private(set) var previewState: EventSettingsDestinationPreviewState
    @Published private(set) var previewStopRequestRevision: UInt64
    @Published private(set) var aiSessionState: EventSettingsDestinationAISessionState
    @Published private(set) var aiSessionEndRequestRevision: UInt64

    private var coordinator: EventSettingsDestinationCoordinator

    var unavailableRequestedScopeStoredValue: String? {
        route.unavailableRequestedScopeStoredValue
    }

    init(route: EventSettingsWindowRoute = EventSettingsWindowRoute(scope: .global)) {
        let coordinator = EventSettingsDestinationCoordinator(route: route)
        self.coordinator = coordinator
        self.route = coordinator.route
        routeRequestRevision = coordinator.routeRequestRevision
        focusRequestRevision = coordinator.focusRequestRevision
        focusTarget = coordinator.focusTarget
        previewState = coordinator.previewState
        previewStopRequestRevision = coordinator.previewStopRequestRevision
        aiSessionState = coordinator.aiSessionState
        aiSessionEndRequestRevision = coordinator.aiSessionEndRequestRevision
    }

    func select(_ route: EventSettingsWindowRoute) {
        guard coordinator.select(route) else { return }
        publishCoordinatorState()
    }

    func markCurrentScopeUnavailable() {
        guard coordinator.markCurrentScopeUnavailable() else { return }
        publishCoordinatorState()
    }

    func clearUnavailableScope() {
        guard coordinator.clearUnavailableScope() else { return }
        publishCoordinatorState()
    }

    func requestInitialFocus(scopes: [PanelSoundScopeID]) {
        coordinator.requestInitialFocus(scopes: scopes)
        publishCoordinatorState()
    }

    func beginPreviewSequence() -> UInt64 {
        let generation = coordinator.beginPreviewSequence()
        publishCoordinatorState()
        return generation
    }

    func completePreviewSequence(generation: UInt64) -> Bool {
        guard coordinator.completePreviewSequence(generation: generation) else { return false }
        publishCoordinatorState()
        return true
    }

    func notePreviewStopped() {
        coordinator.notePreviewStopped()
        publishCoordinatorState()
    }

    func requestPreviewStop() {
        coordinator.requestPreviewStop()
        publishCoordinatorState()
    }

    func beginAISession(scope: PanelSoundScopeID, event: Event) {
        coordinator.beginAISession(scope: scope, event: event)
        publishCoordinatorState()
    }

    func noteAISessionEnded() {
        coordinator.noteAISessionEnded()
        publishCoordinatorState()
    }

    func leaveDestination() {
        coordinator.leaveDestination()
        publishCoordinatorState()
    }

    private func publishCoordinatorState() {
        if route != coordinator.route { route = coordinator.route }
        if routeRequestRevision != coordinator.routeRequestRevision {
            routeRequestRevision = coordinator.routeRequestRevision
        }
        if focusTarget != coordinator.focusTarget { focusTarget = coordinator.focusTarget }
        if previewState != coordinator.previewState { previewState = coordinator.previewState }
        if aiSessionState != coordinator.aiSessionState {
            aiSessionState = coordinator.aiSessionState
        }
        if previewStopRequestRevision != coordinator.previewStopRequestRevision {
            previewStopRequestRevision = coordinator.previewStopRequestRevision
        }
        if aiSessionEndRequestRevision != coordinator.aiSessionEndRequestRevision {
            aiSessionEndRequestRevision = coordinator.aiSessionEndRequestRevision
        }
        if focusRequestRevision != coordinator.focusRequestRevision {
            focusRequestRevision = coordinator.focusRequestRevision
        }
    }
}
