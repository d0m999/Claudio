import ClaudioCore
import ClaudioGUICore
import Combine
import Foundation

package struct EventSettingsPreviewFailure: Equatable {
    package let scope: PanelSoundScopeID
    package let packID: String
    package let event: Event
    package let reason: EventPreviewAttemptFailure
}

/// The original control values are a guard for a deliberate retry after a lock failure.
/// A readback that changed the target requires the user to make a new choice instead.
package struct EventSettingsWriteRetry: Equatable {
    package enum Operation: Equatable {
        case pack(before: String, requested: String)
        case volume(before: Double, requested: Double)
        case event(Event, before: Bool)
        case surfaces(before: [HostSurfaceID], requested: [HostSurfaceID])
    }

    package let scope: PanelSoundScopeID
    package let workspaceDirectory: WorkspaceDirectory?
    package let operation: Operation

    package init(
        scope: PanelSoundScopeID,
        workspaceDirectory: WorkspaceDirectory?,
        operation: Operation
    ) {
        self.scope = scope
        self.workspaceDirectory = workspaceDirectory
        self.operation = operation
    }

    package func canRetry(
        route: EventSettingsWindowRoute,
        selectedScope: PanelSoundScopeID,
        configState: PanelConfigState,
        config: ClaudioConfig,
        workspaceRule: WorkspaceSoundRule?
    ) -> Bool {
        guard case .operational = configState else { return false }
        guard route.scope == scope, route.unavailableRequestedScopeStoredValue == nil,
            selectedScope == scope
        else { return false }
        if let workspaceID = scope.workspaceID {
            guard workspaceRule?.id == workspaceID,
                workspaceRule?.directory == workspaceDirectory,
                workspaceRule?.profile?.isValid == true
            else { return false }
        } else if workspaceDirectory != nil {
            return false
        }
        switch operation {
        case .pack(let before, _): return config.selectedPack == before
        case .volume(let before, _): return config.masterVolume == before
        case .event(let event, let before): return config.isEnabled(event) == before
        case .surfaces(let before, _): return workspaceRule?.surfaces == before
        }
    }
}

