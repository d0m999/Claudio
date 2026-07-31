import ClaudioCore
import Darwin
import Foundation

public enum PackForkIDAllocationError: Error, Sendable, Equatable {
    case unsafeSourceID(fromID: String)
    case candidateCountOverflow
    case noCandidateWithinBound(checked: Int)
}

/// Why ``forkPack(fromID:newID:environment:)`` refused, or failed partway through, forking a
/// built-in pack's factory copy into a brand-new user-owned pack (PLAN-SOUND-MANAGER.md §2.2,
/// T6).
public enum PackForkError: Error, Sendable, Equatable {
    /// `newID` failed ``isSafePackID(_:)`` — checked, and refused, before ANY disk write.
    case unsafeNewID(newID: String)
    /// `fromID` failed ``isSafePackID(_:)``. Not explicitly called for by the plan (which only
    /// requires validating `newID`), but added defensively: `fromID` flows straight into
    /// `environment.factoryPacksDirectory!.appendingPathComponent(fromID:)` below, the exact
    /// same escape-the-root shape every other pack-id boundary in this codebase already
    /// guards against with this same predicate. Checked, and refused, before ANY disk write —
    /// same as ``unsafeNewID(newID:)``.
    case unsafeSourceID(fromID: String)
    /// `environment.userPacksDirectory/newID` already has SOMETHING at it — a file, a
    /// directory, or a dangling symlink (checked via `attributesOfItem`'s **lstat** semantics,
    /// mirroring `Setup.swift`'s own equivalent check — `FileManager.fileExists` would let a
    /// dangling symlink slip through, since it follows links). **Never** silently overwritten,
    /// no matter what's there or whether it's a usable pack.
    case destinationAlreadyExists(newID: String)
    /// `environment.factoryPacksDirectory` is `nil` — there is no factory copy to fork from at
    /// all (e.g. `swift run ClaudioGUI` with no app bundle, or any test fixture that never
    /// injected one). Checked, and refused, before any disk write.
    case sourceUnavailable(fromID: String)
    /// The named factory entry exists only through a symbolic link (or is not a real directory).
    /// Forking it would let the manifest rewrite escape into an external tree.
    case unsafeFactorySource(fromID: String)
    /// Copying `environment.factoryPacksDirectory!/fromID` into staging failed after the source
    /// was verified as a real directory. Always fails closed — never a crash or substitution.
    case copyFailed(reason: String)
    /// The staged copy's `manifest.json` rewrite (id/name/license/author) failed —
    /// ``mutateManifestJSON(at:lockFile:_:)`` returned `.failure`. The staging directory has
    /// already been removed by the time this is returned; nothing is ever left at the final
    /// (non-dot-prefixed, `availablePacks`-visible) destination path.
    case manifestRewriteFailed(reason: String)
    /// The final `rename` — moving the fully-rewritten staging directory into
    /// `userPacksDirectory/newID` — failed. The staging directory has already been removed by
    /// the time this is returned.
    case renameFailed(reason: String)
}

/// Turns a ``ManifestBindError`` into a plain-string reason for
/// ``PackForkError/manifestRewriteFailed(reason:)``. `ManifestBindError` itself carries no
/// `.description`, and ``forkPack(fromID:newID:environment:)`` calls the shared
/// read-modify-write primitive (``mutateManifestJSON(at:lockFile:_:)``) directly — never
/// `bindEventToManifest` — so only the four cases that primitive itself can actually produce
/// (`.manifestUnreadable`, `.writeFailed`, `.lockBusy`, `.lockFailed`) are reachable here in
/// practice; the other three are `bindEventToManifest`'s own file-level pre-check cases (see
/// ``ManifestBindError``'s doc comment) and are handled below defensively, never expected to
/// fire from this call site.
private func manifestRewriteReason(_ error: ManifestBindError) -> String {
    switch error {
    case .manifestUnreadable(let reason): return reason
    case .writeFailed(let reason): return reason
    case .lockBusy: return "另一个写者正持有声音包锁（packs.lock）"
    case .lockFailed(let errno): return "取声音包锁失败（errno \(errno)）"
    case .packNotFound(let packID): return "包目录未找到：\(packID)"
    case .unsafeFileName: return "文件名不安全"
    case .fileNotFound(let fileName): return "文件不存在：\(fileName)"
    }
}

