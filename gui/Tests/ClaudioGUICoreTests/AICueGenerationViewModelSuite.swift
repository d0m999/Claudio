import ClaudioCore
import ClaudioGUICore
import Foundation

private actor ComposerCredentialManagerFixture: AICueCredentialManaging {
    enum SaveMode: Sendable {
        case succeed
        case fail(AICueProviderError)
    }

    private var currentStatus: AICueCredentialStatus
    private var saveMode: SaveMode
    private(set) var saveCount = 0
    private(set) var deleteCount = 0

    init(status: AICueCredentialStatus, saveMode: SaveMode = .succeed) {
        currentStatus = status
        self.saveMode = saveMode
    }

    func status(for profileID: AICueProviderProfileID) async -> AICueCredentialStatus {
        currentStatus
    }

    func save(
        _ credential: SensitiveCredentialInput,
        for profileID: AICueProviderProfileID
    ) async throws -> AICueCredentialStatus {
        saveCount += 1
        switch saveMode {
        case .succeed:
            currentStatus = .stored(verification: .verified, hasPendingReplacement: false)
            return currentStatus
        case .fail(let error):
            throw error
        }
    }

    func delete(for profileID: AICueProviderProfileID) async throws {
        deleteCount += 1
        currentStatus = .missing
    }

    func cancelPendingReplacement(for profileID: AICueProviderProfileID) async throws {
        if case .stored(let verification, _) = currentStatus {
            currentStatus = .stored(
                verification: verification,
                hasPendingReplacement: false)
        }
    }

    func setStatus(_ status: AICueCredentialStatus) {
        currentStatus = status
    }

    func counts() -> (saves: Int, deletions: Int) { (saveCount, deleteCount) }
}

private actor SuspendedCredentialStatusManagerFixture: AICueCredentialManaging {
    private var statusContinuation: CheckedContinuation<AICueCredentialStatus, Never>?

    func status(for profileID: AICueProviderProfileID) async -> AICueCredentialStatus {
        await withCheckedContinuation { continuation in
            statusContinuation = continuation
        }
    }

    func save(
        _ credential: SensitiveCredentialInput,
        for profileID: AICueProviderProfileID
    ) async throws -> AICueCredentialStatus {
        .stored(verification: .verified, hasPendingReplacement: false)
    }

    func delete(for profileID: AICueProviderProfileID) async throws {}

    func cancelPendingReplacement(for profileID: AICueProviderProfileID) async throws {}

    var hasSuspendedStatusRequest: Bool { statusContinuation != nil }

    func resumeStatus(with status: AICueCredentialStatus) {
        let continuation = statusContinuation
        statusContinuation = nil
        continuation?.resume(returning: status)
    }
}

private actor ComposerGeneratorFixture: AICueGenerating {
    enum Mode: Sendable {
        case success(AICueGeneration)
        case failure(AICueGenerationError)
        case waitForCancellation
    }

    private var mode: Mode
    private(set) var generateCount = 0
    private(set) var discardedGenerationIDs: [UUID] = []
    private(set) var requestedProfileIDs: [AICueProviderProfileID] = []
    private(set) var requestedDeadlines: [AICueGenerationDeadline] = []

    init(mode: Mode) { self.mode = mode }

    func setMode(_ mode: Mode) { self.mode = mode }

    func generate(
        description: String,
        locale: String,
        providerProfileID: AICueProviderProfileID,
        deadline: AICueGenerationDeadline
    ) async throws -> AICueGeneration {
        generateCount += 1
        requestedProfileIDs.append(providerProfileID)
        requestedDeadlines.append(deadline)
        switch mode {
        case .success(let generation): return generation
        case .failure(let error): throw error
        case .waitForCancellation:
            do {
                try await Task.sleep(nanoseconds: 5_000_000_000)
                throw AICueGenerationError.provider(.transportFailure)
            } catch {
                throw AICueGenerationError.cancelled
            }
        }
    }

    func discard(generationID: UUID) async {
        discardedGenerationIDs.append(generationID)
    }

    func discardAll() async {}

    func facts() -> (
        generations: Int,
        discarded: [UUID],
        profileIDs: [AICueProviderProfileID],
        deadlines: [AICueGenerationDeadline]
    ) {
        (generateCount, discardedGenerationIDs, requestedProfileIDs, requestedDeadlines)
    }
}

