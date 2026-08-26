import ClaudioGUICore
import Foundation

private final class AICueCredentialHeaderURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let hasExpectedCredential =
            request.value(forHTTPHeaderField: "xi-api-key") == "fixture-transport-key"
        let status = hasExpectedCredential ? 200 : 401
        let body = hasExpectedCredential
            ? Data(
                """
                [
                  {"model_id":"eleven_v3"},
                  {"model_id":"eleven_text_to_sound_v2"}
                ]
                """.utf8)
            : Data("{}".utf8)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["content-type": "application/json"])
        client?.urlProtocol(self, didReceive: response!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private actor AICueHTTPClientFixture: AICueHTTPClient {
    private var queued: [Result<AICueHTTPResponse, Error>]
    private var captured: [AICueHTTPRequest] = []

    init(_ queued: [Result<AICueHTTPResponse, Error>]) {
        self.queued = queued
    }

    func send(_ request: AICueHTTPRequest) async throws -> AICueHTTPResponse {
        captured.append(request)
        guard !queued.isEmpty else { throw AICueHTTPClientError.transportFailure }
        return try queued.removeFirst().get()
    }

    func requests() -> [AICueHTTPRequest] { captured }
}

@MainActor
func runAICueProviderSuites() async {
    await suite("ElevenLabs adapter：只读 models 验证 key 与两个固定模型") {
        let models = Data(
            """
            [
              {"model_id":"eleven_v3","can_do_text_to_speech":true},
              {"model_id":"eleven_text_to_sound_v2","can_do_text_to_speech":false}
            ]
            """.utf8)
        let client = AICueHTTPClientFixture([
            .success(
                AICueHTTPResponse(
                    statusCode: 200,
                    headers: ["content-type": "application/json"],
                    body: models,
                    finalURL: URL(string: "https://api.elevenlabs.io/v1/models")!))
        ])
        let provider = ElevenLabsAICueProvider(httpClient: client)
        let secret = "fixture-provider-key"

        try! await provider.validateCredential(try! SensitiveCredentialInput(secret))
        let requests = await client.requests()
        expect(requests.count == 1, "凭据验证只能发一个低副作用请求")
        expect(requests.first?.method == .get, "凭据验证必须是 GET")
        expect(requests.first?.url.path == "/v1/models", "凭据验证必须调用固定 models endpoint")
        expect(requests.first?.credential != nil, "低层请求必须携带不透明的一次性 credential")
        expect(requests.first?.headers["xi-api-key"] == nil, "明文 key 不得进入可反射 header 字典")
        expect(
            requests.first.map { !String(reflecting: $0).contains(secret) } == true,
            "低层请求的默认反射不得泄漏明文 key")
        expect(requests.first?.body == nil, "models 验证不得携带生成 body")
    }

    await suite("ElevenLabs transport：只在构造 URLRequest 时注入 xi-api-key") {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AICueCredentialHeaderURLProtocol.self]
        let provider = ElevenLabsAICueProvider(
            httpClient: AICueURLSessionHTTPClient(configuration: configuration))

        var accepted = false
        do {
            try await provider.validateCredential(
                try SensitiveCredentialInput("fixture-transport-key"))
            accepted = true
        } catch {}
        expect(accepted, "真实 transport 必须从不透明 credential 构造正确 xi-api-key header")
    }

    await suite("ElevenLabs adapter：缺少任一必需模型时 key 不得被视为可用") {
        let client = AICueHTTPClientFixture([
            .success(
                AICueHTTPResponse(
                    statusCode: 200,
                    headers: ["content-type": "application/json"],
                    body: Data("[{\"model_id\":\"eleven_v3\"}]".utf8),
                    finalURL: URL(string: "https://api.elevenlabs.io/v1/models")!))
        ])
        let provider = ElevenLabsAICueProvider(httpClient: client)
        var missingModels = false
        do {
            try await provider.validateCredential(try SensitiveCredentialInput("fixture-key"))
        } catch AICueProviderError.requiredModelsUnavailable {
            missingModels = true
        } catch {}
        expect(missingModels, "模型权限不完整必须 fail closed")
    }

    await suite("ElevenLabs adapter：即使注入 transport 跟随了 redirect，最终 URL 变化仍失败关闭") {
        let models = Data(
            #"[{"model_id":"eleven_v3"},{"model_id":"eleven_text_to_sound_v2"}]"#.utf8)
        let client = AICueHTTPClientFixture([
            .success(
                AICueHTTPResponse(
                    statusCode: 200,
                    headers: ["content-type": "application/json"],
                    body: models,
                    finalURL: URL(string: "https://example.invalid/harvest")!))
        ])
        let provider = ElevenLabsAICueProvider(httpClient: client)
        var rejected = false
        do {
            try await provider.validateCredential(try SensitiveCredentialInput("fixture-key"))
        } catch AICueProviderError.transportFailure {
            rejected = true
        } catch {}
        expect(rejected, "provider 接缝必须独立复验最终 URL，不能只信任 transport")
    }

    await suite("ElevenLabs adapter：语音候选使用固定 voice/model/output，正文不夹带采用上下文") {
        let audio = validMP3ID3Data()
        let client = AICueHTTPClientFixture([
            .success(
                AICueHTTPResponse(
                    statusCode: 200,
                    headers: ["content-type": "audio/mpeg", "request-id": "fixture-request"],
                    body: audio,
                    finalURL: URL(
                        string:
                            "https://api.elevenlabs.io/v1/text-to-speech/JBFqnCBsd6RMkjVDRZzb"
                            + "?output_format=mp3_44100_128"
                    )!))
        ])
        let provider = ElevenLabsAICueProvider(httpClient: client)
        let plan = try! AICueSoundPlanner().makePlan(
            for: try! AICueGenerationRequest(
                description: "用清晰中文说“本轮结束”", locale: "zh-Hans"))
        let compiled = ElevenLabsAICueRequestCompiler().compile(plan: plan, variant: .clear)

        let response = try! await provider.generateCandidate(
            request: compiled,
            credential: try! SensitiveCredentialInput("fixture-key"))
        let requests = await client.requests()
        let request = requests[0]
        let body = try! JSONSerialization.jsonObject(with: request.body!) as! [String: Any]
        expect(request.method == .post, "生成必须是 POST")
        expect(
            request.url.path
                == "/v1/text-to-speech/\(ElevenLabsAICueRequestCompiler.speechVoiceID)",
            "语音必须使用固定 voice endpoint")
        expect(
            URLComponents(url: request.url, resolvingAgainstBaseURL: false)?
                .queryItems?.contains(where: {
                    $0.name == "output_format" && $0.value == "mp3_44100_128"
                }) == true,
            "语音输出必须固定为 mp3_44100_128")
        expect(body["model_id"] as? String == ElevenLabsAICueRequestCompiler.speechModelID, "model 必须固定为 eleven_v3")
        expect((body["text"] as? String)?.contains("本轮结束") == true, "正文必须包含明确台词")
        expect(
            request.body.map { !String(decoding: $0, as: UTF8.self).contains("workbuddy") } == true,
            "provider body 不得包含 surface token")
        expect(response.data == audio && response.modelID == "eleven_v3", "响应只投影音频与非敏感 provenance")
    }

    await suite("ElevenLabs adapter：纯音效使用 sound-generation 固定模型与有界时长") {
        let client = AICueHTTPClientFixture([
            .success(
                AICueHTTPResponse(
                    statusCode: 200,
                    headers: ["content-type": "audio/mpeg"],
                    body: validMP3ID3Data(),
                    finalURL: URL(string: "https://api.elevenlabs.io/v1/sound-generation")!))
        ])
        let provider = ElevenLabsAICueProvider(httpClient: client)
        let plan = try! AICueSoundPlanner().makePlan(
            for: try! AICueGenerationRequest(
                description: "一只小猫短促叫两声，不要背景音乐", locale: "zh-Hans"))
        let compiled = ElevenLabsAICueRequestCompiler().compile(plan: plan, variant: .brisk)

        _ = try! await provider.generateCandidate(
            request: compiled,
            credential: try! SensitiveCredentialInput("fixture-key"))
        let request = await client.requests()[0]
        let body = try! JSONSerialization.jsonObject(with: request.body!) as! [String: Any]
        expect(request.url.path == "/v1/sound-generation", "动物/音效必须使用固定 sound endpoint")
        expect(body["model_id"] as? String == ElevenLabsAICueRequestCompiler.soundEffectModelID, "音效 model 必须固定")
        expect(body["loop"] as? Bool == false, "提示音不得请求 loop")
        let duration = body["duration_seconds"] as? Double
        expect(duration != nil && duration! >= 0.5 && duration! <= 3, "请求时长必须夹在 0.5...3 秒")
        expect(body["prompt_influence"] as? Double == compiled.promptInfluence, "A/B/C 影响强度必须进入请求")
    }

    await suite("ElevenLabs adapter：认证、额度、权限、限流和服务错误只返回脱敏分类") {
        let cases: [(Int, AICueProviderError)] = [
            (401, .invalidCredential),
            (402, .insufficientCredits),
            (403, .forbidden),
            (429, .rateLimited(retryAfterSeconds: 2)),
            (500, .serviceUnavailable),
        ]
        for (status, expected) in cases {
            let client = AICueHTTPClientFixture([
                .success(
                    AICueHTTPResponse(
                        statusCode: status,
                        headers: ["content-type": "application/json", "retry-after": "2"],
                        body: Data("{\"detail\":{\"message\":\"fixture must stay hidden\"}}".utf8),
                        finalURL: URL(string: "https://api.elevenlabs.io/v1/models")!))
            ])
            let provider = ElevenLabsAICueProvider(httpClient: client)
            var observed: AICueProviderError?
            do {
                try await provider.validateCredential(try SensitiveCredentialInput("fixture-key"))
            } catch let error as AICueProviderError {
                observed = error
            } catch {}
            expect(observed == expected, "HTTP \(status) 必须映射为稳定脱敏分类")
            expect(
                observed.map { !String(describing: $0).contains("fixture must stay hidden") } == true,
                "provider 错误正文不得进入公共错误")
        }
    }

    await suite("ElevenLabs adapter：成功状态仍拒绝 JSON/空音频，不信任 MIME") {
        for (contentType, body) in [
            ("application/json", Data("{}".utf8)),
            ("audio/mpeg", Data()),
        ] {
            let client = AICueHTTPClientFixture([
                .success(
                    AICueHTTPResponse(
                        statusCode: 200,
                        headers: ["content-type": contentType],
                        body: body,
                        finalURL: URL(string: "https://api.elevenlabs.io/v1/sound-generation")!))
            ])
            let provider = ElevenLabsAICueProvider(httpClient: client)
            let plan = try! AICueSoundPlanner().makePlan(
                for: try! AICueGenerationRequest(
                    description: "短促木琴音效", locale: "zh-Hans"))
            let compiled = ElevenLabsAICueRequestCompiler().compile(plan: plan, variant: .clear)
            var rejected = false
            do {
                _ = try await provider.generateCandidate(
                    request: compiled,
                    credential: try SensitiveCredentialInput("fixture-key"))
            } catch AICueProviderError.invalidAudioResponse {
                rejected = true
            } catch {}
            expect(rejected, "成功状态的非音频或空响应仍必须 fail closed")
        }
    }
}
