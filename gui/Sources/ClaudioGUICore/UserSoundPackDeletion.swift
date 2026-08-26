import ClaudioCore
import Darwin
import Foundation

public struct UserSoundPackDeletionOutcome: Sendable, Equatable {
    public let packID: String
    public let trashedPath: String?

    public init(packID: String, trashedPath: String?) {
        self.packID = packID
        self.trashedPath = trashedPath
    }
}

public enum UserSoundPackDeletionError: Error, Sendable, Equatable {
    case unsafePackID(packID: String)
    case builtinReadOnly(packID: String)
    case activePack(packID: String)
    case configUnavailable
    case packNotFound(packID: String)
    case unsafePackEntry(packID: String)
    case trashFailed(reason: String)
    case isolationChangedRetained(path: String)
    case trashFailedRetained(reason: String, path: String)
    case lockBusy
    case lockFailed(errno: Int32)
}

/// Every pack id currently selected by Global or an explicit Surface override.
///
/// An override with no `selected_pack` inherits Global, which is already present in the result.
/// Deletion uses this complete set rather than the editor's current effective scope so switching
/// the Settings scope cannot make a pack referenced elsewhere appear disposable.
@MainActor
public func referencedSoundPackIDs(in config: ClaudioConfig) -> Set<String> {
    var result = Set([config.selectedPack])
    result.formUnion(config.surfaceOverrides.values.compactMap(\.selectedPack))
    return result
}

/// Moves one explicitly confirmed, inactive user sound pack to the system Trash.
///
/// The destination is revalidated under the shared packs lock as a direct real directory entry;
/// symlinks and paths outside the user root fail closed. Built-ins and packs referenced by any
/// Global/Surface scope are never removed. Before invoking the path-based system Trash API, the
/// verified entry is atomically renamed into a private, hidden sibling directory and its device /
/// inode identity is checked again. `moveToTrash` and `beforeIsolation` are injectable solely for
/// hermetic race tests; production uses `FileManager.trashItem`, preserving a recoverable
/// system-trash result rather than recursively unlinking user content.
@MainActor
public func deleteUserSoundPack(
    packID: String,
    configFile: URL,
    configLockFile: URL,
    environment: AudioImportEnvironment,
    beforeIsolation: @MainActor (URL) throws -> Void = { _ in },
    moveToTrash: @MainActor (URL) throws -> URL? = moveUserSoundPackToTrash
) -> Result<UserSoundPackDeletionOutcome, UserSoundPackDeletionError> {
    guard isSafePackID(packID) else {
        return .failure(.unsafePackID(packID: packID))
    }
    guard !environment.builtinPackIDs.contains(packID) else {
        return .failure(.builtinReadOnly(packID: packID))
    }
    let userPacksDirectory = environment.userPacksDirectory.standardizedFileURL
    let expected =
        userPacksDirectory
        .appendingPathComponent(packID, isDirectory: true)
        .standardizedFileURL
    guard expected.deletingLastPathComponent().path == userPacksDirectory.path else {
        return .failure(.unsafePackID(packID: packID))
    }
    // Hold config.lock from the authoritative read through pack isolation. Every Claudio config
    // writer uses this lock, so a confirmation cannot race a later Global/Surface selection and
    // leave config.json pointing at a directory we just moved to Trash.
    let outcome = withNonBlockingLock(path: configLockFile.path) {
        let referencedPackIDs: Set<String>
        switch currentReferencedSoundPackIDs(in: configFile) {
        case .success(let current):
            referencedPackIDs = current
        case .failure(let error):
            return Result<UserSoundPackDeletionOutcome, UserSoundPackDeletionError>.failure(error)
        }
        guard !referencedPackIDs.contains(packID) else {
            return .failure(.activePack(packID: packID))
        }

        let packsOutcome = withNonBlockingLock(path: environment.packsLockFile.path) {
            deleteUserSoundPackWhileLocked(
                packID: packID,
                userPacksDirectory: userPacksDirectory,
                expected: expected,
                beforeIsolation: beforeIsolation,
                moveToTrash: moveToTrash)
        }
        switch packsOutcome {
        case .ran(let result): return result
        case .skipped: return .failure(.lockBusy)
        case .failed(let errno): return .failure(.lockFailed(errno: errno))
        }
    }
    switch outcome {
    case .ran(let result): return result
    case .skipped: return .failure(.lockBusy)
    case .failed(let errno): return .failure(.lockFailed(errno: errno))
    }
}

