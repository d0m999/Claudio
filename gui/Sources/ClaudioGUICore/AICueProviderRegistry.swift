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
    private let assetPoliciesByProfileID: [AICueProviderProfileID: AICueAssetPolicy]

    public init() {
        do {
            try self.init(
                validating: Self.allowlistedProfiles,
                expectedProfiles: Self.allowlistedProfiles,
                assetPoliciesByProfileID: [:])
        } catch {
            preconditionFailure("Built-in AI cue provider profiles are invalid")
        }
    }

    package init(validating profiles: [AICueProviderProfile]) throws {
        try self.init(
            validating: profiles,
            expectedProfiles: Self.allowlistedProfiles,
            assetPoliciesByProfileID: [:])
    }

    /// Deterministic fixtures can exercise the complete SenseAudio contract while production
    /// remains on the four-profile allowlist. A real build may use this initializer only after an
    /// official, smoke-verified exact asset origin has replaced the nil evidence gate.
    package init(evidenceGatedSenseAudioAssetPolicy assetPolicy: AICueAssetPolicy) {
        let expected = Self.allowlistedProfiles + [Self.senseAudioChina]
        do {
            try self.init(
                validating: expected,
                expectedProfiles: expected,
                assetPoliciesByProfileID: [.senseAudioChina: assetPolicy])
        } catch {
            preconditionFailure("Evidence-gated SenseAudio provider profile is invalid")
        }
    }

    private init(
        validating profiles: [AICueProviderProfile],
        expectedProfiles expected: [AICueProviderProfile],
        assetPoliciesByProfileID: [AICueProviderProfileID: AICueAssetPolicy]
    ) throws {
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
                profile.routes.values.allSatisfy({ $0.candidateSetPolicy.isValid }),
                expectedByID[profile.id] == profile
            else {
                throw AICueProviderRegistryError.invalidProfileContract
            }
        }
        guard Set(assetPoliciesByProfileID.keys).isSubset(of: actualIDs) else {
            throw AICueProviderRegistryError.invalidProfileContract
        }

        orderedProfiles = expected.map { expectedProfile in
            profiles.first(where: { $0.id == expectedProfile.id })!
        }
        profilesByID = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })
        self.assetPoliciesByProfileID = assetPoliciesByProfileID
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

    package func assetPolicy(for profileID: AICueProviderProfileID) -> AICueAssetPolicy? {
        assetPoliciesByProfileID[profileID]
    }

    private static let allowlistedProfiles: [AICueProviderProfile] = [
        elevenLabsGlobal,
        miniMaxGlobal,
        qwenSingapore,
        qwenBeijing,
    ]

    /// Intentionally nil until SenseAudio confirms a stable production asset origin and a paid
    /// smoke proves exact origin, MIME, no-auth GET and no-redirect behavior.
    package static let productionSenseAudioAssetPolicy: AICueAssetPolicy? = nil

    private static let styledComplete = AICueCandidateSetPolicy(
        semantics: .styled,
        requestedCount: 3,
        minimumAcceptedCount: 3)
    private static let numberedComplete = AICueCandidateSetPolicy(
        semantics: .numbered,
        requestedCount: 3,
        minimumAcceptedCount: 3)
    private static let numberedPartial = AICueCandidateSetPolicy(
        semantics: .numbered,
        requestedCount: 3,
        minimumAcceptedCount: 1)

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
            transport: .directContainer,
            candidateSetPolicy: styledComplete)
        let mixed = AICueProviderRoute(
            modality: .mixed,
            endpoint: speechEndpoint,
            modelID: "eleven_v3",
            voiceID: "JBFqnCBsd6RMkjVDRZzb",
            supportedLanguageTags: languages,
            authentication: .elevenLabsAPIKeyHeader,
            transport: .directContainer,
            candidateSetPolicy: styledComplete)
        let animal = AICueProviderRoute(
            modality: .animal,
            endpoint: effectsEndpoint,
            modelID: "eleven_text_to_sound_v2",
            voiceID: nil,
            supportedLanguageTags: languages,
            authentication: .elevenLabsAPIKeyHeader,
            transport: .directContainer,
            candidateSetPolicy: styledComplete)
        let soundEffect = AICueProviderRoute(
            modality: .soundEffect,
            endpoint: effectsEndpoint,
            modelID: "eleven_text_to_sound_v2",
            voiceID: nil,
            supportedLanguageTags: languages,
            authentication: .elevenLabsAPIKeyHeader,
            transport: .directContainer,
            candidateSetPolicy: styledComplete)
        return AICueProviderProfile(
            id: .elevenLabsGlobal,
            providerID: .elevenLabs,
            credentialSlotID: .legacyElevenLabs,
            credentialValidationPolicy: .readOnlyProbe,
            regionID: nil,
            displayNameKey: .aiCueProviderProfileElevenLabsGlobal,
            privacyDisclosureKey: .aiCueCredentialPrivacy,
            routes: [
                .speech: speech,
                .mixed: mixed,
                .animal: animal,
                .soundEffect: soundEffect,
            ],
            constraints: AICueProviderConstraints(maximumDurationMilliseconds: 3_000))
    }()

    private static let miniMaxGlobal = AICueProviderProfile(
        id: .miniMaxGlobal,
        providerID: .miniMax,
        credentialSlotID: .miniMaxGlobal,
        credentialValidationPolicy: .readOnlyProbe,
        regionID: nil,
        displayNameKey: .aiCueProviderProfileMiniMaxGlobal,
        privacyDisclosureKey: .aiCueCredentialPrivacyMiniMax,
        routes: [
            .speech: AICueProviderRoute(
                modality: .speech,
                endpoint: fixedURL("https://api.minimax.io/v1/t2a_v2"),
                modelID: "speech-2.8-hd",
                voiceID: "Chinese (Mandarin)_Reliable_Executive",
                supportedLanguageTags: ["zh", "zh-Hans"],
                authentication: .bearerAPIKey,
                transport: .hexEncodedContainer,
                candidateSetPolicy: numberedComplete)
        ],
        constraints: AICueProviderConstraints(maximumDurationMilliseconds: 3_000))

    private static let qwenSingapore = qwenProfile(
        id: .qwenSingapore,
        slotID: .qwenSingapore,
        regionID: "singapore",
        displayNameKey: .aiCueProviderProfileQwenSingapore,
        privacyDisclosureKey: .aiCueCredentialPrivacyQwenSingapore,
        endpoint:
            "https://dashscope-intl.aliyuncs.com/api/v1/services/aigc/"
            + "multimodal-generation/generation")

    private static let qwenBeijing = qwenProfile(
        id: .qwenBeijing,
        slotID: .qwenBeijing,
        regionID: "beijing",
        displayNameKey: .aiCueProviderProfileQwenBeijing,
        privacyDisclosureKey: .aiCueCredentialPrivacyQwenBeijing,
        endpoint:
            "https://dashscope.aliyuncs.com/api/v1/services/aigc/"
            + "multimodal-generation/generation")

    private static func qwenProfile(
        id: AICueProviderProfileID,
        slotID: AICueCredentialSlotID,
        regionID: String,
        displayNameKey: ClaudioL10nKey,
        privacyDisclosureKey: ClaudioL10nKey,
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
            privacyDisclosureKey: privacyDisclosureKey,
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
                            isLittleEndian: true)),
                    candidateSetPolicy: styledComplete)
            ],
            constraints: AICueProviderConstraints(maximumDurationMilliseconds: 3_000))
    }

    private static let senseAudioChina: AICueProviderProfile = {
        let speech = AICueProviderRoute(
            modality: .speech,
            endpoint: fixedURL("https://api.senseaudio.cn/v1/t2a_v2"),
            modelID: "sensenova-tts-2.0",
            voiceID: "female_0033_b",
            supportedLanguageTags: ["zh*"],
            authentication: .bearerAPIKey,
            transport: .hexEncodedContainer,
            candidateSetPolicy: numberedComplete)
        let sfxEndpoint = fixedURL("https://api.senseaudio.cn/v1/sound-effects/generations")
        let animal = AICueProviderRoute(
            modality: .animal,
            endpoint: sfxEndpoint,
            modelID: "senseaudio-sfx-1.0-260626",
            voiceID: nil,
            supportedLanguageTags: ["zh*"],
            authentication: .bearerAPIKey,
            transport: .remoteAssets,
            candidateSetPolicy: numberedPartial)
        let soundEffect = AICueProviderRoute(
            modality: .soundEffect,
            endpoint: sfxEndpoint,
            modelID: "senseaudio-sfx-1.0-260626",
            voiceID: nil,
            supportedLanguageTags: ["zh*"],
            authentication: .bearerAPIKey,
            transport: .remoteAssets,
            candidateSetPolicy: numberedPartial)
        return AICueProviderProfile(
            id: .senseAudioChina,
            providerID: .senseAudio,
            credentialSlotID: .senseAudioChina,
            credentialValidationPolicy: .readOnlyProbe,
            regionID: "china",
            displayNameKey: .aiCueProviderProfileSenseAudioChina,
            privacyDisclosureKey: .aiCueCredentialPrivacySenseAudioChina,
            routes: [.speech: speech, .animal: animal, .soundEffect: soundEffect],
            constraints: AICueProviderConstraints(maximumDurationMilliseconds: 3_000))
    }()

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
