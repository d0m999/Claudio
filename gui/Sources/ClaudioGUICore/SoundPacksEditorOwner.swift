import ClaudioCore
import Combine
import Foundation

/// App-lifetime owner of the one writable sound-pack editor model.
///
/// The unified Settings destination is the only production presentation of this owner. Route
/// application lives in the Foundation-only module so the embedded Scope/pack/Event contract can
/// be exercised without constructing AppKit or SwiftUI.
@MainActor
public final class SoundPacksEditorOwner: ObservableObject {
    public let model: SoundPacksWindowModel
    public let userPacksDirectory: URL
    @Published package private(set) var presentation: SoundPacksEditorPresentation
    private let refreshCoordinator: SoundPacksRefreshCoordinator?
    private let importEnvironment: AudioImportEnvironment
    private let audioImportExecutor: SoundPackAudioImportExecutor
    private var context: SoundPacksEditorContext = .inactive
    private var actionEpoch: UInt64 = 0
    private var candidateGenerationEpoch: UInt64 = 0
    private var currentCandidateGenerationID: UUID?
    private var presentationRevision: UInt64 = 0
    private var nextCapabilityID: UInt64 = 0
    private var actionLedger: [SoundPackEditorAction.ID: EditorActionBinding] = [:]
    private var importPermitLedger: [SoundPackImportPermit.ID: EditorPermitBinding] = [:]
    private var adoptionPermitLedger: [SoundPackAdoptionPermit.ID: EditorAdoptionBinding] = [:]
    private var pendingConfirmationState: EditorConfirmationState?
    private var operationStates: [SoundPackEditorOperationID: EditorOperationState] = [:]
    private var operationOrder: [SoundPackEditorOperationID] = []
    private var operationTasks: [SoundPackEditorOperationID: Task<Void, Never>] = [:]
    private var operationCancellations:
        [SoundPackEditorOperationID: SoundPackAudioImportCancellation] = [:]
    private var announcementQueue: [SoundPackEditorAnnouncement] = []
    private var seenStatusRevisions: Set<Int> = []
    private var isApplyingModelTransition = false
    private var deferredModelSeed: SoundPacksEditorModelSeed?
    private var isPublishingPresentation = false
    private var pendingPublication:
        (
            seed: SoundPacksEditorModelSeed,
            forcesCapabilityGeneration: Bool
        )?
    private var lastCommittedModelSeed: SoundPacksEditorModelSeed?
    private var statusAnnouncementTracker = SoundPacksWindowStatusAnnouncementTracker()
    private var lastSelectionAnnouncementDecision: (packID: String?, shouldAnnounce: Bool)?

    public convenience init(
        configFile: URL,
        lockFile: URL = ClaudioPaths.configLockFile,
        environment: AudioImportEnvironment,
        soundPackLibrary: SoundPackLibrary,
        refreshCoordinator: SoundPacksRefreshCoordinator
    ) {
        let model = SoundPacksWindowModel(
            configFile: configFile,
            lockFile: lockFile,
            environment: environment,
            soundPackLibrary: soundPackLibrary,
            refreshCoordinator: refreshCoordinator)
        self.init(
            model: model,
            userPacksDirectory: environment.userPacksDirectory,
            importEnvironment: environment,
            refreshCoordinator: refreshCoordinator,
            audioImportExecutor: SoundPackAudioImportExecutor())
    }

    private init(
        model: SoundPacksWindowModel,
        userPacksDirectory: URL,
        importEnvironment: AudioImportEnvironment,
        refreshCoordinator: SoundPacksRefreshCoordinator?,
        audioImportExecutor: SoundPackAudioImportExecutor
    ) {
        self.model = model
        self.userPacksDirectory = userPacksDirectory
        self.importEnvironment = importEnvironment
        self.refreshCoordinator = refreshCoordinator
        self.audioImportExecutor = audioImportExecutor
        presentation = Self.initialPresentation(from: model.editorProjectionSeed())
        connectSettledModel(model)
    }

    #if DEBUG
    /// Deterministic route-test seam that uses the harness's synchronous disk-backed model.
    public convenience init(
        configFile: URL,
        lockFile: URL,
        environment: AudioImportEnvironment,
        refreshCoordinator: SoundPacksRefreshCoordinator
    ) {
        let model = SoundPacksWindowModel(
            configFile: configFile,
            lockFile: lockFile,
            environment: environment,
            refreshCoordinator: refreshCoordinator)
        self.init(
            model: model,
            userPacksDirectory: environment.userPacksDirectory,
            importEnvironment: environment,
            refreshCoordinator: refreshCoordinator,
            audioImportExecutor: SoundPackAudioImportExecutor())
    }

    /// Deterministic pending/ready route seam for model fixtures that do not touch user disk.
    public convenience init(model: SoundPacksWindowModel, userPacksDirectory: URL) {
        self.init(
            model: model,
            userPacksDirectory: userPacksDirectory,
            importEnvironment: model.editorImportEnvironment,
            refreshCoordinator: nil,
            audioImportExecutor: SoundPackAudioImportExecutor())
    }

    package convenience init(
        configFile: URL,
        lockFile: URL,
        environment: AudioImportEnvironment,
        soundPackLibrary: SoundPackLibrary,
        refreshCoordinator: SoundPacksRefreshCoordinator,
        afterFinalImportCancellationSampleForTesting: @escaping @Sendable () -> Void
    ) {
        let model = SoundPacksWindowModel(
            configFile: configFile,
            lockFile: lockFile,
            environment: environment,
            soundPackLibrary: soundPackLibrary,
            refreshCoordinator: refreshCoordinator)
        self.init(
            model: model,
            userPacksDirectory: environment.userPacksDirectory,
            importEnvironment: environment,
            refreshCoordinator: refreshCoordinator,
            audioImportExecutor: SoundPackAudioImportExecutor(
                afterFinalCancellationSampleForTesting:
                    afterFinalImportCancellationSampleForTesting))
    }
    #endif

    private static func initialPresentation(
        from seed: SoundPacksEditorModelSeed
    ) -> SoundPacksEditorPresentation {
        SoundPacksEditorPresentation(
            revision: 0,
            library: seed.library,
            mode: .inactive,
            activities: [],
            pendingConfirmation: nil,
            pendingAnnouncement: nil)
    }

    private func connectSettledModel(_ model: SoundPacksWindowModel) {
        lastCommittedModelSeed = model.editorProjectionSeed()
        model.onEditorStateSettled = { [weak self] seed in
            self?.receiveSettledModel(seed)
        }
    }

    private func receiveSettledModel(_ seed: SoundPacksEditorModelSeed) {
        if isApplyingModelTransition {
            deferredModelSeed = seed
            return
        }
        publish(from: seed, forcingCapabilityGeneration: false)
    }

