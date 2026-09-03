import Combine
import ClaudioCore
import Foundation

public enum AICueComposerPhase: Sendable, Equatable {
    case editing
    case generating
    case candidatesReady
    case adopting
    case applied
}

public enum AICueCredentialActivity: Sendable, Equatable {
    case idle
    case probing
    case saving
    case pendingReplacement
    case deleting
}

public enum AICueCredentialFailure: Sendable, Equatable {
    case provider(AICueProviderError)
    case storageUnavailable
}

public enum AICueComposerFailure: Sendable, Equatable {
    case generation(AICueGenerationError)
    case displayName(AICueValidationError)
    case adoption(AICueComposerAdoptionFailure)
}

public enum AICueComposerAdoptionFailure: Sendable, Equatable {
    case targetChanged
    case rejected
    case importedButNotBound(fileName: String)
}

public struct AICueComposerSession: Sendable, Equatable {
    public let scope: PanelSoundScopeID
    public let event: Event

    public init(scope: PanelSoundScopeID, event: Event) {
        self.scope = scope
        self.event = event
    }
}

public struct AICueComposerAdoptionOutcome: Sendable, Equatable {
    public let finalDisplayName: String

    public init(finalDisplayName: String) {
        self.finalDisplayName = finalDisplayName
    }
}

/// Main-actor state machine for the visible two-step flow. It owns no secret value and knows no
/// provider endpoint. Credential plaintext crosses this object only as a one-shot opaque input to
/// the credential manager, while generation and adoption remain injectable deep operations.
@MainActor
public final class AICueGenerationViewModel: ObservableObject {
    @Published public private(set) var credentialStatus: AICueCredentialStatus?
    @Published public private(set) var credentialActivity: AICueCredentialActivity = .idle
    @Published public private(set) var credentialFailure: AICueCredentialFailure?
    @Published public private(set) var providerProfileID: AICueProviderProfileID
    @Published public private(set) var phase: AICueComposerPhase = .editing
    @Published public private(set) var adoptingCandidateID: UUID?
    @Published public private(set) var soundDescription = ""
    @Published public private(set) var displayName = ""
    @Published public private(set) var session: AICueComposerSession?
    @Published public private(set) var generation: AICueGeneration?
    @Published public private(set) var failure: AICueComposerFailure?
    @Published public private(set) var adoptionOutcome: AICueComposerAdoptionOutcome?

    private let credentialManager: any AICueCredentialManaging
    private let generator: any AICueGenerating
    private let registry: AICueProviderRegistry
    private let providerPreferences: AICueProviderPreferences
    private var sessionRevision: UInt64 = 0
    private var credentialStatusRevision: UInt64 = 0
    private var generationTask: Task<Void, Never>?
    private var adoptionTask: Task<Void, Never>?

    public init(
        credentialManager: any AICueCredentialManaging,
        generator: any AICueGenerating,
        providerProfileID: AICueProviderProfileID? = nil,
        registry: AICueProviderRegistry = AICueProviderRegistry(),
        providerPreferences: AICueProviderPreferences = AICueProviderPreferences()
    ) {
        self.credentialManager = credentialManager
        self.generator = generator
        self.registry = registry
        self.providerPreferences = providerPreferences
        let preferredProfileID = providerProfileID ?? providerPreferences.selectedProfileID()
        self.providerProfileID =
            (try? registry.profile(for: preferredProfileID).id)
            ?? providerPreferences.selectedProfileID()
    }

    #if DEBUG
    /// Deterministic, side-effect-free state injection for the repository visual/AX gallery.
    /// Production continues to reach these states only through the credential, generation and
    /// adoption operations above; this initializer supplies no alternate production transition.
    public convenience init(previewState: AICueGenerationPreviewState) {
        self.init(
            credentialManager: AICuePreviewCredentialManager(
                status: previewState.credentialStatus ?? .missing),
            generator: AICuePreviewGenerator(),
            providerProfileID: previewState.providerProfileID,
            providerPreferences: AICueProviderPreferences(defaults: UserDefaults()))
        credentialStatus = previewState.credentialStatus
        credentialActivity = previewState.credentialActivity
        credentialFailure = previewState.credentialFailure
        phase = previewState.phase
        adoptingCandidateID = previewState.adoptingCandidateID
        soundDescription = previewState.soundDescription
        displayName = previewState.displayName
        session = previewState.session
        generation = previewState.generation
        failure = previewState.failure
        adoptionOutcome = previewState.adoptionOutcome
    }
    #endif

