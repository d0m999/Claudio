import ClaudioGUICore
import Dispatch
import Foundation

private actor AICueAssetLoaderFixture: AICueAssetLoading {
    private var results: [Result<AICueFetchedAsset, Error>]
    private var requests: [URLRequest] = []
    private var deadlines: [AICueGenerationDeadline] = []

    init(_ results: [Result<AICueFetchedAsset, AICueAssetFetchError>]) {
        self.results = results.map { result in result.mapError { $0 as Error } }
    }

    init(rawResults: [Result<AICueFetchedAsset, Error>]) {
        results = rawResults
    }

    func load(
        _ request: URLRequest,
        acceptedMediaTypes: Set<String>,
        maximumWireBytes: Int,
        deadline: AICueGenerationDeadline
    ) throws -> AICueFetchedAsset {
        requests.append(request)
        deadlines.append(deadline)
        guard !results.isEmpty else { throw AICueAssetFetchError.transportFailure }
        return try results.removeFirst().get()
    }

    func facts() -> [URLRequest] { requests }
    func observedDeadlines() -> [AICueGenerationDeadline] { deadlines }
}

private actor AICueAssetSleeperFixture: AICueAssetRetrySleeping {
    private var delays: [Int] = []

    func sleep(seconds: Int) {
        delays.append(seconds)
    }

    func facts() -> [Int] { delays }
}

private actor AICueAssetBlockingSleeperFixture: AICueAssetRetrySleeping {
    private var delays: [Int] = []
    private var entered = false

    func sleep(seconds: Int) async throws {
        delays.append(seconds)
        entered = true
        let boundedSeconds = min(max(seconds, 1), 5)
        try await Task.sleep(nanoseconds: UInt64(boundedSeconds) * 1_000_000_000)
    }

    nonisolated func waitUntilEntered(
        timeoutNanoseconds: UInt64 = 10_000_000_000
    ) async -> Bool {
        let start = DispatchTime.now().uptimeNanoseconds
        while DispatchTime.now().uptimeNanoseconds &- start < timeoutNanoseconds {
            if await hasEntered() { return true }
            do {
                try await Task.sleep(nanoseconds: 10_000_000)
            } catch {
                return false
            }
        }
        return await hasEntered()
    }

    private func hasEntered() -> Bool { entered }
    func facts() -> [Int] { delays }
}