    @discardableResult
    private func withModelTransition<T>(_ body: () throws -> T) rethrows -> T {
        isApplyingModelTransition = true
        defer {
            isApplyingModelTransition = false
            let seed = deferredModelSeed ?? model.editorProjectionSeed()
            deferredModelSeed = nil
            publish(from: seed)
        }
        return try model.withEditorStateTransition(body)
    }

    @discardableResult
    package func send(
        _ command: SoundPacksEditorCommand
    ) -> SoundPacksEditorCommandResult {
        switch command {
        case .activate(let nextContext):
            actionEpoch &+= 1
            advanceCandidateGeneration(for: nextContext)
            context = nextContext
            switch nextContext {
            case .inactive:
                publish(from: model.editorProjectionSeed())
            case .sounds(let route, _):
                withModelTransition {
                    model.setManagedSurface(route.surface)
                    let seed = model.editorProjectionSeed()
                    if case .ready = seed.library,
                        let packID = route.editTarget?.packID,
                        seed.installedPackIDs.contains(packID)
                    {
                        _ = model.selectPackForInspection(packID)
                    }
                }
            case .events(let route, _, _):
                withModelTransition {
                    model.setManagedSurface(route.surface)
                }
            }
            return .applied
        case .invoke(let action):
            return invoke(action)
        case .completePanelPackSwitch(let outcome):
            completePanelPackSwitch(outcome)
            return outcome.refreshesEditor ? .applied : .unchanged
        case .acknowledgeAnnouncement(let id, let didPost):
            guard announcementQueue.first?.id == id else {
                return .rejected(.staleAction)
            }
            guard didPost else { return .unchanged }
            announcementQueue.removeFirst()
            publish(from: model.editorProjectionSeed())
            return .applied
        }
    }

    private func advanceCandidateGeneration(for nextContext: SoundPacksEditorContext) {
        let nextGenerationID: UUID?
        switch nextContext {
        case .inactive:
            return
        case .sounds:
            nextGenerationID = nil
        case .events(_, _, let candidateGenerationID):
            nextGenerationID = candidateGenerationID
        }
        guard nextGenerationID != currentCandidateGenerationID else { return }
        candidateGenerationEpoch &+= 1
        currentCandidateGenerationID = nextGenerationID
    }

    package func perform(
        _ operation: SoundPacksEditorOperation
    ) async -> SoundPacksEditorOperationResult {
        switch operation {
        case .importAudio(let permit, let sources, let bindTo):
            return await performImport(permit: permit, sources: sources, bindTo: bindTo)
        case .adoptAICue(let candidate, let displayName, let permit):
            return await performAdoption(
                candidate: candidate,
                displayName: displayName,
                permit: permit)
        }
    }

    private func performAdoption(
        candidate: AICueCandidate,
        displayName: AICueDisplayName,
        permit: SoundPackAdoptionPermit
    ) async -> SoundPacksEditorOperationResult {
        model.refreshEditorConfigProjection()
        let seed = model.editorProjectionSeed()
        let binding = adoptionPermitLedger.removeValue(forKey: permit.id)
        guard seed.writesAllowed else { return .rejected(.scopeUnavailable) }
        guard let binding else {
            return .rejected(.stalePermit)
        }
        guard binding.context == context,
            binding.actionEpoch == actionEpoch,
            binding.candidateGenerationEpoch == candidateGenerationEpoch,
            binding.selectionGeneration == seed.selectionGeneration,
            binding.snapshotRevision == seed.snapshotRevision,
            binding.candidateGenerationID == candidate.provenance.generationID,
            seed.library.isFresh
        else {
            return .rejected(.stalePermit)
        }
        guard
            case .success(let currentTarget) = model.captureAICueAdoptionTarget(
                for: binding.target.event),
            currentTarget == binding.target
        else {
            return .rejected(.targetChanged)
        }

        let cancellation = SoundPackAudioImportCancellation()
        let operationID = beginAsyncOperation(
            kind: .adoptAICue,
            packID: binding.target.packID,
            event: binding.target.event,
            cancellation: cancellation)
        let (_, startedSeed) = captureModelTransition {
            model.beginEditorCompoundMutation(packID: binding.target.packID)
        }
        publish(from: startedSeed)
        let request = AudioImportRequest(
            sourceURL: candidate.asset.fileURL,
            suggestedFileName:
                "ai-cue-\(candidate.id.uuidString.lowercased())."
                + candidate.asset.sniffedFormat.rawValue)
        let execution = await audioImportExecutor.execute(
            SoundPackAudioImportJob(
                requests: [request],
                packID: binding.target.packID,
                environment: importEnvironment),
            cancellation: cancellation)
        switch execution {
        case .cancelledBeforeWrite:
            let (_, settledSeed) = captureModelTransition {
                model.finishEditorCompoundMutationWithoutChange(packID: binding.target.packID)
            }
            settleAsyncOperation(
                operationID,
                phase: .cancelled(changedOnDisk: false),
                seed: settledSeed)
            return .rejected(.cancelled)
        case .completed(let batch, let cancellationRequested):
            let cancellationRequested = cancellationRequested || cancellation.isCancelled
            guard let imported = batch.accepted.first else {
                let (_, settledSeed) = captureModelTransition {
                    model.finishEditorCompoundMutationWithoutChange(packID: binding.target.packID)
                }
                settleAsyncOperation(
                    operationID,
                    phase: cancellationRequested
                        ? .cancelled(changedOnDisk: false) : .failed(.importRejected),
                    seed: settledSeed)
                return .rejected(cancellationRequested ? .cancelled : .importRejected)
            }
            return finishAdoption(
                operationID: operationID,
                binding: binding,
                imported: imported,
                displayName: displayName,
                cancellationRequested: cancellationRequested)
        }
    }

    private func finishAdoption(
        operationID: SoundPackEditorOperationID,
        binding: EditorAdoptionBinding,
        imported: ImportedAudioFile,
        displayName: AICueDisplayName,
        cancellationRequested: Bool
    ) -> SoundPacksEditorOperationResult {
        model.refreshEditorConfigProjection()
        let current = model.editorProjectionSeed()
        let targetRemainsValid: Bool
        if binding.context == context,
            binding.candidateGenerationEpoch == candidateGenerationEpoch,
            binding.selectionGeneration == current.selectionGeneration,
            current.library.isFresh,
            current.installedPackIDs.contains(binding.target.packID),
            current.writesAllowed,
            case .success(let currentTarget) = model.captureAICueAdoptionTarget(
                for: binding.target.event),
            currentTarget == binding.target
        {
            targetRemainsValid = true
        } else {
            targetRemainsValid = false
        }

        let failure: SoundPackEditorFailure?
        var bindingOutcome: AICueManifestBindingOutcome?
        if cancellationRequested {
            failure = .cancelled
        } else if !targetRemainsValid {
            failure = .targetChanged
        } else {
            switch model.bindEditorAICue(
                imported,
                displayName: displayName,
                target: binding.target)
            {
            case .success(let outcome):
                bindingOutcome = outcome
                failure = nil
            case .failure:
                failure = .mutationFailed
            }
        }

        let (_, settledSeed) = captureModelTransition {
            model.finishEditorCompoundMutation(
                packID: binding.target.packID,
                changedDespiteFailure: failure != nil)
        }
        if let failure {
            settleAsyncOperation(
                operationID,
                phase: .orphan(fileName: imported.fileName, failure: failure),
                seed: settledSeed)
            return .adoptionOrphan(imported: imported, failure: failure)
        }
        guard let bindingOutcome else {
            settleAsyncOperation(
                operationID,
                phase: .orphan(fileName: imported.fileName, failure: .mutationFailed),
                seed: settledSeed)
            return .adoptionOrphan(imported: imported, failure: .mutationFailed)
        }
        settleAsyncOperation(operationID, phase: .succeeded, seed: settledSeed)
        return .adopted(
            AICueAdoptionOutcome(
                target: binding.target,
                importedFile: imported,
                finalDisplayName: bindingOutcome.finalDisplayName))
    }

