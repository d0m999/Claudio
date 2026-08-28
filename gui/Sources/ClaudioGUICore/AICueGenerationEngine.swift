import ClaudioCore
import Darwin
import Dispatch
import Foundation

public struct AICueTemporaryAudioAsset: Sendable, Equatable {
    public let fileURL: URL
    public let byteCount: Int
    public let sniffedFormat: AudioFormat

    public init(fileURL: URL, byteCount: Int, sniffedFormat: AudioFormat) {
        self.fileURL = fileURL
        self.byteCount = byteCount
        self.sniffedFormat = sniffedFormat
    }
}

public struct AICueCandidateProvenance: Sendable, Equatable {
    public let providerID: AICueProviderID
    public let profileID: AICueProviderProfileID
    public let modelID: String
    public let generationID: UUID
    public let requestOrdinal: Int
    public let providerRequestID: String?

    public init(
        providerID: AICueProviderID,
        profileID: AICueProviderProfileID,
        modelID: String,
        generationID: UUID,
        requestOrdinal: Int,
        providerRequestID: String?
    ) {
        self.providerID = providerID
        self.profileID = profileID
        self.modelID = modelID
        self.generationID = generationID
        self.requestOrdinal = requestOrdinal
        self.providerRequestID = providerRequestID
    }
}

public struct AICueCandidate: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let variant: AICueVariant
    public let asset: AICueTemporaryAudioAsset
    public let durationMilliseconds: Int
    public let mediaType: String
    public let provenance: AICueCandidateProvenance

    public init(
        id: UUID,
        variant: AICueVariant,
        asset: AICueTemporaryAudioAsset,
        durationMilliseconds: Int,
        mediaType: String,
        provenance: AICueCandidateProvenance
    ) {
        self.id = id
        self.variant = variant
        self.asset = asset
        self.durationMilliseconds = durationMilliseconds
        self.mediaType = mediaType
        self.provenance = provenance
    }
}

public struct AICueGeneration: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let profileID: AICueProviderProfileID
    public let plan: AICueSoundPlan
    public let candidates: [AICueCandidate]
    public let generatedAt: Date

    public init(
        id: UUID,
        profileID: AICueProviderProfileID,
        plan: AICueSoundPlan,
        candidates: [AICueCandidate],
        generatedAt: Date
    ) {
        self.id = id
        self.profileID = profileID
        self.plan = plan
        self.candidates = candidates
        self.generatedAt = generatedAt
    }
}

public enum AICueGenerationError: Error, Sendable, Equatable {
    case validation(AICueValidationError)
    case requestCompilation(AICueProviderRequestCompilationError)
    case providerUnavailable
    case credentialRequired
    case credentialUnavailable
    case provider(AICueProviderError)
    case audioTooLarge
    case unsupportedAudio
    case audioDurationUnavailable
    case audioTooLong
    case temporaryStorageUnavailable
    case deadlineExceeded
    case cancelled
}

package protocol AICueRetrySleeping: Sendable {
    func sleep(seconds: Int) async throws
}

public protocol AICueGenerating: Sendable {
    func generate(
        description: String,
        locale: String,
        providerProfileID: AICueProviderProfileID,
        deadline: AICueGenerationDeadline
    ) async throws -> AICueGeneration
    func discard(generationID: UUID) async
    func discardAll() async
}

private struct AICueSystemRetrySleeper: AICueRetrySleeping {
    func sleep(seconds: Int) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
    }
}

