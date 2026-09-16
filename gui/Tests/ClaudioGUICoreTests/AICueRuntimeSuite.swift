import ClaudioCore
import ClaudioGUICore
import Foundation

private struct RuntimeVaultFacts: Sendable {
    let contains: Int
    let reads: Int
    let replacements: Int
    let deletions: Int
    let slots: Set<AICueCredentialSlotID>
}

private actor RuntimeVaultFixture: AICueCredentialVault {
    private var credentials: [AICueCredentialSlotID: SensitiveCredentialInput]
    private var containsCount = 0
    private var readCount = 0
    private var replacementCount = 0
    private var deletionCount = 0

    init(credentials: [AICueCredentialSlotID: SensitiveCredentialInput] = [:]) {
        self.credentials = credentials
    }

    func containsCredential(in slotID: AICueCredentialSlotID) -> Bool {
        containsCount += 1
        return credentials[slotID] != nil
    }

    func credential(in slotID: AICueCredentialSlotID) -> SensitiveCredentialInput? {
        readCount += 1
        return credentials[slotID]
    }

    func replaceCredential(
        _ credential: SensitiveCredentialInput,
        in slotID: AICueCredentialSlotID
    ) {
        replacementCount += 1
        credentials[slotID] = credential
    }

    func deleteCredential(in slotID: AICueCredentialSlotID) {
        deletionCount += 1
        credentials.removeValue(forKey: slotID)
    }

    func facts() -> RuntimeVaultFacts {
        RuntimeVaultFacts(
            contains: containsCount,
            reads: readCount,
            replacements: replacementCount,
            deletions: deletionCount,
            slots: Set(credentials.keys))
    }
}

private actor RuntimeCredentialMetadataFixture: AICueCredentialMetadataStoring {
    private var values: [AICueProviderProfileID: AICueCredentialVerification] = [:]
    private var readCount = 0
    private var writeCount = 0

    func verification(
        for profileID: AICueProviderProfileID
    ) -> AICueCredentialVerification? {
        readCount += 1
        return values[profileID]
    }

    func setVerification(
        _ verification: AICueCredentialVerification?,
        for profileID: AICueProviderProfileID
    ) {
        writeCount += 1
        values[profileID] = verification
    }

    func counts() -> (reads: Int, writes: Int) {
        (readCount, writeCount)
    }
}

private actor RuntimeUnaryTransportFixture: AICueUnaryTransport {
    private var callCount = 0

    func send(
        _ request: AICueTransportRequest,
        authentication: AICueProviderAuthentication,
        credential: SensitiveCredentialInput
    ) async throws -> AICueHTTPResponse {
        callCount += 1
        throw AICueTransportError.transportFailure
    }

    func calls() -> Int { callCount }
}

private final class RuntimeSSETransportFixture: AICueSSETransport, @unchecked Sendable {
    private let lock = NSLock()
    private var callCount = 0

    func events(
        for request: AICueTransportRequest,
        authentication: AICueProviderAuthentication,
        credential: SensitiveCredentialInput
    ) -> AsyncThrowingStream<AICueSSEEvent, Error> {
        lock.lock()
        callCount += 1
        lock.unlock()
        return AsyncThrowingStream { continuation in
            continuation.finish(throwing: AICueTransportError.transportFailure)
        }
    }

    func calls() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return callCount
    }
}

private actor RuntimeAssetFetcherFixture: AICueAssetFetching {
    private var callCount = 0

    func fetch(
        _ url: URL,
        policy: AICueAssetPolicy,
        deadline: AICueGenerationDeadline
    ) async throws -> AICueFetchedAsset {
        callCount += 1
        throw AICueAssetFetchError.transportFailure
    }

    func calls() -> Int { callCount }
}

private final class RuntimeDurationProbeFixture: AudioDurationProbing, @unchecked Sendable {
    private let lock = NSLock()
    private var callCount = 0

    func probeDuration(of fileURL: URL) -> TimeInterval? {
        lock.lock()
        callCount += 1
        lock.unlock()
        return 1
    }

