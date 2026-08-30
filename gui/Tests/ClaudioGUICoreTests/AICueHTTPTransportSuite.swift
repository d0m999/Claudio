import ClaudioGUICore
import Dispatch
import Foundation

private final class AICueUnaryTransportURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path ?? ""
        let status: Int
        let mediaType: String
        let body: Data
        switch path {
        case "/status":
            status = 401
            mediaType = "application/json"
            body = Data(#"{"secret":"must-not-escape"}"#.utf8)
        case "/wrong-mime":
            status = 200
            mediaType = "text/html"
            body = Data("no".utf8)
        case "/oversize":
            status = 200
            mediaType = "application/json"
            body = Data(repeating: 0x61, count: 65)
        default:
            status = 200
            mediaType = "application/json"
            let auth = request.value(forHTTPHeaderField: "Authorization") ?? ""
            let elevenLabs = request.value(forHTTPHeaderField: "xi-api-key") ?? ""
            let cookie = request.value(forHTTPHeaderField: "Cookie") ?? ""
            body = Data("\(auth)|\(elevenLabs)|\(cookie)".utf8)
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["content-type": mediaType])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class AICueHangingTransportURLProtocol: URLProtocol, @unchecked Sendable {
    static let recorder = AICueRedirectRequestRecorder()

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.recorder.record(request)
    }

    override func stopLoading() {}
}

private final class AICueDelayedBodyTransportURLProtocol: URLProtocol, @unchecked Sendable {
    private var delivery: DispatchWorkItem?

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["content-type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let delivery = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.client?.urlProtocol(self, didLoad: Data("{}".utf8))
            self.client?.urlProtocolDidFinishLoading(self)
        }
        self.delivery = delivery
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + 0.05,
            execute: delivery)
    }

    override func stopLoading() {
        delivery?.cancel()
        delivery = nil
    }
}

private final class AICueRedirectRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var requestedURLs: [URL] = []
    private var targetCredentials: [String] = []

    func reset() {
        lock.withLock {
            requestedURLs.removeAll()
            targetCredentials.removeAll()
        }
    }

    func record(_ request: URLRequest) {
        lock.withLock {
            guard let url = request.url else { return }
            requestedURLs.append(url)
            if url.host == "harvest.invalid" {
                targetCredentials.append(
                    (request.value(forHTTPHeaderField: "Authorization") ?? "")
                        + (request.value(forHTTPHeaderField: "xi-api-key") ?? ""))
            }
        }
    }

    func facts() -> (totalRequests: Int, targetRequests: Int, targetCredentials: [String]) {
        lock.withLock {
            (
                requestedURLs.count,
                requestedURLs.filter { $0.host == "harvest.invalid" }.count,
                targetCredentials
            )
        }
    }
}

private final class AICueRedirectTransportURLProtocol: URLProtocol, @unchecked Sendable {
    static let recorder = AICueRedirectRequestRecorder()

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.recorder.record(request)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 302,
            httpVersion: "HTTP/1.1",
            headerFields: ["location": "https://harvest.invalid/key"])!
        let redirected = URLRequest(url: URL(string: "https://harvest.invalid/key")!)
        client?.urlProtocol(self, wasRedirectedTo: redirected, redirectResponse: response)
    }

    override func stopLoading() {}
}

