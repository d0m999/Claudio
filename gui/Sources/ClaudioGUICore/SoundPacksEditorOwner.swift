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
    private var context: SoundPacksEditorContext = .inactive
    private var presentationRevision: UInt64 = 0
    private var nextCapabilityID: UInt64 = 0
    private var actionLedger: [SoundPackEditorAction.ID: EditorActionBinding] = [:]
    private var importPermitLedger: [SoundPackImportPermit.ID: EditorPermitBinding] = [:]
    private var adoptionPermitLedger: [SoundPackAdoptionPermit.ID: EditorAdoptionBinding] = [:]
    private var isApplyingModelTransition = false
    private var deferredModelSeed: SoundPacksEditorModelSeed?
    private var statusAnnouncementTracker = SoundPacksWindowStatusAnnouncementTracker()
    private var lastSelectionAnnouncementDecision: (packID: String?, shouldAnnounce: Bool)?

    public init(
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
        self.model = model
        self.userPacksDirectory = environment.userPacksDirectory
        self.refreshCoordinator = refreshCoordinator
        presentation = Self.initialPresentation(from: model.editorProjectionSeed())
        connectSettledModel(model)
    }

    #if DEBUG
    /// Deterministic route-test seam that uses the harness's synchronous disk-backed model.
    public init(
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
        self.model = model
        self.userPacksDirectory = environment.userPacksDirectory
        self.refreshCoordinator = refreshCoordinator
        presentation = Self.initialPresentation(from: model.editorProjectionSeed())
        connectSettledModel(model)
    }

    /// Deterministic pending/ready route seam for model fixtures that do not touch user disk.
    public init(model: SoundPacksWindowModel, userPacksDirectory: URL) {
        self.model = model
        self.userPacksDirectory = userPacksDirectory
        refreshCoordinator = nil
        presentation = Self.initialPresentation(from: model.editorProjectionSeed())
        connectSettledModel(model)
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
        model.onEditorStateSettled = { [weak self] seed in
            self?.receiveSettledModel(seed)
        }
    }

    private func receiveSettledModel(_ seed: SoundPacksEditorModelSeed) {
        if isApplyingModelTransition {
            deferredModelSeed = seed
            return
        }
        publish(from: seed)
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
            case .events(let route, _):
                withModelTransition {
                    model.setManagedSurface(route.surface)
                }
            }
            return .applied
        case .invoke(let action):
            guard actionLedger.removeValue(forKey: action.id) != nil else {
                return .rejected(.staleAction)
            }
            publish(from: model.editorProjectionSeed())
            return .rejected(.actionUnavailable)
        case .completePanelPackSwitch(let outcome):
            completePanelPackSwitch(outcome)
            return outcome.refreshesEditor ? .applied : .unchanged
        case .acknowledgeAnnouncement:
            return .unchanged
        }
    }

    private func publish(from seed: SoundPacksEditorModelSeed) {
        presentationRevision &+= 1
        actionLedger.removeAll(keepingCapacity: true)
        importPermitLedger.removeAll(keepingCapacity: true)
        adoptionPermitLedger.removeAll(keepingCapacity: true)
        presentation = SoundPacksEditorPresentation(
            revision: presentationRevision,
            library: seed.library,
            mode: makeMode(from: seed),
            activities: [],
            pendingConfirmation: nil,
            pendingAnnouncement: nil)
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
        case .events(let route, let requestRevision):
            return .events(
                makeEventsPresentation(
                    route: route,
                    requestRevision: requestRevision,
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
                    previewAction: row.coverage.previewEnabled
                        ? makeAction(.preview, binding: .preview(event: row.event), seed: seed)
                        : nil,
                    clearAction: selectedIsWritable && row.coverage.previewEnabled
                        ? makeAction(.clear, binding: .clear(event: row.event), seed: seed)
                        : nil)
            },
            inventory: makeInventory(seed: seed, isWritable: selectedIsWritable),
            requestImportAction: selectedIsWritable
                ? makeAction(.requestImport, binding: .requestImport(bindTo: nil), seed: seed)
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
                : nil)
    }

    private func makeEventsPresentation(
        route: EventSettingsWindowRoute,
        requestRevision: UInt64,
        seed: SoundPacksEditorModelSeed
    ) -> EventsSoundPackPresentation {
        let packs = seed.packCards.map { makePackPresentation(card: $0, seed: seed) }
        var adoptionPermit: SoundPackAdoptionPermit?
        if let event = route.event,
            case .eligible(let target) = model.aiCueAdoptionEligibility(for: event)
        {
            adoptionPermit = makeAdoptionPermit(target: target, seed: seed)
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
            forkAction: writesAllowed && isBuiltin
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
            selectionGeneration: seed.selectionGeneration,
            snapshotRevision: seed.snapshotRevision)
        return action
    }

    private func makeAdoptionPermit(
        target: AICueAdoptionTarget,
        seed: SoundPacksEditorModelSeed
    ) -> SoundPackAdoptionPermit {
        nextCapabilityID &+= 1
        let permit = SoundPackAdoptionPermit(id: nextCapabilityID)
        adoptionPermitLedger[permit.id] = EditorAdoptionBinding(
            target: target,
            context: context,
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
    let selectionGeneration: UInt64
    let snapshotRevision: UInt64?
}

private struct EditorPermitBinding {
    let packID: String
    let bindTo: Event?
    let context: SoundPacksEditorContext
    let selectionGeneration: UInt64
    let snapshotRevision: UInt64?
}

private struct EditorAdoptionBinding {
    let target: AICueAdoptionTarget
    let context: SoundPacksEditorContext
    let selectionGeneration: UInt64
    let snapshotRevision: UInt64?
}

private enum EditorActionIntent {
    case inspect(packID: String)
    case use(packID: String)
    case toggleStar(packID: String)
    case fork(packID: String)
    case requestImport(bindTo: Event?)
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
