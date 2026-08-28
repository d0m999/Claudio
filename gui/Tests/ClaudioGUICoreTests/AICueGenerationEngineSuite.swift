import ClaudioGUICore
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

private enum GenerationProviderStep: Sendable {
    case success(Data)
    case failure(AICueProviderError)
}

private actor GenerationProviderFixture: AICueProvider {
    private var steps: [GenerationProviderStep]
    private var captured: [AICueProviderRequest] = []

    nonisolated let profile: AICueProviderProfile = try! AICueProviderRegistry().profile(
        for: .elevenLabsGlobal)

    init(steps: [GenerationProviderStep]) { self.steps = steps }

    func validateCredential(_ credential: SensitiveCredentialInput) async throws {}

    func generateCandidate(
        request: AICueProviderRequest,
        credential: SensitiveCredentialInput
    ) async throws -> AICueProviderAudioResponse {
        captured.append(request)
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
}

private actor GenerationRetrySleeperFixture: AICueRetrySleeping {
    private(set) var delays: [Int] = []

    func sleep(seconds: Int) async throws {
        delays.append(seconds)
    }

    func observedDelays() -> [Int] { delays }
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
                        providerProfileID: profileID)
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
                    providerProfileID: .elevenLabsGlobal)
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
                providerProfileID: .elevenLabsGlobal)
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
                    providerProfileID: .elevenLabsGlobal)
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
                    providerProfileID: .elevenLabsGlobal)
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
                    providerProfileID: .elevenLabsGlobal)
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
                providerProfileID: .elevenLabsGlobal)
            expect(generation.candidates.count == 3, "一次允许的 429 重试后仍须完整三项")
            expect(await provider.requests().count == 4, "429 只能给失败子请求多一次机会")
            expect(await sleeper.observedDelays() == [2], "必须遵守有界 Retry-After")

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
                    providerProfileID: .elevenLabsGlobal)
            } catch {}
            expect(await noRetryProvider.requests().count == 1, "未知计费结果的网络错误不得自动重试")
            expect(await noRetrySleeper.observedDelays().isEmpty, "网络错误不得偷偷 sleep/retry")
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
                providerProfileID: .elevenLabsGlobal)
            let second = try! await engine.generate(
                description: "清脆铃声音效",
                locale: "zh-Hans",
                providerProfileID: .elevenLabsGlobal)
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

private func generationDirectories(in root: URL) -> [URL] {
    (try? FileManager.default.contentsOfDirectory(
        at: root,
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles])) ?? []
}

private func posixPermissions(at url: URL) -> Int? {
    (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]) as? Int
}