/// The next available id for ``forkPack(fromID:newID:environment:)`` to fork `fromID` into:
/// `<fromID>-copy`, or `<fromID>-copy-2` / `<fromID>-copy-3` / … if that's already taken
/// (PLAN-SOUND-MANAGER.md §2.2's id-generation policy).
///
/// A standalone **pure function** — no disk I/O — factored out so it's independently
/// testable, and so ``forkPack(fromID:newID:environment:)`` itself stays "given a newID,
/// safely execute or refuse", with zero id-generation policy of its own. A caller (a future
/// view model) composes the two: read `userPacksDirectory`'s current ids, call this, then
/// call `forkPack` with the result.
///
/// `@MainActor`: not because this function touches any actor-isolated state (it doesn't — it's
/// pure), but because it lives in the same file as ``forkPack(fromID:newID:environment:)``,
/// and this file is enrolled in the `mutateManifestJSON` concurrency fence
/// (`SourceScannerSuite`) the moment ANY function in it calls that primitive — the fence then
/// requires EVERY exported function in the file to carry `@MainActor`, not just the one(s)
/// that actually call it.
@MainActor
public func nextForkPackID(
    for fromID: String,
    occupiedBasenames: Set<String>
) -> Result<String, PackForkIDAllocationError> {
    guard isSafePackID(fromID) else { return .failure(.unsafeSourceID(fromID: fromID)) }
    let base = "\(fromID)-copy"
    let (candidateCount, overflowed) = occupiedBasenames.count.addingReportingOverflow(1)
    guard !overflowed else { return .failure(.candidateCountOverflow) }

    for offset in 0..<candidateCount {
        let candidate: String
        if offset == 0 {
            candidate = base
        } else {
            let (suffix, suffixOverflowed) = offset.addingReportingOverflow(1)
            guard !suffixOverflowed else { return .failure(.candidateCountOverflow) }
            candidate = "\(base)-\(suffix)"
        }
        if !occupiedBasenames.contains(candidate) { return .success(candidate) }
    }
    return .failure(.noCandidateWithinBound(checked: candidateCount))
}

/// Every directory entry reserves its basename for fork allocation — including regular files,
/// dangling symlinks and malformed pack directories. `packDirectoryIDs(in:)` deliberately filters
/// those entries for gallery display, so it cannot be reused for the stronger publication rule.
@MainActor
public func occupiedPackBasenames(in directory: URL) throws -> Set<String> {
    do {
        return Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
    } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
        return []
    }
}

