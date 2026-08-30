import ClaudioGUICore
import Foundation

private enum QwenStreamFixtureResult {
    case events([AICueSSEEvent])
    case failure(AICueTransportError)
}

private final class QwenSSETransportFixture: AICueSSETransport, @unchecked Sendable {
    private let lock = NSLock()
    private var queued: [QwenStreamFixtureResult]
    private var capturedRequests: [AICueTransportRequest] = []
    private var capturedAuthentications: [AICueProviderAuthentication] = []

    init(_ queued: [QwenStreamFixtureResult]) {
        self.queued = queued
    }

    func events(
        for request: AICueTransportRequest,
        authentication: AICueProviderAuthentication,
        credential: SensitiveCredentialInput
    ) -> AsyncThrowingStream<AICueSSEEvent, Error> {
        lock.lock()
        capturedRequests.append(request)
        capturedAuthentications.append(authentication)
        let result =
            queued.isEmpty ? .failure(AICueTransportError.transportFailure) : queued.removeFirst()
        lock.unlock()
        return AsyncThrowingStream { continuation in
            switch result {
            case .events(let events):
                for event in events { continuation.yield(event) }
                continuation.finish()
            case .failure(let error):
                continuation.finish(throwing: error)
            }
        }
    }

    func requests() -> [AICueTransportRequest] {
        lock.lock()
        defer { lock.unlock() }
        return capturedRequests
    }

    func authentications() -> [AICueProviderAuthentication] {
        lock.lock()
        defer { lock.unlock() }
        return capturedAuthentications
    }
}

private actor QwenGenerationVaultFixture: AICueCredentialVault {
    private let slotID: AICueCredentialSlotID
    private var readSlots: [AICueCredentialSlotID] = []

    init(slotID: AICueCredentialSlotID) {
        self.slotID = slotID
    }

    func containsCredential(in slotID: AICueCredentialSlotID) async throws -> Bool {
        slotID == self.slotID
    }

    func credential(in slotID: AICueCredentialSlotID) async throws -> SensitiveCredentialInput? {
        readSlots.append(slotID)
        guard slotID == self.slotID else { return nil }
        return try SensitiveCredentialInput("fixture-qwen-generation-key")
    }

    func replaceCredential(
        _ credential: SensitiveCredentialInput,
        in slotID: AICueCredentialSlotID
    ) async throws {}

    func deleteCredential(in slotID: AICueCredentialSlotID) async throws {}

    func reads() -> [AICueCredentialSlotID] { readSlots }
}

private let qwenPath = "/api/v1/services/aigc/multimodal-generation/generation"
private let qwenSingaporeURL = URL(
    string: "https://dashscope-intl.aliyuncs.com\(qwenPath)")!
private let qwenBeijingURL = URL(
    string: "https://dashscope.aliyuncs.com\(qwenPath)")!

private func qwenJSON(
    pcm: Data? = nil,
    terminal: Bool = false,
    requestID: String = "fixture-qwen-request",
    statusCode: Int = 200,
    remoteURL: Any? = nil,
    audioOverrides: [String: Any] = [:]
) -> String {
    var audio: [String: Any] = ["data": pcm?.base64EncodedString() ?? ""]
    if let remoteURL { audio["url"] = remoteURL }
    for (key, value) in audioOverrides { audio[key] = value }
    let finishReason: Any = terminal ? "stop" : NSNull()
    let root: [String: Any] = [
        "output": [
            "audio": audio,
            "finish_reason": finishReason,
        ],
        "request_id": requestID,
        "status_code": statusCode,
    ]
    let data = try! JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    return String(decoding: data, as: UTF8.self)
}

private func qwenEvent(_ json: String) -> AICueSSEEvent {
    AICueSSEEvent(dataLines: [json])
}

private func qwenParsedEvents(
    pcmFragments: [Data],
    lineEnding: String = "\n",
    requestID: String = "fixture-qwen-request",
    remoteURL: String = "https://untrusted.example.invalid/result.wav",
    byteByByte: Bool = true
) -> [AICueSSEEvent] {
    let payloads =
        pcmFragments.map { qwenJSON(pcm: $0, requestID: requestID) }
        + [qwenJSON(terminal: true, requestID: requestID, remoteURL: remoteURL)]
    let wire = payloads.map { "data: \($0)\(lineEnding)\(lineEnding)" }.joined()
    var parser = AICueSSEParser(maximumWireBytes: AICueTransportCeilings.qwenSSEWireBytes)
    var events: [AICueSSEEvent] = []
    if byteByByte {
        for byte in Data(wire.utf8) {
            events.append(contentsOf: try! parser.append(Data([byte])))
        }
    } else {
        events.append(contentsOf: try! parser.append(Data(wire.utf8)))
    }
    _ = try! parser.finish()
    return events
}

