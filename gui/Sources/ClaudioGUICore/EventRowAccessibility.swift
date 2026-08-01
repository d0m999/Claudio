import Foundation

/// The two VoiceOver labels ``EventRowView`` (`ClaudioGUI`) puts on its non-interactive
/// identity node and its file-name `Menu` (PLAN-SOUND-MANAGER.md §2.5 第 7 条, T2) — pulled
/// out into pure functions here for the same reason ``panelSentence(state:header:)`` /
/// ``panelAnnouncement(_:)`` live in `PanelAnnouncement.swift` rather than inside a view:
/// `EventRowView.swift` lives in `ClaudioGUI`, a `@main` executableTarget `claudio-gui-tests`
/// cannot `import`, so a DECISION left as a private computed property there is only ever
/// checked by source-text wiring probes ("the accessibilityLabel call is still attached"),
/// never by asserting on the actual returned string. `EventRowAccessibilitySuite` asserts on
/// these two functions' return values directly — the strings themselves, not their wiring.
///
/// `eventDisplayName` is stable semantic copy the caller supplies from `Event.displayName`.
/// These functions only own the DECISION of how that name composes with `coverage`/`enabled`.

/// The row's combined identity announcement (DESIGN.md「无障碍规格」: "事件行→「{事件名}，
/// 声音 {文件名}，{已启用/已静音}」") — lands on `EventRowView`'s non-interactive `identity`
/// node (its own `.accessibilityElement(children: .combine)`).
public func eventRowIdentityAccessibilityLabel(
    eventDisplayName: String, coverage: CoverageState, enabled: Bool
) -> String {
    let soundDescription: String
    switch coverage {
    case .present(let fileName): soundDescription = "声音 \(fileName)"
    case .unmapped: soundDescription = "未配置声音"
    case .broken: soundDescription = "声音文件丢失"
    }
    let muteDescription = enabled ? "已启用" : "已静音"
    return "\(eventDisplayName)，\(soundDescription)，\(muteDescription)"
}

/// `EventRowView.fileNameMenu`'s own accessibility label — deliberately phrased as "what
/// activating this control does", never a repeat of
/// ``eventRowIdentityAccessibilityLabel(eventDisplayName:coverage:enabled:)``'s combined
/// summary (PLAN-SOUND-MANAGER.md §2.5 第 7 条 ①: the row's identity and this control must
/// not double-announce the same fact — `EventRowAccessibilitySuite` asserts this directly for
/// all three coverage states, for exactly this pair of functions).
///
/// `.unmapped`'s wording carries §2.5 第 7 条 ③ as well: it must read as something a VoiceOver
/// user can act on ("选择" — an imperative verb), not a bare restatement of the row's visible
/// state text ("未配置", which lives in `EventRowView.pillLabel(text:)` — that string describes
/// what IS, this one describes what activating the control DOES).
///
/// `.broken`'s wording was rewritten alongside this extraction: the previous copy
/// ("…的声音文件丢失，选择新文件或清除绑定") repeated `identity`'s exact phrase "声音文件丢失"
/// verbatim — the precise double-announcement 第 7 条 ① forbids, just never pinned by a test
/// that could see the actual string before this file existed. The new copy only states what
/// activating the menu does, leaving the "what's wrong" half to `identity` alone.
public func eventRowFileNameMenuAccessibilityLabel(
    eventDisplayName: String, coverage: CoverageState
) -> String {
    switch coverage {
    case .present(let fileName):
        return "更改\(eventDisplayName)的声音，当前 \(fileName)"
    case .unmapped:
        return "为\(eventDisplayName)选择声音"
    case .broken:
        return "为\(eventDisplayName)重新选择声音，或清除这个失效的绑定"
    }
}