private func makeForkStagingRoot(in userPacksDirectory: URL, newID: String) -> Result<URL, PackForkError> {
    let templateURL = userPacksDirectory.appendingPathComponent(".\(newID).tmp-XXXXXX")
    var template = Array(templateURL.path.utf8CString)
    let created = template.withUnsafeMutableBufferPointer { buffer in
        mkdtemp(buffer.baseAddress!)
    }
    guard created != nil else {
        let capturedErrno = errno
        return .failure(
            .copyFailed(
                reason: "无法创建独占暂存目录（errno \(capturedErrno)："
                    + "\(String(cString: strerror(capturedErrno)))）"))
    }
    let createdPath = String(
        decoding: template.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    return .success(URL(fileURLWithPath: createdPath, isDirectory: true))
}

/// A factory pack must itself be a real directory entry. `copyItem` preserves a terminal symlink;
/// accepting one here would make the later manifest rewrite follow that link outside staging.
private func isRealForkSourceDirectory(at url: URL) -> Bool {
    guard
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
        let type = attributes[.type] as? FileAttributeType
    else {
        return false
    }
    return type == .typeDirectory
}

/// Forks `fromID`'s **factory** copy (``AudioImportEnvironment/factoryPacksDirectory`` — never
/// the user's possibly-already-edited copy under `userPacksDirectory`) into a brand-new,
/// user-owned pack at `environment.userPacksDirectory/newID` (PLAN-SOUND-MANAGER.md §2.2).
/// `newID` is the caller's to choose (typically ``nextForkPackID(for:occupiedBasenames:)``'s
/// result) — this function only ever safely executes or refuses a GIVEN `newID`, it never
/// invents one itself.
///
/// ## The load-bearing ordering — why this is NOT "copy, rename, then fix the manifest"
///
/// The staged copy's `manifest.json` is rewritten (`id`/`name`/`license`/`author`) **while the
/// staging directory is still dot-prefixed** — i.e. before ``packDirectoryIDs(in:)`` /
/// ``availablePacks(config:environment:)`` can see it at all (`PackGallery.swift`'s own
/// dot-filter, mirroring `Setup.swift`'s identical one). Only once that rewrite has succeeded
/// does the directory get atomically renamed with `RENAME_EXCL` into its final, visible name.
/// There is therefore never a window in which a caller re-scanning `userPacksDirectory` could
/// observe a directory named
/// `newID` whose `manifest.json` still says `id: fromID` — a silently-mislabeled pack that
/// PLAN-SOUND-MANAGER.md §2.2 calls out by name as exactly the bug a naive
/// "rename first, fix the manifest after" ordering would reintroduce (`doctor` doesn't
/// validate `manifest.json`'s `id` against its directory name, so that bug wouldn't even
/// surface as an error anywhere — "a bug that never errors, the worst kind").
///
/// ## Every failure path leaves the staging directory removed, never a half-finished pack
///
/// A copy failure, manifest-rewrite failure, and rename failure all reach the owned staging root's
/// `defer` cleanup. Final publication uses `renameatx_np(RENAME_EXCL)`, so a concurrent destination
/// cannot be overwritten.
///
/// ## Concurrency
///
/// `@MainActor`, fully synchronous (no `async`/`await`, spawns nothing) — required by the
/// `mutateManifestJSON` source-scanner fence (see ``ManifestBinding.swift``'s doc comment on
/// ``mutateManifestJSON(at:lockFile:_:)``: any function whose body calls it must be
/// `@MainActor public func`, not `async`).
@MainActor
public func forkPack(
    fromID: String,
    newID: String,
    environment: AudioImportEnvironment
) -> Result<Void, PackForkError> {
    guard isSafePackID(newID) else { return .failure(.unsafeNewID(newID: newID)) }
    guard isSafePackID(fromID) else { return .failure(.unsafeSourceID(fromID: fromID)) }

    let destination = environment.userPacksDirectory.appendingPathComponent(
        newID, isDirectory: true)
    // lstat semantics (never follows a symlink) — `Setup.swift`'s `publishBundledPacks` already
    // learned the hard way that `FileManager.fileExists` (which DOES follow symlinks) lets a
    // dangling symlink slip through this exact kind of "is anything there?" check.
    if (try? FileManager.default.attributesOfItem(atPath: destination.path)) != nil {
        return .failure(.destinationAlreadyExists(newID: newID))
    }

    guard let factoryPacksDirectory = environment.factoryPacksDirectory else {
        return .failure(.sourceUnavailable(fromID: fromID))
    }
    let sourceDirectory = factoryPacksDirectory.appendingPathComponent(fromID, isDirectory: true)
    guard isRealForkSourceDirectory(at: sourceDirectory) else {
        return .failure(.unsafeFactorySource(fromID: fromID))
    }

    do {
        // Idempotent — a no-op if it already exists. Mirrors `publishBundledPacks` hoisting the
        // same call ahead of its copy loop: `forkPack` may run before the user has ever
        // imported anything of their own, in which case `userPacksDirectory` might not exist
        // yet at all.
        try FileManager.default.createDirectory(
            at: environment.userPacksDirectory, withIntermediateDirectories: true)
    } catch {
        return .failure(.copyFailed(reason: error.localizedDescription))
    }

    let stagingRoot: URL
    switch makeForkStagingRoot(in: environment.userPacksDirectory, newID: newID) {
    case .success(let createdRoot): stagingRoot = createdRoot
    case .failure(let error): return .failure(error)
    }
    // `stagingRoot` was atomically created by this invocation. No path is removed until ownership
    // is established, and cleanup never escapes this root even if another process guesses newID.
    defer { try? FileManager.default.removeItem(at: stagingRoot) }
    let staging = stagingRoot.appendingPathComponent("payload", isDirectory: true)

    do {
        try FileManager.default.copyItem(at: sourceDirectory, to: staging)
    } catch {
        return .failure(.copyFailed(reason: error.localizedDescription))
    }

    // `copyItem` carries `com.apple.quarantine` across (see `Quarantine.swift`) — strip it from
    // the fresh copy before it's ever exposed under a visible name, same reasoning
    // `publishBundledPacks` documents for the identical call.
    stripQuarantineAttribute(at: staging)

    // The staging directory is STILL dot-prefixed here — see this function's own doc comment
    // on why the manifest rewrite must happen before, never after, the rename into place.
    let mutationResult = mutateManifestJSON(at: staging, lockFile: environment.packsLockFile) {
        json in
        // Read the OLD name from the very `json` this closure was handed — never a second,
        // separate manifest read (PLAN-SOUND-MANAGER.md §2.2's explicit instruction: the
        // primitive already handed us the full top-level dictionary, re-reading it a second
        // time would be exactly the duplicate JSON-surgery path `mutateManifestJSON` exists to
        // eliminate).
        let oldName = (json["name"] as? String) ?? fromID
        json["id"] = newID
        json["name"] = "\(oldName) 的副本"
        // Whole-key removal, not a new value: `license`/`author` absent means "we make no
        // claim either way" — see `PackCard.isCC0`'s own doc comment ("false — not 'unknown' —
        // when license is absent") and PLAN-SOUND-MANAGER.md §2.2's reasoning for why this is
        // deliberate and why no new license identifier is invented here.
        json.removeValue(forKey: "license")
        json.removeValue(forKey: "author")
        // `schema` / `events` / any other unknown top-level key: untouched, passed through
        // by `mutateManifestJSON` itself (this transform never touches them).
    }
    switch mutationResult {
    case .success:
        break
    case .failure(let error):
        return .failure(.manifestRewriteFailed(reason: manifestRewriteReason(error)))
    }

    do {
        try environment.beforeForkPackPublish?(destination)
    } catch {
        return .failure(.renameFailed(reason: error.localizedDescription))
    }

    let renameResult = renameatx_np(
        AT_FDCWD, staging.path, AT_FDCWD, destination.path, UInt32(RENAME_EXCL))
    if renameResult != 0 {
        let renameErrno = errno
        if renameErrno == EEXIST {
            return .failure(.destinationAlreadyExists(newID: newID))
        }
        return .failure(
            .renameFailed(
                reason: "renameatx_np errno \(renameErrno): "
                    + String(cString: strerror(renameErrno))))
    }

    return .success(())
}
