import Foundation

/// The five stable semantic sound events.
///
/// This enum is the **single source of truth** for the event-name mapping shared by
/// `install` / `play` / `uninstall` (ENGINEERING.md 决议 · 指令). Claude Code's
/// `settings.json` uses camelCase (`Stop`, `SubagentStop`), while the CLI `<event>`
/// token and the `manifest.json` event key use snake_case (`stop`, `subagent_stop`).
///
/// The mapping MUST go through this table — never `lowercased()`, which would turn
/// `SubagentStop` into `subagentstop` and fail to match the manifest key
/// `subagent_stop`. 宿主原生事件名由 ``HostCapabilityCatalog`` 持有。
public enum Event: String, CaseIterable, Codable, Sendable, Hashable {
    // Raw values are pinned to `cliName` explicitly (rather than left to Swift's default
    // camelCase-derived rawValue, which would give `stopFailure`/`subagentStop`) — anyone
    // who later reaches for `Event(rawValue:)` or `.rawValue` (e.g. in a config/log/test
    // fixture) must not get a third, undocumented spelling alongside `cliName`/`manifestKey`
    // (`/codex review` 2026-07-08).
    case taskStart = "task_start"
    case stop = "stop"
    case stopFailure = "stop_failure"
    case notification = "notification"
    case subagentStop = "subagent_stop"

    /// CLI `<event>` token — identical to the `manifest.json` event key (snake_case).
    public var cliName: String {
        switch self {
        case .taskStart: "task_start"
        case .stop: "stop"
        case .stopFailure: "stop_failure"
        case .notification: "notification"
        case .subagentStop: "subagent_stop"
        }
    }

    /// `manifest.json` event key — identical to ``cliName`` per the mapping table.
    public var manifestKey: String { cliName }

    /// 用户界面的稳定声音语义；宿主原生事件名由各 adapter 提供。
    public var displayName: String {
        switch self {
        case .taskStart: "任务开始"
        case .stop: "本轮结束"
        case .stopFailure: "执行中断"
        case .notification: "待响应"
        case .subagentStop: "子任务结束"
        }
    }

    /// Resolve from a CLI `<event>` token / `manifest.json` key (snake_case).
    public init?(cliName: String) {
        guard let match = Event.allCases.first(where: { $0.cliName == cliName })
        else { return nil }
        self = match
    }

    /// Claude Code legacy `claudi0 play` 安装器继续只管理原有四个 lifecycle 事件。
    /// `UserPromptSubmit` 必须由现代宿主 adapter 在用户显式 connect / repair / upgrade
    /// 时写入，启动 bootstrap 不得借由 `Event.allCases` 静默修改宿主配置。
    public static let legacyLifecycleCases: [Event] = [
        .stop, .stopFailure, .notification, .subagentStop,
    ]
}
