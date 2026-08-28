import ClaudioGUICore
import Foundation

private actor MiniMaxUnaryTransportFixture: AICueUnaryTransport {
    private var queued: [Result<AICueHTTPResponse, Error>]
    private var capturedRequests: [AICueTransportRequest] = []
    private var capturedAuthentications: [AICueProviderAuthentication] = []

    init(_ queued: [Result<AICueHTTPResponse, Error>]) {
        self.queued = queued
    }

    func send(
        _ request: AICueTransportRequest,
        authentication: AICueProviderAuthentication,
        credential: SensitiveCredentialInput
    ) async throws -> AICueHTTPResponse {
        capturedRequests.append(request)
        capturedAuthentications.append(authentication)
        guard !queued.isEmpty else { throw AICueTransportError.transportFailure }
        return try queued.removeFirst().get()
    }

    func requests() -> [AICueTransportRequest] { capturedRequests }
    func authentications() -> [AICueProviderAuthentication] { capturedAuthentications }
}

private actor MiniMaxGenerationVaultFixture: AICueCredentialVault {
    private var readSlots: [AICueCredentialSlotID] = []

    func containsCredential(in slotID: AICueCredentialSlotID) async throws -> Bool {
        slotID == .miniMaxGlobal
    }

    func credential(in slotID: AICueCredentialSlotID) async throws -> SensitiveCredentialInput? {
        readSlots.append(slotID)
        guard slotID == .miniMaxGlobal else { return nil }
        return try SensitiveCredentialInput("fixture-minimax-generation-key")
    }

    func replaceCredential(
        _ credential: SensitiveCredentialInput,
        in slotID: AICueCredentialSlotID
    ) async throws {}

    func deleteCredential(in slotID: AICueCredentialSlotID) async throws {}

    func reads() -> [AICueCredentialSlotID] { readSlots }
}

private let miniMaxGenerationURL = URL(string: "https://api.minimax.io/v1/t2a_v2")!
private let miniMaxProbeURL = URL(string: "https://api.minimax.io/v1/get_voice")!

private func miniMaxHex(_ data: Data) -> String {
    data.map { String(format: "%02x", $0) }.joined()
}

private func miniMaxJSONData(_ object: [String: Any]) -> Data {
    try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}

private func miniMaxProbeResponse(
    statusCode: Int = 0,
    includesFixedVoice: Bool = true
) -> AICueHTTPResponse {
    let voices: [[String: Any]] = [
        [
            "voice_id":
                includesFixedVoice
                ? "Chinese (Mandarin)_Reliable_Executive" : "fixture-other-voice"
        ]
    ]
    return AICueHTTPResponse(
        statusCode: 200,
        headers: ["content-type": "application/json"],
        body: miniMaxJSONData([
            "base_resp": ["status_code": statusCode],
            "system_voice": voices,
        ]),
        finalURL: miniMaxProbeURL)
}

private func miniMaxGenerationResponse(
    audioHex: String,
    providerStatusCode: Int = 0,
    metadata: [String: Any]? = [
        "audio_channel": 1,
        "audio_format": "mp3",
        "audio_sample_rate": 32_000,
        "bitrate": 128_000,
    ],
    traceID: String = "fixture-trace-1",
    httpStatusCode: Int = 200,
    finalURL: URL = miniMaxGenerationURL,
    contentType: String = "application/json"
) -> AICueHTTPResponse {
    var root: [String: Any] = [
        "base_resp": ["status_code": providerStatusCode],
        "data": ["audio": audioHex, "status": 2],
        "trace_id": traceID,
    ]
    if let metadata { root["extra_info"] = metadata }
    return AICueHTTPResponse(
        statusCode: httpStatusCode,
        headers: ["content-type": contentType],
        body: miniMaxJSONData(root),
        finalURL: finalURL)
}

