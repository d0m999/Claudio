import Darwin
import Dispatch
import Foundation

package enum AICueAssetPolicyError: Error, Sendable, Equatable {
    case invalidOrigin
    case invalidMediaType
}

/// A registry-owned, exact HTTPS origin for generated assets. Wildcards, IP literals and
/// non-default ports are intentionally unrepresentable so a provider response cannot widen the
/// download boundary.
package struct AICueAssetOrigin: Hashable, Sendable, CustomReflectable {
    package let hostname: String

    package init(_ literal: String) throws {
        guard
            let components = URLComponents(string: literal),
            components.scheme?.lowercased() == "https",
            let hostname = components.host?.lowercased(),
            components.user == nil,
            components.password == nil,
            components.port == nil || components.port == 443,
            components.percentEncodedPath.isEmpty || components.percentEncodedPath == "/",
            components.percentEncodedQuery == nil,
            components.fragment == nil,
            Self.isValidHostname(hostname)
        else {
            throw AICueAssetPolicyError.invalidOrigin
        }
        self.hostname = hostname
    }

    package var customMirror: Mirror {
        Mirror(
            self,
            children: ["scheme": "https", "hostname": hostname, "port": 443],
            displayStyle: .struct)
    }

    fileprivate func allows(_ url: URL) -> Bool {
        guard
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            components.scheme?.lowercased() == "https",
            components.host?.lowercased() == hostname,
            components.port == nil || components.port == 443,
            components.user == nil,
            components.password == nil,
            components.fragment == nil,
            !components.percentEncodedPath.isEmpty,
            components.percentEncodedPath != "/",
            components.percentEncodedPath.hasPrefix("/"),
            !components.percentEncodedPath.contains("\\"),
            !components.percentEncodedPath.contains("//"),
            url.absoluteString.utf8.count <= 4_096
        else { return false }

        let pathSegments = components.percentEncodedPath.split(separator: "/")
        return pathSegments.allSatisfy { segment in
            let normalized = segment.removingPercentEncoding?.lowercased()
            return normalized != nil && normalized != "." && normalized != ".."
        }
    }

    private static func isValidHostname(_ hostname: String) -> Bool {
        guard
            !hostname.isEmpty,
            !hostname.contains("*"),
            hostname.canBeConverted(to: .ascii),
            hostname.unicodeScalars.allSatisfy({
                CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-")).contains($0)
            }),
            !isIPLiteral(hostname)
        else { return false }
        return hostname.split(separator: ".").allSatisfy { label in
            !label.isEmpty && label.first != "-" && label.last != "-"
        }
    }

    private static func isIPLiteral(_ hostname: String) -> Bool {
        var ipv4 = in_addr()
        var ipv6 = in6_addr()
        return hostname.withCString { inet_pton(AF_INET, $0, &ipv4) == 1 }
            || hostname.withCString { inet_pton(AF_INET6, $0, &ipv6) == 1 }
    }
}

package struct AICueAssetPolicy: Sendable, Equatable, CustomReflectable {
    package let allowedOrigins: Set<AICueAssetOrigin>
    package let acceptedMediaTypes: Set<String>

    package init(
        allowedOrigins: Set<AICueAssetOrigin>,
        acceptedMediaTypes: Set<String>
    ) throws {
        let mediaTypes = Set(acceptedMediaTypes.map { $0.lowercased() })
        guard !allowedOrigins.isEmpty else { throw AICueAssetPolicyError.invalidOrigin }
        guard !mediaTypes.isEmpty, mediaTypes.allSatisfy(Self.isValidMediaType) else {
            throw AICueAssetPolicyError.invalidMediaType
        }
        self.allowedOrigins = allowedOrigins
        self.acceptedMediaTypes = mediaTypes
    }

    package var customMirror: Mirror {
        Mirror(
            self,
            children: [
                "allowedOrigins": allowedOrigins.map(\.hostname).sorted(),
                "acceptedMediaTypes": acceptedMediaTypes.sorted(),
            ],
            displayStyle: .struct)
    }

    fileprivate func allows(_ url: URL) -> Bool {
        allowedOrigins.contains(where: { $0.allows(url) })
    }

    private static func isValidMediaType(_ value: String) -> Bool {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count == 2
            && parts.allSatisfy { !$0.isEmpty }
            && !value.contains(";")
            && !value.contains(" ")
    }
}