@MainActor
func runAICueGenerationViewModelSuites() async {
    await suite("AI 提示音状态层：迟到的同 profile 状态读取不得覆盖新凭据 mutation") {
        let credentialManager = SuspendedCredentialStatusManagerFixture()
        let viewModel = AICueGenerationViewModel(
            credentialManager: credentialManager,
            generator: ComposerGeneratorFixture(mode: .failure(.credentialRequired)),
            providerProfileID: .elevenLabsGlobal)

        let staleRefresh = Task { await viewModel.refreshCredentialStatus() }
        await waitForSuspendedCredentialStatus(credentialManager)
        await viewModel.saveCredential(
            try! SensitiveCredentialInput("fixture-newer-key"))
        await credentialManager.resumeStatus(with: .unavailable)
        await staleRefresh.value

        expect(
            viewModel.credentialStatus
                == .stored(verification: .verified, hasPendingReplacement: false),
            "旧 status() 完成不能把更新后的同 profile credential 状态覆写回去")
    }

    await suite("AI 提示音状态层：保存 key 保留描述且绝不自动触发计费生成") {
        let credentialManager = ComposerCredentialManagerFixture(status: .missing)
        let generator = ComposerGeneratorFixture(mode: .failure(.credentialRequired))
        let viewModel = AICueGenerationViewModel(
            credentialManager: credentialManager,
            generator: generator,
            providerProfileID: .elevenLabsGlobal)
        viewModel.begin(target: aiCueComposerTarget())
        viewModel.updateDescription("一只小猫短促叫两声，不要背景音乐")
        await viewModel.refreshCredentialStatus()

        viewModel.startGeneration(locale: "zh-Hans")
        await waitForAICueViewModel { viewModel.phase != .generating }
        expect(
            viewModel.failure == .generation(.credentialRequired),
            "缺 key 必须回到可编辑态并请求配置凭据")
        let attemptsBeforeSave = await generator.facts().generations

        await viewModel.saveCredential(
            try! SensitiveCredentialInput("fixture-new-key"))
        expect(
            viewModel.credentialStatus
                == .stored(verification: .verified, hasPendingReplacement: false),
            "验证保存成功后只投影 verified stored")
        expect(
            viewModel.soundDescription == "一只小猫短促叫两声，不要背景音乐",
            "配置 key 不能清掉用户已经写好的描述")
        expect(
            await generator.facts().generations == attemptsBeforeSave,
            "保存 key 后不能自动发起可能计费的生成")
        expect(viewModel.phase == .editing, "保存成功后仍须等待用户再次点击生成")
    }

    await suite("AI 提示音状态层：将 composition root 选择的 profile 原样传给生成器") {
        let generator = ComposerGeneratorFixture(
            mode: .failure(.requestCompilation(.unsupportedModality)))
        let viewModel = AICueGenerationViewModel(
            credentialManager: ComposerCredentialManagerFixture(status: .missing),
            generator: generator,
            providerProfileID: .qwenSingapore)
        viewModel.begin(target: aiCueComposerTarget())
        viewModel.updateDescription("短促木琴完成音效")

        viewModel.startGeneration(locale: "zh-Hans")
        await waitForAICueViewModel { viewModel.phase != .generating }

        expect(
            await generator.facts().profileIDs == [.qwenSingapore],
            "ViewModel 不能把所选 profile 隐式改回 ElevenLabs")
        let deadlines = await generator.facts().deadlines
        expect(
            deadlines.count == 1
                && deadlines[0].expiresAtUptimeNanoseconds
                    - deadlines[0].startedAtUptimeNanoseconds
                    == AICueGenerationDeadline.durationNanoseconds,
            "60 秒 absolute deadline 必须在用户点击入口冻结并传入 engine")
    }

    await suite("AI 提示音状态层：生成拒绝后立即投影当前 profile 的 rejected 状态") {
        let credentialManager = ComposerCredentialManagerFixture(
            status: .stored(verification: .rejected, hasPendingReplacement: false))
        let viewModel = AICueGenerationViewModel(
            credentialManager: credentialManager,
            generator: ComposerGeneratorFixture(mode: .failure(.provider(.invalidCredential))),
            providerProfileID: .qwenSingapore)
        viewModel.begin(target: aiCueComposerTarget())
        viewModel.updateDescription("清晰地说“完成”")

        viewModel.startGeneration(locale: "zh-Hans")
        await waitForAICueViewModel {
            viewModel.phase != .generating
                && viewModel.credentialStatus
                    == .stored(verification: .rejected, hasPendingReplacement: false)
        }

        expect(
            viewModel.credentialStatus
                == .stored(verification: .rejected, hasPendingReplacement: false),
            "明确 401 后 UI 必须刷新当前 profile 状态，不能继续显示 deferred/verified")
        expect(
            viewModel.failure == .generation(.provider(.invalidCredential)),
            "credential 状态刷新不能吞掉可修正的 generation 错误")
    }

    await suite("AI 提示音状态层：候选完整就绪后才建议名称，改名不重新请求") {
        let generation = aiCueComposerGeneration()
        let generator = ComposerGeneratorFixture(mode: .success(generation))
        let credentialManager = ComposerCredentialManagerFixture(
            status: .stored(verification: .deferred, hasPendingReplacement: false))
        let viewModel = AICueGenerationViewModel(
            credentialManager: credentialManager,
            generator: generator,
            providerProfileID: .elevenLabsGlobal)
        viewModel.begin(target: aiCueComposerTarget())
        viewModel.updateDescription("短促木琴完成音效")
        expect(viewModel.displayName.isEmpty, "第一步不得预先要求提示音名称")
        await viewModel.refreshCredentialStatus()
        await credentialManager.setStatus(
            .stored(verification: .verified, hasPendingReplacement: false))

        viewModel.startGeneration(locale: "zh-Hans")
        await waitForAICueViewModel { viewModel.phase == .candidatesReady }
        expect(viewModel.generation == generation, "必须一次性发布完整 generation")
        expect(viewModel.displayName == generation.plan.suggestedDisplayName, "名称建议只在候选阶段出现")

        viewModel.updateDisplayName("我的木琴")
        expect(viewModel.displayName == "我的木琴", "候选阶段必须允许直接修改最终名称")
        expect(await generator.facts().generations == 1, "只改名称绝不能重新请求 provider")
        expect(viewModel.generation == generation, "只改名称不能清理候选")
        expect(
            viewModel.credentialStatus
                == .stored(verification: .verified, hasPendingReplacement: false),
            "显式生成验证成功后必须立即刷新当前 profile 的 credential 投影")
    }

    await suite("AI 提示音状态层：修改声音描述立即作废并清理旧候选") {
        let generation = aiCueComposerGeneration()
        let generator = ComposerGeneratorFixture(mode: .success(generation))
        let viewModel = AICueGenerationViewModel(
            credentialManager: ComposerCredentialManagerFixture(
                status: .stored(verification: .verified, hasPendingReplacement: false)),
            generator: generator,
            providerProfileID: .elevenLabsGlobal)
        viewModel.begin(target: aiCueComposerTarget())
        viewModel.updateDescription("短促木琴")
        viewModel.startGeneration(locale: "zh-Hans")
        await waitForAICueViewModel { viewModel.phase == .candidatesReady }

        viewModel.updateDescription("改成两声猫叫")
        await waitForAICueViewModel { viewModel.phase == .editing }
        await waitForAICueDiscard(generator: generator, generationID: generation.id)
        let facts = await generator.facts()
        expect(viewModel.generation == nil, "描述变化后旧候选不能继续被采用")
        expect(viewModel.displayName.isEmpty, "描述变化后旧名称建议也必须失效")
        expect(facts.discarded.contains(generation.id), "旧 generation 私有目录必须清理")
        expect(facts.generations == 1, "修改描述本身不能自动重新生成")
    }

    await suite("AI 提示音状态层：采用成功后才进入 applied，并清理临时候选") {
        await withTempDirectory { root in
            let generation = aiCueComposerGeneration(root: root)
            let generator = ComposerGeneratorFixture(mode: .success(generation))
            let viewModel = AICueGenerationViewModel(
                credentialManager: ComposerCredentialManagerFixture(
                    status: .stored(verification: .verified, hasPendingReplacement: false)),
                generator: generator,
                providerProfileID: .elevenLabsGlobal)
            let target = aiCueComposerTarget()
            viewModel.begin(target: target)
            viewModel.updateDescription("短促木琴")
            viewModel.startGeneration(locale: "zh-Hans")
            await waitForAICueViewModel { viewModel.phase == .candidatesReady }
            viewModel.updateDisplayName("木琴完成")
            let imported = aiCueImportedFixture(root: root, packID: target.packID)
            var receivedRequest: AICueAdoptionRequest?

            viewModel.adopt(candidateID: generation.candidates[1].id) { request in
                receivedRequest = request
                expect(
                    request.candidate.id == generation.candidates[1].id,
                    "采用请求必须使用用户选中的候选")
                expect(request.target == target, "采用请求必须携带生成前冻结的三元目标")
                return .success(
                    AICueAdoptionOutcome(
                        target: request.target,
                        importedFile: imported,
                        finalDisplayName: request.displayName.value))
            }
            expect(viewModel.phase == .adopting, "采用操作必须立即进入忙状态")
            expect(
                viewModel.adoptingCandidateID == generation.candidates[1].id,
                "忙状态必须只标识用户实际采用的候选")
            await waitForAICueViewModel { viewModel.phase == .applied }
            expect(
                receivedRequest?.displayName.value == "木琴完成",
                "采用请求必须使用候选阶段确认后的名称")
            expect(viewModel.adoptionOutcome?.finalDisplayName == "木琴完成", "完成态必须返回真实最终名称")
            expect(viewModel.generation == nil, "采用成功后不得保留已失效的临时文件引用")
            expect(viewModel.adoptingCandidateID == nil, "成功终态必须清理采用中的候选身份")
            expect(
                await generator.facts().discarded.contains(generation.id),
                "导入与绑定完成后必须删除对应临时候选")
        }
    }

    await suite("AI 提示音状态层：采用失败保留候选以便恢复，旧完成态不得伪造") {
        let generation = aiCueComposerGeneration()
        let generator = ComposerGeneratorFixture(mode: .success(generation))
        let viewModel = AICueGenerationViewModel(
            credentialManager: ComposerCredentialManagerFixture(
                status: .stored(verification: .verified, hasPendingReplacement: false)),
            generator: generator,
            providerProfileID: .elevenLabsGlobal)
        viewModel.begin(target: aiCueComposerTarget())
        viewModel.updateDescription("短促木琴")
        viewModel.startGeneration(locale: "zh-Hans")
        await waitForAICueViewModel { viewModel.phase == .candidatesReady }
        viewModel.updateDisplayName("木琴完成")

        viewModel.adopt(candidateID: generation.candidates[0].id) { _ in
            .failure(.ineligible(.targetChanged))
        }
        expect(
            viewModel.adoptingCandidateID == generation.candidates[0].id,
            "失败返回前也只能标识正在采用的那一个候选")
        await waitForAICueViewModel { viewModel.phase != .adopting }
        expect(viewModel.phase == .candidatesReady, "采用失败必须回到可恢复的候选态")
        expect(
            viewModel.failure == .adoption(.ineligible(.targetChanged)),
            "采用失败必须保留语义错误而不是伪造成功")
        expect(viewModel.generation == generation, "未采用的候选必须留给用户重试或返回修改")
        expect(viewModel.adoptionOutcome == nil, "失败绝不能产生 applied outcome")
        expect(viewModel.adoptingCandidateID == nil, "失败恢复候选态时必须清理忙状态身份")
    }

    await suite("AI 提示音状态层：替换 key 失败时保留已配置状态与描述") {
        let credentials = ComposerCredentialManagerFixture(
            status: .stored(verification: .verified, hasPendingReplacement: false),
            saveMode: .fail(.invalidCredential))
        let viewModel = AICueGenerationViewModel(
            credentialManager: credentials,
            generator: ComposerGeneratorFixture(mode: .failure(.credentialRequired)),
            providerProfileID: .elevenLabsGlobal)
        viewModel.begin(target: aiCueComposerTarget())
        viewModel.updateDescription("两声猫叫")

        await viewModel.saveCredential(
            try! SensitiveCredentialInput("fixture-rejected-key"))
        expect(
            viewModel.credentialStatus
                == .stored(verification: .verified, hasPendingReplacement: false),
            "新 key 验证失败不能把旧已配置状态改成 missing")
        expect(
            viewModel.credentialFailure == .provider(.invalidCredential),
            "provider 拒绝必须投影为不含 key 的语义错误")
        expect(viewModel.soundDescription == "两声猫叫", "凭据失败不得污染生成表单")
        expect(await credentials.counts().saves == 1, "替换只能尝试一次")
    }

    await suite("AI 提示音状态层：切换 profile 取消生成并使未采用候选失效") {
        let suiteName = "AICueProviderSwitch.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = AICueProviderPreferences(defaults: defaults)
        let generator = ComposerGeneratorFixture(mode: .waitForCancellation)
        let viewModel = AICueGenerationViewModel(
            credentialManager: ComposerCredentialManagerFixture(status: .missing),
            generator: generator,
            providerProfileID: .elevenLabsGlobal,
            providerPreferences: preferences)
        viewModel.begin(target: aiCueComposerTarget())
        viewModel.updateDescription("请说\"完成\"")
        viewModel.startGeneration(locale: "zh-Hans")
        await waitForAICueViewModel { viewModel.phase == .generating }

        try! viewModel.selectProviderProfile(.qwenBeijing)
        expect(viewModel.phase == .editing, "切换 profile 必须立即取消旧 generation")
        expect(viewModel.generation == nil, "切换 profile 必须使所有未采用候选失效")
        expect(viewModel.soundDescription == "请说\"完成\"", "切换 profile 必须保留用户描述")
        expect(viewModel.providerProfileID == .qwenBeijing, "选择必须更新当前 profile")
        expect(
            AICueProviderPreferences(defaults: defaults).selectedProfileID() == .qwenBeijing,
            "profile/region 非敏感偏好必须跨实例持久化")
        expect(
            viewModel.availableProviderProfiles.map(\.id)
                == [.elevenLabsGlobal, .miniMaxGlobal, .qwenSingapore, .qwenBeijing],
            "production UI 的 profile 选择必须直接投影 registry 的完整稳定顺序")
        await waitForAICueViewModel { viewModel.phase != .generating }
    }

    suite("AI 提示音状态层：profile 偏好只接受 allowlist 且不含 credential") {
        let suiteName = "AICueProviderPreference.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = AICueProviderPreferences(defaults: defaults)
        try! preferences.select(.qwenSingapore)
        let profile = try! AICueProviderRegistry().profile(
            for: preferences.selectedProfileID())
        expect(profile.regionID == "singapore", "region 必须由选中的 registry profile 派生")
        expect(
            throwsProviderPreference {
                try preferences.select(AICueProviderProfileID(rawValue: "user-endpoint"))
            },
            "未知 profile/region 必须 fail closed")
        let snapshot = String(describing: defaults.dictionaryRepresentation())
        expect(
            !snapshot.localizedCaseInsensitiveContains("authorization")
                && !snapshot.localizedCaseInsensitiveContains("api-key")
                && snapshot.contains("qwen-singapore"),
            "偏好快照只能包含非敏感 allowlisted profile ID")
    }
}

