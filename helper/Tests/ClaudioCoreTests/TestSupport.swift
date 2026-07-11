import Foundation

// Shared fixture helpers for the dependency-free harness (see `main.swift`).

/// Creates a unique temporary directory, runs `body` with its URL, and always removes it
/// afterwards (success or throw). Tests that touch the filesystem (`FileLock`, `doctor`
/// pack/settings probes) MUST use this instead of any real `~/.claudio` or `~/.claude`
/// path — those are the user's actual machine state.
@MainActor
func withTempDirectory<T>(_ body: (URL) throws -> T) rethrows -> T {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("claudio-tests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    return try body(directory)
}

/// Writes `contents` to `url`, creating the parent directory if needed.
@MainActor
func writeFixture(_ contents: String, to url: URL) {
    try? FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? contents.write(to: url, atomically: true, encoding: .utf8)
}

/// Creates a **FIFO** (named pipe) at `url` — the hostile-pack fixture for "this path has
/// something at it, but that something is not a file". Sound packs are third-party-distributed
/// content (ENGINEERING.md: 策展声音包), so a `manifest.json` / `stop.mp3` that is really a FIFO
/// is reachable, not hypothetical.
///
/// Two different behaviors ride on this fixture, and they are NOT the same strength of claim:
/// - `FileManager.fileExists(atPath:)` answers **`true`** for a FIFO — proven, and the whole
///   reason `doctor`/`play` must require ``regularFileExists(at:)`` instead (a pack whose
///   `stop.mp3` is a FIFO would otherwise report `.complete` and then play silence).
/// - `Data(contentsOf:)` does **not** hang on a FIFO on Darwin (measured: it throws `EACCES`).
///   `FileHandle(forReadingFrom:)` **does** hang forever (measured). So the manifest reader's
///   `O_NONBLOCK` + `fstat` gate is what turns "never blocks on hostile pack content" into our
///   own tested contract instead of a borrowed Foundation implementation detail — see
///   `SafeFileRead.swift`'s header.
///
/// Verifies the FIFO was really created (rather than swallowing an `mkfifo` failure), since a
/// silently-missing FIFO would let a caller's "rejected / notReady" assertion pass for the
/// wrong reason — never having exercised a FIFO at all (same reasoning as ``createSymlink``).
@MainActor
func makeFIFO(at url: URL) {
    try? FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let created = url.withUnsafeFileSystemRepresentation { pathPointer -> Bool in
        guard let pathPointer else { return false }
        return mkfifo(pathPointer, 0o644) == 0
    }
    expect(
        created,
        "makeFIFO: mkfifo failed at \(url.path) — a test relying on this fixture would silently"
            + " not be testing a FIFO (hostile pack content) at all")
}

/// Creates `linkURL` as a symbolic link pointing at `targetURL`, creating `linkURL`'s
/// parent directory if needed. Exists solely so tests can construct symlink-escape
/// fixtures (a pack directory, or a file inside one, that resolves outside its pack
/// root) to exercise ``isReallyContained(_:inside:)`` and friends. Production code must
/// never itself create symlinks — this helper is test-only.
///
/// Verifies the link was actually created (rather than swallowing a `createSymbolicLink`
/// failure via `try?`), since a silently-missing symlink would let a caller's "resolves to
/// nil / missing" assertion pass for the wrong reason — never having exercised a symlink
/// at all — and quietly stop testing what it claims to test (Codex review, second pass).
@MainActor
func createSymlink(at linkURL: URL, pointingTo targetURL: URL) {
    try? FileManager.default.createDirectory(
        at: linkURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: targetURL)
    expect(
        (try? FileManager.default.destinationOfSymbolicLink(atPath: linkURL.path)) != nil,
        "createSymlink: no real symlink exists at \(linkURL.path) after creation — a test"
            + " relying on this fixture would silently not be testing a symlink escape at all")
}
