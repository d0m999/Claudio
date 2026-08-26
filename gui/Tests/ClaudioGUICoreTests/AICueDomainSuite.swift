import ClaudioCore
import ClaudioGUICore
import Foundation

@MainActor
func runAICueDomainSuites() {
    suite("AI 提示音领域：生成请求只有描述与非采用上下文") {
        let request = try! AICueGenerationRequest(
            description: "  一只小猫短促地叫两声，第二声稍高  ",
            locale: "zh-Hans")
        expect(request.description == "一只小猫短促地叫两声，第二声稍高", "描述必须去掉首尾空白")
        expect(request.candidateCount == 3, "首版每次必须固定生成三个候选")
        expect(request.maximumDurationMilliseconds == 3_000, "候选时长上限必须固定为三秒")
        expect(request.providerID == .elevenLabs, "provider 必须来自固定注册表")

        let labels = Set(Mirror(reflecting: request).children.compactMap(\.label))
        expect(!labels.contains("event"), "Event 不得进入 provider 生成请求")
        expect(!labels.contains("displayName"), "最终名称不得进入 provider 生成请求")
        expect(!labels.contains("surface"), "surface 不得进入 provider 生成请求")
        expect(!labels.contains("packID"), "packID 不得进入 provider 生成请求")
    }

    suite("AI 提示音领域：描述和最终名称分别做有界校验") {
        expect(
            throwsAICueValidation {
                _ = try AICueGenerationRequest(description: "   ", locale: "zh-Hans")
            },
            "空描述必须在任何网络请求前拒绝")
        expect(
            throwsAICueValidation {
                _ = try AICueGenerationRequest(
                    description: String(repeating: "声", count: 1_001), locale: "zh-Hans")
            },
            "过长描述必须在任何网络请求前拒绝")

        expect(try! AICueDisplayName("  小猫两声  ").value == "小猫两声", "名称必须去掉首尾空白")
        expect(
            throwsAICueValidation { _ = try AICueDisplayName("\n") },
            "空名称不能采用")
        expect(
            throwsAICueValidation {
                _ = try AICueDisplayName(String(repeating: "声", count: 41))
            },
            "名称必须限制为四十个字符")
        expect(
            throwsAICueValidation { _ = try AICueDisplayName("第一行\n第二行") },
            "名称不得包含换行或控制字符")
    }

    suite("AI 提示音领域：本地声音方案覆盖语音、动物、音效与混合声音") {
        let planner = AICueSoundPlanner()
        let speech = try! planner.makePlan(
            for: try! AICueGenerationRequest(
                description: "用清晰中文说“本轮结束”", locale: "zh-Hans"))
        let animal = try! planner.makePlan(
            for: try! AICueGenerationRequest(
                description: "一只小猫短促地叫两声，第二声稍高，不要背景音乐", locale: "zh-Hans"))
        let effect = try! planner.makePlan(
            for: try! AICueGenerationRequest(
                description: "两枚木块清脆碰撞，短促，不要人声", locale: "zh-Hans"))
        let mixed = try! planner.makePlan(
            for: try! AICueGenerationRequest(
                description: "先响一声轻柔木琴，再说“完成”", locale: "zh-Hans"))

        expect(speech.modality == .speech && speech.spokenContent == "本轮结束", "带明确台词的语音必须提取台词")
        expect(animal.modality == .animal && animal.spokenContent == nil, "动物叫声不能被强迫填写台词")
        expect(effect.modality == .soundEffect && effect.spokenContent == nil, "纯音效不能被强迫填写台词")
        expect(mixed.modality == .mixed && mixed.spokenContent == "完成", "语音与音效并存必须走混合路线")
        expect(
            [speech, animal, effect, mixed].allSatisfy {
                $0.targetDurationMilliseconds <= 3_000
                    && $0.instructionVersion == AICueSoundPlanner.instructionVersion
                    && !$0.suggestedDisplayName.isEmpty
            },
            "所有内部方案都必须带有界时长、版本和候选阶段名称建议")
    }

    suite("AI 提示音领域：固定模型按声音类型路由且 A/B/C 是三个有意差异的请求") {
        let planner = AICueSoundPlanner()
        let compiler = ElevenLabsAICueRequestCompiler()
        let speechPlan = try! planner.makePlan(
            for: try! AICueGenerationRequest(
                description: "用温和的声音说“可以继续”", locale: "zh-Hans"))
        let effectPlan = try! planner.makePlan(
            for: try! AICueGenerationRequest(
                description: "一声干净的木琴提示音", locale: "zh-Hans"))

        let variants = AICueVariant.allCases
        expect(variants == [.clear, .brisk, .restrained], "候选顺序必须稳定为清晰、轻快、克制")
        let speechRequests = variants.map { compiler.compile(plan: speechPlan, variant: $0) }
        let effectRequests = variants.map { compiler.compile(plan: effectPlan, variant: $0) }
        expect(
            speechRequests.allSatisfy {
                $0.route == .textToSpeech
                    && $0.modelID == ElevenLabsAICueRequestCompiler.speechModelID
            },
            "语音必须固定路由 eleven_v3")
        expect(
            effectRequests.allSatisfy {
                $0.route == .soundGeneration
                    && $0.modelID == ElevenLabsAICueRequestCompiler.soundEffectModelID
            },
            "纯音效必须固定路由 eleven_text_to_sound_v2")
        expect(Set(speechRequests.map(\.prompt)).count == 3, "三个语音候选必须使用不同的变体约束")
        expect(Set(effectRequests.map(\.prompt)).count == 3, "三个音效候选必须使用不同的变体约束")
        expect(
            (speechRequests + effectRequests).allSatisfy {
                !$0.prompt.contains(Event.stop.cliName)
                    && !$0.prompt.contains(HostSurfaceID.workBuddy.rawValue)
            },
            "编译后的 provider prompt 不能夹带事件或来源 token")
    }

    suite("AI 提示音领域：采用目标显式冻结 surface、Event 与 packID") {
        let target = try! AICueAdoptionTarget(
            surface: .workBuddy,
            event: .stop,
            packID: "my-workbuddy-cues")
        expect(target.surface == .workBuddy, "采用目标必须保留明确 surface")
        expect(target.event == .stop, "采用目标必须保留公共 Event")
        expect(target.packID == "my-workbuddy-cues", "采用目标必须保留用户包 ID")
        expect(
            throwsAICueValidation {
                _ = try AICueAdoptionTarget(
                    surface: .workBuddy,
                    event: .stop,
                    packID: "../escape")
            },
            "不安全 packID 必须在采用前拒绝")
    }
}

private func throwsAICueValidation(_ body: () throws -> Void) -> Bool {
    do {
        try body()
        return false
    } catch is AICueValidationError {
        return true
    } catch {
        return false
    }
}
