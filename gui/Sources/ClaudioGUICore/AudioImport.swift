import ClaudioCore
import Foundation

/// A single audio file successfully copied into a user pack — the result the SwiftUI
/// layer needs to update a row's inline filename and trigger an auto-preview (▶) without
/// re-deriving anything from disk (ENGINEERING.md T8 acceptance criterion 8: "Core 返回
/// 携带已复制文件的结果，供 SwiftUI 触发试听").
public struct ImportedAudioFile: Sendable, Equatable {
    public let packID: String
    /// Where the copy landed — always inside the user pack root, never the bundle.
    public let destinationURL: URL
    /// `destinationURL`'s last path component, surfaced separately so callers don't need
    /// to re-derive it from a URL just to render an inline filename.
    public let fileName: String
    public let format: AudioFormat
    public let fileSizeBytes: Int
    public let duration: TimeInterval
}

/// One imported file's outcome: either it was copied in, or refused for one of
/// ``DropRejectionReason``'s cases.
public enum AudioImportOutcome: Sendable, Equatable {
    case success(ImportedAudioFile)
    case rejected(DropRejectionReason)
}

/// One dropped/picked file's identity, as the SwiftUI drop-zone view extracts it from
/// `NSItemProvider`: `sourceURL` is where the file's *bytes* currently live (a real,
/// already-on-disk local URL — e.g. what `loadFileRepresentation`/`loadObject(ofClass:
/// URL.self)` hands back), while `suggestedFileName` is the *name* it should be copied in
/// under.
///
/// These are deliberately two separate strings, not one derived from the other: an
/// `NSItemProvider`'s "suggested name" has nothing structurally to do with its backing
/// temp file's actual on-disk basename, so the destination-filename safety check
/// (`importAudioFile`'s use of `safePackFileURL`) must validate exactly the string that
/// will become part of a filesystem path — not whatever the temp file happened to be
/// named — for the path-traversal check (ENGINEERING.md T8 acceptance criterion 5) to
/// mean anything.
public struct AudioImportRequest: Sendable, Equatable {
    public let sourceURL: URL
    public let suggestedFileName: String

    public init(sourceURL: URL, suggestedFileName: String) {
        self.sourceURL = sourceURL
        self.suggestedFileName = suggestedFileName
    }
}

