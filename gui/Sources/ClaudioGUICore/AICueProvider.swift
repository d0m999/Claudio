import Foundation

package enum AICueHTTPMethod: String, Sendable, Equatable {
    case get = "GET"
    case post = "POST"
}

package struct AICueHTTPRequest: Sendable, CustomReflectable {
    package let method: AICueHTTPMethod
    package let url: URL
    package let headers: [String: String]
    package let body: Data?
    package let maximumResponseBytes: Int
    package let credential: SensitiveCredentialInput

    package init(
        method: AICueHTTPMethod,
        url: URL,
        headers: [String: String],
        body: Data?,
        maximumResponseBytes: Int,
        credential: SensitiveCredentialInput
    ) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
        self.maximumResponseBytes = maximumResponseBytes
        self.credential = credential
    }

    package var customMirror: Mirror {
        Mirror(
            self,
            children: [
                "method": method.rawValue,
                "url": url.absoluteString,
                "maximumResponseBytes": maximumResponseBytes,
            ],
            displayStyle: .struct)
    }
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

package enum AICueHTTPClientError: Error, Sendable, Equatable {
    case invalidRequest
    case redirectRejected
    case responseTooLarge
    case invalidResponse
    case cancelled
    case transportFailure
}

package protocol AICueHTTPClient: Sendable {
    func send(_ request: AICueHTTPRequest) async throws -> AICueHTTPResponse
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

/// One closed ElevenLabs adapter. Callers can supply a key, but never an endpoint, model, voice,
/// redirect target, or download URL.
public struct ElevenLabsAICueProvider: AICueProvider, Sendable {
    private static let apiHost = "api.elevenlabs.io"
    private static let maximumModelResponseBytes = 512 * 1_024
    private static let maximumAudioResponseBytes = 5 * 1_024 * 1_024
    private static let registeredProfile =
        try! AICueProviderRegistry().profile(for: .elevenLabsGlobal)

    private let httpClient: any AICueHTTPClient

    public var profile: AICueProviderProfile {
        Self.registeredProfile
    }

    public init() {
        httpClient = AICueURLSessionHTTPClient()
    }

    package init(httpClient: any AICueHTTPClient) {
        self.httpClient = httpClient
    }

    public func validateCredential(_ credential: SensitiveCredentialInput) async throws {
        let response = try await send(
            AICueHTTPRequest(
                method: .get,
                url: try fixedURL(path: "/v1/models"),
                headers: ["accept": "application/json"],
                body: nil,
                maximumResponseBytes: Self.maximumModelResponseBytes,
                credential: credential))
        try requireSuccess(response)
        guard
            normalizedMediaType(response.headers["content-type"]) == "application/json",
            let root = try? JSONSerialization.jsonObject(with: response.body),
            let models = root as? [[String: Any]]
        else {
            throw AICueProviderError.requiredModelsUnavailable
        }
        let ids = Set(models.compactMap { $0["model_id"] as? String })
        let requiredModelIDs = Set(profile.routes.values.map(\.modelID))
        guard
            requiredModelIDs.count == 2,
            requiredModelIDs.isSubset(of: ids)
        else {
            throw AICueProviderError.requiredModelsUnavailable
        }
    }

    public func generateCandidate(
        request: AICueProviderRequest,
        credential: SensitiveCredentialInput,
        deadline: AICueGenerationDeadline
    ) async throws -> AICueProviderAudioResponse {
        guard
            deadline.remainingNanoseconds(at: DispatchTime.now().uptimeNanoseconds) != nil
        else { throw AICueProviderError.deadlineExceeded }
        guard
            request.profileID == profile.id,
            let route = profile.routes[request.modality]
        else { throw AICueProviderError.invalidRequest }

        let httpRequest: AICueHTTPRequest
        switch request.modality {
        case .speech, .mixed:
            guard let spokenContent = request.spokenContent else {
                throw AICueProviderError.invalidRequest
            }
            guard
                route.modelID == "eleven_v3",
                route.voiceID == "JBFqnCBsd6RMkjVDRZzb",
                route.authentication == .elevenLabsAPIKeyHeader,
                route.transport == .directContainer,
                !spokenContent.isEmpty,
                request.languageTag != nil
            else { throw AICueProviderError.invalidRequest }
            let body = try jsonBody([
                "text": spokenContent,
                "model_id": route.modelID,
            ])
            guard var components = URLComponents(
                url: route.endpoint,
                resolvingAgainstBaseURL: false
            )
            else { throw AICueProviderError.invalidRequest }
            components.queryItems = [
                URLQueryItem(name: "output_format", value: "mp3_44100_128")
            ]
            guard let url = components.url else { throw AICueProviderError.invalidRequest }
            httpRequest = generationRequest(url: url, body: body, credential: credential)

        case .animal, .soundEffect:
            let influence = promptInfluence(for: request.variant)
            guard
                route.modelID == "eleven_text_to_sound_v2",
                route.voiceID == nil,
                route.authentication == .elevenLabsAPIKeyHeader,
                route.transport == .directContainer,
                !request.prompt.isEmpty,
                (0...1).contains(influence)
            else { throw AICueProviderError.invalidRequest }
            let duration = min(3, max(0.5, Double(request.targetDurationMilliseconds) / 1_000))
            let body = try jsonBody([
                "text": request.prompt,
                "loop": false,
                "duration_seconds": duration,
                "prompt_influence": influence,
                "model_id": route.modelID,
            ])
            httpRequest = generationRequest(
                url: route.endpoint,
                body: body,
                credential: credential)
        }

        let response = try await send(httpRequest)
        try requireSuccess(response)
        let mediaType = normalizedMediaType(response.headers["content-type"])
        guard
            !response.body.isEmpty,
            mediaType.hasPrefix("audio/") || mediaType == "application/octet-stream"
        else {
            throw AICueProviderError.invalidAudioResponse
        }
        return AICueProviderAudioResponse(
            data: response.body,
            mediaType: mediaType,
            modelID: route.modelID,
            requestID: safeOpaqueID(response.headers["request-id"] ?? response.headers["x-request-id"]))
    }

    private func promptInfluence(for variant: AICueVariant) -> Double {
        switch variant {
        case .clear: 0.8
        case .brisk: 0.65
        case .restrained: 0.9
        }
    }

    private func generationRequest(
        url: URL,
        body: Data,
        credential: SensitiveCredentialInput
    ) -> AICueHTTPRequest {
        AICueHTTPRequest(
            method: .post,
            url: url,
            headers: ["accept": "audio/mpeg", "content-type": "application/json"],
            body: body,
            maximumResponseBytes: Self.maximumAudioResponseBytes,
            credential: credential)
    }

    private func fixedURL(path: String) throws -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = Self.apiHost
        components.path = path
        guard let url = components.url else { throw AICueProviderError.invalidRequest }
        return url
    }

    private func jsonBody(_ object: [String: Any]) throws -> Data {
        do {
            return try JSONSerialization.data(withJSONObject: object, options: [])
        } catch {
            throw AICueProviderError.invalidRequest
        }
    }

    private func send(_ request: AICueHTTPRequest) async throws -> AICueHTTPResponse {
        do {
            let response = try await httpClient.send(request)
            // The production transport rejects every redirect. Re-check the exact terminal URL
            // here as well so a future/injected transport cannot silently widen that trust seam.
            guard response.finalURL == request.url else {
                throw AICueProviderError.transportFailure
            }
            return response
        } catch let error as AICueProviderError {
            throw error
        } catch let error as AICueHTTPClientError {
            switch error {
            case .responseTooLarge: throw AICueProviderError.responseTooLarge
            case .cancelled: throw AICueProviderError.cancelled
            case .invalidRequest, .redirectRejected, .invalidResponse, .transportFailure:
                throw AICueProviderError.transportFailure
            }
        } catch is CancellationError {
            throw AICueProviderError.cancelled
        } catch {
            throw AICueProviderError.transportFailure
        }
    }

    private func requireSuccess(_ response: AICueHTTPResponse) throws {
        guard (200..<300).contains(response.statusCode) else {
            switch response.statusCode {
            case 401: throw AICueProviderError.invalidCredential
            case 402: throw AICueProviderError.insufficientCredits
            case 403: throw AICueProviderError.forbidden
            case 429:
                let retry = response.headers["retry-after"].flatMap { Int($0) }
                throw AICueProviderError.rateLimited(retryAfterSeconds: retry)
            case 500...599: throw AICueProviderError.serviceUnavailable
            default: throw AICueProviderError.invalidRequest
            }
        }
    }

    private func normalizedMediaType(_ value: String?) -> String {
        value?.split(separator: ";", maxSplits: 1).first.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        } ?? ""
    }

    private func safeOpaqueID(_ value: String?) -> String? {
        guard let value, !value.isEmpty, value.utf8.count <= 128 else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        guard value.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        return value
    }
}

