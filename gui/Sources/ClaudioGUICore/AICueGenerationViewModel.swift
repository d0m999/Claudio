import Combine
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
    case validating
    case deleting
}

public enum AICueCredentialFailure: Sendable, Equatable {
    case provider(AICueProviderError)
    case storageUnavailable
}

public enum AICueComposerFailure: Sendable, Equatable {
    case generation(AICueGenerationError)
    case displayName(AICueValidationError)
    case adoption(AICueAdoptionError)
}

/// Main-actor state machine for the visible two-step flow. It owns no secret value and knows no
/// provider endpoint. Credential plaintext crosses this object only as a one-shot opaque input to
/// the credential manager, while generation and adoption remain injectable deep operations.
@MainActor
public final class AICueGenerationViewModel: ObservableObject {
    @Published public private(set) var credentialStatus: AICueCredentialStatus?
    @Published public private(set) var credentialActivity: AICueCredentialActivity = .idle
    @Published public private(set) var credentialFailure: AICueCredentialFailure?
    @Published public private(set) var phase: AICueComposerPhase = .editing
    @Published public private(set) var adoptingCandidateID: UUID?
    @Published public private(set) var soundDescription = ""
    @Published public private(set) var displayName = ""
    @Published public private(set) var target: AICueAdoptionTarget?
    @Published public private(set) var generation: AICueGeneration?
    @Published public private(set) var failure: AICueComposerFailure?
    @Published public private(set) var adoptionOutcome: AICueAdoptionOutcome?

    private let credentialManager: any AICueCredentialManaging
    private let generator: any AICueGenerating
    private var sessionRevision: UInt64 = 0
    private var generationTask: Task<Void, Never>?
    private var adoptionTask: Task<Void, Never>?

    public init(
        credentialManager: any AICueCredentialManaging,
        generator: any AICueGenerating
    ) {
        self.credentialManager = credentialManager
        self.generator = generator
    }

    public var requiresCredentialConfiguration: Bool {
        if credentialStatus == .missing { return true }
        guard case .generation(let error) = failure else { return false }
        return error == .credentialRequired
    }

    public var isBusy: Bool {
        phase == .generating || phase == .adopting || credentialActivity != .idle
    }

    /// Opens one event-scoped composer. Re-entering the same live target is a no-op; changing any
    /// part of the target invalidates the old candidate identities before the new session appears.
    public func begin(target: AICueAdoptionTarget) {
        guard self.target != target else { return }
        resetComposer(clearTarget: true)
        self.target = target
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
        credentialStatus = await credentialManager.status(for: .elevenLabs)
    }

    /// Saving is never coupled to generation. A successful save clears only a credential-required
    /// message; the description and explicit second click remain intact.
    public func validateAndSave(_ credential: SensitiveCredentialInput) async {
        guard credentialActivity == .idle else { return }
        credentialActivity = .validating
        credentialFailure = nil
        defer { credentialActivity = .idle }
        do {
            try await credentialManager.validateAndSave(credential, for: .elevenLabs)
            credentialStatus = await credentialManager.status(for: .elevenLabs)
            switch failure {
            case .generation(.credentialRequired), .generation(.credentialUnavailable):
                failure = nil
            default:
                break
            }
        } catch let error as AICueProviderError {
            credentialStatus = await credentialManager.status(for: .elevenLabs)
            credentialFailure = .provider(error)
        } catch {
            credentialStatus = await credentialManager.status(for: .elevenLabs)
            credentialFailure = .storageUnavailable
        }
    }

    public func deleteCredential() async {
        guard credentialActivity == .idle, phase != .generating, phase != .adopting else {
            return
        }
        credentialActivity = .deleting
        credentialFailure = nil
        defer { credentialActivity = .idle }
        do {
            try await credentialManager.delete(for: .elevenLabs)
            credentialStatus = .missing
        } catch {
            credentialStatus = await credentialManager.status(for: .elevenLabs)
            credentialFailure = .storageUnavailable
        }
    }

    public func startGeneration(locale: String) {
        guard target != nil, phase != .generating, phase != .adopting else { return }

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

        generationTask = Task { [weak self] in
            let result: Result<AICueGeneration, AICueGenerationError>
            do {
                result = .success(
                    try await generator.generate(description: description, locale: locale))
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
            case .failure(let error):
                if error == .credentialRequired {
                    self.credentialStatus = .missing
                } else if error == .credentialUnavailable {
                    self.credentialStatus = .unavailable
                }
                self.phase = .editing
                self.failure = .generation(error)
            }
        }
    }

    public func adopt(
        candidateID: UUID,
        using operation:
            @escaping @MainActor (AICueAdoptionRequest) async -> Result<
                AICueAdoptionOutcome, AICueAdoptionError
            >
    ) {
        guard
            phase == .candidatesReady,
            let generation,
            let candidate = generation.candidates.first(where: { $0.id == candidateID }),
            let target
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
        let request = AICueAdoptionRequest(
            candidate: candidate,
            displayName: name,
            target: target)
        adoptionTask = Task { [weak self] in
            let result = await operation(request)
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
            case .success(let outcome):
                await generator.discard(generationID: generation.id)
                guard self.sessionRevision == revision else { return }
                self.generation = nil
                self.adoptionOutcome = outcome
                self.phase = .applied
            case .failure(let error):
                self.phase = .candidatesReady
                self.failure = .adoption(error)
            }
        }
    }

    public func endSession() {
        resetComposer(clearTarget: true)
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

    private func resetComposer(clearTarget: Bool) {
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
        if clearTarget { target = nil }
    }

    private func discard(_ generation: AICueGeneration) {
        let generator = self.generator
        Task {
            await generator.discard(generationID: generation.id)
        }
    }
}
