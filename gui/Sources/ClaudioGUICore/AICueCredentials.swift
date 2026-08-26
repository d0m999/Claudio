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

public enum AICueCredentialStatus: Sendable, Equatable {
    case missing
    case configured(providerID: AICueProviderID)
    case unavailable
}

public protocol AICueCredentialVault: Sendable {
    func containsCredential(for providerID: AICueProviderID) async throws -> Bool
    func credential(for providerID: AICueProviderID) async throws -> SensitiveCredentialInput?
    func replaceCredential(
        _ credential: SensitiveCredentialInput,
        for providerID: AICueProviderID
    ) async throws
    func deleteCredential(for providerID: AICueProviderID) async throws
}

public protocol AICueCredentialValidating: Sendable {
    func validateCredential(_ credential: SensitiveCredentialInput) async throws
}

public protocol AICueCredentialManaging: Sendable {
    func status(for providerID: AICueProviderID) async -> AICueCredentialStatus
    func validateAndSave(
        _ credential: SensitiveCredentialInput,
        for providerID: AICueProviderID
    ) async throws
    func delete(for providerID: AICueProviderID) async throws
}

public actor AICueCredentialManager: AICueCredentialManaging {
    private let vault: any AICueCredentialVault
    private let validator: any AICueCredentialValidating

    public init(
        vault: any AICueCredentialVault,
        validator: any AICueCredentialValidating
    ) {
        self.vault = vault
        self.validator = validator
    }

    public func status(for providerID: AICueProviderID) async -> AICueCredentialStatus {
        do {
            return try await vault.containsCredential(for: providerID)
                ? .configured(providerID: providerID)
                : .missing
        } catch {
            return .unavailable
        }
    }

    /// Validation happens before the vault mutation. The vault contract's replace operation must be
    /// atomic, so neither provider rejection nor a Keychain failure destroys a working old key.
    public func validateAndSave(
        _ credential: SensitiveCredentialInput,
        for providerID: AICueProviderID
    ) async throws {
        try await validator.validateCredential(credential)
        try await vault.replaceCredential(credential, for: providerID)
    }

    public func delete(for providerID: AICueProviderID) async throws {
        try await vault.deleteCredential(for: providerID)
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

    public func containsCredential(for providerID: AICueProviderID) async throws -> Bool {
        var query = baseQuery(for: providerID)
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
        for providerID: AICueProviderID
    ) async throws -> SensitiveCredentialInput? {
        var query = baseQuery(for: providerID)
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
        for providerID: AICueProviderID
    ) async throws {
        let query = baseQuery(for: providerID)
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

    public func deleteCredential(for providerID: AICueProviderID) async throws {
        let status = SecItemDelete(baseQuery(for: providerID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AICueKeychainError.unexpectedStatus(operation: "delete", status: status)
        }
    }

    private func baseQuery(for providerID: AICueProviderID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: providerID.rawValue,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }
}