/// App-lifetime typed selection shared by the unified Events & Sounds destination and its routes.
@MainActor
package final class EventSettingsWindowSelection: ObservableObject {
    @Published package private(set) var presentationState: SettingsEventPresentationState
    @Published package private(set) var deletionPresentation = WorkspaceDeletionPresentation()
    @Published package private(set) var previewFailure: EventSettingsPreviewFailure?
    @Published package private(set) var writeRetry: EventSettingsWriteRetry?
    @Published package private(set) var conflictWasReadBack = false
    @Published package private(set) var conflictRecoveryFiles: [URL] = []

    private var storage: Storage
    private var isPublishingState = false
    private var republishRequested = false
    private var consumedDeleteRequest: WorkspaceDeletionRequest?

    package var route: EventSettingsWindowRoute { storage.route }
    package var routeRequestRevision: UInt64 { storage.routeRequestRevision }
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
        storage.leaveDestination()
        deletionPresentation = WorkspaceDeletionPresentation()
        previewFailure = nil
        writeRetry = nil
        conflictWasReadBack = false
        conflictRecoveryFiles = []
        consumedDeleteRequest = nil
        storage.route = route
        storage.routeRequestRevision &+= 1
        storage.focusTarget = nil
        publishState()
    }

    package func markCurrentScopeUnavailable() {
        guard storage.route.unavailableRequestedScopeStoredValue == nil else { return }
        storage.leaveDestination()
        deletionPresentation.pending = nil
        previewFailure = nil
        writeRetry = nil
        conflictWasReadBack = false
        conflictRecoveryFiles = []
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

    @discardableResult
    package func requestDeletion(of rule: WorkspaceSoundRule) -> Bool {
        guard storage.route.scope == .workspace(rule.id),
            storage.route.unavailableRequestedScopeStoredValue == nil,
            deletionPresentation.pending == nil, consumedDeleteRequest == nil
        else { return false }
        deletionPresentation = WorkspaceDeletionPresentation(
            pending: WorkspaceDeletionRequest(target: WorkspaceSoundDeleteTarget(rule: rule)),
            feedback: nil)
        return true
    }

    package func cancelDeletion() {
        guard let pending = deletionPresentation.pending else { return }
        deletionPresentation.pending = nil
        if storage.route.scope == .workspace(pending.target.id) {
            requestFocus(.workspaceRemove(pending.target.id))
        }
    }

    /// Clear the pending request before any disk I/O, so a second action cannot submit it again.
    package func consumeDeletion(_ request: WorkspaceDeletionRequest) -> Bool {
        guard deletionPresentation.pending == request,
            storage.route.scope == .workspace(request.target.id),
            storage.route.unavailableRequestedScopeStoredValue == nil
        else { return false }
        deletionPresentation.pending = nil
        consumedDeleteRequest = request
        return true
    }

    /// The caller has completed the existing config transaction and its conflict readback.
    /// A route changed during that call must not be overwritten by the old deletion result.
    @discardableResult
    package func finishDeletion(
        _ request: WorkspaceDeletionRequest,
        succeeded: Bool,
        error: WorkspaceSoundError?,
        configState: PanelConfigState
    ) -> Bool {
        guard consumedDeleteRequest == request,
            storage.route.scope == .workspace(request.target.id)
        else { return false }
        consumedDeleteRequest = nil
        let target = request.target
        if succeeded {
            select(EventSettingsWindowRoute(scope: .global))
            deletionPresentation.feedback = .succeeded(target)
            requestFocus(.scope(.global))
            return true
        }
        let reason = error ?? .configFailure
        let readback: WorkspaceDeleteReadback? =
            reason.isPublishedConflict || reason == .staleRule
            ? WorkspaceDeleteReadback(target: target, configState: configState) : nil
        if reason == .staleRule || readback == .absent || readback == .replaced {
            markCurrentScopeUnavailable()
        }
        deletionPresentation.feedback = .failed(
            target, reason,
            reason.isPublishedConflict || reason == .staleRule || readback == .replaced
                ? readback : nil)
        requestFocus(.workspaceDeleteFeedback)
        return false
    }

    package func refreshDeletionReadback(configState: PanelConfigState) {
        guard case .failed(let target, let error, _) = deletionPresentation.feedback,
            error.isPublishedConflict || error == .staleRule
        else {
            return
        }
        let readback = WorkspaceDeleteReadback(target: target, configState: configState)
        if error == .staleRule || readback == .absent || readback == .replaced {
            markCurrentScopeUnavailable()
        }
        deletionPresentation.feedback = .failed(target, error, readback)
        requestFocus(.workspaceDeleteFeedback)
    }

    /// A retry of deletion opens a new confirmation only for the same read-back rule identity.
    /// It never submits the old deletion request or writes from a stale route.
    @discardableResult
    package func requestDeletionRetry(of rule: WorkspaceSoundRule) -> Bool {
        guard case .failed(let target, .lockBusy, _) = deletionPresentation.feedback,
            WorkspaceSoundDeleteTarget(rule: rule) == target,
            storage.route.scope == .workspace(target.id),
            storage.route.unavailableRequestedScopeStoredValue == nil
        else { return false }
        return requestDeletion(of: rule)
    }

    @discardableResult
    package func requestGroupVolumeFocus(for scope: PanelSoundScopeID) -> Bool {
        guard storage.route.scope == scope,
            storage.route.unavailableRequestedScopeStoredValue == nil
        else { return false }
        requestFocus(.masterVolume)
        return true
    }

    @discardableResult
    package func notePreviewFailure(
        event: Event,
        scope: PanelSoundScopeID,
        packID: String,
        reason: EventPreviewAttemptFailure
    ) -> Bool {
        guard storage.route.scope == scope,
            storage.route.unavailableRequestedScopeStoredValue == nil
        else { return false }
        previewFailure = EventSettingsPreviewFailure(
            scope: scope, packID: packID, event: event, reason: reason)
        return true
    }

    package func clearPreviewFailure() {
        previewFailure = nil
    }

    package func noteLockFailureRetry(_ retry: EventSettingsWriteRetry?) {
        guard let retry, storage.route.scope == retry.scope,
            storage.route.unavailableRequestedScopeStoredValue == nil
        else {
            writeRetry = nil
            return
        }
        writeRetry = retry
    }

    package func clearWriteRetry() {
        writeRetry = nil
    }

    package func noteConflictReadback(recoveryFiles: [URL] = []) {
        conflictWasReadBack = true
        conflictRecoveryFiles = recoveryFiles
    }

    package func clearConflictReadback() {
        conflictWasReadBack = false
        conflictRecoveryFiles = []
    }

    private func requestFocus(_ target: EventSettingsFocusTarget) {
        storage.focusTarget = target
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

    package func presentCredentialSheet() {
        guard !storage.credentialSheetIsPresented else { return }
        storage.credentialSheetIsPresented = true
        publishState()
    }

    package func dismissCredentialSheet() {
        guard storage.credentialSheetIsPresented else { return }
        storage.credentialSheetIsPresented = false
        publishState()
    }

    package func beginCandidatePreview(id: UUID) {
        guard storage.playingCandidateID != id else { return }
        storage.playingCandidateID = id
        publishState()
    }

    package func noteCandidatePreviewStopped() {
        guard storage.playingCandidateID != nil else { return }
        storage.playingCandidateID = nil
        publishState()
    }

    package func leaveDestination() {
        storage.leaveDestination()
        deletionPresentation = WorkspaceDeletionPresentation()
        previewFailure = nil
        writeRetry = nil
        conflictWasReadBack = false
        conflictRecoveryFiles = []
        consumedDeleteRequest = nil
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
        var credentialSheetIsPresented = false
        var playingCandidateID: UUID?
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
                aiSessionEndRequestRevision: aiSessionEndRequestRevision,
                credentialSheetIsPresented: credentialSheetIsPresented,
                playingCandidateID: playingCandidateID)
        }

        mutating func requestPreviewStop() {
            previewState = .idle
            previewStopRequestRevision &+= 1
        }

        mutating func requestAISessionEnd() {
            aiSessionState = .idle
            aiSessionEndRequestRevision &+= 1
        }

        mutating func leaveDestination() {
            requestPreviewStop()
            requestAISessionEnd()
            credentialSheetIsPresented = false
            playingCandidateID = nil
        }
    }
}
