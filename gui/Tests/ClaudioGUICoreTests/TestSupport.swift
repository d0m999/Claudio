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

/// Async overload of ``withTempDirectory(_:)`` — identical setup/teardown, but for suites
/// whose body must `await` (the `AudioImportViewModel` drop handlers are `async`, T8). The
/// sync overload above stays for every non-async suite; an async closure at the call site
/// selects this one.
@MainActor
func withTempDirectory<T>(_ body: (URL) async throws -> T) async rethrows -> T {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("claudio-gui-tests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    return try await body(directory)
}

/// Writes `contents` to `url`, creating the parent directory if needed.
@MainActor
func writeFixture(_ contents: String, to url: URL) {
    try? FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? contents.write(to: url, atomically: true, encoding: .utf8)
}

/// Writes raw `data` to `url`, creating the parent directory if needed — the binary
/// counterpart to the `String` overload above, used by ``AudioImportSuite`` to plant
/// fixture files with real magic-byte headers (T8).
@MainActor
func writeFixture(_ data: Data, to url: URL) {
    try? FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? data.write(to: url, options: .atomic)
}

/// Creates a real symlink at `linkURL` pointing to `targetURL`, asserting it actually
/// took — mirrors `helper/Tests/ClaudioCoreTests/TestSupport.swift`'s `createSymlink`
/// exactly (duplicated per this package's established "duplicate rather than share test
/// helpers across packages" convention, see the header comment above).
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
