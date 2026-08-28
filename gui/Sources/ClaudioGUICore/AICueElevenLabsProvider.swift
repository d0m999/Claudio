import Dispatch
import Foundation

/// The closed ElevenLabs adapter. It compiles only provider-specific JSON; the shared unary
/// transport owns authentication injection, exact-origin enforcement, status/MIME checks,
/// redirect rejection, wire ceilings, cancellation and deadline handling.
public struct ElevenLabsAICueProvider: AICueProvider, Sendable {
    private static let modelsURL = fixedURL("https://api.elevenlabs.io/v1/models")
    private static let origin = try! AICueOrigin(
        scheme: "https",
        host: "api.elevenlabs.io",
        port: nil)
    private static let registeredProfile =
        try! AICueProviderRegistry().profile(for: .elevenLabsGlobal)
    private static let acceptedAudioMediaTypes: Set<String> = [
        "application/octet-stream",
        "audio/mp3",
        "audio/mpeg",
    ]
    private static let maximumModelsResponseBytes = 512 * 1_024

    private let unaryTransport: any AICueUnaryTransport

    public var profile: AICueProviderProfile {
        Self.registeredProfile
    }

    public init() {
        unaryTransport = AICueURLSessionUnaryTransport()
    }

    package init(unaryTransport: any AICueUnaryTransport) {
        self.unaryTransport = unaryTransport
    }

    public func validateCredential(_ credential: SensitiveCredentialInput) async throws {
        let request = AICueTransportRequest(
            method: .get,
            url: Self.modelsURL,
            expectedOrigin: Self.origin,
            expectedPath: "/v1/models",
            headers: ["accept": "application/json"],
            body: nil,
            acceptedMediaTypes: ["application/json"],
            maximumWireBytes: Self.maximumModelsResponseBytes,
            deadline: .startingNow())
        let response: AICueHTTPResponse
        do {
            response = try await unaryTransport.send(
                request,
                authentication: .elevenLabsAPIKeyHeader,
                credential: credential)
        } catch {
            throw mapTransportError(error, invalidPayload: .requiredModelsUnavailable)
        }
        guard response.finalURL == request.url else {
            throw AICueProviderError.transportFailure
        }
        guard
            AICueTransportRequestBuilder.normalizedMediaType(
                response.headers["content-type"]) == "application/json",
            let root = try? JSONSerialization.jsonObject(with: response.body),
            let models = root as? [[String: Any]]
        else {
            throw AICueProviderError.requiredModelsUnavailable
        }
        let modelIDs = Set(models.compactMap { $0["model_id"] as? String })
        let requiredModelIDs = Set(profile.routes.values.map(\.modelID))
        guard requiredModelIDs.count == 2, requiredModelIDs.isSubset(of: modelIDs) else {
            throw AICueProviderError.requiredModelsUnavailable
        }
    }

    public func generateCandidate(
        request: AICueProviderRequest,
        credential: SensitiveCredentialInput,
        deadline: AICueGenerationDeadline
    ) async throws -> AICueProviderAudioResponse {
        guard
            deadline.remainingNanoseconds(at: DispatchTime.now().uptimeNanoseconds) != nil,
            request.profileID == profile.id,
            let route = profile.routes[request.modality],
            route.authentication == .elevenLabsAPIKeyHeader,
            route.transport == .directContainer
        else {
            if deadline.remainingNanoseconds(at: DispatchTime.now().uptimeNanoseconds) == nil {
                throw AICueProviderError.deadlineExceeded
            }
            throw AICueProviderError.invalidRequest
        }

        let transportRequest: AICueTransportRequest
        switch request.modality {
        case .speech, .mixed:
            transportRequest = try speechTransportRequest(
                request: request,
                route: route,
                deadline: deadline)
        case .animal, .soundEffect:
            transportRequest = try soundEffectTransportRequest(
                request: request,
                route: route,
                deadline: deadline)
        }

        let response: AICueHTTPResponse
        do {
            response = try await unaryTransport.send(
                transportRequest,
                authentication: route.authentication,
                credential: credential)
        } catch {
            throw mapTransportError(error, invalidPayload: .invalidAudioResponse)
        }
        let mediaType = AICueTransportRequestBuilder.normalizedMediaType(
            response.headers["content-type"])
        guard
            response.finalURL == transportRequest.url,
            response.body.count <= AICueTransportCeilings.elevenLabsDecodedBytes,
            !response.body.isEmpty,
            Self.acceptedAudioMediaTypes.contains(mediaType)
        else {
            if response.body.count > AICueTransportCeilings.elevenLabsDecodedBytes {
                throw AICueProviderError.responseTooLarge
            }
            throw AICueProviderError.invalidAudioResponse
        }
        return AICueProviderAudioResponse(
            data: response.body,
            mediaType: mediaType,
            modelID: route.modelID,
            requestID: safeOpaqueID(
                response.headers["request-id"] ?? response.headers["x-request-id"]))
    }