    func calls() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return callCount
    }
}

private actor RuntimeCandidateSetProviderFixture: AICueCandidateSetProvider {
    nonisolated let profile: AICueProviderProfile
    private let suspendsGeneration: Bool
    private var generationContinuation: CheckedContinuation<Void, Never>?
    private var validationCount = 0
    private var generationCount = 0
    private var completedGenerationCount = 0

    init(profile: AICueProviderProfile, suspendsGeneration: Bool = false) {
        self.profile = profile
        self.suspendsGeneration = suspendsGeneration
    }

    func validateCredential(_ credential: SensitiveCredentialInput) {
        validationCount += 1
    }

    func generateCandidateSet(
        plan: AICueSoundPlan,
        credential: SensitiveCredentialInput,
        deadline: AICueGenerationDeadline
    ) async throws -> [AICueProviderCandidateResponse] {
        generationCount += 1
        if suspendsGeneration {
            await withCheckedContinuation { continuation in
                generationContinuation = continuation
            }
        }
        completedGenerationCount += 1
        guard let route = profile.routes[plan.modality] else {
            throw AICueProviderError.invalidRequest
        }
        return (1...route.candidateSetPolicy.requestedCount).map { ordinalValue in
            let identity: AICueCandidateIdentity
            switch route.candidateSetPolicy.semantics {
            case .styled:
                identity = .styled(AICueVariant.allCases[ordinalValue - 1])
            case .numbered:
                identity = .numbered(AICueCandidateOrdinal(rawValue: ordinalValue)!)
            }
            return AICueProviderCandidateResponse(
                identity: identity,
                audio: AICueProviderAudioResponse(
                    data: validMP3ID3Data(),
                    mediaType: "audio/mpeg",
                    modelID: route.modelID,
                    requestID: nil))
        }
    }

    func resumeGeneration() {
        let continuation = generationContinuation
        generationContinuation = nil
        continuation?.resume()
    }

    func facts() -> (validations: Int, generations: Int, completed: Int, isSuspended: Bool) {
        (
            validationCount,
            generationCount,
            completedGenerationCount,
            generationContinuation != nil
        )
    }
}