private func validQwenRequest(
    profileID: AICueProviderProfileID = .qwenSingapore,
    modality: AICueModality = .speech,
    languageTag: String? = "zh-Hans",
    spokenContent: String? = "本轮完成"
) -> AICueProviderRequest {
    AICueProviderRequest(
        profileID: profileID,
        modality: modality,
        prompt: "[clear] 本轮完成",
        spokenContent: spokenContent,
        languageTag: languageTag,
        targetDurationMilliseconds: 2_400,
        variant: .clear)
}

private func qwenUInt16(_ data: Data, at offset: Int) -> UInt16 {
    UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
}

private func qwenUInt32(_ data: Data, at offset: Int) -> UInt32 {
    UInt32(data[offset])
        | (UInt32(data[offset + 1]) << 8)
        | (UInt32(data[offset + 2]) << 16)
        | (UInt32(data[offset + 3]) << 24)
}

private func qwenProviderError(
    provider: QwenAICueProvider,
    request: AICueProviderRequest = validQwenRequest()
) async -> AICueProviderError? {
    do {
        _ = try await provider.generateCandidate(
            request: request,
            credential: try SensitiveCredentialInput("fixture-key"),
            deadline: .startingNow())
        return nil
    } catch let error as AICueProviderError {
        return error
    } catch {
        return .transportFailure
    }
}