    public var providerProfile: AICueProviderProfile {
        guard let profile = try? registry.profile(for: providerProfileID) else {
            preconditionFailure("Selected provider profile did not come from the registry")
        }
        return profile
    }

    public var availableProviderProfiles: [AICueProviderProfile] {
        registry.profiles()
    }

    public var requiresCredentialConfiguration: Bool {
        if credentialStatus == .missing { return true }
        guard case .generation(let error) = failure else { return false }
        return error == .credentialRequired
    }

    public var isBusy: Bool {
        phase == .generating || phase == .adopting || credentialActivity != .idle
    }

    /// Opens one event-scoped composer. The owner remains solely responsible for resolving the
    /// current pack and signing a permit; this UI state stores only navigation identity.
    public func begin(scope: PanelSoundScopeID, event: Event) {
        let session = AICueComposerSession(scope: scope, event: event)
        guard self.session != session else { return }
        resetComposer(clearSession: true)
        self.session = session
    }

    public func updateDescription(_ value: String) {
        guard phase != .adopting, value != soundDescription else { return }
        soundDescription = value
        guard phase != .editing || generation != nil || adoptionOutcome != nil else {
            failure = nil
            return
        }
        invalidateVisibleGeneration()
    }

    /// Naming is local adoption metadata. It intentionally does not touch generation identity or
    /// launch a task, so a user can refine the final name while repeatedly previewing A/B/C.
    public func updateDisplayName(_ value: String) {
        guard phase != .adopting else { return }
        displayName = value
        if case .displayName = failure { failure = nil }
    }

    public func returnToDescription() {
        guard phase != .adopting else { return }
        invalidateVisibleGeneration()
    }

    public func reportCandidateUnavailable() {
        guard phase == .candidatesReady else { return }
        invalidateVisibleGeneration()
        failure = .generation(.temporaryStorageUnavailable)
    }

    public func refreshCredentialStatus() async {
        guard credentialActivity == .idle else { return }
        let profileID = providerProfileID
        credentialStatusRevision &+= 1
        let revision = credentialStatusRevision
        let status = await credentialManager.status(for: profileID)
        guard
            providerProfileID == profileID,
            credentialStatusRevision == revision
        else { return }
        credentialStatus = status
    }

    /// A profile switch is an explicit region/provider choice. It persists only the allowlisted ID,
    /// cancels the old generation and invalidates every unadopted candidate without touching an
    /// already adopted sound.
    public func selectProviderProfile(_ profileID: AICueProviderProfileID) throws {
        guard
            profileID != providerProfileID,
            credentialActivity == .idle,
            phase != .adopting
        else { return }
        _ = try registry.profile(for: profileID)
        try providerPreferences.select(profileID)
        credentialStatusRevision &+= 1
        invalidateVisibleGeneration()
        providerProfileID = profileID
        credentialStatus = nil
        credentialFailure = nil
    }

    /// Saving is never coupled to generation. A successful save clears only a credential-required
    /// message; the description and explicit second click remain intact.
    public func saveCredential(_ credential: SensitiveCredentialInput) async {
        guard credentialActivity == .idle else { return }
        credentialStatusRevision &+= 1
        let profile = try? registry.profile(for: providerProfileID)
        switch (profile?.credentialValidationPolicy, credentialStatus) {
        case (.readOnlyProbe, _): credentialActivity = .probing
        case (.deferredUntilExplicitGeneration, .stored):
            credentialActivity = .pendingReplacement
        default: credentialActivity = .saving
        }
        credentialFailure = nil
        defer { credentialActivity = .idle }
        do {
            credentialStatus = try await credentialManager.save(
                credential,
                for: providerProfileID)
            switch failure {
            case .generation(.credentialRequired), .generation(.credentialUnavailable):
                failure = nil
            default:
                break
            }
        } catch let error as AICueProviderError {
            credentialStatus = await credentialManager.status(for: providerProfileID)
            credentialFailure = .provider(error)
        } catch {
            credentialStatus = await credentialManager.status(for: providerProfileID)
            credentialFailure = .storageUnavailable
        }
    }

