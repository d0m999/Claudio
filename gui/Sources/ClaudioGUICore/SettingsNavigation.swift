import ClaudioCore
import ClaudioLocalization
import Combine
import Foundation

/// The fixed top-level identity and order of Claudio's unified Settings navigation.
/// Raw values are stable route tokens; user-visible and accessibility names stay localized.
public enum SettingsDestination: String, CaseIterable, Codable, Sendable, Hashable, Identifiable {
    case general
    case integrations
    case eventsAndSounds = "events-and-sounds"
    case notifications
    case display
    case sounds
    case usage
    case shortcuts
    case about

    public var id: String { rawValue }

    public var localizationKey: ClaudioL10nKey {
        switch self {
        case .general: .settingsDestinationGeneral
        case .integrations: .settingsDestinationIntegrations
        case .eventsAndSounds: .settingsDestinationEventsAndSounds
        case .notifications: .settingsDestinationNotifications
        case .display: .settingsDestinationDisplay
        case .sounds: .settingsDestinationSounds
        case .usage: .settingsDestinationUsage
        case .shortcuts: .settingsDestinationShortcuts
        case .about: .settingsDestinationAbout
        }
    }

    public func localizedName(language: ClaudioAppLanguage) -> String {
        ClaudioL10n(language: language).text(localizationKey)
    }
}

/// A unified Settings request. Associated values are domain IDs already owned by ClaudioCore or
/// ClaudioGUICore; display names, view state, and model objects never cross this routing seam.
public enum SettingsRoute: Sendable, Equatable, Hashable {
    case destination(SettingsDestination)
    case integrations(surface: HostSurfaceID)
    case events(scope: PanelSoundScopeID, event: Event?)
    case sounds(SoundPacksWindowRoute)

    public var destination: SettingsDestination {
        switch self {
        case .destination(let destination): destination
        case .integrations: .integrations
        case .events: .eventsAndSounds
        case .sounds: .sounds
        }
    }

    /// Debug and test projection that deliberately exposes only stable route tokens.
    public var stableIdentityComponents: [String] {
        switch self {
        case .destination(let destination):
            return [destination.rawValue]
        case .integrations(let surface):
            return [SettingsDestination.integrations.rawValue, surface.rawValue]
        case .events(let scope, let event):
            return [SettingsDestination.eventsAndSounds.rawValue, scope.storedValue]
                + (event.map { [$0.cliName] } ?? [])
        case .sounds(let route):
            let scope = route.surface?.rawValue ?? PanelSoundScopeID.global.storedValue
            guard let target = route.editTarget else {
                return [SettingsDestination.sounds.rawValue, scope]
            }
            return [
                SettingsDestination.sounds.rawValue, scope, target.packID, target.event.cliName,
            ]
        }
    }
}

/// Current stable identities that a Settings deep link may target. Absence means stale, not an
/// instruction to choose another Surface, scope, or pack.
public struct SettingsRouteAvailability: Sendable, Equatable {
    public let integrationSurfaces: Set<HostSurfaceID>
    public let eventScopes: Set<PanelSoundScopeID>
    public let soundScopes: Set<PanelSoundScopeID>
    public let soundPackIDs: Set<String>
    /// A missing pack ID is stale only after the shared library has published a fresh ready
    /// snapshot. During first hydration or a refresh failure the route remains pending so a
    /// temporarily empty projection cannot reject a valid deep link.
    public let soundPackSnapshotIsFresh: Bool
    public let events: Set<Event>

    public init(
        integrationSurfaces: Set<HostSurfaceID>,
        eventScopes: Set<PanelSoundScopeID>,
        soundScopes: Set<PanelSoundScopeID>,
        soundPackIDs: Set<String>,
        soundPackSnapshotIsFresh: Bool = true,
        events: Set<Event>
    ) {
        self.integrationSurfaces = integrationSurfaces
        self.eventScopes = eventScopes
        self.soundScopes = soundScopes
        self.soundPackIDs = soundPackIDs
        self.soundPackSnapshotIsFresh = soundPackSnapshotIsFresh
        self.events = events
    }

    public static let empty = SettingsRouteAvailability(
        integrationSurfaces: [],
        eventScopes: [.global],
        soundScopes: [.global],
        soundPackIDs: [],
        soundPackSnapshotIsFresh: false,
        events: Set(Event.allCases))
}

