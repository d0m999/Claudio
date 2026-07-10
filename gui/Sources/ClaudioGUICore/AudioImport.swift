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
/// `sourceURL` again after step 3 reads its bytes — every check from there on (duration in
/// step 5, the write in step 6) operates on that already-read `Data`, so the copy is the
/// only thing anything downstream ever touches (acceptance criterion 1: "never reference
/// the original path").
///
/// ## Order of checks (and why)
/// 1. **Destination-name/path safety** (``DropRejectionReason/pathTraversal``) — reused,
///    audited containment logic (`isSafePackID` + `safePackFileURL`), checked before any
///    disk I/O on the dropped file's *content*, since a hostile filename is a security
///    concern independent of what the file contains.
/// 2. **Built-in-pack collision** (``DropRejectionReason/overwritesBuiltin(packID:)``) —
///    still no content I/O; see that case's doc comment for the exact semantics.
/// 3. **Bound source acquisition — symlink refusal, regular-file whitelist, size cap, and
///    the byte read, all against one file descriptor**
///    (``DropRejectionReason/copyFailed(reason:)`` for a symlink or non-regular source,
///    ``DropRejectionReason/oversize(actualBytes:maxBytes:)`` for an oversized one).
///    ``readRegularFileSource(at:maxBytes:)`` opens `sourceURL` exactly once with
///    `O_NOFOLLOW` (a symlink source fails the open, never dereferenced — its target could
///    be arbitrarily large, a size-cap bypass) and `O_NONBLOCK` (a FIFO/device never blocks
///    the open), `fstat`s *that descriptor* to require a real regular file (a directory,
///    FIFO, socket, or device is refused before any read — reading a FIFO could block
///    forever or stream unbounded bytes), and reads at most `maxFileSizeBytes + 1` bytes
///    from it. Binding the type/size checks and the read to the same descriptor is the
///    point: a `stat`-then-reopen pair left a metadata-to-read TOCTOU window (a validated
///    small regular file swapped for a FIFO/symlink/grown file before the reopen); one open
///    closes it, and the bounded read means a still-growing source can neither exhaust
///    memory nor slip past the cap.
/// 4. **Content-sniffed format whitelist** (``DropRejectionReason/nonWhitelistFormat``) —
///    the bytes acquired in step 3 must be one of the whitelisted audio containers. This
///    exact `Data` is what step 6 persists — `sourceURL` is never read a second time.
/// 5. **Duration cap** (``DropRejectionReason/overDuration(actualSeconds:maxSeconds:)``)
///    — probed on the validated bytes already read in step 3 (written to a throwaway temp
///    file for the AVFoundation probe, never re-reading `sourceURL`), before copying, so a
///    too-long file is never written into the user's pack directory at all — and the bytes
///    measured are exactly the bytes step 6 persists, closing the TOCTOU gap a second read
///    of `sourceURL` here would open.
/// 6. Only if all five pass: write the `Data` already read in step 3 → the validated
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

    // 3. Acquire the source bytes safely — a SINGLE `open()` whose file descriptor every
    // subsequent check is bound to, so nothing swapped in at `sourceURL` between checks can
    // change what gets validated versus what gets read. This is the whole ballgame for the
    // drag-in threat model. A `stat`-then-reopen pair (what this used to be) left a
    // metadata-to-read TOCTOU window: a source validated as a small regular file could be
    // swapped — by a same-user concurrent writer, this codebase's established threat model —
    // for a FIFO (`Data(contentsOf:)` then blocks the read forever), a symlink (bypasses the
    // size cap via its target), or a grown file (slips past the cap) before the reopen. See
    // ``readRegularFileSource(at:maxBytes:)``: one `open(O_NOFOLLOW | O_NONBLOCK)`, one
    // `fstat` of *that* descriptor requiring a real regular file, and a read bounded to
    // `maxFileSizeBytes + 1` bytes — check and read now inseparable, and the read can neither
    // hang, exhaust memory, nor overrun the cap. The returned bytes are the only bytes
    // anything downstream touches: `sourceURL` is opened exactly once for this function's
    // whole lifetime (acceptance criterion 1: never reference the original path once
    // validation starts consuming its content).
    let data: Data
    switch readRegularFileSource(at: sourceURL, maxBytes: environment.limits.maxFileSizeBytes) {
    case .success(let bytes):
        data = bytes
    case .symbolicLink:
        // A symlink source is refused outright, never dereferenced — its target could be
        // arbitrarily large (a size-cap bypass) or point anywhere. `O_NOFOLLOW` made the
        // open itself fail, so this is caught before a single target byte is read.
        return .rejected(
            .copyFailed(
                reason: "这个文件是个链接（symlink），Claudio 只收音频文件本身，请直接拖入真正的文件再试一次"))
    case .notRegularFile:
        // A directory, FIFO/named pipe, socket, or character/block device — everything that
        // is not a plain regular file, refused by an explicit whitelist (`fstat` said the
        // opened descriptor is not `S_IFREG`), matching the same allow-list stance the
        // destination-path (step 1) and content-format (step 4) checks take. Reading such a
        // source could block forever (a FIFO with no writer) or stream unbounded bytes;
        // `O_NONBLOCK` on the open plus this `fstat` gate rule it out before any read.
        return .rejected(
            .copyFailed(
                reason: "这个不是普通文件（可能是文件夹或特殊文件），Claudio 只收音频文件本身，请直接拖入真正的音频文件再试一次"))
    case .oversize(let actualBytes):
        return .rejected(
            .oversize(actualBytes: actualBytes, maxBytes: environment.limits.maxFileSizeBytes))
    case .unreadable:
        // A genuine open/stat/read failure (vanished, permission revoked, or an unopenable
        // special file such as a socket). Reported as its real cause — `.copyFailed`, never
        // folded into `.nonWhitelistFormat`, which is a different failure with a different
        // cause (never silently misreport the real cause).
        return .rejected(.copyFailed(reason: "读不到这个文件"))
    }

    // 4. Content-sniffed format whitelist — the bytes acquired in step 3 must be one of the
    // whitelisted audio containers. This exact `data` is what step 6 persists; `sourceURL`
    // is never read again after step 3.
    guard let format = sniffAudioFormat(data) else {
        return .rejected(.nonWhitelistFormat)
    }

    // 5. Duration cap — probed on the *validated bytes already read in step 3*, never by
    // re-reading `sourceURL` a second time. Duration probing (AVFoundation, injected) needs
    // a file URL, so the already-read `data` is written to a throwaway temp file *outside*
    // the user pack directory, probed there, and removed (via `defer`, on every exit path).
    // Two properties fall out of this that probing `sourceURL` directly did not have:
    //   • This function truly never touches `sourceURL` again after step 3 read it — the
    //     header/criterion-1 invariant ("never reference the original path") now holds for
    //     the *whole* remaining pipeline, not just after a successful return.
    //   • The bytes whose duration is measured are byte-for-byte the bytes step 6 persists.
    //     Probing `sourceURL` reopened the original path, leaving a same-user TOCTOU window:
    //     a short, in-cap file swapped in for the probe could pass the duration gate while
    //     the longer bytes already read in step 3 — the ones actually written in step 6 —
    //     sailed into the pack unmeasured.
    // The temp file is named with the validated destination's basename so AVFoundation gets
    // the same extension hint it would for the real file.
    let probeDirectory = fileManager.temporaryDirectory.appendingPathComponent(
        "claudio-duration-probe-\(UUID().uuidString)", isDirectory: true)
    let probeURL = probeDirectory.appendingPathComponent(destinationURL.lastPathComponent)
    defer { try? fileManager.removeItem(at: probeDirectory) }
    do {
        try fileManager.createDirectory(at: probeDirectory, withIntermediateDirectories: true)
        try data.write(to: probeURL, options: .atomic)
    } catch {
        return .rejected(.copyFailed(reason: error.localizedDescription))
    }
    let duration = environment.durationProbe.probeDuration(of: probeURL)
    guard let duration, duration <= environment.limits.maxDurationSeconds else {
        return .rejected(
            .overDuration(actualSeconds: duration, maxSeconds: environment.limits.maxDurationSeconds))
    }

    // 6. Persist. Deliberately `data.write(to:options:.atomic)` — the exact bytes read in
    // step 3 and content-sniffed in step 4 — rather than `FileManager.copyItem(at:to:)`.
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
            // The exact byte count read in step 3 and persisted in step 6 — more accurate
            // than the pre-read `fstat` size (which a mid-read grow could have made stale).
            fileSizeBytes: data.count,
            duration: duration
        ))
}

