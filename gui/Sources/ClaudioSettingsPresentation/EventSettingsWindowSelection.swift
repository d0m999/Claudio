import ClaudioCore
import ClaudioGUICore
import Combine
import Foundation

package struct EventSettingsPreviewFailure: Equatable {
    package let scope: PanelSoundScopeID
    package let packID: String
    package let event: Event
    package let reason: EventPreviewAttemptFailure
    package let sourcePackReadOnly: Bool
    package let workspaceTarget: WorkspaceSoundWriteTarget?
}

/// Keeps the typed failed write available when a requested conflict readback cannot establish
/// an operational configuration. Recovery files remain tied to that original write result.
package enum EventSettingsConflictSource: Equatable {
    case workspace(WorkspaceSoundError)
    case writes([PanelWriteFailure])

    package var isPublishedConflict: Bool {
        switch self {
        case .workspace(let error): return error.isPublishedConflict
        case .writes(let failures):
            return failures.contains {
                if case .configPublishedButFailed = $0.reason { return true }
                return false
            }
        }
    }
}

package enum EventSettingsConflictReadbackState: Equatable {
    case idle
    case readBack(recoveryFiles: [URL])
    case unavailable(source: EventSettingsConflictSource, recoveryFiles: [URL])
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

    @MainActor
    package func failedWithLockBusy(in model: PanelConfigController) -> Bool {
        if scope.workspaceID != nil { return model.workspaceError == .lockBusy }
        switch operation {
        case .pack:
            if case .lockBusy? = model.packSwitchError { return true }
        case .volume:
            if case .lockBusy? = model.masterVolumeError { return true }
        case .event:
            if case .lockBusy? = model.muteError { return true }
        case .surfaces:
            break
        }
        return false
    }
}

package enum EventSettingsWriteRetryFailure: Equatable {
    case targetChanged
    case readbackUnavailable
}

