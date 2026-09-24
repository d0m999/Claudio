import ClaudioCore
import Foundation

public enum AICuePackConsumer: Sendable, Equatable, Hashable {
    case global
    case workspace(UUID)
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
    // Surface-scoped generation/adoption is retired. Pack-scoped editing owns this operation.
    .ineligible(.writesStopped)

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
