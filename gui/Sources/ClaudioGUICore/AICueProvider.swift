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

public protocol AICueProvider: AICueCredentialValidating {
    var profile: AICueProviderProfile { get }

    func generateCandidate(
        request: AICueProviderRequest,
        credential: SensitiveCredentialInput,
        deadline: AICueGenerationDeadline
    ) async throws -> AICueProviderAudioResponse
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
