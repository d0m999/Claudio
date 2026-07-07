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
