import ClaudioCore
import Foundation

/// The observable result of replacing one installed built-in pack with its factory copy.
///
/// `salvaged` is non-`nil` whenever anything already occupied the installed path. The caller
/// must surface its absolute path to the user: the old tree may contain their only copy of
/// imported audio, so moving it aside is never a silent implementation detail.
public struct FactoryPackRestoreOutcome: Sendable, Equatable {
    public let restoredPackID: String
    public let salvaged: SalvagedPack?

    public init(restoredPackID: String, salvaged: SalvagedPack?) {
        self.restoredPackID = restoredPackID
        self.salvaged = salvaged
    }
}

public enum FactoryPackRestoreError: Error, Sendable, Equatable {
    /// Refused before any disk write.
    case unsafePackID(packID: String)
    /// No app-bundled factory root was supplied.
    case factoryUnavailable(packID: String)
    /// The requested id is not a real built-in directory under the factory root.
    case notBuiltinPack(packID: String)
    /// The factory entry is not a real directory (for example, it is a symlink).
    case unsafeFactorySource(packID: String)
    /// The factory manifest is unreadable/mismatched, or one of its declared audio files is not a
    /// contained regular file. Refused before staging or moving the installed tree.
    case invalidFactoryContents(reason: String)
    /// Creating the destination root, copying the complete factory tree into staging, or
    /// validating that the staged tree remains self-contained after relocation failed.
    case stagingFailed(reason: String)
    /// The old installed entry could not be moved intact to its hidden sibling.
    case salvageFailed(reason: String)
    /// The complete staged tree could not be renamed into place. If the old entry had already
    /// been moved, `salvaged` tells the caller exactly where it remains.
    case publishFailed(reason: String, salvaged: SalvagedPack?)
}

/// Returns true only for a real directory entry, without accepting a symlink-to-directory.
private func isRealDirectory(at url: URL) -> Bool {
    guard
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
        let type = attributes[.type] as? FileAttributeType
    else {
        return false
    }
    return type == .typeDirectory
}

/// Finds a hidden sibling without ever deleting or overwriting an older salvage.
private func nextFactoryRestoreSalvageURL(packID: String, userPacksDirectory: URL) -> URL {
    let base = ".\(packID).pre-restore-\(ProcessInfo.processInfo.processIdentifier)"
    var candidate = userPacksDirectory.appendingPathComponent(base, isDirectory: true)
    var attempt = 1
    while (try? FileManager.default.attributesOfItem(atPath: candidate.path)) != nil {
        attempt += 1
        candidate = userPacksDirectory.appendingPathComponent(
            "\(base)-\(attempt)",
            isDirectory: true)
    }
    return candidate
}

private func invalidFactoryContentsReason(packID: String, source: URL) -> String? {
    let manifest: PackManifest
    switch loadPackManifest(in: source) {
    case .success(let loaded):
        manifest = loaded
    case .failure(let error):
        return "manifest.json 无法读取：\(error.reason)"
    }
    guard manifest.id == packID else {
        return "manifest.json 的 id 是「\(manifest.id)」，与目录名「\(packID)」不一致"
    }
    for fileName in Set(manifest.events.values).sorted() {
        guard
            let file = safePackFileURL(fileName, in: source),
            regularFileExists(at: file)
        else {
            return "出厂清单声明的音频「\(fileName)」不存在、不是正规文件或越出声音包目录"
        }
    }
    return nil
}

