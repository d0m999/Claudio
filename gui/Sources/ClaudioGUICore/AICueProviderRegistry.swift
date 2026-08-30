import ClaudioLocalization
import Foundation

public enum AICueProviderRegistryError: Error, Sendable, Equatable {
    case unknownProfile
    case invalidProfileSet
    case invalidProfileContract
}

/// The application-owned profile allowlist. A selected raw ID is only trusted after a lookup;
/// endpoint, model, voice, region, authentication and credential-slot values never come from it.
public struct AICueProviderRegistry: Sendable {
    private let orderedProfiles: [AICueProviderProfile]
    private let profilesByID: [AICueProviderProfileID: AICueProviderProfile]

    public init() {
        do {
            try self.init(validating: Self.allowlistedProfiles)
        } catch {
            preconditionFailure("Built-in AI cue provider profiles are invalid")
        }
    }

    package init(validating profiles: [AICueProviderProfile]) throws {
        let expected = Self.allowlistedProfiles
        let expectedIDs = Set(expected.map(\.id))
        let actualIDs = Set(profiles.map(\.id))
        guard
            profiles.count == expected.count,
            actualIDs.count == profiles.count,
            actualIDs == expectedIDs
        else {
            throw AICueProviderRegistryError.invalidProfileSet
        }

        let expectedByID = Dictionary(uniqueKeysWithValues: expected.map { ($0.id, $0) })
        for profile in profiles {
            guard
                profile.routes.allSatisfy({ $0.key == $0.value.modality }),
                profile.supportedModalities == Set(profile.routes.keys),
                profile.routes.values.allSatisfy({ !$0.supportedLanguageTags.isEmpty }),
                expectedByID[profile.id] == profile
            else {
                throw AICueProviderRegistryError.invalidProfileContract
            }
        }

        orderedProfiles = expected.map { expectedProfile in
            profiles.first(where: { $0.id == expectedProfile.id })!
        }
        profilesByID = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })
    }

    public func profiles() -> [AICueProviderProfile] {
        orderedProfiles
    }

    public func profile(for profileID: AICueProviderProfileID) throws -> AICueProviderProfile {
        guard let profile = profilesByID[profileID] else {
            throw AICueProviderRegistryError.unknownProfile
        }
        return profile
    }

    private static let allowlistedProfiles: [AICueProviderProfile] = [
        elevenLabsGlobal,
        miniMaxGlobal,
        qwenSingapore,
        qwenBeijing,
    ]

    private static let elevenLabsGlobal: AICueProviderProfile = {
        let speechEndpoint = fixedURL(
            "https://api.elevenlabs.io/v1/text-to-speech/JBFqnCBsd6RMkjVDRZzb")
        let effectsEndpoint = fixedURL("https://api.elevenlabs.io/v1/sound-generation")
        let languages: Set<String> = ["zh", "zh-Hans", "en"]
        let speech = AICueProviderRoute(
            modality: .speech,
            endpoint: speechEndpoint,
            modelID: "eleven_v3",
            voiceID: "JBFqnCBsd6RMkjVDRZzb",
            supportedLanguageTags: languages,
            authentication: .elevenLabsAPIKeyHeader,
            transport: .directContainer)
        let mixed = AICueProviderRoute(
            modality: .mixed,
            endpoint: speechEndpoint,
            modelID: "eleven_v3",
            voiceID: "JBFqnCBsd6RMkjVDRZzb",
            supportedLanguageTags: languages,
            authentication: .elevenLabsAPIKeyHeader,
            transport: .directContainer)
        let animal = AICueProviderRoute(
            modality: .animal,
            endpoint: effectsEndpoint,
            modelID: "eleven_text_to_sound_v2",
            voiceID: nil,
            supportedLanguageTags: languages,
            authentication: .elevenLabsAPIKeyHeader,
            transport: .directContainer)
        let soundEffect = AICueProviderRoute(
            modality: .soundEffect,
            endpoint: effectsEndpoint,
            modelID: "eleven_text_to_sound_v2",
            voiceID: nil,
            supportedLanguageTags: languages,
            authentication: .elevenLabsAPIKeyHeader,
            transport: .directContainer)
        return AICueProviderProfile(
            id: .elevenLabsGlobal,
            providerID: .elevenLabs,
            credentialSlotID: .legacyElevenLabs,
            credentialValidationPolicy: .readOnlyProbe,
            regionID: nil,
            displayNameKey: .aiCueProviderProfileElevenLabsGlobal,
            routes: [
                .speech: speech,
                .mixed: mixed,
                .animal: animal,
                .soundEffect: soundEffect,
            ],
            constraints: AICueProviderConstraints(
                supportsInstructionControl: true,
                maximumDurationMilliseconds: 3_000))
    }()

    private static let miniMaxGlobal = AICueProviderProfile(
        id: .miniMaxGlobal,
        providerID: .miniMax,
        credentialSlotID: .miniMaxGlobal,
        credentialValidationPolicy: .readOnlyProbe,
        regionID: nil,
        displayNameKey: .aiCueProviderProfileMiniMaxGlobal,
        routes: [
            .speech: AICueProviderRoute(
                modality: .speech,
                endpoint: fixedURL("https://api.minimax.io/v1/t2a_v2"),
                modelID: "speech-2.8-hd",
                voiceID: "Chinese (Mandarin)_Reliable_Executive",
                supportedLanguageTags: ["zh", "zh-Hans"],
                authentication: .bearerAPIKey,
                transport: .hexEncodedContainer)
        ],
        constraints: AICueProviderConstraints(
            supportsInstructionControl: false,
            maximumDurationMilliseconds: 3_000))

    private static let qwenSingapore = qwenProfile(
        id: .qwenSingapore,
        slotID: .qwenSingapore,
        regionID: "singapore",
        displayNameKey: .aiCueProviderProfileQwenSingapore,
        endpoint:
            "https://dashscope-intl.aliyuncs.com/api/v1/services/aigc/"
            + "multimodal-generation/generation")

    private static let qwenBeijing = qwenProfile(
        id: .qwenBeijing,
        slotID: .qwenBeijing,
        regionID: "beijing",
        displayNameKey: .aiCueProviderProfileQwenBeijing,
        endpoint:
            "https://dashscope.aliyuncs.com/api/v1/services/aigc/"
            + "multimodal-generation/generation")

    private static func qwenProfile(
        id: AICueProviderProfileID,
        slotID: AICueCredentialSlotID,
        regionID: String,
        displayNameKey: ClaudioL10nKey,
        endpoint: String
    ) -> AICueProviderProfile {
        AICueProviderProfile(
            id: id,
            providerID: .qwen,
            credentialSlotID: slotID,
            pendingCredentialSlotID: pendingSlotID(for: id),
            credentialValidationPolicy: .deferredUntilExplicitGeneration,
            regionID: regionID,
            displayNameKey: displayNameKey,
            routes: [
                .speech: AICueProviderRoute(
                    modality: .speech,
                    endpoint: fixedURL(endpoint),
                    modelID: "qwen3-tts-instruct-flash",
                    voiceID: "Cherry",
                    supportedLanguageTags: ["zh*", "en*"],
                    authentication: .bearerAPIKey,
                    transport: .ssePCM(
                        AICuePCMFormat(
                            sampleRate: 24_000,
                            bitsPerSample: 16,
                            channels: 1,
                            isLittleEndian: true)))
            ],
            constraints: AICueProviderConstraints(
                supportsInstructionControl: true,
                maximumDurationMilliseconds: 3_000))
    }

    private static func fixedURL(_ value: String) -> URL {
        guard let url = URL(string: value) else {
            preconditionFailure("Invalid built-in AI cue provider URL")
        }
        return url
    }

    private static func pendingSlotID(
        for profileID: AICueProviderProfileID
    ) -> AICueCredentialSlotID {
        switch profileID {
        case .qwenSingapore: return .qwenSingaporePending
        case .qwenBeijing: return .qwenBeijingPending
        default: preconditionFailure("Only Qwen profiles own pending credential slots")
        }
    }
}