    private func performImport(
        permit: SoundPackImportPermit,
        sources: [URL],
        bindTo: Event?
    ) async -> SoundPacksEditorOperationResult {
        model.refreshEditorConfigProjection()
        let seed = model.editorProjectionSeed()
        let binding = importPermitLedger.removeValue(forKey: permit.id)
        guard seed.writesAllowed else { return .rejected(.scopeUnavailable) }
        guard let binding else {
            return .rejected(.stalePermit)
        }
        guard binding.context == context,
            binding.actionEpoch == actionEpoch,
            binding.selectionGeneration == seed.selectionGeneration,
            binding.snapshotRevision == seed.snapshotRevision,
            binding.bindTo == bindTo,
            seed.library.isFresh
        else {
            return .rejected(.stalePermit)
        }
        guard seed.selectedPackID == binding.packID,
            seed.installedPackIDs.contains(binding.packID)
        else {
            return .rejected(.packUnavailable)
        }
        guard !seed.builtinPackIDs.contains(binding.packID) else {
            return .rejected(.builtinReadOnly)
        }
        guard !sources.isEmpty else {
            return .imported(
                SoundPackEditorImportOutcome(
                    accepted: [],
                    rejected: [],
                    boundEvent: nil,
                    completedInBackground: false,
                    orphan: nil))
        }

        let cancellation = SoundPackAudioImportCancellation()
        let operationID = beginAsyncOperation(
            kind: .importAudio,
            packID: binding.packID,
            event: bindTo,
            cancellation: cancellation)
        let (_, startedSeed) = captureModelTransition {
            model.beginEditorCompoundMutation(packID: binding.packID)
        }
        publish(from: startedSeed)

        let requests = sources.map {
            AudioImportRequest(sourceURL: $0, suggestedFileName: $0.lastPathComponent)
        }
        let execution = await audioImportExecutor.execute(
            SoundPackAudioImportJob(
                requests: requests,
                packID: binding.packID,
                environment: importEnvironment),
            cancellation: cancellation)
        switch execution {
        case .cancelledBeforeWrite:
            let (_, settledSeed) = captureModelTransition {
                model.finishEditorCompoundMutationWithoutChange(packID: binding.packID)
            }
            settleAsyncOperation(
                operationID,
                phase: .cancelled(changedOnDisk: false),
                seed: settledSeed)
            return .rejected(.cancelled)
        case .completed(let batch, let cancellationRequested):
            return finishImport(
                operationID: operationID,
                binding: binding,
                batch: batch,
                cancellationRequested: cancellationRequested || cancellation.isCancelled)
        }
    }

    private func finishImport(
        operationID: SoundPackEditorOperationID,
        binding: EditorPermitBinding,
        batch: AudioImportBatchResult,
        cancellationRequested: Bool
    ) -> SoundPacksEditorOperationResult {
        guard !batch.accepted.isEmpty else {
            let (_, seed) = captureModelTransition {
                model.finishEditorCompoundMutationWithoutChange(packID: binding.packID)
            }
            let phase: SoundPackEditorActivityPhase
            if cancellationRequested {
                phase = .cancelled(changedOnDisk: false)
            } else {
                phase = batch.rejected.isEmpty ? .succeeded : .failed(.importRejected)
            }
            settleAsyncOperation(operationID, phase: phase, seed: seed)
            if cancellationRequested { return .rejected(.cancelled) }
            return .imported(
                SoundPackEditorImportOutcome(
                    accepted: [],
                    rejected: batch.rejected,
                    boundEvent: nil,
                    completedInBackground: false,
                    orphan: nil))
        }

        model.refreshEditorConfigProjection()
        let current = model.editorProjectionSeed()
        let remainsForeground =
            binding.context == context
            && binding.selectionGeneration == current.selectionGeneration
            && current.library.isFresh
            && current.installedPackIDs.contains(binding.packID)
            && current.selectedPackID == binding.packID
            && current.writesAllowed
        var boundEvent: Event?
        var orphan: ImportedAudioFile?
        var failure: SoundPackEditorFailure?

        if cancellationRequested {
            orphan = binding.bindTo == nil ? nil : batch.accepted.last
            failure = .cancelled
        } else if let event = binding.bindTo, let imported = batch.accepted.last {
            if remainsForeground {
                switch model.bindEditorImportedAudioFile(
                    imported,
                    to: event,
                    packID: binding.packID)
                {
                case .success:
                    boundEvent = event
                case .failure:
                    orphan = imported
                    failure = .mutationFailed
                }
            } else {
                orphan = imported
                failure = .targetChanged
            }
        }
        return completeImport(
            operationID: operationID,
            binding: binding,
            batch: batch,
            boundEvent: boundEvent,
            completedInBackground: !remainsForeground,
            orphan: orphan,
            failure: failure)
    }

    private func completeImport(
        operationID: SoundPackEditorOperationID,
        binding: EditorPermitBinding,
        batch: AudioImportBatchResult,
        boundEvent: Event?,
        completedInBackground: Bool,
        orphan: ImportedAudioFile?,
        failure: SoundPackEditorFailure?
    ) -> SoundPacksEditorOperationResult {
        let (_, settledSeed) = captureModelTransition {
            model.finishEditorCompoundMutation(
                packID: binding.packID,
                changedDespiteFailure: failure != nil)
        }
        let phase: SoundPackEditorActivityPhase
        if let orphan, let failure {
            phase = .orphan(fileName: orphan.fileName, failure: failure)
        } else if failure == .cancelled {
            phase = .cancelled(changedOnDisk: true)
        } else if !batch.rejected.isEmpty {
            phase = .partial(accepted: batch.accepted.count, rejected: batch.rejected.count)
        } else {
            phase = .succeeded
        }
        settleAsyncOperation(operationID, phase: phase, seed: settledSeed)
        return .imported(
            SoundPackEditorImportOutcome(
                accepted: batch.accepted,
                rejected: batch.rejected,
                boundEvent: boundEvent,
                completedInBackground: completedInBackground,
                orphan: orphan))
    }

