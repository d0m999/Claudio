import ClaudioGUICore
import Dispatch
import Foundation

private actor AICueAssetLoaderFixture: AICueAssetLoading {
    private var results: [Result<AICueFetchedAsset, AICueAssetFetchError>]
    private var requests: [URLRequest] = []

    init(_ results: [Result<AICueFetchedAsset, AICueAssetFetchError>]) {
        self.results = results
    }

    func load(
        _ request: URLRequest,
        acceptedMediaTypes: Set<String>,
        maximumWireBytes: Int,
        deadline: AICueGenerationDeadline
    ) throws -> AICueFetchedAsset {
        requests.append(request)
        guard !results.isEmpty else { throw AICueAssetFetchError.transportFailure }
        return try results.removeFirst().get()
    }

    func facts() -> [URLRequest] { requests }
}

private actor AICueAssetSleeperFixture: AICueAssetRetrySleeping {
    private var delays: [Int] = []

    func sleep(seconds: Int) {
        delays.append(seconds)
    }

    func facts() -> [Int] { delays }
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