@MainActor
private func currentReferencedSoundPackIDs(
    in configFile: URL
) -> Result<Set<String>, UserSoundPackDeletionError> {
    switch readConfigFileBounded(at: configFile) {
    case .success(let data):
        guard let config = try? JSONDecoder().decode(ClaudioConfig.self, from: data),
            !config.surfaceOverridesMalformed,
            config.invalidSurfaceOverrideKeys.isEmpty
        else {
            return .failure(.configUnavailable)
        }
        return .success(referencedSoundPackIDs(in: config))
    case .unreadable where fileSystemEntryIsAbsent(at: configFile):
        return .success([])
    case .notRegularFile, .oversize, .unreadable:
        return .failure(.configUnavailable)
    }
}

private func fileSystemEntryIsAbsent(at url: URL) -> Bool {
    var status = stat()
    let result = url.withUnsafeFileSystemRepresentation { path in
        guard let path else { return Int32(-1) }
        return lstat(path, &status)
    }
    return result != 0 && errno == ENOENT
}

@MainActor
public func moveUserSoundPackToTrash(_ source: URL) throws -> URL? {
    var resultingURL: NSURL?
    try FileManager.default.trashItem(at: source, resultingItemURL: &resultingURL)
    return resultingURL as URL?
}

@MainActor
private func deleteUserSoundPackWhileLocked(
    packID: String,
    userPacksDirectory: URL,
    expected: URL,
    beforeIsolation: @MainActor (URL) throws -> Void,
    moveToTrash: @MainActor (URL) throws -> URL?
) -> Result<UserSoundPackDeletionOutcome, UserSoundPackDeletionError> {
    let rootDescriptor = userPacksDirectory.withUnsafeFileSystemRepresentation { path in
        guard let path else { return Int32(-1) }
        return open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    }
    guard rootDescriptor >= 0 else {
        return .failure(.unsafePackEntry(packID: packID))
    }
    defer { close(rootDescriptor) }

    var rootStatus = stat()
    guard fstat(rootDescriptor, &rootStatus) == 0,
        (rootStatus.st_mode & S_IFMT) == S_IFDIR,
        rootStatus.st_uid == geteuid()
    else {
        return .failure(.unsafePackEntry(packID: packID))
    }

    var sourceStatus = stat()
    let sourceStatusResult = packID.withCString {
        fstatat(rootDescriptor, $0, &sourceStatus, AT_SYMLINK_NOFOLLOW)
    }
    guard sourceStatusResult == 0 else {
        return .failure(.packNotFound(packID: packID))
    }
    guard (sourceStatus.st_mode & S_IFMT) == S_IFDIR else {
        return .failure(.unsafePackEntry(packID: packID))
    }

    let isolationName = ".claudio-trash-\(UUID().uuidString.lowercased())"
    let makeIsolationResult = isolationName.withCString {
        mkdirat(rootDescriptor, $0, mode_t(S_IRWXU))
    }
    guard makeIsolationResult == 0 else {
        let makeIsolationErrno = errno
        return .failure(
            .trashFailed(reason: deletionSystemError("mkdirat", errno: makeIsolationErrno)))
    }
    defer {
        _ = isolationName.withCString {
            unlinkat(rootDescriptor, $0, AT_REMOVEDIR)
        }
    }

    let isolationDescriptor = isolationName.withCString {
        openat(rootDescriptor, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    }
    guard isolationDescriptor >= 0 else {
        let isolationOpenErrno = errno
        return .failure(
            .trashFailed(reason: deletionSystemError("openat", errno: isolationOpenErrno)))
    }
    defer { close(isolationDescriptor) }

    var isolationStatus = stat()
    guard fstat(isolationDescriptor, &isolationStatus) == 0,
        (isolationStatus.st_mode & S_IFMT) == S_IFDIR,
        isolationStatus.st_uid == geteuid(),
        isolationStatus.st_mode & mode_t(S_IRWXG | S_IRWXO) == 0
    else {
        return .failure(.unsafePackEntry(packID: packID))
    }

    do {
        try beforeIsolation(expected)
    } catch {
        return .failure(.trashFailed(reason: error.localizedDescription))
    }

    let isolateResult = packID.withCString { name in
        renameatx_np(
            rootDescriptor,
            name,
            isolationDescriptor,
            name,
            UInt32(RENAME_EXCL))
    }
    guard isolateResult == 0 else {
        let isolateErrno = errno
        if isolateErrno == ENOENT {
            return .failure(.packNotFound(packID: packID))
        }
        return .failure(
            .trashFailed(reason: deletionSystemError("renameatx_np", errno: isolateErrno)))
    }

    let isolated =
        userPacksDirectory
        .appendingPathComponent(isolationName, isDirectory: true)
        .appendingPathComponent(packID, isDirectory: true)
    var isolatedStatus = stat()
    let isolatedStatusResult = packID.withCString {
        fstatat(isolationDescriptor, $0, &isolatedStatus, AT_SYMLINK_NOFOLLOW)
    }
    guard isolatedStatusResult == 0,
        sameEntry(sourceStatus, isolatedStatus),
        directoryAtPathMatchesDescriptor(userPacksDirectory, status: rootStatus),
        directoryAtPathMatchesDescriptor(
            isolated.deletingLastPathComponent(),
            status: isolationStatus)
    else {
        if restoreIsolatedPack(
            packID: packID,
            rootDescriptor: rootDescriptor,
            isolationDescriptor: isolationDescriptor)
        {
            return .failure(.unsafePackEntry(packID: packID))
        }
        return .failure(
            .isolationChangedRetained(path: isolated.path))
    }

    do {
        let trashedURL = try moveToTrash(isolated)
        return .success(
            UserSoundPackDeletionOutcome(
                packID: packID,
                trashedPath: trashedURL?.path))
    } catch {
        if restoreIsolatedPack(
            packID: packID,
            rootDescriptor: rootDescriptor,
            isolationDescriptor: isolationDescriptor)
        {
            return .failure(.trashFailed(reason: error.localizedDescription))
        }
        return .failure(
            .trashFailedRetained(
                reason: error.localizedDescription,
                path: isolated.path))
    }
}

private func sameEntry(_ lhs: stat, _ rhs: stat) -> Bool {
    lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino
}

private func directoryAtPathMatchesDescriptor(_ directory: URL, status expected: stat) -> Bool {
    var actual = stat()
    let result = directory.withUnsafeFileSystemRepresentation { path in
        guard let path else { return Int32(-1) }
        return lstat(path, &actual)
    }
    return result == 0 && (actual.st_mode & S_IFMT) == S_IFDIR && sameEntry(actual, expected)
}

private func restoreIsolatedPack(
    packID: String,
    rootDescriptor: Int32,
    isolationDescriptor: Int32
) -> Bool {
    packID.withCString { name in
        renameatx_np(
            isolationDescriptor,
            name,
            rootDescriptor,
            name,
            UInt32(RENAME_EXCL)) == 0
    }
}

private func deletionSystemError(_ operation: String, errno value: Int32) -> String {
    "\(operation) errno \(value): \(String(cString: strerror(value)))"
}
