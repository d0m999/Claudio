import ClaudioGUICore
import Foundation

private actor DispatcherGeneratorFixture: AICueGenerating {
    private let returnedProfileID: AICueProviderProfileID
    private var requestedProfileIDs: [AICueProviderProfileID] = []
    private var discardedGenerationIDs: [UUID] = []
    private var discardAllCount = 0

    init(returnedProfileID: AICueProviderProfileID) {
        self.returnedProfileID = returnedProfileID
    }

    func generate(
        description: String,
        locale: String,
        providerProfileID: AICueProviderProfileID,
        deadline: AICueGenerationDeadline
    ) async throws -> AICueGeneration {
        requestedProfileIDs.append(providerProfileID)
        return AICueGeneration(
            id: UUID(),
            profileID: returnedProfileID,
            plan: AICueSoundPlan(
                suggestedDisplayName: "fixture",
                modality: .speech,
                soundDescription: description,
                spokenContent: "fixture",
                languageTag: locale,
                styleDescription: description,
                targetDurationMilliseconds: 1_000,
                instructionVersion: AICueSoundPlanner.instructionVersion),
            candidates: [],
            generatedAt: Date(timeIntervalSince1970: 1))
    }

    func discard(generationID: UUID) {
        discardedGenerationIDs.append(generationID)
    }

    func discardAll() {
        discardAllCount += 1
    }

    func facts() -> (requests: [AICueProviderProfileID], discarded: [UUID], discardAll: Int) {
        (requestedProfileIDs, discardedGenerationIDs, discardAllCount)
    }
}

func runAICueGenerationDispatcherSuites() async {
    await suite("AI 提示音 dispatcher：只把显式 profile 路由给对应 engine 并归还清理") {
        let elevenLabs = DispatcherGeneratorFixture(returnedProfileID: .elevenLabsGlobal)
        let miniMax = DispatcherGeneratorFixture(returnedProfileID: .miniMaxGlobal)
        let qwenSingapore = DispatcherGeneratorFixture(returnedProfileID: .qwenSingapore)
        let qwenBeijing = DispatcherGeneratorFixture(returnedProfileID: .qwenBeijing)
        let dispatcher = try! AICueGenerationDispatcher(generators: [
            .elevenLabsGlobal: elevenLabs,
            .miniMaxGlobal: miniMax,
            .qwenSingapore: qwenSingapore,
            .qwenBeijing: qwenBeijing,
        ])

        let generation = try! await dispatcher.generate(
            description: "清晰地说“完成”",
            locale: "zh-Hans",
            providerProfileID: .qwenBeijing,
            deadline: .startingNow())
        expect(
            await qwenBeijing.facts().requests == [.qwenBeijing],
            "dispatcher 必须只调用用户显式选择的 region/profile")
        let elevenLabsFacts = await elevenLabs.facts()
        let miniMaxFacts = await miniMax.facts()
        let qwenSingaporeFacts = await qwenSingapore.facts()
        expect(
            elevenLabsFacts.requests.isEmpty
                && miniMaxFacts.requests.isEmpty
                && qwenSingaporeFacts.requests.isEmpty,
            "dispatcher 不得 fallback、跨区或复用其他 Provider engine")

        await dispatcher.discard(generationID: generation.id)
        expect(
            await qwenBeijing.facts().discarded == [generation.id],
            "候选清理必须返回创建该 generation 的 engine")
        expect(await elevenLabs.facts().discarded.isEmpty, "清理不得广播到无关 engine")
    }

    await suite("AI 提示音 dispatcher：profile 集合或返回身份漂移时失败关闭") {
        let incomplete: [AICueProviderProfileID: any AICueGenerating] = [
            .elevenLabsGlobal: DispatcherGeneratorFixture(
                returnedProfileID: .elevenLabsGlobal)
        ]
        do {
            _ = try AICueGenerationDispatcher(generators: incomplete)
            expect(false, "缺少 allowlisted profile 的 production dispatcher 必须拒绝初始化")
        } catch AICueGenerationDispatcherError.invalidProfileSet {
            expect(true, "不完整 profile 集合已失败关闭")
        } catch {
            expect(false, "不完整 profile 集合返回了错误的语义错误")
        }

        let mismatched = DispatcherGeneratorFixture(returnedProfileID: .miniMaxGlobal)
        let dispatcher = try! AICueGenerationDispatcher(generators: [
            .elevenLabsGlobal: mismatched,
            .miniMaxGlobal: DispatcherGeneratorFixture(returnedProfileID: .miniMaxGlobal),
            .qwenSingapore: DispatcherGeneratorFixture(returnedProfileID: .qwenSingapore),
            .qwenBeijing: DispatcherGeneratorFixture(returnedProfileID: .qwenBeijing),
        ])
        do {
            _ = try await dispatcher.generate(
                description: "清晰地说“完成”",
                locale: "zh-Hans",
                providerProfileID: .elevenLabsGlobal,
                deadline: .startingNow())
            expect(false, "engine 返回错误 profile 身份时不得发布 generation")
        } catch AICueGenerationError.providerUnavailable {
            expect(await mismatched.facts().discarded.count == 1, "身份漂移的临时候选必须清理")
        } catch {
            expect(false, "profile 身份漂移返回了错误的语义错误")
        }
    }
}