@MainActor
func runAICueRuntimeSuites() async {
    await suite("AI 提示音 runtime：同一 factory 精确装配四或五个 generator 与 probe subset") {
        await withTempDirectory { root in
            let policy = runtimeSenseAudioAssetPolicy()
            let productionRegistry = AICueProviderRegistry(
                evidenceGatedSenseAudioAssetPolicy: nil)
            let evidenceRegistry = AICueProviderRegistry(
                evidenceGatedSenseAudioAssetPolicy: policy)
            let vault = RuntimeVaultFixture()
            let unary = RuntimeUnaryTransportFixture()
            let sse = RuntimeSSETransportFixture()
            let assets = RuntimeAssetFetcherFixture()
            let metadata = RuntimeCredentialMetadataFixture()
            let duration = RuntimeDurationProbeFixture()
            let defaults = runtimeDefaults("Factory")
            defer { defaults.removePersistentDomain(forName: runtimeDefaultsName("Factory")) }
            let temporaryRoot = root.appendingPathComponent("not-created", isDirectory: true)

            let production = try! AICueRuntime(
                registry: productionRegistry,
                vault: vault,
                temporaryRoot: temporaryRoot,
                durationProbe: duration,
                unaryTransport: unary,
                sseTransport: sse,
                assetFetcher: assets,
                credentialMetadata: metadata,
                providerDefaults: defaults)
            let enabled = try! AICueRuntime(
                vault: vault,
                temporaryRoot: temporaryRoot,
                durationProbe: duration,
                unaryTransport: unary,
                sseTransport: sse,
                assetFetcher: assets,
                credentialMetadata: metadata,
                providerDefaults: defaults)
            let evidence = try! AICueRuntime(
                registry: evidenceRegistry,
                vault: vault,
                temporaryRoot: temporaryRoot,
                durationProbe: duration,
                unaryTransport: unary,
                sseTransport: sse,
                assetFetcher: assets,
                credentialMetadata: metadata,
                providerDefaults: defaults)

            expect(
                production.generatorProfileIDs
                    == [.elevenLabsGlobal, .miniMaxGlobal, .qwenSingapore, .qwenBeijing],
                "nil policy runtime 必须为四个 production profile 各装配一个 generator")
            expect(
                production.validatorProfileIDs == [.elevenLabsGlobal, .miniMaxGlobal],
                "nil policy validators 只能包含两个 read-only probe profiles")
            expect(
                enabled.generatorProfileIDs
                    == [
                        .elevenLabsGlobal, .miniMaxGlobal, .qwenSingapore, .qwenBeijing,
                        .senseAudioChina,
                    ]
                    && enabled.validatorProfileIDs
                        == [.elevenLabsGlobal, .miniMaxGlobal, .senseAudioChina],
                "默认 runtime 必须装配五个 generator 与三个 probe validator")
            expect(
                evidence.generatorProfileIDs
                    == Set(evidenceRegistry.profiles().map(\.id))
                    && evidence.generatorProfileIDs.count == 5,
                "非 nil policy runtime 必须覆盖同一 registry 的全部五个 generator")
            expect(
                evidence.validatorProfileIDs
                    == [.elevenLabsGlobal, .miniMaxGlobal, .senseAudioChina]
                    && !evidence.validatorProfileIDs.contains(.qwenSingapore)
                    && !evidence.validatorProfileIDs.contains(.qwenBeijing),
                "SenseAudio 加入 probe subset，但 Qwen deferred profiles 不得被强制 probe")

            let vaultFacts = await vault.facts()
            let metadataCounts = await metadata.counts()
            let transportCalls = (
                unary: await unary.calls(),
                sse: sse.calls(),
                assets: await assets.calls()
            )
            expect(
                vaultFacts.contains == 0 && vaultFacts.reads == 0
                    && vaultFacts.replacements == 0 && vaultFacts.deletions == 0,
                "runtime 构造不得读取或写入 Keychain boundary")
            expect(
                transportCalls.unary == 0 && transportCalls.sse == 0
                    && transportCalls.assets == 0,
                "runtime 构造不得 probe 或生成任何网络请求")
            expect(
                metadataCounts.reads == 0 && metadataCounts.writes == 0
                    && duration.calls() == 0
                    && defaults.object(forKey: AICueProviderPreferences.defaultsKey) == nil,
                "runtime 构造不得读取 metadata、duration 或 provider preferences")
            expect(
                !FileManager.default.fileExists(atPath: temporaryRoot.path),
                "runtime 构造不得创建临时候选目录")
            let viewModel = AICueGenerationViewModel(
                credentialManager: enabled.credentialManager,
                generator: enabled.dispatcher,
                registry: enabled.registry,
                providerPreferences: enabled.providerPreferences)
            expect(
                viewModel.availableProviderProfiles.map(\.id)
                    == enabled.registry.profiles().map(\.id)
                    && viewModel.providerProfileID == .elevenLabsGlobal,
                "默认选择器必须按 registry 顺序提供五 profiles，并保持默认 ElevenLabs")
            for profile in productionRegistry.profiles() {
                defaults.set(profile.id.rawValue, forKey: AICueProviderPreferences.defaultsKey)
                let restored = AICueGenerationViewModel(
                    credentialManager: enabled.credentialManager,
                    generator: enabled.dispatcher,
                    registry: enabled.registry,
                    providerPreferences: enabled.providerPreferences)
                expect(
                    restored.providerProfileID == profile.id
                        && defaults.string(forKey: AICueProviderPreferences.defaultsKey)
                            == profile.id.rawValue,
                    "启用 SenseAudio 不得改变已有 Provider 选择或覆写偏好")
            }
            for (description, locale, expected) in [
                (
                    "先响一声木琴，再说“完成”", "zh-Hans",
                    AICueProviderRequestCompilationError.unsupportedModality
                ),
                ("Say \"Complete\"", "en", .unsupportedLocale),
            ] {
                do {
                    _ = try await enabled.dispatcher.generate(
                        description: description, locale: locale,
                        providerProfileID: .senseAudioChina,
                        deadline: .startingNow())
                    expect(false, "SenseAudio 不支持的输入必须本地拒绝")
                } catch {
                    expect(
                        error as? AICueGenerationError == .requestCompilation(expected),
                        "mixed/非中文 speech 必须因对应 capability/locale 失败")
                }
            }
            let rejectedFacts = await vault.facts()
            let rejectedUnaryCalls = await unary.calls()
            let rejectedAssetCalls = await assets.calls()
            expect(
                rejectedFacts.contains == 0 && rejectedFacts.reads == 0
                    && rejectedUnaryCalls == 0 && sse.calls() == 0 && rejectedAssetCalls == 0
                    && !FileManager.default.fileExists(atPath: temporaryRoot.path),
                "默认 SenseAudio 本地拒绝必须先于取 Key、网络和文件写入")
        }
    }

    await suite("AI 提示音 runtime：binding 缺失、重复或完整 profile 漂移时初始化失败") {
        await withTempDirectory { root in
            let registry = AICueProviderRegistry()
            let bindings = runtimeBindings(registry: registry)
            let vault = RuntimeVaultFixture()
            let metadata = RuntimeCredentialMetadataFixture()
            let defaults = runtimeDefaults("Bindings")
            defer { defaults.removePersistentDomain(forName: runtimeDefaultsName("Bindings")) }
            let elevenLabs = try! registry.profile(for: .elevenLabsGlobal)
            let tampered = RuntimeCandidateSetProviderFixture(
                profile: runtimeCopying(elevenLabs, maximumDurationMilliseconds: 2_999))

            let invalidBindings: [[any AICueCandidateSetProvider]] = [
                Array(bindings.dropLast()),
                bindings + [bindings[0]],
                bindings.map { binding in
                    binding.profile.id == .elevenLabsGlobal ? tampered : binding
                },
            ]
            for candidateBindings in invalidBindings {
                expect(
                    throwsRuntimeBindingError {
                        _ = try AICueRuntime(
                            registry: registry,
                            vault: vault,
                            temporaryRoot: root.appendingPathComponent("unused"),
                            durationProbe: RuntimeDurationProbeFixture(),
                            providerBindings: candidateBindings,
                            credentialMetadata: metadata,
                            providerDefaults: defaults)
                    },
                    "缺项、重复或与 registry 不同的完整 profile binding 必须失败关闭")
            }
            let facts = await vault.facts()
            expect(
                facts.contains == 0 && facts.reads == 0 && facts.replacements == 0
                    && facts.deletions == 0,
                "binding 初始化失败不得触碰 credential boundary")
        }
    }

    await suite("AI 提示音 runtime：Qwen deferred 保存与 pending 替换保持零 probe") {
        await withTempDirectory { root in
            let vault = RuntimeVaultFixture()
            let unary = RuntimeUnaryTransportFixture()
            let sse = RuntimeSSETransportFixture()
            let assets = RuntimeAssetFetcherFixture()
            let metadata = RuntimeCredentialMetadataFixture()
            let defaults = runtimeDefaults("Qwen")
            defer { defaults.removePersistentDomain(forName: runtimeDefaultsName("Qwen")) }
            let runtime = try! AICueRuntime(
                vault: vault,
                temporaryRoot: root.appendingPathComponent("unused"),
                durationProbe: RuntimeDurationProbeFixture(),
                unaryTransport: unary,
                sseTransport: sse,
                assetFetcher: assets,
                credentialMetadata: metadata,
                providerDefaults: defaults)

            let first = try! await runtime.credentialManager.save(
                try! SensitiveCredentialInput("fixture-qwen-active"),
                for: .qwenSingapore)
            let second = try! await runtime.credentialManager.save(
                try! SensitiveCredentialInput("fixture-qwen-pending"),
                for: .qwenSingapore)
            let facts = await vault.facts()
            let transportCalls = (
                unary: await unary.calls(),
                sse: sse.calls(),
                assets: await assets.calls()
            )
            expect(
                first
                    == .stored(
                        verification: .deferred,
                        hasPendingReplacement: false)
                    && second
                        == .stored(
                            verification: .deferred,
                            hasPendingReplacement: true),
                "Qwen 首次保存必须 deferred，已有 active 时替换只能进入 pending")
            expect(
                facts.slots == [.qwenSingapore, .qwenSingaporePending]
                    && facts.replacements == 2,
                "Qwen active/pending slot 合同必须原样保留")
            expect(
                transportCalls.unary == 0 && transportCalls.sse == 0
                    && transportCalls.assets == 0,
                "Qwen 保存和 pending 替换不得误用任何 Provider probe")
        }
    }

    await suite("AI 提示音 runtime：真实 dispatcher/engine 覆盖五个 profile 且不 fallback") {
        await withTempDirectory { root in
            let registry = AICueProviderRegistry()
            let vault = RuntimeVaultFixture()
            let unary = RuntimeUnaryTransportFixture()
            let sse = RuntimeSSETransportFixture()
            let assets = RuntimeAssetFetcherFixture()
            let metadata = RuntimeCredentialMetadataFixture()
            let defaults = runtimeDefaults("Dispatcher")
            defer { defaults.removePersistentDomain(forName: runtimeDefaultsName("Dispatcher")) }
            let temporaryRoot = root.appendingPathComponent("not-created", isDirectory: true)
            let runtime = try! AICueRuntime(
                registry: registry,
                vault: vault,
                temporaryRoot: temporaryRoot,
                durationProbe: RuntimeDurationProbeFixture(),
                unaryTransport: unary,
                sseTransport: sse,
                assetFetcher: assets,
                credentialMetadata: metadata,
                providerDefaults: defaults)

            var credentialRequired: Set<AICueProviderProfileID> = []
            for profile in registry.profiles() {
                do {
                    _ = try await runtime.dispatcher.generate(
                        description: "请说“完成”",
                        locale: "zh-Hans",
                        providerProfileID: profile.id,
                        deadline: .startingNow())
                } catch AICueGenerationError.credentialRequired {
                    credentialRequired.insert(profile.id)
                } catch {}
            }
            expect(
                credentialRequired == Set(registry.profiles().map(\.id)),
                "每个显式 profile 必须到达自己的 engine credential gate，而非缺 binding 或 fallback")
            let transportCalls = (
                unary: await unary.calls(),
                sse: sse.calls(),
                assets: await assets.calls()
            )
            expect(
                transportCalls.unary == 0 && transportCalls.sse == 0
                    && transportCalls.assets == 0,
                "缺 credential 的全 profile seam 不得触发任何 Provider transport")
            expect(
                !FileManager.default.fileExists(atPath: temporaryRoot.path),
                "credential gate 必须先于临时候选目录创建")
        }
    }

    await suite("AI 提示音 runtime：关闭 gated profile 时偏好只读回落且不删除数据") {
        await withTempDirectory { root in
            let defaultsName = runtimeDefaultsName("Rollback")
            let defaults = UserDefaults(suiteName: defaultsName)!
            defer { defaults.removePersistentDomain(forName: defaultsName) }
            defaults.set(
                AICueProviderProfileID.senseAudioChina.rawValue,
                forKey: AICueProviderPreferences.defaultsKey)
            let vault = RuntimeVaultFixture(credentials: [
                .senseAudioChina: try! SensitiveCredentialInput("fixture-preserved-key")
            ])
            let metadata = RuntimeCredentialMetadataFixture()
            let sentinel = root.appendingPathComponent("adopted-sentinel.mp3")
            writeFixture(validMP3ID3Data(), to: sentinel)
            let temporaryRoot = root.appendingPathComponent("unused", isDirectory: true)

            let evidenceRegistry = AICueProviderRegistry()
            let evidence = try! AICueRuntime(
                registry: evidenceRegistry,
                vault: vault,
                temporaryRoot: temporaryRoot,
                durationProbe: RuntimeDurationProbeFixture(),
                unaryTransport: RuntimeUnaryTransportFixture(),
                sseTransport: RuntimeSSETransportFixture(),
                assetFetcher: RuntimeAssetFetcherFixture(),
                credentialMetadata: metadata,
                providerDefaults: defaults)
            let evidenceViewModel = AICueGenerationViewModel(
                credentialManager: evidence.credentialManager,
                generator: evidence.dispatcher,
                registry: evidence.registry,
                providerPreferences: evidence.providerPreferences)
            expect(
                evidenceViewModel.providerProfileID == .senseAudioChina
                    && evidenceViewModel.availableProviderProfiles.count == 5,
                "同一 runtime 的 registry/preferences/VM 必须一致选择 enabled SenseAudio")

            let production = try! AICueRuntime(
                registry: AICueProviderRegistry(
                    evidenceGatedSenseAudioAssetPolicy: nil),
                vault: vault,
                temporaryRoot: temporaryRoot,
                durationProbe: RuntimeDurationProbeFixture(),
                unaryTransport: RuntimeUnaryTransportFixture(),
                sseTransport: RuntimeSSETransportFixture(),
                assetFetcher: RuntimeAssetFetcherFixture(),
                credentialMetadata: metadata,
                providerDefaults: defaults)
            let productionViewModel = AICueGenerationViewModel(
                credentialManager: production.credentialManager,
                generator: production.dispatcher,
                registry: production.registry,
                providerPreferences: production.providerPreferences)
            let vaultFacts = await vault.facts()
            expect(
                productionViewModel.providerProfileID == .elevenLabsGlobal
                    && productionViewModel.availableProviderProfiles.count == 4,
                "历史 SenseAudio 选择在关闭 gate 后必须只读回落默认 ElevenLabs")
            expect(
                defaults.string(forKey: AICueProviderPreferences.defaultsKey)
                    == AICueProviderProfileID.senseAudioChina.rawValue
                    && vaultFacts.deletions == 0
                    && vaultFacts.slots == [.senseAudioChina]
                    && FileManager.default.fileExists(atPath: sentinel.path),
                "回落不得覆写 raw preference、删除 Keychain 项或触碰已采用音频")
        }
    }

    await suite("AI 提示音 runtime：VM 作废后真实 dispatcher/engine 丢弃迟到结果") {
        await withTempDirectory { root in
            let registry = AICueProviderRegistry()
            let suspendedProvider = RuntimeCandidateSetProviderFixture(
                profile: try! registry.profile(for: .elevenLabsGlobal),
                suspendsGeneration: true)
            let bindings: [any AICueCandidateSetProvider] = registry.profiles().map { profile in
                profile.id == .elevenLabsGlobal
                    ? suspendedProvider
                    : RuntimeCandidateSetProviderFixture(profile: profile)
            }
            let vault = RuntimeVaultFixture(credentials: [
                .legacyElevenLabs: try! SensitiveCredentialInput("fixture-active-key")
            ])
            let metadata = RuntimeCredentialMetadataFixture()
            let defaults = runtimeDefaults("Late")
            defer { defaults.removePersistentDomain(forName: runtimeDefaultsName("Late")) }
            let temporaryRoot = root.appendingPathComponent("ai-cues", isDirectory: true)
            let runtime = try! AICueRuntime(
                registry: registry,
                vault: vault,
                temporaryRoot: temporaryRoot,
                durationProbe: RuntimeDurationProbeFixture(),
                providerBindings: bindings,
                credentialMetadata: metadata,
                providerDefaults: defaults)
            let viewModel = AICueGenerationViewModel(
                credentialManager: runtime.credentialManager,
                generator: runtime.dispatcher,
                providerProfileID: .elevenLabsGlobal,
                registry: runtime.registry,
                providerPreferences: runtime.providerPreferences)

            viewModel.begin(scope: .surface(.workBuddy), event: .stop)
            viewModel.updateDescription("请说“完成”")
            viewModel.startGeneration(locale: "zh-Hans")
            await waitForRuntimeProviderSuspension(suspendedProvider)
            viewModel.updateDescription("生成期间应被拒绝的描述")
            expect(viewModel.soundDescription == "请说“完成”", "真实 runtime 也必须拒绝生成中的描述修改")
            viewModel.returnToDescription()
            viewModel.updateDescription("请说“新的完成”")
            await suspendedProvider.resumeGeneration()
            await waitForRuntimeProviderCompletion(suspendedProvider)
            for _ in 0..<100 { await Task.yield() }

            let providerFacts = await suspendedProvider.facts()
            let metadataCounts = await metadata.counts()
            let temporaryContents =
                (try? FileManager.default.contentsOfDirectory(
                    at: temporaryRoot,
                    includingPropertiesForKeys: nil)) ?? []
            expect(
                viewModel.phase == .editing && viewModel.generation == nil
                    && viewModel.soundDescription == "请说“新的完成”",
                "作废后的迟到 Provider 结果不得复活旧候选或覆盖新描述")
            expect(
                providerFacts.generations == 1 && providerFacts.completed == 1
                    && providerFacts.validations == 0,
                "测试必须真的释放一个迟到 generation，且生成不得误走 credential probe")
            expect(
                metadataCounts.writes == 0 && temporaryContents.isEmpty,
                "迟到 generation 不得提交 credential 验证，且只能清理本次临时候选目录")
        }
    }
}

