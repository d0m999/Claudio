import Foundation

// Shared fixture helpers for the dependency-free harness (see `main.swift`). Mirrors
// `helper/Tests/ClaudioCoreTests/TestSupport.swift` — duplicated rather than shared
// across packages, since each package's test executable is private to its own build
// (same reasoning `helper/` already established).

/// Creates a unique temporary directory, runs `body` with its URL, and always removes it
/// afterwards (success or throw). Every test that touches the filesystem MUST use this
/// instead of any real `~/.claudio`/`~/.claude` path — see ``OnboardingEnvironment``'s
/// doc comment on why `$HOME` overrides don't work on Darwin.
@MainActor
func withTempDirectory<T>(_ body: (URL) throws -> T) rethrows -> T {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("claudio-gui-tests-\(UUID().uuidString)", isDirectory: true)
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

/// Creates an empty regular file at `url` (e.g. standing in for the installed `claudio`
/// binary), creating its parent directory if needed.
@MainActor
func writeEmptyFile(at url: URL) {
    try? FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: url.path, contents: Data())
}