/// Owns the all-or-nothing lifetime of one three-candidate generation. The actor retains only
/// private temporary-directory identities; descriptions and SoundPlans remain in the returned
/// in-memory generation and are never serialized here.
public actor AICueGenerationEngine: AICueGenerating {
    private static let maximumAudioBytes = 5 * 1_024 * 1_024
    private static let maximumDurationSeconds = 3.0
    private static let staleLifetime: TimeInterval = 24 * 60 * 60

    private let credentialManager: any AICueGenerationCredentialManaging
    private let provider: any AICueProvider
    private let registry: AICueProviderRegistry
    private let temporaryRoot: URL
    private let durationProbe: any AudioDurationProbing
    private let retrySleeper: any AICueRetrySleeping
    private let planner = AICueSoundPlanner()
    private let compiler: AICueProviderRequestCompiler
    private var activeDirectories: [UUID: URL] = [:]

    public init(
        vault: any AICueCredentialVault,
        provider: any AICueProvider,
        temporaryRoot: URL,
        durationProbe: any AudioDurationProbing,
        registry: AICueProviderRegistry = AICueProviderRegistry()
    ) {
        self.init(
            credentialManager: AICueCredentialManager(
                vault: vault,
                registry: registry,
                validators: [:]),
            provider: provider,
            temporaryRoot: temporaryRoot,
            durationProbe: durationProbe,
            retrySleeper: AICueSystemRetrySleeper(),
            registry: registry)
    }

    package init(
        vault: any AICueCredentialVault,
        provider: any AICueProvider,
        temporaryRoot: URL,
        durationProbe: any AudioDurationProbing,
        retrySleeper: any AICueRetrySleeping,
        registry: AICueProviderRegistry = AICueProviderRegistry()
    ) {
        self.init(
            credentialManager: AICueCredentialManager(
                vault: vault,
                registry: registry,
                validators: [:]),
            provider: provider,
            temporaryRoot: temporaryRoot,
            durationProbe: durationProbe,
            retrySleeper: retrySleeper,
            registry: registry)
    }

    public init(
        credentialManager: any AICueGenerationCredentialManaging,
        provider: any AICueProvider,
        temporaryRoot: URL,
        durationProbe: any AudioDurationProbing,
        registry: AICueProviderRegistry = AICueProviderRegistry()
    ) {
        self.init(
            credentialManager: credentialManager,
            provider: provider,
            temporaryRoot: temporaryRoot,
            durationProbe: durationProbe,
            retrySleeper: AICueSystemRetrySleeper(),
            registry: registry)
    }

    private init(
        credentialManager: any AICueGenerationCredentialManaging,
        provider: any AICueProvider,
        temporaryRoot: URL,
        durationProbe: any AudioDurationProbing,
        retrySleeper: any AICueRetrySleeping,
        registry: AICueProviderRegistry
    ) {
        self.credentialManager = credentialManager
        self.provider = provider
        self.registry = registry
        self.temporaryRoot = temporaryRoot
        self.durationProbe = durationProbe
        self.retrySleeper = retrySleeper
        compiler = AICueProviderRequestCompiler(registry: registry)
    }

    public func generate(
        description: String,
        locale: String,
        providerProfileID: AICueProviderProfileID,
        deadline: AICueGenerationDeadline
    ) async throws -> AICueGeneration {
        try requireRemainingBudget(deadline)
        let request: AICueGenerationRequest
        let plan: AICueSoundPlan
        let profile: AICueProviderProfile
        let compiledRequests: [AICueProviderRequest]
        do {
            request = try AICueGenerationRequest(
                description: description,
                locale: locale,
                providerProfileID: providerProfileID)
            plan = try planner.makePlan(for: request)
            profile = try registry.profile(for: providerProfileID)
            compiledRequests = try AICueVariant.allCases.map {
                try compiler.compile(plan: plan, profileID: providerProfileID, variant: $0)
            }
        } catch let error as AICueValidationError {
            throw AICueGenerationError.validation(error)
        } catch let error as AICueProviderRequestCompilationError {
            throw AICueGenerationError.requestCompilation(error)
        } catch is AICueProviderRegistryError {
            throw AICueGenerationError.requestCompilation(.unknownProfile)
        } catch {
            throw AICueGenerationError.temporaryStorageUnavailable
        }
        guard provider.profile.id == profile.id else {
            throw AICueGenerationError.providerUnavailable
        }
        try requireRemainingBudget(deadline)

        let credentialLease: AICueGenerationCredential
        do {
            let credentialManager = credentialManager
            credentialLease = try await Self.runBeforeDeadline(deadline) {
                try await credentialManager.credentialForGeneration(for: profile.id)
            }
        } catch AICueProviderError.deadlineExceeded {
            throw AICueGenerationError.deadlineExceeded
        } catch is CancellationError {
            throw AICueGenerationError.cancelled
        } catch let error as AICueCredentialManagerError {
            switch error {
            case .credentialRequired: throw AICueGenerationError.credentialRequired
            case .stateChanged: throw AICueGenerationError.cancelled
            case .unknownProfile, .probeUnavailable, .credentialUnavailable:
                throw AICueGenerationError.credentialUnavailable
            }
        } catch {
            throw AICueGenerationError.credentialUnavailable
        }
        try requireRemainingBudget(deadline)

        do {
            try Task.checkCancellation()
        } catch {
            throw AICueGenerationError.cancelled
        }

        let generationID = UUID()
        let directory = temporaryRoot.appendingPathComponent(
            "generation-\(generationID.uuidString.lowercased())",
            isDirectory: true)
        do {
            try ensurePrivateDirectoryTree(at: temporaryRoot)
            purgeStaleDirectories(now: Date())
            try ensurePrivateDirectoryTree(at: directory)
        } catch {
            throw AICueGenerationError.temporaryStorageUnavailable
        }
        try requireRemainingBudget(deadline)
        activeDirectories[generationID] = directory
        var succeeded = false
        defer {
            if !succeeded {
                activeDirectories.removeValue(forKey: generationID)
                try? FileManager.default.removeItem(at: directory)
            }
        }

        var candidates: [AICueCandidate] = []
        candidates.reserveCapacity(AICueGenerationRequest.candidateCount)
        var retryAvailable = true
        for (variant, compiled) in zip(AICueVariant.allCases, compiledRequests) {
            do {
                try Task.checkCancellation()
            } catch {
                throw AICueGenerationError.cancelled
            }
            let response: AICueProviderAudioResponse
            do {
                let attempt = try await generateWithConservativeRetry(
                    request: compiled,
                    credential: credentialLease.credential,
                    deadline: deadline,
                    allowRetry: retryAvailable)
                response = attempt.response
                if attempt.usedRetry { retryAvailable = false }
            } catch let error as AICueProviderError {
                await credentialManager.generation(
                    credentialLease,
                    didFailWith: error)
                if error == .cancelled { throw AICueGenerationError.cancelled }
                if error == .deadlineExceeded { throw AICueGenerationError.deadlineExceeded }
                throw AICueGenerationError.provider(error)
            } catch is CancellationError {
                throw AICueGenerationError.cancelled
            } catch {
                throw AICueGenerationError.provider(.transportFailure)
            }

            let durationProbe = durationProbe
            let candidate: AICueCandidate
            do {
                candidate = try await Self.runBeforeDeadline(deadline) {
                    try Self.validateAndPersist(
                        response: response,
                        variant: variant,
                        profile: profile,
                        generationID: generationID,
                        directory: directory,
                        durationProbe: durationProbe)
                }
            } catch AICueProviderError.deadlineExceeded {
                throw AICueGenerationError.deadlineExceeded
            } catch is CancellationError {
                throw AICueGenerationError.cancelled
            }
            candidates.append(candidate)
        }

        guard candidates.count == AICueGenerationRequest.candidateCount else {
            throw AICueGenerationError.provider(.transportFailure)
        }
        try requireRemainingBudget(deadline)
        do {
            try Task.checkCancellation()
        } catch is CancellationError {
            throw AICueGenerationError.cancelled
        }

        // This is the generation's commit point: all three candidates and the shared budget have
        // passed. Await the local credential mutation directly so cancellation cannot publish a
        // failed result while a detached loser subsequently deletes the retryable pending item.
        // Cancellation before this point retains pending; once commit starts, success wins.
        do {
            try await credentialManager.generationDidValidate(credentialLease)
        } catch let error as AICueCredentialManagerError where error == .stateChanged {
            throw AICueGenerationError.cancelled
        } catch is CancellationError {
            throw AICueGenerationError.cancelled
        } catch {
            throw AICueGenerationError.credentialUnavailable
        }
        succeeded = true
        return AICueGeneration(
            id: generationID,
            profileID: profile.id,
            plan: plan,
            candidates: candidates,
            generatedAt: Date())
    }

    public func discard(generationID: UUID) {
        guard let directory = activeDirectories.removeValue(forKey: generationID) else { return }
        try? FileManager.default.removeItem(at: directory)
    }

    public func discardAll() {
        let directories = Array(activeDirectories.values)
        activeDirectories.removeAll()
        for directory in directories {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func generateWithConservativeRetry(
        request: AICueProviderRequest,
        credential: SensitiveCredentialInput,
        deadline: AICueGenerationDeadline,
        allowRetry: Bool
    ) async throws -> (response: AICueProviderAudioResponse, usedRetry: Bool) {
        let provider = provider
        do {
            let response = try await Self.runBeforeDeadline(deadline) {
                try await provider.generateCandidate(
                    request: request,
                    credential: credential,
                    deadline: deadline)
            }
            return (response, false)
        } catch AICueProviderError.rateLimited(let retryAfter?)
            where allowRetry && (1...5).contains(retryAfter)
        {
            let retrySleeper = retrySleeper
            _ = try await Self.runBeforeDeadline(deadline) {
                try await retrySleeper.sleep(seconds: retryAfter)
                return true
            }
            try Task.checkCancellation()
            // Exactly one retry. A second 429, like every other failure, escapes immediately.
            let response = try await Self.runBeforeDeadline(deadline) {
                try await provider.generateCandidate(
                    request: request,
                    credential: credential,
                    deadline: deadline)
            }
            return (response, true)
        }
    }

    private func requireRemainingBudget(_ deadline: AICueGenerationDeadline) throws {
        guard
            deadline.remainingNanoseconds(at: DispatchTime.now().uptimeNanoseconds) != nil
        else {
            throw AICueGenerationError.deadlineExceeded
        }
    }

    private nonisolated static func runBeforeDeadline<T: Sendable>(
        _ deadline: AICueGenerationDeadline,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try Task.checkCancellation()
        guard
            let remaining = deadline.remainingNanoseconds(
                at: DispatchTime.now().uptimeNanoseconds)
        else {
            throw AICueProviderError.deadlineExceeded
        }
        let value = try await AICueDeadlineRaceCoordinator<T>().run(
            remainingNanoseconds: remaining,
            operation: operation)
        guard
            deadline.remainingNanoseconds(at: DispatchTime.now().uptimeNanoseconds) != nil
        else {
            throw AICueProviderError.deadlineExceeded
        }
        return value
    }

    private nonisolated static func validateAndPersist(
        response: AICueProviderAudioResponse,
        variant: AICueVariant,
        profile: AICueProviderProfile,
        generationID: UUID,
        directory: URL,
        durationProbe: any AudioDurationProbing
    ) throws -> AICueCandidate {
        guard response.data.count <= maximumAudioBytes else {
            throw AICueGenerationError.audioTooLarge
        }
        guard let format = sniffAudioFormat(response.data) else {
            throw AICueGenerationError.unsupportedAudio
        }
        let fileURL = directory.appendingPathComponent(
            "candidate-\(variant.ordinal).\(format.rawValue)")
        do {
            try writePrivateFileWithoutReplacing(response.data, to: fileURL)
        } catch {
            throw AICueGenerationError.temporaryStorageUnavailable
        }
        guard
            let duration = durationProbe.probeDuration(of: fileURL),
            duration.isFinite,
            duration > 0
        else {
            throw AICueGenerationError.audioDurationUnavailable
        }
        guard duration <= maximumDurationSeconds else {
            throw AICueGenerationError.audioTooLong
        }

        return AICueCandidate(
            id: UUID(),
            variant: variant,
            asset: AICueTemporaryAudioAsset(
                fileURL: fileURL,
                byteCount: response.data.count,
                sniffedFormat: format),
            durationMilliseconds: Int((duration * 1_000).rounded()),
            mediaType: response.mediaType,
            provenance: AICueCandidateProvenance(
                providerID: profile.providerID,
                profileID: profile.id,
                modelID: response.modelID,
                generationID: generationID,
                requestOrdinal: variant.ordinal,
                providerRequestID: response.requestID))
    }

    private func purgeStaleDirectories(now: Date) {
        guard
            let contents = try? FileManager.default.contentsOfDirectory(
                at: temporaryRoot,
                includingPropertiesForKeys: [
                    .contentModificationDateKey, .isDirectoryKey, .isSymbolicLinkKey,
                ],
                options: [.skipsHiddenFiles])
        else { return }
        let active = Set(activeDirectories.values.map(\.standardizedFileURL))
        for candidate in contents where candidate.lastPathComponent.hasPrefix("generation-") {
            let standardized = candidate.standardizedFileURL
            guard !active.contains(standardized) else { continue }
            guard
                let values = try? candidate.resourceValues(forKeys: [
                    .contentModificationDateKey, .isDirectoryKey, .isSymbolicLinkKey,
                ]),
                values.isDirectory == true,
                values.isSymbolicLink != true,
                let modified = values.contentModificationDate,
                now.timeIntervalSince(modified) > Self.staleLifetime
            else { continue }
            try? FileManager.default.removeItem(at: candidate)
        }
    }
}

/// Resolves at the first terminal result without structurally awaiting a cancelled loser. Provider
/// transports are still cancelled at the deadline, while a broken/non-cooperative implementation
/// cannot extend the caller-visible generation budget or publish its late result.
private final class AICueDeadlineRaceCoordinator<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var terminalResult: Result<Value, Error>?
    private var operationTask: Task<Void, Never>?
    private var deadlineTask: Task<Void, Never>?

    func run(
        remainingNanoseconds: UInt64,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                install(
                    continuation: continuation,
                    remainingNanoseconds: remainingNanoseconds,
                    operation: operation)
            }
        } onCancel: {
            resolve(.failure(CancellationError()))
        }
    }

    private func install(
        continuation: CheckedContinuation<Value, Error>,
        remainingNanoseconds: UInt64,
        operation: @escaping @Sendable () async throws -> Value
    ) {
        lock.lock()
        if let terminalResult {
            lock.unlock()
            continuation.resume(with: terminalResult)
            return
        }
        self.continuation = continuation
        operationTask = Task {
            do {
                self.resolve(.success(try await operation()))
            } catch {
                self.resolve(.failure(error))
            }
        }
        deadlineTask = Task {
            do {
                try await Task.sleep(nanoseconds: remainingNanoseconds)
                self.resolve(.failure(AICueProviderError.deadlineExceeded))
            } catch {
                // Losing timer cancellation is expected and has no second terminal result.
            }
        }
        lock.unlock()
    }

    private func resolve(_ result: Result<Value, Error>) {
        lock.lock()
        guard terminalResult == nil else {
            lock.unlock()
            return
        }
        terminalResult = result
        let continuation = self.continuation
        let operationTask = self.operationTask
        let deadlineTask = self.deadlineTask
        self.continuation = nil
        self.operationTask = nil
        self.deadlineTask = nil
        lock.unlock()

        operationTask?.cancel()
        deadlineTask?.cancel()
        continuation?.resume(with: result)
    }
}

private func writePrivateFileWithoutReplacing(_ data: Data, to url: URL) throws {
    let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
        guard let path else {
            errno = EINVAL
            return -1
        }
        return Darwin.open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    }
    guard descriptor >= 0 else { throw AICueGenerationError.temporaryStorageUnavailable }
    var shouldUnlink = true
    defer {
        _ = Darwin.close(descriptor)
        if shouldUnlink { _ = url.withUnsafeFileSystemRepresentation(Darwin.unlink) }
    }

    let writeSucceeded = data.withUnsafeBytes { rawBuffer -> Bool in
        guard var pointer = rawBuffer.baseAddress else { return data.isEmpty }
        var remaining = rawBuffer.count
        while remaining > 0 {
            let written = Darwin.write(descriptor, pointer, remaining)
            if written < 0 {
                if errno == EINTR { continue }
                return false
            }
            guard written > 0 else { return false }
            remaining -= written
            pointer = pointer.advanced(by: written)
        }
        return true
    }
    guard writeSucceeded, Darwin.fchmod(descriptor, 0o600) == 0 else {
        throw AICueGenerationError.temporaryStorageUnavailable
    }
    shouldUnlink = false
}
