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
    private static let maximumRetainedTerminalOperationCount = 32

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
    private var confirmationAttemptLedger:
        [SoundPackEditorAction.ID: SoundPackEditorConfirmation.ID] = [:]
    private var importPermitLedger: [SoundPackImportPermit.ID: EditorPermitBinding] = [:]
    private var adoptionPermitLedger: [SoundPackAdoptionPermit.ID: EditorAdoptionBinding] = [:]
    private var pendingConfirmationState: EditorConfirmationState?
    private var operationStates: [SoundPackEditorOperationID: EditorOperationState] = [:]
    private var operationOrder: [SoundPackEditorOperationID] = []
    private var operationTasks: [SoundPackEditorOperationID: Task<Void, Never>] = [:]
    private var operationCancellations:
        [SoundPackEditorOperationID: SoundPackAudioImportCancellation] = [:]
    private var announcementQueue: [EditorAnnouncementDebt] = []
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
    private var suppressesNextForkLibraryObservationCycle = false
    private var interfaceHasActivated = false

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

    /// Creates a real accepted/busy owner transition for the no-I/O state gallery, then cancels
    /// its not-yet-started scheduled writer while retaining that immutable presentation frame.
    /// The MainActor synchronous boundary guarantees the task cannot reach its first yield before
    /// cancellation. Production builds do not expose this static-fixture seam.
    @discardableResult
    package func freezeAcceptedOperationForStateGalleryFixture(
        _ action: SoundPackEditorAction
    ) -> Bool {
        guard case .accepted(let operationID) = send(.invoke(action)),
            let task = operationTasks.removeValue(forKey: operationID)
        else { return false }
        task.cancel()
        operationCancellations.removeValue(forKey: operationID)
        return operationStates[operationID]?.phase == .busy
    }
    #endif

    private static func initialPresentation(
        from seed: SoundPacksEditorModelSeed
    ) -> SoundPacksEditorPresentation {
        SoundPacksEditorPresentation(
            revision: 0,
            library: seed.library,
            installedPackIDs: seed.installedPackIDs,
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
            interfaceHasActivated = true
            let wasSoundsActive = context.isSounds
            actionEpoch &+= 1
            advanceCandidateGeneration(for: nextContext)
            context = nextContext
            switch nextContext {
            case .inactive:
                publish(from: model.editorProjectionSeed())
            case .sounds(let route, _):
                let (_, seed) = captureModelTransition {
                    model.setManagedSurface(route.surface)
                    let seed = model.editorProjectionSeed()
                    if case .ready = seed.library,
                        let packID = route.editTarget?.packID,
                        seed.installedPackIDs.contains(packID)
                    {
                        _ = model.selectPackForInspection(packID)
                    }
                }
                if !wasSoundsActive {
                    enqueueSemanticAnnouncement(
                        .windowOpened(announcementFacts(from: seed)),
                        priority: announcementPriority(for: seed.announcementLibraryState))
                }
                publish(from: seed)
            case .events(let route, _, _):
                let (_, seed) = captureModelTransition {
                    model.setManagedSurface(route.surface)
                }
                publish(from: seed)
            }
            return .applied
        case .invoke(let action):
            return invoke(action)
        case .prepareDrop(let action):
            guard action.kind == .requestImport else {
                return .rejected(.actionUnavailable)
            }
            return invoke(action, importSource: .drop)
        case .completePanelPackSwitch(let outcome):
            completePanelPackSwitch(outcome)
            return outcome.refreshesEditor ? .applied : .unchanged
        case .acknowledgeAnnouncement(let id, let didPost):
            guard let index = announcementQueue.firstIndex(where: { $0.announcement.id == id })
            else {
                return .rejected(.staleAction)
            }
            guard didPost else { return .unchanged }
            let debt = announcementQueue.remove(at: index)
            if let operationID = debt.operationID {
                retireTerminalOperation(operationID)
            }
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
        let (_, seed) = captureModelTransition {
            model.refreshEditorConfigProjection()
        }
        publish(from: seed, forcingCapabilityGeneration: false)
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
        guard
            let eventBinding = eventBindingExpectation(
                for: binding.target.event,
                in: seed)
        else {
            return .rejected(.targetChanged)
        }
        let freshness = EditorAdoptionMutationFreshness(
            snapshotRevision: seed.snapshotRevision,
            eventBinding: eventBinding)

        let cancellation = SoundPackAudioImportCancellation()
        let operationID = beginAsyncOperation(
            kind: .adoptAICue,
            packID: binding.target.packID,
            event: binding.target.event,
            cancellation: cancellation)
        publish(from: seed)
        let request = AudioImportRequest(
            sourceURL: candidate.asset.fileURL,
            suggestedFileName:
                "ai-cue-\(candidate.id.uuidString.lowercased())."
                + candidate.asset.sniffedFormat.rawValue)
        let job = SoundPackAudioImportJob(
            requests: [request],
            packID: binding.target.packID,
            environment: importEnvironment)
        switch await audioImportExecutor.validateTarget(job, cancellation: cancellation) {
        case .cancelled:
            settleAsyncOperation(
                operationID,
                phase: .cancelled(changedOnDisk: false),
                seed: model.editorProjectionSeed())
            return .rejected(.cancelled)
        case .unavailable:
            let observed = await model.refreshEditorObservationForMutation()
            let failure: SoundPackEditorFailure =
                observed.writesAllowed
                ? .packUnavailable : .scopeUnavailable
            settleAsyncOperation(operationID, phase: .failed(failure), seed: observed)
            return .rejected(failure)
        case .available:
            break
        }

        model.refreshEditorConfigProjection()
        let preWrite = model.editorProjectionSeed()
        guard
            adoptionTargetIsCurrent(
                binding: binding,
                freshness: freshness,
                seed: preWrite)
        else {
            let failure: SoundPackEditorFailure =
                preWrite.writesAllowed
                ? .stalePermit : .scopeUnavailable
            settleAsyncOperation(operationID, phase: .failed(failure), seed: preWrite)
            return .rejected(failure)
        }

        let (mutation, startedSeed) = captureModelTransition {
            model.beginEditorCompoundMutation(packID: binding.target.packID)
        }
        publish(from: startedSeed)
        let execution = await audioImportExecutor.execute(
            job,
            cancellation: cancellation)
        switch execution {
        case .cancelledBeforeWrite:
            let (_, settledSeed) = captureModelTransition {
                model.finishEditorCompoundMutationWithoutChange(mutation)
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
                    model.finishEditorCompoundMutationWithoutChange(mutation)
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
                freshness: freshness,
                mutation: mutation,
                imported: imported,
                displayName: displayName,
                cancellationRequested: cancellationRequested)
        }
    }

    private func finishAdoption(
        operationID: SoundPackEditorOperationID,
        binding: EditorAdoptionBinding,
        freshness: EditorAdoptionMutationFreshness,
        mutation: SoundPackLibraryMutation?,
        imported: ImportedAudioFile,
        displayName: AICueDisplayName,
        cancellationRequested: Bool
    ) -> SoundPacksEditorOperationResult {
        model.refreshEditorConfigProjection()
        let current = model.editorProjectionSeed()
        let targetRemainsValid: Bool
        if binding.context == context,
            binding.actionEpoch == actionEpoch,
            binding.candidateGenerationEpoch == candidateGenerationEpoch,
            binding.selectionGeneration == current.selectionGeneration,
            freshness.snapshotRevision == current.snapshotRevision,
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
                target: binding.target,
                expectedEventBinding: freshness.eventBinding)
            {
            case .success(let outcome):
                bindingOutcome = outcome
                failure = nil
            case .failure(.targetChanged):
                failure = .targetChanged
            case .failure:
                failure = .mutationFailed
            }
        }

        let (_, settledSeed) = captureModelTransition {
            model.finishEditorCompoundMutation(
                packID: binding.target.packID,
                mutation: mutation,
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
        let previewAction = makeForegroundPreviewAction(
            imported,
            seed: settledSeed)
        return .adopted(
            SoundPackEditorAdoptionOutcome(
                outcome: AICueAdoptionOutcome(
                    target: binding.target,
                    importedFile: imported,
                    finalDisplayName: bindingOutcome.finalDisplayName),
                previewAction: previewAction))
    }

    private func performImport(
        permit: SoundPackImportPermit,
        sources: [URL],
        bindTo: Event?
    ) async -> SoundPacksEditorOperationResult {
        let (_, seed) = captureModelTransition {
            model.refreshEditorConfigProjection()
        }
        publish(from: seed, forcingCapabilityGeneration: false)
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
            // The picker/drop capability was consumed, so publish a fresh generation even
            // though no domain fact changed. This keeps a cancelled UI affordance retryable
            // without inventing activity, status, announcement, disk work, or a shared scan.
            publish(from: seed)
            return .rejected(.cancelled)
        }
        let eventBinding = bindTo.flatMap { eventBindingExpectation(for: $0, in: seed) }
        if bindTo != nil, eventBinding == nil {
            return .rejected(.targetChanged)
        }
        let freshness = EditorImportMutationFreshness(
            snapshotRevision: seed.snapshotRevision,
            eventBinding: eventBinding)

        let cancellation = SoundPackAudioImportCancellation()
        let operationID = beginAsyncOperation(
            kind: .importAudio,
            packID: binding.packID,
            event: bindTo,
            cancellation: cancellation)
        publish(from: seed)

        let requests = sources.map {
            AudioImportRequest(sourceURL: $0, suggestedFileName: $0.lastPathComponent)
        }
        let job = SoundPackAudioImportJob(
            requests: requests,
            packID: binding.packID,
            environment: importEnvironment)
        switch await audioImportExecutor.validateTarget(job, cancellation: cancellation) {
        case .cancelled:
            settleAsyncOperation(
                operationID,
                phase: .cancelled(changedOnDisk: false),
                seed: model.editorProjectionSeed())
            return .rejected(.cancelled)
        case .unavailable:
            let observed = await model.refreshEditorObservationForMutation()
            let failure: SoundPackEditorFailure =
                observed.writesAllowed
                ? .packUnavailable : .scopeUnavailable
            settleAsyncOperation(operationID, phase: .failed(failure), seed: observed)
            return .rejected(failure)
        case .available:
            break
        }

        model.refreshEditorConfigProjection()
        let preWrite = model.editorProjectionSeed()
        guard
            importTargetIsCurrent(
                binding: binding,
                freshness: freshness,
                seed: preWrite)
        else {
            let failure: SoundPackEditorFailure =
                preWrite.writesAllowed
                ? .stalePermit : .scopeUnavailable
            settleAsyncOperation(operationID, phase: .failed(failure), seed: preWrite)
            return .rejected(failure)
        }

        let (mutation, startedSeed) = captureModelTransition {
            model.beginEditorCompoundMutation(packID: binding.packID)
        }
        publish(from: startedSeed)
        let execution = await audioImportExecutor.execute(
            job,
            cancellation: cancellation)
        switch execution {
        case .cancelledBeforeWrite:
            let (_, settledSeed) = captureModelTransition {
                model.finishEditorCompoundMutationWithoutChange(mutation)
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
                freshness: freshness,
                mutation: mutation,
                batch: batch,
                cancellationRequested: cancellationRequested || cancellation.isCancelled)
        }
    }

    private func finishImport(
        operationID: SoundPackEditorOperationID,
        binding: EditorPermitBinding,
        freshness: EditorImportMutationFreshness,
        mutation: SoundPackLibraryMutation?,
        batch: AudioImportBatchResult,
        cancellationRequested: Bool
    ) -> SoundPacksEditorOperationResult {
        guard !batch.accepted.isEmpty else {
            let (_, seed) = captureModelTransition {
                model.finishEditorCompoundMutationWithoutChange(mutation)
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
                    orphan: nil,
                    completion: .failed(.importRejected),
                    previewAction: nil))
        }

        model.refreshEditorConfigProjection()
        let current = model.editorProjectionSeed()
        let remainsForeground =
            binding.context == context
            && binding.actionEpoch == actionEpoch
            && binding.selectionGeneration == current.selectionGeneration
            && freshness.snapshotRevision == current.snapshotRevision
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
                    packID: binding.packID,
                    expectedEventBinding: freshness.eventBinding)
                {
                case .success:
                    boundEvent = event
                case .failure(.targetChanged):
                    orphan = imported
                    failure = .targetChanged
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
            mutation: mutation,
            batch: batch,
            boundEvent: boundEvent,
            completedInBackground: !remainsForeground || failure == .targetChanged,
            orphan: orphan,
            failure: failure)
    }

    private func completeImport(
        operationID: SoundPackEditorOperationID,
        binding: EditorPermitBinding,
        mutation: SoundPackLibraryMutation?,
        batch: AudioImportBatchResult,
        boundEvent: Event?,
        completedInBackground: Bool,
        orphan: ImportedAudioFile?,
        failure: SoundPackEditorFailure?
    ) -> SoundPacksEditorOperationResult {
        let (_, settledSeed) = captureModelTransition {
            model.finishEditorCompoundMutation(
                packID: binding.packID,
                mutation: mutation,
                changedDespiteFailure: failure != nil)
        }
        let phase: SoundPackEditorActivityPhase
        let completion: SoundPackEditorOperationCompletion
        if let orphan, let failure {
            phase = .orphan(fileName: orphan.fileName, failure: failure)
            completion = .orphan(failure)
        } else if failure == .cancelled {
            phase = .cancelled(changedOnDisk: true)
            completion = .cancelled(changedOnDisk: true)
        } else if !batch.rejected.isEmpty {
            phase = .partial(accepted: batch.accepted.count, rejected: batch.rejected.count)
            completion = .partial(
                accepted: batch.accepted.count,
                rejected: batch.rejected.count)
        } else {
            phase = .succeeded
            completion = .succeeded
        }
        settleAsyncOperation(operationID, phase: phase, seed: settledSeed)
        let previewAction: SoundPackEditorAction?
        if !completedInBackground, failure == nil, let imported = batch.accepted.last {
            previewAction = makeForegroundPreviewAction(imported, seed: settledSeed)
        } else {
            previewAction = nil
        }
        return .imported(
            SoundPackEditorImportOutcome(
                accepted: batch.accepted,
                rejected: batch.rejected,
                boundEvent: boundEvent,
                completedInBackground: completedInBackground,
                orphan: orphan,
                completion: completion,
                previewAction: previewAction))
    }

    private func eventBindingExpectation(
        for event: Event,
        in seed: SoundPacksEditorModelSeed
    ) -> ManifestEventBindingExpectation? {
        guard let row = seed.selectedEventRows.first(where: { $0.event == event }) else {
            return nil
        }
        switch row.coverage {
        case .unmapped:
            return .unmapped
        case .present(let fileName), .broken(let fileName):
            return .mapped(fileName: fileName)
        }
    }

    private func importTargetIsCurrent(
        binding: EditorPermitBinding,
        freshness: EditorImportMutationFreshness,
        seed: SoundPacksEditorModelSeed
    ) -> Bool {
        guard binding.context == context,
            binding.actionEpoch == actionEpoch,
            binding.selectionGeneration == seed.selectionGeneration,
            freshness.snapshotRevision == seed.snapshotRevision,
            seed.library.isFresh,
            seed.writesAllowed,
            seed.installedPackIDs.contains(binding.packID),
            seed.selectedPackID == binding.packID,
            !seed.builtinPackIDs.contains(binding.packID)
        else { return false }
        guard let event = binding.bindTo else { return true }
        return eventBindingExpectation(for: event, in: seed) == freshness.eventBinding
    }

    private func adoptionTargetIsCurrent(
        binding: EditorAdoptionBinding,
        freshness: EditorAdoptionMutationFreshness,
        seed: SoundPacksEditorModelSeed
    ) -> Bool {
        guard binding.context == context,
            binding.actionEpoch == actionEpoch,
            binding.candidateGenerationEpoch == candidateGenerationEpoch,
            binding.selectionGeneration == seed.selectionGeneration,
            freshness.snapshotRevision == seed.snapshotRevision,
            seed.library.isFresh,
            seed.writesAllowed,
            seed.installedPackIDs.contains(binding.target.packID),
            !seed.builtinPackIDs.contains(binding.target.packID),
            eventBindingExpectation(for: binding.target.event, in: seed)
                == freshness.eventBinding,
            case .success(let currentTarget) = model.captureAICueAdoptionTarget(
                for: binding.target.event),
            currentTarget == binding.target
        else { return false }
        return true
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

    private var hasBusyOperation: Bool {
        operationStates.values.contains { $0.phase == .busy }
    }

    private func settleAsyncOperation(
        _ operationID: SoundPackEditorOperationID,
        phase: SoundPackEditorActivityPhase,
        seed: SoundPacksEditorModelSeed
    ) {
        operationCancellations.removeValue(forKey: operationID)
        guard let state = operationStates[operationID] else { return }
        operationStates[operationID] = state.withPhase(phase)
        if let completion = phase.announcementCompletion {
            enqueueOperationAnnouncement(
                state.kind,
                completion: completion,
                operationID: operationID)
        }
        trimTerminalOperationHistory()
        publish(from: seed)
    }

    private func invoke(
        _ action: SoundPackEditorAction,
        importSource: EditorImportSource = .picker
    ) -> SoundPacksEditorCommandResult {
        // Latest config/scope has precedence over capability identity. This is a config-only read
        // and deliberately does not ask the shared library to scan.
        model.refreshEditorConfigProjection()
        let seed = model.editorProjectionSeed()
        if action.kind.requiresWritableScope, !seed.writesAllowed {
            consumeConfirmationAttemptIfCurrent(action)
            publish(from: seed)
            return .rejected(.scopeUnavailable)
        }
        let candidateBinding = actionLedger[action.id]
        if action.kind.requiresFreshLibrary,
            candidateBinding?.intent.allowsNonFreshLibrary != true,
            !seed.library.isFresh
        {
            consumeConfirmationAttemptIfCurrent(action)
            publish(from: seed)
            return action.kind == .confirm
                ? .rejected(.staleConfirmation) : .rejected(.staleAction)
        }
        guard let binding = actionLedger[action.id], binding.context == context,
            binding.actionEpoch == actionEpoch,
            binding.selectionGeneration == seed.selectionGeneration,
            binding.intent.allowsSnapshotAdvance
                || binding.snapshotRevision == seed.snapshotRevision
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
            return acceptScheduledOperation(
                kind: .use,
                packID: packID,
                event: nil,
                binding: binding,
                work: .use(packID: packID))
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
            switch importSource {
            case .picker:
                return .nativeEffect(.selectAudioFiles(permit: permit, bindTo: bindTo))
            case .drop:
                return .importPermit(permit: permit, bindTo: bindTo)
            }
        case .assign(let packID, let fileName, let event):
            return acceptScheduledOperation(
                kind: .assign,
                packID: packID,
                event: event,
                binding: binding,
                work: .assign(packID: packID, fileName: fileName, event: event))
        case .clear(let packID, let event):
            return acceptScheduledOperation(
                kind: .clear,
                packID: packID,
                event: event,
                binding: binding,
                work: .clear(packID: packID, event: event))
        case .preview(let fileURL):
            publish(from: seed)
            return .nativeEffect(
                .playAudio(
                    fileURL: fileURL,
                    volume: AfplayVolume.clamped(seed.config.masterVolume)))
        case .previewForegroundImport(let fileURL, let packID):
            guard seed.installedPackIDs.contains(packID),
                seed.selectedPackID == packID,
                !seed.builtinPackIDs.contains(packID)
            else {
                publish(from: seed)
                return .rejected(.staleAction)
            }
            publish(from: seed)
            return .nativeEffect(
                .playAudio(
                    fileURL: fileURL,
                    volume: AfplayVolume.clamped(seed.config.masterVolume)))
        case .stopPreview:
            publish(from: seed)
            return .nativeEffect(.stopAudio)
        case .reveal(let fileURL):
            publish(from: seed)
            return .nativeEffect(.reveal(fileURL: fileURL))
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
            trimTerminalOperationHistory()
            publish(from: seed)
            return .applied
        case .confirm(let confirmationID):
            return confirm(confirmationID, seed: seed)
        case .cancelConfirmation(let confirmationID):
            guard pendingConfirmationState?.id == confirmationID else {
                return .rejected(.staleConfirmation)
            }
            clearPendingConfirmation()
            publish(from: seed)
            return .applied
        }
    }

    private func consumeConfirmationAttemptIfCurrent(_ action: SoundPackEditorAction) {
        guard action.kind == .confirm,
            let confirmationID = confirmationAttemptLedger.removeValue(forKey: action.id),
            pendingConfirmationState?.id == confirmationID
        else { return }
        clearPendingConfirmation()
    }

    private func clearPendingConfirmation() {
        pendingConfirmationState = nil
        confirmationAttemptLedger.removeAll(keepingCapacity: true)
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
        confirmationAttemptLedger.removeAll(keepingCapacity: true)
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
        clearPendingConfirmation()
        guard seed.library.isFresh,
            confirmation.context == context,
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
            defer { self.operationTasks.removeValue(forKey: operationID) }
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
        let libraryPermitsExecution =
            current.library.isFresh
            || (current.library == .loading(previousAvailable: true)
                && current.snapshotRevision == binding.snapshotRevision)
        guard libraryPermitsExecution, current.writesAllowed, binding.context == context,
            binding.actionEpoch == actionEpoch,
            binding.selectionGeneration == current.selectionGeneration,
            binding.snapshotRevision == current.snapshotRevision
        else {
            let failure: SoundPackEditorFailure =
                current.writesAllowed ? .staleAction : .scopeUnavailable
            finishOperation(
                operationID,
                receipt: .rejected(failure),
                seed: current)
            return
        }

        let (receipt, settledSeed) = captureModelTransition {
            () -> EditorMutationReceipt in
            let receipt: EditorMutationReceipt
            switch work {
            case .use(let packID):
                guard model.selectPackForInspection(packID) else {
                    return .rejected(.staleAction)
                }
                receipt = .use(model.useSelectedPack())
            case .assign(let packID, let fileName, let event):
                guard model.selectedPackID == packID else {
                    return .rejected(.staleAction)
                }
                receipt = .assign(
                    packID: packID,
                    result: model.assignSelectedAudioFile(fileName, to: event))
            case .clear(let packID, let event):
                guard model.selectedPackID == packID else {
                    return .rejected(.staleAction)
                }
                receipt = .clear(
                    packID: packID,
                    result: model.clearSelectedEventBinding(event))
            case .fork(let packID):
                guard model.selectedPackID == packID else {
                    return .rejected(.staleAction)
                }
                suppressesNextForkLibraryObservationCycle = true
                let result = model.forkSelectedFactoryPack()
                if case .failure = result {
                    suppressesNextForkLibraryObservationCycle = false
                }
                receipt = .fork(result)
            case .deletePack(let packID):
                receipt = .deletePack(
                    packID: packID,
                    result: model.deleteSelectedUserPackAfterConfirmation(
                        expectedPackID: packID))
            case .deleteOrphan(let packID, let fileName):
                receipt = .deleteOrphan(
                    packID: packID,
                    result: model.deleteSelectedOrphanAudioFileAfterConfirmation(
                        fileName,
                        expectedPackID: packID))
            case .restoreFactory(let packID):
                receipt = .restoreFactory(
                    packID: packID,
                    result: model.restoreSelectedFactoryPackAfterConfirmation(
                        expectedPackID: packID))
            case .retryRestore(let packID):
                receipt = .retryRestore(
                    packID: packID,
                    result: model.retryFailedFactoryPackRestoreAfterConfirmation(
                        expectedPackID: packID))
            case .restoreAllFactory:
                receipt = .restoreAllFactory(model.restoreAllFactoryPacksAfterConfirmation())
            }
            return receipt
        }
        finishOperation(
            operationID,
            receipt: receipt,
            seed: settledSeed)
    }

    private func finishOperation(
        _ operationID: SoundPackEditorOperationID,
        receipt: EditorMutationReceipt,
        seed: SoundPacksEditorModelSeed
    ) {
        operationTasks.removeValue(forKey: operationID)
        guard let state = operationStates[operationID] else { return }
        let phase = receipt.phase
        operationStates[operationID] = state.withPhase(phase)
        if case .succeeded = phase {
            // The operation receipt is the semantic debt for this synchronous transition.
            // Retain legacy model statuses for direct model consumers, but do not enqueue a
            // second owner debt describing the same completed mutation.
            for status in seed.windowStatuses {
                seenStatusRevisions.insert(status.revision)
            }
            enqueueOperationAnnouncement(
                state.kind,
                completion: .succeeded,
                operationID: operationID)
        } else if let completion = phase.announcementCompletion,
            !ingestAnnouncements(from: seed.windowStatuses, operationID: operationID)
        {
            // Pre-writer rejections do not necessarily create a legacy window status. They still
            // need one retryable semantic debt tied to the terminal activity.
            enqueueOperationAnnouncement(
                state.kind,
                completion: completion,
                operationID: operationID)
        }
        trimTerminalOperationHistory()
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
        ingestPresentationTransition(from: lastCommittedModelSeed, to: seed)
        if !seed.library.isFresh {
            // Loading may be the observation refresh that raced with an operation already
            // accepted from the same fresh snapshot. Keep that accepted confirmation consumed,
            // while any still-pending confirmation remains fail-closed.
            clearPendingConfirmation()
        }
        presentationRevision &+= 1
        let preservesPreBusyCapabilities = hasBusyOperation
        actionLedger = actionLedger.filter { _, binding in
            if preservesPreBusyCapabilities {
                return binding.context == context
                    && binding.actionEpoch == actionEpoch
                    && binding.selectionGeneration == seed.selectionGeneration
                    && (binding.intent.allowsSnapshotAdvance
                        || binding.snapshotRevision == seed.snapshotRevision)
            }
            guard let packID = binding.intent.foregroundPreviewPackID else { return false }
            return binding.context == context
                && binding.actionEpoch == actionEpoch
                && binding.selectionGeneration == seed.selectionGeneration
                && seed.installedPackIDs.contains(packID)
                && !seed.builtinPackIDs.contains(packID)
        }
        prunePermits(using: seed)
        if interfaceHasActivated {
            ingestAnnouncements(from: seed.windowStatuses)
        }
        let nextPresentation = SoundPacksEditorPresentation(
            revision: presentationRevision,
            library: seed.library,
            installedPackIDs: seed.installedPackIDs,
            mode: makeMode(from: seed),
            activities: makeActivities(seed: seed),
            pendingConfirmation: makeConfirmation(seed: seed),
            pendingAnnouncement: announcementQueue.first?.announcement)
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
        let packs = seed.packCards.map {
            makePackPresentation(
                card: $0,
                seed: seed,
                signsWriteActions: !hasBusyOperation)
        }
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
                seed.library.isFresh && !$0.isBuiltinReadOnly
                    && $0.availability == .installed && seed.writesAllowed
                    && !hasBusyOperation
            } ?? false
        let writablePackID = selectedIsWritable ? selectedPack?.id : nil
        let selectedNativeTargets = selectedPack.flatMap {
            seed.nativeTargetsByPackID[$0.id]
        }
        let restoreAllFactoryPacksAction =
            seed.library.isFresh && seed.writesAllowed && !hasBusyOperation
                && !seed.builtinPackIDs.isEmpty
            ? makeAction(
                .restoreAllFactory,
                binding: .requestRestoreAllFactory,
                seed: seed)
            : nil
        let emptyLibraryRecovery: SoundPackEditorEmptyLibraryRecoveryPresentation
        if seed.library.isFresh, packs.isEmpty {
            if !seed.builtinPackIDs.isEmpty {
                emptyLibraryRecovery =
                    restoreAllFactoryPacksAction.map {
                        .restoreFactory(action: $0)
                    } ?? .none
            } else {
                emptyLibraryRecovery = .revealRoot(
                    displayValue: userPacksDirectory.path,
                    action: makeAction(
                        .reveal,
                        binding: .reveal(fileURL: userPacksDirectory),
                        seed: seed))
            }
        } else {
            emptyLibraryRecovery = .none
        }
        return SoundsEditorPresentation(
            route: route,
            requestRevision: requestRevision,
            routeState: routeState,
            scope: scopeAvailability(
                seed,
                requestedScope: route.surface.map(PanelSoundScopeID.surface) ?? .global),
            packs: packs,
            selectedPack: selectedPack,
            eventRows: seed.selectedEventRows.map { row in
                let derivedPreviewAvailability = eventPreviewAvailability(
                    coverage: row.coverage,
                    masterVolume: seed.config.masterVolume)
                let previewAvailability: EventPreviewAvailability
                if derivedPreviewAvailability.isAvailable,
                    selectedNativeTargets?.eventAudioURLs[row.event] == nil
                {
                    switch row.coverage {
                    case .present(let fileName), .broken(let fileName):
                        previewAvailability = .missingOrDamaged(fileName: fileName)
                    case .unmapped:
                        previewAvailability = .unmapped
                    }
                } else {
                    previewAvailability = derivedPreviewAvailability
                }
                let previewAction: SoundPackEditorAction?
                if seed.library.isFresh, previewAvailability.isAvailable,
                    let target = selectedNativeTargets?.eventAudioURLs[row.event]
                {
                    previewAction = makeAction(
                        .preview,
                        binding: .preview(fileURL: target),
                        seed: seed)
                } else {
                    previewAction = nil
                }
                return SoundPackEditorEventPresentation(
                    event: row.event,
                    coverage: row.coverage,
                    enabled: row.enabled,
                    audioDisplayName: row.audioDisplayName,
                    previewAvailability: previewAvailability,
                    importAction: selectedIsWritable
                        ? makeAction(
                            .requestImport,
                            binding: .requestImport(
                                packID: selectedPack?.id ?? "",
                                bindTo: row.event),
                            seed: seed)
                        : nil,
                    previewAction: previewAction,
                    clearAction: row.coverage.hasManifestBinding
                        ? writablePackID.map { packID in
                            makeAction(
                                .clear,
                                binding: .clear(packID: packID, event: row.event),
                                seed: seed)
                        } : nil)
            },
            inventory: makeInventory(
                seed: seed,
                writablePackID: writablePackID),
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
            restoreAllFactoryPacksAction: restoreAllFactoryPacksAction,
            emptyLibraryRecovery: emptyLibraryRecovery,
            windowStatuses: seed.windowStatuses,
            recoveryActions: seed.library.isFresh && seed.writesAllowed && !hasBusyOperation
                ? seed.factoryRestoreRetryPackIDs.map { packID in
                    SoundPackEditorRecoveryPresentation(
                        packID: packID,
                        retryAction: makeAction(
                            .retryRestore,
                            binding: .requestRetryRestore(packID: packID),
                            seed: seed))
                } : [])
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
            scope: scopeAvailability(seed, requestedScope: route.scope),
            packs: packs,
            selectedPack: packs.first(where: { $0.id == seed.selectedPackID }),
            adoptionPermit: adoptionPermit,
            retryLibraryAction: seed.library.canRetryEditorLibrary
                ? makeAction(.retryLibrary, binding: .retryLibrary, seed: seed)
                : nil)
    }

    private func scopeAvailability(
        _ seed: SoundPacksEditorModelSeed,
        requestedScope: PanelSoundScopeID
    ) -> SoundPackEditorScopeAvailability {
        guard isValidSoundPacksWindowSurface(seed.managedSurface), seed.writesAllowed else {
            return .unavailable(scope: requestedScope, reason: .scopeUnavailable)
        }
        return .available(seed.managedSurface.map(PanelSoundScopeID.surface) ?? .global)
    }

    private func makePackPresentation(
        card: PackCard,
        seed: SoundPacksEditorModelSeed,
        signsWriteActions: Bool = true
    ) -> SoundPackEditorPackPresentation {
        let isInspected = card.id == seed.selectedPackID
        let isActiveForScope = card.isSelected
        let isReferencedByAnyScope = seed.referencedPackIDs.contains(card.id)
        let isBuiltin = seed.builtinPackIDs.contains(card.id)
        let isAvailable = card.availability == .installed
        let writesAllowed =
            seed.library.isFresh && seed.writesAllowed && isAvailable && signsWriteActions
        let nativeTarget = seed.nativeTargetsByPackID[card.id]
        let isBroken: Bool
        if case .broken = card.state {
            isBroken = true
        } else {
            isBroken = false
        }
        let starControl = soundPacksWindowStarControl(
            packID: card.id,
            rawStarredPackIDs: Array(seed.starredPackIDs),
            isPackBroken: isBroken)
        return SoundPackEditorPackPresentation(
            id: card.id,
            name: card.name,
            state: card.state,
            availability: card.availability,
            isInspected: isInspected,
            isActiveForScope: isActiveForScope,
            isReferencedByAnyScope: isReferencedByAnyScope,
            isStarred: seed.starredPackIDs.contains(card.id),
            isBuiltinReadOnly: isBuiltin,
            isCC0: card.isCC0,
            factoryIntegrity: card.factoryIntegrity,
            inspectAction: makeAction(.inspect, binding: .inspect(packID: card.id), seed: seed),
            useAction: writesAllowed && !isActiveForScope
                ? makeAction(.use, binding: .use(packID: card.id), seed: seed) : nil,
            toggleStarAction: writesAllowed && starControl.isEnabled
                ? makeAction(.toggleStar, binding: .toggleStar(packID: card.id), seed: seed) : nil,
            forkAction: writesAllowed && isBuiltin && isInspected
                ? makeAction(.fork, binding: .fork(packID: card.id), seed: seed) : nil,
            deleteAction: writesAllowed && !isBuiltin && isInspected && !isReferencedByAnyScope
                ? makeAction(.deletePack, binding: .requestDeletePack(packID: card.id), seed: seed)
                : nil,
            restoreAction: writesAllowed && isBuiltin && isInspected
                ? makeAction(
                    .restoreFactory,
                    binding: .requestRestoreFactory(packID: card.id),
                    seed: seed)
                : nil,
            revealAction: seed.library.isFresh && isAvailable
                ? nativeTarget.map {
                    makeAction(
                        .reveal,
                        binding: .reveal(fileURL: $0.directoryURL),
                        seed: seed)
                } : nil,
            revealDisplayValue: seed.library.isFresh && isAvailable
                ? nativeTarget?.directoryURL.path : nil)
    }

    private func makeInventory(
        seed: SoundPacksEditorModelSeed,
        writablePackID: String?
    ) -> SoundPackEditorInventoryPresentation {
        let canTargetInventory = seed.library.isFresh
        func rows(_ files: [PackAudioFile]) -> [SoundPackEditorAudioPresentation] {
            files.map { file in
                let assignments: [SoundPackEditorAssignmentPresentation]
                let deleteAction: SoundPackEditorAction?
                if canTargetInventory, let writablePackID {
                    assignments = Event.allCases.map { event in
                        SoundPackEditorAssignmentPresentation(
                            event: event,
                            action: makeAction(
                                .assign,
                                binding: .assign(
                                    packID: writablePackID,
                                    fileName: file.fileName,
                                    event: event),
                                seed: seed))
                    }
                    deleteAction =
                        file.isOrphan
                        ? makeAction(
                            .deleteOrphan,
                            binding: .requestDeleteOrphan(fileName: file.fileName),
                            seed: seed)
                        : nil
                } else {
                    assignments = []
                    deleteAction = nil
                }
                return SoundPackEditorAudioPresentation(
                    fileName: file.fileName,
                    isOrphan: file.isOrphan,
                    assignments: assignments,
                    deleteAction: deleteAction,
                    revealAction: canTargetInventory
                        ? file.nativeTargetURL.map {
                            makeAction(
                                .reveal,
                                binding: .reveal(fileURL: $0),
                                seed: seed)
                        } : nil)
            }
        }
        switch seed.selectedAudioInventoryState {
        case .idle:
            return .idle
        case .loading(let previous):
            return .loading(previous: previous.map(rows))
        case .ready(let files):
            return .ready(rows(files))
        case .failed(let previous, let error):
            let reason: SoundPackEditorInventoryFailureReason
            switch error {
            case .packNotFound:
                reason = .packUnavailable
            case .manifestUnreadable:
                reason = .manifestUnreadable
            case .directoryUnreadable:
                reason = .directoryUnavailable
            }
            return .failed(previous: previous.map(rows), reason: reason)
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
        let confirmAction = makeAction(
            .confirm,
            binding: .confirm(pendingConfirmationState.id),
            seed: seed)
        confirmationAttemptLedger[confirmAction.id] = pendingConfirmationState.id
        return SoundPackEditorConfirmation(
            id: pendingConfirmationState.id,
            kind: pendingConfirmationState.kind,
            packID: pendingConfirmationState.packID,
            fileName: pendingConfirmationState.fileName,
            confirmAction: confirmAction,
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
        guard seed.library.isFresh else {
            importPermitLedger.removeAll(keepingCapacity: true)
            adoptionPermitLedger.removeAll(keepingCapacity: true)
            return
        }
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

    @discardableResult
    private func ingestAnnouncements(
        from statuses: [SoundPacksWindowStatus],
        operationID: SoundPackEditorOperationID? = nil
    ) -> Bool {
        var inserted = false
        for status in statuses.sorted(by: { $0.revision < $1.revision }) {
            guard seenStatusRevisions.insert(status.revision).inserted else { continue }
            inserted = true
            enqueueAnnouncement(
                kind: .windowStatus(status.kind),
                actionText: status.actionText,
                messageText: status.messageText,
                operationID: operationID,
                priority: status.severity == .failure ? .failure : .notice)
        }
        return inserted
    }

    private func enqueueOperationAnnouncement(
        _ kind: SoundPackEditorActivityKind,
        completion: SoundPackEditorOperationCompletion,
        operationID: SoundPackEditorOperationID
    ) {
        enqueueAnnouncement(
            kind: .operation(kind: kind, completion: completion),
            actionText: nil,
            messageText: nil,
            operationID: operationID,
            priority: completion.announcementPriority)
    }

    private func ingestPresentationTransition(
        from previous: SoundPacksEditorModelSeed?,
        to seed: SoundPacksEditorModelSeed
    ) {
        guard context.isSounds, let previous else { return }
        if previous.announcementLibraryState != seed.announcementLibraryState {
            let suppressesThisObservation: Bool
            if suppressesNextForkLibraryObservationCycle {
                switch seed.announcementLibraryState {
                case .loading, .refreshing:
                    suppressesThisObservation = true
                case .ready:
                    suppressesNextForkLibraryObservationCycle = false
                    suppressesThisObservation = true
                case .loadFailed, .refreshFailed:
                    // A scan failure is not equivalent to the successful fork receipt and must
                    // still preempt notices with its own failure announcement.
                    suppressesNextForkLibraryObservationCycle = false
                    suppressesThisObservation = false
                }
            } else {
                suppressesThisObservation = false
            }
            if !suppressesThisObservation {
                enqueueSemanticAnnouncement(
                    .libraryStateChanged(announcementFacts(from: seed)),
                    priority: announcementPriority(for: seed.announcementLibraryState))
            }
        }
        guard previous.selectedPackID != seed.selectedPackID,
            shouldAnnounceSelectionChange(to: seed.selectedPackID)
        else { return }
        enqueueSemanticAnnouncement(
            .selectionChanged(announcementFacts(from: seed)),
            priority: .notice)
    }

    private func announcementFacts(
        from seed: SoundPacksEditorModelSeed
    ) -> SoundPacksWindowAnnouncementFacts {
        let selectedName = seed.selectedPackID.flatMap { packID in
            seed.packCards.first(where: { $0.id == packID }).map {
                SelectedPackMetadata(id: $0.id, name: $0.name).displayName
            }
        }
        return SoundPacksWindowAnnouncementFacts(
            packCount: seed.packCards.count,
            selectedPackName: selectedName,
            libraryPresentationState: seed.announcementLibraryState)
    }

    private func announcementPriority(
        for state: SoundPackLibraryPresentationState
    ) -> SoundPackEditorAnnouncementPriority {
        switch state {
        case .loadFailed, .refreshFailed:
            return .failure
        case .loading, .refreshing, .ready:
            return .notice
        }
    }

    private func enqueueSemanticAnnouncement(
        _ kind: SoundPackEditorAnnouncementKind,
        priority: SoundPackEditorAnnouncementPriority
    ) {
        enqueueAnnouncement(
            kind: kind,
            actionText: nil,
            messageText: nil,
            operationID: nil,
            priority: priority)
    }

    private func enqueueAnnouncement(
        kind: SoundPackEditorAnnouncementKind,
        actionText: SoundPacksWindowStatusText?,
        messageText: SoundPacksWindowStatusText?,
        operationID: SoundPackEditorOperationID?,
        priority: SoundPackEditorAnnouncementPriority
    ) {
        nextCapabilityID &+= 1
        let debt = EditorAnnouncementDebt(
            announcement: SoundPackEditorAnnouncement(
                id: SoundPackEditorAnnouncement.ID(rawValue: nextCapabilityID),
                kind: kind,
                priority: priority,
                actionText: actionText,
                messageText: messageText),
            operationID: operationID,
            priority: priority)
        let insertionIndex =
            announcementQueue.firstIndex {
                $0.priority.rawValue > priority.rawValue
            } ?? announcementQueue.endIndex
        announcementQueue.insert(debt, at: insertionIndex)
    }

    private func retireTerminalOperation(_ operationID: SoundPackEditorOperationID) {
        guard let state = operationStates[operationID], state.phase != .busy else { return }
        operationStates.removeValue(forKey: operationID)
        operationOrder.removeAll { $0 == operationID }
        operationTasks.removeValue(forKey: operationID)
        operationCancellations.removeValue(forKey: operationID)
    }

    private func trimTerminalOperationHistory() {
        let terminalIDs = operationOrder.filter { operationID in
            operationStates[operationID]?.phase != .busy
        }
        guard terminalIDs.count > Self.maximumRetainedTerminalOperationCount else { return }
        // Announcement debt remains FIFO and unbounded by this presentation-history safeguard.
        // A later successful acknowledgement still consumes its semantic fact even if the visual
        // activity aged out before it reached the queue head.
        for operationID in terminalIDs.prefix(
            terminalIDs.count - Self.maximumRetainedTerminalOperationCount)
        {
            retireTerminalOperation(operationID)
        }
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

    private func makeForegroundPreviewAction(
        _ imported: ImportedAudioFile,
        seed: SoundPacksEditorModelSeed
    ) -> SoundPackEditorAction {
        makeAction(
            .preview,
            binding: .previewForegroundImport(
                fileURL: imported.destinationURL,
                packID: imported.packID),
            seed: seed)
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

    #if DEBUG
    /// Joins the task already owned by this editor without scheduling work or changing state.
    package func waitForScheduledOperationExitForTesting(
        _ operationID: SoundPackEditorOperationID
    ) async {
        guard let task = operationTasks[operationID] else { return }
        await task.value
    }

    /// Joins every scheduled writer, the shared-library mutation fence/scan, and the model's
    /// terminal observation. This is a test-only synchronization seam, not another state owner.
    package func waitForMutationTransactionsToQuiesceForTesting() async {
        while !operationTasks.isEmpty {
            let tasks = Array(operationTasks.values)
            for task in tasks { await task.value }
        }
        await model.waitForMutationTransactionsToQuiesceForTesting()
    }
    #endif

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

private struct EditorImportMutationFreshness {
    let snapshotRevision: UInt64?
    let eventBinding: ManifestEventBindingExpectation?
}

private struct EditorAdoptionMutationFreshness {
    let snapshotRevision: UInt64?
    let eventBinding: ManifestEventBindingExpectation
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

private struct EditorAnnouncementDebt {
    let announcement: SoundPackEditorAnnouncement
    let operationID: SoundPackEditorOperationID?
    let priority: SoundPackEditorAnnouncementPriority
}

extension SoundPackEditorActivityPhase {
    fileprivate var announcementCompletion: SoundPackEditorOperationCompletion? {
        switch self {
        case .busy:
            return nil
        case .succeeded:
            return .succeeded
        case .failed(let failure):
            return .failed(failure)
        case .partial(let accepted, let rejected):
            return .partial(accepted: accepted, rejected: rejected)
        case .orphan(_, let failure):
            return .orphan(failure)
        case .cancelled(let changedOnDisk):
            return .cancelled(changedOnDisk: changedOnDisk)
        }
    }
}

extension SoundPackEditorOperationCompletion {
    fileprivate var announcementPriority: SoundPackEditorAnnouncementPriority {
        switch self {
        case .failed, .orphan:
            return .failure
        case .unchanged, .succeeded, .partial, .cancelled:
            return .notice
        }
    }
}

extension SoundPacksEditorContext {
    fileprivate var isSounds: Bool {
        if case .sounds = self { return true }
        return false
    }
}

/// The editor keeps each writer's typed result intact until it projects the terminal activity.
/// Disk impact and refresh policy remain owned by the existing model writer's
/// `SoundPacksWindowWriteOutcome`; duplicating those facts here would create a second policy seam.
private enum EditorMutationReceipt {
    case rejected(SoundPackEditorFailure)
    case use(Result<UseOutcome, SoundPacksWindowPackUseActionError>)
    case assign(packID: String, result: Result<Void, SoundPacksWindowAudioActionError>)
    case clear(packID: String, result: Result<Void, SoundPacksWindowAudioActionError>)
    case fork(Result<PackForkOutcome, SoundPacksWindowPackForkActionError>)
    case deletePack(
        packID: String,
        result: Result<UserSoundPackDeletionOutcome, SoundPacksWindowPackDeletionActionError>)
    case deleteOrphan(packID: String, result: Result<Void, SoundPacksWindowAudioActionError>)
    case restoreFactory(
        packID: String,
        result: Result<FactoryPackRestoreOutcome, SoundPacksWindowFactoryRestoreActionError>)
    case retryRestore(
        packID: String,
        result: Result<FactoryPackRestoreOutcome, SoundPacksWindowFactoryRestoreActionError>)
    case restoreAllFactory(FactoryPackBatchRestoreOutcome)

    var phase: SoundPackEditorActivityPhase {
        switch self {
        case .rejected(let failure):
            return .failed(failure)
        case .use(let result):
            return result.isSuccess ? .succeeded : .failed(.mutationFailed)
        case .assign(_, let result), .clear(_, let result), .deleteOrphan(_, let result):
            return result.isSuccess ? .succeeded : .failed(.mutationFailed)
        case .fork(let result):
            return result.isSuccess ? .succeeded : .failed(.mutationFailed)
        case .deletePack(_, let result):
            return result.isSuccess ? .succeeded : .failed(.mutationFailed)
        case .restoreFactory(_, let result), .retryRestore(_, let result):
            return result.isSuccess ? .succeeded : .failed(.mutationFailed)
        case .restoreAllFactory(let outcome):
            if outcome.failures.isEmpty { return .succeeded }
            if !outcome.restoredPacks.isEmpty {
                return .partial(
                    accepted: outcome.restoredPacks.count,
                    rejected: outcome.failures.count)
            }
            return .failed(.mutationFailed)
        }
    }
}

private enum EditorScheduledWork {
    case use(packID: String)
    case assign(packID: String, fileName: String, event: Event)
    case clear(packID: String, event: Event)
    case fork(packID: String)
    case deletePack(packID: String)
    case deleteOrphan(packID: String, fileName: String)
    case restoreFactory(packID: String)
    case retryRestore(packID: String)
    case restoreAllFactory

    var activityKind: SoundPackEditorActivityKind {
        switch self {
        case .use: .use
        case .assign: .assign
        case .clear: .clear
        case .fork: .fork
        case .deletePack: .deletePack
        case .deleteOrphan: .deleteOrphan
        case .restoreFactory, .retryRestore: .restoreFactory
        case .restoreAllFactory: .restoreAllFactory
        }
    }

    var event: Event? {
        switch self {
        case .assign(_, _, let event), .clear(_, let event): event
        case .use, .fork, .deletePack, .deleteOrphan, .restoreFactory, .retryRestore,
            .restoreAllFactory:
            nil
        }
    }

}

private enum EditorImportSource {
    case picker
    case drop
}

private enum EditorActionIntent {
    case inspect(packID: String)
    case use(packID: String)
    case toggleStar(packID: String)
    case fork(packID: String)
    case requestImport(packID: String, bindTo: Event?)
    case assign(packID: String, fileName: String, event: Event)
    case clear(packID: String, event: Event)
    case preview(fileURL: URL)
    case previewForegroundImport(fileURL: URL, packID: String)
    case stopPreview
    case reveal(fileURL: URL)
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

extension EditorActionIntent {
    fileprivate var foregroundPreviewPackID: String? {
        if case .previewForegroundImport(_, let packID) = self { return packID }
        return nil
    }

    fileprivate var allowsNonFreshLibrary: Bool {
        foregroundPreviewPackID != nil
    }

    fileprivate var allowsSnapshotAdvance: Bool {
        foregroundPreviewPackID != nil
    }
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

    fileprivate var requiresFreshLibrary: Bool {
        switch self {
        case .use, .toggleStar, .fork, .requestImport, .assign, .clear, .preview, .reveal,
            .deletePack, .deleteOrphan, .restoreFactory, .retryRestore, .restoreAllFactory,
            .confirm:
            true
        case .inspect, .stopPreview, .retryLibrary, .cancelOperation, .cancelConfirmation:
            false
        }
    }
}

extension CoverageState {
    fileprivate var hasManifestBinding: Bool {
        switch self {
        case .present, .broken:
            true
        case .unmapped:
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