private func throwsProviderPreference(_ body: () throws -> Void) -> Bool {
    do {
        try body()
        return false
    } catch {
        return true
    }
}

private func aiCueComposerTarget() -> AICueAdoptionTarget {
    try! AICueAdoptionTarget(surface: .workBuddy, event: .stop, packID: "workbuddy-pack")
}

private func aiCueComposerGeneration(root: URL? = nil) -> AICueGeneration {
    let generationID = UUID()
    let base = root ?? FileManager.default.temporaryDirectory
    let plan = AICueSoundPlan(
        suggestedDisplayName: "木琴完成",
        modality: .soundEffect,
        soundDescription: "短促木琴完成音效",
        spokenContent: nil,
        languageTag: nil,
        styleDescription: "短促、清晰",
        targetDurationMilliseconds: 1_500,
        instructionVersion: AICueSoundPlanner.instructionVersion)
    let candidates = AICueVariant.allCases.map { variant in
        AICueCandidate(
            id: UUID(),
            variant: variant,
            asset: AICueTemporaryAudioAsset(
                fileURL: base.appendingPathComponent("candidate-\(variant.ordinal).mp3"),
                byteCount: validMP3ID3Data().count,
                sniffedFormat: .mp3),
            durationMilliseconds: 1_200,
            mediaType: "audio/mpeg",
            provenance: AICueCandidateProvenance(
                providerID: .elevenLabs,
                profileID: .elevenLabsGlobal,
                modelID: "eleven_text_to_sound_v2",
                generationID: generationID,
                requestOrdinal: variant.ordinal,
                providerRequestID: nil))
    }
    return AICueGeneration(
        id: generationID,
        profileID: .elevenLabsGlobal,
        plan: plan,
        candidates: candidates,
        generatedAt: Date(timeIntervalSince1970: 1))
}