@MainActor
func runAICueHTTPTransportSuites() async {
    await suite("AI 提示音 unary transport：exact origin/path 后按 auth enum 注入且 request 不含 secret") {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AICueUnaryTransportURLProtocol.self]
        let transport = AICueURLSessionUnaryTransport(configuration: configuration)
        let origin = try! AICueOrigin(scheme: "https", host: "fixture.transport", port: nil)
        let deadline = AICueGenerationDeadline.startingNow()

        let bearerRequest = AICueTransportRequest(
            method: .post,
            url: URL(string: "https://fixture.transport/v1/generate?format=json")!,
            expectedOrigin: origin,
            expectedPath: "/v1/generate",
            headers: ["accept": "application/json"],
            body: Data("{}".utf8),
            acceptedMediaTypes: ["application/json"],
            maximumWireBytes: 64,
            deadline: deadline)
        let bearerSecret = "fixture-bearer-secret"
        let bearer = try! await transport.send(
            bearerRequest,
            authentication: .bearerAPIKey,
            credential: try! SensitiveCredentialInput(bearerSecret))
        expect(
            String(decoding: bearer.body, as: UTF8.self) == "Bearer \(bearerSecret)||",
            "Bearer 只能由 transport 在已验证请求上注入")
        expect(
            !String(reflecting: bearerRequest).contains(bearerSecret),
            "provider-neutral request 的反射不得持有 credential")

        let elevenLabsSecret = "fixture-elevenlabs-secret"
        let elevenLabs = try! await transport.send(
            bearerRequest,
            authentication: .elevenLabsAPIKeyHeader,
            credential: try! SensitiveCredentialInput(elevenLabsSecret))
        expect(
            String(decoding: elevenLabs.body, as: UTF8.self) == "|\(elevenLabsSecret)|",
            "ElevenLabs key 只能进入 xi-api-key，不能串到 Bearer")
    }

    await suite("AI 提示音 unary transport：注入配置不能夹带旧 auth 或 cookie") {
        let configuration = URLSessionConfiguration.default
        configuration.protocolClasses = [AICueUnaryTransportURLProtocol.self]
        configuration.httpAdditionalHeaders = [
            "Authorization": "Bearer stale-config-key",
            "xi-api-key": "stale-elevenlabs-key",
            "Cookie": "provider-session=stale",
        ]
        let transport = AICueURLSessionUnaryTransport(configuration: configuration)
        let request = AICueTransportRequest(
            method: .get,
            url: URL(string: "https://fixture.transport/config-isolation")!,
            expectedOrigin: try! AICueOrigin(
                scheme: "https", host: "fixture.transport", port: nil),
            expectedPath: "/config-isolation",
            headers: [:],
            body: nil,
            acceptedMediaTypes: ["application/json"],
            maximumWireBytes: 128,
            deadline: .startingNow())
        let response = try! await transport.send(
            request,
            authentication: .bearerAPIKey,
            credential: try! SensitiveCredentialInput("fresh-key"))
        expect(
            String(decoding: response.body, as: UTF8.self) == "Bearer fresh-key||",
            "configuration 的 auth/cookie 必须被丢弃，只允许本次 auth enum 注入")
    }

    await suite("AI 提示音 unary transport：拒绝 origin/path 漂移与预注入认证 header") {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AICueUnaryTransportURLProtocol.self]
        let transport = AICueURLSessionUnaryTransport(configuration: configuration)
        let origin = try! AICueOrigin(scheme: "https", host: "fixture.transport", port: nil)
        let credential = try! SensitiveCredentialInput("fixture-secret")

        let cases: [(URL, String, [String: String], AICueTransportError)] = [
            (
                URL(string: "https://other.transport/v1/generate")!,
                "/v1/generate", [:], .originMismatch
            ),
            (
                URL(string: "https://fixture.transport/v1/download")!,
                "/v1/generate", [:], .pathMismatch
            ),
            (
                URL(string: "https://fixture.transport/v1/generate")!,
                "/v1/generate", ["Authorization": "Bearer preinjected"],
                .authenticationHeaderRejected
            ),
            (
                URL(string: "https://fixture.transport/v1/generate")!,
                "/v1/generate", ["XI-API-KEY": "preinjected"],
                .authenticationHeaderRejected
            ),
            (
                URL(string: "https://fixture.transport/v1/generate")!,
                "/v1/generate", ["Authorization ": "Bearer preinjected"],
                .authenticationHeaderRejected
            ),
        ]
        for (url, expectedPath, headers, expectedError) in cases {
            let request = AICueTransportRequest(
                method: .post,
                url: url,
                expectedOrigin: origin,
                expectedPath: expectedPath,
                headers: headers,
                body: nil,
                acceptedMediaTypes: ["application/json"],
                maximumWireBytes: 64,
                deadline: .startingNow())
            var observed: AICueTransportError?
            do {
                _ = try await transport.send(
                    request,
                    authentication: .bearerAPIKey,
                    credential: credential)
            } catch let error as AICueTransportError {
                observed = error
            } catch {}
            expect(observed == expectedError, "无效请求必须在发送 credential 前本地拒绝")
        }
    }

    await suite("AI 提示音 unary transport：统一执行 status、MIME 与 streamed wire ceiling") {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AICueUnaryTransportURLProtocol.self]
        let transport = AICueURLSessionUnaryTransport(configuration: configuration)
        let origin = try! AICueOrigin(scheme: "https", host: "fixture.transport", port: nil)
        let credential = try! SensitiveCredentialInput("fixture-secret")

        let cases: [(String, Int, AICueTransportError)] = [
            ("/status", 64, .httpStatus(code: 401, retryAfterSeconds: nil)),
            ("/wrong-mime", 64, .unexpectedMediaType),
            ("/oversize", 64, .responseTooLarge),
        ]
        for (path, limit, expectedError) in cases {
            let request = AICueTransportRequest(
                method: .get,
                url: URL(string: "https://fixture.transport\(path)")!,
                expectedOrigin: origin,
                expectedPath: path,
                headers: [:],
                body: nil,
                acceptedMediaTypes: ["application/json"],
                maximumWireBytes: limit,
                deadline: .startingNow())
            var observed: AICueTransportError?
            do {
                _ = try await transport.send(
                    request,
                    authentication: .bearerAPIKey,
                    credential: credential)
            } catch let error as AICueTransportError {
                observed = error
            } catch {}
            expect(observed == expectedError, "status/MIME/大小错误只能返回脱敏统一分类")
            expect(
                observed.map { !String(reflecting: $0).contains("must-not-escape") } == true,
                "transport error 不得包含响应正文")
        }
    }

    await suite("AI 提示音 unary transport：inactivity timeout 与调用方 cancel 都终止在途任务") {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AICueHangingTransportURLProtocol.self]
        let origin = try! AICueOrigin(scheme: "https", host: "fixture.transport", port: nil)
        let request = AICueTransportRequest(
            method: .get,
            url: URL(string: "https://fixture.transport/hang")!,
            expectedOrigin: origin,
            expectedPath: "/hang",
            headers: [:],
            body: nil,
            acceptedMediaTypes: ["application/json"],
            maximumWireBytes: 64,
            deadline: .startingNow())
        let credential = try! SensitiveCredentialInput("fixture-secret")

        AICueHangingTransportURLProtocol.recorder.reset()
        let expiringRequest = AICueTransportRequest(
            method: .get,
            url: URL(string: "https://fixture.transport/almost-expired")!,
            expectedOrigin: origin,
            expectedPath: "/almost-expired",
            headers: [:],
            body: nil,
            acceptedMediaTypes: ["application/json"],
            maximumWireBytes: 64,
            deadline: AICueGenerationDeadline(
                startedAtUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds,
                durationNanoseconds: 1_000_000))
        let expiringTransport = AICueURLSessionUnaryTransport(
            configuration: configuration,
            timeouts: AICueTransportTimeouts(connectionSeconds: 1, inactivitySeconds: 1))
        let expiringStart = Date()
        var expiringError: AICueTransportError?
        do {
            _ = try await expiringTransport.send(
                expiringRequest,
                authentication: .bearerAPIKey,
                credential: credential)
        } catch let error as AICueTransportError {
            expiringError = error
        } catch {}
        expect(expiringError == .deadlineExceeded, "临界过期 unary request 必须立即结束")
        expect(Date().timeIntervalSince(expiringStart) < 0.05, "过期 race 不得退化成 connection timeout")
        expect(
            AICueHangingTransportURLProtocol.recorder.facts().totalRequests <= 1,
            "临界过期最多只能启动可被立即取消的单一 request")

        let timeoutTransport = AICueURLSessionUnaryTransport(
            configuration: configuration,
            timeouts: AICueTransportTimeouts(
                connectionSeconds: 0.02,
                inactivitySeconds: 0.02))
        var timeoutError: AICueTransportError?
        do {
            _ = try await timeoutTransport.send(
                request,
                authentication: .bearerAPIKey,
                credential: credential)
        } catch let error as AICueTransportError {
            timeoutError = error
        } catch {}
        expect(timeoutError == .inactivityTimeout, "无 callback 的连接必须被 connection/inactivity 门禁终止")

        let delayedConfiguration = URLSessionConfiguration.ephemeral
        delayedConfiguration.protocolClasses = [AICueDelayedBodyTransportURLProtocol.self]
        let asymmetricTransport = AICueURLSessionUnaryTransport(
            configuration: delayedConfiguration,
            timeouts: AICueTransportTimeouts(
                connectionSeconds: 0.02,
                inactivitySeconds: 0.15))
        let delayedRequest = AICueTransportRequest(
            method: .get,
            url: URL(string: "https://fixture.transport/delayed-body")!,
            expectedOrigin: origin,
            expectedPath: "/delayed-body",
            headers: [:],
            body: nil,
            acceptedMediaTypes: ["application/json"],
            maximumWireBytes: 64,
            deadline: .startingNow())
        let delayed = try? await asymmetricTransport.send(
            delayedRequest,
            authentication: .bearerAPIKey,
            credential: credential)
        expect(delayed?.body == Data("{}".utf8), "收到响应后必须切换到独立 inactivity 预算")

        let cancelTransport = AICueURLSessionUnaryTransport(
            configuration: configuration,
            timeouts: AICueTransportTimeouts(connectionSeconds: 1, inactivitySeconds: 1))
        let task = Task {
            try await cancelTransport.send(
                request,
                authentication: .bearerAPIKey,
                credential: credential)
        }
        try? await Task.sleep(nanoseconds: 10_000_000)
        task.cancel()
        var cancelError: AICueTransportError?
        do { _ = try await task.value } catch let error as AICueTransportError {
            cancelError = error
        } catch {}
        expect(cancelError == .cancelled, "调用方取消必须同步取消 URLSession task")
    }

    await suite("AI 提示音 unary transport：scheme/port/path 逐项 exact，远端下载 URL 无法扩权") {
        var rejectedHTTPOrigin = false
        do {
            _ = try AICueOrigin(scheme: "http", host: "fixture.transport", port: nil)
        } catch AICueOriginError.invalidScheme {
            rejectedHTTPOrigin = true
        } catch {}
        expect(rejectedHTTPOrigin, "origin v1 只能是 HTTPS")

        let derivedURL = URL(string: "https://FIXTURE.transport:8443/v1/generate")!
        let derivedOrigin = try! AICueOrigin(url: derivedURL)
        expect(
            derivedOrigin.matches(derivedURL)
                && !derivedOrigin.matches(URL(string: "https://fixture.transport/v1/generate")!),
            "adapter 必须能从实际 allowlisted route 派生 scheme/host/port 信任边界")
        var rejectedRelativeURL = false
        do {
            _ = try AICueOrigin(url: URL(string: "/v1/generate")!)
        } catch AICueOriginError.invalidScheme {
            rejectedRelativeURL = true
        } catch {}
        expect(rejectedRelativeURL, "没有 HTTPS origin 的相对 URL 必须 fail closed")

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AICueUnaryTransportURLProtocol.self]
        let transport = AICueURLSessionUnaryTransport(configuration: configuration)
        let origin = try! AICueOrigin(scheme: "https", host: "fixture.transport", port: nil)
        let urls = [
            URL(string: "https://fixture.transport:8443/v1/generate")!,
            URL(string: "https://fixture.transport/v1%2Fgenerate")!,
            URL(string: "https://cdn.example.invalid/result.wav")!,
        ]
        let expectedErrors: [AICueTransportError] = [
            .originMismatch, .pathMismatch, .originMismatch,
        ]
        for (url, expectedError) in zip(urls, expectedErrors) {
            let request = AICueTransportRequest(
                method: .get,
                url: url,
                expectedOrigin: origin,
                expectedPath: "/v1/generate",
                headers: [:],
                body: nil,
                acceptedMediaTypes: ["application/json"],
                maximumWireBytes: 64,
                deadline: .startingNow())
            var observed: AICueTransportError?
            do {
                _ = try await transport.send(
                    request,
                    authentication: .bearerAPIKey,
                    credential: try SensitiveCredentialInput("fixture-secret"))
            } catch let error as AICueTransportError {
                observed = error
            } catch {}
            expect(observed == expectedError, "非 exact port/path 或任意远端下载 URL 必须本地拒绝")
        }
    }

    await suite("AI 提示音 unary transport：redirect 在第二个请求前拒绝") {
        AICueRedirectTransportURLProtocol.recorder.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AICueRedirectTransportURLProtocol.self]
        let transport = AICueURLSessionUnaryTransport(configuration: configuration)
        let request = AICueTransportRequest(
            method: .get,
            url: URL(string: "https://fixture.transport/redirect")!,
            expectedOrigin: try! AICueOrigin(
                scheme: "https", host: "fixture.transport", port: nil),
            expectedPath: "/redirect",
            headers: [:],
            body: nil,
            acceptedMediaTypes: ["application/json"],
            maximumWireBytes: 64,
            deadline: .startingNow())
        var observed: AICueTransportError?
        do {
            _ = try await transport.send(
                request,
                authentication: .bearerAPIKey,
                credential: try SensitiveCredentialInput("fixture-secret"))
        } catch let error as AICueTransportError {
            observed = error
        } catch {}
        expect(
            observed == .redirectRejected,
            "redirect 不能获得第二个携带 credential 的请求；observed=\(String(describing: observed))")
        let unaryFacts = AICueRedirectTransportURLProtocol.recorder.facts()
        expect(
            unaryFacts.targetRequests == 0 && unaryFacts.targetCredentials.isEmpty,
            "unary redirect target 必须零请求、零 credential")

        AICueRedirectTransportURLProtocol.recorder.reset()
        let sse = AICueURLSessionSSETransport(configuration: configuration)
        var sseError: AICueTransportError?
        do {
            for try await _ in sse.events(
                for: request,
                authentication: .bearerAPIKey,
                credential: try! SensitiveCredentialInput("fixture-sse-secret"))
            {}
        } catch let error as AICueTransportError {
            sseError = error
        } catch {}
        let sseFacts = AICueRedirectTransportURLProtocol.recorder.facts()
        expect(
            sseError == .redirectRejected,
            "SSE redirect 必须返回统一拒绝分类；observed=\(String(describing: sseError))")
        expect(
            sseFacts.targetRequests == 0 && sseFacts.targetCredentials.isEmpty,
            "SSE redirect target 必须零请求、零 credential")
    }
}