public enum SettingsRouteFailure: Sendable, Equatable {
    case invalidSurface(HostSurfaceID)
    case staleSurface(HostSurfaceID)
    case staleSoundScope(PanelSoundScopeID)
    case staleEvent(Event)
    case invalidSoundPackID
    case staleSoundPack(String)
}

/// Resolution always retains the requested route and therefore its corresponding destination.
/// A failure is presentation state for that destination, never a fallback route.
public struct SettingsRouteResolution: Sendable, Equatable {
    public let route: SettingsRoute
    public let failure: SettingsRouteFailure?

    public init(route: SettingsRoute, failure: SettingsRouteFailure?) {
        self.route = route
        self.failure = failure
    }

    public var destination: SettingsDestination { route.destination }
}

public func resolveSettingsRoute(
    _ route: SettingsRoute,
    availability: SettingsRouteAvailability
) -> SettingsRouteResolution {
    let failure: SettingsRouteFailure?
    switch route {
    case .destination:
        failure = nil
    case .integrations(let surface):
        failure = settingsSurfaceFailure(
            surface,
            availableSurfaces: availability.integrationSurfaces)
    case .events(let scope, let event):
        if let scopeFailure = settingsScopeFailure(
            scope,
            availableScopes: availability.eventScopes)
        {
            failure = scopeFailure
        } else if let event, !availability.events.contains(event) {
            failure = .staleEvent(event)
        } else {
            failure = nil
        }
    case .sounds(let soundsRoute):
        if let surface = soundsRoute.surface,
            let scopeFailure = settingsScopeFailure(
                .surface(surface),
                availableScopes: availability.soundScopes)
        {
            failure = scopeFailure
        } else if let packID = soundsRoute.editTarget?.packID,
            packID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            failure = .invalidSoundPackID
        } else if availability.soundPackSnapshotIsFresh,
            let packID = soundsRoute.editTarget?.packID,
            !availability.soundPackIDs.contains(packID)
        {
            failure = .staleSoundPack(packID)
        } else if let event = soundsRoute.editTarget?.event,
            !availability.events.contains(event)
        {
            failure = .staleEvent(event)
        } else {
            failure = nil
        }
    }
    return SettingsRouteResolution(route: route, failure: failure)
}

private func settingsScopeFailure(
    _ scope: PanelSoundScopeID,
    availableScopes: Set<PanelSoundScopeID>
) -> SettingsRouteFailure? {
    if let surface = scope.surface {
        return settingsSurfaceFailure(
            surface,
            availableSurfaces: Set(availableScopes.compactMap(\.surface)))
    }
    return availableScopes.contains(.global) ? nil : .staleSoundScope(.global)
}

private func settingsSurfaceFailure(
    _ surface: HostSurfaceID,
    availableSurfaces: Set<HostSurfaceID>
) -> SettingsRouteFailure? {
    guard HostID.productVisibleCases.contains(where: { $0.surfaceID == surface }) else {
        return .invalidSurface(surface)
    }
    return availableSurfaces.contains(surface) ? nil : .staleSurface(surface)
}

/// Observable decisions for an app-lifetime retained Settings owner. Re-showing a visible window
/// without a route is idempotent; every explicit route request (including an identical deep link)
/// gets a new revision. Closing consumes the most recent handback exactly once.
public struct SettingsWindowLifecycle<Handback> {
    public private(set) var isPresented = false
    public private(set) var presentationRevision: UInt64 = 0
    public private(set) var routeRequestRevision: UInt64 = 0
    public private(set) var resolution: SettingsRouteResolution

    private var pendingHandback: Handback?

    public init(initialRoute: SettingsRoute = .destination(.general)) {
        resolution = resolveSettingsRoute(initialRoute, availability: .empty)
    }

    @discardableResult
    public mutating func present(
        route: SettingsRoute? = nil,
        availability: SettingsRouteAvailability,
        handback: Handback? = nil
    ) -> SettingsWindowPresentation {
        let wasAlreadyPresented = isPresented
        isPresented = true
        presentationRevision &+= 1
        if let handback {
            pendingHandback = handback
        }

        let requestedRoute = route ?? resolution.route
        resolution = resolveSettingsRoute(requestedRoute, availability: availability)
        if route != nil || !wasAlreadyPresented {
            routeRequestRevision &+= 1
        }
        return SettingsWindowPresentation(
            wasAlreadyPresented: wasAlreadyPresented,
            presentationRevision: presentationRevision,
            routeRequestRevision: routeRequestRevision,
            resolution: resolution)
    }

