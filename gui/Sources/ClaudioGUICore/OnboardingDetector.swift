import ClaudioCore
import Foundation

/// Determines which ``OnboardingState`` currently applies, in the precedence order the
/// state machine is defined by (ENGINEERING.md T7: "六状态机"). Each check either
/// short-circuits to a terminal state or falls through to the next, more specific one:
///
/// 1. Is `~/.claude/` there at all? If not, nothing else matters — Claude Code itself
///    isn't installed (``OnboardingState/claudeCodeNotInstalled``).
/// 2. Is the helper binary installed *and runnable*? A missing binary — or a path that's
///    a directory, a non-executable regular file, or an empty 0-byte stub (all broken /
///    half-finished installs) — makes "already taken over" or "not yet taken over" both
///    moot, since Claude Code could never actually invoke it (``OnboardingState/helperMissing``).
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

    // A bare `fileExists` here would green-light a directory, an empty 0-byte placeholder,
    // or a non-executable file at the binary's path — all of which Claude Code would fail
    // to actually run. The three-part predicate that decides "runnable" now lives in
    // ``isRunnableHelperBinary(at:)`` (T17): DETECTION and INSTALLATION must agree on what a
    // usable helper is, and two inlined copies of the same three checks are two things that
    // can drift.
    guard isRunnableHelperBinary(at: environment.claudioBinaryPath) else {
        return .helperMissing
    }

    // 「在位」不等于「跑得起来」（T17，实测）。一个带 `com.apple.quarantine` 的二进制对上面那三条
    // 检查完全合格 —— 正规文件、非空、执行位也在 —— 但 Claude Code 的 hook 用 `/bin/sh -c` 执行它
    // 时，Gatekeeper 会当场 SIGKILL（实测 exit=137，零 stderr）。不挡住它，面板会亮绿点说「已经接
    // 好了」，而用户永远听不到一声响 —— `doctor` 已经把这种二进制报成硬失败了，面板不能继续撒谎。
    //
    // 回落 `.helperMissing` 而不是新开一个 state：它的 CTA 是「修复」→ takeOver →
    // `performFirstRunSetup` 的**无条件**解除隔离那一步，正好把它治好。用户点一下就好了，而不是被
    // 塞一句他无从下手的诊断。
    //
    // ⚠️ **这个检查只针对 destination**（`~/.claudio/bin/claudio`），**绝不能**下沉进
    // ``isRunnableHelperBinary(at:)``：app bundle 里那份 helper 在真实下载路径上**本来就带着章**，
    // 拿同一把尺子去量它会让 CTA 直接拒绝安装 —— 用户就永远装不上了。
    guard !hasQuarantineAttribute(at: environment.claudioBinaryPath) else {
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
