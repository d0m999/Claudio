import Foundation
import Security

public enum AICueCredentialInputError: Error, Sendable, Equatable {
    case empty
    case tooLong(maximumBytes: Int)
    case containsControlCharacters
}

/// One-shot secret input. A reference type intentionally avoids Swift's synthesized field dump for
/// structs; it does not conform to Codable, Equatable, or either string-description protocol.
public final class SensitiveCredentialInput: @unchecked Sendable, CustomReflectable {
    private static let maximumBytes = 512
    private let utf8: Data

    public init(_ value: String) throws {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw AICueCredentialInputError.empty }
        guard
            normalized.unicodeScalars.allSatisfy({
                !CharacterSet.controlCharacters.contains($0)
                    && !CharacterSet.newlines.contains($0)
            })
        else {
            throw AICueCredentialInputError.containsControlCharacters
        }
        let data = Data(normalized.utf8)
        guard data.count <= Self.maximumBytes else {
            throw AICueCredentialInputError.tooLong(maximumBytes: Self.maximumBytes)
        }
        utf8 = data
    }

    fileprivate init(validatedUTF8: Data) {
        utf8 = validatedUTF8
    }

    public var customMirror: Mirror {
        Mirror(self, children: [:], displayStyle: .class)
    }

    func withUTF8String<T>(_ body: (String) throws -> T) rethrows -> T {
        // Initializers guarantee valid UTF-8; Keychain data is revalidated before this object exists.
        try body(String(decoding: utf8, as: UTF8.self))
    }

    fileprivate var keychainData: Data { utf8 }
}

public enum AICueCredentialVerification: String, Sendable, Equatable {
    case verified
    case deferred
    case rejected
}

public enum AICueCredentialStatus: Sendable, Equatable {
    case missing
    case stored(
        verification: AICueCredentialVerification,
        hasPendingReplacement: Bool
    )
    case unavailable
}

public enum AICueCredentialManagerError: Error, Sendable, Equatable {
    case unknownProfile
    case probeUnavailable
    case credentialRequired
    case credentialUnavailable
    case stateChanged
}

public protocol AICueCredentialVault: Sendable {
    func containsCredential(in slotID: AICueCredentialSlotID) async throws -> Bool
    func credential(in slotID: AICueCredentialSlotID) async throws -> SensitiveCredentialInput?
    func replaceCredential(
        _ credential: SensitiveCredentialInput,
        in slotID: AICueCredentialSlotID
    ) async throws
    func deleteCredential(in slotID: AICueCredentialSlotID) async throws
}

public protocol AICueCredentialValidating: Sendable {
    func validateCredential(_ credential: SensitiveCredentialInput) async throws
}

public protocol AICueCredentialManaging: Sendable {
    func status(for profileID: AICueProviderProfileID) async -> AICueCredentialStatus
    func save(
        _ credential: SensitiveCredentialInput,
        for profileID: AICueProviderProfileID
    ) async throws -> AICueCredentialStatus
    func delete(for profileID: AICueProviderProfileID) async throws
    func cancelPendingReplacement(for profileID: AICueProviderProfileID) async throws
}

package enum AICueGenerationCredentialSource: Sendable {
    case active
    case pending
}

/// A short-lived credential lease for one explicit generation. It has no public secret access and
/// reflects only its profile identity; generation requests, errors and persisted state cannot own it.
public final class AICueGenerationCredential: @unchecked Sendable, CustomReflectable {
    package let profileID: AICueProviderProfileID
    package let credential: SensitiveCredentialInput
    package let source: AICueGenerationCredentialSource
    package let revision: UInt64

    package init(
        profileID: AICueProviderProfileID,
        credential: SensitiveCredentialInput,
        source: AICueGenerationCredentialSource,
        revision: UInt64
    ) {
        self.profileID = profileID
        self.credential = credential
        self.source = source
        self.revision = revision
    }

    public var customMirror: Mirror {
        Mirror(
            self,
            children: ["profileID": profileID.rawValue],
            displayStyle: .class)
    }
}

public protocol AICueGenerationCredentialManaging: Sendable {
    func credentialForGeneration(
        for profileID: AICueProviderProfileID
    ) async throws -> AICueGenerationCredential
    func generationDidValidate(_ lease: AICueGenerationCredential) async throws
    func generation(
        _ lease: AICueGenerationCredential,
        didFailWith error: AICueProviderError
    ) async
}

