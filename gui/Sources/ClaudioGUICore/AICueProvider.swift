import Foundation

package enum AICueHTTPMethod: String, Sendable, Equatable {
    case get = "GET"
    case post = "POST"
}

package struct AICueHTTPResponse: Sendable, Equatable {
    package let statusCode: Int
    package let headers: [String: String]
    package let body: Data
    package let finalURL: URL

    package init(
        statusCode: Int,
        headers: [String: String],
        body: Data,
        finalURL: URL
    ) {
        self.statusCode = statusCode
        self.headers = Dictionary(
            uniqueKeysWithValues: headers.map { ($0.key.lowercased(), $0.value) })
        self.body = body
        self.finalURL = finalURL
    }
}

public enum AICueProviderError: Error, Sendable, Equatable {
    case invalidCredential
    case insufficientCredits
    case forbidden
    case requiredModelsUnavailable
    case rateLimited(retryAfterSeconds: Int?)
    case serviceUnavailable
    case invalidRequest
    case invalidAudioResponse
    case responseTooLarge
    case deadlineExceeded
    case cancelled
    case transportFailure
}

public struct AICueProviderAudioResponse: Sendable, Equatable {
    public let data: Data
    public let mediaType: String
    public let modelID: String
    public let requestID: String?

    public init(data: Data, mediaType: String, modelID: String, requestID: String?) {
        self.data = data
        self.mediaType = mediaType
        self.modelID = modelID
        self.requestID = requestID
    }
}

public struct AICueProviderCandidateResponse: Sendable, Equatable {
    public let identity: AICueCandidateIdentity
    public let audio: AICueProviderAudioResponse

    public init(identity: AICueCandidateIdentity, audio: AICueProviderAudioResponse) {
        self.identity = identity
        self.audio = audio
    }
}

public protocol AICueCandidateSetProvider: AICueCredentialValidating {
    var profile: AICueProviderProfile { get }

    func generateCandidateSet(
        plan: AICueSoundPlan,
        credential: SensitiveCredentialInput,
        deadline: AICueGenerationDeadline
    ) async throws -> [AICueProviderCandidateResponse]
}

public protocol AICueProvider: AICueCredentialValidating {
    var profile: AICueProviderProfile { get }

    func generateCandidate(
        request: AICueProviderRequest,
        credential: SensitiveCredentialInput,
        deadline: AICueGenerationDeadline
    ) async throws -> AICueProviderAudioResponse
}

/// Adapts the original one-request-per-candidate providers to the candidate-set seam. The adapter
/// intentionally preserves their one bounded 429 retry across the whole three-request generation;
/// native-batch providers implement `AICueCandidateSetProvider` directly and own their own retry
/// contract.
public struct SequentialAICueCandidateSetAdapter: AICueCandidateSetProvider, Sendable {
    public let profile: AICueProviderProfile

    private let provider: any AICueProvider
    private let registry: AICueProviderRegistry
    private let compiler: AICueProviderRequestCompiler
    private let retrySleeper: any AICueRetrySleeping

    public init(
        provider: any AICueProvider,
        registry: AICueProviderRegistry = AICueProviderRegistry()
    ) {
        self.init(
            provider: provider,
            registry: registry,
            retrySleeper: AICueSystemRetrySleeper())
    }

    package init(
        provider: any AICueProvider,
        registry: AICueProviderRegistry,
        retrySleeper: any AICueRetrySleeping
    ) {
        self.provider = provider
        profile = provider.profile
        self.registry = registry
        compiler = AICueProviderRequestCompiler(registry: registry)
        self.retrySleeper = retrySleeper
    }

    public func validateCredential(_ credential: SensitiveCredentialInput) async throws {
        try await provider.validateCredential(credential)
    }

    public func generateCandidateSet(
        plan: AICueSoundPlan,
        credential: SensitiveCredentialInput,
        deadline: AICueGenerationDeadline
    ) async throws -> [AICueProviderCandidateResponse] {
        try await generateCandidateSet(
            plan: plan,
            credential: credential,
            deadline: deadline,
            transform: { $0 })
    }