    private func beginAsyncOperation(
        kind: SoundPackEditorActivityKind,
        packID: String,
        event: Event?,
        cancellation: SoundPackAudioImportCancellation
    ) -> SoundPackEditorOperationID {
        nextCapabilityID &+= 1
        let operationID = SoundPackEditorOperationID(rawValue: nextCapabilityID)
        operationStates[operationID] = EditorOperationState(
            kind: kind,
            phase: .busy,
            packID: packID,
            event: event)
        operationOrder.append(operationID)
        operationCancellations[operationID] = cancellation
        return operationID
    }

    private func settleAsyncOperation(
        _ operationID: SoundPackEditorOperationID,
        phase: SoundPackEditorActivityPhase,
        seed: SoundPacksEditorModelSeed
    ) {
        operationCancellations.removeValue(forKey: operationID)
        guard let state = operationStates[operationID] else { return }
        operationStates[operationID] = state.withPhase(phase)
        publish(from: seed)
    }

    private func invoke(_ action: SoundPackEditorAction) -> SoundPacksEditorCommandResult {
        // Latest config/scope has precedence over capability identity. This is a config-only read
        // and deliberately does not ask the shared library to scan.
        model.refreshEditorConfigProjection()
        let seed = model.editorProjectionSeed()
        if action.kind.requiresWritableScope, !seed.writesAllowed {
            consumeConfirmationAttemptIfCurrent(action)
            publish(from: seed)
            return .rejected(.scopeUnavailable)
        }
        guard let binding = actionLedger[action.id], binding.context == context,
            binding.actionEpoch == actionEpoch,
            binding.selectionGeneration == seed.selectionGeneration,
            binding.snapshotRevision == seed.snapshotRevision
        else {
            switch action.kind {
            case .confirm, .cancelConfirmation:
                return .rejected(.staleConfirmation)
            default:
                return .rejected(.staleAction)
            }
        }
        actionLedger.removeValue(forKey: action.id)

        switch binding.intent {
        case .inspect(let packID):
            let applied = withModelTransition { model.selectPackForInspection(packID) }
            return applied ? .applied : .rejected(.packUnavailable)
        case .use(let packID):
            let result = withModelTransition {
                () -> Result<UseOutcome, SoundPacksWindowPackUseActionError> in
                guard model.selectPackForInspection(packID) else {
                    return .failure(.noSelectedPack)
                }
                return model.useSelectedPack()
            }
            return result.isSuccess ? .applied : .rejected(.mutationFailed)
        case .toggleStar(let packID):
            let result = withModelTransition { model.toggleStarredPack(packID) }
            return result.isSuccess ? .applied : .rejected(.mutationFailed)
        case .fork(let packID):
            return acceptScheduledOperation(
                kind: .fork,
                packID: packID,
                event: nil,
                binding: binding,
                work: .fork(packID: packID))
        case .requestImport(let packID, let bindTo):
            publish(from: seed)
            let permit = makeImportPermit(packID: packID, bindTo: bindTo, seed: seed)
            return .nativeEffect(.selectAudioFiles(permit: permit, bindTo: bindTo))
        case .assign(let fileName, let event):
            let result = withModelTransition { model.assignSelectedAudioFile(fileName, to: event) }
            return result.isSuccess ? .applied : .rejected(.mutationFailed)
        case .clear(let event):
            let result = withModelTransition { model.clearSelectedEventBinding(event) }
            return result.isSuccess ? .applied : .rejected(.mutationFailed)
        case .preview(let event):
            let file = withModelTransition { model.previewFileForSelectedEvent(event) }
            guard let file else { return .rejected(.unsafeTarget) }
            return .nativeEffect(
                .playAudio(fileURL: file, volume: AfplayVolume.clamped(model.config.masterVolume)))
        case .stopPreview:
            publish(from: seed)
            return .nativeEffect(.stopAudio)
        case .revealPack(let packID):
            guard let target = model.editorSafePackDirectory(packID: packID) else {
                publish(from: seed)
                return .rejected(.unsafeTarget)
            }
            publish(from: seed)
            return .nativeEffect(.reveal(fileURL: target))
        case .revealAudio(let fileName):
            guard let packID = seed.selectedPackID,
                let target = model.editorSafeAudioFile(packID: packID, fileName: fileName)
            else {
                publish(from: seed)
                return .rejected(.unsafeTarget)
            }
            publish(from: seed)
            return .nativeEffect(.reveal(fileURL: target))
        case .requestDeletePack(let packID):
            return requestConfirmation(
                kind: .deletePack,
                packID: packID,
                fileName: nil,
                target: .deletePack(packID: packID),
                binding: binding,
                seed: seed)
        case .requestDeleteOrphan(let fileName):
            guard let packID = seed.selectedPackID else {
                publish(from: seed)
                return .rejected(.packUnavailable)
            }
            return requestConfirmation(
                kind: .deleteOrphan,
                packID: packID,
                fileName: fileName,
                target: .deleteOrphan(packID: packID, fileName: fileName),
                binding: binding,
                seed: seed)
        case .requestRestoreFactory(let packID):
            return requestConfirmation(
                kind: .restoreFactory,
                packID: packID,
                fileName: nil,
                target: .restoreFactory(packID: packID),
                binding: binding,
                seed: seed)
        case .requestRetryRestore(let packID):
            return requestConfirmation(
                kind: .retryRestore,
                packID: packID,
                fileName: nil,
                target: .retryRestore(packID: packID),
                binding: binding,
                seed: seed)
        case .requestRestoreAllFactory:
            return requestConfirmation(
                kind: .restoreAllFactory,
                packID: nil,
                fileName: nil,
                target: .restoreAllFactory,
                binding: binding,
                seed: seed)
        case .retryLibrary:
            model.retrySoundPackLibraryRefresh()
            publish(from: seed)
            return .applied
        case .cancelOperation(let operationID):
            guard let state = operationStates[operationID], state.phase == .busy else {
                return .rejected(.staleAction)
            }
            operationTasks[operationID]?.cancel()
            operationCancellations[operationID]?.cancel()
            operationStates[operationID] = state.withPhase(.cancelled(changedOnDisk: false))
            publish(from: seed)
            return .applied
        case .confirm(let confirmationID):
            return confirm(confirmationID, seed: seed)
        case .cancelConfirmation(let confirmationID):
            guard pendingConfirmationState?.id == confirmationID else {
                return .rejected(.staleConfirmation)
            }
            pendingConfirmationState = nil
            publish(from: seed)
            return .applied
        }
    }

    private func consumeConfirmationAttemptIfCurrent(_ action: SoundPackEditorAction) {
        guard action.kind == .confirm,
            let binding = actionLedger.removeValue(forKey: action.id),
            case .confirm(let confirmationID) = binding.intent,
            pendingConfirmationState?.id == confirmationID
        else { return }
        pendingConfirmationState = nil
    }

