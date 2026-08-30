import Foundation

public enum AICueGenerationDispatcherError: Error, Sendable, Equatable {
    case invalidProfileSet
}

/// Routes one explicit, allowlisted profile selection to its already-configured generation engine.
/// The dispatcher owns no Provider request details or credentials; it only preserves generation
/// ownership so later candidate cleanup returns to the engine that created the private files.
public actor AICueGenerationDispatcher: AICueGenerating {
    private let generators: [AICueProviderProfileID: any AICueGenerating]
    private var generationOwners: [UUID: AICueProviderProfileID] = [:]

    public init(
        generators: [AICueProviderProfileID: any AICueGenerating],
        registry: AICueProviderRegistry = AICueProviderRegistry()
    ) throws {
        guard Set(generators.keys) == Set(registry.profiles().map(\.id)) else {
            throw AICueGenerationDispatcherError.invalidProfileSet
        }
        self.generators = generators
    }

    public func generate(
        description: String,
        locale: String,
        providerProfileID: AICueProviderProfileID,
        deadline: AICueGenerationDeadline
    ) async throws -> AICueGeneration {
        guard let generator = generators[providerProfileID] else {
            throw AICueGenerationError.providerUnavailable
        }
        let generation = try await generator.generate(
            description: description,
            locale: locale,
            providerProfileID: providerProfileID,
            deadline: deadline)
        guard generation.profileID == providerProfileID else {
            await generator.discard(generationID: generation.id)
            throw AICueGenerationError.providerUnavailable
        }
        generationOwners[generation.id] = providerProfileID
        return generation
    }

    public func discard(generationID: UUID) async {
        guard
            let profileID = generationOwners.removeValue(forKey: generationID),
            let generator = generators[profileID]
        else { return }
        await generator.discard(generationID: generationID)
    }

    public func discardAll() async {
        generationOwners.removeAll()
        for generator in generators.values {
            await generator.discardAll()
        }
    }
}
