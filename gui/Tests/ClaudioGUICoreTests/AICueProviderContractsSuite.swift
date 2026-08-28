import ClaudioGUICore
import Foundation

@MainActor
func runAICueProviderContractsSuites() {
    suite("AI 提示音 Provider registry：只暴露四个固定 profile 与 route-derived capability") {
        let registry = AICueProviderRegistry()
        let profiles = registry.profiles()

        expect(
            profiles.map(\.id) == [
                .elevenLabsGlobal, .miniMaxGlobal, .qwenSingapore, .qwenBeijing,
            ],
            "registry 必须只按稳定顺序暴露四个 allowlisted profile")
        expect(
            profiles.allSatisfy { $0.supportedModalities == Set($0.routes.keys) },
            "supportedModalities 必须只从 routes.keys 派生")
        expect(
            profiles.map(\.displayNameKey) == [
                .aiCueProviderProfileElevenLabsGlobal,
                .aiCueProviderProfileMiniMaxGlobal,
                .aiCueProviderProfileQwenSingapore,
                .aiCueProviderProfileQwenBeijing,
            ],
            "profile 的可见名称必须只引用双语 catalog key")
        expect(
            try! registry.profile(for: .elevenLabsGlobal).supportedModalities
                == Set(AICueModality.allCases),
            "ElevenLabs 必须保留四类 route")
        expect(
            try! registry.profile(for: .miniMaxGlobal).supportedModalities == [.speech],
            "MiniMax 首批只能开放 speech")
        expect(
            try! registry.profile(for: .qwenSingapore).supportedModalities == [.speech]
                && registry.profile(for: .qwenBeijing).supportedModalities == [.speech],
            "Qwen 两个 region profile 首批只能开放 speech")
    }

    suite("AI 提示音 Provider registry：未知 profile 与被篡改的固定合同 fail closed") {
        let registry = AICueProviderRegistry()
        expect(
            throwsRegistryError {
                _ = try registry.profile(
                    for: AICueProviderProfileID(rawValue: "user-controlled-profile"))
            },
            "未知 profile ID 必须拒绝")

        let elevenLabs = try! registry.profile(for: .elevenLabsGlobal)
        let speechRoute = elevenLabs.routes[.speech]!
        let qwen = try! registry.profile(for: .qwenSingapore)
        let invalidProfiles = [
            replacingRoute(
                in: elevenLabs,
                key: .speech,
                with: copying(speechRoute, modality: .soundEffect)),
            replacingRoute(
                in: elevenLabs,
                key: .speech,
                with: copying(
                    speechRoute,
                    endpoint: URL(string: "https://example.invalid/user-endpoint")!)),
            replacingRoute(
                in: elevenLabs,
                key: .speech,
                with: copying(speechRoute, modelID: "user-model")),
            replacingRoute(
                in: elevenLabs,
                key: .speech,
                with: copying(speechRoute, voiceID: "user-voice")),
            replacingRoute(
                in: elevenLabs,
                key: .speech,
                with: copying(speechRoute, supportedLanguageTags: [])),
            replacingRoute(
                in: elevenLabs,
                key: .speech,
                with: copying(speechRoute, authentication: .bearerAPIKey)),
            copying(elevenLabs, credentialSlotID: .qwenSingapore),
            copying(qwen, regionID: "user-region"),
        ]
        for invalidProfile in invalidProfiles {
            let alteredProfiles = registry.profiles().map {
                $0.id == invalidProfile.id ? invalidProfile : $0
            }
            expect(
                throwsRegistryError {
                    _ = try AICueProviderRegistry(validating: alteredProfiles)
                },
                "route/profile 固定合同任一漂移都必须让 registry 初始化失败")
        }
    }

    suite("AI 提示音 Provider registry：四个 profile 的 route、slot 与 policy 精确冻结") {
        let registry = AICueProviderRegistry()
        let elevenLabs = try! registry.profile(for: .elevenLabsGlobal)
        let miniMax = try! registry.profile(for: .miniMaxGlobal)
        let qwenSingapore = try! registry.profile(for: .qwenSingapore)
        let qwenBeijing = try! registry.profile(for: .qwenBeijing)

        expect(
            elevenLabs.credentialSlotID == .legacyElevenLabs
                && elevenLabs.credentialValidationPolicy == .readOnlyProbe,
            "ElevenLabs profile 必须继续映射旧 account 并使用只读 probe")
        expect(
            elevenLabs.routes[.speech]?.endpoint.absoluteString
                == "https://api.elevenlabs.io/v1/text-to-speech/JBFqnCBsd6RMkjVDRZzb"
                && elevenLabs.routes[.speech]?.modelID == "eleven_v3"
                && elevenLabs.routes[.speech]?.voiceID == "JBFqnCBsd6RMkjVDRZzb"
                && elevenLabs.routes[.soundEffect]?.endpoint.absoluteString
                    == "https://api.elevenlabs.io/v1/sound-generation"
                && elevenLabs.routes[.soundEffect]?.modelID == "eleven_text_to_sound_v2",
            "ElevenLabs speech/effect route 必须保持固定 endpoint/model/voice")
        expect(
            miniMax.credentialSlotID == .miniMaxGlobal
                && miniMax.credentialValidationPolicy == .readOnlyProbe
                && miniMax.routes[.speech]?.endpoint.absoluteString
                    == "https://api.minimax.io/v1/t2a_v2"
                && miniMax.routes[.speech]?.modelID == "speech-2.8-hd"
                && miniMax.routes[.speech]?.voiceID
                    == "Chinese (Mandarin)_Reliable_Executive"
                && miniMax.routes[.speech]?.transport == .hexEncodedContainer,
            "MiniMax profile 必须冻结 global slot、T2A route、voice 与 hex transport")
        expect(
            qwenSingapore.credentialSlotID == .qwenSingapore
                && qwenSingapore.regionID == "singapore"
                && qwenSingapore.credentialValidationPolicy
                    == .deferredUntilExplicitGeneration
                && qwenSingapore.routes[.speech]?.endpoint.host
                    == "dashscope-intl.aliyuncs.com",
            "Qwen Singapore 必须冻结独立 region、slot、deferred policy 与 host")
        expect(
            qwenBeijing.credentialSlotID == .qwenBeijing
                && qwenBeijing.regionID == "beijing"
                && qwenBeijing.routes[.speech]?.endpoint.host == "dashscope.aliyuncs.com",
            "Qwen Beijing 必须冻结独立 region、slot 与 host")
        expect(
            [qwenSingapore, qwenBeijing].allSatisfy {
                $0.routes[.speech]?.modelID == "qwen3-tts-instruct-flash"
                    && $0.routes[.speech]?.voiceID == "Cherry"
                    && $0.routes[.speech]?.authentication == .bearerAPIKey
                    && $0.routes[.speech]?.transport
                        == .ssePCM(
                            AICuePCMFormat(
                                sampleRate: 24_000,
                                bitsPerSample: 16,
                                channels: 1,
                                isLittleEndian: true))
            },
            "两个 Qwen region 必须共享固定 model/voice/auth/PCM，不共享 endpoint 或 slot")
    }

    suite("AI 提示音 request compiler：明确台词逐字保留且公共请求没有 Provider HTTP 字段") {
        let request = try! AICueGenerationRequest(
            description: "Say \"  Task  complete  \" in a calm voice",
            locale: "en",
            providerProfileID: .elevenLabsGlobal)
        let plan = try! AICueSoundPlanner().makePlan(for: request)
        let compiled = try! AICueProviderRequestCompiler().compile(
            plan: plan,
            profileID: request.providerProfileID,
            variant: .restrained)

        expect(plan.spokenContent == "Task  complete", "台词只能 trim 边缘，内部原文必须逐字保留")
        expect(compiled.spokenContent == "Task  complete", "provider-neutral request 必须保留明确台词")
        expect(compiled.profileID == .elevenLabsGlobal, "request 必须冻结所选 profile identity")
        let labels = Set(Mirror(reflecting: compiled).children.compactMap(\.label))
        expect(
            labels.isDisjoint(with: [
                "endpoint", "modelID", "voiceID", "headers", "authorization", "credential",
                "displayName",
            ]),
            "公共 request 不能携带 endpoint/model/voice/auth/secret/name")
    }

    suite("AI 提示音 request compiler：未知 profile、能力与 locale 在本地 fail closed") {
        let planner = AICueSoundPlanner()
        let animalPlan = try! planner.makePlan(
            for: try! AICueGenerationRequest(
                description: "一只小猫短促地叫两声",
                locale: "zh-Hans",
                providerProfileID: .miniMaxGlobal))
        expect(
            throwsCompilationError(.unsupportedModality) {
                _ = try AICueProviderRequestCompiler().compile(
                    plan: animalPlan,
                    profileID: .miniMaxGlobal,
                    variant: .clear)
            },
            "speech-only profile 不能把 animal 暗降级为 TTS")

        let unsupportedLocalePlan = AICueSoundPlan(
            suggestedDisplayName: "Bonjour",
            modality: .speech,
            soundDescription: "Say \"Bonjour\"",
            spokenContent: "Bonjour",
            languageTag: "fr",
            styleDescription: "calm",
            targetDurationMilliseconds: 2_000,
            instructionVersion: AICueSoundPlanner.instructionVersion)
        expect(
            throwsCompilationError(.unsupportedLocale) {
                _ = try AICueProviderRequestCompiler().compile(
                    plan: unsupportedLocalePlan,
                    profileID: .qwenSingapore,
                    variant: .clear)
            },
            "不支持的 locale 必须在 adapter 前拒绝")
        expect(
            throwsCompilationError(.unknownProfile) {
                _ = try AICueProviderRequestCompiler().compile(
                    plan: unsupportedLocalePlan,
                    profileID: AICueProviderProfileID(rawValue: "unknown"),
                    variant: .clear)
            },
            "未知 profile 必须在编译阶段 fail closed")
    }

    suite("AI 提示音台词语法：缺引号、空引号和缺右引号都本地拒绝") {
        for description in ["Say Task complete", "Say \"   \"", "Say \"Task complete"] {
            expect(
                throwsSpokenContentRequired {
                    let request = try AICueGenerationRequest(
                        description: description,
                        locale: "en",
                        providerProfileID: .elevenLabsGlobal)
                    _ = try AICueSoundPlanner().makePlan(for: request)
                },
                "无完整明确台词必须拒绝：\(description)")
        }
    }
}