    private func requestConfirmation(
        kind: SoundPackEditorConfirmation.Kind,
        packID: String?,
        fileName: String?,
        target: EditorScheduledWork,
        binding: EditorActionBinding,
        seed: SoundPacksEditorModelSeed
    ) -> SoundPacksEditorCommandResult {
        nextCapabilityID &+= 1
        pendingConfirmationState = EditorConfirmationState(
            id: SoundPackEditorConfirmation.ID(rawValue: nextCapabilityID),
            kind: kind,
            packID: packID,
            fileName: fileName,
            target: target,
            context: binding.context,
            actionEpoch: binding.actionEpoch,
            selectionGeneration: binding.selectionGeneration,
            snapshotRevision: binding.snapshotRevision)
        publish(from: seed)
        guard let confirmation = presentation.pendingConfirmation else {
            return .rejected(.actionUnavailable)
        }
        return .confirmation(confirmation)
    }

    private func confirm(
        _ confirmationID: SoundPackEditorConfirmation.ID,
        seed: SoundPacksEditorModelSeed
    ) -> SoundPacksEditorCommandResult {
        guard let confirmation = pendingConfirmationState,
            confirmation.id == confirmationID
        else {
            return .rejected(.staleConfirmation)
        }
        // Consume and clear before any Task can be scheduled. Replaying either action can never
        // cross this synchronous MainActor boundary.
        pendingConfirmationState = nil
        guard confirmation.context == context,
            confirmation.actionEpoch == actionEpoch,
            confirmation.selectionGeneration == seed.selectionGeneration,
            confirmation.snapshotRevision == seed.snapshotRevision
        else {
            publish(from: seed)
            return .rejected(.staleConfirmation)
        }
        return acceptScheduledOperation(
            kind: confirmation.target.activityKind,
            packID: confirmation.packID,
            event: confirmation.target.event,
            binding: EditorActionBinding(
                intent: .confirm(confirmationID),
                context: confirmation.context,
                actionEpoch: confirmation.actionEpoch,
                selectionGeneration: confirmation.selectionGeneration,
                snapshotRevision: confirmation.snapshotRevision),
            work: confirmation.target)
    }