/// Imports one dropped file into the user pack `packID`: validates destination-name
/// safety, built-in-pack collision, size, content-sniffed format, and duration — in that
/// order — then copies it in only once every check passes (ENGINEERING.md T8, the
/// complete "drag-in hardening" pipeline). Never references or reads from the original
/// `sourceURL` again after a successful import — the copy is the only thing anything
/// downstream ever touches (acceptance criterion 1: "never reference the original path").
///
/// ## Order of checks (and why)
/// 1. **Destination-name/path safety** (``DropRejectionReason/pathTraversal``) — reused,
///    audited containment logic (`isSafePackID` + `safePackFileURL`), checked before any
///    disk I/O on the dropped file's *content*, since a hostile filename is a security
///    concern independent of what the file contains.
/// 2. **Built-in-pack collision** (``DropRejectionReason/overwritesBuiltin(packID:)``) —
///    still no content I/O; see that case's doc comment for the exact semantics.
/// 3. **Symlink-source refusal, then size cap** (``DropRejectionReason/copyFailed(reason:)``
///    for the former, ``DropRejectionReason/oversize(actualBytes:maxBytes:)`` for the
///    latter) — both checked via filesystem metadata only, *before* reading the file's
///    bytes into memory. A symlink source is refused outright rather than dereferenced:
///    its metadata `.size` is the link's own target-path-string length, not the real
///    size of whatever it points to, so trusting it would silently bypass the size cap
///    for a symlink pointing at an arbitrarily large file. Once that's ruled out, an
///    oversized file is rejected without ever being fully loaded.
/// 4. **Content-sniffed format whitelist** (``DropRejectionReason/nonWhitelistFormat``) —
///    only now do we read the file's bytes, once we know they're small enough to be worth
///    reading. This exact `Data` is what step 6 persists — `sourceURL` is never read a
///    second time.
/// 5. **Duration cap** (``DropRejectionReason/overDuration(actualSeconds:maxSeconds:)``)
///    — probed on the *original* `sourceURL`, before copying, so a too-long file is never
///    written into the user's pack directory at all.
/// 6. Only if all five pass: write the `Data` already read in step 4 → the validated
///    destination (never `FileManager.copyItem`, which would copy a symlink source as a
///    symlink rather than its content — moot now that step 3 refuses symlink sources,
///    but writing the already-validated bytes is the stronger invariant regardless).
public func importAudioFile(
    sourceURL: URL,
    suggestedFileName: String,
    packID: String,
    environment: AudioImportEnvironment
) -> AudioImportOutcome {
    let fileManager = FileManager.default

    // 1. Destination-name/path safety — no content I/O yet.
    guard isSafePackID(packID) else { return .rejected(.pathTraversal) }
    let userPackDirectory = environment.userPacksDirectory.appendingPathComponent(
        packID, isDirectory: true)
    guard let destinationURL = safePackFileURL(suggestedFileName, in: userPackDirectory) else {
        return .rejected(.pathTraversal)
    }

    // 2. Built-in-pack collision — still no content I/O.
    if isBuiltinOnlyPackID(
        packID, userPacksDirectory: environment.userPacksDirectory,
        bundledPacksDirectory: environment.bundledPacksDirectory)
    {
        return .rejected(.overwritesBuiltin(packID: packID))
    }

    // 3. Reject a symlink source outright, then apply the size cap — metadata only,
    // before reading any bytes.
    //
    // `FileManager.attributesOfItem(atPath:)` does **not** dereference symlinks — for a
    // symlink it reports `.type == .typeSymbolicLink` and a `.size` equal to the byte
    // length of the link's *target path string* (typically tens of bytes), never the
    // real size of whatever it points to (verified empirically: a symlink to a 2MB file
    // reported `.size == 129`). Trusting that value here would silently bypass the size
    // cap for any symlink pointing at an arbitrarily large file, and would let step 4
    // below fully read that arbitrarily large target into memory before any cap could
    // ever reject it (defeating the documented "reject via metadata before loading
    // bytes" ordering below). Refusing a symlink source here, before any of that, closes
    // the size-cap bypass at its root rather than trying to make every later step
    // symlink-aware individually.
    guard let sourceAttributes = try? fileManager.attributesOfItem(atPath: sourceURL.path) else {
        return .rejected(.copyFailed(reason: "读不到这个文件"))
    }
    guard (sourceAttributes[.type] as? FileAttributeType) != .typeSymbolicLink else {
        return .rejected(
            .copyFailed(
                reason: "这个文件是个链接（symlink），Claudio 只收音频文件本身，请直接拖入真正的文件再试一次"))
    }
    guard let sourceSize = sourceAttributes[.size] as? Int else {
        return .rejected(.copyFailed(reason: "读不到这个文件"))
    }
    guard sourceSize <= environment.limits.maxFileSizeBytes else {
        return .rejected(
            .oversize(actualBytes: sourceSize, maxBytes: environment.limits.maxFileSizeBytes))
    }

    // 4. Content-sniffed format whitelist — first point bytes are actually read. `data`
    // is also exactly what step 6 persists below — never re-read from `sourceURL` again
    // after this point (acceptance criterion 1: never reference the original path once
    // validation has started consuming its content).
    //
    // A real read failure here (source vanished/became unreadable in the window since
    // step 3's metadata check, permission revoked, etc.) is deliberately reported as
    // ``DropRejectionReason/copyFailed(reason:)``, not folded into `.nonWhitelistFormat`
    // — those are different failures with different causes, and misreporting one as the
    // other would contradict `copyFailed`'s own reason for existing (never silently
    // misreport the real cause).
    let data: Data
    do {
        data = try Data(contentsOf: sourceURL)
    } catch {
        return .rejected(.copyFailed(reason: error.localizedDescription))
    }
    // Belt-and-suspenders re-check against the *actually-read* byte count: step 3's cap
    // was enforced against filesystem metadata a moment earlier, so a source that grows
    // between that stat and this read (same-user TOCTOU — the concurrent-writer would
    // have to be the same account, matching this codebase's already-established
    // same-user threat model for pack-directory races) would otherwise slip an oversized
    // file past the cap and into step 6's write. This does not avoid transiently holding
    // the grown file's bytes in memory for this one check — `Data(contentsOf:)` above
    // already read them — but it does guarantee an oversized result is never persisted.
    guard data.count <= environment.limits.maxFileSizeBytes else {
        return .rejected(
            .oversize(actualBytes: data.count, maxBytes: environment.limits.maxFileSizeBytes))
    }
    guard let format = sniffAudioFormat(data) else {
        return .rejected(.nonWhitelistFormat)
    }

    // 5. Duration cap — probed on the original source, before ever copying.
    let duration = environment.durationProbe.probeDuration(of: sourceURL)
    guard let duration, duration <= environment.limits.maxDurationSeconds else {
        return .rejected(
            .overDuration(actualSeconds: duration, maxSeconds: environment.limits.maxDurationSeconds))
    }

    // 6. Persist. Deliberately `data.write(to:options:.atomic)` — the exact bytes already
    // read and content-sniffed in step 4 — rather than `FileManager.copyItem(at:to:)`.
    // `copyItem` was verified empirically to copy a symlink *as a symlink* (its link
    // target string, not the referenced content) rather than duplicating the target's
    // bytes; since step 3 above already refuses a symlink `sourceURL`, this can no
    // longer be reached via that specific path, but writing the already-validated
    // in-memory `data` is a stronger invariant regardless — "the bytes we validated are
    // exactly the bytes on disk", with zero possibility of anything re-reading
    // `sourceURL` a second time and getting a different answer (closes the TOCTOU window
    // a `copyItem`-based re-read of `sourceURL` at write time would otherwise leave open,
    // consistent with acceptance criterion 1: never reference the original path once
    // it's been read).
    //
    // `.atomic` writes to a temp file in the destination directory, then `rename(2)`s it
    // into place: verified empirically this replaces whatever directory entry currently
    // sits at `destinationURL` — a prior regular file, a dangling symlink, or even a
    // symlink pointing at a real file elsewhere — by repointing the directory entry
    // itself, without ever opening/truncating/writing through an existing symlink's
    // target. A re-drop onto the same filename inside the caller's own already-
    // user-owned pack directory therefore safely replaces the previous file — the
    // expected "re-bind this event's sound" flow (re-dragging a new file onto the same
    // row) — distinct from the built-in-collision case already rejected in step 2 above
    // (which blocks the *first* write into a still-purely-built-in pack id, not a second
    // write into a pack the user already owns). An interrupted/failed write leaves the
    // previous file (or nothing) in place, never a truncated half-written one, since the
    // rename is the only step that ever touches the real destination path.
    do {
        try fileManager.createDirectory(at: userPackDirectory, withIntermediateDirectories: true)
        try data.write(to: destinationURL, options: .atomic)
    } catch {
        return .rejected(.copyFailed(reason: error.localizedDescription))
    }

    return .success(
        ImportedAudioFile(
            packID: packID,
            destinationURL: destinationURL,
            fileName: destinationURL.lastPathComponent,
            format: format,
            fileSizeBytes: sourceSize,
            duration: duration
        ))
}

