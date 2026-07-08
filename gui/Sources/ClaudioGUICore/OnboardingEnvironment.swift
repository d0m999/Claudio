import ClaudioCore
import Foundation

/// Everything ``detectOnboardingState(environment:)`` needs, injectable for tests so
/// they never touch the real `~/.claude` / `~/.claudio` (mirrors `helper`'s
/// `DoctorEnvironment` / `FileLockSuite` pattern exactly).
///
/// **Never** override these by setting `$HOME` and calling the defaults — on Darwin,
/// `FileManager.homeDirectoryForCurrentUser` ignores `$HOME` and resolves the real
/// account home directory regardless (this exact mistake is recorded in this repo's
/// memory as a past incident). Tests must instead pass concrete fixture `URL`s for both
/// fields below, exactly as `helper`'s suites do with `withTempDirectory`.
public struct OnboardingEnvironment: Sendable {
    /// Where Claude Code's hook config lives. Defaults to the real
    /// `~/.claude/settings.json` (``ClaudioPaths/claudeSettingsFile``).
    public var settingsFile: URL

    /// Where the installed `claudio` helper binary lives — placed by the app install, not by
    /// `claudio install` (which only writes `settings.json` hooks). Defaults to the real
    /// `~/.claudio/bin/claudio` (``ClaudioPaths/claudioBinary``).
    public var claudioBinaryPath: URL

    public init(
        settingsFile: URL = ClaudioPaths.claudeSettingsFile,
        claudioBinaryPath: URL = ClaudioPaths.claudioBinary
    ) {
        self.settingsFile = settingsFile
        self.claudioBinaryPath = claudioBinaryPath
    }

    /// The directory `settingsFile` lives in — the same directory Claude Code itself
    /// creates (`~/.claude/`) the first time it runs. **Deliberately derived, not an
    /// independent stored field**: an independently-injectable `claudeDirectory` would
    /// let a test override `settingsFile` alone and silently leave `claudeDirectory`
    /// pointed at a different (possibly real) directory — a foot-gun this type is
    /// designed to make structurally impossible.
    public var claudeDirectory: URL {
        settingsFile.deletingLastPathComponent()
    }
}
