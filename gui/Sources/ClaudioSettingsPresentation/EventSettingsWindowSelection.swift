import ClaudioCore
import ClaudioGUICore
import Combine

/// App-lifetime typed selection shared by the unified Events & Sounds destination and its routes.
@MainActor
package final class EventSettingsWindowSelection: ObservableObject {
    @Published private(set) var route: EventSettingsWindowRoute
    @Published private(set) var routeRequestRevision: UInt64
    @Published private(set) var focusRequestRevision: UInt64
    @Published private(set) var focusTarget: EventSettingsFocusTarget?
    @Published private(set) var previewState: EventSettingsDestinationPreviewState
    @Published private(set) var previewStopRequestRevision: UInt64
    @Published private(set) var aiSessionState: EventSettingsDestinationAISessionState
    @Published private(set) var aiSessionEndRequestRevision: UInt64
    @Published private(set) var stateRevision: UInt64 = 0

    private var coordinator: EventSettingsDestinationCoordinator
    private var isPublishingCoordinatorState = false
    private var coordinatorRepublishRequested = false

    package var unavailableRequestedScopeStoredValue: String? {
        route.unavailableRequestedScopeStoredValue
    }

    package init(route: EventSettingsWindowRoute = EventSettingsWindowRoute(scope: .global)) {
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

    package func select(_ route: EventSettingsWindowRoute) {
        guard coordinator.select(route) else { return }
        publishCoordinatorState()
    }

    package func markCurrentScopeUnavailable() {
        guard coordinator.markCurrentScopeUnavailable() else { return }
        publishCoordinatorState()
    }

    package func clearUnavailableScope() {
        guard coordinator.clearUnavailableScope() else { return }
        publishCoordinatorState()
    }

    package func requestInitialFocus(scopes: [PanelSoundScopeID]) {
        coordinator.requestInitialFocus(scopes: scopes)
        publishCoordinatorState()
    }

    package func beginPreviewSequence() -> UInt64 {
        let generation = coordinator.beginPreviewSequence()
        publishCoordinatorState()
        return generation
    }

    package func completePreviewSequence(generation: UInt64) -> Bool {
        guard coordinator.completePreviewSequence(generation: generation) else { return false }
        publishCoordinatorState()
        return true
    }

    package func notePreviewStopped() {
        coordinator.notePreviewStopped()
        publishCoordinatorState()
    }

    package func requestPreviewStop() {
        coordinator.requestPreviewStop()
        publishCoordinatorState()
    }

    package func beginAISession(scope: PanelSoundScopeID, event: Event) {
        coordinator.beginAISession(scope: scope, event: event)
        publishCoordinatorState()
    }

    package func noteAISessionEnded() {
        coordinator.noteAISessionEnded()
        publishCoordinatorState()
    }

    package func leaveDestination() {
        coordinator.leaveDestination()
        publishCoordinatorState()
    }

    package var presentationState: SettingsEventPresentationState {
        SettingsEventPresentationState(
            route: route,
            routeRequestRevision: routeRequestRevision,
            focusRequestRevision: focusRequestRevision,
            focusTarget: focusTarget,
            previewState: previewState,
            previewStopRequestRevision: previewStopRequestRevision,
            aiSessionState: aiSessionState,
            aiSessionEndRequestRevision: aiSessionEndRequestRevision)
    }

    private func publishCoordinatorState() {
        guard !isPublishingCoordinatorState else {
            coordinatorRepublishRequested = true
            return
        }
        isPublishingCoordinatorState = true
        defer { isPublishingCoordinatorState = false }

        repeat {
            coordinatorRepublishRequested = false
            let previous = presentationState
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
            if presentationState != previous {
                stateRevision &+= 1
            }
        } while coordinatorRepublishRequested
    }
}
