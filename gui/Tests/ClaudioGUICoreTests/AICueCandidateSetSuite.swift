import ClaudioGUICore
import Foundation

private enum CandidateSetProviderStep: Sendable {
    case success
    case failure(AICueProviderError)
}

private actor CandidateSetLegacyProviderFixture: AICueProvider {
    nonisolated let profile: AICueProviderProfile
    private var steps: [CandidateSetProviderStep]
    private var capturedRequests: [AICueProviderRequest] = []

    init(profileID: AICueProviderProfileID, steps: [CandidateSetProviderStep]) {
        profile = try! AICueProviderRegistry().profile(for: profileID)
        self.steps = steps
    }

    func validateCredential(_ credential: SensitiveCredentialInput) async throws {}

    func generateCandidate(
        request: AICueProviderRequest,
        credential: SensitiveCredentialInput,
        deadline: AICueGenerationDeadline
    ) async throws -> AICueProviderAudioResponse {
        capturedRequests.append(request)
        guard !steps.isEmpty else { throw AICueProviderError.transportFailure }
        switch steps.removeFirst() {
        case .success:
            return AICueProviderAudioResponse(
                data: validMP3ID3Data(),
                mediaType: "audio/mpeg",
                modelID: profile.routes[request.modality]!.modelID,
                requestID: "candidate-set-\(capturedRequests.count)")
        case .failure(let error):
            throw error
        }
    }

    func requests() -> [AICueProviderRequest] { capturedRequests }
}

private actor CandidateSetRetrySleeperFixture: AICueRetrySleeping {
    private var delays: [Int] = []

    func sleep(seconds: Int) async throws {
        delays.append(seconds)
    }

    func observedDelays() -> [Int] { delays }
}

private actor NativeCandidateSetProviderFixture: AICueCandidateSetProvider {
    nonisolated let profile: AICueProviderProfile
    private let responses: [AICueProviderCandidateResponse]
    private var plans: [AICueSoundPlan] = []

    init(
        profileID: AICueProviderProfileID,
        responses: [AICueProviderCandidateResponse],
        registry: AICueProviderRegistry = AICueProviderRegistry()
    ) {
        profile = try! registry.profile(for: profileID)
        self.responses = responses
    }

    func validateCredential(_ credential: SensitiveCredentialInput) async throws {}

    func generateCandidateSet(
        plan: AICueSoundPlan,
        credential: SensitiveCredentialInput,
        deadline: AICueGenerationDeadline
    ) async throws -> [AICueProviderCandidateResponse] {
        plans.append(plan)
        return responses
    }

    func receivedPlans() -> [AICueSoundPlan] { plans }
}

private struct CandidateSetSelectiveDurationProbe: AudioDurationProbing {
    let rejectedOrdinals: Set<Int>

    func probeDuration(of fileURL: URL) -> TimeInterval? {
        rejectedOrdinals.contains { fileURL.lastPathComponent.hasPrefix("candidate-\($0).") }
            ? nil : 1
    }
}

private actor CandidateSetCredentialManagerFixture: AICueGenerationCredentialManaging {
    private let lease: AICueGenerationCredential
    private var validationCount = 0

    init(profileID: AICueProviderProfileID) {
        lease = AICueGenerationCredential(
            profileID: profileID,
            credential: try! SensitiveCredentialInput("fixture-candidate-set-key"),
            source: .active,
            revision: 0)
    }

    func credentialForGeneration(
        for profileID: AICueProviderProfileID
    ) async throws -> AICueGenerationCredential {
        lease
    }

    func generationDidValidate(_ lease: AICueGenerationCredential) async throws {
        validationCount += 1
    }

    func generation(
        _ lease: AICueGenerationCredential,
        didFailWith error: AICueProviderError
    ) async {}

    func validations() -> Int { validationCount }
}

private func candidateSetPlan(profileID: AICueProviderProfileID) -> AICueSoundPlan {
    try! AICueSoundPlanner().makePlan(
        for: try! AICueGenerationRequest(
            description: "请用清晰中文说“完成”",
            locale: "zh-Hans",
            providerProfileID: profileID))
}