    private func speechTransportRequest(
        request: AICueProviderRequest,
        route: AICueProviderRoute,
        deadline: AICueGenerationDeadline
    ) throws -> AICueTransportRequest {
        guard
            let spokenContent = request.spokenContent,
            !spokenContent.isEmpty,
            let languageTag = request.languageTag,
            route.supportedLanguageTags.contains(languageTag),
            (1...profile.constraints.maximumDurationMilliseconds).contains(
                request.targetDurationMilliseconds)
        else {
            throw AICueProviderError.invalidRequest
        }
        let body = try jsonBody([
            "text": spokenContent,
            "model_id": route.modelID,
        ])
        guard
            var components = URLComponents(url: route.endpoint, resolvingAgainstBaseURL: false)
        else {
            throw AICueProviderError.invalidRequest
        }
        components.queryItems = [
            URLQueryItem(name: "output_format", value: "mp3_44100_128")
        ]
        guard let url = components.url else { throw AICueProviderError.invalidRequest }
        return generationTransportRequest(
            url: url,
            expectedPath: route.endpoint.path,
            body: body,
            deadline: deadline)
    }

    private func soundEffectTransportRequest(
        request: AICueProviderRequest,
        route: AICueProviderRoute,
        deadline: AICueGenerationDeadline
    ) throws -> AICueTransportRequest {
        let influence = promptInfluence(for: request.variant)
        guard
            !request.prompt.isEmpty,
            request.spokenContent == nil,
            request.languageTag == nil,
            (1...profile.constraints.maximumDurationMilliseconds).contains(
                request.targetDurationMilliseconds),
            (0...1).contains(influence)
        else {
            throw AICueProviderError.invalidRequest
        }
        let duration = min(3, max(0.5, Double(request.targetDurationMilliseconds) / 1_000))
        let body = try jsonBody([
            "text": request.prompt,
            "loop": false,
            "duration_seconds": duration,
            "prompt_influence": influence,
            "model_id": route.modelID,
        ])
        return generationTransportRequest(
            url: route.endpoint,
            expectedPath: route.endpoint.path,
            body: body,
            deadline: deadline)
    }

    private func generationTransportRequest(
        url: URL,
        expectedPath: String,
        body: Data,
        deadline: AICueGenerationDeadline
    ) -> AICueTransportRequest {
        AICueTransportRequest(
            method: .post,
            url: url,
            expectedOrigin: Self.origin,
            expectedPath: expectedPath,
            headers: ["accept": "audio/mpeg", "content-type": "application/json"],
            body: body,
            acceptedMediaTypes: Self.acceptedAudioMediaTypes,
            maximumWireBytes: AICueTransportCeilings.elevenLabsWireBytes,
            deadline: deadline)
    }

    private func promptInfluence(for variant: AICueVariant) -> Double {
        switch variant {
        case .clear: 0.8
        case .brisk: 0.65
        case .restrained: 0.9
        }
    }

    private func jsonBody(_ object: [String: Any]) throws -> Data {
        do {
            return try JSONSerialization.data(withJSONObject: object, options: [])
        } catch {
            throw AICueProviderError.invalidRequest
        }
    }

    private func mapTransportError(
        _ error: Error,
        invalidPayload: AICueProviderError
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
            return invalidPayload
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

    private func safeOpaqueID(_ value: String?) -> String? {
        guard let value, !value.isEmpty, value.utf8.count <= 128 else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        guard value.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        return value
    }

    private static func fixedURL(_ value: String) -> URL {
        guard let url = URL(string: value) else {
            preconditionFailure("Invalid built-in ElevenLabs URL")
        }
        return url
    }
}
