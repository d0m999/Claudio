import ClaudioCore
import Foundation

/// Determines which ``OnboardingState`` currently applies, in the precedence order the
/// state machine is defined by (ENGINEERING.md T7: "六状态机"). Each check either
/// short-circuits to a terminal state or falls through to the next, more specific one:
///
/// 1. Is `~/.claude/` there at all? If not, nothing else matters — Claude Code itself
///    isn't installed (``OnboardingState/claudeCodeNotInstalled``).
/// 2. Is the helper binary installed? A missing binary makes "already taken over" or
///    "not yet taken over" both moot (``OnboardingState/helperMissing``).
/// 3. Can we even write `settings.json`? (``probeSettingsWritable(settingsFile:)``,
///    reused verbatim — single source of truth with `installClaudioHooks` itself.)
/// 4. Can we read/parse it? (``detectHookInstallStatus(settingsFile:claudioBinaryPath:)``,
///    likewise reused verbatim, **read-only** — this function never calls
///    `installClaudioHooks`/`uninstallClaudioHooks`, which would have real write side
///    effects, just to answer "is it installed?".)
/// 5. Only once all four prerequisites hold does whether the hook is actually present
///    decide ``OnboardingState/notInstalled`` vs. ``OnboardingState/installed``.
///
/// This function is a **pure function of `environment`'s current on-disk contents** —
/// calling it again after the environment's files change (a fix applied, a CTA action
/// completed) is the state machine's entire "transition" rule (T7 acceptance criterion
/// 1). See ``OnboardingViewModel/refresh()``.
public func detectOnboardingState(
    environment: OnboardingEnvironment = OnboardingEnvironment()
) -> OnboardingState {
    let fileManager = FileManager.default

    var claudeDirectoryIsDirectory: ObjCBool = false
    let claudeDirectoryExists = fileManager.fileExists(
        atPath: environment.claudeDirectory.path, isDirectory: &claudeDirectoryIsDirectory)
    guard claudeDirectoryExists, claudeDirectoryIsDirectory.boolValue else {
        return .claudeCodeNotInstalled
    }

    guard fileManager.fileExists(atPath: environment.claudioBinaryPath.path) else {
        return .helperMissing
    }

    if case .notWritable(let reason) = probeSettingsWritable(settingsFile: environment.settingsFile)
    {
        return .settingsNotWritable(reason: reason)
    }

    switch detectHookInstallStatus(
        settingsFile: environment.settingsFile,
        claudioBinaryPath: environment.claudioBinaryPath.path
    ) {
    case .installed:
        return .installed
    case .notInstalled:
        return .notInstalled
    case .settingsUnreadable(let error):
        return .settingsParseFailure(reason: error.description)
    }
}