private func candidateSetResponse(
    identity: AICueCandidateIdentity,
    data: Data = validMP3ID3Data()
) -> AICueProviderCandidateResponse {
    AICueProviderCandidateResponse(
        identity: identity,
        audio: AICueProviderAudioResponse(
            data: data,
            mediaType: "audio/mpeg",
            modelID: "fixture-model",
            requestID: "candidate-set-\(identity.ordinal)"))
}

private func candidateSetEvidenceRegistry() -> AICueProviderRegistry {
    let policy = try! AICueAssetPolicy(
        allowedOrigins: [try! AICueAssetOrigin("https://assets.fixture.invalid")],
        acceptedMediaTypes: ["audio/mpeg"])
    return AICueProviderRegistry(evidenceGatedSenseAudioAssetPolicy: policy)
}

@MainActor
func runAICueCandidateSetSuites() async {
    suite("AI 提示音 candidate identity：ordinal 仅允许 1...3 且 styled 不伪造 numbered") {
        expect(AICueCandidateOrdinal(rawValue: 0) == nil, "候选编号 0 必须不可表示")
        expect(AICueCandidateOrdinal(rawValue: 4) == nil, "候选编号 4 必须不可表示")
        let second = AICueCandidateOrdinal(rawValue: 2)!
        expect(second.rawValue == 2, "候选编号必须保留稳定原值")
        expect(
            AICueCandidateIdentity.styled(.brisk).styledVariant == .brisk,
            "styled identity 必须可读取原变体")
        expect(
            AICueCandidateIdentity.numbered(second).styledVariant == nil,
            "numbered identity 不得伪造清晰/轻快/克制风格")
    }

    await suite("AI 提示音 legacy adapter：styled 与 numbered policy 决定候选身份") {
        let cases: [(AICueProviderProfileID, [AICueCandidateIdentity])] = [
            (
                .elevenLabsGlobal,
                AICueVariant.allCases.map(AICueCandidateIdentity.styled)
            ),
            (
                .miniMaxGlobal,
                (1...3).map {
                    .numbered(AICueCandidateOrdinal(rawValue: $0)!)
                }
            ),
        ]
        for (profileID, expectedIdentities) in cases {
            let provider = CandidateSetLegacyProviderFixture(
                profileID: profileID,
                steps: [.success, .success, .success])
            let adapter = SequentialAICueCandidateSetAdapter(provider: provider)
            let responses = try! await adapter.generateCandidateSet(
                plan: candidateSetPlan(profileID: profileID),
                credential: try! SensitiveCredentialInput("fixture-key"),
                deadline: .startingNow())
            expect(responses.map(\.identity) == expectedIdentities, "候选身份必须只由 route policy 决定")
            expect(await provider.requests().count == 3, "legacy adapter 必须保持三个顺序请求")
        }
    }

    await suite("AI 提示音 legacy adapter：整个候选集合最多消费一次 1...5 秒 429 retry") {
        let provider = CandidateSetLegacyProviderFixture(
            profileID: .elevenLabsGlobal,
            steps: [
                .failure(.rateLimited(retryAfterSeconds: 2)),
                .success,
                .success,
                .failure(.rateLimited(retryAfterSeconds: 3)),
            ])
        let sleeper = CandidateSetRetrySleeperFixture()
        let adapter = SequentialAICueCandidateSetAdapter(
            provider: provider,
            registry: AICueProviderRegistry(),
            retrySleeper: sleeper)
        var observed: AICueProviderError?
        do {
            _ = try await adapter.generateCandidateSet(
                plan: candidateSetPlan(profileID: .elevenLabsGlobal),
                credential: try SensitiveCredentialInput("fixture-key"),
                deadline: .startingNow())
        } catch let error as AICueProviderError {
            observed = error
        } catch {}
        expect(observed == .rateLimited(retryAfterSeconds: 3), "第二个 429 必须直接结束集合生成")
        expect(await sleeper.observedDelays() == [2], "整个集合只能执行一次保守 retry")
        expect(await provider.requests().count == 4, "retry 只能增加一次 legacy POST")
    }

    await suite("AI 提示音 candidate-set engine：乱序 styled 响应排序后完整提交") {
        await withTempDirectory { root in
            let responses = [
                candidateSetResponse(identity: .styled(.restrained)),
                candidateSetResponse(identity: .styled(.clear)),
                candidateSetResponse(identity: .styled(.brisk)),
            ]
            let provider = NativeCandidateSetProviderFixture(
                profileID: .elevenLabsGlobal,
                responses: responses)
            let credentials = CandidateSetCredentialManagerFixture(
                profileID: .elevenLabsGlobal)
            let engine = AICueGenerationEngine(
                credentialManager: credentials,
                candidateSetProvider: provider,
                temporaryRoot: root.appendingPathComponent("candidate-set-complete"),
                durationProbe: StubDurationProbe(fixedDuration: 1))

            let generation = try! await engine.generate(
                description: "请用清晰中文说“完成”",
                locale: "zh-Hans",
                providerProfileID: .elevenLabsGlobal,
                deadline: .startingNow())
            expect(generation.completion == .complete, "三个本地有效候选必须标记 complete")
            expect(
                generation.candidates.map(\.styledVariant)
                    == AICueVariant.allCases.map(Optional.some),
                "engine 必须按稳定 identity ordinal 排序")
            expect(await provider.receivedPlans().count == 1, "native provider 每次只接收一个 plan")
            expect(await credentials.validations() == 1, "完整集合只能提交一次 credential 验证")
        }
    }

    await suite("AI 提示音 candidate-set engine：重复或错误语义 identity 整批拒绝并清理") {
        await withTempDirectory { root in
            let invalidSets: [[AICueProviderCandidateResponse]] = [
                [
                    candidateSetResponse(identity: .styled(.clear)),
                    candidateSetResponse(identity: .styled(.clear)),
                    candidateSetResponse(identity: .styled(.restrained)),
                ],
                (1...3).map {
                    candidateSetResponse(
                        identity: .numbered(AICueCandidateOrdinal(rawValue: $0)!))
                },
            ]
            for (index, responses) in invalidSets.enumerated() {
                let temporaryRoot = root.appendingPathComponent("invalid-set-\(index)")
                let engine = AICueGenerationEngine(
                    credentialManager: CandidateSetCredentialManagerFixture(
                        profileID: .elevenLabsGlobal),
                    candidateSetProvider: NativeCandidateSetProviderFixture(
                        profileID: .elevenLabsGlobal,
                        responses: responses),
                    temporaryRoot: temporaryRoot,
                    durationProbe: StubDurationProbe(fixedDuration: 1))
                var rejected = false
                do {
                    _ = try await engine.generate(
                        description: "请用清晰中文说“完成”",
                        locale: "zh-Hans",
                        providerProfileID: .elevenLabsGlobal,
                        deadline: .startingNow())
                } catch AICueGenerationError.provider(.invalidAudioResponse) {
                    rejected = true
                } catch {}
                expect(rejected, "重复或错误语义 identity 必须视为不可信 provider 响应")
                let contents =
                    (try? FileManager.default.contentsOfDirectory(atPath: temporaryRoot.path)) ?? []
                expect(contents.isEmpty, "结构失败不得留下候选目录")
            }
        }
    }

    await suite("AI 提示音 candidate-set engine：少于 route minimum 时不发布") {
        await withTempDirectory { root in
            let temporaryRoot = root.appendingPathComponent("insufficient-set")
            let engine = AICueGenerationEngine(
                credentialManager: CandidateSetCredentialManagerFixture(
                    profileID: .elevenLabsGlobal),
                candidateSetProvider: NativeCandidateSetProviderFixture(
                    profileID: .elevenLabsGlobal,
                    responses: [candidateSetResponse(identity: .styled(.clear))]),
                temporaryRoot: temporaryRoot,
                durationProbe: StubDurationProbe(fixedDuration: 1))
            var insufficient = false
            do {
                _ = try await engine.generate(
                    description: "请用清晰中文说“完成”",
                    locale: "zh-Hans",
                    providerProfileID: .elevenLabsGlobal,
                    deadline: .startingNow())
            } catch AICueGenerationError.insufficientValidCandidates {
                insufficient = true
            } catch {}
            expect(insufficient, "候选数低于 route minimum 必须稳定失败")
            let contents =
                (try? FileManager.default.contentsOfDirectory(atPath: temporaryRoot.path)) ?? []
            expect(contents.isEmpty, "不足 minimum 必须清理整次 generation")
        }
    }

    await suite("AI 提示音 candidate-set engine：numbered route 可由本地验证降级为 partial") {
        await withTempDirectory { root in
            let registry = candidateSetEvidenceRegistry()
            let responses = (1...3).map {
                candidateSetResponse(
                    identity: .numbered(AICueCandidateOrdinal(rawValue: $0)!))
            }
            let provider = NativeCandidateSetProviderFixture(
                profileID: .senseAudioChina,
                responses: responses,
                registry: registry)
            let credentials = CandidateSetCredentialManagerFixture(profileID: .senseAudioChina)
            let engine = AICueGenerationEngine(
                credentialManager: credentials,
                candidateSetProvider: provider,
                temporaryRoot: root.appendingPathComponent("candidate-set-partial"),
                durationProbe: CandidateSetSelectiveDurationProbe(rejectedOrdinals: [2]),
                registry: registry)

            let generation = try! await engine.generate(
                description: "短促木琴音效",
                locale: "zh-Hans",
                providerProfileID: .senseAudioChina,
                deadline: .startingNow())
            expect(generation.completion == .partial, "1...2 个本地有效候选必须标记 partial")
            expect(
                generation.candidates.map(\.identity)
                    == [1, 3].map {
                        .numbered(AICueCandidateOrdinal(rawValue: $0)!)
                    },
                "partial 必须保留真实 numbered identity，不得重新编号")
            let directory = generation.candidates[0].asset.fileURL.deletingLastPathComponent()
            expect(
                !FileManager.default.fileExists(
                    atPath: directory.appendingPathComponent("candidate-2.mp3").path),
                "被 duration 门禁淘汰的单项文件必须立即清理")
            expect(await credentials.validations() == 1, "允许的 partial 必须提交 credential 验证")
        }
    }

    await suite("AI 提示音 candidate-set engine：本地有效项少于 minimum 时整批清理") {
        await withTempDirectory { root in
            let registry = candidateSetEvidenceRegistry()
            let responses = (1...3).map {
                candidateSetResponse(
                    identity: .numbered(AICueCandidateOrdinal(rawValue: $0)!))
            }
            let temporaryRoot = root.appendingPathComponent("candidate-set-zero-valid")
            let engine = AICueGenerationEngine(
                credentialManager: CandidateSetCredentialManagerFixture(
                    profileID: .senseAudioChina),
                candidateSetProvider: NativeCandidateSetProviderFixture(
                    profileID: .senseAudioChina,
                    responses: responses,
                    registry: registry),
                temporaryRoot: temporaryRoot,
                durationProbe: CandidateSetSelectiveDurationProbe(rejectedOrdinals: [1, 2, 3]),
                registry: registry)

            var insufficient = false
            do {
                _ = try await engine.generate(
                    description: "短促木琴音效",
                    locale: "zh-Hans",
                    providerProfileID: .senseAudioChina,
                    deadline: .startingNow())
            } catch AICueGenerationError.insufficientValidCandidates {
                insufficient = true
            } catch {}
            expect(insufficient, "零个本地有效候选必须返回 insufficientValidCandidates")
            let contents =
                (try? FileManager.default.contentsOfDirectory(atPath: temporaryRoot.path)) ?? []
            expect(contents.isEmpty, "零有效候选不得留下 generation 目录")
        }
    }
}