/// Whether `packID` currently resolves to a pack directory **only** via the bundled
/// (built-in) root — i.e. the user has no pack of their own at this id yet. This is the
/// exact case ``DropRejectionReason/overwritesBuiltin(packID:)`` blocks.
///
/// **Reconciling with ENGINEERING.md §157-158** (which explicitly *allows* a user pack to
/// override a same-id bundled pack at *selection* time — `resolvePackDirectory` checks
/// the user root first, by design): that decision is about which directory `claudio play`
/// resolves to once a user copy already exists. It says nothing about whether drag-and-
/// drop may *silently create* that user copy's very first file in the first place. T8's
/// "拒同名覆盖内置" scopes to exactly that gap: importing into a pack id that is currently
/// *only* a built-in identity is refused, so a casual drop can't accidentally start
/// shadowing a built-in pack's contents without the user having explicitly done something
/// (a future, out-of-T8-scope "为这个内置包创建你自己的版本" action, or simply having
/// already imported once before) to "claim" that pack id as their own first. Once a user
/// directory for `packID` exists — by whatever means — every subsequent import into it is
/// just an ordinary edit to a pack the user already owns, and proceeds normally.
///
/// Note this is unrelated to, and does not weaken, the *destination-confinement*
/// guarantee: `importAudioFile` never writes anywhere but `environment.userPacksDirectory`
/// — the bundled root is read-only input to this one check, never a write target.
///
/// Deliberately built on top of ``resolvePackDirectory(id:userPacksDirectory:bundledPacksDirectory:)``
/// — the same audited, symlink-safe resolver `doctor`/`play` use — called twice (once
/// against the user root alone, once against both roots) rather than re-implementing
/// containment/existence checks a second time (T8's "REUSE, do not reinvent" instruction).
private func isBuiltinOnlyPackID(
    _ packID: String,
    userPacksDirectory: URL,
    bundledPacksDirectory: URL?
) -> Bool {
    guard bundledPacksDirectory != nil else { return false }
    let userOnlyResolution = resolvePackDirectory(
        id: packID, userPacksDirectory: userPacksDirectory, bundledPacksDirectory: nil)
    guard userOnlyResolution == nil else { return false }
    let eitherRootResolution = resolvePackDirectory(
        id: packID, userPacksDirectory: userPacksDirectory,
        bundledPacksDirectory: bundledPacksDirectory)
    return eitherRootResolution != nil
}