private actor AICueAssetStartGate {
    private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var arrived = false
    private var released = false

    func wait() async {
        arrived = true
        let waiters = arrivalWaiters
        arrivalWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        if released { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilArrived() async {
        if arrived { return }
        await withCheckedContinuation { arrivalWaiters.append($0) }
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}

private enum AICueControlledAssetProtocolStep {
    case http(
        statusCode: Int,
        headers: [String: String],
        responseURL: URL?,
        chunks: [Data]
    )
    case nonHTTP(data: Data)
    case redirect(target: URL)
    case failure(URLError.Code)
    case failureAtDeadline(URLError.Code, UInt64)
    case hold
    case delayedHTTP(
        headers: [String: String],
        firstChunk: Data,
        delayedChunk: Data,
        delayNanoseconds: UInt64
    )
}

private struct AICueControlledAssetProtocolFacts {
    let requests: [URLRequest]
    let stoppedAttempts: Int
    let maximumInFlight: Int
    let suppressedLateChunks: Int
}

private final class AICueControlledAssetProtocolControl: @unchecked Sendable {
    private struct RequestWaiter {
        let count: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private let lock = NSLock()
    private var steps: [AICueControlledAssetProtocolStep] = []
    private var requests: [URLRequest] = []
    private var stoppedAttempts = 0
    private var inFlight = 0
    private var maximumInFlight = 0
    private var suppressedLateChunks = 0
    private var requestWaiters: [RequestWaiter] = []
    private var stoppedAttemptWaiters: [CheckedContinuation<Void, Never>] = []
    private var lateChunkWaiters: [CheckedContinuation<Void, Never>] = []

    func reset(_ steps: [AICueControlledAssetProtocolStep]) {
        lock.withLock {
            self.steps = steps
            requests.removeAll()
            stoppedAttempts = 0
            inFlight = 0
            maximumInFlight = 0
            suppressedLateChunks = 0
            requestWaiters.removeAll()
            stoppedAttemptWaiters.removeAll()
            lateChunkWaiters.removeAll()
        }
    }

    func begin(_ request: URLRequest) -> AICueControlledAssetProtocolStep {
        let result: (AICueControlledAssetProtocolStep, [CheckedContinuation<Void, Never>]) =
            lock.withLock {
                requests.append(request)
                inFlight += 1
                maximumInFlight = max(maximumInFlight, inFlight)
                let step = steps.isEmpty ? .failure(.badServerResponse) : steps.removeFirst()
                let ready = requestWaiters.filter { requests.count >= $0.count }
                requestWaiters.removeAll { requests.count >= $0.count }
                return (step, ready.map(\.continuation))
            }
        for waiter in result.1 { waiter.resume() }
        return result.0
    }

    func finish(stopped: Bool) {
        let waiters = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            inFlight = max(0, inFlight - 1)
            guard stopped else { return [] }
            stoppedAttempts += 1
            let waiters = stoppedAttemptWaiters
            stoppedAttemptWaiters.removeAll()
            return waiters
        }
        for waiter in waiters { waiter.resume() }
    }

    func recordSuppressedLateChunk() {
        let waiters = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            suppressedLateChunks += 1
            let waiters = lateChunkWaiters
            lateChunkWaiters.removeAll()
            return waiters
        }
        for waiter in waiters { waiter.resume() }
    }

    func waitForRequestCount(_ count: Int) async {
        await withCheckedContinuation { continuation in
            let shouldResume = lock.withLock { () -> Bool in
                if requests.count >= count { return true }
                requestWaiters.append(RequestWaiter(count: count, continuation: continuation))
                return false
            }
            if shouldResume { continuation.resume() }
        }
    }

    func waitForSuppressedLateChunk() async {
        await withCheckedContinuation { continuation in
            let shouldResume = lock.withLock { () -> Bool in
                if suppressedLateChunks > 0 { return true }
                lateChunkWaiters.append(continuation)
                return false
            }
            if shouldResume { continuation.resume() }
        }
    }

    func waitForStoppedAttempt() async {
        await withCheckedContinuation { continuation in
            let shouldResume = lock.withLock { () -> Bool in
                if stoppedAttempts > 0 { return true }
                stoppedAttemptWaiters.append(continuation)
                return false
            }
            if shouldResume { continuation.resume() }
        }
    }

    func facts() -> AICueControlledAssetProtocolFacts {
        lock.withLock {
            AICueControlledAssetProtocolFacts(
                requests: requests,
                stoppedAttempts: stoppedAttempts,
                maximumInFlight: maximumInFlight,
                suppressedLateChunks: suppressedLateChunks)
        }
    }
}

private final class AICueControlledAssetURLProtocol: URLProtocol, @unchecked Sendable {
    static let control = AICueControlledAssetProtocolControl()

    private let stateLock = NSLock()
    private var attemptFinished = false

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let step = Self.control.begin(request)
        switch step {
        case .http(let statusCode, let headers, let responseURL, let chunks):
            sendHTTP(
                statusCode: statusCode,
                headers: headers,
                responseURL: responseURL ?? request.url!,
                chunks: chunks)
        case .nonHTTP(let data):
            let response = URLResponse(
                url: request.url!,
                mimeType: "audio/mpeg",
                expectedContentLength: data.count,
                textEncodingName: nil)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
            finishAttempt(stopped: false)
        case .redirect(let target):
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 302,
                httpVersion: "HTTP/1.1",
                headerFields: ["location": target.absoluteString])!
            client?.urlProtocol(
                self,
                wasRedirectedTo: URLRequest(url: target),
                redirectResponse: response)
        case .failure(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
            finishAttempt(stopped: false)
        case .failureAtDeadline(let code, let uptimeNanoseconds):
            // Deliver a Foundation-style timeout at the caller's absolute boundary, independent
            // of how promptly the loader's utility-queue deadline work item gets scheduled.
            let now = DispatchTime.now().uptimeNanoseconds
            if now < uptimeNanoseconds, uptimeNanoseconds - now > 500_000 {
                Thread.sleep(
                    forTimeInterval: Double(uptimeNanoseconds - now - 500_000) / 1_000_000_000)
            }
            while DispatchTime.now().uptimeNanoseconds < uptimeNanoseconds {}
            guard stateLock.withLock({ !attemptFinished }) else { return }
            client?.urlProtocol(self, didFailWithError: URLError(code))
            finishAttempt(stopped: false)
        case .hold:
            break
        case .delayedHTTP(let headers, let firstChunk, let delayedChunk, let nanoseconds):
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: firstChunk)
            DispatchQueue.global(qos: .utility).asyncAfter(
                deadline: .now() + .nanoseconds(Int(clamping: nanoseconds))
            ) { [self] in
                sendDelayedChunk(delayedChunk)
            }
        }
    }

    override func stopLoading() {
        finishAttempt(stopped: true)
    }

    private func sendHTTP(
        statusCode: Int,
        headers: [String: String],
        responseURL: URL,
        chunks: [Data]
    ) {
        let response = HTTPURLResponse(
            url: responseURL,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for chunk in chunks { client?.urlProtocol(self, didLoad: chunk) }
        client?.urlProtocolDidFinishLoading(self)
        finishAttempt(stopped: false)
    }

    private func sendDelayedChunk(_ data: Data) {
        let isActive = stateLock.withLock { !attemptFinished }
        guard isActive else {
            Self.control.recordSuppressedLateChunk()
            return
        }
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
        finishAttempt(stopped: false)
    }

    private func finishAttempt(stopped: Bool) {
        let shouldFinish = stateLock.withLock { () -> Bool in
            guard !attemptFinished else { return false }
            attemptFinished = true
            return true
        }
        if shouldFinish { Self.control.finish(stopped: stopped) }
    }
}

private final class AICueAssetURLProtocol: URLProtocol, @unchecked Sendable {
    static let recorder = AICueAssetRequestRecorder()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.recorder.record(request)
        let path = request.url?.path ?? ""
        if path == "/redirect.mp3" {
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 302,
                httpVersion: "HTTP/1.1",
                headerFields: ["location": "https://harvest.invalid/asset.mp3"])!
            client?.urlProtocol(
                self,
                wasRedirectedTo: URLRequest(url: URL(string: "https://harvest.invalid/asset.mp3")!),
                redirectResponse: response)
            return
        }
        let mediaType = path == "/wrong.mp3" ? "text/html" : "audio/mpeg"
        let body =
            path == "/large.mp3"
            ? Data(repeating: 0x61, count: 9) : Data([0x49, 0x44, 0x33])
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["content-type": mediaType])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class AICueAssetRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []

    func reset() { lock.withLock { requests.removeAll() } }
    func record(_ request: URLRequest) { lock.withLock { requests.append(request) } }
    func facts() -> [URLRequest] { lock.withLock { requests } }
}

