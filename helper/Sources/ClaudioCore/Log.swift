import Darwin
import Foundation

// `~/.claudio/claudio.log` — rolling diagnostic log for silent failure paths
// (ENGINEERING.md 决议 6, T6): `play` appends one line when it hits a real failure (spawn
// failure, a broken `play.lock`), and `doctor` reads the tail back to summarize recent
// trouble for the user. Every write is best-effort and non-blocking, mirroring `play.lock`'s
// "跳过式" philosophy (决议 5): a hook's synchronous call path must never block, so a
// diagnostic log write that can't immediately acquire ``ClaudioPaths/logLockFile`` simply
// skips rather than waiting — a lost diagnostic line is an acceptable trade for never
// blocking the hook.

/// One parsed `claudio.log` line.
public struct LogEntry: Sendable, Equatable {
    public let timestamp: Date
    public let event: String
    public let reason: String

    public init(timestamp: Date, event: String, reason: String) {
        self.timestamp = timestamp
        self.event = event
        self.reason = reason
    }
}

/// The only diagnostic failure detail a UI may project. The free-form ``LogEntry/reason``
/// remains a doctor/log implementation detail and must not cross into Usage presentation state.
public enum LogFailureCategory: String, Sendable, Equatable, CaseIterable {
    case playbackLaunch
    case playbackLock
    case receiptWrite
    case other
}

extension LogEntry {
    public var redactedFailureCategory: LogFailureCategory {
        if reason.hasPrefix("afplay ") { return .playbackLaunch }
        if reason.hasPrefix("play.lock ") { return .playbackLock }
        if reason.hasPrefix("回执写入失败") { return .receiptWrite }
        return .other
    }
}

/// Tab-delimited so `doctor`'s tail-read never has to guess where the timestamp/event end
/// and the free-form (possibly Chinese-prose) reason begins — a `reason` string is never
/// expected to itself contain a literal tab.
private let logFieldSeparator = "\t"

private func makeLogTimestampFormatter() -> ISO8601DateFormatter {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter
}

/// Appends one diagnostic line (`<ISO8601 timestamp>\t<event>\t<reason>`) to `logFile`,
/// rotating first if the file has grown past `maxBytes`. Returns `true` iff the line was
/// actually written.
///
/// The entire check-size → rotate-if-needed → append sequence runs inside a single
/// non-blocking lock (``ClaudioPaths/logLockFile``, via ``withNonBlockingLock(path:_:)``):
/// this is what makes concurrent callers (even across processes) never tear or interleave
/// a line (ENGINEERING.md T6 acceptance (3)) — a rotation's truncate-and-rewrite and
/// another call's append can never run at the same time. On contention this simply skips
/// (mirrors `play.lock`'s skip-style debounce, 决议 5) rather than blocking the hook path
/// this is invoked from.
@discardableResult
public func appendLogLine(
    event: String,
    reason: String,
    timestamp: Date = Date(),
    to logFile: URL,
    lockFile: URL = ClaudioPaths.logLockFile,
    maxBytes: Int = 512 * 1024
) -> Bool {
    let formatter = makeLogTimestampFormatter()
    let line =
        "\(formatter.string(from: timestamp))\(logFieldSeparator)\(event)\(logFieldSeparator)\(reason)\n"

    let result = withNonBlockingLock(path: lockFile.path) { () -> Bool in
        rotateIfNeeded(logFile: logFile, maxBytes: maxBytes)
        return rawAppend(line, to: logFile)
    }
    if case .ran(let wrote) = result {
        return wrote
    }
    return false
}

