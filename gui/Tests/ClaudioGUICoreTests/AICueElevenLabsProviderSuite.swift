import ClaudioGUICore
import Foundation

private final class AICueCredentialHeaderURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let hasExpectedCredential =
            request.value(forHTTPHeaderField: "xi-api-key") == "fixture-transport-key"
        let status = hasExpectedCredential ? 200 : 401
        let body =
            hasExpectedCredential
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

private actor ElevenLabsUnaryTransportFixture: AICueUnaryTransport {
    private var queued: [Result<AICueHTTPResponse, Error>]
    private var captured: [AICueTransportRequest] = []
    private var capturedAuthentication: [AICueProviderAuthentication] = []

    init(_ queued: [Result<AICueHTTPResponse, Error>]) {
        self.queued = queued
    }

    func send(
        _ request: AICueTransportRequest,
        authentication: AICueProviderAuthentication,
        credential: SensitiveCredentialInput
    ) async throws -> AICueHTTPResponse {
        captured.append(request)
        capturedAuthentication.append(authentication)
        guard !queued.isEmpty else { throw AICueTransportError.transportFailure }
        return try queued.removeFirst().get()
    }

    func requests() -> [AICueTransportRequest] { captured }
    func authentications() -> [AICueProviderAuthentication] { capturedAuthentication }
}

private actor ElevenLabsGenerationVaultFixture: AICueCredentialVault {
    private(set) var readSlots: [AICueCredentialSlotID] = []

    func containsCredential(in slotID: AICueCredentialSlotID) async throws -> Bool {
        slotID == .legacyElevenLabs
    }

    func credential(in slotID: AICueCredentialSlotID) async throws -> SensitiveCredentialInput? {
        readSlots.append(slotID)
        guard slotID == .legacyElevenLabs else { return nil }
        return try SensitiveCredentialInput("fixture-generation-key")
    }

    func replaceCredential(
        _ credential: SensitiveCredentialInput,
        in slotID: AICueCredentialSlotID
    ) async throws {}

    func deleteCredential(in slotID: AICueCredentialSlotID) async throws {}

    func reads() -> [AICueCredentialSlotID] { readSlots }
}

private func elevenLabsPOSIXPermissions(at url: URL) -> Int? {
    (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]) as? Int
}

