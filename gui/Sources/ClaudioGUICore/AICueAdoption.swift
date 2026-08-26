import ClaudioCore
import Foundation

public enum AICuePackConsumer: Sendable, Equatable, Hashable {
    case global
    case surface(HostSurfaceID)
}

public enum AICueAdoptionIneligibility: Error, Sendable, Equatable {
    case surfaceRequired
    case invalidSurface(HostSurfaceID)
    case writesStopped
    case noSelectedPack
    case unsafePackID
    case packUnavailable(packID: String)
    case packBroken(packID: String)
    case builtinReadOnly(packID: String)
    case configurationUnavailable
    case targetChanged
    case targetUsesDifferentPack(expected: String, actual: String)
    case sharedPack(consumers: [AICuePackConsumer])
}

public enum AICueAdoptionEligibility: Sendable, Equatable {
    case eligible(AICueAdoptionTarget)
    case ineligible(AICueAdoptionIneligibility)
}

/// Pure fail-closed proof that a pack-wide manifest mutation affects only the requested surface.
public func aiCueAdoptionEligibility(
    surface: HostSurfaceID?,
    event: Event,
    selectedPackID: String?,
    config: ClaudioConfig,
    packCards: [PackCard],
    builtinPackIDs: Set<String>
) -> AICueAdoptionEligibility {
    guard let surface else { return .ineligible(.surfaceRequired) }
    guard HostID.productVisibleCases.contains(where: { $0.surfaceID == surface }) else {
        return .ineligible(.invalidSurface(surface))
    }
    guard let packID = selectedPackID else { return .ineligible(.noSelectedPack) }
    guard isSafePackID(packID) else { return .ineligible(.unsafePackID) }
    guard
        let card = packCards.first(where: { $0.id == packID }),
        card.availability == .installed
    else {
        return .ineligible(.packUnavailable(packID: packID))
    }
    if case .broken = card.state { return .ineligible(.packBroken(packID: packID)) }
    guard !builtinPackIDs.contains(packID) else {
        return .ineligible(.builtinReadOnly(packID: packID))
    }

    let targetProfile: ResolvedSoundProfile
    switch config.resolveSoundProfile(for: surface) {
    case .success(let profile): targetProfile = profile
    case .failure: return .ineligible(.configurationUnavailable)
    }
    guard targetProfile.selectedPack == packID else {
        return .ineligible(
            .targetUsesDifferentPack(
                expected: packID,
                actual: targetProfile.selectedPack))
    }

    var consumers: [AICuePackConsumer] = []
    switch config.resolveSoundProfile(for: nil) {
    case .success(let profile):
        if profile.selectedPack == packID { consumers.append(.global) }
    case .failure:
        return .ineligible(.configurationUnavailable)
    }
    for host in HostID.productVisibleCases {
        let candidateSurface = host.surfaceID
        switch config.resolveSoundProfile(for: candidateSurface) {
        case .success(let profile):
            if candidateSurface != surface, profile.selectedPack == packID {
                consumers.append(.surface(candidateSurface))
            }
        case .failure:
            return .ineligible(.configurationUnavailable)
        }
    }
    guard consumers.isEmpty else {
        return .ineligible(.sharedPack(consumers: consumers))
    }

    guard let target = try? AICueAdoptionTarget(surface: surface, event: event, packID: packID)
    else { return .ineligible(.unsafePackID) }
    return .eligible(target)
}

public struct AICueAdoptionOutcome: Sendable, Equatable {
    public let target: AICueAdoptionTarget
    public let importedFile: ImportedAudioFile
    public let finalDisplayName: String

    public init(
        target: AICueAdoptionTarget,
        importedFile: ImportedAudioFile,
        finalDisplayName: String
    ) {
        self.target = target
        self.importedFile = importedFile
        self.finalDisplayName = finalDisplayName
    }
}

public enum AICuePostImportFailure: Sendable, Equatable {
    case ineligible(AICueAdoptionIneligibility)
    case manifest(ManifestBindError)
}

public enum AICueAdoptionError: Error, Sendable, Equatable {
    case ineligible(AICueAdoptionIneligibility)
    case importRejected(DropRejectionReason)
    case importUnavailable(SoundPacksWindowAudioActionError)
    case importedButNotBound(imported: ImportedAudioFile, reason: AICuePostImportFailure)
}
