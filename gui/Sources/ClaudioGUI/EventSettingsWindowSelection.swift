import ClaudioGUICore
import Combine

/// App-lifetime typed selection shared by the unified Events & Sounds destination and its routes.
@MainActor
final class EventSettingsWindowSelection: ObservableObject {
    @Published private(set) var route: EventSettingsWindowRoute
    @Published private(set) var focusRequestRevision = 0

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

    func resolveUnavailableScope(
        _ requestedScope: PanelSoundScopeID,
        to fallback: PanelSoundScopeID
    ) {
        route = EventSettingsWindowRoute(
            scope: fallback,
            unavailableRequestedScopeStoredValue: requestedScope.storedValue)
    }

    func requestInitialFocus() {
        focusRequestRevision += 1
    }
}
