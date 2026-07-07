import Foundation

/// Single source of truth for every Claudio filesystem location (ENGINEERING.md 决议 4).
///
/// All Claudio-owned state (config / packs / bin / log / lock) lives under `~/.claudio/`
/// — a dot-folder with **no space in its path**. `Application Support` was rejected
/// because its path contains a space, and hook commands are written into
/// `settings.json` as a raw string executed via `/bin/sh -c` (confirmed by spike): a
/// space would get split by the shell and break the hook. `~/.claudio/` is safe under
/// both shell and argv execution models.
///
/// The **only** exception is `settings.json` itself, which stays where Claude Code put
/// it: `~/.claude/settings.json`.
public enum ClaudioPaths {
    /// The current user's home directory — the anchor for every path below.
    private static var home: URL {
        FileManager.default.homeDirectoryForCurrentUser
    }

    /// `~/.claudio/` — root of all Claudio-owned state.
    public static var root: URL {
        home.appendingPathComponent(".claudio", isDirectory: true)
    }

    /// `~/.claudio/config.json` — the single source of truth for user settings (GUI
    /// writes, `claudio play` only reads; see ENGINEERING.md 决议 6).
    public static var configFile: URL {
        root.appendingPathComponent("config.json")
    }

    /// `~/.claudio/packs/` — user-installed sound packs, one subdirectory per pack id.
    public static var packsDirectory: URL {
        root.appendingPathComponent("packs", isDirectory: true)
    }

    /// `~/.claudio/packs/<id>/` — a single user pack's directory.
    public static func packDirectory(id: String) -> URL {
        packsDirectory.appendingPathComponent(id, isDirectory: true)
    }

    /// `~/.claudio/bin/` — where `claudio install` places the helper binary at a fixed,
    /// idempotency-friendly path (ENGINEERING.md 决议 3, T2/T4).
    public static var binDirectory: URL {
        root.appendingPathComponent("bin", isDirectory: true)
    }

    /// `~/.claudio/claudio.log` — rolling diagnostic log (ENGINEERING.md 决议 6, T6).
    public static var logFile: URL {
        root.appendingPathComponent("claudio.log")
    }

    /// `~/.claudio/play.lock` — the non-blocking lock guarding `play`'s skip-style
    /// debounce (ENGINEERING.md 决议 1 + 5, T5). See ``FileLock``.
    public static var lockFile: URL {
        root.appendingPathComponent("play.lock")
    }

    /// `~/.claude/settings.json` — the only Claudio-relevant path outside `~/.claudio/`.
    public static var claudeSettingsFile: URL {
        home
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("settings.json")
    }
}
