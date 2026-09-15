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

private struct SenseAudioAssetLoaderFacts: Sendable {
    let requests: [URLRequest]
    let deadlines: [AICueGenerationDeadline]
    let maximumWireBytes: [Int]
    let maximumInFlight: Int
}

private actor SenseAudioBudgetAssetLoaderFixture: AICueAssetLoading {
    private var steps: [Result<AICueFetchedAsset, AICueAssetFetchError>]
    private var requests: [URLRequest] = []
    private var deadlines: [AICueGenerationDeadline] = []
    private var wireCeilings: [Int] = []
    private var inFlight = 0
    private var maximumInFlight = 0

    init(_ steps: [Result<AICueFetchedAsset, AICueAssetFetchError>]) {
        self.steps = steps
    }

    func load(
        _ request: URLRequest,
        acceptedMediaTypes: Set<String>,
        maximumWireBytes: Int,
        deadline: AICueGenerationDeadline
    ) async throws -> AICueFetchedAsset {
        requests.append(request)
        deadlines.append(deadline)
        wireCeilings.append(maximumWireBytes)
        inFlight += 1
        maximumInFlight = max(maximumInFlight, inFlight)
        defer { inFlight -= 1 }
        await Task.yield()
        guard !steps.isEmpty else { throw AICueAssetFetchError.transportFailure }
        return try steps.removeFirst().get()
    }

    func facts() -> SenseAudioAssetLoaderFacts {
        SenseAudioAssetLoaderFacts(
            requests: requests,
            deadlines: deadlines,
            maximumWireBytes: wireCeilings,
            maximumInFlight: maximumInFlight)
    }
}

private actor SenseAudioAssetRetrySleeperFixture: AICueAssetRetrySleeping {
    private var delays: [Int] = []

    func sleep(seconds: Int) {
        delays.append(seconds)
    }

    func facts() -> [Int] { delays }
}

private enum SenseAudioAssetRetrySleeperFixtureError: Error, Sendable {
    case failed
}

private actor SenseAudioFailingAssetRetrySleeperFixture: AICueAssetRetrySleeping {
    private var delays: [Int] = []

    func sleep(seconds: Int) throws {
        delays.append(seconds)
        throw SenseAudioAssetRetrySleeperFixtureError.failed
    }

    func facts() -> [Int] { delays }
}

private struct SenseAudioGenerationVaultFacts: Sendable {
    let reads: Int
    let replacements: Int
    let deletions: Int
    let slots: Set<AICueCredentialSlotID>
}

private actor SenseAudioGenerationVaultFixture: AICueCredentialVault {
    private var credentials: [AICueCredentialSlotID: SensitiveCredentialInput] = [
        .senseAudioChina: try! SensitiveCredentialInput("fixture-active-senseaudio-key")
    ]
    private var reads = 0
    private var replacements = 0
    private var deletions = 0

    func containsCredential(in slotID: AICueCredentialSlotID) -> Bool {
        credentials[slotID] != nil
    }

    func credential(in slotID: AICueCredentialSlotID) -> SensitiveCredentialInput? {
        reads += 1
        return credentials[slotID]
    }

    func replaceCredential(
        _ credential: SensitiveCredentialInput,
        in slotID: AICueCredentialSlotID
    ) {
        replacements += 1
        credentials[slotID] = credential
    }

    func deleteCredential(in slotID: AICueCredentialSlotID) {
        deletions += 1
        credentials.removeValue(forKey: slotID)
    }

    func facts() -> SenseAudioGenerationVaultFacts {
        SenseAudioGenerationVaultFacts(
            reads: reads,
            replacements: replacements,
            deletions: deletions,
            slots: Set(credentials.keys))
    }
}

private struct SenseAudioCredentialMetadataFacts: Sendable {
    let value: AICueCredentialVerification?
    let writes: Int
}

private actor SenseAudioCredentialMetadataFixture: AICueCredentialMetadataStoring {
    private var value: AICueCredentialVerification? = .verified
    private var writes = 0

    func verification(
        for profileID: AICueProviderProfileID
    ) -> AICueCredentialVerification? {
        value
    }

    func setVerification(
        _ verification: AICueCredentialVerification?,
        for profileID: AICueProviderProfileID
    ) {
        writes += 1
        value = verification
    }

    func facts() -> SenseAudioCredentialMetadataFacts {
        SenseAudioCredentialMetadataFacts(value: value, writes: writes)
    }
}