private func fixtureAssetPolicy() -> AICueAssetPolicy {
    try! AICueAssetPolicy(
        allowedOrigins: [try! AICueAssetOrigin("https://assets.fixture.invalid")],
        acceptedMediaTypes: ["audio/mpeg"])
}

private func controlledAssetLoader(
    connectionSeconds: TimeInterval = 1,
    inactivitySeconds: TimeInterval = 1
) -> AICueURLSessionAssetLoader {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [AICueControlledAssetURLProtocol.self]
    configuration.httpAdditionalHeaders = [
        "Authorization": "Bearer stale-fixture",
        "Cookie": "stale=1",
        "Referer": "https://stale.fixture.invalid",
    ]
    return AICueURLSessionAssetLoader(
        configuration: configuration,
        timeouts: AICueTransportTimeouts(
            connectionSeconds: connectionSeconds,
            inactivitySeconds: inactivitySeconds))
}

private func controlledAssetSuccessStep(
    data: Data = Data([0x49, 0x44, 0x33]),
    headers: [String: String] = ["content-type": "audio/mpeg"]
) -> AICueControlledAssetProtocolStep {
    .http(statusCode: 200, headers: headers, responseURL: nil, chunks: [data])
}

private func controlledAssetHTTPErrorStep(
    _ statusCode: Int,
    retryAfter: String? = nil
) -> AICueControlledAssetProtocolStep {
    var headers = ["content-type": "audio/mpeg"]
    if let retryAfter { headers["retry-after"] = retryAfter }
    return .http(statusCode: statusCode, headers: headers, responseURL: nil, chunks: [])
}

@MainActor
private func observedAssetFetchError(
    _ operation: () async throws -> AICueFetchedAsset
) async -> AICueAssetFetchError? {
    do {
        _ = try await operation()
        return nil
    } catch let error as AICueAssetFetchError {
        return error
    } catch {
        return nil
    }
}

private func assetDeadline(durationNanoseconds: UInt64) -> AICueGenerationDeadline {
    AICueGenerationDeadline(
        startedAtUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds,
        durationNanoseconds: durationNanoseconds)
}

