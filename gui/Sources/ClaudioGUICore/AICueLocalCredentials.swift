import ClaudioLocalization
import Darwin
import Foundation

/// One explicit storage choice, not a fallback after a Keychain failure. Existing providers keep
/// their original slots; SenseAudio never reads, migrates, writes or deletes a Keychain item.
package struct AICueAppCredentialVault: AICueCredentialVault {
    private let keychain: any AICueCredentialVault
    private let senseAudio: any AICueCredentialVault

    package init(
        keychain: any AICueCredentialVault = AICueKeychainCredentialVault(),
        senseAudio: any AICueCredentialVault = SenseAudioFileCredentialVault()
    ) {
        self.keychain = keychain
        self.senseAudio = senseAudio
    }

    package func containsCredential(in slotID: AICueCredentialSlotID) async throws -> Bool {
        try await storage(for: slotID).containsCredential(in: slotID)
    }

    package func credential(in slotID: AICueCredentialSlotID) async throws
        -> SensitiveCredentialInput?
    {
        try await storage(for: slotID).credential(in: slotID)
    }

    package func replaceCredential(
        _ credential: SensitiveCredentialInput, in slotID: AICueCredentialSlotID
    ) async throws {
        try await storage(for: slotID).replaceCredential(credential, in: slotID)
    }

    package func deleteCredential(in slotID: AICueCredentialSlotID) async throws {
        try await storage(for: slotID).deleteCredential(in: slotID)
    }

    private func storage(for slotID: AICueCredentialSlotID) -> any AICueCredentialVault {
        slotID == .senseAudioChina ? senseAudio : keychain
    }
}

extension AICueProviderProfile {
    public var credentialStorageDisclosureKey: ClaudioL10nKey {
        id == .senseAudioChina ? .aiCueCredentialLocalFile : .aiCueCredentialKeychain
    }
}

/// Intentionally contains neither paths nor underlying error descriptions nor credential bytes.
package enum AICueLocalCredentialError: Error, Sendable, Equatable {
    case unavailable
}

/// The filesystem ACL boundary. Tests can model query faults without touching user credentials.
package protocol AICueLocalCredentialACLReading: Sendable {
    func hasEntries(on descriptor: Int32) throws -> Bool
}