    private func acceptScheduledOperation(
        kind: SoundPackEditorActivityKind,
        packID: String?,
        event: Event?,
        binding: EditorActionBinding,
        work: EditorScheduledWork
    ) -> SoundPacksEditorCommandResult {
        nextCapabilityID &+= 1
        let operationID = SoundPackEditorOperationID(rawValue: nextCapabilityID)
        operationStates[operationID] = EditorOperationState(
            kind: kind,
            phase: .busy,
            packID: packID,
            event: event)
        operationOrder.append(operationID)
        publish(from: model.editorProjectionSeed())

        let task = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }
            guard !Task.isCancelled,
                self.operationStates[operationID]?.phase == .busy
            else { return }
            self.executeScheduledOperation(
                operationID: operationID,
                binding: binding,
                work: work)
        }
        operationTasks[operationID] = task
        return .accepted(operationID)
    }

    private func executeScheduledOperation(
        operationID: SoundPackEditorOperationID,
        binding: EditorActionBinding,
        work: EditorScheduledWork
    ) {
        model.refreshEditorConfigProjection()
        let current = model.editorProjectionSeed()
        guard current.writesAllowed, binding.context == context,
            binding.selectionGeneration == current.selectionGeneration,
            binding.snapshotRevision == current.snapshotRevision
        else {
            finishOperation(
                operationID,
                phase: current.writesAllowed
                    ? .failed(.staleAction) : .failed(.scopeUnavailable),
                seed: current)
            return
        }

        let (succeeded, settledSeed) = captureModelTransition {
            switch work {
            case .fork(let packID):
                guard model.selectedPackID == packID else { return false }
                return model.forkSelectedFactoryPack().isSuccess
            case .deletePack(let packID):
                return model.deleteSelectedUserPackAfterConfirmation(expectedPackID: packID)
                    .isSuccess
            case .deleteOrphan(let packID, let fileName):
                return model.deleteSelectedOrphanAudioFileAfterConfirmation(
                    fileName,
                    expectedPackID: packID
                ).isSuccess
            case .restoreFactory(let packID):
                return model.restoreSelectedFactoryPackAfterConfirmation(expectedPackID: packID)
                    .isSuccess
            case .retryRestore(let packID):
                return model.retryFailedFactoryPackRestoreAfterConfirmation(
                    expectedPackID: packID
                ).isSuccess
            case .restoreAllFactory:
                return model.restoreAllFactoryPacksAfterConfirmation().failures.isEmpty
            }
        }
        finishOperation(
            operationID,
            phase: succeeded ? .succeeded : .failed(.mutationFailed),
            seed: settledSeed,
            successfulWork: succeeded ? work : nil)
    }

    private func finishOperation(
        _ operationID: SoundPackEditorOperationID,
        phase: SoundPackEditorActivityPhase,
        seed: SoundPacksEditorModelSeed,
        successfulWork: EditorScheduledWork? = nil
    ) {
        operationTasks.removeValue(forKey: operationID)
        guard let state = operationStates[operationID] else { return }
        operationStates[operationID] = state.withPhase(phase)
        if case .deleteOrphan = successfulWork {
            enqueueOperationAnnouncement(.deleteOrphan)
        }
        publish(from: seed)
    }

    private func captureModelTransition<T>(_ body: () -> T) -> (T, SoundPacksEditorModelSeed) {
        isApplyingModelTransition = true
        let result = model.withEditorStateTransition(body)
        isApplyingModelTransition = false
        let seed = deferredModelSeed ?? model.editorProjectionSeed()
        deferredModelSeed = nil
        return (result, seed)
    }

    private func publish(
        from seed: SoundPacksEditorModelSeed,
        forcingCapabilityGeneration: Bool = true
    ) {
        let force =
            forcingCapabilityGeneration
            || (pendingPublication?.forcesCapabilityGeneration ?? false)
        pendingPublication = (seed: seed, forcesCapabilityGeneration: force)
        guard !isPublishingPresentation else { return }
        isPublishingPresentation = true
        defer { isPublishingPresentation = false }

        while let next = pendingPublication {
            pendingPublication = nil
            publishImmediately(
                from: next.seed,
                forcingCapabilityGeneration: next.forcesCapabilityGeneration)
        }
    }

    private func publishImmediately(
        from seed: SoundPacksEditorModelSeed,
        forcingCapabilityGeneration: Bool
    ) {
        guard forcingCapabilityGeneration || seed != lastCommittedModelSeed else { return }
        presentationRevision &+= 1
        actionLedger.removeAll(keepingCapacity: true)
        prunePermits(using: seed)
        ingestAnnouncements(from: seed.windowStatuses)
        let nextPresentation = SoundPacksEditorPresentation(
            revision: presentationRevision,
            library: seed.library,
            mode: makeMode(from: seed),
            activities: makeActivities(seed: seed),
            pendingConfirmation: makeConfirmation(seed: seed),
            pendingAnnouncement: announcementQueue.first)
        lastCommittedModelSeed = seed
        presentation = nextPresentation
    }

    private func makeMode(
        from seed: SoundPacksEditorModelSeed
    ) -> SoundPacksEditorModePresentation {
        switch context {
        case .inactive:
            return .inactive
        case .sounds(let route, let requestRevision):
            return .sounds(
                makeSoundsPresentation(
                    route: route,
                    requestRevision: requestRevision,
                    seed: seed))
        case .events(let route, let requestRevision, let candidateGenerationID):
            return .events(
                makeEventsPresentation(
                    route: route,
                    requestRevision: requestRevision,
                    candidateGenerationID: candidateGenerationID,
                    seed: seed))
        }
    }

    private func makeSoundsPresentation(
        route: SoundPacksWindowRoute,
        requestRevision: UInt64,
        seed: SoundPacksEditorModelSeed
    ) -> SoundsEditorPresentation {
        let packs = seed.packCards.map { makePackPresentation(card: $0, seed: seed) }
        let selectedPack = packs.first(where: { $0.id == seed.selectedPackID })
        let routeState: SoundPacksEditorRouteState
        if case .ready = seed.library {
            if let packID = route.editTarget?.packID {
                routeState =
                    seed.installedPackIDs.contains(packID)
                    ? .resolved(route)
                    : .staleTarget(packID: packID)
            } else {
                routeState = .resolved(route)
            }
        } else {
            routeState = .pendingFreshSnapshot
        }
        let selectedIsWritable =
            selectedPack.map {
                !$0.isBuiltinReadOnly && $0.availability == .installed && seed.writesAllowed
            } ?? false
        return SoundsEditorPresentation(
            route: route,
            requestRevision: requestRevision,
            routeState: routeState,
            scope: scopeAvailability(seed),
            packs: packs,
            selectedPack: selectedPack,
            eventRows: seed.selectedEventRows.map { row in
                SoundPackEditorEventPresentation(
                    event: row.event,
                    coverage: row.coverage,
                    enabled: row.enabled,
                    audioDisplayName: row.audioDisplayName,
                    importAction: selectedIsWritable
                        ? makeAction(
                            .requestImport,
                            binding: .requestImport(
                                packID: selectedPack?.id ?? "",
                                bindTo: row.event),
                            seed: seed)
                        : nil,
                    previewAction: row.coverage.previewEnabled
                        ? makeAction(.preview, binding: .preview(event: row.event), seed: seed)
                        : nil,
                    clearAction: selectedIsWritable && row.coverage.previewEnabled
                        ? makeAction(.clear, binding: .clear(event: row.event), seed: seed)
                        : nil)
            },
            inventory: makeInventory(seed: seed, isWritable: selectedIsWritable),
            requestImportAction: selectedIsWritable
                ? selectedPack.map {
                    makeAction(
                        .requestImport,
                        binding: .requestImport(packID: $0.id, bindTo: nil),
                        seed: seed)
                }
                : nil,
            stopPreviewAction: makeAction(.stopPreview, binding: .stopPreview, seed: seed),
            retryLibraryAction: seed.library.canRetryEditorLibrary
                ? makeAction(.retryLibrary, binding: .retryLibrary, seed: seed)
                : nil,
            restoreAllFactoryPacksAction: seed.writesAllowed && !seed.builtinPackIDs.isEmpty
                ? makeAction(
                    .restoreAllFactory,
                    binding: .requestRestoreAllFactory,
                    seed: seed)
                : nil,
            recoveryActions: seed.factoryRestoreRetryPackIDs.map { packID in
                SoundPackEditorRecoveryPresentation(
                    packID: packID,
                    retryAction: makeAction(
                        .retryRestore,
                        binding: .requestRetryRestore(packID: packID),
                        seed: seed))
            })
    }

    private func makeEventsPresentation(
        route: EventSettingsWindowRoute,
        requestRevision: UInt64,
        candidateGenerationID: UUID?,
        seed: SoundPacksEditorModelSeed
    ) -> EventsSoundPackPresentation {
        let packs = seed.packCards.map { makePackPresentation(card: $0, seed: seed) }
        var adoptionPermit: SoundPackAdoptionPermit?
        if seed.library.isFresh,
            let candidateGenerationID,
            let event = route.event,
            case .eligible(let target) = model.aiCueAdoptionEligibility(for: event)
        {
            adoptionPermit = makeAdoptionPermit(
                target: target,
                candidateGenerationID: candidateGenerationID,
                seed: seed)
        }
        return EventsSoundPackPresentation(
            route: route,
            requestRevision: requestRevision,
            scope: scopeAvailability(seed),
            packs: packs,
            selectedPack: packs.first(where: { $0.id == seed.selectedPackID }),
            adoptionPermit: adoptionPermit,
            retryLibraryAction: seed.library.canRetryEditorLibrary
                ? makeAction(.retryLibrary, binding: .retryLibrary, seed: seed)
                : nil)
    }

    private func scopeAvailability(
        _ seed: SoundPacksEditorModelSeed
    ) -> SoundPackEditorScopeAvailability {
        guard isValidSoundPacksWindowSurface(seed.managedSurface), seed.writesAllowed else {
            return .unavailable(.scopeUnavailable)
        }
        return .available(seed.managedSurface.map(PanelSoundScopeID.surface) ?? .global)
    }

    private func makePackPresentation(
        card: PackCard,
        seed: SoundPacksEditorModelSeed
    ) -> SoundPackEditorPackPresentation {
        let isSelected = card.id == seed.selectedPackID
        let isBuiltin = seed.builtinPackIDs.contains(card.id)
        let isAvailable = card.availability == .installed
        let writesAllowed = seed.writesAllowed && isAvailable
        return SoundPackEditorPackPresentation(
            id: card.id,
            name: card.name,
            state: card.state,
            availability: card.availability,
            isSelected: isSelected,
            isStarred: seed.starredPackIDs.contains(card.id),
            isBuiltinReadOnly: isBuiltin,
            inspectAction: makeAction(.inspect, binding: .inspect(packID: card.id), seed: seed),
            useAction: writesAllowed
                ? makeAction(.use, binding: .use(packID: card.id), seed: seed) : nil,
            toggleStarAction: writesAllowed
                ? makeAction(.toggleStar, binding: .toggleStar(packID: card.id), seed: seed) : nil,
            forkAction: writesAllowed && isBuiltin && isSelected
                ? makeAction(.fork, binding: .fork(packID: card.id), seed: seed) : nil,
            deleteAction: writesAllowed && !isBuiltin && isSelected
                ? makeAction(.deletePack, binding: .requestDeletePack(packID: card.id), seed: seed)
                : nil,
            restoreAction: writesAllowed && isBuiltin && isSelected
                ? makeAction(
                    .restoreFactory,
                    binding: .requestRestoreFactory(packID: card.id),
                    seed: seed)
                : nil,
            revealAction: isAvailable
                ? makeAction(.reveal, binding: .revealPack(packID: card.id), seed: seed) : nil)
    }

    private func makeInventory(
        seed: SoundPacksEditorModelSeed,
        isWritable: Bool
    ) -> SoundPackEditorInventoryPresentation {
        func rows(_ files: [PackAudioFile]) -> [SoundPackEditorAudioPresentation] {
            files.map { file in
                SoundPackEditorAudioPresentation(
                    fileName: file.fileName,
                    isOrphan: file.isOrphan,
                    assignments: isWritable
                        ? Event.allCases.map { event in
                            SoundPackEditorAssignmentPresentation(
                                event: event,
                                action: makeAction(
                                    .assign,
                                    binding: .assign(fileName: file.fileName, event: event),
                                    seed: seed))
                        } : [],
                    deleteAction: isWritable && file.isOrphan
                        ? makeAction(
                            .deleteOrphan,
                            binding: .requestDeleteOrphan(fileName: file.fileName),
                            seed: seed)
                        : nil,
                    revealAction: makeAction(
                        .reveal,
                        binding: .revealAudio(fileName: file.fileName),
                        seed: seed))
            }
        }
        switch seed.selectedAudioInventoryState {
        case .idle:
            return .idle
        case .loading(let previous):
            return .loading(previous: previous.map(rows))
        case .ready(let files):
            return .ready(rows(files))
        case .failed(let previous, _):
            return .failed(previous: previous.map(rows))
        }
    }

    private func makeActivities(
        seed: SoundPacksEditorModelSeed
    ) -> [SoundPackEditorActivityPresentation] {
        operationOrder.compactMap { operationID in
            guard let state = operationStates[operationID] else { return nil }
            return SoundPackEditorActivityPresentation(
                operationID: operationID,
                kind: state.kind,
                phase: state.phase,
                packID: state.packID,
                event: state.event,
                cancelAction: state.phase == .busy
                    ? makeAction(
                        .cancelOperation,
                        binding: .cancelOperation(operationID),
                        seed: seed)
                    : nil)
        }
    }

    private func makeConfirmation(
        seed: SoundPacksEditorModelSeed
    ) -> SoundPackEditorConfirmation? {
        guard let pendingConfirmationState else { return nil }
        return SoundPackEditorConfirmation(
            id: pendingConfirmationState.id,
            kind: pendingConfirmationState.kind,
            packID: pendingConfirmationState.packID,
            fileName: pendingConfirmationState.fileName,
            confirmAction: makeAction(
                .confirm,
                binding: .confirm(pendingConfirmationState.id),
                seed: seed),
            cancelAction: makeAction(
                .cancelConfirmation,
                binding: .cancelConfirmation(pendingConfirmationState.id),
                seed: seed))
    }

    private func makeImportPermit(
        packID: String,
        bindTo: Event?,
        seed: SoundPacksEditorModelSeed
    ) -> SoundPackImportPermit {
        nextCapabilityID &+= 1
        let permit = SoundPackImportPermit(id: nextCapabilityID)
        importPermitLedger[permit.id] = EditorPermitBinding(
            packID: packID,
            bindTo: bindTo,
            context: context,
            actionEpoch: actionEpoch,
            selectionGeneration: seed.selectionGeneration,
            snapshotRevision: seed.snapshotRevision)
        return permit
    }

    private func prunePermits(using seed: SoundPacksEditorModelSeed) {
        importPermitLedger = importPermitLedger.filter { _, binding in
            binding.context == context
                && binding.actionEpoch == actionEpoch
                && binding.selectionGeneration == seed.selectionGeneration
                && binding.snapshotRevision == seed.snapshotRevision
        }
        adoptionPermitLedger = adoptionPermitLedger.filter { _, binding in
            binding.context == context
                && binding.actionEpoch == actionEpoch
                && binding.candidateGenerationEpoch == candidateGenerationEpoch
                && binding.selectionGeneration == seed.selectionGeneration
                && binding.snapshotRevision == seed.snapshotRevision
        }
    }

    private func ingestAnnouncements(from statuses: [SoundPacksWindowStatus]) {
        for status in statuses.sorted(by: { $0.revision < $1.revision })
        where seenStatusRevisions.insert(status.revision).inserted {
            nextCapabilityID &+= 1
            announcementQueue.append(
                SoundPackEditorAnnouncement(
                    id: SoundPackEditorAnnouncement.ID(rawValue: nextCapabilityID),
                    kind: .windowStatus(status.kind),
                    actionText: status.actionText,
                    messageText: status.messageText))
        }
    }

    private func enqueueOperationAnnouncement(_ kind: SoundPackEditorActivityKind) {
        nextCapabilityID &+= 1
        announcementQueue.append(
            SoundPackEditorAnnouncement(
                id: SoundPackEditorAnnouncement.ID(rawValue: nextCapabilityID),
                kind: .operationSucceeded(kind),
                actionText: nil,
                messageText: nil))
    }

    private func makeAction(
        _ kind: SoundPackEditorAction.Kind,
        binding intent: EditorActionIntent,
        seed: SoundPacksEditorModelSeed
    ) -> SoundPackEditorAction {
        nextCapabilityID &+= 1
        let action = SoundPackEditorAction(id: nextCapabilityID, kind: kind)
        actionLedger[action.id] = EditorActionBinding(
            intent: intent,
            context: context,
            actionEpoch: actionEpoch,
            selectionGeneration: seed.selectionGeneration,
            snapshotRevision: seed.snapshotRevision)
        return action
    }

    private func makeAdoptionPermit(
        target: AICueAdoptionTarget,
        candidateGenerationID: UUID,
        seed: SoundPacksEditorModelSeed
    ) -> SoundPackAdoptionPermit {
        nextCapabilityID &+= 1
        let permit = SoundPackAdoptionPermit(id: nextCapabilityID)
        adoptionPermitLedger[permit.id] = EditorAdoptionBinding(
            target: target,
            candidateGenerationID: candidateGenerationID,
            context: context,
            actionEpoch: actionEpoch,
            candidateGenerationEpoch: candidateGenerationEpoch,
            selectionGeneration: seed.selectionGeneration,
            snapshotRevision: seed.snapshotRevision)
        return permit
    }

    /// Applies one typed route to the shared inspection/write model. Missing targets remain
    /// pending until the shared library can prove a fresh ready snapshot; only then may the
    /// presentation degrade to overview.
    @discardableResult
    public func apply(
        route: SoundPacksWindowRoute
    ) -> SoundPacksWindowRouteResolution {
        model.setManagedSurface(route.surface)
        switch resolveSoundPacksWindowRoute(
            route,
            availablePackIDs: Set(model.packCards.map(\.id)),
            libraryState: model.libraryPresentationState)
        {
        case .pending:
            return .pending(route)
        case .resolved(let resolvedRoute):
            guard let packID = resolvedRoute.editTarget?.packID else {
                return .resolved(resolvedRoute)
            }
            guard model.selectPackForInspection(packID) else {
                return .resolved(.overview(surface: resolvedRoute.surface))
            }
            return .resolved(resolvedRoute)
        }
    }

    /// A pack selected from Events still uses the established panel-to-editor refresh contract.
    /// The Settings shell does not retain a second coordinator or ask the editor to infer writes.
    public func completePanelPackSwitch(_ outcome: PanelPackSwitchOutcome) {
        refreshCoordinator?.completePanelPackSwitch(outcome)
    }

    /// Headless adoption entry used by the retained Events & Sounds destination. It reuses this
    /// owner's disk-backed model and package-lock publication path without creating another window
    /// or write owner.
    public func adoptAICue(
        _ request: AICueAdoptionRequest
    ) async -> Result<AICueAdoptionOutcome, AICueAdoptionError> {
        model.setManagedSurface(request.target.surface)
        return await model.adoptAICue(request)
    }

    /// Coordinates asynchronous status announcements across retained Settings presentations. A
    /// revision is consumed only after the actual key Sounds destination posts it successfully.
    public func beginStatusAnnouncementAttempt(revision: Int, isWindowKey: Bool) -> Bool {
        statusAnnouncementTracker.beginAttempt(
            revision: revision,
            isWindowKey: isWindowKey)
    }

    public func finishStatusAnnouncementAttempt(revision: Int, didPost: Bool) {
        statusAnnouncementTracker.finishAttempt(revision: revision, didPost: didPost)
    }

    /// Returns one shared suppression decision to every retained presentation observing the same
    /// `@Published` selection emission. This prevents an inactive window from consuming the fork
    /// suppression token before the key presentation sees it, while a later A→B→A emission still
    /// computes a fresh decision after the intervening pack ID.
    public func shouldAnnounceSelectionChange(to packID: String?) -> Bool {
        if let lastSelectionAnnouncementDecision,
            lastSelectionAnnouncementDecision.packID == packID
        {
            return lastSelectionAnnouncementDecision.shouldAnnounce
        }
        let shouldAnnounce = !model.consumeSelectionAnnouncementSuppression(for: packID)
        lastSelectionAnnouncementDecision = (packID, shouldAnnounce)
        return shouldAnnounce
    }

    /// Projects announcement facts from the shared read model for whichever retained window is
    /// currently key. `@Published` emits before storing, so callers may pass the emitted selection
    /// or library state to describe the transition rather than the previous property value.
    public func announcementFacts(
        selectedPackID: String? = nil,
        usesEmittedSelection: Bool = false,
        libraryPresentationState: SoundPackLibraryPresentationState? = nil
    ) -> SoundPacksWindowAnnouncementFacts {
        let effectiveSelectedPackID = usesEmittedSelection ? selectedPackID : model.selectedPackID
        let selectedName = effectiveSelectedPackID.flatMap { packID in
            model.packCards.first(where: { $0.id == packID }).map {
                SelectedPackMetadata(id: $0.id, name: $0.name).displayName
            }
        }
        return SoundPacksWindowAnnouncementFacts(
            packCount: model.packCards.count,
            selectedPackName: selectedName,
            libraryPresentationState:
                libraryPresentationState ?? model.libraryPresentationState)
    }
}