private func validMiniMaxRequest(
    modality: AICueModality = .speech,
    languageTag: String? = "zh-Hans"
) -> AICueProviderRequest {
    AICueProviderRequest(
        profileID: .miniMaxGlobal,
        modality: modality,
        prompt: "[clear] 本轮完成",
        spokenContent: modality == .speech || modality == .mixed ? "本轮完成" : nil,
        languageTag: languageTag,
        targetDurationMilliseconds: 1_500,
        variant: .clear)
}

private func miniMaxPOSIXPermissions(at url: URL) -> Int? {
    (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]) as? Int
}

@MainActor
func runAICueMiniMaxProviderSuites() async {
    suite("MiniMax registry：只开放固定 Mandarin speech profile") {
        let provider = MiniMaxAICueProvider(
            unaryTransport: MiniMaxUnaryTransportFixture([]))
        let profile = provider.profile
        expect(profile.id == .miniMaxGlobal, "adapter 必须固定注册为 minimax-global")
        expect(profile.providerID == .miniMax, "provider identity 必须来自 registry")
        expect(profile.credentialSlotID == .miniMaxGlobal, "必须只读取 minimax-global slot")
        expect(profile.supportedModalities == [.speech], "首批只能开放 speech")
        expect(
            profile.routes[.speech]?.supportedLanguageTags == ["zh", "zh-Hans"],
            "首批 locale allowlist 必须只有 zh 与 zh-Hans")
    }

    await suite("MiniMax probe：固定 Bearer POST /v1/get_voice 与 all body") {
        let transport = MiniMaxUnaryTransportFixture([.success(miniMaxProbeResponse())])
        let provider = MiniMaxAICueProvider(unaryTransport: transport)
        let secret = "fixture-minimax-probe-key"

        try! await provider.validateCredential(try! SensitiveCredentialInput(secret))
        let requests = await transport.requests()
        let authentications = await transport.authentications()
        let request = requests[0]
        let body = try! JSONSerialization.jsonObject(with: request.body!) as! [String: Any]
        expect(request.method == .post, "只读 probe 必须是 POST")
        expect(request.url == miniMaxProbeURL, "probe 必须固定 global get_voice endpoint")
        expect(request.expectedPath == "/v1/get_voice", "probe 必须冻结 exact path")
        expect(request.expectedOrigin.matches(miniMaxProbeURL), "probe 必须冻结 exact origin")
        expect(body as NSDictionary == ["voice_type": "all"] as NSDictionary, "probe body 必须固定")
        expect(authentications == [.bearerAPIKey], "probe 必须把 Bearer 注入交给统一 transport")
        expect(request.headers["authorization"] == nil, "transport request 不得预注入 Bearer")
        expect(
            !String(reflecting: request).contains(secret),
            "request 默认反射不得泄漏 credential")
    }

    await suite("MiniMax probe：非零 provider status、缺固定 voice 与畸形 JSON fail closed") {
        let responses: [(AICueHTTPResponse, AICueProviderError)] = [
            (miniMaxProbeResponse(statusCode: 1004), .invalidCredential),
            (miniMaxProbeResponse(includesFixedVoice: false), .requiredModelsUnavailable),
            (
                AICueHTTPResponse(
                    statusCode: 401,
                    headers: ["content-type": "application/json"],
                    body: miniMaxJSONData(["base_resp": ["status_code": 0]]),
                    finalURL: miniMaxProbeURL),
                .invalidCredential
            ),
            (
                AICueHTTPResponse(
                    statusCode: 200,
                    headers: ["content-type": "application/json"],
                    body: Data("not-json".utf8),
                    finalURL: miniMaxProbeURL),
                .requiredModelsUnavailable
            ),
        ]
        for (response, expected) in responses {
            let provider = MiniMaxAICueProvider(
                unaryTransport: MiniMaxUnaryTransportFixture([.success(response)]))
            var observed: AICueProviderError?
            do {
                try await provider.validateCredential(
                    try SensitiveCredentialInput("fixture-probe-key"))
            } catch let error as AICueProviderError {
                observed = error
            } catch {}
            expect(observed == expected, "probe payload 异常必须映射为稳定脱敏错误")
        }
    }

    await suite("MiniMax adapter：固定 model/voice/hex 与 32 kHz/128 kbps/mono MP3") {
        let audio = validMP3ID3Data()
        let transport = MiniMaxUnaryTransportFixture([
            .success(miniMaxGenerationResponse(audioHex: miniMaxHex(audio)))
        ])
        let provider = MiniMaxAICueProvider(unaryTransport: transport)

        let response = try! await provider.generateCandidate(
            request: validMiniMaxRequest(),
            credential: try! SensitiveCredentialInput("fixture-generation-key"),
            deadline: .startingNow())
        let request = await transport.requests()[0]
        let authentication = await transport.authentications()
        let body = try! JSONSerialization.jsonObject(with: request.body!) as! [String: Any]
        let voice = body["voice_setting"] as! [String: Any]
        let audioSettings = body["audio_setting"] as! [String: Any]
        expect(request.method == .post && request.url == miniMaxGenerationURL, "生成 route 必须固定")
        expect(request.expectedPath == "/v1/t2a_v2", "生成必须冻结 exact path")
        expect(authentication == [.bearerAPIKey], "生成必须使用统一 Bearer transport")
        expect(body["model"] as? String == "speech-2.8-hd", "model 必须固定")
        expect(body["text"] as? String == "本轮完成", "只能发送明确台词")
        expect(body["stream"] as? Bool == false, "首批必须使用 unary non-streaming")
        expect(body["language_boost"] as? String == "Chinese", "Mandarin route 必须固定中文")
        expect(body["output_format"] as? String == "hex", "响应编码必须固定 hex")
        expect(
            voice["voice_id"] as? String == "Chinese (Mandarin)_Reliable_Executive",
            "voice 必须固定为 Mandarin Reliable Executive")
        expect(
            voice["speed"] as? Int == 1 && voice["vol"] as? Int == 1
                && voice["pitch"] as? Int == 0,
            "首批 voice controls 必须固定为中性值")
        expect(
            audioSettings["sample_rate"] as? Int == 32_000
                && audioSettings["bitrate"] as? Int == 128_000
                && audioSettings["channel"] as? Int == 1
                && audioSettings["format"] as? String == "mp3",
            "输出必须固定为 32 kHz/128 kbps/mono MP3")
        expect(
            request.maximumWireBytes == AICueTransportCeilings.miniMaxWireBytes,
            "wire ceiling 必须为 10 MiB hex + 512 KiB envelope")
        expect(
            response.data == audio && response.mediaType == "audio/mpeg"
                && response.modelID == "speech-2.8-hd"
                && response.requestID == "fixture-trace-1",
            "成功响应只能投影验证后的 MP3 与非敏感 provenance")
    }

    await suite("MiniMax adapter：不支持的 modality/locale/过期 deadline 在网络前拒绝") {
        let transport = MiniMaxUnaryTransportFixture([])
        let provider = MiniMaxAICueProvider(unaryTransport: transport)
        let invalidRequests = [
            validMiniMaxRequest(modality: .animal, languageTag: nil),
            validMiniMaxRequest(modality: .soundEffect, languageTag: nil),
            validMiniMaxRequest(modality: .mixed),
            validMiniMaxRequest(languageTag: "en"),
        ]
        for request in invalidRequests {
            var rejected = false
            do {
                _ = try await provider.generateCandidate(
                    request: request,
                    credential: try SensitiveCredentialInput("fixture-key"),
                    deadline: .startingNow())
            } catch AICueProviderError.invalidRequest {
                rejected = true
            } catch {}
            expect(rejected, "unsupported capability 必须稳定映射 invalidRequest")
        }
        var expired = false
        do {
            _ = try await provider.generateCandidate(
                request: validMiniMaxRequest(),
                credential: try SensitiveCredentialInput("fixture-key"),
                deadline: AICueGenerationDeadline(
                    startedAtUptimeNanoseconds: 0,
                    durationNanoseconds: 0))
        } catch AICueProviderError.deadlineExceeded {
            expired = true
        } catch {}
        expect(expired, "过期 generation deadline 必须在 transport 前拒绝")
        expect(await transport.requests().isEmpty, "本地门禁失败不得发网络")
    }

    await suite("MiniMax generation：能力与 locale 门禁先于 Keychain lease 和临时目录") {
        await withTempDirectory { root in
            let transport = MiniMaxUnaryTransportFixture([])
            let vault = MiniMaxGenerationVaultFixture()
            let temporaryRoot = root.appendingPathComponent("minimax-preflight", isDirectory: true)
            let engine = AICueGenerationEngine(
                vault: vault,
                provider: MiniMaxAICueProvider(unaryTransport: transport),
                temporaryRoot: temporaryRoot,
                durationProbe: StubDurationProbe(fixedDuration: 1))
            let cases = [
                ("Say \"Task complete\"", "en"),
                ("一只小猫短促叫两声", "zh-Hans"),
            ]
            for (description, locale) in cases {
                do {
                    _ = try await engine.generate(
                        description: description,
                        locale: locale,
                        providerProfileID: .miniMaxGlobal,
                        deadline: .startingNow())
                } catch {}
            }
            expect(await vault.reads().isEmpty, "能力/locale 门禁失败不得读取 key")
            expect(await transport.requests().isEmpty, "能力/locale 门禁失败不得发网络")
            expect(
                !FileManager.default.fileExists(atPath: temporaryRoot.path),
                "能力/locale 门禁失败不得创建候选目录")
        }
    }

    await suite("MiniMax adapter：非零状态、畸形 JSON、空/奇数/非法 hex 全部拒绝") {
        let audio = validMP3ID3Data()
        let invalidResponses = [
            miniMaxGenerationResponse(audioHex: miniMaxHex(audio), providerStatusCode: 1008),
            miniMaxGenerationResponse(
                audioHex: miniMaxHex(audio),
                httpStatusCode: 503),
            AICueHTTPResponse(
                statusCode: 200,
                headers: ["content-type": "application/json"],
                body: Data("{".utf8),
                finalURL: miniMaxGenerationURL),
            miniMaxGenerationResponse(audioHex: ""),
            miniMaxGenerationResponse(audioHex: "494"),
            miniMaxGenerationResponse(audioHex: "not-hex"),
            AICueHTTPResponse(
                statusCode: 200,
                headers: ["content-type": "application/json"],
                body: miniMaxJSONData([
                    "base_resp": ["status_code": true],
                    "data": ["audio": miniMaxHex(audio)],
                ]),
                finalURL: miniMaxGenerationURL),
        ]
        let expected: [AICueProviderError] = [
            .serviceUnavailable,
            .serviceUnavailable,
            .invalidAudioResponse,
            .invalidAudioResponse,
            .invalidAudioResponse,
            .invalidAudioResponse,
            .invalidAudioResponse,
        ]
        for (response, expectedError) in zip(invalidResponses, expected) {
            let provider = MiniMaxAICueProvider(
                unaryTransport: MiniMaxUnaryTransportFixture([.success(response)]))
            var observed: AICueProviderError?
            do {
                _ = try await provider.generateCandidate(
                    request: validMiniMaxRequest(),
                    credential: try SensitiveCredentialInput("fixture-key"),
                    deadline: .startingNow())
            } catch let error as AICueProviderError {
                observed = error
            } catch {}
            expect(observed == expectedError, "MiniMax payload 错误必须稳定且不携带正文")
        }
    }

    await suite("MiniMax adapter：声明格式冲突与 MP3 magic mismatch fail closed") {
        let audioHex = miniMaxHex(validMP3ID3Data())
        let conflicts: [[String: Any]] = [
            ["audio_format": "wav"],
            ["audio_sample_rate": 44_100],
            ["bitrate": 64_000],
            ["audio_channel": 2],
        ]
        let responses =
            conflicts.map {
                miniMaxGenerationResponse(audioHex: audioHex, metadata: $0)
            } + [miniMaxGenerationResponse(audioHex: miniMaxHex(evilShellScriptData()))]
        for response in responses {
            let provider = MiniMaxAICueProvider(
                unaryTransport: MiniMaxUnaryTransportFixture([.success(response)]))
            var rejected = false
            do {
                _ = try await provider.generateCandidate(
                    request: validMiniMaxRequest(),
                    credential: try SensitiveCredentialInput("fixture-key"),
                    deadline: .startingNow())
            } catch AICueProviderError.invalidAudioResponse {
                rejected = true
            } catch {}
            expect(rejected, "声明冲突或伪装 MP3 必须拒绝")
        }
    }

    await suite("MiniMax adapter：wire、envelope 与 decoded ceiling 分别执行") {
        let oversizedWire = AICueHTTPResponse(
            statusCode: 200,
            headers: ["content-type": "application/json"],
            body: Data(repeating: 0x20, count: AICueTransportCeilings.miniMaxWireBytes + 1),
            finalURL: miniMaxGenerationURL)
        let oversizedDecoded = miniMaxGenerationResponse(
            audioHex: String(
                repeating: "00",
                count: AICueTransportCeilings.miniMaxDecodedBytes + 1))
        let oversizedEnvelope = miniMaxGenerationResponse(
            audioHex: miniMaxHex(validMP3ID3Data()),
            metadata: [
                "audio_channel": 1,
                "audio_format": "mp3",
                "audio_sample_rate": 32_000,
                "bitrate": 128_000,
                "padding": String(repeating: "x", count: (512 * 1_024) + 1),
            ])
        for response in [oversizedWire, oversizedDecoded, oversizedEnvelope] {
            let provider = MiniMaxAICueProvider(
                unaryTransport: MiniMaxUnaryTransportFixture([.success(response)]))
            var rejected = false
            do {
                _ = try await provider.generateCandidate(
                    request: validMiniMaxRequest(),
                    credential: try SensitiveCredentialInput("fixture-key"),
                    deadline: .startingNow())
            } catch AICueProviderError.responseTooLarge {
                rejected = true
            } catch {}
            expect(rejected, "三条独立大小门禁都必须映射 responseTooLarge")
        }
    }

    await suite("MiniMax adapter：认证、权限/额度、429、5xx、取消均为脱敏统一错误") {
        let cases: [(AICueTransportError, AICueProviderError)] = [
            (.httpStatus(code: 401, retryAfterSeconds: nil), .invalidCredential),
            (.httpStatus(code: 402, retryAfterSeconds: nil), .insufficientCredits),
            (.httpStatus(code: 403, retryAfterSeconds: nil), .forbidden),
            (.httpStatus(code: 429, retryAfterSeconds: 2), .rateLimited(retryAfterSeconds: 2)),
            (.httpStatus(code: 503, retryAfterSeconds: nil), .serviceUnavailable),
            (.responseTooLarge, .responseTooLarge),
            (.deadlineExceeded, .deadlineExceeded),
            (.cancelled, .cancelled),
            (.redirectRejected, .transportFailure),
        ]
        for (transportError, expected) in cases {
            let secret = "fixture-error-key"
            let provider = MiniMaxAICueProvider(
                unaryTransport: MiniMaxUnaryTransportFixture([.failure(transportError)]))
            var observed: AICueProviderError?
            do {
                _ = try await provider.generateCandidate(
                    request: validMiniMaxRequest(),
                    credential: try SensitiveCredentialInput(secret),
                    deadline: .startingNow())
            } catch let error as AICueProviderError {
                observed = error
            } catch {}
            expect(observed == expected, "transport 错误必须映射统一 provider 分类")
            expect(
                observed.map { !String(describing: $0).contains(secret) } == true,
                "错误不得包含 key")
        }
    }

    await suite("MiniMax generation：统一 deadline 下顺序生成恰好三候选") {
        await withTempDirectory { root in
            let audio = validMP3ID3Data()
            let transport = MiniMaxUnaryTransportFixture(
                (1...3).map { ordinal in
                    .success(
                        miniMaxGenerationResponse(
                            audioHex: miniMaxHex(audio),
                            traceID: "fixture-minimax-\(ordinal)"))
                })
            let vault = MiniMaxGenerationVaultFixture()
            let provider = MiniMaxAICueProvider(unaryTransport: transport)
            let temporaryRoot = root.appendingPathComponent("minimax", isDirectory: true)
            let engine = AICueGenerationEngine(
                vault: vault,
                provider: provider,
                temporaryRoot: temporaryRoot,
                durationProbe: StubDurationProbe(fixedDuration: 1.2))

            let generation = try! await engine.generate(
                description: "用清晰中文说“本轮完成”",
                locale: "zh-Hans",
                providerProfileID: .miniMaxGlobal,
                deadline: .startingNow())
            let requests = await transport.requests()
            expect(requests.count == 3, "一次 generation 必须恰好三个顺序 unary 请求")
            expect(
                generation.candidates.map(\.variant) == [.clear, .brisk, .restrained],
                "候选身份必须稳定为 A/B/C")
            expect(
                generation.candidates.map { $0.provenance.providerRequestID } == [
                    "fixture-minimax-1", "fixture-minimax-2", "fixture-minimax-3",
                ],
                "每个候选 provenance 只能记录脱敏 trace_id")
            expect(
                generation.candidates.allSatisfy {
                    $0.provenance.providerID == .miniMax
                        && $0.provenance.profileID == .miniMaxGlobal
                        && $0.provenance.modelID == "speech-2.8-hd"
                        && $0.asset.sniffedFormat == .mp3
                        && $0.durationMilliseconds == 1_200
                        && FileManager.default.fileExists(atPath: $0.asset.fileURL.path)
                },
                "三候选必须全部通过 MP3 magic、duration 与 provenance 验证")
            let candidateDirectory =
                generation.candidates[0].asset.fileURL.deletingLastPathComponent()
            expect(miniMaxPOSIXPermissions(at: candidateDirectory) == 0o700, "候选目录必须为 0700")
            expect(
                generation.candidates.allSatisfy {
                    miniMaxPOSIXPermissions(at: $0.asset.fileURL) == 0o600
                },
                "每个临时候选必须为 0600")
            expect(await vault.reads() == [.miniMaxGlobal], "generation 只能租用一次当前 key")
        }
    }

    await suite("MiniMax generation：第三候选失败时不发布 partial 并清理临时文件") {
        await withTempDirectory { root in
            let audioResponse = miniMaxGenerationResponse(
                audioHex: miniMaxHex(validMP3ID3Data()))
            let transport = MiniMaxUnaryTransportFixture([
                .success(audioResponse),
                .success(audioResponse),
                .success(miniMaxGenerationResponse(audioHex: "invalid")),
            ])
            let temporaryRoot = root.appendingPathComponent("minimax-partial", isDirectory: true)
            let engine = AICueGenerationEngine(
                vault: MiniMaxGenerationVaultFixture(),
                provider: MiniMaxAICueProvider(unaryTransport: transport),
                temporaryRoot: temporaryRoot,
                durationProbe: StubDurationProbe(fixedDuration: 1.1))
            var rejected = false
            do {
                _ = try await engine.generate(
                    description: "用清晰中文说“本轮完成”",
                    locale: "zh-Hans",
                    providerProfileID: .miniMaxGlobal,
                    deadline: .startingNow())
            } catch AICueGenerationError.provider(.invalidAudioResponse) {
                rejected = true
            } catch {}
            expect(rejected, "第三候选失败必须拒绝整个 generation")
            let remaining =
                (try? FileManager.default.contentsOfDirectory(
                    at: temporaryRoot,
                    includingPropertiesForKeys: nil)) ?? []
            expect(remaining.isEmpty, "partial generation 不得留下候选目录")
        }
    }
}