    public func deleteCredential() async {
        guard credentialActivity == .idle, phase != .generating, phase != .adopting else {
            return
        }
        credentialStatusRevision &+= 1
        credentialActivity = .deleting
        credentialFailure = nil
        defer { credentialActivity = .idle }
        do {
            try await credentialManager.delete(for: providerProfileID)
            credentialStatus = .missing
        } catch {
            credentialStatus = await credentialManager.status(for: providerProfileID)
            credentialFailure = .storageUnavailable
        }
    }

    public func cancelPendingCredentialReplacement() async {
        guard credentialActivity == .idle else { return }
        credentialStatusRevision &+= 1
        credentialActivity = .pendingReplacement
        credentialFailure = nil
        defer { credentialActivity = .idle }
        do {
            try await credentialManager.cancelPendingReplacement(for: providerProfileID)
            credentialStatus = await credentialManager.status(for: providerProfileID)
        } catch {
            credentialStatus = await credentialManager.status(for: providerProfileID)
            credentialFailure = .storageUnavailable
        }
    }

    public func startGeneration(locale: String) {
        guard session != nil, phase != .generating, phase != .adopting else { return }
        let deadline = AICueGenerationDeadline.startingNow()

        generationTask?.cancel()
        if let previous = generation {
            discard(previous)
        }
        generation = nil
        adoptionOutcome = nil
        adoptingCandidateID = nil
        displayName = ""
        failure = nil
        phase = .generating
        sessionRevision &+= 1
        let revision = sessionRevision
        let description = soundDescription
        let generator = self.generator
        let providerProfileID = self.providerProfileID

        generationTask = Task { [weak self] in
            let result: Result<AICueGeneration, AICueGenerationError>
            do {
                result = .success(
                    try await generator.generate(
                        description: description,
                        locale: locale,
                        providerProfileID: providerProfileID,
                        deadline: deadline))
            } catch let error as AICueGenerationError {
                result = .failure(error)
            } catch is CancellationError {
                result = .failure(.cancelled)
            } catch {
                result = .failure(.provider(.transportFailure))
            }

            guard let self else {
                if case .success(let generation) = result {
                    await generator.discard(generationID: generation.id)
                }
                return
            }
            guard self.sessionRevision == revision, !Task.isCancelled else {
                if case .success(let generation) = result {
                    await generator.discard(generationID: generation.id)
                }
                return
            }
            self.generationTask = nil
            switch result {
            case .success(let generation):
                self.generation = generation
                self.displayName = generation.plan.suggestedDisplayName
                self.phase = .candidatesReady
                await self.refreshCredentialStatus()
            case .failure(let error):
                if error == .credentialRequired {
                    self.credentialStatus = .missing
                } else if error == .credentialUnavailable {
                    self.credentialStatus = .unavailable
                }
                self.phase = .editing
                self.failure = .generation(error)
                await self.refreshCredentialStatus()
            }
        }
    }

    package func adopt(
        candidateID: UUID,
        permit: SoundPackAdoptionPermit,
        using operation:
            @escaping @MainActor (
                AICueCandidate,
                AICueDisplayName,
                SoundPackAdoptionPermit
            ) async -> SoundPacksEditorOperationResult
    ) {
        guard
            phase == .candidatesReady,
            let generation,
            let candidate = generation.candidates.first(where: { $0.id == candidateID }),
            session != nil
        else { return }

        let name: AICueDisplayName
        do {
            name = try AICueDisplayName(displayName)
        } catch let error as AICueValidationError {
            failure = .displayName(error)
            return
        } catch {
            failure = .displayName(.emptyDisplayName)
            return
        }

        failure = nil
        phase = .adopting
        adoptingCandidateID = candidateID
        let revision = sessionRevision
        let generator = self.generator
        adoptionTask = Task { [weak self] in
            let result = await operation(candidate, name, permit)
            guard let self else {
                await generator.discard(generationID: generation.id)
                return
            }
            guard self.sessionRevision == revision else {
                await generator.discard(generationID: generation.id)
                return
            }
            self.adoptionTask = nil
            self.adoptingCandidateID = nil
            switch result {
            case .adopted(let outcome):
                await generator.discard(generationID: generation.id)
                guard self.sessionRevision == revision else { return }
                self.generation = nil
                self.adoptionOutcome = AICueComposerAdoptionOutcome(
                    finalDisplayName: outcome.finalDisplayName)
                self.phase = .applied
            case .adoptionOrphan(let imported, _):
                self.phase = .candidatesReady
                self.failure = .adoption(
                    .importedButNotBound(fileName: imported.fileName))
            case .rejected(let failure):
                self.phase = .candidatesReady
                self.failure = .adoption(
                    failure == .targetChanged ? .targetChanged : .rejected)
            case .imported:
                self.phase = .candidatesReady
                self.failure = .adoption(.rejected)
            }
        }
    }

