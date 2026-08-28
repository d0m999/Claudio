import Dispatch
import Foundation

package struct AICueSSEEvent: Sendable, Equatable {
    package let dataLines: [String]

    package init(dataLines: [String]) {
        self.dataLines = dataLines
    }

    package var data: String {
        dataLines.joined(separator: "\n")
    }
}

/// Incremental SSE framing only. Provider JSON and terminal semantics remain adapter concerns, so
/// callback boundaries can never become accidental JSON/Base64 boundaries.
package struct AICueSSEParser: Sendable {
    private let maximumWireBytes: Int
    private var wireBytes = 0
    private var lineBuffer = Data()
    private var dataLines: [String] = []
    private var isFinished = false

    package init(maximumWireBytes: Int) {
        self.maximumWireBytes = maximumWireBytes
        lineBuffer.reserveCapacity(min(maximumWireBytes, 16 * 1_024))
    }

    package mutating func append(_ chunk: Data) throws -> [AICueSSEEvent] {
        var events: [AICueSSEEvent] = []
        try append(chunk) { events.append($0) }
        return events
    }

    package mutating func append(
        _ chunk: Data,
        onEvent: (AICueSSEEvent) throws -> Void
    ) throws {
        guard !isFinished, maximumWireBytes > 0 else {
            throw AICueTransportError.invalidRequest
        }
        guard chunk.count <= maximumWireBytes - wireBytes else {
            throw AICueTransportError.responseTooLarge
        }
        wireBytes += chunk.count
        lineBuffer.append(chunk)

        while let newline = lineBuffer.firstIndex(of: 0x0A) {
            var bytes = Data(lineBuffer[..<newline])
            lineBuffer.removeSubrange(...newline)
            if bytes.last == 0x0D { bytes.removeLast() }
            guard let line = String(data: bytes, encoding: .utf8) else {
                throw AICueTransportError.invalidResponse
            }
            if let event = process(line: line) { try onEvent(event) }
        }
    }

    package mutating func finish() throws -> [AICueSSEEvent] {
        guard !isFinished else { throw AICueTransportError.invalidResponse }
        isFinished = true
        // A provider response is security-sensitive acquisition, not a browser EventSource. EOF
        // cannot promote a partial line/event into a complete terminal event: every event must be
        // closed by an explicit blank line before the connection ends.
        guard lineBuffer.isEmpty, dataLines.isEmpty else {
            throw AICueTransportError.invalidResponse
        }
        return []
    }

    private mutating func process(line: String) -> AICueSSEEvent? {
        if line.isEmpty {
            guard !dataLines.isEmpty else { return nil }
            defer { dataLines.removeAll(keepingCapacity: true) }
            return AICueSSEEvent(dataLines: dataLines)
        }
        guard !line.hasPrefix(":") else { return nil }
        let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.first == "data" else { return nil }
        var value = parts.count == 2 ? String(parts[1]) : ""
        if value.hasPrefix(" ") { value.removeFirst() }
        dataLines.append(value)
        return nil
    }
}

package enum AICueSSESequenceError: Error, Sendable, Equatable {
    case terminalMissing
    case duplicateTerminal
    case dataAfterTerminal
}

/// Adapters classify their own terminal JSON and feed only that boolean into this provider-neutral
/// lifecycle guard. It makes duplicate/post-terminal/EOF behavior identical for every SSE adapter.
package struct AICueSSETerminalValidator: Sendable {
    private var sawTerminal = false

    package init() {}

    package mutating func accept(isTerminal: Bool) throws {
        if sawTerminal {
            throw isTerminal
                ? AICueSSESequenceError.duplicateTerminal
                : AICueSSESequenceError.dataAfterTerminal
        }
        if isTerminal { sawTerminal = true }
    }

    package func finish() throws {
        guard sawTerminal else { throw AICueSSESequenceError.terminalMissing }
    }
}

package protocol AICueSSETransport: Sendable {
    func events(
        for request: AICueTransportRequest,
        authentication: AICueProviderAuthentication,
        credential: SensitiveCredentialInput
    ) -> AsyncThrowingStream<AICueSSEEvent, Error>
}

/// Streaming URLSession transport. It yields framed events as callbacks arrive and never creates a
/// whole-stream Data buffer.
package final class AICueURLSessionSSETransport: AICueSSETransport, @unchecked Sendable {
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

    package func events(
        for request: AICueTransportRequest,
        authentication: AICueProviderAuthentication,
        credential: SensitiveCredentialInput
    ) -> AsyncThrowingStream<AICueSSEEvent, Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingOldest(16)) { continuation in
            guard timeouts.isValid else {
                continuation.finish(throwing: AICueTransportError.invalidRequest)
                return
            }
            let urlRequest: URLRequest
            do {
                urlRequest = try AICueTransportRequestBuilder.authenticatedURLRequest(
                    from: request,
                    authentication: authentication,
                    credential: credential)
            } catch {
                continuation.finish(throwing: error)
                return
            }

            let runner = AICueSSEDataTask(
                transportRequest: request,
                timeouts: timeouts,
                continuation: continuation)
            continuation.onTermination = { @Sendable _ in runner.cancel() }
            let sessionConfiguration =
                (configuration.copy() as? URLSessionConfiguration) ?? configuration
            runner.start(request: urlRequest, configuration: sessionConfiguration)
        }
    }
}