    public mutating func refresh(availability: SettingsRouteAvailability) {
        resolution = resolveSettingsRoute(resolution.route, availability: availability)
    }

    @discardableResult
    public mutating func request(
        route: SettingsRoute,
        availability: SettingsRouteAvailability
    ) -> SettingsWindowPresentation {
        resolution = resolveSettingsRoute(route, availability: availability)
        routeRequestRevision &+= 1
        return SettingsWindowPresentation(
            wasAlreadyPresented: isPresented,
            presentationRevision: presentationRevision,
            routeRequestRevision: routeRequestRevision,
            resolution: resolution)
    }

    public mutating func close() -> Handback? {
        guard isPresented else { return nil }
        isPresented = false
        let handback = pendingHandback
        pendingHandback = nil
        return handback
    }
}

public struct SettingsWindowPresentation: Sendable, Equatable {
    public let wasAlreadyPresented: Bool
    public let presentationRevision: UInt64
    public let routeRequestRevision: UInt64
    public let resolution: SettingsRouteResolution
}

/// Combine adapter around ``SettingsWindowLifecycle``. Publishing is equality-guarded so an
/// idempotent re-show cannot emit an unchanged revision and steal keyboard focus back to content.
@MainActor
public final class SettingsWindowPresentationModel<Handback>: ObservableObject {
    @Published public private(set) var resolution: SettingsRouteResolution
    @Published public private(set) var routeRequestRevision: UInt64 = 0

    private var availability: SettingsRouteAvailability
    private let preferences: ClaudioPreferences?
    private var lifecycle: SettingsWindowLifecycle<Handback>

    public init(
        initialRoute: SettingsRoute? = nil,
        preferences: ClaudioPreferences? = nil,
        availability: SettingsRouteAvailability
    ) {
        self.availability = availability
        self.preferences = preferences
        let restoredRoute =
            initialRoute
            ?? .destination(preferences?.lastSettingsDestination ?? .general)
        lifecycle = SettingsWindowLifecycle(initialRoute: restoredRoute)
        resolution = resolveSettingsRoute(restoredRoute, availability: availability)
    }

    @discardableResult
    public func present(
        route: SettingsRoute? = nil,
        handback: Handback? = nil
    ) -> SettingsWindowPresentation {
        let restoredRoute =
            route == nil && !lifecycle.isPresented
            ? SettingsRoute.destination(preferences?.lastSettingsDestination ?? .general)
            : route
        let presentation = lifecycle.present(
            route: restoredRoute,
            availability: availability,
            handback: handback)
        if let route, presentation.resolution.failure == nil {
            preferences?.setLastSettingsDestination(route.destination)
        }
        publish(presentation)
        return presentation
    }

    public func request(_ route: SettingsRoute) {
        let presentation = lifecycle.request(route: route, availability: availability)
        if presentation.resolution.failure == nil {
            preferences?.setLastSettingsDestination(route.destination)
        }
        publish(presentation)
    }

    /// Re-resolves the retained stable route against newly published app facts. This never
    /// increments the explicit route-request revision, so a background library refresh cannot
    /// steal keyboard focus; it only changes visible pending/failure state in place.
    public func updateAvailability(_ availability: SettingsRouteAvailability) {
        guard self.availability != availability else { return }
        self.availability = availability
        lifecycle.refresh(availability: availability)
        if resolution != lifecycle.resolution {
            resolution = lifecycle.resolution
        }
    }

    public func close() -> Handback? {
        lifecycle.close()
    }

    private func publish(_ presentation: SettingsWindowPresentation) {
        if resolution != presentation.resolution {
            resolution = presentation.resolution
        }
        if routeRequestRevision != presentation.routeRequestRevision {
            routeRequestRevision = presentation.routeRequestRevision
        }
    }
}

public enum SettingsWindowGeometry {
    public static let defaultWidth: Double = 1_240
    public static let defaultHeight: Double = 820
    public static let minimumWidth: Double = 960
    public static let minimumHeight: Double = 640
    public static let compactSidebarWidth: Double = 220
    public static let standardSidebarWidth: Double = 252
    public static let expandedSidebarWidth: Double = 276
    public static let compactSidebarWindowThreshold: Double = 1_040
}