package struct AICueLocalCredentialSystemACLReader: AICueLocalCredentialACLReading {
    package init() {}

    package func hasEntries(on descriptor: Int32) throws -> Bool {
        // Darwin reports ENOENT when this already-open object has no extended ACL.
        guard let acl = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else {
            guard errno == ENOENT else { throw AICueLocalCredentialError.unavailable }
            return false
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        guard acl_valid(acl) == 0 else { throw AICueLocalCredentialError.unavailable }
        var entry: acl_entry_t?
        errno = 0
        let result = acl_get_entry(acl, Int32(ACL_FIRST_ENTRY.rawValue), &entry)
        if result == 0 { return true }
        // macOS returns -1/EINVAL for the end of a valid empty ACL.
        guard result == -1, errno == EINVAL else { throw AICueLocalCredentialError.unavailable }
        return false
    }
}

/// Local plaintext storage protected by POSIX permissions and absence of extended ACL entries.
/// It does not provide encryption or isolation from other processes running as the same user.
/// Construction and missing-item checks never create directories. Only an explicit save writes.
package actor SenseAudioFileCredentialVault: AICueCredentialVault {
    private let directory: URL
    private let filename = "senseaudio-cn.key"
    private let maximumBytes = 512
    private let aclReader: any AICueLocalCredentialACLReading

    package init(
        directory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Application Support/Claudio/Credentials", isDirectory: true),
        aclReader: any AICueLocalCredentialACLReading = AICueLocalCredentialSystemACLReader()
    ) {
        self.directory = directory.standardizedFileURL
        self.aclReader = aclReader
    }

    package func containsCredential(in slotID: AICueCredentialSlotID) throws -> Bool {
        try requireSenseAudio(slotID)
        guard let root = try openDirectory(create: false) else { return false }
        defer { close(root) }
        guard let item = try openItem(in: root) else { return false }
        close(item)
        return true
    }

    package func credential(in slotID: AICueCredentialSlotID) throws -> SensitiveCredentialInput? {
        try requireSenseAudio(slotID)
        guard let root = try openDirectory(create: false) else { return nil }
        defer { close(root) }
        guard let item = try openItem(in: root) else { return nil }
        defer { close(item) }

        // Read through the same validated fd, with an extra byte to detect growth during reading.
        var bytes = [UInt8](repeating: 0, count: maximumBytes + 1)
        var count = 0
        while count < bytes.count {
            let readCount = bytes.withUnsafeMutableBytes {
                Darwin.read(item, $0.baseAddress!.advanced(by: count), $0.count - count)
            }
            if readCount < 0 && errno == EINTR { continue }
            guard readCount >= 0 else { throw AICueLocalCredentialError.unavailable }
            if readCount == 0 { break }
            count += readCount
        }
        guard count > 0, count <= maximumBytes,
            let value = String(bytes: bytes.prefix(count), encoding: .utf8),
            let credential = try? SensitiveCredentialInput(value)
        else { throw AICueLocalCredentialError.unavailable }
        return credential
    }

    package func replaceCredential(
        _ credential: SensitiveCredentialInput, in slotID: AICueCredentialSlotID
    ) throws {
        try requireSenseAudio(slotID)
        guard let root = try openDirectory(create: true) else {
            throw AICueLocalCredentialError.unavailable
        }
        defer { close(root) }
        if let previous = try openItem(in: root) { close(previous) }

        let temporaryName = ".\(UUID().uuidString).tmp"
        let item = openat(
            root, temporaryName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard item >= 0 else { throw AICueLocalCredentialError.unavailable }
        defer {
            close(item)
            unlinkat(root, temporaryName, 0)
        }
        guard fchmod(item, 0o600) == 0 else { throw AICueLocalCredentialError.unavailable }
        var stagingInfo = stat()
        guard fstat(item, &stagingInfo) == 0 else { throw AICueLocalCredentialError.unavailable }
        try requirePrivatePermissions(stagingInfo, descriptor: item, mode: 0o600)
        let data = credential.withUTF8String { Data($0.utf8) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(
                    item, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw AICueLocalCredentialError.unavailable }
                offset += count
            }
        }
        guard fsync(item) == 0,
            renameat(root, temporaryName, root, filename) == 0
        else { throw AICueLocalCredentialError.unavailable }
    }

    package func deleteCredential(in slotID: AICueCredentialSlotID) throws {
        try requireSenseAudio(slotID)
        guard let root = try openDirectory(create: false) else { return }
        defer { close(root) }
        guard let item = try openItem(in: root) else { return }
        close(item)
        guard unlinkat(root, filename, 0) == 0 else { throw AICueLocalCredentialError.unavailable }
    }

    private func requireSenseAudio(_ slotID: AICueCredentialSlotID) throws {
        guard slotID == .senseAudioChina else { throw AICueLocalCredentialError.unavailable }
    }

    private func requirePrivatePermissions(
        _ info: stat, descriptor: Int32, mode: mode_t
    ) throws {
        guard info.st_uid == geteuid(), info.st_mode & 0o7777 == mode else {
            throw AICueLocalCredentialError.unavailable
        }
        do {
            guard try !aclReader.hasEntries(on: descriptor) else {
                throw AICueLocalCredentialError.unavailable
            }
        } catch {
            throw AICueLocalCredentialError.unavailable
        }
    }

    /// Traverse with directory-relative descriptors so user-controlled links are never followed.
    /// Foundation preserves macOS's /var and /tmp aliases even after resolvingSymlinksInPath().
    private func openDirectory(create: Bool) throws -> Int32? {
        guard directory.isFileURL, directory.pathComponents.count > 1 else {
            throw AICueLocalCredentialError.unavailable
        }
        var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw AICueLocalCredentialError.unavailable }
        var transferred = false
        defer { if !transferred { close(descriptor) } }
        var components = Array(directory.pathComponents.dropFirst())
        if let first = components.first, ["var", "tmp", "etc"].contains(first),
            (try? FileManager.default.destinationOfSymbolicLink(atPath: "/\(first)"))
                == "private/\(first)"
        {
            components.insert("private", at: 0)
        }
        for component in components {
            var next = openat(
                descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if next < 0 && errno == ENOENT {
                guard create else { return nil }
                guard mkdirat(descriptor, component, 0o700) == 0 || errno == EEXIST else {
                    throw AICueLocalCredentialError.unavailable
                }
                next = openat(
                    descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard next >= 0 else { throw AICueLocalCredentialError.unavailable }
            close(descriptor)
            descriptor = next
        }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw AICueLocalCredentialError.unavailable }
        try requirePrivatePermissions(info, descriptor: descriptor, mode: 0o700)
        transferred = true
        return descriptor
    }

    private func openItem(in root: Int32) throws -> Int32? {
        let descriptor = openat(root, filename, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if descriptor < 0 && errno == ENOENT { return nil }
        guard descriptor >= 0 else { throw AICueLocalCredentialError.unavailable }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
            info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
            info.st_size > 0, info.st_size <= maximumBytes
        else {
            close(descriptor)
            throw AICueLocalCredentialError.unavailable
        }
        do {
            try requirePrivatePermissions(info, descriptor: descriptor, mode: 0o600)
        } catch {
            close(descriptor)
            throw AICueLocalCredentialError.unavailable
        }
        return descriptor
    }
}