package protocol AICueCredentialMetadataStoring: Sendable {
    func verification(
        for profileID: AICueProviderProfileID
    ) async -> AICueCredentialVerification?
    func setVerification(
        _ verification: AICueCredentialVerification?,
        for profileID: AICueProviderProfileID
    ) async
}

package actor AICueUserDefaultsCredentialMetadataStore: AICueCredentialMetadataStoring {
    private static let keyPrefix = "Claudio.AICue.CredentialVerification."
    private let defaults: UserDefaults

    package init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    package func verification(
        for profileID: AICueProviderProfileID
    ) -> AICueCredentialVerification? {
        defaults.string(forKey: Self.keyPrefix + profileID.rawValue).flatMap(
            AICueCredentialVerification.init(rawValue:))
    }

    package func setVerification(
        _ verification: AICueCredentialVerification?,
        for profileID: AICueProviderProfileID
    ) {
        let key = Self.keyPrefix + profileID.rawValue
        if let verification {
            defaults.set(verification.rawValue, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}

public actor AICueCredentialManager: AICueCredentialManaging,
    AICueGenerationCredentialManaging
{
    private let vault: any AICueCredentialVault
    private let registry: AICueProviderRegistry
    private let validators: [AICueProviderProfileID: any AICueCredentialValidating]
    private let metadata: any AICueCredentialMetadataStoring
    private var revisions: [AICueProviderProfileID: UInt64] = [:]
    private var mutatingProfiles: Set<AICueProviderProfileID> = []

    public init(
        vault: any AICueCredentialVault,
        registry: AICueProviderRegistry = AICueProviderRegistry(),
        validators: [AICueProviderProfileID: any AICueCredentialValidating]
    ) {
        self.vault = vault
        self.registry = registry
        self.validators = validators
        metadata = AICueUserDefaultsCredentialMetadataStore()
    }

    package init(
        vault: any AICueCredentialVault,
        registry: AICueProviderRegistry = AICueProviderRegistry(),
        validators: [AICueProviderProfileID: any AICueCredentialValidating],
        metadata: any AICueCredentialMetadataStoring
    ) {
        self.vault = vault
        self.registry = registry
        self.validators = validators
        self.metadata = metadata
    }

    public func status(for profileID: AICueProviderProfileID) async -> AICueCredentialStatus {
        guard let profile = try? registry.profile(for: profileID) else { return .unavailable }
        return await projectedStatus(for: profile, requiresStableSnapshot: true)
    }

    private func projectedStatus(
        for profile: AICueProviderProfile,
        requiresStableSnapshot: Bool
    ) async -> AICueCredentialStatus {
        let startingRevision = revision(for: profile.id)
        if requiresStableSnapshot, mutatingProfiles.contains(profile.id) { return .unavailable }
        do {
            let hasActive = try await vault.containsCredential(in: profile.credentialSlotID)
            let hasPending = try await containsPendingCredential(for: profile)
            let verification: AICueCredentialVerification?
            if hasActive {
                verification = await metadata.verification(for: profile.id) ?? .deferred
            } else {
                verification = nil
            }
            if requiresStableSnapshot,
                mutatingProfiles.contains(profile.id)
                    || revision(for: profile.id) != startingRevision
            {
                return .unavailable
            }
            guard hasActive else {
                // A pending item without its active predecessor is an invalid, fail-closed state.
                return hasPending ? .unavailable : .missing
            }
            return .stored(
                verification: verification ?? .deferred,
                hasPendingReplacement: hasPending)
        } catch {
            return .unavailable
        }
    }

    public func save(
        _ credential: SensitiveCredentialInput,
        for profileID: AICueProviderProfileID
    ) async throws -> AICueCredentialStatus {
        let profile = try resolveProfile(profileID)
        try beginMutation(for: profileID)
        defer { endMutation(for: profileID) }
        switch profile.credentialValidationPolicy {
        case .readOnlyProbe:
            guard let validator = validators[profileID] else {
                throw AICueCredentialManagerError.probeUnavailable
            }
            try await validator.validateCredential(credential)
            // Keychain update/insert is one atomic active-slot mutation. A failed probe or write
            // never deletes the old active item first.
            try await vault.replaceCredential(credential, in: profile.credentialSlotID)
            await metadata.setVerification(.verified, for: profileID)

        case .deferredUntilExplicitGeneration:
            let hasActive = try await vault.containsCredential(in: profile.credentialSlotID)
            if hasActive {
                guard let pendingSlotID = profile.pendingCredentialSlotID else {
                    throw AICueCredentialManagerError.credentialUnavailable
                }
                try await vault.replaceCredential(credential, in: pendingSlotID)
            } else {
                guard try await containsPendingCredential(for: profile) == false else {
                    throw AICueCredentialManagerError.credentialUnavailable
                }
                try await vault.replaceCredential(credential, in: profile.credentialSlotID)
                await metadata.setVerification(.deferred, for: profileID)
            }
        }
        return await projectedStatus(for: profile, requiresStableSnapshot: false)
    }

    public func delete(for profileID: AICueProviderProfileID) async throws {
        let profile = try resolveProfile(profileID)
        try beginMutation(for: profileID)
        defer { endMutation(for: profileID) }
        // Delete pending first so a failure cannot remove the still-working active item.
        if let pendingSlotID = profile.pendingCredentialSlotID {
            try await vault.deleteCredential(in: pendingSlotID)
        }
        try await vault.deleteCredential(in: profile.credentialSlotID)
        await metadata.setVerification(nil, for: profileID)
    }

    public func cancelPendingReplacement(
        for profileID: AICueProviderProfileID
    ) async throws {
        let profile = try resolveProfile(profileID)
        guard let pendingSlotID = profile.pendingCredentialSlotID else { return }
        try beginMutation(for: profileID)
        defer { endMutation(for: profileID) }
        try await vault.deleteCredential(in: pendingSlotID)
    }

    public func credentialForGeneration(
        for profileID: AICueProviderProfileID
    ) async throws -> AICueGenerationCredential {
        let profile = try resolveProfile(profileID)
        let startingRevision = revision(for: profileID)
        guard !mutatingProfiles.contains(profileID) else {
            throw AICueCredentialManagerError.stateChanged
        }
        do {
            if let pendingSlotID = profile.pendingCredentialSlotID,
                let pending = try await vault.credential(in: pendingSlotID)
            {
                try requireUnchangedProfile(profileID, since: startingRevision)
                return AICueGenerationCredential(
                    profileID: profileID,
                    credential: pending,
                    source: .pending,
                    revision: revision(for: profileID))
            }
            let active = try await vault.credential(in: profile.credentialSlotID)
            try requireUnchangedProfile(profileID, since: startingRevision)
            guard let active else {
                throw AICueCredentialManagerError.credentialRequired
            }
            return AICueGenerationCredential(
                profileID: profileID,
                credential: active,
                source: .active,
                revision: revision(for: profileID))
        } catch let error as AICueCredentialManagerError {
            throw error
        } catch {
            throw AICueCredentialManagerError.credentialUnavailable
        }
    }

    public func generationDidValidate(_ lease: AICueGenerationCredential) async throws {
        let profile = try resolveProfile(lease.profileID)
        guard lease.revision == revision(for: lease.profileID) else {
            throw AICueCredentialManagerError.stateChanged
        }
        try beginMutation(for: lease.profileID)
        defer { endMutation(for: lease.profileID) }
        switch lease.source {
        case .active:
            await metadata.setVerification(.verified, for: lease.profileID)
        case .pending:
            guard let pendingSlotID = profile.pendingCredentialSlotID else {
                throw AICueCredentialManagerError.credentialUnavailable
            }
            // Replace active before deleting pending. If replacement fails, the old active and the
            // retryable pending item both remain available.
            try await vault.replaceCredential(lease.credential, in: profile.credentialSlotID)
            try await vault.deleteCredential(in: pendingSlotID)
            await metadata.setVerification(.verified, for: lease.profileID)
        }
    }

    public func generation(
        _ lease: AICueGenerationCredential,
        didFailWith error: AICueProviderError
    ) async {
        guard
            error == .invalidCredential,
            lease.revision == revision(for: lease.profileID),
            let profile = try? registry.profile(for: lease.profileID)
        else { return }
        do {
            try beginMutation(for: lease.profileID)
        } catch {
            return
        }
        defer { endMutation(for: lease.profileID) }

        switch lease.source {
        case .active:
            await metadata.setVerification(.rejected, for: lease.profileID)
        case .pending:
            guard let pendingSlotID = profile.pendingCredentialSlotID else { return }
            // A clear 401 rejects only the attempted replacement; the old active remains valid.
            do {
                try await vault.deleteCredential(in: pendingSlotID)
            } catch {
                // A Keychain failure must leave the pending fact visible for an explicit retry.
            }
        }
    }

    private func resolveProfile(
        _ profileID: AICueProviderProfileID
    ) throws -> AICueProviderProfile {
        do {
            return try registry.profile(for: profileID)
        } catch {
            throw AICueCredentialManagerError.unknownProfile
        }
    }

    private func containsPendingCredential(
        for profile: AICueProviderProfile
    ) async throws -> Bool {
        guard let pendingSlotID = profile.pendingCredentialSlotID else { return false }
        return try await vault.containsCredential(in: pendingSlotID)
    }

    private func revision(for profileID: AICueProviderProfileID) -> UInt64 {
        revisions[profileID, default: 0]
    }

    private func advanceRevision(for profileID: AICueProviderProfileID) {
        revisions[profileID, default: 0] &+= 1
    }

    private func requireUnchangedProfile(
        _ profileID: AICueProviderProfileID,
        since revision: UInt64
    ) throws {
        guard
            !mutatingProfiles.contains(profileID),
            self.revision(for: profileID) == revision
        else {
            throw AICueCredentialManagerError.stateChanged
        }
    }

    private func beginMutation(for profileID: AICueProviderProfileID) throws {
        guard mutatingProfiles.insert(profileID).inserted else {
            throw AICueCredentialManagerError.stateChanged
        }
    }

    private func endMutation(for profileID: AICueProviderProfileID) {
        mutatingProfiles.remove(profileID)
        advanceRevision(for: profileID)
    }
}

public enum AICueKeychainError: Error, Sendable, Equatable {
    case invalidStoredCredential
    case unexpectedStatus(operation: String, status: OSStatus)
}

/// Production Keychain adapter. The item is local-device-only and available only while unlocked;
/// no key material is copied into config, defaults, logs, manifests, or error descriptions.
public actor AICueKeychainCredentialVault: AICueCredentialVault {
    private let service: String

    public init() {
        service = "com.claudio.ai-cue.byok"
    }

    init(service: String) {
        self.service = service
    }

    public func containsCredential(in slotID: AICueCredentialSlotID) async throws -> Bool {
        var query = baseQuery(for: slotID)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        switch status {
        case errSecSuccess: return true
        case errSecItemNotFound: return false
        default:
            throw AICueKeychainError.unexpectedStatus(
                operation: "lookup",
                status: status)
        }
    }

    public func credential(
        in slotID: AICueCredentialSlotID
    ) async throws -> SensitiveCredentialInput? {
        var query = baseQuery(for: slotID)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw AICueKeychainError.unexpectedStatus(operation: "read", status: status)
        }
        guard
            let data = value as? Data,
            !data.isEmpty,
            data.count <= 512,
            let value = String(data: data, encoding: .utf8),
            let credential = try? SensitiveCredentialInput(value)
        else {
            throw AICueKeychainError.invalidStoredCredential
        }
        return credential
    }

    public func replaceCredential(
        _ credential: SensitiveCredentialInput,
        in slotID: AICueCredentialSlotID
    ) async throws {
        let query = baseQuery(for: slotID)
        let attributes: [String: Any] = [kSecValueData as String: credential.keychainData]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw AICueKeychainError.unexpectedStatus(
                operation: "replace",
                status: updateStatus)
        }

        var item = query
        item[kSecValueData as String] = credential.keychainData
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        item[kSecAttrSynchronizable as String] = false
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw AICueKeychainError.unexpectedStatus(operation: "insert", status: addStatus)
        }
    }

    public func deleteCredential(in slotID: AICueCredentialSlotID) async throws {
        let status = SecItemDelete(baseQuery(for: slotID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AICueKeychainError.unexpectedStatus(operation: "delete", status: status)
        }
    }

    private func baseQuery(for slotID: AICueCredentialSlotID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: slotID.rawValue,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }
}