@MainActor
private func aiCueImportedFixture(root: URL, packID: String) -> ImportedAudioFile {
    let source = root.appendingPathComponent("source.mp3")
    writeFixture(validMP3ID3Data(), to: source)
    let environment = makeAudioImportEnvironment(
        userPacksDirectory: root.appendingPathComponent("packs", isDirectory: true))
    switch importAudioFile(
        sourceURL: source,
        suggestedFileName: "adopted.mp3",
        packID: packID,
        environment: environment)
    {
    case .success(let imported): return imported
    case .rejected(let reason): fatalError("fixture import rejected: \(reason)")
    }
}

@MainActor
private func waitForAICueViewModel(
    _ condition: @MainActor () -> Bool
) async {
    for _ in 0..<2_000 {
        if condition() { return }
        await Task.yield()
    }
    expect(false, "等待 AI 提示音状态转换超时")
}

private func waitForSuspendedCredentialStatus(
    _ credentialManager: SuspendedCredentialStatusManagerFixture
) async {
    for _ in 0..<2_000 {
        if await credentialManager.hasSuspendedStatusRequest { return }
        await Task.yield()
    }
    await MainActor.run {
        expect(false, "等待悬挂 credential status 读取超时")
    }
}

private func waitForAICueDiscard(
    generator: ComposerGeneratorFixture,
    generationID: UUID
) async {
    for _ in 0..<2_000 {
        if await generator.facts().discarded.contains(generationID) { return }
        await Task.yield()
    }
    await MainActor.run {
        expect(false, "等待 AI 提示音候选清理超时")
    }
}
