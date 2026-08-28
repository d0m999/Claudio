import ClaudioGUICore
import Dispatch
import Foundation

private actor GenerationVaultFixture: AICueCredentialVault {
    let configured: Bool
    private(set) var credentialReadCount = 0

    init(configured: Bool) { self.configured = configured }

    func containsCredential(for providerID: AICueProviderID) async throws -> Bool { configured }
    func credential(for providerID: AICueProviderID) async throws -> SensitiveCredentialInput? {
        credentialReadCount += 1
        return configured ? try! SensitiveCredentialInput("fixture-generation-key") : nil
    }
    func replaceCredential(
        _ credential: SensitiveCredentialInput,
        for providerID: AICueProviderID
    ) async throws {}
    func deleteCredential(for providerID: AICueProviderID) async throws {}

    func reads() -> Int { credentialReadCount }
}

private actor GenerationSlowVaultFixture: AICueCredentialVault {
    func containsCredential(for providerID: AICueProviderID) async throws -> Bool { true }

    func credential(for providerID: AICueProviderID) async throws -> SensitiveCredentialInput? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.2) {
                continuation.resume(returning: try! SensitiveCredentialInput("fixture-key"))
            }
        }
    }

    func replaceCredential(
        _ credential: SensitiveCredentialInput,
        for providerID: AICueProviderID
    ) async throws {}

    func deleteCredential(for providerID: AICueProviderID) async throws {}
}

private enum GenerationProviderStep: Sendable {
    case success(Data)
    case failure(AICueProviderError)
}

private actor GenerationProviderFixture: AICueProvider {
    private var steps: [GenerationProviderStep]
    private var captured: [AICueProviderRequest] = []
    private var capturedDeadlines: [AICueGenerationDeadline] = []

    nonisolated let profile: AICueProviderProfile = try! AICueProviderRegistry().profile(
        for: .elevenLabsGlobal)

    init(steps: [GenerationProviderStep]) { self.steps = steps }

    func validateCredential(_ credential: SensitiveCredentialInput) async throws {}

    func generateCandidate(
        request: AICueProviderRequest,
        credential: SensitiveCredentialInput,
        deadline: AICueGenerationDeadline
    ) async throws -> AICueProviderAudioResponse {
        captured.append(request)
        capturedDeadlines.append(deadline)
        guard !steps.isEmpty else { throw AICueProviderError.serviceUnavailable }
        switch steps.removeFirst() {
        case .success(let data):
            return AICueProviderAudioResponse(
                data: data,
                mediaType: "audio/mpeg",
                modelID: profile.routes[request.modality]!.modelID,
                requestID: "fixture-\(captured.count)")
        case .failure(let error):
            throw error
        }
    }

    func requests() -> [AICueProviderRequest] { captured }
    func deadlines() -> [AICueGenerationDeadline] { capturedDeadlines }
}

private actor GenerationRetrySleeperFixture: AICueRetrySleeping {
    private(set) var delays: [Int] = []

    func sleep(seconds: Int) async throws {
        delays.append(seconds)
    }

    func observedDelays() -> [Int] { delays }
}

private actor GenerationBlockingProviderFixture: AICueProvider {
    nonisolated let profile: AICueProviderProfile = try! AICueProviderRegistry().profile(
        for: .elevenLabsGlobal)
    private(set) var requestCount = 0
    private(set) var cancellationCount = 0

    func validateCredential(_ credential: SensitiveCredentialInput) async throws {}

    func generateCandidate(
        request: AICueProviderRequest,
        credential: SensitiveCredentialInput,
        deadline: AICueGenerationDeadline
    ) async throws -> AICueProviderAudioResponse {
        requestCount += 1
        do {
            try await Task.sleep(nanoseconds: 1_000_000_000)
        } catch {
            cancellationCount += 1
            throw AICueProviderError.cancelled
        }
        throw AICueProviderError.transportFailure
    }

    func counts() -> (requests: Int, cancellations: Int) {
        (requestCount, cancellationCount)
    }
}

private actor GenerationIgnoringCancellationProviderFixture: AICueProvider {
    nonisolated let profile: AICueProviderProfile = try! AICueProviderRegistry().profile(
        for: .elevenLabsGlobal)

    func validateCredential(_ credential: SensitiveCredentialInput) async throws {}

    func generateCandidate(
        request: AICueProviderRequest,
        credential: SensitiveCredentialInput,
        deadline: AICueGenerationDeadline
    ) async throws -> AICueProviderAudioResponse {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.2) {
                continuation.resume(
                    returning: AICueProviderAudioResponse(
                        data: validMP3ID3Data(),
                        mediaType: "audio/mpeg",
                        modelID: "fixture-model",
                        requestID: nil))
            }
        }
    }
}

