import Foundation

public enum AICueProviderPreferenceError: Error, Sendable, Equatable {
    case unknownProfile
}

/// Persists only one allowlisted, non-sensitive profile identity. Region is always re-derived from
/// the registry profile, so a stored preference cannot create a free-form endpoint or region.
public struct AICueProviderPreferences {
    public static let defaultsKey = "Claudio.AICue.SelectedProviderProfile"

    private let defaults: UserDefaults
    private let registry: AICueProviderRegistry

    public init(
        defaults: UserDefaults = .standard,
        registry: AICueProviderRegistry = AICueProviderRegistry()
    ) {
        self.defaults = defaults
        self.registry = registry
    }

    public func selectedProfileID() -> AICueProviderProfileID {
        guard
            let rawValue = defaults.string(forKey: Self.defaultsKey),
            let profile = try? registry.profile(
                for: AICueProviderProfileID(rawValue: rawValue))
        else { return .elevenLabsGlobal }
        return profile.id
    }

    public func select(_ profileID: AICueProviderProfileID) throws {
        guard (try? registry.profile(for: profileID)) != nil else {
            throw AICueProviderPreferenceError.unknownProfile
        }
        defaults.set(profileID.rawValue, forKey: Self.defaultsKey)
    }
}
