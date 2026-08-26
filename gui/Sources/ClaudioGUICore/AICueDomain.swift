import ClaudioCore
import Foundation

public struct AICueProviderID: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let elevenLabs = AICueProviderID(rawValue: "elevenlabs")
}

public enum AICueValidationError: Error, Sendable, Equatable {
    case emptyDescription
    case descriptionTooLong(maximumCharacters: Int)
    case invalidLocale
    case emptyDisplayName
    case displayNameTooLong(maximumCharacters: Int)
    case displayNameContainsControlCharacters
    case spokenContentRequiresQuotes
    case unsafePackID
}

public struct AICueGenerationRequest: Sendable, Equatable {
    public static let maximumDescriptionCharacters = 1_000
    public static let candidateCount = 3
    public static let maximumDurationMilliseconds = 3_000

    public let description: String
    public let locale: String
    public let candidateCount: Int
    public let maximumDurationMilliseconds: Int
    public let providerID: AICueProviderID

    public init(description: String, locale: String) throws {
        let normalizedDescription = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedDescription.isEmpty else {
            throw AICueValidationError.emptyDescription
        }
        guard normalizedDescription.count <= Self.maximumDescriptionCharacters else {
            throw AICueValidationError.descriptionTooLong(
                maximumCharacters: Self.maximumDescriptionCharacters)
        }
        let normalizedLocale = locale.trimmingCharacters(in: .whitespacesAndNewlines)
        let localeCharacterSet = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        guard
            !normalizedLocale.isEmpty,
            normalizedLocale.count <= 64,
            normalizedLocale.unicodeScalars.allSatisfy(localeCharacterSet.contains)
        else {
            throw AICueValidationError.invalidLocale
        }

        self.description = normalizedDescription
        self.locale = normalizedLocale
        candidateCount = Self.candidateCount
        maximumDurationMilliseconds = Self.maximumDurationMilliseconds
        providerID = .elevenLabs
    }
}

public struct AICueDisplayName: Hashable, Sendable {
    public static let maximumCharacters = 40

    public let value: String

    public init(_ value: String) throws {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw AICueValidationError.emptyDisplayName }
        guard normalized.count <= Self.maximumCharacters else {
            throw AICueValidationError.displayNameTooLong(
                maximumCharacters: Self.maximumCharacters)
        }
        guard
            normalized.unicodeScalars.allSatisfy({
                !CharacterSet.controlCharacters.contains($0)
                    && !CharacterSet.newlines.contains($0)
            })
        else {
            throw AICueValidationError.displayNameContainsControlCharacters
        }
        self.value = normalized
    }
}

public enum AICueModality: String, CaseIterable, Sendable, Equatable {
    case speech
    case animal
    case soundEffect
    case mixed
}

public enum AICueVariant: String, CaseIterable, Sendable, Equatable, Hashable {
    case clear
    case brisk
    case restrained

    public var ordinal: Int {
        switch self {
        case .clear: 1
        case .brisk: 2
        case .restrained: 3
        }
    }
}

public struct AICueSoundPlan: Sendable, Equatable {
    public let suggestedDisplayName: String
    public let modality: AICueModality
    public let soundDescription: String
    public let spokenContent: String?
    public let languageTag: String?
    public let styleDescription: String
    public let targetDurationMilliseconds: Int
    public let instructionVersion: String

    public init(
        suggestedDisplayName: String,
        modality: AICueModality,
        soundDescription: String,
        spokenContent: String?,
        languageTag: String?,
        styleDescription: String,
        targetDurationMilliseconds: Int,
        instructionVersion: String
    ) {
        self.suggestedDisplayName = suggestedDisplayName
        self.modality = modality
        self.soundDescription = soundDescription
        self.spokenContent = spokenContent
        self.languageTag = languageTag
        self.styleDescription = styleDescription
        self.targetDurationMilliseconds = targetDurationMilliseconds
        self.instructionVersion = instructionVersion
    }
}

/// A local, deterministic normalizer. It deliberately does not make a second model request:
/// interpretation cannot silently add cost, and Event/surface/pack context never enters it.
public struct AICueSoundPlanner: Sendable {
    public static let instructionVersion = "ai-cue-plan-v1"

    public init() {}

    public func makePlan(for request: AICueGenerationRequest) throws -> AICueSoundPlan {
        let description = request.description
        let spokenContent = quotedContent(in: description)
        let lowered = description.lowercased()
        let speechDetectionText = [
            "不要人声", "无人声", "不要语音", "no voice", "without voice", "without speech",
        ].reduce(lowered) { partial, marker in
            partial.replacingOccurrences(of: marker, with: "")
        }
        let speechIntent = spokenContent != nil || containsAny(speechDetectionText, speechMarkers)
        let animalIntent = containsAny(lowered, animalMarkers)
        let effectIntent = containsAny(lowered, effectMarkers)

        if speechIntent && spokenContent == nil {
            throw AICueValidationError.spokenContentRequiresQuotes
        }

        let modality: AICueModality
        if speechIntent && (animalIntent || effectIntent) {
            modality = .mixed
        } else if speechIntent {
            modality = .speech
        } else if animalIntent {
            modality = .animal
        } else {
            modality = .soundEffect
        }

        let duration: Int
        switch modality {
        case .speech: duration = 2_400
        case .animal: duration = 1_600
        case .soundEffect: duration = 1_500
        case .mixed: duration = 2_800
        }

        return AICueSoundPlan(
            suggestedDisplayName: suggestedName(
                description: description,
                spokenContent: spokenContent,
                modality: modality),
            modality: modality,
            soundDescription: description,
            spokenContent: spokenContent,
            languageTag: speechIntent ? request.locale : nil,
            styleDescription: description,
            targetDurationMilliseconds: min(
                duration,
                request.maximumDurationMilliseconds),
            instructionVersion: Self.instructionVersion)
    }

