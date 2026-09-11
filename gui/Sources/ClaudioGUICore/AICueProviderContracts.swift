import ClaudioLocalization
import Foundation

public struct AICueProviderID: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let elevenLabs = AICueProviderID(rawValue: "elevenlabs")
    public static let miniMax = AICueProviderID(rawValue: "minimax")
    public static let qwen = AICueProviderID(rawValue: "qwen")
    public static let senseAudio = AICueProviderID(rawValue: "senseaudio")
}

public struct AICueProviderProfileID: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let elevenLabsGlobal = AICueProviderProfileID(rawValue: "elevenlabs-global")
    public static let miniMaxGlobal = AICueProviderProfileID(rawValue: "minimax-global")
    public static let qwenSingapore = AICueProviderProfileID(rawValue: "qwen-singapore")
    public static let qwenBeijing = AICueProviderProfileID(rawValue: "qwen-beijing")
    public static let senseAudioChina = AICueProviderProfileID(rawValue: "senseaudio-cn")
}

public struct AICueCredentialSlotID: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let legacyElevenLabs = AICueCredentialSlotID(rawValue: "elevenlabs")
    public static let miniMaxGlobal = AICueCredentialSlotID(rawValue: "minimax-global")
    public static let qwenSingapore = AICueCredentialSlotID(rawValue: "qwen-singapore")
    public static let qwenBeijing = AICueCredentialSlotID(rawValue: "qwen-beijing")
    public static let senseAudioChina = AICueCredentialSlotID(rawValue: "senseaudio-cn")
    package static let qwenSingaporePending =
        AICueCredentialSlotID(rawValue: "qwen-singapore.pending")
    package static let qwenBeijingPending =
        AICueCredentialSlotID(rawValue: "qwen-beijing.pending")
}

public enum AICueCredentialValidationPolicy: Sendable, Equatable {
    case readOnlyProbe
    case deferredUntilExplicitGeneration
}

public struct AICueCandidateOrdinal: RawRepresentable, Hashable, Sendable {
    public let rawValue: Int

    public init?(rawValue: Int) {
        guard (1...AICueGenerationRequest.candidateCount).contains(rawValue) else { return nil }
        self.rawValue = rawValue
    }
}

public enum AICueCandidateIdentity: Hashable, Sendable {
    case styled(AICueVariant)
    case numbered(AICueCandidateOrdinal)

    public var ordinal: Int {
        switch self {
        case .styled(let variant): variant.ordinal
        case .numbered(let ordinal): ordinal.rawValue
        }
    }

    public var styledVariant: AICueVariant? {
        guard case .styled(let variant) = self else { return nil }
        return variant
    }
}

public enum AICueCandidateSetSemantics: Sendable, Equatable {
    case styled
    case numbered
}

public struct AICueCandidateSetPolicy: Sendable, Equatable {
    public let semantics: AICueCandidateSetSemantics
    public let requestedCount: Int
    public let minimumAcceptedCount: Int

    public init(
        semantics: AICueCandidateSetSemantics,
        requestedCount: Int,
        minimumAcceptedCount: Int
    ) {
        self.semantics = semantics
        self.requestedCount = requestedCount
        self.minimumAcceptedCount = minimumAcceptedCount
    }

    package var isValid: Bool {
        requestedCount == AICueGenerationRequest.candidateCount
            && (1...requestedCount).contains(minimumAcceptedCount)
    }

    package func accepts(_ identity: AICueCandidateIdentity) -> Bool {
        switch (semantics, identity) {
        case (.styled, .styled), (.numbered, .numbered): true
        default: false
        }
    }
}

public struct AICuePCMFormat: Sendable, Equatable {
    public let sampleRate: Int
    public let bitsPerSample: Int
    public let channels: Int
    public let isLittleEndian: Bool

    public init(
        sampleRate: Int,
        bitsPerSample: Int,
        channels: Int,
        isLittleEndian: Bool
    ) {
        self.sampleRate = sampleRate
        self.bitsPerSample = bitsPerSample
        self.channels = channels
        self.isLittleEndian = isLittleEndian
    }
}

public struct AICueProviderConstraints: Sendable, Equatable {
    public let maximumDurationMilliseconds: Int

    public init(maximumDurationMilliseconds: Int) {
        self.maximumDurationMilliseconds = maximumDurationMilliseconds
    }
}