/// App-lifetime typed selection shared by the unified Events & Sounds destination and its routes.
@MainActor
package final class EventSettingsWindowSelection: ObservableObject {
    @Published package private(set) var presentationState: SettingsEventPresentationState
    @Published package private(set) var deletionPresentation = WorkspaceDeletionPresentation()
    @Published package private(set) var previewFailure: EventSettingsPreviewFailure?
    @Published package private(set) var writeRetry: EventSettingsWriteRetry?
    @Published package private(set) var writeRetryFailure: EventSettingsWriteRetryFailure?
    @Published package private(set) var conflictReadbackState: EventSettingsConflictReadbackState =
        .idle

    package var conflictWasReadBack: Bool {
        if case .readBack = conflictReadbackState { return true }
        return false
    }
    package var conflictRecoveryFiles: [URL] {
        switch conflictReadbackState {
        case .idle: []
        case .readBack(let files), .unavailable(_, let files): files
        }
    }
    package var unresolvedConflict: EventSettingsConflictSource? {
        if case .unavailable(let source, _) = conflictReadbackState { return source }
        return nil
    }

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
        writeRetryFailure = nil
        conflictReadbackState = .idle
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
        writeRetryFailure = nil
        conflictReadbackState = .idle
        storage.route = EventSettingsWindowRoute(
            scope: storage.route.scope,
            event: storage.route.event,
            workspaceTarget: storage.route.workspaceTarget,
            unavailableRequestedScopeStoredValue: storage.route.scope.storedValue)
        storage.routeRequestRevision &+= 1
        storage.focusTarget = nil
        publishState()
    }

    package func clearUnavailableScope() {
        guard storage.route.unavailableRequestedScopeStoredValue != nil else { return }
        storage.route = EventSettingsWindowRoute(
            scope: storage.route.scope,
            event: storage.route.event,
            workspaceTarget: storage.route.workspaceTarget)
        storage.routeRequestRevision &+= 1
        publishState()
    }

    package func requestInitialFocus(scopes: [PanelSoundScopeID], for request: SettingsRoute) {
        if storage.route.unavailableRequestedScopeStoredValue != nil
            || !scopes.contains(storage.route.scope)
        {
            storage.focusTarget = .unavailableScope
        } else if case .events = request {
            storage.focusTarget = eventSettingsRouteFocusTarget(
                route: storage.route,
                scopes: scopes,
                events: Set(Event.allCases))
        } else {
            storage.focusTarget = .title
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
            requestFocus(.workspaceDeleteResult)
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

    /// Reloads before opening a fresh confirmation. A changed or missing rule cannot reuse the
    /// consumed request; the readback becomes visible feedback for the original target.
    @discardableResult
    package func retryDeletion(using model: PanelConfigController) -> Bool {
        guard case .failed(let target, .lockBusy, _) = deletionPresentation.feedback,
            storage.route.scope == .workspace(target.id),
            storage.route.unavailableRequestedScopeStoredValue == nil
        else { return false }
        model.reload()
        guard storage.route.scope == .workspace(target.id),
            storage.route.unavailableRequestedScopeStoredValue == nil
        else { return false }
        let readback = WorkspaceDeleteReadback(target: target, configState: model.configState)
        switch readback {
        case .originalPresent:
            guard case .operational(let config) = model.configState,
                let rule = config.workspaceRules.first(where: { $0.id == target.id }),
                WorkspaceSoundDeleteTarget(rule: rule) == target
            else { return false }
            return requestDeletion(of: rule)
        case .absent, .replaced:
            markCurrentScopeUnavailable()
            deletionPresentation.feedback = .failed(target, .staleRule, readback)
        case .unavailable:
            deletionPresentation.feedback = .failed(target, .lockBusy, .unavailable)
        }
        requestFocus(.workspaceDeleteFeedback)
        return false
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
        reason: EventPreviewAttemptFailure,
        sourcePackReadOnly: Bool = false,
        workspaceTarget: WorkspaceSoundWriteTarget? = nil
    ) -> Bool {
        guard storage.route.scope == scope,
            storage.route.unavailableRequestedScopeStoredValue == nil
        else { return false }
        previewFailure = EventSettingsPreviewFailure(
            scope: scope, packID: packID, event: event, reason: reason,
            sourcePackReadOnly: sourcePackReadOnly, workspaceTarget: workspaceTarget)
        return true
    }

    package func clearPreviewFailure() {
        previewFailure = nil
    }

    package func noteWriteResult(
        _ retry: EventSettingsWriteRetry, using model: PanelConfigController
    ) {
        writeRetryFailure = nil
        guard storage.route.scope == retry.scope,
            storage.route.unavailableRequestedScopeStoredValue == nil
        else {
            writeRetry = nil
            return
        }
        writeRetry = retry.failedWithLockBusy(in: model) ? retry : nil
        if retry.scope.workspaceID != nil, model.workspaceError == .staleRule {
            markCurrentScopeUnavailable()
        }
    }

    package func clearWriteRetry() {
        writeRetry = nil
        writeRetryFailure = nil
    }

    /// This is the only replay path: reload first, compare the original target and value, then
    /// use the existing controller write. The operation switch keeps comparison next to its write.
    @discardableResult
    package func retryWrite(using model: PanelConfigController) -> Bool {
        guard let retry = writeRetry else { return false }
        model.reload()
        guard storage.route.scope == retry.scope,
            storage.route.unavailableRequestedScopeStoredValue == nil,
            model.selectedSoundScope == retry.scope
        else { return rejectWriteRetry(.targetChanged) }
        guard case .operational(let config) = model.configState,
            !config.workspaceRulesMalformed
        else { return rejectWriteRetry(.readbackUnavailable) }

        let currentRule = retry.scope.workspaceID.flatMap { id in
            config.workspaceRules.first { $0.id == id }
        }
        if retry.scope.workspaceID != nil {
            guard currentRule?.directory == retry.workspaceDirectory,
                currentRule?.profile?.isValid == true
            else { return rejectWriteRetry(.targetChanged, scopeUnavailable: true) }
        } else if retry.workspaceDirectory != nil {
            return rejectWriteRetry(.targetChanged)
        }

        switch retry.operation {
        case .pack(let before, let requested):
            guard model.config.selectedPack == before else {
                return rejectWriteRetry(.targetChanged)
            }
            clearConflictReadback()
            _ = model.switchPack(to: requested)
        case .volume(let before, let requested):
            guard model.config.masterVolume == before else {
                return rejectWriteRetry(.targetChanged)
            }
            clearConflictReadback()
            _ = model.setVolume(requested, for: retry.scope)
        case .event(let event, let before):
            guard model.config.isEnabled(event) == before else {
                return rejectWriteRetry(.targetChanged)
            }
            clearConflictReadback()
            model.toggleMute(event)
        case .surfaces(let before, let requested):
            guard let currentRule, currentRule.surfaces == before else {
                return rejectWriteRetry(.targetChanged)
            }
            clearConflictReadback()
            _ = model.changeWorkspace(
                .surfaces(WorkspaceSoundWriteTarget(rule: currentRule), requested))
        }
        noteWriteResult(retry, using: model)
        clearPreviewFailure()
        return true
    }

    private func rejectWriteRetry(
        _ failure: EventSettingsWriteRetryFailure, scopeUnavailable: Bool = false
    ) -> Bool {
        if scopeUnavailable { markCurrentScopeUnavailable() }
        writeRetry = nil
        writeRetryFailure = failure
        return false
    }

    /// Call only after a user-requested reload. A failed readback must keep the original typed
    /// failure and its recovery files visible without asserting that current config was read.
    @discardableResult
    package func finishConflictReadback(
        scope: PanelSoundScopeID,
        configState: PanelConfigState,
        source: EventSettingsConflictSource,
        recoveryFiles: [URL]
    ) -> Bool {
        guard storage.route.scope == scope, source.isPublishedConflict else { return false }
        if case .operational(let config) = configState, !config.workspaceRulesMalformed {
            conflictReadbackState = .readBack(recoveryFiles: recoveryFiles)
            return true
        }
        conflictReadbackState = .unavailable(source: source, recoveryFiles: recoveryFiles)
        return false
    }

    package func clearConflictReadback() {
        conflictReadbackState = .idle
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
        writeRetryFailure = nil
        conflictReadbackState = .idle
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