/// Truncates `logFile` down to (approximately) its last `maxBytes / 2`, dropping only whole
/// lines, once it has grown past `maxBytes` — keeps the log bounded without ever growing
/// unboundedly (ENGINEERING.md T6 acceptance (1)). A no-op when the file doesn't exist yet
/// or is still under the cap.
///
/// Must only ever be called from inside ``appendLogLine(event:reason:timestamp:to:lockFile:maxBytes:)``'s
/// lock — truncating the file while an unguarded append races against it could interleave
/// that append's bytes into the middle of the retained tail.
private func rotateIfNeeded(logFile: URL, maxBytes: Int) {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: logFile.path),
        let size = (attributes[.size] as? NSNumber)?.intValue, size > maxBytes
    else { return }
    guard let data = try? Data(contentsOf: logFile) else { return }

    let newline = UInt8(ascii: "\n")
    let tail = data.suffix(maxBytes / 2)
    // Drop any partial first line left over from the byte-level cut, keeping only whole
    // lines in the retained tail.
    guard let firstNewline = tail.firstIndex(of: newline) else {
        // No complete line survives the cut — safer to drop everything than to keep a
        // truncated fragment that would misparse as a corrupt entry.
        try? Data().write(to: logFile, options: .atomic)
        return
    }
    let wholeLines = tail[tail.index(after: firstNewline)...]
    try? Data(wholeLines).write(to: logFile, options: .atomic)
}

/// Appends `line` to `logFile` via a single `write(2)` syscall on an `O_APPEND`-opened
/// descriptor. POSIX guarantees the seek-to-end-of-file + write pair is atomic for a
/// regular file on a local filesystem, and re-resolves "end of file" fresh for every single
/// `write(2)` call (not just at `open`) — so even a rotation that just truncated the file
/// concurrently is still safe to append after: this call's `open` happens after the lock in
/// ``appendLogLine`` is held, so no rotation can be in flight while this runs. Best-effort:
/// returns `false` (rather than throwing) if the parent directory can't be created, the file
/// can't be opened, or the write is short/fails — callers treat that as "line not written"
/// rather than silently reporting success.
private func rawAppend(_ line: String, to logFile: URL) -> Bool {
    try? ensurePrivateDirectoryTree(at: logFile.deletingLastPathComponent())
    guard let data = line.data(using: .utf8) else { return false }
    let fd = open(logFile.path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
    guard fd != -1 else { return false }
    defer { close(fd) }
    let written = data.withUnsafeBytes { buffer in
        write(fd, buffer.baseAddress, buffer.count)
    }
    return written == data.count
}

/// Reads the last `maxLines` well-formed entries from `logFile`, tolerating a missing file
/// (nothing logged yet — the common case) or malformed lines (skipped, never crashes
/// `doctor`).
public func readRecentLogEntries(from logFile: URL, maxLines: Int = 5) -> [LogEntry] {
    guard let data = try? Data(contentsOf: logFile),
        !data.isEmpty
    else { return [] }

    return parseRecentLogEntries(data, maxLines: maxLines)
}

/// Parses an already bounded log snapshot. Usage settings calls this only after
/// ``readRegularFileBounded(at:maxBytes:followSymlink:)`` has accepted one regular-file
/// snapshot, so it can summarize diagnostics without reopening an unbounded or replaced path.
public func parseRecentLogEntries(_ data: Data, maxLines: Int = 5) -> [LogEntry] {
    guard maxLines > 0, let text = String(data: data, encoding: .utf8) else { return [] }

    let formatter = makeLogTimestampFormatter()
    let lines = text.split(separator: "\n", omittingEmptySubsequences: true)

    // Scan tail-to-head so a garbled trailing line can't eat into the `maxLines` budget
    // of well-formed entries and hide genuinely recent failures further back.
    var entries: [LogEntry] = []
    for line in lines.reversed() {
        guard entries.count < maxLines else { break }
        let fields = line.components(separatedBy: logFieldSeparator)
        guard fields.count >= 3, let timestamp = formatter.date(from: fields[0]) else {
            continue
        }
        let reason = fields[2...].joined(separator: logFieldSeparator)
        entries.append(LogEntry(timestamp: timestamp, event: fields[1], reason: reason))
    }
    return Array(entries.reversed())
}
