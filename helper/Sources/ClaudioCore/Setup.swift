import Foundation

/// `claudio setup` — v1 Terminal 首次安装自举（ENGINEERING.md T17, Distribution Plan「接管
/// 机制」v1 过渡）.
///
/// Closes the gap a codex review of T11+T12 (commits 10f00cf/f31987b) surfaced: `release.yml`
/// ships the helper CLI + `minimal-chime` inside `Claudio.app`'s `Contents/Resources/`, but
/// nothing ever copies either out to `~/.claudio/` — "the app install" `Paths.swift`
/// documents as owning that step doesn't exist anywhere in code, and the real menu bar
/// shell that would trigger it (T15) hasn't landed. This is the interim, Terminal-runnable
/// substitute: run once from *inside* the app bundle (e.g.
/// `/Applications/Claudio.app/Contents/Resources/bin/claudio setup`) and it places the
/// binary, seeds a default pack selection, and installs hooks — the same three side effects
/// T15's onboarding CTA is expected to trigger automatically once it exists.

// MARK: - Environment (injectable, mirrors `PlayEnvironment`/`DoctorEnvironment`)

public struct SetupEnvironment: Sendable {
    /// The absolute, symlink-resolved path to the binary currently executing `claudio
    /// setup`. Real callers derive this from `CommandLine.arguments[0]` via
    /// ``currentExecutablePath(arguments:currentDirectory:)`` — there's no meaningful
    /// static default, since it's inherently "wherever this process happens to be running
    /// from".
    public let executablePath: URL
    public let claudioBinaryDestination: URL
    public let userPacksDirectory: URL
    public let configFile: URL
    public let settingsFile: URL
    public let lockFile: URL

    public init(
        executablePath: URL,
        claudioBinaryDestination: URL = ClaudioPaths.claudioBinary,
        userPacksDirectory: URL = ClaudioPaths.packsDirectory,
        configFile: URL = ClaudioPaths.configFile,
        settingsFile: URL = ClaudioPaths.claudeSettingsFile,
        lockFile: URL = ClaudioPaths.lockFile
    ) {
        self.executablePath = executablePath
        self.claudioBinaryDestination = claudioBinaryDestination
        self.userPacksDirectory = userPacksDirectory
        self.configFile = configFile
        self.settingsFile = settingsFile
        self.lockFile = lockFile
    }
}

/// Resolves the absolute, symlink-resolved path of the currently-running executable from
/// `argv[0]` — absolute if invoked with a full path (the common case when a user pastes
/// the path printed by `docs/distribution.md`'s Terminal instructions; also true once
/// re-invoked from the fixed `~/.claudio/bin/claudio` destination), relative-to-`currentDirectory`
/// if invoked as `./claudio` or `../some/dir/claudio`.
///
/// **Known gap (Codex adversarial review, `/ship` pre-landing, tracked in TODOS.md):**
/// a bare name with no `/` at all (e.g. plain `claudio`, found via a `$PATH` lookup the
/// *shell* performed) is NOT actually resolved against `PATH` here — it falls into the
/// same branch as `./claudio` and gets treated as relative to `currentDirectory`, which is
/// wrong: the shell may have found the real binary somewhere else on `PATH` entirely. This
/// only misresolves when Claudio isn't invoked with a `/` in the command at all, which
/// `docs/distribution.md`'s own instructions never do — but it's still a latent bug for
/// anyone who's added `~/.claudio/bin` to their own `PATH` and runs bare `claudio setup`
/// from an unrelated directory.
public func currentExecutablePath(
    arguments: [String] = CommandLine.arguments,
    currentDirectory: String = FileManager.default.currentDirectoryPath
) -> URL {
    let raw = arguments[0]
    let url =
        raw.hasPrefix("/")
        ? URL(fileURLWithPath: raw)
        : URL(fileURLWithPath: raw, relativeTo: URL(fileURLWithPath: currentDirectory, isDirectory: true))
    return url.resolvingSymlinksInPath()
}

// MARK: - Outcome / errors