private struct SenseAudioSelectiveDurationProbe: AudioDurationProbing {
    let rejectedOrdinals: Set<Int>

    func probeDuration(of fileURL: URL) -> TimeInterval? {
        rejectedOrdinals.contains { ordinal in
            fileURL.lastPathComponent.hasPrefix("candidate-\(ordinal).")
        } ? nil : 1
    }
}

private final class SenseAudioSecondWriteFailureProbe: AudioDurationProbing, @unchecked Sendable {
    private let lock = NSLock()
    private var callCount = 0

    func probeDuration(of fileURL: URL) -> TimeInterval? {
        let shouldRemoveDirectory = lock.withLock { () -> Bool in
            callCount += 1
            return callCount == 1
        }
        if shouldRemoveDirectory {
            try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
        }
        return 1
    }
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
    assetFetcher: any AICueAssetFetching = SenseAudioAssetFetcherFixture([])
) -> SenseAudioAICueProvider {
    try! SenseAudioAICueProvider(
        registry: senseAudioRegistry(),
        unaryTransport: transport,
        assetFetcher: assetFetcher)
}

@MainActor
func runSenseAudioAICueProviderSuites() async {
    await suite("SenseAudio SFX：资源合同违约立即整批失败，成功首项不得授权 partial") {
        let violations: [AICueAssetFetchError] = [
            .invalidURL, .unexpectedMediaType, .redirectRejected,
            .httpStatus(code: 401, retryAfterSeconds: nil),
            .httpStatus(code: 403, retryAfterSeconds: nil),
        ]
        for violation in violations {
            let response = senseAudioSFXResponse(
                status: "completed",
                items: (0...2).map {
                    senseAudioSFXItem(index: $0, url: "\(senseAudioAssetOrigin)/contract-\($0).mp3")
                })
            let transport = SenseAudioUnaryTransportFixture([.success(response)])
            let fetcher = SenseAudioAssetFetcherFixture([
                .success(validMP3ID3Data(), "audio/mpeg"), .failure(violation),
                .success(validMP3ID3Data(), "audio/mpeg"),
            ])
            let provider = senseAudioProvider(transport: transport, assetFetcher: fetcher)
            var observed: AICueProviderError?
            do {
                _ = try await provider.generateCandidateSet(
                    plan: senseAudioEffectPlan(),
                    credential: try SensitiveCredentialInput("fixture-only-contract-key"),
                    deadline: .startingNow())
            } catch let error as AICueProviderError { observed = error } catch {}
            expect(observed == .invalidAudioResponse, "违约不能发布已成功的 sibling")
            expect(await fetcher.urls().count == 2, "第二项违约后不得发出第三项 GET 或重试")
            expect(await transport.requests().count == 1, "违约不追加付费 POST")
        }
    }
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

    await suite("SenseAudio TTS：第 1/2/3 次失败均不重试可能计费的 POST") {
        let failures: [(AICueTransportError, AICueProviderError)] = [
            (.httpStatus(code: 429, retryAfterSeconds: 2), .rateLimited(retryAfterSeconds: 2)),
            (.httpStatus(code: 503, retryAfterSeconds: nil), .serviceUnavailable),
            (.transportFailure, .transportFailure),
        ]
        for failureOrdinal in 1...3 {
            for (transportError, expected) in failures {
                var steps: [Result<AICueHTTPResponse, Error>] = (1..<failureOrdinal).map {
                    .success(senseAudioTTSResponse(traceID: "prior-\($0)"))
                }
                steps.append(.failure(transportError))
                let transport = SenseAudioUnaryTransportFixture(steps)
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
                expect(
                    await transport.requests().count == failureOrdinal,
                    "TTS 第 1/2/3 次失败只能保留此前请求，不得 retry 或发布 partial")
            }
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
        expect(
            requests[0].responseStartPolicy == .generationDeadline,
            "SFX 长计算 POST 的响应头等待必须共享调用方冻结的 route generation deadline")
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

    await suite("SenseAudio SFX：生成 POST 的 429/5xx/timeout/network 永不自动重试") {
        let failures: [(AICueTransportError, AICueProviderError)] = [
            (.httpStatus(code: 429, retryAfterSeconds: 2), .rateLimited(retryAfterSeconds: 2)),
            (.httpStatus(code: 503, retryAfterSeconds: nil), .serviceUnavailable),
            (.inactivityTimeout, .transportFailure),
            (.transportFailure, .transportFailure),
        ]
        for (transportError, expected) in failures {
            let transport = SenseAudioUnaryTransportFixture([
                .failure(transportError),
                .success(
                    senseAudioSFXResponse(
                        status: "completed",
                        items: (0...2).map {
                            senseAudioSFXItem(index: $0, url: validItemsURL($0))
                        })),
            ])
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
            expect(observed == expected, "SFX POST transport 错误必须保持稳定分类")
            expect(await transport.requests().count == 1, "SFX native batch POST 绝不自动 retry")
            expect(await fetcher.urls().isEmpty, "SFX POST 失败不得开始 asset GET")
        }
    }

    await suite("SenseAudio SFX：最多三项六次 GET、共享 deadline 且严格串行") {
        let urls = (0...2).map {
            URL(
                string:
                    "\(senseAudioAssetOrigin)/generated/budget-\($0).mp3?signature=opaque-\($0)"
            )!
        }
        let response = senseAudioSFXResponse(
            status: "completed",
            items: (0...2).map { senseAudioSFXItem(index: $0, url: urls[$0].absoluteString) })
        let fetched = AICueFetchedAsset(data: validMP3ID3Data(), mediaType: "audio/mpeg")
        var steps: [Result<AICueFetchedAsset, AICueAssetFetchError>] = []
        for _ in 0..<3 {
            steps.append(.failure(.transientNetwork))
            steps.append(.success(fetched))
        }
        let loader = SenseAudioBudgetAssetLoaderFixture(steps)
        let sleeper = SenseAudioAssetRetrySleeperFixture()
        let assetFetcher = AICueURLSessionAssetFetcher(loader: loader, retrySleeper: sleeper)
        let transport = SenseAudioUnaryTransportFixture([.success(response)])
        let provider = senseAudioProvider(transport: transport, assetFetcher: assetFetcher)
        let deadline = AICueGenerationDeadline.startingNow()

        let candidates = try! await provider.generateCandidateSet(
            plan: senseAudioEffectPlan(),
            credential: try! SensitiveCredentialInput("fixture-key"),
            deadline: deadline)
        let facts = await loader.facts()
        expect(candidates.count == 3, "三个 asset 各一次 transient retry 后应保持 complete set")
        expect(await transport.requests().count == 1, "六次 GET 不得增加第二次 SFX POST")
        expect(
            facts.requests.count == 6
                && facts.maximumInFlight == 1
                && facts.deadlines == Array(repeating: deadline, count: 6)
                && facts.maximumWireBytes.allSatisfy {
                    $0 == AICueURLSessionAssetFetcher.maximumWireBytes
                },
            "三项 asset 必须最多六次 attempt、共享一个绝对预算且在途上限为一")
        expect(
            stride(from: 0, to: 6, by: 2).allSatisfy { offset in
                facts.requests[offset].url == urls[offset / 2]
                    && facts.requests[offset + 1].url == urls[offset / 2]
                    && facts.requests[offset].value(forHTTPHeaderField: "Authorization") == nil
                    && facts.requests[offset + 1].value(forHTTPHeaderField: "Authorization") == nil
            },
            "每项 retry 必须保持同 URL，六个 GET 都不得带 credential")
        expect(await sleeper.facts().isEmpty, "transient GET retry 不使用 429 backoff")
        expect(
            candidates.reduce(0) { $0 + $1.audio.data.count }
                <= 3 * AICueURLSessionAssetFetcher.maximumWireBytes,
            "存活的三项候选 payload 必须受 15 MiB 上界约束")
    }

    await suite("SenseAudio SFX：backoff 基础设施故障终止整批而非静默 partial") {
        let urls = (0...2).map {
            URL(
                string:
                    "\(senseAudioAssetOrigin)/generated/backoff-failure-\($0).mp3?signature=opaque-\($0)"
            )!
        }
        let response = senseAudioSFXResponse(
            status: "completed",
            items: (0...2).map { senseAudioSFXItem(index: $0, url: urls[$0].absoluteString) })
        let fetched = AICueFetchedAsset(data: validMP3ID3Data(), mediaType: "audio/mpeg")
        let loader = SenseAudioBudgetAssetLoaderFixture([
            .failure(.httpStatus(code: 429, retryAfterSeconds: 1)),
            .success(fetched),
            .success(fetched),
        ])
        let sleeper = SenseAudioFailingAssetRetrySleeperFixture()
        let assetFetcher = AICueURLSessionAssetFetcher(loader: loader, retrySleeper: sleeper)
        let provider = senseAudioProvider(
            transport: SenseAudioUnaryTransportFixture([.success(response)]),
            assetFetcher: assetFetcher)

        var observed: AICueProviderError?
        do {
            _ = try await provider.generateCandidateSet(
                plan: senseAudioEffectPlan(),
                credential: try SensitiveCredentialInput("fixture-key"),
                deadline: .startingNow())
        } catch let error as AICueProviderError {
            observed = error
        } catch {}
        let facts = await loader.facts()
        expect(observed == .transportFailure, "backoff 基础设施故障必须保持整批 transport failure")
        expect(facts.requests.count == 1, "backoff 基础设施故障后不得下载 sibling 或发布 partial")
        expect(await sleeper.facts() == [1], "429 backoff 必须进入一次受控等待后终止")
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
            .failure(.httpStatus(code: 404, retryAfterSeconds: nil)),
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

    await suite("SenseAudio SFX：声明 MP3 但实际为 WAV/AIFF 时只淘汰对应单项") {
        let urls = (0...2).map {
            "\(senseAudioAssetOrigin)/generated/sniff-\($0).mp3?signature=\($0)"
        }
        let response = senseAudioSFXResponse(
            status: "completed",
            items: (0...2).map { senseAudioSFXItem(index: $0, url: urls[$0]) })
        let provider = senseAudioProvider(
            transport: SenseAudioUnaryTransportFixture([.success(response)]),
            assetFetcher: SenseAudioAssetFetcherFixture([
                .success(validWAVData(), "audio/mpeg"),
                .success(validMP3ID3Data(), "audio/mpeg"),
                .success(validAIFFData(), "audio/mpeg"),
            ]))

        let candidates = try! await provider.generateCandidateSet(
            plan: senseAudioEffectPlan(),
            credential: try! SensitiveCredentialInput("fixture-key"),
            deadline: .startingNow())
        expect(
            candidates.map(\.identity)
                == [.numbered(AICueCandidateOrdinal(rawValue: 2)!)],
            "SFX adapter 必须按实际字节只保留真正的 MP3，并保留 provider ordinal")

        let noMP3Provider = senseAudioProvider(
            transport: SenseAudioUnaryTransportFixture([.success(response)]),
            assetFetcher: SenseAudioAssetFetcherFixture([
                .success(validWAVData(), "audio/mpeg"),
                .success(validAIFFData(), "audio/mpeg"),
                .success(Data("not-audio".utf8), "audio/mpeg"),
            ]))
        let noMP3Candidates = try! await noMP3Provider.generateCandidateSet(
            plan: senseAudioEffectPlan(),
            credential: try! SensitiveCredentialInput("fixture-key"),
            deadline: .startingNow())
        expect(noMP3Candidates.isEmpty, "零个真实 MP3 必须交由 engine 判定 insufficient candidates")
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
            let fetcher = SenseAudioAssetFetcherFixture([
                .success(validMP3ID3Data(), "audio/mpeg"),
                .failure(assetError),
            ])
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
            expect(observed == expected, "首项成功后的 cancel/deadline 不得降级为 partial")
            expect(await fetcher.urls().count == 2, "第二项终止错误后不得继续第三个 sibling 下载")
        }
    }

    await suite("SenseAudio→Engine：asset 401 整批失败，不污染 active credential") {
        await withTempDirectory { root in
            let urls = (0...2).map {
                "\(senseAudioAssetOrigin)/generated/unauthorized-\($0).mp3?signature=secret-\($0)"
            }
            let transport = SenseAudioUnaryTransportFixture([
                .success(
                    senseAudioSFXResponse(
                        status: "completed",
                        items: (0...2).map {
                            senseAudioSFXItem(index: $0, url: urls[$0])
                        }))
            ])
            let fetcher = SenseAudioAssetFetcherFixture(
                (0...2).map { _ in
                    .failure(.httpStatus(code: 401, retryAfterSeconds: nil))
                })
            let registry = senseAudioRegistry()
            let provider = try! SenseAudioAICueProvider(
                registry: registry,
                unaryTransport: transport,
                assetFetcher: fetcher)
            let vault = SenseAudioGenerationVaultFixture()
            let metadata = SenseAudioCredentialMetadataFixture()
            let manager = AICueCredentialManager(
                vault: vault,
                registry: registry,
                validators: [.senseAudioChina: provider],
                metadata: metadata)
            let temporaryRoot = root.appendingPathComponent("asset-401", isDirectory: true)
            let engine = AICueGenerationEngine(
                credentialManager: manager,
                candidateSetProvider: provider,
                temporaryRoot: temporaryRoot,
                durationProbe: StubDurationProbe(fixedDuration: 1),
                registry: registry)

            var observed: AICueGenerationError?
            do {
                _ = try await engine.generate(
                    description: "短促木琴音效",
                    locale: "zh-Hans",
                    providerProfileID: .senseAudioChina,
                    deadline: .startingNow())
            } catch let error as AICueGenerationError {
                observed = error
            } catch {}
            let vaultFacts = await vault.facts()
            let metadataFacts = await metadata.facts()
            let postCount = await transport.requests().count
            let assetCount = await fetcher.urls().count
            let temporaryContents =
                (try? FileManager.default.contentsOfDirectory(
                    at: temporaryRoot,
                    includingPropertiesForKeys: nil)) ?? []
            expect(observed == .provider(.invalidAudioResponse), "asset 401 必须终止本次生成")
            expect(
                postCount == 1 && assetCount == 1,
                "首项 asset 401 后不继续 sibling，不追加生成 POST")
            expect(
                vaultFacts.reads == 1 && vaultFacts.replacements == 0
                    && vaultFacts.deletions == 0
                    && vaultFacts.slots == [.senseAudioChina]
                    && metadataFacts.value == .verified
                    && metadataFacts.writes == 0,
                "asset 401 不得映射 invalid credential、拒绝或删除 active key")
            expect(temporaryContents.isEmpty, "零候选失败必须清理本次 generation child")
            expect(
                !String(reflecting: observed).contains("secret-")
                    && !String(reflecting: observed).contains("fixture-active-senseaudio-key"),
                "generation 错误不得包含 asset query 或 credential")
        }
    }

    await suite("SenseAudio→Engine：remote complete 可本地降级 partial，zero 必须清理") {
        await withTempDirectory { root in
            let urls = (0...2).map {
                "\(senseAudioAssetOrigin)/generated/local-validation-\($0).mp3?signature=\($0)"
            }
            let response = senseAudioSFXResponse(
                status: "completed",
                items: (0...2).map { senseAudioSFXItem(index: $0, url: urls[$0]) })
            let registry = senseAudioRegistry()

            let partialTransport = SenseAudioUnaryTransportFixture([.success(response)])
            let partialFetcher = SenseAudioAssetFetcherFixture(
                (0...2).map { _ in .success(validMP3ID3Data(), "audio/mpeg") })
            let partialProvider = try! SenseAudioAICueProvider(
                registry: registry,
                unaryTransport: partialTransport,
                assetFetcher: partialFetcher)
            let partialVault = SenseAudioGenerationVaultFixture()
            let partialMetadata = SenseAudioCredentialMetadataFixture()
            let partialManager = AICueCredentialManager(
                vault: partialVault,
                registry: registry,
                validators: [.senseAudioChina: partialProvider],
                metadata: partialMetadata)
            let partialRoot = root.appendingPathComponent("local-partial", isDirectory: true)
            let partialEngine = AICueGenerationEngine(
                credentialManager: partialManager,
                candidateSetProvider: partialProvider,
                temporaryRoot: partialRoot,
                durationProbe: SenseAudioSelectiveDurationProbe(rejectedOrdinals: [2]),
                registry: registry)

            let generation = try! await partialEngine.generate(
                description: "短促木琴音效",
                locale: "zh-Hans",
                providerProfileID: .senseAudioChina,
                deadline: .startingNow())
            expect(generation.completion == .partial, "remote complete 不能覆盖本地 duration 淘汰结果")
            expect(
                generation.candidates.map(\.identity)
                    == [1, 3].map { .numbered(AICueCandidateOrdinal(rawValue: $0)!) },
                "本地 partial 必须保留真实 provider ordinal [1,3]")
            let partialPostCount = await partialTransport.requests().count
            let partialAssetCount = await partialFetcher.urls().count
            expect(
                partialPostCount == 1 && partialAssetCount == 3,
                "本地验证发生在一次 POST 与三个顺序 asset GET 之后")
            await partialEngine.discard(generationID: generation.id)
            expect(
                generation.candidates.allSatisfy {
                    !FileManager.default.fileExists(atPath: $0.asset.fileURL.path)
                },
                "显式 discard 必须清理允许发布的 partial generation")

            let zeroTransport = SenseAudioUnaryTransportFixture([.success(response)])
            let zeroFetcher = SenseAudioAssetFetcherFixture(
                (0...2).map { _ in .success(validMP3ID3Data(), "audio/mpeg") })
            let zeroProvider = try! SenseAudioAICueProvider(
                registry: registry,
                unaryTransport: zeroTransport,
                assetFetcher: zeroFetcher)
            let zeroMetadata = SenseAudioCredentialMetadataFixture()
            let zeroManager = AICueCredentialManager(
                vault: SenseAudioGenerationVaultFixture(),
                registry: registry,
                validators: [.senseAudioChina: zeroProvider],
                metadata: zeroMetadata)
            let zeroRoot = root.appendingPathComponent("local-zero", isDirectory: true)
            let zeroEngine = AICueGenerationEngine(
                credentialManager: zeroManager,
                candidateSetProvider: zeroProvider,
                temporaryRoot: zeroRoot,
                durationProbe: SenseAudioSelectiveDurationProbe(rejectedOrdinals: [1, 2, 3]),
                registry: registry)
            var zeroError: AICueGenerationError?
            do {
                _ = try await zeroEngine.generate(
                    description: "短促木琴音效",
                    locale: "zh-Hans",
                    providerProfileID: .senseAudioChina,
                    deadline: .startingNow())
            } catch let error as AICueGenerationError {
                zeroError = error
            } catch {}
            let zeroContents =
                (try? FileManager.default.contentsOfDirectory(
                    at: zeroRoot,
                    includingPropertiesForKeys: nil)) ?? []
            expect(zeroError == .insufficientValidCandidates, "remote complete 的零个本地有效项必须失败")
            expect(zeroContents.isEmpty, "zero-valid generation 必须清理全部临时文件")
            expect(await zeroMetadata.facts().writes == 0, "零候选失败不得提交 credential 验证")
        }
    }

    await suite("SenseAudio→Engine：首项落盘后第二项 storage failure 整批清理") {
        await withTempDirectory { root in
            let urls = (0...2).map { validItemsURL($0) }
            let transport = SenseAudioUnaryTransportFixture([
                .success(
                    senseAudioSFXResponse(
                        status: "completed",
                        items: (0...2).map {
                            senseAudioSFXItem(index: $0, url: urls[$0])
                        }))
            ])
            let fetcher = SenseAudioAssetFetcherFixture(
                (0...2).map { _ in .success(validMP3ID3Data(), "audio/mpeg") })
            let registry = senseAudioRegistry()
            let provider = try! SenseAudioAICueProvider(
                registry: registry,
                unaryTransport: transport,
                assetFetcher: fetcher)
            let metadata = SenseAudioCredentialMetadataFixture()
            let manager = AICueCredentialManager(
                vault: SenseAudioGenerationVaultFixture(),
                registry: registry,
                validators: [.senseAudioChina: provider],
                metadata: metadata)
            let temporaryRoot = root.appendingPathComponent("second-storage", isDirectory: true)
            let engine = AICueGenerationEngine(
                credentialManager: manager,
                candidateSetProvider: provider,
                temporaryRoot: temporaryRoot,
                durationProbe: SenseAudioSecondWriteFailureProbe(),
                registry: registry)

            var observed: AICueGenerationError?
            do {
                _ = try await engine.generate(
                    description: "短促木琴音效",
                    locale: "zh-Hans",
                    providerProfileID: .senseAudioChina,
                    deadline: .startingNow())
            } catch let error as AICueGenerationError {
                observed = error
            } catch {}
            let contents =
                (try? FileManager.default.contentsOfDirectory(
                    at: temporaryRoot,
                    includingPropertiesForKeys: nil)) ?? []
            expect(observed == .temporaryStorageUnavailable, "第二项本地写入失败不得降级为 partial")
            expect(contents.isEmpty, "storage failure 必须清理首项已创建的 generation 内容")
            expect(await metadata.facts().writes == 0, "storage failure 不得提交 credential 验证")
        }
    }
}

private func validItemsURL(_ index: Int) -> String {
    "\(senseAudioAssetOrigin)/generated/structure-\(index).mp3?signature=\(index)"
}
