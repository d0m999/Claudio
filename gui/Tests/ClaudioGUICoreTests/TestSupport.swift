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

/// Creates an empty **non-executable** regular file at `url` (default perms, no execute
/// bit) — used to model a broken/partial helper install that `detectOnboardingState`
/// must still treat as `.helperMissing`.
@MainActor
func writeEmptyFile(at url: URL) {
    try? FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: url.path, contents: Data())
}

/// Creates a small, **non-empty executable** (`0o755`) regular file at `url` — the realistic
/// stand-in for the installed `claudio` binary, which ships executable alongside the app (the
/// app places it; `claudio install` itself only writes `settings.json` hooks, and could not
/// run at all unless this binary already existed and were executable). `detectOnboardingState`
/// requires a runnable *non-empty* regular file, so every fixture that means "the helper is
/// installed" must use this, not ``writeEmptyFile(at:)`` or ``writeEmptyExecutableFile(at:)``.
@MainActor
func writeExecutableFile(at url: URL) {
    try? FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    FileManager.default.createFile(
        atPath: url.path, contents: Data("#!/bin/sh\nexit 0\n".utf8),
        attributes: [.posixPermissions: 0o755])
}

/// Creates an empty (0-byte) but **executable** (`0o755`) regular file at `url` — models a
/// truncated / half-copied install where the execute bit is set but no real binary was ever
/// written. `detectOnboardingState` must still treat this as ``OnboardingState/helperMissing``,
/// since Claude Code could not actually run an empty file.
@MainActor
func writeEmptyExecutableFile(at url: URL) {
    try? FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    FileManager.default.createFile(
        atPath: url.path, contents: Data(), attributes: [.posixPermissions: 0o755])
}