public enum AICueProviderAudioTransport: Sendable, Equatable {
    case directContainer
    case hexEncodedContainer
    case ssePCM(AICuePCMFormat)
    case remoteAssets
}

public enum AICueProviderAuthentication: String, Sendable, Equatable {
    case elevenLabsAPIKeyHeader
    case bearerAPIKey
}

public struct AICueProviderRoute: Sendable, Equatable {
    public let modality: AICueModality
    public let endpoint: URL
    public let modelID: String
    public let voiceID: String?
    public let supportedLanguageTags: Set<String>
    public let authentication: AICueProviderAuthentication
    public let transport: AICueProviderAudioTransport
    public let candidateSetPolicy: AICueCandidateSetPolicy

    public init(
        modality: AICueModality,
        endpoint: URL,
        modelID: String,
        voiceID: String?,
        supportedLanguageTags: Set<String>,
        authentication: AICueProviderAuthentication,
        transport: AICueProviderAudioTransport,
        candidateSetPolicy: AICueCandidateSetPolicy
    ) {
        self.modality = modality
        self.endpoint = endpoint
        self.modelID = modelID
        self.voiceID = voiceID
        self.supportedLanguageTags = supportedLanguageTags
        self.authentication = authentication
        self.transport = transport
        self.candidateSetPolicy = candidateSetPolicy
    }
}

public struct AICueProviderProfile: Sendable, Equatable {
    public let id: AICueProviderProfileID
    public let providerID: AICueProviderID
    public let credentialSlotID: AICueCredentialSlotID
    package let pendingCredentialSlotID: AICueCredentialSlotID?
    public let credentialValidationPolicy: AICueCredentialValidationPolicy
    public let regionID: String?
    public let displayNameKey: ClaudioL10nKey
    public let privacyDisclosureKey: ClaudioL10nKey
    public let routes: [AICueModality: AICueProviderRoute]
    public let constraints: AICueProviderConstraints

    public init(
        id: AICueProviderProfileID,
        providerID: AICueProviderID,
        credentialSlotID: AICueCredentialSlotID,
        pendingCredentialSlotID: AICueCredentialSlotID? = nil,
        credentialValidationPolicy: AICueCredentialValidationPolicy,
        regionID: String?,
        displayNameKey: ClaudioL10nKey,
        privacyDisclosureKey: ClaudioL10nKey,
        routes: [AICueModality: AICueProviderRoute],
        constraints: AICueProviderConstraints
    ) {
        self.id = id
        self.providerID = providerID
        self.credentialSlotID = credentialSlotID
        self.pendingCredentialSlotID = pendingCredentialSlotID
        self.credentialValidationPolicy = credentialValidationPolicy
        self.regionID = regionID
        self.displayNameKey = displayNameKey
        self.privacyDisclosureKey = privacyDisclosureKey
        self.routes = routes
        self.constraints = constraints
    }

    public var supportedModalities: Set<AICueModality> {
        Set(routes.keys)
    }
}

/// Provider-neutral generation input. Endpoint, model, voice, authentication, credentials and
/// transport framing remain registry/adapter concerns and cannot be supplied through this value.
public struct AICueProviderRequest: Sendable, Equatable {
    public let profileID: AICueProviderProfileID
    public let modality: AICueModality
    public let prompt: String
    public let spokenContent: String?
    public let languageTag: String?
    public let targetDurationMilliseconds: Int
    public let variant: AICueVariant

    public init(
        profileID: AICueProviderProfileID,
        modality: AICueModality,
        prompt: String,
        spokenContent: String?,
        languageTag: String?,
        targetDurationMilliseconds: Int,
        variant: AICueVariant
    ) {
        self.profileID = profileID
        self.modality = modality
        self.prompt = prompt
        self.spokenContent = spokenContent
        self.languageTag = languageTag
        self.targetDurationMilliseconds = targetDurationMilliseconds
        self.variant = variant
    }
}

public enum AICueProviderRequestCompilationError: Error, Sendable, Equatable {
    case unknownProfile
    case unsupportedModality
    case unsupportedLocale
    case spokenContentRequired
    case invalidSoundPlan
}

package enum AICueLanguageFamily: Sendable, Equatable {
    case chinese
    case english
}