@MainActor
func runAICueElevenLabsProviderSuites() async {
    suite("ElevenLabs registry：四类能力与旧 Keychain account 只来自固定 profile") {
        let provider = ElevenLabsAICueProvider(
            unaryTransport: ElevenLabsUnaryTransportFixture([]))
        let profile = provider.profile
        expect(profile.id == .elevenLabsGlobal, "adapter 必须注册为 elevenlabs-global")
        expect(profile.providerID == .elevenLabs, "provider identity 必须来自 registry")
        expect(profile.credentialSlotID == .legacyElevenLabs, "必须继续使用旧 account elevenlabs")
        expect(
            profile.supportedModalities == [.speech, .mixed, .animal, .soundEffect]
                && profile.supportedModalities == Set(profile.routes.keys),
            "四类能力必须完全由 registry routes 派生")
    }

    await suite("ElevenLabs adapter：只读 models 验证 key 与两个固定模型") {
        let models = Data(
            """
            [
              {"model_id":"eleven_v3","can_do_text_to_speech":true},
              {"model_id":"eleven_text_to_sound_v2","can_do_text_to_speech":false}
            ]
            """.utf8)
        let transport = ElevenLabsUnaryTransportFixture([
            .success(
                AICueHTTPResponse(
                    statusCode: 200,
                    headers: ["content-type": "application/json"],
                    body: models,
                    finalURL: URL(string: "https://api.elevenlabs.io/v1/models")!))
        ])
        let provider = ElevenLabsAICueProvider(unaryTransport: transport)
        let secret = "fixture-provider-key"

        try! await provider.validateCredential(try! SensitiveCredentialInput(secret))
        let requests = await transport.requests()
        let authentication = await transport.authentications()
        expect(requests.count == 1, "凭据验证只能发一个低副作用请求")
        expect(requests.first?.method == .get, "凭据验证必须是 GET")
        expect(requests.first?.url.path == "/v1/models", "凭据验证必须调用固定 models endpoint")
        expect(authentication == [.elevenLabsAPIKeyHeader], "adapter 必须把认证类型交给统一 transport")
        expect(requests.first?.headers["xi-api-key"] == nil, "明文 key 不得进入 transport request")
        expect(
            requests.first.map { !String(reflecting: $0).contains(secret) } == true,
            "统一 transport request 的默认反射不得泄漏明文 key")
        expect(requests.first?.body == nil, "models 验证不得携带生成 body")
        expect(
            requests.first?.expectedPath == "/v1/models"
                && requests.first?.expectedOrigin.matches(
                    URL(string: "https://api.elevenlabs.io/v1/models")!) == true,
            "models probe 必须冻结 exact origin/path")
    }

    await suite("ElevenLabs transport：只在构造 URLRequest 时注入 xi-api-key") {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AICueCredentialHeaderURLProtocol.self]
        let provider = ElevenLabsAICueProvider(
            unaryTransport: AICueURLSessionUnaryTransport(configuration: configuration))

        var accepted = false
        do {
            try await provider.validateCredential(
                try SensitiveCredentialInput("fixture-transport-key"))
            accepted = true
        } catch {}
        expect(accepted, "真实 transport 必须从不透明 credential 构造正确 xi-api-key header")
    }

    await suite("ElevenLabs adapter：缺少任一必需模型时 key 不得被视为可用") {
        let transport = ElevenLabsUnaryTransportFixture([
            .success(
                AICueHTTPResponse(
                    statusCode: 200,
                    headers: ["content-type": "application/json"],
                    body: Data("[{\"model_id\":\"eleven_v3\"}]".utf8),
                    finalURL: URL(string: "https://api.elevenlabs.io/v1/models")!))
        ])
        let provider = ElevenLabsAICueProvider(unaryTransport: transport)
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
        let transport = ElevenLabsUnaryTransportFixture([
            .success(
                AICueHTTPResponse(
                    statusCode: 200,
                    headers: ["content-type": "application/json"],
                    body: models,
                    finalURL: URL(string: "https://example.invalid/harvest")!))
        ])
        let provider = ElevenLabsAICueProvider(unaryTransport: transport)
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
        let transport = ElevenLabsUnaryTransportFixture([
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
        let provider = ElevenLabsAICueProvider(unaryTransport: transport)
        let plan = try! AICueSoundPlanner().makePlan(
            for: try! AICueGenerationRequest(
                description: "用清晰中文说“本轮结束”",
                locale: "zh-Hans",
                providerProfileID: .elevenLabsGlobal))
        let compiled = try! AICueProviderRequestCompiler().compile(
            plan: plan,
            profileID: .elevenLabsGlobal,
            variant: .clear)

        let response = try! await provider.generateCandidate(
            request: compiled,
            credential: try! SensitiveCredentialInput("fixture-key"),
            deadline: .startingNow())
        let requests = await transport.requests()
        let request = requests[0]
        let body = try! JSONSerialization.jsonObject(with: request.body!) as! [String: Any]
        expect(request.method == .post, "生成必须是 POST")
        expect(
            request.url.path
                == "/v1/text-to-speech/JBFqnCBsd6RMkjVDRZzb",
            "语音必须使用固定 voice endpoint")
        expect(
            URLComponents(url: request.url, resolvingAgainstBaseURL: false)?
                .queryItems?.contains(where: {
                    $0.name == "output_format" && $0.value == "mp3_44100_128"
                }) == true,
            "语音输出必须固定为 mp3_44100_128")
        expect(body["model_id"] as? String == "eleven_v3", "model 必须固定为 eleven_v3")
        expect(body["text"] as? String == "本轮结束", "正文必须只逐字发送明确台词")
        expect(
            request.body.map { !String(decoding: $0, as: UTF8.self).contains("workbuddy") } == true,
            "provider body 不得包含 surface token")
        expect(response.data == audio && response.modelID == "eleven_v3", "响应只投影音频与非敏感 provenance")
    }

    await suite("ElevenLabs adapter：纯音效使用 sound-generation 固定模型与有界时长") {
        let transport = ElevenLabsUnaryTransportFixture([
            .success(
                AICueHTTPResponse(
                    statusCode: 200,
                    headers: ["content-type": "audio/mpeg"],
                    body: validMP3ID3Data(),
                    finalURL: URL(string: "https://api.elevenlabs.io/v1/sound-generation")!))
        ])
        let provider = ElevenLabsAICueProvider(unaryTransport: transport)
        let plan = try! AICueSoundPlanner().makePlan(
            for: try! AICueGenerationRequest(
                description: "一只小猫短促叫两声，不要背景音乐",
                locale: "zh-Hans",
                providerProfileID: .elevenLabsGlobal))
        let compiled = try! AICueProviderRequestCompiler().compile(
            plan: plan,
            profileID: .elevenLabsGlobal,
            variant: .brisk)

        _ = try! await provider.generateCandidate(
            request: compiled,
            credential: try! SensitiveCredentialInput("fixture-key"),
            deadline: .startingNow())
        let request = await transport.requests()[0]
        let body = try! JSONSerialization.jsonObject(with: request.body!) as! [String: Any]
        expect(request.url.path == "/v1/sound-generation", "动物/音效必须使用固定 sound endpoint")
        expect(
            body["model_id"] as? String == "eleven_text_to_sound_v2",
            "音效 model 必须固定")
        expect(body["loop"] as? Bool == false, "提示音不得请求 loop")
        let duration = body["duration_seconds"] as? Double
        expect(duration != nil && duration! >= 0.5 && duration! <= 3, "请求时长必须夹在 0.5...3 秒")
        expect(body["prompt_influence"] as? Double == 0.65, "A/B/C 影响强度必须进入请求")
    }

    await suite("ElevenLabs adapter：speech/mixed/animal/soundEffect 逐项保持固定 route") {
        let profile = try! AICueProviderRegistry().profile(for: .elevenLabsGlobal)
        let audio = validMP3ID3Data()
        let speechURL = URL(
            string:
                "https://api.elevenlabs.io/v1/text-to-speech/JBFqnCBsd6RMkjVDRZzb"
                + "?output_format=mp3_44100_128"
        )!
        let effectsURL = URL(string: "https://api.elevenlabs.io/v1/sound-generation")!
        let transport = ElevenLabsUnaryTransportFixture(
            [speechURL, speechURL, effectsURL, effectsURL].map { finalURL in
                .success(
                    AICueHTTPResponse(
                        statusCode: 200,
                        headers: ["content-type": "audio/mpeg"],
                        body: audio,
                        finalURL: finalURL))
            })
        let provider = ElevenLabsAICueProvider(unaryTransport: transport)
        let requests = [
            AICueProviderRequest(
                profileID: .elevenLabsGlobal,
                modality: .speech,
                prompt: "[clear] 完成",
                spokenContent: "完成",
                languageTag: "zh-Hans",
                targetDurationMilliseconds: 1_500,
                variant: .clear),
            AICueProviderRequest(
                profileID: .elevenLabsGlobal,
                modality: .mixed,
                prompt: "[sound effect: 清脆铃声] [cheerful] 完成",
                spokenContent: "完成",
                languageTag: "zh-Hans",
                targetDurationMilliseconds: 1_500,
                variant: .brisk),
            AICueProviderRequest(
                profileID: .elevenLabsGlobal,
                modality: .animal,
                prompt: "一只小猫短促叫两声。主体清晰。",
                spokenContent: nil,
                languageTag: nil,
                targetDurationMilliseconds: 1_500,
                variant: .clear),
            AICueProviderRequest(
                profileID: .elevenLabsGlobal,
                modality: .soundEffect,
                prompt: "短促木琴音效。克制、柔和。",
                spokenContent: nil,
                languageTag: nil,
                targetDurationMilliseconds: 1_500,
                variant: .restrained),
        ]
        for request in requests {
            let response = try! await provider.generateCandidate(
                request: request,
                credential: try! SensitiveCredentialInput("fixture-key"),
                deadline: .startingNow())
            expect(
                response.modelID == profile.routes[request.modality]?.modelID,
                "统一 response provenance 必须投影该 modality 的 registry model")
        }
        let sent = await transport.requests()
        expect(
            sent.map(\.expectedPath) == [
                "/v1/text-to-speech/JBFqnCBsd6RMkjVDRZzb",
                "/v1/text-to-speech/JBFqnCBsd6RMkjVDRZzb",
                "/v1/sound-generation",
                "/v1/sound-generation",
            ],
            "speech/mixed 必须走固定 voice；animal/soundEffect 必须走固定 sound route")
        expect(
            sent.allSatisfy {
                $0.maximumWireBytes == AICueTransportCeilings.elevenLabsWireBytes
                    && $0.acceptedMediaTypes == [
                        "application/octet-stream", "audio/mp3", "audio/mpeg",
                    ]
            },
            "四类直接音频都必须使用统一 5 MiB wire 与固定 MIME allowlist")
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
            let secret = "fixture-error-key"
            let transport = ElevenLabsUnaryTransportFixture([
                .failure(
                    AICueTransportError.httpStatus(
                        code: status,
                        retryAfterSeconds: status == 429 ? 2 : nil))
            ])
            let provider = ElevenLabsAICueProvider(unaryTransport: transport)
            var observed: AICueProviderError?
            do {
                try await provider.validateCredential(try SensitiveCredentialInput(secret))
            } catch let error as AICueProviderError {
                observed = error
            } catch {}
            expect(observed == expected, "HTTP \(status) 必须映射为稳定脱敏分类")
            expect(
                observed.map { !String(describing: $0).contains(secret) } == true,
                "provider 错误不得包含 credential")
        }
    }

    await suite("ElevenLabs adapter：成功状态仍拒绝 JSON/空音频，不信任 MIME") {
        for (contentType, body) in [
            ("application/json", Data("{}".utf8)),
            ("audio/mpeg", Data()),
        ] {
            let transport = ElevenLabsUnaryTransportFixture([
                .success(
                    AICueHTTPResponse(
                        statusCode: 200,
                        headers: ["content-type": contentType],
                        body: body,
                        finalURL: URL(string: "https://api.elevenlabs.io/v1/sound-generation")!))
            ])
            let provider = ElevenLabsAICueProvider(unaryTransport: transport)
            let plan = try! AICueSoundPlanner().makePlan(
                for: try! AICueGenerationRequest(
                    description: "短促木琴音效",
                    locale: "zh-Hans",
                    providerProfileID: .elevenLabsGlobal))
            let compiled = try! AICueProviderRequestCompiler().compile(
                plan: plan,
                profileID: .elevenLabsGlobal,
                variant: .clear)
            var rejected = false
            do {
                _ = try await provider.generateCandidate(
                    request: compiled,
                    credential: try SensitiveCredentialInput("fixture-key"),
                    deadline: .startingNow())
            } catch AICueProviderError.invalidAudioResponse {
                rejected = true
            } catch {}
            expect(rejected, "成功状态的非音频或空响应仍必须 fail closed")
        }
    }

    await suite("ElevenLabs adapter：统一 transport 的 MIME、大小、deadline 与取消错误稳定映射") {
        let cases: [(AICueTransportError, AICueProviderError)] = [
            (.unexpectedMediaType, .invalidAudioResponse),
            (.responseTooLarge, .responseTooLarge),
            (.deadlineExceeded, .deadlineExceeded),
            (.cancelled, .cancelled),
            (.redirectRejected, .transportFailure),
            (.pathMismatch, .transportFailure),
            (.invalidResponse, .transportFailure),
        ]
        let plan = try! AICueSoundPlanner().makePlan(
            for: try! AICueGenerationRequest(
                description: "短促木琴音效",
                locale: "zh-Hans",
                providerProfileID: .elevenLabsGlobal))
        let compiled = try! AICueProviderRequestCompiler().compile(
            plan: plan,
            profileID: .elevenLabsGlobal,
            variant: .clear)
        for (transportError, expectedError) in cases {
            let provider = ElevenLabsAICueProvider(
                unaryTransport: ElevenLabsUnaryTransportFixture([.failure(transportError)]))
            var observed: AICueProviderError?
            do {
                _ = try await provider.generateCandidate(
                    request: compiled,
                    credential: try SensitiveCredentialInput("fixture-key"),
                    deadline: .startingNow())
            } catch let error as AICueProviderError {
                observed = error
            } catch {}
            expect(observed == expectedError, "统一 transport 错误必须映射为稳定 provider 分类")
        }
    }

    await suite("ElevenLabs generation：真实 adapter 恰好三候选并经统一私有发布链") {
        await withTempDirectory { root in
            let audio = validMP3ID3Data()
            let endpoint = URL(string: "https://api.elevenlabs.io/v1/sound-generation")!
            let transport = ElevenLabsUnaryTransportFixture(
                (1...3).map { ordinal in
                    .success(
                        AICueHTTPResponse(
                            statusCode: 200,
                            headers: [
                                "content-type": "audio/mpeg",
                                "request-id": "fixture-\(ordinal)",
                            ],
                            body: audio,
                            finalURL: endpoint))
                })
            let vault = ElevenLabsGenerationVaultFixture()
            let provider = ElevenLabsAICueProvider(unaryTransport: transport)
            let engine = AICueGenerationEngine(
                vault: vault,
                provider: provider,
                temporaryRoot: root.appendingPathComponent("elevenlabs", isDirectory: true),
                durationProbe: StubDurationProbe(fixedDuration: 1.25))

            let generation = try! await engine.generate(
                description: "短促木琴音效",
                locale: "zh-Hans",
                providerProfileID: .elevenLabsGlobal,
                deadline: .startingNow())
            let sent = await transport.requests()
            expect(sent.count == 3, "ElevenLabs 一次 generation 必须恰好三个顺序请求")
            expect(
                generation.candidates.map(\.variant) == [.clear, .brisk, .restrained],
                "候选身份必须稳定为 A/B/C")
            expect(
                generation.candidates.allSatisfy {
                    $0.provenance.providerID == .elevenLabs
                        && $0.provenance.profileID == .elevenLabsGlobal
                        && $0.provenance.modelID == "eleven_text_to_sound_v2"
                        && $0.asset.sniffedFormat == .mp3
                        && $0.durationMilliseconds == 1_250
                        && FileManager.default.fileExists(atPath: $0.asset.fileURL.path)
                },
                "三候选必须全通过 magic bytes、3 秒、私有临时文件与 provenance 校验")
            let candidateDirectory =
                generation.candidates[0].asset.fileURL.deletingLastPathComponent()
            expect(elevenLabsPOSIXPermissions(at: candidateDirectory) == 0o700, "候选目录必须为 0700")
            expect(
                generation.candidates.allSatisfy {
                    elevenLabsPOSIXPermissions(at: $0.asset.fileURL) == 0o600
                },
                "每个 ElevenLabs 临时候选必须为 0600")
            expect(await vault.reads() == [.legacyElevenLabs], "generation 只能读取一次旧 elevenlabs slot")
        }
    }
}
