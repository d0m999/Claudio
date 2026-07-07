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