package enum AICueLanguageTagMatcher {
    package static func matches(_ languageTag: String, allowlist: Set<String>) -> Bool {
        allowlist.contains { allowedTag in
            guard allowedTag.hasSuffix("*") else { return allowedTag == languageTag }
            let prefix = allowedTag.dropLast().lowercased()
            let normalized = languageTag.lowercased()
            return normalized == prefix
                || normalized.hasPrefix("\(prefix)-")
                || normalized.hasPrefix("\(prefix)_")
        }
    }

    package static func family(for languageTag: String) -> AICueLanguageFamily? {
        let primarySubtag =
            languageTag
            .split(whereSeparator: { $0 == "-" || $0 == "_" })
            .first?
            .lowercased()
        switch primarySubtag {
        case "zh": return .chinese
        case "en": return .english
        default: return nil
        }
    }
}

/// Turns one hidden local plan into a provider-neutral A/B/C request. The selected profile is
/// resolved through the allowlist before any adapter or credential boundary is reached.
public struct AICueProviderRequestCompiler: Sendable {
    private let registry: AICueProviderRegistry

    public init(registry: AICueProviderRegistry = AICueProviderRegistry()) {
        self.registry = registry
    }

    public func compile(
        plan: AICueSoundPlan,
        profileID: AICueProviderProfileID,
        variant: AICueVariant
    ) throws -> AICueProviderRequest {
        let profile: AICueProviderProfile
        do {
            profile = try registry.profile(for: profileID)
        } catch {
            throw AICueProviderRequestCompilationError.unknownProfile
        }
        guard profile.routes[plan.modality] != nil else {
            throw AICueProviderRequestCompilationError.unsupportedModality
        }
        guard
            plan.targetDurationMilliseconds > 0,
            plan.targetDurationMilliseconds <= profile.constraints.maximumDurationMilliseconds
        else {
            throw AICueProviderRequestCompilationError.invalidSoundPlan
        }

        switch plan.modality {
        case .speech, .mixed:
            guard
                let spokenContent = plan.spokenContent?.trimmingCharacters(
                    in: .whitespacesAndNewlines),
                !spokenContent.isEmpty
            else {
                throw AICueProviderRequestCompilationError.spokenContentRequired
            }
            guard
                let languageTag = plan.languageTag,
                profile.routes[plan.modality].map({
                    AICueLanguageTagMatcher.matches(
                        languageTag,
                        allowlist: $0.supportedLanguageTags)
                }) == true
            else {
                throw AICueProviderRequestCompilationError.unsupportedLocale
            }
            return AICueProviderRequest(
                profileID: profileID,
                modality: plan.modality,
                prompt: speechPrompt(
                    plan: plan,
                    variant: variant),
                spokenContent: spokenContent,
                languageTag: languageTag,
                targetDurationMilliseconds: plan.targetDurationMilliseconds,
                variant: variant)

        case .animal, .soundEffect:
            guard plan.spokenContent == nil, plan.languageTag == nil else {
                throw AICueProviderRequestCompilationError.invalidSoundPlan
            }
            return AICueProviderRequest(
                profileID: profileID,
                modality: plan.modality,
                prompt: soundPrompt(plan: plan, variant: variant),
                spokenContent: nil,
                languageTag: nil,
                targetDurationMilliseconds: plan.targetDurationMilliseconds,
                variant: variant)
        }
    }

    private func speechPrompt(
        plan: AICueSoundPlan,
        variant: AICueVariant
    ) -> String {
        let styleTag: String
        switch variant {
        case .clear: styleTag = "[clear]"
        case .brisk: styleTag = "[cheerful]"
        case .restrained: styleTag = "[calm]"
        }
        let userStyle = plan.styleDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return [userStyle, styleTag].filter { !$0.isEmpty }.joined(separator: " ")
    }

    private func soundPrompt(plan: AICueSoundPlan, variant: AICueVariant) -> String {
        let variation: String
        switch variant {
        case .clear: variation = "主体清晰，干净，无背景音乐"
        case .brisk: variation = "节奏稍轻快，起音明确，无背景音乐"
        case .restrained: variation = "克制、柔和、短促，无背景音乐"
        }
        return "\(plan.soundDescription)。\(variation)。总时长不超过 3 秒。"
    }
}