private func throwsRegistryError(_ body: () throws -> Void) -> Bool {
    do {
        try body()
        return false
    } catch is AICueProviderRegistryError {
        return true
    } catch {
        return false
    }
}

private func replacingRoute(
    in profile: AICueProviderProfile,
    key: AICueModality,
    with route: AICueProviderRoute
) -> AICueProviderProfile {
    var routes = profile.routes
    routes[key] = route
    return copying(profile, routes: routes)
}

private func copying(
    _ profile: AICueProviderProfile,
    credentialSlotID: AICueCredentialSlotID? = nil,
    regionID: String? = nil,
    routes: [AICueModality: AICueProviderRoute]? = nil
) -> AICueProviderProfile {
    AICueProviderProfile(
        id: profile.id,
        providerID: profile.providerID,
        credentialSlotID: credentialSlotID ?? profile.credentialSlotID,
        credentialValidationPolicy: profile.credentialValidationPolicy,
        regionID: regionID ?? profile.regionID,
        displayNameKey: profile.displayNameKey,
        routes: routes ?? profile.routes,
        constraints: profile.constraints)
}

private func copying(
    _ route: AICueProviderRoute,
    modality: AICueModality? = nil,
    endpoint: URL? = nil,
    modelID: String? = nil,
    voiceID: String? = nil,
    supportedLanguageTags: Set<String>? = nil,
    authentication: AICueProviderAuthentication? = nil
) -> AICueProviderRoute {
    AICueProviderRoute(
        modality: modality ?? route.modality,
        endpoint: endpoint ?? route.endpoint,
        modelID: modelID ?? route.modelID,
        voiceID: voiceID ?? route.voiceID,
        supportedLanguageTags: supportedLanguageTags ?? route.supportedLanguageTags,
        authentication: authentication ?? route.authentication,
        transport: route.transport)
}

private func throwsCompilationError(
    _ expected: AICueProviderRequestCompilationError,
    _ body: () throws -> Void
) -> Bool {
    do {
        try body()
        return false
    } catch let error as AICueProviderRequestCompilationError {
        return error == expected
    } catch {
        return false
    }
}

private func throwsSpokenContentRequired(_ body: () throws -> Void) -> Bool {
    do {
        try body()
        return false
    } catch AICueValidationError.spokenContentRequired {
        return true
    } catch {
        return false
    }
}
