import ClaudioCore
import ClaudioGUICore
import ClaudioLocalization
import Combine
import Foundation
import SoundPacksWindow

/// Single presentation-transaction owner for the retained Settings window. Domain facts remain
/// in their existing owners; this session owns only typed routing, focus/lifecycle debt and the
/// presentation-side orchestration that connects those owners.
@MainActor
package final class SettingsPresentationSession: ObservableObject {
    @Published
    package private(set) var state: SettingsPresentationState

    let dependencies: SettingsPresentationDependencies
    let actions: SettingsPresentationActions
    let eventSettingsSelection: EventSettingsWindowSelection
    let integrationsFocusCoordinator: IntegrationDestinationFocusCoordinator

    private var preferenceSnapshot: ClaudioPreferenceSnapshot
    private var loginProjection: LoginItemSettingsProjection
    private var availability: SettingsRouteAvailability
    private var routeResolution: SettingsRouteResolution
    private var explicitRouteRequestRevision: UInt64 = 0
    private var focusDebt: SettingsFocusDebt?
    private var windowPhase: SettingsWindowPhase = .hidden
    private var activeDestination: SettingsDestination?
    private var lifecycleDestination: SettingsDestination?
    private var platformActionFailure: SettingsPlatformActionFailure?
    private var pendingAnnouncement: SettingsPresentationAnnouncement?
    private var pendingSoundPackOwnerAnnouncement: SoundPackEditorAnnouncement?
    private var pendingSoundPackAnnouncementID: SoundPackEditorAnnouncement.ID?
    private var eventPresentation: SettingsEventPresentationState
    private var nextAnnouncementID: UInt64 = 0
    private var presentationRevision: UInt64 = 0
    private var isPresented = false
    private var isPerformingTransaction = false
    private var isPublishingProjection = false
    private var projectionRepublishRequested = false
    private var preferenceCancellable: AnyCancellable?
    private var soundPackProjectionCancellable: AnyCancellable?
    private var aboutSurfaceCancellable: AnyCancellable?
    private var aiGenerationCancellable: AnyCancellable?
    private var eventPresentationCancellable: AnyCancellable?

    package init(
        dependencies: SettingsPresentationDependencies,
        actions: SettingsPresentationActions
    ) {
        self.dependencies = dependencies
        self.actions = actions
        eventSettingsSelection = EventSettingsWindowSelection()
        integrationsFocusCoordinator = IntegrationDestinationFocusCoordinator()
        eventPresentation = eventSettingsSelection.presentationState
        preferenceSnapshot = dependencies.preferences.snapshot
        loginProjection = dependencies.loginItemSettings.projection
        let initialShell = SettingsSoundPackShellProjection(
            editorPresentation: dependencies.soundPacksEditorOwner.presentation,
            sourceRows: dependencies.hostIntegrations.content.sourceRows)
        availability = initialShell.availability
        pendingSoundPackOwnerAnnouncement = initialShell.pendingAnnouncement
        let initialRoute = SettingsRoute.destination(
            dependencies.preferences.lastSettingsDestination)
        routeResolution = resolveSettingsRoute(
            initialRoute, availability: initialShell.availability)
        state = Self.makeState(
            routeResolution: routeResolution,
            explicitRouteRequestRevision: 0,
            focusDebt: nil,
            windowPhase: .hidden,
            activeDestination: nil,
            eventPresentation: eventPresentation,
            preferenceSnapshot: preferenceSnapshot,
            loginProjection: loginProjection,
            platformActionFailure: nil,
            pendingAnnouncement: nil,
            presentationRevision: 0)

        preferenceCancellable = dependencies.preferences.$snapshot
            .sink { [weak self] snapshot in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.preferenceSnapshot = snapshot
                    self.publishProjection()
                }
            }
        soundPackProjectionCancellable = settingsSoundPackShellProjections(
            editor: dependencies.soundPacksEditorOwner,
            hostIntegrations: dependencies.hostIntegrations
        ).sink { [weak self] projection in
            MainActor.assumeIsolated {
                self?.applyAvailabilityProjection(projection)
            }
        }
        aboutSurfaceCancellable = dependencies.hostIntegrations.$safeSurfaceFacts
            .removeDuplicates()
            .sink { [weak self] surfaceFacts in
                MainActor.assumeIsolated {
                    self?.dependencies.aboutSettings.replaceSurfaceFacts(surfaceFacts)
                }
            }
        aiGenerationCancellable = dependencies.aiCueViewModel.$session
            .combineLatest(dependencies.aiCueViewModel.$generation.map { $0?.id })
            .removeDuplicates { lhs, rhs in
                lhs.0 == rhs.0 && lhs.1 == rhs.1
            }
            .dropFirst()
            .sink { [weak self] projection in
                MainActor.assumeIsolated {
                    guard let self, !self.isPerformingTransaction,
                        self.lifecycleDestination == .eventsAndSounds
                    else { return }
                    self.activateEventsEditor(
                        eventPresentation: self.eventPresentation,
                        aiSession: projection.0,
                        candidateGenerationID: projection.1)
                }
            }
        eventPresentationCancellable = eventSettingsSelection.$presentationState
            .dropFirst()
            .sink { [weak self] presentation in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let previousPresentation = self.eventPresentation
                    self.eventPresentation = presentation
                    if !self.isPerformingTransaction,
                        self.lifecycleDestination == .eventsAndSounds,
                        presentation.route != previousPresentation.route
                            || presentation.routeRequestRevision
                                != previousPresentation.routeRequestRevision
                    {
                        self.activateEventsEditor(
                            eventPresentation: presentation,
                            aiSession: self.dependencies.aiCueViewModel.session,
                            candidateGenerationID: self.dependencies.aiCueViewModel.generation?.id)
                    }
                    self.publishProjection()
                }
            }
    }

    @discardableResult
    package func send(
        _ command: SettingsPresentationCommand
    ) -> SettingsPresentationResult {
        switch command {
        case .present(let request):
            return present(request)
        case .route(let route):
            return routeTransaction(.route(route))
        case .setLanguageMode(let languageMode):
            dependencies.preferences.setLanguageMode(languageMode)
            return .routed
        case .setLoginItemEnabled(let enabled):
            setLoginItemEnabled(enabled)
            return .routed
        case .retryLoginItemOperation:
            retryLoginItemOperation()
            return .routed
        case .performPlatformAction(let action):
            return .platformAction(perform(action))
        case .eventAudibilityInputsChanged:
            actions.notifyEventAudibilityInputsChanged()
            return .routed
        case .announceDestinationUpdate(let sentence):
            guard !sentence.isEmpty else { return .unchanged }
            enqueueAnnouncement(.destinationUpdate(sentence))
            return .routed
        case .windowPhaseChanged(let phase):
            return changeWindowPhase(to: phase)
        case .acknowledgeFocus(let revision):
            guard focusDebt?.revision == revision else { return .unchanged }
            focusDebt = nil
            publishProjection()
            return .routed
        case .acknowledgeAnnouncement(let id, let didPost):
            return acknowledgePendingAnnouncement(id: id, didPost: didPost)
        case .windowWillClose:
            return closeWindow()
        }
    }

    private func refreshLoginItem() {
        let previousProjection = loginProjection
        dependencies.loginItemSettings.refresh()
        loginProjection = dependencies.loginItemSettings.projection
        guard loginProjection != previousProjection else { return }
        guard loginProjection.registration != previousProjection.registration else {
            publishProjection()
            return
        }
        enqueueAnnouncement(.loginItemStatus(loginProjection.registration))
    }

    private func setLoginItemEnabled(_ enabled: Bool) {
        dependencies.loginItemSettings.setEnabled(enabled)
        loginProjection = dependencies.loginItemSettings.projection
        enqueueLoginItemResult()
    }

    private func retryLoginItemOperation() {
        dependencies.loginItemSettings.retryFailedOperation()
        loginProjection = dependencies.loginItemSettings.projection
        enqueueLoginItemResult()
    }

    @discardableResult
    private func perform(_ action: SettingsPlatformAction) -> SettingsPlatformActionResult {
        let result = actions.perform(action)
        platformActionFailure =
            result == .performed
            ? nil : SettingsPlatformActionFailure(action: action, result: result)
        if result != .performed {
            enqueueAnnouncement(.platformAction(action, result))
        } else {
            publishProjection()
        }
        return result
    }

    #if DEBUG
    package func replaceAvailabilityForTesting(_ replacement: SettingsRouteAvailability) {
        applyAvailability(replacement)
    }
    #endif

    private func present(_ request: SettingsPresentationRequest) -> SettingsPresentationResult {
        let wasAlreadyPresented = isPresented
        if wasAlreadyPresented, request == .route(nil) {
            return .presented(wasAlreadyPresented: true)
        }
        isPresented = true
        let effectiveRequest: SettingsPresentationRequest
        if request == .route(nil) {
            effectiveRequest = .route(
                .destination(dependencies.preferences.lastSettingsDestination))
        } else {
            effectiveRequest = request
        }
        let result = routeTransaction(effectiveRequest)
        if case .rejected = result {
            return result
        }
        return .presented(wasAlreadyPresented: wasAlreadyPresented)
    }

    private func routeTransaction(
        _ request: SettingsPresentationRequest
    ) -> SettingsPresentationResult {
        let requestedRoute: SettingsRoute
        let eventShortcut: EventSettingsWindowRoute?
        switch request {
        case .route(let route):
            guard let route else { return .unchanged }
            requestedRoute = route
            eventShortcut = nil
        case .eventShortcut(let route):
            requestedRoute =
                route.unavailableRequestedScopeStoredValue == nil
                ? .events(scope: route.scope, event: route.event)
                : .destination(.eventsAndSounds)
            eventShortcut = route
        }

        let resolved = resolveSettingsRoute(requestedRoute, availability: availability)
        isPerformingTransaction = true
        defer {
            isPerformingTransaction = false
            publishProjection()
        }

        let previousLifecycleDestination = lifecycleDestination
        routeResolution = resolved
        if resolved.failure == nil {
            applyRoute(requestedRoute, eventShortcut: eventShortcut)
        }
        activeDestination = resolved.destination
        if resolved.failure == nil {
            if let previousLifecycleDestination,
                previousLifecycleDestination != resolved.destination
            {
                deactivate(previousLifecycleDestination)
            }
            lifecycleDestination = resolved.destination
            activate(
                resolved.destination,
                route: requestedRoute,
                requestsFocus: true)
        }
        explicitRouteRequestRevision &+= 1
        focusDebt = SettingsFocusDebt(
            revision: explicitRouteRequestRevision,
            destination: resolved.destination)
        if resolved.failure == nil {
            dependencies.preferences.setLastSettingsDestination(resolved.destination)
        }
        synchronizePendingSoundPackAnnouncement()
        if let failure = resolved.failure {
            return .rejected(failure)
        }
        return .routed
    }

    private func applyRoute(
        _ route: SettingsRoute,
        eventShortcut: EventSettingsWindowRoute?
    ) {
        switch route {
        case .integrations(let surface):
            if let host = HostID.productVisibleCases.first(where: { $0.surfaceID == surface }) {
                _ = dependencies.integrationsModel.selectHost(host)
            }
        case .events(let scope, let event):
            let eventRoute = eventShortcut ?? EventSettingsWindowRoute(scope: scope, event: event)
            let routeChanged = eventSettingsSelection.route != eventRoute
            eventSettingsSelection.select(eventRoute)
            if routeChanged {
                dependencies.soundPacksEditorNativeEffects.stopPreview(
                    owner: dependencies.soundPacksEditorOwner)
                dependencies.aiCueViewModel.endSession()
            }
            if eventRoute.unavailableRequestedScopeStoredValue == nil {
                dependencies.eventSettingsModel.selectSoundSurface(eventRoute.surface)
            }
        case .destination(.eventsAndSounds):
            if let eventShortcut {
                let routeChanged = eventSettingsSelection.route != eventShortcut
                eventSettingsSelection.select(eventShortcut)
                if routeChanged {
                    dependencies.soundPacksEditorNativeEffects.stopPreview(
                        owner: dependencies.soundPacksEditorOwner)
                    dependencies.aiCueViewModel.endSession()
                }
            }
        case .destination, .sounds:
            break
        }
    }

    private func activate(
        _ destination: SettingsDestination,
        route: SettingsRoute,
        requestsFocus: Bool
    ) {
        switch destination {
        case .integrations:
            if requestsFocus {
                requestIntegrationsFocus(route: route)
            }
            synchronizeIntegrationsLifecycle()
        case .eventsAndSounds:
            if requestsFocus {
                eventSettingsSelection.requestInitialFocus(scopes: eventSettingsFocusScopes)
            }
            activateEventsEditor()
        case .sounds:
            let soundRoute: SoundPacksWindowRoute =
                if case .sounds(let requested) = route { requested } else { .overview }
            _ = dependencies.soundPacksEditorOwner.send(
                .activate(
                    .sounds(
                        route: soundRoute,
                        requestRevision: explicitRouteRequestRevision + (requestsFocus ? 1 : 0))))
        case .general, .notifications, .display, .usage, .shortcuts, .about:
            break
        }
    }

    private func requestIntegrationsFocus(route: SettingsRoute) {
        if case .integrations(let surface) = route,
            let host = HostID.productVisibleCases.first(where: { $0.surfaceID == surface })
        {
            integrationsFocusCoordinator.requestFocus(.agent(host))
        } else {
            dependencies.integrationsModel.restorePreferredHost()
            integrationsFocusCoordinator.requestFocus(.title)
        }
    }

    private func activateEventsEditor() {
        activateEventsEditor(
            eventPresentation: eventPresentation,
            aiSession: dependencies.aiCueViewModel.session,
            candidateGenerationID: dependencies.aiCueViewModel.generation?.id)
    }

    private func activateEventsEditor(
        eventPresentation: SettingsEventPresentationState,
        aiSession: AICueComposerSession?,
        candidateGenerationID: UUID?
    ) {
        let route =
            if let aiSession {
                EventSettingsWindowRoute(scope: aiSession.scope, event: aiSession.event)
            } else {
                eventPresentation.route
            }
        _ = dependencies.soundPacksEditorOwner.send(
            .activate(
                .events(
                    route: route,
                    requestRevision: eventSettingsSelection.routeRequestRevision,
                    candidateGenerationID: candidateGenerationID)))
    }

    private func deactivate(
        _ destination: SettingsDestination,
        windowIsClosing: Bool = false
    ) {
        switch destination {
        case .integrations:
            dependencies.integrationsModel.noteWindowKeyState(false)
            dependencies.integrationsModel.noteWindowVisibility(false)
        case .eventsAndSounds:
            eventSettingsSelection.leaveDestination()
            dependencies.soundPacksEditorNativeEffects.handleLifecycle(
                windowIsClosing ? .settingsWindowWillClose : .eventsViewDisappeared,
                owner: dependencies.soundPacksEditorOwner)
            dependencies.aiCueViewModel.endSession()
        case .sounds:
            dependencies.soundPacksEditorNativeEffects.handleLifecycle(
                windowIsClosing ? .settingsWindowWillClose : .soundsViewDisappeared,
                owner: dependencies.soundPacksEditorOwner)
        case .general, .notifications, .display, .usage, .shortcuts, .about:
            break
        }
    }

    private func changeWindowPhase(
        to phase: SettingsWindowPhase
    ) -> SettingsPresentationResult {
        guard isPresented else { return .unchanged }
        guard windowPhase != phase else { return .unchanged }
        isPerformingTransaction = true
        windowPhase = phase
        if phase == .key {
            refreshLoginItem()
        }
        synchronizeIntegrationsLifecycle()
        synchronizePendingSoundPackAnnouncement()
        isPerformingTransaction = false
        publishProjection()
        return .routed
    }

    private func closeWindow() -> SettingsPresentationResult {
        guard isPresented else { return .unchanged }
        isPerformingTransaction = true
        windowPhase = .closing
        if let lifecycleDestination {
            deactivate(lifecycleDestination, windowIsClosing: true)
        }
        activeDestination = nil
        lifecycleDestination = nil
        isPresented = false
        windowPhase = .hidden
        focusDebt = nil
        if pendingSoundPackAnnouncementID != nil {
            pendingSoundPackAnnouncementID = nil
            pendingAnnouncement = nil
        }
        isPerformingTransaction = false
        publishProjection()
        return .closed
    }

    private func applyAvailabilityProjection(_ projection: SettingsSoundPackShellProjection) {
        pendingSoundPackOwnerAnnouncement = projection.pendingAnnouncement
        applyAvailability(projection.availability)
    }

    private func applyAvailability(_ replacement: SettingsRouteAvailability) {
        let priorAvailability = availability
        availability = replacement
        guard priorAvailability != availability else {
            synchronizePendingSoundPackAnnouncement()
            publishProjection()
            return
        }
        let previousResolution = routeResolution
        let resolved = resolveSettingsRoute(
            previousResolution.route,
            availability: availability)
        guard resolved != previousResolution else {
            synchronizePendingSoundPackAnnouncement()
            publishProjection()
            return
        }

        let wasPerformingTransaction = isPerformingTransaction
        isPerformingTransaction = true
        routeResolution = resolved
        if previousResolution.failure != nil, resolved.failure == nil, isPresented {
            applyRoute(resolved.route, eventShortcut: nil)
            if let lifecycleDestination,
                lifecycleDestination != resolved.destination
            {
                deactivate(lifecycleDestination)
            }
            lifecycleDestination = resolved.destination
            activate(resolved.destination, route: resolved.route, requestsFocus: false)
        }
        isPerformingTransaction = wasPerformingTransaction
        synchronizePendingSoundPackAnnouncement()
        publishProjection()
    }

    private func synchronizeIntegrationsLifecycle() {
        let visible =
            lifecycleDestination == .integrations
            && (windowPhase == .visibleNonKey || windowPhase == .key)
        dependencies.integrationsModel.noteWindowVisibility(visible)
        dependencies.integrationsModel.noteWindowKeyState(visible && windowPhase == .key)
    }

    private var eventSettingsFocusScopes: [PanelSoundScopeID] {
        panelSoundScopePresentations(
            sourceRows: dependencies.hostIntegrations.content.sourceRows,
            config: dependencies.eventSettingsModel.configState.resolvedConfig,
            language: preferenceSnapshot.language
        ).map(\.scope)
    }

    private func enqueueLoginItemResult() {
        if let failure = loginProjection.failure {
            enqueueAnnouncement(.loginItemFailure(failure))
        } else {
            enqueueAnnouncement(.loginItemStatus(loginProjection.registration))
        }
    }

    private func enqueueAnnouncement(
        _ meaning: SettingsPresentationAnnouncement.Meaning,
        soundPackID: SoundPackEditorAnnouncement.ID? = nil
    ) {
        nextAnnouncementID &+= 1
        pendingAnnouncement = SettingsPresentationAnnouncement(
            id: nextAnnouncementID,
            meaning: meaning)
        pendingSoundPackAnnouncementID = soundPackID
        publishProjection()
    }

    private func synchronizePendingSoundPackAnnouncement() {
        let isEligible =
            windowPhase == .key && activeDestination == .sounds
            && lifecycleDestination == .sounds && routeResolution.failure == nil
        guard isEligible else {
            if pendingSoundPackAnnouncementID != nil {
                pendingSoundPackAnnouncementID = nil
                pendingAnnouncement = nil
            }
            return
        }
        guard pendingAnnouncement == nil,
            let soundAnnouncement = pendingSoundPackOwnerAnnouncement
        else { return }
        let request = soundPacksEditorAccessibilityRequest(
            soundAnnouncement,
            language: preferenceSnapshot.language)
        enqueueAnnouncement(
            .soundPacks(request),
            soundPackID: soundAnnouncement.id)
    }

    private func acknowledgePendingAnnouncement(
        id: UInt64,
        didPost: Bool
    ) -> SettingsPresentationResult {
        guard didPost, pendingAnnouncement?.id == id else { return .unchanged }
        let soundPackID = pendingSoundPackAnnouncementID
        pendingAnnouncement = nil
        pendingSoundPackAnnouncementID = nil
        if let soundPackID {
            _ = dependencies.soundPacksEditorOwner.send(
                .acknowledgeAnnouncement(id: soundPackID, didPost: true))
        }
        synchronizePendingSoundPackAnnouncement()
        publishProjection()
        return .routed
    }

    private func publishProjection() {
        guard !isPerformingTransaction else {
            projectionRepublishRequested = true
            return
        }
        guard !isPublishingProjection else {
            projectionRepublishRequested = true
            return
        }
        isPublishingProjection = true
        defer { isPublishingProjection = false }

        repeat {
            projectionRepublishRequested = false
            let candidate = makeState(presentationRevision: presentationRevision)
            if candidate != state {
                presentationRevision &+= 1
                state = makeState(presentationRevision: presentationRevision)
            }
        } while projectionRepublishRequested
    }

    private func makeState(presentationRevision: UInt64) -> SettingsPresentationState {
        Self.makeState(
            routeResolution: routeResolution,
            explicitRouteRequestRevision: explicitRouteRequestRevision,
            focusDebt: focusDebt,
            windowPhase: windowPhase,
            activeDestination: activeDestination,
            eventPresentation: eventPresentation,
            preferenceSnapshot: preferenceSnapshot,
            loginProjection: loginProjection,
            platformActionFailure: platformActionFailure,
            pendingAnnouncement: pendingAnnouncement,
            presentationRevision: presentationRevision)
    }

    private static func makeState(
        routeResolution: SettingsRouteResolution,
        explicitRouteRequestRevision: UInt64,
        focusDebt: SettingsFocusDebt?,
        windowPhase: SettingsWindowPhase,
        activeDestination: SettingsDestination?,
        eventPresentation: SettingsEventPresentationState,
        preferenceSnapshot: ClaudioPreferenceSnapshot,
        loginProjection: LoginItemSettingsProjection,
        platformActionFailure: SettingsPlatformActionFailure?,
        pendingAnnouncement: SettingsPresentationAnnouncement?,
        presentationRevision: UInt64
    ) -> SettingsPresentationState {
        SettingsPresentationState(
            routeResolution: routeResolution,
            explicitRouteRequestRevision: explicitRouteRequestRevision,
            focusDebt: focusDebt,
            windowPhase: windowPhase,
            activeDestination: activeDestination,
            eventPresentation: eventPresentation,
            languageMode: preferenceSnapshot.languageMode,
            language: preferenceSnapshot.language,
            interfaceTextSize: preferenceSnapshot.interfaceTextSize,
            recoveryIssues: preferenceSnapshot.recoveryIssues,
            loginItemRegistration: loginProjection.registration,
            loginItemFailure: loginProjection.failure,
            platformActionFailure: platformActionFailure,
            pendingAnnouncement: pendingAnnouncement,
            presentationRevision: presentationRevision)
    }
}