func runAICueAssetFetchSuites() async {
    await suite("AI 提示音 asset policy：只接受 exact HTTPS host/443 与正常资源 path") {
        let policy = fixtureAssetPolicy()
        let valid = URL(string: "https://assets.fixture.invalid/audio/item.mp3?token=opaque")!
        expect(
            (try? AICueURLSessionAssetFetcher.request(
                url: valid,
                policy: policy,
                deadline: .startingNow())) != nil,
            "固定 host 的签名 query 资源应通过本地 preflight")

        let rejected = [
            "http://assets.fixture.invalid/audio/item.mp3",
            "https://other.fixture.invalid/audio/item.mp3",
            "https://assets.fixture.invalid:8443/audio/item.mp3",
            "https://user@assets.fixture.invalid/audio/item.mp3",
            "https://assets.fixture.invalid/audio/item.mp3#fragment",
            "https://assets.fixture.invalid/",
            "https://assets.fixture.invalid/a/../item.mp3",
        ]
        for value in rejected {
            do {
                _ = try AICueURLSessionAssetFetcher.request(
                    url: URL(string: value)!,
                    policy: policy,
                    deadline: .startingNow())
                expect(false, "不可信 asset URL 必须在网络前拒绝")
            } catch AICueAssetFetchError.invalidURL {
                expect(true, "asset URL 已按 exact policy 拒绝")
            } catch {
                expect(false, "asset URL 应返回脱敏 invalidURL")
            }
        }
        expect(
            (try? AICueAssetOrigin("https://127.0.0.1")) == nil
                && (try? AICueAssetOrigin("https://[::1]")) == nil
                && (try? AICueAssetOrigin("https://*.fixture.invalid")) == nil,
            "asset allowlist 本身不得表达 IP literal 或通配域")
        expect(
            !String(reflecting: policy).contains("token=opaque")
                && !String(reflecting: AICueAssetFetchError.invalidURL).contains("token=opaque"),
            "policy 与错误反射不得包含资源 URL/query")
    }

    await suite("AI 提示音 asset fetch：GET 不带 credential/cookie/referer 且同 URL 有界重试") {
        let success = AICueFetchedAsset(data: Data([0x49, 0x44, 0x33]), mediaType: "audio/mpeg")
        let loader = AICueAssetLoaderFixture([
            .failure(.httpStatus(code: 429, retryAfterSeconds: 3)),
            .success(success),
        ])
        let sleeper = AICueAssetSleeperFixture()
        let fetcher = AICueURLSessionAssetFetcher(loader: loader, retrySleeper: sleeper)
        let url = URL(string: "https://assets.fixture.invalid/a.mp3?signature=redacted")!
        let fetched = try? await fetcher.fetch(
            url,
            policy: fixtureAssetPolicy(),
            deadline: .startingNow())
        let requests = await loader.facts()
        expect(fetched == success, "合法 429 Retry-After 后应返回第二次 GET 结果")
        expect(requests.count == 2 && requests.allSatisfy { $0.url == url }, "重试只能复用同一 URL")
        expect(
            Set(await loader.observedDeadlines()).count == 1,
            "初次 GET 与 retry 必须共享同一个 absolute deadline")
        expect(await sleeper.facts() == [3], "429 只接受 1...5 秒 Retry-After")
        expect(
            requests.allSatisfy {
                $0.httpMethod == "GET"
                    && $0.httpBody == nil
                    && $0.value(forHTTPHeaderField: "Authorization") == nil
                    && $0.value(forHTTPHeaderField: "Cookie") == nil
                    && $0.value(forHTTPHeaderField: "Referer") == nil
            },
            "asset GET 不得携带 API key、cookie、referer 或 body")

        let rejectedLoader = AICueAssetLoaderFixture([
            .failure(.httpStatus(code: 401, retryAfterSeconds: nil)),
            .success(success),
        ])
        let rejectedFetcher = AICueURLSessionAssetFetcher(
            loader: rejectedLoader,
            retrySleeper: AICueAssetSleeperFixture())
        do {
            _ = try await rejectedFetcher.fetch(
                url,
                policy: fixtureAssetPolicy(),
                deadline: .startingNow())
            expect(false, "资源 GET 401 不得重试或映射为 credential replacement rejection")
        } catch AICueAssetFetchError.httpStatus(401, _) {
            expect(await rejectedLoader.facts().count == 1, "非瞬态资源失败只发一次 GET")
        } catch {
            expect(false, "资源 GET 401 应保留下载错误语义")
        }
    }

    await suite("AI 提示音 asset fetch：真实 loader 只重试 transient/408/5xx 且最多一次") {
        let url = URL(
            string: "https://assets.fixture.invalid/generated/retry.mp3?signature=opaque-sentinel")!
        let deadline = AICueGenerationDeadline.startingNow()
        let transientCases: [AICueControlledAssetProtocolStep] = [
            .failure(.timedOut),
            .failure(.cannotFindHost),
            .failure(.cannotConnectToHost),
            .failure(.dnsLookupFailed),
            .failure(.networkConnectionLost),
            .failure(.notConnectedToInternet),
            controlledAssetHTTPErrorStep(408),
            controlledAssetHTTPErrorStep(500),
            controlledAssetHTTPErrorStep(503),
            controlledAssetHTTPErrorStep(599),
        ]
        for firstFailure in transientCases {
            AICueControlledAssetURLProtocol.control.reset([
                firstFailure, controlledAssetSuccessStep(),
            ])
            let sleeper = AICueAssetSleeperFixture()
            let fetcher = AICueURLSessionAssetFetcher(
                loader: controlledAssetLoader(),
                retrySleeper: sleeper)
            let fetched = try? await fetcher.fetch(
                url,
                policy: fixtureAssetPolicy(),
                deadline: deadline)
            let facts = AICueControlledAssetURLProtocol.control.facts()
            expect(fetched?.data == Data([0x49, 0x44, 0x33]), "窄范围 transient 首次失败应重试成功")
            expect(
                facts.requests.count == 2
                    && facts.requests.allSatisfy { request in
                        request.url == url
                            && request.httpMethod == "GET"
                            && request.httpBody == nil
                            && request.value(forHTTPHeaderField: "Authorization") == nil
                            && request.value(forHTTPHeaderField: "Cookie") == nil
                            && request.value(forHTTPHeaderField: "Referer") == nil
                    }
                    && facts.maximumInFlight == 1,
                "retry 必须同 URL、零敏感 header 且任一时刻只有一个真实 loader request")
            expect(await sleeper.facts().isEmpty, "非 429 transient retry 不得引入 backoff")
        }

        AICueControlledAssetURLProtocol.control.reset([
            controlledAssetHTTPErrorStep(500),
            controlledAssetHTTPErrorStep(503),
            controlledAssetSuccessStep(),
        ])
        let twiceFailingFetcher = AICueURLSessionAssetFetcher(
            loader: controlledAssetLoader(),
            retrySleeper: AICueAssetSleeperFixture())
        let secondError = await observedAssetFetchError {
            try await twiceFailingFetcher.fetch(
                url,
                policy: fixtureAssetPolicy(),
                deadline: deadline)
        }
        expect(
            secondError == .httpStatus(code: 503, retryAfterSeconds: nil)
                && AICueControlledAssetURLProtocol.control.facts().requests.count == 2,
            "第二次 GET 仍失败时必须返回该错误，第三个 scripted response 不得被消费")
    }

    await suite("AI 提示音 asset fetch：429 只接受 Retry-After 1...5，其他 HTTP 不重试") {
        let url = URL(string: "https://assets.fixture.invalid/generated/rate.mp3?token=opaque")!
        for delay in [1, 5] {
            AICueControlledAssetURLProtocol.control.reset([
                controlledAssetHTTPErrorStep(429, retryAfter: String(delay)),
                controlledAssetSuccessStep(),
            ])
            let sleeper = AICueAssetSleeperFixture()
            let fetcher = AICueURLSessionAssetFetcher(
                loader: controlledAssetLoader(),
                retrySleeper: sleeper)
            let fetched = try? await fetcher.fetch(
                url,
                policy: fixtureAssetPolicy(),
                deadline: .startingNow())
            expect(fetched != nil, "Retry-After 边界 1/5 秒必须允许唯一 retry")
            expect(await sleeper.facts() == [delay], "429 必须按合规整数秒等待")
            expect(
                AICueControlledAssetURLProtocol.control.facts().requests.count == 2,
                "合规 429 必须且只能追加一次 GET")
        }

        let rejectedRetryAfter: [(String?, Int?)] = [
            ("0", nil),
            ("6", 6),
            (nil, nil),
            ("invalid", nil),
            ("Sun, 13 Sep 2026 00:00:00 GMT", nil),
        ]
        for (rawValue, parsedValue) in rejectedRetryAfter {
            AICueControlledAssetURLProtocol.control.reset([
                controlledAssetHTTPErrorStep(429, retryAfter: rawValue),
                controlledAssetSuccessStep(),
            ])
            let sleeper = AICueAssetSleeperFixture()
            let fetcher = AICueURLSessionAssetFetcher(
                loader: controlledAssetLoader(),
                retrySleeper: sleeper)
            let observed = await observedAssetFetchError {
                try await fetcher.fetch(
                    url,
                    policy: fixtureAssetPolicy(),
                    deadline: .startingNow())
            }
            let delays = await sleeper.facts()
            expect(
                observed == .httpStatus(code: 429, retryAfterSeconds: parsedValue),
                "不合规 Retry-After 必须保留脱敏 HTTP 429 分类")
            expect(
                AICueControlledAssetURLProtocol.control.facts().requests.count == 1
                    && delays.isEmpty,
                "0/6/missing/invalid/date Retry-After 不得 retry 或 sleep")
        }

        for statusCode in [400, 401, 403, 404] {
            AICueControlledAssetURLProtocol.control.reset([
                controlledAssetHTTPErrorStep(statusCode), controlledAssetSuccessStep(),
            ])
            let fetcher = AICueURLSessionAssetFetcher(
                loader: controlledAssetLoader(),
                retrySleeper: AICueAssetSleeperFixture())
            let observed = await observedAssetFetchError {
                try await fetcher.fetch(
                    url,
                    policy: fixtureAssetPolicy(),
                    deadline: .startingNow())
            }
            expect(
                observed == .httpStatus(code: statusCode, retryAfterSeconds: nil)
                    && AICueControlledAssetURLProtocol.control.facts().requests.count == 1,
                "普通 4xx 必须只发一次 GET")
        }
    }

    await suite("AI 提示音 asset fetch：安全/MIME/size/credential 类错误永不重试") {
        let url = URL(string: "https://assets.fixture.invalid/generated/nonretry.mp3")!
        let failures: [AICueAssetFetchError] = [
            .invalidURL,
            .redirectRejected,
            .unexpectedMediaType,
            .responseTooLarge,
            .deadlineExceeded,
            .cancelled,
            .transportFailure,
            .infrastructureFailure,
            .retryBackoffFailure,
        ]
        for failure in failures {
            let loader = AICueAssetLoaderFixture([
                .failure(failure),
                .success(AICueFetchedAsset(data: validMP3ID3Data(), mediaType: "audio/mpeg")),
            ])
            let sleeper = AICueAssetSleeperFixture()
            let fetcher = AICueURLSessionAssetFetcher(loader: loader, retrySleeper: sleeper)
            let observed = await observedAssetFetchError {
                try await fetcher.fetch(
                    url,
                    policy: fixtureAssetPolicy(),
                    deadline: .startingNow())
            }
            let requestCount = await loader.facts().count
            let delays = await sleeper.facts()
            expect(observed == failure, "非 transient asset 错误必须保持稳定分类")
            expect(
                requestCount == 1 && delays.isEmpty,
                "security/MIME/size/deadline/cancel/transport 错误不得 retry")
        }
    }

    await suite("AI 提示音 asset fetch：未知 loader 错误归一为基础设施失败且不重试") {
        let loader = AICueAssetLoaderFixture(rawResults: [
            .failure(NSError(domain: "ClaudioFixtureInfrastructure", code: 1)),
            .success(AICueFetchedAsset(data: validMP3ID3Data(), mediaType: "audio/mpeg")),
        ])
        let sleeper = AICueAssetSleeperFixture()
        let fetcher = AICueURLSessionAssetFetcher(loader: loader, retrySleeper: sleeper)
        let error = await observedAssetFetchError {
            try await fetcher.fetch(
                URL(string: "https://assets.fixture.invalid/infrastructure.mp3")!,
                policy: fixtureAssetPolicy(), deadline: .startingNow())
        }
        expect(error == .infrastructureFailure, "未知 loader 错误不可降级为普通 transportFailure")
        let requests = await loader.facts()
        let delays = await sleeper.facts()
        expect(requests.count == 1 && delays.isEmpty, "未知错误不重试或等待 backoff")
    }
    await suite("AI 提示音 URLSession asset loader：拒绝 redirect/MIME/wire overflow") {
        let configuration = URLSessionConfiguration.default
        configuration.protocolClasses = [AICueAssetURLProtocol.self]
        configuration.httpAdditionalHeaders = [
            "Authorization": "Bearer stale",
            "Cookie": "stale=1",
            "Referer": "https://stale.invalid",
        ]
        let loader = AICueURLSessionAssetLoader(
            configuration: configuration,
            timeouts: AICueTransportTimeouts(connectionSeconds: 1, inactivitySeconds: 1))
        AICueAssetURLProtocol.recorder.reset()

        let okURL = URL(string: "https://assets.fixture.invalid/ok.mp3?token=opaque")!
        let okRequest = try! AICueURLSessionAssetFetcher.request(
            url: okURL,
            policy: fixtureAssetPolicy(),
            deadline: .startingNow())
        let ok = try? await loader.load(
            okRequest,
            acceptedMediaTypes: ["audio/mpeg"],
            maximumWireBytes: 8,
            deadline: .startingNow())
        expect(ok?.data == Data([0x49, 0x44, 0x33]), "合法响应应完整返回")
        let sent = AICueAssetURLProtocol.recorder.facts().first
        expect(
            sent?.value(forHTTPHeaderField: "Authorization") == nil
                && sent?.value(forHTTPHeaderField: "Cookie") == nil
                && sent?.value(forHTTPHeaderField: "Referer") == nil,
            "注入 URLSessionConfiguration 也不得夹带 credential/cookie/referer")

        let cases: [(String, Int, AICueAssetFetchError)] = [
            ("/redirect.mp3", 8, .redirectRejected),
            ("/wrong.mp3", 8, .unexpectedMediaType),
            ("/large.mp3", 8, .responseTooLarge),
        ]
        for (path, maximumBytes, expected) in cases {
            let url = URL(string: "https://assets.fixture.invalid\(path)")!
            let request = try! AICueURLSessionAssetFetcher.request(
                url: url,
                policy: fixtureAssetPolicy(),
                deadline: .startingNow())
            var observed: AICueAssetFetchError?
            do {
                _ = try await loader.load(
                    request,
                    acceptedMediaTypes: ["audio/mpeg"],
                    maximumWireBytes: maximumBytes,
                    deadline: .startingNow())
            } catch let error as AICueAssetFetchError {
                observed = error
            } catch {}
            expect(observed == expected, "redirect/MIME/size 必须返回脱敏失败")
        }
        expect(
            AICueAssetURLProtocol.recorder.facts().allSatisfy {
                $0.url?.host != "harvest.invalid"
            },
            "redirect target 必须零外发")
    }

    await suite("AI 提示音 URLSession asset loader：final URL、HTTP、MIME 与 wire 边界真实生效") {
        let loader = controlledAssetLoader()
        let policy = fixtureAssetPolicy()
        let cases:
            [(
                path: String, step: AICueControlledAssetProtocolStep, maximumBytes: Int,
                expected: AICueAssetFetchError
            )] = [
                (
                    "/final-url.mp3",
                    .http(
                        statusCode: 200,
                        headers: ["content-type": "audio/mpeg"],
                        responseURL: URL(string: "https://assets.fixture.invalid/drifted.mp3")!,
                        chunks: [Data([0x49, 0x44, 0x33])]),
                    8,
                    .redirectRejected
                ),
                ("/non-http.mp3", .nonHTTP(data: Data([0x49, 0x44, 0x33])), 8, .redirectRejected),
                (
                    "/redirect-controlled.mp3",
                    .redirect(target: URL(string: "https://harvest.invalid/asset.mp3")!),
                    8,
                    .redirectRejected
                ),
                (
                    "/wrong-media.mp3",
                    .http(
                        statusCode: 200,
                        headers: ["content-type": "text/html"],
                        responseURL: nil,
                        chunks: [Data([0x49, 0x44, 0x33])]),
                    8,
                    .unexpectedMediaType
                ),
                (
                    "/missing-media.mp3",
                    .http(
                        statusCode: 200,
                        headers: [:],
                        responseURL: nil,
                        chunks: [Data([0x49, 0x44, 0x33])]),
                    8,
                    .unexpectedMediaType
                ),
                (
                    "/declared-large.mp3",
                    .http(
                        statusCode: 200,
                        headers: ["content-type": "audio/mpeg", "content-length": "9"],
                        responseURL: nil,
                        chunks: []),
                    8,
                    .responseTooLarge
                ),
                (
                    "/chunked-large.mp3",
                    .http(
                        statusCode: 200,
                        headers: ["content-type": "audio/mpeg"],
                        responseURL: nil,
                        chunks: [Data(repeating: 0x49, count: 8), Data([0x00])]),
                    8,
                    .responseTooLarge
                ),
            ]
        for item in cases {
            AICueControlledAssetURLProtocol.control.reset([item.step])
            let url = URL(
                string:
                    "https://assets.fixture.invalid\(item.path)?signed=private-query-sentinel")!
            let request = try! AICueURLSessionAssetFetcher.request(
                url: url,
                policy: policy,
                deadline: .startingNow())
            let observed = await observedAssetFetchError {
                try await loader.load(
                    request,
                    acceptedMediaTypes: ["audio/mpeg"],
                    maximumWireBytes: item.maximumBytes,
                    deadline: .startingNow())
            }
            let facts = AICueControlledAssetURLProtocol.control.facts()
            expect(observed == item.expected, "真实 loader 必须按 final URL/HTTP/MIME/wire 合同失败")
            expect(
                facts.requests.count == 1
                    && facts.requests[0].url == url
                    && facts.requests.allSatisfy { $0.url?.host != "harvest.invalid" },
                "loader 不得把 redirect/final URL 漂移外发到第二 host")
            expect(
                !String(reflecting: observed).contains("private-query-sentinel"),
                "loader 错误不得反射签名 query")
        }

        let exactLimit = AICueURLSessionAssetFetcher.maximumWireBytes
        let exactBody = Data(repeating: 0x61, count: exactLimit)
        AICueControlledAssetURLProtocol.control.reset([
            controlledAssetSuccessStep(data: exactBody)
        ])
        let exactURL = URL(string: "https://assets.fixture.invalid/exact-limit.mp3")!
        let exactRequest = try! AICueURLSessionAssetFetcher.request(
            url: exactURL,
            policy: policy,
            deadline: .startingNow())
        let exact = try? await loader.load(
            exactRequest,
            acceptedMediaTypes: ["audio/mpeg"],
            maximumWireBytes: exactLimit,
            deadline: .startingNow())
        expect(exact?.data.count == exactLimit, "wire 恰好 5 MiB 必须被 loader 接受")

        AICueControlledAssetURLProtocol.control.reset([
            .http(
                statusCode: 200,
                headers: ["content-type": "audio/mpeg"],
                responseURL: nil,
                chunks: [exactBody, Data([0x00])])
        ])
        let overflow = await observedAssetFetchError {
            try await loader.load(
                exactRequest,
                acceptedMediaTypes: ["audio/mpeg"],
                maximumWireBytes: exactLimit,
                deadline: .startingNow())
        }
        expect(overflow == .responseTooLarge, "wire 5 MiB + 1 byte 必须失败")
    }

    await suite("AI 提示音 URLSession asset loader：相邻请求不继承认证、cookie 或 cache 状态") {
        AICueControlledAssetURLProtocol.control.reset([
            controlledAssetSuccessStep(), controlledAssetSuccessStep(),
        ])
        let fetcher = AICueURLSessionAssetFetcher(
            loader: controlledAssetLoader(),
            retrySleeper: AICueAssetSleeperFixture())
        let urls = ["first", "second"].map {
            URL(string: "https://assets.fixture.invalid/\($0).mp3?signature=opaque-\($0)")!
        }
        for url in urls {
            _ = try? await fetcher.fetch(
                url,
                policy: fixtureAssetPolicy(),
                deadline: .startingNow())
        }
        let facts = AICueControlledAssetURLProtocol.control.facts()
        expect(facts.requests.map(\.url) == urls.map(Optional.some), "相邻请求必须保持各自 exact URL")
        expect(
            facts.requests.allSatisfy { request in
                request.cachePolicy == .reloadIgnoringLocalCacheData
                    && request.httpShouldHandleCookies == false
                    && request.value(forHTTPHeaderField: "Authorization") == nil
                    && request.value(forHTTPHeaderField: "Cookie") == nil
                    && request.value(forHTTPHeaderField: "Referer") == nil
            },
            "注入 session headers 与前一请求都不得污染下一次 credential-free GET")
    }

    await suite("AI 提示音 asset fetch：already/in-flight/backoff/second-load cancel 统一映射") {
        let url = URL(string: "https://assets.fixture.invalid/cancel.mp3?signature=opaque")!
        let policy = fixtureAssetPolicy()

        let startGate = AICueAssetStartGate()
        AICueControlledAssetURLProtocol.control.reset([controlledAssetSuccessStep()])
        let alreadyCancelledFetcher = AICueURLSessionAssetFetcher(
            loader: controlledAssetLoader(),
            retrySleeper: AICueAssetSleeperFixture())
        let alreadyCancelledTask = Task {
            await startGate.wait()
            return try await alreadyCancelledFetcher.fetch(
                url,
                policy: policy,
                deadline: .startingNow())
        }
        await startGate.waitUntilArrived()
        alreadyCancelledTask.cancel()
        await startGate.release()
        let alreadyCancelled = await observedAssetFetchError {
            try await alreadyCancelledTask.value
        }
        expect(alreadyCancelled == .cancelled, "already-cancelled fetch 必须稳定映射 cancelled")
        expect(
            AICueControlledAssetURLProtocol.control.facts().requests.isEmpty,
            "already-cancelled fetch 必须在真实 loader/URLProtocol 前结束")

        AICueControlledAssetURLProtocol.control.reset([.hold])
        let inFlightLoader = controlledAssetLoader()
        let inFlightRequest = try! AICueURLSessionAssetFetcher.request(
            url: url,
            policy: policy,
            deadline: .startingNow())
        let inFlightTask = Task {
            try await inFlightLoader.load(
                inFlightRequest,
                acceptedMediaTypes: ["audio/mpeg"],
                maximumWireBytes: 8,
                deadline: .startingNow())
        }
        await AICueControlledAssetURLProtocol.control.waitForRequestCount(1)
        inFlightTask.cancel()
        let inFlightCancelled = await observedAssetFetchError {
            try await inFlightTask.value
        }
        let inFlightFacts = AICueControlledAssetURLProtocol.control.facts()
        expect(inFlightCancelled == .cancelled, "in-flight URLSession cancel 必须映射 cancelled")
        expect(
            inFlightFacts.requests.count == 1 && inFlightFacts.maximumInFlight == 1,
            "in-flight cancel 必须只启动唯一真实 URLProtocol attempt，且不得追加请求")

        let backoffLoader = AICueAssetLoaderFixture([
            .failure(.httpStatus(code: 429, retryAfterSeconds: 2)),
            .success(AICueFetchedAsset(data: validMP3ID3Data(), mediaType: "audio/mpeg")),
        ])
        let blockingSleeper = AICueAssetBlockingSleeperFixture()
        let backoffFetcher = AICueURLSessionAssetFetcher(
            loader: backoffLoader,
            retrySleeper: blockingSleeper)
        let backoffTask = Task {
            try await backoffFetcher.fetch(url, policy: policy, deadline: .startingNow())
        }
        let enteredBackoff = await blockingSleeper.waitUntilEntered()
        expect(enteredBackoff, "retry backoff 必须在 10 秒 watchdog 内进入 sleeper")
        guard enteredBackoff else {
            backoffTask.cancel()
            return
        }
        backoffTask.cancel()
        let backoffCancelled = await observedAssetFetchError {
            try await backoffTask.value
        }
        let backoffRequestCount = await backoffLoader.facts().count
        let backoffDelays = await blockingSleeper.facts()
        expect(backoffCancelled == .cancelled, "retry backoff 的 CancellationError 必须归一为 cancelled")
        expect(
            backoffRequestCount == 1 && backoffDelays == [2],
            "backoff cancel 后不得发起第二次 GET")

        let secondLoad = AICueAssetLoaderFixture(rawResults: [
            .failure(AICueAssetFetchError.transientNetwork as Error),
            .failure(CancellationError()),
        ])
        let secondLoadFetcher = AICueURLSessionAssetFetcher(
            loader: secondLoad,
            retrySleeper: AICueAssetSleeperFixture())
        let secondLoadCancelled = await observedAssetFetchError {
            try await secondLoadFetcher.fetch(url, policy: policy, deadline: .startingNow())
        }
        expect(secondLoadCancelled == .cancelled, "第二次 load 的 CancellationError 必须归一为 cancelled")
        expect(await secondLoad.facts().count == 2, "second-load cancel 前必须真的消费唯一 retry")
    }

    await suite("AI 提示音 URLSession asset loader：connection/inactivity/absolute deadline 均终止") {
        let url = URL(string: "https://assets.fixture.invalid/timing.mp3")!
        let policy = fixtureAssetPolicy()
        let request = try! AICueURLSessionAssetFetcher.request(
            url: url,
            policy: policy,
            deadline: .startingNow())

        AICueControlledAssetURLProtocol.control.reset([.hold])
        let connectionError = await observedAssetFetchError {
            try await controlledAssetLoader(connectionSeconds: 0.02).load(
                request,
                acceptedMediaTypes: ["audio/mpeg"],
                maximumWireBytes: 8,
                deadline: assetDeadline(durationNanoseconds: 1_000_000_000))
        }
        await AICueControlledAssetURLProtocol.control.waitForStoppedAttempt()
        expect(connectionError == .transientNetwork, "connection inactivity 必须映射可重试 transient")
        expect(
            AICueControlledAssetURLProtocol.control.facts().stoppedAttempts == 1,
            "connection timeout 必须取消真实 URLSession task")

        for _ in 0..<20 {
            AICueControlledAssetURLProtocol.control.reset([.hold])
            let deadline = assetDeadline(durationNanoseconds: 20_000_000)
            let deadlineError = await observedAssetFetchError {
                try await controlledAssetLoader(connectionSeconds: 1).load(
                    request,
                    acceptedMediaTypes: ["audio/mpeg"],
                    maximumWireBytes: 8,
                    deadline: deadline)
            }
            let stopWatchdog = DispatchTime.now().uptimeNanoseconds + 1_000_000_000
            while DispatchTime.now().uptimeNanoseconds < stopWatchdog {
                let facts = AICueControlledAssetURLProtocol.control.facts()
                if facts.stoppedAttempts == facts.requests.count { break }
                try? await Task.sleep(nanoseconds: 1_000_000)
            }
            expect(
                deadlineError == .deadlineExceeded,
                "absolute deadline 必须优先返回 deadlineExceeded；实际 \(String(describing: deadlineError))；"
                    + "已过期 \(deadline.remainingNanoseconds(at: DispatchTime.now().uptimeNanoseconds) == nil)"
            )
            let facts = AICueControlledAssetURLProtocol.control.facts()
            expect(
                facts.requests.count <= 1 && facts.stoppedAttempts == facts.requests.count,
                "absolute deadline 必须停止已开始 request；启动前过期可以零请求，不无限等待 stopLoading")
        }

        AICueControlledAssetURLProtocol.control.reset([
            .delayedHTTP(
                headers: ["content-type": "audio/mpeg"],
                firstChunk: Data([0x49]),
                delayedChunk: Data([0x44, 0x33]),
                delayNanoseconds: 100_000_000)
        ])
        let inactivityError = await observedAssetFetchError {
            try await controlledAssetLoader(inactivitySeconds: 0.02).load(
                request,
                acceptedMediaTypes: ["audio/mpeg"],
                maximumWireBytes: 8,
                deadline: assetDeadline(durationNanoseconds: 1_000_000_000))
        }
        expect(inactivityError == .transientNetwork, "响应中途 inactivity 必须终止为 transient")
        await AICueControlledAssetURLProtocol.control.waitForSuppressedLateChunk()
        let lateFacts = AICueControlledAssetURLProtocol.control.facts()
        expect(
            lateFacts.stoppedAttempts == 1 && lateFacts.suppressedLateChunks == 1,
            "inactivity 后的迟到 chunk 必须被已停止的 URLProtocol 丢弃")
    }

    await suite("AI 提示音 URLSession asset loader：绝对边界的 Foundation timeout 不降级为 transient") {
        for _ in 0..<20 {
            let deadline = assetDeadline(durationNanoseconds: 20_000_000)
            AICueControlledAssetURLProtocol.control.reset([
                .failureAtDeadline(
                    .timedOut, deadline.expiresAtUptimeNanoseconds)
            ])
            let request = try! AICueURLSessionAssetFetcher.request(
                url: URL(string: "https://assets.fixture.invalid/deadline-race.mp3")!,
                policy: fixtureAssetPolicy(), deadline: .startingNow())
            let error = await observedAssetFetchError {
                try await controlledAssetLoader().load(
                    request, acceptedMediaTypes: ["audio/mpeg"], maximumWireBytes: 8,
                    deadline: deadline)
            }
            expect(
                error == .deadlineExceeded,
                "边界 timeout 必须为 deadlineExceeded；实际 \(String(describing: error))")
        }
    }
    await suite("AI 提示音 asset fetch：过期 deadline 在 loader 前失败") {
        let loader = AICueAssetLoaderFixture([
            .success(AICueFetchedAsset(data: Data(), mediaType: "audio/mpeg"))
        ])
        let fetcher = AICueURLSessionAssetFetcher(
            loader: loader,
            retrySleeper: AICueAssetSleeperFixture())
        let deadline = AICueGenerationDeadline(
            startedAtUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds,
            durationNanoseconds: 0)
        do {
            _ = try await fetcher.fetch(
                URL(string: "https://assets.fixture.invalid/a.mp3")!,
                policy: fixtureAssetPolicy(),
                deadline: deadline)
            expect(false, "过期资源请求不得启动")
        } catch AICueAssetFetchError.deadlineExceeded {
            expect(await loader.facts().isEmpty, "过期 deadline 必须零网络")
        } catch {
            expect(false, "过期资源请求应返回 deadlineExceeded")
        }
    }
}
