import ClaudioCore
import ClaudioGUICore
import Combine

/// App-lifetime typed selection shared by the unified Events & Sounds destination and its routes.
@MainActor
package final class EventSettingsWindowSelection: ObservableObject {
    @Published package private(set) var presentationState: SettingsEventPresentationState

    private var storage: Storage
    private var isPublishingState = false
    private var republishRequested = false

    package var route: EventSettingsWindowRoute { storage.route }
    package var routeRequestRevision: UInt64 { storage.routeRequestRevision }
    package var focusTarget: EventSettingsFocusTarget? { storage.focusTarget }

    package var unavailableRequestedScopeStoredValue: String? {
        route.unavailableRequestedScopeStoredValue
    }

    package init(route: EventSettingsWindowRoute = EventSettingsWindowRoute(scope: .global)) {
        let storage = Storage(route: route)
        self.storage = storage
        presentationState = storage.presentationState
    }

    package func select(_ route: EventSettingsWindowRoute) {
        guard storage.route != route else { return }
        storage.requestPreviewStop()
        storage.requestAISessionEnd()
        storage.route = route
        storage.routeRequestRevision &+= 1
        storage.focusTarget = nil
        publishState()
    }

    package func markCurrentScopeUnavailable() {
        guard storage.route.unavailableRequestedScopeStoredValue == nil else { return }
        storage.requestPreviewStop()
        storage.requestAISessionEnd()
        storage.route = EventSettingsWindowRoute(
            scope: storage.route.scope,
            event: storage.route.event,
            unavailableRequestedScopeStoredValue: storage.route.scope.storedValue)
        storage.routeRequestRevision &+= 1
        storage.focusTarget = nil
        publishState()
    }

    package func clearUnavailableScope() {
        guard storage.route.unavailableRequestedScopeStoredValue != nil else { return }
        storage.route = EventSettingsWindowRoute(
            scope: storage.route.scope,
            event: storage.route.event)
        storage.routeRequestRevision &+= 1
        publishState()
    }

    package func requestInitialFocus(scopes: [PanelSoundScopeID]) {
        if storage.route.unavailableRequestedScopeStoredValue != nil {
            storage.focusTarget = eventSettingsFirstFocusTarget(scopes: scopes)
        } else {
            storage.focusTarget = eventSettingsRouteFocusTarget(
                route: storage.route,
                scopes: scopes,
                events: Set(Event.allCases))
        }
        storage.focusRequestRevision &+= 1
        publishState()
    }

    package func beginPreviewSequence() -> UInt64 {
        storage.previewGeneration &+= 1
        storage.previewState = .running(generation: storage.previewGeneration)
        publishState()
        return storage.previewGeneration
    }

    package func completePreviewSequence(generation: UInt64) -> Bool {
        guard storage.previewState == .running(generation: generation) else { return false }
        storage.previewState = .idle
        publishState()
        return true
    }

    package func notePreviewStopped() {
        storage.previewState = .idle
        publishState()
    }

    package func requestPreviewStop() {
        storage.requestPreviewStop()
        publishState()
    }

    package func beginAISession(scope: PanelSoundScopeID, event: Event) {
        storage.aiSessionState = .active(scope: scope, event: event)
        publishState()
    }

    package func noteAISessionEnded() {
        storage.aiSessionState = .idle
        publishState()
    }

    package func leaveDestination() {
        storage.requestPreviewStop()
        storage.requestAISessionEnd()
        publishState()
    }

    private func publishState() {
        guard !isPublishingState else {
            republishRequested = true
            return
        }
        isPublishingState = true
        defer { isPublishingState = false }

        repeat {
            republishRequested = false
            let projection = storage.presentationState
            if presentationState != projection { presentationState = projection }
        } while republishRequested
    }

    private struct Storage {
        var route: EventSettingsWindowRoute
        var routeRequestRevision: UInt64 = 0
        var focusRequestRevision: UInt64 = 0
        var focusTarget: EventSettingsFocusTarget?
        var previewState: EventSettingsDestinationPreviewState = .idle
        var previewStopRequestRevision: UInt64 = 0
        var aiSessionState: EventSettingsDestinationAISessionState = .idle
        var aiSessionEndRequestRevision: UInt64 = 0
        var previewGeneration: UInt64 = 0

        var presentationState: SettingsEventPresentationState {
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

        mutating func requestPreviewStop() {
            previewState = .idle
            previewStopRequestRevision &+= 1
        }

        mutating func requestAISessionEnd() {
            aiSessionState = .idle
            aiSessionEndRequestRevision &+= 1
        }
    }
}