package enum AICueAssetFetchError: Error, Sendable, Equatable {
    case invalidURL
    case redirectRejected
    case httpStatus(code: Int, retryAfterSeconds: Int?)
    case unexpectedMediaType
    case responseTooLarge
    case deadlineExceeded
    case cancelled
    case transientNetwork
    case transportFailure
}

package struct AICueFetchedAsset: Sendable, Equatable {
    package let data: Data
    package let mediaType: String

    package init(data: Data, mediaType: String) {
        self.data = data
        self.mediaType = mediaType
    }
}

package protocol AICueAssetFetching: Sendable {
    func fetch(
        _ url: URL,
        policy: AICueAssetPolicy,
        deadline: AICueGenerationDeadline
    ) async throws -> AICueFetchedAsset
}

package protocol AICueAssetLoading: Sendable {
    func load(
        _ request: URLRequest,
        acceptedMediaTypes: Set<String>,
        maximumWireBytes: Int,
        deadline: AICueGenerationDeadline
    ) async throws -> AICueFetchedAsset
}

package protocol AICueAssetRetrySleeping: Sendable {
    func sleep(seconds: Int) async throws
}

private struct AICueAssetSystemRetrySleeper: AICueAssetRetrySleeping {
    func sleep(seconds: Int) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
    }
}

