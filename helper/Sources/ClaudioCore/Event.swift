import Foundation

/// The four v1 semantic events.
///
/// This enum is the **single source of truth** for the event-name mapping shared by
/// `install` / `play` / `uninstall` (ENGINEERING.md 决议 · 指令). Claude Code's
/// `settings.json` uses camelCase (`Stop`, `SubagentStop`), while the CLI `<event>`
/// token and the `manifest.json` event key use snake_case (`stop`, `subagent_stop`).
///
/// The mapping MUST go through this table — never `lowercased()`, which would turn
/// `SubagentStop` into `subagentstop` and fail to match the manifest key
/// `subagent_stop`. See ``Event/init(settingsName:)`` and the `Event` tests.
public enum Event: String, CaseIterable, Sendable {
    // Raw values are pinned to `cliName` explicitly (rather than left to Swift's default
    // camelCase-derived rawValue, which would give `stopFailure`/`subagentStop`) — anyone
    // who later reaches for `Event(rawValue:)` or `.rawValue` (e.g. in a config/log/test
    // fixture) must not get a third, undocumented spelling alongside `cliName`/`manifestKey`
    // (`/codex review` 2026-07-08).
    case stop = "stop"
    case stopFailure = "stop_failure"
    case notification = "notification"
    case subagentStop = "subagent_stop"

    /// Event name as written in Claude Code's `settings.json` hooks (camelCase).
    public var settingsName: String {
        switch self {
        case .stop: "Stop"
        case .stopFailure: "StopFailure"
        case .notification: "Notification"
        case .subagentStop: "SubagentStop"
        }
    }

    /// CLI `<event>` token — identical to the `manifest.json` event key (snake_case).
    public var cliName: String {
        switch self {
        case .stop: "stop"
        case .stopFailure: "stop_failure"
        case .notification: "notification"
        case .subagentStop: "subagent_stop"
        }
    }

    /// `manifest.json` event key — identical to ``cliName`` per the mapping table.
    public var manifestKey: String { cliName }

    /// Resolve from a `settings.json` event name (camelCase). Returns `nil` for
    /// events outside the v1 core set, which callers treat as "not one of ours".
    public init?(settingsName: String) {
        guard let match = Event.allCases.first(where: { $0.settingsName == settingsName })
        else { return nil }
        self = match
    }

    /// Resolve from a CLI `<event>` token / `manifest.json` key (snake_case).
    public init?(cliName: String) {
        guard let match = Event.allCases.first(where: { $0.cliName == cliName })
        else { return nil }
        self = match
    }
}
