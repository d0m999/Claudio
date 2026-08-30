import ClaudioGUICore
import Combine

/// App-lifetime typed selection shared by the unified Events & Sounds destination and its routes.
@MainActor
final class EventSettingsWindowSelection: ObservableObject {
    @Published private(set) var route: EventSettingsWindowRoute
    @Published private(set) var focusRequestRevision = 0
    @Published private(set) var previewStopRequestRevision = 0

    var unavailableRequestedScopeStoredValue: String? {
        route.unavailableRequestedScopeStoredValue
    }

    init(route: EventSettingsWindowRoute = EventSettingsWindowRoute(scope: .global)) {
        self.route = route
    }

    func select(_ route: EventSettingsWindowRoute) {
        guard self.route != route else { return }
        self.route = route
    }

    func markCurrentScopeUnavailable() {
        guard route.unavailableRequestedScopeStoredValue == nil else { return }
        route = EventSettingsWindowRoute(
            scope: route.scope,
            event: route.event,
            unavailableRequestedScopeStoredValue: route.scope.storedValue)
    }

    func clearUnavailableScope() {
        guard route.unavailableRequestedScopeStoredValue != nil else { return }
        route = EventSettingsWindowRoute(scope: route.scope, event: route.event)
    }

    func requestInitialFocus() {
        focusRequestRevision += 1
    }

    func requestPreviewStop() {
        previewStopRequestRevision += 1
    }
}
