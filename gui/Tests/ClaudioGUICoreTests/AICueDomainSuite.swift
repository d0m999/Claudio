import ClaudioCore
import ClaudioGUICore
import Foundation

@MainActor
func runAICueDomainSuites() {
    suite("AI 提示音领域：生成请求只有描述与非采用上下文") {
        let request = try! AICueGenerationRequest(
            description: "  一只小猫短促地叫两声，第二声稍高  ",
            locale: "zh-Hans",
            providerProfileID: .elevenLabsGlobal)
        expect(request.description == "一只小猫短促地叫两声，第二声稍高", "描述必须去掉首尾空白")
        expect(request.candidateCount == 3, "首版每次必须固定生成三个候选")
        expect(request.maximumDurationMilliseconds == 3_000, "候选时长上限必须固定为三秒")
        expect(
            request.providerProfileID == .elevenLabsGlobal,
            "generation request 必须冻结选定的注册 profile")

        let labels = Set(Mirror(reflecting: request).children.compactMap(\.label))
        expect(!labels.contains("event"), "Event 不得进入 provider 生成请求")
        expect(!labels.contains("displayName"), "最终名称不得进入 provider 生成请求")
        expect(!labels.contains("surface"), "surface 不得进入 provider 生成请求")
        expect(!labels.contains("packID"), "packID 不得进入 provider 生成请求")
    }

    suite("AI 提示音领域：描述和最终名称分别做有界校验") {
        expect(
            throwsAICueValidation {
                _ = try AICueGenerationRequest(
                    description: "   ",
                    locale: "zh-Hans",
                    providerProfileID: .elevenLabsGlobal)
            },
            "空描述必须在任何网络请求前拒绝")
        expect(
            throwsAICueValidation {
                _ = try AICueGenerationRequest(
                    description: String(repeating: "声", count: 1_001),
                    locale: "zh-Hans",
                    providerProfileID: .elevenLabsGlobal)
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
                description: "用清晰中文说“本轮结束”",
                locale: "zh-Hans",
                providerProfileID: .elevenLabsGlobal))
        let animal = try! planner.makePlan(
            for: try! AICueGenerationRequest(
                description: "一只小猫短促地叫两声，第二声稍高，不要背景音乐",
                locale: "zh-Hans",
                providerProfileID: .elevenLabsGlobal))
        let effect = try! planner.makePlan(
            for: try! AICueGenerationRequest(
                description: "两枚木块清脆碰撞，短促，不要人声",
                locale: "zh-Hans",
                providerProfileID: .elevenLabsGlobal))
        let effectWithoutSpeech = try! planner.makePlan(
            for: try! AICueGenerationRequest(
                description: "短促木琴音效，不要说话",
                locale: "zh-Hans",
                providerProfileID: .elevenLabsGlobal))
        let mixed = try! planner.makePlan(
            for: try! AICueGenerationRequest(
                description: "先响一声轻柔木琴，再说“完成”",
                locale: "zh-Hans",
                providerProfileID: .elevenLabsGlobal))

        expect(speech.modality == .speech && speech.spokenContent == "本轮结束", "带明确台词的语音必须提取台词")
        expect(animal.modality == .animal && animal.spokenContent == nil, "动物叫声不能被强迫填写台词")
        expect(effect.modality == .soundEffect && effect.spokenContent == nil, "纯音效不能被强迫填写台词")
        expect(
            effectWithoutSpeech.modality == .soundEffect
                && effectWithoutSpeech.spokenContent == nil,
            "明确不要说话不能被单字意图 marker 误判成人声")
        expect(mixed.modality == .mixed && mixed.spokenContent == "完成", "语音与音效并存必须走混合路线")
        expect(
            [speech, animal, effect, mixed].allSatisfy {
                $0.targetDurationMilliseconds <= 3_000
                    && $0.instructionVersion == AICueSoundPlanner.instructionVersion
                    && !$0.suggestedDisplayName.isEmpty
            },
            "所有内部方案都必须带有界时长、版本和候选阶段名称建议")
    }

    suite("AI 提示音领域：provider-neutral compiler 生成三个有意差异的请求") {
        let planner = AICueSoundPlanner()
        let compiler = AICueProviderRequestCompiler()
        let speechPlan = try! planner.makePlan(
            for: try! AICueGenerationRequest(
                description: "用温和的声音说“可以继续”",
                locale: "zh-Hans",
                providerProfileID: .elevenLabsGlobal))
        let effectPlan = try! planner.makePlan(
            for: try! AICueGenerationRequest(
                description: "一声干净的木琴提示音",
                locale: "zh-Hans",
                providerProfileID: .elevenLabsGlobal))

        let variants = AICueVariant.allCases
        expect(variants == [.clear, .brisk, .restrained], "候选顺序必须稳定为清晰、轻快、克制")
        let speechRequests = variants.map {
            try! compiler.compile(
                plan: speechPlan,
                profileID: .elevenLabsGlobal,
                variant: $0)
        }
        let effectRequests = variants.map {
            try! compiler.compile(
                plan: effectPlan,
                profileID: .elevenLabsGlobal,
                variant: $0)
        }
        expect(
            speechRequests.allSatisfy { $0.modality == .speech },
            "语音 request 必须只表达领域 modality，不携带 provider model")
        expect(
            effectRequests.allSatisfy { $0.modality == .soundEffect },
            "音效 request 必须只表达领域 modality，不携带 provider route")
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

    suite("AI 候选 VoiceOver：播放与停止动作共享本地化候选身份") {
        expect(
            localizedAICueCandidatePreviewAccessibilityLabel(
                variant: .clear,
                duration: "1.6 seconds",
                isPlaying: false,
                language: .english) == "Play candidate A · Clear · 1.6 seconds",
            "未播放候选必须公告 Play、候选身份与时长")
        expect(
            localizedAICueCandidatePreviewAccessibilityLabel(
                variant: .brisk,
                duration: "1.7 秒",
                isPlaying: true,
                language: .zhHans) == "停止候选 B · 轻快 · 1.7 秒",
            "正在播放候选必须公告停止动作、候选身份与时长")
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