private func runtimeSenseAudioAssetPolicy() -> AICueAssetPolicy {
    try! AICueAssetPolicy(
        allowedOrigins: [try! AICueAssetOrigin("https://assets.fixture.invalid")],
        acceptedMediaTypes: ["audio/mpeg"])
}

private func runtimeDefaultsName(_ suffix: String) -> String {
    "AICueRuntime.\(suffix).fixture"
}

private func runtimeDefaults(_ suffix: String) -> UserDefaults {
    let name = runtimeDefaultsName(suffix)
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

private func runtimeBindings(
    registry: AICueProviderRegistry
) -> [any AICueCandidateSetProvider] {
    registry.profiles().map { RuntimeCandidateSetProviderFixture(profile: $0) }
}

private func runtimeCopying(
    _ profile: AICueProviderProfile,
    maximumDurationMilliseconds: Int
) -> AICueProviderProfile {
    AICueProviderProfile(
        id: profile.id,
        providerID: profile.providerID,
        credentialSlotID: profile.credentialSlotID,
        pendingCredentialSlotID: profile.pendingCredentialSlotID,
        credentialValidationPolicy: profile.credentialValidationPolicy,
        regionID: profile.regionID,
        displayNameKey: profile.displayNameKey,
        privacyDisclosureKey: profile.privacyDisclosureKey,
        routes: profile.routes,
        constraints: AICueProviderConstraints(
            maximumDurationMilliseconds: maximumDurationMilliseconds))
}

private func throwsRuntimeBindingError(_ body: () throws -> Void) -> Bool {
    do {
        try body()
        return false
    } catch AICueRuntimeError.invalidProviderBindings {
        return true
    } catch {
        return false
    }
}

private func waitForRuntimeProviderSuspension(
    _ provider: RuntimeCandidateSetProviderFixture
) async {
    for _ in 0..<2_000 {
        if await provider.facts().isSuspended { return }
        await Task.yield()
    }
    await MainActor.run {
        expect(false, "等待 runtime Provider 悬挂超时")
    }
}

private func waitForRuntimeProviderCompletion(
    _ provider: RuntimeCandidateSetProviderFixture
) async {
    for _ in 0..<2_000 {
        if await provider.facts().completed == 1 { return }
        await Task.yield()
    }
    await MainActor.run {
        expect(false, "等待 runtime Provider 迟到完成超时")
    }
}
