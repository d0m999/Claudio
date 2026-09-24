import ClaudioCore
import Foundation

/// The language used only when allocating the initial display name for an unpublished cue-pack
/// draft. The draft name is user metadata; it is never used as a filesystem identity.
public enum AICuePackDraftLanguage: Sendable, Equatable, Hashable {
    case zhHans
    case english
}

public enum AICuePackNameValidationError: Error, Sendable, Equatable {
    case empty
    case tooLong(maximumCharacters: Int)
    case containsControlCharacters
}

/// A user-visible cue-pack name. It is intentionally separate from `AICueDisplayName`: pack
/// names have a 64-character contract while individual event labels keep their existing limit.
public struct AICuePackName: Hashable, Sendable {
    public static let maximumCharacters = 64
    public let value: String

    public init(_ value: String) throws {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw AICuePackNameValidationError.empty }
        guard normalized.count <= Self.maximumCharacters else {
            throw AICuePackNameValidationError.tooLong(
                maximumCharacters: Self.maximumCharacters)
        }
        guard
            normalized.unicodeScalars.allSatisfy({
                !CharacterSet.controlCharacters.contains($0)
                    && !CharacterSet.newlines.contains($0)
            })
        else {
            throw AICuePackNameValidationError.containsControlCharacters
        }
        self.value = normalized
    }
}

public func nextAICuePackDraftName(
    existingNames: some Sequence<String>,
    language: AICuePackDraftLanguage
) -> AICuePackName {
    let prefix = language == .english ? "My Cue Pack" : "我的提示音组"
    let occupied = Set(
        existingNames.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
                .folding(options: [.caseInsensitive, .widthInsensitive], locale: .current)
        })
    var ordinal = 1
    while true {
        let candidate = "\(prefix) \(ordinal)"
        let key = candidate.folding(
            options: [.caseInsensitive, .widthInsensitive], locale: .current)
        if !occupied.contains(key) {
            return try! AICuePackName(candidate)
        }
        ordinal += 1
    }
}

/// One effective consumer of a package. `inherited` is retained separately from the consumer
/// identity so the Sounds page can explain why a package is shared without mutating either the
/// Global defaults or a Surface override while the user is only inspecting it.
public struct AICuePackUsageConsumer: Sendable, Equatable, Hashable {
    public let consumer: AICuePackConsumer
    public let inherited: Bool
    public let workspaceName: String?

    public init(consumer: AICuePackConsumer, inherited: Bool = false, workspaceName: String? = nil)
    {
        self.consumer = consumer
        self.inherited = inherited
        self.workspaceName = workspaceName
    }
}

public struct AICuePackUsage: Sendable, Equatable {
    public let packID: String
    public let consumers: [AICuePackUsageConsumer]
    /// `true` means at least one scope could not be classified. It is deliberately independent
    /// from adoption eligibility: a healthy user package can still be edited when config is
    /// damaged, while the usage warning remains honest.
    public let usageIsIncomplete: Bool

    public var effectiveConsumers: [AICuePackConsumer] { consumers.map(\.consumer) }
    public var isShared: Bool { consumers.count > 1 }

    public init(
        packID: String,
        consumers: [AICuePackUsageConsumer],
        usageIsIncomplete: Bool
    ) {
        self.packID = packID
        self.consumers = consumers
        self.usageIsIncomplete = usageIsIncomplete
    }
}

/// Calculates effective package consumers from one config projection. It never treats a damaged
/// Surface override as inherited Global state; it records the uncertainty instead.
public func aiCuePackUsage(
    packID: String,
    config: ClaudioConfig
) -> AICuePackUsage {
    var consumers: [AICuePackUsageConsumer] = []
    var incomplete = !isSafePackID(packID)

    if config.selectedPack == packID {
        consumers.append(AICuePackUsageConsumer(consumer: .global))
    }

    incomplete = incomplete || config.workspaceRulesMalformed
    for rule in config.workspaceRules {
        guard let profile = rule.profile else { incomplete = true; continue }
        if profile.selectedPack == packID {
            consumers.append(
                AICuePackUsageConsumer(consumer: .workspace(rule.id), workspaceName: rule.name))
        }
    }

    return AICuePackUsage(
        packID: packID,
        consumers: consumers,
        usageIsIncomplete: incomplete)
}

/// ADR 0016's package-level eligibility. Configuration is intentionally not an input: adopting a
/// cue changes only the healthy user-pack manifest, while Global/Surface application remains a
/// separate, explicit operation and can fail closed independently.
public func aiCuePackAdoptionEligibility(
    packID: String,
    event: Event,
    packCards: [PackCard],
    builtinPackIDs: Set<String>
) -> AICueAdoptionEligibility {
    guard isSafePackID(packID) else { return .ineligible(.unsafePackID) }
    guard
        let card = packCards.first(where: { $0.id == packID }),
        card.availability == .installed
    else {
        return .ineligible(.packUnavailable(packID: packID))
    }
    if case .broken = card.state {
        return .ineligible(.packBroken(packID: packID))
    }
    guard !builtinPackIDs.contains(packID) else {
        return .ineligible(.builtinReadOnly(packID: packID))
    }
    guard let target = try? AICueAdoptionTarget(packID: packID, event: event) else {
        return .ineligible(.unsafePackID)
    }
    return .eligible(target)
}

/// Long-form alias used by callers whose surrounding code says “package” rather than “pack”.
public func aiCuePackageAdoptionEligibility(
    packID: String,
    event: Event,
    packCards: [PackCard],
    builtinPackIDs: Set<String>
) -> AICueAdoptionEligibility {
    aiCuePackAdoptionEligibility(
        packID: packID,
        event: event,
        packCards: packCards,
        builtinPackIDs: builtinPackIDs)
}

/// An unpublished pack draft. Its safe temporary ID is allocated before generation so permits
/// can bind to a stable identity, but the directory is not created until first adoption.
public struct AICuePackDraft: Sendable, Equatable, Hashable {
    public let packID: String
    public let name: AICuePackName

    public init(packID: String, name: AICuePackName) throws {
        guard isSafePackID(packID) else { throw AICueValidationError.unsafePackID }
        self.packID = packID
        self.name = name
    }

    public static func make(
        existingNames: some Sequence<String>,
        language: AICuePackDraftLanguage
    ) -> AICuePackDraft {
        let name = nextAICuePackDraftName(existingNames: existingNames, language: language)
        return try! AICuePackDraft(
            packID: "ai-cue-\(UUID().uuidString.lowercased())",
            name: name)
    }
}