    /// Lets the engine validate and persist each legacy response before the next potentially
    /// billable POST begins. Native candidate-set providers do not use this compatibility seam.
    package func generateCandidateSet<Output: Sendable>(
        plan: AICueSoundPlan,
        credential: SensitiveCredentialInput,
        deadline: AICueGenerationDeadline,
        transform: @escaping @Sendable (AICueProviderCandidateResponse) async throws -> Output
    ) async throws -> [Output] {
        guard
            let registeredProfile = try? registry.profile(for: profile.id),
            registeredProfile == profile,
            let policy = registeredProfile.routes[plan.modality]?.candidateSetPolicy,
            policy.isValid
        else {
            throw AICueProviderError.invalidRequest
        }

        let variants = Array(AICueVariant.allCases.prefix(policy.requestedCount))
        let requests = try variants.map {
            try compiler.compile(plan: plan, profileID: profile.id, variant: $0)
        }
        var retryAvailable = true
        var responses: [Output] = []
        responses.reserveCapacity(policy.requestedCount)
        for (index, request) in requests.enumerated() {
            try Task.checkCancellation()
            let attempt = try await generateWithConservativeRetry(
                request: request,
                credential: credential,
                deadline: deadline,
                allowRetry: retryAvailable)
            if attempt.usedRetry { retryAvailable = false }
            let identity: AICueCandidateIdentity
            switch policy.semantics {
            case .styled:
                identity = .styled(variants[index])
            case .numbered:
                guard let ordinal = AICueCandidateOrdinal(rawValue: index + 1) else {
                    throw AICueProviderError.invalidRequest
                }
                identity = .numbered(ordinal)
            }
            responses.append(
                try await transform(
                    AICueProviderCandidateResponse(
                        identity: identity,
                        audio: attempt.response)))
        }
        return responses
    }

    private func generateWithConservativeRetry(
        request: AICueProviderRequest,
        credential: SensitiveCredentialInput,
        deadline: AICueGenerationDeadline,
        allowRetry: Bool
    ) async throws -> (response: AICueProviderAudioResponse, usedRetry: Bool) {
        do {
            return (
                try await provider.generateCandidate(
                    request: request,
                    credential: credential,
                    deadline: deadline),
                false
            )
        } catch AICueProviderError.rateLimited(let retryAfter?)
            where allowRetry && (1...5).contains(retryAfter)
        {
            try await retrySleeper.sleep(seconds: retryAfter)
            try Task.checkCancellation()
            return (
                try await provider.generateCandidate(
                    request: request,
                    credential: credential,
                    deadline: deadline),
                true
            )
        }
    }
}

/// Keeps provider adapters on one redacted transport-error vocabulary. Provider-specific payload
/// validation stays in each adapter; this seam only maps errors produced before a response body is
/// exposed to the adapter.
package enum AICueProviderTransportErrorMapper {
    package static func map(
        _ error: Error,
        unexpectedMediaType: AICueProviderError
    ) -> AICueProviderError {
        if let providerError = error as? AICueProviderError { return providerError }
        if error is CancellationError { return .cancelled }
        guard let transportError = error as? AICueTransportError else {
            return .transportFailure
        }
        switch transportError {
        case .httpStatus(let code, let retryAfterSeconds):
            switch code {
            case 401: return .invalidCredential
            case 402: return .insufficientCredits
            case 403: return .forbidden
            case 429: return .rateLimited(retryAfterSeconds: retryAfterSeconds)
            case 500...599: return .serviceUnavailable
            default: return .invalidRequest
            }
        case .unexpectedMediaType:
            return unexpectedMediaType
        case .responseTooLarge:
            return .responseTooLarge
        case .deadlineExceeded:
            return .deadlineExceeded
        case .cancelled:
            return .cancelled
        case .invalidRequest, .originMismatch, .pathMismatch, .authenticationHeaderRejected,
            .redirectRejected, .invalidResponse, .backpressureExceeded, .inactivityTimeout,
            .transportFailure:
            return .transportFailure
        }
    }
}

package func sanitizedAICueProviderRequestID(_ value: String?) -> String? {
    guard let value, !value.isEmpty, value.utf8.count <= 128 else { return nil }
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
    guard value.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
    return value
}
