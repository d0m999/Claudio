import ClaudioGUICore
import Dispatch
import Foundation

private final class AICueSSETransportURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["content-type": "text/event-stream; charset=utf-8"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let auth = request.value(forHTTPHeaderField: "Authorization") ?? ""
        let staleKey = request.value(forHTTPHeaderField: "xi-api-key") ?? ""
        let cookie = request.value(forHTTPHeaderField: "Cookie") ?? ""
        let chunks = [
            "data: {\"audio\":\"Q",
            "UJD\",\"auth\":\"\(auth)\",\"stale\":\"\(staleKey)\(cookie)\"}\r",
            "\n\r\ndata: {\"finish_reason\":\"stop\"}\n\n",
        ]
        for chunk in chunks {
            client?.urlProtocol(self, didLoad: Data(chunk.utf8))
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class AICueHangingSSEURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {}

    override func stopLoading() {}
}

private final class AICueDelayedSSEURLProtocol: URLProtocol, @unchecked Sendable {
    private var delivery: DispatchWorkItem?

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["content-type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let delivery = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.client?.urlProtocol(
                self,
                didLoad: Data("data: {\"finish_reason\":\"stop\"}\n\n".utf8))
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

private final class AICueBurstSSEURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["content-type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for index in 0..<64 {
            client?.urlProtocol(self, didLoad: Data("data: {\"index\":\(index)}\n\n".utf8))
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@MainActor
func runAICueSSETransportSuites() async {
    suite("AI 提示音 SSE parser：byte-by-byte 支持 LF/CRLF、空行与 callback 跨 JSON/Base64") {
        let wire =
            ": keepalive\r\n"
            + "event: message\r\n"
            + "data: {\"audio\":\"QUJD\"}\r\n\r\n"
            + "\n"
            + "data: {\"finish_reason\":\"stop\"}\n\n"
        var parser = AICueSSEParser(maximumWireBytes: wire.utf8.count)
        var events: [AICueSSEEvent] = []
        for byte in wire.utf8 {
            events.append(contentsOf: try! parser.append(Data([byte])))
        }
        events.append(contentsOf: try! parser.finish())
        expect(events.count == 2, "空事件边界与注释不能生成伪事件")
        expect(events.first?.data == #"{"audio":"QUJD"}"#, "跨 callback 的 JSON/Base64 必须原样重组")
        expect(
            events.last?.data == #"{"finish_reason":"stop"}"#,
            "LF terminal event 必须独立派发")
    }

    suite("AI 提示音 SSE parser：terminal 唯一且 EOF-before-terminal fail closed") {
        var completeParser = AICueSSEParser(maximumWireBytes: 64)
        let completeEvents = try! completeParser.append(
            Data("data: {\"finish_reason\":\"stop\"}\n\n".utf8))
        _ = try! completeParser.finish()
        var valid = AICueSSETerminalValidator()
        for event in completeEvents {
            try! valid.accept(isTerminal: event.data.contains("finish_reason"))
        }
        var validEOF = true
        do { try valid.finish() } catch { validEOF = false }
        expect(validEOF, "唯一 terminal 后 EOF 才是完整 stream")

        var missing = AICueSSETerminalValidator()
        try! missing.accept(isTerminal: false)
        var missingError: AICueSSESequenceError?
        do { try missing.finish() } catch let error as AICueSSESequenceError {
            missingError = error
        } catch {}
        expect(missingError == .terminalMissing, "EOF-before-terminal 必须失败")

        for truncated in [
            "data: {\"finish_reason\":\"stop\"}",
            "data: {\"finish_reason\":\"stop\"}\n",
        ] {
            var parser = AICueSSEParser(maximumWireBytes: 64)
            _ = try! parser.append(Data(truncated.utf8))
            var truncatedError: AICueTransportError?
            do { _ = try parser.finish() } catch let error as AICueTransportError {
                truncatedError = error
            } catch {}
            expect(
                truncatedError == .invalidResponse,
                "EOF 不得把未由空行闭合的残缺 terminal 晋升为完整事件")
        }

        var duplicate = AICueSSETerminalValidator()
        try! duplicate.accept(isTerminal: true)
        var duplicateError: AICueSSESequenceError?
        do { try duplicate.accept(isTerminal: true) } catch let error as AICueSSESequenceError {
            duplicateError = error
        } catch {}
        expect(duplicateError == .duplicateTerminal, "重复 terminal 必须失败")

        var postTerminal = AICueSSETerminalValidator()
        try! postTerminal.accept(isTerminal: true)
        var trailingError: AICueSSESequenceError?
        do { try postTerminal.accept(isTerminal: false) } catch let error as AICueSSESequenceError {
            trailingError = error
        } catch {}
        expect(trailingError == .dataAfterTerminal, "terminal 后数据必须失败")
    }

    suite("AI 提示音 SSE parser：wire ceiling 与畸形 UTF-8 均失败关闭") {
        var oversized = AICueSSEParser(maximumWireBytes: 5)
        var oversizedError: AICueTransportError?
        do { _ = try oversized.append(Data("123456".utf8)) } catch let error as AICueTransportError
        {
            oversizedError = error
        } catch {}
        expect(oversizedError == .responseTooLarge, "SSE wire 必须在增量 append 时门禁")

        var malformed = AICueSSEParser(maximumWireBytes: 16)
        var malformedError: AICueTransportError?
        do { _ = try malformed.append(Data([0xFF, 0x0A])) } catch let error as AICueTransportError {
            malformedError = error
        } catch {}
        expect(malformedError == .invalidResponse, "完整行不是 UTF-8 时不得替换字符继续")
    }

    await suite("AI 提示音 SSE transport：流式派发且仅在 validated boundary 注入 Bearer") {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AICueSSETransportURLProtocol.self]
        configuration.httpAdditionalHeaders = [
            "xi-api-key": "stale-provider-key",
            "Cookie": "provider-session=stale",
        ]
        let transport = AICueURLSessionSSETransport(configuration: configuration)
        let request = AICueTransportRequest(
            method: .post,
            url: URL(string: "https://fixture.transport/v1/stream")!,
            expectedOrigin: try! AICueOrigin(
                scheme: "https", host: "fixture.transport", port: nil),
            expectedPath: "/v1/stream",
            headers: ["accept": "text/event-stream"],
            body: Data("{}".utf8),
            acceptedMediaTypes: ["text/event-stream"],
            maximumWireBytes: 256,
            deadline: .startingNow())
        var events: [AICueSSEEvent] = []
        var observedError: AICueTransportError?
        do {
            for try await event in transport.events(
                for: request,
                authentication: .bearerAPIKey,
                credential: try! SensitiveCredentialInput("fixture-sse-secret"))
            {
                events.append(event)
            }
        } catch let error as AICueTransportError {
            observedError = error
        } catch {}
        expect(observedError == nil, "合法 SSE stream 不应失败")
        expect(events.count == 2, "transport 必须增量交付两个 event")
        expect(
            events.first?.data.contains("Bearer fixture-sse-secret") == true,
            "SSE Bearer 只在网络执行边界出现")
        expect(
            events.first?.data.contains(#""stale":"""#) == true,
            "SSE 必须丢弃 configuration 夹带的旧 auth/cookie")
        expect(
            events.last?.data.contains("finish_reason") == true, "terminal event 必须交给 adapter 判定")
    }

    await suite("AI 提示音 SSE transport：连接 inactivity 与调用方取消终止 stream") {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AICueHangingSSEURLProtocol.self]
        let request = AICueTransportRequest(
            method: .post,
            url: URL(string: "https://fixture.transport/stream-hang")!,
            expectedOrigin: try! AICueOrigin(
                scheme: "https", host: "fixture.transport", port: nil),
            expectedPath: "/stream-hang",
            headers: [:],
            body: Data("{}".utf8),
            acceptedMediaTypes: ["text/event-stream"],
            maximumWireBytes: 256,
            deadline: .startingNow())
        let credential = try! SensitiveCredentialInput("fixture-secret")

        let timeoutTransport = AICueURLSessionSSETransport(
            configuration: configuration,
            timeouts: AICueTransportTimeouts(
                connectionSeconds: 0.02,
                inactivitySeconds: 0.02))
        var timeoutError: AICueTransportError?
        do {
            for try await _ in timeoutTransport.events(
                for: request,
                authentication: .bearerAPIKey,
                credential: credential)
            {}
        } catch let error as AICueTransportError {
            timeoutError = error
        } catch {}
        expect(timeoutError == .inactivityTimeout, "无 callback 的 SSE 连接必须被 timeout 门禁终止")

        let delayedConfiguration = URLSessionConfiguration.ephemeral
        delayedConfiguration.protocolClasses = [AICueDelayedSSEURLProtocol.self]
        let asymmetricTransport = AICueURLSessionSSETransport(
            configuration: delayedConfiguration,
            timeouts: AICueTransportTimeouts(
                connectionSeconds: 0.02,
                inactivitySeconds: 0.15))
        var delayedEvents: [AICueSSEEvent] = []
        do {
            for try await event in asymmetricTransport.events(
                for: request,
                authentication: .bearerAPIKey,
                credential: credential)
            {
                delayedEvents.append(event)
            }
        } catch {}
        expect(delayedEvents.count == 1, "SSE 收到响应后必须切换到独立 inactivity 预算")

        let cancelTransport = AICueURLSessionSSETransport(
            configuration: configuration,
            timeouts: AICueTransportTimeouts(connectionSeconds: 1, inactivitySeconds: 1))
        let task = Task { () -> AICueTransportError? in
            do {
                for try await _ in cancelTransport.events(
                    for: request,
                    authentication: .bearerAPIKey,
                    credential: credential)
                {}
                return nil
            } catch let error as AICueTransportError {
                return error
            } catch {
                return .transportFailure
            }
        }
        try? await Task.sleep(nanoseconds: 10_000_000)
        task.cancel()
        expect(await task.value == .cancelled, "取消 iterator 必须终止 URLSession stream")
    }

    await suite("AI 提示音 SSE transport：慢消费者触发有界背压而非缓存完整 stream") {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AICueBurstSSEURLProtocol.self]
        let transport = AICueURLSessionSSETransport(configuration: configuration)
        let request = AICueTransportRequest(
            method: .post,
            url: URL(string: "https://fixture.transport/stream-burst")!,
            expectedOrigin: try! AICueOrigin(
                scheme: "https", host: "fixture.transport", port: nil),
            expectedPath: "/stream-burst",
            headers: [:],
            body: Data("{}".utf8),
            acceptedMediaTypes: ["text/event-stream"],
            maximumWireBytes: 4 * 1_024,
            deadline: .startingNow())
        var received = 0
        var observedError: AICueTransportError?
        do {
            for try await _ in transport.events(
                for: request,
                authentication: .bearerAPIKey,
                credential: try! SensitiveCredentialInput("fixture-secret"))
            {
                received += 1
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
        } catch let error as AICueTransportError {
            observedError = error
        } catch {}
        expect(observedError == .backpressureExceeded, "bounded stream 溢出必须显式失败")
        expect(received <= 17, "慢消费者最多只能观察在途项加 16 项 bounded buffer")
    }
}