/// Ephemeral, cookie/cache/credential-free network transport with a hard streamed byte ceiling.
/// Redirects are rejected before a second request can carry `xi-api-key` to another origin.
package actor AICueURLSessionHTTPClient: AICueHTTPClient {
    private static let allowedHosts: Set<String> = ["api.elevenlabs.io"]
    private let configuration: URLSessionConfiguration

    package init(configuration: URLSessionConfiguration? = nil) {
        let base = configuration ?? .ephemeral
        let hardened = (base.copy() as? URLSessionConfiguration) ?? .ephemeral
        hardened.protocolClasses = base.protocolClasses
        hardened.urlCache = nil
        hardened.requestCachePolicy = .reloadIgnoringLocalCacheData
        hardened.httpCookieStorage = nil
        hardened.httpShouldSetCookies = false
        hardened.urlCredentialStorage = nil
        hardened.timeoutIntervalForRequest = 20
        hardened.timeoutIntervalForResource = 45
        hardened.httpMaximumConnectionsPerHost = 1
        hardened.waitsForConnectivity = false
        self.configuration = hardened
    }

    package func send(_ request: AICueHTTPRequest) async throws -> AICueHTTPResponse {
        guard
            request.method == .get || request.method == .post,
            request.url.scheme?.lowercased() == "https",
            let host = request.url.host?.lowercased(),
            Self.allowedHosts.contains(host),
            (1...(5 * 1_024 * 1_024)).contains(request.maximumResponseBytes)
        else {
            throw AICueHTTPClientError.invalidRequest
        }

        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method.rawValue
        urlRequest.httpBody = request.body
        urlRequest.cachePolicy = .reloadIgnoringLocalCacheData
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        request.credential.withUTF8String { key in
            urlRequest.setValue(key, forHTTPHeaderField: "xi-api-key")
        }

        let runner = AICueBoundedDataTask(
            maximumBytes: request.maximumResponseBytes,
            allowedHosts: Self.allowedHosts)
        let requestConfiguration =
            (configuration.copy() as? URLSessionConfiguration) ?? configuration
        do {
            return try await runner.perform(
                request: urlRequest,
                configuration: requestConfiguration)
        } catch let error as AICueHTTPClientError {
            throw error
        } catch is CancellationError {
            throw AICueHTTPClientError.cancelled
        } catch {
            throw AICueHTTPClientError.transportFailure
        }
    }
}

