import ClaudioCore
import Foundation

public enum AICueValidationError: Error, Sendable, Equatable {
    case emptyDescription
    case descriptionTooLong(maximumCharacters: Int)
    case invalidLocale
    case emptyDisplayName
    case displayNameTooLong(maximumCharacters: Int)
    case displayNameContainsControlCharacters
    case spokenContentRequired(example: String)
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
    public let providerProfileID: AICueProviderProfileID

    public init(
        description: String,
        locale: String,
        providerProfileID: AICueProviderProfileID
    ) throws {
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
        self.providerProfileID = providerProfileID
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
    public static let spokenContentExample = "清晰地说“任务完成”"

    public init() {}

    public func makePlan(for request: AICueGenerationRequest) throws -> AICueSoundPlan {
        let description = request.description
        let quotation = quotedContent(in: description)
        let spokenContent = quotation.content
        let lowered = description.lowercased()
        let speechDetectionText = speechNegationMarkers.reduce(lowered) { partial, marker in
            partial.replacingOccurrences(of: marker, with: "")
        }
        let speechIntent =
            quotation.wasPresent || containsAny(speechDetectionText, speechMarkers)
        let animalIntent = containsAny(lowered, animalMarkers)
        let effectIntent = containsAny(lowered, effectMarkers)

        if speechIntent && spokenContent == nil {
            throw AICueValidationError.spokenContentRequired(
                example: Self.spokenContentExample)
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
            styleDescription: styleDescription(
                in: description,
                excluding: quotation.range),
            targetDurationMilliseconds: min(
                duration,
                request.maximumDurationMilliseconds),
            instructionVersion: Self.instructionVersion)
    }

    private let speechMarkers = [
        "说", "朗读", "念出", "人声", "语音", "voice", "say ", "spoken", "speech",
    ]
    private let speechNegationMarkers = [
        "不要人声", "无人声", "不要语音", "不要说话", "不说话", "没有说话", "无需说话",
        "no voice", "without voice", "without speech",
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

    private func quotedContent(
        in description: String
    ) -> (content: String?, range: Range<String.Index>?, wasPresent: Bool) {
        let pairs: [(Character, Character)] = [
            ("“", "”"), ("‘", "’"), ("「", "」"), ("『", "』"), ("\"", "\""),
        ]
        var sawOpening = false
        for (opening, closing) in pairs {
            guard let openingIndex = description.firstIndex(of: opening) else { continue }
            sawOpening = true
            let contentStart = description.index(after: openingIndex)
            guard
                let closingIndex = description[contentStart...].firstIndex(of: closing),
                closingIndex > contentStart
            else { continue }
            let content = description[contentStart..<closingIndex]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !content.isEmpty {
                return (
                    content,
                    openingIndex..<description.index(after: closingIndex),
                    true
                )
            }
        }
        return (nil, nil, sawOpening)
    }

    private func styleDescription(
        in description: String,
        excluding spokenQuotationRange: Range<String.Index>?
    ) -> String {
        guard let spokenQuotationRange else { return description }
        var style = description
        style.removeSubrange(spokenQuotationRange)
        return
            style
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
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