private final class GenerationSlowThirdDurationProbe: AudioDurationProbing, @unchecked Sendable {
    private let lock = NSLock()
    private var invocationCount = 0

    func probeDuration(of fileURL: URL) -> TimeInterval? {
        let invocation = lock.withLock {
            invocationCount += 1
            return invocationCount
        }
        if invocation == 3 { Thread.sleep(forTimeInterval: 0.3) }
        return 1
    }
}

private actor GenerationSlowRetrySleeperFixture: AICueRetrySleeping {
    private(set) var invocationCount = 0

    func sleep(seconds: Int) async throws {
        invocationCount += 1
        try await Task.sleep(nanoseconds: 100_000_000)
    }

    func calls() -> Int { invocationCount }
}

@MainActor
func runAICueGenerationEngineSuites() async {
    await suite("AI 提示音生成：profile、能力、locale 与台词门禁先于 key/network") {
        await withTempDirectory { root in
            let vault = GenerationVaultFixture(configured: true)
            let provider = GenerationProviderFixture(steps: [])
            let tempRoot = root.appendingPathComponent("preflight", isDirectory: true)
            let engine = AICueGenerationEngine(
                vault: vault,
                provider: provider,
                temporaryRoot: tempRoot,
                durationProbe: StubDurationProbe(fixedDuration: 1))
            let cases: [(String, String, AICueProviderProfileID)] = [
                ("Say Task complete", "en", .elevenLabsGlobal),
                ("说任务完成", "zh-Hans", .elevenLabsGlobal),
                ("Say \"   \"", "en", .elevenLabsGlobal),
                ("Say \"Task complete", "en", .elevenLabsGlobal),
                ("一只小猫短促叫两声", "zh-Hans", .miniMaxGlobal),
                ("Say \"Bonjour\"", "fr", .qwenSingapore),
                ("短促木琴音效", "zh-Hans", AICueProviderProfileID(rawValue: "unknown")),
            ]

            for (description, locale, profileID) in cases {
                do {
                    _ = try await engine.generate(
                        description: description,
                        locale: locale,
                        providerProfileID: profileID,
                        deadline: .startingNow())
                } catch {}
            }

            expect(await vault.reads() == 0, "本地门禁失败不能读取任何 credential")
            expect(await provider.requests().isEmpty, "本地门禁失败不能调用 provider")
            expect(!FileManager.default.fileExists(atPath: tempRoot.path), "本地门禁失败不能建临时目录")
        }
    }

    await suite("AI 提示音生成：缺少 key 时不调用 provider、不创建候选") {
        await withTempDirectory { root in
            let provider = GenerationProviderFixture(steps: [])
            let engine = AICueGenerationEngine(
                vault: GenerationVaultFixture(configured: false),
                provider: provider,
                temporaryRoot: root.appendingPathComponent("ai-cues", isDirectory: true),
                durationProbe: StubDurationProbe(fixedDuration: 1))
            var missing = false
            do {
                _ = try await engine.generate(
                    description: "短促木琴音效",
                    locale: "zh-Hans",
                    providerProfileID: .elevenLabsGlobal,
                    deadline: .startingNow())
            } catch AICueGenerationError.credentialRequired {
                missing = true
            } catch {}
            expect(missing, "缺少 key 必须返回 credentialRequired")
            expect(await provider.requests().isEmpty, "缺少 key 时网络调用必须为零")
            expect(
                !FileManager.default.fileExists(
                    atPath: root.appendingPathComponent("ai-cues").path),
                "缺少 key 时连临时根目录都不应创建")
        }
    }

    await suite("AI 提示音生成：顺序生成 A/B/C，三项校验后才返回私有临时文件") {
        await withTempDirectory { root in
            let audio = validMP3ID3Data()
            let provider = GenerationProviderFixture(steps: [
                .success(audio), .success(audio), .success(audio),
            ])
            let tempRoot = root.appendingPathComponent("ai-cues", isDirectory: true)
            let engine = AICueGenerationEngine(
                vault: GenerationVaultFixture(configured: true),
                provider: provider,
                temporaryRoot: tempRoot,
                durationProbe: StubDurationProbe(fixedDuration: 1.25))

            let generation = try! await engine.generate(
                description: "一只小猫短促叫两声，不要背景音乐",
                locale: "zh-Hans",
                providerProfileID: .elevenLabsGlobal,
                deadline: .startingNow())
            expect(generation.candidates.map(\.variant) == [.clear, .brisk, .restrained], "候选必须稳定按 A/B/C 返回")
            expect(generation.candidates.count == 3, "不能展示少于或多于三个候选")
            expect(generation.profileID == .elevenLabsGlobal, "generation 必须冻结 profile identity")
            expect(
                generation.candidates.allSatisfy {
                    $0.provenance.profileID == generation.profileID
                },
                "每个候选 provenance 必须匹配 generation profile")
            expect(await provider.requests().count == 3, "每个候选必须恰好一个顺序子请求")
            expect(
                generation.candidates.allSatisfy {
                    $0.asset.sniffedFormat == .mp3
                        && $0.asset.byteCount == audio.count
                        && $0.durationMilliseconds == 1_250
                        && FileManager.default.fileExists(atPath: $0.asset.fileURL.path)
                },
                "返回前必须完成内容嗅探、字节和时长校验并真正落入临时目录")
            let directory = generation.candidates[0].asset.fileURL.deletingLastPathComponent()
            expect(posixPermissions(at: tempRoot) == 0o700, "临时根目录必须是 0700")
            expect(posixPermissions(at: directory) == 0o700, "generation 目录必须是 0700")
            expect(
                generation.candidates.allSatisfy { posixPermissions(at: $0.asset.fileURL) == 0o600 },
                "每个临时候选必须是 0600")
        }
    }

    await suite("AI 提示音生成：第二个请求失败时第一个半成品也被清理") {
        await withTempDirectory { root in
            let provider = GenerationProviderFixture(steps: [
                .success(validMP3ID3Data()), .failure(.serviceUnavailable),
            ])
            let tempRoot = root.appendingPathComponent("ai-cues", isDirectory: true)
            let engine = AICueGenerationEngine(
                vault: GenerationVaultFixture(configured: true),
                provider: provider,
                temporaryRoot: tempRoot,
                durationProbe: StubDurationProbe(fixedDuration: 1))
            var failed = false
            do {
                _ = try await engine.generate(
                    description: "短促木琴音效",
                    locale: "zh-Hans",
                    providerProfileID: .elevenLabsGlobal,
                    deadline: .startingNow())
            } catch AICueGenerationError.provider(.serviceUnavailable) {
                failed = true
            } catch {}
            expect(failed, "provider 中途失败必须返回稳定错误")
            expect(await provider.requests().count == 2, "中途失败后不能继续计费请求")
            expect(generationDirectories(in: tempRoot).isEmpty, "任何 partial result 都必须清理")
        }
    }

    await suite("AI 提示音生成：坏格式和超时长都 fail closed 且不继续请求") {
        await withTempDirectory { root in
            let badProvider = GenerationProviderFixture(steps: [.success(Data("not audio".utf8))])
            let badRoot = root.appendingPathComponent("bad", isDirectory: true)
            let badEngine = AICueGenerationEngine(
                vault: GenerationVaultFixture(configured: true),
                provider: badProvider,
                temporaryRoot: badRoot,
                durationProbe: StubDurationProbe(fixedDuration: 1))
            var badFormat = false
            do {
                _ = try await badEngine.generate(
                    description: "短促提示音",
                    locale: "zh-Hans",
                    providerProfileID: .elevenLabsGlobal,
                    deadline: .startingNow())
            } catch AICueGenerationError.unsupportedAudio {
                badFormat = true
            } catch {}
            let badRequestCount = await badProvider.requests().count
            expect(badFormat && badRequestCount == 1, "坏格式必须在首项立即停止")
            expect(generationDirectories(in: badRoot).isEmpty, "坏格式不能留下文件")

            let longProvider = GenerationProviderFixture(steps: [.success(validMP3ID3Data())])
            let longRoot = root.appendingPathComponent("long", isDirectory: true)
            let longEngine = AICueGenerationEngine(
                vault: GenerationVaultFixture(configured: true),
                provider: longProvider,
                temporaryRoot: longRoot,
                durationProbe: StubDurationProbe(fixedDuration: 3.01))
            var tooLong = false
            do {
                _ = try await longEngine.generate(
                    description: "短促提示音",
                    locale: "zh-Hans",
                    providerProfileID: .elevenLabsGlobal,
                    deadline: .startingNow())
            } catch AICueGenerationError.audioTooLong {
                tooLong = true
            } catch {}
            let longRequestCount = await longProvider.requests().count
            expect(tooLong && longRequestCount == 1, "实测超三秒必须立即停止")
            expect(generationDirectories(in: longRoot).isEmpty, "超时长不能留下文件")
        }
    }

    await suite("AI 提示音生成：只有带安全 Retry-After 的 429 至多重试一次") {
        await withTempDirectory { root in
            let audio = validMP3ID3Data()
            let provider = GenerationProviderFixture(steps: [
                .failure(.rateLimited(retryAfterSeconds: 2)),
                .success(audio), .success(audio), .success(audio),
            ])
            let sleeper = GenerationRetrySleeperFixture()
            let engine = AICueGenerationEngine(
                vault: GenerationVaultFixture(configured: true),
                provider: provider,
                temporaryRoot: root.appendingPathComponent("retry", isDirectory: true),
                durationProbe: StubDurationProbe(fixedDuration: 1),
                retrySleeper: sleeper)
            let generation = try! await engine.generate(
                description: "短促木琴音效",
                locale: "zh-Hans",
                providerProfileID: .elevenLabsGlobal,
                deadline: .startingNow())
            expect(generation.candidates.count == 3, "一次允许的 429 重试后仍须完整三项")
            expect(await provider.requests().count == 4, "429 只能给失败子请求多一次机会")
            expect(await sleeper.observedDelays() == [2], "必须遵守有界 Retry-After")
            let deadlines = await provider.deadlines()
            expect(Set(deadlines).count == 1, "A/B/C 与唯一 retry 必须共享同一个 absolute deadline")
            expect(
                deadlines.first.map {
                    $0.expiresAtUptimeNanoseconds - $0.startedAtUptimeNanoseconds
                        == AICueGenerationDeadline.durationNanoseconds
                } == true,
                "production generation deadline 必须从点击起固定为 60 秒")

            let noRetryProvider = GenerationProviderFixture(steps: [.failure(.transportFailure)])
            let noRetrySleeper = GenerationRetrySleeperFixture()
            let noRetryEngine = AICueGenerationEngine(
                vault: GenerationVaultFixture(configured: true),
                provider: noRetryProvider,
                temporaryRoot: root.appendingPathComponent("no-retry", isDirectory: true),
                durationProbe: StubDurationProbe(fixedDuration: 1),
                retrySleeper: noRetrySleeper)
            do {
                _ = try await noRetryEngine.generate(
                    description: "短促木琴音效",
                    locale: "zh-Hans",
                    providerProfileID: .elevenLabsGlobal,
                    deadline: .startingNow())
            } catch {}
            expect(await noRetryProvider.requests().count == 1, "未知计费结果的网络错误不得自动重试")
            expect(await noRetrySleeper.observedDelays().isEmpty, "网络错误不得偷偷 sleep/retry")
        }
    }

    await suite("AI 提示音生成：absolute deadline 取消在途 provider 且不发布 partial") {
        await withTempDirectory { root in
            let provider = GenerationBlockingProviderFixture()
            let tempRoot = root.appendingPathComponent("deadline", isDirectory: true)
            let engine = AICueGenerationEngine(
                vault: GenerationVaultFixture(configured: true),
                provider: provider,
                temporaryRoot: tempRoot,
                durationProbe: StubDurationProbe(fixedDuration: 1),
                retrySleeper: GenerationRetrySleeperFixture())
            var deadlineExceeded = false
            do {
                _ = try await engine.generate(
                    description: "短促木琴音效",
                    locale: "zh-Hans",
                    providerProfileID: .elevenLabsGlobal,
                    deadline: shortGenerationDeadline())
            } catch AICueGenerationError.deadlineExceeded {
                deadlineExceeded = true
            } catch {}
            let counts = await provider.counts()
            expect(deadlineExceeded, "60 秒合同的可注入短预算必须返回 deadlineExceeded")
            expect(counts.requests == 1 && counts.cancellations == 1, "deadline 必须取消唯一在途子请求")
            expect(generationDirectories(in: tempRoot).isEmpty, "deadline 后不得留下 partial candidate")
        }
    }

    await suite("AI 提示音生成：deadline 不等待失控 vault/provider 的迟到结果") {
        await withTempDirectory { root in
            let vaultRoot = root.appendingPathComponent("slow-vault", isDirectory: true)
            let vaultEngine = AICueGenerationEngine(
                vault: GenerationSlowVaultFixture(),
                provider: GenerationProviderFixture(steps: [.success(validMP3ID3Data())]),
                temporaryRoot: vaultRoot,
                durationProbe: StubDurationProbe(fixedDuration: 1))
            let vaultStart = Date()
            var vaultDeadline = false
            do {
                _ = try await vaultEngine.generate(
                    description: "短促木琴音效",
                    locale: "zh-Hans",
                    providerProfileID: .elevenLabsGlobal,
                    deadline: generationDeadline(durationNanoseconds: 20_000_000))
            } catch AICueGenerationError.deadlineExceeded {
                vaultDeadline = true
            } catch {}
            expect(vaultDeadline, "credential read 也必须消耗点击时 deadline")
            expect(Date().timeIntervalSince(vaultStart) < 0.1, "迟到 vault 不得拖长调用方预算")
            expect(generationDirectories(in: vaultRoot).isEmpty, "vault deadline 前不得建候选目录")

            let providerRoot = root.appendingPathComponent("stuck-provider", isDirectory: true)
            let providerEngine = AICueGenerationEngine(
                vault: GenerationVaultFixture(configured: true),
                provider: GenerationIgnoringCancellationProviderFixture(),
                temporaryRoot: providerRoot,
                durationProbe: StubDurationProbe(fixedDuration: 1))
            let providerStart = Date()
            var providerDeadline = false
            do {
                _ = try await providerEngine.generate(
                    description: "短促木琴音效",
                    locale: "zh-Hans",
                    providerProfileID: .elevenLabsGlobal,
                    deadline: generationDeadline(durationNanoseconds: 20_000_000))
            } catch AICueGenerationError.deadlineExceeded {
                providerDeadline = true
            } catch {}
            expect(providerDeadline, "不响应取消的 provider 仍必须在 deadline 结束")
            expect(
                Date().timeIntervalSince(providerStart) < 0.1,
                "deadline race 不得结构化等待失控 provider")
            try? await Task.sleep(nanoseconds: 250_000_000)
            expect(generationDirectories(in: providerRoot).isEmpty, "迟到 provider 结果不得发布")
        }
    }

    await suite("AI 提示音生成：第三个 duration probe 越过 deadline 不得发布") {
        await withTempDirectory { root in
            let audio = validMP3ID3Data()
            let provider = GenerationProviderFixture(steps: [
                .success(audio), .success(audio), .success(audio),
            ])
            let tempRoot = root.appendingPathComponent("slow-third-probe", isDirectory: true)
            let engine = AICueGenerationEngine(
                vault: GenerationVaultFixture(configured: true),
                provider: provider,
                temporaryRoot: tempRoot,
                durationProbe: GenerationSlowThirdDurationProbe())
            let start = Date()
            var deadlineExceeded = false
            do {
                _ = try await engine.generate(
                    description: "短促木琴音效",
                    locale: "zh-Hans",
                    providerProfileID: .elevenLabsGlobal,
                    deadline: generationDeadline(durationNanoseconds: 100_000_000))
            } catch AICueGenerationError.deadlineExceeded {
                deadlineExceeded = true
            } catch {}
            expect(deadlineExceeded, "第三项本地校验也受同一 absolute deadline")
            expect(Date().timeIntervalSince(start) < 0.25, "慢 probe 不得拖过调用方硬上限")
            try? await Task.sleep(nanoseconds: 350_000_000)
            expect(generationDirectories(in: tempRoot).isEmpty, "迟到 probe 不得发布 candidates")
        }
    }

    await suite("AI 提示音生成：429 sleep 消耗同一预算，不能在 retry 时重置") {
        await withTempDirectory { root in
            let provider = GenerationProviderFixture(steps: [
                .failure(.rateLimited(retryAfterSeconds: 1)),
                .success(validMP3ID3Data()),
            ])
            let sleeper = GenerationSlowRetrySleeperFixture()
            let engine = AICueGenerationEngine(
                vault: GenerationVaultFixture(configured: true),
                provider: provider,
                temporaryRoot: root.appendingPathComponent("retry-deadline", isDirectory: true),
                durationProbe: StubDurationProbe(fixedDuration: 1),
                retrySleeper: sleeper)
            var deadlineExceeded = false
            do {
                _ = try await engine.generate(
                    description: "短促木琴音效",
                    locale: "zh-Hans",
                    providerProfileID: .elevenLabsGlobal,
                    deadline: shortGenerationDeadline())
            } catch AICueGenerationError.deadlineExceeded {
                deadlineExceeded = true
            } catch {}
            expect(deadlineExceeded, "Retry-After 超过剩余预算必须以 absolute deadline 结束")
            expect(await sleeper.calls() == 1, "允许的唯一 429 只进入一次 sleep")
            expect(await provider.requests().count == 1, "预算耗尽后不得发起 retry 请求")
        }
    }

    await suite("AI 提示音生成：整次 generation 只有一个 429 retry 名额") {
        await withTempDirectory { root in
            let audio = validMP3ID3Data()
            let provider = GenerationProviderFixture(steps: [
                .failure(.rateLimited(retryAfterSeconds: 1)),
                .success(audio),
                .failure(.rateLimited(retryAfterSeconds: 1)),
                .success(audio),
                .success(audio),
            ])
            let sleeper = GenerationRetrySleeperFixture()
            let tempRoot = root.appendingPathComponent("single-retry", isDirectory: true)
            let engine = AICueGenerationEngine(
                vault: GenerationVaultFixture(configured: true),
                provider: provider,
                temporaryRoot: tempRoot,
                durationProbe: StubDurationProbe(fixedDuration: 1),
                retrySleeper: sleeper)
            var secondRateLimitEscaped = false
            do {
                _ = try await engine.generate(
                    description: "短促木琴音效",
                    locale: "zh-Hans",
                    providerProfileID: .elevenLabsGlobal,
                    deadline: .startingNow())
            } catch AICueGenerationError.provider(.rateLimited(retryAfterSeconds: 1)) {
                secondRateLimitEscaped = true
            } catch {}
            expect(secondRateLimitEscaped, "第一个 retry 名额耗尽后，后续 429 必须直接失败")
            expect(await provider.requests().count == 3, "整次 generation 最多只能多发一个请求")
            expect(await sleeper.observedDelays() == [1], "整次 generation 最多只能 sleep 一次")
            expect(generationDirectories(in: tempRoot).isEmpty, "第二次 429 不能发布首个 partial candidate")
        }
    }

    await suite("AI 提示音生成：显式丢弃只删除对应 generation") {
        await withTempDirectory { root in
            let audio = validMP3ID3Data()
            let provider = GenerationProviderFixture(steps: [
                .success(audio), .success(audio), .success(audio),
                .success(audio), .success(audio), .success(audio),
            ])
            let engine = AICueGenerationEngine(
                vault: GenerationVaultFixture(configured: true),
                provider: provider,
                temporaryRoot: root.appendingPathComponent("discard", isDirectory: true),
                durationProbe: StubDurationProbe(fixedDuration: 1))
            let first = try! await engine.generate(
                description: "短促木琴音效",
                locale: "zh-Hans",
                providerProfileID: .elevenLabsGlobal,
                deadline: .startingNow())
            let second = try! await engine.generate(
                description: "清脆铃声音效",
                locale: "zh-Hans",
                providerProfileID: .elevenLabsGlobal,
                deadline: .startingNow())
            await engine.discard(generationID: first.id)
            expect(
                first.candidates.allSatisfy { !FileManager.default.fileExists(atPath: $0.asset.fileURL.path) },
                "丢弃必须删除该 generation 的全部候选")
            expect(
                second.candidates.allSatisfy { FileManager.default.fileExists(atPath: $0.asset.fileURL.path) },
                "丢弃一个 generation 不能误删另一个")
        }
    }
}

private func shortGenerationDeadline() -> AICueGenerationDeadline {
    generationDeadline(durationNanoseconds: 20_000_000)
}

private func generationDeadline(durationNanoseconds: UInt64) -> AICueGenerationDeadline {
    AICueGenerationDeadline(
        startedAtUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds,
        durationNanoseconds: durationNanoseconds)
}

private func generationDirectories(in root: URL) -> [URL] {
    (try? FileManager.default.contentsOfDirectory(
        at: root,
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles])) ?? []
}

private func posixPermissions(at url: URL) -> Int? {
    (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]) as? Int
}