// MARK: - Multi-file batch

/// One rejected file from a multi-file batch, paired with why (ENGINEERING.md T8
/// acceptance criterion 7: "multi-file batch yields valid-accepted + per-file reject
/// reasons").
public struct RejectedAudioFile: Sendable, Equatable {
    public let sourceFileName: String
    public let reason: DropRejectionReason
}

/// A multi-file drop's outcome: every file that passed is copied in and listed in
/// ``accepted``; every file that failed is listed in ``rejected`` with its own reason. One
/// bad file in a batch never fails the whole batch (T8 acceptance criterion 7: "accept
/// the valid files, and return a per-file list of rejected files each with its human
/// Chinese reason").
public struct AudioImportBatchResult: Sendable, Equatable {
    public let accepted: [ImportedAudioFile]
    public let rejected: [RejectedAudioFile]
}

/// Imports every request in `requests` independently against the same `packID`/
/// `environment` — see ``AudioImportBatchResult``.
public func importAudioFiles(
    _ requests: [AudioImportRequest],
    packID: String,
    environment: AudioImportEnvironment
) -> AudioImportBatchResult {
    var accepted: [ImportedAudioFile] = []
    var rejected: [RejectedAudioFile] = []
    for request in requests {
        switch importAudioFile(
            sourceURL: request.sourceURL, suggestedFileName: request.suggestedFileName,
            packID: packID, environment: environment)
        {
        case .success(let file):
            accepted.append(file)
        case .rejected(let reason):
            rejected.append(
                RejectedAudioFile(sourceFileName: request.suggestedFileName, reason: reason))
        }
    }
    return AudioImportBatchResult(accepted: accepted, rejected: rejected)
}