/// Fetches one preflighted asset without credentials. One same-URL retry is permitted only for
/// explicitly transient GET failures; generation POSTs never enter this path.
package struct AICueURLSessionAssetFetcher: AICueAssetFetching, Sendable {
    package static let maximumWireBytes = 5 * 1_024 * 1_024

    private let loader: any AICueAssetLoading
    private let retrySleeper: any AICueAssetRetrySleeping

    package init() {
        loader = AICueURLSessionAssetLoader()
        retrySleeper = AICueAssetSystemRetrySleeper()
    }

    package init(
        loader: any AICueAssetLoading,
        retrySleeper: any AICueAssetRetrySleeping
    ) {
        self.loader = loader
        self.retrySleeper = retrySleeper
    }

    package func fetch(
        _ url: URL,
        policy: AICueAssetPolicy,
        deadline: AICueGenerationDeadline
    ) async throws -> AICueFetchedAsset {
        let request = try Self.request(url: url, policy: policy, deadline: deadline)
        do {
            return try await loader.load(
                request,
                acceptedMediaTypes: policy.acceptedMediaTypes,
                maximumWireBytes: Self.maximumWireBytes,
                deadline: deadline)
        } catch let error as AICueAssetFetchError where Self.isRetryable(error) {
            let delay = Self.retryDelay(for: error)
            if delay > 0 {
                guard
                    let remaining = deadline.remainingNanoseconds(
                        at: DispatchTime.now().uptimeNanoseconds),
                    remaining > UInt64(delay) * 1_000_000_000
                else { throw AICueAssetFetchError.deadlineExceeded }
                try await retrySleeper.sleep(seconds: delay)
            }
            try Task.checkCancellation()
            guard
                deadline.remainingNanoseconds(at: DispatchTime.now().uptimeNanoseconds) != nil
            else { throw AICueAssetFetchError.deadlineExceeded }
            return try await loader.load(
                request,
                acceptedMediaTypes: policy.acceptedMediaTypes,
                maximumWireBytes: Self.maximumWireBytes,
                deadline: deadline)
        } catch is CancellationError {
            throw AICueAssetFetchError.cancelled
        }
    }

    package static func request(
        url: URL,
        policy: AICueAssetPolicy,
        deadline: AICueGenerationDeadline
    ) throws -> URLRequest {
        guard
            policy.allows(url),
            deadline.remainingNanoseconds(at: DispatchTime.now().uptimeNanoseconds) != nil
        else {
            if deadline.remainingNanoseconds(at: DispatchTime.now().uptimeNanoseconds) == nil {
                throw AICueAssetFetchError.deadlineExceeded
            }
            throw AICueAssetFetchError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = AICueHTTPMethod.get.rawValue
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        request.setValue(
            policy.acceptedMediaTypes.sorted().joined(separator: ", "),
            forHTTPHeaderField: "Accept")
        return request
    }

    private static func isRetryable(_ error: AICueAssetFetchError) -> Bool {
        switch error {
        case .transientNetwork:
            return true
        case .httpStatus(let code, let retryAfter):
            if code == 408 || (500...599).contains(code) { return true }
            return code == 429 && retryAfter.map { (1...5).contains($0) } == true
        case .invalidURL, .redirectRejected, .unexpectedMediaType, .responseTooLarge,
            .deadlineExceeded, .cancelled, .transportFailure:
            return false
        }
    }

    private static func retryDelay(for error: AICueAssetFetchError) -> Int {
        if case .httpStatus(429, let retryAfter?) = error, (1...5).contains(retryAfter) {
            return retryAfter
        }
        return 0
    }
}

package actor AICueURLSessionAssetLoader: AICueAssetLoading {
    private let configuration: URLSessionConfiguration
    private let timeouts: AICueTransportTimeouts

    package init(
        configuration: URLSessionConfiguration? = nil,
        timeouts: AICueTransportTimeouts = AICueTransportTimeouts()
    ) {
        let hardened = AICueTransportSessionConfiguration.hardened(
            from: configuration,
            timeouts: timeouts)
        hardened.httpAdditionalHeaders = [:]
        hardened.httpShouldSetCookies = false
        hardened.httpCookieAcceptPolicy = .never
        hardened.httpCookieStorage = nil
        hardened.urlCache = nil
        hardened.urlCredentialStorage = nil
        hardened.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.configuration = hardened
        self.timeouts = timeouts
    }

    package func load(
        _ request: URLRequest,
        acceptedMediaTypes: Set<String>,
        maximumWireBytes: Int,
        deadline: AICueGenerationDeadline
    ) async throws -> AICueFetchedAsset {
        guard
            timeouts.isValid,
            request.httpMethod == AICueHTTPMethod.get.rawValue,
            request.httpBody == nil,
            request.value(forHTTPHeaderField: "Authorization") == nil,
            request.value(forHTTPHeaderField: "Cookie") == nil,
            request.value(forHTTPHeaderField: "Referer") == nil,
            let url = request.url,
            (1...AICueURLSessionAssetFetcher.maximumWireBytes).contains(maximumWireBytes)
        else { throw AICueAssetFetchError.invalidURL }

        let task = AICueAssetDataTask(
            expectedURL: url,
            acceptedMediaTypes: acceptedMediaTypes,
            maximumWireBytes: maximumWireBytes,
            deadline: deadline,
            timeouts: timeouts)
        let sessionConfiguration =
            (configuration.copy() as? URLSessionConfiguration) ?? configuration
        return try await task.perform(request: request, configuration: sessionConfiguration)
    }
}

private final class AICueAssetDataTask: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let expectedURL: URL
    private let acceptedMediaTypes: Set<String>
    private let maximumWireBytes: Int
    private let deadline: AICueGenerationDeadline
    private let timeouts: AICueTransportTimeouts
    private let lock = NSLock()
    private var body = Data()
    private var mediaType = ""
    private var terminalError: AICueAssetFetchError?
    private var continuation: CheckedContinuation<AICueFetchedAsset, Error>?
    private var task: URLSessionDataTask?
    private var session: URLSession?
    private var inactivityTimer: DispatchWorkItem?
    private var deadlineTimer: DispatchWorkItem?
    private var finished = false

    init(
        expectedURL: URL,
        acceptedMediaTypes: Set<String>,
        maximumWireBytes: Int,
        deadline: AICueGenerationDeadline,
        timeouts: AICueTransportTimeouts
    ) {
        self.expectedURL = expectedURL
        self.acceptedMediaTypes = acceptedMediaTypes
        self.maximumWireBytes = maximumWireBytes
        self.deadline = deadline
        self.timeouts = timeouts
        body.reserveCapacity(min(maximumWireBytes, 512 * 1_024))
    }

    func perform(
        request: URLRequest,
        configuration: URLSessionConfiguration
    ) async throws -> AICueFetchedAsset {
        do {
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    install(
                        continuation: continuation,
                        request: request,
                        configuration: configuration)
                }
            } onCancel: {
                self.finish(.failure(.cancelled))
            }
        } catch let error as AICueAssetFetchError {
            throw error
        } catch is CancellationError {
            throw AICueAssetFetchError.cancelled
        } catch {
            throw AICueAssetFetchError.transportFailure
        }
    }

    private func install(
        continuation: CheckedContinuation<AICueFetchedAsset, Error>,
        request: URLRequest,
        configuration: URLSessionConfiguration
    ) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            continuation.resume(throwing: AICueAssetFetchError.cancelled)
            return
        }
        self.continuation = continuation
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        let task = session.dataTask(with: request)
        self.session = session
        self.task = task
        armDeadlineLocked()
        let expired = terminalError == .deadlineExceeded
        if !expired { armInactivityLocked(seconds: timeouts.connectionSeconds) }
        lock.unlock()
        if expired {
            finish(.failure(.deadlineExceeded))
        } else {
            task.resume()
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
        finish(.failure(.redirectRejected))
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse, http.url == expectedURL else {
            completionHandler(.cancel)
            finish(.failure(.redirectRejected))
            return
        }
        guard !(300..<400).contains(http.statusCode) else {
            completionHandler(.cancel)
            finish(.failure(.redirectRejected))
            return
        }
        guard (200..<300).contains(http.statusCode) else {
            let rawRetryAfter = http.value(forHTTPHeaderField: "retry-after").flatMap { value in
                Int(value)
            }
            let retryAfter = rawRetryAfter.flatMap { value in
                (1...300).contains(value) ? value : nil
            }
            completionHandler(.cancel)
            finish(
                .failure(
                    .httpStatus(
                        code: http.statusCode,
                        retryAfterSeconds: retryAfter)))
            return
        }
        let normalizedMediaType = AICueTransportRequestBuilder.normalizedMediaType(
            http.value(forHTTPHeaderField: "content-type"))
        guard acceptedMediaTypes.contains(normalizedMediaType) else {
            completionHandler(.cancel)
            finish(.failure(.unexpectedMediaType))
            return
        }
        if response.expectedContentLength > Int64(maximumWireBytes) {
            completionHandler(.cancel)
            finish(.failure(.responseTooLarge))
            return
        }
        lock.lock()
        guard !finished else {
            lock.unlock()
            completionHandler(.cancel)
            return
        }
        mediaType = normalizedMediaType
        armInactivityLocked(seconds: timeouts.inactivitySeconds)
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
        guard data.count <= maximumWireBytes - body.count else {
            terminalError = .responseTooLarge
            let task = self.task
            lock.unlock()
            task?.cancel()
            return
        }
        body.append(data)
        armInactivityLocked(seconds: timeouts.inactivitySeconds)
        lock.unlock()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        lock.lock()
        let storedError = terminalError
        let body = self.body
        let mediaType = self.mediaType
        lock.unlock()

        if let storedError {
            finish(.failure(storedError))
            return
        }
        if let urlError = error as? URLError {
            if urlError.code == .cancelled {
                finish(.failure(.cancelled))
            } else if Self.isTransient(urlError.code) {
                finish(.failure(.transientNetwork))
            } else {
                finish(.failure(.transportFailure))
            }
            return
        }
        if error != nil {
            finish(.failure(.transportFailure))
            return
        }
        guard !mediaType.isEmpty else {
            finish(.failure(.transportFailure))
            return
        }
        finish(.success(AICueFetchedAsset(data: body, mediaType: mediaType)))
    }

    private static func isTransient(_ code: URLError.Code) -> Bool {
        switch code {
        case .timedOut, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
            .networkConnectionLost, .notConnectedToInternet:
            return true
        default:
            return false
        }
    }

    private func armDeadlineLocked() {
        deadlineTimer?.cancel()
        guard
            let remaining = deadline.remainingNanoseconds(
                at: DispatchTime.now().uptimeNanoseconds)
        else {
            terminalError = .deadlineExceeded
            return
        }
        let timer = DispatchWorkItem { [weak self] in
            self?.timeout(.deadlineExceeded)
        }
        deadlineTimer = timer
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + .nanoseconds(Int(clamping: remaining)),
            execute: timer)
    }

    private func armInactivityLocked(seconds: TimeInterval) {
        inactivityTimer?.cancel()
        let timer = DispatchWorkItem { [weak self] in
            self?.timeout(.transientNetwork)
        }
        inactivityTimer = timer
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + seconds,
            execute: timer)
    }

    private func timeout(_ error: AICueAssetFetchError) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        if terminalError == nil { terminalError = error }
        let task = self.task
        lock.unlock()
        task?.cancel()
    }

    private func finish(_ result: Result<AICueFetchedAsset, AICueAssetFetchError>) {
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
        inactivityTimer?.cancel()
        deadlineTimer?.cancel()
        inactivityTimer = nil
        deadlineTimer = nil
        lock.unlock()

        if case .failure = result { task?.cancel() }
        session?.finishTasksAndInvalidate()
        continuation?.resume(with: result.mapError { $0 as Error })
    }
}
