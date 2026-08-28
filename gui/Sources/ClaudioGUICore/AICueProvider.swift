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