// MARK: - Bound source read

/// The outcome of ``readRegularFileSource(at:maxBytes:)`` — either the source's bytes or the
/// specific reason it was refused before/while reading. Every non-`.success` case maps to a
/// ``DropRejectionReason`` at the call site in
/// ``importAudioFile(sourceURL:suggestedFileName:packID:environment:)``.
private enum RegularFileSourceOutcome {
    /// A plain regular file, fully read — at most `maxBytes` bytes.
    case success(Data)
    /// The source's final path component is a symbolic link; the open refused to follow it.
    case symbolicLink
    /// The opened descriptor is not a regular file (directory, FIFO, socket, or device).
    case notRegularFile
    /// The source is larger than `maxBytes` — carries the observed byte count.
    case oversize(actualBytes: Int)
    /// The source could not be opened/`fstat`'d/read for any other reason.
    case unreadable
}

/// Opens `url` exactly once and returns its bytes only if it is a regular file no larger than
/// `maxBytes` — with the symlink refusal, the regular-file whitelist, the size cap, and the
/// byte read all bound to the *same* file descriptor. Nothing swapped in at the path after the
/// open can change what is validated versus what is read, closing the metadata-to-read TOCTOU
/// that a `stat`-then-reopen pair leaves open (T8 codex review of 9b6fedb).
///
/// - `O_NOFOLLOW`: a final-component symlink fails the open with `ELOOP` (`.symbolicLink`),
///   never dereferenced — a symlink's target could be arbitrarily large (a size-cap bypass) or
///   point anywhere.
/// - `O_NONBLOCK`: opening a FIFO with no writer, or a device, returns immediately instead of
///   blocking this background import task forever; such sources are then refused by the
///   `fstat` regular-file gate (`.notRegularFile`) before any byte is read.
/// - Bounded read: at most `maxBytes + 1` bytes are ever held in memory. One byte past the cap
///   is enough to prove a source is oversized (`.oversize`) without loading an arbitrarily
///   large — or still-growing — file, so a same-user mid-read grow can neither exhaust memory
///   nor slip past the cap.
private func readRegularFileSource(at url: URL, maxBytes: Int) -> RegularFileSourceOutcome {
    var openErrno: Int32 = 0
    let fd: Int32 = url.withUnsafeFileSystemRepresentation { pathPointer in
        guard let pathPointer else { openErrno = EINVAL; return -1 }
        let result = open(pathPointer, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        if result < 0 { openErrno = errno }
        return result
    }
    if fd < 0 {
        if openErrno == ELOOP { return .symbolicLink }
        // open() failed for a non-symlink reason. A socket (and any other special file whose
        // open() fails outright — unlike a FIFO/directory/device, whose open succeeds and is
        // caught by the `fstat` gate below) would otherwise fall to `.unreadable`'s generic
        // message, losing the specific "not a regular file" guidance the old metadata path
        // gave it. One `lstat` here — cold error path only, used solely to pick the rejection
        // MESSAGE and never to gate the read (both branches still reject; nothing is ever read
        // or written either way) — restores that guidance for a genuinely non-regular source,
        // while a vanished or permission-denied *regular* file stays `.unreadable` (the honest
        // "can't read this file").
        var linkStatus = stat()
        let isNonRegular = url.withUnsafeFileSystemRepresentation { pathPointer -> Bool in
            guard let pathPointer else { return false }
            return lstat(pathPointer, &linkStatus) == 0 && (linkStatus.st_mode & S_IFMT) != S_IFREG
        }
        return isNonRegular ? .notRegularFile : .unreadable
    }
    defer { close(fd) }

    var status = stat()
    guard fstat(fd, &status) == 0 else { return .unreadable }
    guard (status.st_mode & S_IFMT) == S_IFREG else { return .notRegularFile }
    // Metadata oversize fast-path — bound to the opened regular file, so the size tested is
    // the size of the exact object the read below consumes.
    if status.st_size > maxBytes {
        return .oversize(actualBytes: Int(clamping: status.st_size))
    }

    // Read the descriptor in bounded chunks, never holding more than `maxBytes + 1` bytes.
    // `maxBytes + 1` would trap if `maxBytes` were `Int.max` (an "effectively unlimited" cap a
    // public caller could set); saturate instead — at `Int.max` no file can exceed the cap, so
    // reading to EOF is the whole intent. Reaching here means `status.st_size <= maxBytes` (the
    // fast-path above didn't fire), so the reserve hint is `<= maxBytes` and never overflows.
    let readCap = maxBytes == Int.max ? Int.max : maxBytes + 1
    var data = Data()
    data.reserveCapacity(Int(clamping: status.st_size))
    let chunkSize = 1 << 16  // 64 KiB
    var buffer = [UInt8](repeating: 0, count: chunkSize)
    while data.count < readCap {
        let want = min(chunkSize, readCap - data.count)
        let bytesRead = buffer.withUnsafeMutableBytes { raw -> Int in
            var result = read(fd, raw.baseAddress, want)
            while result < 0 && errno == EINTR { result = read(fd, raw.baseAddress, want) }
            return result
        }
        if bytesRead < 0 { return .unreadable }
        if bytesRead == 0 { break }  // EOF
        data.append(contentsOf: buffer[0..<bytesRead])
    }
    // A source that grew past the cap between the `fstat` above and here is caught by the
    // one-byte-over read — never fully loaded, never persisted.
    if data.count > maxBytes {
        return .oversize(actualBytes: data.count)
    }
    return .success(data)
}

/// Whether `packID` currently resolves to a pack directory **only** via the bundled
/// (built-in) root — i.e. the user has no pack of their own at this id yet. This is the
/// exact case ``DropRejectionReason/overwritesBuiltin(packID:)`` blocks.
///
/// **Reconciling with ENGINEERING.md「工程落地细节 ②（声音包存储根 + 查找顺序）」** (which
/// explicitly *allows* a user pack to override a same-id bundled pack at *selection* time —
/// `resolvePackDirectory` checks the user root first, by design): that decision is about
/// which directory `claudio play` resolves to once a user copy already exists. It says
/// nothing about whether drag-and-drop may *silently create* that user copy's very first
/// file in the first place. T8's
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
