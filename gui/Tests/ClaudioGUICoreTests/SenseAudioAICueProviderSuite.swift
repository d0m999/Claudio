import ClaudioGUICore
import ClaudioLocalization
import ClaudioSettingsPresentation
import Foundation

private actor SenseAudioUnaryTransportFixture: AICueUnaryTransport {
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

private enum SenseAudioAssetStep: Sendable {
    case success(Data, String)
    case failure(AICueAssetFetchError)
}

private actor SenseAudioAssetFetcherFixture: AICueAssetFetching {
    private var steps: [SenseAudioAssetStep]
    private var capturedURLs: [URL] = []

    init(_ steps: [SenseAudioAssetStep]) {
        self.steps = steps
    }

    func fetch(
        _ url: URL,
        policy: AICueAssetPolicy,
        deadline: AICueGenerationDeadline
    ) async throws -> AICueFetchedAsset {
        capturedURLs.append(url)
        guard !steps.isEmpty else { throw AICueAssetFetchError.transportFailure }
        switch steps.removeFirst() {
        case .success(let data, let mediaType):
            return AICueFetchedAsset(data: data, mediaType: mediaType)
        case .failure(let error):
            throw error
        }
    }

    func urls() -> [URL] { capturedURLs }
}

private let senseAudioProbeURL = URL(string: "https://api.senseaudio.cn/v1/get_voice")!
private let senseAudioTTSURL = URL(string: "https://api.senseaudio.cn/v1/t2a_v2")!
private let senseAudioSFXURL = URL(
    string: "https://api.senseaudio.cn/v1/sound-effects/generations")!
private let senseAudioAssetOrigin = "https://assets.fixture.invalid"

private func senseAudioRegistry() -> AICueProviderRegistry {
    let policy = try! AICueAssetPolicy(
        allowedOrigins: [try! AICueAssetOrigin(senseAudioAssetOrigin)],
        acceptedMediaTypes: ["audio/mpeg"])
    return AICueProviderRegistry(evidenceGatedSenseAudioAssetPolicy: policy)
}

private func senseAudioJSON(_ object: [String: Any]) -> Data {
    try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}

private func senseAudioHex(_ data: Data) -> String {
    data.map { String(format: "%02x", $0) }.joined()
}

private func senseAudioResponse(
    url: URL,
    body: [String: Any],
    statusCode: Int = 200,
    contentType: String = "application/json"
) -> AICueHTTPResponse {
    AICueHTTPResponse(
        statusCode: statusCode,
        headers: ["content-type": contentType],
        body: senseAudioJSON(body),
        finalURL: url)
}

private func senseAudioProbeResponse(
    statusCode: Int = 0,
    voiceID: String? = "female_0033_b",
    httpStatusCode: Int = 200
) -> AICueHTTPResponse {
    var root: [String: Any] = ["base_resp": ["status_code": statusCode]]
    if let voiceID {
        root["system_voice"] = [["voice_id": voiceID]]
    }
    return senseAudioResponse(
        url: senseAudioProbeURL,
        body: root,
        statusCode: httpStatusCode)
}

private func senseAudioTTSResponse(
    audioHex: String = senseAudioHex(validMP3ID3Data()),
    providerStatusCode: Int = 0,
    dataStatus: Any = 2,
    metadata: Any? = [
        "audio_channel": 1,
        "audio_format": "mp3",
        "audio_length": 1_200,
        "audio_sample_rate": 32_000,
        "audio_size": validMP3ID3Data().count,
        "bitrate": 128_000,
    ],
    traceID: String = "sense-fixture-1",
    httpStatusCode: Int = 200
) -> AICueHTTPResponse {
    var root: [String: Any] = [
        "base_resp": ["status_code": providerStatusCode],
        "data": ["audio": audioHex, "status": dataStatus],
        "trace_id": traceID,
    ]
    if let metadata { root["extra_info"] = metadata }
    return senseAudioResponse(
        url: senseAudioTTSURL,
        body: root,
        statusCode: httpStatusCode)
}

private func senseAudioSpeechPlan(locale: String = "zh-Hans") -> AICueSoundPlan {
    try! AICueSoundPlanner().makePlan(
        for: try! AICueGenerationRequest(
            description: "请用清晰中文说“本轮完成”",
            locale: locale,
            providerProfileID: .senseAudioChina))
}

private func senseAudioEffectPlan(animal: Bool = false) -> AICueSoundPlan {
    try! AICueSoundPlanner().makePlan(
        for: try! AICueGenerationRequest(
            description: animal ? "  一只小猫\n短促地叫两声  " : "  短促  木琴\n音效  ",
            locale: "zh-Hans",
            providerProfileID: .senseAudioChina))
}

private func senseAudioSFXItem(
    index: Int,
    status: String = "completed",
    url: String? = nil,
    format: String? = "mp3",
    duration: Any? = 2
) -> [String: Any] {
    var item: [String: Any] = [
        "status": status,
        "variant_index": index,
    ]
    if let url { item["audio_url"] = url }
    if let format { item["output_format"] = format }
    if let duration { item["duration_seconds"] = duration }
    return item
}

private func senseAudioSFXResponse(
    status: String,
    items: [[String: Any]],
    generationID: String = "sense-sfx-fixture"
) -> AICueHTTPResponse {
    senseAudioResponse(
        url: senseAudioSFXURL,
        body: [
            "generation_id": generationID,
            "items": items,
            "status": status,
        ])
}

private func senseAudioProvider(
    transport: SenseAudioUnaryTransportFixture,
    assetFetcher: SenseAudioAssetFetcherFixture = SenseAudioAssetFetcherFixture([])
) -> SenseAudioAICueProvider {
    try! SenseAudioAICueProvider(
        registry: senseAudioRegistry(),
        unaryTransport: transport,
        assetFetcher: assetFetcher)
}

@MainActor
func runSenseAudioAICueProviderSuites() async {
    await suite("SenseAudio probe：固定 Bearer POST /v1/get_voice 并要求 system voice") {
        let transport = SenseAudioUnaryTransportFixture([.success(senseAudioProbeResponse())])
        let provider = senseAudioProvider(transport: transport)
        let secret = "fixture-senseaudio-probe-key"

        try! await provider.validateCredential(try! SensitiveCredentialInput(secret))
        let requests = await transport.requests()
        let request = requests[0]
        let body = try! JSONSerialization.jsonObject(with: request.body!) as! [String: Any]
        expect(requests.count == 1, "probe 必须只发送一次请求")
        expect(request.method == .post && request.url == senseAudioProbeURL, "probe route 必须固定")
        expect(request.expectedPath == "/v1/get_voice", "probe 必须冻结 exact path")
        expect(request.expectedOrigin.matches(senseAudioProbeURL), "probe 必须冻结 exact origin")
        expect(body as NSDictionary == ["voice_type": "all"] as NSDictionary, "probe body 必须固定")
        expect(await transport.authentications() == [.bearerAPIKey], "probe 必须使用统一 Bearer 注入")
        expect(request.headers["authorization"] == nil, "provider request 不得自行持有 Authorization")
        expect(!String(reflecting: request).contains(secret), "request 反射不得泄漏 API key")
    }

    await suite("SenseAudio probe：仅 HTTP 401 拒绝 key，业务失败、畸形响应与缺音色独立分类") {
        let cases: [(Result<AICueHTTPResponse, Error>, AICueProviderError)] = [
            (
                .failure(AICueTransportError.httpStatus(code: 401, retryAfterSeconds: nil)),
                .invalidCredential
            ),
            (.success(senseAudioProbeResponse(statusCode: 1004)), .serviceUnavailable),
            (
                .success(senseAudioProbeResponse(voiceID: "fixture-other-voice")),
                .requiredModelsUnavailable
            ),
            (.success(senseAudioProbeResponse(voiceID: nil)), .invalidAudioResponse),
            (
                .success(
                    AICueHTTPResponse(
                        statusCode: 200,
                        headers: ["content-type": "application/json"],
                        body: Data("not-json".utf8),
                        finalURL: senseAudioProbeURL)),
                .invalidAudioResponse
            ),
        ]
        for (result, expected) in cases {
            let provider = senseAudioProvider(
                transport: SenseAudioUnaryTransportFixture([result]))
            var observed: AICueProviderError?
            do {
                try await provider.validateCredential(try SensitiveCredentialInput("fixture-key"))
            } catch let error as AICueProviderError {
                observed = error
            } catch {}
            expect(observed == expected, "probe 失败必须映射为稳定且区分 credential/capability 的错误")
        }
    }

    suite("SenseAudio probe：仅确认缺固定音色时显示音色文案，并按旧 Key 状态区分") {
        let chinese = ClaudioL10n(language: .zhHans)
        let english = ClaudioL10n(language: .english)
        let missingKeyMessage = aiCueCredentialFailureText(
            .provider(.requiredModelsUnavailable),
            providerProfileID: .senseAudioChina,
            credentialStatus: .missing,
            l10n: chinese)
        let existingKeyMessage = aiCueCredentialFailureText(
            .provider(.requiredModelsUnavailable),
            providerProfileID: .senseAudioChina,
            credentialStatus: .stored(verification: .verified, hasPendingReplacement: false),
            l10n: english)
        expect(
            missingKeyMessage == chinese.text(.aiCueErrorRequiredVoiceUnavailable)
                && missingKeyMessage.contains("未保存 API Key")
                && !missingKeyMessage.contains("已有的已保存 Key"),
            "首次配置缺固定音色必须说明未保存 Key，不得声称保留不存在的旧 Key")
        expect(
            existingKeyMessage
                == english.text(.aiCueErrorRequiredVoiceUnavailableExistingKey)
                && existingKeyMessage.contains("existing saved key was not changed"),
            "替换时缺固定音色必须明确已有 Key 未更改")

        let otherProviderMessage = aiCueCredentialFailureText(
            .provider(.requiredModelsUnavailable),
            providerProfileID: .miniMaxGlobal,
            credentialStatus: .missing,
            l10n: chinese)
        let businessFailureMessage = aiCueCredentialFailureText(
            .provider(.serviceUnavailable),
            providerProfileID: .senseAudioChina,
            credentialStatus: .stored(verification: .verified, hasPendingReplacement: false),
            l10n: chinese)
        expect(
            otherProviderMessage == chinese.text(.aiCueErrorCredentialValidationFailed)
                && !otherProviderMessage.contains("所需音色"),
            "其他 Provider 的模型/响应错误不得借用 SenseAudio 固定音色文案")
        expect(
            businessFailureMessage == chinese.text(.aiCueErrorCredentialValidationFailed)
                && !businessFailureMessage.contains("所需音色")
                && !businessFailureMessage.contains("钥匙串"),
            "SenseAudio 业务错误不得伪装成缺固定音色或 Keychain 故障")
    }

    await suite("SenseAudio TTS：同一固定 body 顺序 POST 三次并返回 numbered 候选") {
        let audio = validMP3ID3Data()
        let transport = SenseAudioUnaryTransportFixture(
            (1...3).map { ordinal in
                .success(
                    senseAudioTTSResponse(
                        traceID: "sense-tts-\(ordinal)"))
            })
        let provider = senseAudioProvider(transport: transport)
        let deadline = AICueGenerationDeadline.startingNow()

        let responses = try! await provider.generateCandidateSet(
            plan: senseAudioSpeechPlan(),
            credential: try! SensitiveCredentialInput("fixture-tts-key"),
            deadline: deadline)
        let requests = await transport.requests()
        let bodies = requests.map {
            try! JSONSerialization.jsonObject(with: $0.body!) as! [String: Any]
        }
        let body = bodies[0]
        let voice = body["voice_setting"] as! [String: Any]
        let audioSettings = body["audio_setting"] as! [String: Any]
        expect(requests.count == 3, "speech 必须顺序发出恰好三个 POST")
        expect(
            requests.allSatisfy { $0.method == .post && $0.url == senseAudioTTSURL },
            "TTS route 必须固定")
        expect(requests.allSatisfy { $0.deadline == deadline }, "三个 TTS 请求必须共享 absolute deadline")
        expect(Set(requests.compactMap(\.body)).count == 1, "三个请求 body 必须完全一致")
        expect(body["model"] as? String == "sensenova-tts-2.0", "TTS model 必须固定")
        expect(body["text"] as? String == "本轮完成", "TTS 只能发送 planner 提取的台词")
        expect(body["stream"] as? Bool == false, "TTS 必须固定非流式")
        expect(
            voice["voice_id"] as? String == "female_0033_b"
                && voice["speed"] as? Int == 1
                && voice["vol"] as? Int == 1
                && voice["pitch"] as? Int == 0,
            "TTS voice 与控制参数必须固定")
        expect(
            audioSettings["format"] as? String == "mp3"
                && audioSettings["sample_rate"] as? Int == 32_000
                && audioSettings["bitrate"] as? Int == 128_000
                && audioSettings["channel"] as? Int == 1,
            "TTS 输出必须固定 32 kHz/128 kbps/mono MP3")
        expect(
            responses.map(\.identity)
                == (1...3).map { .numbered(AICueCandidateOrdinal(rawValue: $0)!) },
            "TTS 必须返回候选 1/2/3，不得伪造风格")
        expect(responses.allSatisfy { $0.audio.data == audio }, "每个响应必须是验证后的 MP3")
        expect(
            responses.map { $0.audio.requestID } == [
                "sense-tts-1", "sense-tts-2", "sense-tts-3",
            ],
            "每个候选必须保留脱敏 trace_id")
    }

    await suite("SenseAudio TTS：429 或 5xx 不自动重试可能计费的 POST") {
        let failures: [(AICueTransportError, AICueProviderError)] = [
            (.httpStatus(code: 429, retryAfterSeconds: 2), .rateLimited(retryAfterSeconds: 2)),
            (.httpStatus(code: 503, retryAfterSeconds: nil), .serviceUnavailable),
        ]
        for (transportError, expected) in failures {
            let transport = SenseAudioUnaryTransportFixture([.failure(transportError)])
            let provider = senseAudioProvider(transport: transport)
            var observed: AICueProviderError?
            do {
                _ = try await provider.generateCandidateSet(
                    plan: senseAudioSpeechPlan(),
                    credential: try SensitiveCredentialInput("fixture-key"),
                    deadline: .startingNow())
            } catch let error as AICueProviderError {
                observed = error
            } catch {}
            expect(observed == expected, "TTS transport 错误必须保持稳定分类")
            expect(await transport.requests().count == 1, "SenseAudio POST 失败不得自动 retry")
        }
    }

    await suite("SenseAudio TTS：status、hex、metadata 与 MP3 magic 任一异常均拒绝") {
        let audio = validMP3ID3Data()
        let invalid = [
            senseAudioTTSResponse(providerStatusCode: 12),
            senseAudioTTSResponse(dataStatus: 1),
            senseAudioTTSResponse(audioHex: ""),
            senseAudioTTSResponse(audioHex: "494"),
            senseAudioTTSResponse(audioHex: "not-hex!"),
            senseAudioTTSResponse(audioHex: senseAudioHex(Data("not-mp3".utf8)), metadata: nil),
            senseAudioTTSResponse(metadata: ["audio_sample_rate": 44_100]),
            senseAudioTTSResponse(metadata: ["bitrate": 64_000]),
            senseAudioTTSResponse(metadata: ["audio_channel": 2]),
            senseAudioTTSResponse(metadata: ["audio_size": audio.count + 1]),
            senseAudioTTSResponse(metadata: ["audio_format": "wav"]),
            senseAudioTTSResponse(metadata: ["audio_length": 3_001]),
            senseAudioTTSResponse(metadata: ["audio_length": true]),
        ]
        for response in invalid {
            let transport = SenseAudioUnaryTransportFixture([.success(response)])
            let provider = senseAudioProvider(transport: transport)
            var observed: AICueProviderError?
            do {
                _ = try await provider.generateCandidateSet(
                    plan: senseAudioSpeechPlan(),
                    credential: try SensitiveCredentialInput("fixture-key"),
                    deadline: .startingNow())
            } catch let error as AICueProviderError {
                observed = error
            } catch {}
            expect(observed == .invalidAudioResponse, "不可信 TTS envelope 必须 fail closed")
            expect(await transport.requests().count == 1, "首个无效 TTS 响应必须停止后续 POST")
        }
    }

    await suite("SenseAudio SFX：单次 native batch body，URL 预检后按 index 顺序下载") {
        let urls = (0...2).map {
            "\(senseAudioAssetOrigin)/generated/sfx-\($0).mp3?signature=secret-\($0)"
        }
        let response = senseAudioSFXResponse(
            status: "completed",
            items: [
                senseAudioSFXItem(index: 2, url: urls[2]),
                senseAudioSFXItem(index: 0, url: urls[0]),
                senseAudioSFXItem(index: 1, url: urls[1]),
            ])
        let transport = SenseAudioUnaryTransportFixture([.success(response)])
        let fetcher = SenseAudioAssetFetcherFixture(
            (1...3).map { _ in .success(validMP3ID3Data(), "audio/mpeg") })
        let provider = senseAudioProvider(transport: transport, assetFetcher: fetcher)

        let candidates = try! await provider.generateCandidateSet(
            plan: senseAudioEffectPlan(),
            credential: try! SensitiveCredentialInput("fixture-sfx-key"),
            deadline: .startingNow())
        let requests = await transport.requests()
        let body = try! JSONSerialization.jsonObject(with: requests[0].body!) as! [String: Any]
        expect(requests.count == 1, "SFX 必须只发送一次 native batch POST")
        expect(requests[0].url == senseAudioSFXURL, "SFX route 必须固定")
        expect(body["model"] as? String == "senseaudio-sfx-1.0-260626", "SFX model 必须固定")
        expect(body["variants_count"] as? Int == 3, "SFX 必须原生请求三个 variants")
        expect(body["duration_seconds"] as? Int == 2, "1500ms target 必须 ceil 为 2 秒")
        expect(body["smart_duration"] as? Bool == false, "SFX smart duration 必须关闭")
        expect(body["output_format"] as? String == "mp3", "SFX 输出必须固定 MP3")
        expect(body["text"] as? String == "短促 木琴 音效", "SFX prompt 必须只规范化空白")
        expect(
            await fetcher.urls() == urls.map { URL(string: $0)! },
            "全部 URL 预检后必须按 variant_index 顺序下载")
        expect(
            candidates.map(\.identity)
                == (1...3).map { .numbered(AICueCandidateOrdinal(rawValue: $0)!) },
            "SFX identity 必须从 0-based provider index 映射为候选 1/2/3")
        expect(
            candidates.allSatisfy { $0.audio.requestID == "sense-sfx-fixture" }, "batch ID 必须脱敏复用")
    }

    await suite("SenseAudio SFX：partial_success 与普通单项下载失败保留真实编号") {
        let url0 = "\(senseAudioAssetOrigin)/generated/partial-0.mp3?signature=first"
        let url2 = "\(senseAudioAssetOrigin)/generated/partial-2.mp3?signature=third"
        let response = senseAudioSFXResponse(
            status: "partial_success",
            items: [
                senseAudioSFXItem(index: 2, url: url2),
                senseAudioSFXItem(index: 1, status: "failed", format: nil, duration: nil),
                senseAudioSFXItem(index: 0, url: url0),
            ])
        let transport = SenseAudioUnaryTransportFixture([.success(response)])
        let fetcher = SenseAudioAssetFetcherFixture([
            .failure(.unexpectedMediaType),
            .success(validMP3ID3Data(), "audio/mpeg"),
        ])
        let provider = senseAudioProvider(transport: transport, assetFetcher: fetcher)

        let candidates = try! await provider.generateCandidateSet(
            plan: senseAudioEffectPlan(animal: true),
            credential: try! SensitiveCredentialInput("fixture-key"),
            deadline: .startingNow())
        expect(await transport.requests().count == 1, "animal 必须复用同一 SFX native batch route")
        expect(
            await fetcher.urls() == [URL(string: url0)!, URL(string: url2)!], "普通失败后必须继续 sibling")
        expect(
            candidates.map(\.identity)
                == [.numbered(AICueCandidateOrdinal(rawValue: 3)!)],
            "partial 必须保留真实候选 3，不得压缩成候选 1")
    }

    await suite("SenseAudio SFX：未知 batch 状态、index/URL 冲突和越界 URL 整批拒绝") {
        let url0 = "\(senseAudioAssetOrigin)/generated/structure-0.mp3?signature=zero"
        let url1 = "\(senseAudioAssetOrigin)/generated/structure-1.mp3?signature=one"
        let validItems = [
            senseAudioSFXItem(index: 0, url: url0),
            senseAudioSFXItem(index: 1, url: url1),
            senseAudioSFXItem(
                index: 2,
                url: "\(senseAudioAssetOrigin)/generated/structure-2.mp3?signature=two"),
        ]
        let invalidResponses = [
            senseAudioSFXResponse(status: "processing", items: validItems),
            senseAudioSFXResponse(
                status: "completed",
                items: [validItems[0], senseAudioSFXItem(index: 0, url: url1), validItems[2]]),
            senseAudioSFXResponse(
                status: "completed",
                items: [
                    validItems[0], validItems[1],
                    senseAudioSFXItem(index: 3, url: validItemsURL(3)),
                ]),
            senseAudioSFXResponse(
                status: "completed",
                items: [validItems[0], senseAudioSFXItem(index: 1, url: url0), validItems[2]]),
            senseAudioSFXResponse(
                status: "completed",
                items: [
                    validItems[0],
                    senseAudioSFXItem(
                        index: 1,
                        url:
                            "HTTPS://ASSETS.FIXTURE.INVALID:443/generated/structure-0.mp3?signature=zero"
                    ),
                    validItems[2],
                ]),
            senseAudioSFXResponse(status: "completed", items: Array(validItems.prefix(2))),
            senseAudioSFXResponse(
                status: "partial_success",
                items: validItems),
            senseAudioSFXResponse(
                status: "partial_success",
                items: [senseAudioSFXItem(index: 0, status: "failed", format: nil, duration: nil)]),
            senseAudioSFXResponse(
                status: "completed",
                items: [
                    senseAudioSFXItem(index: 0, url: "https://evil.invalid/leak.mp3?token=secret"),
                    validItems[1],
                    validItems[2],
                ]),
        ]
        for response in invalidResponses {
            let transport = SenseAudioUnaryTransportFixture([.success(response)])
            let fetcher = SenseAudioAssetFetcherFixture([])
            let provider = senseAudioProvider(transport: transport, assetFetcher: fetcher)
            var observed: AICueProviderError?
            do {
                _ = try await provider.generateCandidateSet(
                    plan: senseAudioEffectPlan(),
                    credential: try SensitiveCredentialInput("fixture-key"),
                    deadline: .startingNow())
            } catch let error as AICueProviderError {
                observed = error
            } catch {}
            expect(observed == .invalidAudioResponse, "SFX batch 结构冲突必须整批 fail closed")
            expect(await fetcher.urls().isEmpty, "完整 batch 通过预检前不得下载任何 URL")
        }
    }

    await suite("SenseAudio SFX：completed 单项声明缺失可降级，cancel/deadline 必须整批终止") {
        let urls = (0...2).map {
            "\(senseAudioAssetOrigin)/generated/degrade-\($0).mp3?signature=\($0)"
        }
        let degradedResponse = senseAudioSFXResponse(
            status: "completed",
            items: [
                senseAudioSFXItem(index: 0, url: urls[0]),
                senseAudioSFXItem(index: 1, url: nil),
                senseAudioSFXItem(index: 2, url: urls[2], format: "wav"),
            ])
        let degradedFetcher = SenseAudioAssetFetcherFixture([
            .success(validMP3ID3Data(), "audio/mpeg")
        ])
        let degraded = try! await senseAudioProvider(
            transport: SenseAudioUnaryTransportFixture([.success(degradedResponse)]),
            assetFetcher: degradedFetcher
        ).generateCandidateSet(
            plan: senseAudioEffectPlan(),
            credential: try! SensitiveCredentialInput("fixture-key"),
            deadline: .startingNow())
        expect(
            degraded.map(\.identity)
                == [.numbered(AICueCandidateOrdinal(rawValue: 1)!)],
            "completed batch 的缺失 URL/格式声明只能淘汰对应单项")

        let terminalFailures: [(AICueAssetFetchError, AICueProviderError)] = [
            (AICueAssetFetchError.cancelled, AICueProviderError.cancelled),
            (.deadlineExceeded, .deadlineExceeded),
        ]
        for (assetError, expected) in terminalFailures {
            let fetcher = SenseAudioAssetFetcherFixture([.failure(assetError)])
            let provider = senseAudioProvider(
                transport: SenseAudioUnaryTransportFixture([
                    .success(
                        senseAudioSFXResponse(
                            status: "completed",
                            items: (0...2).map {
                                senseAudioSFXItem(index: $0, url: urls[$0])
                            }))
                ]),
                assetFetcher: fetcher)
            var observed: AICueProviderError?
            do {
                _ = try await provider.generateCandidateSet(
                    plan: senseAudioEffectPlan(),
                    credential: try SensitiveCredentialInput("fixture-key"),
                    deadline: .startingNow())
            } catch let error as AICueProviderError {
                observed = error
            } catch {}
            expect(observed == expected, "cancel/deadline 不得降级为 partial")
            expect(await fetcher.urls().count == 1, "终止错误后不得继续 sibling 下载")
        }
    }
}

private func validItemsURL(_ index: Int) -> String {
    "\(senseAudioAssetOrigin)/generated/structure-\(index).mp3?signature=\(index)"
}