private final class AICueSSEDataTask: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let transportRequest: AICueTransportRequest
    private let timeouts: AICueTransportTimeouts
    private let continuation: AsyncThrowingStream<AICueSSEEvent, Error>.Continuation
    private let lock = NSLock()
    private var parser: AICueSSEParser
    private var terminalError: AICueTransportError?
    private var task: URLSessionDataTask?
    private var session: URLSession?
    private var inactivityTimer: DispatchWorkItem?
    private var deadlineTimer: DispatchWorkItem?
    private var finished = false

    init(
        transportRequest: AICueTransportRequest,
        timeouts: AICueTransportTimeouts,
        continuation: AsyncThrowingStream<AICueSSEEvent, Error>.Continuation
    ) {
        self.transportRequest = transportRequest
        self.timeouts = timeouts
        self.continuation = continuation
        parser = AICueSSEParser(maximumWireBytes: transportRequest.maximumWireBytes)
    }

    func start(request: URLRequest, configuration: URLSessionConfiguration) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            continuation.finish(throwing: AICueTransportError.cancelled)
            return
        }
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
            finish(.deadlineExceeded)
        } else {
            task.resume()
        }
    }

    func cancel() {
        finish(.cancelled)
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
        finish(.redirectRejected)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        do {
            _ = try AICueTransportResponseValidator.validate(
                response,
                for: transportRequest)
        } catch let error as AICueTransportError {
            store(error: error)
            completionHandler(.cancel)
            finish(error)
            return
        } catch {
            store(error: .invalidResponse)
            completionHandler(.cancel)
            finish(.invalidResponse)
            return
        }
        lock.lock()
        guard !finished else {
            lock.unlock()
            completionHandler(.cancel)
            return
        }
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
        do {
            try parser.append(data) { event in
                try yield(event)
            }
        } catch let error as AICueTransportError {
            terminalError = error
            let task = self.task
            lock.unlock()
            task?.cancel()
            return
        } catch {
            terminalError = .invalidResponse
            let task = self.task
            lock.unlock()
            task?.cancel()
            return
        }
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
        let finalEvents: [AICueSSEEvent]
        do {
            finalEvents = storedError == nil ? try parser.finish() : []
        } catch let error as AICueTransportError {
            lock.unlock()
            finish(error)
            return
        } catch {
            lock.unlock()
            finish(.invalidResponse)
            return
        }
        lock.unlock()

        if let storedError {
            finish(storedError)
            return
        }
        if let error {
            if (error as? URLError)?.code == .cancelled {
                finish(.cancelled)
            } else if (error as? URLError)?.code == .timedOut {
                finish(.inactivityTimeout)
            } else {
                finish(.transportFailure)
            }
            return
        }
        for event in finalEvents {
            do {
                try yield(event)
            } catch let error as AICueTransportError {
                finish(error)
                return
            } catch {
                finish(.transportFailure)
                return
            }
        }
        finish(nil)
    }

    private func store(error: AICueTransportError) {
        lock.lock()
        if !finished { terminalError = error }
        lock.unlock()
    }

    private func armDeadlineLocked() {
        guard
            let remaining = transportRequest.deadline.remainingNanoseconds(
                at: DispatchTime.now().uptimeNanoseconds)
        else {
            terminalError = .deadlineExceeded
            return
        }
        let timer = DispatchWorkItem { [weak self] in
            self?.finish(.deadlineExceeded)
        }
        deadlineTimer = timer
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + .nanoseconds(Int(clamping: remaining)),
            execute: timer)
    }

    private func armInactivityLocked(seconds: TimeInterval) {
        inactivityTimer?.cancel()
        let timer = DispatchWorkItem { [weak self] in
            self?.finish(.inactivityTimeout)
        }
        inactivityTimer = timer
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + seconds,
            execute: timer)
    }

    private func yield(_ event: AICueSSEEvent) throws {
        switch continuation.yield(event) {
        case .enqueued:
            return
        case .dropped:
            throw AICueTransportError.backpressureExceeded
        case .terminated:
            throw AICueTransportError.cancelled
        @unknown default:
            throw AICueTransportError.transportFailure
        }
    }

    private func finish(_ error: AICueTransportError?) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let task = self.task
        let session = self.session
        self.task = nil
        self.session = nil
        inactivityTimer?.cancel()
        deadlineTimer?.cancel()
        inactivityTimer = nil
        deadlineTimer = nil
        lock.unlock()

        if error != nil { task?.cancel() }
        session?.finishTasksAndInvalidate()
        if let error {
            continuation.finish(throwing: error)
        } else {
            continuation.finish()
        }
    }
}