public func settingsSidebarWidth(
    windowWidth: Double,
    interfaceTextSize: ClaudioInterfaceTextSize
) -> Double {
    if interfaceTextSize == .maximum {
        return windowWidth <= SettingsWindowGeometry.compactSidebarWindowThreshold
            ? SettingsWindowGeometry.standardSidebarWidth
            : SettingsWindowGeometry.expandedSidebarWidth
    }
    return windowWidth <= SettingsWindowGeometry.compactSidebarWindowThreshold
        ? SettingsWindowGeometry.compactSidebarWidth
        : SettingsWindowGeometry.standardSidebarWidth
}

public enum SettingsSidebarSectionID: String, Sendable, CaseIterable, Identifiable {
    case primary
    case advanced
    case product

    public var id: String { rawValue }
}

public struct SettingsSidebarSection: Sendable, Equatable, Identifiable {
    public let id: SettingsSidebarSectionID
    public let destinations: [SettingsDestination]

    public init(id: SettingsSidebarSectionID, destinations: [SettingsDestination]) {
        self.id = id
        self.destinations = destinations
    }
}

public func settingsSidebarSections(
    availableDestinations: [SettingsDestination]
) -> [SettingsSidebarSection] {
    let available = Set(availableDestinations)
    return [
        SettingsSidebarSection(
            id: .primary,
            destinations: [
                .general, .integrations, .eventsAndSounds, .notifications, .display, .sounds,
                .usage,
            ].filter(available.contains)),
        SettingsSidebarSection(
            id: .advanced,
            destinations: [SettingsDestination.shortcuts].filter(available.contains)),
        SettingsSidebarSection(
            id: .product,
            destinations: [SettingsDestination.about].filter(available.contains)),
    ].filter { !$0.destinations.isEmpty }
}

public enum SettingsSidebarMoveDirection: Sendable {
    case previous
    case next
}

public func settingsSidebarDestination(
    moving direction: SettingsSidebarMoveDirection,
    from current: SettingsDestination,
    availableDestinations: [SettingsDestination]
) -> SettingsDestination {
    let ordered = SettingsDestination.allCases.filter(Set(availableDestinations).contains)
    guard let index = ordered.firstIndex(of: current), !ordered.isEmpty else {
        return ordered.first ?? current
    }
    switch direction {
    case .previous:
        return ordered[max(ordered.startIndex, index - 1)]
    case .next:
        return ordered[min(ordered.index(before: ordered.endIndex), index + 1)]
    }
}

/// Visibility facts for an editor embedded in the retained Settings window. Callers pass the
/// destination emitted by the route publisher rather than synchronously reading an `@Published`
/// property that may still contain its pre-publication value.
public struct SettingsEmbeddedDestinationState: Sendable, Equatable {
    public let isVisible: Bool
    public let isKey: Bool

    public init(isVisible: Bool, isKey: Bool) {
        self.isVisible = isVisible
        self.isKey = isKey
    }
}

public func settingsEmbeddedDestinationState(
    selectedDestination: SettingsDestination,
    embeddedDestination: SettingsDestination,
    windowIsVisible: Bool,
    windowIsKey: Bool
) -> SettingsEmbeddedDestinationState {
    let isVisible = windowIsVisible && selectedDestination == embeddedDestination
    return SettingsEmbeddedDestinationState(
        isVisible: isVisible,
        isKey: isVisible && windowIsKey)
}

public enum SettingsWindowFocusTarget: Sendable, Equatable, Hashable {
    case sidebar(SettingsDestination)
    case title(SettingsDestination)
    case firstAction(SettingsDestination)
    case shortcutAction(GlobalShortcutAction)
}

public func settingsWindowFocusOrder(
    selectedDestination: SettingsDestination
) -> [SettingsWindowFocusTarget] {
    var order = SettingsDestination.allCases.map(SettingsWindowFocusTarget.sidebar)
    order.append(.title(selectedDestination))
    // Embedded destinations own route-aware focus identity spaces. Inventing a Settings-shell
    // first action for them would point at no rendered control and compete with their
    // initial-focus requests.
    if selectedDestination != .integrations
        && selectedDestination != .eventsAndSounds
        && selectedDestination != .sounds
    {
        order.append(.firstAction(selectedDestination))
    }
    return order
}
