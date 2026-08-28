import Dispatch
import Foundation

package struct AICueTransportTimeouts: Sendable, Equatable {
    package let connectionSeconds: TimeInterval
    package let inactivitySeconds: TimeInterval

    package init(connectionSeconds: TimeInterval = 10, inactivitySeconds: TimeInterval = 20) {
        self.connectionSeconds = connectionSeconds
        self.inactivitySeconds = inactivitySeconds
    }

    package var isValid: Bool {
        connectionSeconds.isFinite && connectionSeconds > 0
            && inactivitySeconds.isFinite && inactivitySeconds > 0
    }
}

/// Ephemeral, cookie/cache/credential-free unary transport. Credentials exist only while building
/// the one authenticated URLRequest after the complete origin/path policy has passed.
package actor AICueURLSessionUnaryTransport: AICueUnaryTransport {
    private let configuration: URLSessionConfiguration
    private let timeouts: AICueTransportTimeouts

    package init(
        configuration: URLSessionConfiguration? = nil,
        timeouts: AICueTransportTimeouts = AICueTransportTimeouts()
    ) {
        self.configuration = AICueTransportSessionConfiguration.hardened(
            from: configuration,
            timeouts: timeouts)
        self.timeouts = timeouts
    }

    package func send(
        _ request: AICueTransportRequest,
        authentication: AICueProviderAuthentication,
        credential: SensitiveCredentialInput
    ) async throws -> AICueHTTPResponse {
        guard timeouts.isValid else { throw AICueTransportError.invalidRequest }
        let urlRequest = try AICueTransportRequestBuilder.authenticatedURLRequest(
            from: request,
            authentication: authentication,
            credential: credential)
        let runner = AICueUnaryDataTask(
            transportRequest: request,
            timeouts: timeouts)
        let sessionConfiguration =
            (configuration.copy() as? URLSessionConfiguration) ?? configuration
        do {
            return try await runner.perform(
                request: urlRequest,
                configuration: sessionConfiguration)
        } catch let error as AICueTransportError {
            throw error
        } catch is CancellationError {
            throw AICueTransportError.cancelled
        } catch {
            throw AICueTransportError.transportFailure
        }
    }
}

private final class AICueUnaryDataTask: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let transportRequest: AICueTransportRequest
    private let timeouts: AICueTransportTimeouts
    private let lock = NSLock()
    private var body = Data()
    private var response: HTTPURLResponse?
    private var terminalError: AICueTransportError?
    private var continuation: CheckedContinuation<AICueHTTPResponse, Error>?
    private var task: URLSessionDataTask?
    private var session: URLSession?
    private var inactivityTimer: DispatchWorkItem?
    private var deadlineTimer: DispatchWorkItem?
    private var finished = false

    init(transportRequest: AICueTransportRequest, timeouts: AICueTransportTimeouts) {
        self.transportRequest = transportRequest
        self.timeouts = timeouts
        body.reserveCapacity(min(transportRequest.maximumWireBytes, 512 * 1_024))
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
            finish(.failure(.cancelled))
        }
    }

    private func install(
        continuation: CheckedContinuation<AICueHTTPResponse, Error>,
        request: URLRequest,
        configuration: URLSessionConfiguration
    ) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            continuation.resume(throwing: AICueTransportError.cancelled)
            return
        }
        self.continuation = continuation
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        let task = session.dataTask(with: request)
        self.session = session
        self.task = task
        armDeadlineLocked()
        let deadlineAlreadyExpired = terminalError == .deadlineExceeded
        if !deadlineAlreadyExpired {
            armInactivityLocked(seconds: timeouts.connectionSeconds)
        }
        lock.unlock()
        if deadlineAlreadyExpired {
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
        lock.lock()
        if !finished { terminalError = .redirectRejected }
        lock.unlock()
        completionHandler(nil)
        finish(.failure(.redirectRejected))
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        let http: HTTPURLResponse
        do {
            http = try AICueTransportResponseValidator.validate(
                response,
                for: transportRequest)
        } catch let error as AICueTransportError {
            store(error: error)
            completionHandler(.cancel)
            finish(.failure(error))
            return
        } catch {
            store(error: .invalidResponse)
            completionHandler(.cancel)
            finish(.failure(.invalidResponse))
            return
        }
        lock.lock()
        guard !finished else {
            lock.unlock()
            completionHandler(.cancel)
            return
        }
        self.response = http
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
        guard data.count <= transportRequest.maximumWireBytes - body.count else {
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
            } else if (error as? URLError)?.code == .timedOut {
                finish(.failure(.inactivityTimeout))
            } else {
                finish(.failure(.transportFailure))
            }
            return
        }
        guard let response, response.url == transportRequest.url else {
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
                    finalURL: transportRequest.url)))
    }

    private func store(error: AICueTransportError) {
        lock.lock()
        if !finished { terminalError = error }
        lock.unlock()
    }

    private func armDeadlineLocked() {
        deadlineTimer?.cancel()
        guard
            let remaining = transportRequest.deadline.remainingNanoseconds(
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
            self?.timeout(.inactivityTimeout)
        }
        inactivityTimer = timer
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + seconds,
            execute: timer)
    }

    private func timeout(_ error: AICueTransportError) {
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

    private func finish(_ result: Result<AICueHTTPResponse, AICueTransportError>) {
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