private struct EditorActionBinding {
    let intent: EditorActionIntent
    let context: SoundPacksEditorContext
    let actionEpoch: UInt64
    let selectionGeneration: UInt64
    let snapshotRevision: UInt64?
}

private struct EditorPermitBinding {
    let packID: String
    let bindTo: Event?
    let context: SoundPacksEditorContext
    let actionEpoch: UInt64
    let selectionGeneration: UInt64
    let snapshotRevision: UInt64?
}

private struct EditorAdoptionBinding {
    let target: AICueAdoptionTarget
    let candidateGenerationID: UUID
    let context: SoundPacksEditorContext
    let actionEpoch: UInt64
    let candidateGenerationEpoch: UInt64
    let selectionGeneration: UInt64
    let snapshotRevision: UInt64?
}

private struct EditorConfirmationState {
    let id: SoundPackEditorConfirmation.ID
    let kind: SoundPackEditorConfirmation.Kind
    let packID: String?
    let fileName: String?
    let target: EditorScheduledWork
    let context: SoundPacksEditorContext
    let actionEpoch: UInt64
    let selectionGeneration: UInt64
    let snapshotRevision: UInt64?
}

private struct EditorOperationState {
    let kind: SoundPackEditorActivityKind
    let phase: SoundPackEditorActivityPhase
    let packID: String?
    let event: Event?

