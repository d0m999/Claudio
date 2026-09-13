import Foundation

package enum AICueRuntimeError: Error, Sendable, Equatable {
    case invalidProviderBindings
}

/// The package-owned assembly seam for one AI Cue runtime. It owns no alternate provider state:
/// the registry supplies the complete profile set, every profile gets one generation engine, and
/// only profiles whose registry policy requires a read-only probe enter the validator set.
/// Construction only connects values; Keychain, network, duration and preferences I/O remain
/// deferred until an explicit operation calls the corresponding boundary.
package struct AICueRuntime {
    package let registry: AICueProviderRegistry
    package let credentialManager: AICueCredentialManager
    package let dispatcher: AICueGenerationDispatcher
    package let providerPreferences: AICueProviderPreferences

    /// Immutable projections of the two deliberately different compiled binding sets. They make
    /// the production factory contract directly testable without exposing provider instances.
    package let generatorProfileIDs: Set<AICueProviderProfileID>
    package let validatorProfileIDs: Set<AICueProviderProfileID>

    package init(
        registry: AICueProviderRegistry = AICueProviderRegistry(),
        vault: any AICueCredentialVault,
        temporaryRoot: URL,
        durationProbe: any AudioDurationProbing,
        unaryTransport: any AICueUnaryTransport = AICueURLSessionUnaryTransport(),
        sseTransport: any AICueSSETransport = AICueURLSessionSSETransport(),
        assetFetcher: any AICueAssetFetching = AICueURLSessionAssetFetcher(),
        credentialMetadata: any AICueCredentialMetadataStoring =
            AICueUserDefaultsCredentialMetadataStore(),
        providerDefaults: UserDefaults = .standard
    ) throws {
        let providerBindings = try Self.makeProviderBindings(
            registry: registry,
            unaryTransport: unaryTransport,
            sseTransport: sseTransport,
            assetFetcher: assetFetcher)
        try self.init(
            registry: registry,
            vault: vault,
            temporaryRoot: temporaryRoot,
            durationProbe: durationProbe,
            providerBindings: providerBindings,
            credentialMetadata: credentialMetadata,
            providerDefaults: providerDefaults)
    }

    /// A compiled test seam for binding-integrity failures and dispatcher/engine lifecycle tests.
    /// Production always obtains this array from ``makeProviderBindings(registry:unaryTransport:sseTransport:assetFetcher:)``.
    package init(
        registry: AICueProviderRegistry,
        vault: any AICueCredentialVault,
        temporaryRoot: URL,
        durationProbe: any AudioDurationProbing,
        providerBindings: [any AICueCandidateSetProvider],
        credentialMetadata: any AICueCredentialMetadataStoring,
        providerDefaults: UserDefaults
    ) throws {
        let profiles = registry.profiles()
        let expectedByID = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })
        let expectedProfileIDs = Set(expectedByID.keys)
        let actualProfileIDs = Set(providerBindings.map(\.profile.id))
        guard
            providerBindings.count == profiles.count,
            actualProfileIDs.count == providerBindings.count,
            actualProfileIDs == expectedProfileIDs,
            providerBindings.allSatisfy({ expectedByID[$0.profile.id] == $0.profile })
        else {
            throw AICueRuntimeError.invalidProviderBindings
        }

        let expectedValidatorProfileIDs = Set(
            profiles.compactMap { profile in
                profile.credentialValidationPolicy == .readOnlyProbe ? profile.id : nil
            })
        var validators: [AICueProviderProfileID: any AICueCredentialValidating] = [:]
        for binding in providerBindings
        where expectedValidatorProfileIDs.contains(binding.profile.id) {
            validators[binding.profile.id] = binding
        }
        guard Set(validators.keys) == expectedValidatorProfileIDs else {
            throw AICueRuntimeError.invalidProviderBindings
        }

        let credentialManager = AICueCredentialManager(
            vault: vault,
            registry: registry,
            validators: validators,
            metadata: credentialMetadata)
        var generators: [AICueProviderProfileID: any AICueGenerating] = [:]
        for binding in providerBindings {
            generators[binding.profile.id] = AICueGenerationEngine(
                credentialManager: credentialManager,
                candidateSetProvider: binding,
                temporaryRoot: temporaryRoot,
                durationProbe: durationProbe,
                registry: registry)
        }
        guard Set(generators.keys) == expectedProfileIDs else {
            throw AICueRuntimeError.invalidProviderBindings
        }

        do {
            dispatcher = try AICueGenerationDispatcher(
                generators: generators,
                registry: registry)
        } catch {
            throw AICueRuntimeError.invalidProviderBindings
        }
        self.registry = registry
        self.credentialManager = credentialManager
        providerPreferences = AICueProviderPreferences(
            defaults: providerDefaults,
            registry: registry)
        generatorProfileIDs = Set(generators.keys)
        validatorProfileIDs = Set(validators.keys)
    }

    private static func makeProviderBindings(
        registry: AICueProviderRegistry,
        unaryTransport: any AICueUnaryTransport,
        sseTransport: any AICueSSETransport,
        assetFetcher: any AICueAssetFetching
    ) throws -> [any AICueCandidateSetProvider] {
        try registry.profiles().map { profile in
            switch profile.id {
            case .elevenLabsGlobal:
                return SequentialAICueCandidateSetAdapter(
                    provider: ElevenLabsAICueProvider(unaryTransport: unaryTransport),
                    registry: registry)
            case .miniMaxGlobal:
                return SequentialAICueCandidateSetAdapter(
                    provider: MiniMaxAICueProvider(unaryTransport: unaryTransport),
                    registry: registry)
            case .qwenSingapore, .qwenBeijing:
                return SequentialAICueCandidateSetAdapter(
                    provider: try QwenAICueProvider(
                        profileID: profile.id,
                        sseTransport: sseTransport),
                    registry: registry)
            case .senseAudioChina:
                return try SenseAudioAICueProvider(
                    registry: registry,
                    unaryTransport: unaryTransport,
                    assetFetcher: assetFetcher)
            default:
                throw AICueRuntimeError.invalidProviderBindings
            }
        }
    }
}