    private let speechMarkers = [
        "说“", "说\"", "说出", "朗读", "念出", "人声", "语音", "voice", "say ", "spoken",
        "speech",
    ]
    private let animalMarkers = [
        "小猫", "猫叫", "猫咪", "小狗", "狗叫", "犬吠", "鸟叫", "鸟鸣", "动物", "meow", "bark",
        "chirp", "roar",
    ]
    private let effectMarkers = [
        "音效", "木琴", "铃", "钟", "碰撞", "敲", "咔", "滴", "嗒", "响一声", "先响", "chime",
        "click", "impact", "sound effect", "whoosh",
    ]

    private func containsAny(_ value: String, _ markers: [String]) -> Bool {
        markers.contains(where: value.contains)
    }

    private func quotedContent(in description: String) -> String? {
        let pairs: [(Character, Character)] = [("“", "”"), ("「", "」"), ("『", "』"), ("\"", "\"")]
        for (opening, closing) in pairs {
            guard let openingIndex = description.firstIndex(of: opening) else { continue }
            let contentStart = description.index(after: openingIndex)
            guard
                let closingIndex = description[contentStart...].firstIndex(of: closing),
                closingIndex > contentStart
            else { continue }
            let content = description[contentStart..<closingIndex]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !content.isEmpty { return content }
        }
        return nil
    }

    private func suggestedName(
        description: String,
        spokenContent: String?,
        modality: AICueModality
    ) -> String {
        if let spokenContent {
            return limitedName(spokenContent)
        }
        let firstClause = description.split(whereSeparator: { "，,。；;\n".contains($0) }).first
            .map { String($0) } ?? description
        let cleaned = firstClause
            .replacingOccurrences(of: "不要背景音乐", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleaned.isEmpty { return limitedName(cleaned) }
        switch modality {
        case .speech: return "语音提示"
        case .animal: return "动物提示"
        case .soundEffect: return "提示音效"
        case .mixed: return "混合提示"
        }
    }

    private func limitedName(_ value: String) -> String {
        let limit = min(16, AICueDisplayName.maximumCharacters)
        return String(value.prefix(limit))
    }
}

public enum ElevenLabsAICueRoute: String, Sendable, Equatable {
    case textToSpeech
    case soundGeneration
}

public struct ElevenLabsAICueCompiledRequest: Sendable, Equatable {
    public let route: ElevenLabsAICueRoute
    public let modelID: String
    public let voiceID: String?
    public let prompt: String
    public let targetDurationMilliseconds: Int
    public let promptInfluence: Double?
    public let variant: AICueVariant
}

public struct ElevenLabsAICueRequestCompiler: Sendable {
    public static let speechModelID = "eleven_v3"
    public static let soundEffectModelID = "eleven_text_to_sound_v2"
    public static let speechVoiceID = "JBFqnCBsd6RMkjVDRZzb"

    public init() {}

    public func compile(
        plan: AICueSoundPlan,
        variant: AICueVariant
    ) -> ElevenLabsAICueCompiledRequest {
        switch plan.modality {
        case .speech:
            return speechRequest(plan: plan, variant: variant, includesEffect: false)
        case .mixed:
            return speechRequest(plan: plan, variant: variant, includesEffect: true)
        case .animal, .soundEffect:
            return soundEffectRequest(plan: plan, variant: variant)
        }
    }

    private func speechRequest(
        plan: AICueSoundPlan,
        variant: AICueVariant,
        includesEffect: Bool
    ) -> ElevenLabsAICueCompiledRequest {
        let speech = plan.spokenContent ?? ""
        let styleTag: String
        switch variant {
        case .clear: styleTag = "[clear]"
        case .brisk: styleTag = "[cheerful]"
        case .restrained: styleTag = "[calm]"
        }
        let effectTag = includesEffect ? "[sound effect: \(plan.soundDescription)] " : ""
        return ElevenLabsAICueCompiledRequest(
            route: .textToSpeech,
            modelID: Self.speechModelID,
            voiceID: Self.speechVoiceID,
            prompt: "\(effectTag)\(styleTag) \(speech)",
            targetDurationMilliseconds: plan.targetDurationMilliseconds,
            promptInfluence: nil,
            variant: variant)
    }

    private func soundEffectRequest(
        plan: AICueSoundPlan,
        variant: AICueVariant
    ) -> ElevenLabsAICueCompiledRequest {
        let variation: String
        let influence: Double
        switch variant {
        case .clear:
            variation = "主体清晰，干净，无背景音乐"
            influence = 0.8
        case .brisk:
            variation = "节奏稍轻快，起音明确，无背景音乐"
            influence = 0.65
        case .restrained:
            variation = "克制、柔和、短促，无背景音乐"
            influence = 0.9
        }
        return ElevenLabsAICueCompiledRequest(
            route: .soundGeneration,
            modelID: Self.soundEffectModelID,
            voiceID: nil,
            prompt: "\(plan.soundDescription)。\(variation)。总时长不超过 3 秒。",
            targetDurationMilliseconds: plan.targetDurationMilliseconds,
            promptInfluence: influence,
            variant: variant)
    }
}

public struct AICueAdoptionTarget: Sendable, Equatable, Hashable {
    public let surface: HostSurfaceID
    public let event: Event
    public let packID: String

    public init(surface: HostSurfaceID, event: Event, packID: String) throws {
        guard isSafePackID(packID) else { throw AICueValidationError.unsafePackID }
        self.surface = surface
        self.event = event
        self.packID = packID
    }
}