public enum SetupOutcome: Sendable, Equatable {
    /// `copiedPacks` lists the bundled-pack ids that were newly copied into
    /// `userPacksDirectory` this run (empty if none were new, or if setup wasn't running
    /// from inside a bundle at all). `selectedPack` is non-nil only when this run
    /// established a *fresh* `config.json` (an existing one, and its `selected_pack`, are
    /// always left untouched).
    case completed(
        copiedBinary: Bool, copiedPacks: [String], selectedPack: String?,
        hooksOutcome: InstallOutcome)
}

public enum SetupError: Error, Sendable, Equatable, CustomStringConvertible {
    case binaryCopyFailure(reason: String)
    case packCopyFailure(reason: String)
    case useFailure(UseError)
    case installFailure(SettingsUpdateError)

    public var description: String {
        switch self {
        case .binaryCopyFailure(let reason):
            "复制二进制到 ~/.claudio/bin/claudio 失败：\(reason)"
        case .packCopyFailure(let reason):
            "复制内置声音包失败：\(reason)"
        case .useFailure(let error):
            "首次默认选包失败：\(error.description)"
        case .installFailure(let error):
            "写 settings.json hooks 失败：\(error.description)"
        }
    }
}

// MARK: - Entry point

/// Runs the full first-run bootstrap. Safe to call repeatedly (idempotent): if
/// `executablePath` is already `claudioBinaryDestination` (i.e. this is a rerun of the
/// already-installed copy, not a fresh run from inside the app bundle), the binary/pack
/// copy steps are skipped entirely and only the hooks step runs — reusing
/// ``installClaudioHooks(settingsFile:claudioBinaryPath:lockFile:)``'s own idempotency.
public func performFirstRunSetup(environment: SetupEnvironment) -> Result<SetupOutcome, SetupError> {
    let alreadyInstalled =
        environment.executablePath.standardizedFileURL.path
        == environment.claudioBinaryDestination.standardizedFileURL.path

    var copiedBinary = false
    var copiedPackIDs: [String] = []

    if !alreadyInstalled {
        // Copying the binary must NOT be gated on whether a sibling `packs/` exists
        // (Codex + Claude adversarial review, /ship pre-landing: three independent passes
        // converged on this — one verified it empirically in an isolated scratch package).
        // The earlier version nested this inside `if directoryExists(at: bundledPacksDirectory)`,
        // so any invocation that isn't literally running from inside a fully-assembled app
        // bundle (a raw dev build, or a bundle whose Resources/packs/ is missing/corrupted)
        // would skip the binary copy ENTIRELY yet still fall through to
        // `installClaudioHooks` below — writing real hook entries pointing at a
        // `claudioBinaryDestination` that doesn't exist, returning `.success`, and (per
        // `printSetupSummary`) printing a message claiming the binary is "already there."
        // Every subsequent Claude Code event would then silently fail to play a sound with
        // zero signal anything was wrong — the exact "install completes but stays broken"
        // failure class T17 exists to eliminate. Unconditionally attempting the copy here
        // means a real failure now surfaces as a real `SetupError`, never a false success.
        switch copySelfToFixedLocation(
            from: environment.executablePath, to: environment.claudioBinaryDestination
        ) {
        case .success: copiedBinary = true
        case .failure(let error): return .failure(error)
        }

        // Bundled packs ship as a sibling of the binary's containing directory:
        // `Contents/Resources/bin/claudio` ↔ `Contents/Resources/packs/` (release.yml).
        // Its mere presence is also how `setup` tells "running from inside a bundle" apart
        // from "running some other copy of this binary from an arbitrary directory" — if
        // there's no sibling `packs/`, there's no bundled pack to copy, but (unlike the
        // binary above) that's genuinely fine: the user's existing/future packs are
        // untouched either way.
        let bundledPacksDirectory =
            environment.executablePath
            .deletingLastPathComponent()  // .../Contents/Resources/bin
            .deletingLastPathComponent()  // .../Contents/Resources
            .appendingPathComponent("packs", isDirectory: true)  // .../Contents/Resources/packs

        if directoryExists(at: bundledPacksDirectory) {
            let packIDs =
                ((try? FileManager.default.contentsOfDirectory(atPath: bundledPacksDirectory.path))
                    ?? []
                ).sorted()
            if !packIDs.isEmpty {
                // Hoisted out of the per-pack loop below: the destination directory never
                // changes across iterations, so creating it once (idempotent — `createDirectory`
                // no-ops if it already exists) does the same work as calling it once per pack,
                // minus the redundant mkdir/stat syscalls.
                do {
                    try FileManager.default.createDirectory(
                        at: environment.userPacksDirectory, withIntermediateDirectories: true)
                } catch {
                    return .failure(
                        .packCopyFailure(reason: "创建 ~/.claudio/packs 失败：\(error.localizedDescription)")
                    )
                }
            }
            for id in packIDs {
                let source = bundledPacksDirectory.appendingPathComponent(id, isDirectory: true)
                guard directoryExists(at: source) else { continue }
                let destination = environment.userPacksDirectory.appendingPathComponent(
                    id, isDirectory: true)
                // Never clobber a same-id pack the user already has (could be their own
                // customized copy) — mirrors `resolvePackDirectory`'s "user root wins"
                // rule by simply not overwriting it in the first place.
                guard !FileManager.default.fileExists(atPath: destination.path) else { continue }
                do {
                    try FileManager.default.copyItem(at: source, to: destination)
                    copiedPackIDs.append(id)
                } catch {
                    return .failure(
                        .packCopyFailure(reason: "\(id)：\(error.localizedDescription)"))
                }
            }
        }
    }

    var selectedPack: String?
    if !FileManager.default.fileExists(atPath: environment.configFile.path) {
        // Deliberately scans `userPacksDirectory` fresh rather than reusing `copiedPackIDs`
        // (red team / `/ship` pre-landing review finding): `copiedPackIDs` only reflects
        // packs copied *this* invocation, so a pack that already exists from an earlier —
        // possibly interrupted — `setup` run (or one the user placed there manually) would
        // never get selected, and `alreadyInstalled` re-runs (which skip the copy step
        // entirely) could never establish a default pack at all. Scanning disk directly
        // fixes both: any pack that's actually there and resolvable is eligible, regardless
        // of which run put it there.
        let availablePackIDs =
            ((try? FileManager.default.contentsOfDirectory(
                atPath: environment.userPacksDirectory.path)) ?? []
            )
            .sorted()
            .filter {
                directoryExists(
                    at: environment.userPacksDirectory.appendingPathComponent(
                        $0, isDirectory: true))
            }
        if let firstAvailable = availablePackIDs.first {
            switch selectPack(
                firstAvailable, configFile: environment.configFile,
                userPacksDirectory: environment.userPacksDirectory,
                lockFile: environment.lockFile)
            {
            case .success(.selected(let id)): selectedPack = id
            case .failure(let error): return .failure(.useFailure(error))
            }
        }
    }

    switch installClaudioHooks(
        settingsFile: environment.settingsFile,
        claudioBinaryPath: environment.claudioBinaryDestination.path,
        lockFile: environment.lockFile
    ) {
    case .success(let hooksOutcome):
        return .success(
            .completed(
                copiedBinary: copiedBinary, copiedPacks: copiedPackIDs, selectedPack: selectedPack,
                hooksOutcome: hooksOutcome))
    case .failure(let error):
        return .failure(.installFailure(error))
    }
}

/// Copies the currently-running binary to its fixed destination and marks it executable.
/// Replaces an existing destination file (e.g. re-running `setup` after an app update) —
/// `~/.claudio/bin/claudio` holds no user data, so overwriting it is always safe.
private func copySelfToFixedLocation(from source: URL, to destination: URL) -> Result<Void, SetupError> {
    let fileManager = FileManager.default
    do {
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: source, to: destination)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
        return .success(())
    } catch {
        return .failure(.binaryCopyFailure(reason: error.localizedDescription))
    }
}