    public func endSession() {
        resetComposer(clearSession: true)
    }

    public func dismissFailure() {
        failure = nil
        credentialFailure = nil
    }

    private func invalidateVisibleGeneration() {
        generationTask?.cancel()
        generationTask = nil
        sessionRevision &+= 1
        if let generation {
            discard(generation)
        }
        generation = nil
        adoptionOutcome = nil
        adoptingCandidateID = nil
        displayName = ""
        failure = nil
        phase = .editing
    }

    private func resetComposer(clearSession: Bool) {
        let adoptionWasRunning = phase == .adopting
        generationTask?.cancel()
        generationTask = nil
        sessionRevision &+= 1
        if !adoptionWasRunning, let generation {
            discard(generation)
        }
        generation = nil
        adoptionOutcome = nil
        adoptingCandidateID = nil
        soundDescription = ""
        displayName = ""
        failure = nil
        phase = .editing
        if clearSession { session = nil }
    }

    private func discard(_ generation: AICueGeneration) {
        let generator = self.generator
        Task {
            await generator.discard(generationID: generation.id)
        }
    }
}

#if DEBUG
/// A complete render-state snapshot used only by ``PreviewFixtures`` and the DEBUG gallery.
public struct AICueGenerationPreviewState: Sendable, Equatable {
    public let providerProfileID: AICueProviderProfileID
    public let credentialStatus: AICueCredentialStatus?
    public let credentialActivity: AICueCredentialActivity
    public let credentialFailure: AICueCredentialFailure?
    public let phase: AICueComposerPhase
    public let adoptingCandidateID: UUID?
    public let soundDescription: String
    public let displayName: String
    public let session: AICueComposerSession?
    public let generation: AICueGeneration?
    public let failure: AICueComposerFailure?
    public let adoptionOutcome: AICueComposerAdoptionOutcome?

    public init(
        providerProfileID: AICueProviderProfileID,
        credentialStatus: AICueCredentialStatus?,
        credentialActivity: AICueCredentialActivity = .idle,
        credentialFailure: AICueCredentialFailure? = nil,
        phase: AICueComposerPhase = .editing,
        adoptingCandidateID: UUID? = nil,
        soundDescription: String = "",
        displayName: String = "",
        session: AICueComposerSession? = nil,
        generation: AICueGeneration? = nil,
        failure: AICueComposerFailure? = nil,
        adoptionOutcome: AICueComposerAdoptionOutcome? = nil
    ) {
        self.providerProfileID = providerProfileID
        self.credentialStatus = credentialStatus
        self.credentialActivity = credentialActivity
        self.credentialFailure = credentialFailure
        self.phase = phase
        self.adoptingCandidateID = adoptingCandidateID
        self.soundDescription = soundDescription
        self.displayName = displayName
        self.session = session
        self.generation = generation
        self.failure = failure
        self.adoptionOutcome = adoptionOutcome
    }
}

private actor AICuePreviewCredentialManager: AICueCredentialManaging {
    let projectedStatus: AICueCredentialStatus

    init(status: AICueCredentialStatus) {
        projectedStatus = status
    }

    func status(for profileID: AICueProviderProfileID) -> AICueCredentialStatus {
        projectedStatus
    }

    func save(
        _ credential: SensitiveCredentialInput,
        for profileID: AICueProviderProfileID
    ) async throws -> AICueCredentialStatus {
        projectedStatus
    }

    func delete(for profileID: AICueProviderProfileID) async throws {}
    func cancelPendingReplacement(for profileID: AICueProviderProfileID) async throws {}
}

private actor AICuePreviewGenerator: AICueGenerating {
    func generate(
        description: String,
        locale: String,
        providerProfileID: AICueProviderProfileID,
        deadline: AICueGenerationDeadline
    ) async throws -> AICueGeneration {
        throw AICueGenerationError.providerUnavailable
    }

    func discard(generationID: UUID) async {}
    func discardAll() async {}
}
#endif
