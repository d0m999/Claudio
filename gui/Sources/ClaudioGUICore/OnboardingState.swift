import Foundation

/// The complete onboarding state machine (ENGINEERING.md T7): every state the panel can
/// be in before/around "has Claudio taken over Claude Code's hooks yet?", each with a
/// human, reassurance-toned next step — never engineering phrasing like "写入 hook 到
/// settings.json" (T7 acceptance criterion 3).
///
/// This is a **pure value type**: it carries no logic and touches no disk. Everything
/// that decides *which* case applies lives in ``detectOnboardingState(environment:)``;
/// everything that decides *what the panel says* lives in ``onboardingCopy(for:)``. That
/// split is what T7's acceptance criterion 1 means by "状态判定与转移下沉 view-model /
/// state fixture 测": both halves are independently unit-testable without SwiftUI.
public enum OnboardingState: Sendable, Equatable {
    /// `~/.claude/` itself doesn't exist — Claude Code isn't installed (or isn't the
    /// version that creates that directory). Not an app error — a neutral, non-blocking
    /// prerequisite (DESIGN.md「错误态用色（关键约束）」: "非阻断提示...用中性 surface-2 +
    /// text-2，不上真红").
    case claudeCodeNotInstalled

    /// `~/.claudio/bin/claudio` — the fixed install path (ENGINEERING.md「工程落地细节 ③」/T4;
    /// *not* 决议 3, which is the per-event on/off switch) — doesn't exist on disk. A real
    /// app self-error (DESIGN.md「错误态用色（关键约束）」lists "helper 缺失" alongside
    /// "settings 不可写/解析失败" as the three cases that get **真红 `#FF453A`**).
    case helperMissing

    /// ``probeSettingsWritable(settingsFile:)`` reports `.notWritable`. A real app
    /// self-error (真红).
    case settingsNotWritable(reason: String)

    /// `settings.json` exists but can't be read/parsed, or its `hooks` section has an
    /// unexpected shape — the same classification ``installClaudioHooks`` itself would
    /// abort on. A real app self-error (真红).
    case settingsParseFailure(reason: String)

    /// Everything checked out, but claudio's hook isn't (fully) present yet. The
    /// "take over Claude Code" call-to-action state — brand `clay` accent, not an error.
    case notInstalled

    /// Claudio's hook is present for all four core events. Renders the green ● header
    /// dot (T7 acceptance criterion 2) — the only state that does.
    case installed
}

/// The semantic color family a state renders under (DESIGN.md token names, not literal
/// hex — the executable `ClaudioGUI` target maps these to the actual `Color` values so
/// this Foundation-only module never imports SwiftUI).
public enum OnboardingAccent: Sendable, Equatable {
    /// `text-2` / `surface-2` — a non-blocking prerequisite, not an error.
    case neutral
    /// `error` token, `#FF453A` (dark) / `#E0453A` (light) — real app self-error.
    case error
    /// `clay` brand token — an actionable, non-error call-to-action.
    case brand
    /// `success` token, `#34C759` (dark) / `#2FA24E` (light) — the terminal good state.
    case success
}

extension OnboardingState {
    /// Whether the panel header shows the green "接管中" dot. Per T7 acceptance
    /// criterion 2, this is `true` for exactly one state.
    public var showsHeaderTakenOverDot: Bool {
        self == .installed
    }

    /// Whether this state represents a real app self-error (真红 `#FF453A`), as opposed
    /// to a neutral prerequisite (``claudeCodeNotInstalled``) or an actionable-but-normal
    /// state (``notInstalled``/``installed``). Mirrors DESIGN.md「错误态用色（关键约束）」
    /// exactly: "app 自身错误（settings 不可写 / 解析失败 / helper 缺失）用 UI 语义
    /// error #FF453A...非阻断提示（如 Claude Code 未装）用中性...不上真红".
    public var isAppSelfError: Bool {
        switch self {
        case .helperMissing, .settingsNotWritable, .settingsParseFailure: true
        case .claudeCodeNotInstalled, .notInstalled, .installed: false
        }
    }

    /// The state's semantic accent family — drives the onboarding icon-block color
    /// (DESIGN.md "onboarding 卡" component: "44px 图标块（态色 15% 底 + 态色字形）").
    public var accent: OnboardingAccent {
        switch self {
        case .claudeCodeNotInstalled: .neutral
        case .helperMissing, .settingsNotWritable, .settingsParseFailure: .error
        case .notInstalled: .brand
        case .installed: .success
        }
    }
}