/// Replaces an installed built-in pack with the pristine tree from
/// ``AudioImportEnvironment/factoryPacksDirectory``.
///
/// This deliberately does not call setup's `copyBundledPacks`: setup skips an already-usable
/// destination, while restore must replace that exact case. It reuses only the mechanical
/// discipline:
///
/// 1. copy the complete factory tree to a dot-prefixed `.<id>.tmp-<pid>` sibling;
/// 2. move any existing installed entry intact to a unique hidden sibling;
/// 3. rename the complete staging directory into the visible destination.
///
/// A copy failure therefore leaves the old pack untouched. A later failure never exposes a
/// half-copied pack: staging is removed, and an already-moved old tree remains at the returned
/// salvage path. The operation is fully synchronous and main-actor isolated; it intentionally
/// takes no manifest lock because built-ins are read-only and bind/clear never target them.
@MainActor
public func restoreFactoryPack(
    id: String,
    environment: AudioImportEnvironment
) -> Result<FactoryPackRestoreOutcome, FactoryPackRestoreError> {
    guard isSafePackID(id) else {
        return .failure(.unsafePackID(packID: id))
    }
    guard let factoryPacksDirectory = environment.factoryPacksDirectory else {
        return .failure(.factoryUnavailable(packID: id))
    }
    guard environment.builtinPackIDs.contains(id) else {
        return .failure(.notBuiltinPack(packID: id))
    }

    let source = factoryPacksDirectory.appendingPathComponent(id, isDirectory: true)
    guard isRealDirectory(at: source) else {
        return .failure(.unsafeFactorySource(packID: id))
    }
    if let reason = invalidFactoryContentsReason(packID: id, source: source) {
        return .failure(.invalidFactoryContents(reason: reason))
    }

    let fileManager = FileManager.default
    let destination = environment.userPacksDirectory.appendingPathComponent(
        id,
        isDirectory: true)
    let staging = environment.userPacksDirectory.appendingPathComponent(
        ".\(id).tmp-\(ProcessInfo.processInfo.processIdentifier)",
        isDirectory: true)

    do {
        try fileManager.createDirectory(
            at: environment.userPacksDirectory,
            withIntermediateDirectories: true)
        // Same reserved same-pid cleanup used by Setup.swift and PackFork.swift. Old scratch
        // directories from other pids are never globbed or touched.
        try? fileManager.removeItem(at: staging)
        try fileManager.copyItem(at: source, to: staging)
        // `copyItem` preserves symbolic-link destinations verbatim. A factory entry may be safe
        // while it lives under `factoryPacksDirectory` yet become unsafe after relocation: for
        // example, an absolute `stop.mp3` symlink back into the factory tree passes the source
        // containment check but would escape the installed pack after this directory is renamed.
        // Validate the complete staged tree as its own pack before any installed content moves.
        // Relative in-pack symlinks remain valid; absolute/source-anchored links fail closed.
        if let reason = invalidFactoryContentsReason(packID: id, source: staging) {
            try? fileManager.removeItem(at: staging)
            return .failure(
                .stagingFailed(
                    reason: "出厂副本复制后无法作为独立声音包安全发布：\(reason)"))
        }
        stripQuarantineAttribute(at: staging)
    } catch {
        try? fileManager.removeItem(at: staging)
        return .failure(.stagingFailed(reason: error.localizedDescription))
    }

    var salvaged: SalvagedPack?
    if (try? fileManager.attributesOfItem(atPath: destination.path)) != nil {
        let aside = nextFactoryRestoreSalvageURL(
            packID: id,
            userPacksDirectory: environment.userPacksDirectory)
        do {
            try environment.beforeFactoryPackRestoreSalvage?()
            try fileManager.moveItem(at: destination, to: aside)
            salvaged = SalvagedPack(packID: id, movedTo: aside.path)
        } catch {
            try? fileManager.removeItem(at: staging)
            return .failure(.salvageFailed(reason: error.localizedDescription))
        }
    }

    do {
        try environment.beforeFactoryPackRestorePublish?()
        try fileManager.moveItem(at: staging, to: destination)
    } catch {
        try? fileManager.removeItem(at: staging)
        return .failure(
            .publishFailed(
                reason: error.localizedDescription,
                salvaged: salvaged))
    }

    return .success(
        FactoryPackRestoreOutcome(
            restoredPackID: id,
            salvaged: salvaged))
}