    func withPhase(_ phase: SoundPackEditorActivityPhase) -> Self {
        Self(kind: kind, phase: phase, packID: packID, event: event)
    }
}

private enum EditorScheduledWork {
    case fork(packID: String)
    case deletePack(packID: String)
    case deleteOrphan(packID: String, fileName: String)
    case restoreFactory(packID: String)
    case retryRestore(packID: String)
    case restoreAllFactory

    var activityKind: SoundPackEditorActivityKind {
        switch self {
        case .fork: .fork
        case .deletePack: .deletePack
        case .deleteOrphan: .deleteOrphan
        case .restoreFactory, .retryRestore: .restoreFactory
        case .restoreAllFactory: .restoreAllFactory
        }
    }

    var event: Event? { nil }
}

private enum EditorActionIntent {
    case inspect(packID: String)
    case use(packID: String)
    case toggleStar(packID: String)
    case fork(packID: String)
    case requestImport(packID: String, bindTo: Event?)
    case assign(fileName: String, event: Event)
    case clear(event: Event)
    case preview(event: Event)
    case stopPreview
    case revealPack(packID: String)
    case revealAudio(fileName: String)
    case requestDeletePack(packID: String)
    case requestDeleteOrphan(fileName: String)
    case requestRestoreFactory(packID: String)
    case requestRetryRestore(packID: String)
    case requestRestoreAllFactory
    case retryLibrary
    case cancelOperation(SoundPackEditorOperationID)
    case confirm(SoundPackEditorConfirmation.ID)
    case cancelConfirmation(SoundPackEditorConfirmation.ID)
}

extension SoundPackLibraryPresentation {
    fileprivate var canRetryEditorLibrary: Bool {
        if case .failed = self { return true }
        return false
    }
}

extension PanelPackSwitchOutcome {
    fileprivate var refreshesEditor: Bool {
        if case .succeeded = self { return true }
        return false
    }
}

extension SoundPackEditorAction.Kind {
    fileprivate var requiresWritableScope: Bool {
        switch self {
        case .use, .toggleStar, .fork, .requestImport, .assign, .clear, .deletePack,
            .deleteOrphan, .restoreFactory, .retryRestore, .restoreAllFactory, .confirm:
            true
        case .inspect, .preview, .stopPreview, .reveal, .retryLibrary, .cancelOperation,
            .cancelConfirmation:
            false
        }
    }
}

extension Result {
    fileprivate var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}