private final class AICueBoundedDataTask: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let maximumBytes: Int
    private let allowedHosts: Set<String>
    private let lock = NSLock()
    private var body = Data()
    private var response: HTTPURLResponse?
    private var terminalError: AICueHTTPClientError?
    private var continuation: CheckedContinuation<AICueHTTPResponse, Error>?
    private var task: URLSessionDataTask?
    private var session: URLSession?
    private var finished = false

    init(maximumBytes: Int, allowedHosts: Set<String>) {
        self.maximumBytes = maximumBytes
        self.allowedHosts = allowedHosts
        body.reserveCapacity(min(maximumBytes, 512 * 1_024))
    }

    func perform(
        request: URLRequest,
        configuration: URLSessionConfiguration
    ) async throws -> AICueHTTPResponse {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                install(continuation: continuation, request: request, configuration: configuration)
            }
        } onCancel: {
            cancel()
        }
    }

    private func install(
        continuation: CheckedContinuation<AICueHTTPResponse, Error>,
        request: URLRequest,
        configuration: URLSessionConfiguration
    ) {
        lock.lock()
        if finished {
            lock.unlock()
            continuation.resume(throwing: AICueHTTPClientError.cancelled)
            return
        }
        self.continuation = continuation
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        let task = session.dataTask(with: request)
        self.session = session
        self.task = task
        lock.unlock()
        task.resume()
    }

    private func cancel() {
        finish(.failure(.cancelled))
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        lock.lock()
        if !finished { terminalError = .redirectRejected }
        lock.unlock()
        completionHandler(nil)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            lock.lock()
            if !finished { terminalError = .invalidResponse }
            lock.unlock()
            completionHandler(.cancel)
            return
        }
        lock.lock()
        self.response = http
        if http.expectedContentLength > Int64(maximumBytes) {
            terminalError = .responseTooLarge
            lock.unlock()
            completionHandler(.cancel)
            return
        }
        lock.unlock()
        completionHandler(.allow)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        if data.count > maximumBytes - body.count {
            terminalError = .responseTooLarge
            let task = self.task
            lock.unlock()
            task?.cancel()
            return
        }
        body.append(data)
        lock.unlock()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        lock.lock()
        let storedError = terminalError
        let response = self.response
        let body = self.body
        lock.unlock()

        if let storedError {
            finish(.failure(storedError))
            return
        }
        if let error {
            if (error as? URLError)?.code == .cancelled {
                finish(.failure(.cancelled))
            } else {
                finish(.failure(.transportFailure))
            }
            return
        }
        guard
            let response,
            let finalURL = response.url,
            finalURL.scheme?.lowercased() == "https",
            let host = finalURL.host?.lowercased(),
            allowedHosts.contains(host)
        else {
            finish(.failure(.invalidResponse))
            return
        }
        var headers: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            headers[String(describing: key).lowercased()] = String(describing: value)
        }
        finish(
            .success(
                AICueHTTPResponse(
                    statusCode: response.statusCode,
                    headers: headers,
                    body: body,
                    finalURL: finalURL)))
    }

    private func finish(_ result: Result<AICueHTTPResponse, AICueHTTPClientError>) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let continuation = self.continuation
        let task = self.task
        let session = self.session
        self.continuation = nil
        self.task = nil
        self.session = nil
        lock.unlock()

        if case .failure = result { task?.cancel() }
        session?.finishTasksAndInvalidate()
        continuation?.resume(with: result.mapError { $0 as Error })
    }
}