@MainActor
func runQwenAICueProviderSuites() async {
    suite("Qwen registry：两个 deferred speech profile 严格隔离") {
        let singapore = try! QwenAICueProvider(
            profileID: .qwenSingapore,
            sseTransport: QwenSSETransportFixture([]))
        let beijing = try! QwenAICueProvider(
            profileID: .qwenBeijing,
            sseTransport: QwenSSETransportFixture([]))
        expect(singapore.profile.credentialSlotID == .qwenSingapore, "Singapore 必须使用独立 slot")
        expect(beijing.profile.credentialSlotID == .qwenBeijing, "Beijing 必须使用独立 slot")
        expect(
            singapore.profile.routes[.speech]?.endpoint == qwenSingaporeURL,
            "Singapore endpoint 必须由 registry 固定")
        expect(
            beijing.profile.routes[.speech]?.endpoint == qwenBeijingURL,
            "Beijing endpoint 必须由 registry 固定")
        let contractsAreFixed = [singapore.profile, beijing.profile].allSatisfy { profile in
            guard let route = profile.routes[.speech] else { return false }
            return profile.supportedModalities == [.speech]
                && route.modelID == "qwen3-tts-instruct-flash"
                && route.voiceID == "Cherry"
                && route.supportedLanguageTags == ["zh*", "en*"]
                && profile.credentialValidationPolicy == .deferredUntilExplicitGeneration
        }
        expect(
            contractsAreFixed,
            "两个 region 只能共享固定 speech 能力，不能共享 endpoint/credential")
        expect(
            (try? QwenAICueProvider(
                profileID: .miniMaxGlobal,
                sseTransport: QwenSSETransportFixture([]))) == nil,
            "非 Qwen profile 必须拒绝")
    }

    await suite("Qwen credential：probe seam fail closed 且网络计数为 0") {
        let transport = QwenSSETransportFixture([])
        let provider = try! QwenAICueProvider(
            profileID: .qwenSingapore,
            sseTransport: transport)
        var rejected = false
        do {
            try await provider.validateCredential(try SensitiveCredentialInput("fixture-key"))
        } catch AICueProviderError.invalidRequest {
            rejected = true
        } catch {}
        expect(rejected, "Qwen 不得伪造 read-only probe")
        expect(transport.requests().isEmpty, "保存/probe seam 不得触发模型请求")
    }

    await suite("Qwen adapter：双区域固定 Bearer/SSE/model/voice 并封装合法 WAV") {
        let pcm = Data([0x00, 0x00, 0x01, 0x00, 0xFE, 0xFF, 0xFF, 0x7F])
        let cases: [(AICueProviderProfileID, URL, String)] = [
            (.qwenSingapore, qwenSingaporeURL, "zh-Hant"),
            (.qwenBeijing, qwenBeijingURL, "en-US"),
        ]
        for (index, item) in cases.enumerated() {
            let transport = QwenSSETransportFixture([
                .events(
                    qwenParsedEvents(
                        pcmFragments: [Data(pcm.prefix(4)), Data(pcm.suffix(4))],
                        lineEnding: index == 0 ? "\n" : "\r\n"))
            ])
            let provider = try! QwenAICueProvider(
                profileID: item.0,
                sseTransport: transport)
            let response = try! await provider.generateCandidate(
                request: validQwenRequest(profileID: item.0, languageTag: item.2),
                credential: try! SensitiveCredentialInput("fixture-region-key"),
                deadline: .startingNow())
            let request = transport.requests()[0]
            let body = try! JSONSerialization.jsonObject(with: request.body!) as! [String: Any]
            let input = body["input"] as! [String: Any]

            expect(request.method == .post && request.url == item.1, "region endpoint/path 必须固定")
            expect(request.expectedPath == qwenPath, "Qwen path 必须冻结")
            expect(request.expectedOrigin.matches(item.1), "origin 必须与所选 region 精确匹配")
            expect(transport.authentications() == [.bearerAPIKey], "认证只能由 SSE transport 注入 Bearer")
            expect(request.headers["Authorization"] == nil, "公共 request 不得携带 secret header")
            expect(request.headers["X-DashScope-SSE"] == "enable", "必须显式启用 SSE")
            expect(request.maximumWireBytes == 256 * 1_024, "SSE wire ceiling 必须为 256 KiB")
            expect(body["model"] as? String == "qwen3-tts-instruct-flash", "model 必须固定")
            expect(input["voice"] as? String == "Cherry", "voice 必须固定")
            expect(input["text"] as? String == "本轮完成", "text 只能是明确引号台词")
            expect(
                input["language_type"] as? String == (index == 0 ? "Chinese" : "English"),
                "locale 只能按 zh*/en* 映射")
            expect(
                response.mediaType == "audio/wav" && response.modelID == "qwen3-tts-instruct-flash",
                "响应 provenance 必须固定")
            expect(response.requestID == "fixture-qwen-request", "只能保留脱敏 request id")
            expect(String(decoding: response.data.prefix(4), as: UTF8.self) == "RIFF", "必须生成 RIFF")
            expect(
                String(decoding: response.data[8..<12], as: UTF8.self) == "WAVE", "必须生成 WAVE form")
            expect(qwenUInt32(response.data, at: 4) == UInt32(36 + pcm.count), "RIFF size 必须正确")
            expect(qwenUInt16(response.data, at: 20) == 1, "WAV 必须是 PCM")
            expect(qwenUInt16(response.data, at: 22) == 1, "WAV 必须 mono")
            expect(qwenUInt32(response.data, at: 24) == 24_000, "WAV 必须 24 kHz")
            expect(qwenUInt32(response.data, at: 28) == 48_000, "WAV byte rate 必须正确")
            expect(qwenUInt16(response.data, at: 32) == 2, "WAV block align 必须正确")
            expect(qwenUInt16(response.data, at: 34) == 16, "WAV 必须 signed 16-bit")
            expect(qwenUInt32(response.data, at: 40) == UInt32(pcm.count), "data chunk size 必须正确")
            expect(response.data.suffix(pcm.count) == pcm, "PCM 内容不得被改写")
            expect(transport.requests().count == 1, "末包 URL 只能丢弃，绝不能发第二次下载")
        }
    }

    await suite("Qwen adapter：三个候选保留同一台词并传递各自 instruction") {
        let responseEvents = qwenParsedEvents(pcmFragments: [Data([0, 0, 1, 0])])
        let transport = QwenSSETransportFixture(
            AICueVariant.allCases.map { _ in .events(responseEvents) })
        let provider = try! QwenAICueProvider(
            profileID: .qwenSingapore,
            sseTransport: transport)
        let generationRequest = try! AICueGenerationRequest(
            description: "用温和的声音说“可以继续”",
            locale: "zh-Hans",
            providerProfileID: .qwenSingapore)
        let plan = try! AICueSoundPlanner().makePlan(for: generationRequest)
        let compiledRequests = AICueVariant.allCases.map {
            try! AICueProviderRequestCompiler().compile(
                plan: plan,
                profileID: generationRequest.providerProfileID,
                variant: $0)
        }

        for request in compiledRequests {
            _ = try! await provider.generateCandidate(
                request: request,
                credential: try! SensitiveCredentialInput("fixture-key"),
                deadline: .startingNow())
        }

        let inputs = transport.requests().map {
            let body = try! JSONSerialization.jsonObject(with: $0.body!) as! [String: Any]
            return body["input"] as! [String: Any]
        }
        expect(
            inputs.map { $0["text"] as? String } == Array(repeating: "可以继续", count: 3),
            "Qwen A/B/C 的 text 必须只是同一明确台词")
        expect(
            inputs.map { $0["instructions"] as? String } == compiledRequests.map(\.prompt),
            "Qwen A/B/C 必须逐条传递 provider-neutral compiler 的 instruction")
        expect(
            Set(inputs.compactMap { $0["instructions"] as? String }).count == 3
                && inputs.allSatisfy { ($0["instructions"] as? String)?.contains("温和") == true },
            "Qwen A/B/C 请求体必须有三条保留用户 style 的真实变体指令")
    }

    await suite("Qwen adapter：能力、locale、台词、profile 与 deadline 在网络前失败") {
        let transport = QwenSSETransportFixture([])
        let provider = try! QwenAICueProvider(
            profileID: .qwenSingapore,
            sseTransport: transport)
        let invalidRequests = [
            validQwenRequest(modality: .animal, languageTag: nil, spokenContent: nil),
            validQwenRequest(modality: .soundEffect, languageTag: nil, spokenContent: nil),
            validQwenRequest(modality: .mixed),
            validQwenRequest(languageTag: "fr"),
            validQwenRequest(languageTag: "english"),
            validQwenRequest(languageTag: "en", spokenContent: nil),
            validQwenRequest(profileID: .qwenBeijing),
        ]
        for request in invalidRequests {
            expect(
                await qwenProviderError(provider: provider, request: request) == .invalidRequest,
                "不支持的 request 必须本地 fail closed")
        }
        var expired = false
        do {
            _ = try await provider.generateCandidate(
                request: validQwenRequest(),
                credential: try SensitiveCredentialInput("fixture-key"),
                deadline: AICueGenerationDeadline(
                    startedAtUptimeNanoseconds: 0,
                    durationNanoseconds: 0))
        } catch AICueProviderError.deadlineExceeded {
            expired = true
        } catch {}
        expect(expired, "过期 absolute deadline 必须先于 transport 拒绝")
        expect(transport.requests().isEmpty, "本地门禁失败不得发网络")
    }

    await suite("Qwen adapter：Base64、格式与 terminal/EOF 顺序异常全部失败关闭") {
        let pcm = Data([0, 0, 1, 0])
        let data = qwenEvent(qwenJSON(pcm: pcm))
        let terminal = qwenEvent(
            qwenJSON(terminal: true, remoteURL: "https://example.invalid/audio.wav"))
        let malformed = qwenEvent("{not-json")
        let invalidBase64 = qwenEvent(qwenJSON(pcm: nil, audioOverrides: ["data": "not-base64!"]))
        let formatDrift = qwenEvent(qwenJSON(pcm: pcm, audioOverrides: ["sample_rate": 44_100]))
        let dataWithURL = qwenEvent(
            qwenJSON(pcm: pcm, remoteURL: "https://example.invalid/early.wav"))
        let terminalWithData = qwenEvent(
            qwenJSON(
                pcm: pcm,
                terminal: true,
                remoteURL: "https://example.invalid/audio.wav"))
        let mismatchedTerminal = qwenEvent(
            qwenJSON(
                terminal: true,
                requestID: "fixture-other-request",
                remoteURL: "https://example.invalid/audio.wav"))
        let cases: [[AICueSSEEvent]] = [
            [data],
            [data, terminal, terminal],
            [data, terminal, data],
            [terminal],
            [malformed, terminal],
            [invalidBase64, terminal],
            [formatDrift, terminal],
            [dataWithURL, terminal],
            [data, terminalWithData],
            [data, mismatchedTerminal],
        ]
        for events in cases {
            let provider = try! QwenAICueProvider(
                profileID: .qwenSingapore,
                sseTransport: QwenSSETransportFixture([.events(events)]))
            expect(
                await qwenProviderError(provider: provider) == .invalidAudioResponse,
                "畸形 SSE/Base64/format/terminal 必须稳定拒绝")
        }
    }

    await suite("Qwen adapter：PCM/WAV ceilings 在边界精确执行") {
        let maximumPCM = Data(repeating: 0, count: AICueTransportCeilings.qwenDecodedPCMBytes)
        let successTransport = QwenSSETransportFixture([
            .events(qwenParsedEvents(pcmFragments: [maximumPCM], byteByByte: false))
        ])
        let successProvider = try! QwenAICueProvider(
            profileID: .qwenSingapore,
            sseTransport: successTransport)
        let response = try! await successProvider.generateCandidate(
            request: validQwenRequest(),
            credential: try! SensitiveCredentialInput("fixture-key"),
            deadline: .startingNow())
        expect(response.data.count == 144_044, "合法最大 PCM 必须封装为最大 144,044-byte WAV")

        let oversized = Data(
            repeating: 0,
            count: AICueTransportCeilings.qwenDecodedPCMBytes + 2)
        let oversizedProvider = try! QwenAICueProvider(
            profileID: .qwenSingapore,
            sseTransport: QwenSSETransportFixture([
                .events(qwenParsedEvents(pcmFragments: [oversized], byteByByte: false))
            ]))
        expect(
            await qwenProviderError(provider: oversizedProvider) == .responseTooLarge,
            "decoded PCM 超过 144,000 bytes 必须单独映射 responseTooLarge")
    }

    await suite("Qwen adapter：认证/权限/限流/5xx/取消映射为脱敏统一错误") {
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
            let provider = try! QwenAICueProvider(
                profileID: .qwenSingapore,
                sseTransport: QwenSSETransportFixture([.failure(transportError)]))
            expect(await qwenProviderError(provider: provider) == expected, "transport 错误必须脱敏映射")
        }
    }

    await suite("Qwen generation：统一 deadline 顺序生成恰好 3 个 WAV 候选") {
        await withTempDirectory { root in
            let pcm = Data([0, 0, 1, 0])
            let transport = QwenSSETransportFixture(
                (1...3).map { ordinal in
                    .events(
                        qwenParsedEvents(
                            pcmFragments: [pcm],
                            requestID: "fixture-qwen-\(ordinal)"))
                })
            let vault = QwenGenerationVaultFixture(slotID: .qwenSingapore)
            let temporaryRoot = root.appendingPathComponent("qwen", isDirectory: true)
            let engine = AICueGenerationEngine(
                vault: vault,
                provider: try! QwenAICueProvider(
                    profileID: .qwenSingapore,
                    sseTransport: transport),
                temporaryRoot: temporaryRoot,
                durationProbe: StubDurationProbe(fixedDuration: 1.2))
            let generation = try! await engine.generate(
                description: "用清晰中文说“本轮完成”",
                locale: "zh-Hant",
                providerProfileID: .qwenSingapore,
                deadline: .startingNow())
            expect(transport.requests().count == 3, "一次 generation 必须恰好三个顺序 SSE 请求")
            expect(
                generation.candidates.map(\.variant) == [.clear, .brisk, .restrained],
                "候选身份必须稳定为 A/B/C")
            expect(
                generation.candidates.allSatisfy {
                    $0.asset.sniffedFormat == .wav
                        && $0.provenance.providerID == .qwen
                        && $0.provenance.profileID == .qwenSingapore
                        && $0.provenance.modelID == "qwen3-tts-instruct-flash"
                        && FileManager.default.fileExists(atPath: $0.asset.fileURL.path)
                },
                "三候选必须全部通过 WAV/AudioImport/provenance 门禁")
            let readSlots = await vault.reads()
            let allowedSlots: Set<AICueCredentialSlotID> = [
                .qwenSingapore, .qwenSingaporePending,
            ]
            expect(
                readSlots.contains(.qwenSingapore)
                    && Set(readSlots).isSubset(of: allowedSlots),
                "generation 只能读取所选 region key，不得跨区")
        }
    }

    await suite("Qwen generation：第三候选失败不发布 partial 且清理临时文件") {
        await withTempDirectory { root in
            let valid = qwenParsedEvents(pcmFragments: [Data([0, 0, 1, 0])])
            let transport = QwenSSETransportFixture([
                .events(valid),
                .events(valid),
                .events([qwenEvent("{invalid")]),
            ])
            let temporaryRoot = root.appendingPathComponent("qwen-partial", isDirectory: true)
            let engine = AICueGenerationEngine(
                vault: QwenGenerationVaultFixture(slotID: .qwenBeijing),
                provider: try! QwenAICueProvider(
                    profileID: .qwenBeijing,
                    sseTransport: transport),
                temporaryRoot: temporaryRoot,
                durationProbe: StubDurationProbe(fixedDuration: 1))
            var rejected = false
            do {
                _ = try await engine.generate(
                    description: "Say \"Task complete\" clearly",
                    locale: "en-GB",
                    providerProfileID: .qwenBeijing,
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
