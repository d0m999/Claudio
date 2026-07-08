import Foundation

/// The human-facing text + call-to-action labels for one ``OnboardingState``. Every
/// string here is written in the product's **reassurance narrative**, never engineering
/// phrasing (T7 acceptance criterion 3 — no "写入 hook 到 settings.json"-style copy):
/// the user should never need to know what `settings.json` or a "hook" is to understand
/// what Claudio is telling them or what to do next.
public struct OnboardingCopy: Sendable, Equatable {
    public let title: String
    public let body: String

    /// Optional technical detail (the underlying `SettingsWritability`/
    /// `SettingsUpdateError` reason string) surfaced only behind a secondary "查看原因"
    /// disclosure — mirrors DESIGN.md's existing "拒绝行" component pattern (原因 + 怎么
    /// 修), never inlined into ``body`` where it would break the reassurance tone.
    public let detail: String?

    /// The primary, full-width call-to-action button's label. `nil` only for
    /// ``OnboardingState/installed`` — the terminal success state has no forward action
    /// left to take.
    public let primaryActionTitle: String?

    /// A secondary, lower-emphasis ("ghost") action's label, if any.
    public let secondaryActionTitle: String?

    public init(
        title: String,
        body: String,
        detail: String? = nil,
        primaryActionTitle: String?,
        secondaryActionTitle: String? = nil
    ) {
        self.title = title
        self.body = body
        self.detail = detail
        self.primaryActionTitle = primaryActionTitle
        self.secondaryActionTitle = secondaryActionTitle
    }
}

/// Maps every ``OnboardingState`` to its ``OnboardingCopy``. Kept as a free function
/// (not a computed property on the state enum) so copy — presentation — stays a
/// separate, independently testable concern from the state machine itself, per T7's
/// "先定 per-feature 状态枚举，状态判定与转移下沉 view-model" split.
public func onboardingCopy(for state: OnboardingState) -> OnboardingCopy {
    switch state {
    case .claudeCodeNotInstalled:
        return OnboardingCopy(
            title: "没找到 Claude Code",
            body: "Claudio 得先有 Claude Code 才能配合报声音。按官方指引装好以后，回来点一下重新检测就行。",
            primaryActionTitle: "重新检测"
        )

    case .helperMissing:
        return OnboardingCopy(
            title: "还差最后一小步",
            body: "负责放声音的小助手还没装上。点一下，Claudio 会帮你补上，其它设置都不会动。",
            primaryActionTitle: "修复"
        )

    case .settingsNotWritable(let reason):
        return OnboardingCopy(
            title: "这份设置我们暂时改不了",
            body: "Claude Code 的配置文件目前不允许写入，Claudio 不会硬闯。改好权限后，回来点一下重新检测。",
            detail: reason,
            primaryActionTitle: "重新检测",
            secondaryActionTitle: "查看原因"
        )

    case .settingsParseFailure(let reason):
        return OnboardingCopy(
            title: "配置文件看着有点乱",
            body: "Claude Code 的配置文件格式跟预期不太一样，Claudio 怕越改越乱，先停手没有碰它。检查一下这个文件，弄好后回来点一下重新检测。",
            detail: reason,
            primaryActionTitle: "重新检测",
            secondaryActionTitle: "查看原因"
        )

    case .notInstalled:
        return OnboardingCopy(
            title: "让 Claude Code 学会开口",
            body: "接上以后，干完活、要你确认、被打断了都会有声音提示——不用回头盯屏幕也知道进度。"
                + "原来的其它设置都会保留，还会自动留一份备份，随时可以一键撤销。",
            primaryActionTitle: "接管 Claude Code"
        )

    case .installed:
        return OnboardingCopy(
            title: "已经接好了",
            body: "现在 Claude Code 干完活、要确认、被打断了都会响对应的声音。",
            primaryActionTitle: nil,
            secondaryActionTitle: "断开连接"
        )
    }
}
